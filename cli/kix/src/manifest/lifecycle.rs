//! `kix-core`'s resource lifecycles, plus the classification of live objects.

use kube::api::DynamicObject;
use serde_json::Value;

pub use kix_core::manifest::lifecycle::*;

use crate::manifest::keys;

/// Classify a live object. LIST responses put the kind either in `.data`
/// (Kix injects it there) or in `.types`; annotations live on the typed
/// metadata.
pub fn lifecycle_of_live(obj: &DynamicObject) -> Lifecycle {
    let kind = obj
        .data
        .get("kind")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("");
    let api_version = obj
        .data
        .get("apiVersion")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.api_version.as_str()))
        .unwrap_or("");
    let mode = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::MODE));
    classify(
        crate::manifest::kinds::GroupKind::new(
            crate::manifest::types::api_group(api_version),
            kind,
        ),
        mode,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn live_objects_classify_the_same_way() {
        let mut obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "stage1-abc" }
        }))
        .unwrap();
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Record);
        // Kind injected into .data by the sweep, types absent.
        obj.types = None;
        obj.data = json!({ "kind": "PackageInstance", "apiVersion": keys::API_VERSION });
        obj.metadata.annotations = Some([(keys::MODE.to_string(), "import".to_string())].into());
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Marker);
        obj.metadata.annotations = None;
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Desired);
        // Another group's kind of the same name is an object like any other.
        obj.data = json!({ "kind": "Activation", "apiVersion": "ssm.aws.upbound.io/v1beta1" });
        assert_eq!(lifecycle_of_live(&obj), Lifecycle::Desired);
    }
}
