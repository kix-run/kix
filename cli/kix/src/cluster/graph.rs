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
                for dep_entry in deps_str
                    .split(',')
                    .map(|s| s.trim())
                    .filter(|s| !s.is_empty())
                {
                    // Dependencies may be bare hashes or prefixed with `requires:` or `extra:`.
                    let dep_hash = dep_entry
                        .strip_prefix("requires:")
                        .or_else(|| dep_entry.strip_prefix("extra:"))
                        .unwrap_or(dep_entry);
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
    /// `Kind/name@namespace`, or `Kind/name` for a cluster-scoped object.
    pub id: String,
    pub kind: String,
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

#[cfg(test)]
mod tests {
    use super::*;
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
            group: String::new(),
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
            group: String::new(),
            kind: "Activation".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "root".into(),
        };
        let deps = dependencies(&graph, &act_id);
        assert_eq!(deps.len(), 1);
        assert_eq!(deps[0].id.name, "controller");
    }
}
