//! Core manifest types.

use serde::{Deserialize, Serialize};

/// Unique identifier for a K8s resource.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
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
                .unwrap_or("_cluster")
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

    /// Produce the flat filename: `{ns}--{name}-{kind}.yaml`
    pub fn to_flat_filename(&self) -> String {
        format!("{}--{}-{}.yaml", self.namespace, self.name, self.kind)
    }

    /// Display as "Kind/name@namespace".
    pub fn display_id(&self) -> String {
        if self.namespace == "_cluster" {
            format!("{}/{}", self.kind, self.name)
        } else {
            format!("{}/{}@{}", self.kind, self.name, self.namespace)
        }
    }
}

impl std::fmt::Display for ResourceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.display_id())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_filename_basic() {
        let rid = ResourceId::from_filename("kube-system--coredns-deployment.yaml").unwrap();
        assert_eq!(rid.namespace, "kube-system");
        assert_eq!(rid.name, "coredns");
        assert_eq!(rid.kind, "deployment");
    }

    #[test]
    fn from_filename_cluster_scoped() {
        let rid = ResourceId::from_filename("_cluster--cert-manager-clusterrole.yaml").unwrap();
        assert_eq!(rid.namespace, "_cluster");
        assert_eq!(rid.name, "cert-manager");
        assert_eq!(rid.kind, "clusterrole");
    }

    #[test]
    fn from_filename_name_with_dashes() {
        let rid = ResourceId::from_filename(
            "arc-system--arc-controller-gha-rs-controller-deployment.yaml",
        )
        .unwrap();
        assert_eq!(rid.namespace, "arc-system");
        assert_eq!(rid.name, "arc-controller-gha-rs-controller");
        assert_eq!(rid.kind, "deployment");
    }

    #[test]
    fn from_filename_missing_yaml_extension() {
        assert!(ResourceId::from_filename("ns--name-kind.yml").is_none());
    }

    #[test]
    fn from_filename_no_double_dash() {
        assert!(ResourceId::from_filename("ns-name-kind.yaml").is_none());
    }

    #[test]
    fn from_filename_empty_segments() {
        assert!(ResourceId::from_filename("--name-kind.yaml").is_none());
        assert!(ResourceId::from_filename("ns---kind.yaml").is_none());
    }

    #[test]
    fn from_nested_path_basic() {
        let rid = ResourceId::from_nested_path("kube-system", "coredns-deployment.yaml").unwrap();
        assert_eq!(rid.namespace, "kube-system");
        assert_eq!(rid.name, "coredns");
        assert_eq!(rid.kind, "deployment");
    }

    #[test]
    fn from_nested_path_name_with_dashes() {
        let rid =
            ResourceId::from_nested_path("monitoring-system", "kube-state-metrics-deployment.yaml")
                .unwrap();
        assert_eq!(rid.namespace, "monitoring-system");
        assert_eq!(rid.name, "kube-state-metrics");
        assert_eq!(rid.kind, "deployment");
    }

    #[test]
    fn from_nested_path_invalid() {
        assert!(ResourceId::from_nested_path("ns", "nodash.yaml").is_none());
        assert!(ResourceId::from_nested_path("", "name-kind.yaml").is_none());
    }

    #[test]
    fn to_flat_filename_roundtrip() {
        let rid = ResourceId {
            kind: "deployment".into(),
            namespace: "kube-system".into(),
            name: "coredns".into(),
        };
        assert_eq!(
            rid.to_flat_filename(),
            "kube-system--coredns-deployment.yaml"
        );

        // roundtrip
        let parsed = ResourceId::from_filename(&rid.to_flat_filename()).unwrap();
        assert_eq!(parsed, rid);
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

    #[test]
    fn display_cluster_scoped() {
        let rid = ResourceId {
            kind: "clusterrole".into(),
            namespace: "_cluster".into(),
            name: "admin".into(),
        };
        assert_eq!(rid.to_string(), "clusterrole/admin");
    }

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
        assert_eq!(rid.namespace, "_cluster");
    }
}
