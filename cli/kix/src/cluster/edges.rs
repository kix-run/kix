//! The dependency edges between named objects that a Kix cluster recorded:
//! which objects each object depends on, and in which relation.
//!
//! The graph code orders deletes and finds an object's controller from an
//! [`Edges`], so it does not care where the edges came from. There are two
//! sources:
//!
//! - A build's manifests ([`Edges::of_build`]). Each one lists the identity
//!   hashes of its dependencies in `kix.run/depends-on`, and the hashes name
//!   other manifests of the same build.
//! - The revisions of a Kix cluster ([`Edges::of_revisions`]). A revision
//!   records the same edges by name in each object's `needs`, so they
//!   describe a live object without reading anything on it.
//!
//! An import marker is a node of the edges like any object, with its own
//! needs, and it also names the object it stands for ([`Edges::import`]).
//! Kix writes no object for a marker, so a set of live objects never holds
//! one, and an edge to it passes on to what the marker needs.
//!
//! Edges Kix derives from content, such as a RoleBinding to the workload
//! whose ServiceAccount it names, are not recorded edges. The graph code
//! derives them from the manifests in hand ([`crate::cluster::graph`]).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde_json::Value;

use crate::cluster::revision::{Need, Revision, RevisionImport};
use crate::cluster::tenancy::Tenancy;
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

/// The recorded dependency edges of a set of objects, by object.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Edges {
    /// What each object depends on. An object with an entry has its edges
    /// recorded, even when it depends on nothing.
    needs: HashMap<ResourceId, BTreeSet<Need>>,
    /// Objects that only format 1 revisions name, which do not record
    /// edges.
    unrecorded: HashSet<ResourceId>,
    /// Each import marker, by marker. Its needs are in `needs`.
    imports: HashMap<ResourceId, RevisionImport>,
}

impl Edges {
    /// Return the edges that the `kix.run/depends-on` annotations of
    /// `manifests` record between them. Pass the manifests of builds only:
    /// a live object's annotation describes the graph of whichever Kix
    /// cluster wrote it last. An entry whose hash names no manifest of the
    /// set is left out.
    pub fn of_build(manifests: &[Value]) -> Edges {
        annotated(manifests, |_| true)
    }

    /// Return the edges that `revisions` record. An object that several of
    /// them name depends on what any of them says it depends on, because a
    /// delete must wait for every object an earlier build of it needed. An
    /// object that only format 1 revisions name has no recorded edges, and
    /// [`Edges::with_format_one_annotations`] can fill them in.
    pub fn of_revisions<'a>(revisions: impl IntoIterator<Item = &'a Revision>) -> Edges {
        let mut needs: HashMap<ResourceId, BTreeSet<Need>> = HashMap::new();
        let mut unrecorded = HashSet::new();
        let mut imports = HashMap::new();
        for revision in revisions {
            for import in &revision.spec.imports {
                let rid = import.resource_id();
                needs
                    .entry(rid.clone())
                    .or_default()
                    .extend(import.needs.iter().cloned());
                imports.entry(rid).or_insert_with(|| RevisionImport {
                    needs: Vec::new(),
                    ..import.clone()
                });
            }
            for object in &revision.spec.objects {
                if revision.spec.records_edges() {
                    needs
                        .entry(object.resource_id())
                        .or_default()
                        .extend(object.needs.iter().cloned());
                } else {
                    unrecorded.insert(object.resource_id());
                }
            }
        }
        unrecorded.retain(|rid| !needs.contains_key(rid));
        Edges {
            needs,
            unrecorded,
            imports,
        }
    }

    /// Return the edges that the revisions of the records of the Kix cluster
    /// `tenancy` is read for record, with the edges of each object that only
    /// format 1 revisions name read from its manifest in `in_hand`
    /// ([`Edges::with_format_one_annotations`]).
    pub fn of_own_revisions(tenancy: &Tenancy, in_hand: &[Value]) -> Edges {
        let own = tenancy.cluster.as_str();
        Edges::of_revisions(tenancy.revisions().filter(|r| r.spec.cluster == own))
            .with_format_one_annotations(in_hand)
    }

    /// Return these edges, with the edges `other` records for each object
    /// these do not record.
    pub fn or(mut self, other: Edges) -> Edges {
        for (rid, needs) in other.needs {
            self.needs.entry(rid).or_insert(needs);
        }
        for (marker, target) in other.imports {
            self.imports.entry(marker).or_insert(target);
        }
        self
    }

    /// Fill in the edges of each object that only format 1 revisions name
    /// from the `kix.run/depends-on` annotation of its manifest in
    /// `manifests`. This is the one place Kix reads the annotation from a
    /// live object to order deletes, for revisions an earlier build of Kix
    /// wrote. The next deploy replaces them with revisions that record
    /// edges. An object no revision names gets nothing here.
    pub fn with_format_one_annotations(mut self, manifests: &[Value]) -> Edges {
        if self.unrecorded.is_empty() {
            return self;
        }
        let unrecorded = std::mem::take(&mut self.unrecorded);
        let noted = annotated(manifests, |rid| unrecorded.contains(rid));
        self.needs.extend(noted.needs);
        self.imports.extend(noted.imports);
        self
    }

    /// Return the edges the `kix.run/depends-on` notes of the live objects
    /// `manifests` record between them. Use it only for a record an older
    /// Kix wrote, which has no revisions: such a Kix recorded the edges on
    /// the objects and nowhere else.
    pub fn of_older_kix_notes(manifests: &[Value]) -> Edges {
        annotated(manifests, |_| true)
    }

    /// Return whether the edges of `rid` are recorded, even as none.
    pub fn records(&self, rid: &ResourceId) -> bool {
        self.needs.contains_key(rid)
    }

    /// Return what `rid` depends on, sorted.
    pub fn needs(&self, rid: &ResourceId) -> impl Iterator<Item = &Need> {
        self.needs.get(rid).into_iter().flatten()
    }

    /// Return the objects whose edges are recorded.
    pub fn objects(&self) -> impl Iterator<Item = &ResourceId> {
        self.needs.keys()
    }

    /// Return the object the import marker `rid` stands for, or `None` when
    /// `rid` is not a marker these edges know or names no target.
    pub fn import(&self, rid: &ResourceId) -> Option<ResourceId> {
        self.imports
            .get(rid)?
            .target
            .as_ref()
            .map(|t| t.resource_id())
    }

    /// Return the import markers that the objects `rids` depend on, directly
    /// or through other markers, each with its needs. A revision that lists
    /// those objects lists these markers too, so an edge that passes through
    /// a marker stays whole.
    pub fn imports_reached<'a>(
        &self,
        rids: impl IntoIterator<Item = &'a ResourceId>,
    ) -> Vec<RevisionImport> {
        let mut out: BTreeMap<ResourceId, RevisionImport> = BTreeMap::new();
        let mut queue: Vec<ResourceId> = rids.into_iter().cloned().collect();
        while let Some(rid) = queue.pop() {
            for need in self.needs(&rid) {
                let target = need.resource_id();
                let Some(import) = self.imports.get(&target) else {
                    continue;
                };
                if out.contains_key(&target) {
                    continue;
                }
                let mut import = import.clone();
                import.needs = self.needs(&target).cloned().collect();
                out.insert(target.clone(), import);
                queue.push(target);
            }
        }
        out.into_values().collect()
    }

    /// Return the objects `rid` depends on that `holds` accepts. An edge to
    /// an import marker that `holds` does not accept passes on to what the
    /// marker needs, so an object that needs a CRD marker still depends on
    /// the operator the marker needs when no manifest of the marker is at
    /// hand.
    pub fn needs_through_imports<'a>(
        &'a self,
        rid: &ResourceId,
        holds: impl Fn(&ResourceId) -> bool,
    ) -> Vec<&'a Need> {
        let mut out = Vec::new();
        let mut seen: HashSet<ResourceId> = HashSet::new();
        let mut queue: Vec<&Need> = self.needs(rid).collect();
        while let Some(need) = queue.pop() {
            let target = need.resource_id();
            if holds(&target) {
                out.push(need);
            } else if self.imports.contains_key(&target) && seen.insert(target.clone()) {
                queue.extend(self.needs(&target));
            }
        }
        out
    }
}

/// The objects earlier deploys of a Kix cluster made, as a run that may
/// delete some of them knows them: a manifest for each, the recorded edges
/// between them, and the hash each earlier revision or build gives them.
#[derive(Debug, Clone, Default)]
pub struct Prior {
    /// The manifests of earlier builds, or the live objects where no build
    /// is at hand.
    pub manifests: Vec<Value>,
    pub edges: Edges,
    /// The hashes ([`crate::cluster::revision::RevisionObject::hash`]) the
    /// earlier revisions or builds give each object. A kept-orphans
    /// revision names an orphan with them.
    pub hashes: HashMap<ResourceId, BTreeSet<String>>,
}

impl Prior {
    /// Return the objects of earlier builds whose manifests are `manifests`,
    /// with the edges their annotations record and their object hashes.
    /// Pass the manifests of builds only, as for [`Edges::of_build`].
    pub fn of_build(manifests: Vec<Value>) -> Prior {
        let edges = Edges::of_build(&manifests);
        let mut hashes: HashMap<ResourceId, BTreeSet<String>> = HashMap::new();
        for m in &manifests {
            hashes
                .entry(ResourceId::from_value(m))
                .or_default()
                .insert(crate::manifest::hash::object_hash(m));
        }
        Prior {
            manifests,
            edges,
            hashes,
        }
    }

    /// Return the objects `revisions` name, as `manifests` describe them,
    /// with the edges and hashes the revisions give them.
    ///
    /// An import marker counts with the hash its revision records. An older
    /// Kix applied markers, so one can be on the cluster as an orphan, and
    /// the kept-orphans revision must be able to name it.
    pub fn of_revisions<'a>(
        manifests: Vec<Value>,
        revisions: impl IntoIterator<Item = &'a Revision> + Clone,
    ) -> Prior {
        let mut hashes: HashMap<ResourceId, BTreeSet<String>> = HashMap::new();
        for object in revisions.clone().into_iter().flat_map(|r| &r.spec.objects) {
            hashes
                .entry(object.resource_id())
                .or_default()
                .insert(object.hash.clone());
        }
        let edges = Edges::of_revisions(revisions);
        for (rid, import) in &edges.imports {
            hashes
                .entry(rid.clone())
                .or_default()
                .insert(import.hash.clone());
        }
        Prior {
            manifests,
            edges,
            hashes,
        }
    }
}

/// Return the edges that the `kix.run/depends-on` annotations of the
/// manifests that `wanted` picks record, with each hash resolved to the
/// manifest of `manifests` that carries it, and the target of each import
/// marker among them.
fn annotated(manifests: &[Value], wanted: impl Fn(&ResourceId) -> bool) -> Edges {
    let by_hash: HashMap<&str, ResourceId> = manifests
        .iter()
        .filter_map(|m| {
            Some((
                keys::get(m, keys::IDENTITY_HASH)?,
                ResourceId::from_value(m),
            ))
        })
        .collect();
    let mut edges = Edges::default();
    for (rid, m) in manifests
        .iter()
        .map(|m| (ResourceId::from_value(m), m))
        .filter(|(rid, _)| wanted(rid))
    {
        let needs = Need::of_depends_on(m, |hash| by_hash.get(hash).cloned());
        if crate::manifest::lifecycle::is_marker(m) {
            edges
                .imports
                .insert(rid.clone(), RevisionImport::of_marker(m, Vec::new()));
        }
        edges.needs.insert(rid, needs.into_iter().collect());
    }
    edges
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::revision::{RevisionObject, RevisionSpec, Slot};
    use serde_json::json;

    fn cm(name: &str, hash: &str, deps: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": name,
                "namespace": "ns",
                "annotations": { keys::IDENTITY_HASH: hash, keys::DEPENDS_ON: deps },
            },
        })
    }

    fn rid(name: &str) -> ResourceId {
        ResourceId::new("", "ConfigMap", "ns", name)
    }

    fn object(name: &str, needs: &[&str]) -> RevisionObject {
        RevisionObject::of_id(&format!("h-{name}"), &rid(name))
            .with_needs(needs.iter().map(|n| Need::of(&rid(n), None)))
    }

    fn named(edges: &Edges, name: &str) -> Vec<String> {
        edges.needs(&rid(name)).map(|n| n.name.clone()).collect()
    }

    #[test]
    fn a_build_resolves_its_hashes_to_names_and_keeps_the_relation() {
        let edges = Edges::of_build(&[
            cm("a", "ha", "requires:hb,controller:hc,hgone"),
            cm("b", "hb", ""),
            cm("c", "hc", ""),
        ]);
        let needs: Vec<(String, Option<String>)> = edges
            .needs(&rid("a"))
            .map(|n| (n.name.clone(), n.role.clone()))
            .collect();
        assert_eq!(
            needs,
            [
                ("b".to_string(), Some("requires".to_string())),
                ("c".to_string(), Some("controller".to_string())),
            ]
        );
    }

    #[test]
    fn revisions_union_what_each_records_for_an_object() {
        let one = Revision::new(RevisionSpec::new(
            "a",
            Slot::ClusterLevel,
            vec![object("x", &["y"])],
        ));
        let two = Revision::new(RevisionSpec::new(
            "a",
            Slot::KeptOrphans,
            vec![object("x", &["z"])],
        ));
        let edges = Edges::of_revisions([&one, &two]);
        assert_eq!(named(&edges, "x"), ["y", "z"]);
    }

    /// A format 1 revision records no edges. The live annotation fills them
    /// in for its objects only, and a format 2 entry for the same object
    /// wins over it.
    #[test]
    fn format_one_objects_take_their_edges_from_the_annotation() {
        let mut old = Revision::new(RevisionSpec::new(
            "a",
            Slot::ClusterLevel,
            vec![object("old", &[]), object("both", &[])],
        ));
        old.spec.format = 1;
        let new = Revision::new(RevisionSpec::new(
            "a",
            Slot::KeptOrphans,
            vec![object("both", &["dep"])],
        ));
        let live = [
            cm("old", "h1", "h2"),
            cm("dep", "h2", ""),
            cm("both", "h3", "h4"),
            cm("other", "h4", "h2"),
        ];
        let edges = Edges::of_revisions([&old, &new]).with_format_one_annotations(&live);
        assert_eq!(named(&edges, "old"), ["dep"]);
        assert_eq!(named(&edges, "both"), ["dep"]);
        assert!(named(&edges, "other").is_empty(), "no revision names it");
        assert!(!edges.objects().any(|r| r == &rid("other")));
    }
}
