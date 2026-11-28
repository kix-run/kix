//! Tests of revision names, of splitting a build into revisions, and of the
//! store against the in-memory apiserver.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;
use crate::cluster::fake_api::FakeApi;
use crate::eval::store_graph::{PackageNode, ResourceNode, StoreGraph};
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

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

/// The package `web`, whose ConfigMap `b` has store hash `config` and holds
/// `config` as its data.
fn web(config: &'static str) -> Package {
    let mut b = cm("apps", "b");
    b["data"] = json!({ "v": config });
    Package {
        namespace: "apps",
        name: "web",
        instance: "1",
        resources: vec![("2", cm("apps", "a")), (config, b)],
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
            name: "web".into(),
            lifecycle: None,
        }
    );
    let mut kinds: Vec<&str> = web_rev
        .spec
        .objects
        .iter()
        .map(|o| o.kind.as_str())
        .collect();
    kinds.sort();
    assert_eq!(kinds, ["ConfigMap", "ConfigMap", "PackageInstance"]);
    let a = web_rev.spec.objects.iter().find(|o| o.name == "a").unwrap();
    assert_eq!(a.hash, crate::manifest::hash::object_hash(&cm("apps", "a")));
    let instance = web_rev
        .spec
        .objects
        .iter()
        .find(|o| o.kind == "PackageInstance")
        .unwrap();
    assert_eq!(instance.group, keys::GROUP);
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

/// A build whose store hashes changed and whose manifests did not, as when
/// only a dependency changed, gives the same revisions.
#[test]
fn a_change_of_store_hashes_alone_keeps_every_revision() {
    let before = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    let mut moved = web("3");
    moved.instance = "c";
    moved.resources[0].0 = "d";
    let after = RevisionSet::of(CLUSTER, &graph(&[moved, db()], &namespaces(), "e"));
    assert_eq!(names(&before), names(&after));
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
    let listed = store.list(CLUSTER).await.unwrap();
    assert_eq!(listed.names().collect::<Vec<_>>(), [rev.name.as_str()]);
    let message = listed.all_readable().unwrap_err().to_string();
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
        .names()
        .map(str::to_string)
        .collect();
    assert_eq!(listed, expected);
    assert_eq!(store.list("c2").await.unwrap().readable, vec![theirs]);
    assert_eq!(store.list_all().await.unwrap().readable.len(), 3);
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
fn a_map_round_trips_and_names_every_revision() {
    let set = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    let mut map = RevisionMap::of(&set);
    assert_eq!(map.kept_orphans, None);
    assert_eq!(map.to_value()["keptOrphans"], Value::Null);
    assert_eq!(RevisionMap::read(&map.to_value()), Ok(map.clone()));
    map.kept_orphans = Some("c1-kept".into());
    assert_eq!(RevisionMap::read(&map.to_value()), Ok(map.clone()));
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
    let later = RevisionMap::read(&other).unwrap_err().to_string();
    assert!(later.contains("format 2"), "{later}");
    assert!(RevisionMap::read(&json!({})).is_err());
}

#[test]
fn a_build_manifest_names_its_object_by_its_object_hash() {
    let mut manifest = cm("apps", "a");
    assert_eq!(RevisionObject::of_build(&manifest), None, "a live object");
    manifest["metadata"]["annotations"] = json!({ (keys::IDENTITY_HASH): "h1" });
    assert_eq!(
        RevisionObject::of_build(&manifest),
        Some(RevisionObject {
            hash: crate::manifest::hash::object_hash(&manifest),
            group: String::new(),
            kind: "ConfigMap".into(),
            namespace: Some("apps".into()),
            name: "a".into(),
            needs: Vec::new(),
        })
    );
}

/// A create whose stored `spec` differs from the one sent, as when the
/// installed definition prunes a field this version writes, is refused
/// with a message that names the definition.
#[tokio::test]
async fn create_refuses_a_spec_the_server_stored_differently() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let rev = revision(CLUSTER, "apps/web");
    api.on_create(&rev.name, |o| {
        o["spec"]["slot"].as_object_mut().unwrap().remove("name");
    });
    let err = store.create(&rev).await.unwrap_err();
    assert!(
        matches!(&err, RevisionError::StoredDifferently { name } if *name == rev.name),
        "{err}"
    );
    assert!(err.to_string().contains(&crd_name()), "{err}");
}

/// A build with an instance too large to store as one revision is refused,
/// naming the instance and its object count. One that fits passes.
#[test]
fn a_revision_too_large_to_store_names_its_instance() {
    let mut set = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
    assert_eq!(set.check_size(), Ok(()));
    let objects: Vec<RevisionObject> = (0..20_000)
        .map(|i| RevisionObject {
            hash: format!("{i:a>32}"),
            group: String::new(),
            kind: "ConfigMap".into(),
            namespace: Some("data".into()),
            name: format!("config-{i}"),
            needs: Vec::new(),
        })
        .collect();
    let slot = set.instances["data/db"].spec.slot.clone();
    let big = Revision::new(RevisionSpec::new(CLUSTER, slot, objects));
    assert!(big.stored_bytes() > MAX_BYTES);
    set.instances.insert("data/db".into(), big);
    let err = set.check_size().unwrap_err();
    assert_eq!(err.objects, 20_000);
    let message = err.to_string();
    assert!(message.contains("package instance data/db"), "{message}");
    assert!(message.contains("Split the instance"), "{message}");
}

/// A graph whose ConfigMap `b` depends on `a`, on the ClusterRole
/// `system:auth-delegator` as `requires`, and on a hash no manifest of the
/// build carries, in a package whose lifecycle is `stateful`.
fn graph_with_edges() -> StoreGraph {
    let role = json!({
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": "ClusterRole",
        "metadata": { "name": "system:auth-delegator" },
    });
    let mut b = cm("apps", "b");
    b["metadata"]["annotations"] = json!({
        (keys::DEPENDS_ON): format!("{:a>32},requires:{:a>32},{:a>32}", "2", "6", "f"),
    });
    let package = Package {
        namespace: "apps",
        name: "web",
        instance: "1",
        resources: vec![("2", cm("apps", "a")), ("3", b)],
    };
    let mut g = graph(&[package], &[("6", role)], "8");
    for node in g.packages.values_mut() {
        node.lifecycle = Some("stateful".into());
    }
    g
}

/// A revision records each object's dependencies by name, with the
/// relation `kix.run/depends-on` gives them, and the lifecycle of its
/// instance. A hash that names no manifest of the build is left out.
#[test]
fn a_revision_records_needs_by_name_and_the_lifecycle() {
    let set = RevisionSet::of(CLUSTER, &graph_with_edges());
    let web = &set.instances["apps/web"];
    assert_eq!(web.spec.format, FORMAT);
    assert!(matches!(
        &web.spec.slot,
        Slot::Instance { lifecycle: Some(l), .. } if l == "stateful"
    ));
    let b = web.spec.objects.iter().find(|o| o.name == "b").unwrap();
    let needs: Vec<(&str, &str, Option<&str>)> = b
        .needs
        .iter()
        .map(|n| (n.kind.as_str(), n.name.as_str(), n.role.as_deref()))
        .collect();
    assert_eq!(
        needs,
        [
            ("ConfigMap", "a", None),
            ("ClusterRole", "system:auth-delegator", Some("requires")),
        ]
    );
    let stored = serde_json::to_value(&web.spec).unwrap();
    let entry = stored["objects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["name"] == "b")
        .unwrap();
    assert_eq!(
        entry["needs"],
        json!([
            { "kind": "ConfigMap", "namespace": "apps", "name": "a" },
            {
                "group": "rbac.authorization.k8s.io",
                "kind": "ClusterRole",
                "name": "system:auth-delegator",
                "as": "requires",
            },
        ])
    );
}

/// Two machines that build the same graph write the same bytes, so they
/// name its revisions the same.
#[test]
fn a_spec_built_twice_from_one_build_is_the_same_bytes() {
    let first = RevisionSet::of(CLUSTER, &graph_with_edges());
    let again = RevisionSet::of(CLUSTER, &graph_with_edges());
    for (a, b) in first.all().zip(again.all()) {
        assert_eq!(
            serde_json::to_vec(&a.spec).unwrap(),
            serde_json::to_vec(&b.spec).unwrap()
        );
        assert_eq!(a.name, b.name);
    }
}

/// A dependency whose name holds a colon is stored as fields of its own,
/// so it reads back whole.
#[tokio::test]
async fn a_need_with_a_colon_in_its_name_reads_back() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    let set = RevisionSet::of(CLUSTER, &graph_with_edges());
    let web = set.instances["apps/web"].clone();
    store.create(&web).await.unwrap();
    let read = store.get(&web.name).await.unwrap().unwrap();
    assert_eq!(read, web);
    let b = read.spec.objects.iter().find(|o| o.name == "b").unwrap();
    assert!(b.needs.iter().any(|n| n.name == "system:auth-delegator"));
}

/// A revision an earlier build of Kix wrote has no `format`, no `needs`,
/// and no lifecycle. It reads as format 1, records no edges, and keeps its
/// name.
#[test]
fn a_format_one_revision_reads() {
    // The bytes an earlier build of Kix hashed for the name, in its field
    // order.
    let written = format!(
        r#"{{"cluster":"{CLUSTER}","slot":{{"kind":"instance","namespace":"apps","name":"web"}},"objects":[{{"hash":"{:a>32}","group":"","kind":"ConfigMap","namespace":"apps","name":"a"}}]}}"#,
        "2"
    );
    let spec: Value = serde_json::from_str(&written).unwrap();
    let hash = &format!(
        "{:x}",
        <sha2::Sha256 as sha2::Digest>::digest(written.as_bytes())
    )[..32];
    let name = format!("{CLUSTER}-{hash}");
    let obj: kube::api::DynamicObject = serde_json::from_value(json!({
        "apiVersion": keys::API_VERSION,
        "kind": KIND,
        "metadata": { "name": name },
        "spec": spec,
    }))
    .unwrap();
    let read = Revision::from_object(&obj).unwrap();
    assert_eq!(read.spec.format, 1);
    assert!(!read.spec.records_edges());
    assert!(read.spec.objects[0].needs.is_empty());
    assert!(matches!(
        read.spec.slot,
        Slot::Instance {
            lifecycle: None,
            ..
        }
    ));
    let edges = crate::cluster::edges::Edges::of_revisions([&read]);
    assert!(!edges.records(&read.spec.objects[0].resource_id()));
}

/// The size estimate counts each object's `needs`.
#[test]
fn the_size_estimate_counts_needs() {
    let slot = Slot::ClusterLevel;
    let dep = crate::manifest::types::ResourceId::new("", "ConfigMap", "data", "dep");
    let object = |needs: usize| RevisionObject {
        hash: format!("{:a>32}", "1"),
        group: String::new(),
        kind: "ConfigMap".into(),
        namespace: Some("data".into()),
        name: "config".into(),
        needs: (0..needs)
            .map(|i| Need::of(&dep, Some(&format!("role{i}"))))
            .collect(),
    };
    let bare = Revision::new(RevisionSpec::new(CLUSTER, slot.clone(), vec![object(0)]));
    let with = Revision::new(RevisionSpec::new(CLUSTER, slot, vec![object(3)]));
    let added = serde_json::to_vec(&with.spec.objects[0].needs)
        .unwrap()
        .len();
    assert!(with.stored_bytes() >= bare.stored_bytes() + added);
}

/// Entries for one object and build hash merge into one, with the edges of
/// both.
#[test]
fn entries_for_one_object_and_hash_merge_their_needs() {
    let rid = crate::manifest::types::ResourceId::new("", "ConfigMap", "data", "x");
    let need = |name: &str| {
        Need::of(
            &crate::manifest::types::ResourceId::new("", "ConfigMap", "data", name),
            None,
        )
    };
    let spec = RevisionSpec::new(
        CLUSTER,
        Slot::KeptOrphans,
        vec![
            RevisionObject::of_id("h", &rid).with_needs([need("a")]),
            RevisionObject::of_id("h", &rid).with_needs([need("b")]),
        ],
    );
    assert_eq!(spec.objects.len(), 1);
    assert_eq!(spec.objects[0].needs, [need("a"), need("b")]);
}

#[test]
fn the_definition_requires_a_spec() {
    let definition = crd::definition();
    let schema = &definition["spec"]["versions"][0]["schema"]["openAPIV3Schema"];
    assert_eq!(schema["required"], json!(["spec"]));
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
            revisions: Some(Ok(map(name))),
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
        let names = keep::needed(head, records).unwrap();
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
        assert!(keep::needed(None, &[no_map]).unwrap().is_empty());
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

    async fn records_of(api: &FakeApi) -> Records {
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        Records::open_installed(&client, &discovery).unwrap()
    }

    /// Two revisions, one named by an Active record and one by none, and the
    /// records to list them with.
    async fn one_needed_one_not(api: &FakeApi) -> (RevisionSet, RevisionSet) {
        let current = RevisionSet::of(CLUSTER, &graph(&[web("3"), db()], &namespaces(), "8"));
        let old = RevisionSet::of(CLUSTER, &graph(&[web("9"), db()], &namespaces(), "b"));
        api.insert(activation("now", PHASE_ACTIVE, &RevisionMap::of(&current)));
        let store = Revisions::new(&api.client());
        for rev in current.all().chain(old.all()) {
            store.create(rev).await.unwrap();
        }
        (current, old)
    }

    /// The cleanup lists records by the cluster label alone, as it lists
    /// revisions, and refuses when the record the lock holder deploys is
    /// not in that list. Nothing is deleted.
    #[tokio::test]
    async fn clean_refuses_when_the_lock_holders_record_is_not_listed() {
        let api = FakeApi::new([]);
        let (current, _) = one_needed_one_not(&api).await;
        let mut unlabelled = activation("hand", PHASE_ACTIVE, &RevisionMap::of(&current));
        unlabelled["metadata"]["labels"] = json!({});
        api.insert(unlabelled);
        let client = api.client();
        let lock = crate::cluster::head::take(
            &client,
            crate::cluster::head::Request {
                cluster: CLUSTER.into(),
                holder: crate::cluster::head::Holder::cli("kix deploy"),
                purpose: Purpose::Deploy,
                activation: Some("hand".into()),
                expect: None,
            },
            crate::cluster::head::system_clock(),
            &|_| {},
        )
        .await
        .unwrap();
        let records = records_of(&api).await;
        let before = api.names(KIND);
        let err = keep::clean(&client, &records, CLUSTER).await.unwrap_err();
        assert!(
            matches!(&err, keep::CleanError::MissingRecord { record, .. } if record == "hand"),
            "{err}"
        );
        assert_eq!(api.names(KIND), before);

        // A record without `managed-by` but with the cluster label counts.
        api.patch_object("Activation", "hand", |o| {
            o["metadata"]["labels"] = json!({ (keys::CLUSTER_LABEL): CLUSTER });
        });
        keep::clean(&client, &records, CLUSTER).await.unwrap();
        lock.release().await.unwrap();
        assert!(current.all().all(|r| api.names(KIND).contains(&r.name)));
    }

    /// A record list that answers 404 is an error, not an empty list, so
    /// the cleanup deletes nothing.
    #[tokio::test]
    async fn clean_refuses_when_the_records_cannot_be_listed() {
        let api = FakeApi::new([]);
        one_needed_one_not(&api).await;
        let records = records_of(&api).await;
        let before = api.names(KIND);
        api.fail_next(&format!("/apis/{}/activations", keys::API_VERSION), 1, 404);
        let err = keep::clean(&api.client(), &records, CLUSTER)
            .await
            .unwrap_err();
        assert!(matches!(err, keep::CleanError::Records(_)), "{err}");
        assert_eq!(api.names(KIND), before);
    }

    /// A record with a map this release cannot read, such as one a later
    /// release wrote in another format, stops the cleanup.
    #[tokio::test]
    async fn clean_refuses_a_map_it_cannot_read() {
        let api = FakeApi::new([]);
        let (_, old) = one_needed_one_not(&api).await;
        let mut later = RevisionMap::of(&old).to_value();
        later["format"] = json!(2);
        let mut record = activation("later", PHASE_FAILED, &RevisionMap::of(&old));
        record["status"]["revisions"] = later;
        api.insert(record);
        let records = records_of(&api).await;
        let before = api.names(KIND);
        let err = keep::clean(&api.client(), &records, CLUSTER)
            .await
            .unwrap_err();
        assert!(
            matches!(&err, keep::CleanError::UnreadableMap { record, .. } if record == "later"),
            "{err}"
        );
        assert_eq!(api.names(KIND), before);
    }

    /// A revision that cannot be read does not block the cleanup. It is
    /// deleted by name when no record names it, and the others are cleaned.
    #[tokio::test]
    async fn clean_deletes_an_unreadable_revision_by_name() {
        let api = FakeApi::new([]);
        let (current, old) = one_needed_one_not(&api).await;
        let broken = &old.instances["apps/web"].name;
        api.patch_object(KIND, broken, |o| {
            o["spec"]["objects"][0]["name"] = json!("changed");
        });
        let records = records_of(&api).await;
        let deleted = keep::clean(&api.client(), &records, CLUSTER).await.unwrap();
        assert_eq!(deleted, vec![broken.clone()]);
        let mut expected: Vec<String> = current.all().map(|r| r.name.clone()).collect();
        expected.sort();
        assert_eq!(api.names(KIND), expected);
    }
}

mod applied_tests {
    use std::collections::BTreeMap;

    use kube::api::DynamicObject;
    use serde_json::{Value, json};

    use super::super::applied::pending;
    use super::*;
    use crate::cluster::activation::Record;
    use crate::cluster::drift::{self, DriftVerdict};
    use crate::cluster::fieldsv1;
    use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_SUPERSEDED};

    fn object(hash: &str, name: &str) -> RevisionObject {
        RevisionObject {
            hash: format!("{hash:a>32}"),
            group: String::new(),
            kind: "ConfigMap".into(),
            namespace: Some("app".into()),
            name: name.into(),
            needs: Vec::new(),
        }
    }

    fn web(objects: Vec<RevisionObject>, applied: &[(&RevisionObject, &str)]) -> Revision {
        let mut revision = Revision::new(RevisionSpec::new(
            CLUSTER,
            Slot::Instance {
                namespace: "app".into(),
                name: "web".into(),
                lifecycle: None,
            },
            objects,
        ));
        revision.applied = applied
            .iter()
            .map(|(o, h)| (o.hash.clone(), h.to_string()))
            .collect();
        revision
    }

    fn applied(entries: &[(&RevisionObject, &str)]) -> BTreeMap<AppliedKey, String> {
        entries
            .iter()
            .map(|(o, h)| (o.applied_key(), h.to_string()))
            .collect()
    }

    fn entries(pairs: &[(&RevisionObject, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(o, h)| (o.hash.clone(), h.to_string()))
            .collect()
    }

    /// A run that applied nothing, such as an operator deploy whose build
    /// only removed an object, still carries the hashes of what it left
    /// unchanged into the revision that replaces the old one. Otherwise the
    /// next plan would apply each of them again.
    #[test]
    fn a_run_that_applied_nothing_still_carries_hashes() {
        let (x, y) = (object("x", "x"), object("y1", "y"));
        let old = web(vec![x.clone(), y.clone()], &[(&x, "hx")]);
        let new = web(vec![x.clone()], &[]);
        let writes = pending(&BTreeMap::new(), &[&old, &new], &[(&old, &new)]);
        assert_eq!(writes, [(new.name.clone(), entries(&[(&x, "hx")]))].into());
        assert!(pending(&BTreeMap::new(), &[&old], &[]).is_empty());
    }

    /// An object that two kept revisions name with the same build hash gets
    /// its applied hash in both. A revision that names it with another
    /// build hash gets nothing.
    #[test]
    fn an_object_two_kept_revisions_name_gets_its_hash_in_both() {
        let (z, other) = (object("z", "z"), object("z2", "z"));
        let failed = web(vec![z.clone(), object("f", "f")], &[]);
        let current = web(vec![z.clone(), object("n", "n")], &[]);
        let elsewhere = web(vec![other.clone()], &[]);
        let writes = pending(
            &applied(&[(&z, "hz")]),
            &[&failed, &current, &elsewhere],
            &[],
        );
        assert_eq!(
            writes,
            BTreeMap::from([
                (failed.name.clone(), entries(&[(&z, "hz")])),
                (current.name.clone(), entries(&[(&z, "hz")])),
            ])
        );
    }

    /// The new revision of a changed instance takes the old revision's
    /// hash of each object the run did not apply, and the run's hash of
    /// each object it applied. The old revision gets nothing, because it
    /// names no object the run applied.
    #[test]
    fn carry_forward_copies_the_hashes_of_unchanged_objects() {
        let (x, w, y1, y2) = (
            object("x", "x"),
            object("w", "w"),
            object("y1", "y"),
            object("y2", "y"),
        );
        let old = web(
            vec![x.clone(), w.clone(), y1.clone()],
            &[(&x, "hx"), (&y1, "hy1")],
        );
        let new = web(vec![x.clone(), w.clone(), y2.clone()], &[]);
        let writes = pending(&applied(&[(&y2, "hy2")]), &[&old, &new], &[(&old, &new)]);
        assert_eq!(
            writes,
            BTreeMap::from([(new.name.clone(), entries(&[(&x, "hx"), (&y2, "hy2")]))])
        );
    }

    /// Two old revisions that record different hashes for one object carry
    /// none, as a reader treats revisions that disagree. Old revisions that
    /// agree, or where only one records a hash, carry it.
    #[test]
    fn old_revisions_that_disagree_carry_no_hash() {
        let (x, w) = (object("x", "x"), object("w", "w"));
        let first = web(vec![x.clone(), w.clone()], &[(&x, "hx1"), (&w, "hw")]);
        let mut second = web(vec![x.clone(), w.clone()], &[(&x, "hx2"), (&w, "hw")]);
        second.spec.slot = Slot::ClusterLevel;
        second.name = "second".into();
        let mut new = web(vec![x.clone(), w.clone()], &[]);
        new.name = "new".into();
        let writes = pending(&BTreeMap::new(), &[], &[(&first, &new), (&second, &new)]);
        assert_eq!(
            writes,
            BTreeMap::from([("new".to_string(), entries(&[(&w, "hw")]))])
        );
    }

    /// The run notes what it applied by resource id and build hash. Each
    /// revision entry with that id and hash takes the applied hash, and so
    /// does a carry between two revisions that list the object.
    #[test]
    fn applied_hashes_key_on_the_resource_id_and_the_build_hash() {
        let namespace = crate::manifest::types::ResourceId {
            group: String::new(),
            kind: "Namespace".into(),
            namespace: crate::manifest::types::CLUSTER_SCOPED.into(),
            name: "app".into(),
        };
        let hash = format!("{:a>32}", "n");
        let entry = RevisionObject::of_id(&hash, &namespace);
        assert_eq!(entry.namespace, None);
        let x = object("x", "x");
        let old = web(vec![entry.clone(), x.clone()], &[(&x, "hx")]);
        let mut new = web(vec![entry.clone(), x.clone()], &[]);
        new.name = "new".into();
        let noted = BTreeMap::from([(
            AppliedKey {
                rid: namespace,
                hash: hash.clone(),
            },
            "hn".to_string(),
        )]);
        let writes = pending(&noted, &[&new], &[(&old, &new)]);
        assert_eq!(
            writes,
            BTreeMap::from([(
                "new".to_string(),
                BTreeMap::from([(hash, "hn".to_string()), (x.hash.clone(), "hx".to_string())])
            )])
        );
    }

    /// An object whose edges changed and whose build hash did not keeps
    /// its applied hash when the run carries hashes into the new revision.
    #[test]
    fn an_applied_hash_is_carried_when_only_the_needs_differ() {
        let x = object("x", "x");
        let dep = crate::manifest::types::ResourceId::new("", "ConfigMap", "app", "dep");
        let x_with_needs = x.clone().with_needs([Need::of(&dep, None)]);
        let old = web(vec![x.clone()], &[(&x, "hx")]);
        let mut new = web(vec![x_with_needs], &[]);
        new.name = "new".into();
        let writes = pending(&BTreeMap::new(), &[], &[(&old, &new)]);
        assert_eq!(
            writes,
            BTreeMap::from([("new".to_string(), entries(&[(&x, "hx")]))])
        );
    }

    /// An entry a revision already holds with the same value is not sent
    /// again.
    #[test]
    fn entries_a_revision_holds_are_not_written_again() {
        let x = object("x", "x");
        let held = web(vec![x.clone()], &[(&x, "hx")]);
        assert!(pending(&applied(&[(&x, "hx")]), &[&held], &[]).is_empty());
        let writes = pending(&applied(&[(&x, "hx2")]), &[&held], &[]);
        assert_eq!(
            writes,
            BTreeMap::from([(held.name.clone(), entries(&[(&x, "hx2")]))])
        );
    }

    fn record(phase: &str, revision: Option<&Revision>) -> Record {
        Record {
            name: "r".into(),
            phase: phase.into(),
            revisions: revision.map(|r| {
                Ok(RevisionMap {
                    instances: BTreeMap::from([("app/web".to_string(), r.name.clone())]),
                    cluster_level: r.name.clone(),
                    kept_orphans: None,
                })
            }),
            ..Default::default()
        }
    }

    /// A live ConfigMap whose build hash is `x`'s, with Kix's `Apply`
    /// entry owning its data, and `annotation` as its applied-hash
    /// annotation.
    fn live(x: &RevisionObject, annotation: Option<&str>) -> DynamicObject {
        let mut annotations = json!({ (keys::IDENTITY_HASH): x.hash });
        if let Some(stamp) = annotation {
            annotations[keys::APPLIED_HASH] = Value::from(stamp);
        }
        serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": x.name,
                "namespace": "app",
                "annotations": annotations,
                "managedFields": [{
                    "manager": "kix/a",
                    "operation": "Apply",
                    "apiVersion": "v1",
                    "fieldsType": "FieldsV1",
                    "fieldsV1": { "f:data": { "f:k": {} } },
                }],
            },
            "data": { "k": "v" },
        }))
        .unwrap()
    }

    fn manager() -> crate::cluster::field_manager::FieldManager {
        crate::cluster::field_manager::FieldManager::of("a")
    }

    fn applied_of<'a>(source: &'a AppliedHashes, obj: &'a DynamicObject) -> Option<&'a str> {
        source.for_live(obj, &manager(), Some("r"))
    }

    fn verdict(obj: &DynamicObject, source: &AppliedHashes) -> DriftVerdict {
        drift::check_object(obj, applied_of(source, obj), &manager()).verdict
    }

    /// The drift check gives the same verdict whether the applied hash comes
    /// from a revision or from the annotation.
    #[test]
    fn drift_verdicts_are_the_same_from_a_revision_and_from_the_annotation() {
        let x = object("x", "x");
        let current = fieldsv1::applied_content_hash(
            &live(&x, None),
            &crate::cluster::field_manager::FieldManager::of("a"),
        )
        .unwrap();
        let cases: [(Option<&str>, DriftVerdict); 3] = [
            (Some(&current), DriftVerdict::InSync),
            (
                Some("edited"),
                DriftVerdict::Drifted {
                    foreign: Vec::new(),
                    unrecorded_scale: None,
                },
            ),
            (None, DriftVerdict::Unstamped),
        ];
        for (hash, expected) in cases {
            let stamped = live(&x, hash);
            let from_annotation = verdict(&stamped, &AppliedHashes::from_annotations());
            let revision = match hash {
                Some(h) => web(vec![x.clone()], &[(&x, h)]),
                None => web(vec![x.clone()], &[]),
            };
            let source = AppliedHashes::of(
                &[record(PHASE_ACTIVE, Some(&revision))],
                std::slice::from_ref(&revision),
            );
            let from_revision = verdict(&live(&x, None), &source);
            assert_eq!(from_annotation, expected, "{hash:?}");
            assert_eq!(from_revision, expected, "{hash:?}");
        }
    }

    /// Each record is read from its own source. A record that names its
    /// revisions is read from them, and an object they record no hash for
    /// has none: its annotation does not stand in. A record without a map,
    /// as an earlier Kix wrote, is read from the annotation of each object
    /// whose note names it. A `Superseded` record names nothing.
    #[test]
    fn each_record_is_read_from_its_own_source() {
        let x = object("x", "x");
        let obj = live(&x, Some("from-annotation"));
        let mut noted = obj.clone();
        noted
            .metadata
            .annotations
            .get_or_insert_default()
            .insert(keys::ACTIVATIONS.into(), "rec-r".into());
        let empty = web(vec![x.clone()], &[]);
        let revisions = std::slice::from_ref(&empty);
        let with_map = AppliedHashes::of(&[record(PHASE_ACTIVE, Some(&empty))], revisions);
        assert_eq!(applied_of(&with_map, &obj), None);
        let recorded = web(vec![x.clone()], &[(&x, "from-revision")]);
        let from_revision = AppliedHashes::of(
            &[record(PHASE_ACTIVE, Some(&recorded))],
            std::slice::from_ref(&recorded),
        );
        assert_eq!(applied_of(&from_revision, &obj), Some("from-revision"));
        let without_map = Record {
            identity_hash: Some("rec-r".into()),
            ..record(PHASE_ACTIVE, None)
        };
        let from_notes = AppliedHashes::of(std::slice::from_ref(&without_map), revisions);
        assert_eq!(applied_of(&from_notes, &noted), Some("from-annotation"));
        assert_eq!(applied_of(&from_notes, &obj), None);
        let superseded = Record {
            phase: PHASE_SUPERSEDED.into(),
            ..without_map
        };
        let superseded = AppliedHashes::of(std::slice::from_ref(&superseded), revisions);
        assert_eq!(applied_of(&superseded, &noted), None);
        assert_eq!(
            applied_of(&AppliedHashes::from_annotations(), &obj),
            Some("from-annotation")
        );
    }

    /// A revision a record names that Kix cannot read may name any object,
    /// so an object no other revision names reads as not known, not from
    /// its annotation, and the revision is reported.
    #[test]
    fn a_named_revision_that_cannot_be_read_leaves_hashes_not_known() {
        let x = object("x", "x");
        let recorded = web(vec![x.clone()], &[(&x, "from-revision")]);
        let mut map_record = record(PHASE_ACTIVE, Some(&recorded));
        if let Some(Ok(map)) = &mut map_record.revisions {
            map.cluster_level = "a-missing".into();
        }
        let source = AppliedHashes::of(&[map_record], std::slice::from_ref(&recorded));
        assert_eq!(source.missing(), ["a-missing"]);
        assert_eq!(
            applied_of(&source, &live(&x, Some("from-annotation"))),
            Some("from-revision")
        );
        let other = live(&object("y", "y"), Some("from-annotation"));
        assert_eq!(applied_of(&source, &other), None);
    }

    /// Two revisions that record different applied hashes for one object,
    /// as after a write that reached one and not the other, leave its hash
    /// not known, so the next plan applies it without force and records
    /// one. The annotation does not stand in.
    #[test]
    fn two_revisions_that_disagree_leave_the_hash_not_known() {
        let x = object("x", "x");
        let one = web(vec![x.clone()], &[(&x, "h1")]);
        let mut two = web(vec![x.clone()], &[(&x, "h2")]);
        two.name = format!("{}-other", two.name);
        let mut recorded = record(PHASE_ACTIVE, Some(&one));
        if let Some(Ok(map)) = &mut recorded.revisions {
            map.kept_orphans = Some(two.name.clone());
        }
        let source = AppliedHashes::of(&[recorded], [&one, &two]);
        assert_eq!(
            applied_of(&source, &live(&x, Some("from-annotation"))),
            None
        );
    }
}

/// Return an import marker `name` in `ns` that stands for the object
/// `target` of kind `kind`, as the library writes one.
fn marker(ns: &str, name: &str, api_version: &str, kind: &str, target: &str) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": "PackageInstance",
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": {
                (keys::MODE): "import",
                (keys::IMPORT_API_VERSION): api_version,
                (keys::IMPORT_KIND): kind,
                (keys::IMPORT_NAME): target,
            },
        },
        "spec": { "instanceName": name },
    })
}

/// A build with the package `web`, whose custom resource `cr` (written as a
/// ConfigMap) needs a CRD marker that requires the ConfigMap `a`, and the
/// import instance `kube-system/platform-dns`, whose own PackageInstance is
/// a marker for the DNS Service.
fn graph_with_imports() -> StoreGraph {
    let mut crd_ref = marker(
        "apps",
        "crd-ref-web-widgets-example-com",
        "apiextensions.k8s.io/v1",
        "CustomResourceDefinition",
        "widgets.example.com",
    );
    let annotations = &mut crd_ref["metadata"]["annotations"];
    annotations[keys::CRD_KIND] = json!("Widget");
    annotations[keys::CRD_SERVED_VERSIONS] = json!("v1");
    annotations[keys::DEPENDS_ON] = json!(format!("requires:{:a>32}", "2"));
    let mut cr = cm("apps", "cr");
    cr["metadata"]["annotations"] = json!({ (keys::DEPENDS_ON): format!("{:a>32}", "9") });
    let web = Package {
        namespace: "apps",
        name: "web",
        instance: "1",
        resources: vec![("2", cm("apps", "a")), ("9", crd_ref), ("3", cr)],
    };
    let dns = Package {
        namespace: "kube-system",
        name: "platform-dns",
        instance: "4",
        resources: Vec::new(),
    };
    let mut g = graph(&[web, dns], &[], "8");
    for node in g.resources.values_mut() {
        if node.manifest["metadata"]["name"] == "platform-dns" {
            node.manifest = marker("kube-system", "platform-dns", "v1", "Service", "kube-dns");
        }
    }
    g
}

/// A revision lists an instance's import markers under `imports`, with what
/// each stands for and its own needs, and not among its objects. An object
/// that needs a marker names it. An import instance's revision has no
/// objects.
#[test]
fn a_revision_lists_import_markers_apart_from_its_objects() {
    let set = RevisionSet::of(CLUSTER, &graph_with_imports());
    let web = &set.instances["apps/web"];
    let objects: Vec<&str> = web.spec.objects.iter().map(|o| o.name.as_str()).collect();
    let mut sorted = objects.clone();
    sorted.sort();
    assert_eq!(sorted, ["a", "cr", "web"]);
    assert_eq!(web.spec.imports.len(), 1);
    let import = &web.spec.imports[0];
    assert_eq!(import.name, "crd-ref-web-widgets-example-com");
    assert_eq!(import.namespace.as_deref(), Some("apps"));
    assert_eq!(
        import.target,
        Some(ImportedObject {
            api_version: "apiextensions.k8s.io/v1".into(),
            kind: "CustomResourceDefinition".into(),
            namespace: None,
            name: "widgets.example.com".into(),
        })
    );
    assert_eq!(
        import.needs,
        [Need::of(
            &ResourceId::new("", "ConfigMap", "apps", "a"),
            Some("requires")
        )]
    );
    let cr = web.spec.objects.iter().find(|o| o.name == "cr").unwrap();
    assert_eq!(cr.needs, [Need::of(&import.resource_id(), None)]);

    let dns = &set.instances["kube-system/platform-dns"];
    assert!(dns.spec.objects.is_empty());
    assert_eq!(dns.spec.imports.len(), 1);
    assert_eq!(
        dns.spec.imports[0].target.as_ref().map(|t| t.resource_id()),
        Some(ResourceId::new("", "Service", "kube-system", "kube-dns"))
    );
    let stored = serde_json::to_value(&web.spec).unwrap();
    assert_eq!(
        stored["imports"][0]["target"]["apiVersion"],
        "apiextensions.k8s.io/v1"
    );
}

/// A revision with imports reads back whole and keeps its name.
#[tokio::test]
async fn a_revision_with_imports_reads_back() {
    let api = FakeApi::new([]);
    let store = Revisions::new(&api.client());
    for revision in RevisionSet::of(CLUSTER, &graph_with_imports()).all() {
        store.create(revision).await.unwrap();
        assert_eq!(
            store.get(&revision.name).await.unwrap().as_ref(),
            Some(revision)
        );
    }
}

/// The package index read from revisions lists each marker in its instance,
/// names it, and says it is an import, so readers place it as the build did
/// and do not look for it on the cluster.
#[test]
fn the_package_index_lists_imports() {
    let set = RevisionSet::of(CLUSTER, &graph_with_imports());
    let index = RevisionMap::of(&set).package_index(|name| set.all().find(|r| r.name == name));
    let dns_hash = &set.instances["kube-system/platform-dns"].spec.imports[0].hash;
    let crd_ref_hash = &set.instances["apps/web"].spec.imports[0].hash;
    assert_eq!(
        &index.packages["kube-system/platform-dns"].instance,
        dns_hash
    );
    assert!(index.packages["apps/web"].resources.contains(crd_ref_hash));
    assert_eq!(
        index.imports,
        [dns_hash.clone(), crd_ref_hash.clone()]
            .into_iter()
            .collect()
    );
    assert!(matches!(
        index.name_of(dns_hash),
        Some(crate::eval::package_index::IndexedName::Named(rid))
            if rid == ResourceId::new(keys::GROUP, "PackageInstance", "kube-system", "platform-dns")
    ));
}

/// The edges of revisions with imports name what each marker stands for,
/// and an edge to a marker no manifest stands for passes on to what the
/// marker needs.
#[test]
fn edges_pass_through_a_marker_no_manifest_stands_for() {
    let set = RevisionSet::of(CLUSTER, &graph_with_imports());
    let edges = crate::cluster::edges::Edges::of_revisions(set.all());
    let crd_ref = set.instances["apps/web"].spec.imports[0].resource_id();
    assert_eq!(
        edges.import(&crd_ref),
        Some(ResourceId::new(
            "apiextensions.k8s.io",
            "CustomResourceDefinition",
            crate::manifest::types::CLUSTER_SCOPED,
            "widgets.example.com"
        ))
    );
    let cr = ResourceId::new("", "ConfigMap", "apps", "cr");
    let a = ResourceId::new("", "ConfigMap", "apps", "a");
    let through: Vec<ResourceId> = edges
        .needs_through_imports(&cr, |rid| *rid == a)
        .into_iter()
        .map(Need::resource_id)
        .collect();
    assert_eq!(through, std::slice::from_ref(&a));
    let direct: Vec<ResourceId> = edges
        .needs_through_imports(&cr, |rid| *rid == a || *rid == crd_ref)
        .into_iter()
        .map(Need::resource_id)
        .collect();
    assert_eq!(direct, std::slice::from_ref(&crd_ref));
    assert_eq!(edges.imports_reached([&cr]).len(), 1);
    assert!(edges.imports_reached([&a]).is_empty());
}
