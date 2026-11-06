//! Declared and kind-specific readiness evaluation.

use chrono::{DateTime, Utc};
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
/// CR in the `kix.run/readiness` annotation: the rule that means ready, and
/// the states that mean the resource will not become ready until its spec
/// changes.
///
/// The JSON carries the ready rule at the top level, in one of the
/// [`ReadyRule`] shapes, and an optional `"failed"` list of [`FailedRule`]
/// entries: `{"condition": {"type": "Valid", "status": "False", "reason":
/// "<optional>"}}` or `{"path": "/status/phase", "equals": "Failed"}`.
/// Annotations written before the `failed` key existed parse with an empty
/// list, and an older CLI reads only the ready rule.
pub(super) struct DeclaredReadiness {
    pub ready: ReadyRule,
    pub failed: Vec<FailedRule>,
}

/// The rule that means a custom resource is ready.
///
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
pub(super) enum ReadyRule {
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

/// A state the controller does not leave on its own. A condition entry
/// matches on type and status, and on reason when one is declared; a path
/// entry matches the scalar at `path` by its text, as [`ReadyRule::Path`]
/// does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum FailedRule {
    Condition {
        condition_type: String,
        status: String,
        reason: Option<String>,
    },
    Path {
        path: String,
        equals: String,
        /// The state is the controller's verdict on the spec, so the message
        /// says to change the object. Otherwise it is a runtime outcome (a
        /// failed backup, a lost claim) and the message carries `hint`.
        rejected: bool,
        /// What to do next, written by the package.
        hint: Option<String>,
        /// JSON pointers whose values the message quotes.
        message: Vec<String>,
    },
}

/// Parse a well-formed `kix.run/readiness` annotation.
///
/// Ignore malformed annotations and fall back to kind-based readiness so
/// manifests produced by a different library version still work. A custom
/// resource with no recognized readiness rule uses `check_generic_ready`, which
/// treats an empty status as ready. A `failed` entry that does not parse is
/// dropped on its own, so a shape this CLI does not know can only make the
/// deploy wait longer, never fail it.
pub(super) fn declared_readiness(obj: &DynamicObject) -> Option<DeclaredReadiness> {
    let raw = keys::get_meta(obj.metadata.annotations.as_ref()?, keys::READINESS)?;
    let v: Value = serde_json::from_str(raw).ok()?;
    let ready = parse_ready_rule(&v)?;
    let failed = v
        .get("failed")
        .and_then(Value::as_array)
        .map(|entries| entries.iter().filter_map(parse_failed_rule).collect())
        .unwrap_or_default();
    Some(DeclaredReadiness { ready, failed })
}

fn parse_ready_rule(v: &Value) -> Option<ReadyRule> {
    if let Some(condition) = v.get("condition") {
        return Some(ReadyRule::Condition {
            condition_type: condition.get("type")?.as_str()?.to_string(),
            status: condition.get("status")?.as_str()?.to_string(),
        });
    }
    let path = v.get("path")?.as_str()?.to_string();
    if let Some(not_equals) = v.get("notEquals") {
        return Some(ReadyRule::PathNot {
            path,
            not_equals: not_equals.as_str()?.to_string(),
        });
    }
    Some(ReadyRule::Path {
        path,
        equals: v.get("equals")?.as_str()?.to_string(),
    })
}

fn parse_failed_rule(v: &Value) -> Option<FailedRule> {
    if let Some(condition) = v.get("condition") {
        let reason = match condition.get("reason") {
            None | Some(Value::Null) => None,
            Some(reason) => Some(reason.as_str()?.to_string()),
        };
        return Some(FailedRule::Condition {
            condition_type: condition.get("type")?.as_str()?.to_string(),
            status: condition.get("status")?.as_str()?.to_string(),
            reason,
        });
    }
    let message = match v.get("message") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::String(pointer)) => vec![pointer.clone()],
        Some(Value::Array(pointers)) => pointers
            .iter()
            .map(|p| p.as_str().map(str::to_string))
            .collect::<Option<Vec<_>>>()?,
        Some(_) => return None,
    };
    Some(FailedRule::Path {
        path: v.get("path")?.as_str()?.to_string(),
        equals: v.get("equals")?.as_str()?.to_string(),
        rejected: v.get("rejected").and_then(Value::as_bool).unwrap_or(false),
        hint: match v.get("hint") {
            None | Some(Value::Null) => None,
            Some(hint) => Some(hint.as_str()?.to_string()),
        },
        message,
    })
}

/// A declared failure state the live object currently reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct DeclaredFailure {
    /// The message `kix deploy` prints when the failure ends the wait.
    pub message: String,
    /// Whether the status that reports the failure is known to describe the
    /// current spec: the condition's `observedGeneration` (or
    /// `status.observedGeneration`) has reached `metadata.generation`, or the
    /// condition's `lastTransitionTime` is later than this deploy's apply of
    /// the object. When the status carries neither, the caller decides after
    /// the failure has held for a grace period, because the status may still
    /// be the controller's verdict on the spec a just-finished apply replaced.
    pub confirmed: bool,
}

/// Return the first declared failure state the object reports for its
/// current spec, or `None`. `applied_at` is when this deploy changed the
/// object, or `None` when it left the object as it was. A match whose status
/// is known to describe an older spec is not reported: its generation is
/// behind `metadata.generation`, or its condition last changed before the
/// apply. The controller has not judged this spec yet.
pub(super) fn declared_failure(
    obj: &DynamicObject,
    kind: &str,
    applied_at: Option<DateTime<Utc>>,
) -> Option<DeclaredFailure> {
    let rules = declared_readiness(obj)?.failed;
    let generation = obj.metadata.generation;
    let data = &obj.data;
    rules.iter().find_map(|rule| match rule {
        FailedRule::Condition {
            condition_type,
            status,
            reason,
        } => {
            let c = find_condition(data, condition_type)?;
            let actual_status = c.get("status").and_then(Value::as_str)?;
            let actual_reason = c.get("reason").and_then(Value::as_str);
            if actual_status != status
                || reason.as_deref().is_some_and(|r| actual_reason != Some(r))
            {
                return None;
            }
            let observed = condition_observed_generation(data, c);
            if !generation_observed(generation, observed) {
                return None;
            }
            let confirmed = if generation_known(generation, observed) {
                true
            } else {
                match (transition_time(c), applied_at) {
                    (Some(transitioned), Some(applied)) if transitioned < applied => return None,
                    (Some(_), _) => true,
                    (None, _) => false,
                }
            };
            let reported = match actual_reason {
                Some(r) if !r.is_empty() => format!("{condition_type}={actual_status} ({r})"),
                _ => format!("{condition_type}={actual_status}"),
            };
            let detail = c
                .get("message")
                .and_then(Value::as_str)
                .filter(|m| !m.is_empty())
                .map(|m| format!(": {}", m.trim_end_matches('.')));
            Some(DeclaredFailure {
                message: rejected_message(kind, &reported, detail.as_deref()),
                confirmed,
            })
        }
        FailedRule::Path {
            path,
            equals,
            rejected,
            hint,
            message,
        } => {
            let text = data.pointer(path).and_then(scalar_text)?;
            if text != *equals {
                return None;
            }
            let observed = data.pointer("/status/observedGeneration");
            if !generation_observed(generation, observed) {
                return None;
            }
            let reported = format!("{}={text}", dotted_path(path));
            let quoted = quoted_status(data, message);
            let message = if *rejected {
                let detail = quoted.map(|q| format!(": {q}"));
                rejected_message(kind, &reported, detail.as_deref())
            } else {
                outcome_message(&reported, quoted.as_deref(), hint.as_deref())
            };
            Some(DeclaredFailure {
                message,
                confirmed: generation_known(generation, observed),
            })
        }
    })
}

/// Return a condition's `lastTransitionTime`, rounded up to the next whole
/// second. Controllers write the field with second precision, so a transition
/// in the same second as the apply counts as after it.
fn transition_time(condition: &Value) -> Option<DateTime<Utc>> {
    let raw = condition.get("lastTransitionTime")?.as_str()?;
    let parsed = DateTime::parse_from_rfc3339(raw).ok()?.with_timezone(&Utc);
    Some(parsed + chrono::Duration::seconds(1))
}

/// Build the message for a state that is the controller's verdict on the
/// spec: what it reported, that it will not fix itself, and that the object
/// has to change.
fn rejected_message(kind: &str, reported: &str, detail: Option<&str>) -> String {
    format!(
        "its controller rejected it with {reported}{}. This will not fix itself, so Kix stopped waiting. Change this {kind} in the package or cluster definition that creates it, then deploy again.",
        detail.unwrap_or_default()
    )
}

/// Build the message for a runtime outcome the controller does not leave on
/// its own, ending with the package's hint or a generic next step.
fn outcome_message(reported: &str, quoted: Option<&str>, hint: Option<&str>) -> String {
    let quoted = quoted.map(|q| format!(" ({q})")).unwrap_or_default();
    let next = hint.unwrap_or("Find the cause in the object's status, fix it, then deploy again.");
    format!(
        "its controller set {reported}{quoted}, a state it does not leave on its own, so Kix stopped waiting. {next}"
    )
}

/// Join the values at the declared `message` pointers: a string as is, a list
/// of strings by "; ", another scalar by its JSON text. Absent or empty values
/// are skipped.
fn quoted_status(data: &Value, pointers: &[String]) -> Option<String> {
    let parts: Vec<String> = pointers
        .iter()
        .filter_map(|p| data.pointer(p))
        .filter_map(|v| match v {
            Value::Array(items) => {
                let texts: Vec<String> = items.iter().filter_map(scalar_text).collect();
                (!texts.is_empty()).then(|| texts.join("; "))
            }
            other => scalar_text(other),
        })
        .map(|t| t.trim_end_matches('.').to_string())
        .filter(|t| !t.is_empty())
        .collect();
    (!parts.is_empty()).then(|| parts.join("; "))
}

/// Render a JSON pointer such as `/status/phase` as `status.phase`.
fn dotted_path(path: &str) -> String {
    path.trim_start_matches('/').replace('/', ".")
}

/// Return `true` when both `metadata.generation` and the observed generation
/// are present, so a comparison between them means something.
fn generation_known(generation: Option<i64>, observed: Option<&Value>) -> bool {
    generation.is_some() && observed.and_then(Value::as_i64).is_some()
}

/// How long a declared failure must hold before it ends the wait on an object
/// whose status carries neither an `observedGeneration` nor a
/// `lastTransitionTime` (a phase field). Right after an apply such a status
/// may still be the controller's verdict on the previous spec.
pub(super) const DECLARED_FAILURE_GRACE: std::time::Duration = std::time::Duration::from_secs(10);

/// Track a declared failure across polls and decide when it is final.
#[derive(Debug, Default)]
pub(super) struct FailureWatch {
    held_since: Option<(String, std::time::Instant)>,
}

impl FailureWatch {
    /// Record what this poll saw and return the failure message once it is
    /// final: at once when `confirmed`, otherwise after the same failure has
    /// held for [`DECLARED_FAILURE_GRACE`]. A poll without the failure, or
    /// with a different one, restarts the grace period.
    pub(super) fn observe(
        &mut self,
        failure: Option<DeclaredFailure>,
        now: std::time::Instant,
    ) -> Option<String> {
        let Some(failure) = failure else {
            self.held_since = None;
            return None;
        };
        if failure.confirmed {
            return Some(failure.message);
        }
        match &self.held_since {
            Some((message, since)) if *message == failure.message => {
                (now.duration_since(*since) >= DECLARED_FAILURE_GRACE).then_some(failure.message)
            }
            _ => {
                self.held_since = Some((failure.message, now));
                None
            }
        }
    }
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
        return match rule.ready {
            ReadyRule::Path { path, equals } => {
                generation_observed(
                    obj.metadata.generation,
                    obj.data.pointer("/status/observedGeneration"),
                ) && obj
                    .data
                    .pointer(&path)
                    .and_then(scalar_text)
                    .is_some_and(|t| t == equals)
            }
            ReadyRule::PathNot { path, not_equals } => {
                generation_observed(
                    obj.metadata.generation,
                    obj.data.pointer("/status/observedGeneration"),
                ) && obj
                    .data
                    .pointer(&path)
                    .and_then(scalar_text)
                    .is_none_or(|t| t != not_equals)
            }
            ReadyRule::Condition {
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
        "Deployment" | "StatefulSet" => {
            check_deployment_ready(obj.metadata.generation, &obj.data, kind == "Deployment")
        }
        "DaemonSet" => check_daemonset_ready(obj.metadata.generation, &obj.data),
        "Job" => check_job_ready(&obj.data),
        "PersistentVolumeClaim" => check_pvc_ready(&obj.data),
        "CustomResourceDefinition" => check_crd_ready(&obj.data),
        _ => check_generic_ready(&obj.data),
    }
}

/// Return `true` if a Deployment or StatefulSet has `observedGeneration >=
/// generation`, both `readyReplicas` and `updatedReplicas` have reached
/// `spec.replicas`, and, for a Deployment (`no_old_pods`), no pod of an
/// older revision is left.
///
/// `readyReplicas` counts pods of every revision. While a rollout is stuck,
/// a pod of the old revision can still be ready next to an updated pod that
/// never starts, and the first two counts are then both met. A Deployment's
/// `status.replicas` leaves out terminating pods, so the extra rule cannot
/// hold it back during a scale-down. A StatefulSet counts terminating pods
/// there, so the rule does not apply to it.
fn check_deployment_ready(generation: Option<i64>, data: &Value, no_old_pods: bool) -> bool {
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

    let total = data
        .pointer("/status/replicas")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    ready >= desired && updated >= desired && (!no_old_pods || total <= updated)
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
pub(crate) fn check_job_ready(data: &Value) -> bool {
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
        return match rule.ready {
            ReadyRule::Path { path, equals } => {
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
            ReadyRule::PathNot { path, not_equals } => {
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
            ReadyRule::Condition {
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
            let old = obj
                .data
                .pointer("/status/replicas")
                .and_then(Value::as_i64)
                .unwrap_or(0)
                - updated;
            let old = match old {
                _ if kind != "Deployment" => String::new(),
                n if n <= 0 => String::new(),
                1 => ", 1 old pod left".to_string(),
                n => format!(", {n} old pods left"),
            };
            format!("{kind}/{name}: {ready}/{desired} ready, {updated}/{desired} updated{old}")
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
