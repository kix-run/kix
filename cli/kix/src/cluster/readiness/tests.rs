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
    match declared_readiness(&obj).expect("should parse").ready {
        ReadyRule::Path { path, equals } => {
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
    match declared_readiness(&make_annotated_obj(VM_CHILD_RULE, json!({})))
        .expect("should parse")
        .ready
    {
        ReadyRule::PathNot { path, not_equals } => {
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
    match declared_readiness(&obj).expect("should parse").ready {
        ReadyRule::Condition {
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

// ---- Declared failure states ----

const CILIUM_RULE: &str = r#"{"condition":{"status":"True","type":"Valid"},"failed":[{"condition":{"status":"False","type":"Valid"}}]}"#;

fn valid_false(extra: Value) -> Value {
    let mut c = json!({
        "type": "Valid",
        "status": "False",
        "message": "rule must have at least one of Ingress, IngressDeny, Egress, EgressDeny"
    });
    if let (Some(c), Some(extra)) = (c.as_object_mut(), extra.as_object()) {
        c.extend(extra.clone());
    }
    json!({"status": {"conditions": [c]}})
}

const CILIUM_MESSAGE: &str = "its controller rejected it with Valid=False: rule must have at least one of Ingress, IngressDeny, Egress, EgressDeny. This will not fix itself, so Kix stopped waiting. Change this CiliumNetworkPolicy in the package or cluster definition that creates it, then deploy again.";

#[test]
fn declared_failed_rules_parse_beside_the_ready_rule() {
    let parsed = declared_readiness(&make_annotated_obj(CILIUM_RULE, json!({}))).expect("parses");
    assert!(matches!(parsed.ready, ReadyRule::Condition { .. }));
    assert_eq!(
        parsed.failed,
        vec![FailedRule::Condition {
            condition_type: "Valid".into(),
            status: "False".into(),
            reason: None,
        }]
    );

    let mixed = r#"{"equals":"Completed","failed":[{"equals":"Failed","path":"/status/phase"},{"condition":{"reason":"Invalid","status":"False","type":"Accepted"}}],"path":"/status/phase"}"#;
    let parsed = declared_readiness(&make_annotated_obj(mixed, json!({}))).expect("parses");
    assert!(matches!(parsed.ready, ReadyRule::Path { .. }));
    assert_eq!(
        parsed.failed,
        vec![
            FailedRule::Path {
                path: "/status/phase".into(),
                equals: "Failed".into(),
                rejected: false,
                hint: None,
                message: Vec::new(),
            },
            FailedRule::Condition {
                condition_type: "Accepted".into(),
                status: "False".into(),
                reason: Some("Invalid".into()),
            },
        ]
    );
}

// An annotation written before `failed` existed parses as before and
// declares no failure state, so the deploy waits as it did.
#[test]
fn declared_readiness_without_failed_key_parses_as_before() {
    let parsed =
        declared_readiness(&make_annotated_obj(CONDITION_RULE, json!({}))).expect("parses");
    assert!(parsed.failed.is_empty());
    let rejected = make_annotated_obj(
        CONDITION_RULE,
        json!({"status": {"conditions": [{"type": "Bootstrapped", "status": "False"}]}}),
    );
    assert!(declared_failure(&rejected, "SGCluster", None).is_none());
    assert!(!check_readiness(&rejected, "SGCluster"));

    let parsed = declared_readiness(&make_annotated_obj(VM_RULE, json!({}))).expect("parses");
    assert!(parsed.failed.is_empty());
}

// A `failed` entry this CLI cannot read is dropped on its own; the ready
// rule and the other entries still apply.
#[test]
fn declared_failed_rules_drop_malformed_entries() {
    let rule = r#"{"condition":{"status":"True","type":"Valid"},"failed":[{"condition":{"type":"Valid"}},"nope",{"path":"/status/x"},{"condition":{"status":"False","type":"Valid"}}]}"#;
    let parsed = declared_readiness(&make_annotated_obj(rule, json!({}))).expect("parses");
    assert_eq!(parsed.failed.len(), 1);

    let not_a_list = r#"{"condition":{"status":"True","type":"Valid"},"failed":{"condition":{"status":"False","type":"Valid"}}}"#;
    let parsed = declared_readiness(&make_annotated_obj(not_a_list, json!({}))).expect("parses");
    assert!(parsed.failed.is_empty());
    let ready = make_annotated_obj(
        not_a_list,
        json!({"status": {"conditions": [{"type": "Valid", "status": "True"}]}}),
    );
    assert!(check_readiness(&ready, "CiliumNetworkPolicy"));
}

// A matching condition whose observedGeneration has reached the object's
// generation is final at once, with the controller's reason and message.
#[test]
fn declared_failure_with_current_generation_fails_at_once() {
    let obj = with_generation(
        make_annotated_obj(CILIUM_RULE, valid_false(json!({"observedGeneration": 2}))),
        2,
    );
    let failure = declared_failure(&obj, "CiliumNetworkPolicy", None).expect("matches");
    assert!(failure.confirmed);
    assert_eq!(failure.message, CILIUM_MESSAGE);
    assert!(!check_readiness(&obj, "CiliumNetworkPolicy"));

    let mut watch = FailureWatch::default();
    assert_eq!(
        watch.observe(Some(failure), Instant::now()),
        Some(CILIUM_MESSAGE.to_string())
    );

    // status.observedGeneration stands in for a condition without its own.
    let via_status = with_generation(
        make_annotated_obj(
            CILIUM_RULE,
            json!({"status": {"observedGeneration": 2, "conditions": [{"type": "Valid", "status": "False"}]}}),
        ),
        2,
    );
    let failure = declared_failure(&via_status, "CiliumNetworkPolicy", None).expect("matches");
    assert!(failure.confirmed);
    assert_eq!(
        failure.message,
        "its controller rejected it with Valid=False. This will not fix itself, so Kix stopped waiting. Change this CiliumNetworkPolicy in the package or cluster definition that creates it, then deploy again."
    );

    // The ready state and an absent condition match no failure.
    let accepted = make_annotated_obj(
        CILIUM_RULE,
        json!({"status": {"conditions": [{"type": "Valid", "status": "True"}]}}),
    );
    assert!(declared_failure(&accepted, "CiliumNetworkPolicy", None).is_none());
    assert!(
        declared_failure(
            &make_annotated_obj(CILIUM_RULE, json!({})),
            "CiliumNetworkPolicy",
            None
        )
        .is_none()
    );
}

// A failure the controller reported for an older generation is its verdict
// on the previous spec, so the wait continues.
#[test]
fn declared_failure_with_stale_generation_keeps_polling() {
    let stale = with_generation(
        make_annotated_obj(CILIUM_RULE, valid_false(json!({"observedGeneration": 1}))),
        2,
    );
    assert!(declared_failure(&stale, "CiliumNetworkPolicy", None).is_none());

    let stale_status = with_generation(
        make_annotated_obj(
            CILIUM_RULE,
            json!({"status": {"observedGeneration": 1, "conditions": [{"type": "Valid", "status": "False"}]}}),
        ),
        2,
    );
    assert!(declared_failure(&stale_status, "CiliumNetworkPolicy", None).is_none());

    let mut watch = FailureWatch::default();
    assert_eq!(watch.observe(None, Instant::now()), None);
}

// Without any observedGeneration the match is reported unconfirmed, and the
// watch ends the wait only after the same failure has held for the grace
// period; a poll that no longer reports it starts the grace over.
#[test]
fn declared_failure_without_generation_fails_after_the_grace() {
    let obj = make_annotated_obj(CILIUM_RULE, valid_false(json!({})));
    let failure = declared_failure(&obj, "CiliumNetworkPolicy", None).expect("matches");
    assert!(!failure.confirmed);
    assert_eq!(failure.message, CILIUM_MESSAGE);

    let t0 = Instant::now();
    let step = Duration::from_secs(1);
    let mut watch = FailureWatch::default();
    assert_eq!(watch.observe(Some(failure.clone()), t0), None);
    assert_eq!(
        watch.observe(Some(failure.clone()), t0 + DECLARED_FAILURE_GRACE - step),
        None
    );
    assert_eq!(
        watch.observe(Some(failure.clone()), t0 + DECLARED_FAILURE_GRACE),
        Some(CILIUM_MESSAGE.to_string())
    );

    let mut watch = FailureWatch::default();
    assert_eq!(watch.observe(Some(failure.clone()), t0), None);
    assert_eq!(watch.observe(None, t0 + step), None);
    assert_eq!(
        watch.observe(Some(failure.clone()), t0 + DECLARED_FAILURE_GRACE),
        None
    );
    assert_eq!(
        watch.observe(Some(failure), t0 + 2 * DECLARED_FAILURE_GRACE),
        Some(CILIUM_MESSAGE.to_string())
    );
}

// A declared reason narrows the match; without one any reason matches.
#[test]
fn declared_failure_reason_must_match_when_declared() {
    let rule = r#"{"condition":{"status":"True","type":"Accepted"},"failed":[{"condition":{"reason":"Invalid","status":"False","type":"Accepted"}}]}"#;
    let route = |reason: &str| {
        with_generation(
            make_annotated_obj(
                rule,
                json!({"status": {"conditions": [
                    {"type": "Accepted", "status": "False", "reason": reason, "message": "waiting", "observedGeneration": 1}
                ]}}),
            ),
            1,
        )
    };
    assert!(declared_failure(&route("Pending"), "HTTPRoute", None).is_none());
    let failure = declared_failure(&route("Invalid"), "HTTPRoute", None).expect("matches");
    assert_eq!(
        failure.message,
        "its controller rejected it with Accepted=False (Invalid): waiting. This will not fix itself, so Kix stopped waiting. Change this HTTPRoute in the package or cluster definition that creates it, then deploy again."
    );
}

// The path form compares the scalar at the path by its text. A plain entry
// is a runtime outcome: the message names the field, quotes the declared
// `message` pointers, and ends with the package's hint or a generic step. An
// entry with `rejected` uses the spec-rejection wording.
#[test]
fn declared_failure_path_form() {
    let rule = r#"{"equals":"Completed","failed":[
        {"equals":"FailedValidation","message":["/status/validationErrors"],"path":"/status/phase","rejected":true},
        {"equals":"Failed","hint":"Velero does not run a failed backup again. Create it again under a new name.","message":["/status/failureReason"],"path":"/status/phase"},
        {"equals":"PartiallyFailed","path":"/status/phase"}
    ],"path":"/status/phase"}"#;
    let backup = |status: Value| make_annotated_obj(rule, json!({"status": status}));
    assert!(declared_failure(&backup(json!({"phase": "InProgress"})), "Backup", None).is_none());
    assert!(declared_failure(&backup(json!({"phase": "Completed"})), "Backup", None).is_none());

    let parsed = declared_readiness(&backup(json!({}))).expect("parses");
    assert_eq!(
        parsed.failed[0],
        FailedRule::Path {
            path: "/status/phase".into(),
            equals: "FailedValidation".into(),
            rejected: true,
            hint: None,
            message: vec!["/status/validationErrors".into()],
        }
    );

    let no_hint = declared_failure(&backup(json!({"phase": "PartiallyFailed"})), "Backup", None)
        .expect("matches");
    assert!(!no_hint.confirmed);
    assert_eq!(
        no_hint.message,
        "its controller set status.phase=PartiallyFailed, a state it does not leave on its own, so Kix stopped waiting. Find the cause in the object's status, fix it, then deploy again."
    );

    let with_hint = with_generation(
        backup(
            json!({"phase": "Failed", "failureReason": "bucket not found.", "observedGeneration": 3}),
        ),
        3,
    );
    let failure = declared_failure(&with_hint, "Backup", None).expect("matches");
    assert!(failure.confirmed);
    assert_eq!(
        failure.message,
        "its controller set status.phase=Failed (bucket not found), a state it does not leave on its own, so Kix stopped waiting. Velero does not run a failed backup again. Create it again under a new name."
    );

    // A list value is joined; an absent pointer quotes nothing.
    let rejected = declared_failure(
        &backup(
            json!({"phase": "FailedValidation", "validationErrors": ["no location", "bad ttl"]}),
        ),
        "Backup",
        None,
    )
    .expect("matches");
    assert_eq!(
        rejected.message,
        "its controller rejected it with status.phase=FailedValidation: no location; bad ttl. This will not fix itself, so Kix stopped waiting. Change this Backup in the package or cluster definition that creates it, then deploy again."
    );
    let rejected = declared_failure(
        &backup(json!({"phase": "FailedValidation"})),
        "Backup",
        None,
    )
    .expect("matches");
    assert!(rejected.message.starts_with(
        "its controller rejected it with status.phase=FailedValidation. This will not fix itself"
    ));

    let stale = with_generation(
        backup(json!({"phase": "Failed", "observedGeneration": 2})),
        3,
    );
    assert!(declared_failure(&stale, "Backup", None).is_none());

    // A `message` that is not a pointer or a list of them drops the entry.
    let bad = r#"{"equals":"Completed","failed":[{"equals":"Failed","message":3,"path":"/status/phase"}],"path":"/status/phase"}"#;
    assert!(
        declared_readiness(&make_annotated_obj(bad, json!({})))
            .expect("parses")
            .failed
            .is_empty()
    );

    // A boolean compares by its JSON text, as the ready rule does.
    let flag = r#"{"equals":"true","failed":[{"equals":"true","path":"/status/rejected"}],"path":"/status/applied"}"#;
    let rejected = make_annotated_obj(flag, json!({"status": {"rejected": true}}));
    assert!(declared_failure(&rejected, "Database", None).is_some());
    let failure = DeclaredFailure {
        message: "x".into(),
        confirmed: true,
    };
    assert_eq!(
        FailureWatch::default().observe(Some(failure), Instant::now()),
        Some("x".into())
    );
}

// A condition that carries no observedGeneration but a lastTransitionTime
// is final when it changed after this deploy applied the object, or when
// the deploy left the object unchanged; one that changed before the apply
// is the verdict on the previous spec and is not reported.
#[test]
fn declared_failure_trusts_a_transition_after_the_apply() {
    use chrono::TimeZone;
    let at =
        |t: &str| make_annotated_obj(CILIUM_RULE, valid_false(json!({"lastTransitionTime": t})));
    let applied =
        Utc.with_ymd_and_hms(2026, 11, 6, 12, 0, 0).unwrap() + chrono::Duration::milliseconds(700);
    let kind = "CiliumNetworkPolicy";

    assert!(declared_failure(&at("2026-11-06T11:58:00Z"), kind, Some(applied)).is_none());

    // The field has second precision, so the apply's own second counts.
    let same_second =
        declared_failure(&at("2026-11-06T12:00:00Z"), kind, Some(applied)).expect("matches");
    assert!(same_second.confirmed);
    let later =
        declared_failure(&at("2026-11-06T12:00:03Z"), kind, Some(applied)).expect("matches");
    assert!(later.confirmed);
    assert_eq!(later.message, CILIUM_MESSAGE);

    let unchanged = declared_failure(&at("2026-11-06T11:58:00Z"), kind, None).expect("matches");
    assert!(unchanged.confirmed);

    // A time Kix cannot read is treated as absent: the grace applies.
    let unreadable = declared_failure(&at("yesterday"), kind, Some(applied)).expect("matches");
    assert!(!unreadable.confirmed);

    // A current observedGeneration settles it regardless of the time.
    let by_generation = with_generation(
        make_annotated_obj(
            CILIUM_RULE,
            valid_false(
                json!({"lastTransitionTime": "2026-11-06T11:58:00Z", "observedGeneration": 2}),
            ),
        ),
        2,
    );
    assert!(
        declared_failure(&by_generation, kind, Some(applied))
            .expect("matches")
            .confirmed
    );
}
