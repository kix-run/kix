//! Live cluster resource fetching.
//!
//! Uses `kube` discovery to enumerate API resources, then parallel LIST
//! calls with label selectors to fetch kix-managed resources.

use std::collections::HashSet;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    Config,
    api::{Api, DynamicObject, ListParams},
    client::Client,
    config::{KubeConfigOptions, Kubeconfig},
    discovery::{ApiResource, Discovery, Scope},
};
use thiserror::Error;
use tokio::task::JoinSet;

/// Errors from cluster fetching operations.
#[derive(Error, Debug)]
pub enum FetchError {
    #[error("failed to create Kubernetes client: {0}")]
    ClientError(#[source] Box<dyn std::error::Error + Send + Sync>),

    #[error("failed to run API discovery")]
    DiscoveryError(#[source] kube::Error),

    #[error("failed to list {resource}: {source}")]
    ListError {
        resource: String,
        #[source]
        source: kube::Error,
    },
}

/// The managed-by label value that kix sets on all resources.
pub const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by=kix";

/// Resource types to skip — ephemeral, derived, or runtime-only.
/// Not useful for comparing declared vs actual state.
pub const SKIP_RESOURCES: &[&str] = &[
    // Ephemeral / runtime state
    "events",
    "events.events.k8s.io",
    "pods",
    "replicasets.apps",
    "controllerrevisions.apps",
    "endpointslices.discovery.k8s.io",
    "endpoints",
    "leases.coordination.k8s.io",
    "componentstatuses",
    // Node / cluster inventory (not declarative)
    "nodes",
    "nodes.metrics.k8s.io",
    "pods.metrics.k8s.io",
    "csinodes.storage.k8s.io",
    "csidrivers.storage.k8s.io",
    "csistoragecapacities.storage.k8s.io",
    "volumeattachments.storage.k8s.io",
    "runtimeclasses.node.k8s.io",
    // API machinery
    "apiservices.apiregistration.k8s.io",
    "flowschemas.flowcontrol.apiserver.k8s.io",
    "prioritylevelconfigurations.flowcontrol.apiserver.k8s.io",
    // Cilium runtime state
    "ciliumidentities.cilium.io",
    "ciliumendpoints.cilium.io",
    "ciliumnodes.cilium.io",
    // Backup runtime state (Velero)
    "backups.velero.io",
    "datadownloads.velero.io",
    "datauploads.velero.io",
    "podvolumebackups.velero.io",
    "podvolumerestores.velero.io",
    "backuprepositories.velero.io",
    // StackGres operational state
    "sgbackups.stackgres.io",
    "sgdbops.stackgres.io",
    // cert-manager transient state
    "orders.acme.cert-manager.io",
    "challenges.acme.cert-manager.io",
    "certificaterequests.cert-manager.io",
    // KubeVirt runtime
    "virtualmachineinstances.kubevirt.io",
    // Persistent volumes (dynamically provisioned)
    "persistentvolumes",
    // GitHub Actions runner ephemeral resources
    "ephemeralrunners.actions.github.com",
    "ephemeralrunnersets.actions.github.com",
    // CDI runtime
    "storageprofiles.cdi.kubevirt.io",
    // K3s/RKE2 internal. NOTE: helmchartconfigs.helm.cattle.io does NOT
    // belong here — it's user-declared configuration that the cilium-rke2
    // package emits, and this list feeds discover_resources, so skipping a
    // kind makes it undeployable ("kind HelmChartConfig not in discovery
    // cache"; first hit on stage1, the first rke2 cluster kix ever deployed).
    "etcdsnapshotfiles.k3s.cattle.io",
    "addons.k3s.cattle.io",
    "helmcharts.helm.cattle.io",
    // ZFS runtime state
    "zfsvolumes.zfs.openebs.io",
    "zfsnodes.zfs.openebs.io",
    "zfssnapshots.zfs.openebs.io",
    "volumesnapshotcontents.snapshot.storage.k8s.io",
];

/// Fully qualified resource name for skip-list matching (e.g. "pods" or "deployments.apps").
fn resource_fqn(ar: &ApiResource) -> String {
    if ar.group.is_empty() {
        ar.plural.clone()
    } else {
        format!("{}.{}", ar.plural, ar.group)
    }
}

/// Create a kube client, optionally targeting a specific context.
pub async fn make_client(context: Option<&str>) -> Result<Client, FetchError> {
    let config = match context {
        Some(ctx) => {
            let kubeconfig =
                Kubeconfig::read().map_err(|e| FetchError::ClientError(Box::new(e)))?;
            let options = KubeConfigOptions {
                context: Some(ctx.to_string()),
                ..Default::default()
            };
            Config::from_custom_kubeconfig(kubeconfig, &options)
                .await
                .map_err(|e| FetchError::ClientError(Box::new(e)))?
        }
        None => Config::infer()
            .await
            .map_err(|e| FetchError::ClientError(Box::new(e)))?,
    };
    Client::try_from(config).map_err(|e| FetchError::ClientError(Box::new(e)))
}

/// Run API discovery and return all listable resources with their scope.
pub async fn discover_resources(client: &Client) -> Result<Vec<(ApiResource, Scope)>, FetchError> {
    let skip_set: HashSet<&str> = SKIP_RESOURCES.iter().copied().collect();

    let discovery = Discovery::new(client.clone())
        .run()
        .await
        .map_err(FetchError::DiscoveryError)?;

    let mut resources = Vec::new();
    for group in discovery.groups() {
        resources.extend(collect_group_resources(group, &skip_set));
    }
    tracing::debug!(count = resources.len(), "API resources discovered");
    Ok(resources)
}

/// Walk one ApiGroup's resources across EVERY served version.
///
/// recommended_resources() only covers the group's PREFERRED version. A
/// group mixing versions (e.g. operator.victoriametrics.com ships v1beta1
/// kinds plus a v1 kind, making v1 preferred) would hide every
/// non-preferred kind from the deploy scheduler ("kind X not in discovery
/// cache"). Walk every version, preferred first, and keep the first
/// ApiResource seen per kind.
fn collect_group_resources(
    group: &kube::discovery::ApiGroup,
    skip_set: &HashSet<&str>,
) -> Vec<(ApiResource, Scope)> {
    let mut resources = Vec::new();
    let mut seen_kinds = std::collections::HashSet::new();
    let preferred = group.preferred_version_or_latest();
    let mut versions: Vec<&str> = vec![preferred];
    versions.extend(group.versions().filter(|v| *v != preferred));
    for ver in versions {
        for (ar, caps) in group.versioned_resources(ver) {
            if !seen_kinds.insert(ar.kind.clone()) {
                continue;
            }
            // Only include listable resources
            if !caps.supports_operation("list") {
                continue;
            }
            // Skip ephemeral types
            if skip_set.contains(resource_fqn(&ar).as_str()) {
                continue;
            }
            resources.push((ar, caps.scope));
        }
    }
    resources
}

/// Does the cluster serve `kind` in `group` only behind the skip list?
/// Diagnostic for the apply path: a manifest whose kind is SKIP_RESOURCES-
/// filtered would otherwise fail with an opaque "not in discovery cache"
/// after minutes of retries (stage1's HelmChartConfig, 2026-08-31). Fetches
/// the single group unfiltered and reports the skip-list fqn on a match.
pub async fn skip_listed_reason(client: &Client, group: &str, kind: &str) -> Option<String> {
    let ag = kube::discovery::group(client, group).await.ok()?;
    let empty: HashSet<&str> = HashSet::new();
    let unfiltered = collect_group_resources(&ag, &empty);
    let skip_set: HashSet<&str> = SKIP_RESOURCES.iter().copied().collect();
    unfiltered
        .iter()
        .find(|(ar, _)| ar.kind == kind && skip_set.contains(resource_fqn(ar).as_str()))
        .map(|(ar, _)| resource_fqn(ar))
}

/// Targeted single-group discovery — the reliable fallback when the full
/// sweep misses a kind. A bulk Discovery::run() under deploy load can
/// transiently drop whole groups (observed live on stage1: helm.cattle.io
/// absent from every refresh during a deploy while kubectl saw it fine);
/// fetching exactly one group is a single small request and doesn't share
/// that failure mode. `group` is "" for the core group.
pub async fn discover_group(
    client: &Client,
    group: &str,
) -> Result<Vec<(ApiResource, Scope)>, FetchError> {
    let skip_set: HashSet<&str> = SKIP_RESOURCES.iter().copied().collect();
    let ag = kube::discovery::group(client, group)
        .await
        .map_err(FetchError::DiscoveryError)?;
    Ok(collect_group_resources(&ag, &skip_set))
}

/// Merge a fresh discovery result into an existing cache, unioned by
/// (group, kind) with the fresh entry winning. Kubernetes' aggregated
/// discovery document is rebuilt after CRD writes and can transiently
/// omit whole unrelated groups (observed live on rke2 1.33 right after a
/// deploy applied 25 CRDs: helm.cattle.io vanished for a while, failing
/// every later HelmChartConfig apply with "kind not in discovery cache").
/// A refresh must therefore never *forget* kinds the cluster already
/// proved it serves — stale entries for genuinely deleted CRDs are
/// harmless by comparison (their applies would fail anyway).
pub fn merge_discovery(
    existing: &[(ApiResource, Scope)],
    fresh: Vec<(ApiResource, Scope)>,
) -> Vec<(ApiResource, Scope)> {
    let mut merged = fresh;
    let known: HashSet<(String, String)> = merged
        .iter()
        .map(|(ar, _)| (ar.group.clone(), ar.kind.clone()))
        .collect();
    for (ar, scope) in existing {
        if !known.contains(&(ar.group.clone(), ar.kind.clone())) {
            merged.push((ar.clone(), scope.clone()));
        }
    }
    merged
}

/// Fetch all resources with the `managed-by=kix` label, in parallel.
///
/// RBAC errors on individual resource types are logged and skipped
/// (the cluster may have CRDs the user can't list).
pub async fn fetch_managed_resources(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
) -> Result<Vec<DynamicObject>, FetchError> {
    let lp = ListParams::default().labels(MANAGED_BY_LABEL);
    fetch_parallel(client, discovery, &lp).await
}

/// Fetch specific resources by kind/name/namespace.
///
/// Runs a GET per resource rather than LIST+filter, since we know
/// exactly what we're looking for.
pub async fn fetch_matching_resources(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    manifests: &[ResourceId],
) -> Result<Vec<DynamicObject>, FetchError> {
    // Build a lookup: lowercase kind -> (ApiResource, Scope)
    let ar_by_kind: std::collections::HashMap<String, &(ApiResource, Scope)> = discovery
        .iter()
        .map(|pair| (pair.0.kind.to_lowercase(), pair))
        .collect();

    let mut set = JoinSet::new();

    for rid in manifests {
        let kind_lower = rid.kind.to_lowercase();
        let Some(&(ar, scope)) = ar_by_kind.get(&kind_lower) else {
            tracing::warn!(kind = %rid.kind, "no API resource found for kind, skipping");
            continue;
        };

        let api: Api<DynamicObject> = match scope {
            Scope::Namespaced => {
                let ns = if rid.namespace == CLUSTER_SCOPED {
                    "default"
                } else {
                    &rid.namespace
                };
                Api::namespaced_with(client.clone(), ns, &ar.clone())
            }
            Scope::Cluster => Api::all_with(client.clone(), &ar.clone()),
        };

        let name = rid.name.clone();
        let resource_id = rid.display_id();
        set.spawn(async move {
            match api.get(&name).await {
                Ok(obj) => Some(obj),
                Err(e) => {
                    tracing::debug!(resource = %resource_id, error = %e, "resource not found on cluster");
                    None
                }
            }
        });
    }

    let mut results = Vec::new();
    while let Some(join_result) = set.join_next().await {
        match join_result {
            Ok(Some(obj)) => results.push(obj),
            Ok(None) => {} // not found, already logged
            Err(e) => tracing::warn!(error = %e, "task join error during fetch"),
        }
    }
    Ok(results)
}

/// Strip server-side fields from a DynamicObject for diffing.
///
/// Removes: uid, resourceVersion, creationTimestamp, generation,
/// selfLink, managedFields, status, last-applied-configuration annotation.
pub fn normalize_for_diff(obj: &mut DynamicObject) {
    // Top-level metadata fields
    obj.metadata.uid = None;
    obj.metadata.resource_version = None;
    obj.metadata.creation_timestamp = None;
    obj.metadata.generation = None;
    obj.metadata.managed_fields = None;

    // Remove selfLink if present in the raw data
    if let Some(data) = obj.data.as_object_mut() {
        if let Some(meta) = data.get_mut("metadata").and_then(|m| m.as_object_mut()) {
            meta.remove("selfLink");
            meta.remove("uid");
            meta.remove("resourceVersion");
            meta.remove("creationTimestamp");
            meta.remove("generation");
            meta.remove("managedFields");

            // Strip last-applied-configuration annotation
            if let Some(annotations) = meta.get_mut("annotations").and_then(|a| a.as_object_mut()) {
                annotations.remove("kubectl.kubernetes.io/last-applied-configuration");
                // Remove annotations object entirely if empty
                if annotations.is_empty() {
                    meta.remove("annotations");
                }
            }
        }

        // Remove status entirely
        data.remove("status");
    }
}

/// Serialise a fetched object into a whole-manifest `Value`.
///
/// `DynamicObject` keeps `metadata` in a typed field and puts only the
/// *remaining* keys (`spec`, `data`, …) in `.data`. Serialising `.data`
/// alone therefore yields a manifest with no `metadata` — and so no
/// name or namespace — which silently degrades every `ResourceId` built
/// from it to `Kind/unknown`. Every live object of the same kind then
/// collapses onto one id, matches nothing on the kix side, and the diff
/// reports the whole cluster as "will be created".
///
/// `kind`/`apiVersion` come from `.data` (injected by `fetch_parallel`,
/// since LIST responses omit them per item) rather than from `.types`.
pub fn to_manifest_value(obj: &DynamicObject) -> serde_json::Value {
    serde_json::to_value(obj).unwrap_or_else(|e| {
        // ObjectMeta + a JSON Value cannot fail to serialise.
        unreachable!("DynamicObject failed to serialise: {e}")
    })
}

/// Internal: run parallel LIST calls across all discovered resource types.
async fn fetch_parallel(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    lp: &ListParams,
) -> Result<Vec<DynamicObject>, FetchError> {
    let mut set = JoinSet::new();

    for (ar, scope) in discovery {
        let api: Api<DynamicObject> = match scope {
            Scope::Namespaced => {
                // List across all namespaces
                Api::all_with(client.clone(), ar)
            }
            Scope::Cluster => Api::all_with(client.clone(), ar),
        };

        let lp = lp.clone();
        let fqn = resource_fqn(ar);
        let kind = ar.kind.clone();
        let api_version = ar.api_version.clone();
        set.spawn(async move {
            match api.list(&lp).await {
                Ok(list) => {
                    if !list.items.is_empty() {
                        tracing::debug!(resource = %fqn, count = list.items.len(), "fetched");
                    }
                    // Inject kind/apiVersion into data (LIST responses omit them)
                    let items: Vec<DynamicObject> = list
                        .items
                        .into_iter()
                        .map(|mut obj| {
                            if let Some(map) = obj.data.as_object_mut() {
                                map.entry("kind")
                                    .or_insert_with(|| serde_json::Value::String(kind.clone()));
                                map.entry("apiVersion").or_insert_with(|| {
                                    serde_json::Value::String(api_version.clone())
                                });
                            }
                            obj
                        })
                        .collect();
                    Ok(items)
                }
                Err(kube::Error::Api(ref resp)) if resp.code == 403 => {
                    // RBAC forbidden — skip silently (common with CRDs)
                    tracing::debug!(resource = %fqn, "RBAC forbidden, skipping");
                    Ok(vec![])
                }
                Err(e) => {
                    tracing::warn!(resource = %fqn, error = %e, "failed to list, skipping");
                    Ok(vec![])
                }
            }
        });
    }

    let mut results = Vec::new();
    while let Some(join_result) = set.join_next().await {
        match join_result {
            Ok(Ok(items)) => results.extend(items),
            Ok(Err(e)) => return Err(e),
            Err(e) => tracing::warn!(error = %e, "task join error during fetch"),
        }
    }
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::json;

    #[test]
    fn normalize_strips_server_fields() {
        let mut obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("test".into()),
                namespace: Some("default".into()),
                uid: Some("abc-123".into()),
                resource_version: Some("12345".into()),
                generation: Some(3),
                managed_fields: Some(vec![]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "metadata": {
                    "name": "test",
                    "namespace": "default",
                    "uid": "abc-123",
                    "resourceVersion": "12345",
                    "creationTimestamp": "2026-01-01T00:00:00Z",
                    "generation": 3,
                    "selfLink": "/api/v1/namespaces/default/pods/test",
                    "managedFields": [{"manager": "kubectl"}],
                    "annotations": {
                        "kubectl.kubernetes.io/last-applied-configuration": "{}",
                        "custom-annotation": "keep"
                    }
                },
                "spec": {"replicas": 1},
                "status": {"ready": true}
            }),
        };

        normalize_for_diff(&mut obj);

        // Typed metadata fields
        assert!(obj.metadata.uid.is_none());
        assert!(obj.metadata.resource_version.is_none());
        assert!(obj.metadata.generation.is_none());
        assert!(obj.metadata.managed_fields.is_none());

        // Raw JSON fields
        let data = obj.data.as_object().unwrap();
        let meta = data["metadata"].as_object().unwrap();
        assert!(!meta.contains_key("uid"));
        assert!(!meta.contains_key("resourceVersion"));
        assert!(!meta.contains_key("creationTimestamp"));
        assert!(!meta.contains_key("generation"));
        assert!(!meta.contains_key("selfLink"));
        assert!(!meta.contains_key("managedFields"));

        // last-applied-configuration stripped, custom annotation kept
        let annotations = meta["annotations"].as_object().unwrap();
        assert!(!annotations.contains_key("kubectl.kubernetes.io/last-applied-configuration"));
        assert_eq!(annotations["custom-annotation"], "keep");

        // status removed
        assert!(!data.contains_key("status"));

        // spec preserved
        assert!(data.contains_key("spec"));
    }

    /// A LIST item as the apiserver actually returns it: no per-item
    /// `apiVersion`/`kind`, and `metadata` alongside `spec`.
    fn list_item() -> DynamicObject {
        let mut obj: DynamicObject = serde_json::from_value(json!({
            "metadata": { "name": "lithus-secret-operator", "namespace": "lithus-system" },
            "spec": { "replicas": 1 },
        }))
        .unwrap();
        // What fetch_parallel does, because LIST omits these per item.
        let map = obj.data.as_object_mut().unwrap();
        map.insert("kind".into(), json!("Deployment"));
        map.insert("apiVersion".into(), json!("apps/v1"));
        obj
    }

    /// Pins the shape the whole bug turned on: kube-rs parses `metadata`
    /// into the typed field and leaves it OUT of `.data`. The hand-built
    /// fixtures above put `metadata` inside `.data`, which the apiserver
    /// never does — so anything reading `.data["metadata"]` reads nothing.
    #[test]
    fn deserialized_object_keeps_metadata_out_of_data() {
        let obj = list_item();
        assert_eq!(obj.metadata.name.as_deref(), Some("lithus-secret-operator"));
        assert!(
            obj.data.get("metadata").is_none(),
            "metadata must live on the typed field, not in .data"
        );
    }

    /// Regression: serialising `.data` alone drops metadata, so every live
    /// object of a kind degrades to the same `Kind/unknown` id, matches
    /// nothing, and `kix diff` reports an unchanged cluster as fully new.
    #[test]
    fn to_manifest_value_yields_a_matchable_resource_id() {
        let mut obj = list_item();
        normalize_for_diff(&mut obj);

        let broken = crate::manifest::types::ResourceId::from_value(&obj.data);
        assert_eq!(broken.name, "unknown", "the old .data-only path");

        let id = crate::manifest::types::ResourceId::from_value(&to_manifest_value(&obj));
        assert_eq!(id.kind, "Deployment");
        assert_eq!(id.name, "lithus-secret-operator");
        assert_eq!(id.namespace, "lithus-system");
    }

    /// normalize_for_diff clears the TYPED metadata fields; that only has
    /// any effect if the typed metadata is what gets serialised.
    #[test]
    fn to_manifest_value_drops_normalized_server_fields() {
        let mut obj = list_item();
        obj.metadata.uid = Some("abc-123".into());
        obj.metadata.resource_version = Some("12345".into());
        normalize_for_diff(&mut obj);

        let value = to_manifest_value(&obj);
        let meta = value.pointer("/metadata").unwrap().as_object().unwrap();
        assert!(!meta.contains_key("uid"));
        assert!(!meta.contains_key("resourceVersion"));
        assert_eq!(value.pointer("/spec/replicas").unwrap(), &json!(1));
    }

    #[test]
    fn skip_list_contains_expected() {
        let skip_set: HashSet<&str> = SKIP_RESOURCES.iter().copied().collect();
        assert!(skip_set.contains("pods"));
        assert!(skip_set.contains("replicasets.apps"));
        assert!(skip_set.contains("events.events.k8s.io"));
        assert!(skip_set.contains("leases.coordination.k8s.io"));
        assert!(skip_set.contains("ciliumendpoints.cilium.io"));
        assert!(!skip_set.contains("deployments.apps"));
        assert!(!skip_set.contains("services"));
    }
}
