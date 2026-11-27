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
/// Each record is read from its own source. An object that a revision of a
/// record with a readable `status.revisions` names takes its hash from that
/// revision's `status.applied`. An object whose `kix.run/activations` names
/// a consulted record without a map, which an older Kix wrote, takes it
/// from its `kix.run/applied-hash` annotation. Any other object's hash is
/// not known, and so is the hash of an object two revisions record
/// differently.
#[derive(Debug, Default)]
pub struct AppliedHashes {
    /// Each object a consulted revision names, with what the revisions
    /// record for it.
    named: HashMap<RevisionObject, Recorded>,
    /// The identity hashes of the consulted records without a map, or
    /// `None` to read every object's hash from its annotation
    /// ([`AppliedHashes::from_annotations`]).
    noted: Option<std::collections::HashSet<String>>,
    /// The revisions a consulted record names that were not found or could
    /// not be read, sorted.
    missing: Vec<String>,
}

/// What the consulted revisions record for one object.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Recorded {
    /// No revision records a hash.
    Nothing,
    Hash(String),
    /// Two revisions record different hashes.
    Disagree,
}

impl AppliedHashes {
    /// Return a source that reads every object's applied hash from its
    /// annotation, as an older Kix wrote it, for objects whose records have
    /// no map.
    pub fn from_annotations() -> AppliedHashes {
        AppliedHashes::default()
    }

    /// Index the objects that `revisions` holds and that the readable maps of
    /// `records` name. A `Superseded` record is skipped, because Kix deletes
    /// its revisions. When two revisions name the same object, a recorded
    /// hash wins over a missing one, and two different recorded hashes
    /// disagree.
    ///
    /// A named revision that `revisions` does not hold may name any object,
    /// so then an object no other revision names reads as not known rather
    /// than from its annotation. The missing revisions are reported once,
    /// here.
    pub fn of<'a>(
        records: impl IntoIterator<Item = &'a Record>,
        revisions: impl IntoIterator<Item = &'a Revision>,
    ) -> AppliedHashes {
        let by_name: HashMap<&str, &Revision> = revisions
            .into_iter()
            .map(|r| (r.name.as_str(), r))
            .collect();
        let mut named: HashMap<RevisionObject, Recorded> = HashMap::new();
        let mut noted = std::collections::HashSet::new();
        let mut missing: Vec<String> = Vec::new();
        for record in records {
            if record.phase != PHASE_SUPERSEDED
                && record.revisions.is_none()
                && let Some(hash) = &record.identity_hash
            {
                noted.insert(hash.clone());
            }
            let Some(map) = readable_map(record) else {
                continue;
            };
            missing.extend(
                map.names()
                    .filter(|n| !by_name.contains_key(n))
                    .map(str::to_string),
            );
            for revision in map.names().filter_map(|n| by_name.get(n)) {
                for object in &revision.spec.objects {
                    let entry = named.entry(object.clone()).or_insert(Recorded::Nothing);
                    *entry = match (&*entry, revision.applied.get(&object.hash)) {
                        (_, None) => entry.clone(),
                        (Recorded::Nothing, Some(hash)) => Recorded::Hash(hash.clone()),
                        (Recorded::Hash(held), Some(hash)) if held == hash => entry.clone(),
                        (Recorded::Hash(_) | Recorded::Disagree, Some(_)) => Recorded::Disagree,
                    };
                }
            }
        }
        missing.sort();
        missing.dedup();
        if !missing.is_empty() {
            tracing::warn!(
                revisions = ?missing,
                "deployment records name revisions Kix could not read; the applied hashes of the objects they name are not known, so those objects are applied again or reported as not checked"
            );
        }
        AppliedHashes {
            named,
            noted: Some(noted),
            missing,
        }
    }

    /// Return the revisions a consulted record names that Kix could not
    /// read, sorted.
    pub fn missing(&self) -> &[String] {
        &self.missing
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
        let recorded = keys::get_meta(annotations, keys::IDENTITY_HASH).and_then(|hash| {
            self.named
                .get(&RevisionObject::of_id(hash, &drift::resource_id(obj)))
        });
        let from_note = || {
            let named_by_note = match &self.noted {
                None => true,
                Some(noted) => keys::get_meta(annotations, keys::ACTIVATIONS)
                    .unwrap_or_default()
                    .split(',')
                    .any(|h| noted.contains(h.trim())),
            };
            named_by_note
                .then(|| keys::get_meta(annotations, keys::APPLIED_HASH))
                .flatten()
        };
        match recorded {
            Some(Recorded::Hash(hash)) => Some(hash),
            Some(Recorded::Disagree) => None,
            None if !self.missing.is_empty() => None,
            Some(Recorded::Nothing) | None => from_note(),
        }
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
/// - `replaced` pairs each revision the run's record names that the current
///   record does not with the revisions the current record names. The new
///   one takes an old one's hash of every object both name that the run did
///   not apply.
///
/// Leave out entries a revision already holds with the same value. A run
/// that applied nothing still carries hashes into the revisions it replaces.
pub fn pending(
    applied: &BTreeMap<RevisionObject, String>,
    kept: &[&Revision],
    replaced: &[(&Revision, &Revision)],
) -> BTreeMap<String, BTreeMap<String, String>> {
    let mut out: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
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
