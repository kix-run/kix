use std::collections::BTreeMap;

use kube::api::{Api, DynamicObject};
use serde_json::{Value, json};

use super::*;
use crate::cluster::fake_api::FakeApi;
use crate::cluster::revision::{Revision, RevisionMap, RevisionObject, RevisionSpec, Slot};
use crate::manifest::types::ResourceId;

const RECORD: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaanew";
/// The record of Kix cluster `b`, which an older Kix still deploys.
const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbold";
/// The record of this Kix cluster `a` an older Kix wrote.
const OWN_OLD: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaold";

fn entry(manager: &str, operation: &str) -> Value {
    json!({
        "manager": manager,
        "operation": operation,
        "apiVersion": "v1",
        "fieldsType": "FieldsV1",
        "fieldsV1": { "f:data": { "f:k": {} } },
    })
}

fn config_map(annotations: Value, entries: Vec<Value>) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "cm",
            "namespace": "app",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": annotations,
            "managedFields": entries,
        },
        "data": { "k": "v" },
    })
}

fn config_maps(client: kube::Client) -> Api<DynamicObject> {
    let resource =
        kube::api::ApiResource::from_gvk(&kube::api::GroupVersionKind::gvk("", "v1", "ConfigMap"));
    Api::namespaced_with(client, "app", &resource)
}

fn object(value: &Value) -> DynamicObject {
    serde_json::from_value(value.clone()).unwrap()
}

fn record(name: &str, cluster: &str, hash: &str, map: Option<&RevisionMap>) -> Value {
    let mut status = json!({ "phase": "Active" });
    if let Some(map) = map {
        status["revisions"] = map.to_value();
    }
    json!({
        "apiVersion": crate::manifest::keys::API_VERSION,
        "kind": "Activation",
        "metadata": {
            "name": name,
            "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): cluster },
            "annotations": { (keys::IDENTITY_HASH): hash },
        },
        "status": status,
    })
}

/// The revision of Kix cluster `c` that names `cm`, and the map that names
/// it.
fn c_revision() -> (Revision, RevisionMap) {
    let revision = Revision::new(RevisionSpec::new(
        "c",
        Slot::ClusterLevel,
        vec![RevisionObject::of_id(
            "i1",
            &ResourceId::new("", "ConfigMap", "app", "cm"),
        )],
    ));
    let map = RevisionMap {
        instances: BTreeMap::new(),
        cluster_level: revision.name.clone(),
        kept_orphans: None,
    };
    (revision, map)
}

/// The records on the Kubernetes cluster: `a-old` of this Kix cluster and
/// `b-old` of `b`, both written by an older Kix, and `c-1` of `c`, which has
/// revisions that name `cm`.
fn records() -> Vec<Value> {
    let (_, map) = c_revision();
    vec![
        record("a-old", "a", OWN_OLD, None),
        record("b-old", "b", OTHER, None),
        record("c-1", "c", "cccccccccccccccccccccccccccccc01", Some(&map)),
    ]
}

/// The tenancy of Kix cluster `a`. With `with_c`, Kix cluster `c` names
/// `cm` through its revisions.
fn tenancy(with_c: bool) -> Tenancy {
    let objects: Vec<DynamicObject> = records().iter().map(object).collect();
    let (revision, _) = c_revision();
    let revisions: Vec<Revision> = if with_c { vec![revision] } else { Vec::new() };
    Tenancy::fixture_of_state("a", &BTreeMap::new(), &objects, &revisions)
}

/// Apply `ops` to `value` with the fake's JSON patch, so a test reads what
/// the object holds after the write.
async fn patched(value: &Value, ops: &[Value]) -> Value {
    let api = FakeApi::new([value.clone()]);
    let client = api.client();
    let cms = config_maps(client);
    let patch = kube::api::Patch::<Value>::Json(serde_json::from_value(json!(ops)).unwrap());
    cms.patch("cm", &kube::api::PatchParams::default(), &patch)
        .await
        .unwrap();
    api.object("ConfigMap", "cm").unwrap()
}

fn managers(value: &Value) -> Vec<String> {
    value["metadata"]["managedFields"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|e| {
            format!(
                "{}:{}",
                e["manager"].as_str().unwrap(),
                e["operation"].as_str().unwrap()
            )
        })
        .collect()
}

/// Which objects need the migration write, and what it leaves. The entry
/// under `kix` moves to this cluster only on an object a record of it names
/// and that every other Kix cluster naming it holds under its own entry.
/// A note naming a cluster an older Kix deploys keeps both notes and the
/// entries under `kix`.
#[tokio::test]
async fn which_objects_need_the_write_and_what_it_leaves() {
    let a = FieldManager::of("a");
    struct Case {
        name: &'static str,
        annotations: Value,
        entries: Vec<Value>,
        with_c: bool,
        /// `None` when the object needs no write.
        managers: Option<Vec<&'static str>>,
        note: Option<&'static str>,
        applied: Option<&'static str>,
    }
    let notes = json!({
        (keys::ACTIVATIONS): OWN_OLD,
        (keys::APPLIED_HASH): "h1",
        (keys::IDENTITY_HASH): "i1",
    });
    let shared = json!({
        (keys::ACTIVATIONS): format!("{OTHER},{OWN_OLD}"),
        (keys::APPLIED_HASH): "h1",
        (keys::IDENTITY_HASH): "i1",
    });
    let cases = [
        Case {
            name: "tidied already",
            annotations: json!({ (keys::IDENTITY_HASH): "i1" }),
            entries: vec![entry("kix/a", "Apply")],
            with_c: false,
            managers: None,
            note: None,
            applied: None,
        },
        Case {
            name: "both notes and both entries under kix",
            annotations: notes.clone(),
            entries: vec![
                entry("kix", "Apply"),
                entry("kix", "Update"),
                entry("kubectl", "Update"),
            ],
            with_c: false,
            managers: Some(vec!["kix/a:Apply", "kubectl:Update"]),
            note: None,
            applied: None,
        },
        Case {
            name: "the Update entry before the Apply entry",
            annotations: notes.clone(),
            entries: vec![entry("kix", "Update"), entry("kix", "Apply")],
            with_c: false,
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
            applied: None,
        },
        Case {
            name: "an own Apply entry beside the one under kix",
            annotations: notes.clone(),
            entries: vec![entry("kix", "Apply"), entry("kix/a", "Apply")],
            with_c: false,
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
            applied: None,
        },
        Case {
            name: "a key of a retired domain",
            annotations: json!({
                (keys::IDENTITY_HASH): "i1",
                (crate::legacy_domain::legacy_spellings(keys::IDENTITY_HASH)[0].clone()): "old",
            }),
            entries: vec![entry("kix/a", "Apply")],
            with_c: false,
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
            applied: None,
        },
        Case {
            name: "the note names a record of a Kix cluster an older Kix deploys",
            annotations: shared.clone(),
            entries: vec![entry("kix", "Apply"), entry("kix", "Update")],
            with_c: false,
            managers: Some(vec!["kix:Apply", "kix:Update"]),
            note: Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaanew,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbold"),
            applied: Some("h1"),
        },
        Case {
            name: "a kept note that names the deploying record already",
            annotations: json!({
                (keys::ACTIVATIONS): format!("{RECORD},{OTHER}"),
                (keys::APPLIED_HASH): "h1",
                (keys::IDENTITY_HASH): "i1",
            }),
            entries: vec![entry("kix", "Apply"), entry("kix/a", "Apply")],
            with_c: false,
            managers: None,
            note: None,
            applied: None,
        },
        Case {
            name: "no record of this cluster names the object",
            annotations: json!({ (keys::IDENTITY_HASH): "i1" }),
            entries: vec![entry("kix", "Apply")],
            with_c: false,
            managers: None,
            note: None,
            applied: None,
        },
        Case {
            name: "another Kix cluster names it and holds its fields under kix",
            annotations: notes.clone(),
            entries: vec![entry("kix", "Apply"), entry("kix", "Update")],
            with_c: true,
            managers: Some(vec!["kix:Apply"]),
            note: None,
            applied: None,
        },
        Case {
            name: "another Kix cluster names it and has its own entry",
            annotations: notes.clone(),
            entries: vec![entry("kix", "Apply"), entry("kix/c", "Apply")],
            with_c: true,
            managers: Some(vec!["kix/a:Apply", "kix/c:Apply"]),
            note: None,
            applied: None,
        },
    ];
    for case in cases {
        let value = config_map(case.annotations.clone(), case.entries.clone());
        let tenancy = tenancy(case.with_c);
        let found = needed(&object(&value), &a, &tenancy, Some(RECORD));
        let Some(expected) = case.managers else {
            assert!(found.is_none(), "{}: {found:?}", case.name);
            continue;
        };
        let ops = found.unwrap_or_else(|| panic!("{}: needs the write", case.name));
        let after = patched(&value, &ops).await;
        assert_eq!(managers(&after), expected, "{}", case.name);
        let annotations = &after["metadata"]["annotations"];
        assert_eq!(
            annotations[keys::ACTIVATIONS].as_str(),
            case.note,
            "{}",
            case.name
        );
        assert_eq!(
            annotations[keys::APPLIED_HASH].as_str(),
            case.applied,
            "{}",
            case.name
        );
        assert!(
            annotations
                .as_object()
                .unwrap()
                .keys()
                .all(|k| !crate::legacy_domain::is_legacy_key(k)),
            "{}",
            case.name
        );
        assert_eq!(annotations[keys::IDENTITY_HASH], "i1", "{}", case.name);
        assert!(
            needed(&object(&after), &a, &tenancy, Some(RECORD)).is_none(),
            "{}: the write leaves an object that needs no other",
            case.name
        );
    }
}

async fn judge(api: &FakeApi) -> PruneGuard {
    let client = api.client();
    let found = crate::cluster::discovery::discover_resources(&client)
        .await
        .unwrap();
    let opened = crate::cluster::activation::Records::open(&client, &found).unwrap();
    PruneGuard::new(client, opened, "a")
}

async fn write_cm(api: &FakeApi, expect: Option<&str>) -> Result<Written, WriteError> {
    let cms = config_maps(api.client());
    let judge = judge(api).await;
    write(&Write {
        api: &cms,
        name: "cm",
        resource: "ConfigMap/cm",
        manager: &FieldManager::of("a"),
        record: Some(RECORD),
        judge: &judge,
        expect,
    })
    .await
}

/// A fake API server with the records of `a` and `b` and the ConfigMap.
fn fake(annotations: Value, entries: Vec<Value>) -> FakeApi {
    FakeApi::new(
        records()
            .into_iter()
            .take(2)
            .chain([config_map(annotations, entries)]),
    )
}

/// The write tests the `resourceVersion` it read, so it changes the object
/// once and a second call finds nothing to do.
#[tokio::test]
async fn the_write_moves_an_object_once() {
    let api = fake(
        json!({ (keys::ACTIVATIONS): OWN_OLD, (keys::APPLIED_HASH): "h", (keys::IDENTITY_HASH): "i" }),
        vec![entry("kix", "Apply"), entry("kix", "Update")],
    );
    let before = api.object("ConfigMap", "cm").unwrap()["metadata"]["resourceVersion"].clone();
    let written = write_cm(&api, None).await.unwrap();
    let after = api.object("ConfigMap", "cm").unwrap();
    assert_eq!(
        written,
        Written::Rewritten {
            resource_version: after["metadata"]["resourceVersion"]
                .as_str()
                .unwrap()
                .to_string()
        }
    );
    assert_ne!(after["metadata"]["resourceVersion"], before);
    assert_eq!(managers(&after), ["kix/a:Apply"]);
    assert_eq!(write_cm(&api, None).await.unwrap(), Written::NothingToDo);
}

/// An object that changes between the read and the write is read again and
/// the write built again from what it holds then. With the version the
/// plan read, the same change fails the write as changed since the plan.
#[tokio::test]
async fn a_change_between_the_read_and_the_write_is_read_again() {
    let notes = json!({ (keys::ACTIVATIONS): OWN_OLD, (keys::IDENTITY_HASH): "i" });
    let api = fake(notes.clone(), vec![entry("kix", "Apply")]);
    // Another manager adds an entry before the first index, which moves the
    // entry under `kix`.
    api.after_get("cm", |obj| {
        let entries = obj["metadata"]["managedFields"].as_array_mut().unwrap();
        entries.insert(0, entry("kubectl", "Update"));
    });
    assert!(matches!(
        write_cm(&api, None).await.unwrap(),
        Written::Rewritten { .. }
    ));
    let after = api.object("ConfigMap", "cm").unwrap();
    assert_eq!(managers(&after), ["kubectl:Update", "kix/a:Apply"]);
    assert!(
        after["metadata"]["annotations"]
            .get(keys::ACTIVATIONS)
            .is_none()
    );

    let api = fake(notes, vec![entry("kix", "Apply")]);
    let read = api.object("ConfigMap", "cm").unwrap()["metadata"]["resourceVersion"]
        .as_str()
        .unwrap()
        .to_string();
    api.after_get("cm", |obj| {
        obj["data"]["k"] = json!("changed");
    });
    let err = write_cm(&api, Some(&read)).await.unwrap_err();
    assert!(matches!(err, WriteError::ChangedSincePlan { .. }), "{err}");
}

/// An object that something keeps changing fails with an error that says
/// so, after a bounded number of reads.
#[tokio::test]
async fn an_object_that_keeps_changing_fails() {
    let api = fake(
        json!({ (keys::ACTIVATIONS): OWN_OLD }),
        vec![entry("kix", "Apply")],
    );
    for _ in 0..20 {
        api.after_get("cm", |obj| {
            obj["data"]["k"] = json!("changed");
        });
    }
    let err = write_cm(&api, None).await.unwrap_err();
    assert!(matches!(err, WriteError::KeepsChanging { .. }), "{err}");
    assert!(err.to_string().contains("ConfigMap/cm"), "{err}");
}

/// An object that is gone needs nothing.
#[tokio::test]
async fn a_gone_object_needs_nothing() {
    let api = FakeApi::new(records().into_iter().take(2));
    assert_eq!(write_cm(&api, None).await.unwrap(), Written::NothingToDo);
}
