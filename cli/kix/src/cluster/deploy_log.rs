//! JSON deploy log emitted by `kix deploy --log-format json`.
//!
//! Each [`DeployEvent`] produces one JSON [`Line`], followed by a final
//! `summary` line. The JSON Schema for [`Line`] is committed at
//! `kix-cli/schema/deploy-log.schema.json` and checked by a test. Update
//! [`SCHEMA_VERSION`] to the current date when making a breaking change (such
//! as removing or renaming a field, or changing a value's meaning).
//!
//! These types mirror [`DeployEvent`] rather than serializing it directly so
//! internal event changes do not alter the log format.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::apply::ApplyAction;
use super::kept;
use super::stream::{
    CancelReason, DeployEvent, DeployResult, NodeDetail, NodeId, Phase, TransitionKind, Verdict,
};
use crate::manifest::types::ResourceId;

/// Schema version (`YYYY-MM-DD`) of the last breaking change to the log format.
/// Readers should reject versions they do not recognize.
pub const SCHEMA_VERSION: &str = "2026-10-09";

/// One line of the log.
///
/// Later versions of Kix may add fields and new types of line. Skip the ones
/// you do not know.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Line {
    /// Schema version (`YYYY-MM-DD`), included on every line so lines can be
    /// parsed independently.
    pub schema_version: String,
    /// Milliseconds since the deploy started.
    pub elapsed_ms: u64,
    #[serde(flatten)]
    pub event: Event,
}

impl Line {
    /// Build the log line for `event` at `elapsed_ms` into the run. Returns
    /// `None` for intermediate readiness progress polls.
    pub fn of(event: &DeployEvent, elapsed_ms: u64) -> Option<Line> {
        Some(Line {
            schema_version: SCHEMA_VERSION.to_string(),
            elapsed_ms,
            event: Event::of(event)?,
        })
    }

    /// Build the final summary line of the run. `succeeded` matches the process
    /// exit status.
    pub fn summary(r: &DeployResult, dry_run: bool, succeeded: bool, elapsed_ms: u64) -> Line {
        Line {
            schema_version: SCHEMA_VERSION.to_string(),
            elapsed_ms,
            event: Event::Summary {
                dry_run,
                succeeded,
                created: r.created,
                configured: r.configured,
                unchanged: r.unchanged,
                failed: r.failed,
                cancelled: r.cancelled,
                pruned: r.pruned,
            },
        }
    }
}

/// What happened, named by the line's `type`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// The plan, before any node runs. `edges` say which node waits on which.
    Plan {
        nodes: Vec<PlannedNode>,
        edges: Vec<Edge>,
    },
    /// A node's verdict advanced.
    Node {
        id: NodeRef,
        kind: TransitionKind,
        verdict: State,
        detail: Option<Detail>,
    },
    /// CRDs were applied, so API discovery ran again.
    CrdRediscovery,
    /// Start of orphan pruning. `resources` lists orphans in prune order,
    /// `count` is `resources.len()`, `delete` indicates whether this run
    /// deletes or only reports them, and `kept` lists orphans retained by
    /// prune policy.
    PruneStart {
        count: usize,
        delete: bool,
        resources: Vec<String>,
        kept: Vec<String>,
    },
    /// The prune left `resource` in place when it came to delete it.
    PruneKept { resource: String, reason: String },
    /// The new Activation record is current, and `previous` is superseded.
    Finalized {
        activation: String,
        previous: Option<String>,
    },
    /// The run stopped due to cancellation or a failure.
    Stopped { reason: String },
    /// Nothing has happened for `idle_ms`. `aborting` is true on the last
    /// one, when the run gives up.
    Stalled {
        idle_ms: u64,
        aborting: bool,
        in_flight: Vec<Busy>,
    },
    /// `node` has been in `phase` for `since_ms` without a verdict. Repeated
    /// on a schedule while the wait lasts. `status` is the node's last
    /// readiness message and `budget_ms` the readiness timeout. `holds`
    /// names the resources that wait on `node` directly, as the text log
    /// names them, and `holds_total` counts every resource that waits on it
    /// directly or through other nodes.
    Waiting {
        node: String,
        phase: Phase,
        since_ms: u64,
        status: Option<String>,
        budget_ms: Option<u64>,
        #[serde(default)]
        holds: Vec<String>,
        #[serde(default)]
        holds_total: usize,
    },
    /// A write that the next deploy redoes failed.
    BestEffortFailed { what: String, message: String },
    /// The apply of `resource` succeeded, but Kubernetes did not store
    /// `fields` as Kix sent them. A warning: the deploy goes on.
    FieldsNotKept {
        resource: String,
        fields: Vec<FieldNotKept>,
    },
    /// The counts the text summary line shows.
    Summary {
        dry_run: bool,
        succeeded: bool,
        created: usize,
        configured: usize,
        unchanged: usize,
        failed: usize,
        cancelled: usize,
        pruned: usize,
    },
}

/// A node of the plan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct PlannedNode {
    pub id: NodeRef,
    pub kind: TransitionKind,
    /// The Kix package instance the node belongs to.
    pub package: Option<String>,
    pub namespace: Option<String>,
    /// For an import marker, the resource it waits for.
    pub import: Option<Import>,
}

/// The resource an import marker waits for.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Import {
    pub kind: String,
    pub name: String,
    #[serde(rename = "apiVersion")]
    pub api_version: String,
    pub namespace: Option<String>,
}

/// `dependent` waits on `predecessor`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Edge {
    pub dependent: NodeRef,
    pub predecessor: NodeRef,
}

/// A node: a resource, or a step that is not one (`synthetic`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum NodeRef {
    Resource(ResourceId),
    Synthetic { synthetic: String },
}

/// A node's verdict, named by `state`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum State {
    Pending,
    Running,
    Ready,
    Failed {
        message: String,
    },
    Cancelled {
        because: Because,
    },
    AwaitingInput {
        prompt: String,
    },
    /// Was ready, and readiness now says otherwise.
    Drift {
        since_ms: u64,
        message: String,
    },
}

/// Why a node was cancelled.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Because {
    /// This node waited on the one that failed.
    PredecessorFailed(ResourceId),
    /// The run was cancelled. Always `true`.
    External(#[schemars(extend("const" = true))] bool),
}

/// What a node's state change carries, named by its one key.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Detail {
    Applied(ApplyAction),
    ApplyFailed(String),
    ReadinessTimeout {
        elapsed_ms: u64,
        message: String,
    },
    ReadinessFailed {
        message: String,
        missing_keys: Vec<String>,
        /// The last lines a failed container wrote.
        output: Vec<String>,
    },
    /// How many keys were decrypted into the Secret.
    SecretHydrated(usize),
    SecretHydrationFailed(String),
    RecreatedInPlace(String),
    Rerun(String),
    /// `stale` pods run the previous template until someone deletes them.
    PendingRestart {
        stale: i64,
        message: String,
    },
}

/// A field Kix applied that Kubernetes did not store as sent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct FieldNotKept {
    pub path: String,
    pub change: NotKept,
    /// The value Kix sent. A Secret value reads `(secret, not shown)`.
    pub sent: serde_json::Value,
    /// The value Kubernetes stored. Absent when it dropped the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stored: Option<serde_json::Value>,
}

/// What Kubernetes did with a field Kix applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum NotKept {
    /// The stored object does not have the field.
    Dropped,
    /// The stored object has another value.
    Changed,
}

/// A node in flight when the run stalled.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct Busy {
    /// The node, as the text log names it.
    pub node: String,
    pub phase: Phase,
    /// How long it has been in this phase.
    pub since_ms: u64,
}

impl Event {
    fn of(event: &DeployEvent) -> Option<Event> {
        Some(match event {
            DeployEvent::PlanComputed { nodes, edges } => Event::Plan {
                nodes: nodes
                    .iter()
                    .map(|n| PlannedNode {
                        id: NodeRef::of(&n.id),
                        kind: n.kind,
                        package: n.meta.package.clone(),
                        namespace: n.meta.namespace.clone(),
                        import: n.meta.import_target.as_ref().map(|t| Import {
                            kind: t.kind.clone(),
                            name: t.name.clone(),
                            api_version: t.api_version.clone(),
                            namespace: t.namespace.clone(),
                        }),
                    })
                    .collect(),
                edges: edges
                    .iter()
                    .map(|(dependent, predecessor)| Edge {
                        dependent: NodeRef::of(dependent),
                        predecessor: NodeRef::of(predecessor),
                    })
                    .collect(),
            },
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => Event::Node {
                id: NodeRef::of(node),
                kind: *kind,
                verdict: State::of(verdict),
                detail: match detail {
                    Some(d) => Some(Detail::of(d)?),
                    None => None,
                },
            },
            DeployEvent::CrdRediscovery => Event::CrdRediscovery,
            DeployEvent::PruneStart {
                count,
                resources,
                kept,
                delete,
            } => Event::PruneStart {
                count: *count,
                delete: *delete,
                resources: resources.iter().map(ResourceId::display_id).collect(),
                kept: kept.iter().map(ResourceId::display_id).collect(),
            },
            DeployEvent::PruneKept { resource, reason } => Event::PruneKept {
                resource: resource.display_id(),
                reason: reason.clone(),
            },
            DeployEvent::Finalized {
                activation,
                previous,
            } => Event::Finalized {
                activation: activation.clone(),
                previous: previous.clone(),
            },
            DeployEvent::Stopped { reason } => Event::Stopped {
                reason: reason.clone(),
            },
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => Event::Stalled {
                idle_ms: idle.as_millis() as u64,
                aborting: *aborting,
                in_flight: in_flight
                    .iter()
                    .map(|f| Busy {
                        node: f.node.to_string(),
                        phase: f.phase,
                        since_ms: f.since.as_millis() as u64,
                    })
                    .collect(),
            },
            DeployEvent::Waiting {
                node,
                phase,
                since,
                status,
                budget,
                holds,
                holds_total,
            } => Event::Waiting {
                node: node.to_string(),
                phase: *phase,
                since_ms: since.as_millis() as u64,
                status: status.clone(),
                budget_ms: budget.map(|b| b.as_millis() as u64),
                holds: holds.iter().map(ToString::to_string).collect(),
                holds_total: *holds_total,
            },
            DeployEvent::BestEffortFailed { what, message } => Event::BestEffortFailed {
                what: what.clone(),
                message: message.clone(),
            },
            DeployEvent::FieldsNotKept { resource, fields } => Event::FieldsNotKept {
                resource: resource.display_id(),
                fields: fields
                    .iter()
                    .map(|f| FieldNotKept {
                        path: f.path.clone(),
                        change: match f.change {
                            kept::NotKept::Dropped => NotKept::Dropped,
                            kept::NotKept::Changed => NotKept::Changed,
                        },
                        sent: f.sent.clone(),
                        stored: f.stored.clone(),
                    })
                    .collect(),
            },
        })
    }
}

impl NodeRef {
    fn of(id: &NodeId) -> NodeRef {
        match id {
            NodeId::Resource(rid) => NodeRef::Resource(rid.clone()),
            NodeId::Synthetic(s) => NodeRef::Synthetic {
                synthetic: s.clone(),
            },
        }
    }
}

impl State {
    fn of(verdict: &Verdict) -> State {
        match verdict {
            Verdict::Pending => State::Pending,
            Verdict::Running => State::Running,
            Verdict::Ready => State::Ready,
            Verdict::Failed { message } => State::Failed {
                message: message.clone(),
            },
            Verdict::Cancelled { because } => State::Cancelled {
                because: match because {
                    CancelReason::PredecessorFailed(rid) => Because::PredecessorFailed(rid.clone()),
                    CancelReason::External => Because::External(true),
                },
            },
            Verdict::AwaitingInput { prompt } => State::AwaitingInput {
                prompt: prompt.clone(),
            },
            Verdict::DriftDetected { since, message } => State::Drift {
                since_ms: since.as_millis() as u64,
                message: message.clone(),
            },
        }
    }
}

impl Detail {
    /// Convert `detail` into its log representation, or return `None` for
    /// `ReadinessProgress`.
    fn of(detail: &NodeDetail) -> Option<Detail> {
        Some(match detail {
            NodeDetail::Applied(action) => Detail::Applied(action.clone()),
            NodeDetail::ReadinessProgress(_) => return None,
            NodeDetail::ApplyFailed(msg) => Detail::ApplyFailed(msg.clone()),
            NodeDetail::ReadinessTimeout { elapsed, message } => Detail::ReadinessTimeout {
                elapsed_ms: elapsed.as_millis() as u64,
                message: message.clone(),
            },
            NodeDetail::ReadinessFailed {
                message,
                missing_keys,
                output,
            } => Detail::ReadinessFailed {
                message: message.clone(),
                missing_keys: missing_keys.clone(),
                output: output.clone(),
            },
            NodeDetail::SecretHydrated { keys } => Detail::SecretHydrated(*keys),
            NodeDetail::SecretHydrationFailed(msg) => Detail::SecretHydrationFailed(msg.clone()),
            NodeDetail::RecreatedInPlace { reason } => Detail::RecreatedInPlace(reason.clone()),
            NodeDetail::Rerun { reason } => Detail::Rerun(reason.clone()),
            NodeDetail::PendingRestart { stale, message } => Detail::PendingRestart {
                stale: *stale,
                message: message.clone(),
            },
        })
    }
}
