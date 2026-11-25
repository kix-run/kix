//! DAG construction from kix.run/depends-on annotations.
//!
//! Parses annotated manifests to build a dependency graph.
//! Used for wave computation (deploy ordering) and visualization (kix graph).

use crate::manifest::keys;
use crate::manifest::types::ResourceId;
use petgraph::graph::{DiGraph, NodeIndex};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum GraphError {
    #[error(
        "deployment dependencies form a cycle involving {0}. Remove a circular reference or requires entry so Kix can determine deployment order"
    )]
    CycleDetected(String),

    #[error(
        "internal error in Kix: a resource dependency is missing from the build\n  \
         This is a bug in Kix or the Kix library. Nothing was applied to the cluster.\n\n  \
         Detail:\n    \
         {from} depends on resource hash {hash}, which is not in the build's manifest set\n\n  \
         Next:\n    \
         {}",
        crate::eval::error::REPORT_A_BUG
    )]
    DanglingDependency { from: String, hash: String },
}

/// A node in the resource dependency graph.
#[derive(Debug, Clone)]
pub struct ResourceNode {
    pub id: ResourceId,
    pub identity_hash: Option<String>,
    pub manifest: serde_json::Value,
}

/// The resource dependency graph.
#[derive(Debug)]
pub struct ResourceGraph {
    pub graph: DiGraph<ResourceNode, ()>,
}

impl ResourceGraph {
    /// Build a dependency graph from annotated manifests.
    ///
    /// Each manifest may have these annotations:
    /// - `kix.run/identity-hash`: 32-char Nix base32 hash
    /// - `kix.run/depends-on`: comma-separated sorted identity hashes
    pub fn from_manifests(manifests: &[serde_json::Value]) -> Result<Self, GraphError> {
        let mut graph = DiGraph::new();
        let mut id_to_node = HashMap::new();
        let mut hash_to_node = HashMap::new();

        // Create nodes before resolving dependency hashes.
        for manifest in manifests {
            let id = ResourceId::from_value(manifest);
            let identity_hash = get_annotation(manifest, keys::IDENTITY_HASH);

            let node = ResourceNode {
                id: id.clone(),
                identity_hash: identity_hash.clone(),
                manifest: manifest.clone(),
            };

            let idx = graph.add_node(node);
            id_to_node.insert(id, idx);
            if let Some(hash) = identity_hash {
                hash_to_node.insert(hash, idx);
            }
        }

        // Create edges from depends-on annotations.
        for manifest in manifests {
            let id = ResourceId::from_value(manifest);
            let from_idx = id_to_node[&id];

            if let Some(deps_str) = get_annotation(manifest, keys::DEPENDS_ON) {
                for dep_hash in keys::depends_on_hashes(&deps_str) {
                    if let Some(&to_idx) = hash_to_node.get(dep_hash) {
                        // Directed edge from dependent to dependency.
                        graph.add_edge(from_idx, to_idx, ());
                    }
                    // Dependencies may refer to imported resources outside this set.
                }
            }
        }

        // Cross-package edges remain attached to their referenced resources.
        // Rewriting them to PackageInstance nodes creates cycles when packages
        // depend on each other.

        if petgraph::algo::is_cyclic_directed(&graph) {
            let cycle_node = petgraph::algo::toposort(&graph, None)
                .err()
                .map(|cycle| graph[cycle.node_id()].id.display_id())
                .unwrap_or_else(|| "unknown".to_string());
            return Err(GraphError::CycleDetected(cycle_node));
        }

        tracing::debug!(
            nodes = graph.node_count(),
            edges = graph.edge_count(),
            "dependency graph built"
        );

        Ok(ResourceGraph { graph })
    }

    /// Get the number of resources in the graph.
    pub fn node_count(&self) -> usize {
        self.graph.node_count()
    }

    /// Get the number of dependency edges.
    pub fn edge_count(&self) -> usize {
        self.graph.edge_count()
    }

    /// Return resource IDs in reverse topological order so every node appears
    /// after all of its dependents.
    ///
    /// Used during pruning to remove consumers before the providers they
    /// reference. Falls back to natural `(kind, namespace, name)` order when
    /// the graph has a cycle.
    pub fn reverse_topo_ids(&self) -> Vec<ResourceId> {
        use petgraph::Direction;
        use std::collections::HashMap;

        let dag = &self.graph;
        // Pop nodes with zero incoming edges (no remaining dependents) first,
        // since edges point from dependent to dependency.
        let mut in_degree: HashMap<_, usize> = dag
            .node_indices()
            .map(|i| (i, dag.neighbors_directed(i, Direction::Incoming).count()))
            .collect();
        let mut ordered = Vec::with_capacity(dag.node_count());
        let mut next: Vec<_> = in_degree
            .iter()
            .filter(|(_, d)| **d == 0)
            .map(|(i, _)| *i)
            .collect();
        next.sort_by(|a, b| {
            let na = &dag[*a];
            let nb = &dag[*b];
            na.id
                .kind
                .cmp(&nb.id.kind)
                .then_with(|| na.id.namespace.cmp(&nb.id.namespace))
                .then_with(|| na.id.name.cmp(&nb.id.name))
        });
        while let Some(idx) = next.pop() {
            ordered.push(dag[idx].id.clone());
            for pred in dag.neighbors_directed(idx, Direction::Outgoing) {
                if let Some(d) = in_degree.get_mut(&pred) {
                    *d = d.saturating_sub(1);
                    if *d == 0 {
                        next.push(pred);
                    }
                }
            }
        }
        // If a cycle left nodes out, append them in natural order so the
        // caller still gets every id.
        if ordered.len() < dag.node_count() {
            let seen: std::collections::HashSet<_> = ordered.iter().cloned().collect();
            for idx in dag.node_indices() {
                let id = dag[idx].id.clone();
                if !seen.contains(&id) {
                    ordered.push(id);
                }
            }
        }
        ordered
    }

    /// Render the graph as a DOT string for Graphviz.
    pub fn to_dot(&self) -> String {
        let mut dot = String::from("digraph kix {\n  rankdir=LR;\n  node [shape=box];\n\n");

        for idx in self.graph.node_indices() {
            let node = &self.graph[idx];
            let label = node.id.display_id();
            if crate::manifest::lifecycle::is_marker(&node.manifest) {
                dot.push_str(&format!(
                    "  \"{}\" [label=\"{} (import)\" style=dashed color=gray];\n",
                    idx.index(),
                    label
                ));
            } else {
                dot.push_str(&format!("  \"{}\" [label=\"{}\"];\n", idx.index(), label));
            }
        }

        dot.push('\n');

        for edge in self.graph.edge_indices() {
            let (from, to) = self.graph.edge_endpoints(edge).unwrap();
            dot.push_str(&format!("  \"{}\" -> \"{}\";\n", from.index(), to.index()));
        }

        dot.push_str("}\n");
        dot
    }

    /// Render the graph as a terminal tree string.
    pub fn to_tree(&self) -> String {
        let mut output = String::new();

        // Find root nodes (no incoming edges / no dependencies)
        let roots: Vec<NodeIndex> = self
            .graph
            .node_indices()
            .filter(|&idx| {
                self.graph
                    .neighbors_directed(idx, petgraph::Direction::Outgoing)
                    .count()
                    == 0
            })
            .collect();

        for (i, &root) in roots.iter().enumerate() {
            let is_last = i == roots.len() - 1;
            self.render_tree_node(&mut output, root, "", is_last, true, &mut vec![]);
        }

        output
    }

    fn render_tree_node(
        &self,
        output: &mut String,
        idx: NodeIndex,
        prefix: &str,
        is_last: bool,
        is_root: bool,
        visited: &mut Vec<NodeIndex>,
    ) {
        if visited.contains(&idx) {
            let connector = if is_last { "└── " } else { "├── " };
            output.push_str(&format!(
                "{}{}{} (circular ref)\n",
                prefix,
                connector,
                self.graph[idx].id.display_id()
            ));
            return;
        }
        visited.push(idx);

        let connector = if is_root {
            ""
        } else if is_last {
            "└── "
        } else {
            "├── "
        };

        let node = &self.graph[idx];
        let suffix = if crate::manifest::lifecycle::is_marker(&node.manifest) {
            " (import)"
        } else {
            ""
        };
        output.push_str(&format!(
            "{}{}{}{}\n",
            prefix,
            connector,
            node.id.display_id(),
            suffix,
        ));

        // Children = resources that depend on this one (incoming edges)
        let children: Vec<NodeIndex> = self
            .graph
            .neighbors_directed(idx, petgraph::Direction::Incoming)
            .collect();

        let child_prefix = if is_root {
            String::new()
        } else if is_last {
            format!("{}    ", prefix)
        } else {
            format!("{}│   ", prefix)
        };

        for (j, &child) in children.iter().enumerate() {
            let child_is_last = j == children.len() - 1;
            self.render_tree_node(output, child, &child_prefix, child_is_last, false, visited);
        }

        visited.pop();
    }

    /// Serialize the graph to the JSON format emitted by `kix graph -o json`.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::to_value(self.listing()).expect("a GraphListing serializes")
    }

    /// Return every node and edge in manifest order.
    pub fn listing(&self) -> GraphListing {
        let nodes = self
            .graph
            .node_indices()
            .map(|idx| {
                let node = &self.graph[idx];
                ListedNode {
                    id: node.id.display_id(),
                    kind: node.id.kind.clone(),
                    group: node.id.group.clone(),
                    name: node.id.name.clone(),
                    namespace: node.id.namespace.clone(),
                    identity_hash: node.identity_hash.clone(),
                    is_import: crate::manifest::lifecycle::is_marker(&node.manifest),
                }
            })
            .collect();
        let edges = self
            .graph
            .edge_indices()
            .map(|edge| {
                let (from, to) = self.graph.edge_endpoints(edge).unwrap();
                ListedEdge {
                    from: self.graph[from].id.display_id(),
                    to: self.graph[to].id.display_id(),
                }
            })
            .collect();
        GraphListing { nodes, edges }
    }
}

/// The dependency graph as data: what `kix graph -o json` prints and
/// a plan file carries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GraphListing {
    pub nodes: Vec<ListedNode>,
    pub edges: Vec<ListedEdge>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListedNode {
    /// [`ResourceId::display_id`]: `Kind.group/name@namespace`, without
    /// `.group` for the core group and `@namespace` for a cluster-scoped
    /// object.
    pub id: String,
    pub kind: String,
    /// The kind's API group. Left out for the core group.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub group: String,
    pub name: String,
    /// `_cluster` for a cluster-scoped object.
    pub namespace: String,
    /// The object's identity hash annotation, by which other objects'
    /// depends-on annotations name it.
    pub identity_hash: Option<String>,
    /// An import marker: an object another package owns, which this build
    /// only depends on.
    pub is_import: bool,
}

/// `from` depends on `to`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ListedEdge {
    pub from: String,
    pub to: String,
}

/// Extract an annotation value from a manifest.
fn get_annotation(manifest: &serde_json::Value, key: &str) -> Option<String> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|annotations| annotations.get(key))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// Return the object a controller manifest stands for: the workload itself,
/// or for an import marker, the workload it imports.
fn controller_id(manifest: &serde_json::Value) -> ResourceId {
    match crate::cluster::readiness::import_target_from_manifest(manifest) {
        Ok(Some(target)) => ResourceId::new(
            crate::manifest::types::api_group(&target.api_version),
            &target.kind,
            target
                .namespace
                .as_deref()
                .unwrap_or(crate::manifest::types::CLUSTER_SCOPED),
            &target.name,
        ),
        _ => ResourceId::from_value(manifest),
    }
}

/// Objects to delete, in an order that deletes each object before the
/// objects it depends on, together with the dependencies of a whole build.
///
/// A delete that does not finish leaves its object on the cluster, and that
/// object may still need what it depends on, such as the operator that must
/// remove its finalizer. [`DeleteOrder::walk`] deletes each object once
/// nothing still undeleted depends on it, runs independent deletes at the
/// same time, and holds back everything a stuck or failed object depends on.
/// Deploy's prune, `kix gc`, and the operator's teardown all walk a
/// `DeleteOrder`.
///
/// The dependencies come from every manifest the order is made from, not only
/// the objects to delete, so a dependency that passes through an object that
/// stays (a custom resource that needs a Job that needs its operator) still
/// orders the deletes and still holds the operator back.
#[derive(Debug, Clone, Default)]
pub struct DeleteOrder {
    ids: Vec<ResourceId>,
    /// The objects each object depends on directly.
    needs: HashMap<ResourceId, Vec<ResourceId>>,
    /// Each object held back, and the object whose delete did not finish
    /// that holds it.
    held: HashMap<ResourceId, ResourceId>,
    /// The controllers of each custom resource whose kind names them, from
    /// its `controller:` dependencies. A controller that is an import marker
    /// is listed as the object the marker stands for.
    controllers: HashMap<ResourceId, Vec<ResourceId>>,
}

/// What [`DeleteOrder::walk`] did with one object.
pub enum Walked<'a, T> {
    /// The object's delete ran and ended with this outcome.
    Done(T),
    /// Not deleted, because this object, whose delete did not finish,
    /// depends on it.
    HeldBack(&'a ResourceId),
    /// Not deleted, because it is part of a dependency cycle, or something
    /// in one depends on it, so no order deletes it after everything that
    /// needs it.
    Cycle,
    /// Not started, because the walk was cancelled.
    NotStarted,
}

impl DeleteOrder {
    /// Order the objects of `manifests` by their `kix.run/depends-on`
    /// annotations, dependents first, and record those dependencies. When
    /// they form a cycle, keep the order of `manifests`; the walk then
    /// reports the objects of the cycle instead of deleting them. Callers
    /// pass every manifest they know and [`DeleteOrder::retain`] the objects
    /// to delete.
    pub fn of_manifests(manifests: &[serde_json::Value]) -> Self {
        let mut by_hash: HashMap<String, ResourceId> = HashMap::new();
        let mut manifest_by_hash: HashMap<String, &serde_json::Value> = HashMap::new();
        for m in manifests {
            if let Some(hash) = get_annotation(m, keys::IDENTITY_HASH) {
                by_hash.insert(hash.clone(), ResourceId::from_value(m));
                manifest_by_hash.insert(hash, m);
            }
        }
        let mut needs: HashMap<ResourceId, Vec<ResourceId>> = HashMap::new();
        let mut controllers: HashMap<ResourceId, Vec<ResourceId>> = HashMap::new();
        for m in manifests {
            let Some(deps) = get_annotation(m, keys::DEPENDS_ON) else {
                continue;
            };
            let id = ResourceId::from_value(m);
            for hash in keys::depends_on_hashes(&deps) {
                if let Some(dep) = by_hash.get(hash)
                    && *dep != id
                {
                    needs.entry(id.clone()).or_default().push(dep.clone());
                }
            }
            let named: Vec<ResourceId> = keys::controller_hashes(&deps)
                .filter_map(|hash| manifest_by_hash.get(hash).map(|c| controller_id(c)))
                .collect();
            if !named.is_empty() {
                controllers.insert(id, named);
            }
        }
        let ids = match ResourceGraph::from_manifests(manifests) {
            Ok(graph) => graph.reverse_topo_ids(),
            Err(_) => manifests.iter().map(ResourceId::from_value).collect(),
        };
        DeleteOrder {
            ids,
            needs,
            held: HashMap::new(),
            controllers,
        }
    }

    /// Return the controllers that the kind of each object names, for the
    /// objects whose kind names any. A delete loop reads them to say which
    /// workload should remove a stuck object's finalizers.
    pub fn controllers(&self) -> &HashMap<ResourceId, Vec<ResourceId>> {
        &self.controllers
    }

    /// Keep `ids` in the order given, with no known dependencies.
    pub fn unordered(ids: Vec<ResourceId>) -> Self {
        DeleteOrder {
            ids,
            ..Self::default()
        }
    }

    pub fn ids(&self) -> &[ResourceId] {
        &self.ids
    }

    /// Append `rid`, with no known dependencies, unless it is listed already.
    pub fn push(&mut self, rid: ResourceId) {
        if !self.ids.contains(&rid) {
            self.ids.push(rid);
        }
    }

    /// Keep only the objects for which `keep` returns true. The dependencies
    /// recorded through the objects removed still count.
    pub fn retain(&mut self, keep: impl FnMut(&ResourceId) -> bool) {
        self.ids.retain(keep);
    }

    /// Hold back every object that `stuck` depends on, directly or through
    /// others, because `stuck` is still on the cluster.
    pub fn hold_back(&mut self, stuck: &ResourceId) {
        let mut queue = vec![stuck.clone()];
        while let Some(rid) = queue.pop() {
            for dep in self.needs.get(&rid).into_iter().flatten() {
                if dep != stuck && !self.held.contains_key(dep) {
                    self.held.insert(dep.clone(), stuck.clone());
                    queue.push(dep.clone());
                }
            }
        }
    }

    /// Return the object whose delete did not finish and that still needs
    /// `rid`, or `None` when nothing holds `rid` back.
    pub fn held_by(&self, rid: &ResourceId) -> Option<&ResourceId> {
        self.held.get(rid)
    }

    /// Return, for each object to delete, the objects to delete that depend
    /// on it, directly or through any other object. An object in a cycle
    /// lists itself.
    fn blockers(&self) -> HashMap<ResourceId, Vec<ResourceId>> {
        let mut dependents: HashMap<&ResourceId, Vec<&ResourceId>> = HashMap::new();
        for (from, deps) in &self.needs {
            for dep in deps {
                dependents.entry(dep).or_default().push(from);
            }
        }
        let deleting: std::collections::HashSet<&ResourceId> = self.ids.iter().collect();
        self.ids
            .iter()
            .map(|rid| {
                let mut seen: std::collections::HashSet<&ResourceId> =
                    std::collections::HashSet::new();
                let mut queue = vec![rid];
                while let Some(next) = queue.pop() {
                    for d in dependents.get(next).into_iter().flatten() {
                        if seen.insert(*d) {
                            queue.push(*d);
                        }
                    }
                }
                let found = seen
                    .into_iter()
                    .filter(|d| deleting.contains(*d))
                    .cloned()
                    .collect();
                (rid.clone(), found)
            })
            .collect()
    }

    /// Delete the objects in order, running up to `limit` deletes at a time.
    ///
    /// An object starts once every object to delete that depends on it is
    /// done, so independent objects run together and a slow or stuck delete
    /// holds up only what it depends on. `start` returns the future that
    /// deletes one object and waits for it to be gone. When `unfinished` says
    /// an outcome left the object on the cluster, everything it depends on is
    /// held back. Because a stuck object holds back everything below it, a
    /// chain of dependencies waits on at most one delete that never
    /// finishes. Stuck deletes wait side by side, `limit` at a time, so the
    /// time a walk spends on them is about one wait budget for every `limit`
    /// of them, plus the deletes that finish along the longest chain.
    ///
    /// `report` hears of each object once, in the order things happen. Once
    /// `cancel` fires, nothing new starts, and the objects not started are
    /// reported as [`Walked::NotStarted`].
    pub async fn walk<T, Fut>(
        &mut self,
        limit: usize,
        cancel: &crate::cluster::cancel::CancelToken,
        mut start: impl FnMut(&ResourceId) -> Fut,
        unfinished: impl Fn(&T) -> bool,
        mut report: impl FnMut(&ResourceId, Walked<'_, T>),
    ) where
        Fut: std::future::Future<Output = T>,
    {
        use futures::stream::{FuturesUnordered, StreamExt};
        let blockers = self.blockers();
        let ids = self.ids.clone();
        let mut done: std::collections::HashSet<ResourceId> = std::collections::HashSet::new();
        let mut started: std::collections::HashSet<ResourceId> = std::collections::HashSet::new();
        let mut running = FuturesUnordered::new();
        loop {
            let mut rescan = !cancel.is_cancelled();
            while rescan {
                rescan = false;
                for rid in &ids {
                    if running.len() >= limit.max(1) {
                        break;
                    }
                    if started.contains(rid) || !blockers[rid].iter().all(|b| done.contains(b)) {
                        continue;
                    }
                    started.insert(rid.clone());
                    if let Some(stuck) = self.held.get(rid).cloned() {
                        report(rid, Walked::HeldBack(&stuck));
                        done.insert(rid.clone());
                        rescan = true;
                        continue;
                    }
                    let fut = start(rid);
                    let rid = rid.clone();
                    running.push(async move { (rid, fut.await) });
                }
            }
            let Some((rid, outcome)) = running.next().await else {
                break;
            };
            if unfinished(&outcome) {
                self.hold_back(&rid);
            }
            report(&rid, Walked::Done(outcome));
            done.insert(rid);
        }
        for rid in ids.iter().filter(|rid| !started.contains(*rid)) {
            if cancel.is_cancelled() {
                report(rid, Walked::NotStarted);
            } else {
                report(rid, Walked::Cycle);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::test_fixtures::manifest;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    /// Return the nodes that `id` depends on.
    fn dependencies<'a>(graph: &'a ResourceGraph, id: &ResourceId) -> Vec<&'a ResourceNode> {
        let dag = &graph.graph;
        dag.node_indices()
            .filter(|&idx| dag[idx].id == *id)
            .flat_map(|idx| dag.neighbors_directed(idx, petgraph::Direction::Outgoing))
            .map(|dep| &dag[dep])
            .collect()
    }

    /// An object whose delete did not finish holds back what it depends on,
    /// directly and through others, and nothing else.
    #[test]
    fn a_stuck_delete_holds_back_what_it_depends_on() {
        let operator = manifest("Deployment", "operator", "ops", "hash_op", "");
        let job = manifest("Job", "check", "ops", "hash_job", "hash_op");
        let cr = manifest("ConfigMap", "resource", "app", "hash_cr", "hash_job");
        let other = manifest("Secret", "other", "app", "hash_other", "");
        let mut order = DeleteOrder::of_manifests(&[operator, job, cr, other]);
        let id = |kind: &str, ns: &str, name: &str| {
            let group = if kind == "Deployment" {
                "apps"
            } else if kind == "Job" {
                "batch"
            } else {
                ""
            };
            ResourceId::new(group, kind, ns, name)
        };
        let ids = order.ids().to_vec();
        let pos = |rid: &ResourceId| ids.iter().position(|r| r == rid).unwrap();
        let (op, job, cr, other) = (
            id("Deployment", "ops", "operator"),
            id("Job", "ops", "check"),
            id("ConfigMap", "app", "resource"),
            id("Secret", "app", "other"),
        );
        assert!(pos(&cr) < pos(&job) && pos(&job) < pos(&op), "{ids:?}");

        order.retain(|rid| *rid != job);
        order.hold_back(&cr);
        assert_eq!(order.held_by(&op), Some(&cr));
        assert_eq!(order.held_by(&job), Some(&cr));
        assert_eq!(order.held_by(&other), None);
        assert_eq!(order.held_by(&cr), None);
    }

    /// A dependency through an object that is not deleted still orders the
    /// walk and still holds back what the stuck object needs: the custom
    /// resource needs a Job that stays, and the Job needs the operator.
    #[tokio::test]
    async fn the_walk_follows_dependencies_through_objects_that_stay() {
        let operator = manifest("Deployment", "operator", "ops", "hash_op", "");
        let job = manifest("Job", "check", "ops", "hash_job", "hash_op");
        let cr = manifest("ConfigMap", "resource", "app", "hash_cr", "hash_job");
        let mut order = DeleteOrder::of_manifests(&[operator, job, cr]);
        let op = ResourceId::new("apps", "Deployment", "ops", "operator");
        let cr = ResourceId::new("", "ConfigMap", "app", "resource");
        order.retain(|rid| *rid == op || *rid == cr);
        let mut seen = Vec::new();
        order
            .walk(
                8,
                &crate::cluster::cancel::CancelToken::new(),
                |rid| {
                    let stuck = rid.name == "resource";
                    async move { stuck }
                },
                |stuck| *stuck,
                |rid, walked| {
                    seen.push(match walked {
                        Walked::Done(stuck) => format!("{} done stuck={stuck}", rid.name),
                        Walked::HeldBack(by) => format!("{} held by {}", rid.name, by.name),
                        Walked::Cycle => format!("{} cycle", rid.name),
                        Walked::NotStarted => format!("{} not started", rid.name),
                    })
                },
            )
            .await;
        assert_eq!(
            seen,
            vec!["resource done stuck=true", "operator held by resource"]
        );
    }

    /// A `controller:` entry names the custom resource's controller, and a
    /// controller that is an import marker is named as the object it
    /// imports. A plain or `requires:` entry for the same object orders the
    /// deletes the same way and names no controller.
    #[test]
    fn controller_entries_name_the_controller() {
        let operator = manifest("Deployment", "operator", "ops", "hash_op", "");
        let marker = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "PackageInstance",
            "metadata": {
                "name": "crd-ref-dns",
                "namespace": "app",
                "annotations": {
                    (keys::IDENTITY_HASH): "hash_marker",
                    (keys::MODE): "import",
                    (keys::IMPORT_KIND): "Deployment",
                    (keys::IMPORT_API_VERSION): "apps/v1",
                    (keys::IMPORT_NAME): "coredns",
                },
            },
        });
        let named = manifest(
            "ConfigMap",
            "named",
            "app",
            "hash_named",
            "controller:hash_op",
        );
        let imported = manifest(
            "ConfigMap",
            "imported",
            "app",
            "hash_imported",
            "controller:hash_marker",
        );
        let plain = manifest(
            "ConfigMap",
            "plain",
            "app",
            "hash_plain",
            "requires:hash_op",
        );
        let order = DeleteOrder::of_manifests(&[operator, marker, named, imported, plain]);
        let id = |name: &str| ResourceId::new("", "ConfigMap", "app", name);
        let op = ResourceId::new("apps", "Deployment", "ops", "operator");
        assert_eq!(
            order.controllers().get(&id("named")),
            Some(&vec![op.clone()])
        );
        assert_eq!(
            order.controllers().get(&id("imported")),
            Some(&vec![ResourceId::new(
                "apps",
                "Deployment",
                "app",
                "coredns"
            )])
        );
        assert_eq!(order.controllers().get(&id("plain")), None);
        let ids = order.ids().to_vec();
        let pos = |rid: &ResourceId| ids.iter().position(|r| r == rid).unwrap();
        assert!(pos(&id("named")) < pos(&op), "{ids:?}");
        assert!(pos(&id("plain")) < pos(&op), "{ids:?}");
    }

    /// Objects in a dependency cycle are reported, not deleted, and the
    /// walk still deletes what does not depend on the cycle.
    #[tokio::test]
    async fn the_walk_reports_a_cycle() {
        let a = manifest("ConfigMap", "a", "app", "hash_a", "hash_b");
        let b = manifest("ConfigMap", "b", "app", "hash_b", "hash_a");
        let c = manifest("ConfigMap", "c", "app", "hash_c", "");
        let mut order = DeleteOrder::of_manifests(&[a, b, c]);
        let mut seen = Vec::new();
        order
            .walk(
                8,
                &crate::cluster::cancel::CancelToken::new(),
                |_| async { false },
                |stuck| *stuck,
                |rid, walked| {
                    seen.push(format!(
                        "{} {}",
                        rid.name,
                        match walked {
                            Walked::Done(_) => "done",
                            Walked::Cycle => "cycle",
                            _ => "other",
                        }
                    ))
                },
            )
            .await;
        seen.sort();
        assert_eq!(seen, vec!["a cycle", "b cycle", "c done"]);
    }

    #[test]
    fn empty_graph() {
        let graph = ResourceGraph::from_manifests(&[]).unwrap();
        assert_eq!(graph.node_count(), 0);
        assert_eq!(graph.edge_count(), 0);
    }

    #[test]
    fn two_nodes_with_dependency() {
        let sa = manifest("ServiceAccount", "my-sa", "default", "hash_sa", "");
        let deploy = manifest("Deployment", "my-app", "default", "hash_deploy", "hash_sa");

        let graph = ResourceGraph::from_manifests(&[sa, deploy]).unwrap();
        assert_eq!(graph.node_count(), 2);
        assert_eq!(graph.edge_count(), 1);

        let deploy_id = ResourceId {
            group: "apps".into(),
            kind: "Deployment".into(),
            namespace: "default".into(),
            name: "my-app".into(),
        };
        let deps = dependencies(&graph, &deploy_id);
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].id.name, "my-sa");
    }

    #[test]
    fn cycle_detection() {
        let a = manifest("Service", "a", "default", "hash_a", "hash_b");
        let b = manifest("Service", "b", "default", "hash_b", "hash_a");

        let result = ResourceGraph::from_manifests(&[a, b]);
        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), GraphError::CycleDetected(_)));
    }

    /// Build a manifest with `kix.run/package` set.
    fn pkg_manifest(
        kind: &str,
        name: &str,
        ns: &str,
        id_hash: &str,
        deps: &str,
        package: &str,
    ) -> serde_json::Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert(keys::IDENTITY_HASH.into(), json!(id_hash));
        annotations.insert(keys::PACKAGE.into(), json!(package));
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
    fn cross_package_edge_is_not_collapsed_to_pi() {
        // Cross-package edges point directly to the referenced resource without
        // synthesizing an edge to the target's `PackageInstance`.
        let manifests = vec![
            pkg_manifest("Deployment", "controller", "ns-a", "h_wa", "", "pkg-a"),
            pkg_manifest("PackageInstance", "pkg-a", "ns-a", "h_pia", "h_wa", "pkg-a"),
            pkg_manifest(
                "Ingress", "consumer", "ns-b", "h_cb",
                "h_wa", // direct cross-package edge to controller
                "pkg-b",
            ),
            pkg_manifest("PackageInstance", "pkg-b", "ns-b", "h_pib", "h_cb", "pkg-b"),
        ];

        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let consumer_id = ResourceId {
            group: String::new(),
            kind: "Ingress".into(),
            namespace: "ns-b".into(),
            name: "consumer".into(),
        };
        let deps = dependencies(&graph, &consumer_id);
        let dep_names: Vec<&str> = deps.iter().map(|n| n.id.name.as_str()).collect();

        assert!(
            dep_names.contains(&"controller"),
            "direct cross-package edge should be preserved"
        );
        assert!(
            !dep_names.contains(&"pkg-a"),
            "no PI edge is synthesized while the phase 2b collapse is disabled"
        );
    }

    #[test]
    fn intra_package_edges_are_not_collapsed() {
        // Intra-package edges point directly to the referenced resource without
        // adding a `PackageInstance` edge.
        let manifests = vec![
            pkg_manifest("ConfigMap", "cm", "ns-a", "h_cm", "", "pkg-a"),
            pkg_manifest("Deployment", "dep", "ns-a", "h_dep", "h_cm", "pkg-a"),
            pkg_manifest(
                "PackageInstance",
                "pkg-a",
                "ns-a",
                "h_pia",
                "h_dep",
                "pkg-a",
            ),
        ];

        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let dep_id = ResourceId {
            group: String::new(),
            kind: "Deployment".into(),
            namespace: "ns-a".into(),
            name: "dep".into(),
        };
        let deps = dependencies(&graph, &dep_id);

        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].id.name, "cm");
    }

    #[test]
    fn cross_package_edge_duplicate_is_not_added_twice() {
        // Explicit edges to a `PackageInstance` are preserved without duplication.
        let manifests = vec![
            pkg_manifest("Deployment", "controller", "ns-a", "h_wa", "", "pkg-a"),
            pkg_manifest("PackageInstance", "pkg-a", "ns-a", "h_pia", "h_wa", "pkg-a"),
            pkg_manifest(
                "Ingress",
                "consumer",
                "ns-b",
                "h_cb",
                "h_wa,h_pia", // already has edge to pi_a
                "pkg-b",
            ),
            pkg_manifest("PackageInstance", "pkg-b", "ns-b", "h_pib", "h_cb", "pkg-b"),
        ];

        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let consumer_id = ResourceId {
            group: String::new(),
            kind: "Ingress".into(),
            namespace: "ns-b".into(),
            name: "consumer".into(),
        };
        let deps = dependencies(&graph, &consumer_id);
        let pi_a_count = deps.iter().filter(|n| n.id.name == "pkg-a").count();
        assert_eq!(pi_a_count, 1, "PI edge should not be duplicated");
    }

    #[test]
    fn unpackaged_resources_are_not_rewritten() {
        // Edges from resources without `kix.run/package` (such as `Activation`)
        // point directly to the referenced resource.
        let manifests = vec![
            pkg_manifest("Deployment", "controller", "ns-a", "h_wa", "", "pkg-a"),
            pkg_manifest("PackageInstance", "pkg-a", "ns-a", "h_pia", "h_wa", "pkg-a"),
            manifest("Activation", "root", CLUSTER_SCOPED, "h_act", "h_wa"),
        ];

        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let act_id = ResourceId {
            group: keys::GROUP.into(),
            kind: "Activation".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "root".into(),
        };
        let deps = dependencies(&graph, &act_id);
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].id.name, "controller");
    }
}
