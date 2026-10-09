//! Core manifest types.

use kube::api::DynamicObject;
use serde::{Deserialize, Serialize};

/// Sentinel namespace value for cluster-scoped resources.
pub const CLUSTER_SCOPED: &str = "_cluster";

/// Whether `manifest` is a Kubernetes Secret: `apiVersion` `v1` and `kind`
/// `Secret`. Kix hides a Secret's values by this rule, which is also the one
/// Kix Enterprise's agent and server use. An object of another API group
/// with kind `Secret` is a custom resource, and its values show.
pub fn is_secret(manifest: &serde_json::Value) -> bool {
    manifest.get("apiVersion").and_then(|v| v.as_str()) == Some("v1")
        && manifest.get("kind").and_then(|v| v.as_str()) == Some("Secret")
}

/// Unique identifier for a K8s resource.
#[derive(
    Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, schemars::JsonSchema,
)]
pub struct ResourceId {
    pub kind: String,
    pub namespace: String, // "_cluster" for cluster-scoped
    pub name: String,
}

impl ResourceId {
    /// Extract a ResourceId from a manifest JSON value.
    pub fn from_value(doc: &serde_json::Value) -> Self {
        ResourceId {
            kind: doc
                .pointer("/kind")
                .and_then(|v| v.as_str())
                .unwrap_or("Unknown")
                .to_string(),
            namespace: doc
                .pointer("/metadata/namespace")
                .and_then(|v| v.as_str())
                .unwrap_or(CLUSTER_SCOPED)
                .to_string(),
            name: doc
                .pointer("/metadata/name")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
                .to_string(),
        }
    }

    /// Parse from flat filename format: `{ns}--{name}-{kind}.yaml`
    ///
    /// The kind is the last `-`-separated segment before `.yaml`, lowercased in the filename.
    pub fn from_filename(filename: &str) -> Option<Self> {
        let stem = filename.strip_suffix(".yaml")?;
        let (namespace, rest) = stem.split_once("--")?;
        let (name, kind) = rest.rsplit_once('-')?;
        if namespace.is_empty() || name.is_empty() || kind.is_empty() {
            return None;
        }
        Some(ResourceId {
            kind: kind.to_string(),
            namespace: namespace.to_string(),
            name: name.to_string(),
        })
    }

    /// Parse from nested path format: namespace directory + `{name}-{kind}.yaml` filename.
    pub fn from_nested_path(ns_dir: &str, filename: &str) -> Option<Self> {
        let stem = filename.strip_suffix(".yaml")?;
        let (name, kind) = stem.rsplit_once('-')?;
        if ns_dir.is_empty() || name.is_empty() || kind.is_empty() {
            return None;
        }
        Some(ResourceId {
            kind: kind.to_string(),
            namespace: ns_dir.to_string(),
            name: name.to_string(),
        })
    }

    /// "Kind/name@namespace", as given: for keys, and for messages that
    /// escape their text as a whole. Showing an id goes through `Display`.
    pub fn display_id(&self) -> String {
        if self.namespace == CLUSTER_SCOPED {
            format!("{}/{}", self.kind, self.name)
        } else {
            format!("{}/{}@{}", self.kind, self.name, self.namespace)
        }
    }
}

/// "Kind/name@namespace" for people to read: each part through
/// [`crate::text::printable`], since a build's kinds, names and namespaces
/// are its author's text, and plans, logs and graphs show them. This is
/// where kix shows an object's id.
impl std::fmt::Display for ResourceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        use crate::text::printable;
        write!(f, "{}/{}", printable(&self.kind), printable(&self.name))?;
        if self.namespace != CLUSTER_SCOPED {
            write!(f, "@{}", printable(&self.namespace))?;
        }
        Ok(())
    }
}

/// Serialise a fetched object into a whole-manifest `Value`.
///
/// `DynamicObject` keeps `metadata` in a typed field and puts only the
/// *remaining* keys (`spec`, `data`, …) in `.data`. Serialising `.data`
/// alone therefore yields a manifest with no `metadata`, name, or namespace.
/// This silently degrades every `ResourceId` built from it to `Kind/unknown`.
/// Every live object of the same kind then
/// collapses onto one id, matches nothing on the kix side, and the diff
/// reports the whole cluster as "will be created".
///
/// `kind`/`apiVersion` come from `.data` (the cluster sweep injects them,
/// since LIST responses omit them per item) rather than from `.types`.
pub fn to_manifest_value(obj: &DynamicObject) -> serde_json::Value {
    serde_json::to_value(obj).unwrap_or_else(|e| {
        // ObjectMeta + a JSON Value cannot fail to serialise.
        unreachable!("DynamicObject failed to serialise: {e}")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_value_full() {
        let doc = serde_json::json!({
            "kind": "Service",
            "metadata": {
                "name": "my-svc",
                "namespace": "default"
            }
        });
        let rid = ResourceId::from_value(&doc);
        assert_eq!(rid.kind, "Service");
        assert_eq!(rid.name, "my-svc");
        assert_eq!(rid.namespace, "default");
    }

    #[test]
    fn from_value_cluster_scoped() {
        let doc = serde_json::json!({
            "kind": "ClusterRole",
            "metadata": { "name": "admin" }
        });
        let rid = ResourceId::from_value(&doc);
        assert_eq!(rid.namespace, CLUSTER_SCOPED);
    }

    #[test]
    fn display_namespaced() {
        let rid = ResourceId {
            kind: "deployment".into(),
            namespace: "kube-system".into(),
            name: "coredns".into(),
        };
        assert_eq!(rid.to_string(), "deployment/coredns@kube-system");
    }

    /// Two names that look alike show differently.
    #[test]
    fn display_flags_hidden_characters() {
        let rid = ResourceId {
            kind: "ClusterRoleBinding".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "cluster-admin\u{200b}".into(),
        };
        assert_eq!(rid.to_string(), "ClusterRoleBinding/cluster-admin⟨U+200B⟩");
        assert_eq!(rid.display_id(), "ClusterRoleBinding/cluster-admin\u{200b}");
    }

    #[test]
    fn from_filename_basic() {
        let rid = ResourceId::from_filename("kube-system--coredns-deployment.yaml").unwrap();
        assert_eq!(rid.namespace, "kube-system");
        assert_eq!(rid.name, "coredns");
        assert_eq!(rid.kind, "deployment");
    }
}
