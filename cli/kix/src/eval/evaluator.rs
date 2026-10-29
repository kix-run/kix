//! Core evaluator: trait-based Nix backend abstraction with caching.
//!
//! The `NixBackend` trait has two implementations: `CliNixBackend`, which
//! runs the `nix` command, and `MockNixBackend` in this crate's tests.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::cache::SqliteCache;
use super::error::KixEvalError;

/// Output from evaluating a cluster.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterOutput {
    /// The flake attribute the cluster was evaluated as (e.g. "nw1"). See
    /// [`Self::cluster_name`] for the name its records carry.
    pub name: String,
    /// Raw K8s manifests as JSON values (one per resource).
    pub raw_manifests: Vec<Value>,
    /// Scorecard findings from Nix evaluation (None if scorecard disabled).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scorecard_report: Option<Value>,
    /// Extra images declared by packages (operator-spawned, not in manifests).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra_images: Option<Vec<ExtraImage>>,
}

impl ClusterOutput {
    /// Return the cluster name passed to `buildCluster`, read from the
    /// `kix.run/cluster` label on the build's Activation record.
    ///
    /// This name identifies the cluster's records on Kubernetes and in the
    /// activation cache. It differs from [`Self::name`] when a flake maps an
    /// attribute like `clusters.harbor = ./test-harbor.nix` to a cluster
    /// definition that sets `name = "test-harbor"`. Returns `None` when the
    /// build has no Activation record.
    pub fn cluster_name(&self) -> Option<&str> {
        crate::manifest::lifecycle::record_of(&self.raw_manifests)?
            .pointer("/metadata/labels")?
            .get(crate::manifest::keys::CLUSTER_LABEL)?
            .as_str()
    }
}

/// An extra image declared by a package via `root.out.extraImages`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtraImage {
    pub image: String,
    pub source: ExtraImageSource,
}

/// Where an extra image declaration came from.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtraImageSource {
    pub kind: String,
    pub namespace: String,
    pub name: String,
    pub container: String,
}

/// Version info for a package in the global registry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageInfo {
    pub version: Option<String>,
    pub owner: Option<String>,
}

/// Version + auto-instantiation info for a cluster instance.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceInfo {
    pub version: Option<String>,
    pub owner: Option<String>,
    #[serde(default)]
    pub auto: bool,
    #[serde(default, rename = "isImport")]
    pub is_import: bool,
}

/// Per-cluster package metadata (instances + available packages).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClusterPackageInfo {
    /// Nested: namespace → instance name → info
    pub instances:
        std::collections::BTreeMap<String, std::collections::BTreeMap<String, InstanceInfo>>,
    /// Available packages (may include packages not yet instantiated)
    #[serde(rename = "availablePackages")]
    pub available_packages: std::collections::BTreeMap<String, PackageInfo>,
}

/// Abstraction over Nix evaluation: the `nix` command in production, canned
/// data in tests.
pub trait NixBackend: Send {
    /// Evaluate a cluster attribute and return its manifests.
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError>;

    /// List available cluster names in the flake.
    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError>;

    /// List all packages in the flake with version info.
    fn list_packages(
        &mut self,
        flake_path: &Path,
    ) -> Result<std::collections::BTreeMap<String, PackageInfo>, KixEvalError>;

    /// List instances and available packages for a specific cluster.
    fn list_cluster_packages(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterPackageInfo, KixEvalError>;
}

/// Evaluator wrapping a `NixBackend`.
pub struct KixEvaluator {
    backend: Box<dyn NixBackend>,
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
        let flake_path = super::store::resolve_symlinks(flake_path);
        tracing::debug!(flake = %flake_path.display(), "evaluator created");
        Ok(Self {
            backend: Box::new(backend),
            cache,
            flake_path,
        })
    }

    /// Create a new evaluator that never reads from cache.
    ///
    /// Uses an ephemeral in-memory SQLite database, so every evaluation
    /// goes straight to Nix. Useful for debugging stale-cache issues.
    pub fn new_uncached(
        backend: impl NixBackend + 'static,
        flake_path: &Path,
    ) -> Result<Self, KixEvalError> {
        let cache = SqliteCache::open_in_memory()?;
        let flake_path = super::store::resolve_symlinks(flake_path);
        tracing::debug!(flake = %flake_path.display(), "evaluator created (no cache)");
        Ok(Self {
            backend: Box::new(backend),
            cache,
            flake_path,
        })
    }

    /// Evaluate a cluster, returning cached results when source files are unchanged.
    ///
    /// Cache key includes a source fingerprint computed from all `.nix` files in the
    /// flake directory tree. File additions, removals, or content changes invalidate
    /// the cache automatically.
    pub fn eval_cluster(&mut self, cluster_name: &str) -> Result<ClusterOutput, KixEvalError> {
        let start = std::time::Instant::now();
        tracing::debug!(cluster = cluster_name, "evaluating");

        let fingerprint = self.cache.compute_source_fingerprint(&self.flake_path)?;
        let cache_key =
            SqliteCache::compute_key_with_source(&self.flake_path, cluster_name, &fingerprint)?;

        if let Some(cached_json) = self.cache.get(&cache_key)? {
            if let Ok(output) = serde_json::from_str::<ClusterOutput>(&cached_json) {
                tracing::info!(cluster = cluster_name, elapsed = ?start.elapsed(), "cache hit");
                return Ok(output);
            }
            tracing::warn!(
                cluster = cluster_name,
                "corrupted cache entry, re-evaluating"
            );
        }

        let output = self.backend.eval_cluster(&self.flake_path, cluster_name)?;

        // Cache writes are non-fatal because evaluation already succeeded. A
        // write failure, such as a full disk or insufficient permissions,
        // just means the next invocation will re-evaluate instead of hitting cache.
        if let Ok(json) = serde_json::to_string(&output)
            && let Err(e) = self.cache.put(&cache_key, &json)
        {
            tracing::warn!(cluster = cluster_name, error = %e, "failed to cache result");
        }

        tracing::info!(cluster = cluster_name, elapsed = ?start.elapsed(), "evaluation complete");
        Ok(output)
    }

    /// List available clusters, with source-fingerprint caching.
    pub fn list_clusters(&mut self) -> Result<Vec<String>, KixEvalError> {
        let start = std::time::Instant::now();

        let fingerprint = self.cache.compute_source_fingerprint(&self.flake_path)?;
        let cache_key = SqliteCache::compute_key_with_source(
            &self.flake_path,
            "__list_clusters",
            &fingerprint,
        )?;

        if let Some(cached_json) = self.cache.get(&cache_key)? {
            if let Ok(names) = serde_json::from_str::<Vec<String>>(&cached_json) {
                tracing::info!(elapsed = ?start.elapsed(), "list_clusters cache hit");
                return Ok(names);
            }
            tracing::warn!("corrupted list_clusters cache entry, re-evaluating");
        }

        let names = self.backend.list_clusters(&self.flake_path)?;

        if let Ok(json) = serde_json::to_string(&names)
            && let Err(e) = self.cache.put(&cache_key, &json)
        {
            tracing::warn!(error = %e, "failed to cache list_clusters result");
        }

        tracing::info!(elapsed = ?start.elapsed(), "list_clusters complete");
        Ok(names)
    }

    /// List all packages with version info, with source-fingerprint caching.
    pub fn list_packages(
        &mut self,
    ) -> Result<std::collections::BTreeMap<String, PackageInfo>, KixEvalError> {
        let start = std::time::Instant::now();

        let fingerprint = self.cache.compute_source_fingerprint(&self.flake_path)?;
        let cache_key = SqliteCache::compute_key_with_source(
            &self.flake_path,
            "__list_packages",
            &fingerprint,
        )?;

        if let Some(cached_json) = self.cache.get(&cache_key)? {
            if let Ok(packages) = serde_json::from_str::<
                std::collections::BTreeMap<String, PackageInfo>,
            >(&cached_json)
            {
                tracing::info!(elapsed = ?start.elapsed(), "list_packages cache hit");
                return Ok(packages);
            }
            tracing::warn!("corrupted list_packages cache entry, re-evaluating");
        }

        let packages = self.backend.list_packages(&self.flake_path)?;

        if let Ok(json) = serde_json::to_string(&packages)
            && let Err(e) = self.cache.put(&cache_key, &json)
        {
            tracing::warn!(error = %e, "failed to cache list_packages result");
        }

        tracing::info!(elapsed = ?start.elapsed(), "list_packages complete");
        Ok(packages)
    }

    /// List instances and available packages for a cluster, with caching.
    pub fn list_cluster_packages(
        &mut self,
        cluster_name: &str,
    ) -> Result<ClusterPackageInfo, KixEvalError> {
        let start = std::time::Instant::now();

        let fingerprint = self.cache.compute_source_fingerprint(&self.flake_path)?;
        let cache_key = SqliteCache::compute_key_with_source(
            &self.flake_path,
            &format!("__cluster_packages_{cluster_name}"),
            &fingerprint,
        )?;

        if let Some(cached_json) = self.cache.get(&cache_key)? {
            if let Ok(info) = serde_json::from_str::<ClusterPackageInfo>(&cached_json) {
                tracing::info!(
                    cluster = cluster_name,
                    elapsed = ?start.elapsed(),
                    "list_cluster_packages cache hit"
                );
                return Ok(info);
            }
            tracing::warn!("corrupted list_cluster_packages cache entry, re-evaluating");
        }

        let info = self
            .backend
            .list_cluster_packages(&self.flake_path, cluster_name)?;

        if let Ok(json) = serde_json::to_string(&info)
            && let Err(e) = self.cache.put(&cache_key, &json)
        {
            tracing::warn!(error = %e, "failed to cache list_cluster_packages result");
        }

        tracing::info!(
            cluster = cluster_name,
            elapsed = ?start.elapsed(),
            "list_cluster_packages complete"
        );
        Ok(info)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::mock::MockNixBackend;
    use serde_json::json;

    #[test]
    fn cluster_name_is_the_record_label_not_the_attribute() {
        let output = |manifests: Vec<Value>| ClusterOutput {
            name: "harbor".into(),
            raw_manifests: manifests,
            scorecard_report: None,
            extra_images: None,
        };
        let record = json!({
            "apiVersion": format!("{}/v1alpha1", crate::manifest::keys::DOMAIN),
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": {
                "name": "test-harbor-abc",
                "labels": { (crate::manifest::keys::CLUSTER_LABEL): "test-harbor" }
            }
        });
        let ns = json!({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "x"}});
        assert_eq!(
            output(vec![ns.clone(), record]).cluster_name(),
            Some("test-harbor")
        );
        assert_eq!(output(vec![ns]).cluster_name(), None);
    }

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
    fn eval_cluster_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let cache_dir = dir.path().join("cache");
        let mut eval = KixEvaluator::new(test_backend(), dir.path(), &cache_dir).unwrap();
        let err = eval.eval_cluster("nonexistent").unwrap_err();
        assert!(matches!(err, KixEvalError::ClusterNotFound { .. }));
    }
}
