//! Store graph: in-memory representation of a kix cluster's Nix store DAG.
//!
//! Reads the result folder produced by `nix build .#cluster-<name>-activation`
//! (containing `activation` symlink + `kix-packages.json`) and builds a
//! complete graph of packages, resources, and cross-package dependencies.
//!
//! Uses `nix-store -q --graph` for bulk graph loading (one subprocess call
//! for the entire closure) instead of per-path `--references` queries.
//!
//! This is the Rust equivalent of `tools/lib/kix_model.py`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

use crate::error::KixEvalError;

/// Loaded from kix-packages.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KixPackageIndex {
    pub cluster: String,
    /// PI store path → owned resource store paths.
    pub packages: IndexMap<PathBuf, Vec<PathBuf>>,
}

/// Full in-memory graph built from the result folder.
#[derive(Debug, Clone)]
pub struct StoreGraph {
    pub cluster_name: String,
    pub activation_path: PathBuf,
    pub packages: IndexMap<PathBuf, PackageNode>,
    pub resources: HashMap<PathBuf, ResourceNode>,
    /// resource store path → owning PI store path.
    pub resource_owner: HashMap<PathBuf, PathBuf>,
    /// Cached store references: path → direct references.
    /// Populated by bulk_load_graph, reusable by stamp_annotations.
    pub ref_cache: HashMap<PathBuf, Vec<PathBuf>>,
}

#[derive(Debug, Clone)]
pub struct PackageNode {
    pub store_path: PathBuf,
    /// From the PI manifest: spec.instanceName
    pub instance_name: String,
    /// From the PI manifest: metadata.namespace
    pub namespace: String,
    /// From the PI manifest: spec.version
    pub version: Option<String>,
    /// Ordered list of owned resource store paths.
    pub resource_paths: Vec<PathBuf>,
    /// Cross-package dependency edges (computed from store refs).
    pub cross_deps: Vec<CrossDep>,
}

#[derive(Debug, Clone)]
pub struct ResourceNode {
    pub store_path: PathBuf,
    /// Raw K8s manifest parsed from the store path file.
    pub manifest: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrossDep {
    /// "Kind/name" of the resource in this package that has the dep.
    pub from_resource: String,
    /// "Kind/name" of the target resource.
    pub to_resource: String,
    /// Store path of the target PackageInstance.
    pub target_package: PathBuf,
}

/// Bulk-load the entire dependency graph with one `nix-store -q --graph` call.
/// Parses the dot output and returns a map of path → direct references.
fn bulk_load_graph(root_path: &Path) -> HashMap<PathBuf, Vec<PathBuf>> {
    let output = Command::new("nix-store")
        .args(["-q", "--graph"])
        .arg(root_path)
        .output();

    let out = match output {
        Ok(o) if o.status.success() => o,
        _ => return HashMap::new(),
    };

    let stdout = String::from_utf8_lossy(&out.stdout);
    let nix_store = "/nix/store/";
    let mut deps: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();

    for line in stdout.lines() {
        let line = line.trim();
        if !line.contains("->") {
            continue;
        }
        let Some((src_part, dst_part)) = line.split_once("->") else {
            continue;
        };
        let src_base = src_part.trim().trim_matches('"').trim();
        let dst_base = dst_part
            .split('[')
            .next()
            .unwrap_or("")
            .trim()
            .trim_matches('"')
            .trim()
            .trim_end_matches(';');

        if src_base.is_empty() || dst_base.is_empty() {
            continue;
        }

        let src = PathBuf::from(format!("{nix_store}{src_base}"));
        let dst = PathBuf::from(format!("{nix_store}{dst_base}"));

        // In dot output, edge is "src -> dst" meaning src depends on dst
        // (dst is a reference of src)
        deps.entry(src).or_default().push(dst);
    }

    // Sort references for deterministic output
    for refs in deps.values_mut() {
        refs.sort_by(|a, b| {
            store_name(a)
                .to_lowercase()
                .cmp(&store_name(b).to_lowercase())
        });
    }

    deps
}

/// Extract the 32-char base32 hash from a Nix store path.
/// `/nix/store/<32-char-hash>-name` → first 32 chars of the filename.
pub fn store_hash(path: &Path) -> String {
    path.file_name()
        .and_then(|n| n.to_str())
        .filter(|n| n.len() >= 32)
        .map(|n| n[..32].to_string())
        .unwrap_or_default()
}

/// Human-readable part of a store path (after the hash-).
pub fn store_name(path: &Path) -> String {
    path.file_name()
        .and_then(|n| n.to_str())
        .filter(|n| n.len() > 33 && n.as_bytes()[32] == b'-')
        .map(|n| n[33..].to_string())
        .unwrap_or_else(|| path.display().to_string())
}

/// Check whether a store path is a kix k8s resource.
fn is_k8s_path(path: &Path) -> bool {
    store_name(path).starts_with("k8s-")
}

/// Read and parse a JSON file from a store path.
fn read_store_json(path: &Path) -> Result<serde_json::Value, KixEvalError> {
    let contents = std::fs::read_to_string(path).map_err(|e| KixEvalError::StoreGraphError {
        message: format!("failed to read store path {}: {e}", path.display()),
    })?;
    serde_json::from_str(&contents).map_err(|e| KixEvalError::StoreGraphError {
        message: format!("failed to parse JSON from {}: {e}", path.display()),
    })
}

/// Resource label: "Kind/name".
fn resource_label(manifest: &serde_json::Value) -> String {
    let kind = manifest
        .pointer("/kind")
        .and_then(|v| v.as_str())
        .unwrap_or("?");
    let name = manifest
        .pointer("/metadata/name")
        .and_then(|v| v.as_str())
        .unwrap_or("?");
    format!("{kind}/{name}")
}

impl StoreGraph {
    /// Build a StoreGraph from a result directory.
    ///
    /// `status_fn` is called with progress messages during loading.
    pub fn from_result_dir_with_status(
        result_dir: &Path,
        status_fn: &dyn Fn(&str),
    ) -> Result<Self, KixEvalError> {
        // 1. Read kix-packages.json
        status_fn("Reading package index...");
        let index_path = result_dir.join("kix-packages.json");
        let index: KixPackageIndex = {
            let contents = std::fs::read_to_string(&index_path).map_err(|e| {
                KixEvalError::StoreGraphError {
                    message: format!(
                        "failed to read kix-packages.json at {}: {e}",
                        index_path.display()
                    ),
                }
            })?;
            serde_json::from_str(&contents).map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to parse kix-packages.json: {e}"),
            })?
        };

        // 2. Resolve activation symlink
        let activation_link = result_dir.join("activation");
        let activation_path =
            std::fs::canonicalize(&activation_link).map_err(|e| KixEvalError::StoreGraphError {
                message: format!(
                    "failed to resolve activation symlink at {}: {e}",
                    activation_link.display()
                ),
            })?;

        // 3. Bulk-load the entire store graph in one nix-store call
        status_fn("Loading store graph...");
        let ref_cache = bulk_load_graph(&activation_path);

        // 4. Read manifests and build ownership
        let pkg_count = index.packages.len();
        status_fn(&format!("Reading {} packages...", pkg_count));

        let mut packages = IndexMap::new();
        let mut resources = HashMap::new();
        let mut resource_owner = HashMap::new();

        for (pi_path, resource_paths) in &index.packages {
            let pi_manifest = read_store_json(pi_path)?;
            let instance_name = pi_manifest
                .pointer("/spec/instanceName")
                .and_then(|v| v.as_str())
                .unwrap_or_else(|| {
                    tracing::warn!(pi = %pi_path.display(), "PI missing spec.instanceName");
                    "unknown"
                })
                .to_string();
            let namespace = pi_manifest
                .pointer("/metadata/namespace")
                .and_then(|v| v.as_str())
                .unwrap_or("_cluster")
                .to_string();
            let version = pi_manifest
                .pointer("/spec/version")
                .and_then(|v| v.as_str())
                .filter(|v| *v != "<undefined>")
                .map(|v| v.to_string());

            let mut valid_resource_paths = Vec::new();
            for res_path in resource_paths {
                if res_path == pi_path {
                    continue;
                }
                match read_store_json(res_path) {
                    Ok(manifest) => {
                        resource_owner.insert(res_path.clone(), pi_path.clone());
                        resources.insert(
                            res_path.clone(),
                            ResourceNode {
                                store_path: res_path.clone(),
                                manifest,
                            },
                        );
                        valid_resource_paths.push(res_path.clone());
                    }
                    Err(e) => {
                        tracing::warn!(path = %res_path.display(), error = %e, "skipping unreadable resource");
                    }
                }
            }

            packages.insert(
                pi_path.clone(),
                PackageNode {
                    store_path: pi_path.clone(),
                    instance_name,
                    namespace,
                    version,
                    resource_paths: valid_resource_paths,
                    cross_deps: vec![],
                },
            );
        }

        // 5. Compute cross-package dependencies using bulk-loaded graph
        status_fn("Computing cross-package dependencies...");
        for (pi_path, pkg) in packages.iter_mut() {
            let mut deps = Vec::new();
            for res_path in &pkg.resource_paths {
                let res = match resources.get(res_path) {
                    Some(r) => r,
                    None => continue,
                };
                let from_label = resource_label(&res.manifest);

                let empty = vec![];
                let refs = ref_cache.get(res_path).unwrap_or(&empty);
                for dep_ref in refs {
                    if !is_k8s_path(dep_ref) {
                        continue;
                    }
                    let dep_owner = match resource_owner.get(dep_ref) {
                        Some(o) => o,
                        None => continue,
                    };
                    if dep_owner == pi_path {
                        continue;
                    }
                    if let Some(dep_res) = resources.get(dep_ref) {
                        let dep_kind = dep_res
                            .manifest
                            .pointer("/kind")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if dep_kind == "Namespace" {
                            continue;
                        }
                        deps.push(CrossDep {
                            from_resource: from_label.clone(),
                            to_resource: resource_label(&dep_res.manifest),
                            target_package: dep_owner.clone(),
                        });
                    }
                }
            }
            pkg.cross_deps = deps;
        }

        Ok(StoreGraph {
            cluster_name: index.cluster,
            activation_path,
            packages,
            resources,
            resource_owner,
            ref_cache,
        })
    }

    /// Build a StoreGraph from a result directory (no progress callback).
    pub fn from_result_dir(result_dir: &Path) -> Result<Self, KixEvalError> {
        Self::from_result_dir_with_status(result_dir, &|_| {})
    }

    /// Look up which package owns a resource.
    pub fn package_for_resource(&self, res_path: &Path) -> Option<&PackageNode> {
        self.resource_owner
            .get(res_path)
            .and_then(|pi| self.packages.get(pi))
    }

    /// Get cross-package store references for a specific resource.
    /// Uses the bulk-loaded ref_cache — no subprocess calls.
    pub fn cross_pkg_refs(&self, res_path: &Path) -> Vec<PathBuf> {
        let owner = match self.resource_owner.get(res_path) {
            Some(o) => o,
            None => return vec![],
        };

        let empty = vec![];
        let refs = self.ref_cache.get(res_path).unwrap_or(&empty);

        refs.iter()
            .filter(|r| {
                is_k8s_path(r)
                    && self
                        .resource_owner
                        .get(r.as_path())
                        .is_some_and(|o| o != owner)
            })
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_hash_extracts_correctly() {
        let path = PathBuf::from("/nix/store/abc123def456ghi789jkl012mno345pq-k8s-Service-test");
        assert_eq!(store_hash(&path), "abc123def456ghi789jkl012mno345pq");
    }

    #[test]
    fn store_hash_short_path() {
        let path = PathBuf::from("/nix/store/short");
        assert_eq!(store_hash(&path), "");
    }

    #[test]
    fn store_name_extracts_correctly() {
        let path = PathBuf::from("/nix/store/abc123def456ghi789jkl012mno345pq-k8s-Service-test");
        assert_eq!(store_name(&path), "k8s-Service-test");
    }

    #[test]
    fn is_k8s_path_works() {
        assert!(is_k8s_path(Path::new(
            "/nix/store/abc123def456ghi789jkl012mno345pq-k8s-Service-test"
        )));
        assert!(!is_k8s_path(Path::new(
            "/nix/store/abc123def456ghi789jkl012mno345pq-python3-3.11"
        )));
    }

    #[test]
    fn resource_label_formats() {
        let manifest = serde_json::json!({
            "kind": "Service",
            "metadata": { "name": "my-svc" }
        });
        assert_eq!(resource_label(&manifest), "Service/my-svc");
    }
}
