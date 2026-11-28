//! What a revision holds, how it is named, and how a build's objects are
//! split into revisions.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use kube::api::DynamicObject;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::eval::package_index::InstanceGroups;
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::manifest::keys;
use crate::manifest::lifecycle;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

/// Hex digits of the spec's hash in a revision's name. It is as long as a
/// Nix store hash, which names every object of a build.
const HASH_LEN: usize = 32;

/// Longest name Kubernetes accepts for a cluster-scoped object.
const MAX_NAME: usize = 253;

/// The largest object the API server can store: etcd's default request
/// limit (`--max-request-bytes`), which Kubernetes clusters keep.
pub const MAX_BYTES: usize = 1_572_864;

/// Room each object takes in `status.applied` once Kix writes its hashes:
/// two 32-digit hashes and their punctuation, and the entry that records
/// who wrote it in `metadata.managedFields`.
const APPLIED_BYTES: usize = 120;

/// Room for `apiVersion`, `kind`, and `metadata`.
const OVERHEAD_BYTES: usize = 4096;

/// The hash a kept-orphans list that `kix gc` rebuilt gives each object.
/// The rebuild cannot know what build wanted the object to be. An object
/// hash is hex digits only, so this value never equals one, and no plan
/// skips an object for it.
pub const REBUILT: &str = "rebuilt";

/// The format of the revisions this Kix writes. Format 1 has no `needs`
/// and no `slot.lifecycle`, and its `spec` has no `format` field.
pub const FORMAT: u32 = 2;

fn format_one() -> u32 {
    1
}

fn is_format_one(format: &u32) -> bool {
    *format == 1
}

/// One object of a revision.
///
/// The field order is the sort order, so objects sort by hash first.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct RevisionObject {
    /// What the build that the revision records wanted the object to be.
    /// Kix compares it for equality and reads nothing else from it.
    ///
    /// For an object of a build this Kix read, it is the object hash of the
    /// build's manifest ([`crate::manifest::hash::object_hash`]). In a
    /// revision converted from a record an older Kix wrote, it is that
    /// build's Nix store hash, which never equals an object hash. In a
    /// kept-orphans list that `kix gc` rebuilt, it is [`REBUILT`]. No reader
    /// joins it with a build's store hashes: every join between a revision
    /// and a build goes by the object's group, kind, namespace, and name.
    pub hash: String,
    /// The API group, `""` for the core group.
    #[serde(default)]
    pub group: String,
    pub kind: String,
    /// `None` for a cluster-scoped object.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
    /// The objects this one depends on, sorted. Empty in a format 1
    /// revision, where the edges are not recorded.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub needs: Vec<Need>,
}

/// One object a revision entry depends on, by name.
///
/// It is an entry with fields rather than one string, because an object's
/// name can hold a colon, such as the ClusterRole `system:auth-delegator`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Need {
    /// The API group, omitted for the core group.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub group: String,
    pub kind: String,
    /// `None` for a cluster-scoped object.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
    /// The relation the `kix.run/depends-on` entry names, such as
    /// `requires` or `controller`, or `None` for an entry with none.
    #[serde(rename = "as", default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

impl Need {
    /// Return the entry for the object `rid` in relation `role`.
    pub fn of(rid: &ResourceId, role: Option<&str>) -> Need {
        Need {
            group: rid.group.clone(),
            kind: rid.kind.clone(),
            namespace: (rid.namespace != CLUSTER_SCOPED).then(|| rid.namespace.clone()),
            name: rid.name.clone(),
            role: role.map(str::to_string),
        }
    }

    /// Return the entries of the `kix.run/depends-on` value of `manifest`,
    /// sorted and once each. `resolve` names the object an identity hash
    /// stands for. An entry it cannot name is left out.
    pub fn of_depends_on(
        manifest: &Value,
        resolve: impl Fn(&str) -> Option<ResourceId>,
    ) -> Vec<Need> {
        let Some(value) = keys::get(manifest, keys::DEPENDS_ON) else {
            return Vec::new();
        };
        let mut needs: Vec<Need> = keys::depends_on_entries(value)
            .filter_map(|(role, hash)| Some(Need::of(&resolve(hash)?, role)))
            .collect();
        needs.sort();
        needs.dedup();
        needs
    }

    /// Return the group, kind, namespace, and name of the object.
    pub fn resource_id(&self) -> ResourceId {
        ResourceId {
            group: self.group.clone(),
            kind: self.kind.clone(),
            namespace: self
                .namespace
                .clone()
                .unwrap_or_else(|| CLUSTER_SCOPED.to_string()),
            name: self.name.clone(),
        }
    }

    /// Return whether the entry names the controller of a custom resource.
    pub fn is_controller(&self) -> bool {
        self.role.as_deref() == Some(keys::CONTROLLER_RELATION)
    }
}

/// An object of a revision as the applied hashes key it: its resource id
/// and its build hash. Code that maps an object to its applied hash keys on
/// this rather than on the whole [`RevisionObject`], so a field of the entry
/// that says nothing about which build was applied cannot drop the hash.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct AppliedKey {
    pub rid: ResourceId,
    pub hash: String,
}

impl RevisionObject {
    /// Return the key the applied hashes use for this object.
    pub fn applied_key(&self) -> AppliedKey {
        // List every field, so a new field of the entry is a choice here.
        let RevisionObject {
            hash,
            group: _,
            kind: _,
            namespace: _,
            name: _,
            needs: _,
        } = self;
        AppliedKey {
            rid: self.resource_id(),
            hash: hash.clone(),
        }
    }

    /// Return this object with `needs`, sorted and once each.
    pub fn with_needs(mut self, needs: impl IntoIterator<Item = Need>) -> RevisionObject {
        self.needs = needs.into_iter().collect();
        self.needs.sort();
        self.needs.dedup();
        self
    }

    /// Return the object `manifest` describes, with its object hash.
    pub fn of_manifest(manifest: &Value) -> RevisionObject {
        RevisionObject::with_hash(crate::manifest::hash::object_hash(manifest), manifest)
    }

    /// Return the object's group, kind, namespace, and name, without its
    /// build hash.
    pub fn resource_id(&self) -> ResourceId {
        ResourceId {
            group: self.group.clone(),
            kind: self.kind.clone(),
            namespace: self
                .namespace
                .clone()
                .unwrap_or_else(|| CLUSTER_SCOPED.to_string()),
            name: self.name.clone(),
        }
    }

    fn with_hash(hash: String, manifest: &Value) -> RevisionObject {
        let rid = ResourceId::from_value(manifest);
        RevisionObject {
            hash,
            group: rid.group,
            kind: rid.kind,
            namespace: (rid.namespace != CLUSTER_SCOPED).then_some(rid.namespace),
            name: rid.name,
            needs: Vec::new(),
        }
    }
}

/// One import marker of a revision: an object of the build that stands for
/// something Kix does not make, such as a CRD another tool installs. Kix
/// writes no object for it. Edges pass through it, so a custom resource that
/// needs a CRD marker still orders after the operator the marker needs.
///
/// A marker is always a `PackageInstance` of the group `kix.run`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct RevisionImport {
    /// `None` for a marker with no namespace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
    /// The object hash of the marker's manifest, as for a
    /// [`RevisionObject`].
    pub hash: String,
    /// What the marker stands for, or `None` for a marker that names no
    /// target.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<ImportedObject>,
    /// The objects the marker depends on, sorted.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub needs: Vec<Need>,
}

/// The object an import marker stands for.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ImportedObject {
    #[serde(rename = "apiVersion")]
    pub api_version: String,
    pub kind: String,
    /// `None` for a cluster-scoped object.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
}

impl ImportedObject {
    /// Return the group, kind, namespace, and name of the object.
    pub fn resource_id(&self) -> ResourceId {
        ResourceId::new(
            crate::manifest::types::api_group(&self.api_version),
            &self.kind,
            self.namespace.as_deref().unwrap_or(CLUSTER_SCOPED),
            &self.name,
        )
    }
}

impl RevisionImport {
    /// Return the import the built marker `manifest` describes, with its
    /// object hash and `needs`. A marker whose target cannot be read records
    /// no target: planning refuses such a build before it writes anything.
    pub fn of_marker(manifest: &Value, needs: Vec<Need>) -> RevisionImport {
        let rid = ResourceId::from_value(manifest);
        let target = crate::cluster::readiness::import_target_from_manifest(manifest)
            .ok()
            .flatten()
            .map(|t| ImportedObject {
                api_version: t.api_version,
                kind: t.kind,
                namespace: t.namespace,
                name: t.name,
            });
        RevisionImport {
            namespace: (rid.namespace != CLUSTER_SCOPED).then_some(rid.namespace),
            name: rid.name,
            hash: crate::manifest::hash::object_hash(manifest),
            target,
            needs,
        }
    }

    /// Return the marker's group, kind, namespace, and name.
    pub fn resource_id(&self) -> ResourceId {
        ResourceId::new(
            keys::GROUP,
            crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
            self.namespace.as_deref().unwrap_or(CLUSTER_SCOPED),
            &self.name,
        )
    }
}

/// Which part of a Kix cluster a revision covers.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Slot {
    /// One package instance. `lifecycle` is the lifecycle its package's
    /// `meta` gives it, which the CLI stamps as `kix.run/lifecycle` on the
    /// instance's objects.
    Instance {
        namespace: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        lifecycle: Option<String>,
    },
    /// The objects of a build that belong to no instance, such as
    /// Namespaces.
    ClusterLevel,
    /// The objects a deploy that did not prune left on the cluster.
    KeptOrphans,
}

/// The `spec` of a revision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevisionSpec {
    /// The format the revision was written in. A format 1 `spec` has no
    /// `format` field, and it serializes without one so that its name still
    /// matches.
    #[serde(default = "format_one", skip_serializing_if = "is_format_one")]
    pub format: u32,
    /// The Kix cluster's name.
    pub cluster: String,
    pub slot: Slot,
    /// Sorted, so two machines with the same build write the same bytes.
    /// Import markers are not among them.
    pub objects: Vec<RevisionObject>,
    /// The instance's import markers, sorted. Empty before format 2.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub imports: Vec<RevisionImport>,
}

impl RevisionSpec {
    /// Return a spec of `objects` in this Kix's format, sorted, with one
    /// entry for each object and build hash. Entries with the same object
    /// and build hash came from the same manifest, so they have the same
    /// edges when their sources recorded them all. Their `needs` are merged,
    /// so an entry that lost an edge on the way does not lose it here.
    pub fn new(cluster: &str, slot: Slot, objects: Vec<RevisionObject>) -> RevisionSpec {
        let mut merged: BTreeMap<AppliedKey, RevisionObject> = BTreeMap::new();
        for object in objects {
            match merged.entry(object.applied_key()) {
                std::collections::btree_map::Entry::Vacant(e) => {
                    e.insert(object);
                }
                std::collections::btree_map::Entry::Occupied(mut e) => {
                    let held = e.get_mut();
                    held.needs.extend(object.needs);
                    held.needs.sort();
                    held.needs.dedup();
                }
            }
        }
        let mut objects: Vec<RevisionObject> = merged.into_values().collect();
        objects.sort();
        RevisionSpec {
            format: FORMAT,
            cluster: cluster.to_string(),
            slot,
            objects,
            imports: Vec::new(),
        }
    }

    /// Return this spec with `imports`, sorted and once each.
    pub fn with_imports(mut self, imports: impl IntoIterator<Item = RevisionImport>) -> Self {
        self.imports = imports.into_iter().collect();
        self.imports.sort();
        self.imports.dedup();
        self
    }

    /// Return this spec with the markers of `imports` that its objects
    /// depend on, directly or through other markers. A kept-orphans list
    /// that keeps some of its objects keeps the markers they still need.
    pub fn with_imports_reached(self, imports: impl IntoIterator<Item = RevisionImport>) -> Self {
        let all = Revision::new(self.clone().with_imports(imports));
        let rids: Vec<ResourceId> = self
            .objects
            .iter()
            .map(RevisionObject::resource_id)
            .collect();
        let reached = crate::cluster::edges::Edges::of_revisions([&all]).imports_reached(&rids);
        self.with_imports(reached)
    }

    /// Return whether the revision records each object's edges.
    pub fn records_edges(&self) -> bool {
        self.format >= 2
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
    sorted.imports.sort();
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
    /// Each object's [`RevisionObject::hash`] mapped to the applied hash of
    /// what Kix wrote for it.
    pub applied: BTreeMap<String, String>,
}

/// Why a revision read from the API cannot be used.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReadError {
    #[error(
        "{} `{name}` has a `spec` that does not match its name (expected `{expected}` from its `spec`), so Kix cannot trust its object list. Either someone changed it outside Kix, or the API server dropped fields from its `spec` because the installed {} definition is older than this version of Kix",
        super::KIND,
        super::KIND
    )]
    NameMismatch { name: String, expected: String },
    #[error("{} `{name}` is invalid: {reason}", super::KIND)]
    Malformed { name: String, reason: String },
    #[error(
        "{} `{name}` uses format {format}, which a newer version of Kix wrote (this version reads formats 1 and {FORMAT}). Upgrade Kix to read it",
        super::KIND
    )]
    Newer { name: String, format: u32 },
}

/// A revision too large for the API server to store.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "{what} has {objects} objects (~{bytes} bytes), which exceeds Kubernetes's {MAX_BYTES}-byte limit for a single {} object. {next}",
    super::KIND
)]
pub struct TooLarge {
    /// What the revision covers, such as `package instance apps/web`.
    pub what: String,
    pub objects: usize,
    pub bytes: usize,
    /// What a user can do about it.
    pub next: &'static str,
}

impl ReadError {
    /// Return the name of the revision that cannot be read.
    pub fn name(&self) -> &str {
        match self {
            ReadError::NameMismatch { name, .. }
            | ReadError::Malformed { name, .. }
            | ReadError::Newer { name, .. } => name,
        }
    }
}

impl Revision {
    /// Return how many bytes the revision takes on the cluster once every
    /// object has an applied hash, as an upper estimate.
    pub fn stored_bytes(&self) -> usize {
        let spec = serde_json::to_vec(&self.spec).expect("a revision spec serializes");
        spec.len() + self.spec.objects.len() * APPLIED_BYTES + OVERHEAD_BYTES
    }

    /// Return a new revision of `spec`, named for it, with no applied
    /// hashes.
    pub fn new(spec: RevisionSpec) -> Revision {
        Revision {
            name: name_of(&spec),
            spec,
            applied: BTreeMap::new(),
        }
    }

    /// Read a revision from the API. Refuse one in a format a newer Kix
    /// wrote, and one whose name does not match its `spec`.
    pub fn from_object(obj: &DynamicObject) -> Result<Revision, ReadError> {
        let name = obj.metadata.name.clone().unwrap_or_default();
        let malformed = |reason: String| ReadError::Malformed {
            name: name.clone(),
            reason,
        };
        let spec_value = obj
            .data
            .get("spec")
            .ok_or_else(|| malformed("missing `spec`".into()))?;
        let spec: RevisionSpec = serde_json::from_value(spec_value.clone())
            .map_err(|e| malformed(format!("`spec` could not be parsed: {e}")))?;
        // A later format may hold fields this version drops when it parses
        // the `spec`, which would change the name computed from it.
        if spec.format > FORMAT {
            return Err(ReadError::Newer {
                name,
                format: spec.format,
            });
        }
        let expected = name_of(&spec);
        if expected != name {
            return Err(ReadError::NameMismatch { name, expected });
        }
        let applied = match obj.data.pointer("/status/applied") {
            None | Some(Value::Null) => BTreeMap::new(),
            Some(value) => serde_json::from_value(value.clone())
                .map_err(|e| malformed(format!("`status.applied` could not be parsed: {e}")))?,
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
        let by_hash: HashMap<String, ResourceId> = graph
            .resources
            .iter()
            .map(|(path, node)| (store_hash(path), ResourceId::from_value(&node.manifest)))
            .collect();
        // A `kix.run/depends-on` hash that names no manifest of the build
        // names no object the build makes: the build leaves Kix's own CRDs
        // out, and Kix installs them before a deploy writes anything. The
        // graph a deploy orders by drops such an entry too.
        let needs =
            |manifest: &Value| Need::of_depends_on(manifest, |hash| by_hash.get(hash).cloned());
        let object = |path: &Path| {
            let node = graph.resources.get(path)?;
            (!lifecycle::is_marker(&node.manifest)).then(|| {
                RevisionObject::of_manifest(&node.manifest).with_needs(needs(&node.manifest))
            })
        };
        let import = |path: &Path| {
            let node = graph.resources.get(path)?;
            lifecycle::is_marker(&node.manifest)
                .then(|| RevisionImport::of_marker(&node.manifest, needs(&node.manifest)))
        };
        let revision = |slot: Slot, paths: &[&Path]| {
            let objects = paths.iter().filter_map(|p| object(p)).collect();
            let imports: Vec<RevisionImport> = paths.iter().filter_map(|p| import(p)).collect();
            Revision::new(RevisionSpec::new(cluster, slot, objects).with_imports(imports))
        };
        let instances = groups
            .instances
            .iter()
            .map(|(key, group)| {
                let node = &graph.packages[group.instance];
                let paths: Vec<&Path> = std::iter::once(group.instance)
                    .chain(group.resources.iter().map(|p| p.as_path()))
                    .collect();
                let slot = Slot::Instance {
                    namespace: node.namespace.clone(),
                    name: node.instance_name.clone(),
                    lifecycle: node.lifecycle.clone(),
                };
                (key.clone(), revision(slot, &paths))
            })
            .collect();
        let cluster_paths: Vec<&Path> = groups
            .cluster_level
            .iter()
            .copied()
            .filter(|p| *p != graph.activation_path)
            .collect();
        RevisionSet {
            instances,
            cluster_level: revision(Slot::ClusterLevel, &cluster_paths),
        }
    }

    /// Refuse a set with a revision too large for the API server to store,
    /// naming the first such instance.
    pub fn check_size(&self) -> Result<(), TooLarge> {
        let too_large = |what: String, next: &'static str, revision: &Revision| {
            let bytes = revision.stored_bytes();
            (bytes > MAX_BYTES).then_some(TooLarge {
                what,
                objects: revision.spec.objects.len(),
                bytes,
                next,
            })
        };
        let instances = self.instances.iter().filter_map(|(key, revision)| {
            too_large(
                format!("package instance {key}"),
                "Split the instance into smaller package instances, then run the command again.",
                revision,
            )
        });
        let cluster_level = too_large(
            "cluster-level resources (outside any package instance)".into(),
            "Move some of these objects into package instances, then run the command again.",
            &self.cluster_level,
        );
        match instances.chain(cluster_level).next() {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Return every revision of the set: the instances' in key order, then
    /// the cluster level.
    pub fn all(&self) -> impl Iterator<Item = &Revision> {
        self.instances
            .values()
            .chain(std::iter::once(&self.cluster_level))
    }

    /// Return the Kix cluster the set belongs to.
    pub fn cluster(&self) -> &str {
        &self.cluster_level.spec.cluster
    }
}
