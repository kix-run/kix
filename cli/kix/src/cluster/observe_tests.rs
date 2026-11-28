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
        imports: Default::default(),
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
        fieldsv1::applied_content_hash(
            &dynamic,
            &crate::cluster::field_manager::FieldManager::unmigrated("a"),
        )
        .unwrap()
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
    config["metadata"]["finalizers"] = serde_json::json!(["example.com/hold"]);
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    let config = by_name(&seen.clusters[0], "web-config");
    assert_eq!(
        config.readiness,
        Readiness::NotReady("being deleted, waiting for example.com/hold".into())
    );
    assert_eq!(
        config.deleting,
        Some(Deleting {
            since: "2026-11-24T15:54:00Z".into(),
            finalizers: vec!["example.com/hold".into()],
        })
    );
    assert_eq!(by_name(&seen.clusters[0], "web-extra").deleting, None);
    assert!(seen.clusters[0].leaving.is_empty());
}

/// An object of this Kix cluster that left the build and is being deleted
/// is listed as leaving. One that is not being deleted, and one of another
/// Kix cluster, are not.
#[tokio::test]
async fn an_object_that_left_the_build_and_is_being_deleted_is_leaving() {
    let index = index(true);
    let mut objects = live_objects();
    objects.push(record(Some(&index), ""));
    let mut gone = object("v1", "ConfigMap", "web", "old-config", 'o', &[], true);
    gone["metadata"]["deletionTimestamp"] = json!("2026-11-24T15:54:00Z");
    gone["metadata"]["finalizers"] = json!(["example.com/hold"]);
    objects.push(gone);
    objects.push(object(
        "v1",
        "ConfigMap",
        "web",
        "kept-orphan",
        'k',
        &[],
        true,
    ));
    let mut other = object("v1", "ConfigMap", "web", "other-config", 'x', &[], true);
    other["metadata"]["annotations"][keys::ACTIVATIONS] = json!(h('y'));
    other["metadata"]["deletionTimestamp"] = json!("2026-11-24T15:54:00Z");
    other["metadata"]["finalizers"] = json!(["example.com/hold"]);
    objects.push(other);
    let mut other_record = record(None, "");
    other_record["metadata"]["name"] = json!("lab-yyyyyyyyyyyy");
    other_record["metadata"]["labels"][keys::CLUSTER_LABEL] = json!("lab");
    other_record["metadata"]["annotations"][keys::IDENTITY_HASH] = json!(h('y'));
    objects.push(other_record);
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    assert_eq!(
        seen.clusters[0].leaving,
        vec![Leaving {
            rid: ResourceId::new("", "ConfigMap", "web", "old-config"),
            package: Some("web/web".into()),
            deleting: Deleting {
                since: "2026-11-24T15:54:00Z".into(),
                finalizers: vec!["example.com/hold".into()],
            },
        }]
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

    let view = view(
        "shop".into(),
        record.clone(),
        record.package_index.clone(),
        &live,
        &crate::cluster::edges::Edges::default(),
        &Apis::default(),
        &AppliedHashes::from_annotations(),
        &crate::cluster::field_manager::FieldManager::unmigrated("shop"),
        |hashes| {
            assert_eq!(hashes, [h(SECRET).as_str()]);
            HashMap::from([(h(SECRET), StoreEntry::Resource(secret.clone()))])
        },
    );

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
        record.clone(),
        record.package_index.clone(),
        &Live::of(&objects),
        &crate::cluster::edges::Edges::default(),
        &Apis::default(),
        &AppliedHashes::from_annotations(),
        &crate::cluster::field_manager::FieldManager::unmigrated("shop"),
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
        record.clone(),
        record.package_index.clone(),
        &Live::of(&objects),
        &crate::cluster::edges::Edges::default(),
        &Apis::default(),
        &AppliedHashes::from_annotations(),
        &crate::cluster::field_manager::FieldManager::unmigrated("shop"),
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
        .map(|o| o.hash.clone())
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
        record.clone(),
        record.package_index.clone(),
        &Live::of(&[]),
        &crate::cluster::edges::Edges::default(),
        &Apis::default(),
        &AppliedHashes::from_annotations(),
        &crate::cluster::field_manager::FieldManager::unmigrated("shop"),
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

/// Return an Active record and a Deployment it deploys. The record's package
/// index names objects without their API group, as prereleases of Kix 0.10.0
/// wrote it before revisions.
fn state_with_index_without_groups() -> (Record, Value) {
    let hash = |tail: &str| "a".repeat(32 - tail.len()) + tail;
    let name = |kind: &str, ns: &str, name: &str| {
        ObjectName(kind.to_string(), ns.to_string(), name.to_string())
    };
    let mut record = Record::of(
        &serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": {
                "name": "fixtures-act000000000",
                "labels": { (keys::CLUSTER_LABEL): "fixtures" },
                "annotations": { (keys::IDENTITY_HASH): hash("act") },
            },
            "spec": { "cluster": "fixtures" },
            "status": { "phase": "Active" },
        }))
        .unwrap(),
    );
    record.package_index = Some(RecordPackageIndex {
        format: FORMAT,
        packages: BTreeMap::from([(
            "drift-fixtures/fixtures".to_string(),
            IndexedPackage {
                instance: hash("api"),
                resources: vec![hash("web")],
            },
        )]),
        cluster_level: vec![hash("ns")],
        names: BTreeMap::from([
            (hash("ns"), name("Namespace", "", "drift-fixtures")),
            (
                hash("api"),
                name(
                    crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
                    "drift-fixtures",
                    "fixtures",
                ),
            ),
            (
                hash("web"),
                name("Deployment", "drift-fixtures", "fixture-web"),
            ),
        ]),
        groups: None,
        imports: Default::default(),
    });
    let deployment = json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": "fixture-web",
            "namespace": "drift-fixtures",
            "annotations": { (keys::IDENTITY_HASH): hash("web") },
        },
        "spec": {
            "replicas": 1,
            "selector": { "matchLabels": { "app": "fixture-web" } },
            "template": {
                "metadata": { "labels": { "app": "fixture-web" } },
                "spec": { "containers": [{ "name": "web", "image": "nginx:1.27.0" }] },
            },
        },
    });
    (record, deployment)
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

/// An index written before revisions may not say an object's API group. A
/// Deployment live only under an older identity hash is found through the
/// one group that serves `Deployment`, and is present. When several groups
/// serve the kind, Kix reports the object as ambiguous: neither missing nor
/// looked up in a guessed group.
#[test]
fn an_object_from_an_index_without_groups_is_found_through_discovery() {
    let (record, mut deployment) = state_with_index_without_groups();
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
        "the index records no groups"
    );
    deployment["metadata"]["annotations"][hash] = json!("o".repeat(32));
    let objects: Vec<DynamicObject> = vec![serde_json::from_value(deployment).unwrap()];
    let web = |apis: &Apis| {
        let view = view(
            "fixtures".into(),
            record.clone(),
            record.package_index.clone(),
            &Live::of(&objects),
            &crate::cluster::edges::Edges::default(),
            apis,
            &AppliedHashes::from_annotations(),
            &crate::cluster::field_manager::FieldManager::unmigrated("shop"),
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

/// `kix status` judges a Service by its type: a ClusterIP Service has no
/// readiness, and a `LoadBalancer` Service is not ready until its load
/// balancer gives it an address.
#[test]
fn a_load_balancer_service_without_an_address_is_not_ready() {
    let service = |spec: Value, status: Value| -> DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {"name": "hello", "namespace": "demo"},
            "spec": spec,
            "status": status,
        }))
        .unwrap()
    };
    let cluster_ip = service(json!({"type": "ClusterIP"}), json!({}));
    assert_eq!(readiness_of(&cluster_ip), Readiness::NotApplicable);
    let pending = service(json!({"type": "LoadBalancer"}), json!({"loadBalancer": {}}));
    assert!(matches!(readiness_of(&pending), Readiness::NotReady(_)));
    let served = service(
        json!({"type": "LoadBalancer"}),
        json!({"loadBalancer": {"ingress": [{"hostname": "lb.example.com"}]}}),
    );
    assert_eq!(readiness_of(&served), Readiness::Ready);
}

/// Return `index` with one more object of package `web/web`.
fn with_object(
    mut index: RecordPackageIndex,
    c: char,
    kind: &str,
    name: &str,
    group: &str,
) -> RecordPackageIndex {
    index
        .packages
        .get_mut("web/web")
        .unwrap()
        .resources
        .push(h(c));
    index.names.insert(
        h(c),
        ObjectName(kind.to_string(), "web".to_string(), name.to_string()),
    );
    if !group.is_empty() {
        index
            .groups
            .get_or_insert_with(BTreeMap::new)
            .insert(h(c), group.to_string());
    }
    index
}

/// A deploy record that failed at `at` with `reason`, and whose build is
/// `index`.
fn failed_record(name: &str, index: &RecordPackageIndex, at: &str) -> Value {
    let mut failed = record(Some(index), "");
    failed["metadata"]["name"] = json!(name);
    failed["metadata"]["annotations"][keys::IDENTITY_HASH] = json!(h('f'));
    failed["metadata"]["annotations"]
        .as_object_mut()
        .unwrap()
        .remove(keys::DEPLOYED_AT);
    failed["status"]["phase"] = json!("Failed");
    failed["status"]["failure"] = json!({ "at": at, "reason": "1 resource failed" });
    failed
}

fn pending_service() -> Value {
    let mut service = object("v1", "Service", "web", "pending", 'p', &[], true);
    service["spec"] = json!({ "type": "LoadBalancer" });
    service["status"] = json!({ "loadBalancer": {} });
    service
}

/// After a deploy fails, the previous record stays current. `kix status`
/// still reads the failed record, and checks the objects only its build
/// has, such as a Service that got no address. A record that failed before
/// the current one was deployed is history and is not reported.
#[tokio::test]
async fn a_deploy_that_failed_after_the_current_one_is_read() {
    let current = index(true);
    let failed_build = with_object(index(true), 'p', "Service", "pending", "");
    let mut objects = live_objects();
    objects.push(record(Some(&current), ""));
    objects.push(pending_service());
    objects.push(failed_record(
        "shop-ffffffffffff",
        &failed_build,
        "2026-11-12T11:00:00Z",
    ));
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    let view = &seen.clusters[0];
    assert_eq!(view.record.name, "shop-rrrrrrrrrrrr");
    let failed = view.failed.as_ref().expect("the failed deploy");
    assert_eq!(failed.record.name, "shop-ffffffffffff");
    let names: Vec<&str> = failed.objects.iter().map(|o| o.rid.name.as_str()).collect();
    assert_eq!(names, ["pending"], "objects both builds have are left out");
    assert!(matches!(
        failed.objects[0].readiness,
        Readiness::NotReady(_)
    ));

    let mut objects = live_objects();
    objects.push(record(Some(&current), ""));
    objects.push(failed_record(
        "shop-ffffffffffff",
        &failed_build,
        "2026-11-12T09:00:00Z",
    ));
    let api = FakeApi::new(objects);
    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;
    assert!(seen.clusters[0].failed.is_none());
}

/// `kix status` describes a workload that is not ready from its pods, as a
/// deploy's wait does: here a StatefulSet whose pod is held on an older
/// revision.
#[tokio::test]
async fn status_describes_a_workload_from_its_pods() {
    let current = with_object(index(true), 'q', "StatefulSet", "db", "apps");
    let mut objects = live_objects();
    objects.push(record(Some(&current), ""));
    let mut sts = object("apps/v1", "StatefulSet", "web", "db", 'q', &[], true);
    sts["metadata"]["uid"] = json!("sts-uid");
    sts["metadata"]["generation"] = json!(4);
    sts["spec"] = json!({ "replicas": 1, "selector": { "matchLabels": { "app": "db" } } });
    sts["status"] = json!({
        "observedGeneration": 4,
        "replicas": 1,
        "readyReplicas": 0,
        "updatedReplicas": 0,
        "updateRevision": "db-good",
    });
    objects.push(sts);
    objects.push(json!({
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": "db-0",
            "namespace": "web",
            "labels": { "app": "db", "controller-revision-hash": "db-bad" },
            "ownerReferences": [{ "uid": "sts-uid" }],
        },
        "status": {
            "phase": "Running",
            "conditions": [{ "type": "Ready", "status": "False" }],
        },
    }));
    let api = FakeApi::new(objects);

    let seen = observe_fake(&api, ObserveScope::Cluster("shop")).await;

    let Readiness::NotReady(reason) = &by_name(&seen.clusters[0], "db").readiness else {
        panic!("the StatefulSet is not ready");
    };
    assert!(
        reason.starts_with("0/1 updated pods ready. Pod db-0 is not ready"),
        "{reason}"
    );
}

/// A Kix cluster read from revisions takes the objects its current deploy
/// should have, and their names, from the revisions its record names. A
/// revision another cluster's record names that is missing is reported, and
/// the views hold what Kix could read.
#[tokio::test]
async fn expected_objects_come_from_the_revisions() {
    use crate::cluster::tenancy_fixture::{Rec, Written, state};
    use crate::manifest::lifecycle::PHASE_ACTIVE;
    let recs = [
        Rec {
            name: "a-cur",
            cluster: "a",
            hash: "acur",
            phase: PHASE_ACTIVE,
            current: true,
            objects: &["web", "gone"],
            ..Rec::default()
        },
        Rec {
            name: "b-cur",
            cluster: "b",
            hash: "bcur",
            phase: PHASE_ACTIVE,
            current: true,
            objects: &["theirs"],
            ..Rec::default()
        },
    ];
    let mut state = state(&recs, |_| Written::Revisions);
    state.objects.retain(|o| o["metadata"]["name"] != "gone");
    let missing = state.revision_named("b-cur", "instance");
    state.remove_revision(&missing);
    let api = FakeApi::new(state.all());

    let seen = observe_fake(&api, ObserveScope::Cluster("a")).await;
    assert!(seen.problems.is_empty(), "{:?}", seen.problems);
    let [view] = seen.clusters.as_slice() else {
        panic!("one cluster: {:?}", seen.clusters);
    };
    assert_eq!(view.expected_from, ExpectedFrom::Index);
    assert_eq!(by_name(view, "web").presence, Presence::Present);
    let gone = by_name(view, "gone");
    assert_eq!(gone.presence, Presence::Missing);
    assert!(gone.named);
    assert_eq!(gone.package.as_deref(), Some("d/app"));

    let seen = observe_fake(&api, ObserveScope::All).await;
    assert_eq!(seen.clusters.len(), 2);
    assert!(
        seen.problems
            .iter()
            .any(|p| p.to_string().contains(&missing)),
        "{:?}",
        seen.problems
    );
}

/// A Kix cluster read from revisions takes what each object depends on
/// from the revisions, so `kix status` says which objects need a missing
/// one when the live objects carry no `kix.run/depends-on` and no
/// `kix.run/identity-hash`.
#[tokio::test]
async fn needed_by_comes_from_the_revisions() {
    use crate::cluster::revision::{Need, Revision, RevisionObject, RevisionSpec, Slot};
    use crate::cluster::tenancy_fixture::{Rec, Written, revision_value, state};
    use crate::manifest::lifecycle::PHASE_ACTIVE;
    let recs = [Rec {
        name: "a-cur",
        cluster: "a",
        hash: "acur",
        phase: PHASE_ACTIVE,
        current: true,
        objects: &["web", "db", "gone"],
        ..Rec::default()
    }];
    let mut state = state(&recs, |_| Written::Revisions);
    let rid = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
    let entry = |name: &str| RevisionObject::of_id(&format!("h-{name}"), &rid(name));
    let instance = Revision::new(RevisionSpec::new(
        "a",
        Slot::Instance {
            namespace: "d".into(),
            name: "app".into(),
            lifecycle: None,
        },
        vec![
            entry("web").with_needs([Need::of(&rid("db"), None), Need::of(&rid("gone"), None)]),
            entry("db"),
            entry("gone"),
        ],
    ));
    let old = state.revision_named("a-cur", "instance");
    state.remove_revision(&old);
    state.revisions.push(revision_value(&instance));
    state.records[0]["status"]["revisions"]["instances"]["d/app"] = json!(instance.name);
    state.objects.retain(|o| o["metadata"]["name"] != "gone");
    for object in &mut state.objects {
        let annotations = object["metadata"]["annotations"].as_object_mut().unwrap();
        annotations.remove(keys::IDENTITY_HASH);
        annotations.remove(keys::DEPENDS_ON);
    }
    let api = FakeApi::new(state.all());

    let seen = observe_fake(&api, ObserveScope::Cluster("a")).await;
    let [view] = seen.clusters.as_slice() else {
        panic!("one cluster: {:?}", seen.clusters);
    };
    let needed_by = |hash: &str| -> Vec<String> {
        view.needed_by(hash)
            .iter()
            .map(|o| o.rid.name.clone())
            .collect()
    };
    assert_eq!(by_name(view, "gone").presence, Presence::Missing);
    assert_eq!(needed_by("h-gone"), ["web"]);
    assert_eq!(needed_by("h-db"), ["web"]);
    assert_eq!(at_risk(view), BTreeSet::from(["h-web".to_string()]));
}

/// The current record and a deploy that failed after it name one object
/// with two hashes and two applied hashes. `kix status`, which has no new
/// build, finds the object by name and judges it by the applied hash it
/// matches: a live object either deploy wrote is in sync, and one neither
/// wrote has drifted from what the current record applied.
#[tokio::test]
async fn status_judges_an_object_by_the_applied_hash_it_matches() {
    use crate::cluster::field_manager::FieldManager;
    use crate::cluster::revision::{
        Revision, RevisionMap, RevisionObject, RevisionSpec, Revisions, Slot,
    };
    use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_FAILED};
    let live = |v: &str| {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "web",
                "namespace": "d",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
                "managedFields": [{
                    "manager": "kix/a", "operation": "Apply", "apiVersion": "v1",
                    "fieldsV1": { "f:data": { "f:k": {} } },
                }],
            },
            "data": { "k": v },
        })
    };
    let applied = |v: &str| {
        let obj: DynamicObject = serde_json::from_value(live(v)).unwrap();
        fieldsv1::applied_content_hash(&obj, &FieldManager::of("a")).unwrap()
    };
    let rid = ResourceId::new("", "ConfigMap", "d", "web");
    let revision = |record: &str, hash: &str, v: &str| {
        let mut r = Revision::new(RevisionSpec::new(
            "a",
            Slot::Instance {
                namespace: "d".into(),
                name: record.into(),
                lifecycle: None,
            },
            vec![RevisionObject::of_id(hash, &rid)],
        ));
        r.applied.insert(hash.into(), applied(v));
        r
    };
    let empty = Revision::new(RevisionSpec::new("a", Slot::ClusterLevel, Vec::new()));
    let (cur, failed) = (
        revision("cur", "h-one", "1"),
        revision("failed", "h-two", "2"),
    );
    let record = |name: &str, phase: &str, at: &str, instance: &Revision| {
        let map = RevisionMap {
            instances: [("d/app".to_string(), instance.name.clone())].into(),
            cluster_level: empty.name.clone(),
            kept_orphans: None,
        };
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": {
                "name": name,
                "creationTimestamp": at,
                "labels": { (keys::CLUSTER_LABEL): "a" },
                "annotations": { (keys::IDENTITY_HASH): format!("rec-{name}") },
            },
            "status": { "phase": phase, "revisions": map.to_value() },
        })
    };
    for (v, in_sync) in [("1", true), ("2", true), ("by hand", false)] {
        let api = FakeApi::new([
            record("a-cur", PHASE_ACTIVE, "2026-11-01T00:00:00Z", &cur),
            record("a-failed", PHASE_FAILED, "2026-11-02T00:00:00Z", &failed),
            live(v),
        ]);
        let store = Revisions::new(&api.client());
        for r in [&cur, &failed, &empty] {
            store.create(r).await.unwrap();
            store.write_applied(&r.name, &r.applied).await.unwrap();
        }
        let seen = observe_fake(&api, ObserveScope::Cluster("a")).await;
        let [view] = seen.clusters.as_slice() else {
            panic!("one cluster: {:?}", seen.clusters);
        };
        assert!(view.failed.is_some(), "{v}");
        let web = by_name(view, "web");
        assert_eq!(web.presence, Presence::Present, "{v}");
        assert_eq!(
            matches!(web.content, Some(DriftVerdict::InSync)),
            in_sync,
            "{v}: {:?}",
            web.content
        );
    }
}

/// `kix status` reads an import marker from the revision that lists it
/// under `imports`. Kix writes no object for it, so it is external and not
/// missing, and the object that needs it depends on it and is not at risk.
#[tokio::test]
async fn status_reads_imports_from_the_revisions() {
    use crate::cluster::revision::{
        ImportedObject, Need, Revision, RevisionImport, RevisionObject, RevisionSpec, Slot,
    };
    use crate::cluster::tenancy_fixture::{Rec, Written, revision_value, state};
    use crate::manifest::lifecycle::PHASE_ACTIVE;
    let recs = [Rec {
        name: "a-cur",
        cluster: "a",
        hash: "acur",
        phase: PHASE_ACTIVE,
        current: true,
        objects: &["web", "old"],
        ..Rec::default()
    }];
    let mut state = state(&recs, |_| Written::Revisions);
    let rid = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
    let marker = |name: &str| ResourceId::new(keys::GROUP, "PackageInstance", "d", name);
    let import = RevisionImport {
        namespace: Some("d".into()),
        name: "secret-ref-app-creds".into(),
        hash: "h-import".into(),
        target: Some(ImportedObject {
            api_version: "v1".into(),
            kind: "Secret".into(),
            namespace: Some("d".into()),
            name: "creds".into(),
        }),
        needs: Vec::new(),
    };
    let instance = Revision::new(
        RevisionSpec::new(
            "a",
            Slot::Instance {
                namespace: "d".into(),
                name: "app".into(),
                lifecycle: None,
            },
            vec![
                RevisionObject::of_id("h-web", &rid("web"))
                    .with_needs([Need::of(&marker("secret-ref-app-creds"), None)]),
            ],
        )
        .with_imports([import]),
    );
    let old = state.revision_named("a-cur", "instance");
    state.remove_revision(&old);
    state.revisions.push(revision_value(&instance));
    state.records[0]["status"]["revisions"]["instances"]["d/app"] = json!(instance.name);
    state.objects.retain(|o| o["metadata"]["name"] == "web");
    for object in &mut state.objects {
        let annotations = object["metadata"]["annotations"].as_object_mut().unwrap();
        annotations.remove(keys::IDENTITY_HASH);
        annotations.remove(keys::DEPENDS_ON);
    }
    let api = FakeApi::new(state.all());

    let seen = observe_fake(&api, ObserveScope::Cluster("a")).await;
    let [view] = seen.clusters.as_slice() else {
        panic!("one cluster: {:?}", seen.clusters);
    };
    let imported = by_name(view, "secret-ref-app-creds");
    assert_eq!(imported.presence, Presence::External);
    assert_eq!(imported.readiness, Readiness::NotApplicable);
    assert!(imported.content.is_none());
    assert_eq!(by_name(view, "web").depends_on, ["h-import"]);
    assert!(!at_risk(view).contains("h-web"));
}
