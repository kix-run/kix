//! Types shared by the deploy scheduler and its observers.
//!
//! This module defines the per-node state machine and event shape for
//! DAG-streaming deploys. Each transition in the plan is one node. Its state
//! advances through [`Verdict`] variants, and observers consume
//! [`DeployEvent`]s.
//!
//! The planner currently produces Apply, Skip, and Recreate transitions.
//! The remaining variants reserve the event shape for operations handled
//! outside the scheduler.

use std::time::Duration;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::manifest::types::ResourceId;

use super::apply::ApplyAction;
use super::kept::NotKeptField;
use super::readiness::ImportTarget;

/// What kind of operation a node represents.
///
/// The planner tags every node in the plan with one of these. Rendering and
/// scheduling both branch on this tag. The deploy log names it in
/// snake_case.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TransitionKind {
    /// Server-side apply a manifest.
    Apply,
    /// Identity-hash unchanged, so no work is needed. Rendered dim and folded
    /// aggressively.
    Skip,
    /// Delete the live object, then apply. Tagged `recreate` because that
    /// is the act, whatever the trigger. The current producer is the
    /// rerun rule: a Job carrying the rerun annotation whose rerun hash
    /// changed is run again, never patched, and the reason
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
    /// Wait for an object the build needs and another Kix cluster writes,
    /// such as Kix's own CRDs on a consumer cluster.
    /// Nothing is applied or stamped.
    Wait,
}

impl TransitionKind {
    /// Return the transition's name, spelled as the deploy log serializes it.
    pub fn as_str(self) -> &'static str {
        match self {
            TransitionKind::Apply => "apply",
            TransitionKind::Skip => "skip",
            TransitionKind::Recreate => "recreate",
            TransitionKind::Migrate => "migrate",
            TransitionKind::Drain => "drain",
            TransitionKind::Delete => "delete",
            TransitionKind::Pause => "pause",
            TransitionKind::Wait => "wait",
        }
    }

    /// Return the short prefix tag used in renderers, or `None` for `Apply`.
    pub fn tag(self) -> Option<&'static str> {
        match self {
            TransitionKind::Apply => None,
            kind => Some(kind.as_str()),
        }
    }
}

impl std::fmt::Display for TransitionKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
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
    /// Predecessors are not all Ready, so the node is not yet eligible to run.
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
    /// Was Ready, and the readiness probe now says otherwise. Dependents keep
    /// their stale-Ready signal while this row flips its glyph.
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
    /// Return whether the verdict is terminal (`Ready`, `Failed`, `Cancelled`, or `DriftDetected`).
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Verdict::Ready
                | Verdict::Failed { .. }
                | Verdict::Cancelled { .. }
                | Verdict::DriftDetected { .. }
        )
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

/// Format as [`ResourceId`] for resource nodes, or in `⟦…⟧` for synthetic nodes.
impl std::fmt::Display for NodeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NodeId::Resource(rid) => write!(f, "{rid}"),
            NodeId::Synthetic(s) => write!(f, "⟦{s}⟧"),
        }
    }
}

impl NodeId {
    /// Return whether the node is a Kubernetes object rather than a
    /// synthetic step.
    pub fn is_resource(&self) -> bool {
        matches!(self, NodeId::Resource(_))
    }

    /// Return the key that orders nodes by kind, namespace, and name.
    /// Synthetic nodes sort first, by their id.
    pub(crate) fn sort_key(&self) -> (String, String, String) {
        match self {
            NodeId::Resource(rid) => (rid.kind.clone(), rid.namespace.clone(), rid.name.clone()),
            NodeId::Synthetic(s) => (String::new(), String::new(), s.clone()),
        }
    }
}

impl From<ResourceId> for NodeId {
    fn from(rid: ResourceId) -> Self {
        NodeId::Resource(rid)
    }
}

/// Structured per-node detail piggy-backed on state changes.
///
/// The renderer reads this to build the "2/3 ready, rollout 0/1" per-kind
/// strings. The deploy log mirrors them in [`super::deploy_log::Detail`], and
/// other renderers format them for display.
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
    /// under the rerun rule (its own content changed, or its last run failed).
    Rerun { reason: String },
    /// An `OnDelete` DaemonSet is ready, and `stale` of its pods run the
    /// previous pod template until someone deletes them.
    PendingRestart { stale: i64, message: String },
}

/// Metadata attached to a node at plan-time.
///
/// Kept alongside the node so renderers can group by package, chase
/// cross-package references, and surface import markers without asking the
/// planner twice.
#[derive(Debug, Clone)]
pub struct NodeMeta {
    /// Owning Kix package instance name (from `kix.run/package` annotation).
    pub package: Option<String>,
    /// Namespace for namespaced resources, or `None` for cluster-scoped and
    /// synthetic nodes.
    pub namespace: Option<String>,
    /// Populated when the node is an import marker (`kix.run/mode: import`).
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
    /// Plan handed to the executor, carrying the full DAG so renderers can
    /// paint the tree skeleton before execution begins.
    PlanComputed {
        nodes: Vec<PlanNode>,
        /// Directed edges `(dependent, predecessor)` where the dependent waits
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
    /// CRDs applied and API discovery re-ran. Rendered as a subtle banner so
    /// the user knows later rows may reference newly discovered kinds.
    CrdRediscovery,
    /// About to consider the orphans. `resources` names the ones prune may
    /// delete, in prune order, and `count` is its length. `delete` says
    /// whether this run deletes them (`--prune`) or only reports them (the
    /// default, warn-only). `kept` names the orphans whose kind
    /// `lifecycle::never_pruned` protects so no prune policy deletes them.
    PruneStart {
        count: usize,
        resources: Vec<ResourceId>,
        kept: Vec<ResourceId>,
        delete: bool,
    },
    /// Prune left an orphan in place because another Kix cluster's current
    /// build contains it or it changed since it was read. `reason` is the line
    /// to show (`Pruned::kept_reason`).
    PruneKept {
        resource: ResourceId,
        reason: String,
    },
    /// Activation lifecycle finalized. The new CR is Active or Degraded and the
    /// old one Superseded.
    Finalized {
        activation: String,
        previous: Option<String>,
    },
    /// Scheduler stopped because of caller cancellation or a halting failure
    /// under `halt-on-first-failure`. A halting failure's reason starts with
    /// [`HALTED_ON_FAILURE`] and repeats the failed node's message.
    Stopped { reason: String },
    /// Nothing has happened for `idle`. Names every node in flight, what it
    /// is doing, and for how long, so a stuck run is never silent. Emitted by
    /// the progress watchdog (`cluster::watchdog`) and repeated while the stall
    /// lasts. `aborting` is true on the final event when the watchdog cancels
    /// the run.
    Stalled {
        idle: Duration,
        in_flight: Vec<InFlight>,
        aborting: bool,
    },
    /// A node has been in `phase` for `since` without a verdict. The
    /// progress watchdog emits this on a time schedule (`cluster::watchdog`),
    /// so a plain log says what a long wait is for while it lasts and not
    /// only when it ends. `status` is the last readiness message the node
    /// reported, and `budget` is the readiness timeout the wait runs against.
    /// `holds` names the resources that wait on this node directly, sorted
    /// by kind, namespace, and name, and `holds_total` counts every resource
    /// that waits on it directly or through other nodes. Both come from the
    /// plan's edges, so a dependent cancelled since still counts.
    Waiting {
        node: NodeId,
        phase: Phase,
        since: Duration,
        status: Option<String>,
        budget: Option<Duration>,
        holds: Vec<NodeId>,
        holds_total: usize,
    },
    /// A best-effort write failed. These are writes that cannot corrupt
    /// applied state and that the next deploy redoes (checkpoint, stamping
    /// unchanged resources, and finalizing the Activation).
    BestEffortFailed { what: String, message: String },
    /// The apply of `resource` succeeded, but the server did not store these
    /// fields as sent ([`super::kept::not_kept`]). A warning: the deploy
    /// goes on.
    FieldsNotKept {
        resource: ResourceId,
        fields: Vec<NotKeptField>,
    },
}

/// What a node in flight is doing. Reported by the watchdog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    /// Decrypting SOPS secrets before apply.
    Hydrate,
    /// Server-side apply request outstanding (including transport retries).
    Apply,
    /// Polling the object for readiness.
    Readiness,
    /// API discovery refresh behind a CRD barrier.
    Discovery,
}

impl Phase {
    /// Return the snake_case name of the phase.
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
/// Observers are called synchronously on the scheduler thread. Heavy work
/// (redraw, JSON serialization, and K8s Event emission) should be queued and
/// executed on a different task. See `cli/kix-cli/src/commands/deploy_tui.rs`
/// for the mpsc pattern.
pub trait DeployObserver: Send + Sync {
    fn on_event(&self, event: &DeployEvent);
}

/// Observer that discards every event when the caller only needs the final
/// `DeployResult`.
pub struct NullObserver;

impl DeployObserver for NullObserver {
    fn on_event(&self, _event: &DeployEvent) {}
}

/// The start of a [`DeployEvent::Stopped`] reason when a failed node halted
/// the run. The rest repeats the message the node's own `Failed` verdict
/// carried, so a person-facing renderer can leave the line out.
pub const HALTED_ON_FAILURE: &str = "halt-on-first-failure: ";

/// Summary of a completed deploy run.
///
/// Counts are computed from terminal Verdicts rather than apply-time outcomes.
/// A node that applied cleanly but then failed readiness lands in `failed`,
/// not `configured`.
#[derive(Debug, Clone, Default)]
pub struct DeployResult {
    pub created: usize,
    pub configured: usize,
    pub unchanged: usize,
    pub failed: usize,
    pub cancelled: usize,
    pub pruned: usize,
    /// Every node counted in `failed`, in the order it failed, for the text
    /// that closes a run.
    pub failures: Vec<NodeFailure>,
}

/// A node that failed in a run, and the message its `Failed` verdict gave
/// before the engine added what the failure cost.
#[derive(Debug, Clone)]
pub struct NodeFailure {
    pub node: NodeId,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::apply::ApplyAction;

    fn serialized<T: Serialize>(value: T) -> String {
        serde_json::to_value(value)
            .unwrap()
            .as_str()
            .unwrap()
            .to_string()
    }

    #[test]
    fn names_match_the_deploy_log() {
        use TransitionKind::*;
        for kind in [Apply, Skip, Recreate, Migrate, Drain, Delete, Pause, Wait] {
            assert_eq!(kind.as_str(), serialized(kind));
        }
        use ApplyAction::*;
        for action in [Created, Configured, Unchanged, Skipped] {
            assert_eq!(action.as_str(), serialized(action.clone()));
        }
    }
}
