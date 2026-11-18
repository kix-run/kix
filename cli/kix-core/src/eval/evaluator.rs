//! Core evaluator: the [`Builder`] trait with a cache in front of it.
//!
//! The `Builder` trait has two implementations: `LocalBuilder`, which
//! runs the `nix` command, and `MockBuilder` in this crate's tests.

use std::path::{Path, PathBuf};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::cache::FileCache;
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
    /// The Kix library's warnings that are not scorecard findings
    /// ([`crate::build_source::Build::warnings`]).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<super::library_record::LibraryRecord>,
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

/// Build a project's clusters and list what it defines.
///
/// Each builder a project can choose in `kix.toml` implements this trait,
/// and commands use the trait without asking which builder is in use. A
/// result can name store paths. The builder must make every path it names
/// available in the local store before it returns, wherever it did the work.
pub trait Builder: Send {
    /// Return a value that identifies everything an evaluation of the flake
    /// at `flake_path` reads, or `None` when the builder cannot tell. Two
    /// evaluations of one attribute under the same fingerprint must give the
    /// same result, because the evaluator returns a cached result for a
    /// fingerprint it has seen.
    fn source_fingerprint(&mut self, flake_path: &Path) -> Option<String>;

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

/// Evaluator wrapping a [`Builder`].
pub struct KixEvaluator {
    backend: Box<dyn Builder>,
    /// `None` evaluates every request from source.
    cache: Option<FileCache>,
    /// The flake path to evaluate (resolved, no symlinks).
    flake_path: PathBuf,
    /// The flake's fingerprint as the builder last gave it, once asked.
    fingerprint: Option<Option<String>>,
}

impl KixEvaluator {
    /// Create a new evaluator that caches results under `cache_dir`.
    pub fn new(
        backend: impl Builder + 'static,
        flake_path: &Path,
        cache_dir: &Path,
    ) -> Result<Self, KixEvalError> {
        let flake_path = super::store::resolve_symlinks(flake_path);
        tracing::debug!(flake = %flake_path.display(), "evaluator created");
        Ok(Self {
            backend: Box::new(backend),
            cache: Some(FileCache::open(cache_dir)),
            flake_path,
            fingerprint: None,
        })
    }

    /// Create a new evaluator that neither reads nor writes the cache, so
    /// every evaluation goes straight to Nix.
    pub fn new_uncached(
        backend: impl Builder + 'static,
        flake_path: &Path,
    ) -> Result<Self, KixEvalError> {
        let flake_path = super::store::resolve_symlinks(flake_path);
        tracing::debug!(flake = %flake_path.display(), "evaluator created (no cache)");
        Ok(Self {
            backend: Box::new(backend),
            cache: None,
            flake_path,
            fingerprint: None,
        })
    }

    /// Return the cached value of `attr`, or run `eval` and cache its result.
    ///
    /// The cache key holds the builder's fingerprint of the flake's source,
    /// so a change to any file the evaluation reads gives a new entry.
    fn cached<T: Serialize + DeserializeOwned>(
        &mut self,
        attr: &str,
        eval: impl FnOnce(&mut dyn Builder, &Path) -> Result<T, KixEvalError>,
    ) -> Result<T, KixEvalError> {
        let start = std::time::Instant::now();
        let Some(cache) = &self.cache else {
            let value = eval(self.backend.as_mut(), &self.flake_path)?;
            tracing::info!(attr, elapsed = ?start.elapsed(), "evaluation complete");
            return Ok(value);
        };
        let fingerprint = match &self.fingerprint {
            Some(known) => known.clone(),
            None => self.backend.source_fingerprint(&self.flake_path),
        };
        let lookup = cache.lookup(&self.flake_path, attr, fingerprint.as_deref());
        if let Some(json) = &lookup.hit {
            match serde_json::from_str::<T>(json) {
                Ok(value) => {
                    self.fingerprint = Some(fingerprint);
                    tracing::info!(attr, elapsed = ?start.elapsed(), "cache hit");
                    return Ok(value);
                }
                Err(e) => {
                    tracing::warn!(attr, error = %e, "discarding an unreadable eval cache entry and evaluating from source")
                }
            }
        }

        let value = eval(self.backend.as_mut(), &self.flake_path)?;

        // A file may have changed while the evaluation ran. The result then
        // belongs to neither fingerprint for certain, so it is not stored.
        let after = self.backend.source_fingerprint(&self.flake_path);
        if after == fingerprint {
            let stored = serde_json::to_string(&value)
                .map_err(std::io::Error::other)
                .and_then(|json| cache.store(&lookup, &json));
            if let Err(e) = stored {
                tracing::warn!(attr, error = %e, "could not write to the eval cache; continuing with the evaluated result");
            }
        } else {
            tracing::debug!(
                attr,
                "the flake's source changed during the evaluation; result not cached"
            );
        }
        self.fingerprint = Some(after);
        tracing::info!(attr, elapsed = ?start.elapsed(), "evaluation complete");
        Ok(value)
    }

    /// Evaluate a cluster, returning the cached result when the source is unchanged.
    pub fn eval_cluster(&mut self, cluster_name: &str) -> Result<ClusterOutput, KixEvalError> {
        tracing::debug!(cluster = cluster_name, "evaluating");
        self.cached(
            &super::nix::activation_index_attr(cluster_name),
            |b, flake| b.eval_cluster(flake, cluster_name),
        )
    }

    /// List available clusters.
    pub fn list_clusters(&mut self) -> Result<Vec<String>, KixEvalError> {
        self.cached("__list_clusters", |b, flake| b.list_clusters(flake))
    }

    /// List all packages with version info.
    pub fn list_packages(
        &mut self,
    ) -> Result<std::collections::BTreeMap<String, PackageInfo>, KixEvalError> {
        self.cached("__list_packages", |b, flake| b.list_packages(flake))
    }

    /// List instances and available packages for a cluster.
    pub fn list_cluster_packages(
        &mut self,
        cluster_name: &str,
    ) -> Result<ClusterPackageInfo, KixEvalError> {
        self.cached(&format!("__cluster_packages_{cluster_name}"), |b, flake| {
            b.list_cluster_packages(flake, cluster_name)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::mock::MockBuilder;
    use serde_json::json;

    #[test]
    fn cluster_name_is_the_record_label_not_the_attribute() {
        let output = |manifests: Vec<Value>| ClusterOutput {
            name: "harbor".into(),
            raw_manifests: manifests,
            scorecard_report: None,
            extra_images: None,
            warnings: Vec::new(),
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

    fn test_backend() -> MockBuilder {
        let mut backend = MockBuilder::new();
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

    /// Evaluate `test-cluster` with a new evaluator over the same cache, as
    /// a second run of Kix would, and return how many evaluations ran.
    fn run(dir: &Path, fingerprint: Option<&str>, after_eval: Option<&str>) -> usize {
        let mut backend = test_backend();
        backend.fingerprint = fingerprint.map(str::to_string);
        backend.fingerprint_after_eval = after_eval.map(str::to_string);
        let evaluations = backend.evaluations.clone();
        let mut eval = KixEvaluator::new(backend, dir, &dir.join("cache")).unwrap();
        eval.eval_cluster("test-cluster").unwrap();
        evaluations.load(std::sync::atomic::Ordering::Relaxed)
    }

    #[test]
    fn an_unchanged_fingerprint_skips_the_evaluation() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(run(dir.path(), Some("f1"), None), 1);
        assert_eq!(run(dir.path(), Some("f1"), None), 0);
    }

    #[test]
    fn a_changed_fingerprint_evaluates_again() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(run(dir.path(), Some("f1"), None), 1);
        assert_eq!(run(dir.path(), Some("f2"), None), 1);
        assert_eq!(run(dir.path(), Some("f2"), None), 0);
    }

    #[test]
    fn a_flake_with_no_fingerprint_evaluates_every_time() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(run(dir.path(), None, None), 1);
        assert_eq!(run(dir.path(), None, None), 1);
    }

    #[test]
    fn a_result_is_not_cached_when_the_source_changed_during_the_evaluation() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(run(dir.path(), Some("f1"), Some("f2")), 1);
        assert_eq!(run(dir.path(), Some("f1"), None), 1);
        assert_eq!(run(dir.path(), Some("f2"), None), 1);
    }
}
