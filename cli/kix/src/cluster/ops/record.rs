//! [`DeployRecord`] on a real cluster's Activation records.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;

use crate::eval::package_index::RecordPackageIndex;
use crate::manifest::types::ResourceId;

use super::super::activation::{
    self, KeptOrphanSource, KeptOrphans, Records, WaveRecord, WaveStatus,
};
use super::super::apply;
use super::super::errors::{FailureClass, classify};
use super::{DeployRecord, Finalized, KubeResources, RecordWriteError, StampError};

/// Timeout for best-effort writes (checkpoint and finalize). These writes run
/// on their own tasks so a slow write does not block the scheduler, and this
/// bound caps how long the end of the run waits for the final checkpoint and
/// finalize.
const BEST_EFFORT_TIMEOUT: Duration = Duration::from_secs(30);

/// What a run writes to its Activation record, beyond the cluster and the
/// identity hash its [`KubeResources`] carry.
pub(crate) struct RecordConfig {
    /// The record's name, or `None` when the run writes no lifecycle (such as
    /// the operator correcting drift).
    pub(crate) name: Option<String>,
    /// The record's own stamped manifest, so [`DeployRecord::begin`] can
    /// create it before the first node instead of waiting for it to run as the
    /// last node of the plan.
    ///
    /// Both places apply the same manifest with the same field manager and
    /// identity hash, so the final node's apply is a no-op that re-asserts
    /// `spec` once its dependencies are Ready. `None` for the operator, which
    /// created the record itself and owns `spec.source`.
    pub(crate) manifest: Option<Value>,
    /// Provenance to record on the Activation when the deploy finishes. The
    /// CLI computes this from the source tree, whereas the operator leaves it
    /// `None`.
    pub(crate) receipt: Option<Value>,
    /// Failed records whose leftovers this run's plan folded in. Superseded
    /// on finalize, because by then they describe nothing outstanding.
    pub(crate) consumed_failed: Vec<String>,
    /// What finalize writes to the record's `status.orphansKeptFrom`.
    pub(crate) kept_orphans: KeptOrphans,
    /// The build's package index, which [`DeployRecord::begin`] writes to
    /// `status.packageIndex`. `None` for the operator, which holds no build
    /// graph. The CLI wrote the index when it submitted the record.
    pub(crate) package_index: Option<RecordPackageIndex>,
    /// Whether [`DeployRecord::abort`] should mark the record Failed.
    ///
    /// True for the CLI, which owns the run end to end. False for the
    /// operator, which resumes on requeue when a reconcile returns early.
    pub(crate) mark_failed_on_abort: bool,
}

/// A run's Activation record, written through
/// [`super::super::activation::Records`].
pub(crate) struct ActivationRecord {
    /// The objects of the same run. The record is applied, and unchanged
    /// objects are stamped, through them.
    resources: Arc<KubeResources>,
    config: RecordConfig,
    /// Set when [`DeployRecord::begin`] wanted to create the record but its
    /// CRD was not served yet, which is every cluster's first deploy.
    /// [`DeployRecord::discovery_refreshed`] does it at the CRD barrier, the
    /// earliest point at which it can succeed.
    pending: AtomicBool,
    /// The `status.orphansKeptFrom` that [`DeployRecord::finalize`] wrote,
    /// for the caller's GC roots. `None` until a finalize succeeds.
    recorded_kept: std::sync::Mutex<Option<Vec<KeptOrphanSource>>>,
}

impl ActivationRecord {
    pub(super) fn new(resources: Arc<KubeResources>, config: RecordConfig) -> Self {
        ActivationRecord {
            resources,
            config,
            pending: AtomicBool::new(false),
            recorded_kept: std::sync::Mutex::new(None),
        }
    }

    /// Return the `status.orphansKeptFrom` written by `finalize`, or `None` if
    /// the run did not finalize.
    pub(crate) fn orphans_kept_from(&self) -> Option<Vec<KeptOrphanSource>> {
        self.recorded_kept.lock().ok().and_then(|g| g.clone())
    }

    /// Open the `Activation` records API for optional writes, logging any
    /// domain-gate error and returning `None` when the CRD is not served or the
    /// gate refuses.
    async fn logged_records(&self) -> Option<Records> {
        self.resources.records().await.unwrap_or_else(|e| {
            tracing::error!("{e}");
            None
        })
    }

    /// Return the configured record name and `Records` handle, or `None` when
    /// lifecycle recording is disabled or the CRD is not yet served. Propagates
    /// domain-gate errors so a cluster with retired records does not finalize
    /// as if it had none.
    async fn named_records(&self) -> Result<Option<(&str, Records)>, RecordWriteError> {
        let Some(name) = self.config.name.as_deref() else {
            return Ok(None);
        };
        let records = self
            .resources
            .records()
            .await
            .map_err(RecordWriteError::Domain)?;
        Ok(records.map(|records| (name, records)))
    }

    /// Create the Activation record and mark it Deploying.
    ///
    /// Returns false when the record CRD is not served yet (such as on a
    /// cluster's first deploy) so the caller can set `pending` and let
    /// [`DeployRecord::discovery_refreshed`] retry at the CRD barrier.
    ///
    /// The apply uses the same path as the plan's own node, so field manager,
    /// identity hash, and annotation stamping all match and the later apply is
    /// an unchanged no-op.
    async fn create(&self) -> bool {
        let Some(name) = self.config.name.as_ref() else {
            return true;
        };
        let Some(records) = self.logged_records().await else {
            return false;
        };

        // Only the CLI provides a manifest. When the operator reconciles an
        // existing Activation, it skips creation and marks the phase directly.
        if let Some(manifest) = self.config.manifest.as_ref() {
            let rid = ResourceId::from_value(manifest);
            let Some((manifest_ar, scope)) = self.resources.cached_kind(&rid.kind).await else {
                return false;
            };

            if let Err(e) = self.resources.apply_as(&manifest_ar, scope, manifest).await {
                // Non-fatal: the deploy can still proceed and create the record
                // as the final node in the plan. Marking the phase below will
                // 404 and be ignored.
                tracing::warn!(
                    activation = %name,
                    error = %e,
                    "could not create this run's deployment record before applying; continuing, \
                     but if the deploy fails part way, no deployment record will list what it applied",
                );
            }
        }

        if let Err(e) = records
            .begin_deploy(name, 1, self.config.package_index.as_ref())
            .await
        {
            // 404 when the CRD is served but the record does not exist yet
            // (either the up-front create failed or the operator's record was
            // deleted).
            tracing::debug!(activation = %name, error = %e, "could not mark the record Deploying");
        }
        true
    }
}

#[async_trait]
impl DeployRecord for ActivationRecord {
    async fn begin(&self) -> Result<(), RecordWriteError> {
        // A run with a record to write cannot write it on a cluster whose
        // records sit under a retired group, so it stops before applying.
        let records = match self.config.name {
            Some(_) => self
                .resources
                .records()
                .await
                .map_err(RecordWriteError::Domain)?,
            None => self.logged_records().await,
        };
        let Some(records) = records else {
            // No record CRD is served yet. On a cluster's first deploy, the CRD
            // is in this plan and the record is created at the CRD barrier in
            // `discovery_refreshed`.
            self.pending.store(true, Ordering::SeqCst);
            return Ok(());
        };

        // Read the live set BEFORE creating the record, so the annotation
        // stamped on the record itself is computed the same way as every
        // other resource's.
        self.resources
            .set_live_activations(records.live_hashes().await);

        if !self.create().await {
            self.pending.store(true, Ordering::SeqCst);
        }
        Ok(())
    }

    async fn discovery_refreshed(&self) {
        // On a cluster's first deploy, `begin` defers creating the record until
        // the Activation CRD applied by the plan is Established and discovery
        // refreshes here.
        if self.pending.load(Ordering::SeqCst)
            && let Some(records) = self.logged_records().await
        {
            self.resources
                .set_live_activations(records.live_hashes().await);
            if self.create().await {
                self.pending.store(false, Ordering::SeqCst);
            }
        }
    }

    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), RecordWriteError> {
        let Some((name, records)) = self.named_records().await? else {
            return Ok(());
        };
        // Record progress as a single synthetic wave to provide a liveness
        // pulse on the Activation status.
        let record = WaveRecord {
            wave_index: 0,
            status: if finalizing {
                WaveStatus::Complete
            } else {
                WaveStatus::Pending
            },
            resource_count: applied + failed,
            applied,
            failed,
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, records.record_waves(name, &[record])).await
        {
            Ok(Ok(())) => Ok(()),
            // The Activation CR is itself a node of the plan and lands in the
            // last wave, so on a cluster's first deploy every checkpoint
            // before it is a 404. That is expected, not a failure.
            Ok(Err(e)) if classify(&e.source) == FailureClass::NotFound => {
                tracing::debug!("activation not yet on cluster; checkpoint skipped");
                Ok(())
            }
            Ok(Err(e)) => Err(RecordWriteError::Records(e)),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }

    async fn stamp_unchanged(&self, rid: &ResourceId) -> Result<(), StampError> {
        let Some(hash) = self.resources.identity_hash() else {
            return Ok(());
        };
        // A skipped resource is by definition live, so its kind should be in
        // discovery. If it is not, say so rather than dropping it from the
        // count.
        let (ar, scope) = self
            .resources
            .cached_kind(&rid.kind)
            .await
            .ok_or(StampError::NotDiscovered)?;
        let live = self.resources.live_activations();
        apply::record_activation_on_skipped(
            self.resources.client(),
            &ar,
            scope,
            rid,
            hash,
            live.as_ref(),
        )
        .await
        .map_err(StampError::Apply)
    }

    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError> {
        if !self.config.mark_failed_on_abort {
            return Ok(());
        }
        let Some((name, records)) = self.named_records().await? else {
            return Ok(());
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, records.fail_deploy(name, reason)).await {
            Ok(Ok(())) => Ok(()),
            // Nothing to fail. The record never got created, which is the
            // pre-CRD window on a first deploy.
            Ok(Err(e)) if classify(&e.source) == FailureClass::NotFound => Ok(()),
            Ok(Err(e)) => Err(RecordWriteError::Records(e)),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }

    async fn finalize(
        &self,
        had_failures: bool,
        orphans_left: bool,
    ) -> Result<Option<Finalized>, RecordWriteError> {
        let Some((name, records)) = self.named_records().await? else {
            return Ok(None);
        };
        let cluster = self.resources.cluster();
        let work = async {
            let current = records.active(cluster).await.ok().flatten();
            let kept = self.config.kept_orphans.recorded(
                current.as_ref().map(|c| c.orphans_kept_from.as_slice()),
                orphans_left,
            );
            let old = current.filter(|old| old.name != name);
            records
                .finalize_deploy(
                    cluster,
                    name,
                    old.as_ref(),
                    had_failures,
                    self.config.receipt.as_ref(),
                    &self.config.consumed_failed,
                    &kept,
                )
                .await?;
            if let Ok(mut recorded) = self.recorded_kept.lock() {
                *recorded = Some(kept);
            }
            Ok::<_, activation::RecordsError>(Finalized {
                activation: name.to_string(),
                previous: old.map(|a| a.name),
            })
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, work).await {
            Ok(Ok(f)) => Ok(Some(f)),
            Ok(Err(e)) => Err(RecordWriteError::Records(e)),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::discovery;
    use crate::cluster::fake_api::FakeApi;

    async fn record(api: &FakeApi, name: Option<&str>) -> ActivationRecord {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        ActivationRecord::new(
            Arc::new(KubeResources::new(
                client,
                discovery,
                "a".into(),
                None,
                false,
            )),
            RecordConfig {
                name: name.map(str::to_string),
                manifest: None,
                receipt: None,
                consumed_failed: Vec::new(),
                kept_orphans: KeptOrphans::default(),
                package_index: None,
                mark_failed_on_abort: true,
            },
        )
    }

    /// On a cluster whose records sit under a retired group, a run with a
    /// record to write fails its begin, checkpoint, abort, and finalize with
    /// the gate's refusal instead of finalizing as if there were no record. A
    /// run that writes no lifecycle is not affected.
    #[tokio::test]
    async fn the_domain_gate_fails_the_record_writes() {
        let api = FakeApi::new([]);
        api.serve_retired_records();
        let named = record(&api, Some("act")).await;
        for err in [
            named.begin().await.unwrap_err(),
            named.checkpoint(1, 0, false).await.unwrap_err(),
            named.abort("stopped").await.unwrap_err(),
            named.finalize(false, false).await.unwrap_err(),
        ] {
            assert!(matches!(err, RecordWriteError::Domain(_)), "{err}");
            assert!(err.to_string().contains("kix migrate domain"), "{err}");
        }

        let unnamed = record(&api, None).await;
        assert!(unnamed.begin().await.is_ok());
        assert!(unnamed.checkpoint(1, 0, false).await.is_ok());
        assert!(unnamed.finalize(false, false).await.unwrap().is_none());
    }
}
