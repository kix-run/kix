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

use super::error::KixEvalError;

/// Loaded from kix-packages.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KixPackageIndex {
    pub cluster: String,
    /// PI store path to owned resource store paths.
    pub packages: IndexMap<PathBuf, Vec<PathBuf>>,
}

/// Full in-memory graph built from the result folder.
#[derive(Debug, Clone)]
pub struct StoreGraph {
    pub cluster_name: String,
    pub activation_path: PathBuf,
    /// The result directory containing kix-packages.json + activation symlink.
    pub result_dir: PathBuf,
    pub packages: IndexMap<PathBuf, PackageNode>,
    pub resources: HashMap<PathBuf, ResourceNode>,
    /// Resource store path to owning PI store path.
    pub resource_owner: HashMap<PathBuf, PathBuf>,
    /// Cached direct store references by path.
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
    /// From the PI manifest: spec.lifecycle, one of "stateful", "durable",
    /// "ephemeral", or absent. Drives migration pair detection.
    /// See v2_discussions/67_stateful_migration_orchestration.md.
    pub lifecycle: Option<String>,
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
/// Parses the dot output and returns direct references by path.
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

        // Dot edges run from dependency to dependent. Store the inverse map.
        deps.entry(dst).or_default().push(src);
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
/// Reads the first 32 characters of `/nix/store/<hash>-name`.
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
    /// Create an empty StoreGraph (for first-deploy comparisons).
    pub fn empty(cluster_name: &str) -> Self {
        Self {
            cluster_name: cluster_name.to_string(),
            activation_path: PathBuf::new(),
            result_dir: PathBuf::new(),
            packages: IndexMap::new(),
            resources: HashMap::new(),
            resource_owner: HashMap::new(),
            ref_cache: HashMap::new(),
        }
    }

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
                    tracing::warn!(pi = %pi_path.display(), "PackageInstance is missing spec.instanceName; displaying its name as unknown");
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
            let lifecycle = pi_manifest
                .pointer("/spec/lifecycle")
                .and_then(|v| v.as_str())
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
                    lifecycle,
                    resource_paths: valid_resource_paths,
                    cross_deps: vec![],
                },
            );
        }

        // 5. Discover cluster-level resources (Namespaces, CRDs, Activation)
        //    These are k8s store paths in the DAG but not owned by any PI.
        //    Collect all unique paths from both keys and values of ref_cache.
        status_fn("Discovering cluster-level resources...");
        let mut all_dag_paths: std::collections::HashSet<PathBuf> =
            std::collections::HashSet::new();
        for (k, vs) in &ref_cache {
            all_dag_paths.insert(k.clone());
            for v in vs {
                all_dag_paths.insert(v.clone());
            }
        }
        for path in &all_dag_paths {
            if !is_k8s_path(path) || resources.contains_key(path) {
                continue;
            }
            if let Ok(manifest) = read_store_json(path) {
                resources.insert(
                    path.clone(),
                    ResourceNode {
                        store_path: path.clone(),
                        manifest,
                    },
                );
            }
        }

        // 6. Compute cross-package dependencies using bulk-loaded graph
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
            result_dir: result_dir.to_path_buf(),
            packages,
            resources,
            resource_owner,
            ref_cache,
        })
    }

    /// Build a graph from a flat set of stamped manifests, such as live
    /// kix-owned objects or a snapshot directory, so it can stand in
    /// for a store graph that is not on this machine: the previous
    /// activation when its store path is gone, or the cluster side of
    /// `kix diff`.
    ///
    /// Resources group by their stamped `kix.run/package[-namespace]`
    /// annotations. Cluster-level resources (no package annotation) stay in
    /// `resources` outside any PackageNode, the way a real graph keeps
    /// them. Identity hashes map back onto `reference`'s store paths: a
    /// matched resource reuses the reference path and manifest (equal hash
    /// ⇒ identical content), so untouched packages compare path-equal and
    /// read as unchanged; unmatched resources keep their own manifest under
    /// a synthetic path so their diff keeps the old and new sides aligned. Versions come from
    /// PackageInstance manifests.
    pub fn synthesize(manifests: &[serde_json::Value], reference: &StoreGraph) -> StoreGraph {
        use crate::manifest::keys;
        use crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND;
        use serde_json::Value;
        use std::collections::HashSet;

        let reference_path_by_hash: HashMap<String, &PathBuf> = reference
            .resources
            .keys()
            .map(|p| (store_hash(p), p))
            .collect();

        let ann = |m: &Value, key: &str| -> Option<String> {
            m.pointer("/metadata/annotations")
                .and_then(|a| a.get(key))
                .and_then(Value::as_str)
                .map(str::to_string)
        };

        let mut graph = StoreGraph::empty(&reference.cluster_name);
        // Map "ns/instance" to resource paths and its PackageInstance manifest
        // (its path, version, lifecycle). A package exists for every
        // PackageInstance seen, resources or not, so an empty package on
        // the reference side compares as unchanged rather than added.
        let mut paths_by_pkg: HashMap<String, Vec<PathBuf>> = HashMap::new();
        let mut pi_by_pkg: HashMap<String, (PathBuf, Option<String>, Option<String>)> =
            HashMap::new();

        for (i, m) in manifests.iter().enumerate() {
            // A manifest earns the reference path by matching it in content,
            // not by hash alone. Between two builds the hash is the content;
            // a live object keeps its stamp while someone changes it under
            // kix, and that change has to stay visible.
            let hash = ann(m, keys::IDENTITY_HASH).unwrap_or_default();
            let matched = reference_path_by_hash.get(&hash).filter(|&&p| {
                let diff_config = crate::manifest::diff::DiffConfig::default();
                crate::manifest::diff::engine::structural_diff(
                    m,
                    &reference.resources[p].manifest,
                    "$",
                    &diff_config,
                )
                .is_empty()
            });
            // A synthetic path is named by content, so the invariant a real
            // graph gives for free holds here too: equal path ⇔ equal
            // manifest, whichever side synthesized it.
            let (path, manifest) = match matched {
                Some(&p) => (p.clone(), reference.resources[p].manifest.clone()),
                None => (
                    PathBuf::from(format!(
                        "/nix/store/{}-synthetic-{i}",
                        &crate::cluster::normalize::content_hash(m)[..32]
                    )),
                    m.clone(),
                ),
            };
            graph.resources.insert(
                path.clone(),
                ResourceNode {
                    store_path: path.clone(),
                    manifest,
                },
            );

            if m.get("kind").and_then(Value::as_str) == Some(PACKAGE_INSTANCE_KIND) {
                let ns = m
                    .pointer("/metadata/namespace")
                    .and_then(Value::as_str)
                    .unwrap_or("_cluster");
                let name = m
                    .pointer("/spec/instanceName")
                    .and_then(Value::as_str)
                    .or_else(|| m.pointer("/metadata/name").and_then(Value::as_str))
                    .unwrap_or("unknown");
                let version = m
                    .pointer("/spec/version")
                    .and_then(Value::as_str)
                    .filter(|v| *v != "<undefined>")
                    .map(str::to_string);
                let lifecycle = m
                    .pointer("/spec/lifecycle")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                pi_by_pkg.insert(format!("{ns}/{name}"), (path, version, lifecycle));
                continue;
            }

            let pkg = ann(m, keys::PACKAGE).unwrap_or_else(|| "_cluster".into());
            let pkg_ns = ann(m, keys::PACKAGE_NAMESPACE).unwrap_or_else(|| "_cluster".into());
            if pkg != "_cluster" {
                paths_by_pkg
                    .entry(format!("{pkg_ns}/{pkg}"))
                    .or_default()
                    .push(path);
            }
        }

        let mut pkg_keys: Vec<String> = paths_by_pkg
            .keys()
            .chain(pi_by_pkg.keys())
            .cloned()
            .collect();
        pkg_keys.sort();
        pkg_keys.dedup();

        for key in pkg_keys {
            let paths = paths_by_pkg.remove(&key).unwrap_or_default();
            let (pkg_ns, pkg_name) = key.split_once('/').unwrap_or(("_cluster", key.as_str()));

            // Order shared paths exactly like the reference package so an
            // untouched package compares equal; extras go
            // last.
            let ordered = match reference
                .packages
                .values()
                .find(|p| p.namespace == pkg_ns && p.instance_name == pkg_name)
            {
                Some(ref_pkg) => {
                    let old_set: HashSet<&PathBuf> = paths.iter().collect();
                    let ref_set: HashSet<&PathBuf> = ref_pkg.resource_paths.iter().collect();
                    let mut ordered: Vec<PathBuf> = ref_pkg
                        .resource_paths
                        .iter()
                        .filter(|p| old_set.contains(p))
                        .cloned()
                        .collect();
                    let mut extras: Vec<PathBuf> = paths
                        .iter()
                        .filter(|p| !ref_set.contains(p))
                        .cloned()
                        .collect();
                    extras.sort();
                    extras.dedup();
                    ordered.extend(extras);
                    ordered
                }
                None => {
                    let mut sorted = paths;
                    sorted.sort();
                    sorted.dedup();
                    sorted
                }
            };

            let (store_path, version, lifecycle) = pi_by_pkg.remove(&key).unwrap_or_else(|| {
                (
                    PathBuf::from(format!("/nix/store/synthetic-pkg-{pkg_ns}-{pkg_name}")),
                    None,
                    None,
                )
            });
            for res_path in &ordered {
                graph
                    .resource_owner
                    .insert(res_path.clone(), store_path.clone());
            }
            graph.packages.insert(
                store_path.clone(),
                PackageNode {
                    store_path,
                    instance_name: pkg_name.to_string(),
                    namespace: pkg_ns.to_string(),
                    version,
                    lifecycle,
                    resource_paths: ordered,
                    cross_deps: vec![],
                },
            );
        }

        graph
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
    /// Uses the bulk-loaded ref_cache without spawning subprocesses.
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
    fn is_k8s_path_works() {
        assert!(is_k8s_path(Path::new(
            "/nix/store/abc123def456ghi789jkl012mno345pq-k8s-Service-test"
        )));
        assert!(!is_k8s_path(Path::new(
            "/nix/store/abc123def456ghi789jkl012mno345pq-python3-3.11"
        )));
    }

    mod synthesize {
        use super::super::*;
        use crate::manifest::keys;
        use serde_json::{Value, json};

        /// A stamped manifest the way a build (or the kix-owned view of a
        /// live object) carries it.
        fn stamped(
            kind: &str,
            ns: &str,
            name: &str,
            pkg: (&str, &str),
            hash: &str,
            spec: Value,
        ) -> Value {
            json!({
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": ns,
                    "annotations": {
                        keys::PACKAGE: pkg.1,
                        keys::PACKAGE_NAMESPACE: pkg.0,
                        keys::IDENTITY_HASH: hash,
                    }
                },
                "spec": spec,
            })
        }

        fn package_instance(ns: &str, name: &str, version: &str, hash: &str) -> Value {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
                "metadata": {
                    "name": name,
                    "namespace": ns,
                    "annotations": {
                        keys::PACKAGE: "_cluster",
                        keys::PACKAGE_NAMESPACE: "_cluster",
                        keys::IDENTITY_HASH: hash,
                    }
                },
                "spec": {"instanceName": name, "namespaceName": ns, "version": version},
            })
        }

        fn cluster_level(kind: &str, name: &str, hash: &str) -> Value {
            json!({
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {
                    "name": name,
                    "annotations": {keys::IDENTITY_HASH: hash}
                },
            })
        }

        /// 32-char store hash as `store_hash` reads it back from a path.
        fn h(seed: &str) -> String {
            format!("{seed:a<32}")
        }

        fn pkg<'a>(g: &'a StoreGraph, ns: &str, name: &str) -> &'a PackageNode {
            g.packages
                .values()
                .find(|p| p.namespace == ns && p.instance_name == name)
                .unwrap_or_else(|| panic!("no package {ns}/{name}"))
        }

        #[test]
        fn groups_resources_under_their_package_and_owns_them() {
            let manifests = vec![
                package_instance("app", "web", "1.0.0", &h("pi")),
                stamped(
                    "ConfigMap",
                    "app",
                    "web",
                    ("app", "web"),
                    &h("cm"),
                    json!({}),
                ),
                stamped(
                    "Service",
                    "app",
                    "web",
                    ("app", "web"),
                    &h("svc"),
                    json!({}),
                ),
                cluster_level("Namespace", "app", &h("ns")),
            ];
            let g = StoreGraph::synthesize(&manifests, &StoreGraph::empty("c"));

            let web = pkg(&g, "app", "web");
            assert_eq!(web.version.as_deref(), Some("1.0.0"));
            assert_eq!(web.resource_paths.len(), 2);
            for path in &web.resource_paths {
                assert_eq!(g.resource_owner.get(path), Some(&web.store_path));
            }
            // The PI sits at the package's store path, like a real graph.
            assert!(g.resources.contains_key(&web.store_path));
            // The namespace is a resource nobody owns.
            let ns_path = g
                .resources
                .iter()
                .find(|(_, n)| n.manifest["kind"] == "Namespace")
                .map(|(p, _)| p.clone())
                .unwrap();
            assert!(!g.resource_owner.contains_key(&ns_path));
            assert!(!g.packages.contains_key(&ns_path));
        }

        #[test]
        fn a_package_instance_alone_still_makes_a_package() {
            let manifests = vec![package_instance("kube-system", "dns", "2.0", &h("pi"))];
            let g = StoreGraph::synthesize(&manifests, &StoreGraph::empty("c"));
            let dns = pkg(&g, "kube-system", "dns");
            assert!(dns.resource_paths.is_empty());
            assert_eq!(dns.version.as_deref(), Some("2.0"));
        }

        #[test]
        fn matching_content_reuses_the_reference_path_so_the_package_reads_unchanged() {
            let cm = stamped(
                "ConfigMap",
                "app",
                "web",
                ("app", "web"),
                &h("cm"),
                json!({"k": "v"}),
            );
            let reference = StoreGraph::synthesize(
                &[package_instance("app", "web", "1", &h("pi")), cm.clone()],
                &StoreGraph::empty("c"),
            );
            let old = StoreGraph::synthesize(
                &[package_instance("app", "web", "1", &h("pi")), cm],
                &reference,
            );
            assert_eq!(
                pkg(&old, "app", "web").resource_paths,
                pkg(&reference, "app", "web").resource_paths,
            );
        }

        #[test]
        fn same_hash_different_content_keeps_its_own_manifest() {
            // A live object drifted under kix: the stamp is unchanged, the
            // content is not. It must not be mistaken for the reference.
            let built = stamped(
                "Deployment",
                "app",
                "web",
                ("app", "web"),
                &h("dep"),
                json!({"replicas": 2}),
            );
            let live = stamped(
                "Deployment",
                "app",
                "web",
                ("app", "web"),
                &h("dep"),
                json!({"replicas": 3}),
            );
            let reference = StoreGraph::synthesize(&[built], &StoreGraph::empty("c"));
            let old = StoreGraph::synthesize(&[live], &reference);

            let old_pkg = pkg(&old, "app", "web");
            assert_ne!(
                old_pkg.resource_paths,
                pkg(&reference, "app", "web").resource_paths
            );
            let node = &old.resources[&old_pkg.resource_paths[0]];
            assert_eq!(node.manifest["spec"]["replicas"], json!(3));
        }
    }
}
