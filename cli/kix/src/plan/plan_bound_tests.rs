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
use crate::cluster::stream::NodeId;
use crate::eval::store_graph::{PackageNode, ResourceNode};
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::manifest::types::{self, ResourceId};
use crate::manifest::{keys, lifecycle};

const NS: &str = "kix-enterprise-test-data";

pub(crate) fn build() -> StoreGraph {
    super::fixtures::kix_enterprise_test()
}

/// Run the planner's objects check for a deploy of `new` over `old` with flags
/// `extra`, before connecting to the cluster.
fn objects(old: Option<&StoreGraph>, new: &StoreGraph, extra: &[&str]) -> Result<Objects, Unshown> {
    match plan(&deployed(old), new, flags(extra)) {
        Ok(checked) => Ok(checked.objects().clone()),
        Err(PlanError::Unshown(unshown)) => Err(unshown),
        Err(e) => panic!("the plan was refused before the objects check: {e}"),
    }
}

/// Build a store path with `seed` padded to 32 characters for `name`.
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
    let pi = ResourceId::from_value(&package_instance("shop-2", None)).display_id();
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
    assert!(
        refused[0].starts_with(&format!("Activation.{}/", keys::GROUP)),
        "{refused:?}"
    );
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
        group: String::new(),
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

/// Return how many objects `graph` makes: every resource but the import
/// markers, for which Kix writes nothing.
fn made(graph: &StoreGraph) -> usize {
    stamp(graph)
        .0
        .resources
        .values()
        .filter(|n| !crate::manifest::lifecycle::is_marker(&n.manifest))
        .count()
}

/// A first deploy writes every object, each listed as added, and nothing
/// for an import marker.
#[test]
fn a_first_deploy_writes_every_object_the_plan_shows() {
    let new = build();
    assert!(
        made(&new) < stamp(&new).0.resources.len(),
        "the build has a marker"
    );
    let objects = objects(None, &new, &[]).unwrap();
    assert_eq!(objects.writes.len(), made(&new));
    assert!(
        objects
            .writes
            .iter()
            .all(|w| w.change == WriteChange::Added)
    );
    assert!(objects.deletes.is_empty());
}

/// Return `graph` without the Activation and PackageInstance definitions, as
/// builds that no longer carry them are made.
fn without_kix_crds(graph: &StoreGraph) -> StoreGraph {
    let mut graph = graph.clone();
    graph
        .resources
        .retain(|_, node| !lifecycle::is_kix_crd(&node.manifest));
    graph
}

/// A build from before the Kix program installed its own CRDs holds two of
/// them. Loading it leaves them out, so a deploy over it plans no orphan and
/// no leaving kind, and a rollback to it writes neither.
#[test]
fn a_build_that_holds_kixs_own_crds_plans_none_of_them() {
    let old = build();
    assert_eq!(
        old.resources
            .values()
            .filter(|n| lifecycle::is_kix_crd(&n.manifest))
            .count(),
        2,
        "the fixture is a build that holds both definitions"
    );
    let new = without_kix_crds(&old);

    let upgrade = plan(&deployed(Some(&old)), &new, flags(&["--prune"])).unwrap();
    assert!(upgrade.orphans().is_empty(), "{:?}", upgrade.orphans());
    assert!(upgrade.kinds_leaving().is_empty());
    assert!(upgrade.objects().writes.is_empty());
    assert!(upgrade.objects().deletes.is_empty());

    let rollback = plan(&deployed(Some(&new)), &old, flags(&["--prune"])).unwrap();
    assert!(rollback.objects().writes.is_empty());
    assert!(
        !rollback.plan().nodes().iter().any(
            |n| matches!(&n.id, NodeId::Resource(id) if id.kind == "CustomResourceDefinition")
        )
    );
}

#[test]
fn a_redeploy_of_the_deployed_build_writes_nothing() {
    let build = build();
    let objects = objects(Some(&build), &build, &["--prune"]).unwrap();
    assert_eq!(objects, Objects::default());
}

/// An unchanged Job under `kix.run/rerun` runs again only if its last run
/// failed, so a redeploy lists it apart from the writes it makes.
#[test]
fn a_redeploy_lists_an_unchanged_rerun_job_as_a_write_only_if_it_failed() {
    let mut build = build();
    let job = json!({
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": "bootstrap",
            "namespace": NS,
            "annotations": {keys::RERUN: keys::RERUN_ON_CHANGE},
        },
        "spec": {"template": {"spec": {"restartPolicy": "Never", "containers": []}}},
    });
    add(&mut build, &path("rerunjob", "Job-bootstrap"), job);
    let objects = objects(Some(&build), &build, &["--prune"]).unwrap();
    let changes: Vec<(&str, WriteChange)> = objects
        .writes
        .iter()
        .map(|w| (w.name.as_str(), w.change))
        .collect();
    assert_eq!(changes, [("bootstrap", WriteChange::IfLastRunFailed)]);
    assert!(objects.writes.iter().all(|w| !w.change.certain()));
}

/// `--reconcile` writes every object again, each re-applied: the
/// deployed build holds the same file for it.
#[test]
fn reconcile_reapplies_the_deployed_build() {
    let build = build();
    let objects = objects(Some(&build), &build, &["--reconcile"]).unwrap();
    assert_eq!(objects.writes.len(), made(&build));
    assert!(
        objects
            .writes
            .iter()
            .all(|w| w.change == WriteChange::Reapplied)
    );
}

/// A deploy of an unchanged build skips every Service, so it does not
/// recreate one somebody deleted. `--reconcile` puts each Service in the
/// apply set, which is what the dry run's advice for an unreachable webhook
/// relies on.
#[test]
fn reconcile_applies_a_service_the_build_did_not_change() {
    use crate::cluster::apply::ChangeAction;
    let build = build();
    let applied_services = |extra: &[&str]| {
        let checked = plan(&deployed(Some(&build)), &build, flags(extra)).unwrap();
        checked
            .plan()
            .nodes()
            .iter()
            .filter(|n| matches!(&n.action, ChangeAction::Apply(m) if m["kind"] == "Service"))
            .count()
    };
    let services = build
        .resources
        .values()
        .filter(|r| r.manifest["kind"] == "Service")
        .count();
    assert!(services > 0, "the fixture build has no Service");
    assert_eq!(applied_services(&[]), 0);
    assert_eq!(applied_services(&["--reconcile"]), services);
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

/// Another group's `Activation`, such as Crossplane's, is not Kix's
/// deployment record. It sits beside Kix's record in the build as an object
/// like any other, and the plan writes it at the cluster level.
#[test]
fn another_groups_activation_is_an_object_like_any_other() {
    let mut new = build();
    let mut foreign = new.resources[&new.activation_path].manifest.clone();
    foreign["apiVersion"] = json!("example.com/v1");
    foreign["metadata"]["name"] = json!("foreign");
    let at = path("foreign", "Activation-foreign");
    add(&mut new, &at, foreign);
    new.validate().unwrap();
    let objects = objects(None, &new, &[]).unwrap();
    let written: Vec<(&str, &str, &str)> = objects
        .writes
        .iter()
        .filter(|w| w.name == "foreign")
        .map(|w| (w.group.as_str(), w.package.as_str(), w.store_hash.as_str()))
        .collect();
    assert_eq!(
        written,
        [(
            "example.com",
            super::CLUSTER_LEVEL_KEY,
            store_hash(&at).as_str()
        )]
    );
}

/// A package's instance must be Kix's `PackageInstance`, so the build
/// refuses another group's `PackageInstance` listed as a package. Not
/// listed, it is a cluster-level object like any other, shown with its
/// store hash, which covers its `apiVersion`.
#[test]
fn another_groups_package_instance_is_no_package() {
    let mut listed = build();
    let mut pi = package_instance("foreign", Some("foreign"));
    pi["apiVersion"] = json!("example.com/v1");
    add_package(&mut listed, "listed", pi.clone(), "foreign");
    let err = listed.validate().unwrap_err().to_string();
    assert!(err.contains("is not a PackageInstance record"), "{err}");

    let mut new = build();
    pi["metadata"]["name"] = json!("unlisted");
    let unlisted = path("unlisted", "PackageInstance-unlisted");
    add(&mut new, &unlisted, pi);
    new.validate().unwrap();
    let objects = objects(None, &new, &[]).unwrap();
    let pis: Vec<(&str, &str, &str)> = objects
        .writes
        .iter()
        .filter(|w| w.name == "unlisted")
        .map(|w| (w.name.as_str(), w.package.as_str(), w.store_hash.as_str()))
        .collect();
    let unlisted_hash = store_hash(&unlisted);
    assert_eq!(
        pis,
        vec![("unlisted", super::CLUSTER_LEVEL_KEY, unlisted_hash.as_str())]
    );
}

/// Return the [`super::saved::Rule`] mismatches when deploying `deployed`
/// against a plan reviewed for `reviewed`, both over `old`.
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
            super::document::KixBuild::current(&crate::version::running().to_string()),
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

/// Replace the object of `kind` that `graph` holds first with `manifest`,
/// in a new file `seed` names, owned by the same package. Return the old
/// manifest.
fn replace_first(
    graph: &mut StoreGraph,
    kind: &str,
    seed: &str,
    manifest: impl FnOnce(&Value) -> Value,
) -> Value {
    let (at, old) = graph
        .resources
        .iter()
        .filter(|(_, n)| n.manifest["kind"] == kind)
        .min_by_key(|(p, _)| (*p).clone())
        .map(|(p, n)| (p.clone(), n.manifest.clone()))
        .unwrap_or_else(|| panic!("the build has a {kind}"));
    let owner = graph.resource_owner[&at].clone();
    let to = path(seed, &format!("{kind}-{seed}"));
    graph.resources.remove(&at);
    add(graph, &to, manifest(&old));
    graph.resource_owner.remove(&at);
    graph.resource_owner.insert(to.clone(), owner.clone());
    let paths = &mut graph.packages[&owner].resource_paths;
    paths.retain(|p| *p != at);
    paths.push(to);
    graph.validate().unwrap();
    old
}

fn with_api_version(api_version: &str) -> impl FnOnce(&Value) -> Value + '_ {
    move |m| {
        let mut m = m.clone();
        m["apiVersion"] = json!(api_version);
        m
    }
}

/// A build that moves an object to another API group, keeping its kind,
/// namespace, and name, writes the object in its new group and deletes the
/// one in its old group, and the plan shows both.
#[test]
fn moving_an_object_to_another_group_writes_one_and_deletes_the_other() {
    let old = build();
    let mut new = old.clone();
    let before = replace_first(
        &mut new,
        "Deployment",
        "moved",
        with_api_version("apps.example.com/v1"),
    );
    let mut after = before.clone();
    after["apiVersion"] = json!("apps.example.com/v1");
    let objects = objects(Some(&old), &new, &["--prune"]).unwrap();
    let (old_id, new_id) = (
        ResourceId::from_value(&before),
        ResourceId::from_value(&after),
    );
    assert_ne!(old_id.display_id(), new_id.display_id());
    assert!(
        objects
            .writes
            .iter()
            .any(|w| w.resource_id() == new_id && w.change == WriteChange::Added),
        "{objects:?}"
    );
    assert!(
        objects
            .deletes
            .iter()
            .any(|d| d.group == old_id.group && d.kind == old_id.kind && d.name == old_id.name),
        "{objects:?}"
    );
}

/// Kubernetes serves the core `Event` again as `events.k8s.io` `Event`. A
/// build that moves an Event between the two is refused, because the deploy
/// would delete through one group the object it wrote through the other.
#[test]
fn moving_an_object_between_aliased_groups_is_refused() {
    let mut old = build();
    replace_first(&mut old, "ConfigMap", "event", |m| {
        let mut m = m.clone();
        m["apiVersion"] = json!("v1");
        m["kind"] = json!("Event");
        m
    });
    let mut new = old.clone();
    let before = replace_first(
        &mut new,
        "Event",
        "moved",
        with_api_version("events.k8s.io/v1"),
    );
    let old_id = ResourceId::from_value(&before);
    match plan(&deployed(Some(&old)), &new, flags(&["--prune"])) {
        Err(PlanError::AliasedMove(moves)) => {
            assert_eq!(moves.len(), 1, "{moves:?}");
            assert!(moves[0].starts_with(&old_id.to_string()), "{moves:?}");
            assert!(moves[0].contains("Event.events.k8s.io/"), "{moves:?}");
        }
        Err(e) => panic!("refused for another reason: {e}"),
        Ok(_) => panic!("the plan was not refused"),
    }
}

/// A run writes the kept-orphans revision when it finalizes, after every
/// apply and every delete, so a plan whose run would keep more orphans than
/// one revision can hold is refused before the lock. With `--prune` the run
/// deletes them and keeps none, so the same plan goes through.
#[test]
fn a_kept_orphans_list_too_large_to_store_is_refused_before_the_deploy() {
    let new = build();
    let mut old = new.clone();
    for i in 0..4000 {
        let name = format!("left-{i:04}-{}", "x".repeat(200));
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": name, "namespace": NS },
            "data": { "k": "v" },
        });
        add(&mut old, &path(&format!("{i}"), &name), manifest);
    }
    match plan(&deployed(Some(&old)), &new, flags(&[])) {
        Err(PlanError::RevisionTooLarge(too_large)) => {
            assert_eq!(too_large.objects, 4000);
            let message = too_large.to_string();
            assert!(message.contains("kix gc"), "{message}");
        }
        Err(e) => panic!("refused for another reason: {e}"),
        Ok(_) => panic!("not refused"),
    }
    let checked = plan(&deployed(Some(&old)), &new, flags(&["--prune"]))
        .map_err(|e| e.to_string())
        .unwrap();
    assert_eq!(checked.objects().deletes.len(), 4000);
}
