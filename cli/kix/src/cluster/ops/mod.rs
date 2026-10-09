//! The engine's interface to the cluster.
//!
//! Every apiserver call and every other piece of I/O the deploy engine
//! performs goes through three seams:
//!
//! - `ResourceIo`: the objects of the plan. Apply, read, recreate, wait
//!   for readiness, refresh discovery, prune.
//! - `DeployRecord`: the engine's view of the run's Activation record.
//!   Begin, checkpoint, stamp unchanged objects, abort, finalize. Built on
//!   `activation::Records`.
//! - `SecretHydrator`: decrypt SOPS-backed Secret data before an apply.
//!
//! A run reaches them through one `Cluster`. Its implementations:
//!
//! - `KubeResources`, `ActivationRecord` and `SopsHydrator` work
//!   against a real cluster. `resources.rs` is the only file in the engine
//!   that knows `kube::Api`.
//! - `DryRun` wraps `KubeResources` and `SopsHydrator` and sends every
//!   write with `dryRun=All`, journaling what the apiserver answered. A dry
//!   run has no record. Whether a run is dry is decided here, by which
//!   `Cluster` constructor made it, and nowhere else.
//! - `scripted::ScriptedOps` is the fake the engine's tests run against.
//!   Its calls do not complete on their own: a test scripts each one to
//!   complete now, after a virtual delay, when the test releases a gate, or
//!   never. That is what makes a parked future visible to a test.
//!
//! The engine never sees an `ApiResource`. Kind resolution, discovery
//! refresh and the Activation record's writes live behind the seams, so
//! `run_deploy` is about ordering, admission and verdicts and nothing else.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;
use thiserror::Error;

use crate::legacy_domain::LegacyDomainError;
use crate::manifest::types::ResourceId;

use super::activation::RecordsError;
use super::apply::{ApplyError, ApplyResult};
use super::cancel::CancelToken;
use super::errors::describe;
use super::fetch::FetchError;
use super::prune_guard::{PruneError, Pruned};
use super::readiness::{ImportTarget, ReadinessError, ReadinessResult};
use super::secrets::{HydrationResult, SecretError};

mod dry_run;
mod record;
mod resources;
#[cfg(any(test, feature = "test-util"))]
pub mod scripted;
mod sops;

pub(crate) use dry_run::DryRun;
pub(crate) use record::{ActivationRecord, RecordConfig};
pub(crate) use resources::KubeResources;
pub(crate) use sops::SopsHydrator;

/// The Activation lifecycle was finalized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finalized {
    /// The Activation now marked Active (or Degraded).
    pub activation: String,
    /// The Activation marked Superseded, if there was one.
    pub previous: Option<String>,
}

/// Progress callback for readiness waits. Called on every poll so the
/// watchdog sees a long but healthy wait as activity.
pub(crate) type OnStatus<'a> = &'a (dyn Fn(&str) + Send + Sync);

/// The objects of the plan, as the engine reads and writes them.
#[async_trait]
pub(crate) trait ResourceIo: Send + Sync + 'static {
    /// Server-side apply one manifest, resolving its kind from discovery.
    async fn apply(&self, manifest: &Value) -> Result<ApplyResult, ApplyError>;

    /// Read the live object, `Ok(None)` when there is none. A read even
    /// under dry run.
    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError>;

    /// Delete the live object, wait for it to go, re-apply. Called after an
    /// immutable-field conflict when the engine has pre-authorized the
    /// delete (the rid is in the orphan set), and for a live resource that
    /// carries `kix.run/rerun` and must run again. A missing object is not
    /// an error; an object still present after the wait is.
    async fn recreate_in_place(&self, manifest: &Value) -> Result<ApplyResult, RecreateError>;

    /// Wait for the object (or, for an import marker, the object it
    /// describes) to be ready. `on_status` is called on every poll.
    async fn wait_ready(
        &self,
        rid: &ResourceId,
        import_target: Option<&ImportTarget>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ReadinessResult, ReadinessError>;

    /// Refresh discovery after CRDs landed. An error stops the run: a stale
    /// discovery view is a partial view (rule from kixpkgs#60).
    /// [`KubeResources`] first waits out listed group versions that answer
    /// 404 (`fetch::discover_resources`), so an error here means discovery
    /// did not settle within `fetch::DISCOVERY_SETTLE` or failed outright.
    async fn rediscover(&self) -> Result<(), FetchError>;

    /// Delete an orphan, unless another Kix cluster still deploys it or it
    /// changed since it was read (see [`super::prune_guard`]).
    async fn delete(&self, rid: &ResourceId) -> Result<Pruned, DeleteError>;
}

/// The run's Activation record, as the engine writes it.
///
/// Every method is best-effort from the engine's point of view: it reports
/// a failure as a `BestEffortFailed` event and carries on, except that a
/// failed [`DeployRecord::finalize`] means the run did not succeed. Each is
/// bounded in time by the implementation.
#[async_trait]
pub(crate) trait DeployRecord: Send + Sync + 'static {
    /// Start of run. Creates the Activation record, marks it Deploying, and
    /// reads the set of live Activations used to prune `kix.run/activations`.
    /// Nothing is in flight yet, so the engine may await this inline.
    ///
    /// The record is created here rather than only as the last node of the
    /// plan so that a run which stops part way still leaves something that
    /// says what it was attempting (kixpkgs#82). On a cluster's first deploy
    /// the record's own CRD is not served yet, so the implementation may
    /// defer the create to [`DeployRecord::discovery_refreshed`].
    async fn begin(&self);

    /// Discovery was refreshed after CRDs landed. On a cluster's first
    /// deploy this is the first moment the Activation CRD is established,
    /// so a create deferred by [`DeployRecord::begin`] happens here.
    async fn discovery_refreshed(&self);

    /// Record progress. `applied` and `failed` are running totals.
    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), RecordWriteError>;

    /// Stamp the current activation on a resource the run did not apply
    /// because it was unchanged.
    async fn stamp_unchanged(&self, rid: &ResourceId) -> Result<(), StampError>;

    /// The run is ending without finalizing: cancelled, stopped on a failed
    /// node, discovery broke, or a task panicked. Marks the record Failed so
    /// the next deploy can see that this closure was partially applied.
    /// Called at most once, and only after [`DeployRecord::begin`].
    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError>;

    /// Finalize the Activation lifecycle: new one Active (or Degraded), old
    /// one Superseded. `Ok(None)` when there is no Activation to finalize
    /// (no name configured, CRD absent).
    ///
    /// `orphans_left` is true when the run reported orphans it did not delete
    /// (warn-only, skip, or a failed delete), so the record must keep naming
    /// the builds they came from.
    async fn finalize(
        &self,
        had_failures: bool,
        orphans_left: bool,
    ) -> Result<Option<Finalized>, RecordWriteError>;
}

/// Decrypts SOPS-backed data in a Secret manifest before it is applied.
#[async_trait]
pub(crate) trait SecretHydrator: Send + Sync + 'static {
    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError>;
}

/// The cluster as one run of the engine reaches it. Made only by the
/// constructors below, so a run is either a real one with a record or a
/// dry one without.
pub(crate) struct Cluster {
    resources: Arc<dyn ResourceIo>,
    secrets: Arc<dyn SecretHydrator>,
    /// `None` for a dry run, which writes no record.
    record: Option<Arc<dyn DeployRecord>>,
}

impl Cluster {
    /// A run that writes: the objects, and the record that tracks them.
    pub(crate) fn new(
        resources: Arc<KubeResources>,
        record: Arc<ActivationRecord>,
        secrets: SopsHydrator,
    ) -> Self {
        Cluster {
            resources,
            secrets: Arc::new(secrets),
            record: Some(record),
        }
    }

    /// A dry run: every write goes with `dryRun=All`, and there is no record.
    pub(crate) fn dry_run(dry: Arc<DryRun>) -> Self {
        Cluster {
            resources: dry.clone(),
            secrets: dry,
            record: None,
        }
    }

    /// The scripted fake as all three seams, dry when the fake is set to be.
    #[cfg(any(test, feature = "test-util"))]
    pub(crate) fn scripted(ops: Arc<scripted::ScriptedOps>) -> Self {
        let record: Option<Arc<dyn DeployRecord>> = if ops.is_dry_run() {
            None
        } else {
            Some(ops.clone())
        };
        Cluster {
            resources: ops.clone(),
            secrets: ops,
            record,
        }
    }

    pub(crate) fn resources(&self) -> &Arc<dyn ResourceIo> {
        &self.resources
    }

    pub(crate) fn secrets(&self) -> &Arc<dyn SecretHydrator> {
        &self.secrets
    }

    /// The run's record, `None` for a dry run.
    pub(crate) fn record(&self) -> Option<&Arc<dyn DeployRecord>> {
        self.record.as_ref()
    }

    pub(crate) fn is_dry_run(&self) -> bool {
        self.record.is_none()
    }
}

/// A kind the discovery cache does not have.
#[derive(Debug, Error)]
#[error("kind {kind} not in discovery cache")]
pub(crate) struct NotDiscovered {
    pub(crate) kind: String,
}

/// A write to the Activation record that failed. The engine reports it as
/// best-effort and carries on.
#[derive(Debug, Error)]
pub(crate) enum RecordWriteError {
    #[error("{}", describe(.0))]
    Records(RecordsError),
    /// The records sit under a retired group, so there is no record to
    /// write.
    #[error(transparent)]
    Domain(LegacyDomainError),
    /// The write did not answer within the implementation's bound.
    #[error("no answer within {}s", .0.as_secs())]
    NoAnswer(Duration),
}

/// Why [`ResourceIo::get_live`] could not read the live object.
#[derive(Debug, Error)]
pub(crate) enum ReadError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    #[error("get failed: {}", describe(.0))]
    Get(kube::Error),
}

/// Why [`ResourceIo::recreate_in_place`] did not recreate the object.
#[derive(Debug, Error)]
pub(crate) enum RecreateError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    #[error("delete failed: {}", describe(.0))]
    Delete(kube::Error),
    /// The object outlived the wait for it to go, so it was not re-applied:
    /// the apply would fail with the same immutable-field 422.
    #[error("{rid} still exists {}s after delete (stuck finalizer?); not re-applied", .waited.as_secs())]
    StillExists { rid: ResourceId, waited: Duration },
    #[error("re-apply failed: {0}")]
    Reapply(ApplyError),
    #[error("dry-run re-apply failed: {0}")]
    DryRunReapply(ApplyError),
}

/// Why [`DeployRecord::stamp_unchanged`] did not stamp a resource.
#[derive(Debug, Error)]
pub(crate) enum StampError {
    #[error("kind not in discovery cache")]
    NotDiscovered,
    #[error(transparent)]
    Apply(ApplyError),
}

/// Why [`ResourceIo::delete`] did not delete an orphan.
#[derive(Debug, Error)]
pub(crate) enum DeleteError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    /// The records sit under a retired group, so no prune guard can tell
    /// what other Kix clusters deploy.
    #[error(transparent)]
    Domain(LegacyDomainError),
    #[error(transparent)]
    Guard(PruneError),
}
