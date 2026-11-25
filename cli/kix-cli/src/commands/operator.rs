//! Operator-mode helpers for CLI commands.
//!
//! When `--operator` is passed to deploy/rollback/gc, the CLI delegates
//! the actual cluster mutation to the kix-operator. The CLI creates or patches
//! Activation CRs and watches their status for progress, rather than calling
//! the reconcile engine directly.

use std::time::Duration;

use kix::cluster::activation::{Record, Records, WaveStatus};
use kix::eval::package_index::RecordPackageIndex;
use kix::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_QUEUED, PHASE_SUPERSEDED,
};
use kube::client::Client;
use miette::{Result, miette};
use serde_json::Value;

use crate::client;
use kix::cluster::discovery;

use crate::output;

/// Connect to the cluster, run the domain gate, and verify that Activation
/// records are readable.
pub async fn connect_and_verify(context: Option<&str>) -> Result<(Client, Records)> {
    crate::say!("Connecting to cluster...");

    let client = client::make_client(context)
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let records = open_records(&client).await?;

    crate::say!("  {} Activation CRD found", output::green("✓"));

    Ok((client, records))
}

/// Discover and open the cluster's Activation records, verifying read access.
async fn open_records(client: &Client) -> Result<Records> {
    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| miette!("{e}"))?;
    let records = Records::open_installed(client, &discovery).map_err(|e| miette!("{e}"))?;
    records.reachable().await.map_err(|e| {
        miette!(
            "could not read deployment records on this Kubernetes cluster\n  \
             Nothing was changed on the cluster.\n\n  \
             Kubernetes API error:\n    \
             {e}\n\n  \
             Next:\n    \
             Check which cluster your kubeconfig points at (`kubectl config current-context` or pass `--context <name>`), verify that your Kubernetes account has permission to read `activations.{}`, and make sure the cluster has been deployed at least once with `kix deploy <cluster>`.",
            kix::manifest::keys::GROUP
        )
    })?;
    Ok(records)
}

/// Refuse to hand the operator a request when it has not published that it
/// handles requests (`kix.run/operator-features` on the Activation CRD). An
/// operator from before requests would ignore it, and the command would wait
/// for an answer that never comes.
pub async fn require_requests(client: &Client) -> Result<()> {
    use kix::cluster::activation::features;
    let version = kix::version::running();
    let found = features::read(client).await.map_err(|e| {
        miette!(
            "could not read CustomResourceDefinition `{crd}` to check the Kix operator's features\n  \
             Nothing was applied to the cluster.\n\n  \
             Kubernetes API error:\n    \
             {e}\n\n  \
             Next:\n    \
             Check that your Kubernetes account has permission to read CustomResourceDefinition `{crd}`, then run the command again.",
            crd = kix::manifest::keys::ACTIVATIONS_CRD,
        )
    })?;
    if found.handles(features::REQUESTS) {
        return Ok(());
    }
    Err(miette!(
        "the Kix operator on this cluster has not reported support for deployment requests\n  \
         Nothing was applied to the cluster.\n\n  \
         Why:\n    \
         CustomResourceDefinition `{crd}` does not list `{feature}` in its `{key}` annotation. \
         Kix {version} sends each `--operator` run through `spec.request` on the deployment record, which an older operator ignores. \
         The operator writes `{key}` when it starts, so it is either older than Kix {version}, still starting, or missing permission to patch `{crd}`.\n\n  \
         Next:\n    \
         Upgrade the Kix operator to Kix {version} or later, grant its Kubernetes account permission to patch CustomResourceDefinition `{crd}`, and restart it so it writes `{key}`. Then run the command again.",
        key = kix::manifest::keys::OPERATOR_FEATURES,
        crd = kix::manifest::keys::ACTIVATIONS_CRD,
        feature = features::REQUESTS,
    ))
}

/// Create or update an Activation CR to trigger operator reconciliation.
///
/// The CR is created without a phase. The operator treats it as Queued and
/// advances it through Deploying to Active. `kubernetes_uid` is the build's
/// `cluster.kubernetes.uid`, which the record carries as a label.
#[allow(clippy::too_many_arguments)]
pub async fn apply_activation(
    records: &Records,
    activation_name: &str,
    cluster_name: &str,
    source_path: &str,
    identity_hash: Option<&str>,
    kubernetes_uid: Option<&str>,
    receipt: Option<&Value>,
    package_index: &RecordPackageIndex,
) -> Result<String> {
    let request = kix::cluster::activation::new_request();
    records
        .submit(
            activation_name,
            cluster_name,
            source_path,
            identity_hash,
            kubernetes_uid,
            &request,
        )
        .await
        .map_err(|e| miette!("{e}"))?;

    // The operator has no source tree, so it cannot compute provenance. The
    // CLI that submitted this activation does, so it writes the receipt here.
    if let Some(receipt) = receipt {
        records
            .write_receipt(activation_name, receipt)
            .await
            .map_err(|e| miette!("failed to record the deploy receipt: {e}"))?;
    }

    // The operator holds no build graph, so the CLI writes the index of the
    // build the record now names. A failure only warns.
    records
        .write_package_index(activation_name, package_index)
        .await;

    Ok(request)
}

/// Terminal outcome of an operator-reconciled Activation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reconciled {
    Active,
    /// Every resource was attempted and some failed. The record is current,
    /// and the command that waited on it exits non-zero.
    Degraded,
}

/// Tracks which progress lines have already been printed across poll ticks.
#[derive(Default)]
struct Progress {
    seen_deploying: bool,
    waves_done: usize,
    /// The failed attempts already reported, from `status.failedAttempts`.
    attempts_reported: u32,
}

impl Progress {
    /// Return any new progress lines since the previous poll of `act`.
    fn lines(&mut self, act: &Record) -> Vec<String> {
        let mut lines = Vec::new();
        if !self.seen_deploying && act.phase == PHASE_DEPLOYING {
            self.seen_deploying = true;
            lines.push(format!(
                "  {} Operator is reconciling ({} waves)...",
                output::dim("•"),
                act.total_waves,
            ));
        }
        // Each attempt of the operator starts the list of waves again.
        if act.waves.len() < self.waves_done {
            self.waves_done = 0;
        }
        for (i, wave) in act.waves.iter().enumerate().skip(self.waves_done) {
            let (mark, status) = match wave.status {
                WaveStatus::Complete => (output::green("✓"), output::green("Complete")),
                WaveStatus::Failed => (output::red("✗"), output::red("Failed")),
                WaveStatus::Pending => continue,
            };
            lines.push(format!(
                "  {mark} Wave {}: {status} ({}/{} applied, {} failed)",
                i + 1,
                wave.applied,
                wave.resource_count,
                wave.failed,
            ));
            self.waves_done = i + 1;
        }
        // The operator counts each attempt that fails, and retries the
        // record while it stays Deploying, or Queued when the attempt failed
        // before the deploy began.
        let retrying = matches!(act.phase.as_str(), PHASE_DEPLOYING | PHASE_QUEUED | "");
        if retrying && act.failed_attempts > self.attempts_reported {
            self.attempts_reported = act.failed_attempts;
            lines.push(format!(
                "  {} Attempt {} failed. The Kix operator will retry in 30 seconds.",
                output::red("✗"),
                act.failed_attempts,
            ));
            if let Some(reason) = act.failure_reason.as_deref().and_then(|r| r.lines().next()) {
                lines.push(format!("    {reason}"));
            }
        }
        lines
    }
}

/// Watch an Activation CR's status until the operator has run `request` on
/// it.
///
/// Waits until the operator starts the request, so a phase the record had
/// before (such as Active for the build already deployed) is not taken for
/// the answer. Polls the Activation status periodically, printing wave
/// progress as it happens. Returns when the operator has finished the
/// request and `status.phase` is `Active` or `Degraded`; `Failed`,
/// `Superseded`, and a 10 minute timeout are errors.
pub async fn watch_activation_progress(
    records: &Records,
    activation_name: &str,
    request: &str,
) -> Result<Reconciled> {
    let poll_interval = Duration::from_secs(2);
    let timeout = Duration::from_secs(600);
    let start = tokio::time::Instant::now();

    let mut progress = Progress::default();

    loop {
        if start.elapsed() > timeout {
            return Err(miette!(
                "timed out after {} seconds waiting for the Kix operator to finish Activation '{activation_name}'. This stops only the local wait and does not cancel the deploy on the cluster. Check progress with `kubectl describe activation {activation_name}`, and verify that the Kix operator pod is running.",
                timeout.as_secs(),
            ));
        }

        let act = records
            .get(activation_name)
            .await
            .map_err(|e| miette!("{e}"))?
            .ok_or_else(|| miette!("Activation '{activation_name}' no longer exists"))?;
        if act.started_request.as_deref() != Some(request) {
            tokio::time::sleep(poll_interval).await;
            continue;
        }
        let phase = act.phase.as_str();
        for line in progress.lines(&act) {
            crate::say!("{line}");
        }

        // Completion: phase is Active or Degraded (deploy finished, possibly
        // with failures; Activation status contains the failed-resource list.)
        let finished = act.finished_request.as_deref() == Some(request);
        if finished && (phase == PHASE_ACTIVE || phase == PHASE_DEGRADED) {
            let phase_colored = if phase == PHASE_ACTIVE {
                output::green(phase)
            } else {
                output::yellow(phase)
            };
            crate::say!(
                "  {} Activation '{}' is {}",
                output::green("✓"),
                activation_name,
                phase_colored,
            );
            return Ok(if phase == PHASE_ACTIVE {
                Reconciled::Active
            } else {
                Reconciled::Degraded
            });
        }

        // Check for Superseded (another activation took over)
        if phase == PHASE_SUPERSEDED {
            return Err(miette!(
                "Activation '{}' was superseded by a newer activation",
                activation_name
            ));
        }

        if phase == PHASE_FAILED {
            return Err(miette!(
                "Operator reconciliation failed for '{}': {}",
                activation_name,
                act.failure_reason.as_deref().unwrap_or("unknown error"),
            ));
        }

        tokio::time::sleep(poll_interval).await;
    }
}

/// Wait for an Activation CR to be fully deleted (finalizer cleanup complete).
pub async fn wait_for_deletion(records: &Records, activation_name: &str) -> Result<()> {
    let poll_interval = Duration::from_secs(2);
    let timeout = Duration::from_secs(300);
    let start = tokio::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            return Err(miette!(
                "timed out waiting for Activation '{}' to be deleted",
                activation_name
            ));
        }

        match records.get(activation_name).await {
            Ok(Some(act)) => {
                if act.deleting && !output::quiet() {
                    eprint!("\r  {} Finalizer cleanup in progress...", output::dim("•"),);
                }
            }
            Ok(None) => {
                crate::esay!();
                crate::say!(
                    "  {} Activation '{}' deleted",
                    output::green("✓"),
                    activation_name,
                );
                return Ok(());
            }
            Err(e) => {
                return Err(miette!("{e}"));
            }
        }

        tokio::time::sleep(poll_interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;
    use kix::manifest::keys;
    use kix::manifest::lifecycle::RECORD_KIND;
    use serde_json::json;

    fn record(name: &str, phase: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": { "name": name },
            "spec": { "request": "r1" },
            "status": { "phase": phase, "startedRequest": "r1", "finishedRequest": "r1" },
        })
    }

    async fn watch(phase: &str) -> Result<Reconciled> {
        let api = FakeApi::new([record("rec", phase)]);
        let client = api.client();
        let records = open_records(&client).await.unwrap();
        watch_activation_progress(&records, "rec", "r1").await
    }

    /// A record that is already Active, as when `kix deploy --operator`
    /// submits the build already deployed, is not the answer until the
    /// operator has started and finished the request.
    #[tokio::test(start_paused = true)]
    async fn the_watch_waits_for_its_own_request() {
        let mut active = record("rec", "Active");
        active["status"]["startedRequest"] = json!("r0");
        active["status"]["finishedRequest"] = json!("r0");
        let api = FakeApi::new([active]);
        api.after_get("rec", |rec| {
            rec["status"]["startedRequest"] = json!("r1");
            rec["status"]["phase"] = json!("Active");
        });
        let records = open_records(&api.client()).await.unwrap();
        let watched =
            tokio::spawn(async move { watch_activation_progress(&records, "rec", "r1").await });
        // Started but not finished: the watch keeps polling.
        tokio::time::sleep(Duration::from_secs(3)).await;
        assert!(!watched.is_finished());
        api.after_get("rec", |rec| {
            rec["status"]["finishedRequest"] = json!("r1");
            rec["status"]["phase"] = json!("Degraded");
        });
        assert_eq!(watched.await.unwrap().unwrap(), Reconciled::Degraded);
    }

    /// A command refuses before it writes a request when the operator has
    /// not published that it handles requests, and goes on once it has.
    #[tokio::test]
    async fn an_operator_that_does_not_take_requests_is_refused_up_front() {
        let crd = |annotations: Value| {
            json!({
                "apiVersion": "apiextensions.k8s.io/v1",
                "kind": "CustomResourceDefinition",
                "metadata": { "name": keys::ACTIVATIONS_CRD, "annotations": annotations },
            })
        };
        let old = FakeApi::new([crd(json!({}))]);
        assert!(require_requests(&old.client()).await.is_err());
        assert!(
            !old.requests().iter().any(|r| r.starts_with("PATCH")),
            "{:?}",
            old.requests()
        );
        let new = FakeApi::new([crd(json!({ (keys::OPERATOR_FEATURES): "requests" }))]);
        assert!(require_requests(&new.client()).await.is_ok());
    }

    /// Verify that operator mode requires API discovery and rejects unmigrated clusters.
    #[tokio::test]
    async fn operator_mode_opens_records_only_through_discovery() {
        let api = FakeApi::new([]);
        api.fail_next("/apis", 1, 500);
        assert!(open_records(&api.client()).await.is_err());
        assert!(open_records(&api.client()).await.is_ok());

        let unmigrated = FakeApi::new([]);
        unmigrated.serve_retired_records();
        let Err(err) = open_records(&unmigrated.client()).await else {
            panic!("an unmigrated cluster's records were opened");
        };
        assert!(err.to_string().contains("kix migrate domain"), "{err}");
    }

    /// Verify that a `Degraded` record is distinguished from `Active` so the CLI can exit non-zero.
    #[tokio::test]
    async fn a_degraded_record_is_not_reported_as_active() {
        assert_eq!(watch("Active").await.unwrap(), Reconciled::Active);
        assert_eq!(watch("Degraded").await.unwrap(), Reconciled::Degraded);
        assert!(watch("Failed").await.is_err());
    }

    /// Verify that [`Progress::lines`] emits the reconciling banner and each completed wave once.
    #[test]
    fn the_watch_prints_each_step_once() {
        use kix::cluster::activation::{WaveRecord, WaveStatus};
        let wave = |status| WaveRecord {
            wave_index: 0,
            status,
            resource_count: 3,
            applied: 2,
            failed: 1,
        };
        let mut act = Record {
            phase: PHASE_DEPLOYING.into(),
            total_waves: 2,
            ..Default::default()
        };
        let mut progress = Progress::default();
        assert_eq!(
            progress.lines(&act),
            vec!["  • Operator is reconciling (2 waves)...".to_string()]
        );
        act.waves = vec![wave(WaveStatus::Complete), wave(WaveStatus::Pending)];
        assert_eq!(
            progress.lines(&act),
            vec!["  ✓ Wave 1: Complete (2/3 applied, 1 failed)".to_string()]
        );
        act.waves[1] = wave(WaveStatus::Failed);
        assert_eq!(
            progress.lines(&act),
            vec!["  ✗ Wave 2: Failed (2/3 applied, 1 failed)".to_string()]
        );
        assert!(progress.lines(&act).is_empty());

        // An attempt that stopped is reported once, and the waves of the
        // next attempt are reported from the first.
        act.failed_attempts = 1;
        act.failure_reason = Some("Secret/db@app: cannot decrypt SOPS file db.yaml\n  more".into());
        assert_eq!(
            progress.lines(&act),
            vec![
                "  ✗ Attempt 1 failed. The Kix operator will retry in 30 seconds.".to_string(),
                "    Secret/db@app: cannot decrypt SOPS file db.yaml".to_string(),
            ]
        );
        assert!(progress.lines(&act).is_empty());
        act.waves = vec![];
        assert!(progress.lines(&act).is_empty());
        act.waves = vec![wave(WaveStatus::Complete)];
        assert_eq!(
            progress.lines(&act),
            vec!["  ✓ Wave 1: Complete (2/3 applied, 1 failed)".to_string()]
        );
    }

    /// An attempt that failed before the deploy began leaves the record
    /// Queued, and the watch reports it as it reports one on a Deploying
    /// record. A count left on a current record is not reported.
    #[test]
    fn the_watch_reports_an_attempt_on_a_queued_record() {
        let mut act = Record {
            phase: PHASE_QUEUED.into(),
            failed_attempts: 1,
            failure_reason: Some("cannot read the build at /nix/store/x".into()),
            ..Default::default()
        };
        assert_eq!(
            Progress::default().lines(&act),
            vec![
                "  ✗ Attempt 1 failed. The Kix operator will retry in 30 seconds.".to_string(),
                "    cannot read the build at /nix/store/x".to_string(),
            ]
        );
        act.phase = PHASE_ACTIVE.into();
        assert!(Progress::default().lines(&act).is_empty());
    }

    /// Verify that a record deleted while watching returns an error naming the record.
    #[tokio::test]
    async fn a_record_that_vanishes_is_named() {
        let api = FakeApi::new([]);
        let records = open_records(&api.client()).await.unwrap();
        let err = watch_activation_progress(&records, "rec", "r1")
            .await
            .unwrap_err()
            .to_string();
        assert_eq!(err, "Activation 'rec' no longer exists");
    }

    /// Verify that a `Failed` record surfaces `status.failure.reason` in the returned error.
    #[tokio::test]
    async fn a_failed_record_reports_why() {
        let mut failed = record("rec", "Failed");
        failed["status"]["failure"] =
            json!({ "reason": "cancelled", "at": "2026-10-09T00:00:00Z" });
        let api = FakeApi::new([failed]);
        let records = open_records(&api.client()).await.unwrap();
        let err = watch_activation_progress(&records, "rec", "r1")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.ends_with("'rec': cancelled"), "{err}");
    }
}
