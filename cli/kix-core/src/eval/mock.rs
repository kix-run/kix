//! Mock builder for this crate's tests.
//!
//! Returns canned responses without any real Nix evaluation.

use std::collections::HashMap;
use std::path::Path;

use serde_json::Value;

use super::error::KixEvalError;
use super::evaluator::{Builder, ClusterOutput, ClusterPackageInfo, PackageInfo};

/// Mock builder that returns pre-configured cluster data.
pub(crate) struct MockBuilder {
    clusters: HashMap<String, Vec<Value>>,
}

impl MockBuilder {
    /// Create an empty mock backend.
    pub(crate) fn new() -> Self {
        Self {
            clusters: HashMap::new(),
        }
    }

    /// Register a cluster with its manifest data.
    pub(crate) fn add_cluster(&mut self, name: &str, manifests: Vec<Value>) {
        self.clusters.insert(name.to_string(), manifests);
    }
}

impl Default for MockBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl Builder for MockBuilder {
    fn eval_cluster(
        &mut self,
        _flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
        let manifests = self
            .clusters
            .get(cluster_name)
            .ok_or_else(|| KixEvalError::ClusterNotFound {
                name: cluster_name.to_string(),
            })?
            .clone();

        Ok(ClusterOutput {
            name: cluster_name.to_string(),
            raw_manifests: manifests,
            scorecard_report: None,
            extra_images: None,
            warnings: Vec::new(),
        })
    }

    fn list_clusters(&mut self, _flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
        let mut names: Vec<String> = self.clusters.keys().cloned().collect();
        names.sort();
        Ok(names)
    }

    fn list_packages(
        &mut self,
        _flake_path: &Path,
    ) -> Result<std::collections::BTreeMap<String, PackageInfo>, KixEvalError> {
        Ok(std::collections::BTreeMap::new())
    }

    fn list_cluster_packages(
        &mut self,
        _flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterPackageInfo, KixEvalError> {
        if !self.clusters.contains_key(cluster_name) {
            return Err(KixEvalError::ClusterNotFound {
                name: cluster_name.to_string(),
            });
        }
        Ok(ClusterPackageInfo {
            instances: std::collections::BTreeMap::new(),
            available_packages: std::collections::BTreeMap::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn mock_returns_registered_cluster() {
        let mut backend = MockBuilder::new();
        backend.add_cluster(
            "test",
            vec![json!({"kind": "Namespace", "metadata": {"name": "test"}})],
        );

        let output = backend.eval_cluster(Path::new("."), "test").unwrap();
        assert_eq!(output.name, "test");
        assert_eq!(output.raw_manifests.len(), 1);
    }
}
