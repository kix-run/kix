//! What a revision holds, how it is named, and how a build's objects are
//! split into revisions.

use std::collections::BTreeMap;
use std::path::Path;

use kube::api::DynamicObject;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::eval::package_index::InstanceGroups;
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

/// Hex digits of the spec's hash in a revision's name. It is as long as a
/// Nix store hash, which names every object of a build.
const HASH_LEN: usize = 32;

/// Longest name Kubernetes accepts for a cluster-scoped object.
const MAX_NAME: usize = 253;

/// One object of a revision.
///
/// The field order is the sort order, so objects sort by build hash first.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct RevisionObject {
    /// The object's build hash, as `kix.run/identity-hash` carries it.
    pub hash: String,
    /// The API group, `""` for the core group.
    #[serde(default)]
    pub group: String,
    pub kind: String,
    /// `None` for a cluster-scoped object.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
}

impl RevisionObject {
    fn of(path: &Path, manifest: &Value) -> RevisionObject {
        let rid = ResourceId::from_value(manifest);
        RevisionObject {
            hash: store_hash(path),
            group: rid.group,
            kind: rid.kind,
            namespace: (rid.namespace != CLUSTER_SCOPED).then_some(rid.namespace),
            name: rid.name,
        }
    }
}

/// Which part of a Kix cluster a revision covers.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Slot {
    /// One package instance.
    Instance { namespace: String, name: String },
    /// The objects of a build that belong to no instance, such as
    /// Namespaces.
    ClusterLevel,
    /// The objects a deploy that did not prune left on the cluster.
    KeptOrphans,
}

/// The `spec` of a revision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevisionSpec {
    /// The Kix cluster's name.
    pub cluster: String,
    pub slot: Slot,
    /// Sorted, so two machines with the same build write the same bytes.
    pub objects: Vec<RevisionObject>,
}

impl RevisionSpec {
    /// Return a spec of `objects`, sorted.
    pub fn new(cluster: &str, slot: Slot, mut objects: Vec<RevisionObject>) -> RevisionSpec {
        objects.sort();
        objects.dedup();
        RevisionSpec {
            cluster: cluster.to_string(),
            slot,
            objects,
        }
    }
}

/// Return the name of the revision with `spec`: the Kix cluster's name, a
/// dash, and a hash of `spec`.
///
/// The hash covers the JSON of `spec` with its objects in sorted order. A
/// cluster name too long to fit is cut, and any dash or dot at the cut is
/// dropped, so the hash stays whole and the name stays valid.
pub fn name_of(spec: &RevisionSpec) -> String {
    let mut sorted = spec.clone();
    sorted.objects.sort();
    let bytes = serde_json::to_vec(&sorted).expect("a revision spec serializes");
    let hash = &format!("{:x}", Sha256::digest(&bytes))[..HASH_LEN];
    let room = MAX_NAME - HASH_LEN - 1;
    let mut prefix = spec.cluster.as_str();
    if prefix.len() > room {
        let mut cut = room;
        while !prefix.is_char_boundary(cut) {
            cut -= 1;
        }
        prefix = prefix[..cut].trim_end_matches(['-', '.']);
    }
    format!("{prefix}-{hash}")
}

/// A revision: its name, its `spec`, and `status.applied`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Revision {
    pub name: String,
    pub spec: RevisionSpec,
    /// Each object's build hash mapped to the hash Kix applied.
    pub applied: BTreeMap<String, String>,
}

/// Why a revision read from the API cannot be used.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReadError {
    #[error(
        "{} `{name}` has a `spec` that does not match its name (the name's hash belongs to `{expected}`). Someone changed or replaced it outside Kix, so Kix cannot trust the list of objects it holds",
        super::KIND
    )]
    NameMismatch { name: String, expected: String },
    #[error("{} `{name}` cannot be read: {reason}", super::KIND)]
    Malformed { name: String, reason: String },
}

impl Revision {
    /// Return a new revision of `spec`, named for it, with no applied
    /// hashes.
    pub fn new(spec: RevisionSpec) -> Revision {
        Revision {
            name: name_of(&spec),
            spec,
            applied: BTreeMap::new(),
        }
    }

    /// Read a revision from the API. Refuse one whose name does not match
    /// its `spec`.
    pub fn from_object(obj: &DynamicObject) -> Result<Revision, ReadError> {
        let name = obj.metadata.name.clone().unwrap_or_default();
        let malformed = |reason: String| ReadError::Malformed {
            name: name.clone(),
            reason,
        };
        let spec_value = obj
            .data
            .get("spec")
            .ok_or_else(|| malformed("it has no `spec`".into()))?;
        let spec: RevisionSpec = serde_json::from_value(spec_value.clone())
            .map_err(|e| malformed(format!("its `spec` does not parse: {e}")))?;
        let expected = name_of(&spec);
        if expected != name {
            return Err(ReadError::NameMismatch { name, expected });
        }
        let applied = match obj.data.pointer("/status/applied") {
            None | Some(Value::Null) => BTreeMap::new(),
            Some(value) => serde_json::from_value(value.clone())
                .map_err(|e| malformed(format!("its `status.applied` does not parse: {e}")))?,
        };
        Ok(Revision {
            name,
            spec,
            applied,
        })
    }
}

/// The revisions of one build: one for each package instance and one for
/// the cluster level.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionSet {
    /// Keyed `namespace/instance`, as plans key instances.
    pub instances: BTreeMap<String, Revision>,
    pub cluster_level: Revision,
}

impl RevisionSet {
    /// Split the objects of `graph` into revisions of Kix cluster
    /// `cluster`, grouped as the package index groups them.
    ///
    /// The cluster level leaves out the build's Activation record. Its name
    /// and hash change with every build, so including it would give the
    /// cluster level a new revision on every deploy.
    pub fn of(cluster: &str, graph: &StoreGraph) -> RevisionSet {
        let groups = InstanceGroups::of(graph);
        let object = |path: &Path| {
            graph
                .resources
                .get(path)
                .map(|node| RevisionObject::of(path, &node.manifest))
        };
        let instances = groups
            .instances
            .iter()
            .map(|(key, group)| {
                let node = &graph.packages[group.instance];
                let objects = std::iter::once(group.instance)
                    .chain(group.resources.iter().map(|p| p.as_path()))
                    .filter_map(object)
                    .collect();
                let slot = Slot::Instance {
                    namespace: node.namespace.clone(),
                    name: node.instance_name.clone(),
                };
                (
                    key.clone(),
                    Revision::new(RevisionSpec::new(cluster, slot, objects)),
                )
            })
            .collect();
        let cluster_objects = groups
            .cluster_level
            .iter()
            .filter(|p| **p != graph.activation_path)
            .filter_map(|p| object(p))
            .collect();
        RevisionSet {
            instances,
            cluster_level: Revision::new(RevisionSpec::new(
                cluster,
                Slot::ClusterLevel,
                cluster_objects,
            )),
        }
    }

    /// Return every revision of the set: the instances' in key order, then
    /// the cluster level.
    pub fn all(&self) -> impl Iterator<Item = &Revision> {
        self.instances
            .values()
            .chain(std::iter::once(&self.cluster_level))
    }
}
