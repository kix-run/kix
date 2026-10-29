//! Declared and kind-specific readiness evaluation.

use kube::{
    api::{Api, DynamicObject},
    client::Client,
};
use serde_json::Value;

use crate::manifest::keys;

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

/// Readiness convention declared by the CRD-owning package and stamped on the
/// CR in the `kix.run/readiness` annotation.
///
/// Supports three JSON shapes:
/// * `{"path": "/status/...", "equals": "<value>"}` is ready when the string,
///   boolean, or number at `path` formats to `equals` (`true` matches `"true"`,
///   `3` matches `"3"`, and `1.0` matches `"1.0"`), and
///   `status.observedGeneration` (when present) has reached
///   `metadata.generation`.
/// * `{"path": "/status/...", "notEquals": "<value>"}` is ready when the value
///   at `path` is absent or does not match `notEquals` under the same
///   generation guard. This is used when status is written only by a consumer
///   that may not exist.
/// * `{"condition": {"type": "<Type>", "status": "True"}}` is ready when
///   `status.conditions` contains a matching entry whose `observedGeneration`
///   (or `status.observedGeneration` if the condition omits its own) has
///   reached `metadata.generation`. If neither generation field is present, no
///   generation guard applies.
pub(super) enum DeclaredReadiness {
    Path {
        path: String,
        equals: String,
    },
    PathNot {
        path: String,
        not_equals: String,
    },
    Condition {
        condition_type: String,
        status: String,
    },
}

/// Parse a well-formed `kix.run/readiness` annotation.
///
/// Ignore malformed annotations and fall back to kind-based readiness so
/// manifests produced by a different library version still work. A custom
/// resource with no recognized readiness rule uses `check_generic_ready`, which
/// treats an empty status as ready.
pub(super) fn declared_readiness(obj: &DynamicObject) -> Option<DeclaredReadiness> {
    let raw = keys::get_meta(obj.metadata.annotations.as_ref()?, keys::READINESS)?;
    let v: Value = serde_json::from_str(raw).ok()?;
    if let Some(condition) = v.get("condition") {
        return Some(DeclaredReadiness::Condition {
            condition_type: condition.get("type")?.as_str()?.to_string(),
            status: condition.get("status")?.as_str()?.to_string(),
        });
    }
    let path = v.get("path")?.as_str()?.to_string();
    if let Some(not_equals) = v.get("notEquals") {
        return Some(DeclaredReadiness::PathNot {
            path,
            not_equals: not_equals.as_str()?.to_string(),
        });
    }
    Some(DeclaredReadiness::Path {
        path,
        equals: v.get("equals")?.as_str()?.to_string(),
    })
}

/// Format a scalar JSON status value (string, boolean, or number) as text for
/// readiness comparison, returning `None` for non-scalar JSON values.
fn scalar_text(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(s.clone()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// Check whether a single resource is ready based on its kind or declared
/// readiness rule.
pub fn check_readiness(obj: &DynamicObject, kind: &str) -> bool {
    if is_immediate_kind(kind) {
        return true;
    }

    // A CRD-owning package declares its kinds' readiness convention on the CRD
    // builder, and Kix stamps it on every CR built through the typed chain as
    // the `kix.run/readiness` annotation. The match below covers only kinds
    // whose readiness the Kubernetes API defines directly.
    if let Some(rule) = declared_readiness(obj) {
        return match rule {
            DeclaredReadiness::Path { path, equals } => {
                generation_observed(
                    obj.metadata.generation,
                    obj.data.pointer("/status/observedGeneration"),
                ) && obj
                    .data
                    .pointer(&path)
                    .and_then(scalar_text)
                    .is_some_and(|t| t == equals)
            }
            DeclaredReadiness::PathNot { path, not_equals } => {
                generation_observed(
                    obj.metadata.generation,
                    obj.data.pointer("/status/observedGeneration"),
                ) && obj
                    .data
                    .pointer(&path)
                    .and_then(scalar_text)
                    .is_none_or(|t| t != not_equals)
            }
            DeclaredReadiness::Condition {
                condition_type,
                status,
            } => find_condition(&obj.data, &condition_type).is_some_and(|c| {
                c.get("status").and_then(Value::as_str) == Some(status.as_str())
                    && generation_observed(
                        obj.metadata.generation,
                        condition_observed_generation(&obj.data, c),
                    )
            }),
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

/// Return `true` if a Deployment or StatefulSet has `observedGeneration >=
/// generation` and both `readyReplicas` and `updatedReplicas` have reached
/// `spec.replicas`.
fn check_deployment_ready(generation: Option<i64>, data: &Value) -> bool {
    // kube-rs stores generation in DynamicObject.metadata outside `data`.
    // Compare observedGeneration with this typed metadata field to reject
    // status left over from a previous generation.
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

/// Return `true` if a DaemonSet has `observedGeneration >= generation` and its
/// scheduled pods are ready and updated.
///
/// For an `OnDelete` DaemonSet, `updatedNumberScheduled` is not required
/// because the controller replaces pods only when they are deleted manually;
/// [`daemonset_pending_restart`] reports how many pods still use the previous
/// template.
///
/// A DaemonSet whose node selector matches no nodes has
/// `desiredNumberScheduled: 0` once observed by the controller and is
/// considered complete. The `observedGeneration` check prevents a newly created
/// DaemonSet with no status from passing before the controller observes it.
fn check_daemonset_ready(generation: Option<i64>, data: &Value) -> bool {
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

/// Return the number of pods in an `OnDelete` DaemonSet that still run a
/// previous pod template, or `None` when all pods are updated or the DaemonSet
/// uses `RollingUpdate`.
pub(crate) fn daemonset_pending_restart(data: &Value) -> Option<i64> {
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

/// Return `true` if a Job has `status.succeeded >= 1`.
pub(super) fn check_job_ready(data: &Value) -> bool {
    let succeeded = data
        .pointer("/status/succeeded")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    succeeded >= 1
}

/// Return `true` if the named StorageClass uses `WaitForFirstConsumer` binding mode.
pub(super) async fn is_wait_for_first_consumer(client: &Client, sc_name: &str) -> bool {
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

/// Return `true` if a PersistentVolumeClaim has `status.phase == "Bound"`.
fn check_pvc_ready(data: &Value) -> bool {
    data.pointer("/status/phase")
        .and_then(Value::as_str)
        .is_some_and(|p| p == "Bound")
}

/// Return `true` if a CustomResourceDefinition has condition `Established=True`.
pub(super) fn check_crd_ready(data: &Value) -> bool {
    has_condition(data, "Established", "True")
}

/// Return the version names in a CRD's `spec.versions` that have `served: true`.
pub(super) fn served_crd_versions(data: &Value) -> Vec<String> {
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

/// Return the entries in `wanted` that the CRD does not serve, preserving the
/// order in `wanted`.
pub(super) fn unserved_crd_versions(data: &Value, wanted: &[String]) -> Vec<String> {
    let served = served_crd_versions(data);
    wanted
        .iter()
        .filter(|v| !served.contains(v))
        .cloned()
        .collect()
}

/// Check `.status.conditions` for `Ready=True` or `Available=True` on a generic
/// custom resource, treating an absent or empty conditions list as ready.
fn check_generic_ready(data: &Value) -> bool {
    if let Some(conditions) = data.pointer("/status/conditions").and_then(Value::as_array) {
        if conditions.is_empty() {
            return true;
        }
        let has_ready = conditions.iter().any(|c| {
            let ctype = c.get("type").and_then(Value::as_str).unwrap_or("");
            let status = c.get("status").and_then(Value::as_str).unwrap_or("");
            (ctype == "Ready" || ctype == "Available") && status == "True"
        });
        return has_ready;
    }
    true
}

/// Return the entry in `status.conditions` whose `type` matches `condition_type`.
fn find_condition<'a>(data: &'a Value, condition_type: &str) -> Option<&'a Value> {
    data.pointer("/status/conditions")?
        .as_array()?
        .iter()
        .find(|c| c.get("type").and_then(Value::as_str) == Some(condition_type))
}

/// Return `true` if `observed` has reached the object's `metadata.generation`,
/// or if either value is absent.
fn generation_observed(generation: Option<i64>, observed: Option<&Value>) -> bool {
    match (generation, observed.and_then(Value::as_i64)) {
        (Some(generation), Some(observed)) => observed >= generation,
        _ => true,
    }
}

/// Return the generation a condition describes: its own `observedGeneration`,
/// or `status.observedGeneration` when the operator stamps only the top-level
/// status.
fn condition_observed_generation<'a>(data: &'a Value, condition: &'a Value) -> Option<&'a Value> {
    condition
        .get("observedGeneration")
        .or_else(|| data.pointer("/status/observedGeneration"))
}

/// Format the suffix appended to a readiness message when `observed` predates
/// `generation`.
fn stale_note(generation: Option<i64>, observed: Option<&Value>) -> String {
    match (generation, observed.and_then(Value::as_i64)) {
        (Some(generation), Some(observed)) if observed < generation => {
            format!(", observed generation {observed} of {generation}")
        }
        _ => String::new(),
    }
}

fn has_condition(data: &Value, condition_type: &str, expected_status: &str) -> bool {
    find_condition(data, condition_type)
        .and_then(|c| c.get("status"))
        .and_then(Value::as_str)
        == Some(expected_status)
}

/// Build a human-readable message about why a resource isn't ready.
pub(super) fn readiness_message(obj: &DynamicObject, kind: &str) -> String {
    let name = obj.metadata.name.as_deref().unwrap_or("unknown");
    if let Some(rule) = declared_readiness(obj) {
        return match rule {
            DeclaredReadiness::Path { path, equals } => {
                // Distinguish an absent path from a value of a type declared
                // readiness does not compare (null, objects, lists).
                let current = match obj.data.pointer(&path) {
                    None => "<absent>".to_string(),
                    Some(Value::String(v)) => format!("\"{v}\""),
                    Some(v @ (Value::Bool(_) | Value::Number(_))) => v.to_string(),
                    Some(other) => {
                        format!(
                            "{other} (declared readiness compares only strings, booleans, and numbers)"
                        )
                    }
                };
                let stale = stale_note(
                    obj.metadata.generation,
                    obj.data.pointer("/status/observedGeneration"),
                );
                format!(
                    "{kind}/{name}: declared readiness {path}=\"{equals}\", currently {current}{stale}"
                )
            }
            DeclaredReadiness::PathNot { path, not_equals } => {
                let current = match obj.data.pointer(&path) {
                    None => "<absent>".to_string(),
                    Some(v) => v.to_string(),
                };
                let stale = stale_note(
                    obj.metadata.generation,
                    obj.data.pointer("/status/observedGeneration"),
                );
                format!(
                    "{kind}/{name}: declared readiness {path}!=\"{not_equals}\", currently {current}{stale}"
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
                        let stale = stale_note(
                            obj.metadata.generation,
                            condition_observed_generation(&obj.data, c),
                        );
                        match c.get("message").and_then(Value::as_str) {
                            Some(msg) if !msg.is_empty() => {
                                format!("{condition_type}={actual} ({msg}){stale}")
                            }
                            _ => format!("{condition_type}={actual}{stale}"),
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
