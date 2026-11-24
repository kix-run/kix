use super::*;
use crate::cluster::test_fixtures::{api_version_of, manifest};
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
fn a_ceded_field_under_a_multi_key_list_element_is_stripped() {
    let manifest = json!({
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": { "name": "dns", "annotations": { super::keys::CEDE_FIELDS: "spec.ports[*].name" } },
        "spec": { "ports": [
            { "port": 53, "protocol": "UDP", "name": "dns" },
            { "port": 53, "protocol": "TCP", "name": "dns-tcp" }
        ] }
    });
    let msg = "Apply failed with 1 conflict: conflict with \"helm\" using v1: \
               .spec.ports[port=53,protocol=\"UDP\"].name";
    assert_eq!(
        super::conflict_paths(msg),
        vec![".spec.ports[port=53,protocol=\"UDP\"].name"]
    );
    let stripped = super::without_ceded_conflicts(&manifest, msg).expect("ceded");
    assert!(stripped["spec"]["ports"][0].get("name").is_none());
    assert_eq!(stripped["spec"]["ports"][1]["name"], "dns-tcp");
}

#[test]
fn a_declared_two_key_selector_cedes_only_its_element() {
    let manifest = json!({
        "apiVersion": "v1",
        "kind": "Service",
        "metadata": { "name": "dns", "annotations": {
            super::keys::CEDE_FIELDS: "spec.ports[port=53,protocol=\"UDP\"].name"
        } },
        "spec": { "ports": [
            { "port": 53, "protocol": "UDP", "name": "dns" },
            { "port": 53, "protocol": "TCP", "name": "dns-tcp" }
        ] }
    });
    let udp = "conflict with \"helm\" using v1: .spec.ports[port=53,protocol=\"UDP\"].name";
    let stripped = super::without_ceded_conflicts(&manifest, udp).expect("ceded");
    assert!(stripped["spec"]["ports"][0].get("name").is_none());
    assert_eq!(stripped["spec"]["ports"][1]["name"], "dns-tcp");
    let tcp = "conflict with \"helm\" using v1: .spec.ports[port=53,protocol=\"TCP\"].name";
    assert!(super::without_ceded_conflicts(&manifest, tcp).is_none());
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
            super::Seg::Key(vec![("name".into(), json!("x y"))]),
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
    let mut inherited = manifest("EndpointSlice", "web-abc", "default", "unused", "");
    inherited["metadata"]
        .as_object_mut()
        .unwrap()
        .remove("annotations");
    let old = vec![
        inherited,
        manifest("Deployment", "gone", "default", "id-gone", ""),
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

#[test]
fn detect_new_resource() {
    let new = vec![manifest("Deployment", "app", "default", "id1", "")];
    let old: Vec<Value> = vec![];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn detect_unchanged_resource() {
    let new = vec![manifest("Deployment", "app", "default", "id1", "")];
    let old = vec![manifest("Deployment", "app", "default", "id1", "")];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Skip(_)));
}

#[test]
fn detect_changed_resource() {
    let new = vec![manifest("Deployment", "app", "default", "new-hash", "")];
    let old = vec![manifest("Deployment", "app", "default", "old-hash", "")];

    let actions = detect_changes(&new, &old);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

fn with_package(mut manifest: Value, package: &str) -> Value {
    manifest["metadata"]["annotations"][keys::PACKAGE] = json!(package);
    manifest["metadata"]["annotations"][keys::PACKAGE_NAMESPACE] = json!("data");
    manifest
}

/// A build that names another owner for an object whose content is
/// unchanged applies it, so the live `kix.run/package` follows the build.
#[test]
fn detect_changed_owner_stamp() {
    let new = vec![with_package(
        manifest("Deployment", "app", "default", "id1", ""),
        "postgres",
    )];
    let same = vec![with_package(
        manifest("Deployment", "app", "default", "id1", ""),
        "postgres",
    )];
    let other = vec![with_package(
        manifest("Deployment", "app", "default", "id1", ""),
        "app-db",
    )];

    let actions = detect_changes(&new, &same);
    assert!(matches!(&actions[0], ChangeAction::Skip(_)));
    let actions = detect_changes(&new, &other);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn detect_orphan() {
    let new: Vec<Value> = vec![];
    let old = vec![manifest(
        "Deployment",
        "old-app",
        "default",
        "id-orphan",
        "",
    )];

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
        manifest("Deployment", "unchanged", "default", "id1", ""),
        manifest("Deployment", "changed", "default", "new-hash", ""),
        manifest("Deployment", "new-app", "default", "id3", ""),
    ];
    let old = vec![
        manifest("Deployment", "unchanged", "default", "id1", ""),
        manifest("Deployment", "changed", "default", "old-hash", ""),
        manifest("Deployment", "orphan", "default", "id-orphan", ""),
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
        manifest("Namespace", "default", CLUSTER_SCOPED, "id1", ""),
        manifest("Deployment", "app", "default", "id2", ""),
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
    live_object_as(api_version_of(kind), kind, name, ns, identity_hash)
}

fn live_object_as(
    api_version: &str,
    kind: &str,
    name: &str,
    ns: &str,
    identity_hash: &str,
) -> DynamicObject {
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
            api_version: api_version.to_string(),
        }),
        data: json!({
            "kind": kind,
            "apiVersion": api_version,
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
    let desired = vec![manifest("Deployment", "app", "default", "id1", "")];
    let live: Vec<DynamicObject> = vec![];

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn live_detect_unchanged_resource() {
    let desired = vec![manifest("Deployment", "app", "default", "id1", "")];
    let live = vec![live_object("Deployment", "app", "default", "id1")];

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Skip(_)));
}

/// An unchanged object that is being deleted is written again, so the
/// deploy waits for it to go and creates it, instead of skipping it and
/// leaving it to vanish.
#[test]
fn live_detect_unchanged_object_being_deleted_is_written() {
    let desired = vec![manifest("Deployment", "app", "default", "id1", "")];
    let mut live = vec![live_object("Deployment", "app", "default", "id1")];
    live[0].metadata.deletion_timestamp =
        Some(serde_json::from_value(serde_json::json!("2026-11-24T15:54:00Z")).unwrap());

    let actions = detect_changes_live(&desired, &live);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)), "{actions:?}");
}

/// Same as `detect_changed_owner_stamp` against live objects, the rule the
/// operator and a plan without the old build use.
#[test]
fn live_detect_changed_owner_stamp() {
    let desired = vec![with_package(
        manifest("Deployment", "app", "default", "id1", ""),
        "postgres",
    )];
    let stamped = |package: &str| {
        let mut obj = live_object("Deployment", "app", "default", "id1");
        let anns = obj
            .metadata
            .annotations
            .get_or_insert_with(Default::default);
        anns.insert(keys::PACKAGE.to_string(), package.to_string());
        anns.insert(keys::PACKAGE_NAMESPACE.to_string(), "data".to_string());
        obj
    };

    let actions = detect_changes_live(&desired, &[stamped("postgres")]);
    assert!(matches!(&actions[0], ChangeAction::Skip(_)));
    let actions = detect_changes_live(&desired, &[stamped("app-db")]);
    assert_eq!(actions.len(), 1);
    assert!(matches!(&actions[0], ChangeAction::Apply(_)));
}

#[test]
fn live_detect_drifted_resource() {
    let desired = vec![manifest("Deployment", "app", "default", "desired-hash", "")];
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
        manifest("Deployment", "unchanged", "default", "id1", ""),
        manifest("Deployment", "drifted", "default", "new-hash", ""),
        manifest("Deployment", "new-app", "default", "id3", ""),
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
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = active.clone();
    let kept = vec![
        manifest("Deployment", "web", "app", "h0", ""),
        manifest("ConfigMap", "removed", "app", "h9", ""),
        record("demo-old", "h8"),
    ];

    let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[kept]);
    assert_eq!(orphan_ids(&folded), vec!["ConfigMap/removed@app"]);
    // A kept closure never turns a Skip into an Apply: A replaced it in full.
    assert_eq!(skip_ids(&folded), vec!["Deployment.apps/web@app"]);
    assert!(apply_ids(&folded).is_empty());
}

#[test]
fn an_object_the_new_build_declares_again_is_not_an_orphan() {
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![
        manifest("Deployment", "web", "app", "h1", ""),
        manifest("ConfigMap", "removed", "app", "h10", ""),
    ];
    let kept = vec![manifest("ConfigMap", "removed", "app", "h9", "")];

    let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[kept]);
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn kept_closures_and_the_active_diff_do_not_duplicate_orphans() {
    let active = vec![
        manifest("Deployment", "web", "app", "h1", ""),
        manifest("ConfigMap", "gone", "app", "h5", ""),
    ];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let first = vec![
        manifest("ConfigMap", "gone", "app", "h4", ""),
        manifest("Secret", "older", "app", "h3", ""),
    ];
    let second = vec![manifest("Secret", "older", "app", "h3", "")];

    let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[first, second]);
    assert_eq!(
        orphan_ids(&folded),
        vec!["ConfigMap/gone@app", "Secret/older@app"]
    );
}

#[test]
fn a_closure_leaves_orphans_only_for_deletable_objects_the_new_build_lacks() {
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    assert!(leaves_orphans(
        &[manifest("ConfigMap", "removed", "app", "h9", "")],
        &new
    ));
    // Same identity under a different hash is an update, not an orphan.
    assert!(!leaves_orphans(
        &[manifest("Deployment", "web", "app", "h0", "")],
        &new
    ));
    // Records are superseded and Namespaces are never pruned.
    assert!(!leaves_orphans(&[record("demo-old", "h8")], &new));
    let mut ns = manifest("Namespace", "app", "app", "h7", "");
    ns["apiVersion"] = json!("v1");
    ns["metadata"].as_object_mut().unwrap().remove("namespace");
    assert!(!leaves_orphans(&[ns], &new));
}

#[test]
fn an_object_only_the_failed_closure_has_is_an_orphan() {
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let failed = vec![
        manifest("Deployment", "web", "app", "h2", ""),
        manifest("ConfigMap", "leftover", "app", "h9", ""),
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
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let failed = vec![manifest("Deployment", "web", "app", "h2", "")];

    let actions = detect_changes(&new, &active);
    assert_eq!(skip_ids(&actions), vec!["Deployment.apps/web@app"]);

    let folded = fold_failed_closures(actions, &new, &[failed]);
    assert_eq!(apply_ids(&folded), vec!["Deployment.apps/web@app"]);
    assert!(skip_ids(&folded).is_empty());
}

#[test]
fn a_hash_the_failed_closure_agrees_on_stays_skipped() {
    // F never disagreed about this one, so nothing it did could have
    // changed it and re-applying would be noise.
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let failed = vec![manifest("Deployment", "web", "app", "h1", "")];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert_eq!(skip_ids(&folded), vec!["Deployment.apps/web@app"]);
    assert!(apply_ids(&folded).is_empty());
}

#[test]
fn retrying_the_closure_that_failed_applies_it_and_orphans_nothing() {
    // N == F: every node is already an Apply, and nothing F touched is
    // outside the set we are about to write.
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![
        manifest("Deployment", "web", "app", "h2", ""),
        manifest("ConfigMap", "extra", "app", "h9", ""),
    ];
    let failed = new.clone();

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert_eq!(
        apply_ids(&folded),
        vec!["ConfigMap/extra@app", "Deployment.apps/web@app"]
    );
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn stacked_failed_closures_union_their_leftovers() {
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let first = vec![manifest("ConfigMap", "one", "app", "h7", "")];
    let second = vec![manifest("ConfigMap", "two", "app", "h8", "")];

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
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let failed = vec![
        manifest("Deployment", "web", "app", "h1", ""),
        record("demo-abc123", "h2"),
    ];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert!(orphan_ids(&folded).is_empty());
}

#[test]
fn an_unstamped_manifest_in_a_failed_closure_is_never_an_orphan() {
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
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
        manifest("Deployment", "web", "app", "h1", ""),
        manifest("ConfigMap", "gone", "app", "h5", ""),
    ];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let failed = vec![manifest("ConfigMap", "gone", "app", "h6", "")];

    let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
    assert_eq!(orphan_ids(&folded), vec!["ConfigMap/gone@app"]);
}

#[test]
fn no_failed_closures_changes_nothing() {
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let new = vec![manifest("Deployment", "web", "app", "h1", "")];
    let before = detect_changes(&new, &active);
    let after = fold_failed_closures(before.clone(), &new, &[]);
    assert_eq!(skip_ids(&before), skip_ids(&after));
    assert_eq!(apply_ids(&before), apply_ids(&after));
    assert_eq!(orphan_ids(&before), orphan_ids(&after));
}

#[test]
fn baseline_keeps_active_and_adds_only_what_is_missing() {
    let active = vec![manifest("Deployment", "web", "app", "h1", "")];
    let failed = vec![
        // Same identity as active: the active version wins, so the plan
        // describes the object the way the current closure does.
        manifest("Deployment", "web", "app", "h2", ""),
        manifest("ConfigMap", "leftover", "app", "h9", ""),
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
        "",
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
    assert_eq!(
        apply_ids(&actions),
        vec![format!("Activation.{}/stage1-680afyh7g9kd", keys::GROUP)]
    );
}

/// An unchanged build keeps the same record name and hash, and must
/// produce `Skip` on both paths so `total_apply == 0` and the deploy can
/// short-circuit when the activation is identical.
#[test]
fn unchanged_record_is_skip_not_apply() {
    let dep = manifest("Deployment", "web", "default", "d1", "");
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
        live_object_as(
            keys::API_VERSION,
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
    let mut marker = manifest("PackageInstance", "pi-import", "ns", "m1", "");
    marker["metadata"]["annotations"][keys::MODE] = serde_json::json!("import");
    let plain = manifest("PackageInstance", "pi-plain", "ns", "p1", "");
    let keep = manifest("Deployment", "web", "default", "d1", "");
    let old = vec![marker, plain, keep.clone()];
    let actions = detect_changes(std::slice::from_ref(&keep), &old);
    let mut orphans = orphan_ids(&actions);
    orphans.sort();
    assert_eq!(
        orphans,
        vec![
            format!("PackageInstance.{}/pi-import@ns", keys::GROUP),
            format!("PackageInstance.{}/pi-plain@ns", keys::GROUP)
        ]
    );
}

/// Invariant 2: no orphan action ever names a record, whatever the
/// shapes of the two sets.
#[test]
fn records_are_never_orphans() {
    let dep = manifest("Deployment", "web", "default", "d1", "");
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
    assert_eq!(orphan_ids(&actions), vec!["Deployment.apps/web@default"]);
}

/// Invariant 3: the store path and the live path agree on the orphan
/// set for the same previous state, records included.
#[test]
fn store_and_live_paths_agree_on_orphans() {
    let desired = vec![
        record("c-new", "new"),
        manifest("Deployment", "keep", "default", "k1", ""),
    ];
    let old = vec![
        record("c-old", "old"),
        manifest("Deployment", "keep", "default", "k1", ""),
        manifest("Deployment", "gone", "default", "g1", ""),
    ];
    let live = vec![
        live_record("c-old", "old"),
        live_object("Deployment", "keep", "default", "k1"),
        live_object("Deployment", "gone", "default", "g1"),
    ];
    let via_store = orphan_ids(&detect_changes(&desired, &old));
    let via_live = orphan_ids(&detect_changes_live(&desired, &live));
    assert_eq!(via_store, vec!["Deployment.apps/gone@default"]);
    assert_eq!(via_store, via_live);
    // Both paths still apply the new record.
    assert!(
        apply_ids(&detect_changes(&desired, &old))
            .iter()
            .any(|id| id.starts_with(&format!("Activation.{}/", keys::GROUP))),
        "store path drops the new record"
    );
    assert!(
        apply_ids(&detect_changes_live(&desired, &live))
            .iter()
            .any(|id| id.starts_with(&format!("Activation.{}/", keys::GROUP))),
        "live path drops the new record"
    );
}

/// When the operator strips the record from the desired manifest set, live
/// Activation records must still not be reported as orphans.
#[test]
fn operator_shape_live_record_is_not_an_orphan() {
    let desired = vec![manifest("Deployment", "web", "default", "d1", "")];
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

    let rid = |group: &str, kind: &str, ns: &str| ResourceId {
        group: group.into(),
        kind: kind.into(),
        namespace: ns.into(),
        name: "shared".into(),
    };
    let candidates = [
        rid("", "ConfigMap", CLUSTER_SCOPED),
        rid("", "ConfigMap", "default"),
        rid("rbac.authorization.k8s.io", "ClusterRole", CLUSTER_SCOPED),
        rid("", "Widget", CLUSTER_SCOPED),
    ];
    assert_eq!(
        super::namespaceless(&discovery, &candidates),
        vec![rid("", "ConfigMap", CLUSTER_SCOPED)]
    );
}

/// Each kind is looked up in its own group: a `batch` Job without a
/// namespace is refused, and a cluster-scoped `Job` of another group that
/// discovery lists first is not.
#[tokio::test]
async fn namespaceless_looks_each_kind_up_in_its_own_group() {
    use crate::cluster::{discovery, fake_api::FakeApi, fake_api::OTHER_JOB_GROUP};
    use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

    let api = FakeApi::default();
    let discovery = discovery::discover_resources(&api.client()).await.unwrap();
    let job = |group: &str| ResourceId {
        group: group.into(),
        kind: "Job".into(),
        namespace: CLUSTER_SCOPED.into(),
        name: "x".into(),
    };
    assert_eq!(
        super::namespaceless(&discovery, &[job("batch"), job(OTHER_JOB_GROUP)]),
        vec![job("batch")]
    );
}

/// An apply, real or dry run, reports a field the server did not store: a
/// custom resource's field its CRD pruned, against the manifest sent.
#[tokio::test]
async fn an_apply_reports_the_fields_the_server_did_not_keep() {
    use crate::cluster::kept::{NotKept, NotKeptField};
    use crate::cluster::{discovery, fake_api::FakeApi, fake_api::TWO_VERSION_GROUP};

    let api = FakeApi::default();
    let client = api.client();
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let (ar, scope) = discovery.iter().find(|(ar, _)| ar.kind == "Gizmo").unwrap();
    let gizmo = serde_json::json!({
        "apiVersion": format!("{TWO_VERSION_GROUP}/v1"),
        "kind": "Gizmo",
        "metadata": { "name": "g", "namespace": "app" },
        "spec": { "size": 3, "colour": "red" },
    });
    let pruned = vec![NotKeptField {
        path: "$.spec.colour".into(),
        change: NotKept::Dropped,
        sent: json!("red"),
        stored: None,
    }];
    for dry_run in [true, false] {
        let prune = |o: &mut serde_json::Value| {
            o["spec"].as_object_mut().unwrap().remove("colour");
        };
        api.on_apply("g", prune);
        let result = super::apply_resource(
            &client,
            ar,
            scope.clone(),
            &gizmo,
            dry_run,
            None,
            None,
            false,
        )
        .await
        .unwrap();
        assert_eq!(result.not_kept, pruned, "dry run {dry_run}");
        if let Some(preview) = &result.preview {
            assert_eq!(preview.not_kept, pruned);
        }
    }

    // The same object stored as sent has nothing to report.
    let result =
        super::apply_resource(&client, ar, scope.clone(), &gizmo, false, None, None, false)
            .await
            .unwrap();
    assert!(result.not_kept.is_empty(), "{:?}", result.not_kept);
}

/// A Job under the rerun rule with `identity_hash` and, when given, the
/// rerun hash the library stamps.
fn rerun_job(identity_hash: &str, rerun_hash: Option<&str>) -> Value {
    let mut job = manifest("Job", "bootstrap", "db", identity_hash, "");
    job["apiVersion"] = json!("batch/v1");
    job["metadata"]["annotations"][keys::RERUN] = json!(keys::RERUN_ON_CHANGE);
    if let Some(hash) = rerun_hash {
        job["metadata"]["annotations"][keys::RERUN_HASH] = json!(hash);
    }
    job
}

/// A change below the Job in the graph, such as a namespace label, moves its
/// identity hash and leaves its rerun hash alone. The Job is applied in
/// place and does not run again.
#[test]
fn rerun_job_with_the_same_content_is_applied_in_place() {
    let old = vec![rerun_job("id1", Some("c1"))];
    let new = vec![rerun_job("id2", Some("c1"))];
    let actions = detect_changes(&new, &old);
    assert!(matches!(&actions[..], [ChangeAction::Apply(_)]));
}

/// A change to the Job's own content, such as a new password checksum,
/// recreates it.
#[test]
fn rerun_job_with_new_content_is_recreated() {
    let old = vec![rerun_job("id1", Some("c1"))];
    let new = vec![rerun_job("id2", Some("c2"))];
    let actions = detect_changes(&new, &old);
    assert!(matches!(&actions[..], [ChangeAction::Recreate(..)]));
}

/// A new Job, and a Job deployed by a release that wrote no rerun hash, have
/// nothing to compare with and are recreated.
#[test]
fn rerun_job_without_an_old_rerun_hash_is_recreated() {
    let new = vec![rerun_job("id2", Some("c1"))];
    assert!(matches!(
        &detect_changes(&new, &[])[..],
        [ChangeAction::Recreate(..)]
    ));
    let old = vec![rerun_job("id1", None)];
    assert!(matches!(
        &detect_changes(&new, &old)[..],
        [ChangeAction::Recreate(..)]
    ));
}

/// An unchanged Job is skipped whatever its rerun hash says.
#[test]
fn unchanged_rerun_job_is_skipped() {
    let old = vec![rerun_job("id1", Some("c1"))];
    let new = vec![rerun_job("id1", Some("c1"))];
    assert!(matches!(
        &detect_changes(&new, &old)[..],
        [ChangeAction::Skip(_)]
    ));
}

/// The rerun hash only matters to a Job under the rerun rule.
#[test]
fn rerun_hash_on_a_plain_resource_is_ignored() {
    let mut old = manifest("Deployment", "app", "default", "id1", "");
    old["metadata"]["annotations"][keys::RERUN_HASH] = json!("c1");
    let mut new = manifest("Deployment", "app", "default", "id2", "");
    new["metadata"]["annotations"][keys::RERUN_HASH] = json!("c2");
    assert!(matches!(
        &detect_changes(&[new], &[old])[..],
        [ChangeAction::Apply(_)]
    ));
}

/// The operator compares with the rerun hash on the live Job.
#[test]
fn live_rerun_job_compares_the_live_rerun_hash() {
    let live_with = |rerun_hash: &str| {
        let mut obj = live_object_as("batch/v1", "Job", "bootstrap", "db", "id1");
        obj.metadata
            .annotations
            .as_mut()
            .unwrap()
            .insert(keys::RERUN_HASH.to_string(), rerun_hash.to_string());
        obj
    };
    let desired = vec![rerun_job("id2", Some("c1"))];
    assert!(matches!(
        &detect_changes_live(&desired, &[live_with("c1")])[..],
        [ChangeAction::Apply(_)]
    ));
    assert!(matches!(
        &detect_changes_live(&desired, &[live_with("c0")])[..],
        [ChangeAction::Recreate(..)]
    ));
    assert!(matches!(
        &detect_changes_live(
            &desired,
            &[live_object_as("batch/v1", "Job", "bootstrap", "db", "id1")]
        )[..],
        [ChangeAction::Recreate(..)]
    ));
}

/// A failed deploy may have recreated the Job with other content. The Job
/// keeps its last run only when every failed closure agrees with the new
/// build's rerun hash.
#[test]
fn rerun_job_a_failed_deploy_touched_follows_its_content() {
    let active = vec![rerun_job("id1", Some("c1"))];
    let new = vec![rerun_job("id1", Some("c1"))];
    let same_content = vec![rerun_job("id2", Some("c1"))];
    let other_content = vec![rerun_job("id3", Some("c2"))];

    let folded = fold_failed_closures(
        detect_changes(&new, &active),
        &new,
        std::slice::from_ref(&same_content),
    );
    assert!(matches!(&folded[..], [ChangeAction::Apply(_)]));

    let folded = fold_failed_closures(
        detect_changes(&new, &active),
        &new,
        &[same_content, other_content],
    );
    assert!(matches!(&folded[..], [ChangeAction::Recreate(..)]));
}

/// A Job under the rerun rule whose last run failed runs again, and the
/// reason names the failed run, whether or not its content changed since the
/// deployed build. A Job no build had runs as new. Without the rule a failed
/// run changes nothing.
#[test]
fn rerun_job_whose_last_run_failed_names_the_failed_run() {
    for old_content in [Some("c1"), Some("c0"), None] {
        assert!(matches!(
            changed(
                &rerun_job("id2", Some("c1")),
                Deployed::RerunHash(old_content),
                true
            ),
            ChangeAction::Recreate(_, RerunReason::LastRunFailed)
        ));
    }
    assert!(matches!(
        changed(
            &rerun_job("id2", Some("c1")),
            Deployed::RerunHash(Some("c0")),
            false
        ),
        ChangeAction::Recreate(_, RerunReason::Changed)
    ));
    assert!(matches!(
        changed(&rerun_job("id2", Some("c1")), Deployed::Nothing, false),
        ChangeAction::Recreate(_, RerunReason::New)
    ));
    let plain = manifest("Job", "bootstrap", "db", "id2", "");
    assert!(matches!(
        changed(&plain, Deployed::Nothing, true),
        ChangeAction::Apply(_)
    ));
}

/// Two kinds of one name in two groups are two objects. A build that swaps
/// one for the other applies the new one and prunes the old one, from the
/// old build or from the live objects.
#[test]
fn a_kind_of_one_name_in_another_group_is_another_object() {
    let cert = |api_version: &str| {
        let mut m = manifest("Certificate", "tls", "app", "c1", "");
        m["apiVersion"] = json!(api_version);
        m
    };
    let old = cert("a.example/v1");
    let new = cert("b.example/v1");
    let orphan = |actions: &[ChangeAction]| -> Vec<ResourceId> {
        actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect()
    };

    let actions = detect_changes(std::slice::from_ref(&new), std::slice::from_ref(&old));
    assert_eq!(apply_ids(&actions), vec!["Certificate.b.example/tls@app"]);
    assert_eq!(orphan(&actions), vec![ResourceId::from_value(&old)]);

    let live = live_object_as("a.example/v1", "Certificate", "tls", "app", "c1");
    let actions = detect_changes_live(std::slice::from_ref(&new), &[live]);
    assert_eq!(apply_ids(&actions), vec!["Certificate.b.example/tls@app"]);
    assert_eq!(orphan(&actions), vec![ResourceId::from_value(&old)]);
}

/// An apply onto an object that is being deleted is refused before the
/// patch, because the object would be gone after the deploy. The message
/// names the finalizer it waits for.
#[tokio::test]
async fn an_object_being_deleted_is_not_applied() {
    use crate::cluster::{discovery, fake_api::FakeApi};

    let api = FakeApi::new([serde_json::json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "cm",
            "namespace": "app",
            "deletionTimestamp": "2026-11-24T15:54:00Z",
            "finalizers": ["example.com/hold"],
        },
    })]);
    let client = api.client();
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let (ar, scope) = discovery
        .iter()
        .find(|(ar, _)| ar.kind == "ConfigMap")
        .unwrap();
    let cm = serde_json::json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": "cm", "namespace": "app" },
        "data": { "k": "v" },
    });
    let err = super::apply_resource(&client, ar, scope.clone(), &cm, false, None, None, false)
        .await
        .unwrap_err();
    assert!(
        matches!(&err, super::ApplyError::BeingDeleted { reason, uid: Some(_), .. }
            if reason == "being deleted, waiting for example.com/hold"),
        "{err}"
    );
    assert!(
        !api.requests().iter().any(|r| r.starts_with("PATCH")),
        "{:?}",
        api.requests()
    );
}
