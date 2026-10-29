use super::*;
use crate::manifest::keys;
use kube::api::ObjectMeta;
use serde_json::json;

fn make_obj(data: Value) -> DynamicObject {
    DynamicObject {
        metadata: ObjectMeta {
            name: Some("test".into()),
            ..Default::default()
        },
        types: None,
        data,
    }
}

/// Build the live-object shape with generation in the typed ObjectMeta.
fn make_obj_gen(generation: i64, data: Value) -> DynamicObject {
    DynamicObject {
        metadata: ObjectMeta {
            name: Some("test".into()),
            generation: Some(generation),
            ..Default::default()
        },
        types: None,
        data,
    }
}

/// Build a `DynamicObject` with a `kix.run/readiness` annotation.
fn make_annotated_obj(annotation: &str, data: Value) -> DynamicObject {
    let mut annotations = std::collections::BTreeMap::new();
    annotations.insert(keys::READINESS.to_string(), annotation.to_string());
    DynamicObject {
        metadata: ObjectMeta {
            name: Some("test".into()),
            annotations: Some(annotations),
            ..Default::default()
        },
        types: None,
        data,
    }
}

const VM_RULE: &str = r#"{"path":"/status/updateStatus","equals":"operational"}"#;

#[test]
fn declared_readiness_parses_valid_annotation() {
    let obj = make_annotated_obj(VM_RULE, json!({}));
    match declared_readiness(&obj).expect("should parse") {
        DeclaredReadiness::Path { path, equals } => {
            assert_eq!(path, "/status/updateStatus");
            assert_eq!(equals, "operational");
        }
        _ => panic!("parsed as another form"),
    }
}

const VM_CHILD_RULE: &str = r#"{"path":"/status/updateStatus","notEquals":"failed"}"#;

// A VMServiceScrape gets updateStatus only from a VMAgent that selects
// it: absent with no consumer, `failed` when the consumer rejects it.
#[test]
fn declared_not_equals_readiness_accepts_absent_and_refuses_the_value() {
    match declared_readiness(&make_annotated_obj(VM_CHILD_RULE, json!({}))).expect("should parse") {
        DeclaredReadiness::PathNot { path, not_equals } => {
            assert_eq!(path, "/status/updateStatus");
            assert_eq!(not_equals, "failed");
        }
        _ => panic!("parsed as another form"),
    }

    let unclaimed = make_annotated_obj(VM_CHILD_RULE, json!({}));
    assert!(check_readiness(&unclaimed, "VMServiceScrape"));
    let applied = make_annotated_obj(
        VM_CHILD_RULE,
        json!({"status": {"updateStatus": "operational"}}),
    );
    assert!(check_readiness(&applied, "VMServiceScrape"));

    let failed = make_annotated_obj(VM_CHILD_RULE, json!({"status": {"updateStatus": "failed"}}));
    assert!(!check_readiness(&failed, "VMServiceScrape"));
    let msg = readiness_message(&failed, "VMServiceScrape");
    assert!(
        msg.contains(r#"declared readiness /status/updateStatus!="failed", currently "failed""#),
        "got: {msg}"
    );

    // The generation guard applies as for `equals`.
    let stale = with_generation(
        make_annotated_obj(
            VM_CHILD_RULE,
            json!({"status": {"updateStatus": "operational", "observedGeneration": 1}}),
        ),
        2,
    );
    assert!(!check_readiness(&stale, "VMServiceScrape"));

    // A non-string notEquals is malformed and ignored.
    let bad = make_annotated_obj(r#"{"path":"/status/x","notEquals":true}"#, json!({}));
    assert!(declared_readiness(&bad).is_none());
}

#[test]
fn declared_readiness_ignores_malformed_annotations() {
    for bad in [
        "not json",
        r#"{"path":"/status/x"}"#,               // missing equals
        r#"{"equals":"ok"}"#,                    // missing path
        r#"{"path":42,"equals":"ok"}"#,          // non-string path
        r#"{"path":"/status/x","equals":true}"#, // non-string equals
    ] {
        let obj = make_annotated_obj(bad, json!({}));
        assert!(declared_readiness(&obj).is_none(), "should reject: {bad}");
    }
    // No annotation at all.
    assert!(declared_readiness(&make_obj(json!({}))).is_none());
}

#[test]
fn declared_readiness_gates_check_readiness() {
    let ready = make_annotated_obj(VM_RULE, json!({"status": {"updateStatus": "operational"}}));
    assert!(check_readiness(&ready, "VMCluster"));

    let expanding = make_annotated_obj(VM_RULE, json!({"status": {"updateStatus": "expanding"}}));
    assert!(!check_readiness(&expanding, "VMCluster"));

    // No status yet: declared readiness waits (unlike generic ready-on-empty).
    let fresh = make_annotated_obj(VM_RULE, json!({}));
    assert!(!check_readiness(&fresh, "VMCluster"));
}

const CONDITION_RULE: &str = r#"{"condition":{"type":"Bootstrapped","status":"True"}}"#;

#[test]
fn declared_condition_parses() {
    let obj = make_annotated_obj(CONDITION_RULE, json!({}));
    match declared_readiness(&obj).expect("should parse") {
        DeclaredReadiness::Condition {
            condition_type,
            status,
        } => {
            assert_eq!(condition_type, "Bootstrapped");
            assert_eq!(status, "True");
        }
        _ => panic!("parsed as a path form"),
    }
    for bad in [
        r#"{"condition":{"type":"Bootstrapped"}}"#, // missing status
        r#"{"condition":{"status":"True"}}"#,       // missing type
        r#"{"condition":"Bootstrapped"}"#,          // not an object
    ] {
        let obj = make_annotated_obj(bad, json!({}));
        assert!(declared_readiness(&obj).is_none(), "should reject: {bad}");
    }
}

#[test]
fn declared_condition_gates_check_readiness() {
    let ready = make_annotated_obj(
        CONDITION_RULE,
        json!({"status": {"conditions": [{"type": "Bootstrapped", "status": "True"}]}}),
    );
    assert!(check_readiness(&ready, "SGCluster"));

    let pending = make_annotated_obj(
        CONDITION_RULE,
        json!({"status": {"conditions": [{"type": "Bootstrapped", "status": "False"}]}}),
    );
    assert!(!check_readiness(&pending, "SGCluster"));

    // A generic Ready=True does not satisfy a declared condition.
    let other = make_annotated_obj(
        CONDITION_RULE,
        json!({"status": {"conditions": [{"type": "Ready", "status": "True"}]}}),
    );
    assert!(!check_readiness(&other, "SGCluster"));

    // No status yet: declared readiness waits.
    let fresh = make_annotated_obj(CONDITION_RULE, json!({}));
    assert!(!check_readiness(&fresh, "SGCluster"));
}

#[test]
fn declared_condition_message_shapes() {
    let rule = r#"{"condition":{"type":"Valid","status":"True"}}"#;
    let invalid = make_annotated_obj(
        rule,
        json!({"status": {"conditions": [
            {"type": "Valid", "status": "False", "message": "bad selector"}
        ]}}),
    );
    let msg = readiness_message(&invalid, "CiliumNetworkPolicy");
    assert!(
        msg.contains(
            "declared readiness condition Valid=True, currently Valid=False (bad selector)"
        ),
        "got: {msg}"
    );

    let absent = make_annotated_obj(rule, json!({}));
    let msg = readiness_message(&absent, "CiliumNetworkPolicy");
    assert!(msg.contains("no Valid condition yet"), "got: {msg}");
}

#[test]
fn malformed_annotation_falls_through_to_kind_rules() {
    // Malformed annotations fall through for version compatibility. The CR
    // then uses check_generic_ready, which treats an empty status as ready.
    let no_status = make_annotated_obj("not json", json!({}));
    assert!(check_readiness(&no_status, "VMCluster"));

    // ...and unrecognized condition vocabulary as not-ready.
    let stamped = make_annotated_obj(
        "not json",
        json!({"status": {"conditions": [
            {"type": "x.example.com/Applied", "status": "True"}
        ]}}),
    );
    assert!(!check_readiness(&stamped, "VMCluster"));
}

// A boolean or number at the path matches by its JSON text, as
// CloudNativePG's Database reports `status.applied` as a JSON boolean.
#[test]
fn declared_readiness_matches_scalars_by_text() {
    let applied = r#"{"path":"/status/applied","equals":"true"}"#;
    let ready = make_annotated_obj(applied, json!({"status": {"applied": true}}));
    assert!(check_readiness(&ready, "Database"));

    let failed = make_annotated_obj(applied, json!({"status": {"applied": false}}));
    assert!(!check_readiness(&failed, "Database"));
    let msg = readiness_message(&failed, "Database");
    assert!(
        msg.contains(r#"declared readiness /status/applied="true", currently false"#),
        "got: {msg}"
    );

    let replicas = r#"{"path":"/status/replicas","equals":"3"}"#;
    let three = make_annotated_obj(replicas, json!({"status": {"replicas": 3}}));
    assert!(check_readiness(&three, "VMCluster"));
    let two = make_annotated_obj(replicas, json!({"status": {"replicas": 2}}));
    assert!(!check_readiness(&two, "VMCluster"));

    // A string still compares as a string.
    let text = make_annotated_obj(applied, json!({"status": {"applied": "true"}}));
    assert!(check_readiness(&text, "Database"));

    // A missing path is not ready.
    let fresh = make_annotated_obj(applied, json!({"status": {}}));
    assert!(!check_readiness(&fresh, "Database"));
    assert!(readiness_message(&fresh, "Database").contains("<absent>"));
}

fn with_generation(mut obj: DynamicObject, generation: i64) -> DynamicObject {
    obj.metadata.generation = Some(generation);
    obj
}

// A path rule waits until status.observedGeneration reaches
// metadata.generation, so a status left from the previous spec is not
// taken as ready; without status.observedGeneration there is no guard.
#[test]
fn declared_path_readiness_waits_for_observed_generation() {
    let applied = r#"{"path":"/status/applied","equals":"true"}"#;
    let stale = with_generation(
        make_annotated_obj(
            applied,
            json!({"status": {"applied": true, "observedGeneration": 1}}),
        ),
        2,
    );
    assert!(!check_readiness(&stale, "Database"));
    let msg = readiness_message(&stale, "Database");
    assert!(msg.contains("observed generation 1 of 2"), "got: {msg}");

    let current = with_generation(
        make_annotated_obj(
            applied,
            json!({"status": {"applied": true, "observedGeneration": 2}}),
        ),
        2,
    );
    assert!(check_readiness(&current, "Database"));
    assert!(!readiness_message(&current, "Database").contains("observed generation"));

    let absent = with_generation(
        make_annotated_obj(applied, json!({"status": {"applied": true}})),
        2,
    );
    assert!(check_readiness(&absent, "Database"));
}

// A condition rule waits until the condition's own observedGeneration
// reaches metadata.generation; a condition without one has no guard.
#[test]
fn declared_condition_readiness_waits_for_observed_generation() {
    let rule = r#"{"condition":{"type":"Ready","status":"True"}}"#;
    let condition = |extra: Value| {
        let mut c = json!({"type": "Ready", "status": "True"});
        if let (Some(c), Some(extra)) = (c.as_object_mut(), extra.as_object()) {
            c.extend(extra.clone());
        }
        json!({"status": {"conditions": [c]}})
    };

    let stale = with_generation(
        make_annotated_obj(rule, condition(json!({"observedGeneration": 3}))),
        4,
    );
    assert!(!check_readiness(&stale, "Cluster"));
    let msg = readiness_message(&stale, "Cluster");
    assert!(msg.contains("observed generation 3 of 4"), "got: {msg}");

    let current = with_generation(
        make_annotated_obj(rule, condition(json!({"observedGeneration": 4}))),
        4,
    );
    assert!(check_readiness(&current, "Cluster"));

    let absent = with_generation(make_annotated_obj(rule, condition(json!({}))), 4);
    assert!(check_readiness(&absent, "Cluster"));
}

// A condition without its own observedGeneration falls back to
// status.observedGeneration; the condition's own value wins when present.
#[test]
fn declared_condition_readiness_falls_back_to_status_generation() {
    let rule = r#"{"condition":{"type":"AllReplicasReady","status":"True"}}"#;
    let obj = |condition: Value, observed: i64| {
        with_generation(
            make_annotated_obj(
                rule,
                json!({"status": {"observedGeneration": observed, "conditions": [condition]}}),
            ),
            5,
        )
    };
    let bare = json!({"type": "AllReplicasReady", "status": "True"});

    let stale = obj(bare.clone(), 4);
    assert!(!check_readiness(&stale, "RabbitmqCluster"));
    let msg = readiness_message(&stale, "RabbitmqCluster");
    assert!(msg.contains("observed generation 4 of 5"), "got: {msg}");

    assert!(check_readiness(&obj(bare, 5), "RabbitmqCluster"));

    let own = json!({"type": "AllReplicasReady", "status": "True", "observedGeneration": 5});
    assert!(check_readiness(&obj(own, 4), "RabbitmqCluster"));
}

#[test]
fn declared_readiness_object_never_matches() {
    let rule = r#"{"path":"/status/applied","equals":"true"}"#;
    let obj = make_annotated_obj(rule, json!({"status": {"applied": {"value": true}}}));
    assert!(!check_readiness(&obj, "Database"));
    let msg = readiness_message(&obj, "Database");
    assert!(
        msg.contains("only strings, booleans, and numbers"),
        "got: {msg}"
    );
    assert!(!msg.contains("<absent>"), "got: {msg}");
}

#[test]
fn declared_readiness_message_shapes() {
    let waiting = make_annotated_obj(VM_RULE, json!({"status": {"updateStatus": "expanding"}}));
    let msg = readiness_message(&waiting, "VMCluster");
    assert!(
        msg.contains(
            r#"declared readiness /status/updateStatus="operational", currently "expanding""#
        ),
        "got: {msg}"
    );

    let absent = make_annotated_obj(VM_RULE, json!({}));
    let msg = readiness_message(&absent, "VMCluster");
    assert!(msg.contains("<absent>"), "got: {msg}");
}

#[test]
fn immediate_kinds() {
    assert!(is_immediate_kind("ConfigMap"));
    assert!(is_immediate_kind("Secret"));
    assert!(is_immediate_kind("Service"));
    assert!(is_immediate_kind("Namespace"));
    assert!(is_immediate_kind("ServiceAccount"));
    assert!(is_immediate_kind("ClusterRole"));
    assert!(is_immediate_kind("ClusterRoleBinding"));
    assert!(is_immediate_kind("Role"));
    assert!(is_immediate_kind("RoleBinding"));
    assert!(is_immediate_kind("Ingress"));
    assert!(!is_immediate_kind("Deployment"));
    assert!(!is_immediate_kind("StatefulSet"));
    assert!(!is_immediate_kind("Job"));
}

#[test]
fn deployment_ready() {
    let obj = make_obj_gen(
        2,
        json!({
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 2,
                "readyReplicas": 3,
                "updatedReplicas": 3,
            }
        }),
    );
    assert!(check_readiness(&obj, "Deployment"));
}

#[test]
fn deployment_not_ready_replicas() {
    let obj = make_obj_gen(
        1,
        json!({
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 2,
                "updatedReplicas": 3,
            }
        }),
    );
    assert!(!check_readiness(&obj, "Deployment"));
}

#[test]
fn deployment_stale_status_not_ready() {
    // When an update increments metadata.generation to 2 while status still
    // reports observedGeneration 1, the Deployment must not be considered ready.
    let obj = make_obj_gen(
        2,
        json!({
            "spec": {"replicas": 3},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 3,
                "updatedReplicas": 3,
            }
        }),
    );
    assert!(!check_readiness(&obj, "Deployment"));
    let ds = make_obj_gen(
        2,
        json!({
            "status": {
                "observedGeneration": 1,
                "desiredNumberScheduled": 3,
                "numberReady": 3,
                "updatedNumberScheduled": 3,
            }
        }),
    );
    assert!(!check_readiness(&ds, "DaemonSet"));
}

fn on_delete_ds(desired: i64, ready: i64, updated: i64) -> DynamicObject {
    make_obj_gen(
        2,
        json!({
            "spec": {"updateStrategy": {"type": "OnDelete"}},
            "status": {
                "observedGeneration": 2,
                "desiredNumberScheduled": desired,
                "numberReady": ready,
                "updatedNumberScheduled": updated,
            }
        }),
    )
}

#[test]
fn on_delete_daemonset_with_stale_pods_is_ready_and_pending_restart() {
    let ds = on_delete_ds(3, 3, 1);
    assert!(check_readiness(&ds, "DaemonSet"));
    assert_eq!(daemonset_pending_restart(&ds.data), Some(2));
}

#[test]
fn on_delete_daemonset_fully_updated_has_no_pending_restart() {
    let ds = on_delete_ds(3, 3, 3);
    assert!(check_readiness(&ds, "DaemonSet"));
    assert_eq!(daemonset_pending_restart(&ds.data), None);
}

#[test]
fn on_delete_daemonset_waits_for_ready_pods() {
    let ds = on_delete_ds(3, 2, 1);
    assert!(!check_readiness(&ds, "DaemonSet"));
}

#[test]
fn on_delete_daemonset_matching_no_node_is_ready() {
    let ds = on_delete_ds(0, 0, 0);
    assert!(check_readiness(&ds, "DaemonSet"));
    assert_eq!(daemonset_pending_restart(&ds.data), None);
}

#[test]
fn rolling_update_daemonset_waits_for_updated_pods() {
    let ds = make_obj_gen(
        2,
        json!({
            "spec": {"updateStrategy": {"type": "RollingUpdate"}},
            "status": {
                "observedGeneration": 2,
                "desiredNumberScheduled": 3,
                "numberReady": 3,
                "updatedNumberScheduled": 1,
            }
        }),
    );
    assert!(!check_readiness(&ds, "DaemonSet"));
    assert_eq!(daemonset_pending_restart(&ds.data), None);
}

#[test]
fn daemonset_matching_no_node_is_ready_once_observed() {
    // io-engine on a cluster with no openebs.io/engine=mayastor node:
    // 0 desired, 0 ready, observed. Complete, not a timeout.
    let ds = make_obj_gen(
        1,
        json!({
            "status": {
                "observedGeneration": 1,
                "desiredNumberScheduled": 0,
                "numberReady": 0,
                "updatedNumberScheduled": 0,
            }
        }),
    );
    assert!(check_readiness(&ds, "DaemonSet"));
    // The same object before the controller has written any status.
    let unobserved = make_obj_gen(1, json!({}));
    assert!(!check_readiness(&unobserved, "DaemonSet"));
}

#[test]
fn statefulset_ready() {
    let obj = make_obj_gen(
        1,
        json!({
            "spec": {"replicas": 2},
            "status": {
                "observedGeneration": 1,
                "readyReplicas": 2,
                "updatedReplicas": 2,
            }
        }),
    );
    assert!(check_readiness(&obj, "StatefulSet"));
}

#[test]
fn undeclared_custom_kind_uses_generic_conditions() {
    // Without a declaration the CLI knows nothing about an operator's
    // vocabulary: Valid=True is not readiness, Ready=True is.
    let valid_only = make_obj(json!({
        "status": {"conditions": [{"type": "Valid", "status": "True"}]}
    }));
    assert!(!check_readiness(&valid_only, "CiliumNetworkPolicy"));

    let ready = make_obj(json!({
        "status": {"conditions": [{"type": "Ready", "status": "True"}]}
    }));
    assert!(check_readiness(&ready, "CiliumNetworkPolicy"));
}

#[test]
fn crd_established() {
    let obj = make_obj(json!({
        "status": {
            "conditions": [
                {"type": "Established", "status": "True"},
                {"type": "NamesAccepted", "status": "True"},
            ]
        }
    }));
    assert!(check_readiness(&obj, "CustomResourceDefinition"));
}

#[test]
fn crd_not_established() {
    let obj = make_obj(json!({
        "status": {
            "conditions": [
                {"type": "Established", "status": "False"},
            ]
        }
    }));
    assert!(!check_readiness(&obj, "CustomResourceDefinition"));
}

#[test]
fn job_completed() {
    let obj = make_obj(json!({
        "status": {"succeeded": 1}
    }));
    assert!(check_readiness(&obj, "Job"));
}

#[test]
fn expectations_are_read_from_the_annotation() {
    let manifest = json!({
        "kind": "Deployment",
        "metadata": {
            "name": "ctrl",
            "namespace": "ingress-system",
            "annotations": { keys::EXPECTS: "v1|Secret|ctrl-admission,cert-manager.io/v1|Certificate|c,broken" }
        }
    });
    let got = expectations(&manifest);
    assert_eq!(got.len(), 2);
    assert_eq!(got[0].api_version, "v1");
    assert_eq!(got[0].kind, "Secret");
    assert_eq!(got[0].name, "ctrl-admission");
    assert_eq!(got[1].api_version, "cert-manager.io/v1");
    assert_eq!(got[1].display(), "Certificate/c");
    assert!(expectations(&json!({ "metadata": { "name": "n" } })).is_empty());
}

#[test]
fn import_marker_parsed() {
    let manifest = json!({
        "apiVersion": keys::API_VERSION,
        "kind": "PackageInstance",
        "metadata": {
            "name": "crd-ref-stackgres-operator-sgclusters-stackgres-io",
            "namespace": "data",
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_KIND: "CustomResourceDefinition",
                keys::IMPORT_API_VERSION: "apiextensions.k8s.io/v1",
                keys::IMPORT_NAME: "sgclusters.stackgres.io",
            }
        }
    });
    let target = import_target_from_manifest(&manifest)
        .unwrap()
        .expect("should parse");
    assert_eq!(target.kind, "CustomResourceDefinition");
    assert_eq!(target.api_version, "apiextensions.k8s.io/v1");
    assert_eq!(target.name, "sgclusters.stackgres.io");
    // CRDs are cluster-scoped; namespace is always None regardless of
    // the marker's own metadata.namespace.
    assert_eq!(target.namespace, None);
    assert!(target.expected_keys.is_empty());
}

#[test]
fn secret_import_marker_inherits_marker_namespace() {
    // Namespaced imports take their namespace from the marker's own
    // metadata.namespace, not from any annotation.
    let manifest = json!({
        "apiVersion": keys::API_VERSION,
        "kind": "PackageInstance",
        "metadata": {
            "name": "secret-ref-myapp-db-creds",
            "namespace": "myapp",
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_KIND: "Secret",
                keys::IMPORT_API_VERSION: "v1",
                keys::IMPORT_NAME: "db-creds",
                keys::IMPORT_SECRET_KEYS: "username,password",
            }
        }
    });
    let target = import_target_from_manifest(&manifest)
        .unwrap()
        .expect("should parse");
    assert_eq!(target.kind, "Secret");
    assert_eq!(target.name, "db-creds");
    assert_eq!(target.namespace.as_deref(), Some("myapp"));
    assert_eq!(target.expected_keys, vec!["username", "password"]);
}

#[test]
fn secret_import_marker_no_keys_annotation() {
    let manifest = json!({
        "kind": "PackageInstance",
        "metadata": {
            "name": "secret-ref-myapp-bootstrap",
            "namespace": "myapp",
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_KIND: "Secret",
                keys::IMPORT_API_VERSION: "v1",
                keys::IMPORT_NAME: "bootstrap",
            }
        }
    });
    let target = import_target_from_manifest(&manifest)
        .unwrap()
        .expect("should parse");
    assert!(target.expected_keys.is_empty());
}

#[test]
fn import_marker_without_kind_has_no_target() {
    // A kind-less import (`kix.mkImport` with no `kind`) names nothing
    // the deploy can look up, so the marker is not waited on.
    let manifest = json!({
        "apiVersion": keys::API_VERSION,
        "kind": "PackageInstance",
        "metadata": {
            "name": "platform-storage",
            "namespace": "kube-system",
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_NAME: "standard",
            }
        }
    });
    assert!(import_target_from_manifest(&manifest).unwrap().is_none());
    // The marker itself is ready as soon as it exists.
    assert!(is_immediate_kind("PackageInstance"));
}

#[test]
fn crd_ref_marker_carries_served_versions() {
    let marker = |extra: Value| {
        let mut annotations = json!({
            keys::MODE: "import",
            keys::IMPORT_KIND: "CustomResourceDefinition",
            keys::IMPORT_API_VERSION: "apiextensions.k8s.io/v1",
            keys::IMPORT_NAME: "scrapeconfigs.monitoring.coreos.com",
            keys::CRD_KIND: "ScrapeConfig",
            keys::CRD_VERSION: "v1alpha1",
        });
        for (k, v) in extra.as_object().unwrap() {
            annotations[k] = v.clone();
        }
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "PackageInstance",
            "metadata": {
                "name": "crd-ref-vm-scrapeconfigs-monitoring-coreos-com",
                "namespace": "monitoring",
                "annotations": annotations,
            }
        })
    };
    let listed = import_target_from_manifest(&marker(json!({
        keys::CRD_SERVED_VERSIONS: "v1alpha1,v1beta1"
    })))
    .unwrap()
    .unwrap();
    assert_eq!(listed.served_versions, vec!["v1alpha1", "v1beta1"]);

    // `crd-version` is the default version, not a served list, so a CRD
    // ref marker without `crd-served-versions` is refused.
    for extra in [json!({}), json!({ keys::CRD_SERVED_VERSIONS: "" })] {
        let err = import_target_from_manifest(&marker(extra)).unwrap_err();
        assert_eq!(
            err.marker,
            "PackageInstance monitoring/crd-ref-vm-scrapeconfigs-monitoring-coreos-com"
        );
        let message = err.to_string();
        assert!(message.contains(keys::CRD_SERVED_VERSIONS), "{message}");
        assert!(message.contains("ScrapeConfig"), "{message}");
    }
}

#[test]
fn crd_import_that_is_not_a_crd_ref_has_no_served_versions() {
    // `kix.mkImport { kind = "CustomResourceDefinition"; }` writes no
    // `crd-kind`, so the deploy waits for the CRD without a version check.
    let manifest = json!({
        "kind": "PackageInstance",
        "metadata": {
            "name": "external-crds",
            "namespace": "monitoring",
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_KIND: "CustomResourceDefinition",
                keys::IMPORT_API_VERSION: "apiextensions.k8s.io/v1",
                keys::IMPORT_NAME: "scrapeconfigs.monitoring.coreos.com",
            }
        }
    });
    let target = import_target_from_manifest(&manifest).unwrap().unwrap();
    assert!(target.served_versions.is_empty());
    assert!(target.namespace.is_none());
}

#[test]
fn non_crd_import_has_no_served_versions() {
    let manifest = json!({
        "kind": "PackageInstance",
        "metadata": {
            "name": "secret-ref-myapp-bootstrap",
            "namespace": "myapp",
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_KIND: "Secret",
                keys::IMPORT_API_VERSION: "v1",
                keys::IMPORT_NAME: "bootstrap",
                keys::CRD_VERSION: "v1",
            }
        }
    });
    let target = import_target_from_manifest(&manifest).unwrap().unwrap();
    assert!(target.served_versions.is_empty());
}

#[test]
fn crd_served_version_check() {
    let crd = json!({
        "spec": {
            "versions": [
                { "name": "v1", "served": true, "storage": true },
                { "name": "v1beta1", "served": false, "storage": false },
            ]
        }
    });
    let wanted = |vs: &[&str]| vs.iter().map(|v| v.to_string()).collect::<Vec<_>>();
    // Served.
    assert!(unserved_crd_versions(&crd, &wanted(&["v1"])).is_empty());
    // Listed but not served, and absent.
    assert_eq!(
        unserved_crd_versions(&crd, &wanted(&["v1", "v1beta1", "v2"])),
        vec!["v1beta1", "v2"]
    );
    // No declared versions (an import that is not a CRD ref): nothing to check.
    assert!(unserved_crd_versions(&crd, &[]).is_empty());
    assert_eq!(served_crd_versions(&crd), vec!["v1"]);
}

#[test]
fn import_marker_non_import_mode_ignored() {
    let manifest = json!({
        "kind": "PackageInstance",
        "metadata": {
            "annotations": { keys::MODE: "normal" }
        }
    });
    assert!(import_target_from_manifest(&manifest).unwrap().is_none());
}

#[test]
fn import_marker_non_packageinstance_ignored() {
    let manifest = json!({
        "kind": "ConfigMap",
        "metadata": {
            "annotations": {
                keys::MODE: "import",
                keys::IMPORT_KIND: "Secret",
                keys::IMPORT_API_VERSION: "v1",
                keys::IMPORT_NAME: "foo",
            }
        }
    });
    assert!(import_target_from_manifest(&manifest).unwrap().is_none());
}

#[test]
fn check_secret_keys_all_present() {
    let secret = json!({
        "data": {
            "username": "YWRtaW4=",
            "password": "czNjcjN0",
        }
    });
    let missing = check_secret_keys(&secret, &["username".into(), "password".into()]);
    assert!(missing.is_empty());
}

#[test]
fn check_secret_keys_some_missing() {
    let secret = json!({
        "data": {
            "username": "YWRtaW4=",
        }
    });
    let missing = check_secret_keys(
        &secret,
        &["username".into(), "password".into(), "token".into()],
    );
    assert_eq!(missing, vec!["password", "token"]);
}

#[test]
fn check_secret_keys_no_data_field() {
    let secret = json!({});
    let missing = check_secret_keys(&secret, &["username".into()]);
    assert_eq!(missing, vec!["username"]);
}

#[test]
fn split_api_version_core() {
    assert_eq!(split_api_version("v1"), ("", "v1"));
    assert_eq!(split_api_version("apps/v1"), ("apps", "v1"));
    assert_eq!(
        split_api_version("apiextensions.k8s.io/v1"),
        ("apiextensions.k8s.io", "v1")
    );
}

#[test]
fn generic_cr_ready() {
    let obj = make_obj(json!({
        "status": {
            "conditions": [
                {"type": "Ready", "status": "True"}
            ]
        }
    }));
    assert!(check_readiness(&obj, "SomeCustomResource"));
}

#[test]
fn pod_image_pull_backoff_is_terminal() {
    let pod = json!({
        "metadata": {"name": "app-abc"},
        "status": {
            "containerStatuses": [{
                "name": "main",
                "state": {"waiting": {
                    "reason": "ImagePullBackOff",
                    "message": "Back-off pulling image registry/foo:v3"
                }},
                "restartCount": 0
            }]
        }
    });
    let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
    assert_eq!(reason, TerminalReason::ImagePull);
    assert!(msg.contains("app-abc/main"));
    assert!(msg.contains("ImagePullBackOff"));
}

#[test]
fn pod_err_image_pull_is_terminal() {
    let pod = json!({
        "metadata": {"name": "p"},
        "status": {
            "containerStatuses": [{
                "name": "c",
                "state": {"waiting": {"reason": "ErrImagePull", "message": "not found"}},
                "restartCount": 0
            }]
        }
    });
    assert_eq!(
        classify_pod_terminal(&pod).map(|(r, _)| r),
        Some(TerminalReason::ImagePull)
    );
}

#[test]
fn pod_create_container_config_error_is_terminal() {
    let pod = json!({
        "metadata": {"name": "p"},
        "status": {
            "containerStatuses": [{
                "name": "c",
                "state": {"waiting": {
                    "reason": "CreateContainerConfigError",
                    "message": "secret 'creds' not found"
                }},
                "restartCount": 0
            }]
        }
    });
    let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
    assert_eq!(reason, TerminalReason::ContainerConfig);
    assert!(msg.contains("creds"));
}

#[test]
fn pod_crashloop_below_threshold_not_terminal() {
    let pod = json!({
        "metadata": {"name": "p"},
        "status": {
            "containerStatuses": [{
                "name": "c",
                "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                "restartCount": 1
            }]
        }
    });
    assert!(classify_pod_terminal(&pod).is_none());
}

#[test]
fn pod_crashloop_at_threshold_is_terminal() {
    let pod = json!({
        "metadata": {"name": "p"},
        "status": {
            "containerStatuses": [{
                "name": "c",
                "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                "restartCount": 3,
                "lastState": {
                    "terminated": {"reason": "Error", "exitCode": 1}
                }
            }]
        }
    });
    let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
    assert_eq!(reason, TerminalReason::CrashLoop);
    assert!(msg.contains("restarts"));
    assert!(msg.contains("Error"));
}

#[test]
fn pod_terminated_error_with_restarts_is_terminal() {
    // Job pods between restart attempts show state=terminated rather than
    // waiting/CrashLoopBackOff. This must still be caught as terminal.
    let pod = json!({
        "metadata": {"name": "job-pod-abc"},
        "status": {
            "containerStatuses": [{
                "name": "create",
                "state": {"terminated": {"reason": "Error", "exitCode": 1, "finishedAt": "2026-01-01T00:00:00Z"}},
                "lastState": {"terminated": {"reason": "Error", "exitCode": 1}},
                "restartCount": 4
            }]
        }
    });
    let (reason, msg) = classify_pod_terminal(&pod).expect("terminal");
    assert_eq!(reason, TerminalReason::CrashLoop);
    assert!(msg.contains("terminated with Error"));
    assert!(msg.contains("exit=1"));
    assert!(msg.contains("4 restarts"));
}

#[test]
fn pod_terminated_error_below_threshold_not_terminal() {
    let pod = json!({
        "metadata": {"name": "job-pod-abc"},
        "status": {
            "containerStatuses": [{
                "name": "create",
                "state": {"terminated": {"reason": "Error", "exitCode": 1}},
                "restartCount": 1
            }]
        }
    });
    assert!(classify_pod_terminal(&pod).is_none());
}

#[test]
fn pod_terminated_success_not_terminal() {
    // Exit code 0 is a successful termination (normal for Jobs), not a failure.
    let pod = json!({
        "metadata": {"name": "job-pod-abc"},
        "status": {
            "containerStatuses": [{
                "name": "create",
                "state": {"terminated": {"reason": "Completed", "exitCode": 0}},
                "restartCount": 0
            }]
        }
    });
    assert!(classify_pod_terminal(&pod).is_none());
}

#[test]
fn pod_init_container_failures_detected() {
    let pod = json!({
        "metadata": {"name": "p"},
        "status": {
            "initContainerStatuses": [{
                "name": "init",
                "state": {"waiting": {
                    "reason": "ImagePullBackOff",
                    "message": "x"
                }},
                "restartCount": 0
            }],
            "containerStatuses": []
        }
    });
    assert_eq!(
        classify_pod_terminal(&pod).map(|(r, _)| r),
        Some(TerminalReason::ImagePull)
    );
}

#[test]
fn pod_healthy_not_terminal() {
    let pod = json!({
        "metadata": {"name": "p"},
        "status": {
            "containerStatuses": [{
                "name": "c",
                "state": {"running": {"startedAt": "2024-01-01T00:00:00Z"}},
                "restartCount": 0
            }]
        }
    });
    assert!(classify_pod_terminal(&pod).is_none());
}

#[test]
fn deployment_progress_deadline_is_terminal() {
    let obj = json!({
        "status": {
            "conditions": [
                {"type": "Available", "status": "False"},
                {
                    "type": "Progressing",
                    "status": "False",
                    "reason": "ProgressDeadlineExceeded",
                    "message": "ReplicaSet \"app-xyz\" has timed out progressing."
                }
            ]
        }
    });
    let (reason, msg) = classify_workload_terminal(&obj, "Deployment").expect("terminal");
    assert_eq!(reason, TerminalReason::ProgressDeadline);
    assert!(msg.contains("timed out"));
}

#[test]
fn deployment_progressing_true_not_terminal() {
    let obj = json!({
        "status": {
            "conditions": [
                {"type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"}
            ]
        }
    });
    assert!(classify_workload_terminal(&obj, "Deployment").is_none());
}

#[test]
fn job_backoff_exceeded_is_terminal() {
    let obj = json!({
        "spec": {"backoffLimit": 2},
        "status": {"failed": 3}
    });
    let (reason, _) = classify_workload_terminal(&obj, "Job").expect("terminal");
    assert_eq!(reason, TerminalReason::JobBackoffExceeded);
}

#[test]
fn job_within_backoff_not_terminal() {
    let obj = json!({
        "spec": {"backoffLimit": 6},
        "status": {"failed": 2}
    });
    assert!(classify_workload_terminal(&obj, "Job").is_none());
}

#[test]
fn job_failed_condition_is_terminal() {
    let obj = json!({
        "spec": {"backoffLimit": 6},
        "status": {
            "failed": 1,
            "conditions": [
                {"type": "Failed", "status": "True", "reason": "DeadlineExceeded", "message": "Job was active longer than specified deadline"}
            ]
        }
    });
    let (reason, msg) = classify_workload_terminal(&obj, "Job").expect("terminal");
    assert_eq!(reason, TerminalReason::JobBackoffExceeded);
    assert!(msg.contains("DeadlineExceeded"));
}

#[test]
fn job_with_succeeded_and_failed_condition_is_terminal() {
    // A Job can have succeeded >= 1 (some pods completed) while also
    // having a Failed condition. The terminal check must win over the
    // readiness check so we don't report Ready for a broken Job.
    let obj = json!({
        "spec": {"backoffLimit": 2},
        "status": {
            "succeeded": 1,
            "failed": 3,
            "conditions": [
                {"type": "Failed", "status": "True", "reason": "BackoffLimitExceeded", "message": "Job has reached the specified backoff limit"}
            ]
        }
    });
    // The job IS "ready" by the succeeded check...
    assert!(check_job_ready(&obj));
    // ...but it IS terminal due to the failed condition.
    let (reason, _) = classify_workload_terminal(&obj, "Job").expect("terminal");
    assert_eq!(reason, TerminalReason::JobBackoffExceeded);
}

#[test]
fn workload_label_selector_builds_sorted() {
    let obj = json!({
        "spec": {
            "selector": {
                "matchLabels": {
                    "app": "foo",
                    "release": "v1"
                }
            }
        }
    });
    assert_eq!(
        workload_label_selector(&obj).as_deref(),
        Some("app=foo,release=v1")
    );
}

#[test]
fn workload_label_selector_missing_returns_none() {
    let obj = json!({"spec": {}});
    assert!(workload_label_selector(&obj).is_none());
}

fn pod_with_message(container: &str, message: &str) -> Value {
    json!({
        "status": {
            "containerStatuses": [{
                "name": container,
                "state": { "terminated": { "exitCode": 1, "message": message } }
            }]
        }
    })
}

#[test]
fn termination_output_carries_the_probe_lines() {
    let pods = vec![pod_with_message(
        "probe",
        "FAIL  1 of 2 agent replicas scraped and up\nFAIL  targets down: x\n2 check(s) still failing after 90s\n\n",
    )];
    assert_eq!(
        termination_output(&pods),
        vec![
            "FAIL  1 of 2 agent replicas scraped and up",
            "FAIL  targets down: x",
            "2 check(s) still failing after 90s",
        ]
    );
}

#[test]
fn termination_output_reads_last_state_and_prefixes_when_several() {
    let pods = vec![json!({
        "status": {
            "containerStatuses": [
                { "name": "a", "state": { "waiting": {} },
                  "lastState": { "terminated": { "message": "from a" } } },
                { "name": "b", "state": { "terminated": { "message": "from b" } } },
                { "name": "quiet", "state": { "terminated": { "message": "" } } }
            ]
        }
    })];
    assert_eq!(termination_output(&pods), vec!["a: from a", "b: from b"]);
}

#[test]
fn termination_output_reads_the_newest_pod_only() {
    let mut first = pod_with_message("probe", "attempt 1");
    first["status"]["startTime"] = json!("2026-09-08T10:00:00Z");
    let mut second = pod_with_message("probe", "attempt 2");
    second["status"]["startTime"] = json!("2026-09-08T10:05:00Z");
    assert_eq!(
        termination_output(&[second.clone(), first.clone()]),
        vec!["attempt 2"]
    );
    assert_eq!(termination_output(&[first, second]), vec!["attempt 2"]);
}

#[test]
fn termination_output_keeps_the_tail() {
    let message: String = (1..=25).map(|i| format!("line {i}\n")).collect();
    let out = termination_output(&[pod_with_message("probe", &message)]);
    assert_eq!(out.len(), TERMINATION_OUTPUT_LINES + 1);
    assert_eq!(out[0], "... 5 earlier lines, see kubectl logs");
    assert_eq!(out[1], "line 6");
    assert_eq!(out[TERMINATION_OUTPUT_LINES], "line 25");
}

#[test]
fn termination_output_is_empty_without_a_message() {
    let pods = vec![
        json!({ "status": { "containerStatuses": [{ "name": "probe", "state": { "terminated": { "exitCode": 1 } } }] } }),
    ];
    assert!(termination_output(&pods).is_empty());
    assert!(termination_output(&[]).is_empty());
}

#[test]
fn fingerprint_changes_when_replicas_progress() {
    let before = make_obj(json!({
        "metadata": {"name": "app", "generation": 1},
        "spec": {"replicas": 3},
        "status": {"observedGeneration": 1, "readyReplicas": 0, "updatedReplicas": 1}
    }));
    let after = make_obj(json!({
        "metadata": {"name": "app", "generation": 1},
        "spec": {"replicas": 3},
        "status": {"observedGeneration": 1, "readyReplicas": 1, "updatedReplicas": 2}
    }));
    let fp1 = progress_fingerprint(&before, "Deployment", &[]);
    let fp2 = progress_fingerprint(&after, "Deployment", &[]);
    assert_ne!(
        fp1, fp2,
        "ready/updated count changes must register as progress"
    );
}

#[test]
fn fingerprint_stable_when_nothing_moves() {
    let obj = make_obj(json!({
        "metadata": {"name": "app", "generation": 1},
        "spec": {"replicas": 3},
        "status": {"observedGeneration": 1, "readyReplicas": 0, "updatedReplicas": 0}
    }));
    let fp1 = progress_fingerprint(&obj, "Deployment", &[]);
    let fp2 = progress_fingerprint(&obj, "Deployment", &[]);
    assert_eq!(fp1, fp2);
}

#[test]
fn fingerprint_changes_on_pod_phase_transition() {
    let obj = make_obj(json!({
        "metadata": {"name": "app", "generation": 1},
        "spec": {"replicas": 1},
        "status": {"observedGeneration": 1, "readyReplicas": 0, "updatedReplicas": 1}
    }));
    let pods_pending = vec![json!({
        "status": {
            "phase": "Pending",
            "containerStatuses": [{
                "state": {"waiting": {"reason": "ContainerCreating"}},
                "restartCount": 0
            }]
        }
    })];
    let pods_running = vec![json!({
        "status": {
            "phase": "Running",
            "containerStatuses": [{
                "state": {"running": {}},
                "restartCount": 0
            }]
        }
    })];
    let fp1 = progress_fingerprint(&obj, "Deployment", &pods_pending);
    let fp2 = progress_fingerprint(&obj, "Deployment", &pods_running);
    assert_ne!(
        fp1, fp2,
        "Pending→Running pod transition must register as progress"
    );
}

#[test]
fn fingerprint_changes_on_restart_count_bump() {
    let obj = make_obj(json!({
        "spec": {"replicas": 1},
        "status": {"observedGeneration": 1}
    }));
    let pods_low = vec![json!({
        "status": {
            "phase": "Running",
            "containerStatuses": [{"state": {"running": {}}, "restartCount": 1}]
        }
    })];
    let pods_high = vec![json!({
        "status": {
            "phase": "Running",
            "containerStatuses": [{"state": {"running": {}}, "restartCount": 2}]
        }
    })];
    let fp1 = progress_fingerprint(&obj, "Deployment", &pods_low);
    let fp2 = progress_fingerprint(&obj, "Deployment", &pods_high);
    assert_ne!(fp1, fp2, "restart count bump should register as progress");
}
