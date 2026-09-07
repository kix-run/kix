//! DAG-streaming deploy scheduler (doc 99 Stage A, reshaped by doc 134).
//!
//! Replaces the wave-barrier loop in `reconcile.rs`. Every node in the
//! [`DeployPlan`] becomes ready to execute the moment its direct predecessors
//! have emitted [`Verdict::Ready`]; independent subtrees stream through in
//! parallel, bounded by [`SchedulerConfig::concurrency`]. See doc 98 §4 for
//! the motivation (head-of-line blocking under wave barriers) and doc 99 §9
//! for scope.
//!
//! # The engine task never awaits foreign I/O while nodes are in flight
//!
//! Every unit of work (a node, a discovery refresh, a checkpoint) is a task
//! spawned into one `JoinSet`, so the runtime polls it whatever the
//! supervisor is doing. The supervisor's only awaits are its own `JoinSet`,
//! the cancel token and the watchdog. The first version of this loop held
//! its node futures in a `FuturesUnordered` and awaited CRD rediscovery
//! inline; a future nobody polls makes no progress and fires no deadline,
//! and on 2026-09-07 that sat silent for 35 minutes (kixpkgs#62, doc 134).
//!
//! Every cluster call goes through [`ClusterOps`], so the loop runs under
//! test against `ops::scripted::ScriptedOps` with no cluster.
//!
//! Today the planner tags every node as [`TransitionKind::Apply`] or
//! [`TransitionKind::Skip`]; the other variants exist on the enum but are
//! not yet produced. Recreate/Migrate/Drain/Delete/Pause are Stage E–F.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use thiserror::Error;
use tokio::task::JoinSet;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::apply::{ApplyAction, ApplyError, ChangeAction};
use super::cancel::CancelToken;
use super::graph::ResourceGraph;
use super::ops::ClusterOps;
use super::readiness::{self, ImportTarget, ReadinessResult};
use super::secrets;
use super::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeId, NodeMeta, Phase,
    PlanNode, TransitionKind, Verdict,
};
use super::watchdog::{self, Progress, StallPolicy};

pub use super::ops::kube::delete_propagation_for;

// ---------------------------------------------------------------------------
// Plan
// ---------------------------------------------------------------------------

/// A single node in the plan — resource or synthetic — paired with the work
/// the scheduler will perform on it.
#[derive(Debug, Clone)]
pub struct PlanNodeEntry {
    pub id: NodeId,
    pub kind: TransitionKind,
    /// The concrete change to apply. For [`TransitionKind::Skip`] this carries
    /// the `ResourceId`; for [`TransitionKind::Apply`] it carries the manifest.
    pub action: ChangeAction,
    pub meta: NodeMeta,
}

/// The planner's output. Handed to [`run_deploy`] which consumes it.
///
/// `edges` is `(dependent, predecessor)` — the dependent waits on the
/// predecessor. Both endpoints must also appear in `nodes`.
#[derive(Debug, Clone, Default)]
pub struct DeployPlan {
    pub nodes: Vec<PlanNodeEntry>,
    pub edges: Vec<(NodeId, NodeId)>,
}

impl DeployPlan {
    /// Build a plan from the resource dependency graph and the change
    /// actions produced by `detect_changes` / `detect_changes_live`.
    ///
    /// Orphans are not part of the plan — they are handed to the scheduler
    /// separately and pruned after every non-orphan node has terminated.
    pub fn from_graph_and_changes(graph: &ResourceGraph, changes: &[ChangeAction]) -> Self {
        // Index changes by K8s identity so we can look them up per-node.
        let mut by_id: HashMap<String, &ChangeAction> = HashMap::new();
        for action in changes {
            let rid = match action {
                ChangeAction::Apply(m) => ResourceId::from_value(m),
                ChangeAction::Skip(rid) => rid.clone(),
                ChangeAction::Orphan(_) => continue,
            };
            by_id.insert(
                format!("{}/{}/{}", rid.kind, rid.namespace, rid.name),
                action,
            );
        }

        let mut nodes = Vec::with_capacity(graph.graph.node_count());
        for idx in graph.graph.node_indices() {
            let node = &graph.graph[idx];
            let k8s_id = format!("{}/{}/{}", node.id.kind, node.id.namespace, node.id.name);
            let action = match by_id.get(&k8s_id) {
                Some(ChangeAction::Apply(m)) => ChangeAction::Apply((*m).clone()),
                Some(ChangeAction::Skip(rid)) => ChangeAction::Skip(rid.clone()),
                // Node in the graph but no change action — treat as Skip.
                // Happens for manifests that weren't in the diff input (shouldn't
                // occur in practice, but stay defensive).
                None | Some(ChangeAction::Orphan(_)) => ChangeAction::Skip(node.id.clone()),
            };
            let kind = match &action {
                ChangeAction::Apply(_) => TransitionKind::Apply,
                ChangeAction::Skip(_) => TransitionKind::Skip,
                ChangeAction::Orphan(_) => TransitionKind::Delete,
            };

            // Extract meta from the manifest.
            let meta = NodeMeta {
                package: node
                    .manifest
                    .pointer("/metadata/annotations/kix.dev~1package")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string()),
                namespace: (node.id.namespace != CLUSTER_SCOPED).then(|| node.id.namespace.clone()),
                import_target: readiness::import_target_from_manifest(&node.manifest),
            };

            nodes.push(PlanNodeEntry {
                id: NodeId::Resource(node.id.clone()),
                kind,
                action,
                meta,
            });
        }

        // Edges: in ResourceGraph, outgoing edges point from dependent → predecessor.
        let mut edges = Vec::new();
        for idx in graph.graph.node_indices() {
            let dependent_id = NodeId::Resource(graph.graph[idx].id.clone());
            for pred_idx in graph
                .graph
                .neighbors_directed(idx, petgraph::Direction::Outgoing)
            {
                let pred_id = NodeId::Resource(graph.graph[pred_idx].id.clone());
                edges.push((dependent_id.clone(), pred_id));
            }
        }

        DeployPlan { nodes, edges }
    }

    fn to_plan_nodes(&self) -> Vec<PlanNode> {
        self.nodes
            .iter()
            .map(|e| PlanNode {
                id: e.id.clone(),
                kind: e.kind,
                meta: e.meta.clone(),
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Shared policy enums
// ---------------------------------------------------------------------------

/// What to do when a node's verdict lands on `Failed`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnErrorPolicy {
    /// Halt the deploy immediately.
    Stop,
    /// Continue sibling subtrees; cancel transitive dependents of the failed
    /// node (doc 98 §4.4).
    Continue,
}

/// How to handle orphans after every non-orphan node terminates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrunePolicy {
    /// Skip pruning entirely.
    Skip,
    /// Report orphans but do not delete.
    WarnOnly,
    /// Delete orphans in reverse-topological order.
    Delete,
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Default for [`SchedulerConfig::concurrency`]: max nodes in flight. Same
/// ceiling the old wave-based readiness loop used; keeps kube's connection
/// pool and the API server's rate limiter happy on wide clusters.
pub const CONCURRENCY: usize = 64;

/// Checkpoint every N terminal verdicts to the Activation CR. Keeps write
/// pressure modest on the apiserver while giving a crash-recovery point every
/// few seconds under typical deploy cadence.
const CHECKPOINT_BATCH: usize = 16;

/// Bound on the best-effort writes the engine awaits inline after the node
/// phase (final checkpoint, finalize). The ops layer has its own bound; this
/// one holds whatever the implementation does.
const INLINE_BEST_EFFORT_TIMEOUT: Duration = Duration::from_secs(60);

pub struct SchedulerConfig {
    pub timeout: Duration,
    pub on_error: OnErrorPolicy,
    pub prune: PrunePolicy,
    pub cancel: CancelToken,
    /// When true: SSA + DELETE go to the apiserver with `?dryRun=All`, the
    /// Activation CR's `status` subresource is never patched, and readiness
    /// short-circuits to Ready (because nothing was persisted to poll for).
    /// The same DeployEvent stream is emitted, so the same renderer paints
    /// dry-run output as the real path — no parallel render path.
    pub dry_run: bool,
    /// Max nodes in flight. See [`CONCURRENCY`].
    pub concurrency: usize,
    /// When the progress watchdog warns and when it gives up.
    pub stall: StallPolicy,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Error, Debug)]
pub enum DeployError {
    #[error("deploy stopped: {count} node(s) failed")]
    NodesFailed { count: usize, partial: DeployResult },

    /// Discovery could not be refreshed after a CRD landed. The run stopped
    /// rather than continue on a stale view of which kinds exist.
    #[error("API discovery failed: {message}")]
    DiscoveryFailed {
        message: String,
        partial: DeployResult,
    },

    #[error("activation lifecycle error: {0}")]
    ActivationError(String),

    #[error("deploy cancelled: {reason}")]
    Cancelled {
        reason: String,
        partial: DeployResult,
    },

    /// A spawned task panicked or was aborted from outside. A bug, never a
    /// cluster condition.
    #[error("deploy engine failure: {message}")]
    Internal {
        message: String,
        partial: DeployResult,
    },
}

impl DeployError {
    /// The counts accumulated before the run stopped, when there are any.
    pub fn partial(&self) -> Option<&DeployResult> {
        match self {
            DeployError::NodesFailed { partial, .. }
            | DeployError::DiscoveryFailed { partial, .. }
            | DeployError::Cancelled { partial, .. }
            | DeployError::Internal { partial, .. } => Some(partial),
            DeployError::ActivationError(_) => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Which task a `JoinSet` entry is, for accounting aborted and panicked
/// tasks by kind.
enum TaskKind {
    Node(NodeId),
    Rediscovery,
    Checkpoint,
}

/// The watchdog's name for the discovery refresh behind a CRD barrier. Not a
/// plan node, but it is work the run waits on and must never wait on
/// silently.
static DISCOVERY_NODE: std::sync::LazyLock<NodeId> =
    std::sync::LazyLock::new(|| NodeId::Synthetic("api-discovery".into()));

/// What one spawned task reports back to the supervisor.
enum Done {
    Node(NodeId, NodeOutcome),
    Rediscovery(Result<(), String>),
    Checkpoint(Result<(), String>),
}

/// Execute a DAG-streaming deploy.
///
/// The scheduler maintains a ready-queue; a node becomes ready the moment all
/// its predecessors have emitted `Verdict::Ready`. Concurrency is bounded by
/// [`SchedulerConfig::concurrency`]. On a node failure the failure policy
/// either halts the whole deploy ([`OnErrorPolicy::Stop`]) or halts only
/// transitive dependents while sibling subtrees continue
/// ([`OnErrorPolicy::Continue`]).
///
/// Dependents of a CRD wait for one discovery refresh after the CRD is Ready
/// (the CRD barrier, doc 134 §2.3). Several CRDs finishing together share
/// one refresh. A refresh that fails stops the run.
///
/// After every non-orphan node has reached a terminal verdict, orphans are
/// pruned (in reverse-topological order of the old graph) and the Activation
/// CR is finalized.
pub async fn run_deploy(
    ops: Arc<dyn ClusterOps>,
    plan: DeployPlan,
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    config: &SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
) -> Result<DeployResult, DeployError> {
    let mut result = DeployResult::default();
    let progress = Arc::new(Progress::new());
    let emit = |event: DeployEvent| {
        progress.touch();
        observer.on_event(&event);
    };

    // The watchdog is its own task with its own timer, so it runs even if
    // this loop has a bug that parks it. It reports through the observer and
    // stops the run through the cancel token; it never touches the cluster.
    let _watchdog = AbortOnDrop(tokio::spawn(watchdog::run(
        config.stall,
        progress.clone(),
        config.cancel.clone(),
        observer.clone(),
    )));

    // Publish the plan skeleton so renderers can paint the tree before any
    // node has executed.
    emit(DeployEvent::PlanComputed {
        nodes: plan.to_plan_nodes(),
        edges: plan.edges.clone(),
    });

    if ops.dry_run() != config.dry_run {
        let message = format!(
            "dry-run flags disagree: engine {} vs cluster ops {}",
            config.dry_run,
            ops.dry_run()
        );
        emit(DeployEvent::Stopped {
            reason: message.clone(),
        });
        return Err(DeployError::Internal {
            message,
            partial: result,
        });
    }

    // Nothing is in flight yet, so awaiting this inline parks nobody. It is
    // still bounded: the watchdog only watches nodes.
    match tokio::time::timeout(INLINE_BEST_EFFORT_TIMEOUT, ops.begin()).await {
        Ok(Ok(())) => {}
        Ok(Err(message)) => emit(DeployEvent::BestEffortFailed {
            what: "activation begin".into(),
            message,
        }),
        Err(_) => emit(DeployEvent::BestEffortFailed {
            what: "activation begin".into(),
            message: format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
        }),
    }

    // Preauthorized delete set for immutable-conflict recovery.
    let orphan_set: HashSet<ResourceId> = orphan_rids.iter().cloned().collect();
    let mut consumed_orphans: HashSet<ResourceId> = HashSet::new();

    let mut state = SchedulerState::new(&plan);

    let ctx = Arc::new(NodeCtx {
        ops: ops.clone(),
        cancel: config.cancel.clone(),
        timeout: config.timeout,
        orphan_set: orphan_set.clone(),
        dry_run: config.dry_run,
        progress: progress.clone(),
        observer: observer.clone(),
    });

    let mut tasks: JoinSet<Done> = JoinSet::new();
    // Which task is which, so an aborted or panicked task can be accounted
    // for by kind: an aborted node is a Cancelled verdict, a panicked
    // checkpoint is a best-effort failure, a panicked node is a bug.
    let mut kinds: HashMap<tokio::task::Id, TaskKind> = HashMap::new();
    let mut nodes_in_flight = 0usize;
    let mut barrier = CrdBarrier::default();
    let mut checkpoints = Checkpoints::default();
    // Set when the cancel token fires: every task is aborted and the loop
    // drains their results before the run returns `Cancelled`.
    let mut cancelling = false;

    state.seed_ready();

    let mut halting = false; // Set when stop-worthy failure under on_error=Stop.
    let mut halting_reason: Option<String> = None;
    let mut discovery_failed: Option<String> = None;

    // Unchanged resources still belong to this activation; they just have
    // nothing to apply. Collected here, stamped in one pass once every node is
    // terminal (see `record_activation_on_skipped`).
    let mut skipped: Vec<ResourceId> = Vec::new();

    let concurrency = config.concurrency.max(1);

    loop {
        // Fill in-flight up to the concurrency cap.
        while !halting && nodes_in_flight < concurrency {
            let Some(node_id) = state.pop_ready() else {
                break;
            };
            let entry = state.node_entry(&node_id).clone();

            // Skip nodes terminate immediately: no task, just two events
            // back-to-back.
            if matches!(entry.kind, TransitionKind::Skip) {
                emit(DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Running,
                    detail: None,
                });
                emit(DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Ready,
                    detail: Some(NodeDetail::Applied(ApplyAction::Unchanged)),
                });
                result.unchanged += 1;
                if let NodeId::Resource(rid) = &node_id {
                    skipped.push(rid.clone());
                }
                state.mark_terminal(&node_id, true);
                checkpoints.terminal();
                continue;
            }

            emit(DeployEvent::NodeStateChanged {
                node: node_id.clone(),
                kind: entry.kind,
                verdict: Verdict::Running,
                detail: None,
            });
            let ctx = ctx.clone();
            let id = node_id.clone();
            nodes_in_flight += 1;
            let handle = tasks.spawn(async move {
                let out = execute_node(&ctx, &entry).await;
                Done::Node(id, out)
            });
            kinds.insert(handle.id(), TaskKind::Node(node_id));
        }

        // No node running, no refresh in flight, nothing admitted or waiting
        // to be: the node phase is over. A checkpoint still in flight is
        // best-effort and must not hold the run open; `shutdown` below
        // aborts it and the final checkpoint after the loop records the
        // totals.
        if nodes_in_flight == 0 && !barrier.in_flight && (halting || state.ready_is_empty()) {
            break;
        }

        let joined = if cancelling {
            tasks.join_next_with_id().await
        } else {
            tokio::select! {
                biased;
                _ = config.cancel.cancelled() => {
                    // Stop admitting, abort everything, then keep looping to
                    // drain: a node that finished just before the cancel is
                    // still counted, an aborted one becomes Cancelled.
                    cancelling = true;
                    halting = true;
                    halting_reason = Some(
                        config
                            .cancel
                            .reason()
                            .unwrap_or_else(|| "cancelled".to_string()),
                    );
                    tasks.abort_all();
                    continue;
                }
                joined = tasks.join_next_with_id() => joined,
            }
        };

        let done = match joined {
            None => break,
            Some(Ok((task_id, done))) => {
                kinds.remove(&task_id);
                done
            }
            Some(Err(join_err)) => {
                let aborted = join_err.is_cancelled();
                match kinds.remove(&join_err.id()) {
                    Some(TaskKind::Node(node_id)) => {
                        nodes_in_flight -= 1;
                        progress.clear(&node_id);
                        if aborted {
                            let entry = state.node_entry(&node_id).clone();
                            result.cancelled += 1;
                            emit(DeployEvent::NodeStateChanged {
                                node: node_id.clone(),
                                kind: entry.kind,
                                verdict: Verdict::Cancelled {
                                    because: CancelReason::External,
                                },
                                detail: None,
                            });
                            state.mark_terminal(&node_id, false);
                            continue;
                        }
                        // A panic in a node task is a bug, never a cluster
                        // condition.
                        let message = format!("a deploy task panicked: {join_err}");
                        emit(DeployEvent::Stopped {
                            reason: message.clone(),
                        });
                        tasks.shutdown().await;
                        return Err(DeployError::Internal {
                            message,
                            partial: result,
                        });
                    }
                    Some(TaskKind::Rediscovery) => {
                        barrier.in_flight = false;
                        progress.clear(&DISCOVERY_NODE);
                        if !aborted {
                            let message = format!("discovery refresh task panicked: {join_err}");
                            discovery_failed = Some(message.clone());
                            halting = true;
                            halting_reason = Some(message);
                        }
                        continue;
                    }
                    Some(TaskKind::Checkpoint) | None => {
                        checkpoints.in_flight = false;
                        if !aborted {
                            emit(DeployEvent::BestEffortFailed {
                                what: "activation checkpoint".into(),
                                message: format!("task panicked: {join_err}"),
                            });
                        }
                        continue;
                    }
                }
            }
        };

        match done {
            Done::Rediscovery(outcome) => {
                barrier.in_flight = false;
                progress.clear(&DISCOVERY_NODE);
                match outcome {
                    Ok(()) => {
                        for id in barrier.covered.drain(..) {
                            state.promote_dependents(&id);
                        }
                        if !halting {
                            barrier.start_if_needed(&mut tasks, &mut kinds, &ops, &progress, &emit);
                        }
                    }
                    Err(message) => {
                        // A stale discovery view is a partial view; the run
                        // does not continue on it. In-flight nodes finish.
                        discovery_failed = Some(message.clone());
                        halting = true;
                        halting_reason =
                            Some(format!("API rediscovery failed after CRD apply: {message}"));
                    }
                }
                continue;
            }
            Done::Checkpoint(outcome) => {
                checkpoints.in_flight = false;
                if let Err(message) = outcome {
                    emit(DeployEvent::BestEffortFailed {
                        what: "activation checkpoint".into(),
                        message,
                    });
                }
                checkpoints.start_if_due(&mut tasks, &mut kinds, &ops, config.dry_run);
                continue;
            }
            Done::Node(node_id, outcome) => {
                nodes_in_flight -= 1;
                progress.clear(&node_id);
                let entry = state.node_entry(&node_id).clone();
                match outcome {
                    NodeOutcome::Ready { apply_action } => {
                        checkpoints.count(&apply_action, &mut result);
                        emit(DeployEvent::NodeStateChanged {
                            node: node_id.clone(),
                            kind: entry.kind,
                            verdict: Verdict::Ready,
                            detail: Some(NodeDetail::Applied(apply_action)),
                        });
                        finish_success(&mut state, &mut barrier, &node_id, &entry);
                    }
                    NodeOutcome::Recreated {
                        apply_action,
                        reason,
                    } => {
                        if let NodeId::Resource(rid) = &node_id {
                            consumed_orphans.insert(rid.clone());
                        }
                        checkpoints.count(&apply_action, &mut result);
                        emit(DeployEvent::NodeStateChanged {
                            node: node_id.clone(),
                            kind: entry.kind,
                            verdict: Verdict::Ready,
                            detail: Some(NodeDetail::RecreatedInPlace { reason }),
                        });
                        finish_success(&mut state, &mut barrier, &node_id, &entry);
                    }
                    NodeOutcome::Failed { detail, message } => {
                        result.failed += 1;
                        checkpoints.failed += 1;
                        emit(DeployEvent::NodeStateChanged {
                            node: node_id.clone(),
                            kind: entry.kind,
                            verdict: Verdict::Failed {
                                message: message.clone(),
                            },
                            detail: Some(detail),
                        });
                        state.mark_terminal(&node_id, false);

                        // Cancel all transitive dependents.
                        let cancelled = state.cascade_cancel(&node_id);
                        let because = match &node_id {
                            NodeId::Resource(rid) => CancelReason::PredecessorFailed(rid.clone()),
                            NodeId::Synthetic(_) => CancelReason::External,
                        };
                        for dep_id in cancelled {
                            let dep_entry = state.node_entry(&dep_id).clone();
                            result.cancelled += 1;
                            emit(DeployEvent::NodeStateChanged {
                                node: dep_id,
                                kind: dep_entry.kind,
                                verdict: Verdict::Cancelled {
                                    because: because.clone(),
                                },
                                detail: None,
                            });
                        }

                        if config.on_error == OnErrorPolicy::Stop && !halting {
                            halting = true;
                            halting_reason = Some(format!("halt-on-first-failure: {message}"));
                        }
                    }
                    NodeOutcome::Cancelled => {
                        result.cancelled += 1;
                        emit(DeployEvent::NodeStateChanged {
                            node: node_id.clone(),
                            kind: entry.kind,
                            verdict: Verdict::Cancelled {
                                because: CancelReason::External,
                            },
                            detail: None,
                        });
                        state.mark_terminal(&node_id, false);
                    }
                }
                if !halting {
                    barrier.start_if_needed(&mut tasks, &mut kinds, &ops, &progress, &emit);
                }
                checkpoints.terminal();
                checkpoints.start_if_due(&mut tasks, &mut kinds, &ops, config.dry_run);
            }
        }
    }

    // From here on nothing is in flight, so inline awaits park nobody. They
    // are still bounded: a best-effort write that never answers must not
    // hold the run open.
    tasks.shutdown().await;

    // A cancel that landed as the last node finished may have let the loop
    // exit on its own; it must still stop the run here, before anything is
    // pruned or finalized.
    if config.cancel.is_cancelled() && !cancelling {
        cancelling = true;
        halting = true;
        halting_reason = Some(
            config
                .cancel
                .reason()
                .unwrap_or_else(|| "cancelled".to_string()),
        );
    }

    // Whatever stopped the run, every node that never reached a verdict gets
    // one now, so renderers never leave a row Pending under a `Stopped`
    // footer and the counts add up to the plan.
    if halting {
        for node_id in state.non_terminal() {
            let entry = state.node_entry(&node_id).clone();
            result.cancelled += 1;
            emit(DeployEvent::NodeStateChanged {
                node: node_id.clone(),
                kind: entry.kind,
                verdict: Verdict::Cancelled {
                    because: CancelReason::External,
                },
                detail: None,
            });
            state.mark_terminal(&node_id, false);
        }
    }

    if cancelling {
        let reason = halting_reason.unwrap_or_else(|| "cancelled".to_string());
        emit(DeployEvent::Stopped {
            reason: reason.clone(),
        });
        return Err(DeployError::Cancelled {
            reason,
            partial: result,
        });
    }

    // Final checkpoint / close-out if the cadence didn't already cover it.
    if !config.dry_run
        && (checkpoints.since_last > 0 || checkpoints.applied + checkpoints.failed > 0)
    {
        match tokio::time::timeout(
            INLINE_BEST_EFFORT_TIMEOUT,
            ops.checkpoint(checkpoints.applied, checkpoints.failed, true),
        )
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(message)) => emit(DeployEvent::BestEffortFailed {
                what: "activation checkpoint".into(),
                message,
            }),
            Err(_) => emit(DeployEvent::BestEffortFailed {
                what: "activation checkpoint".into(),
                message: format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
            }),
        }
    }

    if let Some(message) = discovery_failed {
        emit(DeployEvent::Stopped {
            reason: halting_reason.unwrap_or_else(|| message.clone()),
        });
        return Err(DeployError::DiscoveryFailed {
            message,
            partial: result,
        });
    }

    if halting {
        emit(DeployEvent::Stopped {
            reason: halting_reason.unwrap_or_else(|| "halting".into()),
        });
        return Err(DeployError::NodesFailed {
            count: result.failed,
            partial: result,
        });
    }

    // Stamp this activation onto the resources we skipped. They were skipped
    // because their content already matches, not because they left the
    // activation; without this the annotation only ever records the deploys
    // that happened to change a resource, and stable leaves (ServiceAccounts,
    // ConfigMaps, import markers) drift arbitrarily far behind.
    //
    // Best-effort by design, unlike the applied path: nothing was written to
    // these resources, so a failure here leaves the cluster exactly as it was
    // and cannot corrupt the applied state. Failures are counted and reported
    // rather than halting a deploy that otherwise succeeded. `KubeOps` makes
    // this a no-op under dry-run and when there is no activation hash.
    if !skipped.is_empty() && !config.dry_run {
        let mut failures = 0usize;
        for chunk in skipped.chunks(concurrency) {
            let mut set = JoinSet::new();
            for rid in chunk {
                let ops = ops.clone();
                let rid = rid.clone();
                set.spawn(async move {
                    match tokio::time::timeout(
                        INLINE_BEST_EFFORT_TIMEOUT,
                        ops.record_activation_on_skipped(&rid),
                    )
                    .await
                    {
                        Ok(Ok(())) => Ok(()),
                        Ok(Err(e)) => Err((rid, e)),
                        Err(_) => Err((
                            rid,
                            format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
                        )),
                    }
                });
            }
            while let Some(joined) = set.join_next().await {
                if let Ok(Err((rid, e))) = joined {
                    failures += 1;
                    tracing::warn!(resource = %rid.display_id(), error = %e, "could not record activation on unchanged resource");
                }
            }
        }
        if failures > 0 {
            emit(DeployEvent::BestEffortFailed {
                what: "activation stamp on unchanged resources".into(),
                message: format!(
                    "{failures} of {} not stamped; the deploy itself is unaffected and the next deploy retries",
                    skipped.len()
                ),
            });
        }
    }

    // Prune orphans (after all nodes terminal).
    let effective_orphans: Vec<ResourceId> = orphan_rids
        .iter()
        .filter(|rid| !consumed_orphans.contains(rid))
        .cloned()
        .collect();
    if !effective_orphans.is_empty() && config.prune != PrunePolicy::Skip {
        let ordered = prune_order(&effective_orphans, old_manifests);
        emit(DeployEvent::PruneStart {
            count: ordered.len(),
        });

        for rid in &ordered {
            // Warn-only policy: report and move on.
            if config.prune == PrunePolicy::WarnOnly {
                continue;
            }
            if rid.kind == "Namespace" {
                // Same policy as the legacy reconcile: never prune a Namespace
                // automatically; sweep the cluster manually after confirming.
                continue;
            }
            let deleted =
                match tokio::time::timeout(INLINE_BEST_EFFORT_TIMEOUT, ops.delete(rid)).await {
                    Ok(outcome) => outcome,
                    Err(_) => Err(format!(
                        "no answer within {}s",
                        INLINE_BEST_EFFORT_TIMEOUT.as_secs()
                    )),
                };
            match deleted {
                Ok(()) => {
                    result.pruned += 1;
                    emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(rid.clone()),
                        kind: TransitionKind::Delete,
                        verdict: Verdict::Ready,
                        detail: None,
                    });
                }
                Err(message) => {
                    result.failed += 1;
                    emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(rid.clone()),
                        kind: TransitionKind::Delete,
                        verdict: Verdict::Failed { message },
                        detail: None,
                    });
                }
            }
        }
    }

    // Finalize Activation lifecycle (unless pure no-op or dry-run).
    let actually_changed =
        result.created > 0 || result.configured > 0 || result.pruned > 0 || result.failed > 0;
    if !config.dry_run && actually_changed {
        match tokio::time::timeout(INLINE_BEST_EFFORT_TIMEOUT, ops.finalize(result.failed > 0))
            .await
        {
            Ok(Ok(Some(f))) => emit(DeployEvent::Finalized {
                activation: f.activation,
                previous: f.previous,
            }),
            Ok(Ok(None)) => {}
            Ok(Err(message)) => emit(DeployEvent::BestEffortFailed {
                what: "activation finalize".into(),
                message,
            }),
            Err(_) => emit(DeployEvent::BestEffortFailed {
                what: "activation finalize".into(),
                message: format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
            }),
        }
    }

    Ok(result)
}

/// Aborts the wrapped task when dropped, on every return path.
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// A node succeeded. CRD-like nodes hold their dependents until the next
/// discovery refresh completes (the barrier); everything else promotes at
/// once.
fn finish_success(
    state: &mut SchedulerState,
    barrier: &mut CrdBarrier,
    node_id: &NodeId,
    entry: &PlanNodeEntry,
) {
    if is_crd_like(entry) {
        state.mark_terminal_deferred(node_id);
        barrier.awaiting.push(node_id.clone());
    } else {
        state.mark_terminal(node_id, true);
    }
}

/// CRD barrier bookkeeping (doc 134 §2.3).
#[derive(Default)]
struct CrdBarrier {
    /// CRD nodes that are Ready and need a refresh to start after them.
    awaiting: Vec<NodeId>,
    /// CRD nodes covered by the refresh in flight.
    covered: Vec<NodeId>,
    in_flight: bool,
}

impl CrdBarrier {
    fn start_if_needed(
        &mut self,
        tasks: &mut JoinSet<Done>,
        kinds: &mut HashMap<tokio::task::Id, TaskKind>,
        ops: &Arc<dyn ClusterOps>,
        progress: &Progress,
        emit: &impl Fn(DeployEvent),
    ) {
        if self.in_flight || self.awaiting.is_empty() {
            return;
        }
        self.covered = std::mem::take(&mut self.awaiting);
        self.in_flight = true;
        emit(DeployEvent::CrdRediscovery);
        progress.set_phase(&DISCOVERY_NODE, Phase::Discovery);
        let ops = ops.clone();
        let handle = tasks.spawn(async move {
            Done::Rediscovery(ops.rediscover().await.map_err(|e| e.to_string()))
        });
        kinds.insert(handle.id(), TaskKind::Rediscovery);
    }
}

/// Checkpoint cadence. Running totals, one write in flight at most.
#[derive(Default)]
struct Checkpoints {
    applied: usize,
    failed: usize,
    since_last: usize,
    in_flight: bool,
}

impl Checkpoints {
    fn count(&mut self, action: &ApplyAction, result: &mut DeployResult) {
        match action {
            ApplyAction::Created => {
                result.created += 1;
                self.applied += 1;
            }
            ApplyAction::Configured => {
                result.configured += 1;
                self.applied += 1;
            }
            ApplyAction::Unchanged | ApplyAction::Skipped => {
                result.unchanged += 1;
            }
        }
    }

    fn terminal(&mut self) {
        self.since_last += 1;
    }

    fn start_if_due(
        &mut self,
        tasks: &mut JoinSet<Done>,
        kinds: &mut HashMap<tokio::task::Id, TaskKind>,
        ops: &Arc<dyn ClusterOps>,
        dry_run: bool,
    ) {
        if dry_run || self.in_flight || self.since_last < CHECKPOINT_BATCH {
            return;
        }
        self.since_last = 0;
        self.in_flight = true;
        let ops = ops.clone();
        let (applied, failed) = (self.applied, self.failed);
        let handle = tasks
            .spawn(async move { Done::Checkpoint(ops.checkpoint(applied, failed, false).await) });
        kinds.insert(handle.id(), TaskKind::Checkpoint);
    }
}

// ---------------------------------------------------------------------------
// Scheduler state
// ---------------------------------------------------------------------------

struct SchedulerState {
    entries: HashMap<NodeId, PlanNodeEntry>,
    /// Remaining non-Ready predecessors.
    pending_preds: HashMap<NodeId, usize>,
    /// Predecessor → dependents (reverse adjacency).
    dependents: HashMap<NodeId, Vec<NodeId>>,
    /// Nodes ready to execute.
    ready: VecDeque<NodeId>,
    /// Nodes already emitted to ready (guard against double-push).
    enqueued: HashSet<NodeId>,
    /// Terminal nodes.
    terminal: HashSet<NodeId>,
}

impl SchedulerState {
    fn new(plan: &DeployPlan) -> Self {
        let mut entries = HashMap::with_capacity(plan.nodes.len());
        for e in &plan.nodes {
            entries.insert(e.id.clone(), e.clone());
        }
        let mut pending_preds: HashMap<NodeId, usize> =
            entries.keys().map(|id| (id.clone(), 0)).collect();
        let mut dependents: HashMap<NodeId, Vec<NodeId>> = HashMap::new();
        for (dep, pred) in &plan.edges {
            if !entries.contains_key(dep) || !entries.contains_key(pred) {
                continue;
            }
            *pending_preds.entry(dep.clone()).or_insert(0) += 1;
            dependents
                .entry(pred.clone())
                .or_default()
                .push(dep.clone());
        }
        Self {
            entries,
            pending_preds,
            dependents,
            ready: VecDeque::new(),
            enqueued: HashSet::new(),
            terminal: HashSet::new(),
        }
    }

    fn seed_ready(&mut self) {
        let zero_pred: Vec<NodeId> = self
            .pending_preds
            .iter()
            .filter(|(_, c)| **c == 0)
            .map(|(id, _)| id.clone())
            .collect();
        // Lexicographic-ish determinism for test stability: sort Resource nodes
        // by (kind, namespace, name).
        let mut zero_pred = zero_pred;
        zero_pred.sort_by_key(node_sort_key);
        for id in zero_pred {
            if self.enqueued.insert(id.clone()) {
                self.ready.push_back(id);
            }
        }
    }

    fn pop_ready(&mut self) -> Option<NodeId> {
        self.ready.pop_front()
    }

    fn ready_is_empty(&self) -> bool {
        self.ready.is_empty()
    }

    /// Every node without a verdict, in deterministic order.
    fn non_terminal(&self) -> Vec<NodeId> {
        let mut out: Vec<NodeId> = self
            .entries
            .keys()
            .filter(|id| !self.terminal.contains(*id))
            .cloned()
            .collect();
        out.sort_by_key(node_sort_key);
        out
    }

    fn node_entry(&self, id: &NodeId) -> &PlanNodeEntry {
        self.entries.get(id).expect("node id must be in plan")
    }

    /// Mark a node terminal. If `success`, promote any dependents whose last
    /// predecessor just became Ready onto the ready queue. If not a success,
    /// the caller is responsible for cascade-cancelling dependents.
    fn mark_terminal(&mut self, id: &NodeId, success: bool) {
        self.terminal.insert(id.clone());
        if !success {
            return;
        }
        self.promote_dependents(id);
    }

    /// Mark a node terminal without promoting its dependents yet. Used for
    /// CRD nodes, whose dependents wait for the discovery refresh
    /// ([`promote_dependents`](Self::promote_dependents) follows).
    fn mark_terminal_deferred(&mut self, id: &NodeId) {
        self.terminal.insert(id.clone());
    }

    /// Promote every dependent of `id` whose last predecessor is now Ready.
    fn promote_dependents(&mut self, id: &NodeId) {
        let deps = self.dependents.get(id).cloned().unwrap_or_default();
        for dep in deps {
            let Some(count) = self.pending_preds.get_mut(&dep) else {
                continue;
            };
            if *count > 0 {
                *count -= 1;
            }
            if *count == 0 && !self.terminal.contains(&dep) && self.enqueued.insert(dep.clone()) {
                self.ready.push_back(dep);
            }
        }
    }

    /// Cascade-cancel: mark every transitive dependent of `id` terminal (as
    /// cancelled) and return the list so the caller can emit events.
    fn cascade_cancel(&mut self, id: &NodeId) -> Vec<NodeId> {
        let mut cancelled = Vec::new();
        let mut queue: VecDeque<NodeId> = self
            .dependents
            .get(id)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .collect();
        while let Some(n) = queue.pop_front() {
            if self.terminal.contains(&n) {
                continue;
            }
            self.terminal.insert(n.clone());
            cancelled.push(n.clone());
            if let Some(next) = self.dependents.get(&n) {
                for d in next {
                    queue.push_back(d.clone());
                }
            }
        }
        cancelled
    }
}

fn node_sort_key(id: &NodeId) -> (String, String, String) {
    match id {
        NodeId::Resource(rid) => (rid.kind.clone(), rid.namespace.clone(), rid.name.clone()),
        NodeId::Synthetic(s) => (String::new(), String::new(), s.clone()),
    }
}

// ---------------------------------------------------------------------------
// Per-node execution
// ---------------------------------------------------------------------------

struct NodeCtx {
    ops: Arc<dyn ClusterOps>,
    cancel: CancelToken,
    timeout: Duration,
    orphan_set: HashSet<ResourceId>,
    dry_run: bool,
    progress: Arc<Progress>,
    observer: Arc<dyn DeployObserver>,
}

impl NodeCtx {
    fn emit(&self, event: DeployEvent) {
        self.progress.touch();
        self.observer.on_event(&event);
    }
}

enum NodeOutcome {
    Ready {
        apply_action: ApplyAction,
    },
    Recreated {
        apply_action: ApplyAction,
        reason: String,
    },
    Failed {
        detail: NodeDetail,
        message: String,
    },
    Cancelled,
}

/// Runs on its own task. Hydrate, apply, wait for readiness, report.
async fn execute_node(ctx: &NodeCtx, entry: &PlanNodeEntry) -> NodeOutcome {
    // Only Apply reaches this path today; Skip is short-circuited in the
    // main loop, and Recreate/Migrate/Drain/Delete/Pause are Stage E/F.
    let manifest = match &entry.action {
        ChangeAction::Apply(m) => m.clone(),
        ChangeAction::Skip(_) => {
            return NodeOutcome::Ready {
                apply_action: ApplyAction::Unchanged,
            };
        }
        ChangeAction::Orphan(_) => {
            return NodeOutcome::Ready {
                apply_action: ApplyAction::Skipped,
            };
        }
    };
    let rid = ResourceId::from_value(&manifest);
    let node = NodeId::Resource(rid.clone());

    // Hydrate SOPS secrets before apply.
    let manifest = if secrets::needs_hydration(&manifest) {
        ctx.progress.set_phase(&node, Phase::Hydrate);
        match ctx.ops.hydrate(manifest).await {
            Ok((manifest, results)) => {
                for hr in &results {
                    ctx.emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(hr.rid.clone()),
                        kind: TransitionKind::Apply,
                        verdict: Verdict::Running,
                        detail: Some(NodeDetail::SecretHydrated {
                            keys: hr.keys_injected,
                        }),
                    });
                }
                manifest
            }
            Err(e) => {
                return NodeOutcome::Failed {
                    detail: NodeDetail::SecretHydrationFailed(e.to_string()),
                    message: format!("secret hydration failed: {e}"),
                };
            }
        }
    } else {
        manifest
    };

    // Apply. Kind resolution (with refresh-on-miss) lives in the ops layer.
    ctx.progress.set_phase(&node, Phase::Apply);
    let applied_action: ApplyAction;
    let mut recreated_reason: Option<String> = None;
    match ctx.ops.apply(&manifest).await {
        Ok(result) => {
            applied_action = result.action;
        }
        Err(ApplyError::ImmutableConflict { source, .. }) if ctx.orphan_set.contains(&rid) => {
            let reason = source.to_string();
            match ctx.ops.recreate_in_place(&manifest).await {
                Ok(apply_result) => {
                    applied_action = apply_result.action;
                    recreated_reason = Some(reason);
                }
                Err(e) => {
                    return NodeOutcome::Failed {
                        detail: NodeDetail::ApplyFailed(e.clone()),
                        message: e,
                    };
                }
            }
        }
        Err(e) => {
            return NodeOutcome::Failed {
                detail: NodeDetail::ApplyFailed(e.to_string()),
                message: e.to_string(),
            };
        }
    }

    // Surface apply outcome to the renderer as a mid-flight progress event.
    ctx.emit(DeployEvent::NodeStateChanged {
        node: node.clone(),
        kind: TransitionKind::Apply,
        verdict: Verdict::Running,
        detail: Some(NodeDetail::Applied(applied_action.clone())),
    });

    let done = |recreated_reason: Option<String>| match recreated_reason {
        Some(reason) => NodeOutcome::Recreated {
            apply_action: applied_action.clone(),
            reason,
        },
        None => NodeOutcome::Ready {
            apply_action: applied_action.clone(),
        },
    };

    // Under apiserver dry-run (`?dryRun=All`) the object was never persisted,
    // so polling readiness would 404 or time out. Readiness is a runtime-cluster
    // outcome and orthogonal to "what would this apply do", so we synthesise
    // Ready immediately. The renderer paints the same terminal line.
    if ctx.dry_run {
        return done(recreated_reason);
    }

    let import_target: Option<ImportTarget> = entry.meta.import_target.clone();
    if import_target.is_none() && readiness::is_immediate_kind(&rid.kind) {
        return done(recreated_reason);
    }

    // Wait for readiness. Every status callback counts as progress for the
    // watchdog, so a long but healthy rollout is never reported as a stall.
    ctx.progress.set_phase(&node, Phase::Readiness);
    let on_status = |msg: &str| {
        ctx.emit(DeployEvent::NodeStateChanged {
            node: node.clone(),
            kind: TransitionKind::Apply,
            verdict: Verdict::Running,
            detail: Some(NodeDetail::ReadinessProgress(msg.to_string())),
        });
    };
    let outcome = ctx
        .ops
        .wait_ready(
            &rid,
            import_target.as_ref(),
            ctx.timeout,
            &ctx.cancel,
            &on_status,
        )
        .await;

    let outcome = match outcome {
        Ok(o) => o,
        Err(e) => {
            tracing::warn!("readiness error for {rid}: {e}");
            return NodeOutcome::Failed {
                detail: NodeDetail::ReadinessFailed {
                    message: e.to_string(),
                    missing_keys: Vec::new(),
                },
                message: e.to_string(),
            };
        }
    };

    match outcome {
        ReadinessResult::Ready => done(recreated_reason),
        ReadinessResult::Cancelled => NodeOutcome::Cancelled,
        ReadinessResult::TimedOut { elapsed, message } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessTimeout {
                elapsed,
                message: message.clone(),
            },
            message,
        },
        ReadinessResult::Failed(message) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys: Vec::new(),
            },
            message,
        },
        ReadinessResult::ImportMismatch {
            missing_keys,
            message,
        } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys,
            },
            message,
        },
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Reverse-topological ordering over the subset of `old_manifests` matching
/// `orphan_rids`. Lifted here so scheduler.rs stops depending on
/// `reconcile::compute_prune_order` (which exists only until reconcile.rs is
/// deleted in doc 99 Stage D.5).
fn prune_order(orphan_rids: &[ResourceId], old_manifests: &[Value]) -> Vec<ResourceId> {
    let orphan_set: HashSet<String> = orphan_rids
        .iter()
        .map(|rid| format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
        .collect();
    let orphan_manifests: Vec<Value> = old_manifests
        .iter()
        .filter(|m| {
            let rid = ResourceId::from_value(m);
            orphan_set.contains(&format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
        })
        .cloned()
        .collect();
    match ResourceGraph::from_manifests(&orphan_manifests) {
        Ok(graph) => graph.reverse_topo_ids(),
        Err(_) => orphan_rids.to_vec(),
    }
}

fn is_crd_like(entry: &PlanNodeEntry) -> bool {
    match &entry.id {
        NodeId::Resource(rid) if rid.kind == "CustomResourceDefinition" => true,
        _ => entry
            .meta
            .import_target
            .as_ref()
            .is_some_and(|t| t.kind == "CustomResourceDefinition"),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    fn manifest(kind: &str, name: &str, ns: &str, id_hash: &str, deps: &str) -> Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert("kix.dev/identity-hash".into(), json!(id_hash));
        if !deps.is_empty() {
            annotations.insert("kix.dev/depends-on".into(), json!(deps));
        }
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": annotations,
            }
        })
    }

    #[test]
    fn plan_from_linear_chain_has_expected_edges() {
        let manifests = vec![
            manifest("Namespace", "default", CLUSTER_SCOPED, "h_ns", ""),
            manifest("ServiceAccount", "sa", "default", "h_sa", "h_ns"),
            manifest("Deployment", "app", "default", "h_app", "h_sa"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let changes: Vec<ChangeAction> = manifests
            .iter()
            .map(|m| ChangeAction::Apply(m.clone()))
            .collect();
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes);

        assert_eq!(plan.nodes.len(), 3);
        assert_eq!(plan.edges.len(), 2);
        // Every node is Apply (not Skip).
        for node in &plan.nodes {
            assert!(matches!(node.kind, TransitionKind::Apply));
        }
    }

    #[test]
    fn plan_marks_skip_when_change_action_is_skip() {
        let manifests = vec![
            manifest("ConfigMap", "cm", "default", "h_cm", ""),
            manifest("Deployment", "app", "default", "h_app", "h_cm"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        // cm is Skip (unchanged), app is Apply.
        let changes = vec![
            ChangeAction::Skip(ResourceId::from_value(&manifests[0])),
            ChangeAction::Apply(manifests[1].clone()),
        ];
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes);
        assert_eq!(plan.nodes.len(), 2);
        let cm = plan
            .nodes
            .iter()
            .find(|n| matches!(&n.id, NodeId::Resource(rid) if rid.name == "cm"))
            .unwrap();
        let app = plan
            .nodes
            .iter()
            .find(|n| matches!(&n.id, NodeId::Resource(rid) if rid.name == "app"))
            .unwrap();
        assert!(matches!(cm.kind, TransitionKind::Skip));
        assert!(matches!(app.kind, TransitionKind::Apply));
    }

    #[test]
    fn scheduler_state_seeds_zero_pred_nodes() {
        let manifests = vec![
            manifest("Namespace", "default", CLUSTER_SCOPED, "h_ns", ""),
            manifest("ConfigMap", "cm", "default", "h_cm", "h_ns"),
            manifest("ServiceAccount", "sa", "default", "h_sa", "h_ns"),
            manifest("Deployment", "app", "default", "h_app", "h_sa,h_cm"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let changes: Vec<ChangeAction> = manifests
            .iter()
            .map(|m| ChangeAction::Apply(m.clone()))
            .collect();
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes);

        let mut state = SchedulerState::new(&plan);
        state.seed_ready();

        // Only the Namespace has zero predecessors.
        let ready: Vec<_> = std::iter::from_fn(|| state.pop_ready()).collect();
        assert_eq!(ready.len(), 1);
        match &ready[0] {
            NodeId::Resource(rid) => assert_eq!(rid.name, "default"),
            _ => panic!("unexpected synthetic node"),
        }

        // Marking ns terminal (success) should promote cm AND sa (both depend
        // only on ns) but not app (still waiting on sa + cm).
        state.mark_terminal(&ready[0], true);
        let next: Vec<_> = std::iter::from_fn(|| state.pop_ready()).collect();
        assert_eq!(next.len(), 2);
        let names: Vec<&str> = next
            .iter()
            .map(|id| match id {
                NodeId::Resource(rid) => rid.name.as_str(),
                _ => "",
            })
            .collect();
        assert!(names.contains(&"cm"));
        assert!(names.contains(&"sa"));
    }

    #[test]
    fn scheduler_state_cascade_cancels_transitive_dependents() {
        let manifests = vec![
            manifest("Namespace", "default", CLUSTER_SCOPED, "h_ns", ""),
            manifest("ServiceAccount", "sa", "default", "h_sa", "h_ns"),
            manifest("Deployment", "app", "default", "h_app", "h_sa"),
            manifest("Ingress", "ing", "default", "h_ing", "h_app"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let changes: Vec<ChangeAction> = manifests
            .iter()
            .map(|m| ChangeAction::Apply(m.clone()))
            .collect();
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes);
        let mut state = SchedulerState::new(&plan);
        state.seed_ready();
        let _ns = state.pop_ready().unwrap();

        // Cancel cascade from "sa": app and ing should go down.
        let sa_id = plan
            .nodes
            .iter()
            .find_map(|n| match &n.id {
                NodeId::Resource(rid) if rid.name == "sa" => Some(n.id.clone()),
                _ => None,
            })
            .unwrap();
        let cancelled = state.cascade_cancel(&sa_id);
        assert_eq!(cancelled.len(), 2);
        let names: Vec<&str> = cancelled
            .iter()
            .map(|id| match id {
                NodeId::Resource(rid) => rid.name.as_str(),
                _ => "",
            })
            .collect();
        assert!(names.contains(&"app"));
        assert!(names.contains(&"ing"));
    }
}

/// Engine tests: `run_deploy` against the scripted fake, no cluster, paused
/// clock. Every run is wrapped in a one-hour virtual timeout: a parked engine
/// fails at once instead of hanging the suite (doc 134 §3).
#[cfg(test)]
mod engine_tests {
    use super::*;
    use crate::cluster::ops::scripted::{
        ApplyFailure, Behaviour, Call, Gate, NodeScript, Ready, ScriptedOps,
    };
    use crate::cluster::stream::{InFlight, NullObserver};
    use serde_json::json;
    use std::sync::Mutex;
    use tokio::time::Instant;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            namespace: if kind == "CustomResourceDefinition" {
                CLUSTER_SCOPED.into()
            } else {
                "default".into()
            },
            name: name.into(),
        }
    }

    /// A manifest whose identity hash is `h_<name>` and whose predecessors
    /// are named in `deps`.
    fn m(kind: &str, name: &str, deps: &[&str]) -> Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert("kix.dev/identity-hash".into(), json!(format!("h_{name}")));
        if !deps.is_empty() {
            let deps: Vec<String> = deps.iter().map(|d| format!("h_{d}")).collect();
            annotations.insert("kix.dev/depends-on".into(), json!(deps.join(",")));
        }
        let mut metadata = json!({ "name": name, "annotations": annotations });
        if kind != "CustomResourceDefinition" {
            metadata["namespace"] = json!("default");
        }
        json!({ "apiVersion": "v1", "kind": kind, "metadata": metadata })
    }

    fn plan_of(manifests: &[Value]) -> DeployPlan {
        plan_with_skips(manifests, &[])
    }

    /// Like `plan_of`, but the named resources are `Skip` (unchanged) nodes.
    fn plan_with_skips(manifests: &[Value], skip: &[&str]) -> DeployPlan {
        let graph = ResourceGraph::from_manifests(manifests).unwrap();
        let changes: Vec<ChangeAction> = manifests
            .iter()
            .map(|m| {
                let rid = ResourceId::from_value(m);
                if skip.contains(&rid.name.as_str()) {
                    ChangeAction::Skip(rid)
                } else {
                    ChangeAction::Apply(m.clone())
                }
            })
            .collect();
        DeployPlan::from_graph_and_changes(&graph, &changes)
    }

    fn config(stall: StallPolicy) -> SchedulerConfig {
        SchedulerConfig {
            timeout: secs(300),
            on_error: OnErrorPolicy::Continue,
            prune: PrunePolicy::WarnOnly,
            cancel: CancelToken::new(),
            dry_run: false,
            concurrency: CONCURRENCY,
            stall,
        }
    }

    fn quiet_watchdog() -> StallPolicy {
        StallPolicy::off()
    }

    #[derive(Default)]
    struct Recorder(Mutex<Vec<DeployEvent>>);

    impl DeployObserver for Recorder {
        fn on_event(&self, event: &DeployEvent) {
            self.0.lock().unwrap().push(event.clone());
        }
    }

    impl Recorder {
        fn stalls(&self) -> Vec<(Duration, Vec<InFlight>, bool)> {
            self.0
                .lock()
                .unwrap()
                .iter()
                .filter_map(|e| match e {
                    DeployEvent::Stalled {
                        idle,
                        in_flight,
                        aborting,
                    } => Some((*idle, in_flight.clone(), *aborting)),
                    _ => None,
                })
                .collect()
        }

        fn best_effort_failures(&self) -> Vec<String> {
            self.0
                .lock()
                .unwrap()
                .iter()
                .filter_map(|e| match e {
                    DeployEvent::BestEffortFailed { what, message } => {
                        Some(format!("{what}: {message}"))
                    }
                    _ => None,
                })
                .collect()
        }

        fn stopped(&self) -> Option<String> {
            self.0.lock().unwrap().iter().find_map(|e| match e {
                DeployEvent::Stopped { reason } => Some(reason.clone()),
                _ => None,
            })
        }

        /// Terminal verdicts per node, in order of emission.
        fn terminals(&self) -> Vec<(NodeId, Verdict)> {
            self.0
                .lock()
                .unwrap()
                .iter()
                .filter_map(|e| match e {
                    DeployEvent::NodeStateChanged { node, verdict, .. }
                        if verdict.is_terminal() =>
                    {
                        Some((node.clone(), verdict.clone()))
                    }
                    _ => None,
                })
                .collect()
        }

        fn terminal_count(&self, node: &NodeId) -> usize {
            self.terminals().iter().filter(|(n, _)| n == node).count()
        }
    }

    /// Run the engine. Panics if it parks: under the paused clock the
    /// timeout fires the moment nothing is runnable.
    async fn run(
        ops: &Arc<ScriptedOps>,
        plan: DeployPlan,
        config: &SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        let ops: Arc<dyn ClusterOps> = ops.clone();
        tokio::time::timeout(
            secs(3600),
            run_deploy(ops, plan, &[], &[], config, observer),
        )
        .await
        .expect("engine parked: nothing runnable for an hour of virtual time")
    }

    /// `run` with orphans to prune.
    async fn run_with_orphans(
        ops: &Arc<ScriptedOps>,
        plan: DeployPlan,
        orphans: &[ResourceId],
        old_manifests: &[Value],
        config: &SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        let ops: Arc<dyn ClusterOps> = ops.clone();
        tokio::time::timeout(
            secs(3600),
            run_deploy(ops, plan, orphans, old_manifests, config, observer),
        )
        .await
        .expect("engine parked: nothing runnable for an hour of virtual time")
    }

    fn total(r: &DeployResult) -> usize {
        r.created + r.configured + r.unchanged + r.failed + r.cancelled
    }

    /// Doc 134 test 1. 64 slow applies fill the concurrency cap; a CRD
    /// finishes at once and its dependent must not wait for the slow ones,
    /// only for the discovery refresh.
    #[tokio::test(start_paused = true)]
    async fn crd_barrier_does_not_park_running_nodes() {
        let mut manifests: Vec<Value> = (0..64)
            .map(|i| m("Deployment", &format!("d{i}"), &[]))
            .collect();
        manifests.push(m("CustomResourceDefinition", "widgets", &[]));
        manifests.push(m("Widget", "w", &["widgets"]));
        let ops = Arc::new(ScriptedOps::new());
        ops.default_node(
            NodeScript::default().apply(Behaviour::After(secs(5), Ok(ApplyAction::Created))),
        );
        ops.script(
            rid("CustomResourceDefinition", "widgets"),
            NodeScript::default(),
        );
        ops.script(rid("Widget", "w"), NodeScript::default());
        ops.default_rediscover(Behaviour::After(secs(1), Ok(())));
        let mut cfg = config(quiet_watchdog());
        cfg.concurrency = 100;

        let start = Instant::now();
        let result = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
            .await
            .unwrap();

        assert_eq!(result.created, 66);
        assert_eq!(start.elapsed(), secs(5), "slow applies bound the run");
        let w = rid("Widget", "w");
        let rediscover_end = ops.time_of(|c| *c == Call::RediscoverEnd).unwrap();
        let w_start = ops.time_of(|c| *c == Call::ApplyStart(w.clone())).unwrap();
        assert_eq!(rediscover_end, secs(1));
        assert!(w_start >= rediscover_end, "dependent waits for the refresh");
        assert!(
            w_start < secs(5),
            "dependent does not wait for unrelated slow nodes"
        );
        assert_eq!(
            ops.calls()
                .iter()
                .filter(|c| **c == Call::RediscoverStart)
                .count(),
            1
        );
    }

    /// Doc 134 test 2. A failed refresh stops the run; the dependent is never
    /// applied; nodes already in flight finish.
    #[tokio::test(start_paused = true)]
    async fn rediscovery_failure_stops_the_run() {
        let manifests = vec![
            m("CustomResourceDefinition", "widgets", &[]),
            m("Widget", "w", &["widgets"]),
            m("Deployment", "slow", &[]),
        ];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "slow"),
            NodeScript::default().apply(Behaviour::After(secs(3), Ok(ApplyAction::Created))),
        );
        ops.rediscover_next(Behaviour::Now(Err("aggregated discovery 503".into())));
        let rec = Arc::new(Recorder::default());
        let cfg = config(quiet_watchdog());

        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        match err {
            DeployError::DiscoveryFailed { message, partial } => {
                assert!(message.contains("503"), "{message}");
                assert_eq!(partial.created, 2, "crd and the slow node finished");
            }
            other => panic!("expected DiscoveryFailed, got {other}"),
        }
        let w = rid("Widget", "w");
        assert!(ops.time_of(|c| *c == Call::ApplyStart(w.clone())).is_none());
        assert!(rec.stopped().unwrap().contains("rediscovery failed"));
    }

    /// Doc 134 test 3. A hung apply is named within the warn bound and the
    /// run is cancelled at the abort bound.
    #[tokio::test(start_paused = true)]
    async fn hung_apply_is_reported_then_aborted() {
        let manifests = vec![m("Deployment", "stuck", &[]), m("ConfigMap", "cm", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "stuck"),
            NodeScript::default().apply(Behaviour::Hang),
        );
        let rec = Arc::new(Recorder::default());
        let cfg = config(StallPolicy {
            warn_after: secs(30),
            abort_after: Some(secs(120)),
        });

        let start = Instant::now();
        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        let DeployError::Cancelled { reason, partial } = err else {
            panic!("expected Cancelled, got {err}");
        };
        assert!(reason.starts_with("no progress for 120s"), "{reason}");
        assert!(
            reason.contains("Deployment/stuck@default (apply, 12"),
            "{reason}"
        );
        assert_eq!(
            partial.created, 1,
            "the ConfigMap finished before the stall"
        );
        assert!(start.elapsed() >= secs(120) && start.elapsed() < secs(126));

        let stalls = rec.stalls();
        assert_eq!(
            stalls.len(),
            4,
            "warn at 30, 60, 90, abort at 120: {stalls:?}"
        );
        for (i, (idle, in_flight, aborting)) in stalls.iter().enumerate() {
            let expected = secs(30 * (i as u64 + 1));
            assert!(
                *idle >= expected && *idle < expected + secs(6),
                "stall {i} idle {idle:?}, expected about {expected:?}"
            );
            assert_eq!(*aborting, i == 3);
            assert_eq!(in_flight.len(), 1);
            assert_eq!(
                in_flight[0].node,
                NodeId::Resource(rid("Deployment", "stuck"))
            );
            assert_eq!(in_flight[0].phase, Phase::Apply);
        }
        assert_eq!(rec.stopped().as_deref(), Some(reason.as_str()));
        // The hung node gets a verdict: Cancelled, exactly once.
        let stuck = NodeId::Resource(rid("Deployment", "stuck"));
        assert_eq!(rec.terminal_count(&stuck), 1);
        assert_eq!(partial.cancelled, 1);
    }

    /// Doc 134 test 4. A slow but healthy rollout reports every 2s for five
    /// minutes. That is activity; the watchdog stays quiet.
    #[tokio::test(start_paused = true)]
    async fn readiness_progress_keeps_the_watchdog_quiet() {
        let manifests = vec![m("StatefulSet", "db", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("StatefulSet", "db"),
            NodeScript::default().ready(Behaviour::Now(Ready::Heartbeat {
                every: secs(2),
                count: 150,
                then: Box::new(Ready::Ready),
            })),
        );
        let rec = Arc::new(Recorder::default());
        let cfg = config(StallPolicy {
            warn_after: secs(30),
            abort_after: Some(secs(120)),
        });

        let start = Instant::now();
        let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap();

        assert_eq!(result.created, 1);
        assert_eq!(start.elapsed(), secs(300));
        assert!(rec.stalls().is_empty(), "{:?}", rec.stalls());
    }

    /// Doc 134 test 5. Cancel with every node hung returns at once, aborts
    /// the in-flight tasks (they never complete once released), and gives
    /// every node a verdict: the in-flight ones Cancelled, the pending
    /// dependent Cancelled.
    #[tokio::test(start_paused = true)]
    async fn cancel_terminates_promptly_and_accounts_for_everything() {
        let manifests = vec![
            m("Deployment", "a", &[]),
            m("Deployment", "b", &[]),
            m("Deployment", "c", &["a"]),
        ];
        let ops = Arc::new(ScriptedOps::new());
        let gate = Gate::new();
        ops.default_node(
            NodeScript::default().apply(Behaviour::Gate(gate.clone(), Ok(ApplyAction::Created))),
        );
        let cfg = config(quiet_watchdog());
        let token = cfg.cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(secs(1)).await;
            token.cancel_with_reason("interrupted");
        });
        let rec = Arc::new(Recorder::default());

        let start = Instant::now();
        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        let DeployError::Cancelled { reason, partial } = err else {
            panic!("expected Cancelled, got {err}");
        };
        assert_eq!(reason, "interrupted");
        assert_eq!(start.elapsed(), secs(1));
        assert_eq!(rec.stopped().as_deref(), Some("interrupted"));
        assert_eq!(
            partial.cancelled, 3,
            "a and b in flight, c pending: {partial:?}"
        );
        for name in ["a", "b", "c"] {
            assert_eq!(
                rec.terminal_count(&NodeId::Resource(rid("Deployment", name))),
                1
            );
        }
        // Opening the gate now must not complete anything: the tasks were
        // aborted, not left running.
        gate.open();
        tokio::time::sleep(secs(1)).await;
        assert!(
            !ops.calls().iter().any(|c| matches!(c, Call::ApplyEnd(_))),
            "an aborted apply completed after the run returned"
        );
        // A run that stopped writes nothing more.
        assert!(
            !ops.calls()
                .iter()
                .any(|c| matches!(c, Call::Finalize { .. } | Call::Delete(_)))
        );
    }

    /// Cancel while a node is in readiness: the node reports Cancelled, its
    /// dependent is Cancelled, and nothing after the loop runs (no prune, no
    /// finalize), even though the loop may exit on its own.
    #[tokio::test(start_paused = true)]
    async fn cancel_during_readiness_never_reaches_prune_or_finalize() {
        let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "a"),
            NodeScript::default().ready(Behaviour::Now(Ready::Heartbeat {
                every: secs(2),
                count: 100,
                then: Box::new(Ready::Ready),
            })),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.prune = PrunePolicy::Delete;
        let token = cfg.cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(secs(5)).await;
            token.cancel();
        });
        let rec = Arc::new(Recorder::default());
        let orphans = [rid("ConfigMap", "old")];
        let old = [m("ConfigMap", "old", &[])];

        let err = run_with_orphans(&ops, plan_of(&manifests), &orphans, &old, &cfg, rec.clone())
            .await
            .unwrap_err();

        assert!(matches!(err, DeployError::Cancelled { .. }), "{err}");
        let calls = ops.calls();
        assert!(
            !calls
                .iter()
                .any(|c| matches!(c, Call::Delete(_) | Call::Finalize { .. }))
        );
        assert_eq!(
            rec.terminal_count(&NodeId::Resource(rid("Deployment", "a"))),
            1
        );
        assert_eq!(
            rec.terminal_count(&NodeId::Resource(rid("Deployment", "b"))),
            1
        );
    }

    /// Doc 134 test 6. A checkpoint write that never answers neither parks
    /// the nodes nor holds the run open.
    #[tokio::test(start_paused = true)]
    async fn hung_checkpoint_does_not_hold_the_run() {
        let manifests: Vec<Value> = (0..40)
            .map(|i| m("ConfigMap", &format!("cm{i}"), &[]))
            .collect();
        let ops = Arc::new(ScriptedOps::new());
        // 16 nodes finish at 1s (that spawns the first checkpoint, which
        // hangs), 16 more at 2s, the last 8 at 3s.
        for i in 0..40 {
            ops.script(
                rid("ConfigMap", &format!("cm{i}")),
                NodeScript::default()
                    .apply(Behaviour::After(secs(1 + i / 16), Ok(ApplyAction::Created))),
            );
        }
        ops.checkpoint_behaviour(Behaviour::Hang);
        let rec = Arc::new(Recorder::default());
        let cfg = config(quiet_watchdog());

        let start = Instant::now();
        let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap();

        assert_eq!(result.created, 40);
        let mid_run = ops
            .calls()
            .iter()
            .filter(|c| {
                matches!(
                    c,
                    Call::Checkpoint {
                        finalizing: false,
                        ..
                    }
                )
            })
            .count();
        assert_eq!(mid_run, 1, "one checkpoint in flight at most, and it hung");
        // Nodes kept finishing (t=2s, t=3s) while the checkpoint hung; only
        // the final inline checkpoint costs its bounded timeout.
        let last_apply = ops
            .log()
            .iter()
            .filter(|l| matches!(l.call, Call::ApplyEnd(_)))
            .map(|l| l.at)
            .max()
            .unwrap();
        assert_eq!(last_apply, secs(3));
        assert_eq!(start.elapsed(), secs(3) + INLINE_BEST_EFFORT_TIMEOUT);
        let failures = rec.best_effort_failures();
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(failures[0].starts_with("activation checkpoint: no answer within"));
    }

    /// Admission streams: a slot freed by one fast node is refilled at once,
    /// not when the whole batch drains.
    #[tokio::test(start_paused = true)]
    async fn admission_refills_a_slot_as_soon_as_it_frees() {
        let manifests: Vec<Value> = (0..65)
            .map(|i| m("ConfigMap", &format!("cm{i:02}"), &[]))
            .collect();
        let ops = Arc::new(ScriptedOps::new());
        ops.default_node(
            NodeScript::default().apply(Behaviour::After(secs(10), Ok(ApplyAction::Created))),
        );
        // Admission is in sorted order, so cm00 is in the first batch.
        ops.script(
            rid("ConfigMap", "cm00"),
            NodeScript::default().apply(Behaviour::After(secs(1), Ok(ApplyAction::Created))),
        );
        let cfg = config(quiet_watchdog());

        let start = Instant::now();
        let result = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
            .await
            .unwrap();

        assert_eq!(result.created, 65);
        let last = rid("ConfigMap", "cm64");
        assert_eq!(
            ops.time_of(|c| *c == Call::ApplyStart(last.clone())),
            Some(secs(1)),
            "the 65th node starts when the fast node frees its slot"
        );
        assert_eq!(start.elapsed(), secs(11));
    }

    /// Doc 134 test 7. Peak concurrency equals the cap and never exceeds it.
    #[tokio::test(start_paused = true)]
    async fn concurrency_never_exceeds_the_cap() {
        let manifests: Vec<Value> = (0..200)
            .map(|i| m("ConfigMap", &format!("cm{i}"), &[]))
            .collect();
        let ops = Arc::new(ScriptedOps::new());
        ops.default_node(
            NodeScript::default().apply(Behaviour::After(secs(1), Ok(ApplyAction::Created))),
        );
        let cfg = config(quiet_watchdog());

        let start = Instant::now();
        let result = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
            .await
            .unwrap();

        assert_eq!(result.created, 200);
        assert_eq!(ops.peak_concurrent_applies(), CONCURRENCY);
        assert_eq!(start.elapsed(), secs(4), "200 nodes in batches of 64");
    }

    /// Doc 134 test 8. A node task that panics is a fatal engine error, not
    /// a lost node.
    #[tokio::test(start_paused = true)]
    async fn panicking_node_is_fatal() {
        let manifests = vec![m("ConfigMap", "boom", &[]), m("ConfigMap", "ok", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("ConfigMap", "boom"),
            NodeScript::default().apply(Behaviour::Panic("scripted panic".into())),
        );
        let cfg = config(quiet_watchdog());

        let err = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
            .await
            .unwrap_err();

        let DeployError::Internal { message, .. } = err else {
            panic!("expected Internal, got {err}");
        };
        assert!(message.contains("panicked"), "{message}");
    }

    /// Gated applies: the run does not finish until the test opens the gate,
    /// and does finish then. Pins the fake's central property.
    #[tokio::test(start_paused = true)]
    async fn gated_apply_completes_only_when_released() {
        let manifests = vec![m("ConfigMap", "g", &[])];
        let ops = Arc::new(ScriptedOps::new());
        let gate = Gate::new();
        ops.script(
            rid("ConfigMap", "g"),
            NodeScript::default().apply(Behaviour::Gate(gate.clone(), Ok(ApplyAction::Created))),
        );
        let cfg = config(quiet_watchdog());
        let ops2 = ops.clone();
        let handle = tokio::spawn(async move {
            run(&ops2, plan_of(&manifests), &cfg, Arc::new(NullObserver)).await
        });
        tokio::time::sleep(secs(10)).await;
        assert!(!handle.is_finished());
        gate.open();
        let result = handle.await.unwrap().unwrap();
        assert_eq!(result.created, 1);
    }

    /// An immutable conflict on a pre-authorized orphan recreates in place.
    #[tokio::test(start_paused = true)]
    async fn immutable_conflict_recreates_when_preauthorized() {
        let manifests = vec![m("Deployment", "sts", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "sts"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::ImmutableConflict))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.prune = PrunePolicy::Delete;
        let orphans = [rid("Deployment", "sts")];
        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &manifests,
            &cfg,
            Arc::new(NullObserver),
        )
        .await
        .unwrap();
        assert_eq!(result.configured, 1);
        assert!(
            ops.calls()
                .contains(&Call::RecreateStart(rid("Deployment", "sts")))
        );
        assert_eq!(result.pruned, 0, "the consumed orphan is not pruned again");
        assert!(!ops.calls().iter().any(|c| matches!(c, Call::Delete(_))));
    }

    /// Red team finding: the watchdog must see a hung discovery refresh. With
    /// every node done and the barrier waiting, the run is not silent and
    /// gives up at the bound, naming the refresh.
    #[tokio::test(start_paused = true)]
    async fn hung_rediscovery_is_reported_and_aborted() {
        let manifests = vec![
            m("CustomResourceDefinition", "widgets", &[]),
            m("Widget", "w", &["widgets"]),
        ];
        let ops = Arc::new(ScriptedOps::new());
        ops.default_rediscover(Behaviour::Hang);
        let rec = Arc::new(Recorder::default());
        let cfg = config(StallPolicy {
            warn_after: secs(10),
            abort_after: Some(secs(30)),
        });

        let start = Instant::now();
        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        let DeployError::Cancelled { reason, partial } = err else {
            panic!("expected Cancelled, got {err}");
        };
        assert!(reason.contains("api-discovery (discovery, 3"), "{reason}");
        assert!(start.elapsed() >= secs(30) && start.elapsed() < secs(36));
        assert_eq!(partial.created, 1);
        assert_eq!(
            partial.cancelled, 1,
            "the dependent never ran and is Cancelled"
        );
        assert!(
            ops.time_of(|c| *c == Call::ApplyStart(rid("Widget", "w")))
                .is_none()
        );
        assert_eq!(rec.terminal_count(&NodeId::Resource(rid("Widget", "w"))), 1);
    }

    /// Red team finding: a hung stamp of an unchanged resource is bounded and
    /// reported, never a silent park.
    #[tokio::test(start_paused = true)]
    async fn hung_stamp_of_unchanged_resource_is_bounded() {
        let manifests = vec![m("ConfigMap", "same", &[]), m("ConfigMap", "new", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.stamp_behaviour(Behaviour::Hang);
        let rec = Arc::new(Recorder::default());
        let cfg = config(quiet_watchdog());

        let start = Instant::now();
        let result = run(
            &ops,
            plan_with_skips(&manifests, &["same"]),
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap();

        assert_eq!(result.unchanged, 1);
        assert_eq!(result.created, 1);
        assert!(ops.calls().contains(&Call::Stamp(rid("ConfigMap", "same"))));
        assert_eq!(start.elapsed(), INLINE_BEST_EFFORT_TIMEOUT);
        let failures = rec.best_effort_failures();
        assert_eq!(failures.len(), 1, "{failures:?}");
        assert!(failures[0].starts_with("activation stamp on unchanged resources: 1 of 1"));
    }

    /// Red team finding: a hung prune delete is bounded and reported as a
    /// failed delete, never a silent park. Namespaces are never pruned.
    #[tokio::test(start_paused = true)]
    async fn hung_prune_delete_is_bounded() {
        let manifests = vec![m("ConfigMap", "keep", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.delete_behaviour(Behaviour::Hang);
        let rec = Arc::new(Recorder::default());
        let mut cfg = config(quiet_watchdog());
        cfg.prune = PrunePolicy::Delete;
        let orphans = [rid("ConfigMap", "old"), rid("Namespace", "ns")];
        let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];

        let start = Instant::now();
        let result = run_with_orphans(&ops, plan_of(&manifests), &orphans, &old, &cfg, rec.clone())
            .await
            .unwrap();

        assert_eq!(result.pruned, 0);
        assert_eq!(
            result.failed, 1,
            "the hung delete counts as failed: {result:?}"
        );
        assert_eq!(start.elapsed(), INLINE_BEST_EFFORT_TIMEOUT);
        let delete_calls: Vec<Call> = ops
            .calls()
            .into_iter()
            .filter(|c| matches!(c, Call::Delete(_)))
            .collect();
        assert_eq!(delete_calls, vec![Call::Delete(rid("ConfigMap", "old"))]);
        let failed: Vec<(NodeId, Verdict)> = rec
            .terminals()
            .into_iter()
            .filter(|(_, v)| matches!(v, Verdict::Failed { .. }))
            .collect();
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].0, NodeId::Resource(rid("ConfigMap", "old")));
    }

    /// Under `OnErrorPolicy::Stop`, nodes still in flight finish and are
    /// counted; nodes never admitted get a Cancelled verdict.
    #[tokio::test(start_paused = true)]
    async fn halt_on_first_failure_finishes_in_flight_and_cancels_the_rest() {
        let manifests = vec![
            m("ConfigMap", "bad", &[]),
            m("ConfigMap", "slow", &[]),
            m("ConfigMap", "later", &["slow"]),
        ];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("ConfigMap", "bad"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("nope".into())))),
        );
        ops.script(
            rid("ConfigMap", "slow"),
            NodeScript::default().apply(Behaviour::After(secs(2), Ok(ApplyAction::Created))),
        );
        let rec = Arc::new(Recorder::default());
        let mut cfg = config(quiet_watchdog());
        cfg.on_error = OnErrorPolicy::Stop;

        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        let DeployError::NodesFailed { count, partial } = err else {
            panic!("expected NodesFailed, got {err}");
        };
        assert_eq!(count, 1);
        assert_eq!(partial.created, 1, "the in-flight node finished");
        assert_eq!(partial.cancelled, 1, "the never-admitted node is Cancelled");
        for name in ["bad", "slow", "later"] {
            assert_eq!(
                rec.terminal_count(&NodeId::Resource(rid("ConfigMap", name))),
                1,
                "{name}"
            );
        }
        assert!(rec.stopped().unwrap().starts_with("halt-on-first-failure"));
    }

    // ----------------------------------------------------------------------
    // Doc 134 test 9: property test over random DAGs and outcomes.
    // ----------------------------------------------------------------------

    #[derive(Debug, Clone, Copy)]
    enum Outcome {
        Ok,
        /// Applies after 1 to 3 virtual seconds. Far below the 30s abort
        /// bound the case runs with, so a Slow node never looks like a hang.
        Slow,
        Fail,
        Hang,
        /// Applies, then readiness fails.
        ReadyFail,
        /// Applies, then readiness never answers.
        ReadyHang,
    }

    #[derive(Debug, Clone)]
    struct Case {
        n: usize,
        /// `edges[j]` holds the predecessors of node `j` (all `< j`).
        preds: Vec<Vec<usize>>,
        outcomes: Vec<Outcome>,
        /// Whether the node has a readiness wait (Deployment) or not
        /// (ConfigMap).
        polled: Vec<bool>,
    }

    fn case_strategy() -> impl proptest::strategy::Strategy<Value = Case> {
        use proptest::prelude::*;
        (1usize..=24).prop_flat_map(|n| {
            let preds = (0..n)
                .map(|j| proptest::collection::vec(any::<bool>(), j))
                .collect::<Vec<_>>();
            let outcome = prop_oneof![
                6 => Just(Outcome::Ok),
                3 => Just(Outcome::Slow),
                2 => Just(Outcome::Fail),
                1 => Just(Outcome::Hang),
                1 => Just(Outcome::ReadyFail),
                1 => Just(Outcome::ReadyHang),
            ];
            (
                preds,
                proptest::collection::vec(outcome, n),
                proptest::collection::vec(any::<bool>(), n),
            )
                .prop_map(move |(mask, outcomes, polled)| Case {
                    n,
                    preds: mask
                        .into_iter()
                        .map(|row| {
                            row.into_iter()
                                .enumerate()
                                .filter(|(_, b)| *b)
                                .map(|(i, _)| i)
                                .collect()
                        })
                        .collect(),
                    outcomes,
                    polled,
                })
        })
    }

    /// Readiness outcomes need a polled kind; a ConfigMap is immediate.
    fn polled(case: &Case, j: usize) -> bool {
        case.polled[j] || matches!(case.outcomes[j], Outcome::ReadyFail | Outcome::ReadyHang)
    }

    fn case_manifests(case: &Case) -> Vec<Value> {
        (0..case.n)
            .map(|j| {
                let kind = if polled(case, j) {
                    "Deployment"
                } else {
                    "ConfigMap"
                };
                let deps: Vec<String> = case.preds[j].iter().map(|i| format!("n{i}")).collect();
                let deps: Vec<&str> = deps.iter().map(String::as_str).collect();
                m(kind, &format!("n{j}"), &deps)
            })
            .collect()
    }

    fn node_rid(case: &Case, j: usize) -> ResourceId {
        let kind = if polled(case, j) {
            "Deployment"
        } else {
            "ConfigMap"
        };
        rid(kind, &format!("n{j}"))
    }

    /// What the engine must do with each node, derived from the case alone.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Fate {
        Ready,
        Failed,
        /// A predecessor failed or was cancelled: cascade-cancelled, terminal.
        Cancelled,
        /// Ran and never finished. Cancelled by the watchdog's abort.
        Hung,
        /// Waits on a hung ancestor with no failed one: never admitted.
        /// Cancelled when the run stops.
        Pending,
    }

    fn fates(case: &Case) -> Vec<Fate> {
        let mut out = Vec::with_capacity(case.n);
        for j in 0..case.n {
            let preds: Vec<Fate> = case.preds[j].iter().map(|&i| out[i]).collect();
            let fate = if preds
                .iter()
                .any(|f| matches!(f, Fate::Failed | Fate::Cancelled))
            {
                Fate::Cancelled
            } else if preds
                .iter()
                .any(|f| matches!(f, Fate::Hung | Fate::Pending))
            {
                Fate::Pending
            } else {
                match case.outcomes[j] {
                    Outcome::Ok | Outcome::Slow => Fate::Ready,
                    Outcome::Fail | Outcome::ReadyFail => Fate::Failed,
                    Outcome::Hang | Outcome::ReadyHang => Fate::Hung,
                }
            };
            out.push(fate);
        }
        out
    }

    fn check_case(case: Case) -> Result<(), proptest::test_runner::TestCaseError> {
        use proptest::prop_assert;
        use proptest::prop_assert_eq;

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .start_paused(true)
            .build()
            .unwrap();
        // The fake stamps its log with tokio's (paused) clock.
        let _enter = rt.enter();
        let ops = Arc::new(ScriptedOps::new());
        for j in 0..case.n {
            let apply = match case.outcomes[j] {
                Outcome::Ok | Outcome::ReadyFail | Outcome::ReadyHang => {
                    Behaviour::Now(Ok(ApplyAction::Created))
                }
                Outcome::Slow => {
                    Behaviour::After(secs(1 + (j as u64 % 3)), Ok(ApplyAction::Created))
                }
                Outcome::Fail => Behaviour::Now(Err(ApplyFailure::Other(format!("n{j} failed")))),
                Outcome::Hang => Behaviour::Hang,
            };
            let ready = match case.outcomes[j] {
                Outcome::ReadyFail => Behaviour::Now(Ready::Failed(format!("n{j} not ready"))),
                Outcome::ReadyHang => Behaviour::Hang,
                _ => Behaviour::Now(Ready::Ready),
            };
            ops.script(
                node_rid(&case, j),
                NodeScript::default().apply(apply).ready(ready),
            );
        }
        let cfg = config(StallPolicy {
            warn_after: secs(10),
            abort_after: Some(secs(30)),
        });
        let manifests = case_manifests(&case);
        let plan = plan_of(&manifests);
        let ops_dyn: Arc<dyn ClusterOps> = ops.clone();
        let rec = Arc::new(Recorder::default());
        let outcome = rt.block_on(tokio::time::timeout(
            secs(3600),
            run_deploy(ops_dyn, plan, &[], &[], &cfg, rec.clone()),
        ));
        let outcome = match outcome {
            Ok(o) => o,
            Err(_) => return Err(proptest::test_runner::TestCaseError::fail("engine parked")),
        };

        // A node scripted to hang only hangs if it runs; one behind a failed
        // predecessor is cancelled instead.
        let fates = fates(&case);
        let any_hang = fates.iter().any(|f| matches!(f, Fate::Hung));
        let result = match (&outcome, any_hang) {
            (Ok(r), false) => r.clone(),
            (Err(DeployError::Cancelled { partial, reason }), true) => {
                prop_assert!(reason.starts_with("no progress"), "{reason}");
                partial.clone()
            }
            (other, _) => {
                return Err(proptest::test_runner::TestCaseError::fail(format!(
                    "unexpected outcome {other:?} (any_hang={any_hang})"
                )));
            }
        };

        let calls = ops.log();
        let started: HashSet<ResourceId> = calls
            .iter()
            .filter_map(|l| match &l.call {
                Call::ApplyStart(r) => Some(r.clone()),
                _ => None,
            })
            .collect();
        let mut expected = DeployResult::default();
        for (j, fate) in fates.iter().enumerate() {
            let r = node_rid(&case, j);
            match fate {
                Fate::Ready => {
                    expected.created += 1;
                    prop_assert!(started.contains(&r), "n{j} never ran");
                }
                Fate::Failed => {
                    expected.failed += 1;
                    prop_assert!(started.contains(&r), "n{j} never ran");
                }
                Fate::Hung => {
                    expected.cancelled += 1;
                    prop_assert!(started.contains(&r), "n{j} never ran");
                }
                Fate::Cancelled => {
                    expected.cancelled += 1;
                    prop_assert!(
                        !started.contains(&r),
                        "n{j} ran despite a failed predecessor"
                    );
                }
                Fate::Pending => {
                    expected.cancelled += 1;
                    prop_assert!(!started.contains(&r), "n{j} ran despite a hung predecessor");
                }
            }
            // Exactly one terminal verdict per node, whatever stopped the run.
            let node = NodeId::Resource(r);
            prop_assert_eq!(
                rec.terminal_count(&node),
                1,
                "n{} ({:?}) terminal verdicts: {:?}",
                j,
                fates[j],
                rec.terminals()
                    .into_iter()
                    .filter(|(n, _)| *n == node)
                    .collect::<Vec<_>>()
            );
        }
        // The counts are a pure function of the case and add up to the plan.
        prop_assert_eq!(
            result.created,
            expected.created,
            "created: {:?} vs fates {:?}",
            result,
            fates
        );
        prop_assert_eq!(
            result.failed,
            expected.failed,
            "failed: {:?} vs fates {:?}",
            result,
            fates
        );
        prop_assert_eq!(
            result.cancelled,
            expected.cancelled,
            "cancelled: {:?} vs fates {:?}",
            result,
            fates
        );
        prop_assert_eq!(result.configured + result.unchanged + result.pruned, 0);
        prop_assert_eq!(total(&result), case.n);

        // Ordering: a node starts only after every predecessor is done. Log
        // position, not virtual time: most nodes finish at t=0, where a time
        // comparison proves nothing.
        let index_of = |call: &Call| calls.iter().position(|l| l.call == *call);
        for j in 0..case.n {
            let r = node_rid(&case, j);
            let Some(start) = index_of(&Call::ApplyStart(r)) else {
                continue;
            };
            for &i in &case.preds[j] {
                let p = node_rid(&case, i);
                let done = index_of(&Call::ReadyEnd(p.clone()))
                    .or_else(|| index_of(&Call::ApplyEnd(p.clone())))
                    .expect("predecessor of a started node finished");
                prop_assert!(
                    start > done,
                    "n{j} started (log #{start}) before n{i} finished (log #{done})"
                );
            }
        }
        Ok(())
    }

    proptest::proptest! {
        #![proptest_config(proptest::test_runner::Config { cases: 96, .. Default::default() })]
        #[test]
        fn random_dags_reach_terminal_verdicts_in_order(case in case_strategy()) {
            check_case(case)?;
        }
    }
}
