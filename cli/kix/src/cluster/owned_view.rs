//! A live object as a comparison with a build sees it: the fields Kix's
//! server-side apply owns, with Secret values redacted.

use std::collections::HashMap;

use crate::manifest::keys;
use crate::manifest::types::{ResourceId, to_manifest_value};
use kube::api::DynamicObject;

/// Strip server-side fields from a DynamicObject for diffing.
///
/// Removes: uid, resourceVersion, creationTimestamp, generation,
/// selfLink, managedFields, status, last-applied-configuration annotation.
pub(crate) fn normalize_for_diff(obj: &mut DynamicObject) {
    // Top-level metadata fields
    obj.metadata.uid = None;
    obj.metadata.resource_version = None;
    obj.metadata.creation_timestamp = None;
    obj.metadata.generation = None;
    obj.metadata.managed_fields = None;

    // Remove selfLink if present in the raw data
    if let Some(data) = obj.data.as_object_mut() {
        if let Some(meta) = data.get_mut("metadata").and_then(|m| m.as_object_mut()) {
            meta.remove("selfLink");
            meta.remove("uid");
            meta.remove("resourceVersion");
            meta.remove("creationTimestamp");
            meta.remove("generation");
            meta.remove("managedFields");

            // Strip last-applied-configuration annotation
            if let Some(annotations) = meta.get_mut("annotations").and_then(|a| a.as_object_mut()) {
                annotations.remove("kubectl.kubernetes.io/last-applied-configuration");
                // Remove annotations object entirely if empty
                if annotations.is_empty() {
                    meta.remove("annotations");
                }
            }
        }

        // Remove status entirely
        data.remove("status");
    }
}

/// The kix-owned view of a live object: the live value projected onto the
/// fieldset kix's server-side apply owns, with the type
/// meta and identity that fieldsV1 never lists (`apiVersion`, `kind`,
/// `metadata.name`, `metadata.namespace`) restored.
///
/// This is what `kix diff` and `kix snapshot save` compare against a build:
/// the server's defaults (deployment strategy, probe thresholds, scheduler
/// name, ...) are owned by nobody or by a controller, so they never enter the
/// view, and kix's own bookkeeping annotations (`kix.run/activations`,
/// `kix.run/applied-hash`) are written through a separate `Update` entry, so
/// they are excluded too. Comparing this to the rendered manifest asks the
/// question a change review actually needs answered: "does what kix would
/// apply differ from what kix last applied?"
///
/// Objects without a kix `Apply` entry (adopted externally, or predating SSA)
/// fall back to the whole object with server metadata stripped.
///
/// A Secret's view holds no live value: every `data` key reads
/// [`HIDDEN_SECRET_VALUE`] (see `redact_secret`). Values kix applied
/// through `stringData` are absent, since the server stores them only in
/// `data` and kix's fieldset lists `stringData`.
/// [`kix_owned_manifests_against`] compares both against a build.
pub(crate) fn kix_owned_view(obj: &DynamicObject) -> serde_json::Value {
    let mut view = unredacted_view(obj);
    redact_secret(&mut view, obj, None);
    view
}

/// [`kix_owned_view`] before [`redact_secret`]. A Secret's live values are
/// still in it, so it must not leave this module.
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

/// Stands in for a live Secret value that differs from the build's, so a
/// diff shows the key as changed without printing what the cluster holds.
pub const HIDDEN_SECRET_VALUE: &str = "(live value differs from the build, not shown)";

/// Keep every live value out of a Secret's view.
///
/// Each key under the view's `data` becomes the value `built` gives it when
/// the decoded live value equals the build's: under `data` when the build
/// declares the key there, under `stringData` when the build declares it
/// there. Every other key reads [`HIDDEN_SECRET_VALUE`], as does every key
/// when `built` is `None`.
///
/// The API server merges `stringData` into `data` and never stores it, so the
/// projection of a Secret kix applied with `stringData` lists neither field.
/// For each `stringData` key `built` declares and kix's fieldset lists, the
/// decoded live `data` value is compared the same way and the key is added
/// under `stringData`; a key whose live value is missing or is not
/// base64-encoded UTF-8 is left out. A SOPS Secret's build manifest has no
/// `stringData` (kix decrypts its values at deploy time), so none of its keys
/// are restored and a value changed out of band does not show.
///
/// The view therefore never holds a value that is not already in the build.
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
    // The server never returns `stringData`; hide anything found there.
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

/// The kix-owned view of every object in a sweep, brought to the current
/// domain: what a build is compared against, whether the comparison runs
/// now (`kix diff`), later from a directory (`kix snapshot save`), or as
/// the previous state a deploy plans from when its store path is gone.
///
/// The domain upgrade matters on a cluster a previous Kix stamped under a
/// retired domain: without it every Kix annotation reads as a paired add
/// and remove, and an in-sync cluster reads as entirely modified.
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

/// [`kix_owned_manifests`] for comparison against a build, with each object
/// that is unchanged since kix applied a manifest still in the build replaced
/// by that manifest. `built` maps identity hash to the build's stamped
/// manifest.
///
/// An object is unchanged when its `kix.run/identity-hash` names a manifest
/// in `built`, [`super::drift::check_object`] finds it in sync, and every
/// field that manifest sets holds the same value in the kix-owned view (see
/// `build_holds_in`). The view may carry fields the build does not set,
/// such as the `publisher` StackGres's mutating webhook adds to each
/// extension; those are what the replacement hides. In sync alone is not
/// enough: it means the live fields match the apply response, which already
/// lacks a field the CRD schema pruned and already holds a value a webhook
/// overwrote. The replacement keeps the live `kix.run/*` annotations, because
/// both hashes leave them out and a package move would otherwise not show.
///
/// Every other object is compared through its view, with `redact_secret`
/// run against the build manifest of the same name, so no live Secret value
/// leaves this function. A Secret kix applied with `stringData` always takes
/// that path (the server stores no `stringData`). A changed value shows there
/// only when the build holds the plaintext: a literal `data` or `stringData`
/// value, not a SOPS Secret's.
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
            if let Some(manifest) = unchanged_since_apply(&obj, &view, built) {
                return manifest;
            }
            let build = by_id.get(&ResourceId::from_value(&view)).copied();
            redact_secret(&mut view, &obj, build);
            view
        })
        .collect()
}

/// The build manifest `obj` was applied from, with the live `kix.run/*`
/// annotations of `view`, when nothing has changed it since. See
/// [`kix_owned_manifests_against`].
fn unchanged_since_apply(
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
    if super::drift::check_object(obj).verdict != super::drift::DriftVerdict::InSync
        || !build_holds_in(manifest, view, "$")
    {
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

/// Whether every field `build` sets is present in `live` with an equal
/// value, using the same equivalences as the diff engine (a server default
/// or empty list for an absent field, quantity spellings). `live` may hold
/// fields `build` does not. Lists match by the diff engine's keys, or by
/// position, and must have the same length. `path` is the diff path of
/// `build`, which the equivalence rules match on.
fn build_holds_in(build: &serde_json::Value, live: &serde_json::Value, path: &str) -> bool {
    use crate::manifest::diff::equivalence::{
        equivalent_to_unset, is_quantity_field, same_quantity,
    };
    use crate::manifest::diff::keyed_lists::{path_leaf, try_key_lists};
    use serde_json::Value;

    match (build, live) {
        (Value::Object(b), Value::Object(l)) => {
            let parent = path_leaf(path);
            b.iter().all(|(key, bv)| {
                let child = format!("{path}.{key}");
                match l.get(key) {
                    None => equivalent_to_unset(&child, bv),
                    Some(lv) => {
                        (bv.is_null() && equivalent_to_unset(&child, lv))
                            || (is_quantity_field(parent, key) && same_quantity(bv, lv))
                            || build_holds_in(bv, lv, &child)
                    }
                }
            })
        }
        (Value::Array(b), Value::Array(l)) => {
            if b.len() != l.len() {
                return false;
            }
            match try_key_lists(path_leaf(path), b, l) {
                Some((b_map, l_map)) => b_map.iter().all(|(key, bv)| {
                    l_map
                        .get(key)
                        .is_some_and(|lv| build_holds_in(bv, lv, &format!("{path}[{key}]")))
                }),
                None => b
                    .iter()
                    .zip(l)
                    .enumerate()
                    .all(|(i, (bv, lv))| build_holds_in(bv, lv, &format!("{path}[{i}]"))),
            }
        }
        _ => build == live,
    }
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

    /// A live Deployment as the apiserver hands it back: kix's Apply entry
    /// owns what kix sent, kix's bookkeeping patch is a separate Update
    /// entry, the controller owns its revision annotation and status, and
    /// the server defaulted strategy, probe thresholds and the like with no
    /// owner at all. Only the first survives.
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

    /// A live Secret kix applied with `stringData`: the server stored only
    /// `data`, under the given base64 password and `other`, which is not kix's.
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

    /// A live SGCluster after an apply: the operator's webhook added
    /// `publisher` to each extension, inside a list kix owns whole.
    fn webhook_defaulted_cluster(extensions: Value, applied_hash: Option<&str>) -> DynamicObject {
        applied_cluster(
            json!({"postgres": {"extensions": extensions}}),
            &[(keys::IDENTITY_HASH, "h-pg")],
            applied_hash,
        )
    }

    /// A live SGCluster whose kix Apply entry owns the given annotations and
    /// `spec.postgres.extensions`. The applied-content hash is computed from
    /// the object unless `applied_hash` overrides it.
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

    /// A field the CRD schema pruned on apply is absent from the live object,
    /// although drift finds it in sync. It shows as missing.
    #[test]
    fn a_field_pruned_on_apply_shows_in_the_comparison() {
        let built = built_cluster(
            json!({"postgres": {"extensions": [{"name": "cube"}], "flavour": "babelfish"}}),
            json!({keys::IDENTITY_HASH: "h-pg"}),
        );
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();
        let live = applied_cluster(
            json!({"postgres": {"extensions": [{"name": "cube"}]}}),
            &[(keys::IDENTITY_HASH, "h-pg")],
            None,
        );
        let out = kix_owned_manifests_against([live], &by_hash).remove(0);
        assert_eq!(diff_paths(&built, &out), vec!["$.spec.postgres.flavour"]);
    }

    /// A value a mutating webhook overwrote on apply reads as changed, while
    /// the field it added beside it still does not show.
    #[test]
    fn a_value_a_webhook_overwrote_shows_in_the_comparison() {
        let built = built_cluster(
            json!({"postgres": {"extensions": [{"name": "cube", "version": "1.5"}]}}),
            json!({keys::IDENTITY_HASH: "h-pg"}),
        );
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();
        let live = webhook_defaulted_cluster(
            json!([{"name": "cube", "version": "1.6", "publisher": "com.ongres"}]),
            None,
        );
        let out = kix_owned_manifests_against([live], &by_hash).remove(0);
        assert_eq!(
            out["spec"]["postgres"]["extensions"][0]["version"],
            json!("1.6")
        );
        assert!(
            diff_paths(&built, &out)
                .contains(&"$.spec.postgres.extensions[cube].version".to_string())
        );
    }

    /// The identity and applied-content hashes leave out `kix.run/*`
    /// annotations, so a package move or a hand-edited stamp keeps both. The
    /// comparison carries the live stamps and shows the change.
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

    #[test]
    fn an_object_unchanged_since_apply_compares_as_its_build_manifest() {
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

        // Changed since the apply: the live view, webhook default and all.
        let drifted = webhook_defaulted_cluster(live_extensions.clone(), Some("other"));
        let out = kix_owned_manifests_against([drifted], &by_hash);
        assert_eq!(out[0]["spec"]["postgres"]["extensions"], live_extensions);

        // Applied from a manifest the build no longer has: the live view.
        let in_sync = webhook_defaulted_cluster(live_extensions.clone(), None);
        let out = kix_owned_manifests_against([in_sync], &HashMap::new());
        assert_eq!(out[0]["spec"]["postgres"]["extensions"], live_extensions);
    }

    fn compare_with_build(live: DynamicObject, built: &Value) -> Value {
        let by_hash: HashMap<String, &Value> = [("h-sec".to_string(), built)].into();
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

    /// A SOPS Secret: the build has no `stringData`, and kix applied the
    /// decrypted values through it. The live object reads as the build, and
    /// no decrypted value appears in the comparison or the view.
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

    /// A live Secret holding `data` user "admin", password "rotated" and
    /// `other` "x", whose managedFields are `managed_fields`.
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

    /// A Secret kix applied through `data` that has drifted since: no live
    /// value is in its view, and against the build a key equal to the
    /// build's reads as the build's while a changed one is hidden.
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
                         "annotations": {keys::IDENTITY_HASH: "h-sec"}},
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

    /// A Secret with no kix Apply entry falls back to the whole object, and
    /// still holds no live value: without a build every key is hidden, and a
    /// key the build declares under `stringData` with the same value reads
    /// as the build's.
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

    /// No kix Apply entry (adopted externally, or pre-SSA): the whole object,
    /// minus server metadata, so the diff still has something to show.
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

    /// A LIST item as the apiserver actually returns it: no per-item
    /// `apiVersion`/`kind`, and `metadata` alongside `spec`.
    fn list_item() -> DynamicObject {
        let mut obj: DynamicObject = serde_json::from_value(json!({
            "metadata": { "name": "lithus-secret-operator", "namespace": "lithus-system" },
            "spec": { "replicas": 1 },
        }))
        .unwrap();
        // What fetch_parallel does, because LIST omits these per item.
        let map = obj.data.as_object_mut().unwrap();
        map.insert("kind".into(), json!("Deployment"));
        map.insert("apiVersion".into(), json!("apps/v1"));
        obj
    }

    /// Pins the shape the whole bug turned on: kube-rs parses `metadata`
    /// into the typed field and leaves it OUT of `.data`. The synthetic
    /// fixtures above put `metadata` inside `.data`, which the apiserver
    /// never does, so anything reading `.data["metadata"]` reads nothing.
    #[test]
    fn deserialized_object_keeps_metadata_out_of_data() {
        let obj = list_item();
        assert_eq!(obj.metadata.name.as_deref(), Some("lithus-secret-operator"));
        assert!(
            obj.data.get("metadata").is_none(),
            "metadata must live on the typed field, not in .data"
        );
    }

    /// Regression: serialising `.data` alone drops metadata, so every live
    /// object of a kind degrades to the same `Kind/unknown` id, matches
    /// nothing, and `kix diff` reports an unchanged cluster as fully new.
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

    /// normalize_for_diff clears the TYPED metadata fields; that only has
    /// any effect if the typed metadata is what gets serialised.
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
