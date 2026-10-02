//! Readiness polling for K8s resources.
//!
//! Per-kind readiness checks with `observedGeneration` guards for workloads.
//! Used by `kix deploy` to wait for resources to become ready after apply.
//!
//! Also handles "import marker" PackageInstance resources whose readiness is
//! defined as "the described external resource exists on the cluster AND passes
//! the same per-kind readiness checks as managed resources". Used to gate waves
//! on CRDs installed by operators outside Kix (e.g. stackgres `INSTALL_CRDS=true`)
//! and on platform-provided workloads (e.g. coredns Deployment).
//! See [`ImportTarget`] and [`wait_for_import_target`].

use std::time::{Duration, Instant};

use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

use super::cancel::CancelToken;
use super::errors::{FailureClass, classify};
use super::fetch;
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

/// After a CRD reaches `Established=True`, the apiserver's discovery endpoint
/// (and replicas behind an HA load balancer) may still lag by a few hundred
/// ms before the new group/version/kind appears. Dependents that race in
/// during that window would hit "no matches for kind" on apply. We poll
/// discovery for up to this budget after Established.
const CRD_DISCOVERY_PROBE_BUDGET: Duration = Duration::from_secs(5);
const CRD_DISCOVERY_PROBE_INTERVAL: Duration = Duration::from_millis(300);

/// Run a bounded discovery probe until the CRD's group/version/kind appears.
/// Called after a freshly-applied CRD reports `Established=True`. Returns
/// `true` if the kind was observed in discovery, `false` if the budget
/// elapsed without it showing up (deploy still proceeds; the retry-on-miss
/// in the scheduler will absorb residual skew).
async fn probe_crd_discovery(client: &Client, crd: &Value) -> bool {
    let Some(group) = crd.pointer("/spec/group").and_then(Value::as_str) else {
        return true;
    };
    let Some(kind) = crd.pointer("/spec/names/kind").and_then(Value::as_str) else {
        return true;
    };
    let deadline = Instant::now() + CRD_DISCOVERY_PROBE_BUDGET;
    loop {
        if let Ok(resources) = fetch::discover_resources(client).await
            && resources
                .iter()
                .any(|(ar, _)| ar.group == group && ar.kind == kind)
        {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(CRD_DISCOVERY_PROBE_INTERVAL).await;
    }
}

/// A resource described by an import marker. The CLI polls the cluster for
/// this resource and blocks the wave until it's present and ready, using the
/// same per-kind readiness checks as managed resources (e.g. for Deployments,
/// waits for `readyReplicas == spec.replicas`). CRDs additionally require
/// `Established=True`; Secrets with `expected_keys` verify every key in `data`.
///
/// The marker lives in its own namespace and the described resource is
/// expected in the same namespace (for namespaced kinds). Cross-namespace
/// imports are not supported; use a dedicated adapter instance in the owning
/// namespace and DI the resource handle instead.
#[derive(Debug, Clone)]
pub struct ImportTarget {
    /// K8s kind of the expected resource (e.g. "CustomResourceDefinition").
    pub kind: String,
    /// K8s apiVersion (e.g. "apiextensions.k8s.io/v1" or "v1").
    pub api_version: String,
    /// Name of the expected resource.
    pub name: String,
    /// Namespace of the expected resource. `None` for cluster-scoped kinds
    /// (currently just `CustomResourceDefinition`). For namespaced kinds this
    /// is sourced from the marker's own `metadata.namespace`.
    pub namespace: Option<String>,
    /// For `Secret` imports, the set of keys the consumer expects to find in
    /// `data`. Parsed from the `kix.run/import-secret-keys` annotation (comma
    /// separated). Empty = identity-only check (resource existence).
    pub expected_keys: Vec<String>,
    /// For `CustomResourceDefinition` imports from a CRD ref marker, the API
    /// versions the declaration says the CRD serves: `kix.run/crd-served-versions`,
    /// else `kix.run/crd-version`. Each must be in the live CRD's
    /// `spec.versions` with `served: true`. Empty = no version check.
    pub served_versions: Vec<String>,
}

/// Extract an [`ImportTarget`] from a manifest if it is a PackageInstance
/// import marker (`kix.run/mode: import`). Returns `None` for non-markers or
/// for markers that don't have enough info to verify (no kind hint, etc.).
///
/// The target's namespace is sourced from the marker's own `metadata.namespace`
/// for namespaced kinds. Cluster-scoped kinds (`CustomResourceDefinition`) set
/// it to `None`. There is no `kix.run/import-namespace` annotation: an import
/// always describes a resource in the marker's own namespace.
pub fn import_target_from_manifest(manifest: &Value) -> Option<ImportTarget> {
    if !crate::manifest::lifecycle::is_marker(manifest) {
        return None;
    }
    let annotations = manifest.pointer("/metadata/annotations")?;

    let import_kind = annotations
        .get(keys::IMPORT_KIND)
        .and_then(Value::as_str)?
        .to_string();
    let import_api_version = annotations
        .get(keys::IMPORT_API_VERSION)
        .and_then(Value::as_str)?
        .to_string();
    let import_name = annotations
        .get(keys::IMPORT_NAME)
        .and_then(Value::as_str)?
        .to_string();

    // Cluster-scoped imports (currently just CRDs) have no target namespace.
    // All other imports inherit the marker's own namespace.
    let namespace = if import_kind == "CustomResourceDefinition" {
        None
    } else {
        manifest
            .pointer("/metadata/namespace")
            .and_then(Value::as_str)
            .map(String::from)
    };

    // Parse expected Secret keys (comma-separated, no spaces). Empty list is
    // valid; it means "only check that the Secret exists".
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

    let served_versions = if import_kind == "CustomResourceDefinition" {
        let listed = annotations
            .get(keys::CRD_SERVED_VERSIONS)
            .or_else(|| annotations.get(keys::CRD_VERSION))
            .and_then(Value::as_str)
            .unwrap_or("");
        listed
            .split(',')
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(String::from)
            .collect()
    } else {
        Vec::new()
    };

    Some(ImportTarget {
        kind: import_kind,
        api_version: import_api_version,
        name: import_name,
        namespace,
        expected_keys,
        served_versions,
    })
}

/// Poll the cluster for the described [`ImportTarget`] until it exists and
/// passes the same readiness checks as managed resources (e.g. Deployment
/// replica counts, DaemonSet scheduling, CRD `Established=True`, Secret key
/// verification), or the timeout elapses.
///
/// Unlike [`wait_for_ready`] this does not need the target kind to be in the
/// CLI's discovery cache. For `CustomResourceDefinition` targets we construct
/// the `ApiResource` directly from the well-known `apiextensions.k8s.io/v1`
/// group, so we can wait for a CRD that doesn't exist yet at the start of the
/// deploy, as happens with operator-installed CRDs.
///
/// Scope is determined by the target kind: `CustomResourceDefinition` is
/// cluster-scoped, everything else is namespaced and queried in
/// `target.namespace` (sourced from the marker's own `metadata.namespace`).
pub async fn wait_for_import_target(
    client: &Client,
    target: &ImportTarget,
    timeout: Duration,
    cancel: &CancelToken,
    on_status: impl Fn(&str),
) -> Result<ReadinessResult, ReadinessError> {
    // Build an ApiResource for the target. CRDs are handled specially so we
    // do not depend on discovery because the target may not be registered yet.
    let (ar, scope) = if target.kind == "CustomResourceDefinition" {
        (
            ApiResource {
                group: "apiextensions.k8s.io".into(),
                version: "v1".into(),
                api_version: "apiextensions.k8s.io/v1".into(),
                kind: "CustomResourceDefinition".into(),
                plural: "customresourcedefinitions".into(),
            },
            Scope::Cluster,
        )
    } else {
        // Ask the apiserver what the kind is and where it lives. The marker
        // is namespaced; what it imports need not be. A StorageClass or a
        // ClusterIssuer is cluster-scoped, and looking for one inside the
        // marker's namespace found nothing every time. A kind discovery
        // cannot see yet (an operator's, not served) falls back to the
        // annotation and the marker's namespace, as before.
        let (group, version) = split_api_version(&target.api_version);
        let gvk = kube::core::GroupVersionKind::gvk(group, version, &target.kind);
        match kube::discovery::oneshot::pinned_kind(client, &gvk).await {
            Ok((ar, caps)) => (ar, caps.scope),
            Err(_) => (
                ApiResource {
                    group: group.to_string(),
                    version: version.to_string(),
                    api_version: target.api_version.clone(),
                    kind: target.kind.clone(),
                    plural: pluralize_kind(&target.kind),
                },
                Scope::Namespaced,
            ),
        }
    };

    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            // Namespaced imports must carry a namespace from the marker.
            // mkImportMarker enforces this at build time. If
            // it's ever missing, the target is malformed and we bail rather
            // rather than querying "default".
            let ns = target.namespace.as_deref().ok_or_else(|| {
                ReadinessError::MalformedImportTarget(format!(
                    "namespaced import target {}/{} has no namespace (marker malformed)",
                    target.kind, target.name
                ))
            })?;
            Api::namespaced_with(client.clone(), ns, &ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), &ar),
    };

    let start = Instant::now();
    loop {
        if cancel.is_cancelled() {
            return Ok(ReadinessResult::Cancelled);
        }
        let status_msg: String = match api.get_opt(&target.name).await {
            Ok(Some(obj)) => {
                // For CRDs, also wait for Established=True so the kind is
                // actually serving requests before we advance the wave.
                if target.kind == "CustomResourceDefinition" {
                    if check_crd_ready(&obj.data) {
                        // A declared version the CRD does not serve fails
                        // every apply of the kind at that version, and
                        // waiting does not change what the CRD serves.
                        let unserved = unserved_crd_versions(&obj.data, &target.served_versions);
                        if !unserved.is_empty() {
                            return Ok(ReadinessResult::ImportMismatch {
                                missing_keys: Vec::new(),
                                message: format!(
                                    "CustomResourceDefinition {} does not serve {} (serves {}). Correct version or servedVersions on the scope.mkCRDRef or mkImport crds entry that declares it.",
                                    target.name,
                                    unserved.join(", "),
                                    served_crd_versions(&obj.data).join(", ")
                                ),
                            });
                        }
                        let _ = probe_crd_discovery(client, &obj.data).await;
                        return Ok(ReadinessResult::Ready);
                    }
                    "CRD present, waiting for Established=True".into()
                } else if target.kind == "Secret" && !target.expected_keys.is_empty() {
                    // The Secret exists. Verify every declared key is present in
                    // `data`. Missing keys are a hard failure, not a transient
                    // state: if kix deploy got here the owning reconciler
                    // (ESO/Vault/etc.) already considers the secret populated,
                    // and retrying won't help. Emit a mismatch result so the
                    // observer can render the exact missing keys.
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
                } else if target.kind == "Service" {
                    // Service imports must wait for at least one ready
                    // endpoint rather than object existence. A controller may
                    // create the Service before its backing pods are ready.
                    //
                    // Edge cases to revisit:
                    //   - ExternalName Services have no selector / no
                    //     endpoints; they would time out here. If we ever
                    //     import an ExternalName, add a type check.
                    //   - Headless Services (clusterIP: None) populate
                    //     Endpoints the same way, so this works.
                    //   - Services with no selector (manual Endpoints)
                    //     work if someone creates the Endpoints object.
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
                } else if is_immediate_kind(&target.kind) || check_readiness(&obj, &target.kind) {
                    return Ok(ReadinessResult::Ready);
                } else {
                    readiness_message(&obj, &target.kind)
                }
            }
            Ok(None) => "not found yet".into(),
            Err(e) if classify(&e) == FailureClass::NotFound => "not found yet".into(),
            Err(e) => {
                // Keep polling through network and other transient failures until
                // timeout rather than failing immediately.
                tracing::debug!(
                    target.kind = %target.kind,
                    target.name = %target.name,
                    error = %e,
                    "transient error polling import target, retrying"
                );
                format!("transient error: {e}")
            }
        };

        on_status(&status_msg);

        let elapsed = start.elapsed();
        if elapsed >= timeout {
            return Ok(ReadinessResult::TimedOut {
                elapsed,
                message: format!(
                    "import target {}/{} (apiVersion {}) not found on cluster",
                    target.kind, target.name, target.api_version
                ),
            });
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

/// Check whether a Service has at least one ready endpoint by querying the
/// Endpoints resource (auto-managed by kube-controller-manager for Services
/// with a selector). Returns `Ok(true)` if at least one address appears in
/// a `ready` subset, `Ok(false)` if no ready addresses yet, or `Err` on
/// transient API errors.
///
/// We use the legacy Endpoints API (v1) rather than EndpointSlice because:
///   1. It's always available (EndpointSlice requires discovery.k8s.io/v1).
///   2. A single GET returns all addresses without a label-selector list.
///   3. The Endpoints object shares the Service's name, so the lookup is trivial.
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
            // subsets[].addresses[] contains ready endpoints.
            // subsets[].notReadyAddresses[] contains not-yet-ready endpoints.
            // At least one address must be ready.
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

/// Return the subset of `expected` not present in the live Secret's `data`
/// field. Only key presence is checked; values may be empty strings.
fn check_secret_keys(secret: &Value, expected: &[String]) -> Vec<String> {
    let Some(data) = secret.pointer("/data").and_then(Value::as_object) else {
        // No `data` at all → every expected key is missing.
        return expected.to_vec();
    };
    expected
        .iter()
        .filter(|k| !data.contains_key(k.as_str()))
        .cloned()
        .collect()
}

/// Split an apiVersion string into (group, version). "v1" → ("", "v1"),
/// "apps/v1" → ("apps", "v1").
fn split_api_version(api_version: &str) -> (&str, &str) {
    match api_version.split_once('/') {
        Some((g, v)) => (g, v),
        None => ("", api_version),
    }
}

/// Best-effort plural for a kind: lowercase + "s", with the usual "y → ies"
/// rule. Only used for the generic non-CRD import path; CRDs bypass this.
/// Consumers with irregular plurals should rely on discovery instead.
fn pluralize_kind(kind: &str) -> String {
    let lower = kind.to_ascii_lowercase();
    if lower.ends_with('y') && !lower.ends_with("ay") && !lower.ends_with("ey") {
        format!("{}ies", &lower[..lower.len() - 1])
    } else if lower.ends_with('s') {
        format!("{lower}es")
    } else {
        format!("{lower}s")
    }
}

/// Default timeout for readiness polling.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(180);

/// Default interval between readiness polls.
const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Errors from readiness polling.
#[derive(Error, Debug)]
pub enum ReadinessError {
    #[error("failed to fetch resource for readiness check: {0}")]
    FetchError(#[source] kube::Error),
    #[error("malformed import target: {0}")]
    MalformedImportTarget(String),
}

// ---------------------------------------------------------------------------
// Expected objects (`kix.run/expects`)
// ---------------------------------------------------------------------------

/// One object a manifest expects something else to have created.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Expectation {
    pub api_version: String,
    pub kind: String,
    pub name: String,
}

impl Expectation {
    pub fn display(&self) -> String {
        format!("{}/{}", self.kind, self.name)
    }
}

/// The `kix.run/expects` entries of a manifest, malformed ones dropped.
pub fn expectations(manifest: &Value) -> Vec<Expectation> {
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
pub async fn wait_for_expectations(
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

/// Number of container restarts required before CrashLoopBackOff is treated
/// as terminal. Allows a couple of flapping-startup cycles (InitContainer
/// ordering, DB migrations waiting for a sidecar, etc.) before we give up.
const CRASHLOOP_RESTART_THRESHOLD: i64 = 3;

/// Classification of a terminal workload failure. Bubbles up from the per-pod
/// and per-workload classifiers in [`classify_terminal_failure`] so callers
/// can render the machine-readable reason distinctly from the free-form message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalReason {
    /// Container image pull failed (ImagePullBackOff, ErrImagePull, InvalidImageName).
    ImagePull,
    /// Container config invalid (CreateContainerConfigError, CreateContainerError).
    ContainerConfig,
    /// CrashLoopBackOff past the restart threshold.
    CrashLoop,
    /// Deployment rollout exceeded spec.progressDeadlineSeconds.
    ProgressDeadline,
    /// Job exceeded spec.backoffLimit.
    JobBackoffExceeded,
}

impl TerminalReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            TerminalReason::ImagePull => "ImagePullBackOff",
            TerminalReason::ContainerConfig => "CreateContainerConfigError",
            TerminalReason::CrashLoop => "CrashLoopBackOff",
            TerminalReason::ProgressDeadline => "ProgressDeadlineExceeded",
            TerminalReason::JobBackoffExceeded => "JobBackoffExceeded",
        }
    }
}

/// Result of a readiness check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadinessResult {
    /// Resource is ready.
    Ready,
    /// An `OnDelete` DaemonSet is ready, but `stale` of its pods still run
    /// the previous pod template. The controller replaces a pod only when it
    /// is deleted, so the deploy reports this instead of waiting.
    ReadyPendingRestart { stale: i64, message: String },
    /// Timed out waiting for readiness.
    TimedOut { elapsed: Duration, message: String },
    /// The poll loop observed a cancellation request and bailed before
    /// reaching a definitive state. Caller should propagate cancellation
    /// rather than treating this as a failure.
    Cancelled,
    /// Resource entered a terminal failure state. `output` holds the last
    /// lines a failed container wrote (see [`termination_output`]); empty
    /// when nothing was recorded.
    Failed {
        message: String,
        output: Vec<String>,
    },
    /// An import target exists on the cluster but does not match the shape
    /// declared by its marker. Currently only produced by `Secret` imports
    /// when one or more `expected_keys` are missing from `data`.
    ImportMismatch {
        missing_keys: Vec<String>,
        message: String,
    },
}

/// Scan a single pod's containerStatuses for a terminal failure reason.
/// Returns the first terminal signal found and a human-readable message.
///
/// Kept pure and test-driven so the noisy-event classification logic is
/// independent of the cluster poll loop.
pub fn classify_pod_terminal(pod: &Value) -> Option<(TerminalReason, String)> {
    let pod_name = pod
        .pointer("/metadata/name")
        .and_then(Value::as_str)
        .unwrap_or("?");

    // Check both init and regular container statuses. InitContainer failures
    // are common for things like "wait-for-db" containers with a bad image.
    let slots = ["/status/initContainerStatuses", "/status/containerStatuses"];
    for slot in slots {
        let Some(statuses) = pod.pointer(slot).and_then(Value::as_array) else {
            continue;
        };
        for cs in statuses {
            let container = cs.get("name").and_then(Value::as_str).unwrap_or("?");
            let waiting_reason = cs
                .pointer("/state/waiting/reason")
                .and_then(Value::as_str)
                .unwrap_or("");
            let waiting_msg = cs
                .pointer("/state/waiting/message")
                .and_then(Value::as_str)
                .unwrap_or("");

            match waiting_reason {
                "ImagePullBackOff" | "ErrImagePull" | "InvalidImageName" | "ImageInspectError" => {
                    return Some((
                        TerminalReason::ImagePull,
                        format!("pod {pod_name}/{container}: {waiting_reason}: {waiting_msg}"),
                    ));
                }
                "CreateContainerConfigError" | "CreateContainerError" | "RunContainerError" => {
                    return Some((
                        TerminalReason::ContainerConfig,
                        format!("pod {pod_name}/{container}: {waiting_reason}: {waiting_msg}"),
                    ));
                }
                "CrashLoopBackOff" => {
                    let restarts = cs.get("restartCount").and_then(Value::as_i64).unwrap_or(0);
                    if restarts >= CRASHLOOP_RESTART_THRESHOLD {
                        // The last-termination reason is usually the real
                        // story ("Error", "OOMKilled", "StartError").
                        let last_reason = cs
                            .pointer("/lastState/terminated/reason")
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        let last_exit = cs
                            .pointer("/lastState/terminated/exitCode")
                            .and_then(Value::as_i64);
                        let detail = match (last_reason, last_exit) {
                            ("", None) => String::new(),
                            ("", Some(code)) => format!(" (last exit={code})"),
                            (r, None) => format!(" (last={r})"),
                            (r, Some(code)) => format!(" (last={r} exit={code})"),
                        };
                        return Some((
                            TerminalReason::CrashLoop,
                            format!(
                                "pod {pod_name}/{container}: CrashLoopBackOff after {restarts} restarts{detail}"
                            ),
                        ));
                    }
                }
                _ => {}
            }

            // Also detect containers currently in a terminated state with a
            // non-zero exit code and enough restarts. This catches Job pods
            // between restart attempts; the container shows terminated/Error
            // rather than waiting/CrashLoopBackOff.
            let terminated_exit = cs
                .pointer("/state/terminated/exitCode")
                .and_then(Value::as_i64);
            if let Some(exit_code) = terminated_exit
                && exit_code != 0
            {
                let restarts = cs.get("restartCount").and_then(Value::as_i64).unwrap_or(0);
                if restarts >= CRASHLOOP_RESTART_THRESHOLD {
                    let term_reason = cs
                        .pointer("/state/terminated/reason")
                        .and_then(Value::as_str)
                        .unwrap_or("Error");
                    return Some((
                        TerminalReason::CrashLoop,
                        format!(
                            "pod {pod_name}/{container}: terminated with {term_reason} (exit={exit_code}) after {restarts} restarts"
                        ),
                    ));
                }
            }
        }
    }
    None
}

/// Classify workload-level terminal failures that don't require pod inspection.
/// Currently covers Deployment progress deadline and Job backoff limit.
pub fn classify_workload_terminal(obj: &Value, kind: &str) -> Option<(TerminalReason, String)> {
    match kind {
        "Deployment" => {
            // conditions[?(@.type=='Progressing' && @.status=='False' && @.reason=='ProgressDeadlineExceeded')]
            let conditions = obj
                .pointer("/status/conditions")
                .and_then(Value::as_array)?;
            for c in conditions {
                let ctype = c.get("type").and_then(Value::as_str).unwrap_or("");
                let status = c.get("status").and_then(Value::as_str).unwrap_or("");
                let reason = c.get("reason").and_then(Value::as_str).unwrap_or("");
                if ctype == "Progressing"
                    && status == "False"
                    && reason == "ProgressDeadlineExceeded"
                {
                    let msg = c
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("progress deadline exceeded");
                    return Some((TerminalReason::ProgressDeadline, msg.to_string()));
                }
            }
            None
        }
        "Job" => {
            let failed = obj
                .pointer("/status/failed")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let backoff_limit = obj
                .pointer("/spec/backoffLimit")
                .and_then(Value::as_i64)
                .unwrap_or(6);
            if failed > backoff_limit {
                return Some((
                    TerminalReason::JobBackoffExceeded,
                    format!("Job failed {failed} times (backoffLimit={backoff_limit})"),
                ));
            }
            // Also honor the explicit Failed condition if the controller set one.
            if let Some(conditions) = obj.pointer("/status/conditions").and_then(Value::as_array) {
                for c in conditions {
                    let ctype = c.get("type").and_then(Value::as_str).unwrap_or("");
                    let status = c.get("status").and_then(Value::as_str).unwrap_or("");
                    if ctype == "Failed" && status == "True" {
                        let reason = c.get("reason").and_then(Value::as_str).unwrap_or("Failed");
                        let msg = c.get("message").and_then(Value::as_str).unwrap_or("");
                        return Some((
                            TerminalReason::JobBackoffExceeded,
                            format!("Job condition Failed: {reason}: {msg}"),
                        ));
                    }
                }
            }
            None
        }
        _ => None,
    }
}

/// Build a labelSelector string from a workload's `spec.selector.matchLabels`.
/// Returns `None` if the workload has no selector (e.g. bare CRs).
fn workload_label_selector(obj: &Value) -> Option<String> {
    let labels = obj
        .pointer("/spec/selector/matchLabels")
        .and_then(Value::as_object)?;
    if labels.is_empty() {
        return None;
    }
    let mut parts: Vec<String> = labels
        .iter()
        .filter_map(|(k, v)| v.as_str().map(|s| format!("{k}={s}")))
        .collect();
    parts.sort();
    Some(parts.join(","))
}

/// The label that pins a pod to one revision of its controller, and the
/// controller field naming the revision that should be running now.
///
/// A workload's label selector matches every pod it has ever owned,
/// including the ones a rollout is in the middle of replacing. Judging the
/// workload by those was wrong four times on one kind run: a Deployment
/// that gained its CRDs failed on the pod crash-looping from before the
/// fix, and a StatefulSet on a new image failed on the old pod's
/// ImagePullBackOff while the controller was already deleting it. Narrowing
/// the list to the current revision means the verdict is about the rollout
/// that is happening, not the one it replaces. When the current revision
/// has no pods yet the list is empty, nothing is classified, and the poll
/// loop keeps waiting, which is the right answer.
///
/// Returns a label selector fragment to AND with the workload's own, or
/// `None` when the kind has no revision concept or the controller has not
/// published one yet. A DaemonSet is not covered: its revision lives in a
/// ControllerRevision the DaemonSet's own status does not name.
async fn current_revision_selector(
    client: &Client,
    obj: &Value,
    kind: &str,
    namespace: &str,
    selector: &str,
) -> Option<String> {
    match kind {
        // The StatefulSet controller publishes the revision it is rolling
        // towards, and stamps it on each pod it creates.
        "StatefulSet" => {
            let rev = obj
                .pointer("/status/updateRevision")
                .and_then(Value::as_str)?;
            Some(format!("controller-revision-hash={rev}"))
        }
        // A Deployment owns one ReplicaSet per revision and never names the
        // newest itself, so find it: the ReplicaSets this Deployment owns,
        // highest `deployment.kubernetes.io/revision` first. Its
        // `pod-template-hash` is what its pods carry.
        "Deployment" => {
            let uid = obj.pointer("/metadata/uid").and_then(Value::as_str)?;
            let rs_ar = ApiResource {
                group: "apps".into(),
                version: "v1".into(),
                api_version: "apps/v1".into(),
                kind: "ReplicaSet".into(),
                plural: "replicasets".into(),
            };
            let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), namespace, &rs_ar);
            let lp = kube::api::ListParams::default().labels(selector);
            let list = api.list(&lp).await.ok()?;
            let newest = list
                .items
                .iter()
                .filter(|rs| {
                    rs.data
                        .pointer("/metadata/ownerReferences")
                        .and_then(Value::as_array)
                        .is_some_and(|refs| {
                            refs.iter()
                                .any(|r| r.get("uid").and_then(Value::as_str) == Some(uid))
                        })
                })
                .max_by_key(|rs| {
                    let revision = rs
                        .data
                        .pointer("/metadata/annotations/deployment.kubernetes.io~1revision")
                        .and_then(Value::as_str)
                        .and_then(|r| r.parse::<i64>().ok())
                        .unwrap_or(0);
                    let created = rs
                        .data
                        .pointer("/metadata/creationTimestamp")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    (revision, created)
                })?;
            let hash = newest
                .data
                .pointer("/spec/selector/matchLabels/pod-template-hash")
                .and_then(Value::as_str)?;
            Some(format!("pod-template-hash={hash}"))
        }
        _ => None,
    }
}

/// List pods matching a workload's label selector. Returns an empty Vec on API
/// errors so the terminal classifier can keep running from
/// workload-level signals alone.
async fn list_pods_for_workload(
    client: &Client,
    namespace: &str,
    label_selector: &str,
) -> Vec<Value> {
    let pod_ar = ApiResource {
        group: "".into(),
        version: "v1".into(),
        api_version: "v1".into(),
        kind: "Pod".into(),
        plural: "pods".into(),
    };
    let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), namespace, &pod_ar);
    let lp = kube::api::ListParams::default().labels(label_selector);
    match api.list(&lp).await {
        Ok(list) => list.items.into_iter().map(|p| p.data).collect(),
        Err(e) => {
            tracing::debug!(
                namespace = namespace,
                selector = label_selector,
                error = %e,
                "failed to list pods for terminal classification; skipping pod-level checks"
            );
            Vec::new()
        }
    }
}

/// Kinds whose readiness is driven by pods and therefore benefit from
/// pod-level terminal classification.
fn has_pods(kind: &str) -> bool {
    matches!(
        kind,
        "Deployment" | "StatefulSet" | "DaemonSet" | "Job" | "ReplicaSet"
    )
}

/// Result of one terminal-and-progress scan against the live cluster.
/// Bundles the pods we already had to fetch for terminal classification so
/// the surrounding poll loop can reuse them when computing the progress
/// fingerprint, avoiding a second `list pods` round-trip per tick.
struct ScanResult {
    terminal: Option<(TerminalReason, String)>,
    pods: Vec<Value>,
}

/// Lines a failed container left in its termination message.
///
/// With `terminationMessagePolicy: FallbackToLogsOnError` the kubelet copies
/// the tail of a container's log (2048 bytes or 80 lines) into
/// `status.containerStatuses[].state.terminated.message` when the container
/// exits non-zero. That is how a probe's `FAIL` lines reach the deploy
/// without a log API call. Only the newest pod (by `status.startTime`) is
/// read: a Job with a backoff limit above zero has one pod per attempt and
/// the last attempt is the one that decided the verdict. Reads
/// `state.terminated` first, then `lastState.terminated`. Lines carry a
/// `<container>: ` prefix only when more than one container wrote
/// something. At most the last [`TERMINATION_OUTPUT_LINES`] lines are
/// kept; a truncated result starts with a line saying how many were
/// dropped.
pub fn termination_output(pods: &[Value]) -> Vec<String> {
    let newest = pods.iter().max_by_key(|p| {
        p.pointer("/status/startTime")
            .or_else(|| p.pointer("/metadata/creationTimestamp"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    });
    let mut per_container: Vec<(String, Vec<String>)> = Vec::new();
    if let Some(statuses) = newest.and_then(|pod| {
        pod.pointer("/status/containerStatuses")
            .and_then(Value::as_array)
    }) {
        for cs in statuses {
            let name = cs.get("name").and_then(Value::as_str).unwrap_or("");
            let message = cs
                .pointer("/state/terminated/message")
                .or_else(|| cs.pointer("/lastState/terminated/message"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let mut lines: Vec<String> = message.lines().map(str::to_string).collect();
            while lines.last().is_some_and(|l| l.trim().is_empty()) {
                lines.pop();
            }
            if !lines.is_empty() {
                per_container.push((name.to_string(), lines));
            }
        }
    }
    let prefix = per_container.len() > 1;
    let mut all: Vec<String> = per_container
        .into_iter()
        .flat_map(|(name, lines)| {
            lines
                .into_iter()
                .map(move |l| if prefix { format!("{name}: {l}") } else { l })
        })
        .collect();
    if all.len() > TERMINATION_OUTPUT_LINES {
        let dropped = all.len() - TERMINATION_OUTPUT_LINES;
        all = all.split_off(dropped);
        all.insert(0, format!("... {dropped} earlier lines, see kubectl logs"));
    }
    all
}

/// How many lines of a failed container's output the deploy shows.
pub const TERMINATION_OUTPUT_LINES: usize = 20;

/// Full terminal-failure scan: checks workload-level signals first, then
/// pod-level signals for pod-backed kinds. Returns on the first hit (in
/// `terminal`) but always returns the fetched pods so the caller can reuse
/// them for progress fingerprinting. On a Job-level hit the Job's pods are
/// listed once more so the failure can carry what the container wrote.
async fn scan_terminal(client: &Client, obj: &Value, kind: &str, namespace: &str) -> ScanResult {
    if let Some(hit) = classify_workload_terminal(obj, kind) {
        let pods = match (kind, workload_label_selector(obj)) {
            ("Job", Some(selector)) => list_pods_for_workload(client, namespace, &selector).await,
            _ => Vec::new(),
        };
        return ScanResult {
            terminal: Some(hit),
            pods,
        };
    }
    if !has_pods(kind) {
        return ScanResult {
            terminal: None,
            pods: Vec::new(),
        };
    }
    let Some(selector) = workload_label_selector(obj) else {
        return ScanResult {
            terminal: None,
            pods: Vec::new(),
        };
    };
    // Judge the rollout that is happening, not the one it replaces.
    let selector = match current_revision_selector(client, obj, kind, namespace, &selector).await {
        Some(revision) => format!("{selector},{revision}"),
        None => selector,
    };
    let pods = list_pods_for_workload(client, namespace, &selector).await;
    let terminal = pods.iter().find_map(classify_pod_terminal);
    ScanResult { terminal, pods }
}

/// Build a stable string fingerprint of a resource's *progress* state.
/// Whenever this changes between two polls we treat it as forward progress
/// and reset the idle timer; only if the fingerprint is unchanged for the
/// full idle budget do we declare a no-progress timeout.
///
/// Includes the readiness message (which already encodes the per-kind
/// counters), `observedGeneration`, and aggregated pod state: phase
/// counts, total restart count, and the set of distinct waiting reasons.
/// Excludes timestamps and other always-bumping fields so a reconcile
/// loop on the controller side doesn't register as forward progress on
/// its own.
fn progress_fingerprint(obj: &DynamicObject, kind: &str, pods: &[Value]) -> String {
    use std::collections::BTreeMap;

    let mut parts: Vec<String> = Vec::with_capacity(4);
    parts.push(readiness_message(obj, kind));

    if let Some(g) = obj
        .data
        .pointer("/status/observedGeneration")
        .and_then(Value::as_i64)
    {
        parts.push(format!("og={g}"));
    }

    if !pods.is_empty() {
        let mut phases: BTreeMap<&str, usize> = BTreeMap::new();
        let mut total_restarts: i64 = 0;
        let mut waiting_reasons: std::collections::BTreeSet<&str> =
            std::collections::BTreeSet::new();

        for p in pods {
            let phase = p
                .pointer("/status/phase")
                .and_then(Value::as_str)
                .unwrap_or("?");
            *phases.entry(phase).or_insert(0) += 1;

            for slot in ["/status/initContainerStatuses", "/status/containerStatuses"] {
                if let Some(arr) = p.pointer(slot).and_then(Value::as_array) {
                    for cs in arr {
                        total_restarts +=
                            cs.get("restartCount").and_then(Value::as_i64).unwrap_or(0);
                        if let Some(r) = cs.pointer("/state/waiting/reason").and_then(Value::as_str)
                        {
                            waiting_reasons.insert(r);
                        }
                        // Also fold the running/terminated transition into
                        // the fingerprint via the discriminant. Going from
                        // waiting → running is forward progress even if no
                        // counter on the workload moved yet.
                        if cs.pointer("/state/running").is_some() {
                            waiting_reasons.insert("__running__");
                        }
                        if cs.pointer("/state/terminated").is_some() {
                            waiting_reasons.insert("__terminated__");
                        }
                    }
                }
            }
        }

        parts.push(format!("phases={phases:?}"));
        parts.push(format!("rc={total_restarts}"));
        parts.push(format!("waiting={waiting_reasons:?}"));
    }

    parts.join("|")
}

/// Absolute upper bound on how long any single resource may take to become
/// Ready. Catches pathological "fingerprint flickers forever but never
/// reaches Ready" cases. Enforced regardless of the per-resource idle
/// budget; even an actively progressing rollout has to finish in this
/// time or we declare it stuck.
const HARD_CEILING: Duration = Duration::from_secs(5 * 60);

/// Wait for a resource to become ready, polling every 2 seconds.
///
/// Two-tier timeout model:
///
/// * **Idle progress timeout** (`timeout` argument): the maximum time we'll
///   wait without observing *any* progress in the resource's status. The
///   "progress fingerprint" combines the readiness message, observedGeneration,
///   and pod-level state (phases, restart counts, waiting reasons). Whenever
///   the fingerprint changes between polls, we reset this timer so a slow
///   but actively rolling Deployment does not trip it.
/// * **Hard ceiling** (`HARD_CEILING`, currently 5 minutes): an absolute
///   upper bound regardless of progress. Catches pathological resources
///   whose fingerprint flickers forever but never reaches Ready.
///
/// Before each poll iteration we also scan for terminal failure signals
/// (ImagePullBackOff, CrashLoopBackOff past threshold, ProgressDeadlineExceeded,
/// Job backoff exhausted) and return `Failed` immediately on a hit.
///
/// Returns `Ready` on success, `Failed` on a terminal signal, `TimedOut` on
/// either the idle or hard budget elapsing, or `Cancelled` if the cancel
/// token flips mid-wait.
#[allow(clippy::too_many_arguments)]
pub async fn wait_for_ready(
    client: &Client,
    ar: &ApiResource,
    scope: &Scope,
    rid: &ResourceId,
    timeout: Duration,
    cancel: &CancelToken,
    on_status: impl Fn(&str),
) -> Result<ReadinessResult, ReadinessError> {
    let (name, kind) = (rid.name.as_str(), rid.kind.as_str());
    // Immediate kinds: existence = ready
    if is_immediate_kind(kind) {
        return Ok(ReadinessResult::Ready);
    }

    let api: Api<DynamicObject> = fetch::api_for(client, ar, scope, rid);

    let idle_budget = timeout;
    let hard_ceiling = HARD_CEILING;

    let start = Instant::now();
    let mut last_progress_at = start;
    let mut last_fingerprint = String::new();

    loop {
        if cancel.is_cancelled() {
            return Ok(ReadinessResult::Cancelled);
        }
        let obj = match api.get(name).await {
            Ok(obj) => obj,
            // The TTL controller deletes only finished Jobs. If a Job applied
            // by this deploy disappears while readiness is polling it, treat
            // the deletion as successful completion.
            Err(e) if kind == "Job" && classify(&e) == FailureClass::NotFound => {
                on_status("Job finished and was removed by its ttlSecondsAfterFinished");
                return Ok(ReadinessResult::Ready);
            }
            Err(e) => return Err(ReadinessError::FetchError(e)),
        };

        // PVCs with WaitForFirstConsumer storage classes stay Pending until a pod
        // mounts them. Treat these as ready so downstream pods can be created,
        // which will then trigger the actual binding.
        if kind == "PersistentVolumeClaim" {
            let phase = obj
                .data
                .pointer("/status/phase")
                .and_then(Value::as_str)
                .unwrap_or("");
            if phase == "Pending"
                && let Some(sc_name) = obj
                    .data
                    .pointer("/spec/storageClassName")
                    .and_then(Value::as_str)
                && is_wait_for_first_consumer(client, sc_name).await
            {
                return Ok(ReadinessResult::Ready);
            }
        }

        // Check terminal failures before readiness so partial success does not
        // hide a Failed condition.
        let ns_for_pods = obj.metadata.namespace.as_deref().unwrap_or_default();
        let scan = scan_terminal(client, &obj.data, kind, ns_for_pods).await;
        if let Some((reason, detail)) = scan.terminal {
            return Ok(ReadinessResult::Failed {
                message: format!("{}: {detail}", reason.as_str()),
                output: termination_output(&scan.pods),
            });
        }

        if check_readiness(&obj, kind) {
            if kind == "DaemonSet"
                && let Some(stale) = daemonset_pending_restart(&obj.data)
            {
                return Ok(ReadinessResult::ReadyPendingRestart {
                    stale,
                    message: "the DaemonSet replaces a pod with the current template only when the pod is deleted".into(),
                });
            }
            // A CRD that reports Established=True can still be invisible to
            // the apiserver's discovery endpoint for a few hundred ms (and
            // longer across HA replicas). Probe discovery before declaring
            // the CRD ready so dependents don't race.
            if kind == "CustomResourceDefinition" {
                on_status("CRD Established, probing discovery");
                let _ = probe_crd_discovery(client, &obj.data).await;
            }
            return Ok(ReadinessResult::Ready);
        }

        // Compute progress fingerprint and reset the idle timer on any change.
        let fingerprint = progress_fingerprint(&obj, kind, &scan.pods);
        if fingerprint != last_fingerprint {
            last_fingerprint = fingerprint;
            last_progress_at = Instant::now();
        }

        let message = readiness_message(&obj, kind);
        let idle = last_progress_at.elapsed();
        let total = start.elapsed();
        on_status(&format!("{message} (idle {}s)", idle.as_secs()));

        if idle >= idle_budget {
            return Ok(ReadinessResult::TimedOut {
                elapsed: total,
                message: format!(
                    "no progress for {}s (idle budget {}s): {message}",
                    idle.as_secs(),
                    idle_budget.as_secs()
                ),
            });
        }
        if total >= hard_ceiling {
            return Ok(ReadinessResult::TimedOut {
                elapsed: total,
                message: format!(
                    "hard ceiling {}s exceeded: {message}",
                    hard_ceiling.as_secs()
                ),
            });
        }

        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

/// Check if a kind is immediately ready upon existence (no polling needed).
pub fn is_immediate_kind(kind: &str) -> bool {
    matches!(
        kind,
        "ConfigMap"
            | "Secret"
            | "ServiceAccount"
            | "Namespace"
            | "Service"
            | "ClusterRole"
            | "ClusterRoleBinding"
            | "Role"
            | "RoleBinding"
            | "Ingress"
            | "NetworkPolicy"
            | "LimitRange"
            | "ResourceQuota"
            | "PodDisruptionBudget"
            | "HorizontalPodAutoscaler"
            | "ServiceMonitor"
            | "PriorityClass"
            | crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND
            | crate::manifest::lifecycle::RECORD_KIND
            | "StorageClass"
    )
}

/// A readiness convention declared by the CRD-owning package and stamped on
/// the CR as the `kix.run/readiness` annotation. Two JSON shapes:
/// `{"path": "/status/...", "equals": "<value>"}` is ready when the string at
/// `path` equals `equals`; `{"condition": {"type": "<Type>", "status": "True"}}`
/// is ready when `status.conditions` holds an entry with that type and status.
enum DeclaredReadiness {
    Path {
        path: String,
        equals: String,
    },
    Condition {
        condition_type: String,
        status: String,
    },
}

/// Parse a well-formed `kix.run/readiness` annotation.
///
/// Ignore malformed annotations and use kind-based readiness. This supports
/// manifests produced by a different library version. A custom resource with
/// no recognized readiness rule follows `check_generic_ready`, which treats an
/// empty status as ready. Rebuild older manifests to add declared readiness.
fn declared_readiness(obj: &DynamicObject) -> Option<DeclaredReadiness> {
    let raw = keys::get_meta(obj.metadata.annotations.as_ref()?, keys::READINESS)?;
    let v: Value = serde_json::from_str(raw).ok()?;
    if let Some(condition) = v.get("condition") {
        return Some(DeclaredReadiness::Condition {
            condition_type: condition.get("type")?.as_str()?.to_string(),
            status: condition.get("status")?.as_str()?.to_string(),
        });
    }
    Some(DeclaredReadiness::Path {
        path: v.get("path")?.as_str()?.to_string(),
        equals: v.get("equals")?.as_str()?.to_string(),
    })
}

/// Synchronous readiness check for a single resource.
///
/// Returns `true` if the resource is considered ready based on its kind.
pub fn check_readiness(obj: &DynamicObject, kind: &str) -> bool {
    if is_immediate_kind(kind) {
        return true;
    }

    // A CRD-owning package declares its kinds' readiness convention on the
    // CRD builder (readiness = { path; equals; } or readiness = { condition
    // = { type; status; }; }) and kix stamps it on every CR built through
    // the typed chain as the `kix.run/readiness` annotation. The match
    // below covers only kinds whose readiness the Kubernetes API itself
    // defines. An operator's condition vocabulary belongs in the owning
    // package's declaration, not in this list.
    if let Some(rule) = declared_readiness(obj) {
        return match rule {
            DeclaredReadiness::Path { path, equals } => obj
                .data
                .pointer(&path)
                .and_then(Value::as_str)
                .is_some_and(|v| v == equals),
            DeclaredReadiness::Condition {
                condition_type,
                status,
            } => has_condition(&obj.data, &condition_type, &status),
        };
    }

    match kind {
        "Deployment" | "StatefulSet" => check_deployment_ready(obj.metadata.generation, &obj.data),
        "DaemonSet" => check_daemonset_ready(obj.metadata.generation, &obj.data),
        "Job" => check_job_ready(&obj.data),
        "PersistentVolumeClaim" => check_pvc_ready(&obj.data),
        "CustomResourceDefinition" => check_crd_ready(&obj.data),
        _ => check_generic_ready(&obj.data),
    }
}

/// Deployment/StatefulSet: readyReplicas == spec.replicas && updatedReplicas == spec.replicas
/// && observedGeneration >= generation
fn check_deployment_ready(generation: Option<i64>, data: &Value) -> bool {
    // kube-rs stores generation in DynamicObject.metadata, outside data.
    // Compare observedGeneration with this typed metadata field to reject
    // readiness left over from the previous generation.
    let generation = generation.unwrap_or(0);
    let observed = data
        .pointer("/status/observedGeneration")
        .and_then(Value::as_i64)
        .unwrap_or(-1);

    if observed < generation {
        return false;
    }

    let desired = data
        .pointer("/spec/replicas")
        .and_then(Value::as_i64)
        .unwrap_or(1);
    let ready = data
        .pointer("/status/readyReplicas")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let updated = data
        .pointer("/status/updatedReplicas")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    ready >= desired && updated >= desired
}

/// DaemonSet: numberReady == desiredNumberScheduled && updatedNumberScheduled == desiredNumberScheduled
/// && observedGeneration >= generation. An `OnDelete` DaemonSet drops the
/// updatedNumberScheduled condition: the controller replaces its pods only
/// when they are deleted, and `daemonset_pending_restart` counts the pods
/// still on the previous template.
///
/// A DaemonSet whose node selector matches no node has
/// `desiredNumberScheduled: 0` once the controller has observed it, and
/// is complete (`kubectl rollout status` agrees): mayastor's io-engine
/// selects `openebs.io/engine=mayastor` nodes, and a cluster labels those
/// after the deploy. The observedGeneration guard is what keeps an
/// unobserved, status-less object from passing on the first poll.
fn check_daemonset_ready(generation: Option<i64>, data: &Value) -> bool {
    // Read generation from typed metadata; see check_deployment_ready.
    let generation = generation.unwrap_or(0);
    let observed = data
        .pointer("/status/observedGeneration")
        .and_then(Value::as_i64)
        .unwrap_or(-1);

    if observed < generation {
        return false;
    }

    let desired = data
        .pointer("/status/desiredNumberScheduled")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let ready = data
        .pointer("/status/numberReady")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    // Under OnDelete the controller replaces a pod only when someone
    // deletes it, so pods on the previous template are not waited for;
    // `daemonset_pending_restart` reports them.
    if is_on_delete(data) {
        return ready >= desired;
    }

    let updated = data
        .pointer("/status/updatedNumberScheduled")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    ready >= desired && updated >= desired
}

fn is_on_delete(data: &Value) -> bool {
    data.pointer("/spec/updateStrategy/type")
        .and_then(Value::as_str)
        == Some("OnDelete")
}

/// The number of pods of an `OnDelete` DaemonSet that still run a previous
/// pod template, or `None` when there are none or the DaemonSet rolls its
/// pods itself.
pub fn daemonset_pending_restart(data: &Value) -> Option<i64> {
    if !is_on_delete(data) {
        return None;
    }
    let desired = data
        .pointer("/status/desiredNumberScheduled")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let updated = data
        .pointer("/status/updatedNumberScheduled")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let stale = desired - updated;
    (stale > 0).then_some(stale)
}

/// Job: status.succeeded >= 1
fn check_job_ready(data: &Value) -> bool {
    let succeeded = data
        .pointer("/status/succeeded")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    succeeded >= 1
}

/// Returns true if the named StorageClass uses WaitForFirstConsumer binding mode.
async fn is_wait_for_first_consumer(client: &Client, sc_name: &str) -> bool {
    use kube::discovery::ApiResource;

    let ar = ApiResource {
        group: "storage.k8s.io".into(),
        version: "v1".into(),
        api_version: "storage.k8s.io/v1".into(),
        kind: "StorageClass".into(),
        plural: "storageclasses".into(),
    };
    let api: Api<DynamicObject> = Api::all_with(client.clone(), &ar);
    match api.get(sc_name).await {
        Ok(sc) => sc
            .data
            .pointer("/volumeBindingMode")
            .and_then(Value::as_str)
            .is_some_and(|m| m == "WaitForFirstConsumer"),
        Err(_) => false,
    }
}

/// PVC: status.phase == "Bound"
fn check_pvc_ready(data: &Value) -> bool {
    data.pointer("/status/phase")
        .and_then(Value::as_str)
        .is_some_and(|p| p == "Bound")
}

/// CRD: conditions contains Established=True
fn check_crd_ready(data: &Value) -> bool {
    has_condition(data, "Established", "True")
}

/// Names in a CRD's `spec.versions` with `served: true`.
fn served_crd_versions(data: &Value) -> Vec<String> {
    data.pointer("/spec/versions")
        .and_then(Value::as_array)
        .map(|versions| {
            versions
                .iter()
                .filter(|v| v.get("served").and_then(Value::as_bool) == Some(true))
                .filter_map(|v| v.get("name").and_then(Value::as_str).map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// The entries of `wanted` the CRD does not serve, in `wanted`'s order.
fn unserved_crd_versions(data: &Value, wanted: &[String]) -> Vec<String> {
    let served = served_crd_versions(data);
    wanted
        .iter()
        .filter(|v| !served.contains(v))
        .cloned()
        .collect()
}

/// Generic CR: check .status.conditions for Ready=True or Available=True, else immediate.
fn check_generic_ready(data: &Value) -> bool {
    // If there are conditions, check for Ready or Available
    if let Some(conditions) = data.pointer("/status/conditions").and_then(Value::as_array) {
        if conditions.is_empty() {
            return true;
        }
        // Check for Ready=True or Available=True
        let has_ready = conditions.iter().any(|c| {
            let ctype = c.get("type").and_then(Value::as_str).unwrap_or("");
            let status = c.get("status").and_then(Value::as_str).unwrap_or("");
            (ctype == "Ready" || ctype == "Available") && status == "True"
        });
        return has_ready;
    }
    // Treat a resource with no conditions as ready.
    true
}

/// Check if a specific condition type has a given status.
/// The entry of `status.conditions` whose `type` is `condition_type`.
fn find_condition<'a>(data: &'a Value, condition_type: &str) -> Option<&'a Value> {
    data.pointer("/status/conditions")?
        .as_array()?
        .iter()
        .find(|c| c.get("type").and_then(Value::as_str) == Some(condition_type))
}

fn has_condition(data: &Value, condition_type: &str, expected_status: &str) -> bool {
    find_condition(data, condition_type)
        .and_then(|c| c.get("status"))
        .and_then(Value::as_str)
        == Some(expected_status)
}

/// Build a human-readable message about why a resource isn't ready.
fn readiness_message(obj: &DynamicObject, kind: &str) -> String {
    let name = obj.metadata.name.as_deref().unwrap_or("unknown");
    if let Some(rule) = declared_readiness(obj) {
        return match rule {
            DeclaredReadiness::Path { path, equals } => {
                // Distinguish an absent path from a non-string value because
                // declared readiness compares strings only.
                let current = match obj.data.pointer(&path) {
                    None => "<absent>".to_string(),
                    Some(Value::String(v)) => format!("\"{v}\""),
                    Some(other) => {
                        format!("{other} (non-string; declared readiness compares strings)")
                    }
                };
                format!(
                    "{kind}/{name}: declared readiness {path}=\"{equals}\", currently {current}"
                )
            }
            DeclaredReadiness::Condition {
                condition_type,
                status,
            } => {
                let current = match find_condition(&obj.data, &condition_type) {
                    None => format!("no {condition_type} condition yet"),
                    Some(c) => {
                        let actual = c.get("status").and_then(Value::as_str).unwrap_or("?");
                        match c.get("message").and_then(Value::as_str) {
                            Some(msg) if !msg.is_empty() => {
                                format!("{condition_type}={actual} ({msg})")
                            }
                            _ => format!("{condition_type}={actual}"),
                        }
                    }
                };
                format!(
                    "{kind}/{name}: declared readiness condition {condition_type}={status}, currently {current}"
                )
            }
        };
    }
    match kind {
        "Deployment" | "StatefulSet" => {
            let desired = obj
                .data
                .pointer("/spec/replicas")
                .and_then(Value::as_i64)
                .unwrap_or(1);
            let ready = obj
                .data
                .pointer("/status/readyReplicas")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let updated = obj
                .data
                .pointer("/status/updatedReplicas")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            format!("{kind}/{name}: {ready}/{desired} ready, {updated}/{desired} updated")
        }
        "DaemonSet" => {
            let desired = obj
                .data
                .pointer("/status/desiredNumberScheduled")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let ready = obj
                .data
                .pointer("/status/numberReady")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            format!("DaemonSet/{name}: {ready}/{desired} ready")
        }
        "Job" => {
            let succeeded = obj
                .data
                .pointer("/status/succeeded")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            format!("Job/{name}: {succeeded} succeeded")
        }
        "PersistentVolumeClaim" => {
            let phase = obj
                .data
                .pointer("/status/phase")
                .and_then(Value::as_str)
                .unwrap_or("Unknown");
            format!("PVC/{name}: phase={phase}")
        }
        _ => {
            // Show condition types when a generic custom resource has neither
            // Ready nor Available, so the missing readiness convention is visible.
            let seen: Vec<String> = obj
                .data
                .pointer("/status/conditions")
                .and_then(Value::as_array)
                .map(|conds| {
                    conds
                        .iter()
                        .filter_map(|c| {
                            let t = c.get("type").and_then(Value::as_str)?;
                            let st = c.get("status").and_then(Value::as_str).unwrap_or("?");
                            Some(format!("{t}={st}"))
                        })
                        .collect()
                })
                .unwrap_or_default();
            if seen.is_empty() {
                format!("{kind}/{name}: not ready")
            } else {
                format!(
                    concat!(
                        "{kind}/{name}: no Ready or Available condition; the controller reports [{seen}]. ",
                        "check on the owning package's CRD builder (readiness = {{ condition = ",
                        "{{ type; status; }}; }} or {{ path; equals; }}, stamped as the ",
                        "{readiness_key} annotation)."
                    ),
                    kind = kind,
                    name = name,
                    readiness_key = keys::READINESS,
                    seen = seen.join(", ")
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::json;

    fn make_obj(data: Value) -> DynamicObject {
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("test".into()),
                ..Default::default()
            },
            types: None,
            data,
        }
    }

    /// Build the live-object shape with generation in the typed ObjectMeta.
    fn make_obj_gen(generation: i64, data: Value) -> DynamicObject {
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("test".into()),
                generation: Some(generation),
                ..Default::default()
            },
            types: None,
            data,
        }
    }

    /// Like make_obj but with a kix.run/readiness annotation, mirroring what
    /// the nix typed CRD chain stamps on every CR.
    fn make_annotated_obj(annotation: &str, data: Value) -> DynamicObject {
        let mut annotations = std::collections::BTreeMap::new();
        annotations.insert(keys::READINESS.to_string(), annotation.to_string());
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("test".into()),
                annotations: Some(annotations),
                ..Default::default()
            },
            types: None,
            data,
        }
    }

    const VM_RULE: &str = r#"{"path":"/status/updateStatus","equals":"operational"}"#;

    #[test]
    fn declared_readiness_parses_valid_annotation() {
        let obj = make_annotated_obj(VM_RULE, json!({}));
        match declared_readiness(&obj).expect("should parse") {
            DeclaredReadiness::Path { path, equals } => {
                assert_eq!(path, "/status/updateStatus");
                assert_eq!(equals, "operational");
            }
            DeclaredReadiness::Condition { .. } => panic!("parsed as condition form"),
        }
    }

    #[test]
    fn declared_readiness_ignores_malformed_annotations() {
        for bad in [
            "not json",
            r#"{"path":"/status/x"}"#,               // missing equals
            r#"{"equals":"ok"}"#,                    // missing path
            r#"{"path":42,"equals":"ok"}"#,          // non-string path
            r#"{"path":"/status/x","equals":true}"#, // non-string equals
        ] {
            let obj = make_annotated_obj(bad, json!({}));
            assert!(declared_readiness(&obj).is_none(), "should reject: {bad}");
        }
        // No annotation at all.
        assert!(declared_readiness(&make_obj(json!({}))).is_none());
    }

    #[test]
    fn declared_readiness_gates_check_readiness() {
        let ready = make_annotated_obj(VM_RULE, json!({"status": {"updateStatus": "operational"}}));
        assert!(check_readiness(&ready, "VMCluster"));

        let expanding =
            make_annotated_obj(VM_RULE, json!({"status": {"updateStatus": "expanding"}}));
        assert!(!check_readiness(&expanding, "VMCluster"));

        // No status yet: declared readiness waits (unlike generic ready-on-empty).
        let fresh = make_annotated_obj(VM_RULE, json!({}));
        assert!(!check_readiness(&fresh, "VMCluster"));
    }

    const CONDITION_RULE: &str = r#"{"condition":{"type":"Bootstrapped","status":"True"}}"#;

    #[test]
    fn declared_condition_parses() {
        let obj = make_annotated_obj(CONDITION_RULE, json!({}));
        match declared_readiness(&obj).expect("should parse") {
            DeclaredReadiness::Condition {
                condition_type,
                status,
            } => {
                assert_eq!(condition_type, "Bootstrapped");
                assert_eq!(status, "True");
            }
            DeclaredReadiness::Path { .. } => panic!("parsed as path form"),
        }
        for bad in [
            r#"{"condition":{"type":"Bootstrapped"}}"#, // missing status
            r#"{"condition":{"status":"True"}}"#,       // missing type
            r#"{"condition":"Bootstrapped"}"#,          // not an object
        ] {
            let obj = make_annotated_obj(bad, json!({}));
            assert!(declared_readiness(&obj).is_none(), "should reject: {bad}");
        }
    }

    #[test]
    fn declared_condition_gates_check_readiness() {
        let ready = make_annotated_obj(
            CONDITION_RULE,
            json!({"status": {"conditions": [{"type": "Bootstrapped", "status": "True"}]}}),
        );
        assert!(check_readiness(&ready, "SGCluster"));

        let pending = make_annotated_obj(
            CONDITION_RULE,
            json!({"status": {"conditions": [{"type": "Bootstrapped", "status": "False"}]}}),
        );
        assert!(!check_readiness(&pending, "SGCluster"));

        // A generic Ready=True does not satisfy a declared condition.
        let other = make_annotated_obj(
            CONDITION_RULE,
            json!({"status": {"conditions": [{"type": "Ready", "status": "True"}]}}),
        );
        assert!(!check_readiness(&other, "SGCluster"));

        // No status yet: declared readiness waits.
        let fresh = make_annotated_obj(CONDITION_RULE, json!({}));
        assert!(!check_readiness(&fresh, "SGCluster"));
    }

    #[test]
    fn declared_condition_message_shapes() {
        let rule = r#"{"condition":{"type":"Valid","status":"True"}}"#;
        let invalid = make_annotated_obj(
            rule,
            json!({"status": {"conditions": [
                {"type": "Valid", "status": "False", "message": "bad selector"}
            ]}}),
        );
        let msg = readiness_message(&invalid, "CiliumNetworkPolicy");
        assert!(
            msg.contains(
                "declared readiness condition Valid=True, currently Valid=False (bad selector)"
            ),
            "got: {msg}"
        );

        let absent = make_annotated_obj(rule, json!({}));
        let msg = readiness_message(&absent, "CiliumNetworkPolicy");
        assert!(msg.contains("no Valid condition yet"), "got: {msg}");
    }

    #[test]
    fn malformed_annotation_falls_through_to_kind_rules() {
        // Malformed annotations fall through for version compatibility. The CR
        // then uses check_generic_ready, which treats an empty status as ready.
        let no_status = make_annotated_obj("not json", json!({}));
        assert!(check_readiness(&no_status, "VMCluster"));

        // ...and unrecognized condition vocabulary as not-ready.
        let stamped = make_annotated_obj(
            "not json",
            json!({"status": {"conditions": [
                {"type": "x.example.com/Applied", "status": "True"}
            ]}}),
        );
        assert!(!check_readiness(&stamped, "VMCluster"));
    }

    #[test]
    fn declared_readiness_non_string_value_never_matches() {
        let rule = r#"{"path":"/status/replicas","equals":"3"}"#;
        let obj = make_annotated_obj(rule, json!({"status": {"replicas": 3}}));
        assert!(!check_readiness(&obj, "VMCluster"));
        let msg = readiness_message(&obj, "VMCluster");
        assert!(msg.contains("non-string"), "got: {msg}");
        assert!(!msg.contains("<absent>"), "got: {msg}");
    }

    #[test]
    fn declared_readiness_message_shapes() {
        let waiting = make_annotated_obj(VM_RULE, json!({"status": {"updateStatus": "expanding"}}));
        let msg = readiness_message(&waiting, "VMCluster");
        assert!(
            msg.contains(
                r#"declared readiness /status/updateStatus="operational", currently "expanding""#
            ),
            "got: {msg}"
        );

        let absent = make_annotated_obj(VM_RULE, json!({}));
        let msg = readiness_message(&absent, "VMCluster");
        assert!(msg.contains("<absent>"), "got: {msg}");
    }

    #[test]
    fn immediate_kinds() {
        assert!(is_immediate_kind("ConfigMap"));
        assert!(is_immediate_kind("Secret"));
        assert!(is_immediate_kind("Service"));
        assert!(is_immediate_kind("Namespace"));
        assert!(is_immediate_kind("ServiceAccount"));
        assert!(is_immediate_kind("ClusterRole"));
        assert!(is_immediate_kind("ClusterRoleBinding"));
        assert!(is_immediate_kind("Role"));
        assert!(is_immediate_kind("RoleBinding"));
        assert!(is_immediate_kind("Ingress"));
        assert!(!is_immediate_kind("Deployment"));
        assert!(!is_immediate_kind("StatefulSet"));
        assert!(!is_immediate_kind("Job"));
    }

    #[test]
    fn deployment_ready() {
        let obj = make_obj_gen(
            2,
            json!({
                "spec": {"replicas": 3},
                "status": {
                    "observedGeneration": 2,
                    "readyReplicas": 3,
                    "updatedReplicas": 3,
                }
            }),
        );
        assert!(check_readiness(&obj, "Deployment"));
    }

    #[test]
    fn deployment_not_ready_replicas() {
        let obj = make_obj_gen(
            1,
            json!({
                "spec": {"replicas": 3},
                "status": {
                    "observedGeneration": 1,
                    "readyReplicas": 2,
                    "updatedReplicas": 3,
                }
            }),
        );
        assert!(!check_readiness(&obj, "Deployment"));
    }

    #[test]
    fn deployment_stale_status_not_ready() {
        // The live-object shape the dead guard never caught: an UPDATE
        // bumped metadata.generation to 2 while status still reports the
        // previous generation's healthy rollout. Must NOT be ready.
        let obj = make_obj_gen(
            2,
            json!({
                "spec": {"replicas": 3},
                "status": {
                    "observedGeneration": 1,
                    "readyReplicas": 3,
                    "updatedReplicas": 3,
                }
            }),
        );
        assert!(!check_readiness(&obj, "Deployment"));
        let ds = make_obj_gen(
            2,
            json!({
                "status": {
                    "observedGeneration": 1,
                    "desiredNumberScheduled": 3,
                    "numberReady": 3,
                    "updatedNumberScheduled": 3,
                }
            }),
        );
        assert!(!check_readiness(&ds, "DaemonSet"));
    }

    fn on_delete_ds(desired: i64, ready: i64, updated: i64) -> DynamicObject {
        make_obj_gen(
            2,
            json!({
                "spec": {"updateStrategy": {"type": "OnDelete"}},
                "status": {
                    "observedGeneration": 2,
                    "desiredNumberScheduled": desired,
                    "numberReady": ready,
                    "updatedNumberScheduled": updated,
                }
            }),
        )
    }

    #[test]
    fn on_delete_daemonset_with_stale_pods_is_ready_and_pending_restart() {
        let ds = on_delete_ds(3, 3, 1);
        assert!(check_readiness(&ds, "DaemonSet"));
        assert_eq!(daemonset_pending_restart(&ds.data), Some(2));
    }

    #[test]
    fn on_delete_daemonset_fully_updated_has_no_pending_restart() {
        let ds = on_delete_ds(3, 3, 3);
        assert!(check_readiness(&ds, "DaemonSet"));
        assert_eq!(daemonset_pending_restart(&ds.data), None);
    }

    #[test]
    fn on_delete_daemonset_waits_for_ready_pods() {
        let ds = on_delete_ds(3, 2, 1);
        assert!(!check_readiness(&ds, "DaemonSet"));
    }

    #[test]
    fn on_delete_daemonset_matching_no_node_is_ready() {
        let ds = on_delete_ds(0, 0, 0);
        assert!(check_readiness(&ds, "DaemonSet"));
        assert_eq!(daemonset_pending_restart(&ds.data), None);
    }

    #[test]
    fn rolling_update_daemonset_waits_for_updated_pods() {
        let ds = make_obj_gen(
            2,
            json!({
                "spec": {"updateStrategy": {"type": "RollingUpdate"}},
                "status": {
                    "observedGeneration": 2,
                    "desiredNumberScheduled": 3,
                    "numberReady": 3,
                    "updatedNumberScheduled": 1,
                }
            }),
        );
        assert!(!check_readiness(&ds, "DaemonSet"));
        assert_eq!(daemonset_pending_restart(&ds.data), None);
    }

    #[test]
    fn daemonset_matching_no_node_is_ready_once_observed() {
        // io-engine on a cluster with no openebs.io/engine=mayastor node:
        // 0 desired, 0 ready, observed. Complete, not a timeout.
        let ds = make_obj_gen(
            1,
            json!({
                "status": {
                    "observedGeneration": 1,
                    "desiredNumberScheduled": 0,
                    "numberReady": 0,
                    "updatedNumberScheduled": 0,
                }
            }),
        );
        assert!(check_readiness(&ds, "DaemonSet"));
        // The same object before the controller has written any status.
        let unobserved = make_obj_gen(1, json!({}));
        assert!(!check_readiness(&unobserved, "DaemonSet"));
    }

    #[test]
    fn statefulset_ready() {
        let obj = make_obj_gen(
            1,
            json!({
                "spec": {"replicas": 2},
                "status": {
                    "observedGeneration": 1,
                    "readyReplicas": 2,
                    "updatedReplicas": 2,
                }
            }),
        );
        assert!(check_readiness(&obj, "StatefulSet"));
    }

    #[test]
    fn undeclared_custom_kind_uses_generic_conditions() {
        // Without a declaration the CLI knows nothing about an operator's
        // vocabulary: Valid=True is not readiness, Ready=True is.
        let valid_only = make_obj(json!({
            "status": {"conditions": [{"type": "Valid", "status": "True"}]}
        }));
        assert!(!check_readiness(&valid_only, "CiliumNetworkPolicy"));

        let ready = make_obj(json!({
            "status": {"conditions": [{"type": "Ready", "status": "True"}]}
        }));
        assert!(check_readiness(&ready, "CiliumNetworkPolicy"));
    }

    #[test]
    fn crd_established() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Established", "status": "True"},
                    {"type": "NamesAccepted", "status": "True"},
                ]
            }
        }));
        assert!(check_readiness(&obj, "CustomResourceDefinition"));
    }

    #[test]
    fn crd_not_established() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Established", "status": "False"},
                ]
            }
        }));
        assert!(!check_readiness(&obj, "CustomResourceDefinition"));
    }

    #[test]
    fn job_completed() {
        let obj = make_obj(json!({
            "status": {"succeeded": 1}
        }));
        assert!(check_readiness(&obj, "Job"));
    }

    #[test]
    fn expectations_are_read_from_the_annotation() {
        let manifest = json!({
            "kind": "Deployment",
            "metadata": {
                "name": "ctrl",
                "namespace": "ingress-system",
                "annotations": { keys::EXPECTS: "v1|Secret|ctrl-admission,cert-manager.io/v1|Certificate|c,broken" }
            }
        });
        let got = expectations(&manifest);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].api_version, "v1");
        assert_eq!(got[0].kind, "Secret");
        assert_eq!(got[0].name, "ctrl-admission");
        assert_eq!(got[1].api_version, "cert-manager.io/v1");
        assert_eq!(got[1].display(), "Certificate/c");
        assert!(expectations(&json!({ "metadata": { "name": "n" } })).is_empty());
    }

    #[test]
    fn import_marker_parsed() {
        let manifest = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "PackageInstance",
            "metadata": {
                "name": "crd-ref-stackgres-operator-sgclusters-stackgres-io",
                "namespace": "data",
                "annotations": {
                    keys::MODE: "import",
                    keys::IMPORT_KIND: "CustomResourceDefinition",
                    keys::IMPORT_API_VERSION: "apiextensions.k8s.io/v1",
                    keys::IMPORT_NAME: "sgclusters.stackgres.io",
                }
            }
        });
        let target = import_target_from_manifest(&manifest).expect("should parse");
        assert_eq!(target.kind, "CustomResourceDefinition");
        assert_eq!(target.api_version, "apiextensions.k8s.io/v1");
        assert_eq!(target.name, "sgclusters.stackgres.io");
        // CRDs are cluster-scoped; namespace is always None regardless of
        // the marker's own metadata.namespace.
        assert_eq!(target.namespace, None);
        assert!(target.expected_keys.is_empty());
    }

    #[test]
    fn secret_import_marker_inherits_marker_namespace() {
        // Namespaced imports take their namespace from the marker's own
        // metadata.namespace, not from any annotation.
        let manifest = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "PackageInstance",
            "metadata": {
                "name": "secret-ref-myapp-db-creds",
                "namespace": "myapp",
                "annotations": {
                    keys::MODE: "import",
                    keys::IMPORT_KIND: "Secret",
                    keys::IMPORT_API_VERSION: "v1",
                    keys::IMPORT_NAME: "db-creds",
                    keys::IMPORT_SECRET_KEYS: "username,password",
                }
            }
        });
        let target = import_target_from_manifest(&manifest).expect("should parse");
        assert_eq!(target.kind, "Secret");
        assert_eq!(target.name, "db-creds");
        assert_eq!(target.namespace.as_deref(), Some("myapp"));
        assert_eq!(target.expected_keys, vec!["username", "password"]);
    }

    #[test]
    fn secret_import_marker_no_keys_annotation() {
        let manifest = json!({
            "kind": "PackageInstance",
            "metadata": {
                "name": "secret-ref-myapp-bootstrap",
                "namespace": "myapp",
                "annotations": {
                    keys::MODE: "import",
                    keys::IMPORT_KIND: "Secret",
                    keys::IMPORT_API_VERSION: "v1",
                    keys::IMPORT_NAME: "bootstrap",
                }
            }
        });
        let target = import_target_from_manifest(&manifest).expect("should parse");
        assert!(target.expected_keys.is_empty());
    }

    #[test]
    fn import_marker_without_kind_has_no_target() {
        // A kind-less import (`kix.mkImport` with no `kind`) names nothing
        // the deploy can look up, so the marker is not waited on.
        let manifest = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "PackageInstance",
            "metadata": {
                "name": "platform-storage",
                "namespace": "kube-system",
                "annotations": {
                    keys::MODE: "import",
                    keys::IMPORT_NAME: "standard",
                }
            }
        });
        assert!(import_target_from_manifest(&manifest).is_none());
        // The marker itself is ready as soon as it exists.
        assert!(is_immediate_kind("PackageInstance"));
    }

    #[test]
    fn crd_ref_marker_carries_served_versions() {
        let marker = |extra: Value| {
            let mut annotations = json!({
                keys::MODE: "import",
                keys::IMPORT_KIND: "CustomResourceDefinition",
                keys::IMPORT_API_VERSION: "apiextensions.k8s.io/v1",
                keys::IMPORT_NAME: "scrapeconfigs.monitoring.coreos.com",
                keys::CRD_VERSION: "v1alpha1",
            });
            for (k, v) in extra.as_object().unwrap() {
                annotations[k] = v.clone();
            }
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "PackageInstance",
                "metadata": {
                    "name": "crd-ref-vm-scrapeconfigs-monitoring-coreos-com",
                    "namespace": "monitoring",
                    "annotations": annotations,
                }
            })
        };
        let default_only = import_target_from_manifest(&marker(json!({}))).unwrap();
        assert_eq!(default_only.served_versions, vec!["v1alpha1"]);
        let listed = import_target_from_manifest(&marker(json!({
            keys::CRD_SERVED_VERSIONS: "v1alpha1,v1beta1"
        })))
        .unwrap();
        assert_eq!(listed.served_versions, vec!["v1alpha1", "v1beta1"]);
    }

    #[test]
    fn non_crd_import_has_no_served_versions() {
        let manifest = json!({
            "kind": "PackageInstance",
            "metadata": {
                "name": "secret-ref-myapp-bootstrap",
                "namespace": "myapp",
                "annotations": {
                    keys::MODE: "import",
                    keys::IMPORT_KIND: "Secret",
                    keys::IMPORT_API_VERSION: "v1",
                    keys::IMPORT_NAME: "bootstrap",
                    keys::CRD_VERSION: "v1",
                }
            }
        });
        let target = import_target_from_manifest(&manifest).unwrap();
        assert!(target.served_versions.is_empty());
    }

    #[test]
    fn crd_served_version_check() {
        let crd = json!({
            "spec": {
                "versions": [
                    { "name": "v1", "served": true, "storage": true },
                    { "name": "v1beta1", "served": false, "storage": false },
                ]
            }
        });
        let wanted = |vs: &[&str]| vs.iter().map(|v| v.to_string()).collect::<Vec<_>>();
        // Served.
        assert!(unserved_crd_versions(&crd, &wanted(&["v1"])).is_empty());
        // Listed but not served, and absent.
        assert_eq!(
            unserved_crd_versions(&crd, &wanted(&["v1", "v1beta1", "v2"])),
            vec!["v1beta1", "v2"]
        );
        // No declared versions (a marker without the annotation): nothing to check.
        assert!(unserved_crd_versions(&crd, &[]).is_empty());
        assert_eq!(served_crd_versions(&crd), vec!["v1"]);
    }

    #[test]
    fn import_marker_non_import_mode_ignored() {
        let manifest = json!({
            "kind": "PackageInstance",
            "metadata": {
                "annotations": { keys::MODE: "normal" }
            }
        });
        assert!(import_target_from_manifest(&manifest).is_none());
    }

    #[test]
    fn import_marker_non_packageinstance_ignored() {
        let manifest = json!({
            "kind": "ConfigMap",
            "metadata": {
                "annotations": {
                    keys::MODE: "import",
                    keys::IMPORT_KIND: "Secret",
                    keys::IMPORT_API_VERSION: "v1",
                    keys::IMPORT_NAME: "foo",
                }
            }
        });
        assert!(import_target_from_manifest(&manifest).is_none());
    }

    #[test]
    fn check_secret_keys_all_present() {
        let secret = json!({
            "data": {
                "username": "YWRtaW4=",
                "password": "czNjcjN0",
            }
        });
        let missing = check_secret_keys(&secret, &["username".into(), "password".into()]);
        assert!(missing.is_empty());
    }

    #[test]
    fn check_secret_keys_some_missing() {
        let secret = json!({
            "data": {
                "username": "YWRtaW4=",
            }
        });
        let missing = check_secret_keys(
            &secret,
            &["username".into(), "password".into(), "token".into()],
        );
        assert_eq!(missing, vec!["password", "token"]);
    }

    #[test]
    fn check_secret_keys_no_data_field() {
        let secret = json!({});
        let missing = check_secret_keys(&secret, &["username".into()]);
        assert_eq!(missing, vec!["username"]);
    }

    #[test]
    fn split_api_version_core() {
        assert_eq!(split_api_version("v1"), ("", "v1"));
        assert_eq!(split_api_version("apps/v1"), ("apps", "v1"));
        assert_eq!(
            split_api_version("apiextensions.k8s.io/v1"),
            ("apiextensions.k8s.io", "v1")
        );
    }

    #[test]
    fn generic_cr_ready() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Ready", "status": "True"}
                ]
            }
        }));
        assert!(check_readiness(&obj, "SomeCustomResource"));
    }

    // -- terminal-failure classifier tests --

    #[test]
    fn pod_image_pull_backoff_is_terminal() {
        let pod = json!({
            "metadata": {"name": "app-abc"},
            "status": {
                "containerStatuses": [{
                    "name": "main",
                    "state": {"waiting": {
                        "reason": "ImagePullBackOff",
                        "message": "Back-off pulling image registry/foo:v3"
                    }},
                    "restartCount": 0
                }]
            }
        });
        let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
        assert_eq!(reason, TerminalReason::ImagePull);
        assert!(msg.contains("app-abc/main"));
        assert!(msg.contains("ImagePullBackOff"));
    }

    #[test]
    fn pod_err_image_pull_is_terminal() {
        let pod = json!({
            "metadata": {"name": "p"},
            "status": {
                "containerStatuses": [{
                    "name": "c",
                    "state": {"waiting": {"reason": "ErrImagePull", "message": "not found"}},
                    "restartCount": 0
                }]
            }
        });
        assert_eq!(
            classify_pod_terminal(&pod).map(|(r, _)| r),
            Some(TerminalReason::ImagePull)
        );
    }

    #[test]
    fn pod_create_container_config_error_is_terminal() {
        let pod = json!({
            "metadata": {"name": "p"},
            "status": {
                "containerStatuses": [{
                    "name": "c",
                    "state": {"waiting": {
                        "reason": "CreateContainerConfigError",
                        "message": "secret 'creds' not found"
                    }},
                    "restartCount": 0
                }]
            }
        });
        let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
        assert_eq!(reason, TerminalReason::ContainerConfig);
        assert!(msg.contains("creds"));
    }

    #[test]
    fn pod_crashloop_below_threshold_not_terminal() {
        let pod = json!({
            "metadata": {"name": "p"},
            "status": {
                "containerStatuses": [{
                    "name": "c",
                    "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                    "restartCount": 1
                }]
            }
        });
        assert!(classify_pod_terminal(&pod).is_none());
    }

    #[test]
    fn pod_crashloop_at_threshold_is_terminal() {
        let pod = json!({
            "metadata": {"name": "p"},
            "status": {
                "containerStatuses": [{
                    "name": "c",
                    "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                    "restartCount": 3,
                    "lastState": {
                        "terminated": {"reason": "Error", "exitCode": 1}
                    }
                }]
            }
        });
        let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
        assert_eq!(reason, TerminalReason::CrashLoop);
        assert!(msg.contains("restarts"));
        assert!(msg.contains("Error"));
    }

    #[test]
    fn pod_terminated_error_with_restarts_is_terminal() {
        // Job pods between restart attempts show state=terminated rather than
        // waiting/CrashLoopBackOff. This must still be caught as terminal.
        let pod = json!({
            "metadata": {"name": "job-pod-abc"},
            "status": {
                "containerStatuses": [{
                    "name": "create",
                    "state": {"terminated": {"reason": "Error", "exitCode": 1, "finishedAt": "2026-01-01T00:00:00Z"}},
                    "lastState": {"terminated": {"reason": "Error", "exitCode": 1}},
                    "restartCount": 4
                }]
            }
        });
        let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
        assert_eq!(reason, TerminalReason::CrashLoop);
        assert!(msg.contains("terminated with Error"));
        assert!(msg.contains("exit=1"));
        assert!(msg.contains("4 restarts"));
    }

    #[test]
    fn pod_terminated_error_below_threshold_not_terminal() {
        let pod = json!({
            "metadata": {"name": "job-pod-abc"},
            "status": {
                "containerStatuses": [{
                    "name": "create",
                    "state": {"terminated": {"reason": "Error", "exitCode": 1}},
                    "restartCount": 1
                }]
            }
        });
        assert!(classify_pod_terminal(&pod).is_none());
    }

    #[test]
    fn pod_terminated_success_not_terminal() {
        // Exit code 0 is a successful termination (normal for Jobs), not a failure.
        let pod = json!({
            "metadata": {"name": "job-pod-abc"},
            "status": {
                "containerStatuses": [{
                    "name": "create",
                    "state": {"terminated": {"reason": "Completed", "exitCode": 0}},
                    "restartCount": 0
                }]
            }
        });
        assert!(classify_pod_terminal(&pod).is_none());
    }

    #[test]
    fn pod_init_container_failures_detected() {
        let pod = json!({
            "metadata": {"name": "p"},
            "status": {
                "initContainerStatuses": [{
                    "name": "init",
                    "state": {"waiting": {
                        "reason": "ImagePullBackOff",
                        "message": "x"
                    }},
                    "restartCount": 0
                }],
                "containerStatuses": []
            }
        });
        assert_eq!(
            classify_pod_terminal(&pod).map(|(r, _)| r),
            Some(TerminalReason::ImagePull)
        );
    }

    #[test]
    fn pod_healthy_not_terminal() {
        let pod = json!({
            "metadata": {"name": "p"},
            "status": {
                "containerStatuses": [{
                    "name": "c",
                    "state": {"running": {"startedAt": "2024-01-01T00:00:00Z"}},
                    "restartCount": 0
                }]
            }
        });
        assert!(classify_pod_terminal(&pod).is_none());
    }

    #[test]
    fn deployment_progress_deadline_is_terminal() {
        let obj = json!({
            "status": {
                "conditions": [
                    {"type": "Available", "status": "False"},
                    {
                        "type": "Progressing",
                        "status": "False",
                        "reason": "ProgressDeadlineExceeded",
                        "message": "ReplicaSet \"app-xyz\" has timed out progressing."
                    }
                ]
            }
        });
        let (reason, msg) = classify_workload_terminal(&obj, "Deployment").expect("terminal");
        assert_eq!(reason, TerminalReason::ProgressDeadline);
        assert!(msg.contains("timed out"));
    }

    #[test]
    fn deployment_progressing_true_not_terminal() {
        let obj = json!({
            "status": {
                "conditions": [
                    {"type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"}
                ]
            }
        });
        assert!(classify_workload_terminal(&obj, "Deployment").is_none());
    }

    #[test]
    fn job_backoff_exceeded_is_terminal() {
        let obj = json!({
            "spec": {"backoffLimit": 2},
            "status": {"failed": 3}
        });
        let (reason, _) = classify_workload_terminal(&obj, "Job").expect("terminal");
        assert_eq!(reason, TerminalReason::JobBackoffExceeded);
    }

    #[test]
    fn job_within_backoff_not_terminal() {
        let obj = json!({
            "spec": {"backoffLimit": 6},
            "status": {"failed": 2}
        });
        assert!(classify_workload_terminal(&obj, "Job").is_none());
    }

    #[test]
    fn job_failed_condition_is_terminal() {
        let obj = json!({
            "spec": {"backoffLimit": 6},
            "status": {
                "failed": 1,
                "conditions": [
                    {"type": "Failed", "status": "True", "reason": "DeadlineExceeded", "message": "Job was active longer than specified deadline"}
                ]
            }
        });
        let (reason, msg) = classify_workload_terminal(&obj, "Job").expect("terminal");
        assert_eq!(reason, TerminalReason::JobBackoffExceeded);
        assert!(msg.contains("DeadlineExceeded"));
    }

    #[test]
    fn job_with_succeeded_and_failed_condition_is_terminal() {
        // A Job can have succeeded >= 1 (some pods completed) while also
        // having a Failed condition. The terminal check must win over the
        // readiness check so we don't report Ready for a broken Job.
        let obj = json!({
            "spec": {"backoffLimit": 2},
            "status": {
                "succeeded": 1,
                "failed": 3,
                "conditions": [
                    {"type": "Failed", "status": "True", "reason": "BackoffLimitExceeded", "message": "Job has reached the specified backoff limit"}
                ]
            }
        });
        // The job IS "ready" by the succeeded check...
        assert!(check_job_ready(&obj));
        // ...but it IS terminal due to the failed condition.
        let (reason, _) = classify_workload_terminal(&obj, "Job").expect("terminal");
        assert_eq!(reason, TerminalReason::JobBackoffExceeded);
    }

    #[test]
    fn workload_label_selector_builds_sorted() {
        let obj = json!({
            "spec": {
                "selector": {
                    "matchLabels": {
                        "app": "foo",
                        "release": "v1"
                    }
                }
            }
        });
        assert_eq!(
            workload_label_selector(&obj).as_deref(),
            Some("app=foo,release=v1")
        );
    }

    #[test]
    fn workload_label_selector_missing_returns_none() {
        let obj = json!({"spec": {}});
        assert!(workload_label_selector(&obj).is_none());
    }

    // -- termination output tests --

    fn pod_with_message(container: &str, message: &str) -> Value {
        json!({
            "status": {
                "containerStatuses": [{
                    "name": container,
                    "state": { "terminated": { "exitCode": 1, "message": message } }
                }]
            }
        })
    }

    #[test]
    fn termination_output_carries_the_probe_lines() {
        let pods = vec![pod_with_message(
            "probe",
            "FAIL  1 of 2 agent replicas scraped and up\nFAIL  targets down: x\n2 check(s) still failing after 90s\n\n",
        )];
        assert_eq!(
            termination_output(&pods),
            vec![
                "FAIL  1 of 2 agent replicas scraped and up",
                "FAIL  targets down: x",
                "2 check(s) still failing after 90s",
            ]
        );
    }

    #[test]
    fn termination_output_reads_last_state_and_prefixes_when_several() {
        let pods = vec![json!({
            "status": {
                "containerStatuses": [
                    { "name": "a", "state": { "waiting": {} },
                      "lastState": { "terminated": { "message": "from a" } } },
                    { "name": "b", "state": { "terminated": { "message": "from b" } } },
                    { "name": "quiet", "state": { "terminated": { "message": "" } } }
                ]
            }
        })];
        assert_eq!(termination_output(&pods), vec!["a: from a", "b: from b"]);
    }

    #[test]
    fn termination_output_reads_the_newest_pod_only() {
        let mut first = pod_with_message("probe", "attempt 1");
        first["status"]["startTime"] = json!("2026-09-08T10:00:00Z");
        let mut second = pod_with_message("probe", "attempt 2");
        second["status"]["startTime"] = json!("2026-09-08T10:05:00Z");
        assert_eq!(
            termination_output(&[second.clone(), first.clone()]),
            vec!["attempt 2"]
        );
        assert_eq!(termination_output(&[first, second]), vec!["attempt 2"]);
    }

    #[test]
    fn termination_output_keeps_the_tail() {
        let message: String = (1..=25).map(|i| format!("line {i}\n")).collect();
        let out = termination_output(&[pod_with_message("probe", &message)]);
        assert_eq!(out.len(), TERMINATION_OUTPUT_LINES + 1);
        assert_eq!(out[0], "... 5 earlier lines, see kubectl logs");
        assert_eq!(out[1], "line 6");
        assert_eq!(out[TERMINATION_OUTPUT_LINES], "line 25");
    }

    #[test]
    fn termination_output_is_empty_without_a_message() {
        let pods = vec![
            json!({ "status": { "containerStatuses": [{ "name": "probe", "state": { "terminated": { "exitCode": 1 } } }] } }),
        ];
        assert!(termination_output(&pods).is_empty());
        assert!(termination_output(&[]).is_empty());
    }

    // -- progress fingerprint tests --

    #[test]
    fn fingerprint_changes_when_replicas_progress() {
        let before = make_obj(json!({
            "metadata": {"name": "app", "generation": 1},
            "spec": {"replicas": 3},
            "status": {"observedGeneration": 1, "readyReplicas": 0, "updatedReplicas": 1}
        }));
        let after = make_obj(json!({
            "metadata": {"name": "app", "generation": 1},
            "spec": {"replicas": 3},
            "status": {"observedGeneration": 1, "readyReplicas": 1, "updatedReplicas": 2}
        }));
        let fp1 = progress_fingerprint(&before, "Deployment", &[]);
        let fp2 = progress_fingerprint(&after, "Deployment", &[]);
        assert_ne!(
            fp1, fp2,
            "ready/updated count changes must register as progress"
        );
    }

    #[test]
    fn fingerprint_stable_when_nothing_moves() {
        let obj = make_obj(json!({
            "metadata": {"name": "app", "generation": 1},
            "spec": {"replicas": 3},
            "status": {"observedGeneration": 1, "readyReplicas": 0, "updatedReplicas": 0}
        }));
        let fp1 = progress_fingerprint(&obj, "Deployment", &[]);
        let fp2 = progress_fingerprint(&obj, "Deployment", &[]);
        assert_eq!(fp1, fp2);
    }

    #[test]
    fn fingerprint_changes_on_pod_phase_transition() {
        let obj = make_obj(json!({
            "metadata": {"name": "app", "generation": 1},
            "spec": {"replicas": 1},
            "status": {"observedGeneration": 1, "readyReplicas": 0, "updatedReplicas": 1}
        }));
        let pods_pending = vec![json!({
            "status": {
                "phase": "Pending",
                "containerStatuses": [{
                    "state": {"waiting": {"reason": "ContainerCreating"}},
                    "restartCount": 0
                }]
            }
        })];
        let pods_running = vec![json!({
            "status": {
                "phase": "Running",
                "containerStatuses": [{
                    "state": {"running": {}},
                    "restartCount": 0
                }]
            }
        })];
        let fp1 = progress_fingerprint(&obj, "Deployment", &pods_pending);
        let fp2 = progress_fingerprint(&obj, "Deployment", &pods_running);
        assert_ne!(
            fp1, fp2,
            "Pending→Running pod transition must register as progress"
        );
    }

    #[test]
    fn fingerprint_changes_on_restart_count_bump() {
        let obj = make_obj(json!({
            "spec": {"replicas": 1},
            "status": {"observedGeneration": 1}
        }));
        let pods_low = vec![json!({
            "status": {
                "phase": "Running",
                "containerStatuses": [{"state": {"running": {}}, "restartCount": 1}]
            }
        })];
        let pods_high = vec![json!({
            "status": {
                "phase": "Running",
                "containerStatuses": [{"state": {"running": {}}, "restartCount": 2}]
            }
        })];
        let fp1 = progress_fingerprint(&obj, "Deployment", &pods_low);
        let fp2 = progress_fingerprint(&obj, "Deployment", &pods_high);
        assert_ne!(fp1, fp2, "restart count bump should register as progress");
    }
}
