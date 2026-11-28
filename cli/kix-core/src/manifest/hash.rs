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
pub(crate) fn normalize_for_content_hash(manifest: &Value) -> Value {
    let mut v = manifest.clone();
    strip_server_metadata(&mut v);
    strip_status(&mut v);
    strip_kix_annotations(&mut v);
    strip_kubectl_annotations(&mut v);
    strip_null_values(&mut v);
    sort_keys(&v)
}

/// Compute the Blake3 hash of the canonical JSON of a normalized manifest.
pub(crate) fn content_hash(manifest: &Value) -> String {
    let normalized = normalize_for_content_hash(manifest);
    let canonical = serde_json::to_string(&normalized).unwrap_or_default();
    blake3::hash(canonical.as_bytes()).to_hex().to_string()
}

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
/// `kix export` to produce Kix-neutral YAML for exit-strategy
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

/// Compute the Blake3 hash of an already normalized and key-sorted `Value`.
pub fn hash_value(v: &Value) -> String {
    let canonical = serde_json::to_string(v).unwrap_or_default();
    blake3::hash(canonical.as_bytes()).to_hex().to_string()
}

/// Hex digits of an object hash. It is as long as the Nix store hash an
/// older Kix stored in a revision's place, so the revision size estimate
/// holds for both.
pub const OBJECT_HASH_LEN: usize = 32;

/// Return the object hash of the built manifest `manifest`: the first
/// [`OBJECT_HASH_LEN`] hex digits of the SHA-256 of the manifest Kix sends
/// for it ([`super::sent::of`]), with every retired note removed, nulls
/// removed, and keys sorted.
///
/// Take it from the manifest as the build holds it, before secret values
/// are filled in. It covers every other `kix.run/*` annotation, such as
/// `kix.run/sops-digest`, so a changed SOPS file changes it. Revisions store
/// it and plans compare it for equality, so a change to what it covers
/// makes the next deploy apply every object once.
pub fn object_hash(manifest: &Value) -> String {
    use sha2::{Digest, Sha256};
    let mut v = super::sent::of(manifest).into_owned();
    super::sent::strip_retired_notes(&mut v);
    strip_null_values(&mut v);
    let canonical = serde_json::to_vec(&sort_keys(&v)).unwrap_or_default();
    let mut hex = format!("{:x}", Sha256::digest(canonical));
    hex.truncate(OBJECT_HASH_LEN);
    hex
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

    fn fixture() -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "creds",
                "namespace": "app",
                "labels": { "app": "web" },
                "annotations": {
                    keys::SOPS_SOURCE: "secrets/creds.yaml",
                    keys::SOPS_DIGEST: "ab12",
                    keys::IDENTITY_HASH: "0123456789abcdfghijklmnpqrsvwxyz",
                    keys::DEPENDS_ON: "requires:h2",
                    keys::PACKAGE: "web",
                    keys::PACKAGE_NAMESPACE: "app",
                    keys::LIFECYCLE: "stateful",
                },
            },
            "type": "Opaque",
            "stringData": { "user": "admin" },
        })
    }

    /// The object hash is stored in revisions, so a change to it makes every
    /// deploy after an upgrade apply every object once. Change this value
    /// only on purpose, with an upgrade note.
    #[test]
    fn the_object_hash_of_a_fixed_manifest_is_pinned() {
        assert_eq!(object_hash(&fixture()), "dc62fbf782b8161a192e97c66cc45b58");
    }

    #[test]
    fn the_object_hash_ignores_key_order_nulls_and_retired_notes() {
        let base = object_hash(&fixture());
        assert_eq!(base.len(), OBJECT_HASH_LEN);
        let reordered: Value =
            serde_json::from_str(&serde_json::to_string(&sort_keys(&fixture())).unwrap()).unwrap();
        assert_eq!(object_hash(&reordered), base);
        let mut with_null = fixture();
        with_null["metadata"]["annotations"]["x.example/y"] = Value::Null;
        with_null["data"] = Value::Null;
        assert_eq!(object_hash(&with_null), base);
        let mut without_notes = fixture();
        let annotations = without_notes["metadata"]["annotations"]
            .as_object_mut()
            .unwrap();
        for note in crate::manifest::sent::GRAPH_NOTES {
            annotations.remove(*note);
        }
        assert_eq!(object_hash(&without_notes), base);
        let mut with_old_notes = fixture();
        with_old_notes["metadata"]["annotations"][keys::APPLIED_HASH] = json!("a");
        with_old_notes["metadata"]["annotations"][keys::ACTIVATIONS] = json!("h1");
        assert_eq!(object_hash(&with_old_notes), base);
    }

    #[test]
    fn the_object_hash_covers_every_other_kix_annotation() {
        let base = object_hash(&fixture());
        for key in [
            keys::SOPS_DIGEST,
            keys::SOPS_SOURCE,
            keys::READINESS,
            keys::CEDE_FIELDS,
        ] {
            let mut changed = fixture();
            changed["metadata"]["annotations"][key] = json!("other");
            assert_ne!(object_hash(&changed), base, "{key}");
        }
        let mut data = fixture();
        data["stringData"]["user"] = json!("root");
        assert_ne!(object_hash(&data), base);
    }

    #[test]
    fn content_hash_is_deterministic() {
        let a = json!({"b": 2, "a": 1});
        let b = json!({"a": 1, "b": 2});
        assert_eq!(content_hash(&a), content_hash(&b));
    }
}
