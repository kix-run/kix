use kube::api::DynamicObject;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::ensure::{crds, ensure};
use super::{Action, Live, OwnCrd, all, decide, ensure_all};
use crate::cluster::fake_api::FakeApi;
use crate::manifest::keys;

fn live(number: u32, serves: bool) -> Live {
    Live { number, serves }
}

#[test]
fn decide_follows_the_numbers() {
    let cases = [
        (2, None, Action::Create),
        (2, Some(live(1, true)), Action::Replace),
        (2, Some(live(1, false)), Action::Replace),
        (2, Some(live(2, true)), Action::Leave),
        (2, Some(live(3, true)), Action::Leave),
        (2, Some(live(2, false)), Action::NotServed),
        (2, Some(live(3, false)), Action::NotServed),
    ];
    for (mine, found, want) in cases {
        assert_eq!(
            decide(mine, found.as_ref()),
            want,
            "{mine} against {found:?}"
        );
    }
}

fn crd_object(annotations: Value, generation: i64, served: bool) -> DynamicObject {
    serde_json::from_value(json!({
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {
            "name": keys::ACTIVATIONS_CRD,
            "generation": generation,
            "annotations": annotations,
        },
        "spec": { "versions": [{ "name": "v1alpha1", "served": served }] },
    }))
    .unwrap()
}

#[test]
fn a_number_holds_while_the_generation_has_not_moved() {
    let mine = all()[0].definition.clone();
    let stamped = |s: &str| json!({ (keys::DEFINITION): s });
    let cases = [
        (json!({}), 4, true, live(1, true)),
        (stamped("3/4"), 4, true, live(3, true)),
        (stamped("3/4"), 5, true, live(1, true)),
        (stamped("not a stamp"), 4, true, live(1, true)),
        (stamped("3/4"), 4, false, live(3, false)),
    ];
    for (annotations, generation, served, want) in cases {
        let found = crd_object(annotations.clone(), generation, served);
        assert_eq!(
            Live::of(&found, &mine),
            want,
            "{annotations} at generation {generation}"
        );
    }
}

/// A change to a definition's content without a new number fails here. Raise
/// the number in `all()`, then put the new number and hash in this table.
#[test]
fn each_definition_has_the_number_of_its_content() {
    let pinned = [
        (
            keys::ACTIVATIONS_CRD.to_string(),
            1,
            "7b620c8d7109350d83ce575703851339775fbe696d5b58afc07f17124c60518a",
        ),
        (
            keys::PACKAGE_INSTANCES_CRD.to_string(),
            1,
            "18fd490e4f5dffdc86c036f73c46c218c15f5873cb3f02ce033096a3bb3b29e7",
        ),
        (
            crate::cluster::head::crd_name(),
            1,
            "59656af6b97799a5d16fe176d5bcfbb6a506891e9fb6f49ec8a66081bcd5d0d4",
        ),
        (
            crate::cluster::revision::crd_name(),
            2,
            "6086e6e86d95a9d44801c588992dde97a7f158250e779acfc4f56919111d616e",
        ),
    ];
    let found: Vec<(String, u32, String)> = all()
        .into_iter()
        .map(|crd| {
            let hash = format!("{:x}", Sha256::digest(crd.definition.to_string()));
            (crd.name, crd.number, hash)
        })
        .collect();
    let pinned: Vec<(String, u32, String)> = pinned
        .into_iter()
        .map(|(n, number, h)| (n, number, h.to_string()))
        .collect();
    assert_eq!(found, pinned);
}

/// Return the definition that builds of earlier releases applied for a
/// record kind, as `kix/lib/core/resource.nix` wrote it before the program
/// installed it.
fn built_by_earlier_releases(kind: &str, plural: &str, scope: &str) -> Value {
    let open = json!({ "type": "object", "x-kubernetes-preserve-unknown-fields": true });
    json!({
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "name": format!("{plural}.{}", keys::GROUP),
        },
        "spec": {
            "group": keys::GROUP,
            "names": {
                "kind": kind,
                "listKind": format!("{kind}List"),
                "plural": plural,
                "singular": kind.to_lowercase(),
            },
            "scope": scope,
            "versions": [{
                "name": "v1alpha1",
                "schema": { "openAPIV3Schema": {
                    "properties": {
                        "apiVersion": { "type": "string" },
                        "kind": { "type": "string" },
                        "metadata": { "type": "object" },
                        "spec": open,
                        "status": open,
                    },
                    "type": "object",
                }},
                "served": true,
                "storage": true,
                "subresources": { "status": {} },
            }],
        },
    })
}

/// Builds of earlier releases apply these two definitions. Number 1 must
/// match them, so an older Kix that applies them changes nothing.
#[test]
fn number_one_of_the_record_kinds_is_what_builds_applied() {
    let built = [
        built_by_earlier_releases("Activation", "activations", "Cluster"),
        built_by_earlier_releases("PackageInstance", "packageinstances", "Namespaced"),
    ];
    for (crd, from_build) in all()[..2].iter().zip(&built) {
        assert_eq!(crd.number, 1);
        assert_eq!(crd.name, from_build["metadata"]["name"].as_str().unwrap());
        assert_eq!(crd.definition["spec"], from_build["spec"], "{}", crd.name);
        assert_eq!(crd.definition["apiVersion"], from_build["apiVersion"]);
    }
}

fn stamp_of(object: &Value) -> Option<&str> {
    keys::get(object, keys::DEFINITION)
}

#[tokio::test]
async fn a_fresh_cluster_gets_all_four_stamped() {
    let api = FakeApi::new([]);
    ensure_all(&api.client()).await.unwrap();
    for crd in all() {
        let object = api
            .object("CustomResourceDefinition", &crd.name)
            .unwrap_or_else(|| panic!("{} was created", crd.name));
        assert_eq!(object["spec"], crd.definition["spec"]);
        let stamp = format!("{}/1", crd.number);
        assert_eq!(stamp_of(&object), Some(stamp.as_str()), "{}", crd.name);
    }
    let writes = |api: &FakeApi| {
        api.requests()
            .into_iter()
            .filter(|r| !r.starts_with("GET"))
            .count()
    };
    let before = writes(&api);
    ensure_all(&api.client()).await.unwrap();
    assert_eq!(writes(&api), before, "a second run writes nothing");
}

#[tokio::test]
async fn a_newer_definition_on_the_cluster_is_left_as_it_is() {
    let mut newer = all()[2].definition.clone();
    newer["metadata"]["annotations"] = json!({ (keys::DEFINITION): "7/3" });
    newer["metadata"]["generation"] = json!(3);
    newer["spec"]["versions"][0]["additionalPrinterColumns"] = json!([]);
    newer["status"] = json!({ "conditions": [{ "type": "Established", "status": "True" }] });
    let api = FakeApi::new([newer.clone()]);
    ensure_all(&api.client()).await.unwrap();
    let object = api
        .object("CustomResourceDefinition", &all()[2].name)
        .unwrap();
    assert_eq!(object["spec"], newer["spec"]);
}

#[tokio::test]
async fn a_newer_definition_that_drops_the_version_is_refused() {
    let mut newer = all()[2].definition.clone();
    newer["metadata"]["annotations"] = json!({ (keys::DEFINITION): "7/3" });
    newer["metadata"]["generation"] = json!(3);
    newer["spec"]["versions"][0]["served"] = json!(false);
    let api = FakeApi::new([newer]);
    let err = ensure_all(&api.client()).await.unwrap_err();
    assert!(matches!(err, super::CrdError::NotServed { .. }), "{err}");
}

/// The head's definition under a higher number, as a later release would
/// carry it.
fn raised() -> OwnCrd {
    let mut crd = all()[2].clone();
    crd.number = 2;
    crd.definition["spec"]["versions"][0]["additionalPrinterColumns"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "name": "Writer", "type": "string", "jsonPath": ".status.writer.version" }));
    crd
}

/// The head's number 1 as a build-era Kix left it: a stamp, the operator's
/// annotation, and marks a build would leave.
fn old_head() -> Value {
    let mut old = all()[2].definition.clone();
    old["metadata"]["generation"] = json!(4);
    old["metadata"]["labels"] = json!({ "app.kubernetes.io/managed-by": "kix", "team": "a" });
    old["metadata"]["annotations"] = json!({
        (keys::DEFINITION): "1/4",
        (keys::OPERATOR_FEATURES): "requests,head-lock",
        (keys::ACTIVATIONS): "abc",
        "example.com/note": "kept",
    });
    old
}

#[tokio::test]
async fn a_replace_takes_the_new_spec_and_keeps_foreign_marks() {
    let crd = raised();
    let api = FakeApi::new([old_head()]);
    let found = crds(&api.client()).get_opt(&crd.name).await.unwrap();
    assert!(ensure(&crds(&api.client()), &crd, found).await.unwrap());
    let object = api.object("CustomResourceDefinition", &crd.name).unwrap();
    assert_eq!(object["spec"], crd.definition["spec"]);
    assert_eq!(object["metadata"]["generation"], 5);
    assert_eq!(stamp_of(&object), Some("2/5"));
    let annotations = &object["metadata"]["annotations"];
    assert_eq!(annotations[keys::OPERATOR_FEATURES], "requests,head-lock");
    assert_eq!(annotations["example.com/note"], "kept");
    assert!(annotations.get(keys::ACTIVATIONS).is_none());
    assert_eq!(object["metadata"]["labels"], json!({ "team": "a" }));
}

#[tokio::test]
async fn a_replace_that_loses_a_race_reads_again() {
    let crd = raised();
    let api = FakeApi::new([old_head()]);
    let client = api.client();
    // Another writer changes the CRD between this run's read and its write.
    api.after_get(&crd.name, |o| {
        o["metadata"]["annotations"]["example.com/other"] = json!("written");
    });
    let found = crds(&client).get_opt(&crd.name).await.unwrap();
    assert!(ensure(&crds(&client), &crd, found).await.unwrap());
    let object = api.object("CustomResourceDefinition", &crd.name).unwrap();
    assert_eq!(object["spec"], crd.definition["spec"]);
    assert_eq!(stamp_of(&object), Some("2/5"));
    assert_eq!(
        object["metadata"]["annotations"]["example.com/other"],
        "written"
    );
    let puts = api
        .requests()
        .iter()
        .filter(|r| r.starts_with("PUT"))
        .count();
    assert_eq!(puts, 3, "{:?}", api.requests());
}

#[tokio::test]
async fn a_create_that_loses_a_race_reads_again() {
    let crd = all()[2].clone();
    let mut theirs = crd.definition.clone();
    theirs["status"] = json!({ "conditions": [{ "type": "Established", "status": "True" }] });
    let api = FakeApi::new([theirs]);
    let client = api.client();
    // This run read the cluster before the other run created the CRD.
    assert!(!ensure(&crds(&client), &crd, None).await.unwrap());
    let requests = api.requests();
    assert!(
        requests.iter().any(|r| r.starts_with("POST")),
        "{requests:?}"
    );
    assert!(
        !requests.iter().any(|r| r.starts_with("PUT")),
        "{requests:?}"
    );
}
