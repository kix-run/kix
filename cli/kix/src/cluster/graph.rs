//! DAG construction from kix.run/depends-on annotations and the RBAC
//! bindings that grant a workload's ServiceAccount its rights.
//! Used for wave computation (deploy ordering) and visualization (kix graph).

use crate::manifest::keys;
use crate::manifest::kinds::{self, GroupKind};
use crate::manifest::types::ResourceId;
use crate::manifest::workload;
use kube::api::PropagationPolicy;
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
    /// Build a dependency graph from annotated manifests, with the
    /// dependencies [`dependency_pairs`] finds.
    pub fn from_manifests(manifests: &[serde_json::Value]) -> Result<Self, GraphError> {
        Self::with_pairs(manifests, dependency_pairs(manifests))
    }

    /// Build the graph of `manifests` with the dependencies `pairs` gives,
    /// as indexes into `manifests`, the dependent first.
    fn with_pairs(
        manifests: &[serde_json::Value],
        pairs: Vec<(usize, usize)>,
    ) -> Result<Self, GraphError> {
        let mut graph = DiGraph::new();
        let mut id_to_node = HashMap::new();

        for manifest in manifests {
            let id = ResourceId::from_value(manifest);
            let node = ResourceNode {
                id: id.clone(),
                identity_hash: get_annotation(manifest, keys::IDENTITY_HASH),
                manifest: manifest.clone(),
            };
            let idx = graph.add_node(node);
            id_to_node.insert(id, idx);
        }

        // Each edge points from the dependent to its dependency.
        let node_of = |i: usize| id_to_node[&ResourceId::from_value(&manifests[i])];
        for (from, to) in pairs {
            graph.add_edge(node_of(from), node_of(to), ());
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

/// Return each dependency among `manifests` as a pair of indexes into it,
/// the dependent first. Apply creates a dependency before its dependent and
/// waits for it to be ready, and a delete removes the dependent first.
///
/// Most dependencies are the `kix.run/depends-on` entries that name another
/// manifest of the set. The library writes those from the references in a
/// manifest. Two more come from what Kubernetes does with a manifest,
/// whatever the package wrote, because the object a workload needs names the
/// workload's pods and nothing in the workload names it:
///
/// - A workload depends on each RoleBinding or ClusterRoleBinding whose
///   subjects include the ServiceAccount its pods run as ([`grants`]).
/// - A workload depends on each network policy whose selector matches its
///   pods ([`selecting_policies`]).
///
/// A controller then gets its rights and its network access before it
/// starts, and keeps both while it removes the finalizers of custom resources
/// deleted in the same run.
///
/// An added dependency that the recorded ones already contradict, because its
/// target depends on its dependent directly or through other objects, is left
/// out, because the package recorded the opposite order. An operator that
/// removes the finalizer of a binding it manages for its own ServiceAccount is
/// one case.
pub fn dependency_pairs(manifests: &[serde_json::Value]) -> Vec<(usize, usize)> {
    let mut added = grants(manifests);
    added.extend(selecting_policies(manifests));
    with_added(manifests, recorded_pairs(manifests), added)
}

/// Return the pairs of [`dependency_pairs`], and the pairs that order only
/// deletes: a webhook configuration is deleted before each Service of the set
/// that its webhooks call ([`webhook_services`]), so the API server never
/// calls a webhook that has nothing behind it. These pairs do not order
/// apply, because a configuration often has to exist before what serves it
/// can start, for example when a controller writes the webhook's certificate
/// into it.
pub fn removal_pairs(manifests: &[serde_json::Value]) -> Vec<(usize, usize)> {
    with_added(
        manifests,
        dependency_pairs(manifests),
        webhook_services(manifests),
    )
}

/// Return the pairs of each `kix.run/depends-on` entry that names another
/// manifest of `manifests`. An entry may name an imported object outside
/// the set.
fn recorded_pairs(manifests: &[serde_json::Value]) -> Vec<(usize, usize)> {
    let mut by_hash: HashMap<String, usize> = HashMap::new();
    for (i, m) in manifests.iter().enumerate() {
        if let Some(hash) = get_annotation(m, keys::IDENTITY_HASH) {
            by_hash.insert(hash, i);
        }
    }
    let mut pairs = Vec::new();
    for (i, m) in manifests.iter().enumerate() {
        if let Some(deps) = get_annotation(m, keys::DEPENDS_ON) {
            pairs.extend(
                keys::depends_on_hashes(&deps).filter_map(|hash| Some((i, *by_hash.get(hash)?))),
            );
        }
    }
    pairs
}

/// Return `pairs` with each pair of `added` whose target does not already
/// depend on its dependent, directly or through other pairs.
fn with_added(
    manifests: &[serde_json::Value],
    mut pairs: Vec<(usize, usize)>,
    mut added: Vec<(usize, usize)>,
) -> Vec<(usize, usize)> {
    let mut graph: DiGraph<(), ()> = DiGraph::new();
    let nodes: Vec<NodeIndex> = manifests.iter().map(|_| graph.add_node(())).collect();
    for &(from, to) in &pairs {
        graph.add_edge(nodes[from], nodes[to], ());
    }
    added.sort_unstable();
    added.dedup();
    for (from, to) in added {
        if !petgraph::algo::has_path_connecting(&graph, nodes[to], nodes[from], None) {
            graph.add_edge(nodes[from], nodes[to], ());
            pairs.push((from, to));
        }
    }
    pairs.sort_unstable();
    pairs.dedup();
    pairs
}

/// Return a pair for each workload and each RoleBinding or ClusterRoleBinding
/// whose subjects include the ServiceAccount the workload's pods run as
/// (`default` when the pod spec names none). The binding names the
/// ServiceAccount, but nothing in the pod spec names the binding.
fn grants(manifests: &[serde_json::Value]) -> Vec<(usize, usize)> {
    let mut bindings: HashMap<(&str, &str), Vec<usize>> = HashMap::new();
    for (i, m) in manifests.iter().enumerate() {
        let gk = GroupKind::of_manifest(m);
        if gk != kinds::ROLE_BINDING && gk != kinds::CLUSTER_ROLE_BINDING {
            continue;
        }
        let own_namespace = namespace_of(m);
        for subject in m
            .get("subjects")
            .and_then(|s| s.as_array())
            .into_iter()
            .flatten()
        {
            if subject.get("kind").and_then(|k| k.as_str()) != Some("ServiceAccount") {
                continue;
            }
            let Some(name) = subject.get("name").and_then(|n| n.as_str()) else {
                continue;
            };
            // The API server requires a namespace on a ServiceAccount
            // subject, so the binding's own namespace only stands in for a
            // manifest that has not been through it.
            let Some(namespace) = subject
                .get("namespace")
                .and_then(|n| n.as_str())
                .or(own_namespace)
            else {
                continue;
            };
            bindings.entry((namespace, name)).or_default().push(i);
        }
    }
    let mut pairs = Vec::new();
    for (i, m) in manifests.iter().enumerate() {
        let Some(spec) = workload::pod_spec(m) else {
            continue;
        };
        let account = spec
            .get("serviceAccountName")
            .or_else(|| spec.get("serviceAccount"))
            .and_then(|n| n.as_str())
            .unwrap_or("default");
        let Some(namespace) = namespace_of(m) else {
            continue;
        };
        for &binding in bindings.get(&(namespace, account)).into_iter().flatten() {
            pairs.push((i, binding));
        }
    }
    pairs
}

/// Return a pair for each workload and each NetworkPolicy,
/// CiliumNetworkPolicy, or CiliumClusterwideNetworkPolicy whose pod selector
/// matches the labels of the workload's pod template, unless its pods use the
/// host network, which network policies do not cover. A policy that selects
/// a pod limits what it may reach and adds what other policies allow it, so
/// the pod needs every such policy while it runs, a namespace's default deny
/// included. Apply creates them before the pods start, and a delete removes
/// them only after the pods are gone.
fn selecting_policies(manifests: &[serde_json::Value]) -> Vec<(usize, usize)> {
    let policies: Vec<(usize, PolicyScope<'_>, &serde_json::Value)> = manifests
        .iter()
        .enumerate()
        .filter_map(|(i, m)| {
            let gk = GroupKind::of_manifest(m);
            let (scope, selector) = if gk == kinds::NETWORK_POLICY {
                (
                    PolicyScope::Namespace(namespace_of(m)?),
                    m.pointer("/spec/podSelector")?,
                )
            } else if gk == CILIUM_NETWORK_POLICY {
                (
                    PolicyScope::Namespace(namespace_of(m)?),
                    m.pointer("/spec/endpointSelector")?,
                )
            } else if gk == CILIUM_CLUSTERWIDE_NETWORK_POLICY {
                (PolicyScope::Cluster, m.pointer("/spec/endpointSelector")?)
            } else {
                return None;
            };
            Some((i, scope, selector))
        })
        .collect();
    let mut pairs = Vec::new();
    for (i, m) in manifests.iter().enumerate() {
        // Network policies do not apply to pods on the host network.
        let Some(spec) = workload::pod_spec(m) else {
            continue;
        };
        if spec.get("hostNetwork").and_then(|h| h.as_bool()) == Some(true) {
            continue;
        }
        let Some(namespace) = namespace_of(m) else {
            continue;
        };
        let labels = pod_labels(m);
        for (policy, scope, selector) in &policies {
            let in_scope = match scope {
                PolicyScope::Namespace(ns) => *ns == namespace,
                PolicyScope::Cluster => true,
            };
            if in_scope && selector_matches(selector, &labels, namespace) {
                pairs.push((i, *policy));
            }
        }
    }
    pairs
}

const CILIUM_NETWORK_POLICY: GroupKind<'static> =
    GroupKind::new("cilium.io", "CiliumNetworkPolicy");
const CILIUM_CLUSTERWIDE_NETWORK_POLICY: GroupKind<'static> =
    GroupKind::new("cilium.io", "CiliumClusterwideNetworkPolicy");

/// Where a network policy selects pods.
enum PolicyScope<'a> {
    /// Only in this namespace.
    Namespace(&'a str),
    /// In every namespace.
    Cluster,
}

/// Return the labels of the pod template of a workload, or of a Pod.
fn pod_labels(manifest: &serde_json::Value) -> HashMap<&str, &str> {
    let path = match GroupKind::of_manifest(manifest) {
        kinds::POD => "/metadata/labels",
        kinds::CRON_JOB => "/spec/jobTemplate/spec/template/metadata/labels",
        _ => "/spec/template/metadata/labels",
    };
    manifest
        .pointer(path)
        .and_then(|l| l.as_object())
        .into_iter()
        .flatten()
        .filter_map(|(k, v)| Some((k.as_str(), v.as_str()?)))
        .collect()
}

/// Return whether the label selector `selector` matches a pod with `labels`
/// in `namespace`. An empty selector matches every pod. Cilium writes a label
/// with its source as a prefix: `k8s:` and `any:` name a pod label, and
/// `k8s:io.kubernetes.pod.namespace` the pod's namespace. A label of another
/// source, such as `reserved:`, names something other than a pod, so it
/// matches none.
fn selector_matches(
    selector: &serde_json::Value,
    labels: &HashMap<&str, &str>,
    namespace: &str,
) -> bool {
    let value_of = |key: &str| -> Option<Option<&str>> {
        // A Kubernetes label key holds no `:`, so one marks a Cilium source.
        let key = match key.split_once(':') {
            Some(("k8s" | "any", rest)) => rest,
            Some(_) => return None,
            None => key,
        };
        if key == "io.kubernetes.pod.namespace" {
            return Some(Some(namespace));
        }
        Some(labels.get(key).copied())
    };
    let match_labels = selector
        .get("matchLabels")
        .and_then(|l| l.as_object())
        .into_iter()
        .flatten()
        .all(|(k, v)| match value_of(k) {
            Some(Some(found)) => Some(found) == v.as_str(),
            _ => false,
        });
    let match_expressions = selector
        .get("matchExpressions")
        .and_then(|e| e.as_array())
        .into_iter()
        .flatten()
        .all(|e| {
            let Some(found) = e.get("key").and_then(|k| k.as_str()).and_then(value_of) else {
                return false;
            };
            let values: Vec<&str> = e
                .get("values")
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
                .filter_map(|v| v.as_str())
                .collect();
            match e.get("operator").and_then(|o| o.as_str()) {
                Some("In") => found.is_some_and(|f| values.contains(&f)),
                Some("NotIn") => found.is_none_or(|f| !values.contains(&f)),
                Some("Exists") => found.is_some(),
                Some("DoesNotExist") => found.is_none(),
                _ => false,
            }
        });
    match_labels && match_expressions
}

/// Return a pair for each ValidatingWebhookConfiguration or
/// MutatingWebhookConfiguration and each Service of the set that one of its
/// webhooks calls through `clientConfig.service`. A webhook that the API
/// server calls while its Service has no pods behind it fails every request
/// it covers when its `failurePolicy` is `Fail`.
fn webhook_services(manifests: &[serde_json::Value]) -> Vec<(usize, usize)> {
    let services: HashMap<(&str, &str), usize> = manifests
        .iter()
        .enumerate()
        .filter(|(_, m)| GroupKind::of_manifest(m) == kinds::SERVICE)
        .filter_map(|(i, m)| {
            let name = m.pointer("/metadata/name")?.as_str()?;
            Some(((namespace_of(m)?, name), i))
        })
        .collect();
    let mut pairs = Vec::new();
    for (i, m) in manifests.iter().enumerate() {
        let gk = GroupKind::of_manifest(m);
        if gk != kinds::VALIDATING_WEBHOOK_CONFIGURATION
            && gk != kinds::MUTATING_WEBHOOK_CONFIGURATION
        {
            continue;
        }
        for webhook in m
            .get("webhooks")
            .and_then(|w| w.as_array())
            .into_iter()
            .flatten()
        {
            let Some(service) = webhook.pointer("/clientConfig/service") else {
                continue;
            };
            let field = |key: &str| service.get(key).and_then(|v| v.as_str());
            if let (Some(namespace), Some(name)) = (field("namespace"), field("name"))
                && let Some(&target) = services.get(&(namespace, name))
            {
                pairs.push((i, target));
            }
        }
    }
    pairs
}

fn namespace_of(manifest: &serde_json::Value) -> Option<&str> {
    manifest
        .pointer("/metadata/namespace")
        .and_then(|n| n.as_str())
        .filter(|n| !n.is_empty())
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

/// Return the controllers that the kind of each object of `manifests` names,
/// from its `controller:` entries of `kix.run/depends-on`, for the objects
/// whose kind names any. A controller that is an import marker is listed as
/// the object the marker stands for. An entry whose manifest is not in
/// `manifests` is skipped.
pub fn controllers_of<'a>(
    manifests: impl IntoIterator<Item = &'a serde_json::Value>,
) -> HashMap<ResourceId, Vec<ResourceId>> {
    let manifests: Vec<&serde_json::Value> = manifests.into_iter().collect();
    let by_hash: HashMap<String, &serde_json::Value> = manifests
        .iter()
        .filter_map(|m| Some((get_annotation(m, keys::IDENTITY_HASH)?, *m)))
        .collect();
    manifests
        .iter()
        .filter_map(|m| {
            let deps = get_annotation(m, keys::DEPENDS_ON)?;
            let named: Vec<ResourceId> = keys::controller_hashes(&deps)
                .filter_map(|hash| by_hash.get(hash).map(|c| controller_id(c)))
                .collect();
            (!named.is_empty()).then(|| (ResourceId::from_value(m), named))
        })
        .collect()
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
    /// Order the objects of `manifests` by the dependencies
    /// [`removal_pairs`] finds, dependents first, and record those dependencies. When
    /// they form a cycle, keep the order of `manifests`; the walk then
    /// reports the objects of the cycle instead of deleting them. Callers
    /// pass every manifest they know and [`DeleteOrder::retain`] the objects
    /// to delete.
    pub fn of_manifests(manifests: &[serde_json::Value]) -> Self {
        let pairs = removal_pairs(manifests);
        let mut needs: HashMap<ResourceId, Vec<ResourceId>> = HashMap::new();
        for &(from, to) in &pairs {
            let id = ResourceId::from_value(&manifests[from]);
            let dep = ResourceId::from_value(&manifests[to]);
            if dep != id {
                needs.entry(id).or_default().push(dep);
            }
        }
        let ids = match ResourceGraph::with_pairs(manifests, pairs) {
            Ok(graph) => graph.reverse_topo_ids(),
            Err(_) => manifests.iter().map(ResourceId::from_value).collect(),
        };
        DeleteOrder {
            ids,
            needs,
            held: HashMap::new(),
            controllers: controllers_of(manifests.iter()),
        }
    }

    /// Return the controllers that the kind of each object names, for the
    /// objects whose kind names any. A delete loop reads them to say which
    /// workload should remove a stuck object's finalizers.
    pub fn controllers(&self) -> &HashMap<ResourceId, Vec<ResourceId>> {
        &self.controllers
    }

    /// Return how to delete `rid`. An object whose kind names a controller
    /// is deleted in the foreground. Kubernetes then keeps it until the
    /// objects the controller made for it, and that block their owner's
    /// deletion, are gone. So the order keeps the controller until it has
    /// cleaned up those objects too, such as a pending ACME Challenge under a
    /// Certificate. Other objects are deleted in the background, so their
    /// delete does not wait for their pods to stop.
    pub fn propagation(&self, rid: &ResourceId) -> PropagationPolicy {
        if self.controllers.contains_key(rid) {
            PropagationPolicy::Foreground
        } else {
            PropagationPolicy::Background
        }
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

    /// Return `m` with `field` set at the JSON pointer `path`.
    fn with(mut m: serde_json::Value, path: &str, field: serde_json::Value) -> serde_json::Value {
        let mut at = &mut m;
        for key in path.trim_start_matches('/').split('/') {
            at = &mut at[key];
        }
        *at = field;
        m
    }

    fn rbac(kind: &str, name: &str, ns: &str, hash: &str, deps: &str) -> serde_json::Value {
        with(
            manifest(kind, name, ns, hash, deps),
            "/apiVersion",
            json!("rbac.authorization.k8s.io/v1"),
        )
    }

    fn binding(
        kind: &str,
        name: &str,
        ns: &str,
        hash: &str,
        deps: &str,
        sa: (&str, &str),
    ) -> serde_json::Value {
        with(
            rbac(kind, name, ns, hash, deps),
            "/subjects",
            json!([{ "kind": "ServiceAccount", "name": sa.1, "namespace": sa.0 }]),
        )
    }

    fn runs_as(m: serde_json::Value, sa: &str) -> serde_json::Value {
        with(
            m,
            "/spec/template/spec",
            json!({ "serviceAccountName": sa, "containers": [] }),
        )
    }

    fn rbac_id(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId::new("rbac.authorization.k8s.io", kind, ns, name)
    }

    /// The controller of a custom resource whose delete does not finish
    /// keeps the bindings that grant its ServiceAccount rights, and the roles
    /// they bind, although nothing in the controller names them. A binding
    /// for another ServiceAccount is not held.
    #[test]
    fn a_held_controller_keeps_the_rights_of_its_service_account() {
        let sa = manifest("ServiceAccount", "operator", "ops", "hash_sa", "");
        let operator = runs_as(
            manifest("Deployment", "operator", "ops", "hash_op", "hash_sa"),
            "operator",
        );
        let cluster_role = rbac("ClusterRole", "operator", CLUSTER_SCOPED, "hash_cr", "");
        let cluster_binding = binding(
            "ClusterRoleBinding",
            "operator",
            CLUSTER_SCOPED,
            "hash_crb",
            "hash_cr,hash_sa",
            ("ops", "operator"),
        );
        let role = rbac("Role", "leader-election", "ops", "hash_role", "");
        let role_binding = binding(
            "RoleBinding",
            "leader-election",
            "ops",
            "hash_rb",
            "hash_role,hash_sa",
            ("ops", "operator"),
        );
        let other_binding = binding(
            "RoleBinding",
            "other",
            "ops",
            "hash_other",
            "",
            ("ops", "someone-else"),
        );
        let resource = manifest(
            "ConfigMap",
            "resource",
            "app",
            "hash_res",
            "controller:hash_op",
        );
        let mut order = DeleteOrder::of_manifests(&[
            sa,
            operator,
            cluster_role,
            cluster_binding,
            role,
            role_binding,
            other_binding,
            resource,
        ]);
        let resource = ResourceId::new("", "ConfigMap", "app", "resource");
        order.hold_back(&resource);
        for held in [
            ResourceId::new("apps", "Deployment", "ops", "operator"),
            ResourceId::new("", "ServiceAccount", "ops", "operator"),
            rbac_id("ClusterRoleBinding", CLUSTER_SCOPED, "operator"),
            rbac_id("ClusterRole", CLUSTER_SCOPED, "operator"),
            rbac_id("RoleBinding", "ops", "leader-election"),
            rbac_id("Role", "ops", "leader-election"),
        ] {
            assert_eq!(order.held_by(&held), Some(&resource), "{held}");
        }
        assert_eq!(order.held_by(&rbac_id("RoleBinding", "ops", "other")), None);
    }

    /// A workload is applied after the bindings that grant its ServiceAccount
    /// rights, and deleted before them. A pod spec that names no
    /// ServiceAccount runs as `default`. A binding in another namespace, or
    /// for another ServiceAccount, adds no dependency.
    #[test]
    fn a_workload_depends_on_the_bindings_of_its_service_account() {
        let workload = runs_as(manifest("Deployment", "web", "app", "hash_web", ""), "web");
        let plain = with(
            manifest("Job", "job", "app", "hash_job", ""),
            "/spec/template/spec",
            json!({ "containers": [] }),
        );
        let manifests = [
            workload,
            plain,
            binding("RoleBinding", "web", "app", "hash_rb", "", ("app", "web")),
            binding(
                "RoleBinding",
                "default",
                "app",
                "hash_def",
                "",
                ("app", "default"),
            ),
            binding(
                "RoleBinding",
                "elsewhere",
                "other",
                "hash_else",
                "",
                ("other", "web"),
            ),
            binding(
                "ClusterRoleBinding",
                "nobody",
                CLUSTER_SCOPED,
                "hash_no",
                "",
                ("app", "nobody"),
            ),
        ];
        let names = |i: usize| {
            manifests[i]["metadata"]["name"]
                .as_str()
                .unwrap()
                .to_string()
        };
        let pairs: Vec<(String, String)> = dependency_pairs(&manifests)
            .into_iter()
            .map(|(from, to)| (names(from), names(to)))
            .collect();
        assert_eq!(
            pairs,
            vec![
                ("web".to_string(), "web".to_string()),
                ("job".to_string(), "default".to_string()),
            ]
        );

        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let web = ResourceId::new("apps", "Deployment", "app", "web");
        let deps: Vec<&str> = dependencies(&graph, &web)
            .iter()
            .map(|n| n.id.name.as_str())
            .collect();
        assert_eq!(deps, vec!["web"]);
        let ids = DeleteOrder::of_manifests(&manifests).ids().to_vec();
        let pos = |rid: &ResourceId| ids.iter().position(|r| r == rid).unwrap();
        assert!(
            pos(&web) < pos(&rbac_id("RoleBinding", "app", "web")),
            "{ids:?}"
        );
    }

    /// A binding that the build lists as depending on the workload, such as
    /// one whose finalizer the workload removes, keeps that order, and the
    /// workload gets no dependency on it, so the graph has no cycle.
    #[test]
    fn a_binding_that_depends_on_its_workload_keeps_the_recorded_order() {
        let sa = manifest("ServiceAccount", "operator", "ops", "hash_sa", "");
        let operator = runs_as(
            manifest("Deployment", "operator", "ops", "hash_op", "hash_sa"),
            "operator",
        );
        let managed = binding(
            "RoleBinding",
            "managed",
            "app",
            "hash_managed",
            "hash_sa,requires:hash_op",
            ("ops", "operator"),
        );
        let own = binding(
            "RoleBinding",
            "own",
            "ops",
            "hash_own",
            "hash_sa",
            ("ops", "operator"),
        );
        let manifests = [sa, operator, managed, own];
        let graph = ResourceGraph::from_manifests(&manifests).expect("no cycle");
        let op = ResourceId::new("apps", "Deployment", "ops", "operator");
        let mut deps: Vec<String> = dependencies(&graph, &op)
            .iter()
            .map(|n| n.id.to_string())
            .collect();
        deps.sort();
        assert_eq!(
            deps,
            vec![
                rbac_id("RoleBinding", "ops", "own").to_string(),
                ResourceId::new("", "ServiceAccount", "ops", "operator").to_string(),
            ]
        );
    }

    /// When the delete of a custom resource does not finish, every workload
    /// held back with it keeps the bindings that grant its ServiceAccount
    /// rights, and the roles they bind, in the builds of real operator
    /// packages. Their workloads do not name those bindings, so without the
    /// bindings' dependencies prune would delete them while the controller
    /// still has to remove the finalizers. The fixtures are recorded by
    /// `tests/fixtures/operator-graphs/record.sh`.
    #[test]
    fn operator_graphs_keep_the_rights_of_held_workloads() {
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/operator-graphs");
        for cluster in ["cert-manager", "velero", "external-secrets"] {
            let text = std::fs::read_to_string(dir.join(format!("{cluster}.json"))).unwrap();
            let manifests: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
            let base = DeleteOrder::of_manifests(&manifests);
            let resources: Vec<ResourceId> = base.controllers().keys().cloned().collect();
            assert!(
                !resources.is_empty(),
                "{cluster}: no custom resource names a controller"
            );
            let mut unnamed = 0;
            for resource in &resources {
                let mut order = base.clone();
                order.hold_back(resource);
                for workload in manifests.iter().filter(|m| {
                    order.held_by(&ResourceId::from_value(m)) == Some(resource)
                        && crate::manifest::workload::pod_spec(m).is_some()
                }) {
                    let account = crate::manifest::workload::pod_spec(workload).unwrap()
                        ["serviceAccountName"]
                        .as_str()
                        .unwrap_or("default");
                    let namespace = workload["metadata"]["namespace"].as_str().unwrap();
                    let named = get_annotation(workload, keys::DEPENDS_ON).unwrap_or_default();
                    for binding in manifests.iter().filter(|m| {
                        m["subjects"].as_array().is_some_and(|subjects| {
                            subjects.iter().any(|s| {
                                s["kind"] == "ServiceAccount"
                                    && s["name"] == account
                                    && s["namespace"] == namespace
                            })
                        })
                    }) {
                        let id = ResourceId::from_value(binding);
                        assert_eq!(
                            order.held_by(&id),
                            Some(resource),
                            "{cluster}: {id} is deleted while {} still runs",
                            ResourceId::from_value(workload)
                        );
                        let hash = get_annotation(binding, keys::IDENTITY_HASH).unwrap();
                        if !named.contains(&hash) {
                            unnamed += 1;
                        }
                        let role_ref = &binding["roleRef"];
                        if let Some(role) = manifests.iter().find(|m| {
                            m["kind"] == role_ref["kind"]
                                && m["metadata"]["name"] == role_ref["name"]
                                && (m["kind"] == "ClusterRole"
                                    || m["metadata"]["namespace"]
                                        == binding["metadata"]["namespace"])
                        }) {
                            let role = ResourceId::from_value(role);
                            assert_eq!(order.held_by(&role), Some(resource), "{cluster}: {role}");
                        }
                    }
                }
            }
            assert!(
                unnamed > 0,
                "{cluster}: every held binding is named by its workload, so this test checks nothing new"
            );
        }
    }

    /// A webhook configuration depends on the Service of the set that a
    /// webhook calls. A Service in another namespace, a Service not in the
    /// set, and a webhook called by URL add no dependency.
    #[test]
    fn a_webhook_configuration_depends_on_the_service_it_calls() {
        let config = |kind: &str, name: &str, hash: &str, webhooks: serde_json::Value| {
            json!({
                "apiVersion": "admissionregistration.k8s.io/v1",
                "kind": kind,
                "metadata": { "name": name, "annotations": { (keys::IDENTITY_HASH): hash } },
                "webhooks": webhooks,
            })
        };
        let calls = |ns: &str, name: &str| json!({ "clientConfig": { "service": { "namespace": ns, "name": name } } });
        let manifests = [
            manifest("Service", "webhook", "ops", "hash_svc", ""),
            config(
                "ValidatingWebhookConfiguration",
                "validate",
                "hash_v",
                json!([calls("ops", "webhook"), calls("other", "webhook")]),
            ),
            config(
                "MutatingWebhookConfiguration",
                "mutate",
                "hash_m",
                json!([calls("ops", "webhook")]),
            ),
            config(
                "ValidatingWebhookConfiguration",
                "elsewhere",
                "hash_e",
                json!([
                    calls("ops", "missing"),
                    { "clientConfig": { "url": "https://example.com/validate" } },
                ]),
            ),
        ];
        let names = |i: usize| manifests[i]["metadata"]["name"].as_str().unwrap();
        let pairs: Vec<(&str, &str)> = removal_pairs(&manifests)
            .into_iter()
            .map(|(from, to)| (names(from), names(to)))
            .collect();
        assert_eq!(pairs, vec![("validate", "webhook"), ("mutate", "webhook")]);
        assert!(dependency_pairs(&manifests).is_empty());
    }

    /// A controller that writes a webhook's certificate into its
    /// configuration requires the configuration, and the webhook's pods start
    /// only once the certificate exists. Apply does not make the configuration
    /// wait for the webhook's Service, so the controller can start. Delete
    /// still removes the configuration before the Service.
    #[test]
    fn a_webhook_service_orders_deletes_but_not_applies() {
        let config = json!({
            "apiVersion": "admissionregistration.k8s.io/v1",
            "kind": "ValidatingWebhookConfiguration",
            "metadata": { "name": "validate", "annotations": { (keys::IDENTITY_HASH): "hash_v" } },
            "webhooks": [{ "clientConfig": { "service": { "namespace": "ops", "name": "webhook" } } }],
        });
        let manifests = [
            manifest("Deployment", "webhook", "ops", "hash_wd", ""),
            manifest("Service", "webhook", "ops", "hash_svc", "hash_wd"),
            config,
            manifest(
                "Deployment",
                "cert-controller",
                "ops",
                "hash_cc",
                "requires:hash_v",
            ),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).expect("no cycle");
        let config_id = ResourceId::new(
            "admissionregistration.k8s.io",
            "ValidatingWebhookConfiguration",
            CLUSTER_SCOPED,
            "validate",
        );
        assert!(dependencies(&graph, &config_id).is_empty());
        let order = DeleteOrder::of_manifests(&manifests);
        let service = ResourceId::new("", "Service", "ops", "webhook");
        assert_eq!(order.needs[&config_id], vec![service.clone()]);
        let ids = order.ids();
        let pos = |rid: &ResourceId| ids.iter().position(|r| r == rid).unwrap();
        assert!(pos(&config_id) < pos(&service), "{ids:?}");
    }

    /// In the builds of real operator packages, prune deletes each webhook
    /// configuration before the Service it calls, and that Service before the
    /// workload behind it, so the API server never calls a webhook that has
    /// nothing behind it. Some configurations do not name their Service.
    #[test]
    fn operator_graphs_delete_webhook_configurations_before_their_service() {
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/operator-graphs");
        let mut unnamed = 0;
        for cluster in ["cert-manager", "external-secrets"] {
            let text = std::fs::read_to_string(dir.join(format!("{cluster}.json"))).unwrap();
            let manifests: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
            let order = DeleteOrder::of_manifests(&manifests);
            let mut checked = 0;
            for config in manifests.iter().filter(|m| {
                m["kind"]
                    .as_str()
                    .is_some_and(|k| k.ends_with("WebhookConfiguration"))
            }) {
                let config_id = ResourceId::from_value(config);
                let named = get_annotation(config, keys::DEPENDS_ON).unwrap_or_default();
                for webhook in config["webhooks"].as_array().unwrap() {
                    let called = &webhook["clientConfig"]["service"];
                    let service = manifests
                        .iter()
                        .find(|m| {
                            m["kind"] == "Service"
                                && m["metadata"]["name"] == called["name"]
                                && m["metadata"]["namespace"] == called["namespace"]
                        })
                        .unwrap();
                    let service_id = ResourceId::from_value(service);
                    assert!(
                        order.needs[&config_id].contains(&service_id),
                        "{cluster}: {config_id} does not need {service_id}"
                    );
                    let workloads = order.needs[&service_id]
                        .iter()
                        .filter(|d| d.group == "apps")
                        .count();
                    assert!(workloads > 0, "{cluster}: {service_id} needs no workload");
                    let hash = get_annotation(service, keys::IDENTITY_HASH).unwrap();
                    if !named.contains(&hash) {
                        unnamed += 1;
                    }
                    checked += 1;
                }
            }
            assert!(checked > 0, "{cluster}: no webhook calls a Service");
        }
        assert!(
            unnamed > 0,
            "every configuration names its Service, so this test checks nothing new"
        );
    }

    /// In the builds of real operator packages, prune deletes each custom
    /// resource whose kind names a controller in the foreground, and every
    /// other object, the controllers included, in the background.
    #[test]
    fn operator_graphs_delete_custom_resources_in_the_foreground() {
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/operator-graphs");
        for cluster in ["cert-manager", "velero", "external-secrets"] {
            let text = std::fs::read_to_string(dir.join(format!("{cluster}.json"))).unwrap();
            let manifests: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
            let order = DeleteOrder::of_manifests(&manifests);
            let mut foreground = 0;
            for m in &manifests {
                let rid = ResourceId::from_value(m);
                let expected = if order.controllers().contains_key(&rid) {
                    foreground += 1;
                    PropagationPolicy::Foreground
                } else {
                    PropagationPolicy::Background
                };
                assert_eq!(
                    format!("{:?}", order.propagation(&rid)),
                    format!("{expected:?}"),
                    "{cluster}: {rid}"
                );
            }
            assert!(
                foreground > 0,
                "{cluster}: no custom resource names a controller"
            );
        }
    }

    /// A workload depends on each network policy that selects its pods: a
    /// NetworkPolicy or CiliumNetworkPolicy in its namespace, a namespace's
    /// default deny (an empty selector), and a CiliumClusterwideNetworkPolicy
    /// that names its namespace. A policy for other labels, one in another
    /// namespace, and one that selects only `reserved:` entities add nothing.
    #[test]
    fn a_workload_depends_on_the_policies_that_select_its_pods() {
        let policy = |api: &str,
                      kind: &str,
                      name: &str,
                      ns: Option<&str>,
                      field: &str,
                      selector: serde_json::Value| {
            let mut m = json!({
                "apiVersion": api,
                "kind": kind,
                "metadata": { "name": name, "annotations": { (keys::IDENTITY_HASH): format!("hash_{name}") } },
                "spec": { field: selector },
            });
            if let Some(ns) = ns {
                m["metadata"]["namespace"] = json!(ns);
            }
            m
        };
        let np = |name: &str, ns: &str, sel: serde_json::Value| {
            policy(
                "networking.k8s.io/v1",
                "NetworkPolicy",
                name,
                Some(ns),
                "podSelector",
                sel,
            )
        };
        let cnp = |name: &str, ns: &str, sel: serde_json::Value| {
            policy(
                "cilium.io/v2",
                "CiliumNetworkPolicy",
                name,
                Some(ns),
                "endpointSelector",
                sel,
            )
        };
        let ccnp = |name: &str, sel: serde_json::Value| {
            policy(
                "cilium.io/v2",
                "CiliumClusterwideNetworkPolicy",
                name,
                None,
                "endpointSelector",
                sel,
            )
        };
        let web = with(
            manifest("Deployment", "web", "app", "hash_web", ""),
            "/spec/template",
            json!({ "metadata": { "labels": { "app": "web", "tier": "front" } }, "spec": { "containers": [] } }),
        );
        let host = with(
            manifest("DaemonSet", "agent", "app", "hash_agent", ""),
            "/spec/template",
            json!({ "metadata": { "labels": { "app": "web" } }, "spec": { "hostNetwork": true } }),
        );
        let manifests = [
            web,
            np("deny", "app", json!({})),
            cnp(
                "egress",
                "app",
                json!({ "matchLabels": { "k8s:app": "web" } }),
            ),
            np(
                "tier",
                "app",
                json!({ "matchExpressions": [
                { "key": "tier", "operator": "In", "values": ["front", "back"] },
                { "key": "debug", "operator": "DoesNotExist" },
            ] }),
            ),
            ccnp("cluster-dns", json!({})),
            ccnp(
                "app-ns",
                json!({ "matchLabels": { "k8s:io.kubernetes.pod.namespace": "app" } }),
            ),
            np(
                "other-labels",
                "app",
                json!({ "matchLabels": { "app": "db" } }),
            ),
            np("other-ns", "ops", json!({})),
            ccnp(
                "health",
                json!({ "matchLabels": { "reserved:health": "" } }),
            ),
            ccnp(
                "ops-ns",
                json!({ "matchLabels": { "k8s:io.kubernetes.pod.namespace": "ops" } }),
            ),
            host,
        ];
        let names = |i: usize| manifests[i]["metadata"]["name"].as_str().unwrap();
        let mut deps: Vec<&str> = dependency_pairs(&manifests)
            .into_iter()
            .filter(|(from, _)| *from == 0)
            .map(|(_, to)| names(to))
            .collect();
        deps.sort();
        assert_eq!(deps, ["app-ns", "cluster-dns", "deny", "egress", "tier"]);
        let agent = manifests.len() - 1;
        assert!(
            dependency_pairs(&manifests)
                .iter()
                .all(|(from, _)| *from != agent)
        );
    }

    /// In the builds of real operator packages, every network policy that
    /// selects a held controller's pods is held with it, so the controller
    /// keeps its access to the API server while it removes finalizers. Some
    /// of those policies, such as the API-server egress, are not named by the
    /// workload.
    #[test]
    fn operator_graphs_keep_the_policies_of_held_workloads() {
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/operator-graphs");
        let mut unnamed = 0;
        for cluster in ["cert-manager", "velero", "external-secrets"] {
            let text = std::fs::read_to_string(dir.join(format!("{cluster}.json"))).unwrap();
            let manifests: Vec<serde_json::Value> = serde_json::from_str(&text).unwrap();
            let base = DeleteOrder::of_manifests(&manifests);
            // A pair the recorded dependencies contradict is left out, as
            // `dependency_pairs` does: a policy that needs its enforcer's own
            // agent, for example.
            let kept: std::collections::HashSet<(usize, usize)> =
                dependency_pairs(&manifests).into_iter().collect();
            let selects: Vec<(usize, usize)> = selecting_policies(&manifests)
                .into_iter()
                .filter(|p| kept.contains(p))
                .collect();
            assert!(
                !selects.is_empty(),
                "{cluster}: no policy selects a workload"
            );
            for resource in base.controllers().keys() {
                let mut order = base.clone();
                order.hold_back(resource);
                for &(w, p) in &selects {
                    let workload = ResourceId::from_value(&manifests[w]);
                    if order.held_by(&workload) != Some(resource) {
                        continue;
                    }
                    let policy = ResourceId::from_value(&manifests[p]);
                    assert_eq!(
                        order.held_by(&policy),
                        Some(resource),
                        "{cluster}: {policy} is deleted while {workload} still runs"
                    );
                    let named = get_annotation(&manifests[w], keys::DEPENDS_ON).unwrap_or_default();
                    let hash = get_annotation(&manifests[p], keys::IDENTITY_HASH).unwrap();
                    if !named.contains(&hash) {
                        unnamed += 1;
                    }
                }
            }
        }
        assert!(unnamed > 0, "every held policy is named by its workload");
    }

    /// In a rendered build with network policy, cert-manager and the
    /// monitoring module, no network policy records a dependency on a workload
    /// whose pods it selects, so every such pair orders the workload after the
    /// policy. A policy that admits a scraper, or the API server to a webhook,
    /// then stays until the pods it admits to are gone.
    #[test]
    fn no_policy_depends_on_the_pods_it_selects() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/operator-graphs/netpol-eks.json");
        let manifests: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let pairs: std::collections::HashSet<(usize, usize)> =
            dependency_pairs(&manifests).into_iter().collect();
        let selected = selecting_policies(&manifests);
        let name = |i: usize| ResourceId::from_value(&manifests[i]).to_string();
        let skipped: Vec<(String, String)> = selected
            .iter()
            .filter(|p| !pairs.contains(p))
            .map(|&(w, p)| (name(w), name(p)))
            .collect();
        assert!(selected.len() > 20, "{}", selected.len());
        assert!(skipped.is_empty(), "{skipped:#?}");
        let order = DeleteOrder::of_manifests(&manifests);
        let ids = order.ids();
        let pos = |rid: &ResourceId| ids.iter().position(|r| r == rid).unwrap();
        let webhook = ResourceId::new("apps", "Deployment", "cert-manager", "cert-manager-webhook");
        let policy = ResourceId::new(
            "networking.k8s.io",
            "NetworkPolicy",
            "cert-manager",
            "cert-manager-webhook-apiserver-ingress",
        );
        assert!(pos(&webhook) < pos(&policy), "{ids:?}");
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
