//! Core evaluator: trait-based Nix backend abstraction with caching.
//!
//! The `NixBackend` trait allows swapping between:
//! - `MockNixBackend` (for testing, available now)
//! - A real FFI backend using `nix-bindings-*` crates (added in Step 9)

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::cache::SqliteCache;
use crate::error::KixEvalError;

/// Output from evaluating a cluster.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterOutput {
    /// Cluster name (e.g. "nw1").
    pub name: String,
    /// Raw K8s manifests as JSON values (one per resource).
    pub raw_manifests: Vec<Value>,
}

/// Abstraction over Nix evaluation. Implementations provide either real
/// FFI evaluation or mock/test data.
pub trait NixBackend: Send {
    /// Evaluate a cluster attribute and return its manifests.
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError>;

    /// List available cluster names in the flake.
    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError>;
}

/// Evaluator wrapping a `NixBackend`.
pub struct KixEvaluator {
    backend: Box<dyn NixBackend>,
    #[allow(dead_code)] // Cache disabled pending file-level invalidation
    cache: SqliteCache,
    /// The flake path to evaluate (resolved, no symlinks).
    flake_path: PathBuf,
}

impl KixEvaluator {
    /// Create a new evaluator with the given backend and cache directory.
    pub fn new(
        backend: impl NixBackend + 'static,
        flake_path: &Path,
        cache_dir: &Path,
    ) -> Result<Self, KixEvalError> {
        let db_path = cache_dir.join("eval-cache.db");
        let cache = SqliteCache::open(&db_path)?;
        let flake_path = crate::store::resolve_symlinks(flake_path);
        tracing::debug!(flake = %flake_path.display(), "evaluator created");
        Ok(Self {
            backend: Box::new(backend),
            cache,
            flake_path,
        })
    }

    /// Evaluate a cluster.
    ///
    /// Caching is disabled: the cache key (flake_path + flake.lock + attr) doesn't
    /// track individual .nix source files, so edits to cluster/package/lib files
    /// returned stale results. Re-enable when we have file-level invalidation.
    pub fn eval_cluster(&mut self, cluster_name: &str) -> Result<ClusterOutput, KixEvalError> {
        let start = std::time::Instant::now();
        tracing::debug!(cluster = cluster_name, "evaluating");
        let output = self.backend.eval_cluster(&self.flake_path, cluster_name)?;
        tracing::info!(cluster = cluster_name, elapsed = ?start.elapsed(), "evaluation complete");
        Ok(output)
    }

    /// List available clusters (not cached — cheap operation).
    pub fn list_clusters(&mut self) -> Result<Vec<String>, KixEvalError> {
        self.backend.list_clusters(&self.flake_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockNixBackend;
    use serde_json::json;

    fn test_backend() -> MockNixBackend {
        let mut backend = MockNixBackend::new();
        backend.add_cluster(
            "test-cluster",
            vec![json!({
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": { "name": "test" }
            })],
        );
        backend
    }

    #[test]
    fn eval_returns_cluster_output() {
        let dir = tempfile::tempdir().unwrap();
        let cache_dir = dir.path().join("cache");
        let mut eval = KixEvaluator::new(test_backend(), dir.path(), &cache_dir).unwrap();
        let output = eval.eval_cluster("test-cluster").unwrap();
        assert_eq!(output.name, "test-cluster");
        assert_eq!(output.raw_manifests.len(), 1);
    }

    #[test]
    fn eval_returns_consistent_results() {
        let dir = tempfile::tempdir().unwrap();
        let cache_dir = dir.path().join("cache");
        let mut eval = KixEvaluator::new(test_backend(), dir.path(), &cache_dir).unwrap();

        let out1 = eval.eval_cluster("test-cluster").unwrap();
        let out2 = eval.eval_cluster("test-cluster").unwrap();
        assert_eq!(out1.name, out2.name);
        assert_eq!(out1.raw_manifests.len(), out2.raw_manifests.len());
    }

    #[test]
    fn list_clusters_delegates_to_backend() {
        let dir = tempfile::tempdir().unwrap();
        let cache_dir = dir.path().join("cache");
        let mut eval = KixEvaluator::new(test_backend(), dir.path(), &cache_dir).unwrap();
        let clusters = eval.list_clusters().unwrap();
        assert_eq!(clusters, vec!["test-cluster"]);
    }

    #[test]
    fn eval_cluster_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let cache_dir = dir.path().join("cache");
        let mut eval = KixEvaluator::new(test_backend(), dir.path(), &cache_dir).unwrap();
        let err = eval.eval_cluster("nonexistent").unwrap_err();
        assert!(matches!(err, KixEvalError::ClusterNotFound { .. }));
    }
}
