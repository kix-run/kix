//! Mock Nix backend for testing.
//!
//! Returns canned responses without any real Nix evaluation.
//! Commands can use this for downstream testing
//! without a Nix installation.

use std::collections::HashMap;
use std::path::Path;

use serde_json::Value;

use super::error::KixEvalError;
use super::evaluator::{ClusterOutput, ClusterPackageInfo, NixBackend, PackageInfo};

/// Mock backend that returns pre-configured cluster data.
pub struct MockNixBackend {
    clusters: HashMap<String, Vec<Value>>,
    call_count: usize,
    call_limit: Option<usize>,
}

impl MockNixBackend {
    /// Create an empty mock backend.
    pub fn new() -> Self {
        Self {
            clusters: HashMap::new(),
            call_count: 0,
            call_limit: None,
        }
    }

    /// Register a cluster with its manifest data.
    pub fn add_cluster(&mut self, name: &str, manifests: Vec<Value>) {
        self.clusters.insert(name.to_string(), manifests);
    }

    /// Set a maximum number of eval calls allowed (for cache testing).
    /// After this limit, `eval_cluster` will panic.
    pub fn set_call_limit(&mut self, limit: usize) {
        self.call_limit = Some(limit);
    }

    /// Load cluster data from a JSON file. The file should contain an array
    /// of K8s manifest objects.
    pub fn add_cluster_from_file(&mut self, name: &str, path: &Path) -> Result<(), KixEvalError> {
        let contents = std::fs::read_to_string(path).map_err(|e| KixEvalError::EvalFailed {
            flake: path.display().to_string(),
            attr: name.to_string(),
            source: e.into(),
        })?;
        let manifests: Vec<Value> =
            serde_json::from_str(&contents).map_err(|e| KixEvalError::EvalFailed {
                flake: path.display().to_string(),
                attr: name.to_string(),
                source: e.into(),
            })?;
        self.clusters.insert(name.to_string(), manifests);
        Ok(())
    }
}

impl Default for MockNixBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl NixBackend for MockNixBackend {
    fn eval_cluster(
        &mut self,
        _flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
        if let Some(limit) = self.call_limit
            && self.call_count >= limit
        {
            panic!(
                "MockNixBackend: eval_cluster called {} times, limit is {limit}",
                self.call_count + 1
            );
        }
        self.call_count += 1;

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
        let mut backend = MockNixBackend::new();
        backend.add_cluster(
            "test",
            vec![json!({"kind": "Namespace", "metadata": {"name": "test"}})],
        );

        let output = backend.eval_cluster(Path::new("."), "test").unwrap();
        assert_eq!(output.name, "test");
        assert_eq!(output.raw_manifests.len(), 1);
    }
}
