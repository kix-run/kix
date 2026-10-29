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

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use thiserror::Error;
use tokio::task::JoinSet;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::apply::{ApplyAction, ApplyError, ApplyResult, ChangeAction, wants_rerun};
use super::cancel::CancelToken;
use super::graph::ResourceGraph;
use super::ops::{Cluster, DeployRecord, RecordWriteError, ResourceIo, SecretHydrator};
use super::prune_guard::Pruned;
use super::readiness::{self, ImportTarget, ReadinessResult};
use super::secrets;
use super::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeId, NodeMeta, Phase,
    PlanNode, TransitionKind, Verdict,
};
use super::watchdog::{self, Progress, StallPolicy};
use crate::manifest::keys;
use crate::manifest::lifecycle::{self, never_pruned};

/// A single resource or synthetic node paired with the work
/// the scheduler will perform on it.
#[derive(Debug, Clone)]
pub struct PlanNodeEntry {
    pub id: NodeId,
    pub kind: TransitionKind,
    /// The concrete change to apply. For [`TransitionKind::Skip`] this carries
    /// the `ResourceId`. For [`TransitionKind::Apply`] and
    /// [`TransitionKind::Recreate`] it carries the manifest.
    pub action: ChangeAction,
    pub meta: NodeMeta,
    /// The manifest when it carries the `kix.run/rerun` annotation. A changed
    /// resource is tagged `Recreate`. An unchanged resource keeps its `Skip`
    /// tag, but still runs a task to recreate the live object if its previous
    /// run failed.
    pub rerun: Option<Value>,
}

/// The planner's output, consumed by `run_deploy`. Constructed
/// only inside the library; callers read [`DeployPlan::nodes`].
///
/// Each entry in `edges` is `(dependent, predecessor)`, where the dependent
/// waits for the predecessor. Both endpoints must appear in `nodes`.
#[derive(Debug, Clone, Default)]
pub struct DeployPlan {
    pub(crate) nodes: Vec<PlanNodeEntry>,
    pub(crate) edges: Vec<(NodeId, NodeId)>,
}

impl DeployPlan {
    /// Build a plan from the resource dependency graph and the change
    /// actions produced by `detect_changes` or `detect_changes_live`.
    ///
    /// Orphans are excluded from the plan and passed to the scheduler
    /// separately for pruning after all plan nodes terminate.
    ///
    /// Returns an error before applying anything if any import marker is
    /// malformed (see [`readiness::import_target_from_manifest`]).
    pub(crate) fn from_graph_and_changes(
        graph: &ResourceGraph,
        changes: &[ChangeAction],
    ) -> Result<Self, readiness::MalformedMarker> {
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

        // Consumer clusters do not apply Kix's own CRDs because the platform
        // cluster manages them. Wait for the live CRDs instead (see `lifecycle::left_to_platform`).
        let manifests = || graph.graph.node_weights().map(|n| &n.manifest);
        let left_to_platform = lifecycle::left_to_platform(manifests());
        let platform = manifests()
            .find(|m| lifecycle::is_record(m))
            .and_then(lifecycle::platform_of)
            .unwrap_or_default();

        let mut nodes = Vec::with_capacity(graph.graph.node_count());
        for idx in graph.graph.node_indices() {
            let node = &graph.graph[idx];
            if left_to_platform.contains(&node.id) {
                nodes.push(PlanNodeEntry {
                    id: NodeId::Resource(node.id.clone()),
                    kind: TransitionKind::Wait,
                    action: ChangeAction::Skip(node.id.clone()),
                    meta: NodeMeta {
                        package: keys::get(&node.manifest, keys::PACKAGE).map(|s| s.to_string()),
                        namespace: None,
                        import_target: Some(ImportTarget::left_to_platform(
                            &node.manifest,
                            platform,
                        )),
                    },
                    rerun: None,
                });
                continue;
            }
            let k8s_id = format!("{}/{}/{}", node.id.kind, node.id.namespace, node.id.name);
            let action = match by_id.get(&k8s_id) {
                Some(ChangeAction::Apply(m)) => ChangeAction::Apply((*m).clone()),
                Some(ChangeAction::Skip(rid)) => ChangeAction::Skip(rid.clone()),
                // Default to Skip if a graph node has no matching change action.
                None | Some(ChangeAction::Orphan(_)) => ChangeAction::Skip(node.id.clone()),
            };
            let rerun = wants_rerun(&node.manifest).then(|| node.manifest.clone());
            let kind = match &action {
                ChangeAction::Apply(_) if rerun.is_some() => TransitionKind::Recreate,
                ChangeAction::Apply(_) => TransitionKind::Apply,
                ChangeAction::Skip(_) => TransitionKind::Skip,
                ChangeAction::Orphan(_) => TransitionKind::Delete,
            };

            let meta = NodeMeta {
                package: keys::get(&node.manifest, keys::PACKAGE).map(|s| s.to_string()),
                namespace: (node.id.namespace != CLUSTER_SCOPED).then(|| node.id.namespace.clone()),
                import_target: readiness::import_target_from_manifest(&node.manifest)?,
            };

            nodes.push(PlanNodeEntry {
                id: NodeId::Resource(node.id.clone()),
                kind,
                action,
                meta,
                rerun,
            });
        }

        // ResourceGraph edges point from dependent to predecessor.
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

        Ok(DeployPlan { nodes, edges })
    }

    /// Return the nodes of the plan in graph order.
    pub fn nodes(&self) -> &[PlanNodeEntry] {
        &self.nodes
    }

    /// Build a test plan that applies every manifest.
    #[cfg(any(test, feature = "test-util"))]
    pub fn applying(manifests: &[Value]) -> Self {
        let graph = ResourceGraph::from_manifests(manifests).expect("a test plan's graph");
        let changes: Vec<ChangeAction> =
            manifests.iter().cloned().map(ChangeAction::Apply).collect();
        Self::from_graph_and_changes(&graph, &changes).expect("a test plan's markers")
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrunePolicy {
    /// Skip pruning entirely.
    Skip,
    /// Report orphans but do not delete them.
    WarnOnly,
    /// Delete orphans in reverse-topological order.
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
    /// Recreate an unchanged `kix.run/rerun` node if its live object failed.
    /// `kix deploy` and `kix rollback` enable this so explicit CLI runs retry
    /// failed probes. The operator disables this because it diffs against live
    /// objects and requeues failed runs every 30 seconds, which would otherwise
    /// recreate a failing probe Job in an infinite loop.
    pub rerun_failed: bool,
}

#[derive(Error, Debug)]
pub enum DeployError {
    /// The Activation record could not be started, so nothing was applied.
    #[error("Nothing was applied: the deployment record could not be started. {message}")]
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
        "the changes were applied, but the deployment record could not be finalized: {message}. \
         The record may still read Deploying."
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
            rerun_failed: config.rerun_failed,
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
            state: SchedulerState::new(plan),
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

            // Complete ordinary Skip nodes immediately without spawning a task.
            // Skip nodes with `kix.run/rerun` still spawn a task to inspect the
            // live object and recreate it if it failed.
            if matches!(entry.kind, TransitionKind::Skip) && entry.rerun.is_none() {
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
            self.nodes_in_flight += 1;
            let handle = self.tasks.spawn(async move {
                let out = execute_node(&ctx, &entry).await;
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
                // A rerun-annotated Skip node whose live object succeeded is
                // unchanged and still belongs to this activation.
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
    /// immediately.
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
        if is_crd_like(entry) {
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
        self.checkpoints.failed += 1;
        self.emit(DeployEvent::NodeStateChanged {
            node: node_id.clone(),
            kind: entry.kind,
            verdict: Verdict::Failed {
                message: message.clone(),
            },
            detail: Some(detail),
        });
        self.state.mark_terminal(node_id, false);

        // Dry runs persist nothing, so promote dependents even when a
        // predecessor fails so all validation errors surface in a single preview.
        let cancelled = if self.dry_run {
            self.state.promote_dependents(node_id);
            Vec::new()
        } else {
            self.state.cascade_cancel(node_id)
        };
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
            self.halting_reason = Some(format!("halt-on-first-failure: {message}"));
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
            && effective_orphans.iter().any(|rid| !never_pruned(&rid.kind));
        if effective_orphans.is_empty() || prune == PrunePolicy::Skip {
            return orphans_left;
        }
        let ordered = prune_order(&effective_orphans, self.old_manifests);
        let delete = prune == PrunePolicy::Delete;
        let (kept, prunable): (Vec<ResourceId>, Vec<ResourceId>) =
            ordered.iter().cloned().partition(|r| never_pruned(&r.kind));
        self.emit(DeployEvent::PruneStart {
            count: prunable.len(),
            resources: prunable,
            kept,
            delete,
        });

        for rid in &ordered {
            if prune == PrunePolicy::WarnOnly || never_pruned(&rid.kind) {
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

struct SchedulerState {
    entries: HashMap<NodeId, PlanNodeEntry>,
    /// Remaining non-Ready predecessors.
    pending_preds: HashMap<NodeId, usize>,
    /// Predecessor to dependents (reverse adjacency).
    dependents: HashMap<NodeId, Vec<NodeId>>,
    /// Nodes ready to execute.
    ready: VecDeque<NodeId>,
    /// Nodes already pushed to `ready` to guard against duplicate admission.
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
        // Sort resource nodes by `(kind, namespace, name)` for deterministic
        // execution in tests.
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

    /// Return all nodes that have not yet reached a terminal verdict, in
    /// deterministic order.
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

    /// Mark a node terminal. If `success` is true, promote any dependents whose
    /// last predecessor just became ready onto the ready queue.
    fn mark_terminal(&mut self, id: &NodeId, success: bool) {
        self.terminal.insert(id.clone());
        if !success {
            return;
        }
        self.promote_dependents(id);
    }

    /// Mark a CRD node terminal without promoting its dependents until the
    /// subsequent discovery refresh completes.
    fn mark_terminal_deferred(&mut self, id: &NodeId) {
        self.terminal.insert(id.clone());
    }

    /// Promote every dependent of `id` whose last predecessor is now ready.
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

    /// Mark every transitive dependent of `id` as terminal and return the
    /// cancelled node IDs so the caller can emit events.
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

struct NodeCtx {
    resources: Arc<dyn ResourceIo>,
    secrets: Arc<dyn SecretHydrator>,
    cancel: CancelToken,
    timeout: Duration,
    orphan_set: HashSet<ResourceId>,
    dry_run: bool,
    rerun_failed: bool,
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
    /// Deleted and recreated under the rerun rule.
    Rerun {
        apply_action: ApplyAction,
        reason: String,
    },
    /// Ready, with `stale` pods of an `OnDelete` DaemonSet still running the
    /// previous pod template.
    PendingRestart {
        apply_action: ApplyAction,
        stale: i64,
        message: String,
    },
    Failed {
        detail: NodeDetail,
        message: String,
    },
    Cancelled,
}

/// Delete and recreate a resource through `ResourceIo::recreate_in_place`
/// unless `recreate_refusal` rejects its kind.
async fn recreate(
    ctx: &NodeCtx,
    manifest: &Value,
    rid: &ResourceId,
) -> Result<ApplyResult, String> {
    if let Some(refusal) = recreate_refusal(rid) {
        return Err(refusal);
    }
    ctx.resources
        .recreate_in_place(manifest)
        .await
        .map_err(|e| e.to_string())
}

/// Return an error message if `rid` is a protected kind that Kix must not
/// delete and recreate automatically, or `None` if recreation is allowed.
fn recreate_refusal(rid: &ResourceId) -> Option<String> {
    if !never_pruned(&rid.kind) {
        return None;
    }
    let consequence = match rid.kind.as_str() {
        "Namespace" => "deleting a Namespace deletes everything in it",
        "CustomResourceDefinition" => {
            "deleting a CustomResourceDefinition deletes every custom resource of that kind"
        }
        _ => "deleting it also deletes objects outside the build",
    };
    Some(format!(
        "{rid} can only be changed by deleting and re-creating it, and Kix never \
         deletes a {kind} automatically: {consequence}. Delete it with kubectl \
         if that is intended, then deploy again.",
        kind = rid.kind,
    ))
}

/// Hydrate secrets, apply or recreate the resource, wait for readiness, and
/// return the node's outcome.
async fn execute_node(ctx: &NodeCtx, entry: &PlanNodeEntry) -> NodeOutcome {
    if entry.kind == TransitionKind::Wait {
        return wait_for_platform(ctx, entry).await;
    }
    // Reason a rerun node is deleted before apply. `None` means a standard apply.
    let mut rerun_reason: Option<&'static str> = None;
    let manifest = match (&entry.action, &entry.rerun) {
        (ChangeAction::Apply(m), _) => m.clone(),
        (ChangeAction::Skip(rid), Some(manifest)) => {
            // Recreate an unchanged probe if its live object failed and
            // `rerun_failed` is enabled; otherwise report the failure.
            let live = ctx.resources.get_live(rid).await;
            let terminal = match &live {
                Ok(Some(obj)) => readiness::classify_workload_terminal(obj, &rid.kind),
                _ => None,
            };
            match (live, terminal) {
                (Ok(Some(_)), Some((reason, detail))) => {
                    if !ctx.rerun_failed {
                        let message = format!(
                            "{}: {detail}; unchanged since its last run, which failed. \
                             Deploy with the CLI to run it again, or change an input",
                            reason.as_str()
                        );
                        return NodeOutcome::Failed {
                            detail: NodeDetail::ReadinessFailed {
                                message: message.clone(),
                                missing_keys: Vec::new(),
                                output: Vec::new(),
                            },
                            message,
                        };
                    }
                    rerun_reason = Some("the last run failed");
                    manifest.clone()
                }
                (Ok(_), _) => {
                    return NodeOutcome::Ready {
                        apply_action: ApplyAction::Unchanged,
                    };
                }
                (Err(e), _) => {
                    let message = format!("could not read the live object: {e}");
                    return NodeOutcome::Failed {
                        detail: NodeDetail::ApplyFailed(message.clone()),
                        message,
                    };
                }
            }
        }
        (ChangeAction::Skip(_), None) => {
            return NodeOutcome::Ready {
                apply_action: ApplyAction::Unchanged,
            };
        }
        (ChangeAction::Orphan(_), _) => {
            return NodeOutcome::Ready {
                apply_action: ApplyAction::Skipped,
            };
        }
    };
    let rid = ResourceId::from_value(&manifest);
    let node = NodeId::Resource(rid.clone());

    let manifest = if secrets::needs_hydration(&manifest) {
        ctx.progress.set_phase(&node, Phase::Hydrate);
        match ctx.secrets.hydrate(manifest).await {
            Ok((manifest, results)) => {
                for hr in &results {
                    ctx.emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(hr.rid.clone()),
                        kind: entry.kind,
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
                    message: format!("could not prepare secret values for deployment: {e}"),
                };
            }
        }
    } else {
        manifest
    };

    // Changed resources carrying `kix.run/rerun` are never patched in place.
    // Delete the live object in the foreground first so its pods are removed
    // before recreating it, or apply directly if no live object exists.
    if matches!(entry.kind, TransitionKind::Recreate) && rerun_reason.is_none() {
        match ctx.resources.get_live(&rid).await {
            Ok(Some(_)) => rerun_reason = Some("changed since the last run"),
            Ok(None) => {}
            Err(e) => {
                let message = format!("could not read the live object: {e}");
                return NodeOutcome::Failed {
                    detail: NodeDetail::ApplyFailed(message.clone()),
                    message,
                };
            }
        }
    }

    ctx.progress.set_phase(&node, Phase::Apply);
    let applied_action: ApplyAction;
    let mut recreated_reason: Option<String> = None;
    if let Some(reason) = rerun_reason {
        match recreate(ctx, &manifest, &rid).await {
            Ok(apply_result) => {
                applied_action = apply_result.action;
            }
            Err(e) => {
                let message = format!("rerun ({reason}) failed: {e}");
                return NodeOutcome::Failed {
                    detail: NodeDetail::ApplyFailed(message.clone()),
                    message,
                };
            }
        }
    } else {
        match ctx.resources.apply(&manifest).await {
            Ok(result) => {
                applied_action = result.action;
            }
            Err(ApplyError::ImmutableConflict { source, .. }) if ctx.orphan_set.contains(&rid) => {
                let reason = source.to_string();
                match recreate(ctx, &manifest, &rid).await {
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
    }

    ctx.emit(DeployEvent::NodeStateChanged {
        node: node.clone(),
        kind: entry.kind,
        verdict: Verdict::Running,
        detail: Some(NodeDetail::Applied(applied_action.clone())),
    });

    let done = |recreated_reason: Option<String>| match (rerun_reason, recreated_reason) {
        (Some(reason), _) => NodeOutcome::Rerun {
            apply_action: applied_action.clone(),
            reason: reason.to_string(),
        },
        (None, Some(reason)) => NodeOutcome::Recreated {
            apply_action: applied_action.clone(),
            reason,
        },
        (None, None) => NodeOutcome::Ready {
            apply_action: applied_action.clone(),
        },
    };

    // Dry-run applies are not persisted, so skip readiness polling.
    if ctx.dry_run {
        return done(recreated_reason);
    }

    let import_target: Option<ImportTarget> = entry.meta.import_target.clone();
    if import_target.is_none() && readiness::is_immediate_kind(&rid.kind) {
        return done(recreated_reason);
    }

    // Poll for readiness. Each status callback updates the watchdog so an
    // active rollout does not trigger a stall warning.
    ctx.progress.set_phase(&node, Phase::Readiness);
    let on_status = |msg: &str| {
        ctx.progress.set_status(&node, msg);
        ctx.emit(DeployEvent::NodeStateChanged {
            node: node.clone(),
            kind: entry.kind,
            verdict: Verdict::Running,
            detail: Some(NodeDetail::ReadinessProgress(msg.to_string())),
        });
    };
    let outcome = ctx
        .resources
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
                    output: Vec::new(),
                },
                message: e.to_string(),
            };
        }
    };

    match outcome {
        ReadinessResult::Ready => done(recreated_reason),
        ReadinessResult::ReadyPendingRestart { stale, message } => match done(recreated_reason) {
            NodeOutcome::Ready { apply_action } => NodeOutcome::PendingRestart {
                apply_action,
                stale,
                message,
            },
            other => other,
        },
        ReadinessResult::Cancelled => NodeOutcome::Cancelled,
        ReadinessResult::TimedOut { elapsed, message } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessTimeout {
                elapsed,
                message: message.clone(),
            },
            message,
        },
        ReadinessResult::Failed { message, output } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys: Vec::new(),
                output,
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
                output: Vec::new(),
            },
            message,
        },
    }
}

/// Wait for a resource managed by a platform Kix cluster
/// ([`TransitionKind::Wait`]) to become ready without applying it.
async fn wait_for_platform(ctx: &NodeCtx, entry: &PlanNodeEntry) -> NodeOutcome {
    let unchanged = NodeOutcome::Ready {
        apply_action: ApplyAction::Unchanged,
    };
    let NodeId::Resource(rid) = &entry.id else {
        return unchanged;
    };
    if ctx.dry_run {
        return unchanged;
    }
    let node = entry.id.clone();
    ctx.progress.set_phase(&node, Phase::Readiness);
    let on_status = |msg: &str| {
        ctx.progress.set_status(&node, msg);
        ctx.emit(DeployEvent::NodeStateChanged {
            node: node.clone(),
            kind: entry.kind,
            verdict: Verdict::Running,
            detail: Some(NodeDetail::ReadinessProgress(msg.to_string())),
        });
    };
    let outcome = ctx
        .resources
        .wait_ready(
            rid,
            entry.meta.import_target.as_ref(),
            ctx.timeout,
            &ctx.cancel,
            &on_status,
        )
        .await;
    match outcome {
        Ok(ReadinessResult::Ready | ReadinessResult::ReadyPendingRestart { .. }) => unchanged,
        Ok(ReadinessResult::Cancelled) => NodeOutcome::Cancelled,
        Ok(ReadinessResult::TimedOut { elapsed, message }) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessTimeout {
                elapsed,
                message: message.clone(),
            },
            message,
        },
        Ok(
            ReadinessResult::Failed { message, .. }
            | ReadinessResult::ImportMismatch { message, .. },
        ) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys: Vec::new(),
                output: Vec::new(),
            },
            message,
        },
        Err(e) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: e.to_string(),
                missing_keys: Vec::new(),
                output: Vec::new(),
            },
            message: e.to_string(),
        },
    }
}

/// Return rerun-annotated `Skip` nodes whose live object is in a terminal
/// failed state.
///
/// `kix deploy` and `kix rollback` short-circuit before invoking the scheduler
/// when a plan has no changes to apply. They call this function first so an
/// unchanged probe whose previous run failed still triggers a scheduler run.
pub async fn failed_rerun_nodes(
    client: &kube::Client,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
    plan: &DeployPlan,
) -> Vec<ResourceId> {
    let mut failed = Vec::new();
    for entry in &plan.nodes {
        let (ChangeAction::Skip(rid), Some(_)) = (&entry.action, &entry.rerun) else {
            continue;
        };
        let Some((ar, scope)) = discovery.iter().find(|(ar, _)| ar.kind == rid.kind) else {
            continue;
        };
        let api = super::discovery::api_for(client, ar, scope, rid);
        match api.get_opt(&rid.name).await {
            Ok(Some(live))
                if readiness::classify_workload_terminal(&live.data, &rid.kind).is_some() =>
            {
                failed.push(rid.clone());
            }
            Ok(_) => {}
            Err(e) => {
                tracing::debug!(resource = %rid, error = %e, "could not read a rerun node's live object");
            }
        }
    }
    failed
}

/// Return orphaned resources in reverse-topological order according to
/// `old_manifests`. Orphans without a matching manifest in `old_manifests`
/// have no known dependencies and are appended at the end.
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
    let mut ordered = match ResourceGraph::from_manifests(&orphan_manifests) {
        Ok(graph) => graph.reverse_topo_ids(),
        Err(_) => return orphan_rids.to_vec(),
    };
    let listed: HashSet<ResourceId> = ordered.iter().cloned().collect();
    ordered.extend(
        orphan_rids
            .iter()
            .filter(|rid| !listed.contains(*rid))
            .cloned(),
    );
    ordered
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    fn manifest(kind: &str, name: &str, ns: &str, id_hash: &str, deps: &str) -> Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert(keys::IDENTITY_HASH.into(), json!(id_hash));
        if !deps.is_empty() {
            annotations.insert(keys::DEPENDS_ON.into(), json!(deps));
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
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes).unwrap();

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
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes).unwrap();
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

    /// A CRD ref marker without `kix.run/crd-served-versions` fails the
    /// plan, whether or not it changed since the last deploy.
    #[test]
    fn plan_refuses_crd_ref_marker_without_served_versions() {
        let mut marker = manifest(
            "PackageInstance",
            "crd-ref-vm-scrapeconfigs-monitoring-coreos-com",
            "monitoring",
            "h_marker",
            "",
        );
        marker["apiVersion"] = json!(keys::API_VERSION);
        let annotations = &mut marker["metadata"]["annotations"];
        annotations[keys::MODE] = json!("import");
        annotations[keys::IMPORT_KIND] = json!("CustomResourceDefinition");
        annotations[keys::IMPORT_API_VERSION] = json!("apiextensions.k8s.io/v1");
        annotations[keys::IMPORT_NAME] = json!("scrapeconfigs.monitoring.coreos.com");
        annotations[keys::CRD_KIND] = json!("ScrapeConfig");
        annotations[keys::CRD_VERSION] = json!("v1alpha1");
        let manifests = vec![marker];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();

        for change in [
            ChangeAction::Apply(manifests[0].clone()),
            ChangeAction::Skip(ResourceId::from_value(&manifests[0])),
        ] {
            let err = DeployPlan::from_graph_and_changes(&graph, &[change]).unwrap_err();
            assert!(err.to_string().contains(keys::CRD_SERVED_VERSIONS), "{err}");
        }

        let mut served = manifests;
        served[0]["metadata"]["annotations"][keys::CRD_SERVED_VERSIONS] = json!("v1alpha1");
        let graph = ResourceGraph::from_manifests(&served).unwrap();
        let plan =
            DeployPlan::from_graph_and_changes(&graph, &[ChangeAction::Apply(served[0].clone())])
                .unwrap();
        let target = plan.nodes[0].meta.import_target.as_ref().unwrap();
        assert_eq!(target.served_versions, vec!["v1alpha1"]);
    }

    /// A manifest carrying `kix.run/rerun` is tagged Recreate when it
    /// changed and keeps its Skip tag, with the manifest attached, when it
    /// did not.
    #[test]
    fn plan_tags_rerun_manifests() {
        let mut changed = manifest("Job", "probe", "default", "h_probe", "");
        changed["metadata"]["annotations"][keys::RERUN] = json!("on-change");
        let mut same = manifest("Job", "old-probe", "default", "h_old", "");
        same["metadata"]["annotations"][keys::RERUN] = json!("on-change");
        let plain = manifest("ConfigMap", "cm", "default", "h_cm", "");
        let manifests = vec![changed.clone(), same.clone(), plain.clone()];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let changes = vec![
            ChangeAction::Apply(changed),
            ChangeAction::Skip(ResourceId::from_value(&same)),
            ChangeAction::Skip(ResourceId::from_value(&plain)),
        ];
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes).unwrap();
        let by_name = |name: &str| {
            plan.nodes
                .iter()
                .find(|n| matches!(&n.id, NodeId::Resource(rid) if rid.name == name))
                .unwrap()
        };
        assert!(matches!(by_name("probe").kind, TransitionKind::Recreate));
        assert!(by_name("probe").rerun.is_some());
        assert!(matches!(by_name("old-probe").kind, TransitionKind::Skip));
        assert!(by_name("old-probe").rerun.is_some());
        assert!(matches!(by_name("cm").kind, TransitionKind::Skip));
        assert!(by_name("cm").rerun.is_none());
    }

    /// The annotation is honoured on Jobs only: a Deployment carrying it
    /// is a plain Apply, never deleted.
    #[test]
    fn plan_ignores_rerun_on_non_jobs() {
        let mut deploy = manifest("Deployment", "web", "default", "h_web", "");
        deploy["metadata"]["annotations"][keys::RERUN] = json!("on-change");
        let manifests = vec![deploy.clone()];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let plan =
            DeployPlan::from_graph_and_changes(&graph, &[ChangeAction::Apply(deploy)]).unwrap();
        assert!(matches!(plan.nodes[0].kind, TransitionKind::Apply));
        assert!(plan.nodes[0].rerun.is_none());
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
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes).unwrap();

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
        let plan = DeployPlan::from_graph_and_changes(&graph, &changes).unwrap();
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

/// Engine tests: `run_deploy` against the scripted fake without a cluster,
/// using a paused clock. Every run is wrapped in a one-hour virtual timeout so
/// a parked engine fails immediately instead of hanging the suite.
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

    /// Build a manifest with identity hash `h_<name>` and dependencies `deps`.
    fn m(kind: &str, name: &str, deps: &[&str]) -> Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert(keys::IDENTITY_HASH.into(), json!(format!("h_{name}")));
        if !deps.is_empty() {
            let deps: Vec<String> = deps.iter().map(|d| format!("h_{d}")).collect();
            annotations.insert(keys::DEPENDS_ON.into(), json!(deps.join(",")));
        }
        let mut metadata = json!({ "name": name, "annotations": annotations });
        if kind != "CustomResourceDefinition" {
            metadata["namespace"] = json!("default");
        }
        json!({ "apiVersion": "v1", "kind": kind, "metadata": metadata })
    }

    /// Build a manifest carrying the `kix.run/rerun` annotation.
    fn rerun_m(kind: &str, name: &str, deps: &[&str]) -> Value {
        let mut v = m(kind, name, deps);
        v["metadata"]["annotations"][keys::RERUN] = json!("on-change");
        v
    }

    /// Build a live Job object in a failed or succeeded state.
    fn live_job(failed: bool) -> Value {
        json!({
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": { "name": "probe", "namespace": "default" },
            "spec": { "backoffLimit": 0 },
            "status": if failed { json!({ "failed": 1 }) } else { json!({ "succeeded": 1 }) },
        })
    }

    fn plan_of(manifests: &[Value]) -> DeployPlan {
        plan_with_skips(manifests, &[])
    }

    /// Build a plan from `manifests`, marking the named resources as `Skip`.
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
        DeployPlan::from_graph_and_changes(&graph, &changes).unwrap()
    }

    fn config(stall: StallPolicy) -> SchedulerConfig {
        SchedulerConfig {
            timeout: secs(300),
            on_error: OnErrorPolicy::Continue,
            cancel: CancelToken::new(),
            concurrency: CONCURRENCY,
            stall,
            rerun_failed: true,
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

        fn prune_starts(&self) -> Vec<(usize, Vec<ResourceId>, Vec<ResourceId>, bool)> {
            self.0
                .lock()
                .unwrap()
                .iter()
                .filter_map(|e| match e {
                    DeployEvent::PruneStart {
                        count,
                        resources,
                        kept,
                        delete,
                    } => Some((*count, resources.clone(), kept.clone(), *delete)),
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

        /// Return terminal verdicts per node in emission order.
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

    /// Run the engine with a virtual timeout so any deadlock fails immediately.
    async fn run(
        ops: &Arc<ScriptedOps>,
        plan: DeployPlan,
        config: &SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        tokio::time::timeout(
            secs(3600),
            run_scripted(
                ops.clone(),
                plan,
                &[],
                &[],
                PrunePolicy::WarnOnly,
                config,
                observer,
            ),
        )
        .await
        .expect("engine parked: nothing runnable for an hour of virtual time")
    }

    /// Run the engine with orphans to prune.
    async fn run_with_orphans(
        ops: &Arc<ScriptedOps>,
        plan: DeployPlan,
        orphans: &[ResourceId],
        old_manifests: &[Value],
        prune: PrunePolicy,
        config: &SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        tokio::time::timeout(
            secs(3600),
            run_scripted(
                ops.clone(),
                plan,
                orphans,
                old_manifests,
                prune,
                config,
                observer,
            ),
        )
        .await
        .expect("engine parked: nothing runnable for an hour of virtual time")
    }

    fn total(r: &DeployResult) -> usize {
        r.created + r.configured + r.unchanged + r.failed + r.cancelled
    }

    /// Slow applies can fill the concurrency cap without blocking a completed
    /// CRD's discovery refresh or its dependent.
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

    /// A failed discovery refresh stops the run before its dependent is
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

    /// A hung apply is named within the warning bound and the
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

    /// A slow but healthy rollout reports progress often enough to keep the
    /// watchdog quiet.
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

    /// Cancellation with every node hung returns promptly and aborts
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
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::Delete;
        let token = cfg.cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(secs(5)).await;
            token.cancel();
        });
        let rec = Arc::new(Recorder::default());
        let orphans = [rid("ConfigMap", "old")];
        let old = [m("ConfigMap", "old", &[])];

        let err = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &old,
            prune,
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap_err();

        assert!(matches!(err, DeployError::Cancelled { .. }), "{err}");
        let calls = ops.calls();
        assert!(
            !calls
                .iter()
                .any(|c| matches!(c, Call::Delete(_) | Call::Finalize { .. }))
        );
        // But it does mark the record Failed, which is the whole point: this
        // run applied part of its closure and nothing else will say so.
        assert!(
            calls.iter().any(|c| matches!(c, Call::Abort { .. })),
            "a cancelled run must abort the activation: {calls:?}",
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

    /// A run that stops because a node failed under `OnErrorPolicy::Stop`
    /// marks the activation record as `Failed` so the next deploy can
    /// reconcile what was applied.
    #[tokio::test(start_paused = true)]
    async fn a_failed_node_under_stop_aborts_the_activation() {
        let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.on_error = OnErrorPolicy::Stop;
        let rec = Arc::new(Recorder::default());

        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        assert!(matches!(err, DeployError::NodesFailed { .. }), "{err}");
        let calls = ops.calls();
        assert!(
            calls.iter().any(|c| matches!(c, Call::Abort { .. })),
            "a halted run must abort the activation: {calls:?}",
        );
        assert!(
            !calls.iter().any(|c| matches!(c, Call::Finalize { .. })),
            "and must not also finalize: {calls:?}",
        );
    }

    /// A run under `--on-error=continue` that leaves nodes never attempted
    /// must not finalize. The record would land Degraded, and Degraded is a
    /// current state: the next deploy of the same closure would then skip
    /// every node this one never ran.
    #[tokio::test(start_paused = true)]
    async fn a_run_with_cancelled_nodes_aborts_instead_of_finalizing() {
        let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.on_error = OnErrorPolicy::Continue;
        let prune = PrunePolicy::Delete;
        let rec = Arc::new(Recorder::default());

        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &[rid("ConfigMap", "old")],
            &[m("ConfigMap", "old", &[])],
            prune,
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap();
        assert!(result.cancelled > 0, "b should have been cancelled");

        let calls = ops.calls();
        assert!(
            calls.iter().any(|c| matches!(c, Call::Abort { .. })),
            "an incomplete run must abort: {calls:?}",
        );
        assert!(
            !calls.iter().any(|c| matches!(c, Call::Finalize { .. })),
            "and must not finalize, which would supersede a still-running activation: {calls:?}",
        );
        // And it must not prune. The previous activation stays Active, so its
        // orphans are objects the cluster still depends on.
        assert!(
            !calls.iter().any(|c| matches!(c, Call::Delete(_))),
            "an incomplete run must not prune the still-current closure: {calls:?}",
        );
    }

    /// A dry run tries the dependents of a refused node, since nothing a dry
    /// run writes persists: every refusal shows, not only the first.
    #[tokio::test(start_paused = true)]
    async fn a_dry_run_tries_the_dependents_of_a_refused_node() {
        let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
        let ops = Arc::new(ScriptedOps::new());
        ops.set_dry_run(true);
        ops.script(
            rid("Deployment", "a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.on_error = OnErrorPolicy::Continue;
        let rec = Arc::new(Recorder::default());

        let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap();
        assert_eq!((result.failed, result.cancelled), (1, 0));
        assert!(
            ops.calls()
                .contains(&Call::ApplyEnd(rid("Deployment", "b"))),
            "b was not tried: {:?}",
            ops.calls()
        );
    }

    /// A run where everything was attempted and some failed IS a current
    /// state, so it finalizes (Degraded) rather than aborting.
    #[tokio::test(start_paused = true)]
    async fn a_run_that_attempted_everything_still_finalizes() {
        // Two independent nodes: one fails, the other applies. Nothing is
        // cancelled, so the closure is as applied as it can be.
        let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.on_error = OnErrorPolicy::Continue;
        let rec = Arc::new(Recorder::default());

        let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap();
        assert_eq!(result.cancelled, 0);
        assert_eq!(result.failed, 1);

        let calls = ops.calls();
        assert!(
            calls.iter().any(|c| matches!(
                c,
                Call::Finalize {
                    had_failures: true,
                    ..
                }
            )),
            "expected a Degraded finalize: {calls:?}",
        );
        assert!(!calls.iter().any(|c| matches!(c, Call::Abort { .. })));
    }

    /// A run that finishes never aborts. Finalize and abort are the two ends
    /// of the same lifecycle and exactly one of them happens.
    #[tokio::test(start_paused = true)]
    async fn a_clean_run_finalizes_and_never_aborts() {
        let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
        let ops = Arc::new(ScriptedOps::new());
        let cfg = config(quiet_watchdog());
        let rec = Arc::new(Recorder::default());

        run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap();

        let calls = ops.calls();
        assert!(calls.iter().any(|c| matches!(c, Call::Finalize { .. })));
        assert!(
            !calls.iter().any(|c| matches!(c, Call::Abort { .. })),
            "a clean run must not abort: {calls:?}",
        );
    }

    /// A record that cannot be begun stops the run before any node is
    /// applied, and the run does not abort a record it never began.
    #[tokio::test(start_paused = true)]
    async fn a_failed_begin_stops_the_run_before_any_node() {
        let manifests = vec![m("Deployment", "a", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.begin_behaviour(Behaviour::Now(Err("records under a retired group".into())));
        let rec = Arc::new(Recorder::default());

        let err = run(
            &ops,
            plan_of(&manifests),
            &config(quiet_watchdog()),
            rec.clone(),
        )
        .await
        .unwrap_err();

        assert!(matches!(err, DeployError::BeginFailed { .. }), "{err}");
        assert!(
            err.to_string().contains("records under a retired group"),
            "{err}"
        );
        assert_eq!(ops.calls(), vec![Call::Begin]);
        assert!(rec.stopped().is_some());
    }

    /// An abort that will not go through is reported, not fatal. The run has
    /// already ended; the error it ends with must still be the real one.
    #[tokio::test(start_paused = true)]
    async fn a_failing_abort_is_reported_and_does_not_change_the_error() {
        let manifests = vec![m("Deployment", "a", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Deployment", "a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        ops.abort_behaviour(Behaviour::Now(Err("no answer from the apiserver".into())));
        let mut cfg = config(quiet_watchdog());
        cfg.on_error = OnErrorPolicy::Stop;
        let rec = Arc::new(Recorder::default());

        let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap_err();

        assert!(matches!(err, DeployError::NodesFailed { .. }), "{err}");
        assert!(
            rec.best_effort_failures()
                .iter()
                .any(|line| line.starts_with("activation abort:")),
            "the failed abort should be reported as best-effort",
        );
    }

    /// A checkpoint write that never answers does not park nodes or hold the
    /// run open.
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

    /// Peak concurrency reaches the configured cap without exceeding it.
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

    /// A node task panic is a fatal engine error rather than
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
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::Delete;
        let orphans = [rid("Deployment", "sts")];
        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &manifests,
            prune,
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

    /// An immutable conflict on a CRD fails the node even when the CRD is a
    /// pre-authorized orphan: re-creating it would delete every custom
    /// resource of its kind.
    #[tokio::test(start_paused = true)]
    async fn immutable_conflict_on_crd_is_not_recreated() {
        let manifests = vec![m("CustomResourceDefinition", "widgets.example.com", &[])];
        let crd = rid("CustomResourceDefinition", "widgets.example.com");
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            crd.clone(),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::ImmutableConflict))),
        );
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::Delete;
        let orphans = [crd.clone()];
        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &manifests,
            prune,
            &cfg,
            Arc::new(NullObserver),
        )
        .await
        .unwrap();
        assert_eq!(result.failed, 1);
        assert!(
            !ops.calls()
                .iter()
                .any(|c| matches!(c, Call::RecreateStart(_) | Call::Delete(_)))
        );
    }

    /// The refusal names the kind and what deleting it would take with it;
    /// ordinary kinds are not refused.
    #[test]
    fn recreate_refusal_names_the_consequence() {
        let crd = recreate_refusal(&rid("CustomResourceDefinition", "widgets.example.com"))
            .expect("a CRD is refused");
        assert!(crd.contains("every custom resource of that kind"), "{crd}");
        assert!(crd.contains("kubectl"), "{crd}");
        let ns = recreate_refusal(&ResourceId {
            kind: "Namespace".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "apps".into(),
        })
        .expect("a Namespace is refused");
        assert!(ns.contains("deletes everything in it"), "{ns}");
        assert!(recreate_refusal(&rid("Job", "probe")).is_none());
    }

    fn rerun_details(rec: &Recorder) -> Vec<String> {
        rec.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::NodeStateChanged {
                    detail: Some(NodeDetail::Rerun { reason }),
                    ..
                } => Some(reason.clone()),
                _ => None,
            })
            .collect()
    }

    /// A changed Job carrying `kix.run/rerun`
    /// with a live object is deleted and created again, not applied. The
    /// delete goes through `recreate_in_place`, never through the prune
    /// path, and the node reports `Rerun`.
    #[tokio::test(start_paused = true)]
    async fn rerun_job_with_live_object_is_recreated() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Job", "probe"),
            NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(false))))),
        );
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_of(&manifests),
            &config(quiet_watchdog()),
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.configured, 1);
        assert_eq!(result.failed, 0);
        let calls = ops.calls();
        assert!(calls.contains(&Call::RecreateStart(rid("Job", "probe"))));
        assert!(!calls.iter().any(|c| matches!(c, Call::ApplyStart(_))));
        assert!(!calls.iter().any(|c| matches!(c, Call::Delete(_))));
        assert_eq!(rerun_details(&rec), vec!["changed since the last run"]);
    }

    /// Nothing live (first deploy, TTL-reaped, or deleted externally): a plain
    /// apply, no delete.
    #[tokio::test(start_paused = true)]
    async fn rerun_job_without_live_object_is_applied() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_of(&manifests),
            &config(quiet_watchdog()),
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.created, 1);
        let calls = ops.calls();
        assert!(calls.contains(&Call::GetLive(rid("Job", "probe"))));
        assert!(calls.contains(&Call::ApplyStart(rid("Job", "probe"))));
        assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
        assert!(rerun_details(&rec).is_empty());
    }

    /// An unchanged probe whose live Job failed runs again on the next
    /// deploy without a manual delete.
    #[tokio::test(start_paused = true)]
    async fn skipped_rerun_job_that_failed_is_recreated() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Job", "probe"),
            NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(true))))),
        );
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_with_skips(&manifests, &["probe"]),
            &config(quiet_watchdog()),
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.configured, 1);
        assert_eq!(result.unchanged, 0);
        assert!(
            ops.calls()
                .contains(&Call::RecreateStart(rid("Job", "probe")))
        );
        assert_eq!(rerun_details(&rec), vec!["the last run failed"]);
    }

    /// An unchanged probe whose live Job succeeded is left alone: counted
    /// unchanged and stamped with the activation like any Skip node.
    #[tokio::test(start_paused = true)]
    async fn skipped_rerun_job_that_succeeded_is_left_alone() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Job", "probe"),
            NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(false))))),
        );
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_with_skips(&manifests, &["probe"]),
            &config(quiet_watchdog()),
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.unchanged, 1);
        assert_eq!(result.configured, 0);
        let calls = ops.calls();
        assert!(calls.contains(&Call::GetLive(rid("Job", "probe"))));
        assert!(calls.contains(&Call::Stamp(rid("Job", "probe"))));
        assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
        assert!(!calls.iter().any(|c| matches!(c, Call::ApplyStart(_))));
        assert!(rerun_details(&rec).is_empty());
    }

    /// Without `rerun_failed` (the operator) an unchanged probe whose live
    /// Job failed is reported as failed, never deleted: the gate stays red
    /// instead of reading as healthy, and nothing loops.
    #[tokio::test(start_paused = true)]
    async fn skipped_rerun_job_is_reported_not_retried_without_rerun_failed() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Job", "probe"),
            NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(true))))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.rerun_failed = false;
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_with_skips(&manifests, &["probe"]),
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.failed, 1);
        assert_eq!(result.unchanged, 0);
        let calls = ops.calls();
        assert!(calls.contains(&Call::GetLive(rid("Job", "probe"))));
        assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
        assert!(!calls.iter().any(|c| matches!(c, Call::Delete(_))));
        assert!(rerun_details(&rec).is_empty());
        let failed: Vec<String> = rec
            .0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::NodeStateChanged {
                    verdict: Verdict::Failed { message },
                    ..
                } => Some(message.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(failed.len(), 1);
        assert!(failed[0].contains("which failed"), "{}", failed[0]);
    }

    /// Under dry run a changed rerun Job with a live object still takes the
    /// recreate path (the ops layer answers without writing) and reports
    /// `Rerun`, so a preview shows what the real deploy will do.
    #[tokio::test(start_paused = true)]
    async fn rerun_job_under_dry_run_reports_rerun() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.set_dry_run(true);
        ops.script(
            rid("Job", "probe"),
            NodeScript::default()
                .live(Behaviour::Now(Ok(Some(live_job(false)))))
                .recreate(Behaviour::Now(Ok(ApplyAction::Created))),
        );
        let cfg = config(quiet_watchdog());
        let rec = Arc::new(Recorder::default());
        let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
            .await
            .unwrap();
        assert_eq!(result.failed, 0);
        assert_eq!(result.created, 1);
        assert!(
            ops.calls()
                .contains(&Call::RecreateStart(rid("Job", "probe")))
        );
        assert_eq!(rerun_details(&rec), vec!["changed since the last run"]);
    }

    /// A delete that never completes (stuck finalizer) fails the node with
    /// the ops layer's message instead of a blind re-apply.
    #[tokio::test(start_paused = true)]
    async fn rerun_job_still_present_after_delete_fails_the_node() {
        let manifests = vec![rerun_m("Job", "probe", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Job", "probe"),
            NodeScript::default()
                .live(Behaviour::Now(Ok(Some(live_job(false)))))
                .recreate(Behaviour::Now(Err(
                    "Job/default/probe still exists 30s after delete (stuck finalizer?); not re-applied".into(),
                ))),
        );
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_of(&manifests),
            &config(quiet_watchdog()),
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.failed, 1);
        let failed: Vec<String> = rec
            .0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::NodeStateChanged {
                    verdict: Verdict::Failed { message },
                    ..
                } => Some(message.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(failed.len(), 1);
        assert!(
            failed[0].contains("still exists 30s after delete"),
            "{}",
            failed[0]
        );
        assert!(
            failed[0].contains("changed since the last run"),
            "{}",
            failed[0]
        );
    }

    /// A hung discovery refresh is bounded and named in the error.
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

    /// Build one of Kix's own CRDs serving `v1alpha1`.
    fn kix_crd(name: &str) -> Value {
        let mut v = m("CustomResourceDefinition", name, &[]);
        v["apiVersion"] = json!("apiextensions.k8s.io/v1");
        v["spec"] = json!({"versions": [{"name": "v1alpha1", "served": true}]});
        v
    }

    /// Build a deploy record depending on `deps` with `interfaces`.
    fn record_m(interfaces: Value, deps: &[&str]) -> Value {
        let mut v = m(lifecycle::RECORD_KIND, "rec", deps);
        v["apiVersion"] = json!(keys::API_VERSION);
        v["metadata"].as_object_mut().unwrap().remove("namespace");
        v["spec"] = json!({ "interfaces": interfaces });
        v
    }

    /// Build a manifest set with Kix's two CRDs, a `PackageInstance`, and an
    /// `Activation` record. Non-empty `interfaces` marks the build as a
    /// consumer cluster.
    fn kix_build(interfaces: Value) -> Vec<Value> {
        vec![
            kix_crd(keys::ACTIVATIONS_CRD),
            kix_crd(keys::PACKAGE_INSTANCES_CRD),
            m("PackageInstance", "web", &[keys::PACKAGE_INSTANCES_CRD]),
            record_m(interfaces, &[keys::ACTIVATIONS_CRD, "web"]),
        ]
    }

    /// A consumer waits for Kix's CRDs, which its platform writes. It never
    /// applies them, nor stamps them, and its other objects wait for them.
    #[tokio::test(start_paused = true)]
    async fn a_consumer_waits_for_kix_crds_and_never_writes_them() {
        let manifests = kix_build(json!({"core": {"consumer": "acme"}}));
        let plan = plan_of(&manifests);
        let crds = [
            rid("CustomResourceDefinition", keys::ACTIVATIONS_CRD),
            rid("CustomResourceDefinition", keys::PACKAGE_INSTANCES_CRD),
        ];
        for crd in &crds {
            let node = plan
                .nodes()
                .iter()
                .find(|n| n.id == NodeId::Resource(crd.clone()))
                .unwrap();
            assert_eq!(node.kind, TransitionKind::Wait);
            assert!(matches!(node.action, ChangeAction::Skip(_)));
            let target = node.meta.import_target.as_ref().unwrap();
            assert_eq!(target.platform.as_deref(), Some("core"));
            assert_eq!(target.served_versions, ["v1alpha1"]);
        }

        let ops = Arc::new(ScriptedOps::new());
        let result = run(
            &ops,
            plan,
            &config(quiet_watchdog()),
            Arc::new(NullObserver),
        )
        .await
        .unwrap();

        let calls = ops.calls();
        for crd in &crds {
            assert!(!calls.contains(&Call::ApplyStart(crd.clone())));
            assert!(!calls.contains(&Call::Stamp(crd.clone())));
            assert!(calls.contains(&Call::ReadyEnd(crd.clone())));
        }
        let crd_ready = ops
            .time_of(|c| *c == Call::ReadyEnd(crds[1].clone()))
            .unwrap();
        let web_applied = ops
            .time_of(|c| *c == Call::ApplyStart(rid("PackageInstance", "web")))
            .unwrap();
        assert!(crd_ready <= web_applied);
        assert_eq!(result.unchanged, 2);
        assert_eq!(result.created, 2);
    }

    /// A Kix CRD the platform never installs fails its node, and nothing
    /// that needs it is applied.
    #[tokio::test(start_paused = true)]
    async fn a_consumer_stops_when_kix_crds_never_appear() {
        let manifests = kix_build(json!({"core": {"consumer": "acme"}}));
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("CustomResourceDefinition", keys::PACKAGE_INSTANCES_CRD),
            NodeScript::default().ready(Behaviour::Now(Ready::TimedOut)),
        );
        let result = run(
            &ops,
            plan_of(&manifests),
            &config(quiet_watchdog()),
            Arc::new(NullObserver),
        )
        .await
        .unwrap();

        assert_eq!(result.failed, 1);
        assert!(
            !ops.calls()
                .contains(&Call::ApplyStart(rid("PackageInstance", "web")))
        );
    }

    /// A cluster that is no one's consumer applies Kix's CRDs itself.
    #[tokio::test(start_paused = true)]
    async fn a_cluster_without_a_platform_applies_kix_crds() {
        let manifests = kix_build(json!({}));
        let plan = plan_of(&manifests);
        assert!(!plan.nodes().iter().any(|n| n.kind == TransitionKind::Wait));

        let ops = Arc::new(ScriptedOps::new());
        run(
            &ops,
            plan,
            &config(quiet_watchdog()),
            Arc::new(NullObserver),
        )
        .await
        .unwrap();
        let calls = ops.calls();
        assert!(calls.contains(&Call::ApplyStart(rid(
            "CustomResourceDefinition",
            keys::PACKAGE_INSTANCES_CRD
        ))));
    }

    /// Stamping an unchanged resource is bounded by the watchdog.
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

    /// A hung prune delete is reported as failed. Namespaces are never pruned.
    #[tokio::test(start_paused = true)]
    async fn hung_prune_delete_is_bounded() {
        let manifests = vec![m("ConfigMap", "keep", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.delete_behaviour(Behaviour::Hang);
        let rec = Arc::new(Recorder::default());
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::Delete;
        let orphans = [rid("ConfigMap", "old"), rid("Namespace", "ns")];
        let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];

        let start = Instant::now();
        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &old,
            prune,
            &cfg,
            rec.clone(),
        )
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
        // The announced prune list matches what is acted on: the Namespace
        // is never deleted, so it is announced as kept.
        assert_eq!(
            rec.prune_starts(),
            vec![(
                1,
                vec![rid("ConfigMap", "old")],
                vec![rid("Namespace", "ns")],
                true
            )]
        );
        let failed: Vec<(NodeId, Verdict)> = rec
            .terminals()
            .into_iter()
            .filter(|(_, v)| matches!(v, Verdict::Failed { .. }))
            .collect();
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0].0, NodeId::Resource(rid("ConfigMap", "old")));
    }

    /// Under warn-only, a Namespace orphan is announced as kept, apart from
    /// the orphans the policy reports, and nothing is deleted.
    #[tokio::test(start_paused = true)]
    async fn warn_only_announces_a_namespace_orphan_as_kept() {
        let manifests = vec![m("ConfigMap", "keep", &[])];
        let ops = Arc::new(ScriptedOps::new());
        let rec = Arc::new(Recorder::default());
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::WarnOnly;
        let orphans = [rid("ConfigMap", "old"), rid("Namespace", "ns")];
        let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];

        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &old,
            prune,
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap();

        assert_eq!(result.pruned, 0);
        assert!(!ops.calls().iter().any(|c| matches!(c, Call::Delete(_))));
        assert_eq!(
            rec.prune_starts(),
            vec![(
                1,
                vec![rid("ConfigMap", "old")],
                vec![rid("Namespace", "ns")],
                false
            )]
        );
    }

    /// Finalize is told whether a prunable orphan is still on the cluster:
    /// true when the policy keeps one or a delete fails, false when every
    /// delete succeeds or the only orphans are kinds prune never deletes.
    #[tokio::test(start_paused = true)]
    async fn finalize_learns_whether_orphans_were_left() {
        async fn orphans_left(
            policy: PrunePolicy,
            orphans: &[ResourceId],
            delete: Behaviour<Result<Pruned, String>>,
        ) -> bool {
            let manifests = vec![m("ConfigMap", "keep", &[])];
            let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];
            let ops = Arc::new(ScriptedOps::new());
            ops.delete_behaviour(delete);
            let cfg = config(quiet_watchdog());
            let prune = policy;
            let _ = run_with_orphans(
                &ops,
                plan_of(&manifests),
                orphans,
                &old,
                prune,
                &cfg,
                Arc::new(Recorder::default()),
            )
            .await;
            let finalized: Vec<bool> = ops
                .calls()
                .into_iter()
                .filter_map(|c| match c {
                    Call::Finalize { orphans_left, .. } => Some(orphans_left),
                    _ => None,
                })
                .collect();
            assert_eq!(finalized.len(), 1, "finalize runs once");
            finalized[0]
        }
        let cm = [rid("ConfigMap", "old")];
        let ns = [rid("Namespace", "ns")];
        let ok = || Behaviour::Now(Ok(Pruned::Deleted));

        assert!(orphans_left(PrunePolicy::WarnOnly, &cm, ok()).await);
        assert!(orphans_left(PrunePolicy::Skip, &cm, ok()).await);
        assert!(!orphans_left(PrunePolicy::Delete, &cm, ok()).await);
        assert!(
            orphans_left(
                PrunePolicy::Delete,
                &cm,
                Behaviour::Now(Err("denied".into()))
            )
            .await
        );
        assert!(!orphans_left(PrunePolicy::WarnOnly, &ns, ok()).await);
        // A delete the guard refused because the object changed leaves it
        // for the next prune; one another Kix cluster still deploys does not.
        let changed = Pruned::Changed(rid("ConfigMap", "old"));
        assert!(orphans_left(PrunePolicy::Delete, &cm, Behaviour::Now(Ok(changed))).await);
        let shared = Pruned::Kept(crate::cluster::inventory::SharedOrphan {
            rid: rid("ConfigMap", "old"),
            clusters: vec!["b".into()],
        });
        assert!(!orphans_left(PrunePolicy::Delete, &cm, Behaviour::Now(Ok(shared))).await);
    }

    /// An orphan with no manifest among the old manifests is still pruned,
    /// after the ones the graph orders.
    #[tokio::test(start_paused = true)]
    async fn an_orphan_the_old_manifests_lack_is_still_pruned() {
        let manifests = vec![m("ConfigMap", "keep", &[])];
        let ops = Arc::new(ScriptedOps::new());
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::Delete;
        let orphans = [rid("ConfigMap", "listed"), rid("ConfigMap", "unlisted")];
        let old = [m("ConfigMap", "listed", &[])];

        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &old,
            prune,
            &cfg,
            Arc::new(Recorder::default()),
        )
        .await
        .unwrap();

        assert_eq!(result.pruned, 2);
        let deleted: Vec<ResourceId> = ops
            .calls()
            .into_iter()
            .filter_map(|c| match c {
                Call::Delete(rid) => Some(rid),
                _ => None,
            })
            .collect();
        assert_eq!(deleted, orphans.to_vec());
    }

    /// An orphan the prune guard keeps is reported as kept, not as pruned or
    /// failed.
    #[tokio::test(start_paused = true)]
    async fn a_kept_prune_delete_is_reported_as_kept() {
        let manifests = vec![m("ConfigMap", "keep", &[])];
        let ops = Arc::new(ScriptedOps::new());
        let shared = Pruned::Kept(crate::cluster::inventory::SharedOrphan {
            rid: rid("ConfigMap", "old"),
            clusters: vec!["b".into()],
        });
        ops.delete_behaviour(Behaviour::Now(Ok(shared)));
        let rec = Arc::new(Recorder::default());
        let cfg = config(quiet_watchdog());
        let prune = PrunePolicy::Delete;
        let orphans = [rid("ConfigMap", "old")];
        let old = [m("ConfigMap", "old", &[])];

        let result = run_with_orphans(
            &ops,
            plan_of(&manifests),
            &orphans,
            &old,
            prune,
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap();

        assert_eq!((result.pruned, result.failed), (0, 0));
        let kept: Vec<(ResourceId, String)> = rec
            .0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::PruneKept { resource, reason } => {
                    Some((resource.clone(), reason.clone()))
                }
                _ => None,
            })
            .collect();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].0, rid("ConfigMap", "old"));
        assert!(
            kept[0].1.contains("still deployed by Kix cluster b"),
            "{kept:?}"
        );
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

    // Property tests over generated DAGs and outcomes.

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

    /// Return true if node `j` requires readiness polling (`Deployment`).
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
        let rec = Arc::new(Recorder::default());
        let outcome = rt.block_on(tokio::time::timeout(
            secs(3600),
            run_scripted(
                ops.clone(),
                plan,
                &[],
                &[],
                PrunePolicy::WarnOnly,
                &cfg,
                rec.clone(),
            ),
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
