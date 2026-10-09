//! The engine's interface to cluster operations.
//!
//! Every apiserver call and every other piece of I/O the deploy engine
//! performs goes through [`ClusterOps`]. Two implementations:
//!
//! - [`KubeOps`] talks to a real cluster. It is the only file in the engine
//!   that knows `kube::Api`.
//! - [`scripted::ScriptedOps`] is the fake the engine's tests run against.
//!   Its calls do not complete on their own: a test scripts each one to
//!   complete now, after a virtual delay, when the test releases a gate, or
//!   never. That is what makes a parked future visible to a test.
//!
//! The engine never sees an `ApiResource`. Kind resolution, discovery
//! refresh, the Activation record and dry-run plumbing all live behind the
//! trait, so `run_deploy` is about ordering, admission and verdicts and
//! nothing else.

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

pub mod kube;
#[cfg(any(test, feature = "test-util"))]
pub mod scripted;

pub use kube::{KubeOps, KubeOpsConfig};

/// The Activation lifecycle was finalized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finalized {
    /// The Activation now marked Active (or Degraded).
    pub activation: String,
    /// The Activation marked Superseded, if there was one.
    pub previous: Option<String>,
}

/// A kind the discovery cache does not have.
#[derive(Debug, Error)]
#[error("kind {kind} not in discovery cache")]
pub struct NotDiscovered {
    pub kind: String,
}

/// A write to the Activation record that failed. The engine reports it as
/// best-effort and carries on.
#[derive(Debug, Error)]
pub enum RecordWriteError {
    #[error("{}", describe(.0))]
    Records(RecordsError),
    /// The write did not answer within the implementation's bound.
    #[error("no answer within {}s", .0.as_secs())]
    NoAnswer(Duration),
}

/// Why [`ClusterOps::get_live`] could not read the live object.
#[derive(Debug, Error)]
pub enum ReadError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    #[error("get failed: {}", describe(.0))]
    Get(::kube::Error),
}

/// Why [`ClusterOps::recreate_in_place`] did not recreate the object.
#[derive(Debug, Error)]
pub enum RecreateError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    #[error("delete failed: {}", describe(.0))]
    Delete(::kube::Error),
    /// The object outlived the wait for it to go, so it was not re-applied:
    /// the apply would fail with the same immutable-field 422.
    #[error("{rid} still exists {}s after delete (stuck finalizer?); not re-applied", .waited.as_secs())]
    StillExists { rid: ResourceId, waited: Duration },
    #[error("re-apply failed: {0}")]
    Reapply(ApplyError),
    #[error("dry-run re-apply failed: {0}")]
    DryRunReapply(ApplyError),
}

/// Why [`ClusterOps::record_activation_on_skipped`] did not stamp a
/// resource.
#[derive(Debug, Error)]
pub enum StampError {
    #[error("kind not in discovery cache")]
    NotDiscovered,
    #[error(transparent)]
    Apply(ApplyError),
}

/// Why [`ClusterOps::delete`] did not delete an orphan.
#[derive(Debug, Error)]
pub enum DeleteError {
    #[error(transparent)]
    NotDiscovered(#[from] NotDiscovered),
    /// The records sit under a retired group, so no prune guard can tell
    /// what other Kix clusters deploy.
    #[error(transparent)]
    Domain(LegacyDomainError),
    #[error(transparent)]
    Guard(PruneError),
}

/// Progress callback for readiness waits. Called on every poll so the
/// watchdog sees a long but healthy wait as activity.
pub type OnStatus<'a> = &'a (dyn Fn(&str) + Send + Sync);

/// Everything the deploy engine does to a cluster.
///
/// Failures of the Activation record's writes ([`RecordWriteError`]) and of
/// [`ClusterOps::record_activation_on_skipped`] are best-effort from the
/// engine's point of view: it reports them as a `BestEffortFailed` event and
/// carries on. The others decide verdicts or stop the run.
#[async_trait]
pub trait ClusterOps: Send + Sync + 'static {
    /// Whether writes go to the apiserver with `dryRun=All`. The engine
    /// checks this against its own flag once, at the start of a run: the
    /// two must agree or readiness would poll objects that were never
    /// persisted.
    fn dry_run(&self) -> bool;

    /// Start of run. Creates the Activation record, marks it Deploying, and
    /// reads the set of live Activations used to prune `kix.run/activations`.
    /// Nothing is in flight yet, so the engine may await this inline.
    ///
    /// The record is created here rather than only as the last node of the
    /// plan so that a run which stops part way still leaves something that
    /// says what it was attempting (kixpkgs#82). On a cluster's first deploy
    /// the record's own CRD is not served yet, so the implementation may
    /// defer the create to [`ClusterOps::rediscover`].
    async fn begin(&self);

    /// The run is ending without finalizing: cancelled, stopped on a failed
    /// node, discovery broke, or a task panicked. Marks the Activation
    /// record Failed so the next deploy can see that this closure was
    /// partially applied.
    ///
    /// Best-effort and bounded in time by the implementation. Called at most
    /// once, and only after [`ClusterOps::begin`] has run.
    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError>;

    /// Decrypt SOPS-backed data in a Secret manifest.
    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError>;

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
    /// discovery view is a partial view (rule from kixpkgs#60). `KubeOps`
    /// first waits out listed group versions that answer 404
    /// (`fetch::discover_resources`), so an error here means discovery did
    /// not settle within `fetch::DISCOVERY_SETTLE` or failed outright.
    ///
    /// Also where a create deferred by [`ClusterOps::begin`] happens, since
    /// this is the first moment on a cluster's first deploy at which the
    /// Activation CRD is established.
    async fn rediscover(&self) -> Result<(), FetchError>;

    /// Record progress on the Activation. `applied` and `failed` are running
    /// totals. Best-effort; bounded in time by the implementation.
    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), RecordWriteError>;

    /// Stamp the current activation on a resource the run did not apply
    /// because it was unchanged. Best-effort.
    async fn record_activation_on_skipped(&self, rid: &ResourceId) -> Result<(), StampError>;

    /// Delete an orphan, unless another Kix cluster still deploys it or it
    /// changed since it was read (see [`super::prune_guard`]).
    async fn delete(&self, rid: &ResourceId) -> Result<Pruned, DeleteError>;

    /// Finalize the Activation lifecycle: new one Active (or Degraded), old
    /// one Superseded. `Ok(None)` when there is no Activation to finalize
    /// (no name configured, CRD absent, dry run).
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
