//! Types shared by the deploy scheduler and its observers.
//!
//! This module defines the per-node state machine and event shape for
//! DAG-streaming deploys. Each transition in the plan is one node; its state
//! advances through [`Verdict`] variants, and observers consume
//! [`DeployEvent`]s.
//!
//! The planner currently produces Apply, Skip, and Recreate transitions.
//! The remaining variants reserve the event shape for operations handled
//! outside the scheduler.

use std::time::Duration;

use crate::manifest::types::ResourceId;

use super::apply::ApplyAction;
use super::readiness::ImportTarget;

/// What kind of operation a node represents.
///
/// The planner tags every node in the plan with one of these. Rendering and
/// scheduling both branch on this tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TransitionKind {
    /// Server-side apply a manifest.
    Apply,
    /// Identity-hash unchanged; no work needed. Rendered dim, folded
    /// aggressively.
    Skip,
    /// Delete the live object, then apply. Tagged `recreate` because that
    /// is the act, whatever the trigger. The current producer is the
    /// rerun rule: a manifest carrying `kix.run/rerun` (a probe Job) whose
    /// identity hash changed is run again, never patched, and the reason
    /// rides [`NodeDetail::Rerun`]. The executor applies plainly when
    /// nothing is live.
    Recreate,
    /// Stateful migration pair barrier. Detection currently happens before
    /// scheduling.
    Migrate,
    /// Drain consumers before deleting their provider.
    Drain,
    /// Delete an orphaned resource.
    Delete,
    /// Wait for operator approval.
    Pause,
}

impl TransitionKind {
    /// Short tag used as the prefix in renderers.
    ///
    /// `Apply` has no prefix (it's the default); the others render their tag.
    pub fn tag(self) -> Option<&'static str> {
        match self {
            TransitionKind::Apply => None,
            TransitionKind::Skip => Some("skip"),
            TransitionKind::Recreate => Some("recreate"),
            TransitionKind::Migrate => Some("migrate"),
            TransitionKind::Drain => Some("drain"),
            TransitionKind::Delete => Some("delete"),
            TransitionKind::Pause => Some("pause"),
        }
    }
}

/// Terminal-or-in-flight state of a single node.
///
/// A node enters `Pending`, advances to `Running` when the scheduler picks it
/// up, and lands on exactly one of `Ready` / `Failed` / `Cancelled` (or
/// `AwaitingInput` for Pause gates). `DriftDetected` is a post-terminal flag
/// the readiness watcher raises when a previously ready node slips back.
/// Dependents are not cancelled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Predecessors not all Ready; not yet eligible to run.
    Pending,
    /// Apply issued and readiness being watched.
    Running,
    /// Terminal success.
    Ready,
    /// Terminal failure.
    Failed { message: String },
    /// Predecessor failed and failure policy halted this subtree.
    Cancelled { because: CancelReason },
    /// A Pause gate waiting on operator approval.
    AwaitingInput { prompt: String },
    /// Was Ready, readiness probe now says otherwise. Dependents keep their
    /// stale-Ready signal; this row just flips its glyph.
    DriftDetected { since: Duration, message: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CancelReason {
    /// A direct predecessor entered `Failed`.
    PredecessorFailed(ResourceId),
    /// Caller (operator supersession, Ctrl-C) flipped the cancel token.
    External,
}

impl Verdict {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Verdict::Ready
                | Verdict::Failed { .. }
                | Verdict::Cancelled { .. }
                | Verdict::DriftDetected { .. }
        )
    }

    pub fn is_success(&self) -> bool {
        matches!(self, Verdict::Ready | Verdict::DriftDetected { .. })
    }
}

/// A node in the deploy plan, keyed for events.
///
/// For concrete transitions this is the `ResourceId`. Synthetic nodes
/// (migration-pair barriers, Pause gates) use `Synthetic` with a stable id
/// the renderer can deduplicate across restarts.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum NodeId {
    Resource(ResourceId),
    Synthetic(String),
}

impl From<ResourceId> for NodeId {
    fn from(rid: ResourceId) -> Self {
        NodeId::Resource(rid)
    }
}

/// Structured per-node detail piggy-backed on state changes.
///
/// The renderer reads this to build the "2/3 ready, rollout 0/1" per-kind
/// strings. JSON logs serialize the variants directly; other renderers format
/// them for display.
#[derive(Debug, Clone)]
pub enum NodeDetail {
    /// Apply returned this outcome (Created/Configured/Unchanged/Skipped).
    Applied(ApplyAction),
    /// Readiness poll produced a new status message.
    ReadinessProgress(String),
    /// Apply failed with this error.
    ApplyFailed(String),
    /// Readiness timed out after this wall-clock duration.
    ReadinessTimeout { elapsed: Duration, message: String },
    /// Readiness returned a hard Failed result.
    ReadinessFailed {
        message: String,
        /// Exact keys missing from a Secret import.
        missing_keys: Vec<String>,
        /// The last lines a failed container wrote, read from its
        /// termination message. A Job whose pod ran with
        /// `terminationMessagePolicy: FallbackToLogsOnError` provides these. Empty when
        /// nothing was recorded.
        output: Vec<String>,
    },
    /// SOPS-hydrated N keys into this Secret.
    SecretHydrated { keys: usize },
    /// SOPS hydration failed, dropping the manifest from the wave.
    SecretHydrationFailed(String),
    /// In-place recreate consumed the immutable-field conflict.
    RecreatedInPlace { reason: String },
    /// A resource carrying `kix.run/rerun` was deleted and created again
    /// under the rerun rule (its identity changed, or its last run failed).
    Rerun { reason: String },
}

/// Metadata attached to a node at plan-time.
///
/// Kept alongside the node so renderers can group by package, chase
/// cross-package references, and surface import markers without asking the
/// planner twice.
#[derive(Debug, Clone)]
pub struct NodeMeta {
    /// Owning kix package instance name (from `kix.run/package` annotation).
    pub package: Option<String>,
    /// Namespace for namespaced resources; `None` for cluster-scoped or
    /// synthetic nodes.
    pub namespace: Option<String>,
    /// Populated iff the node is an import marker (`kix.run/mode: import`).
    pub import_target: Option<ImportTarget>,
}

/// A single event in the deploy stream.
///
/// Every node emits a `NodeStateChanged` on each `Verdict` transition. The
/// `PlanComputed` bookend carries the full node/edge set up front so
/// renderers can draw the tree skeleton before any work starts. Other
/// variants are deploy-wide lifecycle (finalization, prune, discovery).
#[derive(Debug, Clone)]
pub enum DeployEvent {
    /// Plan handed to the executor; carries the full DAG so renderers can
    /// paint the tree skeleton before execution begins.
    PlanComputed {
        nodes: Vec<PlanNode>,
        /// Directed edges: `(dependent, predecessor)`; the dependent waits
        /// on the predecessor.
        edges: Vec<(NodeId, NodeId)>,
    },
    /// A node's verdict advanced.
    NodeStateChanged {
        node: NodeId,
        kind: TransitionKind,
        verdict: Verdict,
        detail: Option<NodeDetail>,
    },
    /// CRDs applied; re-ran API discovery. Rendered as a subtle banner so the
    /// user knows later rows may reference newly-known kinds.
    CrdRediscovery,
    /// About to consider the orphans. `resources` names them, in prune
    /// order. `delete` says whether this run deletes them (`--prune`) or
    /// only reports them (the default, warn-only). Namespaces and kinds
    /// outside discovery are listed but never deleted.
    PruneStart {
        count: usize,
        resources: Vec<ResourceId>,
        delete: bool,
    },
    /// Activation lifecycle finalized. The new CR is Active or Degraded and the
    /// old one Superseded.
    Finalized {
        activation: String,
        previous: Option<String>,
    },
    /// Scheduler stopped because of caller cancellation or a halting failure
    /// under `halt-on-first-failure`.
    Stopped { reason: String },
    /// Nothing has happened for `idle`. Names every node in flight, what it
    /// is doing and for how long, so a stuck run is never silent. Emitted by
    /// the progress watchdog (`cluster::watchdog`), repeated while the stall
    /// lasts. `aborting` is true on the last one: the watchdog is cancelling
    /// the run.
    Stalled {
        idle: Duration,
        in_flight: Vec<InFlight>,
        aborting: bool,
    },
    /// A best-effort write failed. These are writes that cannot corrupt
    /// applied state and that the next deploy redoes (checkpoint, stamping
    /// unchanged resources, finalizing the Activation). They used to be
    /// `tracing::warn` lines the user never saw.
    BestEffortFailed { what: String, message: String },
}

/// What a node in flight is doing. Reported by the watchdog.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Decrypting SOPS secrets before apply.
    Hydrate,
    /// Server-side apply request outstanding (including transport retries).
    Apply,
    /// Polling the object for readiness.
    Readiness,
    /// Not a node: the API discovery refresh behind a CRD barrier.
    Discovery,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Hydrate => "hydrate",
            Phase::Apply => "apply",
            Phase::Readiness => "readiness",
            Phase::Discovery => "discovery",
        }
    }
}

/// One node in flight, as the watchdog saw it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InFlight {
    pub node: NodeId,
    pub phase: Phase,
    /// How long the node has been in this phase.
    pub since: Duration,
}

/// A node in the plan, handed to observers in `PlanComputed` so the renderer
/// can build the tree before any node has executed.
#[derive(Debug, Clone)]
pub struct PlanNode {
    pub id: NodeId,
    pub kind: TransitionKind,
    pub meta: NodeMeta,
}

/// Progress observer for a DAG-streaming deploy.
///
/// Observers are called synchronously on the scheduler thread; heavy work
/// (redraw, JSON serialization, K8s Event emission) should be queued and
/// executed on a different task. See `cli/kix-cli/src/commands/deploy_tui.rs`
/// for the mpsc pattern.
pub trait DeployObserver: Send + Sync {
    fn on_event(&self, event: &DeployEvent);
}

/// Discards every event. Used when the caller only wants the final
/// `DeployResult` and nothing else.
pub struct NullObserver;

impl DeployObserver for NullObserver {
    fn on_event(&self, _event: &DeployEvent) {}
}

/// Summary of a completed deploy run.
///
/// Counts are computed from terminal Verdicts, not from apply-time outcomes:
/// a node that applied cleanly but then failed readiness lands in `failed`,
/// not `configured`.
#[derive(Debug, Clone, Default)]
pub struct DeployResult {
    pub created: usize,
    pub configured: usize,
    pub unchanged: usize,
    pub failed: usize,
    pub cancelled: usize,
    pub pruned: usize,
}
