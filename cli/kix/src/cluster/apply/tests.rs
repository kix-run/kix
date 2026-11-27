use super::*;
use crate::cluster::field_manager::FieldManager;
use crate::cluster::test_fixtures::manifest;
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

/// A path the API server writes resolves on the object it names: a label
/// key that holds dots, a list element picked by keys or by a set value,
/// and a position. A path that finds no value, or two that differ, does
/// not resolve.
#[test]
fn a_server_field_path_is_read_from_the_live_object() {
    let obj = json!({
        "metadata": {
            "labels": { "app.kubernetes.io/name": "web", "app": "x" },
            "finalizers": ["a", "b"],
        },
        "spec": { "ports": [
            { "port": 80, "protocol": "TCP", "targetPort": 8080 },
            { "port": 80, "protocol": "UDP", "targetPort": 53 },
        ] },
    });
    assert_eq!(
        ssa::value_at(&obj, ".metadata.labels.app.kubernetes.io/name"),
        Some(&json!("web"))
    );
    assert_eq!(
        ssa::value_at(&obj, ".metadata.labels.app"),
        Some(&json!("x"))
    );
    assert_eq!(
        ssa::value_at(&obj, r#".spec.ports[port=80,protocol="UDP"].targetPort"#),
        Some(&json!(53))
    );
    assert_eq!(
        ssa::value_at(&obj, r#".metadata.finalizers[="b"]"#),
        Some(&json!("b"))
    );
    assert_eq!(ssa::value_at(&obj, ".spec.ports[0].port"), Some(&json!(80)));
    assert_eq!(ssa::value_at(&obj, ".spec.ports[port=80].targetPort"), None);
    assert_eq!(ssa::value_at(&obj, ".spec.missing"), None);
}

/// The 409 answer to an unforced apply names what a forced apply takes,
/// from its causes when it has them and from its message otherwise. A 409
/// that names no manager is a `resourceVersion` that moved, and a field the
/// object does not hold leaves the answer unknown.
#[test]
fn a_conflict_answer_gives_what_a_forced_apply_takes() {
    let live: kube::api::DynamicObject = serde_json::from_value(json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": "cm", "labels": { "app.kubernetes.io/part-of": "shop" } },
        "data": { "k": "edited" },
    }))
    .unwrap();
    let status = |message: &str, causes: Vec<kube::core::response::StatusCause>| {
        let mut s = kube::core::Status::failure(message, "Conflict");
        s.code = 409;
        if !causes.is_empty() {
            s.details = Some(serde_json::from_value(json!({ "causes": causes })).unwrap());
        }
        s
    };
    let cause = |manager: &str, field: &str| kube::core::response::StatusCause {
        reason: "FieldManagerConflict".into(),
        message: format!("conflict with \"{manager}\" using v1"),
        field: field.into(),
    };
    let taken = |manager: &str, path: &str, live: &str| crate::cluster::drift::TakenField {
        manager: manager.into(),
        path: path.into(),
        live: live.into(),
    };
    let from_causes = status(
        "Apply failed with 2 conflicts: ...",
        vec![
            cause("kubectl-edit", ".data.k"),
            cause("helm", ".metadata.labels.app.kubernetes.io/part-of"),
        ],
    );
    assert_eq!(
        ssa::taken_in(&from_causes, &live),
        ssa::Takes::Fields(vec![
            taken(
                "helm",
                ".metadata.labels.app.kubernetes.io/part-of",
                "\"shop\""
            ),
            taken("kubectl-edit", ".data.k", "\"edited\""),
        ])
    );
    let from_message = status(
        "Apply failed with 1 conflict: conflict with \"kubectl-edit\" using v1: .data.k",
        Vec::new(),
    );
    assert_eq!(
        ssa::taken_in(&from_message, &live),
        ssa::Takes::Fields(vec![taken("kubectl-edit", ".data.k", "\"edited\"")])
    );
    let moved = status(
        "Operation cannot be fulfilled on configmaps \"cm\": the object has been modified",
        Vec::new(),
    );
    assert_eq!(ssa::taken_in(&moved, &live), ssa::Takes::Moved);
    let missing = status(
        "Apply failed with 1 conflict: conflict with \"x\" using v1: .data.gone",
        Vec::new(),
    );
    assert_eq!(ssa::taken_in(&missing, &live), ssa::Takes::Unknown);
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
/// produce `Skip` so `total_apply == 0` and the deploy can
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
/// one for the other applies the new one and prunes the old one.
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
    let err = super::apply_resource(
        &client,
        ar,
        scope.clone(),
        &FieldManager::of("a"),
        &cm,
        false,
        super::Takeover::No,
    )
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

fn secret(body: Value) -> Value {
    let mut s = json!({"apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "creds", "namespace": "app"}, "type": "Opaque"});
    s.as_object_mut()
        .unwrap()
        .extend(body.as_object().unwrap().clone());
    s
}

/// A Secret's `stringData` goes into `data` as base64. A key in both takes
/// the `stringData` value, and `data` keys it does not name stay as they are.
#[test]
fn string_data_is_sent_as_data() {
    let sent = |body: Value| string_data_as_data(&secret(body)).into_owned();
    assert_eq!(
        sent(json!({
            "stringData": {"user": "admin", "password": "hunter2"},
            // "old", and bytes that are not UTF-8
            "data": {"password": "b2xk", "key.bin": "/w=="},
        })),
        secret(json!({"data": {
            "user": "YWRtaW4=",
            "password": "aHVudGVyMg==",
            "key.bin": "/w==",
        }}))
    );
    assert_eq!(
        sent(json!({"stringData": {"user": "admin"}})),
        secret(json!({"data": {"user": "YWRtaW4="}}))
    );
    assert_eq!(
        sent(json!({"stringData": {"user": "admin"}, "data": null})),
        secret(json!({"data": {"user": "YWRtaW4="}}))
    );
    assert_eq!(
        sent(json!({"stringData": {}, "data": {"k": "eA=="}})),
        secret(json!({"data": {"k": "eA=="}}))
    );
}

/// Anything but a Secret with a map of strings in `stringData` is sent as
/// the build has it. The server refuses a malformed Secret with its own
/// message.
#[test]
fn other_manifests_are_sent_as_they_are() {
    use std::borrow::Cow;

    let config_map = json!({"apiVersion": "v1", "kind": "ConfigMap",
        "metadata": {"name": "c", "namespace": "app"}, "stringData": {"a": "b"}});
    let unchanged = [
        config_map,
        secret(json!({"data": {"k": "eA=="}})),
        secret(json!({"stringData": {"port": 5432}})),
        secret(json!({"stringData": {"a": "b"}, "data": "not a map"})),
        secret(json!({"stringData": "not a map"})),
    ];
    for m in &unchanged {
        assert!(
            matches!(string_data_as_data(m), Cow::Borrowed(b) if b == m),
            "{m}"
        );
    }
}

/// A real apply and a dry run both send the Secret's values as `data`, so
/// the plan previews what the deploy writes. The server stores `data` as
/// sent, so nothing is reported as not kept.
#[tokio::test]
async fn an_apply_sends_secret_values_as_data() {
    use crate::cluster::{discovery, fake_api::FakeApi};

    let api = FakeApi::default();
    let client = api.client();
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let (ar, scope) = discovery
        .iter()
        .find(|(ar, _)| ar.kind == "Secret")
        .unwrap();
    let built = secret(json!({"stringData": {"password": "hunter2"}}));
    let sent = secret(json!({"data": {"password": "aHVudGVyMg=="}}));
    let without_server_fields = |mut o: Value| {
        let meta = o["metadata"].as_object_mut().unwrap();
        meta.remove("uid");
        meta.remove("resourceVersion");
        o
    };

    let result = super::apply_resource(
        &client,
        ar,
        scope.clone(),
        &FieldManager::of("a"),
        &built,
        true,
        super::Takeover::No,
    )
    .await
    .unwrap();
    let preview = result.preview.expect("a dry run previews");
    assert_eq!(without_server_fields(preview.result), sent);
    assert!(result.not_kept.is_empty(), "{:?}", result.not_kept);
    assert_eq!(api.object("Secret", "creds"), None);

    let result = super::apply_resource(
        &client,
        ar,
        scope.clone(),
        &FieldManager::of("a"),
        &built,
        false,
        super::Takeover::No,
    )
    .await
    .unwrap();
    assert!(result.not_kept.is_empty(), "{:?}", result.not_kept);
    assert_eq!(
        without_server_fields(api.object("Secret", "creds").unwrap()),
        sent
    );
}

/// A conflict on a Secret's `data` keys names the Secret case. Any other
/// conflict, on a Secret or not, is the general one.
#[test]
fn a_conflict_on_secret_data_is_named_as_such() {
    let rid = |kind: &str| ResourceId {
        group: String::new(),
        kind: kind.into(),
        namespace: "app".into(),
        name: "creds".into(),
    };
    let conflict = |message: &str| {
        kube::Error::Api(
            kube::core::Status::failure(message, "Conflict")
                .with_code(409)
                .boxed(),
        )
    };
    let on_data =
        "Apply failed with 1 conflict: conflict with \"kubectl-edit\" using v1: .data.password";
    let on_labels =
        "Apply failed with 1 conflict: conflict with \"x\" using v1: .metadata.labels.app";

    let err = super::conflict_error(
        &rid("Secret"),
        &FieldManager::of("a"),
        "Secret/creds@app".into(),
        conflict(on_data),
    );
    assert!(
        matches!(err, ApplyError::SecretDataConflict { .. }),
        "{err}"
    );
    assert!(err.to_string().starts_with("[K9044] "), "{err}");
    for (kind, message) in [("Secret", on_labels), ("ConfigMap", on_data)] {
        let err = super::conflict_error(
            &rid(kind),
            &FieldManager::of("a"),
            format!("{kind}/creds@app"),
            conflict(message),
        );
        assert!(matches!(err, ApplyError::Conflict { .. }), "{kind}: {err}");
    }
}

/// A Secret key ceded to another manager is left out of the apply when that
/// manager owns it, because the conflict names the `data` key the apply sends.
#[test]
fn a_ceded_secret_key_is_stripped_from_data() {
    let mut built = secret(json!({"stringData": {"user": "admin", "token": "t"}}));
    built["metadata"]["annotations"] = json!({ super::keys::CEDE_FIELDS: "data.token" });
    let sent = string_data_as_data(&built);
    let msg = "Apply failed with 1 conflict: conflict with \"issuer\" using v1: .data.token";
    let stripped = super::without_ceded_conflicts(&sent, msg).expect("ceded");
    assert_eq!(stripped["data"], json!({"user": "YWRtaW4="}));
}

/// An apply names the Kix cluster's own field manager, writes nothing else,
/// and the applied hash is read from its entry.
#[tokio::test]
async fn an_apply_writes_under_the_clusters_own_manager() {
    use crate::cluster::{discovery, fake_api::FakeApi};

    let api = FakeApi::default();
    api.track_owners();
    let client = api.client();
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let (ar, scope) = discovery
        .iter()
        .find(|(ar, _)| ar.kind == "ConfigMap")
        .unwrap();
    let cm = json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": "shared", "namespace": "app" },
        "data": { "key": "1" },
    });
    let manager = FieldManager::of("lab");
    let result = super::apply_resource(
        &client,
        ar,
        scope.clone(),
        &manager,
        &cm,
        false,
        super::Takeover::No,
    )
    .await
    .unwrap();
    assert!(result.applied_hash.is_some());
    let writes: Vec<String> = api
        .requests()
        .into_iter()
        .filter(|r| r.starts_with("PATCH"))
        .collect();
    // The apply is the one write: no annotation write follows it.
    assert_eq!(writes.len(), 1, "{writes:?}");
    assert!(
        writes.iter().all(|r| r.contains("fieldManager=kix%2Flab")),
        "{writes:?}"
    );
    let stored = api.object("ConfigMap", "shared").unwrap();
    assert_eq!(stored["metadata"]["managedFields"][0]["manager"], "kix/lab");
}

/// An apply refused because another Kix cluster applies different values
/// names that Kix cluster and the fields, and says what to do. A conflict
/// with a manager that is not a Kix cluster's keeps the plain message.
#[tokio::test]
async fn a_conflict_with_another_kix_cluster_names_it() {
    use crate::cluster::{discovery, fake_api::FakeApi};

    let api = FakeApi::default();
    api.track_owners();
    let client = api.client();
    let discovery = discovery::discover_resources(&client).await.unwrap();
    let (ar, scope) = discovery
        .iter()
        .find(|(ar, _)| ar.kind == "ConfigMap")
        .unwrap();
    let cm = |value: &str| {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "shared", "namespace": "app" },
            "data": { "key": value },
        })
    };
    let apply = |manager: &str, value: &str| {
        let (client, ar, scope, manifest) = (client.clone(), ar.clone(), scope.clone(), cm(value));
        let manager = FieldManager::of(manager);
        async move {
            super::apply_resource(
                &client,
                &ar,
                scope,
                &manager,
                &manifest,
                false,
                super::Takeover::No,
            )
            .await
        }
    };
    apply("b", "1").await.unwrap();
    // The same content from a second Kix cluster is accepted.
    apply("a", "1").await.unwrap();
    let err = apply("a", "2").await.unwrap_err();
    let ApplyError::KixClusterConflict { clusters, .. } = &err else {
        panic!("{err}");
    };
    assert_eq!(clusters.len(), 1);
    assert_eq!(clusters[0].manager, "b");
    assert_eq!(clusters[0].fields, [".data.key"]);
    let message = err.to_string();
    for part in [
        "ConfigMap/shared@app was not updated.",
        "Kix cluster `b` also deploys it",
        "Kix cluster `b` owns .data.key.",
        "Make the definitions agree",
        "`--force-conflicts`",
        "the next deploy of `b` will be refused",
    ] {
        assert!(message.contains(part), "{part}: {message}");
    }

    let not_kix = super::conflict_error(
        &ResourceId {
            group: String::new(),
            kind: "ConfigMap".into(),
            namespace: "app".into(),
            name: "shared".into(),
        },
        &FieldManager::of("a"),
        "ConfigMap/shared@app".into(),
        kube::Error::Api(
            kube::core::Status::failure(
                "Apply failed with 1 conflict: conflict with \"kix\": .data.key",
                "Conflict",
            )
            .with_code(409)
            .boxed(),
        ),
    );
    assert!(matches!(not_kix, ApplyError::Conflict { .. }), "{not_kix}");
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
    let err = super::apply_resource(
        &client,
        ar,
        scope.clone(),
        &FieldManager::of("a"),
        &cm,
        false,
        super::Takeover::No,
    )
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
            &FieldManager::of("a"),
            &gizmo,
            dry_run,
            super::Takeover::No,
        )
        .await
        .unwrap();
        assert_eq!(result.not_kept, pruned, "dry run {dry_run}");
        if let Some(preview) = &result.preview {
            assert_eq!(preview.not_kept, pruned);
        }
    }

    // The same object stored as sent has nothing to report.
    let result = super::apply_resource(
        &client,
        ar,
        scope.clone(),
        &FieldManager::of("a"),
        &gizmo,
        false,
        super::Takeover::No,
    )
    .await
    .unwrap();
    assert!(result.not_kept.is_empty(), "{:?}", result.not_kept);
}
