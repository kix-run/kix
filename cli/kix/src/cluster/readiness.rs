//! Readiness polling for K8s resources.
//!
//! Per-kind readiness checks with `observedGeneration` guards for workloads.
//! Used by `kix deploy` to wait for resources to become ready after apply.
//!
//! Also handles "import marker" PackageInstance resources whose readiness is
//! defined as "the described external resource exists on the cluster AND passes
//! the same per-kind readiness checks as managed resources". Used to gate waves
//! on CRDs installed out-of-band by operators (e.g. stackgres `INSTALL_CRDS=true`)
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
/// elapsed without it showing up (deploy still proceeds — the retry-on-miss
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
/// this resource and blocks the wave until it's present and ready — using the
/// same per-kind readiness checks as managed resources (e.g. for Deployments,
/// waits for `readyReplicas == spec.replicas`). CRDs additionally require
/// `Established=True`; Secrets with `expected_keys` verify every key in `data`.
///
/// The marker lives in its own namespace and the described resource is
/// expected in the same namespace (for namespaced kinds). Cross-namespace
/// imports are not supported — use a dedicated adapter instance in the owning
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
    /// `data`. Parsed from the `kix.dev/import-secret-keys` annotation (comma
    /// separated). Empty = identity-only check (resource existence).
    pub expected_keys: Vec<String>,
}

/// Extract an [`ImportTarget`] from a manifest if it is a PackageInstance
/// import marker (`kix.dev/mode: import`). Returns `None` for non-markers or
/// for markers that don't have enough info to verify (no kind hint, etc.).
///
/// The target's namespace is sourced from the marker's own `metadata.namespace`
/// for namespaced kinds. Cluster-scoped kinds (`CustomResourceDefinition`) set
/// it to `None`. There is no `kix.dev/import-namespace` annotation: an import
/// always describes a resource in the marker's own namespace.
pub fn import_target_from_manifest(manifest: &Value) -> Option<ImportTarget> {
    if !crate::manifest::lifecycle::is_marker(manifest) {
        return None;
    }
    let annotations = manifest.pointer("/metadata/annotations")?;

    let import_kind = annotations
        .get("kix.dev/import-kind")
        .and_then(Value::as_str)?
        .to_string();
    let import_api_version = annotations
        .get("kix.dev/import-apiversion")
        .and_then(Value::as_str)?
        .to_string();
    let import_name = annotations
        .get("kix.dev/import-name")
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
    // valid — it means "only check that the Secret exists".
    let expected_keys = annotations
        .get("kix.dev/import-secret-keys")
        .and_then(Value::as_str)
        .map(|s| {
            s.split(',')
                .map(str::trim)
                .filter(|k| !k.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    Some(ImportTarget {
        kind: import_kind,
        api_version: import_api_version,
        name: import_name,
        namespace,
        expected_keys,
    })
}

/// Poll the cluster for the described [`ImportTarget`] until it exists and
/// passes the same readiness checks as managed resources (e.g. Deployment
/// replica counts, DaemonSet scheduling, CRD `Established=True`, Secret key
/// verification), or the timeout elapses.
///
/// Unlike [`wait_for_ready`] this does not need the target kind to be in the
/// CLI's discovery cache — for `CustomResourceDefinition` targets we construct
/// the `ApiResource` directly from the well-known `apiextensions.k8s.io/v1`
/// group, so we can wait for a CRD that doesn't exist yet at the start of the
/// deploy (which is exactly the case for operator-installed CRDs).
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
    // don't depend on discovery — the target may not be registered yet.
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
        // Generic path: construct from the import-apiversion annotation.
        // Used for non-CRD imports (e.g. waiting on an external Secret).
        // Namespaced by definition — the marker carries its namespace.
        let (group, version) = split_api_version(&target.api_version);
        let plural = pluralize_kind(&target.kind);
        (
            ApiResource {
                group: group.to_string(),
                version: version.to_string(),
                api_version: target.api_version.clone(),
                kind: target.kind.clone(),
                plural,
            },
            Scope::Namespaced,
        )
    };

    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            // Namespaced imports must carry a namespace from the marker.
            // This is a build-time invariant enforced by mkImportMarker — if
            // it's ever missing, the target is malformed and we bail rather
            // than silently querying "default".
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
                        let _ = probe_crd_discovery(client, &obj.data).await;
                        return Ok(ReadinessResult::Ready);
                    }
                    "CRD present, waiting for Established=True".into()
                } else if target.kind == "Secret" && !target.expected_keys.is_empty() {
                    // Secret exists — verify every declared key is present in
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
                    // endpoint, not just object existence. Operators (e.g.
                    // StackGres) create the Service before the backing
                    // StatefulSet pods are ready, so existence alone races
                    // the workload boot sequence.
                    //
                    // Edge cases to revisit:
                    //   - ExternalName Services have no selector / no
                    //     endpoints — they'd time out here. If we ever
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
                // Network errors / transient failures — keep polling until
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
///   2. A single GET returns all addresses — no label-selector list needed.
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
            // We need at least one entry in addresses.
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
/// field. Only key presence is checked — values may be empty strings.
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
    /// Timed out waiting for readiness.
    TimedOut { elapsed: Duration, message: String },
    /// The poll loop observed a cancellation request and bailed before
    /// reaching a definitive state. Caller should propagate cancellation
    /// rather than treating this as a failure.
    Cancelled,
    /// Resource entered a terminal failure state.
    Failed(String),
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
            // between restart attempts — the container shows terminated/Error
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

/// List pods matching a workload's label selector. Best-effort — returns an
/// empty Vec on API errors so the terminal classifier can keep running off
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

/// Full terminal-failure scan: checks workload-level signals first, then
/// pod-level signals for pod-backed kinds. Returns on the first hit (in
/// `terminal`) but always returns the fetched pods so the caller can reuse
/// them for progress fingerprinting.
async fn scan_terminal(client: &Client, obj: &Value, kind: &str, namespace: &str) -> ScanResult {
    if let Some(hit) = classify_workload_terminal(obj, kind) {
        return ScanResult {
            terminal: Some(hit),
            pods: Vec::new(),
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
/// counters), `observedGeneration`, and aggregated pod state — phase
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
                        // the fingerprint via the discriminant — going from
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
/// budget — even an actively-progressing rollout has to finish in this
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
///   the fingerprint changes between polls we reset this timer — so a slow
///   but actively rolling Deployment never trips it.
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
    name: &str,
    namespace: Option<&str>,
    kind: &str,
    timeout: Duration,
    cancel: &CancelToken,
    on_status: impl Fn(&str),
) -> Result<ReadinessResult, ReadinessError> {
    // Immediate kinds: existence = ready
    if is_immediate_kind(kind) {
        return Ok(ReadinessResult::Ready);
    }

    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            Api::namespaced_with(client.clone(), namespace.unwrap_or("default"), ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), ar),
    };

    let idle_budget = timeout;
    let hard_ceiling = HARD_CEILING;

    let start = Instant::now();
    let mut last_progress_at = start;
    let mut last_fingerprint = String::new();

    loop {
        if cancel.is_cancelled() {
            return Ok(ReadinessResult::Cancelled);
        }
        let obj = api.get(name).await.map_err(ReadinessError::FetchError)?;

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

        // Terminal-failure scan runs BEFORE readiness so that a failed Job
        // (or any other terminal signal) is not masked by a partial success
        // (e.g. status.succeeded >= 1 while the Job also has a Failed condition).
        let ns_for_pods = namespace.unwrap_or("default");
        let scan = scan_terminal(client, &obj.data, kind, ns_for_pods).await;
        if let Some((reason, detail)) = scan.terminal {
            return Ok(ReadinessResult::Failed(format!(
                "{}: {detail}",
                reason.as_str()
            )));
        }

        if check_readiness(&obj, kind) {
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
/// the CR as the `kix.dev/readiness` annotation (JSON: `{"path": "/status/...",
/// "equals": "<value>"}`). The CR is ready when the string at `path` equals
/// `equals`.
struct DeclaredReadiness {
    path: String,
    equals: String,
}

/// Parse the `kix.dev/readiness` annotation, if present and well-formed.
/// Malformed declarations are ignored (fall through to kind-based checks)
/// rather than treated as never-ready: the annotation is kix-authored, and a
/// shape mismatch means a version skew between the CLI and the library, not
/// an unhealthy resource.
///
/// Be honest about what the fallthrough means for a CR with NO annotation
/// (manifests built by a pre-declaration library): check_generic_ready
/// treats a status-less CR as READY, so a freshly-created CR races its
/// operator instead of waiting — strictly worse than a timeout. The
/// information simply isn't in old manifests; rebuild them with a library
/// that stamps the annotation. (Old CLI + new manifests is safe: the
/// annotation is inert there.)
fn declared_readiness(obj: &DynamicObject) -> Option<DeclaredReadiness> {
    let raw = obj
        .metadata
        .annotations
        .as_ref()?
        .get("kix.dev/readiness")?;
    let v: Value = serde_json::from_str(raw).ok()?;
    Some(DeclaredReadiness {
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

    // A CRD-owning package can declare its kinds' readiness convention on
    // the CRD builder (readiness = { path; equals; }); kix stamps it on
    // every CR built through the typed chain as the `kix.dev/readiness`
    // annotation. Honoring it here keeps controller vocabulary out of the
    // CLI: the VictoriaMetrics operator's status.updateStatus ==
    // "operational" convention (15 kinds) used to be a hardcoded list in
    // this match. The SGCluster / Gateway arms below predate the
    // annotation and are candidates to migrate when their packages gain
    // typed CRD builders.
    if let Some(rule) = declared_readiness(obj) {
        return obj
            .data
            .pointer(&rule.path)
            .and_then(Value::as_str)
            .is_some_and(|v| v == rule.equals);
    }

    match kind {
        "Deployment" | "StatefulSet" => check_deployment_ready(obj.metadata.generation, &obj.data),
        "DaemonSet" => check_daemonset_ready(obj.metadata.generation, &obj.data),
        "Job" => check_job_ready(&obj.data),
        "PersistentVolumeClaim" => check_pvc_ready(&obj.data),
        "CustomResourceDefinition" => check_crd_ready(&obj.data),
        "CiliumNetworkPolicy" | "CiliumClusterwideNetworkPolicy" => {
            has_condition(&obj.data, "Valid", "True")
        }
        // StackGres clusters never surface a Ready/Available condition;
        // they report Bootstrapped=True once the primary is initialized
        // and accepting connections — which is exactly what dependents
        // (stackgres-database bootstrap jobs) need. Without this they fall
        // through to check_generic_ready, which waits forever for a
        // Ready/Available=True that never comes, times out, and cancels
        // everything downstream (e.g. the whole immich stack).
        "SGCluster" | "SGShardedCluster" => has_condition(&obj.data, "Bootstrapped", "True"),
        // Gateway API kinds use their own condition vocabulary, not
        // Ready/Available: a GatewayClass is usable once Accepted=True, a
        // Gateway once Programmed=True. Without these they fall through to
        // check_generic_ready and time out.
        "GatewayClass" => has_condition(&obj.data, "Accepted", "True"),
        "Gateway" => has_condition(&obj.data, "Programmed", "True"),
        _ => check_generic_ready(&obj.data),
    }
}

/// Deployment/StatefulSet: readyReplicas == spec.replicas && updatedReplicas == spec.replicas
/// && observedGeneration >= generation
fn check_deployment_ready(generation: Option<i64>, data: &Value) -> bool {
    // `generation` comes from the TYPED ObjectMeta: kube-rs's DynamicObject
    // consumes the `metadata` key into its named field, so
    // data.pointer("/metadata/...") is ALWAYS None on live objects — the
    // original guard read it from there and was dead code in production
    // (first-poll readiness on a stale previous-generation status).
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
/// && observedGeneration >= generation
fn check_daemonset_ready(generation: Option<i64>, data: &Value) -> bool {
    // Typed-metadata generation — see check_deployment_ready.
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
    let updated = data
        .pointer("/status/updatedNumberScheduled")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    desired > 0 && ready >= desired && updated >= desired
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
    // No conditions at all — treat as immediate
    true
}

/// Check if a specific condition type has a given status.
fn has_condition(data: &Value, condition_type: &str, expected_status: &str) -> bool {
    data.pointer("/status/conditions")
        .and_then(Value::as_array)
        .is_some_and(|conditions| {
            conditions.iter().any(|c| {
                let ctype = c.get("type").and_then(Value::as_str).unwrap_or("");
                let status = c.get("status").and_then(Value::as_str).unwrap_or("");
                ctype == condition_type && status == expected_status
            })
        })
}

/// Build a human-readable message about why a resource isn't ready.
fn readiness_message(obj: &DynamicObject, kind: &str) -> String {
    let name = obj.metadata.name.as_deref().unwrap_or("unknown");
    if let Some(rule) = declared_readiness(obj) {
        // Render the truth about what sits at the path: a present but
        // non-string value silently never matches (comparison is string
        // equality), and calling it "<absent>" sent operators hunting for
        // a field that exists.
        let current = match obj.data.pointer(&rule.path) {
            None => "<absent>".to_string(),
            Some(Value::String(v)) => format!("\"{v}\""),
            Some(other) => format!("{other} (non-string; declared readiness compares strings)"),
        };
        return format!(
            "{kind}/{name}: declared readiness {}=\"{}\", currently {current}",
            rule.path, rule.equals
        );
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
        "CiliumNetworkPolicy" | "CiliumClusterwideNetworkPolicy" => {
            let reason = obj
                .data
                .pointer("/status/conditions")
                .and_then(Value::as_array)
                .and_then(|conds| {
                    conds.iter().find_map(|c| {
                        let ctype = c.get("type").and_then(Value::as_str)?;
                        if ctype == "Valid" {
                            c.get("message").and_then(Value::as_str)
                        } else {
                            None
                        }
                    })
                })
                .unwrap_or("no Valid=True condition");
            format!("{kind}/{name}: {reason}")
        }
        _ => {
            // For a generic CR the usual stall is a condition-vocabulary
            // mismatch: the controller stamps conditions, but none named
            // Ready/Available (stage1's VMServiceScrape stamped only
            // "<consumer>/Applied" and timed out silently). Name what we
            // saw so the fix — a kind-specific rule in check_readiness —
            // is obvious from the failure message alone.
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
                        "{kind}/{name}: no Ready/Available condition; controller reports [{seen}] — ",
                        "if this vocabulary is healthy for this kind, declare its readiness ",
                        "convention on the owning package's CRD builder (readiness = {{ path; ",
                        "equals; }}, stamped as the kix.dev/readiness annotation) or add a ",
                        "rule in check_readiness"
                    ),
                    kind = kind,
                    name = name,
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

    /// Like make_obj but with metadata.generation set on the TYPED
    /// ObjectMeta — the shape live objects actually have. Stuffing a
    /// "metadata" key inside `data` tests a shape the apiserver never
    /// produces (kube-rs consumes it into the named field) and is how the
    /// dead generation guard stayed green for so long.
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

    /// Like make_obj but with a kix.dev/readiness annotation, mirroring what
    /// the nix typed CRD chain stamps on every CR.
    fn make_annotated_obj(annotation: &str, data: Value) -> DynamicObject {
        let mut annotations = std::collections::BTreeMap::new();
        annotations.insert("kix.dev/readiness".to_string(), annotation.to_string());
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
        let rule = declared_readiness(&obj).expect("should parse");
        assert_eq!(rule.path, "/status/updateStatus");
        assert_eq!(rule.equals, "operational");
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

    #[test]
    fn declared_readiness_beats_kind_rules() {
        // SGCluster has a hardcoded Bootstrapped-condition arm; a declared
        // rule must take precedence over it.
        let obj = make_annotated_obj(
            VM_RULE,
            json!({"status": {
                "updateStatus": "operational",
                "conditions": [{"type": "Bootstrapped", "status": "False"}]
            }}),
        );
        assert!(check_readiness(&obj, "SGCluster"));
    }

    #[test]
    fn malformed_annotation_falls_through_to_kind_rules() {
        // Deliberate design: version skew is not unhealthiness. A CR whose
        // annotation is garbage falls to check_generic_ready — which treats
        // an empty status as READY (documented on declared_readiness).
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
    fn cilium_network_policy_valid() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Valid", "status": "True", "message": "Policy validation succeeded"},
                ]
            }
        }));
        assert!(check_readiness(&obj, "CiliumNetworkPolicy"));
        assert!(check_readiness(&obj, "CiliumClusterwideNetworkPolicy"));
    }

    #[test]
    fn cilium_network_policy_invalid() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Valid", "status": "False", "message": "bad selector"},
                ]
            }
        }));
        assert!(!check_readiness(&obj, "CiliumNetworkPolicy"));
    }

    #[test]
    fn cilium_network_policy_missing_status() {
        // Freshly created CNP before cilium-operator has set status.
        let obj = make_obj(json!({}));
        assert!(!check_readiness(&obj, "CiliumNetworkPolicy"));
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
    fn import_marker_parsed() {
        let manifest = json!({
            "apiVersion": "kix.dev/v1alpha1",
            "kind": "PackageInstance",
            "metadata": {
                "name": "crd-ref-sgclusters-stackgres-io",
                "namespace": "data",
                "annotations": {
                    "kix.dev/mode": "import",
                    "kix.dev/import-kind": "CustomResourceDefinition",
                    "kix.dev/import-apiversion": "apiextensions.k8s.io/v1",
                    "kix.dev/import-name": "sgclusters.stackgres.io",
                }
            }
        });
        let target = import_target_from_manifest(&manifest).expect("should parse");
        assert_eq!(target.kind, "CustomResourceDefinition");
        assert_eq!(target.api_version, "apiextensions.k8s.io/v1");
        assert_eq!(target.name, "sgclusters.stackgres.io");
        // CRDs are cluster-scoped — namespace is always None regardless of
        // the marker's own metadata.namespace.
        assert_eq!(target.namespace, None);
        assert!(target.expected_keys.is_empty());
    }

    #[test]
    fn secret_import_marker_inherits_marker_namespace() {
        // Namespaced imports take their namespace from the marker's own
        // metadata.namespace, not from any annotation.
        let manifest = json!({
            "apiVersion": "kix.dev/v1alpha1",
            "kind": "PackageInstance",
            "metadata": {
                "name": "secret-ref-myapp-db-creds",
                "namespace": "myapp",
                "annotations": {
                    "kix.dev/mode": "import",
                    "kix.dev/import-kind": "Secret",
                    "kix.dev/import-apiversion": "v1",
                    "kix.dev/import-name": "db-creds",
                    "kix.dev/import-secret-keys": "username,password",
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
                    "kix.dev/mode": "import",
                    "kix.dev/import-kind": "Secret",
                    "kix.dev/import-apiversion": "v1",
                    "kix.dev/import-name": "bootstrap",
                }
            }
        });
        let target = import_target_from_manifest(&manifest).expect("should parse");
        assert!(target.expected_keys.is_empty());
    }

    #[test]
    fn import_marker_non_import_mode_ignored() {
        let manifest = json!({
            "kind": "PackageInstance",
            "metadata": {
                "annotations": { "kix.dev/mode": "normal" }
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
                    "kix.dev/mode": "import",
                    "kix.dev/import-kind": "Secret",
                    "kix.dev/import-apiversion": "v1",
                    "kix.dev/import-name": "foo",
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
