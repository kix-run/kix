//! Interpret fieldsV1 for applied-content drift detection.
//!
//! Extracts Kix's server-side apply managedFields entry from a live object and
//! projects the object onto that fieldset. Hashing the projection at apply time
//! (from the SSA response) and again at check time (from a GET) reduces runtime
//! content drift to a hash comparison between two server representations.

use k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry;
use kube::api::DynamicObject;
use serde_json::{Map, Value};

use super::field_manager::{FieldManager, Manager};
use crate::manifest::hash;

/// Extract the fieldsV1 tree of the server-side apply entry that holds the
/// fields `manager`'s Kix cluster applied ([`FieldManager::apply_entry`]).
///
/// Reads typed `metadata.managed_fields`. LIST responses split metadata
/// out of `obj.data`, so the raw data must never be consulted for this.
pub fn kix_fieldset(obj: &DynamicObject, manager: &FieldManager) -> Option<Value> {
    manager
        .apply_entry(obj.metadata.managed_fields.as_deref()?)
        .and_then(|e| e.fields_v1.as_ref())
        .map(|f| f.0.clone())
}

/// Return whether any `managedFields` entry names a field manager that a Kix
/// cluster writes under, its own or the legacy one.
///
/// Kix writes every object it applies under its cluster's manager, and an
/// older Kix wrote it under the legacy manager. The API server records the
/// manager of each write, so an object a controller made from a Kix
/// object's labels and annotations has no such entry.
pub(crate) fn written_by_kix(entries: &[ManagedFieldsEntry]) -> bool {
    entries.iter().any(|e| {
        e.manager
            .as_deref()
            .is_some_and(|m| Manager::parse(m).is_kix())
    })
}

/// Project a live value onto a fieldsV1 tree, keeping the fields the fieldset
/// lists at the granularity the server tracked them.
///
/// Supported fieldsV1 keys:
/// - `f:<name>`: map member. An empty subtree means the server tracks the field
///   as an atomic leaf and copies the whole live value. A non-empty subtree
///   recurses into it.
/// - `k:{...}`: associative-list element matched by every key-value pair
///   against live array elements.
/// - `v:<json>`: set element matched by value.
/// - `i:<n>`: positional element.
/// - `.`: the node itself, which marks existence and contributes no content. An
///   element owned only via `.` still appears in the projection as an empty
///   object so its deletion is detected.
///
/// Live array order is preserved because both hash inputs are server
/// representations. Fieldset entries with no matching live counterpart are
/// skipped, which shrinks the projection and changes the hash when a field is
/// deleted.
pub fn project(live: &Value, fields: &Value) -> Value {
    let Some(fmap) = fields.as_object() else {
        return live.clone();
    };
    if fmap.is_empty() {
        // The server tracks an atomic leaf as one field.
        return live.clone();
    }
    match live {
        Value::Object(lmap) => project_object(lmap, fmap),
        Value::Array(larr) => project_array(larr, fmap),
        // A scalar with a non-empty fieldset only occurs if the live value
        // changed type since apply. Keep the live value so the hash differs.
        other => other.clone(),
    }
}

fn project_object(live: &Map<String, Value>, fields: &Map<String, Value>) -> Value {
    let mut out = Map::new();
    for (key, subtree) in fields {
        // Fields missing from live are skipped: deletion shows up as a
        // shrunken projection. "." (node-itself marker) contributes nothing.
        if let Some(name) = key.strip_prefix("f:")
            && let Some(live_val) = live.get(name)
        {
            out.insert(name.to_string(), project(live_val, subtree));
        }
    }
    Value::Object(out)
}

fn project_array(live: &[Value], fields: &Map<String, Value>) -> Value {
    let mut out = Vec::new();
    for (idx, elem) in live.iter().enumerate() {
        if let Some(subtree) = match_element(elem, idx, fields) {
            out.push(project(elem, subtree));
        }
    }
    Value::Array(out)
}

/// Find the fieldset entry matching a live array element, if any.
pub(crate) fn match_element<'a>(
    elem: &Value,
    idx: usize,
    fields: &'a Map<String, Value>,
) -> Option<&'a Value> {
    for (key, subtree) in fields {
        if let Some(key_json) = key.strip_prefix("k:") {
            if let Ok(Value::Object(keys)) = serde_json::from_str(key_json)
                && keys.iter().all(|(k, v)| elem.get(k) == Some(v))
            {
                return Some(subtree);
            }
        } else if let Some(val_json) = key.strip_prefix("v:") {
            if let Ok(val) = serde_json::from_str::<Value>(val_json)
                && *elem == val
            {
                return Some(subtree);
            }
        } else if let Some(i_str) = key.strip_prefix("i:")
            && i_str.parse::<usize>() == Ok(idx)
        {
            return Some(subtree);
        }
    }
    None
}

/// Reconstruct a full manifest `Value` from a `DynamicObject` by merging the
/// typed metadata back into the raw data. kube's `DynamicObject` always
/// deserializes `metadata` into the typed field, so `obj.data` never carries
/// it. Name, namespace, labels, and annotations must be merged back before the
/// object can be projected.
pub fn merge_typed_metadata(obj: &DynamicObject) -> Value {
    let mut value = obj.data.clone();
    if let Some(map) = value.as_object_mut() {
        let meta = map
            .entry("metadata")
            .or_insert_with(|| serde_json::json!({}));
        if let Some(meta_obj) = meta.as_object_mut() {
            if let Some(name) = &obj.metadata.name {
                meta_obj
                    .entry("name")
                    .or_insert_with(|| Value::String(name.clone()));
            }
            if let Some(ns) = &obj.metadata.namespace {
                meta_obj
                    .entry("namespace")
                    .or_insert_with(|| Value::String(ns.clone()));
            }
            if let Some(labels) = &obj.metadata.labels
                && !labels.is_empty()
            {
                meta_obj
                    .entry("labels")
                    .or_insert_with(|| serde_json::to_value(labels).unwrap_or_default());
            }
            if let Some(annotations) = &obj.metadata.annotations
                && !annotations.is_empty()
            {
                let existing = meta_obj
                    .entry("annotations")
                    .or_insert_with(|| serde_json::json!({}));
                if let (Some(existing_map), Value::Object(ann_map)) = (
                    existing.as_object_mut(),
                    serde_json::to_value(annotations).unwrap_or_default(),
                ) {
                    for (k, v) in ann_map {
                        existing_map.entry(k).or_insert(v);
                    }
                }
            }
        }
    }
    value
}

/// Compute the applied-content hash of `obj`:
///
/// 1. Merge typed metadata back into the data `Value`.
/// 2. Project onto Kix's `fieldsV1` fieldset.
/// 3. Remove the fields the object cedes in `kix.run/cede-fields`.
/// 4. Remove the retired notes ([`crate::manifest::sent::is_retired_note`]).
///    Every other `kix.run/*` annotation Kix owns stays, so the hash covers
///    what the object hash of the build covers.
/// 5. Compute Blake3 over canonical (sorted-keys) JSON.
///
/// Kix computes this hash from the apply's answer and again from the live
/// object, so a ceded field is out of both. Another controller may then
/// change it without the object reading as drifted.
///
/// Returns `None` when the object has no server-side apply `managedFields`
/// entry that counts as `manager`'s.
pub fn applied_content_hash(obj: &DynamicObject, manager: &FieldManager) -> Option<String> {
    hashed_projection(obj, manager).map(projection_hash)
}

/// Return what [`applied_content_hash`] hashes: [`kix_owned_projection`]
/// without the fields the object cedes.
pub(crate) fn hashed_projection(obj: &DynamicObject, manager: &FieldManager) -> Option<Value> {
    let fields = kix_fieldset(obj, manager)?;
    let full = merge_typed_metadata(obj);
    let mut projection = project(&full, &fields);
    for ceded in crate::cluster::apply::ceded_fields(&full) {
        crate::cluster::apply::remove_covered(&mut projection, &ceded);
    }
    Some(projection)
}

/// Remove the retired notes from `projection` and return its canonical
/// Blake3 hash.
pub(crate) fn projection_hash(mut projection: Value) -> String {
    crate::manifest::sent::strip_retired_notes(&mut projection);
    hash::hash_value(&hash::sort_keys(&projection))
}

/// Return the applied hash an older Kix computed for `obj`, which left out
/// every `kix.run/*` annotation. Kix reads it only to judge whether a live
/// object still matches the `kix.run/applied-hash` note or the format 1
/// revision an older Kix wrote, when it converts their records.
pub(crate) fn older_kix_applied_hash(
    obj: &DynamicObject,
    manager: &FieldManager,
) -> Option<String> {
    let mut projection = hashed_projection(obj, manager)?;
    hash::strip_kix_annotations(&mut projection);
    Some(hash::hash_value(&hash::sort_keys(&projection)))
}

/// Project `obj` onto `manager`'s server-side apply fieldset after merging
/// typed metadata back into its data. Returns `None` when `obj` has no
/// `Apply` entry that counts as `manager`'s.
pub(crate) fn kix_owned_projection(obj: &DynamicObject, manager: &FieldManager) -> Option<Value> {
    let fields = kix_fieldset(obj, manager)?;
    Some(project(&merge_typed_metadata(obj), &fields))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn atomic_leaf_copies_whole_value() {
        let live = json!({"spec": {"replicas": 3, "paused": false}});
        let fields = json!({"f:spec": {}});
        assert_eq!(
            project(&live, &fields),
            json!({"spec": {"replicas": 3, "paused": false}})
        );
    }

    #[test]
    fn granular_map_recurses_and_skips_unowned() {
        let live = json!({"spec": {"replicas": 3, "minReadySeconds": 5}});
        let fields = json!({"f:spec": {"f:replicas": {}}});
        assert_eq!(project(&live, &fields), json!({"spec": {"replicas": 3}}));
    }

    #[test]
    fn missing_live_field_is_skipped() {
        // Deletion detection: the fieldset still lists the field but live
        // lost it, so the projection shrinks.
        let live = json!({"spec": {}});
        let fields = json!({"f:spec": {"f:replicas": {}}});
        assert_eq!(project(&live, &fields), json!({"spec": {}}));
    }

    #[test]
    fn keyed_list_matches_by_all_keys_not_position() {
        let live = json!([
            {"name": "b", "image": "img-b", "extra": "server-added"},
            {"name": "a", "image": "img-a"}
        ]);
        // Kix owns only container "a" (and within it only image).
        let fields = json!({
            "k:{\"name\":\"a\"}": {".": {}, "f:name": {}, "f:image": {}}
        });
        assert_eq!(
            project(&live, &fields),
            json!([{"name": "a", "image": "img-a"}])
        );
    }

    #[test]
    fn keyed_list_multi_key_match() {
        let live = json!([
            {"containerPort": 80, "protocol": "TCP"},
            {"containerPort": 80, "protocol": "UDP"}
        ]);
        let fields = json!({
            "k:{\"containerPort\":80,\"protocol\":\"UDP\"}": {".": {}, "f:containerPort": {}, "f:protocol": {}}
        });
        assert_eq!(
            project(&live, &fields),
            json!([{"containerPort": 80, "protocol": "UDP"}])
        );
    }

    #[test]
    fn keyed_list_preserves_live_order() {
        let live = json!([{"name": "b", "v": 2}, {"name": "a", "v": 1}]);
        let fields = json!({
            "k:{\"name\":\"a\"}": {"f:name": {}, "f:v": {}},
            "k:{\"name\":\"b\"}": {"f:name": {}, "f:v": {}}
        });
        // `serde_json` object keys iterate in sorted order (a before b), while
        // the projection preserves live array order (b before a).
        assert_eq!(
            project(&live, &fields),
            json!([{"name": "b", "v": 2}, {"name": "a", "v": 1}])
        );
    }

    #[test]
    fn dot_only_element_is_included_empty() {
        // An element owned only via "." still appears, so deleting it is
        // detected while its foreign-owned content stays out of the hash.
        let live = json!([{"name": "a", "foreign": 1}]);
        let fields = json!({"k:{\"name\":\"a\"}": {".": {}}});
        assert_eq!(project(&live, &fields), json!([{}]));
    }

    #[test]
    fn set_element_matches_by_value() {
        let live = json!(["example.com/finalizer", "other/finalizer"]);
        let fields = json!({"v:\"example.com/finalizer\"": {}});
        assert_eq!(project(&live, &fields), json!(["example.com/finalizer"]));
    }

    #[test]
    fn positional_element_matches_by_index() {
        let live = json!(["a", "b", "c"]);
        let fields = json!({"i:1": {}});
        assert_eq!(project(&live, &fields), json!(["b"]));
    }

    /// A field the object cedes is out of the applied hash, so another
    /// manager may change it. A field it does not cede is still in.
    #[test]
    fn the_applied_hash_leaves_out_ceded_fields() {
        let object = |replicas: i64, image: &str| -> DynamicObject {
            serde_json::from_value(json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": "web",
                    "namespace": "app",
                    "annotations": {
                        (crate::manifest::keys::CEDE_FIELDS): ".spec.replicas,.spec.template.spec.containers[*].resources",
                    },
                    "managedFields": [{
                        "manager": "kix/a",
                        "operation": "Apply",
                        "fieldsV1": {"f:spec": {
                            "f:replicas": {},
                            "f:template": {"f:spec": {"f:containers": {
                                "k:{\"name\":\"web\"}": {"f:name": {}, "f:image": {}, "f:resources": {}},
                            }}},
                        }},
                    }],
                },
                "spec": {
                    "replicas": replicas,
                    "template": {"spec": {"containers": [
                        {"name": "web", "image": image, "resources": {"limits": {"cpu": replicas}}},
                    ]}},
                },
            }))
            .unwrap()
        };
        let a = FieldManager::of("a");
        let base = applied_content_hash(&object(1, "a"), &a);
        assert_eq!(applied_content_hash(&object(5, "a"), &a), base);
        assert_ne!(applied_content_hash(&object(1, "b"), &a), base);
    }

    #[test]
    fn type_change_keeps_live_value() {
        // Keep a live type change so the hash differs.
        let live = json!({"spec": "now-a-string"});
        let fields = json!({"f:spec": {"f:replicas": {}}});
        assert_eq!(project(&live, &fields), json!({"spec": "now-a-string"}));
    }
}
