//! The applied hashes in `status.applied`: which ones a run writes, and where
//! a drift check reads an object's applied hash.
//!
//! A run writes the applied hash of each object it applied to every kept
//! revision of its Kix cluster that names the object with the same build
//! hash. A revision of a changed instance also takes the applied hashes of
//! the objects the run did not apply from the revision it replaces.
//!
//! An entry is written only for an object Kix applied, so a missing entry
//! means the hash is not known. It never means the object is in sync.

use std::collections::{BTreeMap, HashMap, HashSet};

use kube::Client;
use kube::api::DynamicObject;

use super::map::RevisionMap;
use super::spec::{Revision, RevisionObject};
use super::store::{RevisionError, Revisions};
use crate::cluster::activation::Record;
use crate::cluster::drift;
use crate::manifest::keys;
use crate::manifest::lifecycle::PHASE_SUPERSEDED;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

impl RevisionObject {
    /// Return the object `rid` names, with build hash `hash`.
    pub fn of_id(hash: &str, rid: &ResourceId) -> RevisionObject {
        RevisionObject {
            hash: hash.to_string(),
            group: rid.group.clone(),
            kind: rid.kind.clone(),
            namespace: (rid.namespace != CLUSTER_SCOPED).then(|| rid.namespace.clone()),
            name: rid.name.clone(),
        }
    }
}

/// Where a drift check reads the applied hash of a live object.
///
/// An object that a revision of a record with a readable `status.revisions`
/// names takes its hash from that revision's `status.applied`. Any other
/// object takes it from its `kix.run/applied-hash` annotation, which an
/// earlier Kix wrote.
#[derive(Debug, Default)]
pub struct AppliedHashes {
    /// Each object a consulted revision names, with its applied hash when a
    /// revision records one.
    named: HashMap<RevisionObject, Option<String>>,
}

impl AppliedHashes {
    /// Return a source that reads every object's applied hash from its
    /// annotation.
    pub fn from_annotations() -> AppliedHashes {
        AppliedHashes::default()
    }

    /// Index the objects that `revisions` holds and that the readable maps of
    /// `records` name. A `Superseded` record is skipped, because Kix deletes
    /// its revisions. When two revisions name the same object, a recorded
    /// hash wins over a missing one.
    pub fn of<'a>(
        records: impl IntoIterator<Item = &'a Record>,
        revisions: impl IntoIterator<Item = &'a Revision>,
    ) -> AppliedHashes {
        let by_name: HashMap<&str, &Revision> = revisions
            .into_iter()
            .map(|r| (r.name.as_str(), r))
            .collect();
        let mut named: HashMap<RevisionObject, Option<String>> = HashMap::new();
        for record in records {
            let Some(map) = readable_map(record) else {
                continue;
            };
            for revision in map.names().filter_map(|n| by_name.get(n)) {
                for object in &revision.spec.objects {
                    let entry = named.entry(object.clone()).or_default();
                    if entry.is_none() {
                        *entry = revision.applied.get(&object.hash).cloned();
                    }
                }
            }
        }
        AppliedHashes { named }
    }

    /// Read what [`AppliedHashes::of`] needs for the records of Kix cluster
    /// `cluster`. List the cluster's revisions only when one of `records`
    /// has a readable map, so a cluster that no Kix with revisions deployed
    /// needs no revision kind.
    pub async fn load(
        client: &Client,
        cluster: &str,
        records: &[&Record],
    ) -> Result<AppliedHashes, RevisionError> {
        if !records.iter().any(|r| readable_map(r).is_some()) {
            return Ok(AppliedHashes::from_annotations());
        }
        let listed = Revisions::new(client).list(cluster).await?;
        Ok(AppliedHashes::of(records.iter().copied(), &listed.readable))
    }

    /// Return the applied hash of the live object `obj`, or `None` when it
    /// is not known.
    pub fn applied<'a>(&'a self, obj: &'a DynamicObject) -> Option<&'a str> {
        let annotations = obj.metadata.annotations.as_ref()?;
        if !self.named.is_empty()
            && let Some(hash) = keys::get_meta(annotations, keys::IDENTITY_HASH)
            && let Some(found) = self
                .named
                .get(&RevisionObject::of_id(hash, &drift::resource_id(obj)))
        {
            return found.as_deref();
        }
        keys::get_meta(annotations, keys::APPLIED_HASH)
    }
}

fn readable_map(record: &Record) -> Option<&RevisionMap> {
    if record.phase == PHASE_SUPERSEDED {
        return None;
    }
    record.revisions.as_ref()?.as_ref().ok()
}

/// Return the `status.applied` entries a run writes, keyed by revision name.
///
/// - `applied` holds each object the run applied, with its applied hash.
/// - `kept` holds the kept revisions of the run's Kix cluster, with the
///   entries they already have. Each one that names an applied object takes
///   its hash.
/// - `replaced` pairs each revision the run's record names with the revision
///   of the same instance that the current record names, when the two
///   differ. The new one takes the old one's hash of every object both name
///   that the run did not apply.
///
/// Leave out entries a revision already holds with the same value, and
/// write nothing when the run applied nothing.
pub fn pending(
    applied: &BTreeMap<RevisionObject, String>,
    kept: &[&Revision],
    replaced: &[(&Revision, &Revision)],
) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut out: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    if applied.is_empty() {
        return out;
    }
    for (old, new) in replaced {
        let in_old: HashSet<&RevisionObject> = old.spec.objects.iter().collect();
        let carried = new
            .spec
            .objects
            .iter()
            .filter(|o| !applied.contains_key(*o) && in_old.contains(o))
            .filter_map(|o| Some((o.hash.clone(), old.applied.get(&o.hash)?.clone())));
        out.entry(new.name.clone()).or_default().extend(carried);
    }
    for revision in kept {
        let entries = revision
            .spec
            .objects
            .iter()
            .filter_map(|o| Some((o.hash.clone(), applied.get(o)?.clone())));
        out.entry(revision.name.clone())
            .or_default()
            .extend(entries);
    }
    let held: HashMap<&str, &BTreeMap<String, String>> = replaced
        .iter()
        .map(|(_, new)| *new)
        .chain(kept.iter().copied())
        .map(|r| (r.name.as_str(), &r.applied))
        .collect();
    for (name, entries) in &mut out {
        if let Some(held) = held.get(name.as_str()) {
            entries.retain(|hash, value| held.get(hash) != Some(value));
        }
    }
    out.retain(|_, entries| !entries.is_empty());
    out
}
