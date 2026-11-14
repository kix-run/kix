//! DAG-streaming deploy scheduler.
//!
//! Every node in the [`DeployPlan`] becomes ready to execute when its direct predecessors
//! have emitted [`Verdict::Ready`]. Independent subtrees stream through in
//! parallel, bounded by [`SchedulerConfig::concurrency`].
//!
//! # The engine task never awaits external I/O while nodes are in flight
//!
//! Every unit of work (a node, a discovery refresh, or a checkpoint) runs as a task
//! spawned into one `JoinSet`, so the runtime continues polling it while the
//! supervisor runs. The supervisor awaits only its `JoinSet`,
//! the cancel token, and the watchdog. Work that may block another task must
//! remain spawned because an unpolled future makes no progress and fires no
//! deadline.
//!
//! All cluster interactions go through [`Cluster`], which provides resource I/O,
//! deployment record persistence, and secret hydration. Tests supply
//! `ops::scripted::ScriptedOps` to run the scheduler without a live cluster.
//! [`Cluster`] also determines whether a run is a dry run.
//!
//! `run_deploy` is private to the library and accepts only plans constructed
//! by library entry points.
//!
//! The planner produces `Apply`, `Skip`, `Recreate`, and `Wait` transitions.

#[cfg(test)]
mod engine_tests;
mod node;
mod plan;
#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use thiserror::Error;
use tokio::task::JoinSet;

use crate::manifest::lifecycle::never_pruned;
use crate::manifest::types::ResourceId;
#[cfg(test)]
use crate::manifest::{keys, lifecycle, types::CLUSTER_SCOPED};

use super::apply::ApplyAction;
use super::cancel::CancelToken;
use super::ops::{Cluster, DeployRecord, RecordWriteError, ResourceIo};
use super::prune_guard::Pruned;
use super::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeFailure, NodeId,
    Phase, TransitionKind, Verdict,
};
use super::watchdog::{self, Progress, StallPolicy};
#[cfg(test)]
use super::{apply::ChangeAction, graph::ResourceGraph};

#[cfg(test)]
use node::recreate_refusal;
use node::{NodeCtx, NodeOutcome, execute_node, prune_order, with_sentence};
use plan::{SchedulerState, is_crd_like, runs_task};

pub use plan::{DeployPlan, LastRuns, PlanNodeEntry};

/// Policy for handling a node that reaches `Verdict::Failed`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnErrorPolicy {
    /// Halt the deploy immediately.
    Stop,
    /// Continue sibling subtrees and cancel transitive dependents of the failed
    /// node.
    Continue,
}

/// Policy for handling orphaned resources after all plan nodes terminate.
///
/// The plan document maps it to its own type for `flags.prune`, so this
/// type does not set the JSON of a plan or a saved plan file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrunePolicy {
    /// Do not look for orphans at all (`--skip-orphan-check`).
    Skip,
    /// Report orphans and keep them, recorded on the new Activation for a
    /// later `--prune` or `kix gc` (the default).
    WarnOnly,
    /// Delete orphans in reverse-topological order (`--prune`).
    Delete,
}

/// Default for [`SchedulerConfig::concurrency`]: maximum nodes in flight.
/// Bounds concurrent requests to keep the HTTP connection pool and the API
/// server's rate limiter within safe limits on wide clusters.
pub const CONCURRENCY: usize = 64;

/// Checkpoint every N terminal verdicts to the Activation CR. Keeps write
/// pressure modest on the API server while recording crash-recovery progress
/// every few seconds.
const CHECKPOINT_BATCH: usize = 16;

/// Timeout for best-effort writes awaited inline after the node phase (final
/// checkpoint and finalization).
const INLINE_BEST_EFFORT_TIMEOUT: Duration = Duration::from_secs(60);

pub struct SchedulerConfig {
    pub timeout: Duration,
    pub on_error: OnErrorPolicy,
    pub cancel: CancelToken,
    /// Maximum nodes in flight. See [`CONCURRENCY`].
    pub concurrency: usize,
    /// Thresholds for progress watchdog warnings and aborts.
    pub stall: StallPolicy,
    /// Read the live object of every unchanged node that a node with work
    /// depends on before its dependents run, and fail the deploy on it when
    /// it is not ready. `kix deploy` and the operator's deploy of a new build
    /// enable this. The operator disables it while it repairs drift on a
    /// running build, because that runs every requeue and an unchanged object
    /// that never reports ready would fail the record every cycle.
    pub check_unchanged: bool,
    /// Whether failure messages may name `kix deploy` flags as the next step.
    /// The CLI sets it; the operator has no flags to pass.
    pub names_flags: bool,
}

#[derive(Error, Debug)]
pub enum DeployError {
    /// The Activation record could not be started, so nothing was applied.
    #[error(
        "could not read or start deployment records before applying\n  \
         Nothing was applied to the cluster.\n\n  \
         Cause:\n    {message}\n\n  \
         Next:\n    Resolve the problem above and run the deploy again."
    )]
    BeginFailed {
        message: String,
        partial: DeployResult,
    },

    #[error("deployment stopped: {count} resource operations failed")]
    NodesFailed { count: usize, partial: DeployResult },

    /// API discovery could not be refreshed after a CRD was applied. The run
    /// stopped rather than continuing with a stale view of available resource kinds.
    #[error("could not discover the resource types supported by the Kubernetes API: {message}")]
    DiscoveryFailed {
        message: String,
        partial: DeployResult,
    },

    #[error("deploy cancelled: {reason}")]
    Cancelled {
        reason: String,
        partial: DeployResult,
    },

    /// A spawned task panicked or was aborted unexpectedly.
    #[error("deployment could not continue: {message}")]
    Internal {
        message: String,
        partial: DeployResult,
    },

    /// Every node reached a verdict, but the Activation record could not be
    /// finalized. The record remains in `Deploying` and the previous
    /// activation stays current.
    #[error(
        "every object reached a result, but Kix could not mark this run's deployment record finished\n  \
         Cause:\n    {message}\n\n  \
         Cluster state:\n    \
         - This run's deployment record may still be in phase Deploying, and the previous deployment record remains Active.\n    \
         - The next `kix plan`, `kix deploy`, or `kix rollback` will warn about the Deploying record and show the `kubectl patch` command to clear it."
    )]
    FinalizeFailed {
        message: String,
        partial: DeployResult,
    },
}

impl DeployError {
    /// Return the counts accumulated before the run stopped.
    pub fn partial(&self) -> &DeployResult {
        match self {
            DeployError::BeginFailed { partial, .. }
            | DeployError::NodesFailed { partial, .. }
            | DeployError::DiscoveryFailed { partial, .. }
            | DeployError::Cancelled { partial, .. }
            | DeployError::Internal { partial, .. }
            | DeployError::FinalizeFailed { partial, .. } => partial,
        }
    }
}

/// Identifies a `JoinSet` task so aborted or panicked tasks can be accounted
/// for by kind.
enum TaskKind {
    Node(NodeId),
    Rediscovery,
    Checkpoint,
}

/// Synthetic node identifier used by the watchdog while waiting for an API
/// discovery refresh after a CRD barrier.
static DISCOVERY_NODE: std::sync::LazyLock<NodeId> =
    std::sync::LazyLock::new(|| NodeId::Synthetic("api-discovery".into()));

/// Result reported back to the supervisor by a spawned task.
enum Done {
    Node(NodeId, NodeOutcome),
    Rediscovery(Result<(), String>),
    Checkpoint(Result<(), RecordWriteError>),
}

/// Execute a DAG-streaming deploy.
///
/// The scheduler maintains a ready queue. A node becomes ready as soon as all
/// of its predecessors emit `Verdict::Ready`. Concurrency is bounded by
/// [`SchedulerConfig::concurrency`]. On a node failure, the error policy
/// either halts the entire deploy ([`OnErrorPolicy::Stop`]) or cancels only
/// transitive dependents while sibling subtrees continue
/// ([`OnErrorPolicy::Continue`]).
///
/// Dependents of a CRD wait at a barrier until one API discovery refresh
/// completes after the CRD becomes ready. Multiple CRDs finishing concurrently
/// share a single refresh. A failed refresh stops the deploy.
///
/// After every plan node reaches a terminal verdict, orphans are pruned in
/// reverse-topological order of the old graph and the Activation CR is
/// finalized.
///
/// A dry run ([`Cluster::dry_run`]) sends every write with `dryRun=All`,
/// writes no deployment record, and emits the same event stream for rendering.
/// Because dry runs persist nothing, readiness checks short-circuit to
/// `Ready` and dependents of failed nodes are still tried so all validation
/// errors surface in a single preview.
pub(crate) async fn run_deploy(
    cluster: Cluster,
    plan: DeployPlan,
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    prune: PrunePolicy,
    config: &SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
) -> Result<DeployResult, DeployError> {
    let mut run = Run::new(
        &cluster,
        &plan,
        orphan_rids,
        old_manifests,
        prune,
        config,
        observer,
    );

    // Run the watchdog on its own task and timer so it fires even if the
    // scheduler loop stalls. It reports through the observer and cancels the
    // run via the cancel token without touching the cluster.
    let _watchdog = AbortOnDrop(tokio::spawn(watchdog::run(
        config.stall,
        run.progress.clone(),
        config.cancel.clone(),
        run.observer.clone(),
    )));

    // Publish the plan skeleton so renderers can draw the tree before any
    // node executes.
    run.emit(DeployEvent::PlanComputed {
        nodes: plan.to_plan_nodes(),
        edges: plan.edges.clone(),
    });

    run.begin().await?;
    run.run_nodes().await?;
    run.close_out().await?;
    if run.stop_partial_closure().await {
        return Ok(run.result);
    }
    run.stamp_unchanged().await;
    let orphans_left = run.prune().await;
    run.finalize(orphans_left).await
}

/// State for a single execution of [`run_deploy`].
struct Run<'a> {
    config: &'a SchedulerConfig,
    /// Orphaned resource IDs and the previous build's manifests used to order
    /// pruning.
    orphan_rids: &'a [ResourceId],
    old_manifests: &'a [Value],
    prune: PrunePolicy,
    progress: Arc<Progress>,
    observer: Arc<dyn DeployObserver>,
    dry_run: bool,
    resources: Arc<dyn ResourceIo>,
    record: Option<Arc<dyn DeployRecord>>,
    ctx: Arc<NodeCtx>,
    result: DeployResult,

    state: SchedulerState,
    tasks: JoinSet<Done>,
    // Maps Tokio task IDs to their role so aborted or panicked tasks can be
    // handled appropriately.
    kinds: HashMap<tokio::task::Id, TaskKind>,
    nodes_in_flight: usize,
    barrier: CrdBarrier,
    checkpoints: Checkpoints,
    // Set when the cancel token fires. All tasks are aborted and drained before
    // returning `DeployError::Cancelled`.
    cancelling: bool,
    /// Set when the deploy is stopping due to `OnErrorPolicy::Stop`, a failed
    /// discovery refresh, or cancellation.
    halting: bool,
    halting_reason: Option<String>,
    discovery_failed: Option<String>,
    // Unchanged resources still belong to this activation and are stamped in a
    // batch after all nodes terminate (see `DeployRecord::stamp_unchanged`).
    skipped: Vec<ResourceId>,
    /// Orphans that were deleted and recreated during immutable-conflict
    /// recovery. Excluded from post-deploy pruning because they now belong to
    /// the new build.
    consumed_orphans: HashSet<ResourceId>,
}

impl<'a> Run<'a> {
    fn new(
        cluster: &Cluster,
        plan: &DeployPlan,
        orphan_rids: &'a [ResourceId],
        old_manifests: &'a [Value],
        prune: PrunePolicy,
        config: &'a SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Self {
        let progress = Arc::new(Progress::new());
        progress.set_readiness_budget(config.timeout);
        progress.set_plan(
            &plan.edges,
            plan.nodes
                .iter()
                .filter(|e| e.kind != TransitionKind::Skip || e.rerun.is_some())
                .map(|e| e.id.clone()),
        );
        let dry_run = cluster.is_dry_run();
        let resources = cluster.resources().clone();
        let ctx = Arc::new(NodeCtx {
            resources: resources.clone(),
            secrets: cluster.secrets().clone(),
            cancel: config.cancel.clone(),
            timeout: config.timeout,
            // Preauthorized delete set for immutable-conflict recovery.
            orphan_set: orphan_rids.iter().cloned().collect(),
            dry_run,
            progress: progress.clone(),
            observer: observer.clone(),
        });
        Self {
            config,
            orphan_rids,
            old_manifests,
            prune,
            progress,
            observer,
            dry_run,
            resources,
            record: cluster.record().cloned(),
            ctx,
            result: DeployResult::default(),
            state: SchedulerState::new(plan, config.check_unchanged),
            tasks: JoinSet::new(),
            kinds: HashMap::new(),
            nodes_in_flight: 0,
            barrier: CrdBarrier::default(),
            checkpoints: Checkpoints::default(),
            cancelling: false,
            halting: false,
            halting_reason: None,
            discovery_failed: None,
            skipped: Vec::new(),
            consumed_orphans: HashSet::new(),
        }
    }

    fn emit(&self, event: DeployEvent) {
        self.progress.touch();
        if let DeployEvent::NodeStateChanged { node, verdict, .. } = &event
            && verdict.is_terminal()
        {
            self.progress.finished(node);
        }
        self.observer.on_event(&event);
    }

    /// Take the accumulated counts for an error return.
    fn partial(&mut self) -> DeployResult {
        std::mem::take(&mut self.result)
    }

    /// Begin the Activation record, stopping the run before any resource is
    /// applied if the record cannot be written.
    async fn begin(&mut self) -> Result<(), DeployError> {
        // No nodes are in flight yet, so awaiting inline cannot block node tasks.
        let Some(record) = &self.record else {
            return Ok(());
        };
        match tokio::time::timeout(INLINE_BEST_EFFORT_TIMEOUT, record.begin()).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                let message = e.to_string();
                self.emit(DeployEvent::Stopped {
                    reason: message.clone(),
                });
                return Err(DeployError::BeginFailed {
                    message,
                    partial: self.partial(),
                });
            }
            Err(_) => self.emit(DeployEvent::BestEffortFailed {
                what: "activation begin".into(),
                message: format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
            }),
        }
        Ok(())
    }

    /// Execute plan nodes up to `concurrency` at a time until no nodes are
    /// running or ready.
    async fn run_nodes(&mut self) -> Result<(), DeployError> {
        self.state.seed_ready();
        let config = self.config;
        loop {
            self.admit_ready();

            // Exit when no nodes or discovery refreshes are running and no
            // further nodes can be admitted. Any in-flight checkpoint is
            // best-effort and will be aborted by `shutdown` below before
            // `close_out` writes the final totals.
            if self.nodes_in_flight == 0
                && !self.barrier.in_flight
                && (self.halting || self.state.ready_is_empty())
            {
                break;
            }

            let joined = if self.cancelling {
                self.tasks.join_next_with_id().await
            } else {
                tokio::select! {
                    biased;
                    _ = config.cancel.cancelled() => {
                        // Stop admitting new nodes, abort running tasks, and
                        // drain the JoinSet so completed and aborted tasks are
                        // both accounted for.
                        self.cancelling = true;
                        self.halting = true;
                        self.halting_reason = Some(cancel_reason(config));
                        self.tasks.abort_all();
                        continue;
                    }
                    joined = self.tasks.join_next_with_id() => joined,
                }
            };

            match joined {
                None => break,
                Some(Ok((task_id, done))) => {
                    self.kinds.remove(&task_id);
                    self.on_done(done);
                }
                Some(Err(join_err)) => self.on_join_error(join_err).await?,
            }
        }

        self.tasks.shutdown().await;
        Ok(())
    }

    /// Admit ready nodes up to the concurrency limit.
    fn admit_ready(&mut self) {
        let concurrency = self.config.concurrency.max(1);
        while !self.halting && self.nodes_in_flight < concurrency {
            let Some(node_id) = self.state.pop_ready() else {
                break;
            };
            let entry = self.state.node_entry(&node_id).clone();

            // Complete a Skip node without a task unless its task reads the
            // live object. A skipped Job always does, to report a failed run
            // or recreate it under `kix.run/rerun`, and it also waits for a
            // run still in progress when something depends on it. Any other
            // Skip node reads it only when something in this deploy depends
            // on it (`SchedulerState::is_checked`), so the dependents run
            // only after the live object is checked.
            if matches!(entry.kind, TransitionKind::Skip)
                && !plan::skip_reads_live(&entry)
                && !self.state.is_checked(&node_id)
            {
                self.emit(DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Running,
                    detail: None,
                });
                self.emit(DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Ready,
                    detail: Some(NodeDetail::Applied(ApplyAction::Unchanged)),
                });
                self.result.unchanged += 1;
                if let NodeId::Resource(rid) = &node_id {
                    self.skipped.push(rid.clone());
                }
                self.state.mark_terminal(&node_id, true);
                self.checkpoints.terminal();
                continue;
            }

            self.emit(DeployEvent::NodeStateChanged {
                node: node_id.clone(),
                kind: entry.kind,
                verdict: Verdict::Running,
                detail: None,
            });
            let ctx = self.ctx.clone();
            let id = node_id.clone();
            let checked = self.state.is_checked(&node_id);
            self.nodes_in_flight += 1;
            let handle = self.tasks.spawn(async move {
                let out = execute_node(&ctx, &entry, checked).await;
                Done::Node(id, out)
            });
            self.kinds.insert(handle.id(), TaskKind::Node(node_id));
        }
    }

    /// Handle a task that was aborted or panicked. Only a panicked node task is
    /// immediately fatal here.
    async fn on_join_error(&mut self, join_err: tokio::task::JoinError) -> Result<(), DeployError> {
        let aborted = join_err.is_cancelled();
        match self.kinds.remove(&join_err.id()) {
            Some(TaskKind::Node(node_id)) => {
                self.nodes_in_flight -= 1;
                self.progress.clear(&node_id);
                if aborted {
                    let entry = self.state.node_entry(&node_id).clone();
                    self.result.cancelled += 1;
                    self.emit(DeployEvent::NodeStateChanged {
                        node: node_id.clone(),
                        kind: entry.kind,
                        verdict: Verdict::Cancelled {
                            because: CancelReason::External,
                        },
                        detail: None,
                    });
                    self.state.mark_terminal(&node_id, false);
                    return Ok(());
                }
                // A panic in a node task is an internal bug rather than a
                // cluster condition.
                let message = format!("a deploy task panicked: {join_err}");
                self.emit(DeployEvent::Stopped {
                    reason: message.clone(),
                });
                self.tasks.shutdown().await;
                self.abort_record(&message).await;
                Err(DeployError::Internal {
                    message,
                    partial: self.partial(),
                })
            }
            Some(TaskKind::Rediscovery) => {
                self.barrier.in_flight = false;
                self.progress.clear(&DISCOVERY_NODE);
                if !aborted {
                    let message = format!("discovery refresh task panicked: {join_err}");
                    self.discovery_failed = Some(message.clone());
                    self.halting = true;
                    self.halting_reason = Some(message);
                }
                Ok(())
            }
            Some(TaskKind::Checkpoint) | None => {
                self.checkpoints.in_flight = false;
                if !aborted {
                    self.emit(DeployEvent::BestEffortFailed {
                        what: "activation checkpoint".into(),
                        message: format!("task panicked: {join_err}"),
                    });
                }
                Ok(())
            }
        }
    }

    fn on_done(&mut self, done: Done) {
        match done {
            Done::Rediscovery(outcome) => {
                self.barrier.in_flight = false;
                self.progress.clear(&DISCOVERY_NODE);
                match outcome {
                    Ok(()) => {
                        for id in std::mem::take(&mut self.barrier.covered) {
                            self.state.promote_dependents(&id);
                        }
                        if !self.halting {
                            self.start_rediscovery_if_needed();
                        }
                    }
                    Err(message) => {
                        // Do not continue with a stale discovery view. Let
                        // in-flight nodes finish before halting.
                        self.discovery_failed = Some(message.clone());
                        self.halting = true;
                        self.halting_reason =
                            Some(format!("API rediscovery failed after CRD apply: {message}"));
                    }
                }
            }
            Done::Checkpoint(outcome) => {
                self.checkpoints.in_flight = false;
                if let Err(e) = outcome {
                    self.emit(DeployEvent::BestEffortFailed {
                        what: "activation checkpoint".into(),
                        message: e.to_string(),
                    });
                }
                self.start_checkpoint_if_due();
            }
            Done::Node(node_id, outcome) => {
                self.nodes_in_flight -= 1;
                self.progress.clear(&node_id);
                self.on_node(node_id, outcome);
                if !self.halting {
                    self.start_rediscovery_if_needed();
                }
                self.checkpoints.terminal();
                self.start_checkpoint_if_due();
            }
        }
    }

    /// Record a node's verdict and promote or cancel its dependents.
    fn on_node(&mut self, node_id: NodeId, outcome: NodeOutcome) {
        let entry = self.state.node_entry(&node_id).clone();
        match outcome {
            NodeOutcome::Ready { apply_action } => {
                // A skipped Job whose live object succeeded is unchanged and
                // still belongs to this activation.
                self.push_skipped(&node_id, &entry);
                let detail = NodeDetail::Applied(apply_action.clone());
                self.node_ready(&node_id, &entry, &apply_action, detail);
            }
            NodeOutcome::PendingRestart {
                apply_action,
                stale,
                message,
            } => {
                self.push_skipped(&node_id, &entry);
                let detail = NodeDetail::PendingRestart { stale, message };
                self.node_ready(&node_id, &entry, &apply_action, detail);
            }
            NodeOutcome::Rerun {
                apply_action,
                reason,
            } => {
                let detail = NodeDetail::Rerun { reason };
                self.node_ready(&node_id, &entry, &apply_action, detail);
            }
            NodeOutcome::Recreated {
                apply_action,
                reason,
            } => {
                if let NodeId::Resource(rid) = &node_id {
                    self.consumed_orphans.insert(rid.clone());
                }
                let detail = NodeDetail::RecreatedInPlace { reason };
                self.node_ready(&node_id, &entry, &apply_action, detail);
            }
            NodeOutcome::Failed { detail, message } => {
                self.node_failed(&node_id, &entry, detail, message);
            }
            NodeOutcome::Cancelled => {
                self.result.cancelled += 1;
                self.emit(DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Cancelled {
                        because: CancelReason::External,
                    },
                    detail: None,
                });
                self.state.mark_terminal(&node_id, false);
            }
        }
    }

    /// Record a `Skip` node that executed a task so it is stamped as unchanged.
    fn push_skipped(&mut self, node_id: &NodeId, entry: &PlanNodeEntry) {
        if matches!(entry.kind, TransitionKind::Skip)
            && let NodeId::Resource(rid) = node_id
        {
            self.skipped.push(rid.clone());
        }
    }

    /// Record a ready node. CRD-like nodes hold their dependents until the next
    /// discovery refresh completes; all other nodes promote their dependents
    /// immediately. An unchanged CRD was served before the run began, so its
    /// kinds are already in the discovery view and it needs no refresh.
    fn node_ready(
        &mut self,
        node_id: &NodeId,
        entry: &PlanNodeEntry,
        apply_action: &ApplyAction,
        detail: NodeDetail,
    ) {
        self.checkpoints.count(apply_action, &mut self.result);
        self.emit(DeployEvent::NodeStateChanged {
            node: node_id.clone(),
            kind: entry.kind,
            verdict: Verdict::Ready,
            detail: Some(detail),
        });
        if is_crd_like(entry) && entry.kind != TransitionKind::Skip {
            self.state.mark_terminal_deferred(node_id);
            self.barrier.awaiting.push(node_id.clone());
        } else {
            self.state.mark_terminal(node_id, true);
        }
    }

    fn node_failed(
        &mut self,
        node_id: &NodeId,
        entry: &PlanNodeEntry,
        detail: NodeDetail,
        message: String,
    ) {
        self.result.failed += 1;
        self.result.failures.push(NodeFailure {
            node: node_id.clone(),
            message: message.clone(),
        });
        self.checkpoints.failed += 1;
        self.state.mark_terminal(node_id, false);

        // Dry runs persist nothing, so promote dependents even when a
        // predecessor fails so all validation errors surface in a single preview.
        let cancelled = if self.dry_run {
            self.state.promote_dependents(node_id);
            Vec::new()
        } else {
            self.state.cascade_cancel(node_id)
        };
        // The failure line says what the failure cost before the cancelled
        // dependents are listed one by one. Only dependents that had work to
        // do count: an unchanged dependent was never going to be deployed.
        let undone = cancelled
            .iter()
            .filter(|id| runs_task(self.state.node_entry(id)))
            .count();
        let mut full = message.clone();
        match undone {
            0 => {}
            1 => full = with_sentence(&full, "Kix did not deploy the object that depends on it."),
            n => {
                full = with_sentence(
                    &full,
                    &format!("Kix did not deploy the {n} objects that depend on it."),
                )
            }
        }
        if is_checked_unchanged(entry) {
            full = with_sentence(
                &full,
                &next_step_for_unchanged(entry, self.config.names_flags),
            );
        }
        self.emit(DeployEvent::NodeStateChanged {
            node: node_id.clone(),
            kind: entry.kind,
            verdict: Verdict::Failed { message: full },
            detail: Some(detail),
        });
        let because = match node_id {
            NodeId::Resource(rid) => CancelReason::PredecessorFailed(rid.clone()),
            NodeId::Synthetic(_) => CancelReason::External,
        };
        for dep_id in cancelled {
            let dep_entry = self.state.node_entry(&dep_id).clone();
            self.result.cancelled += 1;
            self.emit(DeployEvent::NodeStateChanged {
                node: dep_id,
                kind: dep_entry.kind,
                verdict: Verdict::Cancelled {
                    because: because.clone(),
                },
                detail: None,
            });
        }

        if self.config.on_error == OnErrorPolicy::Stop && !self.halting {
            self.halting = true;
            self.halting_reason = Some(format!("{}{message}", super::stream::HALTED_ON_FAILURE));
        }
    }

    /// Spawn a discovery refresh if any CRDs have become ready since the last
    /// refresh and no refresh is already running.
    fn start_rediscovery_if_needed(&mut self) {
        if self.barrier.in_flight || self.barrier.awaiting.is_empty() {
            return;
        }
        self.barrier.covered = std::mem::take(&mut self.barrier.awaiting);
        self.barrier.in_flight = true;
        self.emit(DeployEvent::CrdRediscovery);
        self.progress
            .set_stands_for(&DISCOVERY_NODE, &self.barrier.covered);
        self.progress.set_phase(&DISCOVERY_NODE, Phase::Discovery);
        let resources = self.resources.clone();
        let record = self.record.clone();
        let handle = self.tasks.spawn(async move {
            let refreshed = resources.rediscover().await;
            if refreshed.is_ok()
                && let Some(record) = record
            {
                record.discovery_refreshed().await;
            }
            Done::Rediscovery(refreshed.map_err(|e| e.to_string()))
        });
        self.kinds.insert(handle.id(), TaskKind::Rediscovery);
    }

    /// Spawn a checkpoint write once [`CHECKPOINT_BATCH`] terminal verdicts
    /// have accumulated since the last checkpoint and none is in flight.
    fn start_checkpoint_if_due(&mut self) {
        let Some(record) = &self.record else {
            return;
        };
        let checkpoints = &mut self.checkpoints;
        if checkpoints.in_flight || checkpoints.since_last < CHECKPOINT_BATCH {
            return;
        }
        checkpoints.since_last = 0;
        checkpoints.in_flight = true;
        let record = record.clone();
        let (applied, failed) = (checkpoints.applied, checkpoints.failed);
        let handle = self.tasks.spawn(async move {
            Done::Checkpoint(record.checkpoint(applied, failed, false).await)
        });
        self.kinds.insert(handle.id(), TaskKind::Checkpoint);
    }

    /// Mark the Activation record as `Failed` when the deploy stops without
    /// finalizing, and emit an event if the status write fails.
    ///
    /// Every early return after `begin` calls this because an interrupted run
    /// may have already applied part of its closure, and the `Failed` record
    /// tells the next deploy to fold those changes into its plan.
    async fn abort_record(&self, reason: &str) {
        let Some(record) = &self.record else {
            return;
        };
        let failed =
            match tokio::time::timeout(INLINE_BEST_EFFORT_TIMEOUT, record.abort(reason)).await {
                Ok(Ok(())) => return,
                Ok(Err(e)) => e.to_string(),
                Err(_) => format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
            };
        self.emit(DeployEvent::BestEffortFailed {
            what: "activation abort".into(),
            message: failed,
        });
    }

    /// Finish the node phase by assigning a terminal verdict to every remaining
    /// node, writing the final checkpoint, and returning an error if the run
    /// was cancelled, lost discovery, or halted on failure.
    async fn close_out(&mut self) -> Result<(), DeployError> {
        // Check the cancel token in case cancellation arrived just as the last
        // node completed.
        if self.config.cancel.is_cancelled() && !self.cancelling {
            self.cancelling = true;
            self.halting = true;
            self.halting_reason = Some(cancel_reason(self.config));
        }

        // Emit a `Cancelled` verdict for every remaining node so renderers do
        // not leave rows in `Pending` and summary counts match the plan size.
        if self.halting {
            for node_id in self.state.non_terminal() {
                let entry = self.state.node_entry(&node_id).clone();
                self.result.cancelled += 1;
                self.emit(DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Cancelled {
                        because: CancelReason::External,
                    },
                    detail: None,
                });
                self.state.mark_terminal(&node_id, false);
            }
        }

        if self.cancelling {
            let reason = self
                .halting_reason
                .take()
                .unwrap_or_else(|| "cancelled".to_string());
            self.emit(DeployEvent::Stopped {
                reason: reason.clone(),
            });
            self.abort_record(&reason).await;
            return Err(DeployError::Cancelled {
                reason,
                partial: self.partial(),
            });
        }

        self.final_checkpoint().await;

        if let Some(message) = self.discovery_failed.take() {
            let reason = self
                .halting_reason
                .take()
                .unwrap_or_else(|| message.clone());
            self.emit(DeployEvent::Stopped { reason });
            self.abort_record(&message).await;
            return Err(DeployError::DiscoveryFailed {
                message,
                partial: self.partial(),
            });
        }

        if self.halting {
            let reason = self
                .halting_reason
                .take()
                .unwrap_or_else(|| "halting".into());
            self.emit(DeployEvent::Stopped {
                reason: reason.clone(),
            });
            self.abort_record(&reason).await;
            let count = self.result.failed;
            return Err(DeployError::NodesFailed {
                count,
                partial: self.partial(),
            });
        }
        Ok(())
    }

    /// Write the final checkpoint if any verdicts accumulated since the last
    /// periodic checkpoint.
    async fn final_checkpoint(&self) {
        let Some(record) = &self.record else {
            return;
        };
        let checkpoints = &self.checkpoints;
        if checkpoints.since_last == 0 && checkpoints.applied + checkpoints.failed == 0 {
            return;
        }
        match tokio::time::timeout(
            INLINE_BEST_EFFORT_TIMEOUT,
            record.checkpoint(checkpoints.applied, checkpoints.failed, true),
        )
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(e)) => self.emit(DeployEvent::BestEffortFailed {
                what: "activation checkpoint".into(),
                message: e.to_string(),
            }),
            Err(_) => self.emit(DeployEvent::BestEffortFailed {
                what: "activation checkpoint".into(),
                message: format!("no answer within {}s", INLINE_BEST_EFFORT_TIMEOUT.as_secs()),
            }),
        }
    }

    /// Abort the deployment record and return `true` if any nodes were
    /// cancelled and left unapplied.
    ///
    /// Under `--on-error=continue`, a failed node cancels its transitive
    /// dependents without setting `halting`. Finalizing such a run would mark
    /// the record `Degraded`, which is treated as the cluster's current state
    /// and would cause the next deploy of the same closure to skip nodes that
    /// were never attempted.
    ///
    /// This check must run before stamping skipped resources or pruning
    /// orphans. Because the new record is marked `Failed` and the previous
    /// activation remains `Active`, pruning here would delete resources that
    /// the active closure still depends on.
    async fn stop_partial_closure(&self) -> bool {
        if self.dry_run || self.result.cancelled == 0 {
            return false;
        }
        let reason = format!(
            "{} failed, {} never attempted",
            self.result.failed, self.result.cancelled
        );
        self.emit(DeployEvent::Stopped {
            reason: reason.clone(),
        });
        self.abort_record(&reason).await;
        true
    }

    /// Stamp the current activation onto unchanged resources. Without this,
    /// `kix.run/activations` would only record deployments that modified a
    /// resource, leaving stable resources with stale activation references.
    ///
    /// Stamping is best-effort because nothing was written to these resources.
    /// Failures are counted and reported rather than failing a deploy that
    /// otherwise succeeded.
    async fn stamp_unchanged(&self) {
        let Some(record) = &self.record else {
            return;
        };
        if self.skipped.is_empty() {
            return;
        }
        let mut failures = 0usize;
        for chunk in self.skipped.chunks(self.config.concurrency.max(1)) {
            let mut set = JoinSet::new();
            for rid in chunk {
                let record = record.clone();
                let rid = rid.clone();
                set.spawn(async move {
                    match tokio::time::timeout(
                        INLINE_BEST_EFFORT_TIMEOUT,
                        record.stamp_unchanged(&rid),
                    )
                    .await
                    {
                        Ok(Ok(())) => Ok(()),
                        Ok(Err(e)) => Err((rid, e.to_string())),
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
            self.emit(DeployEvent::BestEffortFailed {
                what: "activation stamp on unchanged resources".into(),
                message: format!(
                    "{failures} of {} not stamped; the deploy itself is unaffected and the next deploy retries",
                    self.skipped.len()
                ),
            });
        }
    }

    /// Prune orphaned resources after all plan nodes reach a terminal verdict.
    /// Returns `true` if any prunable orphans remain on the cluster so
    /// finalization can record their source builds.
    async fn prune(&mut self) -> bool {
        let prune = self.prune;
        let effective_orphans: Vec<ResourceId> = self
            .orphan_rids
            .iter()
            .filter(|rid| !self.consumed_orphans.contains(rid))
            .cloned()
            .collect();
        let mut orphans_left = prune != PrunePolicy::Delete
            && effective_orphans
                .iter()
                .any(|rid| !never_pruned(rid.group_kind()));
        if effective_orphans.is_empty() || prune == PrunePolicy::Skip {
            return orphans_left;
        }
        let ordered = prune_order(&effective_orphans, self.old_manifests);
        let delete = prune == PrunePolicy::Delete;
        let (kept, prunable): (Vec<ResourceId>, Vec<ResourceId>) = ordered
            .iter()
            .cloned()
            .partition(|r| never_pruned(r.group_kind()));
        self.emit(DeployEvent::PruneStart {
            count: prunable.len(),
            resources: prunable,
            kept,
            delete,
        });

        for rid in &ordered {
            if prune == PrunePolicy::WarnOnly || never_pruned(rid.group_kind()) {
                continue;
            }
            let deleted =
                match tokio::time::timeout(INLINE_BEST_EFFORT_TIMEOUT, self.resources.prune(rid))
                    .await
                {
                    Ok(outcome) => outcome.map_err(|e| e.to_string()),
                    Err(_) => Err(format!(
                        "no answer within {}s",
                        INLINE_BEST_EFFORT_TIMEOUT.as_secs()
                    )),
                };
            match deleted {
                Ok(outcome @ (Pruned::Kept(_) | Pruned::Changed(_))) => {
                    // An object kept because its content drifted still belongs
                    // to this cluster, so preserve its source build for the
                    // next prune. An object shared with another Kix cluster is
                    // managed by that cluster.
                    if matches!(outcome, Pruned::Changed(_)) {
                        orphans_left = true;
                    }
                    self.emit(DeployEvent::PruneKept {
                        resource: rid.clone(),
                        reason: outcome.kept_reason().unwrap_or_default(),
                    });
                }
                Ok(Pruned::Deleted | Pruned::Gone) => {
                    self.result.pruned += 1;
                    self.emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(rid.clone()),
                        kind: TransitionKind::Delete,
                        verdict: Verdict::Ready,
                        detail: None,
                    });
                }
                Err(message) => {
                    self.result.failed += 1;
                    self.result.failures.push(NodeFailure {
                        node: NodeId::Resource(rid.clone()),
                        message: message.clone(),
                    });
                    orphans_left = true;
                    self.emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(rid.clone()),
                        kind: TransitionKind::Delete,
                        verdict: Verdict::Failed { message },
                        detail: None,
                    });
                }
            }
        }
        orphans_left
    }

    /// Finalize the Activation record unless the run was a no-op or a dry run.
    async fn finalize(self, orphans_left: bool) -> Result<DeployResult, DeployError> {
        let r = &self.result;
        let actually_changed = r.created > 0 || r.configured > 0 || r.pruned > 0 || r.failed > 0;
        if let Some(record) = &self.record
            && actually_changed
        {
            match tokio::time::timeout(
                INLINE_BEST_EFFORT_TIMEOUT,
                record.finalize(r.failed > 0, orphans_left),
            )
            .await
            {
                Ok(Ok(Some(f))) => self.emit(DeployEvent::Finalized {
                    activation: f.activation,
                    previous: f.previous,
                }),
                Ok(Ok(None)) => {}
                // Fail if the record could not be finalized so the caller does
                // not cache the build as the cluster's active state.
                Ok(Err(e)) => {
                    return Err(DeployError::FinalizeFailed {
                        message: e.to_string(),
                        partial: self.result,
                    });
                }
                Err(_) => {
                    return Err(DeployError::FinalizeFailed {
                        message: format!(
                            "no answer within {}s",
                            INLINE_BEST_EFFORT_TIMEOUT.as_secs()
                        ),
                        partial: self.result,
                    });
                }
            }
        }
        Ok(self.result)
    }
}

/// Return whether `entry` is an unchanged node the scheduler ran a task for
/// only to check its live object. Such a node fails only through that check.
/// A skipped Job is not one: its own failure message already gives the next
/// step.
fn is_checked_unchanged(entry: &PlanNodeEntry) -> bool {
    entry.kind == TransitionKind::Skip && !plan::skip_reads_live(entry)
}

/// Return the next step after an unchanged object failed its check. An
/// import marker names its target, since the marker itself is fine.
/// `names_flags` adds the `--on-error continue` alternative.
fn next_step_for_unchanged(entry: &PlanNodeEntry, names_flags: bool) -> String {
    let step = match (&entry.meta.import_target, &entry.id) {
        (Some(target), _) => {
            let ns = target
                .namespace
                .as_deref()
                .map(|ns| format!("@{ns}"))
                .unwrap_or_default();
            format!(
                "Fix {}/{}{ns}, or whatever creates it, and deploy again",
                target.kind, target.name
            )
        }
        (None, id) => format!("Fix {id} and deploy again"),
    };
    if names_flags {
        format!(
            "{step}, or pass --on-error continue to deploy the objects that do not depend on it."
        )
    } else {
        format!("{step}.")
    }
}

/// Return the cancellation reason from the cancel token, or `"cancelled"`.
fn cancel_reason(config: &SchedulerConfig) -> String {
    config
        .cancel
        .reason()
        .unwrap_or_else(|| "cancelled".to_string())
}

/// Run [`run_deploy`] against `ScriptedOps` for testing without a live cluster.
#[cfg(any(test, feature = "test-util"))]
pub async fn run_scripted(
    ops: Arc<super::ops::scripted::ScriptedOps>,
    plan: DeployPlan,
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    prune: PrunePolicy,
    config: &SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
) -> Result<DeployResult, DeployError> {
    run_deploy(
        Cluster::scripted(ops),
        plan,
        orphan_rids,
        old_manifests,
        prune,
        config,
        observer,
    )
    .await
}

/// Aborts the wrapped task when dropped.
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// CRD barrier state.
#[derive(Default)]
struct CrdBarrier {
    /// Ready CRD nodes waiting for a discovery refresh to start.
    awaiting: Vec<NodeId>,
    /// CRD nodes covered by the currently running discovery refresh.
    covered: Vec<NodeId>,
    in_flight: bool,
}

/// Checkpoint counters and in-flight state.
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
}
