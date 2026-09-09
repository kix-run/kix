//! fieldsV1 interpretation for the applied-hash drift design (doc 122).
//!
//! Pure module — no cluster access. Extracts kix's server-side-apply
//! managedFields entry from a live object and projects the object onto that
//! fieldset: "the subset of the live object that kix put there". Hashing the
//! projection at apply time (from the SSA response echo) and again at check
//! time (from a GET) makes runtime content drift a hash comparison between
//! two *server* representations — no build, no normalization heroics.

use k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry;
use kube::api::DynamicObject;
use serde_json::{Map, Value};

use super::normalize;

/// The field manager kix uses for server-side apply.
pub const KIX_FIELD_MANAGER: &str = "kix";

/// Extract the fieldsV1 tree of kix's SSA entry: manager == "kix",
/// operation == "Apply", no subresource.
///
/// Reads the TYPED `metadata.managed_fields` — LIST responses split metadata
/// out of `obj.data`, so the raw data must never be consulted for this.
pub fn kix_fieldset(obj: &DynamicObject) -> Option<Value> {
    kix_apply_entry(obj.metadata.managed_fields.as_deref()?)
        .and_then(|e| e.fields_v1.as_ref())
        .map(|f| f.0.clone())
}

/// The managedFields entry kix's SSA writes, if present.
pub fn kix_apply_entry(entries: &[ManagedFieldsEntry]) -> Option<&ManagedFieldsEntry> {
    entries.iter().find(|e| {
        e.manager.as_deref() == Some(KIX_FIELD_MANAGER)
            && e.operation.as_deref() == Some("Apply")
            && e.subresource.is_none()
    })
}

/// Project a live value onto a fieldsV1 tree — keep exactly the fields the
/// fieldset lists, at the granularity the server tracked them.
///
/// fieldsV1 semantics implemented:
/// - `f:<name>` — member of a map. Empty subtree `{}` means the server tracks
///   the field as one atomic leaf → copy the whole live value; a non-empty
///   subtree recurses into it.
/// - `k:{...}` — associative-list element, matched by ALL key/value pairs
///   against live array elements.
/// - `v:<json>` — set element, matched by value.
/// - `i:<n>` — positional element.
/// - `.` — the node itself; marks existence, contributes no content. An
///   element owned only via `.` still appears in the projection (as an empty
///   object), so its deletion is detected.
///
/// Live array order is preserved and arrays are never sorted: both hash
/// inputs are server representations, so order is stable unless someone
/// actually changed it. Fieldset entries with no matching live counterpart
/// are skipped — that is how deletions are detected (the projection shrinks,
/// the hash changes).
pub fn project(live: &Value, fields: &Value) -> Value {
    let Some(fmap) = fields.as_object() else {
        return live.clone();
    };
    if fmap.is_empty() {
        // Atomic leaf — the server tracks this whole subtree as one field.
        return live.clone();
    }
    match live {
        Value::Object(lmap) => project_object(lmap, fmap),
        Value::Array(larr) => project_array(larr, fmap),
        // Scalar with a non-empty fieldset only happens if the live value
        // changed type since apply; keep the live value so the hash differs.
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
fn match_element<'a>(
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
/// it — name/namespace/labels/annotations must be merged back before the
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

/// The applied-content hash — ONE shared recipe, used at stamp time (on the
/// SSA response echo) and at check time (on a GET/LIST result):
///
/// 1. Merge typed metadata back into the data `Value`.
/// 2. Project onto kix's fieldsV1 (the subset kix owns).
/// 3. Strip `kix.run/*` annotations (self-reference: the stamp must not
///    change its own hash).
/// 4. Blake3 over canonical (sorted-keys) JSON.
///
/// Returns `None` when the object has no kix SSA managedFields entry.
pub fn applied_content_hash(obj: &DynamicObject) -> Option<String> {
    // TODO(doc-123): exclude PI spec.driftIgnore pointers here — compiled
    // delegation drops the listed JSON pointers from the projection on both
    // the stamp and the check side, so expected co-owners (HPA on replicas,
    // cert-manager on Secret data) never enter the hash.
    let mut projection = kix_owned_projection(obj)?;
    normalize::strip_kix_annotations(&mut projection);
    Some(normalize::hash_value(&normalize::sort_keys(&projection)))
}

/// The part of a live object kix's server-side apply owns: typed metadata
/// merged back, then projected onto kix's `Apply` fieldset. Steps 1 and 2
/// of the applied-content hash, and the whole of what `kix diff` and
/// `kix snapshot save` look at (see `fetch::kix_owned_view`). `None` when
/// the object has no kix SSA managedFields entry.
pub fn kix_owned_projection(obj: &DynamicObject) -> Option<Value> {
    let fields = kix_fieldset(obj)?;
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
        // lost it → projection shrinks.
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
        // kix owns only container "a" (and within it only image).
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
        // serde_json object keys iterate sorted (a before b) — the projection
        // must follow LIVE order (b before a) regardless.
        assert_eq!(
            project(&live, &fields),
            json!([{"name": "b", "v": 2}, {"name": "a", "v": 1}])
        );
    }

    #[test]
    fn dot_only_element_is_included_empty() {
        // An element owned only via "." still appears, so deleting it is
        // detected — but its (foreign-owned) content stays out of the hash.
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

    #[test]
    fn type_change_keeps_live_value() {
        // Live changed type since apply — keep it so the hash differs.
        let live = json!({"spec": "now-a-string"});
        let fields = json!({"f:spec": {"f:replicas": {}}});
        assert_eq!(project(&live, &fields), json!({"spec": "now-a-string"}));
    }
}
