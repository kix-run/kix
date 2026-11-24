//! The engine's interface to the cluster.
//!
//! Every apiserver call and every other piece of I/O the deploy engine
//! performs goes through three seams:
//!
//! - `ResourceIo` manages the objects of the plan (apply, read, recreate, wait
//!   for readiness, refresh discovery, and prune).
//! - `DeployRecord` manages the engine's view of the run's Activation record
//!   (begin, checkpoint, stamp unchanged objects, abort, and finalize), built on
//!   `activation::Records`.
//! - `SecretHydrator` decrypts SOPS-backed Secret data before an apply.
//!
//! A run reaches them through one `Cluster`, which has three implementations:
//!
//! - `KubeResources`, `ActivationRecord`, and `SopsHydrator` operate
//!   against a real cluster. `resources.rs` is the only file in the engine
//!   that uses `kube::Api`.
//! - `DryRun` wraps `KubeResources` and `SopsHydrator` and sends every
//!   write with `dryRun=All`, journaling what the apiserver answered. A dry
//!   run has no record. Whether a run is dry is decided by which
//!   `Cluster` constructor created it.
//! - `scripted::ScriptedOps` is the fake the engine's tests run against.
//!   Each call is scripted to complete immediately, after a virtual delay,
//!   when the test opens a gate, or never, making parked futures visible to
//!   tests.
//!
//! The engine never sees an `ApiResource`. Kind resolution, discovery
//! refresh, and the Activation record's writes live behind these seams, so
//! `run_deploy` handles only ordering, admission, and verdicts.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};

use async_trait::async_trait;
use serde_json::Value;
use thiserror::Error;

use crate::legacy_domain::LegacyDomainError;
use crate::manifest::types::ResourceId;

use super::activation::RecordsError;
use super::apply::{ApplyError, ApplyResult};
use super::cancel::CancelToken;
use super::errors::FetchError;
use super::errors::describe;
use super::prune_guard::{PruneError, Pruned};
use super::readiness::{Deletion, ImportTarget, ReadinessError, ReadinessResult, Stuck};
use super::secrets::{HydrationResult, SecretError};
use crate::build_source::SopsSources;

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
    /// When the live object is being deleted, wait for it to be gone
    /// ([`super::readiness::wait_gone`], `timeout` as its budget, reporting
    /// to `on_status`), then create it.
    async fn apply(
        &self,
        manifest: &Value,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ApplyResult, ApplyError>;

    /// Read the live object, returning `Ok(None)` when absent. Performs a real
    /// read even during a dry run.
    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError>;

    /// Delete the live object, wait for it to be gone, and re-apply. Called
    /// after an immutable-field conflict when the engine has pre-authorized the
    /// delete (the resource is in the orphan set), and for a live resource that
    /// carries `kix.run/rerun` and must run again. A missing object is not
    /// an error, whereas an object still present after the wait is. The wait
    /// is [`super::readiness::wait_gone`] with `timeout` as its budget.
    async fn recreate_in_place(
        &self,
        manifest: &Value,
        timeout: Duration,
        cancel: &CancelToken,
    ) -> Result<ApplyResult, RecreateError>;

    /// Wait for the object (or, for an import marker, the object it
    /// describes) to be ready. `applied_at` is when this deploy changed the
    /// object, or `None` when it left the object as it was; a declared
    /// failure state the controller last reported before that time is not
    /// trusted. `on_status` is called on every poll.
    async fn wait_ready(
        &self,
        rid: &ResourceId,
        import_target: Option<&ImportTarget>,
        applied_at: Option<DateTime<Utc>>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ReadinessResult, ReadinessError>;

    /// Refresh discovery after CRDs land. An error stops the run because a stale
    /// discovery view is a partial view. [`KubeResources`] first waits out listed
    /// group versions that answer 404 (`discovery::discover_resources`), so an
    /// error here means discovery did not settle within
    /// `discovery::DISCOVERY_SETTLE` or failed outright.
    async fn rediscover(&self) -> Result<(), FetchError>;

    /// Delete an orphan, unless another Kix cluster still deploys it, it
    /// changed since it was read, or it is already being deleted (see
    /// [`super::prune_guard`]). The object may still be on the cluster when
    /// this returns; [`ResourceIo::wait_gone`] waits for it.
    async fn prune(&self, rid: &ResourceId) -> Result<Pruned, DeleteError>;

    /// Wait for the object `rid` with uid `uid`, which [`ResourceIo::prune`]
    /// deleted, to be gone ([`super::readiness::wait_gone`]). A dry run
    /// deleted nothing, so it does not wait.
    async fn wait_gone(
        &self,
        rid: &ResourceId,
        uid: Option<&str>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<Deletion, ReadError>;
}

/// The run's Activation record, as the engine writes it.
///
/// Every method is best-effort from the engine's point of view. The engine
/// reports a failure as a `BestEffortFailed` event and continues, except that a
/// failed [`DeployRecord::finalize`] means the run did not succeed. The
/// engine bounds each call in time, and [`ActivationRecord`] also bounds its
/// checkpoint, abort, and finalize with a shorter limit of its own.
/// [`DeployRecord::discovery_refreshed`] runs inside the discovery refresh,
/// which the watchdog monitors.
#[async_trait]
pub(crate) trait DeployRecord: Send + Sync + 'static {
    /// Create the Activation record, mark it `Deploying`, and read the set of
    /// live Activations used to prune `kix.run/activations`. Nothing is in
    /// flight yet, so the engine may await this inline.
    ///
    /// Creating the record before the first node ensures that a run stopping
    /// midway still leaves a record of what it attempted. On a cluster's first
    /// deploy, the record's own CRD is not served yet, so the implementation
    /// may defer creation to [`DeployRecord::discovery_refreshed`].
    ///
    /// Returns an error to stop the run before its first node when a record is
    /// configured but cannot be written ([`RecordWriteError::Domain`]).
    async fn begin(&self) -> Result<(), RecordWriteError>;

    /// Retry creating a pending Activation record after CRD discovery refreshes.
    /// On a cluster's first deploy, this is the first moment the Activation CRD
    /// is established.
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

    /// Mark the Activation record `Failed` when the run ends without finalizing
    /// (cancelled, stopped on a failed node, discovery failed, or a task
    /// panicked) so the next deploy can see that this closure was partially
    /// applied. Called at most once, and only after [`DeployRecord::begin`].
    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError>;

    /// Finalize the Activation lifecycle by marking the new record Active (or
    /// Degraded) and the old one Superseded. Returns `Ok(None)` when there is
    /// no Activation to finalize (no name configured or CRD absent).
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

/// The cluster interface used by a single deploy run. Constructed either as a
/// live cluster with an Activation record or as a dry run without one.
pub(crate) struct Cluster {
    resources: Arc<dyn ResourceIo>,
    secrets: Arc<dyn SecretHydrator>,
    /// `None` for a dry run, which writes no record.
    record: Option<Arc<dyn DeployRecord>>,
}

impl Cluster {
    /// Construct a live cluster interface and its [`ActivationRecord`].
    pub(crate) fn new(
        resources: KubeResources,
        record: RecordConfig,
        sops: SopsSources,
    ) -> (Self, Arc<ActivationRecord>) {
        let resources = Arc::new(resources);
        let record = Arc::new(ActivationRecord::new(resources.clone(), record));
        let cluster = Cluster {
            resources,
            secrets: Arc::new(SopsHydrator::new(sops)),
            record: Some(record.clone()),
        };
        (cluster, record)
    }

    /// Construct a dry-run cluster interface (`dryRun=All`, no deploy record).
    pub(crate) fn dry_run(dry: Arc<DryRun>) -> Self {
        Cluster {
            resources: dry.clone(),
            secrets: dry,
            record: None,
        }
    }

    /// Construct a cluster interface backed by [`scripted::ScriptedOps`] for tests.
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

    /// Return the run's deploy record, or `None` for a dry run.
    pub(crate) fn record(&self) -> Option<&Arc<dyn DeployRecord>> {
        self.record.as_ref()
    }

    pub(crate) fn is_dry_run(&self) -> bool {
        self.record.is_none()
    }
}

/// A kind the discovery cache does not have.
#[derive(Debug, Error)]
#[error(
    "this Kubernetes cluster does not serve resource kind `{kind}` (not applied). If `{kind}` is a custom resource installed by an operator or another Kix cluster, install its CustomResourceDefinition on this cluster first. If this build installs that CustomResourceDefinition, wait for it to become Established and run `kix deploy` again."
)]
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
    /// A failure a test scripted, with its message.
    #[cfg(any(test, feature = "test-util"))]
    #[error("{0}")]
    Scripted(String),
}

/// Why [`ResourceIo::get_live`] could not read the live object.
#[derive(Debug, Error)]
pub(crate) enum ReadError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    #[error("get failed: {}", describe(.0))]
    Get(kube::Error),
    /// A failure a test scripted, with its message.
    #[cfg(any(test, feature = "test-util"))]
    #[error("{0}")]
    Scripted(String),
}

/// Why [`ResourceIo::recreate_in_place`] did not recreate the object.
#[derive(Debug, Error)]
pub(crate) enum RecreateError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    #[error("delete failed: {}", describe(.0))]
    Delete(kube::Error),
    /// The object outlived the deletion wait and was not re-applied because the
    /// apply would fail with the same immutable-field 422.
    #[error(
        "{}",
        super::readiness::stuck_message(.rid, .stuck)
    )]
    StillExists { rid: ResourceId, stuck: Stuck },
    /// The cancel token fired while the deleted object was still there.
    #[error("interrupted while waiting for {0} to be deleted; the new object was not applied")]
    Cancelled(ResourceId),
    /// The object could not be read while waiting for it to be gone.
    #[error("could not read {rid} while waiting for it to be deleted: {}", describe(.source))]
    WaitGone {
        rid: ResourceId,
        source: kube::Error,
    },
    #[error("re-apply failed: {0}")]
    Reapply(ApplyError),
    #[error("dry-run re-apply failed: {0}")]
    DryRunReapply(ApplyError),
    /// A failure a test scripted, with its message.
    #[cfg(any(test, feature = "test-util"))]
    #[error("{0}")]
    Scripted(String),
}

/// Why [`DeployRecord::stamp_unchanged`] did not stamp a resource.
#[derive(Debug, Error)]
pub(crate) enum StampError {
    #[error("this Kubernetes cluster does not serve this resource's kind")]
    NotDiscovered,
    #[error(transparent)]
    Apply(ApplyError),
    /// A failure a test scripted, with its message.
    #[cfg(any(test, feature = "test-util"))]
    #[error("{0}")]
    Scripted(String),
}

/// Why [`ResourceIo::prune`] did not delete an orphan.
#[derive(Debug, Error)]
pub(crate) enum DeleteError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    /// The records sit under a retired group, so no prune guard can tell
    /// what other Kix clusters deploy.
    #[error(transparent)]
    Domain(LegacyDomainError),
    #[error(transparent)]
    Prune(PruneError),
    /// A failure a test scripted, with its message.
    #[cfg(any(test, feature = "test-util"))]
    #[error("{0}")]
    Scripted(String),
}
