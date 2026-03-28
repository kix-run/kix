//! Content-hash normalization for drift detection.
//!
//! Normalizes K8s manifests by stripping server-injected fields, kix annotations,
//! null values, and sorting keys — so that identical *intended* state produces
//! identical hashes regardless of server enrichment.
//!
//! Used by `kix health` and (eventually) the operator's drift detection loop.
//! NOT used by deploy or GC, which use local DAG diff via identity-hash.

use std::collections::BTreeMap;

use crate::manifest::types::ResourceId;
use kube::{
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;

use super::fetch::{self, FetchError};

/// Per-resource drift status.
#[derive(Debug, Clone)]
pub enum DriftStatus {
    /// Resource on cluster matches intended manifest.
    InSync,
    /// Resource on cluster differs from intended manifest.
    Drifted {
        /// Human-readable diff (YAML) between intended and live.
        diff: String,
    },
    /// Resource is in intended state but missing from cluster.
    Missing,
}

/// A drift report for a single resource.
#[derive(Debug, Clone)]
pub struct DriftReport {
    pub rid: ResourceId,
    pub status: DriftStatus,
}

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

/// Compare intended manifests against live cluster resources.
///
/// For each intended manifest, fetches the corresponding live resource
/// and compares their normalized content hashes.
pub async fn detect_drift(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    intended: &[Value],
) -> Result<Vec<DriftReport>, FetchError> {
    // Fetch all kix-managed resources from the cluster
    let live_objects = fetch::fetch_managed_resources(client, discovery).await?;

    // Build lookup: (kind, namespace, name) → normalized live manifest
    let mut live_map: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for mut obj in live_objects {
        fetch::normalize_for_diff(&mut obj);
        let value = serde_json::to_value(&obj.data).unwrap_or_default();
        let rid = ResourceId::from_value(&value);
        let key = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
        live_map.insert(key, value);
    }

    let mut reports = Vec::new();
    for intended_manifest in intended {
        let rid = ResourceId::from_value(intended_manifest);
        let key = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);

        let status = match live_map.get(&key) {
            Some(live_value) => {
                let intended_hash = content_hash(intended_manifest);
                let live_hash = content_hash(live_value);

                if intended_hash == live_hash {
                    DriftStatus::InSync
                } else {
                    // Generate a human-readable diff
                    let intended_yaml =
                        serde_yml::to_string(&normalize_for_content_hash(intended_manifest))
                            .unwrap_or_default();
                    let live_yaml = serde_yml::to_string(&normalize_for_content_hash(live_value))
                        .unwrap_or_default();

                    let diff = unified_diff(&intended_yaml, &live_yaml);
                    DriftStatus::Drifted { diff }
                }
            }
            None => DriftStatus::Missing,
        };

        reports.push(DriftReport { rid, status });
    }

    reports.sort_by(|a, b| a.rid.cmp(&b.rid));
    Ok(reports)
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

fn strip_kix_annotations(v: &mut Value) {
    if let Some(annotations) = v
        .pointer_mut("/metadata/annotations")
        .and_then(|a| a.as_object_mut())
    {
        let kix_keys: Vec<String> = annotations
            .keys()
            .filter(|k| k.starts_with("kix.dev/"))
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
fn sort_keys(v: &Value) -> Value {
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

/// Generate a unified diff between two strings.
fn unified_diff(a: &str, b: &str) -> String {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(a, b);
    let mut output = String::new();
    for change in diff.iter_all_changes() {
        let sign = match change.tag() {
            ChangeTag::Delete => "-",
            ChangeTag::Insert => "+",
            ChangeTag::Equal => " ",
        };
        output.push_str(sign);
        output.push_str(change.as_str().unwrap_or(""));
    }
    output
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
                    "kix.dev/identity-hash": "abc123",
                    "kix.dev/package": "my-pkg",
                    "kix.dev/activations": "hash1,hash2",
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
        assert!(!ann.contains_key("kix.dev/identity-hash"));
        assert!(!ann.contains_key("kix.dev/package"));
        assert!(!ann.contains_key("kix.dev/activations"));
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
