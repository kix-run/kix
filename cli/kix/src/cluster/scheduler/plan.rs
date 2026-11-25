//! Deploy plan construction and DAG readiness state tracking.

use std::collections::{HashMap, HashSet, VecDeque};

use serde_json::Value;

use crate::manifest::keys;
use crate::manifest::kinds;
use crate::manifest::lifecycle;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::super::apply::{ChangeAction, Deployed, changed, wants_rerun};
use super::super::graph::ResourceGraph;
use super::super::inventory::{Live, LiveObjects};
use super::super::readiness::{self, ImportTarget};
use super::super::stream::{NodeId, NodeMeta, PlanNode, TransitionKind};

/// A single resource or synthetic node paired with the work
/// the scheduler will perform on it.
#[derive(Debug, Clone)]
pub struct PlanNodeEntry {
    pub id: NodeId,
    pub kind: TransitionKind,
    /// The concrete change to apply. For [`TransitionKind::Skip`] this carries
    /// the `ResourceId`. For [`TransitionKind::Apply`] and
    /// [`TransitionKind::Recreate`] it carries the manifest, as
    /// [`ChangeAction::Apply`] and [`ChangeAction::Recreate`].
    pub action: ChangeAction,
    pub meta: NodeMeta,
    /// The manifest when it carries the `kix.run/rerun` annotation. A Job
    /// that runs again is tagged `Recreate`. Any other keeps its `Apply` or
    /// `Skip` tag, and an unchanged one still runs a task that reports a
    /// failed last run.
    pub rerun: Option<Value>,
}

/// What reading the last runs of a plan's Jobs found
/// ([`DeployPlan::read_last_runs`]). Only that read makes one, so code that
/// needs the answer cannot run before the plan has read the cluster.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LastRuns {
    /// Kix read every Job. `failed` lists the Jobs the plan leaves unchanged
    /// whose last run failed. They do not run again, and the run reports
    /// them as failed. A Job under `kix.run/rerun` whose last run failed is
    /// not listed, because the plan now runs it again.
    Read { failed: Vec<ResourceId> },
    /// Kix could not read at least one Job. The run reads it itself, because
    /// the scheduler runs a task for every rerun Job and reads every
    /// unchanged Job (see `skip_reads_live`).
    Unreadable,
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
    /// The controllers that the kind of each object names
    /// ([`super::super::graph::controllers_of`]), which a stuck delete before
    /// a recreate or an apply reports on.
    pub(crate) controllers: HashMap<ResourceId, Vec<ResourceId>>,
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
        let mut by_id: HashMap<ResourceId, &ChangeAction> = HashMap::new();
        for action in changes {
            let rid = match action {
                ChangeAction::Apply(m) | ChangeAction::Recreate(m, _) => ResourceId::from_value(m),
                ChangeAction::Skip(rid) => rid.clone(),
                ChangeAction::Orphan(_) => continue,
            };
            by_id.insert(rid, action);
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
            let action = match by_id.get(&node.id) {
                Some(action @ (ChangeAction::Apply(_) | ChangeAction::Recreate(..))) => {
                    (*action).clone()
                }
                Some(ChangeAction::Skip(rid)) => ChangeAction::Skip(rid.clone()),
                // Default to Skip if a graph node has no matching change action.
                None | Some(ChangeAction::Orphan(_)) => ChangeAction::Skip(node.id.clone()),
            };
            let rerun = wants_rerun(&node.manifest).then(|| node.manifest.clone());
            let kind = match &action {
                ChangeAction::Recreate(..) => TransitionKind::Recreate,
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

        Ok(DeployPlan {
            nodes,
            edges,
            controllers: super::super::graph::controllers_of(manifests()),
        })
    }

    /// Return whether the plan has a Job whose last run decides what the
    /// plan does with it (see [`reads_last_run`]).
    pub(crate) fn reads_last_runs(&self) -> bool {
        self.nodes.iter().any(reads_last_run)
    }

    /// List the Jobs whose last run decides what the plan does with them,
    /// one LIST per kind, and read their last runs
    /// ([`DeployPlan::last_runs_from`]). A plan with no such Job lists
    /// nothing.
    pub(crate) async fn read_last_runs(
        &mut self,
        client: &kube::Client,
        discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
    ) -> LastRuns {
        let jobs: Vec<ResourceId> = self
            .nodes
            .iter()
            .filter(|e| reads_last_run(e))
            .filter_map(|e| match &e.id {
                NodeId::Resource(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect();
        match LiveObjects::list(client, discovery, &jobs).await {
            Ok(live) => self.last_runs_from(&live),
            Err(e) => {
                tracing::debug!(error = %e, "could not list the Jobs whose last run the plan reads");
                LastRuns::Unreadable
            }
        }
    }

    /// Read in `live` the last run of every Job whose last run decides what
    /// the plan does with it, and apply [`DeployPlan::rerun_failed`] to the
    /// Jobs whose last run failed.
    pub(crate) fn last_runs_from(&mut self, live: &LiveObjects) -> LastRuns {
        let mut failed = HashSet::new();
        let mut all_read = true;
        for entry in self.nodes.iter().filter(|e| reads_last_run(e)) {
            let NodeId::Resource(rid) = &entry.id else {
                continue;
            };
            match live.get(rid) {
                Live::Present(obj)
                    if readiness::classify_workload_terminal(&obj.data, rid.group_kind())
                        .is_some() =>
                {
                    failed.insert(rid.clone());
                }
                Live::Unread => all_read = false,
                Live::Present(_) | Live::Absent => {}
            }
        }
        let reported = self.rerun_failed(&failed);
        if all_read {
            LastRuns::Read { failed: reported }
        } else {
            LastRuns::Unreadable
        }
    }

    /// Recreate every Job under `kix.run/rerun` in `failed`, the Jobs whose
    /// last run failed, through [`changed`], which names that reason. Return
    /// the other Jobs in `failed` that the plan leaves unchanged, which the
    /// run reports as failed.
    pub(crate) fn rerun_failed(&mut self, failed: &HashSet<ResourceId>) -> Vec<ResourceId> {
        let mut reported = Vec::new();
        for node in &mut self.nodes {
            let NodeId::Resource(rid) = &node.id else {
                continue;
            };
            if !failed.contains(rid) || node.kind == TransitionKind::Wait {
                continue;
            }
            match &node.rerun {
                Some(rerun) => {
                    let manifest = node.action.written().unwrap_or(rerun).clone();
                    node.action = changed(&manifest, Deployed::RerunHash(None), true);
                    node.kind = TransitionKind::Recreate;
                }
                None if matches!(node.action, ChangeAction::Skip(_)) => {
                    reported.push(rid.clone());
                }
                None => {}
            }
        }
        reported.sort();
        reported
    }

    /// Return the nodes of the plan in graph order.
    pub fn nodes(&self) -> &[PlanNodeEntry] {
        &self.nodes
    }

    /// Build a test plan that applies every manifest as a new object.
    #[cfg(any(test, feature = "test-util"))]
    pub fn applying(manifests: &[Value]) -> Self {
        let graph = ResourceGraph::from_manifests(manifests).expect("a test plan's graph");
        let changes: Vec<ChangeAction> = manifests
            .iter()
            .map(|m| changed(m, Deployed::Nothing, false))
            .collect();
        Self::from_graph_and_changes(&graph, &changes).expect("a test plan's markers")
    }

    pub(super) fn to_plan_nodes(&self) -> Vec<PlanNode> {
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

pub(super) struct SchedulerState {
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
    /// Unchanged nodes that a node with work to do depends on, directly or
    /// through other unchanged nodes. The scheduler reads their live object
    /// before their dependents run; every other unchanged node is ready
    /// without a task.
    checked: HashSet<NodeId>,
}

impl SchedulerState {
    /// `check_unchanged` says whether unchanged nodes that a node with work
    /// depends on are read before their dependents run (`is_checked`). With
    /// it off every unchanged node is ready without a task.
    pub(super) fn new(plan: &DeployPlan, check_unchanged: bool) -> Self {
        let mut entries = HashMap::with_capacity(plan.nodes.len());
        for e in &plan.nodes {
            entries.insert(e.id.clone(), e.clone());
        }
        let mut pending_preds: HashMap<NodeId, usize> =
            entries.keys().map(|id| (id.clone(), 0)).collect();
        let mut dependents: HashMap<NodeId, Vec<NodeId>> = HashMap::new();
        let mut predecessors: HashMap<NodeId, Vec<NodeId>> = HashMap::new();
        for (dep, pred) in &plan.edges {
            if !entries.contains_key(dep) || !entries.contains_key(pred) {
                continue;
            }
            *pending_preds.entry(dep.clone()).or_insert(0) += 1;
            dependents
                .entry(pred.clone())
                .or_default()
                .push(dep.clone());
            predecessors
                .entry(dep.clone())
                .or_default()
                .push(pred.clone());
        }
        let checked = if check_unchanged {
            checked_unchanged(&entries, &predecessors)
        } else {
            HashSet::new()
        };
        Self {
            entries,
            pending_preds,
            dependents,
            ready: VecDeque::new(),
            enqueued: HashSet::new(),
            terminal: HashSet::new(),
            checked,
        }
    }

    /// Return whether the plan leaves `id` unchanged and a node with a task
    /// depends on it, so the scheduler checks its live object first.
    pub(super) fn is_checked(&self, id: &NodeId) -> bool {
        self.checked.contains(id)
    }

    pub(super) fn seed_ready(&mut self) {
        let zero_pred: Vec<NodeId> = self
            .pending_preds
            .iter()
            .filter(|(_, c)| **c == 0)
            .map(|(id, _)| id.clone())
            .collect();
        // Sort resource nodes by `(kind, namespace, name)` for deterministic
        // execution in tests.
        let mut zero_pred = zero_pred;
        zero_pred.sort_by_key(NodeId::sort_key);
        for id in zero_pred {
            if self.enqueued.insert(id.clone()) {
                self.ready.push_back(id);
            }
        }
    }

    pub(super) fn pop_ready(&mut self) -> Option<NodeId> {
        self.ready.pop_front()
    }

    pub(super) fn ready_is_empty(&self) -> bool {
        self.ready.is_empty()
    }

    /// Return all nodes that have not yet reached a terminal verdict, in
    /// deterministic order.
    pub(super) fn non_terminal(&self) -> Vec<NodeId> {
        let mut out: Vec<NodeId> = self
            .entries
            .keys()
            .filter(|id| !self.terminal.contains(*id))
            .cloned()
            .collect();
        out.sort_by_key(NodeId::sort_key);
        out
    }

    pub(super) fn node_entry(&self, id: &NodeId) -> &PlanNodeEntry {
        self.entries.get(id).expect("node id must be in plan")
    }

    /// Mark a node terminal. If `success` is true, promote any dependents whose
    /// last predecessor just became ready onto the ready queue.
    pub(super) fn mark_terminal(&mut self, id: &NodeId, success: bool) {
        self.terminal.insert(id.clone());
        if !success {
            return;
        }
        self.promote_dependents(id);
    }

    /// Mark a CRD node terminal without promoting its dependents until the
    /// subsequent discovery refresh completes.
    pub(super) fn mark_terminal_deferred(&mut self, id: &NodeId) {
        self.terminal.insert(id.clone());
    }

    /// Promote every dependent of `id` whose last predecessor is now ready.
    pub(super) fn promote_dependents(&mut self, id: &NodeId) {
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
    pub(super) fn cascade_cancel(&mut self, id: &NodeId) -> Vec<NodeId> {
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

/// Return whether the plan reads the live object of `entry` to learn whether
/// its last run failed: a Job under `kix.run/rerun`, which then runs again,
/// or a Job the plan leaves unchanged, which is then reported.
fn reads_last_run(entry: &PlanNodeEntry) -> bool {
    entry.kind != TransitionKind::Wait && (entry.rerun.is_some() || skip_reads_live(entry))
}

/// Return whether a `Skip` node still reads its live object before it counts
/// as unchanged. Every Job does: an unchanged Job is never applied again, so
/// a run that failed would otherwise read as healthy on every later deploy
/// and reconcile. The run reports such a Job as failed. The plan recreates a
/// Job carrying `kix.run/rerun` whose last run it saw fail
/// ([`DeployPlan::rerun_failed`]), so only one that failed after the plan, or
/// one left by a plan that did not read last runs (the operator's repair or
/// resume of a running build), is reported here.
pub(super) fn skip_reads_live(entry: &PlanNodeEntry) -> bool {
    match (&entry.action, &entry.rerun) {
        (ChangeAction::Skip(_), Some(_)) => true,
        (ChangeAction::Skip(rid), None) => rid.group_kind() == kinds::JOB,
        _ => false,
    }
}

/// Return whether the scheduler runs a task for `entry` because of the plan
/// alone: it applies, recreates, or waits for the object, or it is an
/// unchanged probe Job the rerun rule may create again.
pub(super) fn runs_task(entry: &PlanNodeEntry) -> bool {
    entry.kind != TransitionKind::Skip || entry.rerun.is_some()
}

/// Return the unchanged nodes that a node with a task depends on, directly
/// or through other unchanged nodes. An unchanged object that nothing in the
/// deploy depends on cannot mislead anything, so it is not read. An
/// unchanged Job under `kix.run/rerun` runs a task of its own, so the walk
/// does not go past it, but it is in the set so that what depends on it
/// waits for a run still in progress.
fn checked_unchanged(
    entries: &HashMap<NodeId, PlanNodeEntry>,
    predecessors: &HashMap<NodeId, Vec<NodeId>>,
) -> HashSet<NodeId> {
    let mut checked = HashSet::new();
    let mut queue: VecDeque<&NodeId> = entries
        .values()
        .filter(|e| runs_task(e))
        .map(|e| &e.id)
        .collect();
    while let Some(id) = queue.pop_front() {
        for pred in predecessors.get(id).into_iter().flatten() {
            let Some(entry) = entries.get(pred) else {
                continue;
            };
            if entry.kind == TransitionKind::Skip
                && checked.insert(pred.clone())
                && !runs_task(entry)
            {
                queue.push_back(pred);
            }
        }
    }
    checked
}

pub(super) fn is_crd_like(entry: &PlanNodeEntry) -> bool {
    match &entry.id {
        NodeId::Resource(rid) if rid.group_kind() == kinds::CUSTOM_RESOURCE_DEFINITION => true,
        _ => entry
            .meta
            .import_target
            .as_ref()
            .is_some_and(|t| t.group_kind() == kinds::CUSTOM_RESOURCE_DEFINITION),
    }
}
