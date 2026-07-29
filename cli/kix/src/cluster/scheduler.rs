//! DAG-streaming deploy scheduler (doc 99 Stage A).
//!
//! Replaces the wave-barrier loop in `reconcile.rs`. Every node in the
//! [`DeployPlan`] becomes ready to execute the moment its direct predecessors
//! have emitted [`Verdict::Ready`]; independent subtrees stream through in
//! parallel, bounded by [`CONCURRENCY`]. See doc 98 §4 for the motivation
//! (head-of-line blocking under wave barriers) and doc 99 §9 for scope.
//!
//! Today the planner tags every node as [`TransitionKind::Apply`] or
//! [`TransitionKind::Skip`]; the other variants exist on the enum but are
//! not yet produced. Recreate/Migrate/Drain/Delete/Pause are Stage E–F.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;

use futures::stream::{FuturesUnordered, StreamExt};
use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;
use tokio::sync::RwLock;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::activation::{self, WaveRecord, WaveStatus};
use super::apply::{self, ApplyAction, ApplyError, ApplyResult, ChangeAction};
use super::cancel::CancelToken;
use super::fetch;
use super::graph::ResourceGraph;
use super::readiness::{self, ImportTarget, ReadinessResult};
use super::secrets;
use super::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeId, NodeMeta,
    PlanNode, TransitionKind, Verdict,
};

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

/// Max concurrent in-flight nodes. Same ceiling the old wave-based readiness
/// loop used; keeps kube's connection pool and the API server's rate limiter
/// happy on wide clusters.
pub const CONCURRENCY: usize = 64;

/// Checkpoint every N terminal verdicts to the Activation CR. Keeps write
/// pressure modest on the apiserver while giving a crash-recovery point every
/// few seconds under typical deploy cadence.
const CHECKPOINT_BATCH: usize = 16;

pub struct SchedulerConfig {
    pub timeout: Duration,
    pub on_error: OnErrorPolicy,
    pub prune: PrunePolicy,
    pub force_conflicts: bool,
    pub cancel: CancelToken,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Error, Debug)]
pub enum DeployError {
    #[error("deploy stopped: {count} node(s) failed")]
    NodesFailed { count: usize, partial: DeployResult },

    #[error("API discovery failed: {0}")]
    DiscoveryFailed(String),

    #[error("activation lifecycle error: {0}")]
    ActivationError(String),

    #[error("deploy cancelled")]
    Cancelled { partial: DeployResult },
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Execute a DAG-streaming deploy.
///
/// The scheduler maintains a ready-queue; a node becomes ready the moment all
/// its predecessors have emitted `Verdict::Ready`. Concurrency is bounded by
/// [`CONCURRENCY`]. On a node failure the failure policy either halts the
/// whole deploy ([`OnErrorPolicy::Stop`]) or halts only transitive dependents
/// while sibling subtrees continue ([`OnErrorPolicy::Continue`]).
///
/// After every non-orphan node has reached a terminal verdict, orphans are
/// pruned (in reverse-topological order of the old graph) and the Activation
/// CR is finalized.
#[allow(clippy::too_many_arguments)]
pub async fn run_deploy(
    client: &Client,
    discovery: Arc<RwLock<Vec<(ApiResource, Scope)>>>,
    plan: DeployPlan,
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    cluster_name: &str,
    activation_name: Option<&str>,
    activation_identity_hash: Option<&str>,
    config: &SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
) -> Result<DeployResult, DeployError> {
    let mut result = DeployResult::default();

    // Publish the plan skeleton so renderers can paint the tree before any
    // node has executed.
    observer.on_event(&DeployEvent::PlanComputed {
        nodes: plan.to_plan_nodes(),
        edges: plan.edges.clone(),
    });

    // Find Activation ApiResource for status updates.
    let activation_ar = {
        let d = discovery.read().await;
        activation::find_activation_ar(&d).map(|(ar, _)| ar.clone())
    };

    // Best-effort: stamp deploy-start on the Activation CR. 404 on first deploy.
    if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
        // Single synthetic "wave" for the whole stream; resource_count is the
        // total applyable node count. The Activation CR schema still carries
        // WaveRecord until a follow-up migration replaces it.
        if let Err(e) = activation::begin_deploy(client, ar, act_name, 1).await {
            tracing::debug!("activation not yet on cluster (first deploy): {e}");
        }
    }

    // Which activations still exist, for pruning `kix.dev/activations`. Read
    // once up front: activations do not appear mid-deploy (the new one is
    // applied in the last wave and is kept unconditionally), and the alternative
    // is a LIST per stamped resource. `None` when it cannot be established —
    // callers must then merge without pruning.
    let live_activations: Option<HashSet<String>> = match &activation_ar {
        Some(ar) => activation::live_activation_hashes(client, ar).await,
        None => None,
    };

    // Preauthorized delete set for immutable-conflict recovery.
    let orphan_set: HashSet<ResourceId> = orphan_rids.iter().cloned().collect();
    let mut consumed_orphans: HashSet<ResourceId> = HashSet::new();

    // Build scheduler state.
    let mut state = SchedulerState::new(&plan);

    // Shared context for per-node tasks.
    let ctx = Arc::new(NodeCtx {
        client: client.clone(),
        discovery: discovery.clone(),
        activation_hash: activation_identity_hash.map(|s| s.to_string()),
        live_activations: live_activations.clone(),
        force_conflicts: config.force_conflicts,
        cancel: config.cancel.clone(),
        timeout: config.timeout,
        orphan_set: orphan_set.clone(),
    });

    // Batched checkpoint counter.
    let mut terminals_since_checkpoint = 0usize;
    let mut applied_for_checkpoint = 0usize;
    let mut failed_for_checkpoint = 0usize;

    type NodeFuture =
        std::pin::Pin<Box<dyn std::future::Future<Output = (NodeId, NodeOutcome)> + Send>>;
    let mut in_flight: FuturesUnordered<NodeFuture> = FuturesUnordered::new();

    // Promote all initially-ready nodes onto the queue.
    state.seed_ready();

    let mut halting = false; // Set when stop-worthy failure under on_error=Stop.
    let mut halting_reason: Option<String> = None;

    // Unchanged resources still belong to this activation; they just have
    // nothing to apply. Collected here, stamped in one pass once every node is
    // terminal (see `record_activation_on_skipped`).
    let mut skipped: Vec<ResourceId> = Vec::new();

    loop {
        // External cancellation check — cheapest at loop top.
        if config.cancel.is_cancelled() {
            observer.on_event(&DeployEvent::Stopped {
                reason: "cancelled".into(),
            });
            return Err(DeployError::Cancelled { partial: result });
        }

        // Fill in-flight up to concurrency cap.
        while !halting && in_flight.len() < CONCURRENCY {
            let Some(node_id) = state.pop_ready() else {
                break;
            };
            let entry = state.node_entry(&node_id).clone();

            // Skip nodes terminate immediately — no task, no observer Running→Ready
            // round trip beyond two events back-to-back.
            if matches!(entry.kind, TransitionKind::Skip) {
                observer.on_event(&DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Running,
                    detail: None,
                });
                observer.on_event(&DeployEvent::NodeStateChanged {
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
                terminals_since_checkpoint += 1;
                continue;
            }

            // Apply node — emit Running, spawn task.
            observer.on_event(&DeployEvent::NodeStateChanged {
                node: node_id.clone(),
                kind: entry.kind,
                verdict: Verdict::Running,
                detail: None,
            });

            let ctx = ctx.clone();
            let observer_cloned = observer.clone();
            let node_id_c = node_id.clone();
            let fut = async move {
                let out = execute_node(&ctx, &entry, observer_cloned.as_ref()).await;
                (node_id_c, out)
            };
            in_flight.push(Box::pin(fut));
        }

        // Nothing more to schedule and nothing running — we're done.
        if in_flight.is_empty() {
            break;
        }

        // Await the next terminal outcome.
        let Some((node_id, outcome)) = in_flight.next().await else {
            break;
        };

        // Translate outcome into verdict, update result, emit terminal event.
        let entry = state.node_entry(&node_id).clone();
        match outcome {
            NodeOutcome::Ready { apply_action } => {
                match apply_action {
                    ApplyAction::Created => {
                        result.created += 1;
                        applied_for_checkpoint += 1;
                    }
                    ApplyAction::Configured => {
                        result.configured += 1;
                        applied_for_checkpoint += 1;
                    }
                    ApplyAction::Unchanged | ApplyAction::Skipped => {
                        result.unchanged += 1;
                    }
                }
                observer.on_event(&DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Ready,
                    detail: Some(NodeDetail::Applied(apply_action)),
                });
                state.mark_terminal(&node_id, true);

                // If this node is a CRD (or CRD-import target that just
                // materialized), refresh the discovery cache so dependents can
                // find their kinds.
                if is_crd_like(&entry) {
                    observer.on_event(&DeployEvent::CrdRediscovery);
                    if let Ok(new) = fetch::discover_resources(client).await {
                        *discovery.write().await = new;
                    }
                }
            }
            NodeOutcome::Recreated {
                apply_action,
                reason,
            } => {
                if let NodeId::Resource(rid) = &node_id {
                    consumed_orphans.insert(rid.clone());
                }
                match apply_action {
                    ApplyAction::Created => {
                        result.created += 1;
                        applied_for_checkpoint += 1;
                    }
                    ApplyAction::Configured => {
                        result.configured += 1;
                        applied_for_checkpoint += 1;
                    }
                    ApplyAction::Unchanged | ApplyAction::Skipped => {
                        result.unchanged += 1;
                    }
                }
                observer.on_event(&DeployEvent::NodeStateChanged {
                    node: node_id.clone(),
                    kind: entry.kind,
                    verdict: Verdict::Ready,
                    detail: Some(NodeDetail::RecreatedInPlace { reason }),
                });
                state.mark_terminal(&node_id, true);
                if is_crd_like(&entry) {
                    observer.on_event(&DeployEvent::CrdRediscovery);
                    if let Ok(new) = fetch::discover_resources(client).await {
                        *discovery.write().await = new;
                    }
                }
            }
            NodeOutcome::Failed { detail, message } => {
                result.failed += 1;
                failed_for_checkpoint += 1;
                observer.on_event(&DeployEvent::NodeStateChanged {
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
                    observer.on_event(&DeployEvent::NodeStateChanged {
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
                observer.on_event(&DeployEvent::NodeStateChanged {
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

        terminals_since_checkpoint += 1;
        if terminals_since_checkpoint >= CHECKPOINT_BATCH {
            checkpoint(
                client,
                activation_ar.as_ref(),
                activation_name,
                applied_for_checkpoint,
                failed_for_checkpoint,
                false,
            )
            .await;
            terminals_since_checkpoint = 0;
        }
    }

    // Final checkpoint / close-out if the cadence didn't already cover it.
    if terminals_since_checkpoint > 0 {
        checkpoint(
            client,
            activation_ar.as_ref(),
            activation_name,
            applied_for_checkpoint,
            failed_for_checkpoint,
            true,
        )
        .await;
    }

    if halting {
        observer.on_event(&DeployEvent::Stopped {
            reason: halting_reason.unwrap_or_else(|| "halting".into()),
        });
        return Err(DeployError::NodesFailed {
            count: result.failed,
            partial: result,
        });
    }

    // Stamp this activation onto the resources we skipped. They were skipped
    // because their content already matches, not because they left the
    // activation — without this the annotation only ever records the deploys
    // that happened to change a resource, and stable leaves (ServiceAccounts,
    // ConfigMaps, import markers) drift arbitrarily far behind.
    //
    // Best-effort by design, unlike the applied path: nothing was written to
    // these resources, so a failure here leaves the cluster exactly as it was
    // and cannot corrupt the applied state. Failures are counted and reported
    // rather than halting a deploy that otherwise succeeded.
    if let Some(act_hash) = activation_identity_hash
        && !skipped.is_empty()
    {
        let d = discovery.read().await;
        let ar_by_kind: HashMap<String, (ApiResource, Scope)> = d
            .iter()
            .map(|(ar, scope)| (ar.kind.clone(), (ar.clone(), scope.clone())))
            .collect();
        drop(d);

        let live = live_activations.clone().map(Arc::new);
        let mut failures = 0usize;
        for chunk in skipped.chunks(CONCURRENCY) {
            let mut set = tokio::task::JoinSet::new();
            for rid in chunk {
                let Some((ar, scope)) = ar_by_kind.get(&rid.kind).cloned() else {
                    // A skipped resource is by definition live, so its kind
                    // should be in discovery. If it isn't, say so rather than
                    // quietly dropping it from the count.
                    failures += 1;
                    tracing::warn!(resource = %rid.display_id(), "kind not in discovery cache; cannot record activation");
                    continue;
                };
                let client = client.clone();
                let rid = rid.clone();
                let act_hash = act_hash.to_string();
                let live = live.clone();
                set.spawn(async move {
                    apply::record_activation_on_skipped(
                        &client,
                        &ar,
                        scope,
                        &rid,
                        &act_hash,
                        live.as_deref(),
                    )
                    .await
                    .map_err(|e| (rid, e))
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
            tracing::warn!(
                failures,
                total = skipped.len(),
                "kix.dev/activations is incomplete for some unchanged resources; \
                 the deploy itself is unaffected and the next deploy retries"
            );
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
        observer.on_event(&DeployEvent::PruneStart {
            count: ordered.len(),
        });
        let d = discovery.read().await;
        let ar_by_kind: HashMap<String, (ApiResource, Scope)> = d
            .iter()
            .map(|(ar, scope)| (ar.kind.clone(), (ar.clone(), scope.clone())))
            .collect();
        drop(d);

        for rid in &ordered {
            // Warn-only policy: emit a Delete/Skipped event-ish and move on.
            // For now we skip rendering the per-orphan detail under WarnOnly;
            // callers can opt into actual deletion.
            if config.prune == PrunePolicy::WarnOnly {
                continue;
            }
            if rid.kind == "Namespace" {
                // Same policy as the legacy reconcile: never prune a Namespace
                // automatically — sweep the cluster manually after confirming.
                continue;
            }
            let Some((ar, scope)) = ar_by_kind.get(&rid.kind) else {
                result.failed += 1;
                continue;
            };
            let api: Api<DynamicObject> = match scope {
                Scope::Namespaced => {
                    let ns = if rid.namespace == CLUSTER_SCOPED {
                        "default"
                    } else {
                        rid.namespace.as_str()
                    };
                    Api::namespaced_with(client.clone(), ns, ar)
                }
                Scope::Cluster => Api::all_with(client.clone(), ar),
            };
            let dp = kube::api::DeleteParams {
                propagation_policy: Some(kube::api::PropagationPolicy::Background),
                ..Default::default()
            };
            match api.delete(&rid.name, &dp).await {
                Ok(_) => {
                    result.pruned += 1;
                    // A dedicated prune event would be nicer — fold into
                    // NodeStateChanged for the time being.
                    observer.on_event(&DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(rid.clone()),
                        kind: TransitionKind::Delete,
                        verdict: Verdict::Ready,
                        detail: None,
                    });
                }
                Err(e) => {
                    result.failed += 1;
                    observer.on_event(&DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(rid.clone()),
                        kind: TransitionKind::Delete,
                        verdict: Verdict::Failed {
                            message: e.to_string(),
                        },
                        detail: None,
                    });
                }
            }
        }
    }

    // Finalize Activation lifecycle (unless pure no-op).
    let actually_changed =
        result.created > 0 || result.configured > 0 || result.pruned > 0 || result.failed > 0;
    if actually_changed && let Some(act_name) = activation_name {
        let d = discovery.read().await;
        if let Some((ar, _)) = activation::find_activation_ar(&d) {
            let ar = ar.clone();
            drop(d);
            let old_activation = activation::find_active(client, &ar, cluster_name)
                .await
                .ok()
                .flatten()
                .filter(|old| old.name != act_name);
            let had_failures = result.failed > 0;
            if let Err(e) = activation::finalize_deploy(
                client,
                &ar,
                cluster_name,
                act_name,
                old_activation.as_ref(),
                had_failures,
            )
            .await
            {
                tracing::warn!("failed to finalize activation lifecycle: {e}");
            } else {
                observer.on_event(&DeployEvent::Finalized {
                    activation: act_name.to_string(),
                    previous: old_activation.map(|a| a.name),
                });
            }
        }
    }

    Ok(result)
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
    client: Client,
    discovery: Arc<RwLock<Vec<(ApiResource, Scope)>>>,
    activation_hash: Option<String>,
    /// Identity hashes of every Activation CR on the cluster, used to prune
    /// dead entries out of `kix.dev/activations`. `None` = do not prune.
    live_activations: Option<HashSet<String>>,
    force_conflicts: bool,
    cancel: CancelToken,
    timeout: Duration,
    orphan_set: HashSet<ResourceId>,
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

async fn execute_node(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    observer: &dyn DeployObserver,
) -> NodeOutcome {
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

    // Hydrate SOPS secrets before apply.
    let manifest = if secrets::needs_hydration(&manifest) {
        let mut single = [manifest];
        match secrets::hydrate_secrets(&mut single) {
            Ok(results) => {
                for hr in &results {
                    observer.on_event(&DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(hr.rid.clone()),
                        kind: TransitionKind::Apply,
                        verdict: Verdict::Running,
                        detail: Some(NodeDetail::SecretHydrated {
                            keys: hr.keys_injected,
                        }),
                    });
                }
                single.into_iter().next().unwrap()
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

    // Snapshot discovery. Dependents of a CRD don't run until the CRD has
    // reached Ready (including a post-Established discovery probe in
    // readiness.rs), so by the time we execute a node whose kind exists,
    // it will normally be in the cache. Import markers bypass this via
    // their own bootstrap in readiness.
    //
    // Safety net: HA apiservers can serve discovery from different replicas
    // with a few hundred ms of skew, so even after our probe the local
    // cache may briefly lack the kind. Retry-on-miss with a live refresh
    // before failing the node.
    let lookup_kind = if rid.kind == "PackageInstance" {
        "PackageInstance"
    } else {
        rid.kind.as_str()
    };
    let (ar, scope) = 'resolve: {
        const RETRIES: u32 = 4;
        const INTERVAL: Duration = Duration::from_millis(500);
        for attempt in 0..=RETRIES {
            {
                let d = ctx.discovery.read().await;
                if let Some((ar, scope)) = d.iter().find(|(ar, _)| ar.kind == lookup_kind) {
                    break 'resolve (ar.clone(), scope.clone());
                }
            }
            if attempt == RETRIES {
                break;
            }
            tracing::debug!(
                kind = %lookup_kind,
                attempt = attempt + 1,
                "kind missing from discovery cache, refreshing"
            );
            if let Ok(new) = fetch::discover_resources(&ctx.client).await {
                *ctx.discovery.write().await = new;
            }
            tokio::time::sleep(INTERVAL).await;
        }
        let msg = if lookup_kind == "PackageInstance" {
            "PackageInstance kind not discovered".to_string()
        } else {
            format!("kind {} not in discovery cache", rid.kind)
        };
        return NodeOutcome::Failed {
            detail: NodeDetail::ApplyFailed(msg.clone()),
            message: msg,
        };
    };

    // Apply.
    let applied_action: ApplyAction;
    let mut recreated_reason: Option<String> = None;
    match apply::apply_resource(
        &ctx.client,
        &ar,
        scope.clone(),
        &manifest,
        false,
        ctx.activation_hash.as_deref(),
        ctx.live_activations.as_ref(),
        ctx.force_conflicts,
    )
    .await
    {
        Ok(result) => {
            applied_action = result.action;
        }
        Err(ApplyError::ImmutableConflict { source, .. }) if ctx.orphan_set.contains(&rid) => {
            let reason = source.to_string();
            // Lift from reconcile.rs.
            let d = ctx.discovery.read().await;
            let disc_snap: Vec<(ApiResource, Scope)> = d.clone();
            drop(d);
            match recreate_in_place(
                &ctx.client,
                &disc_snap,
                &rid,
                &manifest,
                ctx.force_conflicts,
                ctx.activation_hash.as_deref(),
                ctx.live_activations.as_ref(),
            )
            .await
            {
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
    observer.on_event(&DeployEvent::NodeStateChanged {
        node: NodeId::Resource(rid.clone()),
        kind: TransitionKind::Apply,
        verdict: Verdict::Running,
        detail: Some(NodeDetail::Applied(applied_action.clone())),
    });

    // Wait for readiness.
    let import_target: Option<ImportTarget> = entry.meta.import_target.clone();

    if import_target.is_none() && readiness::is_immediate_kind(&rid.kind) {
        return match recreated_reason {
            Some(reason) => NodeOutcome::Recreated {
                apply_action: applied_action,
                reason,
            },
            None => NodeOutcome::Ready {
                apply_action: applied_action,
            },
        };
    }

    // For non-import kinds we need an ApiResource in discovery for the poll.
    let outcome = {
        let rid_clone = rid.clone();
        let import_for_status = import_target.clone();
        let on_status = |msg: &str| {
            observer.on_event(&DeployEvent::NodeStateChanged {
                node: NodeId::Resource(rid_clone.clone()),
                kind: TransitionKind::Apply,
                verdict: Verdict::Running,
                detail: Some(NodeDetail::ReadinessProgress(msg.to_string())),
            });
            let _ = &import_for_status; // import target is carried on the node, not per-event
        };
        if let Some(target) = &import_target {
            readiness::wait_for_import_target(
                &ctx.client,
                target,
                ctx.timeout,
                &ctx.cancel,
                on_status,
            )
            .await
        } else {
            let ns = if rid.namespace == CLUSTER_SCOPED {
                None
            } else {
                Some(rid.namespace.as_str())
            };
            readiness::wait_for_ready(
                &ctx.client,
                &ar,
                &scope,
                &rid.name,
                ns,
                &rid.kind,
                ctx.timeout,
                &ctx.cancel,
                on_status,
            )
            .await
        }
    };

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
        ReadinessResult::Ready => match recreated_reason {
            Some(reason) => NodeOutcome::Recreated {
                apply_action: applied_action,
                reason,
            },
            None => NodeOutcome::Ready {
                apply_action: applied_action,
            },
        },
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

/// Wall-clock bound for waiting on the live resource to disappear during an
/// immutable-conflict recreate. Independent of the readiness timeout —
/// deletion should be near-instant; anything longer usually means stuck
/// finalizers, which we surface rather than mask.
const RECREATE_DELETE_TIMEOUT: Duration = Duration::from_secs(30);

/// Kind-aware propagation policy for in-place recreate. Jobs foreground-delete
/// so the old pods are gone before we re-apply. StatefulSets orphan-delete so
/// PVCs are retained. Everything else uses Background (kubectl default).
pub fn delete_propagation_for(kind: &str) -> kube::api::PropagationPolicy {
    match kind {
        "Job" => kube::api::PropagationPolicy::Foreground,
        "StatefulSet" => kube::api::PropagationPolicy::Orphan,
        _ => kube::api::PropagationPolicy::Background,
    }
}

/// Delete the live resource identified by `rid`, wait for it to disappear,
/// then re-apply `manifest`. The caller must have already verified the rid
/// is authorized for deletion (i.e. present in the orphan set).
pub async fn recreate_in_place(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    rid: &ResourceId,
    manifest: &Value,
    force_conflicts: bool,
    activation_hash: Option<&str>,
    live_activations: Option<&HashSet<String>>,
) -> Result<ApplyResult, String> {
    let Some((ar, scope)) = discovery.iter().find(|(ar, _)| ar.kind == rid.kind) else {
        return Err(format!("kind {} not in discovery cache", rid.kind));
    };
    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            let ns = if rid.namespace == CLUSTER_SCOPED {
                "default"
            } else {
                &rid.namespace
            };
            Api::namespaced_with(client.clone(), ns, ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), ar),
    };

    let dp = kube::api::DeleteParams {
        propagation_policy: Some(delete_propagation_for(&rid.kind)),
        ..Default::default()
    };
    api.delete(&rid.name, &dp)
        .await
        .map_err(|e| format!("delete failed: {e}"))?;

    // Poll for deletion. Transient API errors are treated as "probably gone"
    // since the delete itself succeeded; any real problem re-surfaces on the
    // re-apply below.
    let deadline = std::time::Instant::now() + RECREATE_DELETE_TIMEOUT;
    while std::time::Instant::now() < deadline {
        match api.get_opt(&rid.name).await {
            Ok(None) => break,
            Ok(Some(_)) => tokio::time::sleep(Duration::from_millis(500)).await,
            Err(e) => {
                tracing::debug!(resource = %rid, error = %e, "transient error polling deletion; assuming gone");
                break;
            }
        }
    }

    apply::apply_resource(
        client,
        ar,
        scope.clone(),
        manifest,
        false,
        activation_hash,
        live_activations,
        force_conflicts,
    )
    .await
    .map_err(|e| format!("re-apply failed: {e}"))
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

async fn checkpoint(
    client: &Client,
    activation_ar: Option<&ApiResource>,
    activation_name: Option<&str>,
    applied: usize,
    failed: usize,
    finalizing: bool,
) {
    let (Some(ar), Some(name)) = (activation_ar, activation_name) else {
        return;
    };
    // Synthesize a single "wave" record until the Activation CR schema moves
    // to per-node progress. Stage A is deliberately non-resuming; the batch
    // still gives the operator a liveness pulse.
    let record = WaveRecord {
        wave_index: 0,
        status: if finalizing {
            WaveStatus::Complete
        } else {
            WaveStatus::Pending
        },
        resource_count: applied + failed,
        applied,
        failed,
    };
    let _ = activation::record_waves(client, ar, name, &[record]).await;
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
