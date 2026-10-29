//! Terminal workload failure classification and progress fingerprinting.

use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::ApiResource,
};
use serde_json::Value;

use super::declared::readiness_message;

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

/// Return a label selector fragment that restricts pod queries to the
/// workload's current controller revision, or `None` if the kind has no
/// revision selector or the controller has not published one yet.
///
/// A workload's `spec.selector.matchLabels` matches pods from all revisions,
/// including pods from a previous revision that a rollout is replacing.
/// Filtering to the current revision ensures terminal failure classification
/// evaluates only the active rollout rather than pods being terminated.
async fn current_revision_selector(
    client: &Client,
    obj: &Value,
    kind: &str,
    namespace: &str,
    selector: &str,
) -> Option<String> {
    match kind {
        // StatefulSet controllers publish the target revision in
        // `status.updateRevision` and stamp it on each pod.
        "StatefulSet" => {
            let rev = obj
                .pointer("/status/updateRevision")
                .and_then(Value::as_str)?;
            Some(format!("controller-revision-hash={rev}"))
        }
        // Deployments manage one ReplicaSet per revision without recording the
        // newest ReplicaSet in `Deployment.status`. Find the owned ReplicaSet
        // with the highest `deployment.kubernetes.io/revision` annotation and
        // read its `pod-template-hash`.
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

/// Return true if `kind` creates pods that can be inspected for terminal
/// container failures.
fn has_pods(kind: &str) -> bool {
    matches!(
        kind,
        "Deployment" | "StatefulSet" | "DaemonSet" | "Job" | "ReplicaSet"
    )
}

/// Result of a terminal-failure and progress scan against the live cluster.
/// Retains the fetched pods so the poll loop can reuse them when computing the
/// progress fingerprint without a second `list pods` request.
pub(super) struct ScanResult {
    pub terminal: Option<(TerminalReason, String)>,
    pub pods: Vec<Value>,
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
pub(super) async fn scan_terminal(
    client: &Client,
    obj: &Value,
    kind: &str,
    namespace: &str,
) -> ScanResult {
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
    // Filter to the current rollout revision so previous-revision pods are ignored.
    let selector = match current_revision_selector(client, obj, kind, namespace, &selector).await {
        Some(revision) => format!("{selector},{revision}"),
        None => selector,
    };
    let pods = list_pods_for_workload(client, namespace, &selector).await;
    let terminal = pods.iter().find_map(classify_pod_terminal);
    ScanResult { terminal, pods }
}

/// Build a stable string fingerprint of a resource's progress state.
///
/// Whenever this fingerprint changes between two polls, Kix treats it as
/// forward progress and resets the idle timer. Kix declares a no-progress
/// timeout only if the fingerprint remains unchanged for the full idle budget.
///
/// Includes the readiness message (which encodes per-kind counters),
/// `observedGeneration`, and aggregated pod state: phase counts, total restart
/// count, and distinct waiting reasons. Excludes timestamps and other
/// frequently changing fields so controller reconcile loops do not register as
/// forward progress on their own.
pub(super) fn progress_fingerprint(obj: &DynamicObject, kind: &str, pods: &[Value]) -> String {
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
