use std::collections::HashSet;
use std::sync::Arc;

use kube::api::{Api, DynamicObject};
use serde_json::{Value, json};

use super::*;
use crate::cluster::fake_api::FakeApi;

const RECORD: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaanew";
const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbold";
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

fn rule(others: &[&str]) -> Rule {
    Rule {
        others: Arc::new(others.iter().map(|s| s.to_string()).collect::<HashSet<_>>()),
        record: Some(RECORD.to_string()),
    }
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

/// Which objects need the migration write, and what it leaves.
#[tokio::test]
async fn which_objects_need_the_write_and_what_it_leaves() {
    let a = FieldManager::of("a");
    struct Case {
        name: &'static str,
        annotations: Value,
        entries: Vec<Value>,
        others: &'static [&'static str],
        /// `None` when the object needs no write.
        managers: Option<Vec<&'static str>>,
        note: Option<&'static str>,
    }
    let notes = json!({
        (keys::ACTIVATIONS): format!("{OWN_OLD}"),
        (keys::APPLIED_HASH): "h1",
        (keys::IDENTITY_HASH): "i1",
    });
    let cases = [
        Case {
            name: "migrated already",
            annotations: json!({ (keys::IDENTITY_HASH): "i1" }),
            entries: vec![entry("kix/a", "Apply")],
            others: &[],
            managers: None,
            note: None,
        },
        Case {
            name: "both notes and both entries under kix",
            annotations: notes.clone(),
            entries: vec![
                entry("kix", "Apply"),
                entry("kix", "Update"),
                entry("kubectl", "Update"),
            ],
            others: &[],
            managers: Some(vec!["kix/a:Apply", "kubectl:Update"]),
            note: None,
        },
        Case {
            name: "the Update entry before the Apply entry",
            annotations: notes.clone(),
            entries: vec![entry("kix", "Update"), entry("kix", "Apply")],
            others: &[],
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
        },
        Case {
            name: "an own Apply entry beside the one under kix",
            annotations: json!({ (keys::IDENTITY_HASH): "i1" }),
            entries: vec![entry("kix", "Apply"), entry("kix/a", "Apply")],
            others: &[],
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
        },
        Case {
            name: "a key of a retired domain",
            annotations: json!({
                (keys::IDENTITY_HASH): "i1",
                (crate::legacy_domain::legacy_spellings(keys::IDENTITY_HASH)[0].clone()): "old",
            }),
            entries: vec![entry("kix/a", "Apply")],
            others: &[],
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
        },
        Case {
            name: "the note names a record of a Kix cluster an older Kix deploys",
            annotations: json!({
                (keys::ACTIVATIONS): format!("{OTHER},{OWN_OLD}"),
                (keys::APPLIED_HASH): "h1",
                (keys::IDENTITY_HASH): "i1",
            }),
            entries: vec![entry("kix", "Apply"), entry("kix", "Update")],
            others: &[OTHER],
            managers: Some(vec!["kix:Apply", "kix:Update"]),
            note: Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaanew,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbold"),
        },
        Case {
            name: "a kept note that names the deploying record already",
            annotations: json!({
                (keys::ACTIVATIONS): format!("{RECORD},{OTHER}"),
                (keys::IDENTITY_HASH): "i1",
            }),
            entries: vec![entry("kix", "Apply"), entry("kix/a", "Apply")],
            others: &[OTHER],
            managers: None,
            note: None,
        },
        Case {
            name: "the note names a Kix cluster that migrated",
            annotations: json!({
                (keys::ACTIVATIONS): format!("{OTHER},{OWN_OLD}"),
                (keys::IDENTITY_HASH): "i1",
            }),
            entries: vec![entry("kix", "Apply")],
            others: &[],
            managers: Some(vec!["kix/a:Apply"]),
            note: None,
        },
    ];
    for case in cases {
        let value = config_map(case.annotations.clone(), case.entries.clone());
        let found = needed(&object(&value), &a, &rule(case.others));
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
        assert!(
            annotations.get(keys::APPLIED_HASH).is_none(),
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
        // The write leaves an object that needs no other.
        assert!(
            needed(&object(&after), &a, &rule(case.others)).is_none(),
            "{}",
            case.name
        );
    }
}

fn cms(api: &FakeApi) -> Api<DynamicObject> {
    config_maps(api.client())
}

/// The write tests the `resourceVersion` it read, so it changes the object
/// once and a second call finds nothing to do.
#[tokio::test]
async fn the_write_moves_an_object_once() {
    let api = FakeApi::new([config_map(
        json!({ (keys::ACTIVATIONS): OWN_OLD, (keys::APPLIED_HASH): "h", (keys::IDENTITY_HASH): "i" }),
        vec![entry("kix", "Apply"), entry("kix", "Update")],
    )]);
    let a = FieldManager::of("a");
    let before = api.object("ConfigMap", "cm").unwrap()["metadata"]["resourceVersion"].clone();
    let written = write(&cms(&api), "cm", "ConfigMap/cm", &a, &rule(&[]))
        .await
        .unwrap();
    assert_eq!(written, Written::Rewritten);
    let after = api.object("ConfigMap", "cm").unwrap();
    assert_ne!(after["metadata"]["resourceVersion"], before);
    assert_eq!(managers(&after), ["kix/a:Apply"]);
    let again = write(&cms(&api), "cm", "ConfigMap/cm", &a, &rule(&[]))
        .await
        .unwrap();
    assert_eq!(again, Written::NothingToDo);
}

/// An object that changes between the read and the write is read again and
/// the write built again from what it holds then.
#[tokio::test]
async fn a_change_between_the_read_and_the_write_is_read_again() {
    let api = FakeApi::new([config_map(
        json!({ (keys::ACTIVATIONS): OWN_OLD, (keys::IDENTITY_HASH): "i" }),
        vec![entry("kix", "Apply")],
    )]);
    // Another manager adds an entry before the first index, which moves the
    // entry under `kix`.
    api.after_get("cm", |obj| {
        let entries = obj["metadata"]["managedFields"].as_array_mut().unwrap();
        entries.insert(0, entry("kubectl", "Update"));
    });
    let written = write(
        &cms(&api),
        "cm",
        "ConfigMap/cm",
        &FieldManager::of("a"),
        &rule(&[]),
    )
    .await
    .unwrap();
    assert_eq!(written, Written::Rewritten);
    let after = api.object("ConfigMap", "cm").unwrap();
    assert_eq!(managers(&after), ["kubectl:Update", "kix/a:Apply"]);
    assert!(
        after["metadata"]["annotations"]
            .get(keys::ACTIVATIONS)
            .is_none()
    );
}

/// An object that something keeps changing fails with an error that says
/// so, after a bounded number of reads.
#[tokio::test]
async fn an_object_that_keeps_changing_fails() {
    let api = FakeApi::new([config_map(
        json!({ (keys::ACTIVATIONS): OWN_OLD }),
        vec![entry("kix", "Apply")],
    )]);
    for _ in 0..20 {
        api.after_get("cm", |obj| {
            obj["data"]["k"] = json!("changed");
        });
    }
    let err = write(
        &cms(&api),
        "cm",
        "ConfigMap/cm",
        &FieldManager::of("a"),
        &rule(&[]),
    )
    .await
    .unwrap_err();
    assert!(matches!(err, WriteError::KeepsChanging { .. }), "{err}");
    assert!(err.to_string().contains("ConfigMap/cm"), "{err}");
}

/// An object that is gone needs nothing.
#[tokio::test]
async fn a_gone_object_needs_nothing() {
    let api = FakeApi::new([]);
    let written = write(
        &cms(&api),
        "cm",
        "ConfigMap/cm",
        &FieldManager::of("a"),
        &rule(&[]),
    )
    .await
    .unwrap();
    assert_eq!(written, Written::NothingToDo);
}
