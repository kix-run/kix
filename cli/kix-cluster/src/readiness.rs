//! Readiness polling for K8s resources.
//!
//! Per-kind readiness checks with `observedGeneration` guards for workloads.
//! Used by `kix deploy` to wait for resources to become ready after apply.

use std::time::{Duration, Instant};

use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

/// Default timeout for readiness polling.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);

/// Default interval between readiness polls.
const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Errors from readiness polling.
#[derive(Error, Debug)]
pub enum ReadinessError {
    #[error("failed to fetch resource for readiness check: {0}")]
    FetchError(#[source] kube::Error),
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
}

/// Wait for a resource to become ready, polling until timeout.
///
/// Checks readiness immediately, then polls every 2 seconds.
/// Returns `Ready` as soon as the condition is met, or `TimedOut`
/// if the timeout elapses.
pub async fn wait_for_ready(
    client: &Client,
    ar: &ApiResource,
    scope: &Scope,
    name: &str,
    namespace: Option<&str>,
    kind: &str,
    timeout: Duration,
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

        if check_readiness(&obj, kind) {
            return Ok(ReadinessResult::Ready);
        }

        let elapsed = start.elapsed();
        if elapsed >= timeout {
            let message = readiness_message(&obj, kind);
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

    // --- Immediate kinds ---

    #[test]
    fn configmap_immediate() {
        let obj = make_obj(json!({}));
        assert!(check_readiness(&obj, "ConfigMap"));
    }

    #[test]
    fn secret_immediate() {
        let obj = make_obj(json!({}));
        assert!(check_readiness(&obj, "Secret"));
    }

    #[test]
    fn service_immediate() {
        let obj = make_obj(json!({}));
        assert!(check_readiness(&obj, "Service"));
    }

    #[test]
    fn namespace_immediate() {
        let obj = make_obj(json!({}));
        assert!(check_readiness(&obj, "Namespace"));
    }

    #[test]
    fn serviceaccount_immediate() {
        let obj = make_obj(json!({}));
        assert!(check_readiness(&obj, "ServiceAccount"));
    }

    #[test]
    fn clusterrole_immediate() {
        let obj = make_obj(json!({}));
        assert!(check_readiness(&obj, "ClusterRole"));
    }

    // --- Deployment ---

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
    fn deployment_not_ready_generation() {
        let obj = make_obj(json!({
            "metadata": {"generation": 3},
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 2,
                "readyReplicas": 3,
                "updatedReplicas": 3,
            }
        }));
        assert!(!check_readiness(&obj, "Deployment"));
    }

    #[test]
    fn deployment_not_ready_updated() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 3,
                "updatedReplicas": 2,
            }
        }));
        assert!(!check_readiness(&obj, "Deployment"));
    }

    #[test]
    fn deployment_no_status() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "spec": {"replicas": 1},
        }));
        assert!(!check_readiness(&obj, "Deployment"));
    }

    // --- StatefulSet ---

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
    fn statefulset_not_ready() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "spec": {"replicas": 2},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 1,
                "updatedReplicas": 2,
            }
        }));
        assert!(!check_readiness(&obj, "StatefulSet"));
    }

    // --- DaemonSet ---

    #[test]
    fn daemonset_ready() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "status": {
                "observedGeneration": 1,
                "desiredNumberScheduled": 3,
                "numberReady": 3,
                "updatedNumberScheduled": 3,
            }
        }));
        assert!(check_readiness(&obj, "DaemonSet"));
    }

    #[test]
    fn daemonset_not_ready() {
        let obj = make_obj(json!({
            "metadata": {"generation": 1},
            "status": {
                "observedGeneration": 1,
                "desiredNumberScheduled": 3,
                "numberReady": 2,
                "updatedNumberScheduled": 3,
            }
        }));
        assert!(!check_readiness(&obj, "DaemonSet"));
    }

    #[test]
    fn daemonset_stale_generation() {
        let obj = make_obj(json!({
            "metadata": {"generation": 2},
            "status": {
                "observedGeneration": 1,
                "desiredNumberScheduled": 3,
                "numberReady": 3,
                "updatedNumberScheduled": 3,
            }
        }));
        assert!(!check_readiness(&obj, "DaemonSet"));
    }

    // --- Job ---

    #[test]
    fn job_completed() {
        let obj = make_obj(json!({
            "status": {"succeeded": 1}
        }));
        assert!(check_readiness(&obj, "Job"));
    }

    #[test]
    fn job_not_completed() {
        let obj = make_obj(json!({
            "status": {"succeeded": 0, "active": 1}
        }));
        assert!(!check_readiness(&obj, "Job"));
    }

    #[test]
    fn job_no_status() {
        let obj = make_obj(json!({}));
        assert!(!check_readiness(&obj, "Job"));
    }

    // --- PVC ---

    #[test]
    fn pvc_bound() {
        let obj = make_obj(json!({
            "status": {"phase": "Bound"}
        }));
        assert!(check_readiness(&obj, "PersistentVolumeClaim"));
    }

    #[test]
    fn pvc_pending() {
        let obj = make_obj(json!({
            "status": {"phase": "Pending"}
        }));
        assert!(!check_readiness(&obj, "PersistentVolumeClaim"));
    }

    // --- CRD ---

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
    fn crd_no_conditions() {
        let obj = make_obj(json!({
            "status": {}
        }));
        assert!(!check_readiness(&obj, "CustomResourceDefinition"));
    }

    // --- Generic CR ---

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

    #[test]
    fn generic_cr_available() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Available", "status": "True"}
                ]
            }
        }));
        assert!(check_readiness(&obj, "SomeCustomResource"));
    }

    #[test]
    fn generic_cr_not_ready() {
        let obj = make_obj(json!({
            "status": {
                "conditions": [
                    {"type": "Ready", "status": "False"}
                ]
            }
        }));
        assert!(!check_readiness(&obj, "SomeCustomResource"));
    }

    #[test]
    fn generic_cr_no_conditions() {
        // No status.conditions at all — treat as immediate
        let obj = make_obj(json!({"spec": {}}));
        assert!(check_readiness(&obj, "SomeCustomResource"));
    }

    #[test]
    fn generic_cr_empty_conditions() {
        let obj = make_obj(json!({
            "status": {"conditions": []}
        }));
        assert!(check_readiness(&obj, "SomeCustomResource"));
    }

    // --- Readiness message ---

    #[test]
    fn message_deployment() {
        let obj = make_obj(json!({
            "spec": {"replicas": 3},
            "status": {"readyReplicas": 1, "updatedReplicas": 2}
        }));
        let msg = readiness_message(&obj, "Deployment");
        assert!(msg.contains("1/3 ready"));
        assert!(msg.contains("2/3 updated"));
    }

    #[test]
    fn message_job() {
        let obj = make_obj(json!({
            "status": {"succeeded": 0}
        }));
        let msg = readiness_message(&obj, "Job");
        assert!(msg.contains("0 succeeded"));
    }

    #[test]
    fn message_pvc() {
        let obj = make_obj(json!({
            "status": {"phase": "Pending"}
        }));
        let msg = readiness_message(&obj, "PersistentVolumeClaim");
        assert!(msg.contains("phase=Pending"));
    }

    // --- is_immediate_kind ---

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
}
