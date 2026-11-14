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
//!
//! The index also names each object (`names`), so `kix status` can say which
//! object is missing on a machine that does not have the build. Records
//! written before 0.10 have no `names`, and readers before 0.10 skip the
//! field. The API group of each named object outside the core group is in
//! `groups`, a separate field so that readers which do not know it still
//! read `names`.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::store_graph::{StoreGraph, store_hash};
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

/// The format this release writes and reads.
pub const FORMAT: u64 = 1;

/// Largest index, in bytes of JSON, that a deploy writes.
///
/// A cluster keeps 10 to 50 records, and every command that lists records
/// reads all of their indexes. A typical index of about 13 KB makes that
/// list about 650 KB. At this cap the worst case is about 7.5 MB, where a
/// 512 KiB cap would allow 25 MB. An index costs about 42 bytes an object
/// (9.4 KB for the 223 objects of `test-cnpg`, measured on kind), so 150 KiB
/// still fits some 3,600 objects, more than any build Kix has measured.
///
/// The names of the objects cost about 80 bytes more an object, so an index
/// with names fits some 1,200 objects. Past that, a deploy writes the index
/// without its names ([`RecordPackageIndex::without_names`]).
pub const MAX_BYTES: usize = 150 * 1024;

/// Which package each resource of a build belongs to.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordPackageIndex {
    /// Always [`FORMAT`] once read. Readers check it before the rest.
    pub format: u64,
    /// Packages keyed `namespace/instance`, as plans key them.
    pub packages: BTreeMap<String, IndexedPackage>,
    /// Identity hashes of the resources no package lists, sorted.
    pub cluster_level: Vec<String>,
    /// The kind, namespace, and name of each resource, keyed by identity
    /// hash. Empty in an index written before 0.10, or one too large to
    /// store with its names.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub names: BTreeMap<String, ObjectName>,
    /// The API group of each named object outside the core group, keyed by
    /// identity hash. `None` in an index written before the field existed,
    /// whose names do not say their group, and in an index without names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub groups: Option<BTreeMap<String, String>>,
}

/// The name an index gives one object.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexedName {
    /// The index says the object's group.
    Named(ResourceId),
    /// The index was written before it recorded groups, so the group of the
    /// object is not known.
    GroupUnknown(ObjectName),
}

/// The kind, namespace, and name of one object, stored as a JSON array of
/// three strings. The namespace of a cluster-scoped object is `""`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ObjectName(pub String, pub String, pub String);

impl ObjectName {
    /// Return the name of the object `rid` names.
    pub fn of(rid: &ResourceId) -> ObjectName {
        let namespace = if rid.namespace == CLUSTER_SCOPED {
            String::new()
        } else {
            rid.namespace.clone()
        };
        ObjectName(rid.kind.clone(), namespace, rid.name.clone())
    }

    /// Return the object's [`ResourceId`] in API group `group`.
    pub fn resource_id(&self, group: &str) -> ResourceId {
        ResourceId {
            group: group.to_string(),
            kind: self.0.clone(),
            namespace: if self.1.is_empty() {
                CLUSTER_SCOPED.to_string()
            } else {
                self.1.clone()
            },
            name: self.2.clone(),
        }
    }
}

/// One package of a [`RecordPackageIndex`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexedPackage {
    /// Identity hash of the package's own `PackageInstance`.
    pub instance: String,
    /// Identity hashes of the package's resources, in the build's order.
    pub resources: Vec<String>,
}

impl RecordPackageIndex {
    /// Return the index of `graph`.
    pub fn of(graph: &StoreGraph) -> RecordPackageIndex {
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
        let mut names = BTreeMap::new();
        let mut groups = BTreeMap::new();
        for (path, node) in &graph.resources {
            let rid = ResourceId::from_value(&node.manifest);
            let hash = store_hash(path);
            if !rid.group.is_empty() {
                groups.insert(hash.clone(), rid.group.clone());
            }
            names.insert(hash, ObjectName::of(&rid));
        }
        RecordPackageIndex {
            format: FORMAT,
            packages,
            cluster_level,
            names,
            groups: Some(groups),
        }
    }

    /// Return the index without the names of its objects.
    pub fn without_names(&self) -> RecordPackageIndex {
        RecordPackageIndex {
            names: BTreeMap::new(),
            groups: None,
            ..self.clone()
        }
    }

    /// Return the name of the object with identity hash `hash`, when the
    /// index has names.
    pub fn name_of(&self, hash: &str) -> Option<IndexedName> {
        let name = self.names.get(hash)?;
        Some(match &self.groups {
            Some(groups) => {
                IndexedName::Named(name.resource_id(groups.get(hash).map_or("", String::as_str)))
            }
            None => IndexedName::GroupUnknown(name.clone()),
        })
    }

    /// Return the identity hash of every resource the index lists: each
    /// package's `PackageInstance` and resources, and the cluster-level ones.
    pub fn hashes(&self) -> HashSet<&str> {
        self.packages
            .values()
            .flat_map(|p| std::iter::once(&p.instance).chain(&p.resources))
            .chain(&self.cluster_level)
            .map(String::as_str)
            .collect()
    }

    /// Read an index from `status.packageIndex`. Return `None`, with a debug
    /// log, when it is in another format or does not parse.
    pub fn from_value(value: &Value) -> Option<RecordPackageIndex> {
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
        let index = RecordPackageIndex::of(&graph());
        let a = |c: &str| format!("{c:a>32}");
        assert_eq!(
            index.to_value(),
            json!({
                "format": FORMAT,
                "packages": {
                    "default/web": { "instance": a("1"), "resources": [a("3"), a("2")] },
                },
                "clusterLevel": [a("4")],
                "names": {
                    a("1"): ["PackageInstance", "default", "web"],
                    a("2"): ["ConfigMap", "default", "a"],
                    a("3"): ["ConfigMap", "default", "b"],
                    a("4"): ["Namespace", "", "default"],
                },
                "groups": { a("1"): crate::manifest::keys::GROUP },
            })
        );
        assert_eq!(
            RecordPackageIndex::from_value(&index.to_value()),
            Some(index)
        );
    }

    fn named_str(index: &RecordPackageIndex, hash: &str) -> Option<String> {
        match index.name_of(hash)? {
            IndexedName::Named(rid) => Some(rid.to_string()),
            IndexedName::GroupUnknown(name) => panic!("{name:?}"),
        }
    }

    #[test]
    fn hashes_lists_instances_resources_and_cluster_level() {
        let index = RecordPackageIndex::of(&graph());
        let a = |c: &str| format!("{c:a>32}");
        let expected: Vec<String> = ["1", "2", "3", "4"].iter().map(|c| a(c)).collect();
        assert_eq!(
            index.hashes(),
            expected.iter().map(String::as_str).collect::<HashSet<_>>()
        );
    }

    /// The names give each object's identity, and an index without them,
    /// as one written before 0.10, reads with no names.
    #[test]
    fn names_give_each_object_its_identity() {
        let index = RecordPackageIndex::of(&graph());
        let a = |c: &str| format!("{c:a>32}");
        assert_eq!(
            named_str(&index, &a("4")).as_deref(),
            Some("Namespace/default")
        );
        assert_eq!(
            named_str(&index, &a("2")).as_deref(),
            Some("ConfigMap/a@default")
        );
        let old = index.without_names();
        assert!(!old.to_value().as_object().unwrap().contains_key("names"));
        let read = RecordPackageIndex::from_value(&old.to_value()).unwrap();
        assert_eq!(read.name_of(&a("2")), None);
        assert_eq!(read.hashes(), index.hashes());
    }

    /// A named object outside the core group keeps its group, and an index
    /// written before `groups` existed does not say any object's group.
    #[test]
    fn names_carry_the_api_group() {
        let index = RecordPackageIndex::of(&graph());
        let a = |c: &str| format!("{c:a>32}");
        let named = |hash: &str| match index.name_of(hash) {
            Some(IndexedName::Named(rid)) => rid,
            other => panic!("{other:?}"),
        };
        assert_eq!(named(&a("1")).group, crate::manifest::keys::GROUP);
        assert_eq!(named(&a("1")).kind, "PackageInstance");
        assert_eq!(named(&a("2")).group, "");

        let mut value = index.to_value();
        value.as_object_mut().unwrap().remove("groups");
        let read = RecordPackageIndex::from_value(&value).unwrap();
        assert_eq!(
            read.name_of(&a("1")),
            Some(IndexedName::GroupUnknown(ObjectName(
                "PackageInstance".into(),
                "default".into(),
                "web".into()
            )))
        );
    }

    /// An index in a format this release does not know, or with no format,
    /// is not read.
    #[test]
    fn an_index_in_an_unknown_format_is_ignored() {
        let mut value = RecordPackageIndex::of(&graph()).to_value();
        value["format"] = json!(FORMAT + 1);
        assert_eq!(RecordPackageIndex::from_value(&value), None);
        value.as_object_mut().unwrap().remove("format");
        assert_eq!(RecordPackageIndex::from_value(&value), None);
        assert_eq!(
            RecordPackageIndex::from_value(&json!({ "format": FORMAT, "packages": [] })),
            None
        );
    }

    /// Placing the build's own objects from its index gives the build's own
    /// package graph, as placing them from the build does.
    #[test]
    fn placing_from_the_index_matches_placing_from_the_build() {
        let build = graph();
        let index = RecordPackageIndex::of(&build);
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
