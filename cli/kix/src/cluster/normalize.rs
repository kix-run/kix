//! Manifest normalization helpers for stripping server metadata, Kix annotations,
//! status, nulls; canonical (sorted-keys) Blake3 hashing.
//!
//! The hash and strip helpers are shared by export and applied-content drift
//! checks.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::manifest::keys;

/// Normalize a `serde_json::Value` manifest for content comparison.
///
/// Strips server-injected metadata, status, kix-internal annotations,
/// kubectl bookkeeping annotations, and null values. Sorts all object
/// keys for canonical serialization.
pub fn normalize_for_content_hash(manifest: &Value) -> Value {
    let mut v = manifest.clone();
    strip_server_metadata(&mut v);
    strip_status(&mut v);
    strip_kix_annotations(&mut v);
    strip_kubectl_annotations(&mut v);
    strip_null_values(&mut v);
    sort_keys(&v)
}

/// Blake3 hash of the canonical JSON of a normalized manifest.
pub fn content_hash(manifest: &Value) -> String {
    let normalized = normalize_for_content_hash(manifest);
    let canonical = serde_json::to_string(&normalized).unwrap_or_default();
    blake3::hash(canonical.as_bytes()).to_hex().to_string()
}

// ---------------------------------------------------------------------------
// Internal normalization helpers
// ---------------------------------------------------------------------------

fn strip_server_metadata(v: &mut Value) {
    if let Some(meta) = v.pointer_mut("/metadata").and_then(|m| m.as_object_mut()) {
        meta.remove("uid");
        meta.remove("resourceVersion");
        meta.remove("creationTimestamp");
        meta.remove("generation");
        meta.remove("managedFields");
        meta.remove("selfLink");
    }
}

fn strip_status(v: &mut Value) {
    if let Some(obj) = v.as_object_mut() {
        obj.remove("status");
    }
}

/// Remove all `kix.run/*` annotations from a manifest's `metadata.annotations`.
/// Used by `normalize_for_content_hash` for drift detection and by
/// `kix export --for=exit` to produce kix-neutral YAML for exit-strategy
/// handoff. If the annotations map becomes empty, the `annotations` key is
/// also removed.
pub fn strip_kix_annotations(v: &mut Value) {
    if let Some(annotations) = v
        .pointer_mut("/metadata/annotations")
        .and_then(|a| a.as_object_mut())
    {
        let kix_keys: Vec<String> = annotations
            .keys()
            .filter(|k| keys::is_kix_key(k))
            .cloned()
            .collect();
        for key in kix_keys {
            annotations.remove(&key);
        }
        if annotations.is_empty()
            && let Some(meta) = v.pointer_mut("/metadata").and_then(|m| m.as_object_mut())
        {
            meta.remove("annotations");
        }
    }
}

fn strip_kubectl_annotations(v: &mut Value) {
    if let Some(annotations) = v
        .pointer_mut("/metadata/annotations")
        .and_then(|a| a.as_object_mut())
    {
        annotations.remove("kubectl.kubernetes.io/last-applied-configuration");
        if annotations.is_empty()
            && let Some(meta) = v.pointer_mut("/metadata").and_then(|m| m.as_object_mut())
        {
            meta.remove("annotations");
        }
    }
}

fn strip_null_values(v: &mut Value) {
    match v {
        Value::Object(map) => {
            map.retain(|_, val| !val.is_null());
            for val in map.values_mut() {
                strip_null_values(val);
            }
        }
        Value::Array(arr) => {
            for val in arr.iter_mut() {
                strip_null_values(val);
            }
        }
        _ => {}
    }
}

/// Recursively sort all object keys by converting to BTreeMap.
pub fn sort_keys(v: &Value) -> Value {
    match v {
        Value::Object(map) => {
            let sorted: BTreeMap<String, Value> =
                map.iter().map(|(k, v)| (k.clone(), sort_keys(v))).collect();
            serde_json::to_value(sorted).unwrap_or_default()
        }
        Value::Array(arr) => Value::Array(arr.iter().map(sort_keys).collect()),
        other => other.clone(),
    }
}

/// Blake3 hash of a normalized Value (already sorted/stripped).
pub fn hash_value(v: &Value) -> String {
    let canonical = serde_json::to_string(v).unwrap_or_default();
    blake3::hash(canonical.as_bytes()).to_hex().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalize_strips_server_fields() {
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "test",
                "namespace": "default",
                "uid": "abc-123",
                "resourceVersion": "12345",
                "creationTimestamp": "2026-01-01T00:00:00Z",
                "generation": 1,
                "managedFields": [{"manager": "kix"}],
                "selfLink": "/api/v1/namespaces/default/configmaps/test"
            },
            "data": {"key": "value"}
        });

        let normalized = normalize_for_content_hash(&manifest);
        assert!(normalized.pointer("/metadata/uid").is_none());
        assert!(normalized.pointer("/metadata/resourceVersion").is_none());
        assert!(normalized.pointer("/metadata/creationTimestamp").is_none());
        assert!(normalized.pointer("/metadata/generation").is_none());
        assert!(normalized.pointer("/metadata/managedFields").is_none());
        assert!(normalized.pointer("/metadata/selfLink").is_none());
        // Data should remain
        assert_eq!(
            normalized.pointer("/data/key").and_then(|v| v.as_str()),
            Some("value")
        );
    }

    #[test]
    fn normalize_strips_kix_and_kubectl_annotations() {
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "test",
                "namespace": "default",
                "annotations": {
                    keys::IDENTITY_HASH: "abc123",
                    keys::PACKAGE: "my-pkg",
                    keys::ACTIVATIONS: "hash1,hash2",
                    "kubectl.kubernetes.io/last-applied-configuration": "{}",
                    "custom-annotation": "keep-me"
                }
            },
            "data": {"key": "value"}
        });

        let normalized = normalize_for_content_hash(&manifest);
        let annotations = normalized
            .pointer("/metadata/annotations")
            .and_then(|a| a.as_object());
        assert!(annotations.is_some());
        let ann = annotations.unwrap();
        assert!(!ann.contains_key(keys::IDENTITY_HASH));
        assert!(!ann.contains_key(keys::PACKAGE));
        assert!(!ann.contains_key(keys::ACTIVATIONS));
        assert!(!ann.contains_key("kubectl.kubernetes.io/last-applied-configuration"));
        assert_eq!(
            ann.get("custom-annotation").and_then(|v| v.as_str()),
            Some("keep-me")
        );
    }

    #[test]
    fn normalize_strips_status_and_nulls() {
        let manifest = json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "test", "namespace": "default"},
            "spec": {"replicas": 1, "unused": null},
            "status": {"ready": true}
        });

        let normalized = normalize_for_content_hash(&manifest);
        assert!(normalized.pointer("/status").is_none());
        assert!(normalized.pointer("/spec/unused").is_none());
        assert_eq!(
            normalized
                .pointer("/spec/replicas")
                .and_then(|v| v.as_i64()),
            Some(1)
        );
    }

    #[test]
    fn content_hash_is_deterministic() {
        let a = json!({"b": 2, "a": 1});
        let b = json!({"a": 1, "b": 2});
        assert_eq!(content_hash(&a), content_hash(&b));
    }
}
