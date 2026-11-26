//! Terminal workload failure classification and progress fingerprinting.

use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::ApiResource,
};
use serde_json::Value;

use super::declared::{readiness_message, status_observed_generation};
use super::identity::{classify_pod_identity, identity_env};
use crate::manifest::kinds::{self, GroupKind};

/// Number of container restarts required before CrashLoopBackOff is treated
/// as terminal. Allows a couple of flapping-startup cycles (InitContainer
/// ordering, DB migrations waiting for a sidecar, etc.) before we give up.
const CRASHLOOP_RESTART_THRESHOLD: i64 = 3;

/// Classification of a terminal workload failure. Bubbles up from the per-pod
/// and per-workload classifiers ([`classify_pod_terminal`], [`classify_workload_terminal`]) so callers
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
    /// A pod of the current revision lacks the environment variables that
    /// the platform adds when it gives the pod its cloud identity.
    CloudIdentityNotApplied,
}

impl TerminalReason {
    pub fn as_str(&self) -> &'static str {
        match self {
            TerminalReason::ImagePull => "ImagePullBackOff",
            TerminalReason::ContainerConfig => "CreateContainerConfigError",
            TerminalReason::CrashLoop => "CrashLoopBackOff",
            TerminalReason::ProgressDeadline => "ProgressDeadlineExceeded",
            TerminalReason::JobBackoffExceeded => "JobBackoffExceeded",
            TerminalReason::CloudIdentityNotApplied => "CloudIdentityNotApplied",
        }
    }
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
                "ImagePullBackOff" | "ErrImagePull"
                    if classify_pull_error(waiting_msg) == PullError::Transient => {}
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

/// Whether an image pull error can clear up on a later pull of the same image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PullError {
    /// The registry or the network failed. The kubelet pulls again, and a
    /// later pull can succeed.
    Transient,
    /// The image reference, the registry's answer, or the credentials are
    /// wrong, so every later pull fails the same way.
    Permanent,
}

/// Phrases of pull errors that a later pull cannot fix. They are checked
/// before [`TRANSIENT_PULL_ERRORS`], so a message with both fails fast.
const PERMANENT_PULL_ERRORS: &[&str] = &[
    "manifest unknown",
    "not found",
    "unauthorized",
    "denied",
    "forbidden",
    "invalid reference format",
    "no matching manifest",
    "repository does not exist",
];

/// Phrases of pull errors that come from the network or an overloaded
/// registry. Each starts with a space or a separator so that a word such as
/// `timeout=` in a URL does not match.
const TRANSIENT_PULL_ERRORS: &[&str] = &[
    " timeout",
    "timeout exceeded",
    "deadline exceeded",
    "connection reset",
    "connection refused",
    " eof",
    "temporary failure in name resolution",
    "network is unreachable",
    "no route to host",
    "internal server error",
    "bad gateway",
    "service unavailable",
    "too many requests",
    "toomanyrequests",
];

/// Classify the message of an `ErrImagePull` or `ImagePullBackOff` container
/// state. A message Kix does not recognize counts as permanent. This includes
/// the bare `Back-off pulling image "x"` that kubelets before Kubernetes 1.30
/// write without the pull error.
pub fn classify_pull_error(message: &str) -> PullError {
    let message = message.to_lowercase();
    if PERMANENT_PULL_ERRORS.iter().any(|p| message.contains(p)) {
        return PullError::Permanent;
    }
    if TRANSIENT_PULL_ERRORS.iter().any(|p| message.contains(p)) {
        return PullError::Transient;
    }
    PullError::Permanent
}

/// Return the first container in `pod` whose image pull failed with a
/// transient error, as `pod <pod>/<container>: <reason>: <message>`. The
/// kubelet keeps pulling such an image, so the deploy keeps waiting and shows
/// this error if the wait runs out.
pub fn transient_pull_error(pod: &Value) -> Option<String> {
    let pod_name = pod
        .pointer("/metadata/name")
        .and_then(Value::as_str)
        .unwrap_or("?");
    ["/status/initContainerStatuses", "/status/containerStatuses"]
        .into_iter()
        .filter_map(|slot| pod.pointer(slot).and_then(Value::as_array))
        .flatten()
        .find_map(|cs| {
            let reason = cs
                .pointer("/state/waiting/reason")
                .and_then(Value::as_str)?;
            let message = cs
                .pointer("/state/waiting/message")
                .and_then(Value::as_str)
                .unwrap_or("");
            let pulling = matches!(reason, "ImagePullBackOff" | "ErrImagePull");
            (pulling && classify_pull_error(message) == PullError::Transient).then(|| {
                let container = cs.get("name").and_then(Value::as_str).unwrap_or("?");
                format!("pod {pod_name}/{container}: {reason}: {message}")
            })
        })
}

/// Classify workload-level terminal failures that don't require pod inspection.
/// Currently covers Deployment progress deadline and Job backoff limit.
pub fn classify_workload_terminal(
    obj: &Value,
    kind: GroupKind<'_>,
) -> Option<(TerminalReason, String)> {
    match kind {
        kinds::DEPLOYMENT => {
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
        kinds::JOB => {
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

/// Build a label selector string from a workload's `spec.selector.matchLabels`.
/// Returns `None` if the workload has no selector.
pub(super) fn workload_label_selector(obj: &Value) -> Option<String> {
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

/// Return true when the controller of a rollout workload has acted on the
/// current spec, that is when `status.observedGeneration` has reached
/// `metadata.generation`.
///
/// Until then the workload's status, its revision fields, and its pods all
/// describe the previous template. A deploy that restores an earlier template
/// would otherwise be judged by the pods of the template it is replacing.
/// Kinds without a rollout controller always count as observed.
pub(super) fn rollout_observed(obj: &DynamicObject, kind: GroupKind<'_>) -> bool {
    if !matches!(
        kind,
        kinds::DEPLOYMENT | kinds::STATEFUL_SET | kinds::DAEMON_SET
    ) {
        return true;
    }
    let Some(generation) = obj.metadata.generation else {
        return true;
    };
    obj.data
        .pointer("/status/observedGeneration")
        .and_then(Value::as_i64)
        .is_some_and(|observed| observed >= generation)
}

/// Which pods of a workload belong to its current revision.
enum RevisionPods {
    /// Pods whose labels also match this selector fragment.
    Matching(String),
    /// The kind has no revision label, so every selected pod counts.
    All,
    /// The controller has not created the current revision yet, so no pod
    /// can be judged.
    NotCreated,
}

fn owned_by(obj: &Value, uid: &str) -> bool {
    obj.pointer("/metadata/ownerReferences")
        .and_then(Value::as_array)
        .is_some_and(|refs| {
            refs.iter()
                .any(|r| r.get("uid").and_then(Value::as_str) == Some(uid))
        })
}

/// Return the ReplicaSet that runs a Deployment's current pod template.
///
/// The Deployment controller labels each ReplicaSet's template with
/// `pod-template-hash` and otherwise copies the Deployment's template. The
/// ReplicaSet whose template equals the Deployment's once that label is
/// removed is the current one. The highest `deployment.kubernetes.io/revision`
/// is not enough: when an earlier template comes back, the controller reuses
/// its old ReplicaSet and raises that revision only later.
pub(super) fn current_replicaset<'a>(
    deployment: &DynamicObject,
    replicasets: &'a [Value],
) -> Option<&'a Value> {
    let uid = deployment.metadata.uid.as_deref()?;
    let template = deployment.data.pointer("/spec/template")?;
    replicasets
        .iter()
        .filter(|rs| owned_by(rs, uid))
        .filter(|rs| {
            let Some(mut rs_template) = rs.pointer("/spec/template").cloned() else {
                return false;
            };
            if let Some(labels) = rs_template
                .pointer_mut("/metadata/labels")
                .and_then(Value::as_object_mut)
            {
                labels.remove("pod-template-hash");
            }
            &rs_template == template
        })
        .max_by_key(|rs| {
            rs.pointer("/metadata/annotations/deployment.kubernetes.io~1revision")
                .and_then(Value::as_str)
                .and_then(|r| r.parse::<i64>().ok())
                .unwrap_or(0)
        })
}

/// Return the `controller-revision-hash` of a DaemonSet's current
/// ControllerRevision, the owned one with the highest `revision`.
///
/// The DaemonSet controller raises a reused revision before it records
/// `observedGeneration`, so the highest revision is current once
/// [`rollout_observed`] holds.
pub(super) fn current_daemonset_revision_hash(
    daemonset: &DynamicObject,
    revisions: &[Value],
) -> Option<String> {
    let uid = daemonset.metadata.uid.as_deref()?;
    revisions
        .iter()
        .filter(|rev| owned_by(rev, uid))
        .max_by_key(|rev| rev.get("revision").and_then(Value::as_i64).unwrap_or(0))?
        .pointer("/metadata/labels/controller-revision-hash")
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// List the objects of one `apps/v1` kind that match `selector`, with their
/// metadata. Returns `None` on API errors.
async fn list_apps_objects(
    client: &Client,
    namespace: &str,
    kind: &str,
    plural: &str,
    selector: &str,
) -> Option<Vec<Value>> {
    let ar = ApiResource {
        group: "apps".into(),
        version: "v1".into(),
        api_version: "apps/v1".into(),
        kind: kind.into(),
        plural: plural.into(),
    };
    let api: Api<DynamicObject> = Api::namespaced_with(client.clone(), namespace, &ar);
    let lp = kube::api::ListParams::default().labels(selector);
    let list = api.list(&lp).await.ok()?;
    Some(
        list.items
            .into_iter()
            .filter_map(|o| serde_json::to_value(o).ok())
            .collect(),
    )
}

/// Find which of a workload's pods belong to its current revision.
///
/// A workload's `spec.selector.matchLabels` matches pods from all revisions,
/// including pods from a previous revision that a rollout is replacing.
/// Restricting to the current revision means terminal failures come only from
/// the rollout in progress. Call this only once [`rollout_observed`] holds.
async fn current_revision_pods(
    client: &Client,
    obj: &DynamicObject,
    kind: GroupKind<'_>,
    namespace: &str,
    selector: &str,
) -> RevisionPods {
    match kind {
        // The StatefulSet controller publishes the current revision in
        // `status.updateRevision` and stamps it on each pod.
        kinds::STATEFUL_SET => match obj
            .data
            .pointer("/status/updateRevision")
            .and_then(Value::as_str)
        {
            Some(rev) => RevisionPods::Matching(format!("controller-revision-hash={rev}")),
            None => RevisionPods::NotCreated,
        },
        kinds::DEPLOYMENT => {
            let Some(replicasets) =
                list_apps_objects(client, namespace, "ReplicaSet", "replicasets", selector).await
            else {
                return RevisionPods::All;
            };
            match current_replicaset(obj, &replicasets)
                .and_then(|rs| rs.pointer("/spec/selector/matchLabels/pod-template-hash"))
                .and_then(Value::as_str)
            {
                Some(hash) => RevisionPods::Matching(format!("pod-template-hash={hash}")),
                None => RevisionPods::NotCreated,
            }
        }
        kinds::DAEMON_SET => {
            let Some(revisions) = list_apps_objects(
                client,
                namespace,
                "ControllerRevision",
                "controllerrevisions",
                selector,
            )
            .await
            else {
                return RevisionPods::All;
            };
            match current_daemonset_revision_hash(obj, &revisions) {
                Some(hash) => RevisionPods::Matching(format!("controller-revision-hash={hash}")),
                None => RevisionPods::NotCreated,
            }
        }
        _ => RevisionPods::All,
    }
}

/// List pods matching a workload's label selector. Returns an empty `Vec` on
/// API errors so the terminal classifier can continue using workload-level
/// signals.
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
        // `DynamicObject::data` leaves out `metadata`, which the pod name in
        // failure messages comes from, so serialize the whole object.
        Ok(list) => list
            .items
            .into_iter()
            .filter_map(|p| serde_json::to_value(p).ok())
            .collect(),
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

/// Return true if `kind` creates pods that can be inspected for terminal
/// container failures.
fn has_pods(kind: GroupKind<'_>) -> bool {
    matches!(
        kind,
        kinds::DEPLOYMENT
            | kinds::STATEFUL_SET
            | kinds::DAEMON_SET
            | kinds::JOB
            | kinds::REPLICA_SET
    )
}

/// Result of a terminal-failure and progress scan against the live cluster.
/// Retains the fetched pods so the poll loop can reuse them when computing the
/// progress fingerprint without a second `list pods` request.
pub(super) struct ScanResult {
    pub terminal: Option<(TerminalReason, String)>,
    pub pods: Vec<Value>,
    /// A transient image pull error the kubelet is retrying; see
    /// [`transient_pull_error`].
    pub pull_retrying: Option<String>,
}

/// Extract the termination message lines from the most recently started pod.
///
/// With `terminationMessagePolicy: FallbackToLogsOnError`, the kubelet copies
/// the tail of a container's log into
/// `status.containerStatuses[].state.terminated.message` when the container
/// exits non-zero. Only the newest pod by `status.startTime` is inspected so
/// Jobs with multiple attempts report output from the final attempt. Reads
/// `state.terminated` first, then falls back to `lastState.terminated`. Lines
/// are prefixed with `<container>: ` when multiple containers produced output,
/// and truncated to the last [`TERMINATION_OUTPUT_LINES`] lines.
pub(crate) fn termination_output(pods: &[Value]) -> Vec<String> {
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
pub(crate) const TERMINATION_OUTPUT_LINES: usize = 20;

/// Scan for terminal failures: check workload-level signals first, then
/// pod-level signals for pod-backed kinds. Return on the first hit in
/// `terminal`, while retaining the fetched pods so the caller can reuse them
/// for progress fingerprinting. On a Job-level hit, list the Job's pods once
/// more so the failure includes container output.
///
/// A rollout workload whose controller has not yet acted on the current spec
/// is not judged at all, because every signal it has describes the old spec.
pub(super) async fn scan_terminal(
    client: &Client,
    obj: &DynamicObject,
    kind: GroupKind<'_>,
    namespace: &str,
) -> ScanResult {
    let nothing = || ScanResult {
        terminal: None,
        pods: Vec::new(),
        pull_retrying: None,
    };
    if !rollout_observed(obj, kind) {
        return nothing();
    }
    if let Some(hit) = classify_workload_terminal(&obj.data, kind) {
        let pods = match (kind, workload_label_selector(&obj.data)) {
            (kinds::JOB, Some(selector)) => {
                list_pods_for_workload(client, namespace, &selector).await
            }
            _ => Vec::new(),
        };
        return ScanResult {
            terminal: Some(hit),
            pods,
            pull_retrying: None,
        };
    }
    if !has_pods(kind) {
        return nothing();
    }
    let Some(selector) = workload_label_selector(&obj.data) else {
        return nothing();
    };
    let (selector, current_only) =
        match current_revision_pods(client, obj, kind, namespace, &selector).await {
            RevisionPods::Matching(revision) => (format!("{selector},{revision}"), true),
            RevisionPods::All => (selector, false),
            RevisionPods::NotCreated => return nothing(),
        };
    let pods = list_pods_for_workload(client, namespace, &selector).await;
    // Only pods of the current revision can show whether the current pod
    // template got its cloud identity.
    let identity = if current_only {
        obj.metadata
            .annotations
            .as_ref()
            .and_then(identity_env)
            .and_then(|expected| {
                pods.iter()
                    .find_map(|p| classify_pod_identity(p, &expected))
                    .map(|m| (TerminalReason::CloudIdentityNotApplied, m))
            })
    } else {
        None
    };
    let terminal = identity.or_else(|| pods.iter().find_map(classify_pod_terminal));
    let pull_retrying = pods.iter().find_map(transient_pull_error);
    ScanResult {
        terminal,
        pods,
        pull_retrying,
    }
}

/// Build a stable string fingerprint of a resource's progress state.
///
/// Whenever this fingerprint changes between two polls, Kix treats it as
/// forward progress and resets the idle timer. Kix declares a no-progress
/// timeout only if the fingerprint remains unchanged for the full idle budget.
///
/// Includes the readiness message (which encodes per-kind counters), the
/// observed generation (`status.observedGeneration`, or the field a declared
/// readiness names), and aggregated pod state: phase counts, total restart
/// count, and distinct waiting reasons. Excludes timestamps and other
/// frequently changing fields so controller reconcile loops do not register as
/// forward progress on their own.
pub(super) fn progress_fingerprint(
    obj: &DynamicObject,
    kind: GroupKind<'_>,
    pods: &[Value],
) -> String {
    use std::collections::BTreeMap;

    let mut parts: Vec<String> = Vec::with_capacity(4);
    parts.push(readiness_message(obj, kind));

    if let Some(g) = status_observed_generation(obj) {
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
                            // The kubelet moves a failing pull between these
                            // two states on every retry, which is not progress.
                            waiting_reasons.insert(match r {
                                "ErrImagePull" => "ImagePullBackOff",
                                other => other,
                            });
                        }
                        // Include the running and terminated states in the fingerprint
                        // because transitioning from waiting to running is forward
                        // progress even before workload counters update.
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
