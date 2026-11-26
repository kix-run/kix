//! The engine's interface to the cluster.
//!
//! Every apiserver call and every other piece of I/O the deploy engine
//! performs goes through three seams:
//!
//! - `ResourceIo` manages the objects of the plan (apply, read, recreate, wait
//!   for readiness, refresh discovery, and prune).
//! - `DeployRecord` manages the engine's view of the run's Activation record
//!   (begin, checkpoint, applied hashes, abort, finalize, and the end of a
//!   partial deploy), built on
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
pub(crate) use resources::{Force, KubeResources};
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
    /// this returns; [`ResourceIo::wait_gone`] waits for it. `propagation`
    /// comes from [`super::graph::DeleteOrder::propagation`].
    async fn prune(
        &self,
        rid: &ResourceId,
        propagation: kube::api::PropagationPolicy,
    ) -> Result<Pruned, DeleteError>;

    /// Write the migration write ([`super::migration_write`]) to the
    /// object `rid` of the build, which the run did not apply because it was
    /// unchanged, when the plan listed it and the run has not written it
    /// yet. Return whether it wrote.
    async fn migrate_unchanged(
        &self,
        _rid: &ResourceId,
    ) -> Result<bool, super::migration_write::WriteError> {
        Ok(false)
    }

    /// Once the run's record is final: write the migration write to each
    /// orphan of `left`, the ones the run left on the cluster, that the plan
    /// listed, and give up the fields of each orphan another Kix cluster
    /// still deploys. Return what failed, one message for each object.
    async fn after_finalize(&self, _left: &[ResourceId]) -> Vec<String> {
        Vec::new()
    }

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
#[async_trait]
pub(crate) trait DeployRecord: Send + Sync + 'static {
    /// Create the Activation record and the revisions it names, and mark it
    /// `Deploying`. Nothing is in flight yet, so the engine may await this
    /// inline.
    ///
    /// Creating the record before the first node ensures that a run stopping
    /// midway still leaves a record of what it attempted. The record's kind is
    /// always served, because taking the deploy lock installed it.
    ///
    /// Returns an error to stop the run before its first node when a record is
    /// configured but it or the revisions it names cannot be written.
    async fn begin(&self) -> Result<(), RecordWriteError>;

    /// Record progress. `applied` and `failed` are running totals.
    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), RecordWriteError>;

    /// Write the applied hash of each object the run applied since the last
    /// call to `status.applied` of every kept revision of the run's Kix
    /// cluster that names the object, and carry the hashes of the objects
    /// the run did not apply into the new revisions of changed instances
    /// ([`super::revision::applied::pending`]). The engine calls it once the
    /// nodes finish and before it marks a stopped run `Failed`. A call with
    /// nothing new writes nothing.
    async fn write_applied(&self) -> Result<(), RecordWriteError>;

    /// Mark the Activation record `Failed` when the run ends without finalizing
    /// (cancelled, stopped on a failed node, discovery failed, or a task
    /// panicked) so the next deploy can see that this closure was partially
    /// applied. Called at most once, and only after [`DeployRecord::begin`].
    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError>;

    /// Renew the run's deploy lock right before the prune deletes anything,
    /// so the deletes start with a whole lease ahead of them. A run without
    /// a lock does nothing.
    async fn before_prune(&self) -> Result<(), RecordWriteError>;

    /// End a run that applied the part of the build `kix deploy --only`
    /// selected: mark the record `Partial`, leaving the previous record
    /// current ([`super::activation::Records::end_partial`]). Called instead
    /// of [`DeployRecord::finalize`], and only when every node succeeded.
    async fn end_partial(&self) -> Result<(), RecordWriteError>;

    /// Finalize the Activation lifecycle by marking the new record Active (or
    /// Degraded) and the old one Superseded. Returns `Ok(None)` when there is
    /// no Activation to finalize (no name configured or CRD absent).
    ///
    /// `left` names the orphans the run did not delete (warn-only, skip, or
    /// a failed delete). The record lists them in a kept-orphans revision.
    async fn finalize(
        &self,
        had_failures: bool,
        left: Left<'_>,
    ) -> Result<Option<Finalized>, RecordWriteError>;
}

/// The migration writes a run makes ([`super::migration_write`]), as the
/// plan listed them.
#[derive(Debug, Clone, Default)]
pub(crate) struct Migrations {
    /// The objects of the build that need the write. The run writes it
    /// right before it applies one, and once the nodes finish to each one
    /// it did not apply because it was unchanged.
    pub(crate) objects: std::collections::HashSet<ResourceId>,
    /// The objects of `objects` whose `Apply` entry under `kix` the write
    /// moves to the cluster's manager. A dry run applies them under `kix`.
    pub(crate) renamed: std::collections::HashSet<ResourceId>,
    /// The orphans that need the write. The run writes it to those it left
    /// on the cluster once its record is final and lists them.
    pub(crate) orphans: Vec<ResourceId>,
    /// The orphans another Kix cluster still deploys. Once the record is
    /// final, the run gives up its fields on each with an empty apply, so
    /// its entry does not keep the object for ever.
    pub(crate) releases: Vec<ResourceId>,
    /// The applied hashes the notes of objects the run does not apply hold,
    /// which the run writes to its revisions with the hashes of what it
    /// applies ([`super::revision::applied::pending`]).
    pub(crate) carried: Vec<(super::revision::RevisionObject, String)>,
    pub(crate) rule: super::migration_write::Rule,
}

impl Migrations {
    /// Return how many objects the run writes the migration write to, at
    /// most.
    pub(crate) fn count(&self) -> usize {
        self.objects.len() + self.orphans.len()
    }
}

/// The orphans a run left on the cluster.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Left<'a> {
    /// Each orphan the run did not delete, leaving out the kinds Kix never
    /// prunes.
    pub(crate) orphans: &'a [ResourceId],
    /// Each orphan of a kind Kix never prunes (`lifecycle::never_pruned`).
    /// The kept-orphans revision names them so reports can list them.
    pub(crate) never_pruned: &'a [ResourceId],
    /// The manifests the run's orphans came from: the earlier builds for the
    /// CLI, the live objects for the operator.
    pub(crate) manifests: &'a [Value],
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
    /// The run lost its deploy lock, or its lease ran out.
    #[error(transparent)]
    Lock(super::head::WritesStopped),
    /// The deploy lock could not be written at the commit point.
    #[error(transparent)]
    Commit(super::head::CommitError),
    /// The run's record could not be created before the first node.
    #[error("cannot create deployment record `{name}`: {source}")]
    Create {
        name: String,
        #[source]
        source: ApplyError,
    },
    /// A revision the record names could not be created.
    #[error(transparent)]
    Revisions(super::revision::RevisionError),
    /// The applied hashes of the objects the run applied could not be
    /// written to the revisions.
    #[error(
        "cannot record the applied hashes of the objects this run applied: {0}. The next deploy reads their hashes as unknown"
    )]
    Applied(super::revision::keep::CleanError),
    /// The list of objects a deploy left on the cluster could not be read
    /// or written, so finalizing would lose track of them.
    #[error(
        "cannot record the objects this deploy left on the cluster: {0}. The deploy is not marked finished, so the next deploy or `kix gc` still sees the objects it left"
    )]
    KeptOrphans(String),
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

/// Why [`ResourceIo::prune`] did not delete an orphan.
#[derive(Debug, Error)]
pub(crate) enum DeleteError {
    /// Kix could not tell whether the cluster serves the object's kind.
    #[error(
        "Kix could not check whether Kubernetes recognizes this resource kind (not deleted): {0}"
    )]
    Discovery(FetchError),
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
