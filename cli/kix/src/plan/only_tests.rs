//! `--only`: a plan of the instances it names and what they depend on.
//! Each plan here is of the `kix-enterprise-test` build.

use std::collections::HashSet;

use super::PlanError;
use super::baseline::Baseline;
use super::document::{LeftAlone, PlanFlags};
use super::fixtures::{deployed, flags, kix_enterprise_test, plan};
use crate::cluster::activation::Record;
use crate::cluster::scheduler::LastRuns;
use crate::cluster::stream::NodeId;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::lifecycle;
use crate::manifest::types::ResourceId;
use crate::plan::{CheckedPlan, Work};

const SHOP: &str = "kix-enterprise-test-data/shop";
const STATUS_PAGE: &str = "kix-enterprise-test-web/status-page";

fn only(names: &[&str]) -> PlanFlags {
    PlanFlags {
        only: names.iter().map(|n| n.to_string()).collect(),
        ..flags(&[])
    }
}

/// Mark `baseline` as one the cluster's current record `c-old` names.
fn current(mut baseline: Baseline) -> Baseline {
    baseline.active = Some(Record {
        name: "c-old".into(),
        identity_hash: Some("old".into()),
        ..Default::default()
    });
    baseline
}

/// Return the build without the instance `key`.
fn without(graph: &StoreGraph, key: &str) -> StoreGraph {
    let mut graph = graph.clone();
    let (pi, package) = graph
        .packages
        .iter()
        .find(|(_, p)| format!("{}/{}", p.namespace, p.instance_name) == key)
        .map(|(pi, p)| (pi.clone(), p.clone()))
        .unwrap();
    graph.packages.shift_remove(&pi);
    graph.resources.remove(&pi);
    for path in &package.resource_paths {
        graph.resources.remove(path);
        graph.resource_owner.remove(path);
    }
    graph
}

/// Return the ids of the objects of instance `key` in `graph`, its
/// PackageInstance among them.
fn objects_of(graph: &StoreGraph, key: &str) -> HashSet<ResourceId> {
    let package = graph
        .packages
        .values()
        .find(|p| format!("{}/{}", p.namespace, p.instance_name) == key)
        .unwrap();
    package
        .resource_paths
        .iter()
        .chain([&package.store_path])
        .map(|path| ResourceId::from_value(&graph.resources[path].manifest))
        .collect()
}

fn nodes(checked: &CheckedPlan) -> HashSet<ResourceId> {
    checked
        .plan()
        .nodes()
        .iter()
        .filter_map(|n| match &n.id {
            NodeId::Resource(rid) => Some(rid.clone()),
            NodeId::Synthetic(_) => None,
        })
        .collect()
}

fn writes(checked: &CheckedPlan) -> usize {
    checked
        .plan()
        .nodes()
        .iter()
        .filter_map(|n| n.action.written())
        .filter(|m| !lifecycle::is_record(m))
        .count()
}

/// The plan of one instance holds the instance and everything it depends
/// on, and nothing that depends on it alone: no other instance and no
/// Activation record. Every node it holds is one the instance needs, and
/// the package diff and objects show what it writes and nothing else.
#[test]
fn one_instance_plans_the_instance_and_what_it_depends_on() {
    let build = kix_enterprise_test();
    let baseline = current(Baseline::empty());
    let whole = plan(&baseline, &build, flags(&[])).unwrap();
    let checked = plan(&baseline, &build, only(&[SHOP])).unwrap();

    let held = nodes(&checked);
    let shop = objects_of(&build, SHOP);
    assert!(shop.is_subset(&held), "{shop:?} not in {held:?}");
    assert!(
        objects_of(&build, STATUS_PAGE).is_disjoint(&held),
        "{held:?}"
    );
    assert!(
        !checked
            .plan()
            .nodes()
            .iter()
            .any(|n| matches!(&n.id, NodeId::Resource(r) if r.kind == lifecycle::RECORD_KIND)),
        "the record's node left the plan"
    );
    // Each node is the instance or a predecessor of one held node.
    for (dependent, predecessor) in &checked.plan().edges {
        let (NodeId::Resource(d), NodeId::Resource(p)) = (dependent, predecessor) else {
            continue;
        };
        assert!(held.contains(d) && held.contains(p));
    }

    let left = checked.left_alone().unwrap();
    assert_eq!(
        left,
        LeftAlone {
            writes: writes(&whole) - writes(&checked),
            orphans: 0,
        }
    );
    assert!(left.writes > 0);
    assert_eq!(checked.flags().only, [SHOP]);
    assert!(checked.orphans().is_empty() && checked.consumed_failed().is_empty());

    let written: HashSet<ResourceId> = checked
        .objects()
        .writes
        .iter()
        .map(|w| w.resource_id())
        .collect();
    assert!(written.is_subset(&held));
    assert!(shop.is_subset(&written));
    let diff = checked.pkg_diff();
    assert!(diff.activation.is_none());
    let keys: Vec<&str> = diff.added.iter().map(|p| p.key.as_str()).collect();
    assert!(keys.contains(&SHOP), "{keys:?}");
    assert!(!keys.contains(&STATUS_PAGE), "{keys:?}");
}

/// Two instances plan both, each with what it depends on, and the names
/// are held sorted and once.
#[test]
fn two_instances_plan_both() {
    let build = kix_enterprise_test();
    let baseline = current(Baseline::empty());
    let checked = plan(&baseline, &build, only(&[STATUS_PAGE, SHOP, STATUS_PAGE])).unwrap();
    let held = nodes(&checked);
    for key in [SHOP, STATUS_PAGE] {
        assert!(objects_of(&build, key).is_subset(&held), "{key}");
    }
    assert!(
        objects_of(&build, "kix-enterprise-test-edge/landing").is_disjoint(&held),
        "{held:?}"
    );
    assert_eq!(checked.flags().only, [SHOP, STATUS_PAGE]);
}

/// A name the build has no instance for stops the plan and lists the
/// instances it has.
#[test]
fn an_unknown_instance_is_refused_with_the_valid_names() {
    let build = kix_enterprise_test();
    let baseline = current(Baseline::empty());
    let Err(PlanError::UnknownInstances(e)) = plan(
        &baseline,
        &build,
        only(&[SHOP, "kix-enterprise-test-data/shopp"]),
    ) else {
        panic!("the plan was not refused");
    };
    assert_eq!(e.unknown, ["kix-enterprise-test-data/shopp"]);
    let message = e.to_string();
    assert!(
        message.contains("has no instance 'kix-enterprise-test-data/shopp'"),
        "{message}"
    );
    assert!(message.contains(&format!("    {SHOP}\n")), "{message}");
    assert!(message.contains(&format!("    {STATUS_PAGE}")), "{message}");
}

/// `--only` on a cluster with no current record is refused: the first
/// deploy installs the record's kind and must be of the whole build.
#[test]
fn only_is_refused_on_a_first_deploy() {
    let build = kix_enterprise_test();
    let err = plan(&Baseline::empty(), &build, only(&[SHOP]))
        .err()
        .unwrap();
    assert!(matches!(err, PlanError::OnlyFirstDeploy(_)), "{err}");
    assert!(
        err.to_string().contains("kix deploy kix-enterprise-test`"),
        "{err}"
    );
}

/// `--only` on a cluster whose current record the operator deployed is
/// refused: the operator would repair that build over this deploy.
#[test]
fn only_is_refused_while_the_operator_keeps_the_current_build() {
    let build = kix_enterprise_test();
    let mut baseline = current(Baseline::empty());
    baseline.active.as_mut().unwrap().operator_driven = true;
    let err = plan(&baseline, &build, only(&[SHOP])).err().unwrap();
    assert!(
        matches!(&err, PlanError::OnlyUnderOperator { record, .. } if record == "c-old"),
        "{err}"
    );
}

/// An instance the new build leaves unchanged gives a plan with nothing to
/// do, while the rest of the build waits. A plan with `--only` folds in what
/// failed deploys applied, and supersedes none of them.
#[test]
fn an_unchanged_instance_has_nothing_to_do() {
    let build = kix_enterprise_test();
    let mut baseline = current(deployed(Some(&without(&build, STATUS_PAGE))));
    baseline.failed.consumed = vec!["c-failed".into()];
    let checked = plan(&baseline, &build, only(&[SHOP])).unwrap();
    assert_eq!(writes(&checked), 0);
    assert_eq!(
        checked.work(&LastRuns::Read { failed: vec![] }),
        Work::Nothing
    );
    assert!(checked.consumed_failed().is_empty());
    assert!(
        checked.objects().writes.is_empty(),
        "{:?}",
        checked.objects()
    );
    let left = checked.left_alone().unwrap();
    assert_eq!(left.writes, objects_of(&build, STATUS_PAGE).len());

    let checked = plan(&baseline, &build, only(&[STATUS_PAGE])).unwrap();
    assert_eq!(writes(&checked), objects_of(&build, STATUS_PAGE).len());
    assert_eq!(checked.left_alone().unwrap().writes, 0);
}

/// Orphans of the whole build are left for the deploy that finishes it:
/// the plan neither deletes nor lists them, and counts them.
#[test]
fn orphans_are_left_for_a_later_deploy() {
    let build = kix_enterprise_test();
    let baseline = current(deployed(Some(&build)));
    let smaller = without(&build, STATUS_PAGE);
    let whole = plan(&baseline, &smaller, flags(&["--prune"])).unwrap();
    assert!(!whole.orphans().is_empty());
    let checked = plan(
        &baseline,
        &smaller,
        PlanFlags {
            only: vec![SHOP.into()],
            ..flags(&[])
        },
    )
    .unwrap();
    assert!(checked.orphans().is_empty());
    assert!(checked.objects().deletes.is_empty());
    assert!(checked.pkg_diff().removed.is_empty());
    assert_eq!(checked.left_alone().unwrap().orphans, whole.orphans().len());
}

/// The deploy of the whole build that follows deploys with `--only` folds
/// in what they applied, as it does for a deploy that stopped, writes the
/// rest, and supersedes their record when it finalizes, whether it deploys
/// the same build or another.
#[test]
fn the_whole_build_after_a_partial_deploy_supersedes_it() {
    let build = kix_enterprise_test();
    for new in [
        build.clone(),
        without(&build, "kix-enterprise-test-edge/landing"),
    ] {
        let mut baseline = current(deployed(Some(&without(&build, STATUS_PAGE))));
        baseline.failed.closures = vec![super::fixtures::stamp(&build).1];
        baseline.failed.consumed = vec!["c-new".into()];
        let whole = plan(&baseline, &new, flags(&[])).unwrap();
        assert_eq!(whole.consumed_failed(), ["c-new"]);
        assert!(whole.left_alone().is_none());
        assert!(writes(&whole) >= objects_of(&build, STATUS_PAGE).len());
        let partial = plan(&baseline, &new, only(&[STATUS_PAGE])).unwrap();
        assert!(partial.consumed_failed().is_empty());
    }
}

/// A small build in namespace `lab`: instance `base` with two ConfigMaps,
/// `mid` whose Deployment reads `base-cfg` and ClusterRole `reader`, and
/// `top` whose Deployment needs `mid`'s. ClusterRole `spare` and the
/// Namespace belong to no instance.
mod chain {
    use std::path::PathBuf;

    use serde_json::{Value, json};

    use super::*;
    use crate::eval::store_graph::{PackageNode, ResourceNode};
    use crate::manifest::keys;

    fn path(seed: &str, name: &str) -> PathBuf {
        PathBuf::from(format!("/nix/store/{seed:0<32}-k8s-{name}"))
    }

    fn hash(seed: &str) -> String {
        format!("{seed:0<32}")
    }

    fn manifest(kind: &str, name: &str, namespaced: bool, deps: &[&str]) -> Value {
        let deps: Vec<String> = deps.iter().map(|d| hash(d)).collect();
        let mut metadata = json!({
            "name": name,
            "annotations": { (keys::DEPENDS_ON): deps.join(",") },
        });
        if namespaced {
            metadata["namespace"] = json!("lab");
        }
        let api_version = match kind {
            "Deployment" => "apps/v1",
            "ClusterRole" => "rbac.authorization.k8s.io/v1",
            "PackageInstance" => keys::API_VERSION,
            _ => "v1",
        };
        let mut m = json!({ "apiVersion": api_version, "kind": kind, "metadata": metadata });
        if kind == "PackageInstance" {
            m["spec"] = json!({ "instanceName": name, "namespaceName": "lab" });
        }
        m
    }

    fn add(
        graph: &mut StoreGraph,
        seed: &str,
        kind: &str,
        name: &str,
        namespaced: bool,
        deps: &[&str],
    ) -> PathBuf {
        let p = path(seed, &format!("{kind}-{name}"));
        graph.resources.insert(
            p.clone(),
            ResourceNode {
                store_path: p.clone(),
                manifest: manifest(kind, name, namespaced, deps),
            },
        );
        p
    }

    /// Add instance `name` with a PackageInstance seeded `pi` and the
    /// objects `objects` (seed, kind, name, dependencies).
    fn instance(
        graph: &mut StoreGraph,
        name: &str,
        pi: &str,
        objects: &[(&str, &str, &str, &[&str])],
    ) {
        let pi_path = add(graph, pi, "PackageInstance", name, true, &["ns"]);
        let mut paths = Vec::new();
        for (seed, kind, object, deps) in objects {
            let p = add(graph, seed, kind, object, true, deps);
            graph.resource_owner.insert(p.clone(), pi_path.clone());
            paths.push(p);
        }
        paths.push(pi_path.clone());
        graph.packages.insert(
            pi_path.clone(),
            PackageNode {
                store_path: pi_path,
                instance_name: name.to_string(),
                namespace: "lab".to_string(),
                version: None,
                lifecycle: None,
                resource_paths: paths,
                cross_deps: Vec::new(),
            },
        );
    }

    fn build() -> StoreGraph {
        let mut graph = StoreGraph::empty("c");
        add(&mut graph, "ns", "Namespace", "lab", false, &[]);
        add(&mut graph, "reader", "ClusterRole", "reader", false, &[]);
        add(&mut graph, "spare", "ClusterRole", "spare", false, &[]);
        instance(
            &mut graph,
            "base",
            "pibase",
            &[
                ("cfg", "ConfigMap", "base-cfg", &["ns"]),
                ("extra", "ConfigMap", "base-extra", &["ns"]),
            ],
        );
        instance(
            &mut graph,
            "mid",
            "pimid",
            &[("mid", "Deployment", "mid", &["cfg", "reader"])],
        );
        instance(
            &mut graph,
            "top",
            "pitop",
            &[("top", "Deployment", "top", &["mid"])],
        );
        graph
    }

    fn held(names: &[&str]) -> (CheckedPlan, Vec<String>) {
        let checked = plan(&current(Baseline::empty()), &build(), only(names)).unwrap();
        let mut held: Vec<String> = nodes(&checked)
            .into_iter()
            .map(|rid| format!("{}/{}", rid.kind, rid.name))
            .collect();
        held.sort();
        (checked, held)
    }

    /// The instance a named one needs is applied whole, its PackageInstance
    /// and the object nothing references included, and named as needed.
    #[test]
    fn a_needed_instance_is_applied_whole() {
        let (checked, held) = held(&["lab/mid"]);
        assert_eq!(
            held,
            [
                "ClusterRole/reader",
                "ConfigMap/base-cfg",
                "ConfigMap/base-extra",
                "Deployment/mid",
                "Namespace/lab",
                "PackageInstance/base",
                "PackageInstance/mid",
            ]
        );
        assert_eq!(checked.needed(), ["lab/base"]);
        assert_eq!(checked.applied_instances(), ["lab/base", "lab/mid"]);
    }

    /// Down a chain, every instance the named one needs, directly or not,
    /// is applied whole.
    #[test]
    fn a_chain_is_applied_whole() {
        let (checked, held) = held(&["lab/top"]);
        for object in [
            "PackageInstance/base",
            "ConfigMap/base-extra",
            "PackageInstance/mid",
            "Deployment/top",
        ] {
            assert!(held.contains(&object.to_string()), "{object}: {held:?}");
        }
        assert_eq!(checked.needed(), ["lab/base", "lab/mid"]);
    }

    /// Objects outside every instance are taken one by one: the ClusterRole
    /// nothing selected depends on stays out, and nothing needs `top`.
    #[test]
    fn objects_outside_instances_are_not_expanded() {
        let (checked, held) = held(&["lab/base"]);
        assert_eq!(
            held,
            [
                "ConfigMap/base-cfg",
                "ConfigMap/base-extra",
                "Namespace/lab",
                "PackageInstance/base"
            ]
        );
        assert!(checked.needed().is_empty());
        let (_, held) = held_of_mid();
        assert!(!held.contains(&"ClusterRole/spare".to_string()), "{held:?}");
    }

    fn held_of_mid() -> (CheckedPlan, Vec<String>) {
        held(&["lab/mid"])
    }

    /// A name without a namespace that matches an instance's name is
    /// answered with the full name first.
    #[test]
    fn a_name_without_its_namespace_is_suggested() {
        let Err(PlanError::UnknownInstances(e)) =
            plan(&current(Baseline::empty()), &build(), only(&["mid"]))
        else {
            panic!("the plan was not refused");
        };
        let message = e.to_string();
        let lines: Vec<&str> = message.lines().collect();
        assert_eq!(lines[1], "  Did you mean lab/mid?", "{message}");
    }
}
