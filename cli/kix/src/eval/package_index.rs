//! The package index a deploy writes to its Activation record's
//! `status.packageIndex`.
//!
//! When the deployed build is not on this machine, Kix rebuilds the old side
//! of a comparison from live objects ([`super::store_graph::StoreGraph::synthesize_placed`]).
//! This index says which package each of those objects belonged to in the
//! deployed build, so an object that moved between packages shows under both.
//!
//! The index is keyed by identity hash, the hash part of a resource's store
//! path, which Kix also stamps on every object as `kix.run/identity-hash`.
//! It carries a format number. A reader that does not know the format
//! ignores the index and places objects the way it would without one.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::store_graph::{StoreGraph, store_hash};

/// The format this release writes and reads.
pub const FORMAT: u64 = 1;

/// Largest index, in bytes of JSON, that a deploy writes. A record is kept
/// 10 to 50 times, and a larger index would make each of them heavy for
/// etcd. At about 35 bytes an object, this allows some 14,000 objects.
pub const MAX_BYTES: usize = 512 * 1024;

/// Which package each resource of a build belongs to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageIndex {
    /// Always [`FORMAT`] once read. Readers check it before the rest.
    pub format: u64,
    /// Packages keyed `namespace/instance`, as plans key them.
    pub packages: BTreeMap<String, IndexedPackage>,
    /// Identity hashes of the resources no package lists, sorted.
    pub cluster_level: Vec<String>,
}

/// One package of a [`PackageIndex`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexedPackage {
    /// Identity hash of the package's own `PackageInstance`.
    pub instance: String,
    /// Identity hashes of the package's resources, in the build's order.
    pub resources: Vec<String>,
}

impl PackageIndex {
    /// Return the index of `graph`.
    pub fn of(graph: &StoreGraph) -> PackageIndex {
        let mut in_package = HashSet::new();
        let mut packages = BTreeMap::new();
        for p in graph.packages.values() {
            in_package.insert(&p.store_path);
            in_package.extend(&p.resource_paths);
            packages.insert(
                format!("{}/{}", p.namespace, p.instance_name),
                IndexedPackage {
                    instance: store_hash(&p.store_path),
                    resources: p.resource_paths.iter().map(|r| store_hash(r)).collect(),
                },
            );
        }
        let mut cluster_level: Vec<String> = graph
            .resources
            .keys()
            .filter(|p| !in_package.contains(p))
            .map(|p| store_hash(p))
            .collect();
        cluster_level.sort();
        PackageIndex {
            format: FORMAT,
            packages,
            cluster_level,
        }
    }

    /// Read an index from `status.packageIndex`. Return `None`, with a debug
    /// log, when it is in another format or does not parse.
    pub fn from_value(value: &Value) -> Option<PackageIndex> {
        let format = value.get("format").and_then(Value::as_u64);
        if format != Some(FORMAT) {
            tracing::debug!(
                ?format,
                "ignoring a package index in a format this release does not read"
            );
            return None;
        }
        serde_json::from_value(value.clone())
            .inspect_err(|e| tracing::debug!(error = %e, "ignoring a malformed package index"))
            .ok()
    }

    /// Return the index as the JSON the record stores.
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).expect("a package index serializes")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::store_graph::{KixPackageIndex, ResourceNode};
    use serde_json::json;
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn path(hash: &str, name: &str) -> PathBuf {
        PathBuf::from(format!("/nix/store/{hash:a>32}-k8s-{name}"))
    }

    fn pi(ns: &str, instance: &str) -> Value {
        json!({
            "apiVersion": crate::manifest::keys::API_VERSION,
            "kind": "PackageInstance",
            "metadata": { "name": instance, "namespace": ns },
            "spec": { "instanceName": instance },
        })
    }

    fn cm(ns: &str, name: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": name, "namespace": ns },
        })
    }

    /// Assemble a graph from a `kix-packages.json` shape with one package of
    /// two resources, a marker it lists, and a cluster-level Namespace.
    fn graph() -> StoreGraph {
        let web = path("1", "PackageInstance-web");
        let a = path("2", "ConfigMap-a");
        let b = path("3", "ConfigMap-b");
        let ns = path("4", "Namespace-default");
        let index: KixPackageIndex = serde_json::from_value(json!({
            "cluster": "c",
            "packages": { (web.to_str().unwrap()): [b.to_str().unwrap(), a.to_str().unwrap()] },
        }))
        .unwrap();
        let mut files: HashMap<PathBuf, Value> = HashMap::from([
            (web.clone(), pi("default", "web")),
            (a.clone(), cm("default", "a")),
            (b.clone(), cm("default", "b")),
            (
                ns.clone(),
                json!({ "apiVersion": "v1", "kind": "Namespace", "metadata": { "name": "default" } }),
            ),
        ]);
        let ref_cache = HashMap::from([(PathBuf::from("/nix/store/activation"), vec![ns])]);
        let mut g = StoreGraph::assemble(
            index,
            PathBuf::from("/nix/store/activation"),
            PathBuf::new(),
            ref_cache,
            &mut |p| Ok(serde_json::to_vec(&files.remove(p).unwrap()).unwrap()),
            &|_| {},
        )
        .unwrap();
        crate::eval::stamp::stamp_annotations(&mut g);
        g
    }

    /// The index lists each package's instance and resources by identity
    /// hash in the build's order, and the rest as cluster-level.
    #[test]
    fn the_index_lists_packages_and_cluster_level_resources_by_hash() {
        let index = PackageIndex::of(&graph());
        let a = |c: &str| format!("{c:a>32}");
        assert_eq!(
            index.to_value(),
            json!({
                "format": FORMAT,
                "packages": {
                    "default/web": { "instance": a("1"), "resources": [a("3"), a("2")] },
                },
                "clusterLevel": [a("4")],
            })
        );
        assert_eq!(PackageIndex::from_value(&index.to_value()), Some(index));
    }

    /// An index in a format this release does not know, or with no format,
    /// is not read.
    #[test]
    fn an_index_in_an_unknown_format_is_ignored() {
        let mut value = PackageIndex::of(&graph()).to_value();
        value["format"] = json!(FORMAT + 1);
        assert_eq!(PackageIndex::from_value(&value), None);
        value.as_object_mut().unwrap().remove("format");
        assert_eq!(PackageIndex::from_value(&value), None);
        assert_eq!(
            PackageIndex::from_value(&json!({ "format": FORMAT, "packages": [] })),
            None
        );
    }

    /// Placing the build's own objects from its index gives the build's own
    /// package graph, as placing them from the build does.
    #[test]
    fn placing_from_the_index_matches_placing_from_the_build() {
        let build = graph();
        let index = PackageIndex::of(&build);
        let manifests: Vec<Value> = build
            .resources
            .values()
            .map(|r: &ResourceNode| r.manifest.clone())
            .collect();
        // Without its package stamps, only the index can place an object.
        let unstamped: Vec<Value> = manifests
            .iter()
            .cloned()
            .map(|mut m| {
                let anns = m["metadata"]["annotations"].as_object_mut().unwrap();
                anns.remove(crate::manifest::keys::PACKAGE);
                anns.remove(crate::manifest::keys::PACKAGE_NAMESPACE);
                m
            })
            .collect();
        let empty = StoreGraph::empty("c");
        let from_index = StoreGraph::synthesize_placed(&unstamped, &empty, &[&index]);
        let from_build = StoreGraph::synthesize(&manifests, &build);
        let shape = |g: &StoreGraph| {
            let mut v: Vec<(String, Vec<String>)> = g
                .packages
                .values()
                .map(|p| {
                    let mut names: Vec<String> = p
                        .resource_paths
                        .iter()
                        .map(|r| {
                            g.resources[r].manifest["metadata"]["name"]
                                .as_str()
                                .unwrap()
                                .into()
                        })
                        .collect();
                    names.sort();
                    (format!("{}/{}", p.namespace, p.instance_name), names)
                })
                .collect();
            v.sort();
            v
        };
        assert_eq!(shape(&from_index), shape(&from_build));
        assert_eq!(
            shape(&from_index),
            vec![("default/web".to_string(), vec!["a".into(), "b".into()])]
        );
    }
}
