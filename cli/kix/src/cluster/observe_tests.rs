use super::*;
use crate::cluster::activation::Records;
use crate::cluster::discovery::discover_resources;
use crate::cluster::fake_api::FakeApi;
use crate::cluster::fieldsv1;
use crate::eval::package_index::{FORMAT, IndexedPackage, ObjectName, RecordPackageIndex};
use crate::manifest::lifecycle::RECORD_KIND;
use serde_json::{Value, json};

fn h(c: char) -> String {
    c.to_string().repeat(32)
}

/// The deploy's objects: a package `web/web` whose instance stands in as a
/// ConfigMap, and a cluster-level Namespace.
const ROOT: char = 'r';
const INSTANCE: char = 'i';
const CONFIG: char = 'c';
const EXTRA: char = 'e';
const JOB: char = 'j';
const SECRET: char = 's';
const NAMESPACE: char = 'n';

fn index(with_names: bool) -> RecordPackageIndex {
    let names = [
        (INSTANCE, "ConfigMap", "web", "web-instance"),
        (CONFIG, "ConfigMap", "web", "web-config"),
        (EXTRA, "ConfigMap", "web", "web-extra"),
        (JOB, "Job", "web", "web-migrate"),
        (SECRET, "Secret", "web", "web-db"),
        (NAMESPACE, "Namespace", "", "web"),
    ];
    RecordPackageIndex {
        format: FORMAT,
        packages: BTreeMap::from([(
            "web/web".to_string(),
            IndexedPackage {
                instance: h(INSTANCE),
                resources: [CONFIG, EXTRA, JOB, SECRET].map(h).to_vec(),
            },
        )]),
        cluster_level: vec![h(NAMESPACE)],
        names: if with_names {
            names
                .iter()
                .map(|(c, kind, ns, name)| {
                    (
                        h(*c),
                        ObjectName(kind.to_string(), ns.to_string(), name.to_string()),
                    )
                })
                .collect()
        } else {
            BTreeMap::new()
        },
        groups: with_names.then(|| BTreeMap::from([(h(JOB), "batch".to_string())])),
    }
}

fn record(index: Option<&RecordPackageIndex>, depends_on: &str) -> Value {
    let mut status = json!({ "phase": "Active" });
    if let Some(index) = index {
        status[keys::PACKAGE_INDEX_FIELD] = index.to_value();
    }
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": RECORD_KIND,
        "metadata": {
            "name": "shop-rrrrrrrrrrrr",
            "labels": {
                "app.kubernetes.io/managed-by": "kix",
                (keys::CLUSTER_LABEL): "shop",
            },
            "annotations": {
                (keys::IDENTITY_HASH): h(ROOT),
                (keys::DEPLOYED_AT): "2026-11-12T10:00:00Z",
                (keys::DEPENDS_ON): depends_on,
            },
        },
        "status": status,
    })
}

/// An object Kix applied, with a stamp that matches its content when
/// `in_sync`.
fn object(
    api_version: &str,
    kind: &str,
    ns: &str,
    name: &str,
    hash: char,
    depends_on: &[String],
    in_sync: bool,
) -> Value {
    let mut metadata = json!({
        "name": name,
        "labels": { "app.kubernetes.io/managed-by": "kix" },
        "annotations": {
            (keys::IDENTITY_HASH): h(hash),
            (keys::ACTIVATIONS): h(ROOT),
            (keys::PACKAGE): "web",
            (keys::PACKAGE_NAMESPACE): "web",
            (keys::DEPENDS_ON): depends_on.join(","),
        },
        "managedFields": [{
            "manager": "kix",
            "operation": "Apply",
            "apiVersion": api_version,
            "fieldsType": "FieldsV1",
            "fieldsV1": { "f:metadata": { "f:labels": { "f:app.kubernetes.io/managed-by": {} } } },
        }],
    });
    if !ns.is_empty() {
        metadata["namespace"] = json!(ns);
    }
    let mut obj = json!({ "apiVersion": api_version, "kind": kind, "metadata": metadata });
    let dynamic: DynamicObject = serde_json::from_value(obj.clone()).unwrap();
    let stamp = if in_sync {
        fieldsv1::applied_content_hash(&dynamic).unwrap()
    } else {
        "0".repeat(64)
    };
    obj["metadata"]["annotations"][keys::APPLIED_HASH] = json!(stamp);
    obj
}

/// Every object of the deploy except the Secret: one ConfigMap drifted and
/// the Job, which needs the Secret, not finished.
fn live_objects() -> Vec<Value> {
    vec![
        object(
            "v1",
            "ConfigMap",
            "web",
            "web-instance",
            INSTANCE,
            &[],
            true,
        ),
        object("v1", "ConfigMap", "web", "web-config", CONFIG, &[], true),
        object("v1", "ConfigMap", "web", "web-extra", EXTRA, &[], false),
        object(
            "batch/v1",
            "Job",
            "web",
            "web-migrate",
            JOB,
            &[format!("requires:{}", h(SECRET)), h(CONFIG)],
            true,
        ),
        object("v1", "Namespace", "", "web", NAMESPACE, &[], true),
    ]
}

async fn observe_fake(api: &FakeApi, scope: ObserveScope<'_>) -> Observation {
    let client = api.client();
    let discovery = discover_resources(&client).await.unwrap();
    let records = Records::open(&client, &discovery).unwrap();
    observe(&client, &discovery, &records, scope).await.unwrap()
}

fn by_name<'a>(view: &'a ClusterView, name: &str) -> &'a ObjectView {
    view.objects
        .iter()
        .find(|o| o.rid.name == name)
        .unwrap_or_else(|| panic!("no object {name}"))
}

/// A ConfigMap of the build that is being deleted is not ready, though a
/// ConfigMap has no readiness otherwise, so `kix status` does not call it ok.
#[tokio::test]
async fn an_object_being_deleted_is_not_ready() {
    let index = index(true);
    let mut objects = live_objects();
    objects.push(record(Some(&index), ""));
    let config = objects
        .iter_mut()
        .find(|o| o["metadata"]["name"] == "web-config")
        .unwrap();
    config["metadata"]["deletionTimestamp"] = serde_json::json!("2026-11-24T15:54:00Z");
    config["metadata"]["finalizers"] = serde_json::json!(["test.kix.run/hold"]);
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    let config = by_name(&seen.clusters[0], "web-config");
    assert_eq!(
        config.readiness,
        Readiness::NotReady("being deleted, waiting for test.kix.run/hold".into())
    );
}

/// One read gives each object its three facts: the Secret is missing, one
/// ConfigMap changed, and the Job that needs the Secret is not ready.
#[tokio::test]
async fn each_object_gets_presence_content_and_readiness() {
    let index = index(true);
    let mut objects = live_objects();
    objects.push(record(Some(&index), ""));
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    assert!(seen.unreadable.is_empty());
    let [view] = seen.clusters.as_slice() else {
        panic!("one cluster: {:?}", seen.clusters);
    };
    assert_eq!(view.cluster, "shop");
    assert_eq!(view.expected_from, ExpectedFrom::Index);
    assert_eq!(view.objects.len(), 6);

    let secret = by_name(view, "web-db");
    assert_eq!(secret.presence, Presence::Missing);
    assert_eq!(secret.rid.to_string(), "Secret/web-db@web");
    assert!(secret.named);
    assert_eq!(secret.package.as_deref(), Some("web/web"));
    assert_eq!(secret.content, None);

    let config = by_name(view, "web-config");
    assert_eq!(config.presence, Presence::Present);
    assert_eq!(config.content, Some(DriftVerdict::InSync));
    assert_eq!(config.readiness, Readiness::NotApplicable);

    let extra = by_name(view, "web-extra");
    assert!(matches!(extra.content, Some(DriftVerdict::Drifted { .. })));

    let job = by_name(view, "web-migrate");
    assert_eq!(job.presence, Presence::Present);
    assert_eq!(job.readiness, Readiness::NotReady("0 succeeded".into()));
    assert_eq!(job.depends_on, [h(SECRET), h(CONFIG)]);

    let namespace = by_name(view, "web");
    assert_eq!(namespace.package, None);
    assert_eq!(namespace.rid.to_string(), "Namespace/web");

    let needed_by: Vec<String> = view
        .needed_by(&h(SECRET))
        .iter()
        .map(|o| o.rid.to_string())
        .collect();
    assert_eq!(needed_by, ["Job.batch/web-migrate@web"]);
    assert_eq!(at_risk(view), BTreeSet::from([h(JOB)]));
}

/// An object the account may not list is not checked, never missing.
#[tokio::test]
async fn an_object_of_a_kind_the_account_cannot_list_is_unknown() {
    let index = index(true);
    let mut objects = live_objects();
    objects.push(record(Some(&index), ""));
    let api = FakeApi::new(objects);
    api.fail_next("/api/v1/secrets", u32::MAX, 403);

    let seen = observe_fake(&api, ObserveScope::All).await;

    assert_eq!(seen.unreadable, ["secrets"]);
    let view = &seen.clusters[0];
    assert_eq!(by_name(view, "web-db").presence, Presence::Unknown);
    assert!(at_risk(view).is_empty());
}

/// A record written before names carries none. A missing object that this
/// machine's store does not hold shows the start of its hash, and objects
/// on the cluster take their names from the live objects.
#[tokio::test]
async fn a_record_without_names_names_live_objects_from_the_cluster() {
    let index = index(false);
    let mut objects = live_objects();
    objects.push(record(Some(&index), ""));
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    let view = &seen.clusters[0];
    let missing: Vec<&ObjectView> = view
        .objects
        .iter()
        .filter(|o| o.presence == Presence::Missing)
        .collect();
    let [secret] = missing.as_slice() else {
        panic!("one missing object: {missing:?}");
    };
    assert!(!secret.named);
    assert_eq!(secret.rid.to_string(), "Unknown/(hash: ssssssssssss...)");
    assert_eq!(by_name(view, "web-config").rid.kind, "ConfigMap");
}

/// Without names, the local store names a missing object when it has the
/// build, and Kix looks up only the hashes it cannot name otherwise.
#[test]
fn a_record_without_names_names_a_missing_object_from_the_store() {
    let objects: Vec<DynamicObject> = live_objects()
        .into_iter()
        .map(|o| serde_json::from_value(o).unwrap())
        .collect();
    let live = Live::of(&objects);
    let record = Record {
        identity_hash: Some(h(ROOT)),
        package_index: Some(index(false)),
        ..Record::default()
    };
    let secret = ResourceId {
        group: String::new(),
        kind: "Secret".into(),
        namespace: "web".into(),
        name: "web-db".into(),
    };

    let view = view("shop".into(), record, &live, &Apis::default(), |hashes| {
        assert_eq!(hashes, [h(SECRET).as_str()]);
        HashMap::from([(h(SECRET), StoreEntry::Resource(secret.clone()))])
    });

    let missing = by_name(&view, "web-db");
    assert_eq!(missing.presence, Presence::Missing);
    assert_eq!(missing.rid, secret);
    assert!(missing.named);
}

/// An older version of an object is live under another identity hash. It
/// is not missing.
#[test]
fn an_object_live_under_another_hash_is_present() {
    let mut objects = live_objects();
    objects.push(object("v1", "Secret", "web", "web-db", 'o', &[], true));
    let objects: Vec<DynamicObject> = objects
        .into_iter()
        .map(|o| serde_json::from_value(o).unwrap())
        .collect();
    let record = Record {
        identity_hash: Some(h(ROOT)),
        package_index: Some(index(true)),
        ..Record::default()
    };

    let view = view(
        "shop".into(),
        record,
        &Live::of(&objects),
        &Apis::default(),
        |_| unreachable!(),
    );

    assert_eq!(by_name(&view, "web-db").presence, Presence::Present);
}

/// A record without a package index falls back to following
/// `kix.run/depends-on` from the record's object. A dependency that is the
/// object's SOPS file, or that the store holds as a file, is not an object.
#[test]
fn a_record_without_an_index_follows_depends_on() {
    let sops = h('f');
    let script = h('x');
    let mut objects = live_objects();
    let job = objects
        .iter_mut()
        .find(|o| o["kind"] == "Job")
        .expect("the Job");
    job["metadata"]["annotations"][keys::DEPENDS_ON] = json!(format!(
        "requires:{},{},{},{}",
        h(SECRET),
        h(CONFIG),
        sops,
        script
    ));
    job["metadata"]["annotations"][keys::SOPS_SOURCE] =
        json!(format!("/nix/store/{sops}-web-db.sops.yaml"));
    objects.push(record(
        None,
        &[INSTANCE, CONFIG, EXTRA, JOB, NAMESPACE].map(h).join(","),
    ));
    let objects: Vec<DynamicObject> = objects
        .into_iter()
        .map(|o| serde_json::from_value(o).unwrap())
        .collect();
    let record = Record::of(objects.last().unwrap());
    assert_eq!(record.package_index, None);

    let view = view(
        "shop".into(),
        record,
        &Live::of(&objects),
        &Apis::default(),
        |hashes| {
            let mut hashes = hashes.to_vec();
            hashes.sort();
            assert_eq!(hashes, [sops.as_str(), h(SECRET).as_str(), script.as_str()]);
            HashMap::from([(script.clone(), StoreEntry::Other)])
        },
    );

    assert_eq!(view.expected_from, ExpectedFrom::DependsOn);
    let missing: Vec<String> = view
        .objects
        .iter()
        .filter(|o| o.presence == Presence::Missing)
        .map(|o| o.identity_hash.clone())
        .collect();
    assert_eq!(missing, [h(SECRET)]);
    assert_eq!(view.objects.len(), 6);
    assert_eq!(
        by_name(&view, "web-config").package.as_deref(),
        Some("web/web")
    );
}

/// A record with no index whose own object is gone gives no list of
/// objects, so nothing counts as missing.
#[test]
fn a_record_with_nothing_to_follow_lists_no_objects() {
    let record = Record {
        identity_hash: Some(h(ROOT)),
        ..Record::default()
    };
    let view = view(
        "shop".into(),
        record,
        &Live::of(&[]),
        &Apis::default(),
        |_| unreachable!(),
    );
    assert_eq!(view.expected_from, ExpectedFrom::Nothing);
    assert!(view.objects.is_empty());
}

/// Each Kix cluster with a current record gets a view, and a named cluster
/// with none gets no view.
#[tokio::test]
async fn every_cluster_with_a_current_record_gets_a_view() {
    let index = index(true);
    let mut objects = live_objects();
    objects.push(record(Some(&index), ""));
    let api = FakeApi::new(objects);

    assert_eq!(
        observe_fake(&api, ObserveScope::All)
            .await
            .clusters
            .iter()
            .map(|c| c.cluster.as_str())
            .collect::<Vec<_>>(),
        ["shop"]
    );
    assert!(
        observe_fake(&api, ObserveScope::Cluster("other"))
            .await
            .clusters
            .is_empty()
    );
}

/// Read the Active record and the Deployment that Kix 0.10.0 left on a
/// cluster (`tests/fixtures/cluster-state/0.10.0`). Its package index names
/// objects without their API group.
fn state_from_0_10_0() -> (Record, Value) {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/cluster-state/0.10.0");
    let read = |file: &str| -> Value {
        serde_json::from_str(&std::fs::read_to_string(dir.join(file)).unwrap()).unwrap()
    };
    let Value::Array(records) = read("activations.json") else {
        panic!("activations.json holds a list");
    };
    let active = records
        .iter()
        .map(|r| Record::of(&serde_json::from_value(r.clone()).unwrap()))
        .find(|r| r.phase == "Active")
        .unwrap();
    (active, read("deployment.json"))
}

fn served(groups: &[&str], kind: &str) -> Vec<(ApiResource, Scope)> {
    groups
        .iter()
        .map(|g| {
            let gvk = kube::api::GroupVersionKind::gvk(g, "v1", kind);
            (ApiResource::from_gvk(&gvk), Scope::Namespaced)
        })
        .collect()
}

/// An index written by Kix 0.10.0 does not say an object's API group. A
/// Deployment live only under an older identity hash is found through the
/// one group that serves `Deployment`, and is present. When several groups
/// serve the kind, Kix reports the object as ambiguous: neither missing nor
/// looked up in a guessed group.
#[test]
fn an_object_from_an_index_without_groups_is_found_through_discovery() {
    let (record, mut deployment) = state_from_0_10_0();
    let hash = keys::IDENTITY_HASH;
    assert!(
        matches!(
            record.package_index.as_ref().unwrap().name_of(
                deployment["metadata"]["annotations"][hash]
                    .as_str()
                    .unwrap()
            ),
            Some(IndexedName::GroupUnknown(_))
        ),
        "the 0.10.0 index records no groups"
    );
    deployment["metadata"]["annotations"][hash] = json!("o".repeat(32));
    let objects: Vec<DynamicObject> = vec![serde_json::from_value(deployment).unwrap()];
    let web = |apis: &Apis| {
        let view = view(
            "fixtures".into(),
            record.clone(),
            &Live::of(&objects),
            apis,
            |_| HashMap::new(),
        );
        by_name(&view, "fixture-web").clone()
    };

    let one = Apis::of(&served(&["apps"], "Deployment"), &[]);
    let found = web(&one);
    assert_eq!(found.presence, Presence::Present);
    assert_eq!(found.rid.group, "apps");

    let two = Apis::of(&served(&["apps", "apps.example.com"], "Deployment"), &[]);
    assert_eq!(web(&two).presence, Presence::Ambiguous);
}
