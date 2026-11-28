//! Readiness checks for import markers and resource expectations.

use std::time::Duration;

use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use tokio::time::Instant;

use super::super::cancel::CancelToken;
use super::super::errors::{FailureClass, classify};
use super::declared::{
    check_crd_ready, check_readiness, is_immediate_kind, readiness_message, served_crd_versions,
    unserved_crd_versions,
};
use super::{
    CRD_AWAITING_DISCOVERY, POLL_INTERVAL, ReadinessError, ReadinessResult, crd_kind_served,
};
use crate::manifest::keys;
use crate::manifest::kinds::{self, GroupKind};

/// A resource described by an import marker. The CLI polls the cluster for
/// this resource and blocks dependents until it is present and ready, using the
/// same per-kind readiness checks as managed resources (for example, waiting
/// for `readyReplicas == spec.replicas` on `Deployment` resources). CRDs also
/// require `Established=True`, and `Secret` resources with `expected_keys`
/// verify that every declared key is present in `data`.
///
/// For namespaced kinds, the described resource is expected in the namespace
/// named by `kix.run/import-namespace`, or in the marker's own namespace when
/// the marker does not carry it. A platform that refuses writes to a
/// namespace, such as `kube-system` on GKE Autopilot, can then keep the marker
/// elsewhere.
#[derive(Debug, Clone)]
pub struct ImportTarget {
    /// Kubernetes kind of the expected resource (such as `"CustomResourceDefinition"`).
    pub kind: String,
    /// Kubernetes `apiVersion` (such as `"apiextensions.k8s.io/v1"` or `"v1"`).
    pub api_version: String,
    /// Name of the expected resource.
    pub name: String,
    /// Namespace of the expected resource. `None` for cluster-scoped kinds
    /// (currently `CustomResourceDefinition`). For namespaced kinds, this
    /// comes from `kix.run/import-namespace`, or else the marker's own
    /// `metadata.namespace`.
    pub namespace: Option<String>,
    /// For `Secret` imports, the set of keys expected in `data`, parsed from
    /// the comma-separated `kix.run/import-secret-keys` annotation. When empty,
    /// only Secret existence is checked.
    pub expected_keys: Vec<String>,
    /// For a CRD reference marker, the API versions declared in
    /// `kix.run/crd-served-versions`. Each version must appear in the live
    /// CRD's `spec.versions` with `served: true`. Empty for non-CRD imports.
    pub served_versions: Vec<String>,
}

impl ImportTarget {
    /// Return the API group and kind of the imported resource.
    pub fn group_kind(&self) -> GroupKind<'_> {
        GroupKind::new(
            crate::manifest::types::api_group(&self.api_version),
            &self.kind,
        )
    }

    /// Return the group, kind, namespace, and name of the imported object.
    pub fn resource_id(&self) -> crate::manifest::types::ResourceId {
        crate::manifest::types::ResourceId::new(
            crate::manifest::types::api_group(&self.api_version),
            &self.kind,
            self.namespace
                .as_deref()
                .unwrap_or(crate::manifest::types::CLUSTER_SCOPED),
            &self.name,
        )
    }
}

/// An import marker with missing or invalid annotations. Planning a deploy
/// rejects the build rather than deploying a marker whose checks would be
/// skipped.
#[derive(Debug, thiserror::Error)]
#[error("{marker}: {reason}")]
pub struct MalformedMarker {
    /// The marker identifier formatted as `PackageInstance <namespace>/<name>`.
    pub marker: String,
    pub reason: String,
}

/// Extract an [`ImportTarget`] from a manifest if it is a `PackageInstance`
/// import marker (`kix.run/mode: import`). Returns `Ok(None)` for non-markers
/// or for markers that lack a target kind or name.
///
/// A CRD reference marker carries `kix.run/crd-kind` and must also list at
/// least one version in `kix.run/crd-served-versions`, or this function returns
/// [`MalformedMarker`].
///
/// The target's namespace comes from `kix.run/import-namespace`, or else the
/// marker's own `metadata.namespace`, for namespaced kinds, or `None` for
/// `CustomResourceDefinition`.
pub fn import_target_from_manifest(
    manifest: &Value,
) -> Result<Option<ImportTarget>, MalformedMarker> {
    if !crate::manifest::lifecycle::is_marker(manifest) {
        return Ok(None);
    }
    let Some(annotations) = manifest.pointer("/metadata/annotations") else {
        return Ok(None);
    };
    let annotation = |key: &str| annotations.get(key).and_then(Value::as_str);

    let (Some(import_kind), Some(import_api_version), Some(import_name)) = (
        annotation(keys::IMPORT_KIND),
        annotation(keys::IMPORT_API_VERSION),
        annotation(keys::IMPORT_NAME),
    ) else {
        return Ok(None);
    };

    let namespace = if GroupKind::new(
        crate::manifest::types::api_group(import_api_version),
        import_kind,
    ) == kinds::CUSTOM_RESOURCE_DEFINITION
    {
        None
    } else {
        annotation(keys::IMPORT_NAMESPACE)
            .or_else(|| {
                manifest
                    .pointer("/metadata/namespace")
                    .and_then(Value::as_str)
            })
            .map(String::from)
    };

    // Parse comma-separated Secret keys. An empty list checks only that the
    // Secret exists.
    let expected_keys = annotations
        .get(keys::IMPORT_SECRET_KEYS)
        .and_then(Value::as_str)
        .map(|s| {
            s.split(',')
                .map(str::trim)
                .filter(|k| !k.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    let served_versions = match annotation(keys::CRD_KIND) {
        None => Vec::new(),
        Some(crd_kind) => {
            let served: Vec<String> = annotation(keys::CRD_SERVED_VERSIONS)
                .unwrap_or("")
                .split(',')
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(String::from)
                .collect();
            if served.is_empty() {
                return Err(MalformedMarker {
                    marker: format!(
                        "PackageInstance {}/{}",
                        manifest
                            .pointer("/metadata/namespace")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                        manifest
                            .pointer("/metadata/name")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                    ),
                    reason: format!(
                        "CRD ref marker for {crd_kind} ({import_name}) lists no versions in {}. Builds from the Kix library before 2026-10-02 lack this field; rebuild and deploy (a rollback or the operator cannot apply this build).",
                        keys::CRD_SERVED_VERSIONS
                    ),
                });
            }
            served
        }
    };

    Ok(Some(ImportTarget {
        kind: import_kind.to_string(),
        api_version: import_api_version.to_string(),
        name: import_name.to_string(),
        namespace,
        expected_keys,
        served_versions,
    }))
}

/// Poll the cluster for the described [`ImportTarget`] until it exists and
/// passes the same readiness checks as managed resources, or until the timeout
/// elapses.
///
/// Unlike [`super::wait_for_ready`], this does not require the target kind to
/// be in the discovery cache at the start of the deploy. It asks discovery
/// for the kind on each poll until discovery serves it, so it can wait for a
/// kind whose CRD an operator installs during the deploy.
pub(crate) async fn wait_for_import_target(
    client: &Client,
    target: &ImportTarget,
    timeout: Duration,
    cancel: &CancelToken,
    on_status: impl Fn(&str),
) -> Result<ReadinessResult, ReadinessError> {
    let mut api = None;
    let start = Instant::now();
    loop {
        if cancel.is_cancelled() {
            return Ok(ReadinessResult::Cancelled);
        }
        if api.is_none() {
            api = import_api(client, target).await?;
        }
        let status_msg: String = match &api {
            None => format!(
                "the API server does not serve {} kind {} yet",
                target.api_version, target.kind
            ),
            Some(api) => match api.get_opt(&target.name).await {
                Ok(Some(obj)) => {
                    if target.group_kind() == kinds::CUSTOM_RESOURCE_DEFINITION {
                        if check_crd_ready(&obj.data) {
                            // Fail immediately if the live CRD does not serve a
                            // required API version.
                            let unserved =
                                unserved_crd_versions(&obj.data, &target.served_versions);
                            if !unserved.is_empty() {
                                let fix = "Correct version or servedVersions on the scope.mkCRDRef or mkImport crds entry that declares it.";
                                return Ok(ReadinessResult::ImportMismatch {
                                    missing_keys: Vec::new(),
                                    message: format!(
                                        "CustomResourceDefinition {} does not serve {} (serves {}). {fix}",
                                        target.name,
                                        unserved.join(", "),
                                        served_crd_versions(&obj.data).join(", ")
                                    ),
                                });
                            }
                            if crd_kind_served(client, &obj.data).await {
                                return Ok(ReadinessResult::Ready);
                            }
                            CRD_AWAITING_DISCOVERY.into()
                        } else {
                            "CRD present, waiting for Established=True".into()
                        }
                    } else if target.group_kind() == kinds::SECRET
                        && !target.expected_keys.is_empty()
                    {
                        // Once the Secret exists, any missing declared key in `data`
                        // is treated as an immediate mismatch rather than a transient
                        // state because external secret controllers populate keys
                        // atomically when creating the Secret.
                        let missing = check_secret_keys(&obj.data, &target.expected_keys);
                        if missing.is_empty() {
                            return Ok(ReadinessResult::Ready);
                        } else {
                            let ns = target.namespace.as_deref().unwrap_or("?");
                            let message = format!(
                                "Secret {}/{} is missing expected key(s): [{}]",
                                ns,
                                target.name,
                                missing.join(", ")
                            );
                            return Ok(ReadinessResult::ImportMismatch {
                                missing_keys: missing,
                                message,
                            });
                        }
                    } else if target.group_kind() == kinds::SERVICE {
                        // Wait for at least one ready endpoint because a controller
                        // may create the Service before its backing pods are ready.
                        // Headless Services and manual Endpoints populate the
                        // Endpoints object the same way; ExternalName Services have
                        // no endpoints and are not supported as Service imports.
                        let ns = target.namespace.as_deref().unwrap_or("default");
                        match check_service_has_ready_endpoints(client, ns, &target.name).await {
                            Ok(true) => return Ok(ReadinessResult::Ready),
                            Ok(false) => "Service exists, waiting for ready endpoints".into(),
                            Err(e) => {
                                tracing::debug!(
                                    service = %target.name,
                                    error = %e,
                                    "transient error checking endpoints, retrying"
                                );
                                format!("Service exists, endpoints check error: {e}")
                            }
                        }
                    } else if is_immediate_kind(target.group_kind())
                        || check_readiness(&obj, target.group_kind())
                    {
                        return Ok(ReadinessResult::Ready);
                    } else {
                        readiness_message(&obj, target.group_kind())
                    }
                }
                Ok(None) => "not found yet".into(),
                Err(e) if classify(&e) == FailureClass::NotFound => "not found yet".into(),
                Err(e) => {
                    // Keep polling through transient API or network failures until
                    // the timeout elapses.
                    tracing::debug!(
                        target.kind = %target.kind,
                        target.name = %target.name,
                        error = %e,
                        "transient error polling import target, retrying"
                    );
                    format!("transient error: {e}")
                }
            },
        };

        on_status(&status_msg);

        let elapsed = start.elapsed();
        if elapsed >= timeout {
            let message = format!(
                "import target {}/{} (apiVersion {}) not found on the cluster before the timeout expired.",
                target.kind, target.name, target.api_version
            );
            return Ok(ReadinessResult::TimedOut { elapsed, message });
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

/// Check whether a Service has at least one ready endpoint by querying the
/// `v1/Endpoints` resource. Returns `Ok(true)` if at least one address appears
/// in a ready subset, `Ok(false)` if none are ready yet, or `Err` on API errors.
///
/// Queries `v1/Endpoints` rather than `EndpointSlice` because the Endpoints
/// object shares the Service's name and can be fetched in a single `GET`
/// without listing by label selector.
async fn check_service_has_ready_endpoints(
    client: &Client,
    namespace: &str,
    service_name: &str,
) -> Result<bool, kube::Error> {
    let ar = ApiResource {
        group: "".into(),
        version: "v1".into(),
        api_version: "v1".into(),
        kind: "Endpoints".into(),
        plural: "endpoints".into(),
    };
    let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), namespace, &ar);
    match api.get_opt(service_name).await? {
        Some(ep) => {
            let has_ready = ep
                .data
                .pointer("/subsets")
                .and_then(Value::as_array)
                .map(|subsets| {
                    subsets.iter().any(|s| {
                        s.pointer("/addresses")
                            .and_then(Value::as_array)
                            .is_some_and(|addrs| !addrs.is_empty())
                    })
                })
                .unwrap_or(false);
            Ok(has_ready)
        }
        None => Ok(false),
    }
}

/// Return the subset of `expected` keys not present in the live Secret's `data`
/// field. Checks key presence only; values may be empty strings.
pub(super) fn check_secret_keys(secret: &Value, expected: &[String]) -> Vec<String> {
    let Some(data) = secret.pointer("/data").and_then(Value::as_object) else {
        return expected.to_vec();
    };
    expected
        .iter()
        .filter(|k| !data.contains_key(k.as_str()))
        .cloned()
        .collect()
}

/// Split an `apiVersion` string into `(group, version)`, such as `"v1"` into
/// `("", "v1")` and `"apps/v1"` into `("apps", "v1")`.
pub(super) fn split_api_version(api_version: &str) -> (&str, &str) {
    match api_version.split_once('/') {
        Some((g, v)) => (g, v),
        None => ("", api_version),
    }
}

/// Return the API for `target`'s kind, or `None` while API discovery does
/// not serve that kind, such as before an operator has installed its CRD.
/// Discovery also gives the kind's scope, because a namespaced marker may
/// import a cluster-scoped resource such as a StorageClass or ClusterIssuer.
async fn import_api(
    client: &Client,
    target: &ImportTarget,
) -> Result<Option<Api<DynamicObject>>, ReadinessError> {
    let (group, version) = split_api_version(&target.api_version);
    let gvk = kube::core::GroupVersionKind::gvk(group, version, &target.kind);
    let (ar, caps) = match kube::discovery::oneshot::pinned_kind(client, &gvk).await {
        Ok(found) => found,
        Err(e) => {
            tracing::debug!(
                api_version = %target.api_version,
                kind = %target.kind,
                error = %e,
                "imported kind not served yet, retrying"
            );
            return Ok(None);
        }
    };
    let api = match caps.scope {
        Scope::Namespaced => {
            // Reject namespaced targets without a namespace rather than
            // defaulting to "default".
            let ns = target.namespace.as_deref().ok_or_else(|| {
                ReadinessError::MalformedImportTarget(format!(
                    "namespaced import target {}/{} has no namespace (marker malformed); build the cluster again and deploy.",
                    target.kind, target.name
                ))
            })?;
            Api::namespaced_with(client.clone(), ns, &ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), &ar),
    };
    Ok(Some(api))
}

/// An external resource that a manifest expects another controller to create.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Expectation {
    pub api_version: String,
    pub kind: String,
    pub name: String,
}

impl Expectation {
    pub fn display(&self) -> String {
        format!("{}/{}", self.kind, self.name)
    }
}

/// Parse the `kix.run/expects` annotation of a manifest, ignoring malformed
/// entries.
pub(crate) fn expectations(manifest: &Value) -> Vec<Expectation> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::EXPECTS))
        .and_then(Value::as_str)
        .map(|s| {
            s.split(',')
                .filter_map(|entry| {
                    let mut parts = entry.trim().splitn(3, '|');
                    let api_version = parts.next()?.to_string();
                    let kind = parts.next()?.to_string();
                    let name = parts.next()?.to_string();
                    if api_version.is_empty() || kind.is_empty() || name.is_empty() {
                        return None;
                    }
                    Some(Expectation {
                        api_version,
                        kind,
                        name,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Wait until every object the manifest expects exists, in the manifest's
/// namespace (or at cluster scope for a cluster-scoped kind). Returns the
/// first expectation still unmet at the timeout, with the reason.
pub(crate) async fn wait_for_expectations(
    client: &Client,
    manifest: &Value,
    timeout: Duration,
    cancel: &CancelToken,
) -> Result<(), (Expectation, String)> {
    let expected = expectations(manifest);
    if expected.is_empty() {
        return Ok(());
    }
    let namespace = manifest
        .pointer("/metadata/namespace")
        .and_then(Value::as_str)
        .map(str::to_string);
    let start = Instant::now();
    for e in expected {
        let (group, version) = split_api_version(&e.api_version);
        let gvk = kube::core::GroupVersionKind::gvk(group, version, &e.kind);
        let (ar, caps) = kube::discovery::oneshot::pinned_kind(client, &gvk)
            .await
            .map_err(|err| (e.clone(), format!("the kind is not served: {err}")))?;
        let api: Api<DynamicObject> = match caps.scope {
            Scope::Cluster => Api::all_with(client.clone(), &ar),
            Scope::Namespaced => {
                let ns = namespace.as_deref().ok_or_else(|| {
                    (
                        e.clone(),
                        "the referring manifest has no namespace".to_string(),
                    )
                })?;
                Api::namespaced_with(client.clone(), ns, &ar)
            }
        };
        loop {
            if cancel.is_cancelled() {
                return Err((e, "cancelled".to_string()));
            }
            match api.get_opt(&e.name).await {
                Ok(Some(_)) => break,
                Ok(None) => {}
                Err(err) => return Err((e, format!("lookup failed: {err}"))),
            }
            if start.elapsed() >= timeout {
                return Err((e, format!("not found after {}s", timeout.as_secs())));
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
    Ok(())
}
