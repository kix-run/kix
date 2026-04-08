//! Readiness polling for K8s resources.
//!
//! Per-kind readiness checks with `observedGeneration` guards for workloads.
//! Used by `kix deploy` to wait for resources to become ready after apply.
//!
//! Also handles "import marker" PackageInstance resources whose readiness is
//! defined as "the described external resource exists on the cluster". Used to
//! gate waves on CRDs installed out-of-band by operators (e.g. stackgres
//! `INSTALL_CRDS=true`). See [`ImportTarget`] and [`wait_for_import_target`].

use std::time::{Duration, Instant};

use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

/// A resource described by an import marker. The CLI polls the cluster for
/// this resource and blocks the wave until it's present (and, for CRDs, also
/// `Established=True`; for Secrets with `expected_keys`, also verifies every
/// key is present in `data`).
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
    let kind = manifest.get("kind").and_then(Value::as_str)?;
    if kind != "PackageInstance" {
        return None;
    }
    let annotations = manifest.pointer("/metadata/annotations")?;
    let mode = annotations.get("kix.dev/mode").and_then(Value::as_str)?;
    if mode != "import" {
        return None;
    }

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

/// Poll the cluster for the described [`ImportTarget`] until it exists (and,
/// for CRDs, is `Established=True`; for Secrets with declared `expected_keys`,
/// also verifies every key is present in `data`), or the timeout elapses.
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
        let status_msg: String = match api.get_opt(&target.name).await {
            Ok(Some(obj)) => {
                // For CRDs, also wait for Established=True so the kind is
                // actually serving requests before we advance the wave.
                if target.kind == "CustomResourceDefinition" {
                    if check_crd_ready(&obj.data) {
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
                } else {
                    return Ok(ReadinessResult::Ready);
                }
            }
            Ok(None) => "not found yet".into(),
            Err(kube::Error::Api(resp)) if resp.code == 404 => "not found yet".into(),
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
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);

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

/// Result of a readiness check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadinessResult {
    /// Resource is ready.
    Ready,
    /// Timed out waiting for readiness.
    TimedOut { elapsed: Duration, message: String },
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

/// Wait for a resource to become ready, polling until timeout.
///
/// Checks readiness immediately, then polls every 2 seconds.
/// Returns `Ready` as soon as the condition is met, or `TimedOut`
/// if the timeout elapses.
#[allow(clippy::too_many_arguments)]
pub async fn wait_for_ready(
    client: &Client,
    ar: &ApiResource,
    scope: &Scope,
    name: &str,
    namespace: Option<&str>,
    kind: &str,
    timeout: Duration,
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

    let start = Instant::now();

    loop {
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

        if check_readiness(&obj, kind) {
            return Ok(ReadinessResult::Ready);
        }

        let message = readiness_message(&obj, kind);
        on_status(&message);

        let elapsed = start.elapsed();
        if elapsed >= timeout {
            return Ok(ReadinessResult::TimedOut { elapsed, message });
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
            | "PackageInstance"
            | "Activation"
            | "StorageClass"
    )
}

/// Synchronous readiness check for a single resource.
///
/// Returns `true` if the resource is considered ready based on its kind.
pub fn check_readiness(obj: &DynamicObject, kind: &str) -> bool {
    if is_immediate_kind(kind) {
        return true;
    }

    match kind {
        "Deployment" | "StatefulSet" => check_deployment_ready(&obj.data),
        "DaemonSet" => check_daemonset_ready(&obj.data),
        "Job" => check_job_ready(&obj.data),
        "PersistentVolumeClaim" => check_pvc_ready(&obj.data),
        "CustomResourceDefinition" => check_crd_ready(&obj.data),
        _ => check_generic_ready(&obj.data),
    }
}

/// Deployment/StatefulSet: readyReplicas == spec.replicas && updatedReplicas == spec.replicas
/// && observedGeneration >= generation
fn check_deployment_ready(data: &Value) -> bool {
    let generation = data
        .pointer("/metadata/generation")
        .and_then(Value::as_i64)
        .unwrap_or(0);
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
fn check_daemonset_ready(data: &Value) -> bool {
    let generation = data
        .pointer("/metadata/generation")
        .and_then(Value::as_i64)
        .unwrap_or(0);
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
        _ => format!("{kind}/{name}: not ready"),
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
        let obj = make_obj(json!({
            "metadata": {"generation": 2},
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 2,
                "readyReplicas": 3,
                "updatedReplicas": 3,
            }
        }));
        assert!(check_readiness(&obj, "Deployment"));
    }

    #[test]
    fn deployment_not_ready_replicas() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 2,
                "updatedReplicas": 3,
            }
        }));
        assert!(!check_readiness(&obj, "Deployment"));
    }

    #[test]
    fn statefulset_ready() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "spec": {"replicas": 2},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 2,
                "updatedReplicas": 2,
            }
        }));
        assert!(check_readiness(&obj, "StatefulSet"));
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
}
