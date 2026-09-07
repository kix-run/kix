//! The engine's one seam to the cluster (doc 134 §2.5).
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

use crate::manifest::types::ResourceId;

use super::apply::{ApplyError, ApplyResult};
use super::cancel::CancelToken;
use super::fetch::FetchError;
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

/// Progress callback for readiness waits. Called on every poll so the
/// watchdog sees a long but healthy wait as activity.
pub type OnStatus<'a> = &'a (dyn Fn(&str) + Send + Sync);

/// Everything the deploy engine does to a cluster.
///
/// Methods that return `Result<_, String>` are best-effort from the engine's
/// point of view: it reports the failure as a `BestEffortFailed` event and
/// carries on. The others decide verdicts or stop the run.
#[async_trait]
pub trait ClusterOps: Send + Sync + 'static {
    /// Whether writes go to the apiserver with `dryRun=All`. The engine
    /// checks this against its own flag once, at the start of a run: the
    /// two must agree or readiness would poll objects that were never
    /// persisted.
    fn dry_run(&self) -> bool;

    /// Start of run. Stamps deploy-start on the Activation and reads the set
    /// of live Activations used to prune `kix.dev/activations`. Nothing is
    /// in flight yet, so the engine may await this inline.
    async fn begin(&self) -> Result<(), String>;

    /// Decrypt SOPS-backed data in a Secret manifest.
    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError>;

    /// Server-side apply one manifest, resolving its kind from discovery.
    async fn apply(&self, manifest: &Value) -> Result<ApplyResult, ApplyError>;

    /// Delete the live object, wait for it to go, re-apply. Only called when
    /// the engine has pre-authorized the delete (the rid is in the orphan
    /// set) after an immutable-field conflict.
    async fn recreate_in_place(&self, manifest: &Value) -> Result<ApplyResult, String>;

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
    async fn rediscover(&self) -> Result<(), FetchError>;

    /// Record progress on the Activation. `applied` and `failed` are running
    /// totals. Best-effort; bounded in time by the implementation.
    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), String>;

    /// Stamp the current activation on a resource the run did not apply
    /// because it was unchanged. Best-effort.
    async fn record_activation_on_skipped(&self, rid: &ResourceId) -> Result<(), String>;

    /// Delete an orphan.
    async fn delete(&self, rid: &ResourceId) -> Result<(), String>;

    /// Finalize the Activation lifecycle: new one Active (or Degraded), old
    /// one Superseded. `Ok(None)` when there is no Activation to finalize
    /// (no name configured, CRD absent, dry run).
    async fn finalize(&self, had_failures: bool) -> Result<Option<Finalized>, String>;
}
