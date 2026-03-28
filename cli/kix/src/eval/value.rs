//! Value conversion helpers.
//!
//! When the real Nix FFI crates are available (Step 9), this module will
//! contain functions to walk `nix_bindings_expr::Value` trees and convert
//! them into `serde_json::Value`. The FFI value navigation API:
//!
//! ```ignore
//! eval_state.require_attrs_select(&v, "name")?        // -> Value (errors if missing)
//! eval_state.require_attrs_select_opt(&v, "name")?     // -> Option<Value>
//! eval_state.require_attrs_names(&v)?                   // -> Vec<String>
//! eval_state.require_list_strict::<Vec<Value>>(&v)?     // -> Vec<Value>
//! eval_state.require_string(&v)?                        // -> String
//! eval_state.require_int(&v)?                           // -> i64
//! eval_state.require_bool(&v)?                          // -> bool
//! ```
//!
//! For now, since the mock backend already produces `serde_json::Value`,
//! this module provides helpers for working with JSON values that represent
//! K8s manifests.

use serde_json::Value;

/// Extract the `kind` field from a K8s manifest JSON value.
pub fn manifest_kind(v: &Value) -> Option<&str> {
    v.get("kind").and_then(Value::as_str)
}

/// Extract the `metadata.name` field from a K8s manifest JSON value.
pub fn manifest_name(v: &Value) -> Option<&str> {
    v.get("metadata")
        .and_then(|m| m.get("name"))
        .and_then(Value::as_str)
}

/// Extract the `metadata.namespace` field from a K8s manifest JSON value.
pub fn manifest_namespace(v: &Value) -> Option<&str> {
    v.get("metadata")
        .and_then(|m| m.get("namespace"))
        .and_then(Value::as_str)
}

/// Build a GVK string (group/version.kind) from a manifest, used for display.
pub fn manifest_gvk(v: &Value) -> Option<String> {
    let api_version = v.get("apiVersion").and_then(Value::as_str)?;
    let kind = v.get("kind").and_then(Value::as_str)?;
    Some(format!("{api_version}/{kind}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extract_manifest_fields() {
        let manifest = json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "nginx",
                "namespace": "default"
            }
        });
        assert_eq!(manifest_kind(&manifest), Some("Deployment"));
        assert_eq!(manifest_name(&manifest), Some("nginx"));
        assert_eq!(manifest_namespace(&manifest), Some("default"));
        assert_eq!(manifest_gvk(&manifest), Some("apps/v1/Deployment".into()));
    }
}
