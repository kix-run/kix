//! DAG construction from kix.dev/depends-on annotations.
//!
//! Parses annotated manifests to build a dependency graph.
//! Used for wave computation (deploy ordering) and visualization (kix graph).

use crate::manifest::types::ResourceId;
use petgraph::graph::{DiGraph, NodeIndex};
use std::collections::HashMap;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum GraphError {
    #[error("dependency cycle detected involving {0}")]
    CycleDetected(String),

    #[error(
        "dangling dependency: {from} depends on identity hash {hash} which does not map to any resource"
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
    /// - `kix.dev/identity-hash`: 32-char Nix base32 hash
    /// - `kix.dev/depends-on`: comma-separated sorted identity hashes
    pub fn from_manifests(manifests: &[serde_json::Value]) -> Result<Self, GraphError> {
        let mut graph = DiGraph::new();
        let mut id_to_node = HashMap::new();
        let mut hash_to_node = HashMap::new();

        // Phase 1: Create all nodes
        for manifest in manifests {
            let id = ResourceId::from_value(manifest);
            let identity_hash = get_annotation(manifest, "kix.dev/identity-hash");

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

            if let Some(deps_str) = get_annotation(manifest, "kix.dev/depends-on") {
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
            let is_import =
                get_annotation(&node.manifest, "kix.dev/mode").as_deref() == Some("import");
            if is_import {
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
        let is_import = get_annotation(&node.manifest, "kix.dev/mode").as_deref() == Some("import");
        let suffix = if is_import { " (import)" } else { "" };
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
                let is_import =
                    get_annotation(&node.manifest, "kix.dev/mode").as_deref() == Some("import");
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
