//! Readiness polling for Kubernetes resources.
//!
//! Provides per-kind readiness checks with `observedGeneration` guards for workloads,
//! used by `kix deploy` to wait for resources to become ready after apply.
//!
//! Also handles import marker `PackageInstance` resources whose readiness is
//! defined as the external resource existing on the cluster and passing
//! the same per-kind readiness checks as managed resources. Used to gate waves
//! on CRDs installed by operators outside Kix (such as StackGres `INSTALL_CRDS=true`)
//! and on platform-provided workloads (such as the CoreDNS `Deployment`).
//! See [`ImportTarget`] and [`wait_for_import_target`].

mod declared;
mod imports;
mod terminal;
#[cfg(test)]
mod tests;

use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

use super::cancel::CancelToken;
use super::discovery;
use crate::manifest::types::ResourceId;

pub use declared::{check_readiness, declared_rule, is_immediate_kind, not_ready_reason};
pub use imports::{ImportTarget, MalformedMarker, import_target_from_manifest};
pub use terminal::{
    PullError, TerminalReason, classify_pod_terminal, classify_pull_error,
    classify_workload_terminal, transient_pull_error,
};

pub(crate) use declared::{check_job_ready, daemonset_pending_restart};
pub(crate) use imports::{wait_for_expectations, wait_for_import_target};
pub(crate) use terminal::termination_output;

#[cfg(test)]
use declared::{
    DECLARED_FAILURE_GRACE, DeclaredFailure, FailedRule, ReadyRule, declared_readiness,
    served_crd_versions, unserved_crd_versions,
};
#[cfg(test)]
use imports::{check_secret_keys, expectations, split_api_version};
#[cfg(test)]
use terminal::{
    TERMINATION_OUTPUT_LINES, current_daemonset_revision_hash, current_replicaset,
    rollout_observed, workload_label_selector,
};

use declared::{FailureWatch, declared_failure, is_wait_for_first_consumer, readiness_message};
use terminal::{progress_fingerprint, scan_terminal};

/// After a CRD reaches `Established=True`, the API server's discovery endpoint
/// (and replicas behind an HA load balancer) may still lag by a few hundred
/// milliseconds before the new group/version/kind appears. Dependents that race in
/// during that window would hit "no matches for kind" on apply. Poll
/// discovery for up to this budget after `Established=True`.
const CRD_DISCOVERY_PROBE_BUDGET: Duration = Duration::from_secs(5);
const CRD_DISCOVERY_PROBE_INTERVAL: Duration = Duration::from_millis(300);

/// Run a bounded discovery probe until the CRD's group/version/kind appears.
/// Called after a newly applied CRD reports `Established=True`. Returns
/// `true` if the kind was observed in discovery, or `false` if the budget
/// elapsed before it appeared (the deploy still proceeds, and retry-on-miss
/// in the scheduler absorbs any remaining skew).
pub(super) async fn probe_crd_discovery(client: &Client, crd: &Value) -> bool {
    let Some(group) = crd.pointer("/spec/group").and_then(Value::as_str) else {
        return true;
    };
    let Some(kind) = crd.pointer("/spec/names/kind").and_then(Value::as_str) else {
        return true;
    };
    let deadline = Instant::now() + CRD_DISCOVERY_PROBE_BUDGET;
    loop {
        // Query only the target group rather than walking all API groups, which
        // would wait on any unrelated group version that returns 404.
        if let Ok(walk) = discovery::discover_group(client, group).await
            && walk
                .resources
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

/// Default timeout for readiness polling.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(180);

/// Default interval between readiness polls.
pub(super) const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Errors from readiness polling.
#[derive(Error, Debug)]
pub(crate) enum ReadinessError {
    #[error("failed to fetch resource for readiness check: {0}")]
    FetchError(#[source] kube::Error),
    #[error("malformed import target: {0}")]
    MalformedImportTarget(String),
}

/// Result of a readiness check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ReadinessResult {
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

/// Absolute upper bound on how long any single resource may take to become
/// Ready. Enforced regardless of the per-resource idle budget so a resource
/// whose fingerprint changes continuously without reaching Ready still times
/// out.
const HARD_CEILING: Duration = Duration::from_secs(5 * 60);

/// Wait for a resource to become ready, polling every 2 seconds.
///
/// Uses a two-tier timeout model:
///
/// * **Idle progress timeout** (`timeout` argument): the maximum time to wait
///   without observing any progress in the resource's status. The progress
///   fingerprint combines the readiness message, `observedGeneration`, and
///   pod-level state (phases, restart counts, and waiting reasons). Whenever
///   the fingerprint changes between polls, this timer resets so a slow but
///   actively rolling Deployment does not time out.
/// * **Hard ceiling** ([`HARD_CEILING`], 5 minutes): an absolute upper bound
///   enforced regardless of progress, catching resources whose fingerprint
///   changes continuously without reaching Ready.
///
/// Before each poll iteration, scans for terminal failure signals
/// (`ImagePullBackOff`, `CrashLoopBackOff` past threshold,
/// `ProgressDeadlineExceeded`, or Job backoff exhausted) and returns `Failed`
/// immediately on a match. An image pull that failed for a network reason is
/// not terminal because the kubelet pulls again. A timeout during such a
/// retry ends its message with the pull error. A custom resource whose `kix.run/readiness`
/// annotation lists `failed` states ends the same way when the controller
/// reports one of them for the current spec ([`declared_failure`]). A match
/// counts as current when its `observedGeneration` has reached
/// `metadata.generation`, or its condition's `lastTransitionTime` is later
/// than `applied_at`, the time this deploy changed the object (`None` when it
/// left the object unchanged); with neither field, the state must hold for
/// [`DECLARED_FAILURE_GRACE`] first.
///
/// Returns `Ready` on success, `Failed` on a terminal signal, `TimedOut` when
/// either timeout budget elapses, or `Cancelled` if `cancel` is triggered.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn wait_for_ready(
    client: &Client,
    ar: &ApiResource,
    scope: &Scope,
    rid: &ResourceId,
    applied_at: Option<DateTime<Utc>>,
    timeout: Duration,
    cancel: &CancelToken,
    on_status: impl Fn(&str),
) -> Result<ReadinessResult, ReadinessError> {
    let (name, kind) = (rid.name.as_str(), rid.kind.as_str());
    if is_immediate_kind(kind) {
        return Ok(ReadinessResult::Ready);
    }

    let api: Api<DynamicObject> = discovery::api_for(client, ar, scope, rid);

    let idle_budget = timeout;
    let hard_ceiling = HARD_CEILING;

    let start = Instant::now();
    let mut last_progress_at = start;
    let mut last_fingerprint = String::new();
    let mut failure_watch = FailureWatch::default();

    loop {
        if cancel.is_cancelled() {
            return Ok(ReadinessResult::Cancelled);
        }
        let obj = match api.get(name).await {
            Ok(obj) => obj,
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
        let scan = scan_terminal(client, &obj, kind, ns_for_pods).await;
        if let Some((reason, detail)) = scan.terminal {
            return Ok(ReadinessResult::Failed {
                message: format!("{}: {detail}", reason.as_str()),
                output: termination_output(&scan.pods),
            });
        }

        if let Some(message) =
            failure_watch.observe(declared_failure(&obj, kind, applied_at), Instant::now())
        {
            return Ok(ReadinessResult::Failed {
                message,
                output: Vec::new(),
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

        let mut message = readiness_message(&obj, kind);
        let idle = last_progress_at.elapsed();
        let total = start.elapsed();
        if scan.pull_retrying.is_some() {
            message.push_str(", retrying an image pull");
        }
        on_status(&format!("{message} (idle {}s)", idle.as_secs()));
        if let Some(pull) = &scan.pull_retrying {
            message = format!("{message} after this error: {pull}");
        }

        if idle >= idle_budget {
            return Ok(ReadinessResult::TimedOut {
                elapsed: total,
                message: format!(
                    "no readiness progress for {}s (idle budget {}s): {message}",
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
