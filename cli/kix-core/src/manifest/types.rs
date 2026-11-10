//! Core manifest types.

use serde::{Deserialize, Serialize};

/// Sentinel namespace value for cluster-scoped resources.
pub const CLUSTER_SCOPED: &str = "_cluster";

/// Return whether `manifest` is a core Kubernetes `v1/Secret`.
///
/// Kix redacts secret values based on this check. Custom resources in other API
/// groups whose kind happens to be `Secret` are not redacted.
pub fn is_secret(manifest: &serde_json::Value) -> bool {
    manifest.get("apiVersion").and_then(|v| v.as_str()) == Some("v1")
        && manifest.get("kind").and_then(|v| v.as_str()) == Some("Secret")
}

/// Return whether the manifest's API group is one whose kinds Kix knows: the
/// core group, a [`BUILTIN_GROUPS`] entry, a group ending in one of
/// [`BUILTIN_GROUP_SUFFIXES`], and Kix's own group.
///
/// Every built-in Kubernetes group is in this set. So are some groups that
/// CRDs serve, such as `gateway.networking.k8s.io`, so a caller must not rely
/// on a known group meaning "served by Go types".
pub fn is_known_api(manifest: &serde_json::Value) -> bool {
    let api_version = manifest
        .get("apiVersion")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let Some((group, _)) = api_version.split_once('/') else {
        return true;
    };
    BUILTIN_GROUPS.contains(&group)
        || BUILTIN_GROUP_SUFFIXES.iter().any(|s| group.ends_with(s))
        || group == super::keys::GROUP
}

/// API groups whose kinds Kix treats as built-in, besides the core group and
/// Kix's own. The library reads the same lists from
/// `kix/lib/core/api-groups.json` (`facts.isForeignGroup`), and a test in
/// `cluster/migrate.rs` checks that the two agree.
pub const BUILTIN_GROUPS: &[&str] = &["apps", "batch", "policy", "autoscaling"];

/// Suffixes of API groups whose kinds Kix treats as built-in.
pub const BUILTIN_GROUP_SUFFIXES: &[&str] = &[".k8s.io"];

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
    pub(crate) fn from_filename(filename: &str) -> Option<Self> {
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
    pub(crate) fn from_nested_path(ns_dir: &str, filename: &str) -> Option<Self> {
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

    /// Return `"Kind/name@namespace"` (or `"Kind/name"` when cluster-scoped)
    /// without escaping control characters. Use `Display` for user-facing output.
    pub fn display_id(&self) -> String {
        if self.namespace == CLUSTER_SCOPED {
            format!("{}/{}", self.kind, self.name)
        } else {
            format!("{}/{}@{}", self.kind, self.name, self.namespace)
        }
    }
}

/// Format `"Kind/name@namespace"` for user-facing output, passing each segment
/// through [`crate::text::printable`].
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
