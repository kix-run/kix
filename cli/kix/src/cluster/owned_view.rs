//! A live object as a comparison with a build sees it: the fields Kix's
//! server-side apply owns, with Secret values redacted.

use std::collections::HashMap;

use crate::manifest::keys;
use crate::manifest::types::{ResourceId, to_manifest_value};
use kube::api::DynamicObject;

/// Strip server-side fields from a DynamicObject for diffing.
///
/// Removes `uid`, `resourceVersion`, `creationTimestamp`, `generation`,
/// `selfLink`, `managedFields`, `status`, and the `last-applied-configuration`
/// annotation.
pub(crate) fn normalize_for_diff(obj: &mut DynamicObject) {
    obj.metadata.uid = None;
    obj.metadata.resource_version = None;
    obj.metadata.creation_timestamp = None;
    obj.metadata.generation = None;
    obj.metadata.managed_fields = None;

    if let Some(data) = obj.data.as_object_mut() {
        if let Some(meta) = data.get_mut("metadata").and_then(|m| m.as_object_mut()) {
            meta.remove("selfLink");
            meta.remove("uid");
            meta.remove("resourceVersion");
            meta.remove("creationTimestamp");
            meta.remove("generation");
            meta.remove("managedFields");

            if let Some(annotations) = meta.get_mut("annotations").and_then(|a| a.as_object_mut()) {
                annotations.remove("kubectl.kubernetes.io/last-applied-configuration");
                if annotations.is_empty() {
                    meta.remove("annotations");
                }
            }
        }

        data.remove("status");
    }
}

/// Project `obj` onto the fieldset owned by Kix's server-side apply, restoring
/// `apiVersion`, `kind`, `metadata.name`, and `metadata.namespace`, and
/// redacting `Secret` values.
///
/// `kix diff` and `kix snapshot save` compare this view against a build. Server
/// defaults (such as deployment strategy, probe thresholds, and scheduler name)
/// are unowned or owned by a controller, so they are excluded. Kix's
/// bookkeeping annotations (`kix.run/activations` and `kix.run/applied-hash`)
/// are written through a separate `Update` entry and are also excluded.
///
/// Objects without a Kix `Apply` entry fall back to the full object with server
/// metadata stripped.
///
/// Every `data` key on a `Secret` is replaced with [`HIDDEN_SECRET_VALUE`] (see
/// [`redact_secret`]). Values Kix applied through `stringData` are absent
/// because the server stores them only in `data`.
/// [`kix_owned_manifests_against`] compares both against a build.
pub(crate) fn kix_owned_view(obj: &DynamicObject) -> serde_json::Value {
    let mut view = unredacted_view(obj);
    redact_secret(&mut view, obj, None);
    view
}

/// Build [`kix_owned_view`] before running [`redact_secret`]. Because `Secret`
/// values remain unredacted, this value must not leave the module.
fn unredacted_view(obj: &DynamicObject) -> serde_json::Value {
    let Some(mut view) = super::fieldsv1::kix_owned_projection(obj) else {
        let mut fallback = obj.clone();
        normalize_for_diff(&mut fallback);
        return to_manifest_value(&fallback);
    };
    if let Some(map) = view.as_object_mut() {
        for key in ["apiVersion", "kind"] {
            if let Some(v) = obj.data.get(key) {
                map.insert(key.to_string(), v.clone());
            }
        }
        let meta = map
            .entry("metadata")
            .or_insert_with(|| serde_json::json!({}));
        if let Some(meta) = meta.as_object_mut() {
            if let Some(name) = &obj.metadata.name {
                meta.insert("name".into(), serde_json::Value::String(name.clone()));
            }
            if let Some(ns) = &obj.metadata.namespace {
                meta.insert("namespace".into(), serde_json::Value::String(ns.clone()));
            }
        }
    }
    view
}

/// Placeholder for a live `Secret` value that differs from the build, so a diff
/// shows the key as changed without printing the live value.
pub const HIDDEN_SECRET_VALUE: &str = "(live value differs from the build, not shown)";

/// Replace live `Secret` values in `view` with build values when equal, or
/// [`HIDDEN_SECRET_VALUE`] when different.
///
/// Each key under `view`'s `data` is replaced with `built`'s value when the
/// decoded live bytes match `built` (under `data` or `stringData` according to
/// where `built` declares the key). Every other key, and every key when `built`
/// is `None`, becomes [`HIDDEN_SECRET_VALUE`].
///
/// Because the API server merges `stringData` into `data` and never stores
/// `stringData`, the projection of a `Secret` that Kix applied with
/// `stringData` contains neither field. For each `stringData` key declared in
/// `built` and listed in Kix's fieldset, the decoded live `data` value is
/// compared and restored under `stringData` (or omitted if missing or not valid
/// UTF-8). A SOPS `Secret` manifest has no `stringData` in the build, so its
/// keys are not restored.
fn redact_secret(
    view: &mut serde_json::Value,
    obj: &DynamicObject,
    built: Option<&serde_json::Value>,
) {
    use serde_json::{Map, Value};

    if !crate::manifest::types::is_secret(&obj.data) {
        return;
    }
    let hidden = || Value::String(HIDDEN_SECRET_VALUE.into());
    let built_data = built.and_then(|b| b.get("data")).and_then(Value::as_object);
    let built_string_data = built
        .and_then(|b| b.get("stringData"))
        .and_then(Value::as_object);
    let live_data = obj.data.get("data").and_then(Value::as_object);
    let live_text = |key: &str| -> Option<String> {
        let bytes = decode_base64(live_data?.get(key)?.as_str()?)?;
        String::from_utf8(bytes).ok()
    };

    let mut string_data: Map<String, Value> = Map::new();
    let Some(map) = view.as_object_mut() else {
        return;
    };
    // The server never returns `stringData`, so redact anything present there.
    if let Some(Value::Object(found)) = map.remove("stringData") {
        string_data.extend(found.into_iter().map(|(k, _)| (k, hidden())));
    }
    if let Some(Value::Object(data)) = map.get_mut("data") {
        let keys: Vec<String> = data.keys().cloned().collect();
        for key in keys {
            let live_bytes = live_data
                .and_then(|d| d.get(&key))
                .and_then(Value::as_str)
                .and_then(decode_base64);
            let from_data = built_data.and_then(|d| d.get(&key)).filter(|b| {
                let built_bytes = b.as_str().and_then(decode_base64);
                built_bytes.is_some() && built_bytes == live_bytes
            });
            if let Some(value) = from_data {
                data.insert(key, value.clone());
                continue;
            }
            let from_string_data = built_string_data
                .and_then(|d| d.get(&key))
                .filter(|b| b.as_str().is_some() && b.as_str() == live_text(&key).as_deref());
            if let Some(value) = from_string_data {
                data.remove(&key);
                string_data.insert(key, value.clone());
            } else {
                data.insert(key, hidden());
            }
        }
        if data.is_empty() {
            map.remove("data");
        }
    }

    let owned = super::fieldsv1::kix_fieldset(obj);
    let owned = owned
        .as_ref()
        .and_then(|f| f.get("f:stringData"))
        .and_then(Value::as_object);
    if let (Some(declared), Some(owned)) = (built_string_data, owned) {
        for (key, built_value) in declared {
            if !owned.contains_key(&format!("f:{key}")) {
                continue;
            }
            let Some(text) = live_text(key) else { continue };
            let value = if built_value.as_str() == Some(text.as_str()) {
                built_value.clone()
            } else {
                hidden()
            };
            string_data.insert(key.clone(), value);
        }
    }
    if !string_data.is_empty() {
        map.insert("stringData".into(), Value::Object(string_data));
    }
}

fn decode_base64(text: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(text).ok()
}

/// Project each object in `objects` with [`kix_owned_view`] and upgrade retired
/// Kix annotation domains to the current domain.
pub fn kix_owned_manifests(
    objects: impl IntoIterator<Item = DynamicObject>,
) -> Vec<serde_json::Value> {
    objects
        .into_iter()
        .map(|obj| {
            let mut manifest = kix_owned_view(&obj);
            crate::legacy_domain::upgrade_manifest(&mut manifest);
            manifest
        })
        .collect()
}

/// Build [`kix_owned_manifests`] for comparison against `built` (keyed by
/// identity hash), replacing each object the build does not change with its
/// build manifest.
///
/// The build does not change an object when the object's
/// `kix.run/identity-hash` names a manifest in `built` for the same kind,
/// namespace, and name. This is the rule `kix deploy` uses to skip an object.
/// The identity hash is the hash of the manifest file, so the build manifest
/// is what Kix applied. A value diff of the live object cannot stand in for
/// it, because the API server drops `omitempty` values, defaults custom
/// resources, and lets other field managers take fields. Whether someone has
/// edited the object since apply is answered separately by
/// [`super::drift::check_object`]. Live `kix.run/*` annotations are kept so
/// the record and activation stamps read as the cluster has them.
///
/// All other objects use their Kix-owned view after running [`redact_secret`]
/// against the matching build manifest.
pub fn kix_owned_manifests_against(
    objects: impl IntoIterator<Item = DynamicObject>,
    built: &HashMap<String, &serde_json::Value>,
) -> Vec<serde_json::Value> {
    let by_id: HashMap<ResourceId, &serde_json::Value> = built
        .values()
        .map(|m| (ResourceId::from_value(m), *m))
        .collect();
    objects
        .into_iter()
        .map(|obj| {
            let mut view = unredacted_view(&obj);
            crate::legacy_domain::upgrade_manifest(&mut view);
            if let Some(manifest) = unchanged_by_build(&obj, &view, built) {
                return manifest;
            }
            let build = by_id.get(&ResourceId::from_value(&view)).copied();
            redact_secret(&mut view, &obj, build);
            view
        })
        .collect()
}

/// Return the build manifest with `obj`'s identity hash and resource id, with
/// the live `kix.run/*` annotations in place of the build's.
fn unchanged_by_build(
    obj: &DynamicObject,
    view: &serde_json::Value,
    built: &HashMap<String, &serde_json::Value>,
) -> Option<serde_json::Value> {
    let hash = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))?;
    let manifest = *built.get(hash)?;
    if ResourceId::from_value(manifest) != ResourceId::from_value(view) {
        return None;
    }
    let mut out = manifest.clone();
    let live_stamps: Vec<(String, serde_json::Value)> = view
        .pointer("/metadata/annotations")
        .and_then(serde_json::Value::as_object)
        .into_iter()
        .flatten()
        .filter(|(k, _)| keys::is_kix_key(k))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    crate::manifest::hash::strip_kix_annotations(&mut out);
    if !live_stamps.is_empty()
        && let Some(meta) = out.get_mut("metadata").and_then(|m| m.as_object_mut())
        && let Some(annotations) = meta
            .entry("annotations")
            .or_insert_with(|| serde_json::json!({}))
            .as_object_mut()
    {
        annotations.extend(live_stamps);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::{Value, json};
    use std::collections::BTreeMap;

    fn managed(
        manager: &str,
        operation: &str,
        subresource: Option<&str>,
        fields: serde_json::Value,
    ) -> k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
        k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
            manager: Some(manager.into()),
            operation: Some(operation.into()),
            subresource: subresource.map(str::to_string),
            fields_v1: Some(k8s_openapi::apimachinery::pkg::apis::meta::v1::FieldsV1(
                fields,
            )),
            ..Default::default()
        }
    }

    /// Verify that only Kix's `Apply` fieldset survives in the view, excluding
    /// Kix's `Update` bookkeeping patch, controller-owned fields, and unowned
    /// server defaults.
    #[test]
    fn kix_owned_view_keeps_only_the_applied_fieldset() {
        let f_identity = format!("f:{}", keys::IDENTITY_HASH);
        let f_activations = format!("f:{}", keys::ACTIVATIONS);
        let f_applied = format!("f:{}", keys::APPLIED_HASH);
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("web".into()),
                namespace: Some("app".into()),
                uid: Some("abc".into()),
                resource_version: Some("9".into()),
                labels: Some(
                    [(
                        "app.kubernetes.io/managed-by".to_string(),
                        "kix".to_string(),
                    )]
                    .into(),
                ),
                annotations: Some(
                    [
                        (keys::IDENTITY_HASH.to_string(), "h1".to_string()),
                        (keys::ACTIVATIONS.to_string(), "a1".to_string()),
                        (keys::APPLIED_HASH.to_string(), "deadbeef".to_string()),
                        (
                            "deployment.kubernetes.io/revision".to_string(),
                            "1".to_string(),
                        ),
                    ]
                    .into(),
                ),
                managed_fields: Some(vec![
                    managed(
                        "kix",
                        "Apply",
                        None,
                        json!({
                            "f:metadata": {
                                "f:annotations": {f_identity: {}},
                                "f:labels": {"f:app.kubernetes.io/managed-by": {}}
                            },
                            "f:spec": {
                                "f:replicas": {},
                                "f:selector": {},
                                "f:template": {"f:spec": {"f:containers": {
                                    "k:{\"name\":\"nginx\"}": {
                                        ".": {}, "f:name": {}, "f:image": {},
                                        "f:readinessProbe": {"f:httpGet": {"f:path": {}, "f:port": {}}}
                                    }
                                }}}
                            }
                        }),
                    ),
                    managed(
                        "kix",
                        "Update",
                        None,
                        json!({
                            "f:metadata": {"f:annotations": {f_activations: {}, f_applied: {}}}
                        }),
                    ),
                    managed(
                        "kube-controller-manager",
                        "Update",
                        Some("status"),
                        json!({
                            "f:metadata": {"f:annotations": {"f:deployment.kubernetes.io/revision": {}}},
                            "f:status": {"f:replicas": {}}
                        }),
                    ),
                ]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "spec": {
                    "replicas": 2,
                    "selector": {"matchLabels": {"app": "web"}},
                    "progressDeadlineSeconds": 600,
                    "revisionHistoryLimit": 10,
                    "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": "25%"}},
                    "template": {
                        "metadata": {"creationTimestamp": null},
                        "spec": {
                            "dnsPolicy": "ClusterFirst",
                            "schedulerName": "default-scheduler",
                            "containers": [{
                                "name": "nginx",
                                "image": "nginx:1.27",
                                "terminationMessagePath": "/dev/termination-log",
                                "readinessProbe": {
                                    "httpGet": {"path": "/", "port": "http", "scheme": "HTTP"},
                                    "failureThreshold": 3,
                                    "periodSeconds": 10
                                }
                            }]
                        }
                    }
                },
                "status": {"replicas": 2}
            }),
        };

        assert_eq!(
            kix_owned_view(&obj),
            json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": "web",
                    "namespace": "app",
                    "annotations": {keys::IDENTITY_HASH: "h1"},
                    "labels": {"app.kubernetes.io/managed-by": "kix"}
                },
                "spec": {
                    "replicas": 2,
                    "selector": {"matchLabels": {"app": "web"}},
                    "template": {"spec": {"containers": [{
                        "name": "nginx",
                        "image": "nginx:1.27",
                        "readinessProbe": {"httpGet": {"path": "/", "port": "http"}}
                    }]}}
                }
            })
        );
    }

    /// Build a live `Secret` that Kix applied with `stringData`, where the
    /// server stored only `data` plus an unowned `other` key.
    fn string_data_secret(password_b64: &str, annotations: Value) -> DynamicObject {
        let annotation_fields: serde_json::Map<String, Value> = annotations
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, _)| (format!("f:{k}"), json!({})))
            .collect();
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("creds".into()),
                namespace: Some("app".into()),
                annotations: Some(
                    annotations
                        .as_object()
                        .into_iter()
                        .flatten()
                        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
                        .collect(),
                ),
                managed_fields: Some(vec![managed(
                    "kix",
                    "Apply",
                    None,
                    json!({
                        "f:metadata": {"f:annotations": annotation_fields},
                        "f:stringData": {".": {}, "f:password": {}, "f:user": {}},
                        "f:type": {}
                    }),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "v1",
                "kind": "Secret",
                "type": "Opaque",
                // "admin", the given password, and "x".
                "data": {"user": "YWRtaW4=", "password": password_b64, "other": "eA=="}
            }),
        }
    }

    /// An object of another API group with kind Secret is not a Kubernetes
    /// Secret, and its view keeps its values.
    #[test]
    fn kix_owned_view_of_a_custom_resource_named_secret_keeps_its_values() {
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("creds".into()),
                namespace: Some("app".into()),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "x.example/v1",
                "kind": "Secret",
                "data": {"password": "plain"}
            }),
        };
        assert_eq!(kix_owned_view(&obj)["data"]["password"], json!("plain"));
    }

    #[test]
    fn kix_owned_view_of_a_string_data_secret_holds_no_values() {
        let view = kix_owned_view(&string_data_secret("ZGV2LXBhc3N3b3Jk", json!({})));
        assert!(view.get("stringData").is_none());
        assert!(view.get("data").is_none());
    }

    /// Build a live `SGCluster` where a mutating webhook added `publisher` to
    /// each extension inside an atomic list owned by Kix.
    fn webhook_defaulted_cluster(extensions: Value, applied_hash: Option<&str>) -> DynamicObject {
        applied_cluster(
            json!({"postgres": {"extensions": extensions}}),
            &[(keys::IDENTITY_HASH, "h-pg")],
            applied_hash,
        )
    }

    /// Build a live `SGCluster` whose Kix `Apply` entry owns `owned_annotations`
    /// and `spec.postgres.extensions`.
    fn applied_cluster(
        spec: Value,
        owned_annotations: &[(&str, &str)],
        applied_hash: Option<&str>,
    ) -> DynamicObject {
        let mut annotations: BTreeMap<String, String> = owned_annotations
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let annotation_fields: serde_json::Map<String, Value> = owned_annotations
            .iter()
            .map(|(k, _)| (format!("f:{k}"), json!({})))
            .collect();
        let mut obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("postgres".into()),
                namespace: Some("data".into()),
                annotations: Some(annotations.clone()),
                managed_fields: Some(vec![managed(
                    "kix",
                    "Apply",
                    None,
                    json!({
                        "f:metadata": {"f:annotations": annotation_fields},
                        "f:spec": {"f:postgres": {"f:extensions": {}}}
                    }),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "stackgres.io/v1",
                "kind": "SGCluster",
                "spec": spec
            }),
        };
        let hash = match applied_hash {
            Some(h) => h.to_string(),
            None => crate::cluster::fieldsv1::applied_content_hash(&obj).unwrap(),
        };
        annotations.insert(keys::APPLIED_HASH.to_string(), hash);
        obj.metadata.annotations = Some(annotations);
        obj
    }

    fn built_cluster(spec: Value, annotations: Value) -> Value {
        json!({
            "apiVersion": "stackgres.io/v1",
            "kind": "SGCluster",
            "metadata": {"name": "postgres", "namespace": "data", "annotations": annotations},
            "spec": spec
        })
    }

    fn diff_paths(built: &Value, compared: &Value) -> Vec<String> {
        let config = crate::manifest::diff::DiffConfig::default();
        crate::manifest::diff::engine::structural_diff(built, compared, "$", &config)
            .into_iter()
            .map(|d| d.path)
            .collect()
    }

    /// Because identity and applied-content hashes exclude `kix.run/*`
    /// annotations, the comparison preserves live `kix.run/*` annotations so
    /// package moves or annotation edits remain visible.
    #[test]
    fn a_changed_stamp_annotation_shows_in_the_comparison() {
        let spec = json!({"postgres": {"extensions": [{"name": "cube"}]}});
        let built = built_cluster(
            spec.clone(),
            json!({keys::IDENTITY_HASH: "h-pg", keys::PACKAGE: "postgres-new"}),
        );
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();

        let moved = applied_cluster(
            spec.clone(),
            &[
                (keys::IDENTITY_HASH, "h-pg"),
                (keys::PACKAGE, "postgres-old"),
            ],
            None,
        );
        let out = kix_owned_manifests_against([moved], &by_hash).remove(0);
        assert_eq!(
            out["metadata"]["annotations"][keys::PACKAGE],
            json!("postgres-old")
        );

        let extra = applied_cluster(
            spec,
            &[
                (keys::IDENTITY_HASH, "h-pg"),
                (keys::PACKAGE, "postgres-new"),
                (keys::LIFECYCLE, "stateful"),
            ],
            None,
        );
        let out = kix_owned_manifests_against([extra], &by_hash).remove(0);
        assert_eq!(
            out["metadata"]["annotations"][keys::LIFECYCLE],
            json!("stateful")
        );
    }

    /// The build does not change an object whose identity hash names a build
    /// manifest of the same resource, so the object compares as that
    /// manifest. That holds when it drifted since apply too, because drift is
    /// reported apart from the diff. Another resource carrying the hash, or a
    /// hash the build lacks, compares as the live view.
    #[test]
    fn an_object_the_build_does_not_change_compares_as_its_build_manifest() {
        let built = json!({
            "apiVersion": "stackgres.io/v1",
            "kind": "SGCluster",
            "metadata": {"name": "postgres", "namespace": "data",
                         "annotations": {keys::IDENTITY_HASH: "h-pg"}},
            "spec": {"postgres": {"extensions": [{"name": "cube"}]}}
        });
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();
        let live_extensions = json!([{"name": "cube", "publisher": "com.ongres"}]);

        let in_sync = webhook_defaulted_cluster(live_extensions.clone(), None);
        assert_eq!(
            kix_owned_manifests_against([in_sync], &by_hash),
            std::slice::from_ref(&built)
        );

        let drifted = webhook_defaulted_cluster(live_extensions.clone(), Some("other"));
        let out = kix_owned_manifests_against([drifted], &by_hash);
        assert_eq!(out[0]["spec"], built["spec"]);

        let mut renamed = webhook_defaulted_cluster(live_extensions.clone(), None);
        renamed.metadata.name = Some("other".into());
        let out = kix_owned_manifests_against([renamed], &by_hash);
        assert_eq!(out[0]["spec"]["postgres"]["extensions"], live_extensions);

        let in_sync = webhook_defaulted_cluster(live_extensions.clone(), None);
        let out = kix_owned_manifests_against([in_sync], &HashMap::new());
        assert_eq!(out[0]["spec"]["postgres"]["extensions"], live_extensions);
    }

    /// Build a live object Kix applied from `built` with the identity hash
    /// `h-live`, holding `data` and the given `managedFields`. Kix's `Apply`
    /// entry also owns the identity hash annotation, as a real apply does.
    fn live_of(
        built: &Value,
        data: Value,
        mut managed_fields: Vec<k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry>,
    ) -> DynamicObject {
        for entry in &mut managed_fields {
            if entry.manager.as_deref() == Some("kix")
                && let Some(fields) = &mut entry.fields_v1
            {
                fields.0["f:metadata"]["f:annotations"][format!("f:{}", keys::IDENTITY_HASH)] =
                    json!({});
            }
        }
        DynamicObject {
            metadata: ObjectMeta {
                name: built["metadata"]["name"].as_str().map(str::to_string),
                namespace: built["metadata"]["namespace"].as_str().map(str::to_string),
                annotations: Some(
                    [
                        (keys::IDENTITY_HASH.to_string(), "h-live".to_string()),
                        (keys::APPLIED_HASH.to_string(), "stamp".to_string()),
                    ]
                    .into(),
                ),
                managed_fields: Some(managed_fields),
                ..Default::default()
            },
            types: None,
            data,
        }
    }

    /// Assert that the Kix-owned view of `live` differs from `built`, so the
    /// case reproduces, and that the comparison against the build does not.
    fn assert_unchanged_by_build(built: &Value, live: DynamicObject) {
        assert!(
            !diff_paths(built, &kix_owned_view(&live)).is_empty(),
            "the case does not reproduce"
        );
        let by_hash: HashMap<String, &Value> = [("h-live".to_string(), built)].into();
        let out = kix_owned_manifests_against([live], &by_hash).remove(0);
        assert_eq!(diff_paths(built, &out), Vec::<String>::new());
    }

    /// The API server drops an `omitempty` value of `""`, so the live object
    /// lacks a field the build sets. The build does not change the object.
    #[test]
    fn an_empty_string_the_server_drops_does_not_show() {
        let built = json!({
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"name": "web", "namespace": "app",
                         "annotations": {keys::IDENTITY_HASH: "h-live"}},
            "spec": {"template": {"spec": {"containers": [{
                "name": "controller", "image": "c:1",
                "env": [{"name": "EXAMPLE_PULL_SECRET", "value": ""}]
            }]}}}
        });
        let data = json!({
            "apiVersion": "apps/v1", "kind": "Deployment",
            "spec": {"template": {"spec": {"containers": [{
                "name": "controller", "image": "c:1",
                "env": [{"name": "EXAMPLE_PULL_SECRET"}]
            }]}}}
        });
        let fields = json!({"f:spec": {"f:template": {"f:spec": {"f:containers": {
            "k:{\"name\":\"controller\"}": {
                ".": {}, "f:name": {}, "f:image": {},
                "f:env": {"k:{\"name\":\"EXAMPLE_PULL_SECRET\"}": {
                    ".": {}, "f:name": {}, "f:value": {}
                }}
            }
        }}}}});
        let live = live_of(&built, data, vec![managed("kix", "Apply", None, fields)]);
        assert_unchanged_by_build(&built, live);
    }

    fn virtual_machine(spec: Value, identity: bool) -> Value {
        let mut vm = json!({
            "apiVersion": "kubevirt.io/v1", "kind": "VirtualMachine",
            "metadata": {"name": "vm", "namespace": "app"},
            "spec": spec
        });
        if identity {
            vm["metadata"]["annotations"] = json!({keys::IDENTITY_HASH: "h-live"});
        }
        vm
    }

    /// `kubectl patch` set a field to the value the build holds, so its
    /// manager owns the field and Kix's `Apply` entry does not. The build
    /// does not change the object.
    #[test]
    fn a_field_another_manager_took_at_the_same_value_does_not_show() {
        let spec = json!({"runStrategy": "Always", "template": {"spec": {"domain": {}}}});
        let built = virtual_machine(spec.clone(), true);
        let live = live_of(
            &built,
            virtual_machine(spec, false),
            vec![
                managed("kix", "Apply", None, json!({"f:spec": {"f:template": {}}})),
                managed(
                    "kubectl-patch",
                    "Update",
                    None,
                    json!({"f:spec": {"f:runStrategy": {}}}),
                ),
            ],
        );
        assert_unchanged_by_build(&built, live);
    }

    /// An operator added `creationTimestamp: null` inside each item of an
    /// atomic list Kix owns, so the live list differs from the build's. The
    /// build does not change the object.
    #[test]
    fn a_null_creation_timestamp_in_an_atomic_list_does_not_show() {
        let template = |name: &str, live: bool| {
            let mut t = json!({"metadata": {"name": name},
                               "spec": {"storage": {"resources": {"requests": {"storage": "1Gi"}}}}});
            if live {
                t["metadata"]["creationTimestamp"] = Value::Null;
            }
            t
        };
        let spec = |live: bool| {
            json!({"runStrategy": "Always",
                   "dataVolumeTemplates": [template("vm-root", live), template("vm-scratch", live)]})
        };
        let built = virtual_machine(spec(false), true);
        let live = live_of(
            &built,
            virtual_machine(spec(true), false),
            vec![managed(
                "kix",
                "Apply",
                None,
                json!({"f:spec": {"f:runStrategy": {}, "f:dataVolumeTemplates": {}}}),
            )],
        );
        assert_unchanged_by_build(&built, live);
    }

    /// Compare `live` against a build holding only `built`, keyed by its
    /// identity hash or by `h-new` when it has none.
    fn compare_with_build(live: DynamicObject, built: &Value) -> Value {
        let hash = keys::get(built, keys::IDENTITY_HASH).unwrap_or("h-new");
        let by_hash: HashMap<String, &Value> = [(hash.to_string(), built)].into();
        kix_owned_manifests_against([live], &by_hash).remove(0)
    }

    /// Literal `stringData` in the build: a live value equal to the build's
    /// reads as the build's, a changed one is hidden, and one that does not
    /// decode is left out. `other` is not in the build and never appears.
    #[test]
    fn a_secret_applied_with_string_data_compares_against_the_build() {
        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app"},
            "stringData": {"user": "admin", "password": "dev-password"}
        });

        let same = compare_with_build(string_data_secret("ZGV2LXBhc3N3b3Jk", json!({})), &built);
        assert_eq!(same, built);

        // "rotated"
        let changed = compare_with_build(string_data_secret("cm90YXRlZA==", json!({})), &built);
        assert_eq!(
            changed["stringData"],
            json!({"user": "admin", "password": HIDDEN_SECRET_VALUE})
        );
        assert!(!changed.to_string().contains("rotated"));

        let broken = compare_with_build(string_data_secret("not base64", json!({})), &built);
        assert_eq!(broken["stringData"], json!({"user": "admin"}));
    }

    /// A SOPS `Secret` has no `stringData` in the build, and Kix applies
    /// decrypted values through `stringData`. Verify that the live object
    /// compares equal to the build without exposing decrypted values.
    #[test]
    fn a_sops_secret_compares_unchanged_without_its_values() {
        let annotations = json!({
            keys::SOPS_SOURCE: "/nix/store/abc-secrets.yaml",
            keys::IDENTITY_HASH: "h-sec"
        });
        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app", "annotations": annotations}
        });
        // "s3cr3t-from-sops"
        let live = || string_data_secret("czNjcjN0LWZyb20tc29wcw==", annotations.clone());

        let compared = compare_with_build(live(), &built);
        let config = crate::manifest::diff::DiffConfig::default();
        assert_eq!(
            crate::manifest::diff::engine::structural_diff(&built, &compared, "$", &config),
            vec![]
        );
        for out in [compared, kix_owned_view(&live())] {
            let text = out.to_string();
            assert!(!text.contains("s3cr3t-from-sops"), "{text}");
            assert!(!text.contains("admin"), "{text}");
        }
    }

    /// Build a live `Secret` with `data` keys `user`, `password`, and `other`
    /// and the given `managed_fields`.
    fn data_secret(
        managed_fields: Vec<k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry>,
    ) -> DynamicObject {
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("creds".into()),
                namespace: Some("app".into()),
                annotations: Some(
                    [
                        (keys::IDENTITY_HASH.to_string(), "h-sec".to_string()),
                        (keys::APPLIED_HASH.to_string(), "drifted".to_string()),
                    ]
                    .into(),
                ),
                managed_fields: Some(managed_fields),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "v1",
                "kind": "Secret",
                "type": "Opaque",
                "data": {"user": "YWRtaW4=", "password": "cm90YXRlZA==", "other": "eA=="}
            }),
        }
    }

    fn assert_no_live_value(out: &Value) {
        let text = out.to_string();
        for live in ["cm90YXRlZA==", "rotated", "eA=="] {
            assert!(!text.contains(live), "{live} in {text}");
        }
    }

    /// Verify that a `Secret` applied through `data` that the build changes
    /// exposes no live values, keeping matching build values and replacing
    /// changed ones with [`HIDDEN_SECRET_VALUE`].
    #[test]
    fn a_secret_applied_with_data_holds_no_live_value() {
        let live = || {
            data_secret(vec![managed(
                "kix",
                "Apply",
                None,
                json!({"f:data": {".": {}, "f:user": {}, "f:password": {}}, "f:type": {}}),
            )])
        };
        let view = kix_owned_view(&live());
        assert_eq!(
            view["data"],
            json!({"user": HIDDEN_SECRET_VALUE, "password": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&view);

        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app",
                         "annotations": {keys::IDENTITY_HASH: "h-sec-new"}},
            // "admin", "dev-password"
            "data": {"user": "YWRtaW4=", "password": "ZGV2LXBhc3N3b3Jk"}
        });
        let compared = compare_with_build(live(), &built);
        assert_eq!(
            compared["data"],
            json!({"user": "YWRtaW4=", "password": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&compared);
    }

    /// Verify that a `Secret` without a Kix `Apply` entry still redacts all
    /// live values.
    #[test]
    fn a_secret_without_an_apply_entry_holds_no_live_value() {
        let live = || {
            data_secret(vec![managed(
                "kubectl-create",
                "Update",
                None,
                json!({"f:data": {}}),
            )])
        };
        let view = kix_owned_view(&live());
        assert_eq!(
            view["data"],
            json!({"user": HIDDEN_SECRET_VALUE, "password": HIDDEN_SECRET_VALUE,
                   "other": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&view);
        assert_no_live_value(&kix_owned_manifests([live()]).remove(0));

        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app"},
            "stringData": {"user": "admin", "password": "dev-password"}
        });
        let compared = compare_with_build(live(), &built);
        assert_eq!(compared["stringData"], json!({"user": "admin"}));
        assert_eq!(
            compared["data"],
            json!({"password": HIDDEN_SECRET_VALUE, "other": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&compared);
    }

    /// When an object has no Kix `Apply` entry, [`kix_owned_view`] falls back
    /// to the full object with server metadata stripped.
    #[test]
    fn kix_owned_view_falls_back_without_an_apply_entry() {
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("cm".into()),
                namespace: Some("app".into()),
                uid: Some("abc".into()),
                managed_fields: Some(vec![managed(
                    "kubectl-create",
                    "Update",
                    None,
                    json!({"f:data": {}}),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({"apiVersion": "v1", "kind": "ConfigMap", "data": {"k": "v"}}),
        };
        let view = kix_owned_view(&obj);
        assert_eq!(view["data"], json!({"k": "v"}));
        assert_eq!(view["metadata"]["name"], json!("cm"));
        assert!(view["metadata"].get("uid").is_none());
        assert!(view["metadata"].get("managedFields").is_none());
    }

    #[test]
    fn normalize_strips_server_fields() {
        let mut obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("test".into()),
                namespace: Some("default".into()),
                uid: Some("abc-123".into()),
                resource_version: Some("12345".into()),
                generation: Some(3),
                managed_fields: Some(vec![]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "metadata": {
                    "name": "test",
                    "namespace": "default",
                    "uid": "abc-123",
                    "resourceVersion": "12345",
                    "creationTimestamp": "2026-01-01T00:00:00Z",
                    "generation": 3,
                    "selfLink": "/api/v1/namespaces/default/pods/test",
                    "managedFields": [{"manager": "kubectl"}],
                    "annotations": {
                        "kubectl.kubernetes.io/last-applied-configuration": "{}",
                        "custom-annotation": "keep"
                    }
                },
                "spec": {"replicas": 1},
                "status": {"ready": true}
            }),
        };

        normalize_for_diff(&mut obj);

        // Typed metadata fields
        assert!(obj.metadata.uid.is_none());
        assert!(obj.metadata.resource_version.is_none());
        assert!(obj.metadata.generation.is_none());
        assert!(obj.metadata.managed_fields.is_none());

        // Raw JSON fields
        let data = obj.data.as_object().unwrap();
        let meta = data["metadata"].as_object().unwrap();
        assert!(!meta.contains_key("uid"));
        assert!(!meta.contains_key("resourceVersion"));
        assert!(!meta.contains_key("creationTimestamp"));
        assert!(!meta.contains_key("generation"));
        assert!(!meta.contains_key("selfLink"));
        assert!(!meta.contains_key("managedFields"));

        // last-applied-configuration stripped, custom annotation kept
        let annotations = meta["annotations"].as_object().unwrap();
        assert!(!annotations.contains_key("kubectl.kubernetes.io/last-applied-configuration"));
        assert_eq!(annotations["custom-annotation"], "keep");

        // status removed
        assert!(!data.contains_key("status"));

        // spec preserved
        assert!(data.contains_key("spec"));
    }

    /// Build a deserialized LIST item with `kind` and `apiVersion` injected as
    /// [`super::inventory`] does.
    fn list_item() -> DynamicObject {
        let mut obj: DynamicObject = serde_json::from_value(json!({
            "metadata": { "name": "lithus-secret-operator", "namespace": "lithus-system" },
            "spec": { "replicas": 1 },
        }))
        .unwrap();
        let map = obj.data.as_object_mut().unwrap();
        map.insert("kind".into(), json!("Deployment"));
        map.insert("apiVersion".into(), json!("apps/v1"));
        obj
    }

    /// Verify that deserializing a `DynamicObject` places `metadata` on the
    /// typed field rather than inside `.data`.
    #[test]
    fn deserialized_object_keeps_metadata_out_of_data() {
        let obj = list_item();
        assert_eq!(obj.metadata.name.as_deref(), Some("lithus-secret-operator"));
        assert!(
            obj.data.get("metadata").is_none(),
            "metadata must live on the typed field, not in .data"
        );
    }

    /// Verify that [`to_manifest_value`] merges typed metadata so
    /// [`ResourceId::from_value`] extracts the resource's name and namespace.
    #[test]
    fn to_manifest_value_yields_a_matchable_resource_id() {
        let mut obj = list_item();
        normalize_for_diff(&mut obj);

        let broken = crate::manifest::types::ResourceId::from_value(&obj.data);
        assert_eq!(broken.name, "unknown", "the old .data-only path");

        let id = crate::manifest::types::ResourceId::from_value(&to_manifest_value(&obj));
        assert_eq!(id.kind, "Deployment");
        assert_eq!(id.name, "lithus-secret-operator");
        assert_eq!(id.namespace, "lithus-system");
    }

    /// Verify that [`to_manifest_value`] omits server fields cleared by
    /// [`normalize_for_diff`].
    #[test]
    fn to_manifest_value_drops_normalized_server_fields() {
        let mut obj = list_item();
        obj.metadata.uid = Some("abc-123".into());
        obj.metadata.resource_version = Some("12345".into());
        normalize_for_diff(&mut obj);

        let value = to_manifest_value(&obj);
        let meta = value.pointer("/metadata").unwrap().as_object().unwrap();
        assert!(!meta.contains_key("uid"));
        assert!(!meta.contains_key("resourceVersion"));
        assert_eq!(value.pointer("/spec/replicas").unwrap(), &json!(1));
    }
}
