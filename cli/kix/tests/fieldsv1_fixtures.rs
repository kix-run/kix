//! fieldsV1 projection and applied-hash tests against recorded fixtures.
//!
//! The fixtures in `tests/fixtures/` are real apiserver objects, recorded from
//! a kind cluster where they were server-side applied with field manager
//! `kix` (mimicking Kix's SSA), merge-patched with Kix's bookkeeping
//! annotations, and (for `deployment-coowned.json`) co-written by foreign
//! managers: `kubectl-patch` took `containers[name=api].image` and `kubectl`
//! took `spec.replicas` through the `/scale` subresource. Recorded with
//! `kubectl get --show-managed-fields -o json`.

use kube::api::DynamicObject;
use serde_json::Value;

use kix::cluster::drift::{self, DriftVerdict};
use kix::cluster::field_manager::FieldManager;
use kix::cluster::fieldsv1;
use kix::cluster::revision::AppliedHashes;
use kix::manifest::keys;

/// The field manager of the Kix cluster the fixtures are read for. They were
/// applied under the legacy name, which counts as every Kix cluster's own.
fn manager() -> FieldManager {
    // The fixtures were captured from objects an older Kix applied under the
    // legacy field manager.
    FieldManager::unmigrated("fixture")
}

fn load(json: &str) -> DynamicObject {
    serde_json::from_str(json).expect("fixture must deserialize as DynamicObject")
}

fn deployment() -> DynamicObject {
    load(include_str!("fixtures/deployment.json"))
}

fn secret() -> DynamicObject {
    load(include_str!("fixtures/secret.json"))
}

fn coowned() -> DynamicObject {
    load(include_str!("fixtures/deployment-coowned.json"))
}

#[test]
fn kix_fieldset_found_on_all_fixtures() {
    for obj in [deployment(), secret(), coowned()] {
        let fs = fieldsv1::kix_fieldset(&obj, &manager()).expect("kix Apply entry present");
        assert!(fs.get("f:spec").is_some() || fs.get("f:data").is_some());
    }
}

#[test]
fn fieldset_reads_typed_metadata_not_raw_data() {
    let mut obj = deployment();
    // Simulate a LIST response where raw data carries no metadata at all:
    // the typed metadata must be the only source consulted.
    if let Some(map) = obj.data.as_object_mut() {
        map.remove("metadata");
    }
    assert!(fieldsv1::kix_fieldset(&obj, &manager()).is_some());
}

#[test]
fn deployment_projection_shape() {
    let obj = deployment();
    let fields = fieldsv1::kix_fieldset(&obj, &manager()).unwrap();
    let full = fieldsv1::merge_typed_metadata(&obj);
    let proj = fieldsv1::project(&full, &fields);

    // Kix-owned spec content is present.
    let containers = proj
        .pointer("/spec/template/spec/containers")
        .and_then(Value::as_array)
        .expect("containers projected");
    assert_eq!(containers.len(), 2, "both containers kix applied");
    let web = containers
        .iter()
        .find(|c| c.pointer("/name") == Some(&Value::String("web".into())))
        .expect("web container matched by k: key");
    assert_eq!(
        web.pointer("/image").and_then(Value::as_str),
        Some("nginx:1.27.0")
    );
    assert_eq!(
        web.pointer("/ports")
            .and_then(Value::as_array)
            .map(Vec::len),
        Some(2)
    );
    assert_eq!(
        web.pointer("/env").and_then(Value::as_array).map(Vec::len),
        Some(2)
    );

    // Server-owned noise is not.
    assert!(proj.pointer("/status").is_none(), "status never projected");
    assert!(proj.pointer("/metadata/uid").is_none());
    assert!(proj.pointer("/metadata/resourceVersion").is_none());
    assert!(proj.pointer("/metadata/creationTimestamp").is_none());
    assert!(
        proj.pointer("/spec/progressDeadlineSeconds").is_none(),
        "server-defaulted fields stay out"
    );
    // The bookkeeping annotations live under Kix's Update entry, not the
    // Apply fieldset, so they never enter the projection.
    assert!(keys::get(&proj, keys::APPLIED_HASH).is_none());
}

#[test]
fn secret_projection_includes_data() {
    let obj = secret();
    let fields = fieldsv1::kix_fieldset(&obj, &manager()).unwrap();
    let full = fieldsv1::merge_typed_metadata(&obj);
    let proj = fieldsv1::project(&full, &fields);
    assert_eq!(
        proj.pointer("/data/username").and_then(Value::as_str),
        Some("dGVzdHVzZXI=")
    );
    assert!(proj.pointer("/data/password").is_some());
    assert_eq!(
        proj.pointer("/type").and_then(Value::as_str),
        Some("Opaque")
    );
}

#[test]
fn hash_is_stable_across_recompute_and_roundtrip() {
    let obj = deployment();
    let h1 = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    let h2 = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    assert_eq!(h1, h2);

    // Round-trip through JSON (as a watch/LIST would re-deliver the object).
    let json = serde_json::to_string(&obj).unwrap();
    let reparsed: DynamicObject = serde_json::from_str(&json).unwrap();
    assert_eq!(
        h1,
        fieldsv1::applied_content_hash(&reparsed, &manager()).unwrap()
    );
}

#[test]
fn hash_ignores_own_stamp_annotation() {
    // The stamp must not change its own hash: rewriting kix.run/applied-hash
    // (or any kix.run/* bookkeeping) leaves the hash untouched.
    let mut obj = secret();
    let before = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    obj.metadata
        .annotations
        .as_mut()
        .unwrap()
        .insert(keys::APPLIED_HASH.to_string(), before.clone());
    assert_eq!(
        before,
        fieldsv1::applied_content_hash(&obj, &manager()).unwrap()
    );
}

#[test]
fn tamper_on_kix_owned_field_changes_hash() {
    let mut obj = deployment();
    let before = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    *obj.data
        .pointer_mut("/spec/template/spec/containers/0/image")
        .unwrap() = Value::String("nginx:evil".into());
    let after = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    assert_ne!(before, after, "kix-owned image change must change the hash");
}

#[test]
fn tamper_on_kix_owned_secret_data_changes_hash() {
    let mut obj = secret();
    let before = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    *obj.data.pointer_mut("/data/password").unwrap() = Value::String("dGFtcGVyZWQ=".into());
    assert_ne!(
        before,
        fieldsv1::applied_content_hash(&obj, &manager()).unwrap()
    );
}

#[test]
fn deleting_kix_owned_field_changes_hash() {
    let mut obj = deployment();
    let before = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    obj.data
        .pointer_mut("/spec/template/spec/containers/0")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .remove("env");
    assert_ne!(
        before,
        fieldsv1::applied_content_hash(&obj, &manager()).unwrap()
    );
}

#[test]
fn tamper_on_foreign_owned_field_keeps_hash() {
    // On the co-owned fixture, `image` and `replicas` were taken by foreign
    // managers. They left Kix's fieldset, so mutating them must NOT move the
    // Kix hash (the take-over itself was the drift, already reflected in the
    // fieldset shrink at take-over time).
    let mut obj = coowned();
    let before = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    *obj.data.pointer_mut("/spec/replicas").unwrap() = serde_json::json!(7);
    *obj.data
        .pointer_mut("/spec/template/spec/containers/0/image")
        .unwrap() = Value::String("nginx:9.9.9".into());
    assert_eq!(
        before,
        fieldsv1::applied_content_hash(&obj, &manager()).unwrap(),
        "foreign-owned fields are outside kix's projection"
    );
}

#[test]
fn fieldset_shrink_after_takeover_changes_hash() {
    // The take-over story end to end: same live content, but Kix's fieldset
    // with vs without `f:image` hashes differently. Simulate the pre-takeover
    // state by re-adding f:image to Kix's entry in the co-owned fixture.
    let obj = coowned();
    let after_takeover = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();

    let mut restored = obj.clone();
    let entries = restored.metadata.managed_fields.as_mut().unwrap();
    let kix_entry = entries
        .iter_mut()
        .find(|e| e.manager.as_deref() == Some("kix") && e.operation.as_deref() == Some("Apply"))
        .unwrap();
    let fv = &mut kix_entry.fields_v1.as_mut().unwrap().0;
    fv.pointer_mut("/f:spec/f:template/f:spec/f:containers/k:{\"name\":\"api\"}")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .insert("f:image".to_string(), serde_json::json!({}));
    let before_takeover = fieldsv1::applied_content_hash(&restored, &manager()).unwrap();

    assert_ne!(before_takeover, after_takeover);
}

#[test]
fn keyed_list_matching_is_by_key_not_position() {
    let mut obj = deployment();
    let baseline_proj = {
        let fields = fieldsv1::kix_fieldset(&obj, &manager()).unwrap();
        fieldsv1::project(&fieldsv1::merge_typed_metadata(&obj), &fields)
    };

    // Reverse the live containers array: each element must still be matched
    // to ITS OWN k:{"name":...} subtree.
    let containers = obj
        .data
        .pointer_mut("/spec/template/spec/containers")
        .unwrap()
        .as_array_mut()
        .unwrap();
    containers.reverse();

    let fields = fieldsv1::kix_fieldset(&obj, &manager()).unwrap();
    let proj = fieldsv1::project(&fieldsv1::merge_typed_metadata(&obj), &fields);
    let projected = proj
        .pointer("/spec/template/spec/containers")
        .and_then(Value::as_array)
        .unwrap();
    assert_eq!(projected.len(), 2);
    // Live order preserved: sidecar now first.
    assert_eq!(
        projected[0].pointer("/name").and_then(Value::as_str),
        Some("sidecar")
    );
    let sidecar = &projected[0];
    assert_eq!(
        sidecar.pointer("/env/0/name").and_then(Value::as_str),
        Some("ROLE"),
        "sidecar element carries its own owned fields after reorder"
    );
    let web = &projected[1];
    assert_eq!(
        web.pointer("/ports")
            .and_then(Value::as_array)
            .map(Vec::len),
        Some(2),
        "web element carries its own owned fields after reorder"
    );

    // Reordering IS a hash change (live order is part of the server
    // representation), but element↔fieldset matching stayed keyed.
    let baseline_containers = baseline_proj
        .pointer("/spec/template/spec/containers")
        .and_then(Value::as_array)
        .unwrap();
    assert_eq!(baseline_containers[0], projected[1]);
    assert_eq!(baseline_containers[1], projected[0]);
}

#[test]
fn check_object_in_sync_when_stamp_matches() {
    let mut obj = deployment();
    let hash = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    obj.metadata
        .annotations
        .as_mut()
        .unwrap()
        .insert(keys::APPLIED_HASH.to_string(), hash);
    let report = drift::check_object(
        &obj,
        AppliedHashes::from_annotations().for_live(&obj, &manager(), None),
        &manager(),
    );
    assert_eq!(report.verdict, DriftVerdict::InSync);
    assert_eq!(report.rid.name, "fixture-web");
}

#[test]
fn check_object_unstamped_without_annotation() {
    let mut obj = deployment();
    // Every Kix key, under the current domain or a retired one: an object
    // stamped by an older Kix is stamped, not unstamped.
    obj.metadata
        .annotations
        .as_mut()
        .unwrap()
        .retain(|k, _| !keys::is_kix_key(k));
    assert_eq!(
        drift::check_object(
            &obj,
            AppliedHashes::from_annotations().for_live(&obj, &manager(), None),
            &manager()
        )
        .verdict,
        DriftVerdict::Unstamped
    );
}

/// Verify that an object stamped by Kix under a retired domain still reads as
/// stamped, so drift reports it and gc does not call it unmanaged.
#[test]
fn check_object_reads_a_stamp_under_a_retired_domain() {
    let Some(legacy) = kix::legacy_domain::DOMAINS.first() else {
        return;
    };
    let mut obj = deployment();
    let annotations = obj.metadata.annotations.as_mut().unwrap();
    annotations.remove(keys::APPLIED_HASH);
    annotations.insert(
        format!("{legacy}/applied-hash"),
        "some-old-hash".to_string(),
    );
    assert_ne!(
        drift::check_object(
            &obj,
            AppliedHashes::from_annotations().for_live(&obj, &manager(), None),
            &manager()
        )
        .verdict,
        DriftVerdict::Unstamped
    );
}

#[test]
fn check_object_no_fieldset_when_managed_fields_stripped() {
    let mut obj = deployment();
    obj.metadata.managed_fields = None;
    assert_eq!(
        drift::check_object(
            &obj,
            AppliedHashes::from_annotations().for_live(&obj, &manager(), None),
            &manager()
        )
        .verdict,
        DriftVerdict::NoFieldset
    );
}

#[test]
fn check_object_drifted_with_attribution() {
    // Stamp the co-owned fixture as if Kix had applied it BEFORE the foreign
    // take-overs (fieldset still holding image), then check the recorded
    // post-takeover object.
    let mut pre_takeover = coowned();
    let entries = pre_takeover.metadata.managed_fields.as_mut().unwrap();
    let kix_entry = entries
        .iter_mut()
        .find(|e| e.manager.as_deref() == Some("kix") && e.operation.as_deref() == Some("Apply"))
        .unwrap();
    kix_entry
        .fields_v1
        .as_mut()
        .unwrap()
        .0
        .pointer_mut("/f:spec/f:template/f:spec/f:containers/k:{\"name\":\"api\"}")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .insert("f:image".to_string(), serde_json::json!({}));
    let stamped_hash = fieldsv1::applied_content_hash(&pre_takeover, &manager()).unwrap();

    let mut obj = coowned();
    obj.metadata
        .annotations
        .as_mut()
        .unwrap()
        .insert(keys::APPLIED_HASH.to_string(), stamped_hash);

    let report = drift::check_object(
        &obj,
        AppliedHashes::from_annotations().for_live(&obj, &manager(), None),
        &manager(),
    );
    let DriftVerdict::Drifted {
        foreign,
        unrecorded_scale,
    } = report.verdict
    else {
        panic!("expected Drifted, got {:?}", report.verdict);
    };
    // kubectl owns spec.replicas, so the write is recorded, not inferred.
    assert_eq!(unrecorded_scale, None);

    // kubectl-patch took the image: attributed with a field path.
    let patcher = foreign
        .iter()
        .find(|o| o.manager == "kubectl-patch")
        .expect("kubectl-patch attributed");
    assert!(
        patcher
            .paths
            .contains(&"spec.template.spec.containers[name=api].image".to_string()),
        "paths: {:?}",
        patcher.paths
    );
    assert!(patcher.time.is_some());

    // kubectl scale went through the /scale subresource and must stay visible.
    let scaler = foreign
        .iter()
        .find(|o| o.subresource.as_deref() == Some("scale"))
        .expect("scale-subresource writer attributed");
    assert_eq!(scaler.manager, "kubectl");
    assert!(scaler.paths.contains(&"spec.replicas".to_string()));
    // The apiserver records a /scale entry without a time.
    assert_eq!(scaler.time, None);

    // Status writers and Kix itself are never attributed.
    assert!(
        foreign
            .iter()
            .all(|o| o.subresource.as_deref() != Some("status"))
    );
    assert!(foreign.iter().all(|o| o.manager != "kix"));
}

// These objects are derived from the recorded `deployment.json` (Kix owns
// `spec.replicas` = 2) by the changes the apiserver's ScaleHandler makes
// (k8s.io/apimachinery v0.36.1, util/managedfields/scalehandler.go). Scaling
// to 0 removes `replicas` from the Scale object, so no writer gains it and
// Kix's `Apply` entry loses it. Scaling back up finds no owner to map onto
// the Scale object, and the field manager skips tracking an update of an
// object with no managedFields (internal/skipnonapplied.go). Both leave
// `spec.replicas` with no owner and add no entry.

/// Return `deployment.json` stamped as Kix applied it, then scaled through
/// `/scale` to `live` replicas without a recorded owner.
fn scaled_without_owner(live: i64) -> DynamicObject {
    let mut obj = deployment();
    let stamp = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    obj.metadata
        .annotations
        .as_mut()
        .unwrap()
        .insert(keys::APPLIED_HASH.to_string(), stamp);
    release_replicas(&mut obj);
    obj.data["spec"]["replicas"] = serde_json::json!(live);
    obj
}

/// Drop `spec.replicas` from Kix's `Apply` entry.
fn release_replicas(obj: &mut DynamicObject) {
    let entries = obj.metadata.managed_fields.as_mut().unwrap();
    let kix_entry = entries
        .iter_mut()
        .find(|e| e.manager.as_deref() == Some("kix") && e.operation.as_deref() == Some("Apply"))
        .unwrap();
    kix_entry
        .fields_v1
        .as_mut()
        .unwrap()
        .0
        .pointer_mut("/f:spec")
        .unwrap()
        .as_object_mut()
        .unwrap()
        .remove("f:replicas")
        .expect("kix owned spec.replicas in the fixture");
}

fn unrecorded_scale(obj: &DynamicObject) -> Option<drift::UnrecordedScale> {
    match drift::check_object(
        obj,
        AppliedHashes::from_annotations().for_live(obj, &manager(), None),
        &manager(),
    )
    .verdict
    {
        DriftVerdict::Drifted {
            foreign,
            unrecorded_scale,
        } => {
            assert!(
                foreign
                    .iter()
                    .all(|o| o.subresource.as_deref() != Some("scale")),
                "no /scale entry is recorded in these objects: {foreign:?}"
            );
            unrecorded_scale
        }
        other => panic!("expected Drifted, got {other:?}"),
    }
}

#[test]
fn scale_to_zero_without_owner_names_both_values() {
    let scale = unrecorded_scale(&scaled_without_owner(0)).expect("attributed");
    assert_eq!(scale.path, "spec.replicas");
    assert_eq!((scale.deployed, scale.live), (2, 0));
}

#[test]
fn scale_back_to_deployed_value_without_owner_is_attributed() {
    let scale = unrecorded_scale(&scaled_without_owner(2)).expect("attributed");
    assert_eq!((scale.deployed, scale.live), (2, 2));
}

#[test]
fn unrecorded_scale_with_another_change_is_not_attributed() {
    let mut obj = scaled_without_owner(0);
    obj.data["spec"]["template"]["spec"]["containers"][0]["image"] = serde_json::json!("nginx:9");
    assert_eq!(unrecorded_scale(&obj), None);
}

#[test]
fn unowned_replicas_kix_never_applied_is_not_attributed() {
    // Kix applied no replicas (the stamp has none), and an image change with
    // no recorded owner drifted the object.
    let mut obj = deployment();
    release_replicas(&mut obj);
    let stamp = fieldsv1::applied_content_hash(&obj, &manager()).unwrap();
    obj.metadata
        .annotations
        .as_mut()
        .unwrap()
        .insert(keys::APPLIED_HASH.to_string(), stamp);
    obj.data["spec"]["template"]["spec"]["containers"][0]["image"] = serde_json::json!("nginx:9");
    assert_eq!(unrecorded_scale(&obj), None);
}

#[test]
fn unrecorded_scale_is_limited_to_kinds_that_serve_scale() {
    let mut obj = scaled_without_owner(0);
    obj.data["kind"] = serde_json::json!("DaemonSet");
    assert_eq!(unrecorded_scale(&obj), None);
}
