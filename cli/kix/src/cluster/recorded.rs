//! What a Kix cluster's own records say about each of its live objects:
//! which part of the cluster names it, the hash its build gave it, which
//! records name it, what it depends on, and the applied hash to judge it by.
//!
//! The answer comes from revisions whatever the Kix cluster is read from.
//! A record an older Kix wrote, and a record whose map names format 1
//! revisions, is first converted in memory the way the next deploy will
//! convert it ([`convert::in_memory`]). The slot, the lifecycle, and the
//! edges of such a record therefore come from the package index and the
//! notes on the live objects by the conversion's rules, and its applied
//! hashes are the ones the conversion would store.
//!
//! Some objects get no entry. Kix writes no object for a revision's import
//! marker, and no revision names an Activation record or one of the CRDs
//! Kix installs itself. A marker an older Kix applied is a live object, and
//! the record that names it does so as one of its objects.
//!
//! An object without an entry may also be one the read could not account
//! for. [`RecordedObjects::incomplete`] says when that can be so.

use std::collections::{HashMap, HashSet};

use kube::api::DynamicObject;
use serde_json::Value;

use super::drift::{self, DriftReport};
use super::edges::Edges;
use super::field_manager::FieldManager;
use super::owned_view::Observed;
use super::revision::{AppliedHashes, Need, REBUILT, Revision, Slot, convert};
use super::tenancy::{Claim, Problem, Tenancy};
use crate::manifest::lifecycle::{PHASE_DEPLOYING, PHASE_QUEUED, PHASE_SUPERSEDED};
use crate::manifest::types::{ResourceId, to_manifest_value};

/// What the records of one Kix cluster say about one live object.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Recorded {
    /// The part of the Kix cluster whose revision gave the object `hash`.
    /// When `hash` is `None`, it is the revision of the current record, or
    /// of another record when the current one does not name the object. An
    /// instance's slot carries the lifecycle of its package. An object only
    /// the kept-orphans revision names is in [`Slot::KeptOrphans`].
    pub slot: Slot,
    /// The hash the records' builds gave the object
    /// ([`RevisionObject::hash`](super::revision::RevisionObject::hash)). It is an object hash or, for a
    /// record converted from one an older Kix wrote, that build's Nix store
    /// hash. The two never compare equal. The deploy that migrates such a
    /// cluster names its objects with object hashes, so on that deploy this
    /// value changes once even when the object's content does not.
    ///
    /// `None` when the records disagree and none of them applied what the
    /// object holds, or when a rebuilt kept-orphans list cannot know it
    /// ([`REBUILT`]).
    pub hash: Option<String>,
    /// The identity hashes of the records whose revisions, other than the
    /// kept orphans, name the object with `hash`, sorted. When `hash` is
    /// `None`, every such record that names the object.
    pub records: Vec<String>,
    /// What the object depends on in the revision `slot` comes from,
    /// sorted. An edge to an import marker passes on to what the marker
    /// needs, so every need ends at a live object.
    pub needs: Vec<Need>,
    /// The applied hash to judge the object by
    /// ([`AppliedHashes::for_observed`]), or `None` when it is not known.
    pub applied: Option<String>,
}

/// Why the answer for a Kix cluster may leave out objects its records name,
/// or file an object under an earlier build.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Incomplete {
    /// The read of the cluster's records or revisions failed in part.
    #[error(transparent)]
    Tenancy(Problem),
    /// The records an older Kix wrote could not be read as revisions.
    #[error(transparent)]
    Conversion(convert::Refusal),
    /// The tenancy was read for no Kix cluster, so no record is its own.
    #[error(
        "no Kix cluster name was given, so Kix could not match live objects to deployment records. Pass a Kix cluster name when reading deployment records"
    )]
    NoCluster,
    /// An older Kix is deploying these records, or has them queued. Their
    /// deploy may already have rewritten objects that the entries still
    /// file under the current record's build.
    #[error(
        "deployment record(s) {} are queued, or an older version of Kix has not finished deploying them. Kix skipped those records, so any new objects they added are omitted, and any objects they updated are still attributed to the earlier deployment. Wait for the deploy to finish",
        records.join(", ")
    )]
    OlderKixPending { records: Vec<String> },
}

/// What a Kix cluster's records say about each of its live objects, by
/// object.
#[derive(Debug, Clone)]
pub struct RecordedObjects {
    by_object: HashMap<ResourceId, Recorded>,
    /// The field manager the Kix cluster's objects are judged under.
    manager: FieldManager,
    incomplete: Vec<Incomplete>,
}

impl RecordedObjects {
    /// Read what the records of the Kix cluster `tenancy` is read for say
    /// about `live`, the objects swept for that cluster, each read once
    /// under [`Tenancy::manager_of`]. An object no record of the cluster
    /// names gets no entry.
    ///
    /// A sweep that could not list some kinds is not refused. The objects
    /// of those kinds are absent from `live`, so they get no entry, and a
    /// record that only names objects through their notes names fewer.
    pub fn of(tenancy: &Tenancy, live: &[Observed]) -> RecordedObjects {
        let manager = tenancy.manager_of(&tenancy.cluster);
        if tenancy.cluster.is_empty() {
            return RecordedObjects {
                by_object: HashMap::new(),
                manager,
                incomplete: vec![Incomplete::NoCluster],
            };
        }
        let mut incomplete: Vec<Incomplete> = tenancy
            .problems()
            .iter()
            .filter(|p| p.cluster().is_none_or(|c| c == tenancy.cluster))
            .cloned()
            .map(Incomplete::Tenancy)
            .collect();
        let pending: Vec<String> = tenancy
            .own_records()
            .iter()
            .filter(|r| {
                r.revisions.is_none()
                    && matches!(r.phase.as_str(), "" | PHASE_QUEUED | PHASE_DEPLOYING)
            })
            .map(|r| r.name.clone())
            .collect();
        if !pending.is_empty() {
            incomplete.push(Incomplete::OlderKixPending { records: pending });
        }

        let objects: Vec<DynamicObject> = live.iter().map(|o| o.obj.clone()).collect();
        let current = convert::current_of(tenancy.own_current(), tenancy.own_records())
            .map(|r| r.name.clone());
        let tenancy = match converted(tenancy, current.as_deref(), &objects) {
            Ok(converted) => converted,
            Err(refusal) => {
                incomplete.push(Incomplete::Conversion(refusal));
                tenancy.clone()
            }
        };
        // A Superseded record names no revision a reader keeps
        // ([`AppliedHashes::of`]), even when the head still names it.
        let superseded: HashSet<&str> = tenancy
            .own_records()
            .iter()
            .filter(|r| r.phase == PHASE_SUPERSEDED)
            .map(|r| r.name.as_str())
            .collect();
        let applied = AppliedHashes::of(tenancy.own_records(), tenancy.revisions());
        let manifests: Vec<Value> = objects.iter().map(to_manifest_value).collect();
        let held: HashSet<ResourceId> = objects.iter().map(drift::resource_id).collect();
        let mut edges: HashMap<&str, Edges> = HashMap::new();

        let mut by_object = HashMap::new();
        for observed in live {
            let mut entries: Vec<Entry> = tenancy
                .claims_of(&observed.obj)
                .iter()
                .filter(|c| tenancy.is_own(&c.cluster) && !superseded.contains(c.record.as_str()))
                .filter_map(|claim| {
                    Some(Entry {
                        claim,
                        revision: tenancy.revision(&claim.revision)?,
                    })
                })
                .collect();
            entries.sort_by_key(|e| {
                (
                    e.claim.kept,
                    Some(e.claim.record.as_str()) != current.as_deref(),
                    e.claim.record.clone(),
                )
            });
            let Some(decided) = decide(&entries, observed.applied.as_deref()) else {
                continue;
            };
            let hash = decided.hash.filter(|h| *h != REBUILT).map(str::to_string);
            let mut records: Vec<String> = entries
                .iter()
                .filter(|e| !e.claim.kept)
                .filter(|e| hash.is_none() || Some(&e.claim.hash) == hash.as_ref())
                .filter_map(|e| e.claim.record_hash.clone())
                .collect();
            records.sort();
            records.dedup();
            let rid = drift::resource_id(&observed.obj);
            let revision = decided.from.revision;
            let edges = edges.entry(revision.name.as_str()).or_insert_with(|| {
                Edges::of_revisions([revision]).with_format_one_annotations(&manifests)
            });
            let mut needs: Vec<Need> = edges
                .needs_through_imports(&rid, |r| held.contains(r))
                .into_iter()
                .cloned()
                .collect();
            needs.sort();
            needs.dedup();
            let recorded = Recorded {
                slot: revision.spec.slot.clone(),
                hash,
                records,
                needs,
                applied: applied
                    .for_observed(observed, current.as_deref())
                    .map(str::to_string),
            };
            by_object.insert(rid, recorded);
        }
        RecordedObjects {
            by_object,
            manager,
            incomplete,
        }
    }

    /// Return what the records say about `obj`, or `None` when no record of
    /// the Kix cluster names it.
    pub fn get(&self, obj: &DynamicObject) -> Option<&Recorded> {
        self.by_object.get(&drift::resource_id(obj))
    }

    /// Return why an object without an entry may still be one the records
    /// name, or an entry may be stale. Empty when the read is complete.
    pub fn incomplete(&self) -> &[Incomplete] {
        &self.incomplete
    }

    /// Run the drift check on `observed` against the applied hash its
    /// records hold.
    pub fn drift(&self, observed: &Observed) -> DriftReport {
        let applied = self.get(&observed.obj).and_then(|r| r.applied.as_deref());
        drift::check_observed(observed, applied, &self.manager)
    }
}

/// One revision of the Kix cluster that names an object.
struct Entry<'a> {
    claim: &'a Claim,
    revision: &'a Revision,
}

/// The entry that gives an object its slot, and the hash it gives.
struct Decided<'e, 'a> {
    from: &'e Entry<'a>,
    hash: Option<&'a str>,
}

/// Return `tenancy` as it reads once the next deploy converts the records
/// that have no map or a format 1 map, with `current` as the record a run
/// treats as current.
fn converted(
    tenancy: &Tenancy,
    current: Option<&str>,
    objects: &[DynamicObject],
) -> Result<Tenancy, convert::Refusal> {
    let own = tenancy.own_records();
    let current = current.and_then(|name| own.iter().find(|r| r.name == name));
    let conversion = convert::in_memory(
        &tenancy.cluster,
        current,
        own,
        &tenancy.own_listed_revisions(),
        objects,
        &[],
    )?;
    Ok(tenancy.with_conversion(&conversion))
}

/// Decide the hash the records gave an object that `entries` name, sorted
/// current record first and kept orphans last, given `applied`, the applied
/// hash of what the object holds now. Return `None` when no entry names it.
///
/// The hash of a revision that applied what the object holds comes first,
/// so a deploy whose record names its revisions and that stopped partway
/// does not file new content under the old hash. A deploy by an older Kix
/// that is still under way names no revisions, and
/// [`Incomplete::OlderKixPending`] reports it. Otherwise the hash is the one
/// the revisions other than the kept orphans agree on, or the kept orphans'
/// when nothing else names the object.
fn decide<'e, 'a>(entries: &'e [Entry<'a>], applied: Option<&str>) -> Option<Decided<'e, 'a>> {
    let first = entries.first()?;
    if let Some(applied) = applied
        && let Some(from) = entries
            .iter()
            .find(|e| e.revision.applied.get(&e.claim.hash).map(String::as_str) == Some(applied))
    {
        return Some(Decided {
            from,
            hash: Some(from.claim.hash.as_str()),
        });
    }
    let deployed: Vec<&Entry> = entries.iter().filter(|e| !e.claim.kept).collect();
    let pool: Vec<&Entry> = if deployed.is_empty() {
        entries.iter().collect()
    } else {
        deployed
    };
    let agreed = pool
        .split_first()
        .filter(|(head, rest)| rest.iter().all(|e| e.claim.hash == head.claim.hash))
        .map(|(head, _)| *head);
    Some(match agreed {
        Some(from) => Decided {
            from,
            hash: Some(from.claim.hash.as_str()),
        },
        None => Decided {
            from: first,
            hash: None,
        },
    })
}

#[cfg(test)]
#[path = "recorded_tests.rs"]
mod tests;
