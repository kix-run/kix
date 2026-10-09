//! [`DeployRecord`] on a real cluster's Activation records.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;

use crate::manifest::types::ResourceId;

use super::super::activation::{
    self, KeptOrphanSource, KeptOrphans, Records, WaveRecord, WaveStatus,
};
use super::super::apply;
use super::super::errors::{FailureClass, classify};
use super::{DeployRecord, Finalized, KubeResources, RecordWriteError, StampError};

/// Best-effort writes (checkpoint, finalize) get this long. They run on
/// their own tasks so a slow one parks nothing, but the end of the run
/// awaits the last checkpoint and finalize inline; this keeps that bounded.
const BEST_EFFORT_TIMEOUT: Duration = Duration::from_secs(30);

/// What a run writes to its Activation record, beyond the cluster and the
/// identity hash its [`KubeResources`] carry.
pub(crate) struct RecordConfig {
    /// The record's name. `None` writes no lifecycle: the operator
    /// correcting drift.
    pub(crate) name: Option<String>,
    /// The record's own stamped manifest, so [`DeployRecord::begin`] can
    /// create it before the first node instead of waiting for it to come
    /// round as the last node of the plan.
    ///
    /// The same manifest either way, applied by the same field manager with
    /// the same identity hash, so the last-node apply of it is a no-op that
    /// re-asserts spec once everything it depends on is Ready. `None` for
    /// the operator: it created the record itself and owns `spec.source`.
    pub(crate) manifest: Option<Value>,
    /// Provenance to record on the Activation when the deploy finishes. The
    /// CLI computes it; the operator does not, because it never had a source
    /// tree to compute it from.
    pub(crate) receipt: Option<Value>,
    /// Failed records whose leftovers this run's plan folded in. Superseded
    /// on finalize, because by then they describe nothing outstanding.
    pub(crate) consumed_failed: Vec<String>,
    /// What finalize writes to the record's `status.orphansKeptFrom`.
    pub(crate) kept_orphans: KeptOrphans,
    /// Whether [`DeployRecord::abort`] should mark the record Failed.
    ///
    /// True for the CLI, which owns the run end to end. False for the
    /// operator, whose model is resume-on-requeue: a reconcile that returns
    /// early will be retried, so failing the record would fight it.
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

    /// The `status.orphansKeptFrom` the run's finalize wrote, or `None` when
    /// it did not finalize (no-op run, failure).
    pub(crate) fn orphans_kept_from(&self) -> Option<Vec<KeptOrphanSource>> {
        self.recorded_kept.lock().ok().and_then(|g| g.clone())
    }

    /// The records, for a write the run can do without: `None` when the
    /// record CRD is not served yet or the domain gate refuses, which is
    /// logged. The later writes report the refusal.
    async fn logged_records(&self) -> Option<Records> {
        self.resources.records().await.unwrap_or_else(|e| {
            tracing::error!("{e}");
            None
        })
    }

    /// The record's name and the records to write it through. `None` when
    /// the run writes no lifecycle or the record CRD is not served yet; the
    /// gate's refusal is an error, so a run on a cluster whose records sit
    /// under a retired group does not finalize as if it had none.
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
    /// Returns false when the record CRD is not served yet, which is a
    /// cluster's first deploy: the caller sets `pending` and
    /// [`DeployRecord::discovery_refreshed`] retries at the CRD barrier.
    ///
    /// The apply goes through the same path the plan's own node will take, so
    /// field manager, identity hash and annotation stamping all match and the
    /// later apply is an unchanged no-op.
    async fn create(&self) -> bool {
        let Some(name) = self.config.name.as_ref() else {
            return true;
        };
        let Some(records) = self.logged_records().await else {
            return false;
        };

        // Only the CLI brings a manifest. The operator's record already
        // exists on the cluster, because the operator is reconciling it, so
        // there is nothing to create and it goes straight to marking the
        // phase, which is what `begin` has always done for it.
        if let Some(manifest) = self.config.manifest.as_ref() {
            let rid = ResourceId::from_value(manifest);
            let Some((manifest_ar, scope)) = self.resources.cached_kind(&rid.kind).await else {
                return false;
            };

            if let Err(e) = self.resources.apply_as(&manifest_ar, scope, manifest).await {
                // Not fatal. Without the record the run behaves exactly as it
                // did before this existed, and the deploy itself is what
                // matters. Marking the phase below will 404 and be swallowed.
                tracing::warn!(
                    activation = %name,
                    error = %e,
                    "could not create the Activation record up front; a failure part way \
                     through this run will leave nothing to say what it applied",
                );
            }
        }

        if let Err(e) = records.begin_deploy(name, 1).await {
            // 404 on a cluster whose record CRD is served but whose record
            // does not exist yet: the create above failed, or this is the
            // operator on a record that has since gone.
            tracing::debug!(activation = %name, error = %e, "could not mark the record Deploying");
        }
        true
    }
}

#[async_trait]
impl DeployRecord for ActivationRecord {
    async fn begin(&self) {
        let Some(records) = self.logged_records().await else {
            // No record CRD served yet. On a cluster's first deploy the CRD is
            // in this very plan, so the record is created at the CRD barrier
            // instead; see `discovery_refreshed`.
            self.pending.store(true, Ordering::SeqCst);
            return;
        };

        // Read the live set BEFORE creating the record, so the annotation
        // stamped on the record itself is computed the same way as every
        // other resource's.
        self.resources
            .set_live_activations(records.live_hashes().await);

        if !self.create().await {
            self.pending.store(true, Ordering::SeqCst);
        }
    }

    async fn discovery_refreshed(&self) {
        // A cluster's first deploy carries the record's own CRD, so `begin`
        // could not create the record. This is the first moment it can: the
        // engine only refreshes discovery once a CRD it applied is
        // Established.
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
        // One synthetic "wave" until the Activation schema moves to per-node
        // progress; it still gives the operator a liveness pulse.
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
    use crate::cluster::fake_api::FakeApi;
    use crate::cluster::fetch;

    async fn record(api: &FakeApi, name: Option<&str>) -> ActivationRecord {
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
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
                mark_failed_on_abort: true,
            },
        )
    }

    /// On a cluster whose records sit under a retired group, a run with a
    /// record to write fails its checkpoint, abort and finalize with the
    /// gate's refusal instead of finalizing as if there were no record. A
    /// run that writes no lifecycle is not affected.
    #[tokio::test]
    async fn the_domain_gate_fails_the_record_writes() {
        let api = FakeApi::new([]);
        api.serve_retired_records();
        let named = record(&api, Some("act")).await;
        for err in [
            named.checkpoint(1, 0, false).await.unwrap_err(),
            named.abort("stopped").await.unwrap_err(),
            named.finalize(false, false).await.unwrap_err(),
        ] {
            assert!(matches!(err, RecordWriteError::Domain(_)), "{err}");
            assert!(err.to_string().contains("kix migrate domain"), "{err}");
        }

        let unnamed = record(&api, None).await;
        assert!(unnamed.checkpoint(1, 0, false).await.is_ok());
        assert!(unnamed.finalize(false, false).await.unwrap().is_none());
    }
}
