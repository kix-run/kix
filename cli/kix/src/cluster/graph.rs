//! DAG construction from kix.run/depends-on annotations.
//!
//! Parses annotated manifests to build a dependency graph.
//! Used for wave computation (deploy ordering) and visualization (kix graph).

use crate::manifest::keys;
use crate::manifest::types::ResourceId;
use petgraph::graph::{DiGraph, NodeIndex};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum GraphError {
    #[error(
        "deployment dependencies form a cycle involving {0}. Remove a circular reference or requires entry so Kix can determine deployment order"
    )]
    CycleDetected(String),

    #[error(
        "{from} depends on a resource with identity hash {hash}, but that resource is missing from the manifest set. Include the dependency or remove the reference"
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
    /// Map from ResourceId to node index for fast lookup.
    id_to_node: HashMap<ResourceId, NodeIndex>,
    /// Map from identity hash to node index (used during construction for edge resolution).
    _hash_to_node: HashMap<String, NodeIndex>,
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

        // Phase 1: Create all nodes
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

        // Phase 2: Create edges from depends-on annotations
        for manifest in manifests {
            let id = ResourceId::from_value(manifest);
            let from_idx = id_to_node[&id];

            if let Some(deps_str) = get_annotation(manifest, keys::DEPENDS_ON) {
                for dep_entry in deps_str
                    .split(',')
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                {
                    // Tagged format: bare hash (implicit), requires:<hash>, extra:<hash>
                    let dep_hash = dep_entry
                        .strip_prefix("requires:")
                        .or_else(|| dep_entry.strip_prefix("extra:"))
                        .unwrap_or(dep_entry);
                    if let Some(&to_idx) = hash_to_node.get(dep_hash) {
                        // Edge: from depends on to
                        graph.add_edge(from_idx, to_idx, ());
                    }
                    // Silently skip dangling deps — they may reference resources
                    // outside this manifest set (e.g., imported instances)
                }
            }
        }

        // Phase 2b: Collapse cross-package edges onto the target package's
        // PackageInstance marker.
        //
        // DISABLED: this rewrite creates dependency cycles whenever two
        // packages reference each other in any direction (PI_A → wA → PI_B →
        // wB → PI_A). The intended semantics ("consumer waits until target
        // package is fully Ready") will be reintroduced as a wave-computation
        // concern via a side-table of package gates, so the literal DAG stays
        // honest and cycles can be detected + degraded gracefully instead of
        // hard-failing graph construction.
        //
        // Context (kept for when this is rewritten): a resource R in package
        // A may carry a direct edge to a specific resource S in package B
        // (e.g. n8n's Ingress → ingress-nginx's IngressClass). The direct
        // edge only gates R on S being applied, not on B being fully Ready.
        // In practice this races the operator that reconciles R (controller
        // Deployment, admission webhook, etc.).
        /*
        {
            // Build package name → PackageInstance node map.
            let mut package_to_pi: HashMap<String, NodeIndex> = HashMap::new();
            for idx in graph.node_indices() {
                let node = &graph[idx];
                if node.id.kind == crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND
                    && let Some(pkg) = get_annotation(&node.manifest, keys::PACKAGE)
                {
                    package_to_pi.insert(pkg, idx);
                }
            }

            // Collect edges to add in a separate pass so we don't mutate the
            // graph while iterating its edges.
            let mut edges_to_add: Vec<(NodeIndex, NodeIndex)> = Vec::new();
            for edge in graph.edge_indices() {
                let (src, dst) = graph.edge_endpoints(edge).unwrap();
                let src_pkg = match get_annotation(&graph[src].manifest, keys::PACKAGE) {
                    Some(p) => p,
                    None => continue,
                };
                let dst_pkg = match get_annotation(&graph[dst].manifest, keys::PACKAGE) {
                    Some(p) => p,
                    None => continue,
                };
                if src_pkg == dst_pkg {
                    continue;
                }
                let dst_pi = match package_to_pi.get(&dst_pkg) {
                    Some(&idx) => idx,
                    None => continue,
                };
                // Skip reflexive: an edge whose src is already the target
                // PI (the edge we'd add is a self-loop) or whose dst is
                // already the target PI (the existing edge is the PI edge).
                if src == dst_pi || dst == dst_pi {
                    continue;
                }
                edges_to_add.push((src, dst_pi));
            }

            // Deduplicate and add, skipping pairs already connected.
            edges_to_add.sort_by_key(|(s, d)| (s.index(), d.index()));
            edges_to_add.dedup();
            for (src, dst_pi) in edges_to_add {
                if !graph.contains_edge(src, dst_pi) {
                    graph.add_edge(src, dst_pi, ());
                }
            }
        }
        */

        // Phase 3: Check for cycles
        if petgraph::algo::is_cyclic_directed(&graph) {
            // Find a node in a cycle for the error message
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

        Ok(ResourceGraph {
            graph,
            id_to_node,
            _hash_to_node: hash_to_node,
        })
    }

    /// Get all nodes (resources) in the graph.
    pub fn nodes(&self) -> impl Iterator<Item = &ResourceNode> {
        self.graph.node_weights()
    }

    /// Get the number of resources in the graph.
    pub fn node_count(&self) -> usize {
        self.graph.node_count()
    }

    /// Get the number of dependency edges.
    pub fn edge_count(&self) -> usize {
        self.graph.edge_count()
    }

    /// Reverse-topological ordering of the resource IDs: every node appears
    /// after all of its dependents. Used for safe deletion / prune ordering
    /// where we must remove consumers before the providers they reference.
    ///
    /// Falls back to the natural (kind, namespace, name) order when the
    /// graph has a cycle — deletion is best-effort anyway, and a cycle among
    /// orphans is not an error we want to propagate.
    pub fn reverse_topo_ids(&self) -> Vec<ResourceId> {
        use petgraph::Direction;
        use std::collections::HashMap;

        let dag = &self.graph;
        // Out-degree in the ResourceGraph model = number of dependencies of a
        // node. Reverse-topo = delete leaves (zero dependents) first, then
        // work inward. We pop nodes with zero *incoming* edges (no dependents
        // left) instead, since our edges point dependent → predecessor.
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

    /// Get the direct dependencies of a resource.
    pub fn dependencies(&self, id: &ResourceId) -> Vec<&ResourceNode> {
        if let Some(&idx) = self.id_to_node.get(id) {
            self.graph
                .neighbors_directed(idx, petgraph::Direction::Outgoing)
                .map(|dep_idx| &self.graph[dep_idx])
                .collect()
        } else {
            vec![]
        }
    }

    /// Get the resources that depend on a given resource.
    pub fn dependents(&self, id: &ResourceId) -> Vec<&ResourceNode> {
        if let Some(&idx) = self.id_to_node.get(id) {
            self.graph
                .neighbors_directed(idx, petgraph::Direction::Incoming)
                .map(|dep_idx| &self.graph[dep_idx])
                .collect()
        } else {
            vec![]
        }
    }

    /// Get a topological ordering of all nodes (dependencies before dependents).
    pub fn topological_order(&self) -> Vec<&ResourceNode> {
        petgraph::algo::toposort(&self.graph, None)
            .expect("cycle check already passed")
            .into_iter()
            .rev() // toposort returns reverse order for our edge direction
            .map(|idx| &self.graph[idx])
            .collect()
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

    /// Serialize the graph as JSON (for --output json).
    pub fn to_json(&self) -> serde_json::Value {
        let nodes: Vec<serde_json::Value> = self
            .graph
            .node_indices()
            .map(|idx| {
                let node = &self.graph[idx];
                let is_import = crate::manifest::lifecycle::is_marker(&node.manifest);
                serde_json::json!({
                    "id": node.id.display_id(),
                    "kind": node.id.kind,
                    "name": node.id.name,
                    "namespace": node.id.namespace,
                    "identityHash": node.identity_hash,
                    "isImport": is_import,
                })
            })
            .collect();

        let edges: Vec<serde_json::Value> = self
            .graph
            .edge_indices()
            .map(|edge| {
                let (from, to) = self.graph.edge_endpoints(edge).unwrap();
                serde_json::json!({
                    "from": self.graph[from].id.display_id(),
                    "to": self.graph[to].id.display_id(),
                })
            })
            .collect();

        serde_json::json!({
            "nodes": nodes,
            "edges": edges,
        })
    }
}

/// Extract an annotation value from a manifest.
fn get_annotation(manifest: &serde_json::Value, key: &str) -> Option<String> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|annotations| annotations.get(key))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    fn manifest(kind: &str, name: &str, ns: &str, id_hash: &str, deps: &str) -> serde_json::Value {
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
            kind: "Deployment".into(),
            namespace: "default".into(),
            name: "my-app".into(),
        };
        let deps = graph.dependencies(&deploy_id);
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

    /// Helper: manifest with a `kix.run/package` annotation set.
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
        // Package A: pi_a, workload_a. Package B: pi_b, consumer_b, where
        // consumer_b has a direct edge to workload_a (cross-package).
        //
        // The graph keeps that direct edge as written and synthesizes no
        // consumer_b → pi_a edge. The PI collapse is disabled (phase 2b): it
        // produced cycles whenever two packages referenced each other. The
        // "wait for the whole package" semantics will come back as a wave
        // gate, not as a DAG edge. This test pins the current contract so
        // the disabled block cannot silently come back half-way.
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
            kind: "Ingress".into(),
            namespace: "ns-b".into(),
            name: "consumer".into(),
        };
        let deps = graph.dependencies(&consumer_id);
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
        // Two resources in the same package: no PI rewrite. The PI edge
        // would collapse to src → (its own PI), which is skipped.
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
            kind: "Deployment".into(),
            namespace: "ns-a".into(),
            name: "dep".into(),
        };
        let deps = graph.dependencies(&dep_id);

        // Deployment depends only on ConfigMap — no extra PI edge (same package).
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].id.name, "cm");
    }

    #[test]
    fn cross_package_edge_duplicate_is_not_added_twice() {
        // Consumer already has a direct edge to pi_a (e.g. because the
        // package author wrote `root = { ...; requires = [ otherPkg ]; }`).
        // The cross-package rewrite must not add a duplicate edge.
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
            kind: "Ingress".into(),
            namespace: "ns-b".into(),
            name: "consumer".into(),
        };
        let deps = graph.dependencies(&consumer_id);
        let pi_a_count = deps.iter().filter(|n| n.id.name == "pkg-a").count();
        assert_eq!(pi_a_count, 1, "PI edge should not be duplicated");
    }

    #[test]
    fn unpackaged_resources_are_not_rewritten() {
        // Activation CR style: no kix.run/package annotation. An edge from
        // an unpackaged node to a packaged resource should not be rewritten,
        // since the src has no package identity.
        let manifests = vec![
            pkg_manifest("Deployment", "controller", "ns-a", "h_wa", "", "pkg-a"),
            pkg_manifest("PackageInstance", "pkg-a", "ns-a", "h_pia", "h_wa", "pkg-a"),
            // No kix.run/package on this one.
            manifest("Activation", "root", CLUSTER_SCOPED, "h_act", "h_wa"),
        ];

        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let act_id = ResourceId {
            kind: "Activation".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "root".into(),
        };
        let deps = graph.dependencies(&act_id);
        // Only the direct edge to controller — no PI rewrite.
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].id.name, "controller");
    }

    #[test]
    fn topological_order() {
        let ns = manifest("Namespace", "default", CLUSTER_SCOPED, "hash_ns", "");
        let sa = manifest("ServiceAccount", "my-sa", "default", "hash_sa", "hash_ns");
        let deploy = manifest("Deployment", "my-app", "default", "hash_deploy", "hash_sa");

        let graph = ResourceGraph::from_manifests(&[ns, sa, deploy]).unwrap();
        let order = graph.topological_order();
        assert_eq!(order.len(), 3);

        let names: Vec<&str> = order.iter().map(|n| n.id.name.as_str()).collect();
        // Namespace must come before SA, SA before Deployment
        let ns_pos = names.iter().position(|&n| n == "default").unwrap();
        let sa_pos = names.iter().position(|&n| n == "my-sa").unwrap();
        let deploy_pos = names.iter().position(|&n| n == "my-app").unwrap();
        assert!(ns_pos < sa_pos);
        assert!(sa_pos < deploy_pos);
    }
}
