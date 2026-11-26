//! Tests of revision names, of splitting a build into revisions, and of the
//! store against the in-memory apiserver.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;
use crate::cluster::fake_api::FakeApi;
use crate::eval::store_graph::{PackageNode, ResourceNode, StoreGraph};
use crate::manifest::keys;

const CLUSTER: &str = "c1";

fn path(hash: &str, name: &str) -> PathBuf {
    PathBuf::from(format!("/nix/store/{hash:a>32}-k8s-{name}"))
}

fn pi(ns: &str, instance: &str) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": "PackageInstance",
        "metadata": { "name": instance, "namespace": ns },
        "spec": { "instanceName": instance },
    })
}

fn cm(ns: &str, name: &str) -> Value {
    json!({ "apiVersion": "v1", "kind": "ConfigMap", "metadata": { "name": name, "namespace": ns } })
}

/// One package's instance and resources, as `(hash, manifest)` pairs.
struct Package {
    namespace: &'static str,
    name: &'static str,
    instance: &'static str,
    resources: Vec<(&'static str, Value)>,
}

/// Build a graph of `packages`, the cluster-level `cluster_level`, and an
/// Activation record whose store hash is `activation`, inserting everything
/// in the order given.
fn graph(packages: &[Package], cluster_level: &[(&str, Value)], activation: &str) -> StoreGraph {
    let mut g = StoreGraph::empty(CLUSTER);
    let add = |g: &mut StoreGraph, hash: &str, manifest: &Value| {
        let kind = manifest["kind"].as_str().unwrap();
        let name = manifest["metadata"]["name"].as_str().unwrap();
        let p = path(hash, &format!("{kind}-{name}"));
        g.resources.insert(
            p.clone(),
            ResourceNode {
                store_path: p.clone(),
                manifest: manifest.clone(),
            },
        );
        p
    };
    for pkg in packages {
        let store_path = add(&mut g, pkg.instance, &pi(pkg.namespace, pkg.name));
        let resource_paths = pkg
            .resources
            .iter()
            .map(|(h, m)| add(&mut g, h, m))
            .collect();
        g.packages.insert(
            store_path.clone(),
            PackageNode {
                store_path,
                instance_name: pkg.name.into(),
                namespace: pkg.namespace.into(),
                version: None,
                lifecycle: None,
                resource_paths,
                cross_deps: Vec::new(),
            },
        );
    }
    for (h, m) in cluster_level {
        add(&mut g, h, m);
    }
    let record = json!({
        "apiVersion": keys::API_VERSION,
        "kind": "Activation",
        "metadata": { "name": format!("{CLUSTER}-{activation}") },
    });
    g.activation_path = add(&mut g, activation, &record);
    g
}

fn web(config: &'static str) -> Package {
    Package {
        namespace: "apps",
        name: "web",
        instance: "1",
        resources: vec![("2", cm("apps", "a")), (config, cm("apps", "b"))],
    }
}

fn db() -> Package {
    Package {
        namespace: "data",
        name: "db",
        instance: "4",
        resources: vec![("5", cm("data", "d"))],
    }
}

fn namespaces() -> Vec<(&'static str, Value)> {
    ["apps", "data"]
        .iter()
        .zip(["6", "7"])
        .map(|(ns, h)| {
            (
                h,
                json!({ "apiVersion": "v1", "kind": "Namespace", "metadata": { "name": ns } }),
            )
        })
        .collect()
}

fn names(set: &RevisionSet) -> BTreeMap<String, String> {
    let mut out: BTreeMap<String, String> = set
        .instances
        .iter()
        .map(|(k, r)| (k.clone(), r.name.clone()))
        .collect();
    out.insert("<cluster>".into(), set.cluster_level.name.clone());
    out
}

#[test]
fn the_same_build_gives_the_same_names_in_any_order() {
    let first = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    let again = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    assert_eq!(first, again);

    let mut reordered = web("3");
    reordered.resources.reverse();
    let mut ns = namespaces();
    ns.reverse();
    let other = RevisionSet::of(CLUSTER, &graph(&[db(), reordered], &ns, "8"));
    assert_eq!(names(&first), names(&other));
    assert_eq!(
        first.instances["apps/web"].spec,
        other.instances["apps/web"].spec
    );

    let web_rev = &first.instances["apps/web"];
    assert!(web_rev.name.starts_with("c1-"));
    assert_eq!(web_rev.name.len(), "c1-".len() + 32);
    assert_eq!(
        web_rev.spec.slot,
        Slot::Instance {
            namespace: "apps".into(),
            name: "web".into()
        }
    );
    let kinds: Vec<&str> = web_rev
        .spec
        .objects
        .iter()
        .map(|o| o.kind.as_str())
        .collect();
    assert_eq!(kinds, ["PackageInstance", "ConfigMap", "ConfigMap"]);
    assert_eq!(web_rev.spec.objects[0].group, keys::GROUP);
    assert_eq!(web_rev.spec.objects[1].hash, format!("{:a>32}", "2"));
}

#[test]
fn changing_one_object_changes_only_its_instance() {
    let before = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    let after = RevisionSet::of(CLUSTER, &graph(&[web("9"), db()], &namespaces(), "b"));
    assert_ne!(
        before.instances["apps/web"].name,
        after.instances["apps/web"].name
    );
    assert_eq!(
        before.instances["data/db"].name,
        after.instances["data/db"].name
    );
    assert_eq!(
        before.cluster_level.name, after.cluster_level.name,
        "a new Activation record leaves the cluster level as it was"
    );
}

#[test]
fn the_cluster_level_holds_unowned_objects_but_not_the_record() {
    let set = RevisionSet::of(CLUSTER, &graph(&[web("3")], &namespaces(), "8"));
    assert_eq!(set.cluster_level.spec.slot, Slot::ClusterLevel);
    let objects: Vec<(&str, Option<&str>, &str)> = set
        .cluster_level
        .spec
        .objects
        .iter()
        .map(|o| (o.kind.as_str(), o.namespace.as_deref(), o.name.as_str()))
        .collect();
    assert_eq!(
        objects,
        [("Namespace", None, "apps"), ("Namespace", None, "data")]
    );
    assert_eq!(set.all().count(), 2);
}

#[test]
fn a_long_cluster_name_is_cut_and_the_hash_kept_whole() {
    let long = format!("{}-{}", "x".repeat(219), "y".repeat(40));
    let spec = RevisionSpec::new(&long, Slot::ClusterLevel, Vec::new());
    let name = name_of(&spec);
    assert!(name.len() <= 253, "{}", name.len());
    // The cut lands on the dash after the x's, which is dropped.
    assert_eq!(name, format!("{}-{}", "x".repeat(219), &name[220..]));
    assert_eq!(name[220..].len(), 32);
    assert_eq!(name, name_of(&spec));
}

fn revision(cluster: &str, instance: &'static str) -> Revision {
    let set = RevisionSet::of(cluster, &graph(&[web("3"), db()], &namespaces(), "8"));
    set.instances[instance].clone()
}

#[tokio::test]
async fn create_accepts_a_revision_that_already_exists() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let rev = revision(CLUSTER, "apps/web");
    assert_eq!(store.create(&rev).await.unwrap(), Created::Created);
    assert_eq!(store.create(&rev).await.unwrap(), Created::Exists);
    let obj = api.object(KIND, &rev.name).unwrap();
    assert_eq!(obj["metadata"]["labels"][keys::CLUSTER_LABEL], CLUSTER);
    assert_eq!(obj["apiVersion"], keys::API_VERSION);
    assert_eq!(store.get(&rev.name).await.unwrap(), Some(rev));
}

#[tokio::test]
async fn a_read_refuses_a_revision_whose_spec_does_not_match_its_name() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let rev = revision(CLUSTER, "apps/web");
    store.create(&rev).await.unwrap();
    api.patch_object(KIND, &rev.name, |o| {
        o["spec"]["objects"][1]["name"] = json!("changed");
    });
    match store.get(&rev.name).await {
        Err(RevisionError::Read(ReadError::NameMismatch { name, .. })) => {
            assert_eq!(name, rev.name);
        }
        other => panic!("{other:?}"),
    }
    let message = store.list(CLUSTER).await.unwrap_err().to_string();
    assert!(message.contains(&rev.name), "{message}");
}

#[tokio::test]
async fn list_returns_only_the_named_clusters_revisions() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let mine = [revision(CLUSTER, "apps/web"), revision(CLUSTER, "data/db")];
    let theirs = revision("c2", "apps/web");
    for rev in mine.iter().chain([&theirs]) {
        store.create(rev).await.unwrap();
    }
    let mut expected: Vec<String> = mine.iter().map(|r| r.name.clone()).collect();
    expected.sort();
    let listed: Vec<String> = store
        .list(CLUSTER)
        .await
        .unwrap()
        .into_iter()
        .map(|r| r.name)
        .collect();
    assert_eq!(listed, expected);
    assert_eq!(store.list("c2").await.unwrap(), vec![theirs]);
    assert_eq!(store.list_all().await.unwrap().len(), 3);
}

#[tokio::test]
async fn applied_hashes_round_trip_through_the_status() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let rev = revision(CLUSTER, "apps/web");
    store.create(&rev).await.unwrap();
    let first: BTreeMap<String, String> = [(rev.spec.objects[0].hash.clone(), "h0".to_string())]
        .into_iter()
        .collect();
    store.write_applied(&rev.name, &first).await.unwrap();
    let second: BTreeMap<String, String> = [(rev.spec.objects[1].hash.clone(), "h1".to_string())]
        .into_iter()
        .collect();
    store.write_applied(&rev.name, &second).await.unwrap();
    let read = store.get(&rev.name).await.unwrap().unwrap();
    let mut both = first.clone();
    both.extend(second);
    assert_eq!(read.applied, both);
    assert!(
        api.requests()
            .iter()
            .any(|r| r.starts_with("PATCH ") && r.contains(&format!("{}/status", rev.name))),
        "{:?}",
        api.requests()
    );
}

#[tokio::test]
async fn deleting_a_missing_revision_succeeds() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let rev = revision(CLUSTER, "apps/web");
    store.delete(&rev.name).await.unwrap();
    store.create(&rev).await.unwrap();
    store.delete(&rev.name).await.unwrap();
    assert_eq!(store.get(&rev.name).await.unwrap(), None);
}

#[test]
fn of_applied_names_only_what_the_filter_keeps() {
    let g = graph(&[web("3"), db()], &namespaces(), "8");
    let all = RevisionSet::of(CLUSTER, &g);
    let no_b = RevisionSet::of_applied(CLUSTER, &g, |m| m["metadata"]["name"] != "b");
    let names =
        |r: &Revision| -> Vec<String> { r.spec.objects.iter().map(|o| o.name.clone()).collect() };
    assert_eq!(names(&all.instances["apps/web"]), ["web", "a", "b"]);
    assert_eq!(names(&no_b.instances["apps/web"]), ["web", "a"]);
    assert_eq!(all.instances["data/db"], no_b.instances["data/db"]);
    assert_eq!(all.cluster_level, no_b.cluster_level);
}

#[test]
fn a_map_round_trips_and_names_every_revision() {
    let set = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    let mut map = RevisionMap::of(&set);
    assert_eq!(map.kept_orphans, None);
    assert_eq!(map.to_value()["keptOrphans"], Value::Null);
    assert_eq!(RevisionMap::from_value(&map.to_value()), Some(map.clone()));
    map.kept_orphans = Some("c1-kept".into());
    assert_eq!(RevisionMap::from_value(&map.to_value()), Some(map.clone()));
    let mut names: Vec<&str> = map.names().collect();
    names.sort();
    let mut expected: Vec<&str> = set
        .all()
        .map(|r| r.name.as_str())
        .chain(["c1-kept"])
        .collect();
    expected.sort();
    assert_eq!(names, expected);

    let mut other = map.to_value();
    other["format"] = json!(2);
    assert_eq!(RevisionMap::from_value(&other), None);
    assert_eq!(RevisionMap::from_value(&json!({})), None);
}

#[test]
fn a_manifest_names_its_object_by_its_identity_hash() {
    let mut manifest = cm("apps", "a");
    assert_eq!(RevisionObject::of_manifest(&manifest), None);
    manifest["metadata"]["annotations"] = json!({ (keys::IDENTITY_HASH): "h1" });
    assert_eq!(
        RevisionObject::of_manifest(&manifest),
        Some(RevisionObject {
            hash: "h1".into(),
            group: String::new(),
            kind: "ConfigMap".into(),
            namespace: Some("apps".into()),
            name: "a".into(),
        })
    );
}

mod keep_tests {
    use super::*;
    use crate::cluster::activation::{Record, Records};
    use crate::cluster::head::{HeadStatus, LockState, Purpose};
    use crate::manifest::lifecycle::{
        PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_PARTIAL, PHASE_QUEUED,
        PHASE_SUPERSEDED,
    };

    fn map(name: &str) -> RevisionMap {
        RevisionMap {
            instances: BTreeMap::from([("apps/web".to_string(), format!("{name}-web"))]),
            cluster_level: format!("{name}-cl"),
            kept_orphans: Some(format!("{name}-kept")),
        }
    }

    fn rec(name: &str, phase: &str) -> Record {
        Record {
            name: name.into(),
            phase: phase.into(),
            revisions: Some(map(name)),
            ..Default::default()
        }
    }

    fn head(current: Option<&str>, deploying: Option<&str>) -> HeadStatus {
        HeadStatus {
            current: current.map(str::to_string),
            lock: deploying.map(|a| LockState {
                holder: "h".into(),
                hint: String::new(),
                activation: Some(a.into()),
                purpose: Purpose::Deploy,
                renewed: "2026-11-26T00:00:00Z".into(),
                duration_seconds: 30,
                waiting: None,
            }),
            ..Default::default()
        }
    }

    /// Return which of the records' revisions `needed` keeps, as record
    /// names.
    fn kept(head: Option<&HeadStatus>, records: &[Record]) -> Vec<String> {
        let names = keep::needed(head, records);
        let mut out: Vec<String> = records
            .iter()
            .filter(|r| {
                let all: Vec<String> = map(&r.name).names().map(str::to_string).collect();
                let some = all.iter().any(|n| names.contains(n));
                assert_eq!(some, all.iter().all(|n| names.contains(n)), "{}", r.name);
                some
            })
            .map(|r| r.name.clone())
            .collect();
        out.sort();
        out
    }

    #[test]
    fn needed_keeps_what_every_record_but_a_superseded_one_names() {
        let records = [
            rec("active", PHASE_ACTIVE),
            rec("degraded", PHASE_DEGRADED),
            rec("deploying", PHASE_DEPLOYING),
            rec("failed", PHASE_FAILED),
            rec("partial", PHASE_PARTIAL),
            rec("queued", PHASE_QUEUED),
            rec("new", ""),
            rec("superseded", PHASE_SUPERSEDED),
            rec("rollback", PHASE_SUPERSEDED),
            rec("committed", PHASE_SUPERSEDED),
        ];
        let cases: [(Option<HeadStatus>, &[&str]); 3] = [
            (
                None,
                &[
                    "active",
                    "degraded",
                    "deploying",
                    "failed",
                    "new",
                    "partial",
                    "queued",
                ],
            ),
            (
                Some(head(Some("committed"), Some("rollback"))),
                &[
                    "active",
                    "committed",
                    "degraded",
                    "deploying",
                    "failed",
                    "new",
                    "partial",
                    "queued",
                    "rollback",
                ],
            ),
            (
                Some(head(None, None)),
                &[
                    "active",
                    "degraded",
                    "deploying",
                    "failed",
                    "new",
                    "partial",
                    "queued",
                ],
            ),
        ];
        for (head, expected) in cases {
            assert_eq!(kept(head.as_ref(), &records), expected, "{head:?}");
        }

        let no_map = Record {
            name: "old".into(),
            phase: PHASE_ACTIVE.into(),
            ..Default::default()
        };
        assert!(keep::needed(None, &[no_map]).is_empty());
    }

    fn activation(name: &str, phase: &str, map: &RevisionMap) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": name,
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): CLUSTER },
            },
            "status": { "phase": phase, "revisions": map.to_value() },
        })
    }

    /// `clean` deletes the revisions only a `Superseded` record names and
    /// leaves another Kix cluster's revisions alone.
    #[tokio::test]
    async fn clean_deletes_what_no_needed_record_names() {
        let current = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
        let old = RevisionSet::of(CLUSTER, &graph(&[web("9"), db()], &namespaces(), "b"));
        let theirs = revision("c2", "apps/web");
        let api = FakeApi::new([
            activation("now", PHASE_ACTIVE, &RevisionMap::of(&current)),
            activation("before", PHASE_SUPERSEDED, &RevisionMap::of(&old)),
        ]);
        let client = api.client();
        let store = Revisions::new(&client);
        for rev in current.all().chain(old.all()).chain([&theirs]) {
            store.create(rev).await.unwrap();
        }
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let deleted = keep::clean(&client, &records, CLUSTER).await.unwrap();
        assert_eq!(deleted, vec![old.instances["apps/web"].name.clone()]);
        let mut expected: Vec<String> = current
            .all()
            .map(|r| r.name.clone())
            .chain([theirs.name.clone()])
            .collect();
        expected.sort();
        assert_eq!(api.names(KIND), expected);
    }
}
