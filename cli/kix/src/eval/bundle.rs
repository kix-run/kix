//! Bundles: a cluster build as one JSON file, read without Nix.
//!
//! `kix bundle` writes every store file in the build's Activation closure,
//! with its references, plus `kix-packages.json`. `kix plan`, `kix deploy`
//! and `kix graph` read it back with `--bundle`, so a machine with no Nix
//! store, such as an in-cluster agent, can plan and deploy a build made
//! elsewhere.
//!
//! Whoever wrote a bundle chose its store paths, and kix decides what to
//! apply, skip and prune by the hash in those paths. So [`Bundle::verify`]
//! recomputes every path from its file's bytes, references and name
//! (`eval::store_path`) and refuses a bundle where any differs. With that,
//! equal paths mean equal content, as they do for a Nix build.

use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::error::KixEvalError;
use super::store_graph::{KixPackageIndex, StoreGraph, store_name};
use super::store_path::{self, Method};
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};

/// The `format` field of every bundle.
pub const FORMAT: &str = "kix-bundle";
/// The version this kix writes and reads. A reader refuses any other.
pub const VERSION: u32 = 1;
/// The largest bundle kix reads, in bytes.
pub const MAX_BYTES: usize = 64 * 1024 * 1024;
/// The most files a bundle may hold.
pub const MAX_FILES: usize = 50_000;

/// A build as one file. See the module documentation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bundle {
    /// Always [`FORMAT`].
    pub format: String,
    /// Always [`VERSION`].
    pub version: u32,
    /// The kix revision that wrote the bundle, for the record. Not checked.
    pub kix_rev: String,
    /// The cluster name the build gives (`kix-packages.json`'s `cluster`).
    pub cluster: String,
    /// The store path of the Activation record.
    pub activation: String,
    /// The store path of `kix-packages.json`.
    pub index: String,
    /// Every store file of the build, by store path.
    pub files: BTreeMap<String, BundleFile>,
    /// What `kix deploy` would otherwise read from the flake's checkout for
    /// the deploy receipt: `source`, `inputs` and `builder`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt: Option<serde_json::Value>,
}

/// One store file.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleFile {
    /// The file's bytes. Every file in a cluster build is UTF-8.
    pub text: String,
    /// The store paths it references, as Nix records them.
    pub references: Vec<String>,
}

/// Why a bundle was refused.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum BundleError {
    #[error("the bundle is {0} bytes; the most kix reads is {MAX_BYTES}")]
    TooLarge(usize),
    #[error("the bundle is not valid JSON of the bundle format: {0}")]
    Unreadable(String),
    #[error(
        "the bundle's format is '{format}' version {version}; this kix reads '{FORMAT}' version {VERSION}"
    )]
    WrongFormat { format: String, version: u32 },
    #[error("the bundle has {0} files; the most kix reads is {MAX_FILES}")]
    TooManyFiles(usize),
    #[error("'{0}' is not a store path")]
    NotAStorePath(String),
    #[error("{0} was not made from the bytes and references the bundle gives it")]
    PathMismatch(String),
    #[error("{path} references {missing}, which is not in the bundle")]
    MissingReference { path: String, missing: String },
    #[error("the bundle's {what} {path} is not among its files")]
    MissingEntry { what: &'static str, path: String },
    #[error(
        "{0} is in the bundle but not part of the build: nothing the Activation record depends on references it"
    )]
    Unreachable(String),
    #[error("{path} is not a JSON manifest: {message}")]
    NotJson { path: String, message: String },
    #[error(
        "the bundle must hold exactly one Activation record, and it must be its `activation`; found {0}"
    )]
    Records(usize),
    #[error("the bundle is for cluster '{bundle}', but its {what} says '{other}'")]
    WrongCluster {
        bundle: String,
        what: &'static str,
        other: String,
    },
    #[error("kix-packages.json lists {0}, which the Activation record's closure does not hold")]
    IndexOutsideClosure(String),
    #[error(
        "kix-packages.json and the Activation record's `spec.instances` list different package instances"
    )]
    IndexInstances,
    #[error("two manifests in the bundle name {0}")]
    DuplicateObject(String),
    #[error(
        "kix-packages.json lists {0}, which is not a manifest: its store name does not start with k8s-"
    )]
    IndexNotManifest(String),
    #[error("{0} uses a retired kix domain key or group")]
    RetiredDomain(String),
    #[error("{0} is a source file that no Secret's SOPS source annotation names")]
    UnexpectedSource(String),
}

impl Bundle {
    /// Parse a bundle and check its format, version and size. Call
    /// [`Bundle::verify`] before trusting anything in it.
    pub fn parse(bytes: &[u8]) -> Result<Self, BundleError> {
        if bytes.len() > MAX_BYTES {
            return Err(BundleError::TooLarge(bytes.len()));
        }
        // serde_json stops at 128 levels of nesting.
        let bundle: Bundle =
            serde_json::from_slice(bytes).map_err(|e| BundleError::Unreadable(e.to_string()))?;
        if bundle.format != FORMAT || bundle.version != VERSION {
            return Err(BundleError::WrongFormat {
                format: bundle.format,
                version: bundle.version,
            });
        }
        if bundle.files.len() > MAX_FILES {
            return Err(BundleError::TooManyFiles(bundle.files.len()));
        }
        Ok(bundle)
    }

    /// Check that the bundle is a build: every path made from its file, the
    /// closure complete, one Activation record that everything hangs off,
    /// and a package index that agrees with it. See the module docs.
    pub fn verify(&self) -> Result<(), BundleError> {
        let mut methods: HashMap<&str, Method> = HashMap::new();
        for (path, file) in &self.files {
            if store_path::name_of(path).is_none() {
                return Err(BundleError::NotAStorePath(path.clone()));
            }
            let method = store_path::method_of(path, file.text.as_bytes(), &file.references)
                .ok_or_else(|| BundleError::PathMismatch(path.clone()))?;
            methods.insert(path, method);
            for r in &file.references {
                if !self.files.contains_key(r) {
                    return Err(BundleError::MissingReference {
                        path: path.clone(),
                        missing: r.clone(),
                    });
                }
            }
        }
        for (what, path) in [("activation", &self.activation), ("index", &self.index)] {
            if !self.files.contains_key(path) {
                return Err(BundleError::MissingEntry {
                    what,
                    path: path.clone(),
                });
            }
        }

        let closure = self.closure_of(&self.activation);
        if let Some(stray) = self
            .files
            .keys()
            .find(|p| !closure.contains(p.as_str()) && **p != self.index)
        {
            return Err(BundleError::Unreachable(stray.clone()));
        }

        let mut records = 0;
        let mut sops_sources: BTreeSet<String> = BTreeSet::new();
        let mut instances: BTreeSet<(String, String)> = BTreeSet::new();
        // Plan and deploy each keep one manifest per object, and which one
        // depends on hash map order, so two copies could plan one and apply
        // the other.
        let mut objects: BTreeSet<ResourceId> = BTreeSet::new();
        for (path, file) in &self.files {
            let is_manifest = store_name(Path::new(path)).starts_with("k8s-");
            if !is_manifest {
                continue;
            }
            let manifest: serde_json::Value =
                serde_json::from_str(&file.text).map_err(|e| BundleError::NotJson {
                    path: path.clone(),
                    message: e.to_string(),
                })?;
            if has_retired_domain(&manifest) {
                return Err(BundleError::RetiredDomain(path.clone()));
            }
            let id = ResourceId::from_value(&manifest);
            if !objects.insert(id.clone()) {
                return Err(BundleError::DuplicateObject(id.display_id()));
            }
            match manifest.pointer("/kind").and_then(|k| k.as_str()) {
                Some(kind) if kind == lifecycle::RECORD_KIND => {
                    records += 1;
                    if *path != self.activation {
                        return Err(BundleError::Records(records));
                    }
                }
                Some(kind) if kind == lifecycle::PACKAGE_INSTANCE_KIND => {
                    instances.insert((
                        text_at(&manifest, "/metadata/namespace"),
                        text_at(&manifest, "/spec/instanceName"),
                    ));
                }
                _ => {}
            }
            if let Some(source) = keys::get(&manifest, keys::SOPS_SOURCE) {
                sops_sources.insert(source.to_string());
            }
        }
        if records != 1 {
            return Err(BundleError::Records(records));
        }
        for (path, method) in &methods {
            if *method == Method::Source && !sops_sources.contains(*path) {
                return Err(BundleError::UnexpectedSource(path.to_string()));
            }
        }

        let record: serde_json::Value = serde_json::from_str(&self.files[&self.activation].text)
            .map_err(|e| BundleError::NotJson {
                path: self.activation.clone(),
                message: e.to_string(),
            })?;
        let labelled = record
            .pointer("/metadata/labels")
            .and_then(|l| l.get(keys::CLUSTER_LABEL))
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if labelled != self.cluster {
            return Err(BundleError::WrongCluster {
                bundle: self.cluster.clone(),
                what: "Activation record",
                other: labelled.to_string(),
            });
        }

        let index = self.package_index()?;
        if index.cluster != self.cluster {
            return Err(BundleError::WrongCluster {
                bundle: self.cluster.clone(),
                what: "kix-packages.json",
                other: index.cluster.clone(),
            });
        }
        for (pi, resources) in &index.packages {
            for p in std::iter::once(pi).chain(resources) {
                // The checks above cover the files named k8s-*, and the
                // graph reads every file the index lists as a manifest.
                if !store_name(p).starts_with("k8s-") {
                    return Err(BundleError::IndexNotManifest(
                        p.to_string_lossy().into_owned(),
                    ));
                }
                let p = p.to_string_lossy();
                if !closure.contains(p.as_ref()) {
                    return Err(BundleError::IndexOutsideClosure(p.into_owned()));
                }
            }
        }
        if instances != record_instances(&record) {
            return Err(BundleError::IndexInstances);
        }
        Ok(())
    }

    /// The build as a [`StoreGraph`], after [`Bundle::verify`]. Its
    /// `result_dir` is `bundle:sha256:<sha256>`, which kix writes to the
    /// record's `kix.run/built-via`: a bundle has no directory on disk.
    pub fn into_graph(&self, sha256: &str) -> Result<StoreGraph, KixEvalError> {
        self.verify().map_err(|e| KixEvalError::StoreGraphError {
            message: e.to_string(),
        })?;
        let index = self
            .package_index()
            .map_err(|e| KixEvalError::StoreGraphError {
                message: e.to_string(),
            })?;
        let closure = self.closure_of(&self.activation);
        let mut ref_cache: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        for path in &closure {
            let refs: Vec<PathBuf> = self.files[*path]
                .references
                .iter()
                .filter(|r| r.as_str() != *path)
                .map(PathBuf::from)
                .collect();
            if !refs.is_empty() {
                ref_cache.insert(PathBuf::from(path), refs);
            }
        }
        // Same order `bulk_load_graph` gives a Nix build's references.
        for refs in ref_cache.values_mut() {
            refs.sort_by_key(|r| store_name(r).to_lowercase());
        }
        let read = |path: &Path| -> Result<serde_json::Value, KixEvalError> {
            let key = path.to_string_lossy();
            let file =
                self.files
                    .get(key.as_ref())
                    .ok_or_else(|| KixEvalError::StoreGraphError {
                        message: format!("{key} is not in the bundle"),
                    })?;
            serde_json::from_str(&file.text).map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to parse JSON from {key}: {e}"),
            })
        };
        StoreGraph::assemble(
            index,
            PathBuf::from(&self.activation),
            PathBuf::from(format!("bundle:sha256:{sha256}")),
            ref_cache,
            &read,
            &|_| {},
        )
    }

    /// The bytes of each SOPS source in the bundle, by store path.
    pub fn sops_sources(&self) -> HashMap<String, Vec<u8>> {
        self.files
            .iter()
            .filter(|(path, file)| {
                store_path::method_of(path, file.text.as_bytes(), &file.references)
                    == Some(Method::Source)
            })
            .map(|(path, file)| (path.clone(), file.text.as_bytes().to_vec()))
            .collect()
    }

    fn package_index(&self) -> Result<KixPackageIndex, BundleError> {
        serde_json::from_str(&self.files[&self.index].text).map_err(|e| BundleError::NotJson {
            path: self.index.clone(),
            message: e.to_string(),
        })
    }

    fn closure_of<'a>(&'a self, root: &'a str) -> BTreeSet<&'a str> {
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut queue: VecDeque<&str> = VecDeque::from([root]);
        while let Some(path) = queue.pop_front() {
            if !seen.insert(path) {
                continue;
            }
            if let Some(file) = self.files.get(path) {
                queue.extend(file.references.iter().map(String::as_str));
            }
        }
        seen
    }
}

/// The SHA-256 of a bundle's bytes, lowercase hex: what `built-via` and a
/// Kix Enterprise statement name it by.
pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Write a bundle of the build in `result_dir`, reading references from the
/// Nix store (`nix path-info`). Needs Nix; reading a bundle does not.
pub fn from_result_dir(
    result_dir: &Path,
    kix_rev: &str,
    receipt: Option<serde_json::Value>,
) -> Result<Bundle, KixEvalError> {
    let err = |message: String| KixEvalError::StoreGraphError { message };
    let resolve = |name: &str| {
        std::fs::canonicalize(result_dir.join(name)).map_err(|e| {
            err(format!(
                "failed to resolve {name} in {}: {e}",
                result_dir.display()
            ))
        })
    };
    let activation = resolve("activation")?;
    let index = resolve("kix-packages.json")?;
    let output = std::process::Command::new("nix")
        .args([
            "path-info",
            "--json",
            "--recursive",
            "--extra-experimental-features",
            "nix-command",
        ])
        .arg(&activation)
        .arg(&index)
        .output()
        .map_err(|e| err(format!("failed to run nix path-info: {e}")))?;
    if !output.status.success() {
        return Err(err(format!(
            "nix path-info failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    let info: serde_json::Value = serde_json::from_slice(&output.stdout).map_err(|e| {
        err(format!(
            "nix path-info printed something other than JSON: {e}"
        ))
    })?;
    let mut files = BTreeMap::new();
    for (path, references) in path_info_references(&info) {
        let text = std::fs::read_to_string(&path)
            .map_err(|e| err(format!("failed to read {path}: {e}")))?;
        files.insert(path, BundleFile { text, references });
    }
    let index_json: KixPackageIndex =
        serde_json::from_str(&files[&index.to_string_lossy().into_owned()].text)
            .map_err(|e| err(format!("failed to parse kix-packages.json: {e}")))?;
    Ok(Bundle {
        format: FORMAT.to_string(),
        version: VERSION,
        kix_rev: kix_rev.to_string(),
        cluster: index_json.cluster,
        activation: activation.to_string_lossy().into_owned(),
        index: index.to_string_lossy().into_owned(),
        files,
        receipt,
    })
}

/// `(path, references)` from `nix path-info --json`, which is an object keyed
/// by path in Nix 2.19 and later and an array of `{path, references}` before.
fn path_info_references(info: &serde_json::Value) -> Vec<(String, Vec<String>)> {
    let refs = |v: &serde_json::Value| -> Vec<String> {
        v.get("references")
            .and_then(|r| r.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    };
    match info {
        serde_json::Value::Object(map) => map.iter().map(|(p, v)| (p.clone(), refs(v))).collect(),
        serde_json::Value::Array(items) => items
            .iter()
            .filter_map(|v| Some((v.get("path")?.as_str()?.to_string(), refs(v))))
            .collect(),
        _ => Vec::new(),
    }
}

fn text_at(v: &serde_json::Value, pointer: &str) -> String {
    v.pointer(pointer)
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string()
}

/// `spec.instances` as `(namespace, instance)` pairs.
fn record_instances(record: &serde_json::Value) -> BTreeSet<(String, String)> {
    record
        .pointer("/spec/instances")
        .and_then(|v| v.as_object())
        .into_iter()
        .flat_map(|by_ns| {
            by_ns.iter().flat_map(|(ns, names)| {
                names
                    .as_object()
                    .into_iter()
                    .flat_map(move |m| m.keys().map(move |k| (ns.clone(), k.clone())))
            })
        })
        .collect()
}

/// Whether a manifest carries a label or annotation key, or an API group,
/// of a retired kix domain. `stamp_annotations` would upgrade those, so the
/// bundle's bytes would differ from what is applied.
fn has_retired_domain(manifest: &serde_json::Value) -> bool {
    let retired_key = |field: &str| {
        manifest
            .pointer(&format!("/metadata/{field}"))
            .and_then(|v| v.as_object())
            .is_some_and(|m| m.keys().any(|k| crate::legacy_domain::is_legacy_key(k)))
    };
    let retired_group = manifest
        .pointer("/apiVersion")
        .and_then(|v| v.as_str())
        .and_then(|v| v.split_once('/'))
        .is_some_and(|(group, _)| crate::legacy_domain::is_legacy_key(&format!("{group}/x")));
    retired_key("labels") || retired_key("annotations") || retired_group
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A bundle of a real `kix-enterprise-test` build on stage1: 26 manifests
    /// and `kix-packages.json`.
    fn real() -> Bundle {
        Bundle::parse(include_bytes!(
            "../../tests/fixtures/bundles/kix-enterprise-test.json"
        ))
        .unwrap()
    }

    fn path_ending(bundle: &Bundle, suffix: &str) -> String {
        bundle
            .files
            .keys()
            .find(|p| p.ends_with(suffix))
            .unwrap()
            .clone()
    }

    #[test]
    fn a_real_build_verifies_and_loads() {
        let bundle = real();
        bundle.verify().unwrap();
        let graph = bundle.into_graph("abc").unwrap();
        assert_eq!(graph.cluster_name, "kix-enterprise-test");
        assert_eq!(graph.result_dir, PathBuf::from("bundle:sha256:abc"));
        assert_eq!(graph.packages.len(), 6);
        assert_eq!(graph.resources.len(), 26);
        let cross: usize = graph.packages.values().map(|p| p.cross_deps.len()).sum();
        assert!(cross > 0, "the shop reads the valkey in another package");
    }

    #[test]
    fn a_changed_byte_is_refused() {
        let mut bundle = real();
        let p = path_ending(
            &bundle,
            "-k8s-ConfigMap-kix-enterprise-test-web-status-page",
        );
        bundle.files.get_mut(&p).unwrap().text = bundle.files[&p].text.replace("status", "statux");
        assert_eq!(bundle.verify(), Err(BundleError::PathMismatch(p)));
    }

    #[test]
    fn a_dropped_reference_is_refused() {
        let mut bundle = real();
        let p = path_ending(
            &bundle,
            "-k8s-Deployment-kix-enterprise-test-web-status-page",
        );
        bundle.files.get_mut(&p).unwrap().references.pop();
        assert_eq!(bundle.verify(), Err(BundleError::PathMismatch(p)));
    }

    #[test]
    fn a_missing_reference_is_refused() {
        let mut bundle = real();
        let p = path_ending(&bundle, "-k8s-Namespace-_cluster_-kix-enterprise-test-web");
        bundle.files.remove(&p);
        assert!(matches!(
            bundle.verify(),
            Err(BundleError::MissingReference { missing, .. }) if missing == p
        ));
    }

    #[test]
    fn a_file_outside_the_build_is_refused() {
        let mut bundle = real();
        let text = r#"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"extra","namespace":"kix-enterprise-test-web"}}"#;
        let path = store_path::path_for(Method::Text, text.as_bytes(), &[], "k8s-ConfigMap-extra");
        bundle.files.insert(
            path.clone(),
            BundleFile {
                text: text.to_string(),
                references: vec![],
            },
        );
        assert_eq!(bundle.verify(), Err(BundleError::Unreachable(path)));
    }

    /// Add a file named `name` holding `text` to the build: the Activation
    /// record references it, and when `package` is given (the end of a
    /// PackageInstance path) kix-packages.json lists it under that package.
    /// Recomputes the paths that change. Returns the new file's path.
    fn add_to_build(bundle: &mut Bundle, name: &str, text: &str, package: Option<&str>) -> String {
        let path = store_path::path_for(Method::Text, text.as_bytes(), &[], name);
        bundle.files.insert(
            path.clone(),
            BundleFile {
                text: text.to_string(),
                references: vec![],
            },
        );
        let mut record = bundle.files.remove(&bundle.activation).unwrap();
        record.references.push(path.clone());
        let record_name = store_path::name_of(&bundle.activation).unwrap().to_string();
        bundle.activation = store_path::path_for(
            Method::Text,
            record.text.as_bytes(),
            &record.references,
            &record_name,
        );
        bundle.files.insert(bundle.activation.clone(), record);
        if let Some(package) = package {
            let mut index = bundle.package_index().unwrap();
            let (_, resources) = index
                .packages
                .iter_mut()
                .find(|(pi, _)| pi.to_string_lossy().ends_with(package))
                .unwrap();
            resources.push(PathBuf::from(&path));
            let text = serde_json::to_string(&index).unwrap();
            bundle.files.remove(&bundle.index);
            bundle.index =
                store_path::path_for(Method::Text, text.as_bytes(), &[], "kix-packages.json");
            bundle.files.insert(
                bundle.index.clone(),
                BundleFile {
                    text,
                    references: vec![],
                },
            );
        }
        path
    }

    #[test]
    fn two_manifests_of_one_object_are_refused() {
        let mut bundle = real();
        let configmap = |value: &str| {
            format!(
                r#"{{"apiVersion":"v1","kind":"ConfigMap","metadata":{{"name":"x","namespace":"kix-enterprise-test-web"}},"data":{{"k":"{value}"}}}}"#
            )
        };
        let package = Some("-k8s-PackageInstance-kix-enterprise-test-web-status-page");
        add_to_build(
            &mut bundle,
            "k8s-ConfigMap-kix-enterprise-test-web-x",
            &configmap("harmless"),
            package,
        );
        add_to_build(
            &mut bundle,
            "k8s-ConfigMap-kix-enterprise-test-web-x-copy",
            &configmap("harmful"),
            package,
        );
        assert_eq!(
            bundle.verify(),
            Err(BundleError::DuplicateObject(
                "ConfigMap/x@kix-enterprise-test-web".to_string()
            ))
        );
    }

    #[test]
    fn an_index_entry_not_named_as_a_manifest_is_refused() {
        let mut bundle = real();
        let record = serde_json::json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {"name": "other", "labels": {(keys::CLUSTER_LABEL): "kix-enterprise-test"}},
        })
        .to_string();
        let path = add_to_build(
            &mut bundle,
            "extra",
            &record,
            Some("-k8s-PackageInstance-kix-enterprise-test-web-status-page"),
        );
        assert_eq!(bundle.verify(), Err(BundleError::IndexNotManifest(path)));
    }

    #[test]
    fn a_bundle_for_another_cluster_is_refused() {
        let mut bundle = real();
        bundle.cluster = "stage1".to_string();
        assert!(matches!(
            bundle.verify(),
            Err(BundleError::WrongCluster { .. })
        ));
    }

    #[test]
    fn a_misnamed_path_is_refused() {
        let mut bundle = real();
        let p = path_ending(&bundle, "-k8s-Namespace-_cluster_-kix-enterprise-test-web");
        let file = bundle.files.remove(&p).unwrap();
        let renamed = p.replace("-k8s-Namespace", "-k8s-Namespacx");
        bundle.files.insert(renamed.clone(), file);
        assert!(bundle.verify().is_err());
    }

    #[test]
    fn another_format_version_is_refused() {
        let mut bundle = real();
        bundle.version = 2;
        let bytes = serde_json::to_vec(&bundle).unwrap();
        assert!(matches!(
            Bundle::parse(&bytes),
            Err(BundleError::WrongFormat { version: 2, .. })
        ));
    }

    #[test]
    fn an_unknown_field_is_refused() {
        let mut value: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../tests/fixtures/bundles/kix-enterprise-test.json"
        ))
        .unwrap();
        value["extra"] = serde_json::json!(1);
        assert!(matches!(
            Bundle::parse(&serde_json::to_vec(&value).unwrap()),
            Err(BundleError::Unreadable(_))
        ));
    }

    #[test]
    fn path_info_in_either_shape() {
        let object = serde_json::json!({"/nix/store/a-x": {"references": ["/nix/store/b-y"]}});
        let array =
            serde_json::json!([{"path": "/nix/store/a-x", "references": ["/nix/store/b-y"]}]);
        let want = vec![(
            "/nix/store/a-x".to_string(),
            vec!["/nix/store/b-y".to_string()],
        )];
        assert_eq!(path_info_references(&object), want);
        assert_eq!(path_info_references(&array), want);
    }
}
