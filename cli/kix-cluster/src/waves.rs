//! Wave computation for deployment ordering.
//!
//! Uses Kahn's algorithm for level-based topological sort on the resource
//! dependency graph. Wave 0 = resources with no dependencies. Wave N+1 =
//! resources whose dependencies are all in waves 0..N.
//!
//! Within each wave, resources are sorted by kind priority (Namespace first,
//! then CRDs, then ServiceAccounts, etc.) then by name for deterministic ordering.

use petgraph::Direction;
use petgraph::graph::NodeIndex;
use std::collections::HashMap;

use super::graph::ResourceGraph;

/// Compute deployment waves from the resource dependency graph.
///
/// Returns a Vec of waves, where each wave is a Vec of NodeIndex values.
/// Wave 0 contains resources with no dependencies. Each subsequent wave
/// contains resources whose dependencies are all in earlier waves.
///
/// Within each wave, resources are sorted by kind priority then name.
pub fn compute_waves(graph: &ResourceGraph) -> Vec<Vec<NodeIndex>> {
    let dag = &graph.graph;

    if dag.node_count() == 0 {
        return vec![];
    }

    // Compute out-degree for each node (number of dependencies).
    // In this graph, outgoing edges point to dependencies.
    let mut out_degree: HashMap<NodeIndex, usize> = HashMap::new();
    for idx in dag.node_indices() {
        out_degree.insert(
            idx,
            dag.neighbors_directed(idx, Direction::Outgoing).count(),
        );
    }

    // Wave 0: nodes with no dependencies (out-degree 0)
    let mut waves: Vec<Vec<NodeIndex>> = Vec::new();
    let mut current_wave: Vec<NodeIndex> = out_degree
        .iter()
        .filter(|(_, deg)| **deg == 0)
        .map(|(idx, _)| *idx)
        .collect();

    while !current_wave.is_empty() {
        // Sort this wave by kind priority, then name
        current_wave.sort_by(|&a, &b| {
            let node_a = &dag[a];
            let node_b = &dag[b];
            let pri_a = kind_priority(&node_a.id.kind);
            let pri_b = kind_priority(&node_b.id.kind);
            pri_a
                .cmp(&pri_b)
                .then_with(|| node_a.id.namespace.cmp(&node_b.id.namespace))
                .then_with(|| node_a.id.name.cmp(&node_b.id.name))
        });

        // Find next wave: for each node in current wave, decrement out-degree
        // of its dependents (incoming neighbors = nodes that depend on it).
        let mut next_wave = Vec::new();
        for &idx in &current_wave {
            for dependent in dag.neighbors_directed(idx, Direction::Incoming) {
                if let Some(deg) = out_degree.get_mut(&dependent) {
                    *deg -= 1;
                    if *deg == 0 {
                        next_wave.push(dependent);
                    }
                }
            }
        }

        waves.push(current_wave);
        current_wave = next_wave;
    }

    tracing::debug!(waves = waves.len(), "computed deployment waves");

    waves
}

/// Returns the deployment priority for a K8s resource kind.
///
/// Lower numbers are deployed first within a wave.
pub fn kind_priority(kind: &str) -> u32 {
    match kind {
        "Namespace" => 0,
        "NetworkPolicy" | "ResourceQuota" | "LimitRange" => 1,
        "CustomResourceDefinition" => 2,
        "ServiceAccount" => 3,
        "PersistentVolumeClaim" | "PersistentVolume" => 4,
        "ConfigMap" | "Secret" => 5,
        "ClusterRole" | "ClusterRoleBinding" | "Role" | "RoleBinding" => 6,
        "Service" => 7,
        "DaemonSet" | "Deployment" | "StatefulSet" => 8,
        "Job" | "CronJob" => 9,
        "Ingress" | "IngressRoute" => 10,
        _ => 99,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn manifest(kind: &str, name: &str, ns: &str, id_hash: &str, deps: &str) -> serde_json::Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert("kix.dev/identity-hash".into(), json!(id_hash));
        annotations.insert("kix.dev/content-hash".into(), json!("deadbeef"));
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

    /// Helper: get resource names for each wave.
    fn wave_names(graph: &ResourceGraph, waves: &[Vec<NodeIndex>]) -> Vec<Vec<String>> {
        waves
            .iter()
            .map(|wave| {
                wave.iter()
                    .map(|&idx| graph.graph[idx].id.name.clone())
                    .collect()
            })
            .collect()
    }

    /// Helper: get resource kinds for each wave.
    fn wave_kinds(graph: &ResourceGraph, waves: &[Vec<NodeIndex>]) -> Vec<Vec<String>> {
        waves
            .iter()
            .map(|wave| {
                wave.iter()
                    .map(|&idx| graph.graph[idx].id.kind.clone())
                    .collect()
            })
            .collect()
    }

    #[test]
    fn empty_graph_empty_waves() {
        let graph = ResourceGraph::from_manifests(&[]).unwrap();
        let waves = compute_waves(&graph);
        assert!(waves.is_empty());
    }

    #[test]
    fn single_resource_one_wave() {
        let manifests = vec![manifest("Deployment", "app", "default", "h1", "")];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0].len(), 1);
    }

    #[test]
    fn linear_chain_one_per_wave() {
        // ns → sa → deploy (each depends on the previous)
        let manifests = vec![
            manifest("Namespace", "default", "_cluster", "h_ns", ""),
            manifest("ServiceAccount", "my-sa", "default", "h_sa", "h_ns"),
            manifest("Deployment", "my-app", "default", "h_deploy", "h_sa"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);
        let names = wave_names(&graph, &waves);

        assert_eq!(waves.len(), 3);
        assert_eq!(names[0], vec!["default"]);
        assert_eq!(names[1], vec!["my-sa"]);
        assert_eq!(names[2], vec!["my-app"]);
    }

    #[test]
    fn diamond_dependency() {
        // ns → sa, ns → cm, sa+cm → deploy
        let manifests = vec![
            manifest("Namespace", "default", "_cluster", "h_ns", ""),
            manifest("ServiceAccount", "my-sa", "default", "h_sa", "h_ns"),
            manifest("ConfigMap", "my-cm", "default", "h_cm", "h_ns"),
            manifest("Deployment", "my-app", "default", "h_deploy", "h_sa,h_cm"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);
        let names = wave_names(&graph, &waves);

        assert_eq!(waves.len(), 3);
        assert_eq!(names[0], vec!["default"]); // wave 0: namespace
        // wave 1: sa and cm (sorted by kind priority: SA=3 before ConfigMap=5)
        assert_eq!(names[1], vec!["my-sa", "my-cm"]);
        assert_eq!(names[2], vec!["my-app"]); // wave 2: deploy
    }

    #[test]
    fn all_independent_single_wave() {
        let manifests = vec![
            manifest("ConfigMap", "cm-a", "default", "h1", ""),
            manifest("ConfigMap", "cm-b", "default", "h2", ""),
            manifest("ConfigMap", "cm-c", "default", "h3", ""),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);

        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0].len(), 3);
        // Sorted alphabetically by name (same kind)
        let names = wave_names(&graph, &waves);
        assert_eq!(names[0], vec!["cm-a", "cm-b", "cm-c"]);
    }

    #[test]
    fn kind_priority_tiebreaker() {
        // All independent but different kinds — should be sorted by kind priority
        let manifests = vec![
            manifest("Deployment", "app", "default", "h1", ""),
            manifest("ServiceAccount", "sa", "default", "h2", ""),
            manifest("Namespace", "ns", "_cluster", "h3", ""),
            manifest("ConfigMap", "cm", "default", "h4", ""),
            manifest("Service", "svc", "default", "h5", ""),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);
        let kinds = wave_kinds(&graph, &waves);

        assert_eq!(waves.len(), 1);
        assert_eq!(
            kinds[0],
            vec![
                "Namespace",
                "ServiceAccount",
                "ConfigMap",
                "Service",
                "Deployment"
            ]
        );
    }

    #[test]
    fn kind_priority_values() {
        assert_eq!(kind_priority("Namespace"), 0);
        assert_eq!(kind_priority("NetworkPolicy"), 1);
        assert_eq!(kind_priority("CustomResourceDefinition"), 2);
        assert_eq!(kind_priority("ServiceAccount"), 3);
        assert_eq!(kind_priority("PersistentVolumeClaim"), 4);
        assert_eq!(kind_priority("ConfigMap"), 5);
        assert_eq!(kind_priority("Secret"), 5);
        assert_eq!(kind_priority("ClusterRole"), 6);
        assert_eq!(kind_priority("Role"), 6);
        assert_eq!(kind_priority("Service"), 7);
        assert_eq!(kind_priority("Deployment"), 8);
        assert_eq!(kind_priority("StatefulSet"), 8);
        assert_eq!(kind_priority("DaemonSet"), 8);
        assert_eq!(kind_priority("Job"), 9);
        assert_eq!(kind_priority("CronJob"), 9);
        assert_eq!(kind_priority("Ingress"), 10);
        assert_eq!(kind_priority("IngressRoute"), 10);
        assert_eq!(kind_priority("SomethingCustom"), 99);
    }

    #[test]
    fn complex_dag() {
        // Wave 0: ns
        // Wave 1: sa (depends on ns), cm (depends on ns)
        // Wave 2: svc (depends on sa), deploy (depends on sa, cm)
        // Wave 3: ingress (depends on svc)
        let manifests = vec![
            manifest("Namespace", "app", "_cluster", "h_ns", ""),
            manifest("ServiceAccount", "sa", "app", "h_sa", "h_ns"),
            manifest("ConfigMap", "cm", "app", "h_cm", "h_ns"),
            manifest("Service", "svc", "app", "h_svc", "h_sa"),
            manifest("Deployment", "deploy", "app", "h_deploy", "h_sa,h_cm"),
            manifest("Ingress", "ingress", "app", "h_ing", "h_svc"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);
        let names = wave_names(&graph, &waves);

        assert_eq!(waves.len(), 4);
        assert_eq!(names[0], vec!["app"]); // namespace
        assert_eq!(names[1], vec!["sa", "cm"]); // sa (pri 3) before cm (pri 5)
        // wave 2: svc (pri 7) and deploy (pri 8)
        assert_eq!(names[2], vec!["svc", "deploy"]);
        assert_eq!(names[3], vec!["ingress"]);
    }

    #[test]
    fn all_nodes_accounted_for() {
        let manifests = vec![
            manifest("Namespace", "ns", "_cluster", "h1", ""),
            manifest("ServiceAccount", "sa", "ns", "h2", "h1"),
            manifest("ConfigMap", "cm", "ns", "h3", "h1"),
            manifest("Deployment", "app", "ns", "h4", "h2,h3"),
        ];
        let graph = ResourceGraph::from_manifests(&manifests).unwrap();
        let waves = compute_waves(&graph);
        let total: usize = waves.iter().map(|w| w.len()).sum();
        assert_eq!(total, 4);
    }
}
