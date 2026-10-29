use super::*;
use kube::api::ObjectMeta;
use serde_json::json;

#[test]
fn ceded_conflict_is_stripped_and_others_are_not() {
    let manifest = serde_json::json!({
        "apiVersion": "admissionregistration.k8s.io/v1",
        "kind": "ValidatingWebhookConfiguration",
        "metadata": { "name": "op", "annotations": { super::keys::CEDE_FIELDS: "webhooks[*].rules,spec.versions" } },
        "webhooks": [
            { "name": "a.example.io", "rules": [ { "apiGroups": ["x"] } ], "clientConfig": { "service": { "name": "op" } } },
            { "name": "b.example.io", "rules": [ { "apiGroups": ["y"] } ] }
        ]
    });
    let msg = "Apply failed with 1 conflict: conflict with \"fabric8-kubernetes-client\" using \
               admissionregistration.k8s.io/v1: .webhooks[name=\"a.example.io\"].rules";
    let stripped = super::without_ceded_conflicts(&manifest, msg).expect("ceded");
    assert!(stripped["webhooks"][0].get("rules").is_none());
    assert!(stripped["webhooks"][0].get("clientConfig").is_some());
    assert!(stripped["webhooks"][1].get("rules").is_some());

    // A conflict outside the declaration is still a conflict.
    let other = "conflict with \"x\" using v1: .webhooks[name=\"a.example.io\"].clientConfig";
    assert!(super::without_ceded_conflicts(&manifest, other).is_none());
    // Two paths, one outside: still a conflict.
    let mixed = "conflicts with \"x\" using v1:\n- .spec.versions\n- .metadata.labels";
    assert!(super::without_ceded_conflicts(&manifest, mixed).is_none());
    // Nothing ceded: never stripped.
    let plain = serde_json::json!({ "metadata": { "name": "n" }, "spec": { "versions": [] } });
    assert!(super::without_ceded_conflicts(&plain, ".spec.versions").is_none());
}

#[test]
fn conflict_paths_are_read_from_the_message() {
    let msg = "Apply failed with 2 conflicts: conflicts with \"cdi-operator\" using apiextensions.k8s.io/v1:\n- .spec.versions\n- .spec.conversion";
    assert_eq!(
        super::conflict_paths(msg),
        vec![".spec.versions", ".spec.conversion"]
    );
    assert_eq!(
        super::parse_path(".a[name=\"x y\"].b[0]").unwrap(),
        vec![
            super::Seg::Field("a".into()),
            super::Seg::Key("name".into(), "x y".into()),
            super::Seg::Field("b".into()),
            super::Seg::Index(0)
        ]
    );
    assert!(super::parse_path("").is_none());
}

#[test]
fn stored_version_rejection_is_recognised() {
    // What the apiserver actually says when a CRD drops a version that
    // still has objects stored at it.
    let msg = "CustomResourceDefinition.apiextensions.k8s.io \"cdis.cdi.kubevirt.io\" \
               is invalid: status.storedVersions[0]: Invalid value: \"v1alpha1\": \
               must appear in spec.versions";
    assert!(super::is_stored_version_message(msg));
    assert!(!super::is_immutable_field_message(msg));
}

#[test]
fn immutable_rejection_is_not_a_stored_version_one() {
    let msg =
        "Job.batch \"probe\" is invalid: spec.template: Invalid value: ...: field is immutable";
    assert!(super::is_immutable_field_message(msg));
    assert!(!super::is_stored_version_message(msg));
}

fn live(hashes: &[&str]) -> HashSet<String> {
    hashes.iter().map(|s| s.to_string()).collect()
}

#[test]
fn merges_into_an_existing_set() {
    assert_eq!(
        merge_activation_set("bbb,ccc", "aaa", Some(&live(&["bbb", "ccc"]))),
        "aaa,bbb,ccc"
    );
}

#[test]
fn first_activation_on_a_bare_resource() {
    assert_eq!(merge_activation_set("", "aaa", Some(&live(&[]))), "aaa");
}

#[test]
fn drops_activations_that_no_longer_exist() {
    // `dead` names an Activation CR that has been garbage-collected.
    assert_eq!(
        merge_activation_set("bbb,dead", "aaa", Some(&live(&["bbb"]))),
        "aaa,bbb"
    );
}

#[test]
fn keeps_the_current_activation_even_when_not_yet_on_cluster() {
    // The Activation CR is applied in the last wave, so it is absent from
    // the live set while its own resources are being stamped.
    assert_eq!(
        merge_activation_set("bbb", "aaa", Some(&live(&["bbb"]))),
        "aaa,bbb"
    );
}

#[test]
fn unknown_live_set_never_prunes() {
    assert_eq!(
        merge_activation_set("bbb,dead", "aaa", None),
        "aaa,bbb,dead"
    );
}

#[test]
fn is_idempotent_and_order_insensitive() {
    let l = live(&["aaa", "bbb"]);
    let once = merge_activation_set("bbb,aaa", "aaa", Some(&l));
    assert_eq!(once, merge_activation_set(&once, "aaa", Some(&l)));
    assert_eq!(once, merge_activation_set("aaa,bbb", "aaa", Some(&l)));
    // Unchanged output is how the caller decides to skip the write.
    assert_eq!(once, "aaa,bbb");
}

#[test]
fn tolerates_whitespace_and_empty_entries() {
    assert_eq!(
        merge_activation_set(" bbb , , ccc ", "aaa", Some(&live(&["bbb", "ccc"]))),
        "aaa,bbb,ccc"
    );
}

#[test]
fn unstamped_old_manifest_is_never_an_orphan() {
    let mut inherited = manifest("EndpointSlice", "web-abc", "default", "unused");
    inherited["metadata"]
        .as_object_mut()
        .unwrap()
        .remove("annotations");
    let old = vec![
        inherited,
        manifest("Deployment", "gone", "default", "id-gone"),
    ];
    let actions = detect_changes(&[], &old);
    let orphans: Vec<_> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Orphan(rid) => Some(rid.name.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(orphans, vec!["gone"]);
}

#[test]
fn unstamped_live_object_is_never_an_orphan() {
    let mut inherited = live_object("EndpointSlice", "web-abc", "default", "unused");
    inherited.metadata.annotations = None;
    let live = vec![
        inherited,
        live_object("Deployment", "gone", "default", "id-gone"),
    ];
    let actions = detect_changes_live(&[], &live);
    let orphans: Vec<_> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Orphan(rid) => Some(rid.name.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(orphans, vec!["gone"]);
}

fn manifest(kind: &str, name: &str, ns: &str, identity_hash: &str) -> Value {
    json!({
        "apiVersion": "apps/v1",
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": {
                keys::IDENTITY_HASH: identity_hash,
            }
        }
    })
}

#[test]
fn detect_new_resource() {
    let new = vec![manifest("Deployment", "app", "default", "id1")];
    let old: Vec<Value> = vec![];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn detect_unchanged_resource() {
    let new = vec![manifest("Deployment", "app", "default", "id1")];
    let old = vec![manifest("Deployment", "app", "default", "id1")];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Skip(_)));
}

#[test]
fn detect_changed_resource() {
    let new = vec![manifest("Deployment", "app", "default", "new-hash")];
    let old = vec![manifest("Deployment", "app", "default", "old-hash")];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn detect_orphan() {
    let new: Vec<Value> = vec![];
    let old = vec![manifest("Deployment", "old-app", "default", "id-orphan")];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Orphan(_)));
    if let ChangeAction::Orphan(rid) = &actions[0] {
        assert_eq!(rid.name, "old-app");
    }
}

#[test]
fn detect_mixed_actions() {
    let new = vec![
        manifest("Deployment", "unchanged", "default", "id1"),
        manifest("Deployment", "changed", "default", "new-hash"),
        manifest("Deployment", "new-app", "default", "id3"),
    ];
    let old = vec![
        manifest("Deployment", "unchanged", "default", "id1"),
        manifest("Deployment", "changed", "default", "old-hash"),
        manifest("Deployment", "orphan", "default", "id-orphan"),
    ];

    let actions = detect_changes(&new, &old);
    // 3 new manifest actions + 1 orphan = 4
    assert_eq!(actions.len(), 4);

    let skips: Vec<_> = actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Skip(_)))
        .collect();
    let applies: Vec<_> = actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .collect();
    let orphans: Vec<_> = actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Orphan(_)))
        .collect();

    assert_eq!(skips.len(), 1); // unchanged
    assert_eq!(applies.len(), 2); // changed + new
    assert_eq!(orphans.len(), 1); // orphan
}

#[test]
fn first_deploy_all_applies() {
    let new = vec![
        manifest("Namespace", "default", CLUSTER_SCOPED, "id1"),
        manifest("Deployment", "app", "default", "id2"),
    ];
    let old: Vec<Value> = vec![];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 2);
    assert!(actions.iter().all(|a| matches!(a, ChangeAction::Apply(_))));
}

#[test]
fn immutable_field_messages_detected() {
    assert!(is_immutable_field_message(
        "Job.batch \"x\" is invalid: spec.template: Invalid value: ...: field is immutable"
    ));
    assert!(is_immutable_field_message(
        "Service \"x\" is invalid: spec.clusterIP: Invalid value: \"10.0.0.1\": field is immutable"
    ));
    assert!(is_immutable_field_message(
        "StatefulSet.apps \"x\" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals'"
    ));
    assert!(!is_immutable_field_message(
        "Deployment.apps \"x\" is invalid: spec.replicas: must be non-negative"
    ));
    assert!(!is_immutable_field_message("unrelated error"));
}

#[test]
fn apply_action_eq() {
    assert_eq!(ApplyAction::Created, ApplyAction::Created);
    assert_eq!(ApplyAction::Configured, ApplyAction::Configured);
    assert_eq!(ApplyAction::Unchanged, ApplyAction::Unchanged);
    assert_ne!(ApplyAction::Created, ApplyAction::Configured);
}

fn live_object(kind: &str, name: &str, ns: &str, identity_hash: &str) -> DynamicObject {
    let mut annotations = std::collections::BTreeMap::new();
    annotations.insert(keys::IDENTITY_HASH.to_string(), identity_hash.to_string());
    DynamicObject {
        metadata: ObjectMeta {
            name: Some(name.to_string()),
            namespace: if ns == crate::manifest::types::CLUSTER_SCOPED {
                None
            } else {
                Some(ns.to_string())
            },
            annotations: Some(annotations),
            ..Default::default()
        },
        types: Some(kube::api::TypeMeta {
            kind: kind.to_string(),
            api_version: "apps/v1".to_string(),
        }),
        data: json!({
            "kind": kind,
            "apiVersion": "apps/v1",
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {
                    keys::IDENTITY_HASH: identity_hash,
                }
            }
        }),
    }
}

#[test]
fn live_detect_new_resource() {
    let desired = vec![manifest("Deployment", "app", "default", "id1")];
    let live: Vec<DynamicObject> = vec![];

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn live_detect_unchanged_resource() {
    let desired = vec![manifest("Deployment", "app", "default", "id1")];
    let live = vec![live_object("Deployment", "app", "default", "id1")];

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Skip(_)));
}

#[test]
fn live_detect_drifted_resource() {
    let desired = vec![manifest("Deployment", "app", "default", "desired-hash")];
    let live = vec![live_object("Deployment", "app", "default", "live-hash")];

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn live_detect_orphan() {
    let desired: Vec<Value> = vec![];
    let live = vec![live_object("Deployment", "orphan", "default", "id1")];

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Orphan(_)));
    if let ChangeAction::Orphan(rid) = &actions[0] {
        assert_eq!(rid.name, "orphan");
    }
}

#[test]
fn live_detect_mixed() {
    let desired = vec![
        manifest("Deployment", "unchanged", "default", "id1"),
        manifest("Deployment", "drifted", "default", "new-hash"),
        manifest("Deployment", "new-app", "default", "id3"),
    ];
    let live = vec![
        live_object("Deployment", "unchanged", "default", "id1"),
        live_object("Deployment", "drifted", "default", "old-hash"),
        live_object("Deployment", "orphan", "default", "id-orphan"),
    ];

    let actions = detect_changes_live(&desired, &live);
    // 3 desired actions + 1 orphan = 4
    assert_eq!(actions.len(), 4);

    let skips = actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Skip(_)))
        .count();
    let applies = actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .count();
    let orphans = actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Orphan(_)))
        .count();

    assert_eq!(skips, 1);
    assert_eq!(applies, 2);
    assert_eq!(orphans, 1);
}

// Deploy records do not participate in change detection.

fn record(name: &str, hash: &str) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": "Activation",
        "metadata": {
            "name": name,
            "annotations": { keys::IDENTITY_HASH: hash, keys::PACKAGE: "_cluster" }
        }
    })
}

fn live_record(name: &str, hash: &str) -> DynamicObject {
    serde_json::from_value(record(name, hash)).unwrap()
}

fn orphan_ids(actions: &[ChangeAction]) -> Vec<String> {
    let mut v: Vec<String> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Orphan(rid) => Some(rid.display_id()),
            _ => None,
        })
        .collect();
    v.sort();
    v
}

fn apply_ids(actions: &[ChangeAction]) -> Vec<String> {
    let mut v: Vec<String> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Apply(m) => Some(ResourceId::from_value(m).display_id()),
            _ => None,
        })
        .collect();
    v.sort();
    v
}

fn skip_ids(actions: &[ChangeAction]) -> Vec<String> {
    let mut v: Vec<String> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Skip(rid) => Some(rid.display_id()),
            _ => None,
        })
        .collect();
    v.sort();
    v
}

#[test]
fn an_object_only_a_kept_closure_has_is_an_orphan_again() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = active.clone();
    let kept = vec![
        manifest("Deployment", "web", "app", "h0"),
        manifest("ConfigMap", "removed", "app", "h9"),
        record("demo-old", "h8"),
    ];

    let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[kept]);
    assert_eq!(orphan_ids(&folded), vec!["ConfigMap/removed@app"]);
    // A kept closure never turns a Skip into an Apply: A replaced it in full.
    assert_eq!(skip_ids(&folded), vec!["Deployment/web@app"]);
    assert!(apply_ids(&folded).is_empty());
}

#[test]
fn an_object_the_new_build_declares_again_is_not_an_orphan() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![
        manifest("Deployment", "web", "app", "h1"),
        manifest("ConfigMap", "removed", "app", "h10"),
    ];
    let kept = vec![manifest("ConfigMap", "removed", "app", "h9")];

    let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[kept]);
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn kept_closures_and_the_active_diff_do_not_duplicate_orphans() {
    let active = vec![
        manifest("Deployment", "web", "app", "h1"),
        manifest("ConfigMap", "gone", "app", "h5"),
    ];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let first = vec![
        manifest("ConfigMap", "gone", "app", "h4"),
        manifest("Secret", "older", "app", "h3"),
    ];
    let second = vec![manifest("Secret", "older", "app", "h3")];

    let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[first, second]);
    assert_eq!(
        orphan_ids(&folded),
        vec!["ConfigMap/gone@app", "Secret/older@app"]
    );
}

#[test]
fn a_closure_leaves_orphans_only_for_deletable_objects_the_new_build_lacks() {
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    assert!(leaves_orphans(
        &[manifest("ConfigMap", "removed", "app", "h9")],
        &new
    ));
    // Same identity under a different hash is an update, not an orphan.
    assert!(!leaves_orphans(
        &[manifest("Deployment", "web", "app", "h0")],
        &new
    ));
    // Records are superseded and Namespaces are never pruned.
    assert!(!leaves_orphans(&[record("demo-old", "h8")], &new));
    let mut ns = manifest("Namespace", "app", "app", "h7");
    ns["metadata"].as_object_mut().unwrap().remove("namespace");
    assert!(!leaves_orphans(&[ns], &new));
}

#[test]
fn an_object_only_the_failed_closure_has_is_an_orphan() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![
        manifest("Deployment", "web", "app", "h2"),
        manifest("ConfigMap", "leftover", "app", "h9"),
    ];

    let actions = detect_changes(&new, &active);
    assert_eq!(orphan_ids(&actions), Vec::<String>::new());

    let folded = fold_failed_closures(actions, &new, &[failed]);
    assert_eq!(orphan_ids(&folded), vec!["ConfigMap/leftover@app"]);
}

#[test]
fn an_object_the_failed_deploy_may_have_changed_is_reapplied() {
    // When N is identical to A, detect_changes marks `web` as Skip, but if
    // a failed deploy F had a different hash for `web`, it must be
    // re-applied in case F overwrote the live object before aborting.
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![manifest("Deployment", "web", "app", "h2")];

    let actions = detect_changes(&new, &active);
    assert_eq!(skip_ids(&actions), vec!["Deployment/web@app"]);

    let folded = fold_failed_closures(actions, &new, &[failed]);
    assert_eq!(apply_ids(&folded), vec!["Deployment/web@app"]);
    assert!(skip_ids(&folded).is_empty());
}

#[test]
fn a_hash_the_failed_closure_agrees_on_stays_skipped() {
    // F never disagreed about this one, so nothing it did could have
    // changed it and re-applying would be noise.
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![manifest("Deployment", "web", "app", "h1")];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert_eq!(skip_ids(&folded), vec!["Deployment/web@app"]);
    assert!(apply_ids(&folded).is_empty());
}

#[test]
fn retrying_the_closure_that_failed_applies_it_and_orphans_nothing() {
    // N == F: every node is already an Apply, and nothing F touched is
    // outside the set we are about to write.
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![
        manifest("Deployment", "web", "app", "h2"),
        manifest("ConfigMap", "extra", "app", "h9"),
    ];
    let failed = new.clone();

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert_eq!(
        apply_ids(&folded),
        vec!["ConfigMap/extra@app", "Deployment/web@app"]
    );
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn stacked_failed_closures_union_their_leftovers() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let first = vec![manifest("ConfigMap", "one", "app", "h7")];
    let second = vec![manifest("ConfigMap", "two", "app", "h8")];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[first, second]);
    assert_eq!(
        orphan_ids(&folded),
        vec!["ConfigMap/one@app", "ConfigMap/two@app"]
    );
}

#[test]
fn a_record_in_a_failed_closure_is_never_an_orphan() {
    // Records are superseded, not pruned. A failed closure always carries
    // its own, and its name differs from the new one on every changed
    // deploy, so without the lifecycle check every run would invent one.
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![
        manifest("Deployment", "web", "app", "h1"),
        record("demo-abc123", "h2"),
    ];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn an_unstamped_manifest_in_a_failed_closure_is_never_an_orphan() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": "unstamped", "namespace": "app" }
    })];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn an_orphan_detect_changes_already_found_is_not_duplicated() {
    let active = vec![
        manifest("Deployment", "web", "app", "h1"),
        manifest("ConfigMap", "gone", "app", "h5"),
    ];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![manifest("ConfigMap", "gone", "app", "h6")];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert_eq!(orphan_ids(&folded), vec!["ConfigMap/gone@app"]);
}

#[test]
fn no_failed_closures_changes_nothing() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let new = vec![manifest("Deployment", "web", "app", "h1")];
    let before = detect_changes(&new, &active);
    let after = fold_failed_closures(before.clone(), &new, &[]);
    assert_eq!(skip_ids(&before), skip_ids(&after));
    assert_eq!(apply_ids(&before), apply_ids(&after));
    assert_eq!(orphan_ids(&before), orphan_ids(&after));
}

#[test]
fn baseline_keeps_active_and_adds_only_what_is_missing() {
    let active = vec![manifest("Deployment", "web", "app", "h1")];
    let failed = vec![
        // Same identity as active: the active version wins, so the plan
        // describes the object the way the current closure does.
        manifest("Deployment", "web", "app", "h2"),
        manifest("ConfigMap", "leftover", "app", "h9"),
    ];

    let merged = baseline_manifests(&active, &[failed]);
    assert_eq!(merged.len(), 2);
    assert_eq!(manifest_identity_hash(&merged[0]), Some("h1"));
    assert_eq!(
        ResourceId::from_value(&merged[1]).display_id(),
        "ConfigMap/leftover@app"
    );
}

/// Invariant 1: two builds that differ only in the record produce no
/// orphan. The only apply is the new record itself, which is how it
/// reaches the cluster.
#[test]
fn record_rename_is_not_an_orphan() {
    let shared = manifest(
        "ConfigMap",
        "grafana-datasources",
        "monitoring-system",
        "same",
    );
    let old = vec![
        record("stage1-0f3g4dhhzqfd", "0f3g4dhhzqfd0xvgwfw987lf0s8xhmkb"),
        shared.clone(),
    ];
    let new = vec![
        record("stage1-680afyh7g9kd", "680afyh7g9kd5vdqk3p5kzgs5ymyyyzi"),
        shared,
    ];
    let actions = detect_changes(&new, &old);
    assert!(
        orphan_ids(&actions).is_empty(),
        "{:?}",
        orphan_ids(&actions)
    );
    assert_eq!(apply_ids(&actions), vec!["Activation/stage1-680afyh7g9kd"]);
}

/// An unchanged build keeps the same record name and hash, and must
/// produce `Skip` on both paths so `total_apply == 0` and the deploy can
/// short-circuit when the activation is identical.
#[test]
fn unchanged_record_is_skip_not_apply() {
    let dep = manifest("Deployment", "web", "default", "d1");
    let same = record("stage1-0f3g4dhhzqfd", "0f3g4dhhzqfd0xvgwfw987lf0s8xhmkb");
    let actions = detect_changes(&[same.clone(), dep.clone()], &[same.clone(), dep.clone()]);
    assert!(apply_ids(&actions).is_empty(), "{:?}", apply_ids(&actions));
    assert!(orphan_ids(&actions).is_empty());
    assert_eq!(
        actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Skip(_)))
            .count(),
        2
    );

    let live = vec![
        live_object(
            "Activation",
            "stage1-0f3g4dhhzqfd",
            CLUSTER_SCOPED,
            "0f3g4dhhzqfd0xvgwfw987lf0s8xhmkb",
        ),
        live_object("Deployment", "web", "default", "d1"),
    ];
    let actions = detect_changes_live(&[same, dep], &live);
    assert!(apply_ids(&actions).is_empty(), "{:?}", apply_ids(&actions));
    assert!(orphan_ids(&actions).is_empty());
}

/// Markers and plain PackageInstances are ordinary desired state for
/// orphan detection: one that left the build is an orphan. Pins
/// `Lifecycle::prunable()` against a mutant that only prunes `Desired`.
#[test]
fn markers_and_plain_package_instances_can_be_orphans() {
    let mut marker = manifest("PackageInstance", "pi-import", "ns", "m1");
    marker["metadata"]["annotations"][keys::MODE] = serde_json::json!("import");
    let plain = manifest("PackageInstance", "pi-plain", "ns", "p1");
    let keep = manifest("Deployment", "web", "default", "d1");
    let old = vec![marker, plain, keep.clone()];
    let actions = detect_changes(std::slice::from_ref(&keep), &old);
    let mut orphans = orphan_ids(&actions);
    orphans.sort();
    assert_eq!(
        orphans,
        vec![
            "PackageInstance/pi-import@ns",
            "PackageInstance/pi-plain@ns"
        ]
    );
}

/// Invariant 2: no orphan action ever names a record, whatever the
/// shapes of the two sets.
#[test]
fn records_are_never_orphans() {
    let dep = manifest("Deployment", "web", "default", "d1");
    let cases: Vec<(Vec<Value>, Vec<Value>)> = vec![
        // old has a record, new has none
        (vec![dep.clone()], vec![record("c-a", "a"), dep.clone()]),
        // old has two records (a stale one and the active one)
        (
            vec![record("c-c", "c"), dep.clone()],
            vec![record("c-a", "a"), record("c-b", "b"), dep.clone()],
        ),
        // old is only a record
        (vec![dep.clone()], vec![record("c-a", "a")]),
        // a real orphan alongside a record: the real one is still found
        (
            vec![record("c-b", "b")],
            vec![record("c-a", "a"), dep.clone()],
        ),
    ];
    for (new, old) in cases {
        let actions = detect_changes(&new, &old);
        for id in orphan_ids(&actions) {
            assert!(
                !id.starts_with("Activation/"),
                "record reported as orphan: {id}"
            );
        }
    }
    // The last case must still report the Deployment.
    let actions = detect_changes(&[record("c-b", "b")], &[record("c-a", "a"), dep]);
    assert_eq!(orphan_ids(&actions), vec!["Deployment/web@default"]);
}

/// Invariant 3: the store path and the live path agree on the orphan
/// set for the same previous state, records included.
#[test]
fn store_and_live_paths_agree_on_orphans() {
    let desired = vec![
        record("c-new", "new"),
        manifest("Deployment", "keep", "default", "k1"),
    ];
    let old = vec![
        record("c-old", "old"),
        manifest("Deployment", "keep", "default", "k1"),
        manifest("Deployment", "gone", "default", "g1"),
    ];
    let live = vec![
        live_record("c-old", "old"),
        live_object("Deployment", "keep", "default", "k1"),
        live_object("Deployment", "gone", "default", "g1"),
    ];
    let via_store = orphan_ids(&detect_changes(&desired, &old));
    let via_live = orphan_ids(&detect_changes_live(&desired, &live));
    assert_eq!(via_store, vec!["Deployment/gone@default"]);
    assert_eq!(via_store, via_live);
    // Both paths still apply the new record.
    assert!(
        apply_ids(&detect_changes(&desired, &old))
            .iter()
            .any(|id| id.starts_with("Activation/")),
        "store path drops the new record"
    );
    assert!(
        apply_ids(&detect_changes_live(&desired, &live))
            .iter()
            .any(|id| id.starts_with("Activation/")),
        "live path drops the new record"
    );
}

/// When the operator strips the record from the desired manifest set, live
/// Activation records must still not be reported as orphans.
#[test]
fn operator_shape_live_record_is_not_an_orphan() {
    let desired = vec![manifest("Deployment", "web", "default", "d1")];
    let live = vec![
        live_record("c-active", "act"),
        live_object("Deployment", "web", "default", "d1"),
    ];
    let actions = detect_changes_live(&desired, &live);
    assert!(
        orphan_ids(&actions).is_empty(),
        "{:?}",
        orphan_ids(&actions)
    );
}

/// A ConfigMap manifest without metadata.namespace is refused before any
/// request, so the apiserver never stores it in `default` under an id
/// the build does not have. `namespaceless` reports only that case: not a
/// ClusterRole, a ConfigMap with a namespace, or a kind discovery lacks.
#[tokio::test]
async fn a_namespaced_kind_without_a_namespace_is_refused() {
    use crate::cluster::{discovery, fake_api::FakeApi};
    use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

    let api = FakeApi::default();
    let client = api.client();
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let before = api.requests().len();
    let cm = serde_json::json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": "shared" },
    });
    let (ar, scope) = discovery
        .iter()
        .find(|(ar, _)| ar.kind == "ConfigMap")
        .unwrap();
    let err = super::apply_resource(&client, ar, scope.clone(), &cm, false, None, None, false)
        .await
        .unwrap_err();
    assert!(
        matches!(&err, super::ApplyError::NoNamespace { resource } if resource == "ConfigMap/shared"),
        "{err}"
    );
    assert_eq!(api.requests().len(), before, "{:?}", api.requests());

    let rid = |kind: &str, ns: &str| ResourceId {
        kind: kind.into(),
        namespace: ns.into(),
        name: "shared".into(),
    };
    let candidates = [
        rid("ConfigMap", CLUSTER_SCOPED),
        rid("ConfigMap", "default"),
        rid("ClusterRole", CLUSTER_SCOPED),
        rid("Widget", CLUSTER_SCOPED),
    ];
    assert_eq!(
        super::namespaceless(&discovery, &candidates),
        vec![rid("ConfigMap", CLUSTER_SCOPED)]
    );
}
