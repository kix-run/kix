//! A deploy refuses an object its plan does not show. Each build here is
//! the `kix-enterprise-test` build changed after it was read, past
//! `StoreGraph::validate`, so the objects check alone stands between it
//! and the cluster. The steps are the ones [`super::Planner`] takes.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::PlanError;
use super::document::{Objects, WriteChange};
use super::fixtures::{deployed, flags, plan, stamp};
use super::objects::Unshown;
use crate::eval::store_graph::{PackageNode, ResourceNode};
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::manifest::types::{self, ResourceId};
use crate::manifest::{keys, lifecycle};

const NS: &str = "kix-enterprise-test-data";

pub(crate) fn build() -> StoreGraph {
    super::fixtures::kix_enterprise_test()
}

/// What the planner checks for a deploy of `new` to a cluster that runs
/// `old`, or nothing, with the flags `extra`, before the plan reads the
/// cluster.
fn objects(old: Option<&StoreGraph>, new: &StoreGraph, extra: &[&str]) -> Result<Objects, Unshown> {
    match plan(&deployed(old), new, flags(extra)) {
        Ok(checked) => Ok(checked.objects().clone()),
        Err(PlanError::Unshown(unshown)) => Err(unshown),
        Err(e) => panic!("the plan was refused before the objects check: {e}"),
    }
}

/// A store path whose hash is `seed`, padded, for a file named `name`.
fn path(seed: &str, name: &str) -> PathBuf {
    PathBuf::from(format!("/nix/store/{seed:0<32}-k8s-{name}"))
}

fn add(graph: &mut StoreGraph, path: &Path, manifest: Value) {
    graph.resources.insert(
        path.to_path_buf(),
        ResourceNode {
            store_path: path.to_path_buf(),
            manifest,
        },
    );
}

pub(crate) fn package_instance(name: &str, instance: Option<&str>) -> Value {
    let mut spec = json!({"namespaceName": NS});
    if let Some(instance) = instance {
        spec["instanceName"] = json!(instance);
    }
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": lifecycle::PACKAGE_INSTANCE_KIND,
        "metadata": {"name": name, "namespace": NS},
        "spec": spec,
    })
}

fn cluster_role_binding(name: &str) -> Value {
    json!({
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRoleBinding",
        "metadata": {"name": name},
        "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"kind": "ServiceAccount", "name": "default", "namespace": NS}],
    })
}

/// Add a package that the graph names `instance` in [`NS`], made from
/// `pi` and holding one ClusterRoleBinding, before every other package.
pub(crate) fn add_package(
    graph: &mut StoreGraph,
    seed: &str,
    pi: Value,
    instance: &str,
) -> ResourceId {
    let pi_path = path(&format!("{seed}p"), "PackageInstance-pi");
    let crb = cluster_role_binding(&format!("{seed}-admin"));
    let crb_path = path(&format!("{seed}c"), "ClusterRoleBinding-admin");
    let id = ResourceId::from_value(&crb);
    add(graph, &pi_path, pi);
    add(graph, &crb_path, crb);
    graph
        .resource_owner
        .insert(crb_path.clone(), pi_path.clone());
    graph.packages.shift_insert(
        0,
        pi_path.clone(),
        PackageNode {
            store_path: pi_path,
            instance_name: instance.to_string(),
            namespace: NS.to_string(),
            version: None,
            lifecycle: None,
            resource_paths: vec![crb_path],
            cross_deps: Vec::new(),
        },
    );
    id
}

fn refused_writes(result: Result<Objects, Unshown>) -> Vec<String> {
    match result {
        Ok(objects) => panic!("the deploy was not refused: {objects:?}"),
        Err(unshown) => unshown.writes,
    }
}

/// Two PackageInstances of one instance: the plan keys packages by
/// namespace and instance, so it shows one of them, and the deploy
/// would apply both.
#[test]
fn a_package_hidden_behind_another_of_its_instance_is_refused() {
    let mut new = build();
    let id = add_package(
        &mut new,
        "evil",
        package_instance("shop-2", Some("shop")),
        "shop",
    );
    let refused = refused_writes(objects(None, &new, &[]));
    let hidden: Vec<&str> = refused
        .iter()
        .map(|w| w.split(' ').next().unwrap())
        .collect();
    let pi = format!("{}/shop-2@{NS}", lifecycle::PACKAGE_INSTANCE_KIND);
    assert_eq!(hidden, vec![id.display_id(), pi], "{refused:?}");
}

/// An object whose owner is a package the graph does not hold is in no
/// package and not cluster-level, so no section of the plan lists it.
#[test]
fn an_object_owned_by_a_missing_package_is_refused() {
    let mut new = build();
    let crb = cluster_role_binding("orphaned-admin");
    let id = ResourceId::from_value(&crb);
    let crb_path = path("orphaned", "ClusterRoleBinding-orphaned-admin");
    add(&mut new, &crb_path, crb);
    new.resource_owner
        .insert(crb_path, path("missing", "PackageInstance-missing"));
    let refused = refused_writes(objects(None, &new, &[]));
    assert_eq!(refused.len(), 1, "{refused:?}");
    assert!(refused[0].starts_with(&id.display_id()), "{refused:?}");
}

/// The plan shows one Activation record; a second is applied unseen.
#[test]
fn a_second_activation_record_is_refused() {
    let mut new = build();
    let record = new.resources[&new.activation_path].manifest.clone();
    let mut second = record.clone();
    second["metadata"]["name"] = json!("kix-enterprise-test-second");
    add(&mut new, &path("second", "Activation-second"), second);
    let refused = refused_writes(objects(None, &new, &[]));
    assert_eq!(refused.len(), 1, "{refused:?}");
    assert!(refused[0].starts_with("Activation/"), "{refused:?}");
}

/// Two files of one object: the deploy applies one of them, and which
/// one the plan shows is not fixed.
#[test]
fn two_files_of_one_object_are_refused() {
    let mut new = build();
    let (at, node) = new
        .resources
        .iter()
        .find(|(_, n)| n.manifest["kind"] == "ConfigMap")
        .map(|(p, n)| (p.clone(), n.clone()))
        .unwrap();
    let mut copy = node.manifest.clone();
    copy["data"] = json!({"other": "value"});
    let copy_path = path("copy", "ConfigMap-copy");
    add(&mut new, &copy_path, copy);
    let owner = new.resource_owner[&at].clone();
    new.resource_owner.insert(copy_path, owner);
    let refused = refused_writes(objects(None, &new, &[]));
    assert!(
        refused.iter().any(|w| w.contains("in 2 build files")),
        "{refused:?}"
    );
}

/// A deploy deletes only what the plan lists as removed.
#[test]
fn a_delete_the_plan_does_not_show_is_refused() {
    let new = build();
    let baseline = deployed(Some(&new));
    let (new_graph, _) = stamp(&new);
    let checked = plan(&baseline, &new, flags(&[])).unwrap();
    let (plan, pkg_diff) = (checked.plan(), checked.pkg_diff());
    let stray = ResourceId {
        kind: "ConfigMap".into(),
        namespace: NS.into(),
        name: "not-in-any-build".into(),
    };
    let refused = super::objects::of(
        &pkg_diff.shown,
        &new_graph,
        plan,
        std::slice::from_ref(&stray),
        &[],
        baseline.ran(),
    )
    .unwrap_err();
    assert_eq!(refused.deletes, vec![stray.display_id()]);
    // The plan's prune section, when it read the cluster, lists it.
    assert!(
        super::objects::of(
            &pkg_diff.shown,
            &new_graph,
            plan,
            std::slice::from_ref(&stray),
            std::slice::from_ref(&stray),
            baseline.ran(),
        )
        .is_ok()
    );
}

/// A first deploy writes every object, each listed as added.
#[test]
fn a_first_deploy_writes_every_object_the_plan_shows() {
    let new = build();
    let objects = objects(None, &new, &[]).unwrap();
    assert_eq!(objects.writes.len(), new.resources.len());
    assert!(
        objects
            .writes
            .iter()
            .all(|w| w.change == WriteChange::Added)
    );
    assert!(objects.deletes.is_empty());
}

#[test]
fn a_redeploy_of_the_deployed_build_writes_nothing() {
    let build = build();
    let objects = objects(Some(&build), &build, &["--prune"]).unwrap();
    assert_eq!(objects, Objects::default());
}

/// `--reconcile` writes every object again, each re-applied: the
/// deployed build holds the same file for it.
#[test]
fn reconcile_reapplies_the_deployed_build() {
    let build = build();
    let objects = objects(Some(&build), &build, &["--reconcile"]).unwrap();
    assert_eq!(objects.writes.len(), build.resources.len());
    assert!(
        objects
            .writes
            .iter()
            .all(|w| w.change == WriteChange::Reapplied)
    );
}

/// A PackageInstance that changed while its resources did not is
/// applied, so the plan shows its package as changed.
#[test]
fn a_package_instance_changed_alone_is_shown() {
    let old = build();
    let mut new = old.clone();
    let at = new
        .packages
        .iter()
        .find(|(_, p)| p.instance_name == "shop")
        .map(|(at, _)| at.clone())
        .unwrap();
    let mut node = new.packages.shift_remove(&at).unwrap();
    let mut pi = new.resources.remove(&at).unwrap().manifest;
    pi["spec"]["version"] = json!("2.0.0");
    let moved = path("shopv2", "PackageInstance-shop");
    add(&mut new, &moved, pi);
    for owner in new.resource_owner.values_mut() {
        if *owner == at {
            *owner = moved.clone();
        }
    }
    node.store_path = moved.clone();
    new.packages.insert(moved, node);
    let objects = objects(Some(&old), &new, &[]).unwrap();
    let written: Vec<(&str, &str, WriteChange)> = objects
        .writes
        .iter()
        .map(|w| (w.kind.as_str(), w.package.as_str(), w.change))
        .collect();
    assert_eq!(
        written,
        vec![(
            lifecycle::PACKAGE_INSTANCE_KIND,
            "kix-enterprise-test-data/shop",
            WriteChange::Modified
        )]
    );
}

/// A package left out of the build is deleted under `--prune`, each of
/// its objects listed as removed.
#[test]
fn a_removed_package_is_deleted_as_shown() {
    let old = build();
    let mut new = old.clone();
    let at = new
        .packages
        .iter()
        .find(|(_, p)| p.instance_name == "landing")
        .map(|(at, _)| at.clone())
        .unwrap();
    let node = new.packages.shift_remove(&at).unwrap();
    for p in node.resource_paths.iter().chain([&at]) {
        new.resources.remove(p);
        new.resource_owner.remove(p);
    }
    let objects = objects(Some(&old), &new, &["--prune"]).unwrap();
    assert!(objects.writes.is_empty(), "{:?}", objects.writes);
    assert!(!objects.deletes.is_empty());
}

/// A namespaced object with no namespace and one in `default` pass the
/// build's one-object rule, which compares (kind, namespace, name)
/// exactly, and both are applied to the one live object in `default`.
/// The plan lists both, each with its own store hash, so the reviewer
/// sees both manifests and the digest binds both.
#[test]
fn an_object_without_a_namespace_and_one_in_default_are_both_shown() {
    let mut new = build();
    let shop = package_at(&new, "shop");
    for (seed, namespace) in [("bare", None), ("dflt", Some("default"))] {
        let mut cm = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "twin"},
            "data": {"from": seed},
        });
        if let Some(namespace) = namespace {
            cm["metadata"]["namespace"] = json!(namespace);
        }
        let at = path(seed, "ConfigMap-twin");
        add(&mut new, &at, cm);
        new.resource_owner.insert(at.clone(), shop.clone());
        new.packages[&shop].resource_paths.push(at);
    }
    new.validate().unwrap();
    let objects = objects(None, &new, &[]).unwrap();
    let twins: Vec<(&str, WriteChange)> = objects
        .writes
        .iter()
        .filter(|w| w.name == "twin")
        .map(|w| (w.namespace.as_str(), w.change))
        .collect();
    assert_eq!(
        twins,
        vec![
            (types::CLUSTER_SCOPED, WriteChange::Added),
            ("default", WriteChange::Added)
        ]
    );
}

/// The build's one-record rule counts every manifest of kind
/// Activation, whatever its API group, so another group's Activation
/// cannot sit beside kix's record.
#[test]
fn another_groups_activation_is_refused_by_the_build() {
    let mut new = build();
    let mut foreign = new.resources[&new.activation_path].manifest.clone();
    foreign["apiVersion"] = json!("example.com/v1");
    foreign["metadata"]["name"] = json!("foreign");
    add(&mut new, &path("foreign", "Activation-foreign"), foreign);
    let err = new.validate().unwrap_err().to_string();
    assert!(err.contains("one Activation record"), "{err}");
}

/// Another group's PackageInstance listed as a package is shown as that
/// package's PackageInstance, and its store hash, which covers its
/// `apiVersion`, is in the digest. Not listed, it is a cluster-level
/// object like any other.
#[test]
fn another_groups_package_instance_is_shown_with_its_store_hash() {
    let mut new = build();
    let mut pi = package_instance("foreign", Some("foreign"));
    pi["apiVersion"] = json!("example.com/v1");
    add_package(&mut new, "listed", pi.clone(), "foreign");
    pi["metadata"]["name"] = json!("unlisted");
    let unlisted = path("unlisted", "PackageInstance-unlisted");
    add(&mut new, &unlisted, pi);
    new.validate().unwrap();
    let objects = objects(None, &new, &[]).unwrap();
    let pis: Vec<(&str, &str, &str)> = objects
        .writes
        .iter()
        .filter(|w| w.name == "foreign" || w.name == "unlisted")
        .map(|w| (w.name.as_str(), w.package.as_str(), w.store_hash.as_str()))
        .collect();
    let listed_hash = store_hash(&path("listedp", "PackageInstance-pi"));
    let unlisted_hash = store_hash(&unlisted);
    assert_eq!(
        pis,
        vec![
            (
                "foreign",
                "kix-enterprise-test-data/foreign",
                listed_hash.as_str()
            ),
            ("unlisted", super::CLUSTER_LEVEL_KEY, unlisted_hash.as_str()),
        ]
    );
}

/// Whether a deploy of `deployed` from a plan reviewed for `reviewed`,
/// both over `old`, is refused, and on which rules. Both builds carry
/// one Activation record, so the build rule alone lets it through.
fn saved_rules(
    old: Option<&StoreGraph>,
    reviewed: &StoreGraph,
    deployed: &StoreGraph,
    extra: &[&str],
) -> Vec<super::saved::Rule> {
    let doc = |graph: &StoreGraph| {
        let (stamped_graph, _) = stamp(graph);
        let empty = super::diff_graphs(&stamped_graph, &stamped_graph);
        let mut doc = super::document::Plan::new(
            super::document::KixBuild::current(env!("CARGO_PKG_VERSION")),
            super::document::MadeBy::DryRun,
            &graph.cluster_name,
            super::document::Build::of(&stamped_graph),
            &empty,
            super::document::Detail::Plain,
            &[],
            super::document::NotCheckedReason::BuildsOnly,
        );
        let objects = objects(old, graph, extra).unwrap();
        doc.objects_digest = Some(super::objects::digest(&objects));
        doc.objects = Some(objects);
        doc
    };
    let (reviewed, fresh) = (doc(reviewed), doc(deployed));
    assert_eq!(reviewed.build, fresh.build, "one Activation record");
    super::saved::compare(&reviewed, &fresh)
        .mismatches
        .iter()
        .map(|m| m.rule)
        .collect()
}

fn package_at(graph: &StoreGraph, instance: &str) -> PathBuf {
    graph
        .packages
        .iter()
        .find(|(_, p)| p.instance_name == instance)
        .map(|(at, _)| at.clone())
        .unwrap()
}

/// An object added under a package of a build with the reviewed
/// Activation record is another set of objects.
#[test]
fn a_saved_plan_refuses_an_object_added_under_its_activation() {
    let reviewed = build();
    let mut deployed = reviewed.clone();
    let shop = package_at(&deployed, "shop");
    let crb_path = path("added", "ClusterRoleBinding-added");
    add(&mut deployed, &crb_path, cluster_role_binding("added"));
    deployed
        .resource_owner
        .insert(crb_path.clone(), shop.clone());
    deployed.packages[&shop].resource_paths.push(crb_path);
    assert_eq!(
        saved_rules(None, &reviewed, &deployed, &[]),
        vec![super::saved::Rule::Objects]
    );
}

/// The same files under another package stamp another owner on what
/// the deploy applies.
#[test]
fn a_saved_plan_refuses_another_owner_for_the_same_files() {
    let reviewed = build();
    let mut deployed = reviewed.clone();
    let (shop, cache) = (
        package_at(&deployed, "shop"),
        package_at(&deployed, "cache"),
    );
    let moved = deployed.packages[&shop].resource_paths.remove(0);
    deployed.packages[&cache].resource_paths.push(moved.clone());
    deployed.resource_owner.insert(moved, cache);
    assert_eq!(
        saved_rules(None, &reviewed, &deployed, &[]),
        vec![super::saved::Rule::Objects]
    );
}

/// A manifest missing from the deployed build is an orphan, and
/// `--prune` would delete its live object.
#[test]
fn a_saved_plan_refuses_a_build_that_lost_a_manifest() {
    let reviewed = build();
    let mut deployed = reviewed.clone();
    let landing = package_at(&deployed, "landing");
    let lost = deployed.packages[&landing].resource_paths.remove(0);
    deployed.resources.remove(&lost);
    deployed.resource_owner.remove(&lost);
    assert_eq!(
        saved_rules(Some(&reviewed), &reviewed, &deployed, &["--prune"]),
        vec![super::saved::Rule::Objects]
    );
}
