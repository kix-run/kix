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
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};
use crate::text::printable;

/// Loaded from kix-packages.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KixPackageIndex {
    pub cluster: String,
    /// PI store path to owned resource store paths.
    pub packages: IndexMap<PathBuf, Vec<PathBuf>>,
}

/// Full in-memory graph built from the result folder.
#[derive(Debug, Clone, PartialEq)]
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
    /// Populated by bulk_load_graph.
    pub ref_cache: HashMap<PathBuf, Vec<PathBuf>>,
}

#[derive(Debug, Clone, PartialEq)]
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

#[derive(Debug, Clone, PartialEq)]
pub struct ResourceNode {
    pub store_path: PathBuf,
    /// Raw K8s manifest parsed from the store path file.
    pub manifest: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
///
/// A failure is an error. An empty graph would load the build with no
/// resources, and a plan against that would prune everything.
fn bulk_load_graph(root_path: &Path) -> Result<HashMap<PathBuf, Vec<PathBuf>>, KixEvalError> {
    let command = format!("nix-store -q --graph {}", root_path.display());
    let out = Command::new("nix-store")
        .args(["-q", "--graph"])
        .arg(root_path)
        .output()
        .map_err(|e| KixEvalError::StoreGraphError {
            message: format!("`{command}` did not run: {e}"),
        })?;
    if !out.status.success() {
        return Err(KixEvalError::StoreGraphError {
            message: format!(
                "`{command}` failed ({}): {}",
                out.status,
                String::from_utf8_lossy(&out.stderr).trim()
            ),
        });
    }

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

    Ok(deps)
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

/// Read a file from a store path.
fn read_store_file(path: &Path) -> Result<Vec<u8>, KixEvalError> {
    std::fs::read(path).map_err(|e| KixEvalError::StoreGraphError {
        message: format!("failed to read store path {}: {e}", path.display()),
    })
}

/// A path for a message, its hidden characters shown.
fn shown(path: &Path) -> String {
    printable(&path.to_string_lossy())
}

/// The first of `manifest`'s kind, `apiVersion` parts, name, and namespace
/// (when it has one) that is not one URL path segment.
fn unrequestable_field(manifest: &serde_json::Value) -> Option<&'static str> {
    let segment = |s: &str| !matches!(s, "" | "." | "..") && !s.contains(['/', '%', '?', '#']);
    let text = |pointer: &str| manifest.pointer(pointer).and_then(|v| v.as_str());
    let api_version = text("/apiVersion").is_some_and(|v| match v.split_once('/') {
        Some((group, version)) => segment(group) && segment(version),
        None => segment(v),
    });
    let namespace = manifest.pointer("/metadata/namespace").is_none()
        || text("/metadata/namespace").is_some_and(segment);
    [
        ("kind", text("/kind").is_some_and(segment)),
        ("apiVersion", api_version),
        ("metadata.name", text("/metadata/name").is_some_and(segment)),
        ("metadata.namespace", namespace),
    ]
    .into_iter()
    .find(|(_, ok)| !ok)
    .map(|(field, _)| field)
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

    /// Build a StoreGraph from a result directory. Commands load one through
    /// [`crate::build_source::Build::local`], which stamps it.
    ///
    /// `status_fn` is called with progress messages during loading.
    pub(crate) fn from_result_dir(
        result_dir: &Path,
        status_fn: &dyn Fn(&str),
    ) -> Result<Self, KixEvalError> {
        // 1. Read kix-packages.json
        status_fn("Reading package index...");
        let index_path = result_dir.join("kix-packages.json");
        let bytes = std::fs::read(&index_path).map_err(|e| KixEvalError::StoreGraphError {
            message: format!(
                "failed to read kix-packages.json at {}: {e}",
                index_path.display()
            ),
        })?;
        let index = super::manifest_json::parse_index(&index_path.to_string_lossy(), &bytes)
            .map_err(|e| KixEvalError::StoreGraphError {
                message: e.to_string(),
            })?;

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
        let ref_cache = bulk_load_graph(&activation_path)?;

        let graph = Self::assemble(
            index,
            activation_path,
            result_dir.to_path_buf(),
            ref_cache,
            &mut read_store_file,
            status_fn,
        )?;
        graph.validate()?;
        Ok(graph)
    }

    /// Steps 4 to 6 of loading a build: read every manifest, group them by
    /// package, and work out the cross-package dependencies. Shared by
    /// every reader of a build, which differ only in where a file's bytes
    /// come from (`read`). Each file is parsed here, with
    /// [`super::manifest_json::parse_manifest`], so every reader parses
    /// alike. A reader runs [`StoreGraph::validate`] on the result. Calls
    /// `read` once for each path the index lists and each `k8s-` path among
    /// the references, and fails when it fails: a build is not deployed
    /// without a file it names.
    /// A package that lists a path twice holds it once.
    pub fn assemble(
        index: KixPackageIndex,
        activation_path: PathBuf,
        result_dir: PathBuf,
        ref_cache: HashMap<PathBuf, Vec<PathBuf>>,
        read: &mut dyn FnMut(&Path) -> Result<Vec<u8>, KixEvalError>,
        status_fn: &dyn Fn(&str),
    ) -> Result<Self, KixEvalError> {
        // 4. Read every manifest once. A k8s path among the references that
        //    no package lists is cluster-level: a Namespace, a CRD, the
        //    Activation record.
        status_fn(&format!("Reading {} packages...", index.packages.len()));
        let mut resources: HashMap<PathBuf, ResourceNode> = HashMap::new();
        let listed = index
            .packages
            .iter()
            .flat_map(|(pi, paths)| std::iter::once(pi).chain(paths));
        let referenced = ref_cache
            .iter()
            .flat_map(|(k, vs)| std::iter::once(k).chain(vs))
            .filter(|p| is_k8s_path(p));
        for path in listed.chain(referenced) {
            if !resources.contains_key(path) {
                let bytes = read(path)?;
                let node = ResourceNode {
                    store_path: path.clone(),
                    manifest: super::manifest_json::parse_manifest(
                        &path.to_string_lossy(),
                        &bytes,
                    )?,
                };
                resources.insert(path.clone(), node);
            }
        }

        // 5. Group the resources by package. Plan keys packages by
        //    namespace and instance name, so a package with no instance
        //    name is refused rather than shown under a stand-in.
        let mut packages = IndexMap::new();
        let mut resource_owner = HashMap::new();
        for (pi_path, resource_paths) in &index.packages {
            let pi_manifest = &resources[pi_path].manifest;
            let instance_name = pi_manifest
                .pointer("/spec/instanceName")
                .and_then(|v| v.as_str())
                .filter(|name| !name.is_empty())
                .ok_or_else(|| KixEvalError::StoreGraphError {
                    message: format!(
                        "the PackageInstance {} has no spec.instanceName",
                        shown(pi_path)
                    ),
                })?
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

            let mut owned: Vec<PathBuf> = Vec::new();
            for res_path in resource_paths {
                if res_path == pi_path || owned.contains(res_path) {
                    continue;
                }
                resource_owner.insert(res_path.clone(), pi_path.clone());
                owned.push(res_path.clone());
            }

            packages.insert(
                pi_path.clone(),
                PackageNode {
                    store_path: pi_path.clone(),
                    instance_name,
                    namespace,
                    version,
                    lifecycle,
                    resource_paths: owned,
                    cross_deps: vec![],
                },
            );
        }

        // 6. Compute cross-package dependencies using bulk-loaded graph
        status_fn("Computing cross-package dependencies...");
        for (pi_path, pkg) in packages.iter_mut() {
            let mut deps = Vec::new();
            for res_path in &pkg.resource_paths {
                let from_label = resource_label(&resources[res_path].manifest);
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
                    let dep_res = &resources[dep_ref];
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
            pkg.cross_deps = deps;
        }

        Ok(StoreGraph {
            cluster_name: index.cluster,
            activation_path,
            result_dir,
            packages,
            resources,
            resource_owner,
            ref_cache,
        })
    }

    /// Check that the graph is one build as plan shows it and deploy
    /// requests it. Run on every build, whichever reader read it; a graph
    /// [`StoreGraph::synthesize`] makes describes live objects, not a
    /// build, and is not checked. Refuses:
    ///
    /// - a manifest whose kind, `apiVersion` parts, name, or namespace is
    ///   not one URL path segment, since kube-rs puts them in request paths
    ///   unescaped, and a request could reach another object than plan
    ///   shows;
    /// - two manifests of one object (kind, namespace, name), since plan
    ///   and deploy key objects that way, without the API group;
    /// - any Activation record but one, at `activation_path`, labelled with
    ///   the index's cluster;
    /// - two packages of one namespace and instance, which plan would show
    ///   as one, and a package whose PackageInstance or listed resource is
    ///   not among the resources;
    /// - a resource two packages list that is not an import marker. Plan
    ///   shows each other resource under the one package that lists it, or
    ///   as cluster-level.
    pub fn validate(&self) -> Result<(), KixEvalError> {
        let fail = |message: String| Err(KixEvalError::StoreGraphError { message });
        let mut paths: Vec<&PathBuf> = self.resources.keys().collect();
        paths.sort();
        let mut objects: HashMap<ResourceId, &PathBuf> = HashMap::new();
        let mut records = Vec::new();
        for path in paths {
            let manifest = &self.resources[path].manifest;
            if let Some(field) = unrequestable_field(manifest) {
                return fail(format!(
                    "{}'s {field} must be one URL path segment: a string, not empty, '.', or '..', and without '/', '%', '?', or '#'",
                    shown(path)
                ));
            }
            let id = ResourceId::from_value(manifest);
            if let Some(other) = objects.insert(id.clone(), path) {
                return fail(format!(
                    "{} and {} are both {id}",
                    shown(other),
                    shown(path)
                ));
            }
            if lifecycle::is_record(manifest) {
                records.push(path);
            }
        }
        if records != [&self.activation_path] {
            return fail(format!(
                "the build must hold one Activation record, at {}; it holds {}",
                shown(&self.activation_path),
                records.len()
            ));
        }
        let record = &self.resources[&self.activation_path].manifest;
        let label = keys::label(record, keys::CLUSTER_LABEL).unwrap_or_default();
        if label != self.cluster_name {
            return fail(format!(
                "the Activation record is for cluster '{}', but kix-packages.json says '{}'",
                printable(label),
                printable(&self.cluster_name)
            ));
        }
        let mut keys: HashMap<(&str, &str), &PathBuf> = HashMap::new();
        let mut listings: HashMap<&PathBuf, usize> = HashMap::new();
        for (pi_path, package) in &self.packages {
            let Some(pi) = self.resources.get(pi_path) else {
                return fail(format!("{} is not among the resources", shown(pi_path)));
            };
            let kind = pi.manifest.get("kind");
            if kind.and_then(|k| k.as_str()) != Some(lifecycle::PACKAGE_INSTANCE_KIND) {
                return fail(format!("{} is not a PackageInstance", shown(pi_path)));
            }
            let key = (package.namespace.as_str(), package.instance_name.as_str());
            if let Some(other) = keys.insert(key, pi_path) {
                return fail(format!(
                    "{} and {} are both package {}/{}, which plan would show as one",
                    shown(other),
                    shown(pi_path),
                    printable(key.0),
                    printable(key.1)
                ));
            }
            for path in &package.resource_paths {
                if !self.resources.contains_key(path) {
                    return fail(format!(
                        "{} lists {}, which is not among the resources",
                        shown(pi_path),
                        shown(path)
                    ));
                }
                *listings.entry(path).or_default() += 1;
            }
        }
        let mut shared: Vec<&PathBuf> = listings
            .into_iter()
            .filter(|(path, n)| *n > 1 && !lifecycle::is_marker(&self.resources[*path].manifest))
            .map(|(path, _)| path)
            .collect();
        shared.sort();
        if let Some(path) = shared.first() {
            return fail(format!(
                "{} is listed by more than one package, which only an import marker may be",
                shown(path)
            ));
        }
        Ok(())
    }

    /// Build a graph from a flat set of stamped manifests, such as live
    /// kix-owned objects or a snapshot directory, so it can stand in
    /// for a store graph that is not on this machine: the previous
    /// activation when its store path is gone, or the cluster side of
    /// `kix diff`.
    ///
    /// Resources group by their stamped `kix.run/package[-namespace]`
    /// annotations, except that a manifest matching a `reference` path joins
    /// every reference package that lists the path: a build lists one store
    /// path under several packages (a `secret-ref-*` marker each importer
    /// declares), and `stamp::stamp_annotations` stamps only one of them.
    /// A PackageInstance is a package of its own unless it is an import
    /// marker stamped with another package; a marker the build indexes as a
    /// package (a `kix.mkImport` platform import) is stamped `_cluster`.
    /// Cluster-level resources (no package annotation) stay in
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

        let mut reference_members: HashMap<&PathBuf, Vec<(&str, &str)>> = HashMap::new();
        for p in reference.packages.values() {
            for res in &p.resource_paths {
                reference_members
                    .entry(res)
                    .or_default()
                    .push((p.namespace.as_str(), p.instance_name.as_str()));
            }
        }

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
                let diff_config = crate::manifest::diff::DiffConfig::default().in_order();
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

            let stamped_pkg = ann(m, keys::PACKAGE).filter(|p| p != "_cluster");

            // An import marker declared by a package (`crd-ref-*`,
            // `secret-ref-*`, ...) is a resource of that package, grouped
            // below. Any other PackageInstance is a package.
            if m.get("kind").and_then(Value::as_str) == Some(PACKAGE_INSTANCE_KIND)
                && !(crate::manifest::lifecycle::is_marker(m) && stamped_pkg.is_some())
            {
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

            if let Some(members) = matched.and_then(|&p| reference_members.get(p)) {
                for (pkg_ns, pkg) in members {
                    paths_by_pkg
                        .entry(format!("{pkg_ns}/{pkg}"))
                        .or_default()
                        .push(path.clone());
                }
            } else if let Some(pkg) = stamped_pkg {
                let pkg_ns = ann(m, keys::PACKAGE_NAMESPACE).unwrap_or_else(|| "_cluster".into());
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

    mod validate {
        use super::super::*;
        use crate::manifest::{keys, lifecycle};
        use serde_json::{Value, json};

        fn path(name: &str) -> PathBuf {
            PathBuf::from(format!("/nix/store/{:0>32}-k8s-{name}", 0))
        }

        fn add(g: &mut StoreGraph, name: &str, manifest: Value) -> PathBuf {
            let p = path(name);
            let node = ResourceNode {
                store_path: p.clone(),
                manifest,
            };
            g.resources.insert(p.clone(), node);
            p
        }

        fn package_instance(ns: &str, instance: &str, import: bool) -> Value {
            let mut pi = json!({
                "apiVersion": keys::API_VERSION,
                "kind": lifecycle::PACKAGE_INSTANCE_KIND,
                "metadata": {"name": instance, "namespace": ns},
                "spec": {"instanceName": instance},
            });
            if import {
                pi["metadata"]["annotations"] = json!({(keys::MODE): "import"});
            }
            pi
        }

        /// A build of cluster `c` with a record and the packages
        /// `(namespace, instance)`, each listing `shared`: an import marker
        /// or a ConfigMap.
        fn build(packages: &[(&str, &str)], shared_marker: bool) -> StoreGraph {
            let mut g = StoreGraph::empty("c");
            g.activation_path = add(
                &mut g,
                "Activation-c",
                json!({
                    "apiVersion": keys::API_VERSION,
                    "kind": lifecycle::RECORD_KIND,
                    "metadata": {"name": "c", "labels": {(keys::CLUSTER_LABEL): "c"}},
                }),
            );
            let shared = match shared_marker {
                true => add(
                    &mut g,
                    "PackageInstance-marker",
                    package_instance("a", "marker", true),
                ),
                false => add(
                    &mut g,
                    "ConfigMap-shared",
                    json!({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "shared", "namespace": "a"}}),
                ),
            };
            for (i, (ns, instance)) in packages.iter().enumerate() {
                let pi = add(
                    &mut g,
                    &format!("PackageInstance-{i}"),
                    package_instance(ns, &format!("{instance}{i}"), false),
                );
                g.resource_owner.insert(shared.clone(), pi.clone());
                let node = PackageNode {
                    store_path: pi.clone(),
                    instance_name: instance.to_string(),
                    namespace: ns.to_string(),
                    version: None,
                    lifecycle: None,
                    resource_paths: vec![shared.clone()],
                    cross_deps: vec![],
                };
                g.packages.insert(pi, node);
            }
            g
        }

        #[test]
        fn packages_that_share_an_import_marker_are_valid() {
            build(&[("a", "x"), ("b", "y")], true).validate().unwrap();
        }

        #[test]
        fn a_resource_two_packages_list_that_is_not_a_marker_is_refused() {
            let err = build(&[("a", "x"), ("b", "y")], false)
                .validate()
                .unwrap_err();
            assert!(err.to_string().contains("only an import marker"), "{err}");
        }

        /// Plan keys packages by namespace and instance.
        #[test]
        fn two_packages_of_one_namespace_and_instance_are_refused() {
            let err = build(&[("a", "x"), ("a", "x")], true)
                .validate()
                .unwrap_err();
            assert!(err.to_string().contains("plan would show as one"), "{err}");
        }

        #[test]
        fn a_build_without_one_record_at_its_path_is_refused() {
            let mut g = build(&[("a", "x")], true);
            g.activation_path = path("elsewhere");
            assert!(g.validate().is_err());
            let mut g = build(&[("a", "x")], true);
            let record = g.resources[&g.activation_path].manifest.clone();
            let mut second = record;
            second["metadata"]["name"] = json!("d");
            add(&mut g, "Activation-d", second);
            assert!(g.validate().is_err());
        }

        #[test]
        fn a_package_without_its_package_instance_is_refused() {
            let mut g = build(&[("a", "x")], true);
            let pi = g.packages.keys().next().unwrap().clone();
            g.resources.get_mut(&pi).unwrap().manifest["kind"] = json!("ConfigMap");
            assert!(g.validate().is_err());
        }

        #[test]
        fn a_package_whose_package_instance_is_absent_is_refused() {
            let mut g = build(&[("a", "x")], true);
            let node = g.packages.values().next().unwrap().clone();
            let absent = path("PackageInstance-absent");
            g.packages.insert(
                absent.clone(),
                PackageNode {
                    store_path: absent,
                    ..node
                },
            );
            let err = g.validate().unwrap_err();
            assert!(err.to_string().contains("not among the resources"), "{err}");
        }

        #[test]
        fn a_package_that_lists_an_absent_resource_is_refused() {
            let mut g = build(&[("a", "x")], true);
            let pkg = g.packages.values_mut().next().unwrap();
            pkg.resource_paths.push(path("ConfigMap-absent"));
            let err = g.validate().unwrap_err();
            assert!(err.to_string().contains("not among the resources"), "{err}");
        }
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

        /// An unstamped PackageInstance as the library renders it. With
        /// `import` set it is an import marker, shaped like the build's
        /// `secret-ref-*`, `service-ref-*` and `platform-*` markers.
        fn rendered_pi(ns: &str, name: &str, import: Option<(&str, &str)>) -> Value {
            let mut anns = serde_json::Map::new();
            anns.insert(keys::DEPENDS_ON.into(), json!("x,requires:y"));
            if let Some((kind, target)) = import {
                anns.insert(keys::MODE.into(), json!("import"));
                anns.insert(keys::IMPORT_API_VERSION.into(), json!("v1"));
                anns.insert(keys::IMPORT_KIND.into(), json!(kind));
                anns.insert(keys::IMPORT_NAME.into(), json!(target));
            }
            let mut spec = json!({"instanceName": name, "namespaceName": ns});
            if import.is_some() {
                spec["mode"] = json!("import");
            } else {
                spec["version"] = json!("1");
            }
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
                "metadata": {
                    "name": name,
                    "namespace": ns,
                    "annotations": anns,
                    "labels": {"app.kubernetes.io/instance": name},
                },
                "spec": spec,
            })
        }

        fn rendered(kind: &str, ns: &str, name: &str) -> Value {
            json!({
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {"name": name, "namespace": ns},
            })
        }

        /// `(store hash seed, PackageInstance, [(seed, resource)])`.
        type BuiltPackage<'a> = (&'a str, Value, Vec<(&'a str, Value)>);

        /// A build graph shaped like `Build::local` makes one: each
        /// package lists `(seed, manifest)` resources by store path, a seed
        /// listed under two packages is one store path, every PackageInstance
        /// is in `resources`, and `stamp_annotations` has run.
        fn built(packages: &[BuiltPackage]) -> StoreGraph {
            let path = |seed: &str| PathBuf::from(format!("/nix/store/{}-k8s", h(seed)));
            let mut g = StoreGraph::empty("c");
            for (pi_seed, pi, resources) in packages {
                let pi_path = path(pi_seed);
                g.resources.insert(
                    pi_path.clone(),
                    ResourceNode {
                        store_path: pi_path.clone(),
                        manifest: pi.clone(),
                    },
                );
                let mut resource_paths = Vec::new();
                for (seed, manifest) in resources {
                    let p = path(seed);
                    g.resources.insert(
                        p.clone(),
                        ResourceNode {
                            store_path: p.clone(),
                            manifest: manifest.clone(),
                        },
                    );
                    g.resource_owner.insert(p.clone(), pi_path.clone());
                    resource_paths.push(p);
                }
                g.packages.insert(
                    pi_path.clone(),
                    PackageNode {
                        store_path: pi_path,
                        instance_name: pi["spec"]["instanceName"].as_str().unwrap().into(),
                        namespace: pi["metadata"]["namespace"].as_str().unwrap().into(),
                        version: pi["spec"]["version"].as_str().map(str::to_string),
                        lifecycle: None,
                        resource_paths,
                        cross_deps: vec![],
                    },
                );
            }
            crate::eval::stamp::stamp_annotations(&mut g);
            g
        }

        /// Synthesize the live side from every stamped manifest of `build`,
        /// as a converged cluster holds them, and check it groups exactly
        /// like the build, which is what `plan::diff_graphs` compares.
        fn assert_converged(build: &StoreGraph) {
            let live_manifests: Vec<Value> = build
                .resources
                .values()
                .map(|n| n.manifest.clone())
                .collect();
            let live = StoreGraph::synthesize(&live_manifests, build);

            let groups = |g: &StoreGraph| -> std::collections::BTreeMap<String, Vec<PathBuf>> {
                g.packages
                    .values()
                    .map(|p| {
                        (
                            format!("{}/{}", p.namespace, p.instance_name),
                            p.resource_paths.clone(),
                        )
                    })
                    .collect()
            };
            let unowned = |g: &StoreGraph| -> std::collections::BTreeSet<PathBuf> {
                g.resources
                    .keys()
                    .filter(|p| !g.resource_owner.contains_key(*p) && !g.packages.contains_key(*p))
                    .cloned()
                    .collect()
            };
            assert_eq!(groups(&live), groups(build));
            assert_eq!(unowned(&live), unowned(build));
        }

        /// A live import marker stamped with the package that declares it
        /// lands among that package's resources, the way a build lists it,
        /// and is not a package of its own.
        #[test]
        fn an_import_marker_is_a_resource_of_its_declaring_package() {
            let build = built(&[(
                "pi",
                rendered_pi("data", "pg", None),
                vec![
                    ("sts", rendered("StatefulSet", "data", "pg")),
                    (
                        "mk",
                        rendered_pi(
                            "data",
                            "crd-ref-pg-sgclusters",
                            Some(("CustomResourceDefinition", "sgclusters.stackgres.io")),
                        ),
                    ),
                ],
            )]);
            assert_converged(&build);

            let live_manifests: Vec<Value> = build
                .resources
                .values()
                .map(|n| n.manifest.clone())
                .collect();
            let g = StoreGraph::synthesize(&live_manifests, &StoreGraph::empty("c"));
            assert_eq!(g.packages.len(), 1);
            let pg = pkg(&g, "data", "pg");
            assert_eq!(pg.resource_paths.len(), 2);
        }

        /// `secret-ref-*` and `service-ref-*` markers for one database are
        /// one store path each, listed under the database package and under
        /// every package that imports them; the live object carries only
        /// one `kix.run/package` stamp. The synthesized graph lists each
        /// marker under every package the build does.
        #[test]
        fn a_marker_two_packages_list_is_a_resource_of_both() {
            let secret_ref = rendered_pi(
                "data",
                "secret-ref-postgres-postgres",
                Some(("Secret", "postgres")),
            );
            let service_ref = rendered_pi(
                "data",
                "service-ref-postgres-postgres",
                Some(("Service", "postgres")),
            );
            let build = built(&[
                (
                    "pg",
                    rendered_pi("data", "postgres", None),
                    vec![
                        ("sgc", rendered("SGCluster", "data", "postgres")),
                        ("svcref", service_ref.clone()),
                        ("secref", secret_ref.clone()),
                    ],
                ),
                (
                    "appdb",
                    rendered_pi("app", "app-db", None),
                    vec![
                        ("job", rendered("Job", "data", "app-db-bootstrap")),
                        ("svcref", service_ref),
                        ("secref", secret_ref),
                    ],
                ),
            ]);
            assert_converged(&build);
        }

        /// A `kix.mkImport` platform import (`platform-storage`,
        /// `platform-dns`) is a package of its own in the build, so
        /// `stamp_annotations` stamps it `_cluster`. It stays a package
        /// whether or not it owns resources, never a cluster-level resource.
        #[test]
        fn a_platform_import_is_a_package_of_its_own() {
            let build = built(&[
                (
                    "storage",
                    rendered_pi(
                        "kube-system",
                        "platform-storage",
                        Some(("StorageClass", "standard")),
                    ),
                    vec![],
                ),
                (
                    "dns",
                    rendered_pi(
                        "kube-system",
                        "platform-dns",
                        Some(("Deployment", "coredns")),
                    ),
                    vec![(
                        "cnp",
                        rendered("CiliumNetworkPolicy", "kube-system", "coredns-egress"),
                    )],
                ),
            ]);
            assert_converged(&build);
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

    /// Before, any failure gave an empty graph, and the build loaded with
    /// no resources.
    #[test]
    fn a_graph_query_that_fails_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let err = bulk_load_graph(dir.path()).unwrap_err();
        assert!(err.to_string().contains("nix-store -q --graph"), "{err}");
    }
}
