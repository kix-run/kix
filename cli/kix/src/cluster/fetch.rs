//! Live cluster resource fetching.
//!
//! Uses `kube` discovery to enumerate API resources, then parallel LIST
//! calls with label selectors to fetch kix-managed resources.

use std::collections::HashSet;
use std::time::Duration;

use super::client::{ResiliencePolicy, build_client, mark_first_contact, preflight_enabled};
use super::errors::{FailureClass, classify};
use crate::manifest::keys;
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

    /// The endpoint swallowed the first-contact probe: no answer at all
    /// within the deadline. A stale `server:` address, a routing blackhole, a
    /// VPN or tailnet that is not up, or a load balancer that terminates TLS
    /// in front of an apiserver that has stopped answering all land here.
    #[error(
        "no response from the Kubernetes API server at {endpoint} within {}s. \
         Check the server address in your kubeconfig, or try --context <name>. \
         If the connection is working but needs more time, increase KIX_CONNECT_TIMEOUT (seconds).",
        timeout.as_secs()
    )]
    Unreachable { endpoint: String, timeout: Duration },

    /// First contact failed outright: DNS, connection refused, TLS, or a
    /// credential plugin that could not produce a token.
    #[error(
        "cannot reach the Kubernetes API server at {endpoint}: {}. \
         Check your kubeconfig, or try --context <name>.",
        super::errors::describe(source)
    )]
    ConnectFailed {
        endpoint: String,
        #[source]
        source: kube::Error,
    },

    #[error("could not discover the resource types supported by the Kubernetes API: {}", super::errors::describe(.0))]
    DiscoveryError(#[source] kube::Error),

    #[error("failed to list {resource}: {}", super::errors::describe(source))]
    ListError {
        resource: String,
        #[source]
        source: kube::Error,
    },
}

/// The managed-by label value that kix sets on all resources.
pub const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by=kix";

/// Fully qualified resource name for logging (e.g. "pods" or "deployments.apps").
fn resource_fqn(ar: &ApiResource) -> String {
    if ar.group.is_empty() {
        ar.plural.clone()
    } else {
        format!("{}.{}", ar.plural, ar.group)
    }
}

/// Create a kube client, optionally targeting a specific context.
///
/// The client carries the transport policy from [`super::client`]: retries
/// with backoff and per-request deadlines. Every command and the operator
/// build their client here.
///
/// Before returning, the client has exchanged one request with the
/// apiserver, so every caller past this point is talking to an endpoint that
/// answers. See [`probe_apiserver`] for why that matters.
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

    let policy = ResiliencePolicy::from_env();
    let endpoint = config.cluster_url.to_string();
    let deadline = policy.connect_timeout + PROBE_GRACE;

    let client = build_client(config, policy)
        .await
        .map_err(|e| FetchError::ClientError(Box::new(e)))?;

    if preflight_enabled() {
        probe_apiserver(&client, &endpoint, deadline).await?;
    }
    Ok(client)
}

/// How much slack the probe's deadline gets over the transport's
/// `connect_timeout`.
///
/// The two bound different things and must not race. A connect that never
/// completes is the transport's to report, because it knows the cause
/// ("tcp connect error", "deadline has elapsed") where the probe knows only
/// that time passed; the probe adds the endpoint on the way out. What is
/// left over for the probe's own deadline is the case the transport cannot
/// see at all: a connect that succeeded, followed by silence.
const PROBE_GRACE: Duration = Duration::from_secs(5);

/// Confirm the apiserver answers at all, within `deadline`.
///
/// `Client::try_from` never touches the network, so without this the first
/// real request carries the cost of an unreachable endpoint and the "failed
/// to connect to cluster" message at every call site is dead code: no error
/// is ever produced for it to print, because nothing has tried to connect
/// (kixpkgs#36).
///
/// Two failure shapes, and only one of them is a connect problem:
///
/// - The connect never completes or is refused. The transport's own
///   `connect_timeout` bounds it, and the probe's job is to add the endpoint
///   to the error, where kube alone yields an opaque
///   `ServiceError: client error (Connect)`.
/// - The connect completes and the endpoint then says nothing. No connect
///   timeout can ever fire on this one, because the connect succeeded. With
///   HTTPS the TLS handshake usually turns this into the first shape, but a
///   load balancer that terminates TLS in front of a wedged apiserver does
///   not. Only the probe's own deadline bounds it.
///
/// Only transport failures count as unreachable. *Any* HTTP response, 401
/// and 403 and 404 included, proves the endpoint is alive, so the probe
/// passes and the real call gets to report the real error. That rule is what
/// keeps the probe from becoming a new failure mode of its own on a cluster
/// where the account cannot read `/version`.
async fn probe_apiserver(
    client: &Client,
    endpoint: &str,
    deadline: Duration,
) -> Result<(), FetchError> {
    // `Client::apiserver_version()` would do, but it gives us no way to mark
    // the request, so this is that call with the marker added. The response
    // is `/version`'s, and the connection it opens is pooled for the real
    // work that follows.
    let mut request = match http::Request::get("/version").body(Vec::new()) {
        Ok(request) => request,
        Err(e) => return Err(FetchError::ClientError(Box::new(e))),
    };
    mark_first_contact(&mut request);

    let probe = client.request::<k8s_openapi::apimachinery::pkg::version::Info>(request);
    match tokio::time::timeout(deadline, probe).await {
        Ok(Ok(info)) => {
            tracing::debug!(endpoint, version = %info.git_version, "apiserver reachable");
            Ok(())
        }
        Ok(Err(e)) if server_responded(&e) => {
            // Alive, just not willing or able to serve /version to us.
            tracing::debug!(endpoint, error = %e, "apiserver reachable, /version unreadable");
            Ok(())
        }
        Ok(Err(source)) => Err(FetchError::ConnectFailed {
            endpoint: endpoint.to_string(),
            source,
        }),
        Err(_elapsed) => Err(FetchError::Unreachable {
            endpoint: endpoint.to_string(),
            timeout: deadline,
        }),
    }
}

/// Did an HTTP response come back? Separates "the endpoint is alive but said
/// no" from "we never reached it".
fn server_responded(e: &kube::Error) -> bool {
    matches!(
        e,
        kube::Error::Api(_) | kube::Error::SerdeError(_) | kube::Error::FromUtf8(_)
    )
}

/// Run API discovery and return all listable resources with their scope.
pub async fn discover_resources(client: &Client) -> Result<Vec<(ApiResource, Scope)>, FetchError> {
    let discovery = Discovery::new(client.clone())
        .run()
        .await
        .map_err(FetchError::DiscoveryError)?;

    let mut resources = Vec::new();
    for group in discovery.groups() {
        resources.extend(collect_group_resources(group));
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
fn collect_group_resources(group: &kube::discovery::ApiGroup) -> Vec<(ApiResource, Scope)> {
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
            resources.push((ar, caps.scope));
        }
    }
    resources
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
    let ag = kube::discovery::group(client, group)
        .await
        .map_err(FetchError::DiscoveryError)?;
    Ok(collect_group_resources(&ag))
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

/// What the managed sweep found.
pub struct ManagedSweep {
    /// Objects kix applied: each carries `kix.run/identity-hash`.
    pub managed: Vec<DynamicObject>,
    /// Objects that carry the kix label but no identity hash and no owner.
    /// kix never applied them (someone `kubectl apply`ed a kix render, or a
    /// pre-hash kix did). `kix gc --hard` reports them; nothing deletes them
    /// unless asked.
    pub unstamped: Vec<DynamicObject>,
    /// Resource types this account may not list (403). Nothing in them is
    /// visible to kix. Callers print this so a narrower-than-cluster view is
    /// never mistaken for a complete one.
    pub forbidden: Vec<String>,
}

/// Fetch every resource kix applied, in parallel: one LIST per discovered
/// kind with the `managed-by=kix` label selector, then [`partition_sweep`].
///
/// A 403 on a resource type is recorded, not fatal: the account simply
/// cannot see that kind. Use [`sweep_managed`] to read the list. Any other
/// list failure that survives the transport's retries is an error: a plan
/// built on a partial view of the cluster is wrong in ways the user cannot
/// see, so no caller gets one.
pub async fn fetch_managed_resources(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
) -> Result<Vec<DynamicObject>, FetchError> {
    Ok(sweep_managed(client, discovery).await?.managed)
}

/// The full sweep: kix-applied objects plus the unstamped label carriers.
pub async fn sweep_managed(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
) -> Result<ManagedSweep, FetchError> {
    let lp = ListParams::default().labels(MANAGED_BY_LABEL);
    let listed = fetch_parallel(client, discovery, &lp).await?;
    let mut sweep = partition_sweep(listed.objects);
    sweep.forbidden = listed.forbidden;
    Ok(sweep)
}

/// Decide what the label sweep really found.
///
/// The label only finds candidates; it does not prove kix applied an object.
/// Controllers copy labels onto what they derive: the EndpointSlice
/// controller mirrors a Service's labels, ReplicaSets and Pods carry their
/// template's labels. Proof that kix applied something is its
/// `kix.run/identity-hash` annotation, which the apply step stamps and no
/// controller copies. So:
///
/// - stamped: kix's, whatever its owner references say (`managed`);
/// - unstamped and owned: a controller child, judged through its owner and
///   dropped here;
/// - unstamped and unowned: kept apart in `unstamped` for gc to report;
/// - unstamped `Endpoints` named after a managed Service in the same
///   namespace: that Service's mirror. Endpoints are the pre-EndpointSlice
///   mirror; the endpoints controller copies the Service's labels and sets
///   no owner reference, so ownership alone cannot tell them apart. Dropped.
///
/// These rules replace the old hand-maintained list of "ephemeral" kinds,
/// which also made every listed kind undeployable because the same
/// discovery cache resolved kinds on the apply path (kixpkgs#41).
pub fn partition_sweep(objects: Vec<DynamicObject>) -> ManagedSweep {
    let (managed, rest): (Vec<DynamicObject>, Vec<DynamicObject>) =
        objects.into_iter().partition(is_stamped);
    let managed_services: HashSet<(String, String)> = managed
        .iter()
        .filter(|o| object_kind(o) == "Service")
        .map(|o| (namespace_of(o), o.metadata.name.clone().unwrap_or_default()))
        .collect();
    let unstamped = rest
        .into_iter()
        .filter(|o| !is_owned(o))
        .filter(|o| {
            !(object_kind(o) == "Endpoints"
                && managed_services
                    .contains(&(namespace_of(o), o.metadata.name.clone().unwrap_or_default())))
        })
        .collect();
    ManagedSweep {
        managed,
        unstamped,
        forbidden: Vec::new(),
    }
}

/// Did kix's apply step stamp this object?
pub fn is_stamped(obj: &DynamicObject) -> bool {
    obj.metadata
        .annotations
        .as_ref()
        .is_some_and(|a| keys::contains_meta(a, keys::IDENTITY_HASH))
}

/// Does a controller own this object?
pub fn is_owned(obj: &DynamicObject) -> bool {
    obj.metadata
        .owner_references
        .as_ref()
        .is_some_and(|owners| !owners.is_empty())
}

fn object_kind(obj: &DynamicObject) -> &str {
    obj.data
        .get("kind")
        .and_then(serde_json::Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("")
}

fn namespace_of(obj: &DynamicObject) -> String {
    obj.metadata.namespace.clone().unwrap_or_default()
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
            tracing::warn!(kind = %rid.kind, "Kubernetes does not recognize this resource kind; skipping it");
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
            Err(e) => {
                tracing::warn!(error = %e, "a resource-fetching task stopped unexpectedly; results may be incomplete")
            }
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

/// The kix-owned view of a live object: the live value projected onto the
/// fieldset kix's server-side apply owns (doc 122's recipe), with the type
/// meta and identity that fieldsV1 never lists (`apiVersion`, `kind`,
/// `metadata.name`, `metadata.namespace`) restored.
///
/// This is what `kix diff` and `kix snapshot save` compare against a build:
/// the server's defaults (deployment strategy, probe thresholds, scheduler
/// name, ...) are owned by nobody or by a controller, so they never enter the
/// view, and kix's own bookkeeping annotations (`kix.run/activations`,
/// `kix.run/applied-hash`) are written through a separate `Update` entry, so
/// they are excluded too. Comparing this to the rendered manifest asks the
/// question a change review actually needs answered: "does what kix would
/// apply differ from what kix last applied?"
///
/// Objects without a kix `Apply` entry (adopted by hand, or predating SSA)
/// fall back to the whole object with server metadata stripped.
pub fn kix_owned_view(obj: &DynamicObject) -> serde_json::Value {
    let Some(mut view) = super::fieldsv1::kix_owned_projection(obj) else {
        let mut fallback = obj.clone();
        normalize_for_diff(&mut fallback);
        return to_manifest_value(&fallback);
    };
    if let Some(map) = view.as_object_mut() {
        for key in ["apiVersion", "kind"] {
            if let Some(v) = obj.data.get(key) {
                map.insert(key.to_string(), v.clone());
            }
        }
        let meta = map
            .entry("metadata")
            .or_insert_with(|| serde_json::json!({}));
        if let Some(meta) = meta.as_object_mut() {
            if let Some(name) = &obj.metadata.name {
                meta.insert("name".into(), serde_json::Value::String(name.clone()));
            }
            if let Some(ns) = &obj.metadata.namespace {
                meta.insert("namespace".into(), serde_json::Value::String(ns.clone()));
            }
        }
    }
    view
}

/// The kix-owned view of every object in a sweep, brought to the current
/// domain: what a build is compared against, whether the comparison runs
/// now (`kix diff`), later from a directory (`kix snapshot save`), or as
/// the previous state a deploy plans from when its store path is gone.
///
/// The domain upgrade matters on a cluster a previous Kix stamped under a
/// retired domain: without it every Kix annotation reads as a paired add
/// and remove, and an in-sync cluster reads as entirely modified.
pub fn kix_owned_manifests(
    objects: impl IntoIterator<Item = DynamicObject>,
) -> Vec<serde_json::Value> {
    objects
        .into_iter()
        .map(|obj| {
            let mut manifest = kix_owned_view(&obj);
            crate::legacy_domain::upgrade_manifest(&mut manifest);
            manifest
        })
        .collect()
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

/// What one parallel LIST pass produced.
pub struct Listed {
    pub objects: Vec<DynamicObject>,
    /// Resource types that answered 403.
    pub forbidden: Vec<String>,
}

/// One task's result inside [`fetch_parallel`].
enum ListOutcome {
    Items(Vec<DynamicObject>),
    Forbidden(String),
}

/// How many LISTs the sweep keeps in flight. One per kind is over a hundred
/// on a real cluster, and the apiserver's priority-and-fairness answers
/// that burst with 429s. Bounded here, on spawned tasks the runtime always
/// polls, rather than in the transport layer, where a permit held inside a
/// future its owner had parked deadlocked `kix deploy` (see
/// `cluster::client`). Override with `KIX_SWEEP_CONCURRENCY`.
pub const DEFAULT_SWEEP_CONCURRENCY: usize = 16;
/// Env var for [`DEFAULT_SWEEP_CONCURRENCY`].
pub const SWEEP_CONCURRENCY_ENV: &str = "KIX_SWEEP_CONCURRENCY";

fn sweep_concurrency() -> usize {
    super::client::env_number(SWEEP_CONCURRENCY_ENV)
        .map(|n| n.max(1) as usize)
        .unwrap_or(DEFAULT_SWEEP_CONCURRENCY)
}

/// Internal: run parallel LIST calls across all discovered resource types,
/// at most [`DEFAULT_SWEEP_CONCURRENCY`] at a time.
///
/// The transport layer already retried each LIST on 429, 5xx and
/// connection errors, so an error here is one that outlasted the budget.
/// It is returned, and dropping the `JoinSet` cancels the lists still in
/// flight. The old behaviour, logging a warning and continuing with an
/// empty list for that kind, made `kix diff` report every PackageInstance
/// as "will be created" during an apiserver restart (2026-09-07, stage1).
async fn fetch_parallel(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    lp: &ListParams,
) -> Result<Listed, FetchError> {
    let mut set = JoinSet::new();
    let mut listed = Listed {
        objects: Vec::new(),
        forbidden: Vec::new(),
    };
    let limit = sweep_concurrency();

    for (ar, scope) in discovery {
        // Keep the number in flight bounded: drain one before adding one.
        while set.len() >= limit {
            match set.join_next().await {
                Some(outcome) => absorb(&mut listed, outcome)?,
                None => break,
            }
        }
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
                    Ok(ListOutcome::Items(items))
                }
                Err(e) if classify(&e) == FailureClass::Forbidden => {
                    // RBAC: a stable fact about the account, not a fault.
                    tracing::debug!(resource = %fqn, "forbidden, recorded");
                    Ok(ListOutcome::Forbidden(fqn))
                }
                Err(e) => Err(FetchError::ListError {
                    resource: fqn,
                    source: e,
                }),
            }
        });
    }

    while let Some(join_result) = set.join_next().await {
        absorb(&mut listed, join_result)?;
    }
    listed.forbidden.sort();
    Ok(listed)
}

/// Fold one finished LIST task into the result, or stop on its error.
// FetchError carries a kube::Error; boxing it here would only move the
// size to every caller's match arms.
#[allow(clippy::result_large_err)]
fn absorb(
    listed: &mut Listed,
    join_result: Result<Result<ListOutcome, FetchError>, tokio::task::JoinError>,
) -> Result<(), FetchError> {
    match join_result {
        Ok(Ok(ListOutcome::Items(items))) => listed.objects.extend(items),
        Ok(Ok(ListOutcome::Forbidden(fqn))) => listed.forbidden.push(fqn),
        Ok(Err(e)) => return Err(e),
        Err(e) => return Err(FetchError::ClientError(Box::new(e))),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::json;

    fn managed(
        manager: &str,
        operation: &str,
        subresource: Option<&str>,
        fields: serde_json::Value,
    ) -> k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
        k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
            manager: Some(manager.into()),
            operation: Some(operation.into()),
            subresource: subresource.map(str::to_string),
            fields_v1: Some(k8s_openapi::apimachinery::pkg::apis::meta::v1::FieldsV1(
                fields,
            )),
            ..Default::default()
        }
    }

    /// A live Deployment as the apiserver hands it back: kix's Apply entry
    /// owns what kix sent, kix's bookkeeping patch is a separate Update
    /// entry, the controller owns its revision annotation and status, and
    /// the server defaulted strategy, probe thresholds and the like with no
    /// owner at all. Only the first survives.
    #[test]
    fn kix_owned_view_keeps_only_the_applied_fieldset() {
        let f_identity = format!("f:{}", keys::IDENTITY_HASH);
        let f_activations = format!("f:{}", keys::ACTIVATIONS);
        let f_applied = format!("f:{}", keys::APPLIED_HASH);
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("web".into()),
                namespace: Some("app".into()),
                uid: Some("abc".into()),
                resource_version: Some("9".into()),
                labels: Some(
                    [(
                        "app.kubernetes.io/managed-by".to_string(),
                        "kix".to_string(),
                    )]
                    .into(),
                ),
                annotations: Some(
                    [
                        (keys::IDENTITY_HASH.to_string(), "h1".to_string()),
                        (keys::ACTIVATIONS.to_string(), "a1".to_string()),
                        (keys::APPLIED_HASH.to_string(), "deadbeef".to_string()),
                        (
                            "deployment.kubernetes.io/revision".to_string(),
                            "1".to_string(),
                        ),
                    ]
                    .into(),
                ),
                managed_fields: Some(vec![
                    managed(
                        "kix",
                        "Apply",
                        None,
                        json!({
                            "f:metadata": {
                                "f:annotations": {f_identity: {}},
                                "f:labels": {"f:app.kubernetes.io/managed-by": {}}
                            },
                            "f:spec": {
                                "f:replicas": {},
                                "f:selector": {},
                                "f:template": {"f:spec": {"f:containers": {
                                    "k:{\"name\":\"nginx\"}": {
                                        ".": {}, "f:name": {}, "f:image": {},
                                        "f:readinessProbe": {"f:httpGet": {"f:path": {}, "f:port": {}}}
                                    }
                                }}}
                            }
                        }),
                    ),
                    managed(
                        "kix",
                        "Update",
                        None,
                        json!({
                            "f:metadata": {"f:annotations": {f_activations: {}, f_applied: {}}}
                        }),
                    ),
                    managed(
                        "kube-controller-manager",
                        "Update",
                        Some("status"),
                        json!({
                            "f:metadata": {"f:annotations": {"f:deployment.kubernetes.io/revision": {}}},
                            "f:status": {"f:replicas": {}}
                        }),
                    ),
                ]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "spec": {
                    "replicas": 2,
                    "selector": {"matchLabels": {"app": "web"}},
                    "progressDeadlineSeconds": 600,
                    "revisionHistoryLimit": 10,
                    "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": "25%"}},
                    "template": {
                        "metadata": {"creationTimestamp": null},
                        "spec": {
                            "dnsPolicy": "ClusterFirst",
                            "schedulerName": "default-scheduler",
                            "containers": [{
                                "name": "nginx",
                                "image": "nginx:1.27",
                                "terminationMessagePath": "/dev/termination-log",
                                "readinessProbe": {
                                    "httpGet": {"path": "/", "port": "http", "scheme": "HTTP"},
                                    "failureThreshold": 3,
                                    "periodSeconds": 10
                                }
                            }]
                        }
                    }
                },
                "status": {"replicas": 2}
            }),
        };

        assert_eq!(
            kix_owned_view(&obj),
            json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": "web",
                    "namespace": "app",
                    "annotations": {keys::IDENTITY_HASH: "h1"},
                    "labels": {"app.kubernetes.io/managed-by": "kix"}
                },
                "spec": {
                    "replicas": 2,
                    "selector": {"matchLabels": {"app": "web"}},
                    "template": {"spec": {"containers": [{
                        "name": "nginx",
                        "image": "nginx:1.27",
                        "readinessProbe": {"httpGet": {"path": "/", "port": "http"}}
                    }]}}
                }
            })
        );
    }

    /// No kix Apply entry (adopted by hand, or pre-SSA): the whole object,
    /// minus server metadata, so the diff still has something to show.
    #[test]
    fn kix_owned_view_falls_back_without_an_apply_entry() {
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("cm".into()),
                namespace: Some("app".into()),
                uid: Some("abc".into()),
                managed_fields: Some(vec![managed(
                    "kubectl-create",
                    "Update",
                    None,
                    json!({"f:data": {}}),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({"apiVersion": "v1", "kind": "ConfigMap", "data": {"k": "v"}}),
        };
        let view = kix_owned_view(&obj);
        assert_eq!(view["data"], json!({"k": "v"}));
        assert_eq!(view["metadata"]["name"], json!("cm"));
        assert!(view["metadata"].get("uid").is_none());
        assert!(view["metadata"].get("managedFields").is_none());
    }

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

    fn swept(kind: &str, ns: &str, name: &str, stamped: bool, owned: bool) -> DynamicObject {
        use k8s_openapi::apimachinery::pkg::apis::meta::v1::OwnerReference;
        let mut obj = DynamicObject {
            types: None,
            metadata: ObjectMeta {
                name: Some(name.into()),
                namespace: Some(ns.into()),
                ..Default::default()
            },
            data: json!({ "kind": kind }),
        };
        if stamped {
            obj.metadata.annotations = Some(
                [(keys::IDENTITY_HASH.to_string(), "h".to_string())]
                    .into_iter()
                    .collect(),
            );
        }
        if owned {
            obj.metadata.owner_references = Some(vec![OwnerReference {
                api_version: "v1".into(),
                kind: "Service".into(),
                name: name.into(),
                uid: "abc".into(),
                controller: Some(true),
                block_owner_deletion: None,
            }]);
        }
        obj
    }

    fn names(objs: &[DynamicObject]) -> Vec<String> {
        let mut v: Vec<String> = objs
            .iter()
            .map(|o| {
                format!(
                    "{}/{}/{}",
                    o.metadata.namespace.as_deref().unwrap_or(""),
                    o.data["kind"].as_str().unwrap(),
                    o.metadata.name.as_deref().unwrap()
                )
            })
            .collect();
        v.sort();
        v
    }

    #[test]
    fn sweep_keeps_stamped_objects_whoever_owns_them() {
        let sweep = partition_sweep(vec![
            swept("Deployment", "ns", "web", true, false),
            swept("Job", "ns", "adopted", true, true),
        ]);
        assert_eq!(
            names(&sweep.managed),
            ["ns/Deployment/web", "ns/Job/adopted"]
        );
        assert!(sweep.unstamped.is_empty());
    }

    #[test]
    fn sweep_drops_owned_unstamped_children() {
        let sweep = partition_sweep(vec![
            swept("Service", "ns", "web", true, false),
            swept("EndpointSlice", "ns", "web-abc12", false, true),
            swept("ReplicaSet", "ns", "web-7d9f", false, true),
        ]);
        assert_eq!(names(&sweep.managed), ["ns/Service/web"]);
        assert!(sweep.unstamped.is_empty());
    }

    #[test]
    fn sweep_reports_unowned_unstamped_label_carriers() {
        let sweep = partition_sweep(vec![swept(
            "ConfigMap",
            "ns",
            "kubectl-applied",
            false,
            false,
        )]);
        assert!(sweep.managed.is_empty());
        assert_eq!(names(&sweep.unstamped), ["ns/ConfigMap/kubectl-applied"]);
    }

    #[test]
    fn sweep_treats_endpoints_named_after_a_managed_service_as_its_mirror() {
        let sweep = partition_sweep(vec![
            swept("Service", "ns", "web", true, false),
            swept("Endpoints", "ns", "web", false, false),
            swept("Endpoints", "ns", "stray", false, false),
            swept("Endpoints", "other", "web", false, false),
        ]);
        assert_eq!(names(&sweep.managed), ["ns/Service/web"]);
        assert_eq!(
            names(&sweep.unstamped),
            ["ns/Endpoints/stray", "other/Endpoints/web"],
            "only the same-namespace mirror is dropped"
        );
    }

    // ── First contact (kixpkgs#36) ───────────────────────────────────────
    //
    // These drive a real localhost socket rather than mocking kube, because
    // the mode that matters is a TCP-level one: accept the connection and
    // then say nothing. A mock at the kube layer cannot express it.

    /// A localhost stand-in for an apiserver.
    ///
    /// `reply: None` accepts the connection and then goes silent, which is
    /// the failure mode no connect timeout can catch: the handshake
    /// succeeds, so only a deadline above the connect ever fires.
    async fn fake_apiserver(reply: Option<&'static [u8]>) -> String {
        use tokio::io::AsyncWriteExt;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            // Sockets stay in `held` so the peer sees silence, not a close.
            let mut held = Vec::new();
            while let Ok((mut sock, _)) = listener.accept().await {
                if let Some(bytes) = reply {
                    let _ = sock.write_all(bytes).await;
                    let _ = sock.flush().await;
                }
                held.push(sock);
            }
        });
        format!("http://{addr}")
    }

    /// A client for `endpoint`, built the way `make_client` builds it.
    async fn client_for(endpoint: &str) -> Client {
        let config = Config::new(endpoint.parse().unwrap());
        build_client(config, ResiliencePolicy::default())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn probe_gives_up_on_a_silent_endpoint() {
        let endpoint = fake_apiserver(None).await;
        let client = client_for(&endpoint).await;

        let started = tokio::time::Instant::now();
        let err = probe_apiserver(&client, &endpoint, Duration::from_millis(300))
            .await
            .expect_err("a silent endpoint must not pass the probe");

        assert!(
            matches!(err, FetchError::Unreachable { .. }),
            "expected Unreachable, got {err:?}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "probe must fail on its own deadline, not the transport's"
        );
        // The message has to name the endpoint: that is the whole point of
        // failing here rather than deep inside discovery.
        assert!(err.to_string().contains(&endpoint), "{err}");
    }

    #[tokio::test]
    async fn probe_passes_when_the_endpoint_answers_at_all() {
        // 403 on /version still proves the apiserver is alive and routable;
        // the real call gets to report the real error.
        let endpoint = fake_apiserver(Some(
            b"HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 61\r\n\r\n\
              {\"kind\":\"Status\",\"status\":\"Failure\",\"code\":403,\"message\":\"no\"}",
        ))
        .await;
        let client = client_for(&endpoint).await;

        probe_apiserver(&client, &endpoint, Duration::from_secs(5))
            .await
            .expect("an endpoint that responds must pass the probe");
    }

    #[tokio::test]
    async fn probe_reports_a_refused_connection() {
        // Bind then drop: nothing is listening on the port any more.
        let endpoint = {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            format!("http://{}", listener.local_addr().unwrap())
        };
        let client = client_for(&endpoint).await;

        let err = probe_apiserver(&client, &endpoint, Duration::from_secs(5))
            .await
            .expect_err("a closed port must not pass the probe");

        assert!(
            matches!(err, FetchError::ConnectFailed { .. }),
            "expected ConnectFailed, got {err:?}"
        );
        assert!(err.to_string().contains(&endpoint), "{err}");
    }

    #[tokio::test]
    async fn probe_reports_a_refused_connection_without_retrying() {
        // The same refused port under the full policy is retried for ~18s.
        // The `FirstContact` marker is what stops that, and it is the whole
        // reason a probe on the real client is affordable.
        let endpoint = {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            format!("http://{}", listener.local_addr().unwrap())
        };
        let client = client_for(&endpoint).await;

        let started = tokio::time::Instant::now();
        probe_apiserver(&client, &endpoint, Duration::from_secs(30))
            .await
            .expect_err("a closed port must not pass the probe");

        assert!(
            started.elapsed() < Duration::from_secs(5),
            "first contact must not spend the retry budget: took {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn the_probe_deadline_does_not_tie_with_the_transports() {
        // Two deadlines of the same length would race for the error message.
        assert!(
            PROBE_GRACE > Duration::ZERO,
            "the transport must win the connect race, not tie it"
        );
    }
}
