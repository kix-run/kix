//! The applied hashes in `status.applied`: which ones a run writes, and where
//! a plan or a drift check reads an object's applied hash.
//!
//! A run writes the applied hash of each object it applied to every kept
//! revision of its Kix cluster that names the object with the same object
//! hash. A revision of a changed instance also takes the applied hashes of
//! the objects the run did not apply from the revision it replaces.
//!
//! An entry is written only for an object Kix applied, so a missing entry
//! means the hash is not known. It never means the object is in sync.

use std::collections::{BTreeMap, HashMap, HashSet};

use kube::Client;
use kube::api::DynamicObject;

use super::map::RevisionMap;
use super::spec::{AppliedKey, Revision, RevisionObject};
use super::store::{RevisionError, Revisions};
use crate::cluster::activation::Record;
use crate::cluster::drift;
use crate::manifest::keys;
use crate::manifest::lifecycle::PHASE_SUPERSEDED;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

impl RevisionObject {
    /// Return the object `rid` names, with hash `hash`.
    pub fn of_id(hash: &str, rid: &ResourceId) -> RevisionObject {
        RevisionObject {
            hash: hash.to_string(),
            group: rid.group.clone(),
            kind: rid.kind.clone(),
            namespace: (rid.namespace != CLUSTER_SCOPED).then(|| rid.namespace.clone()),
            name: rid.name.clone(),
            needs: Vec::new(),
        }
    }
}

/// The applied hashes the revisions of a Kix cluster's records hold, by
/// object name.
///
/// Each record is read from its own source. An object that a revision of a
/// record with a readable `status.revisions` names takes its hash from that
/// revision's `status.applied`, keyed by the object's name and the hash the
/// revision gives it ([`RevisionObject::hash`]). An object whose
/// `kix.run/activations` names a consulted record without a map, which an
/// older Kix wrote, takes it from its `kix.run/applied-hash` annotation.
#[derive(Debug, Default)]
pub struct AppliedHashes {
    /// Each object a consulted revision names, with each revision entry
    /// that names it.
    named: HashMap<ResourceId, Vec<Entry>>,
    /// The identity hashes of the consulted records without a map, or
    /// `None` to read every object's hash from its annotation
    /// ([`AppliedHashes::from_annotations`]).
    noted: Option<std::collections::HashSet<String>>,
    /// The revisions a consulted record names that were not found or could
    /// not be read, sorted.
    missing: Vec<String>,
}

/// One revision entry for an object.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    /// The record whose map names the revision.
    record: String,
    /// The hash the revision gives the object.
    hash: String,
    /// The applied hash the revision holds for it.
    applied: Option<String>,
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
    /// its revisions.
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
        let mut named: HashMap<ResourceId, Vec<Entry>> = HashMap::new();
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
                    let entry = Entry {
                        record: record.name.clone(),
                        hash: object.hash.clone(),
                        applied: revision.applied.get(&object.hash).cloned(),
                    };
                    let entries = named.entry(object.resource_id()).or_default();
                    if !entries.contains(&entry) {
                        entries.push(entry);
                    }
                }
            }
        }
        missing.sort();
        missing.dedup();
        if !missing.is_empty() {
            tracing::warn!(
                revisions = ?missing,
                "deployment records reference PackageInstanceRevision objects that Kix could not read; Kix will reapply their objects or report them as not checked"
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

    fn entries(&self, rid: &ResourceId) -> impl Iterator<Item = &Entry> {
        self.named.get(rid).into_iter().flatten()
    }

    /// Return the applied hash the consulted revisions hold for the object
    /// `rid` with hash `hash`, or `None` when none holds one or two hold
    /// different ones.
    pub fn entry(&self, rid: &ResourceId, hash: &str) -> Option<&str> {
        agreed(self.entries(rid).filter(|e| e.hash == hash))
    }

    /// Return whether a revision of record `record` names the object `rid`
    /// with hash `hash`: that record's build wanted the object to be the
    /// manifest whose object hash is `hash`.
    pub fn names(&self, rid: &ResourceId, hash: &str, record: &str) -> bool {
        self.entries(rid)
            .any(|e| e.hash == hash && e.record == record)
    }

    /// Return whether a consulted revision holds `applied` for the object
    /// `rid`.
    pub fn holds(&self, rid: &ResourceId, applied: &str) -> bool {
        self.entries(rid)
            .any(|e| e.applied.as_deref() == Some(applied))
    }

    /// Return the applied hash to judge the live object `obj` by, for a
    /// reader with no new build, such as `kix status`. `manager` is the
    /// field manager of the Kix cluster whose records were consulted, and
    /// `prefer` the record the reader shows.
    ///
    /// When the live object matches an applied hash a consulted revision
    /// holds for it, return that one: the deploy that wrote it applied
    /// what the object holds. Otherwise return the one the revisions of
    /// `prefer` hold. An object no consulted revision names takes its hash
    /// from its annotation when a consulted record without a map names it.
    /// Return `None` when the hash is not known.
    pub fn for_live<'a>(
        &'a self,
        obj: &'a DynamicObject,
        manager: &crate::cluster::field_manager::FieldManager,
        prefer: Option<&str>,
    ) -> Option<&'a str> {
        let rid = drift::resource_id(obj);
        if self.named.contains_key(&rid) {
            let live = crate::cluster::fieldsv1::applied_content_hash(obj, manager);
            if let Some(live) = live
                && let Some(e) = self
                    .entries(&rid)
                    .find(|e| e.applied.as_deref() == Some(live.as_str()))
            {
                return e.applied.as_deref();
            }
            return agreed(
                self.entries(&rid)
                    .filter(|e| Some(e.record.as_str()) == prefer),
            );
        }
        if !self.missing.is_empty() {
            return None;
        }
        self.noted_hash(obj)
    }

    /// Return the `kix.run/applied-hash` note of `obj` when a consulted
    /// record without a map names the object, as an older Kix wrote it.
    fn noted_hash<'a>(&self, obj: &'a DynamicObject) -> Option<&'a str> {
        let annotations = obj.metadata.annotations.as_ref()?;
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
    }
}

/// Return the applied hash `entries` hold, or `None` when none holds one or
/// two hold different ones.
fn agreed<'a>(entries: impl Iterator<Item = &'a Entry>) -> Option<&'a str> {
    let mut found: Option<&str> = None;
    for applied in entries.filter_map(|e| e.applied.as_deref()) {
        match found {
            Some(held) if held != applied => return None,
            _ => found = Some(applied),
        }
    }
    found
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
///   one takes the old ones' hash of every object both name that the run did
///   not apply, when the old ones that record a hash for it agree.
///
/// Leave out entries a revision already holds with the same value. A run
/// that applied nothing still carries hashes into the revisions it replaces.
pub fn pending(
    applied: &BTreeMap<AppliedKey, String>,
    kept: &[&Revision],
    replaced: &[(&Revision, &Revision)],
) -> BTreeMap<String, BTreeMap<String, String>> {
    // Old revisions that record different hashes for one object leave it
    // without one, as a reader treats revisions that disagree.
    let mut carried: BTreeMap<&str, BTreeMap<&str, Option<&String>>> = BTreeMap::new();
    for (old, new) in replaced {
        let in_old: HashSet<AppliedKey> = old
            .spec
            .objects
            .iter()
            .map(RevisionObject::applied_key)
            .collect();
        let entries = carried.entry(new.name.as_str()).or_default();
        for object in new.spec.objects.iter().filter(|o| {
            let key = o.applied_key();
            !applied.contains_key(&key) && in_old.contains(&key)
        }) {
            let Some(value) = old.applied.get(&object.hash) else {
                continue;
            };
            entries
                .entry(object.hash.as_str())
                .and_modify(|known| {
                    if *known != Some(value) {
                        *known = None;
                    }
                })
                .or_insert(Some(value));
        }
    }
    let mut out: BTreeMap<String, BTreeMap<String, String>> = carried
        .into_iter()
        .map(|(name, entries)| {
            let agreed = entries
                .into_iter()
                .filter_map(|(hash, value)| Some((hash.to_string(), value?.clone())))
                .collect();
            (name.to_string(), agreed)
        })
        .collect();
    for revision in kept {
        let entries = revision
            .spec
            .objects
            .iter()
            .filter_map(|o| Some((o.hash.clone(), applied.get(&o.applied_key())?.clone())));
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
