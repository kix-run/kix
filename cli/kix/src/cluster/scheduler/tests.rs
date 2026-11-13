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

/// A manifest carrying `kix.run/rerun` is tagged Recreate when the diff
/// recreates it, keeps its Apply tag when the diff applies it in place, and
/// keeps its Skip tag, with the manifest attached, when it did not change.
#[test]
fn plan_tags_rerun_manifests() {
    let mut changed = manifest("Job", "probe", "default", "h_probe", "");
    changed["metadata"]["annotations"][keys::RERUN] = json!("on-change");
    let mut moved = manifest("Job", "moved-probe", "default", "h_moved", "");
    moved["metadata"]["annotations"][keys::RERUN] = json!("on-change");
    let mut same = manifest("Job", "old-probe", "default", "h_old", "");
    same["metadata"]["annotations"][keys::RERUN] = json!("on-change");
    let plain = manifest("ConfigMap", "cm", "default", "h_cm", "");
    let manifests = vec![changed.clone(), moved.clone(), same.clone(), plain.clone()];
    let graph = ResourceGraph::from_manifests(&manifests).unwrap();
    let changes = vec![
        ChangeAction::Recreate(changed),
        ChangeAction::Apply(moved),
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
    assert!(matches!(by_name("moved-probe").kind, TransitionKind::Apply));
    assert!(by_name("moved-probe").rerun.is_some());
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
    let plan = DeployPlan::from_graph_and_changes(
        &graph,
        &[crate::cluster::apply::changed(&deploy, None)],
    )
    .unwrap();
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

    let mut state = SchedulerState::new(&plan, true);
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
    let mut state = SchedulerState::new(&plan, true);
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
