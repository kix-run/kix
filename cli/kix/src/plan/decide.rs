//! The one planner: what a deploy does to each object of a Kix cluster read
//! from revisions.
//!
//! [`decide`] reads three stored facts: the new build, the live objects, and
//! the records and revisions of the Kix cluster ([`Ledger`]). `kix plan`,
//! `kix deploy`, `kix rollback`, and the operator's deploy and repair all
//! decide through it. For each object of the new build it applies three
//! rules, in this order:
//!
//! 1. The live object is missing, or its build hash (`kix.run/identity-hash`)
//!    or owner stamps differ from the new build's: apply.
//! 2. The build hashes match and Kix has no applied hash for the object:
//!    apply, so the run records one. A missing applied hash never reads as
//!    in sync.
//! 3. The applied hash differs from the hash of the live object's Kix-owned
//!    fields: apply, reverting drift ([`drift::check_object`]).
//!
//! Otherwise the object is unchanged and nothing is written to it.
//!
//! An orphan is a live object that the new build does not make and that the
//! current record's revisions, the kept-orphans revision, or a `Failed` or
//! `Partial` record's revisions name. A `Failed` or `Partial` record left an
//! object only when the live object carries the build hash that record's
//! revision gives it, so a run that died before it wrote applied hashes
//! still leaves objects the next deploy takes in.
//!
//! A Kix cluster that is not read from revisions has no [`Ledger`]
//! ([`Ledger::of`] returns `None`), and its plans compare builds.

use std::collections::{BTreeSet, HashMap, HashSet};

use serde_json::Value;

use crate::cluster::apply::{self, ChangeAction, Deployed};
use crate::cluster::drift::{self, DriftReport, DriftVerdict};
use crate::cluster::inventory::{Live, LiveObjects};
use crate::cluster::revision::AppliedHashes;
use crate::cluster::tenancy::{Source, Tenancy};
use crate::manifest::keys;
use crate::manifest::lifecycle::{self, PHASE_DEGRADED, PHASE_FAILED, PHASE_PARTIAL};
use crate::manifest::types::ResourceId;

/// Why a decision writes an object, or why it leaves it alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Label {
    /// The new build changes the object, or the cluster does not hold it.
    Intended,
    /// The live object carries the build hash that this `Failed` or
    /// `Partial` record's revision gives it: that deploy wrote it.
    AppliedByRecord(String),
    /// This `Degraded` record names the object with a build hash the live
    /// object does not carry: its deploy did not reach it.
    LeftByDegraded(String),
    /// The live object carries the new build's hash, but Kix has no applied
    /// hash for it.
    AppliedHashMissing,
    /// The live object's Kix-owned fields changed since Kix applied it.
    RevertsDrift(DriftReport),
    /// Unchanged, and written again because the deploy runs with
    /// `--reconcile`.
    Reconciled,
    /// Unchanged: nothing is written to it.
    Unchanged,
    /// The account may not list the object's kind, so it is left alone.
    NotListed,
}

/// What a deploy does to one object of the new build.
#[derive(Debug, Clone)]
pub(crate) struct Decision {
    pub id: ResourceId,
    pub action: ChangeAction,
    pub label: Label,
}

/// What [`decide`] found.
#[derive(Debug, Default)]
pub(crate) struct Decided {
    /// One for each object of the new build, in its order.
    pub decisions: Vec<Decision>,
    /// The orphans, sorted.
    pub orphans: Vec<ResourceId>,
    /// Objects the new build leaves unchanged from the current record that
    /// are gone or being deleted.
    pub lost: Vec<ResourceId>,
    /// The kinds the account may not list, as `Kind` or `Kind.group`.
    pub unread: BTreeSet<String>,
}

/// How a record of the Kix cluster names an object.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Role {
    /// One of the current record's revisions, other than its kept orphans.
    Current,
    /// The current record's kept-orphans revision.
    Kept,
    /// A revision of a `Failed` or `Partial` record whose leftovers the
    /// deploy takes in.
    Stopped,
}

/// One revision of a record that names an object.
#[derive(Debug, Clone)]
struct Named {
    record: String,
    phase: String,
    role: Role,
    /// The build hash the revision gives the object.
    hash: String,
    /// The revision records an applied hash for the object.
    applied: bool,
}

/// What the records and revisions of one Kix cluster say about its objects.
#[derive(Debug, Default)]
pub(crate) struct Ledger {
    named: HashMap<ResourceId, Vec<Named>>,
    applied: AppliedHashes,
    taken_in: Vec<String>,
}

impl Ledger {
    /// Read the ledger of the Kix cluster `tenancy` is read for, or return
    /// `None` when that Kix cluster is not read from revisions. This is the
    /// one place that chooses between the one planner and the comparison of
    /// builds.
    ///
    /// With `take_in_stopped`, the revisions of each `Failed` or `Partial`
    /// record name objects the deploy takes in. Without it, another deploy
    /// may still be applying them, so they are left out.
    pub(crate) fn of(tenancy: &Tenancy, take_in_stopped: bool) -> Option<Ledger> {
        if tenancy.own_source() != Source::Revisions {
            return None;
        }
        let current = tenancy.own_current();
        let mut ledger = Ledger {
            applied: AppliedHashes::of(tenancy.own_records(), tenancy.revisions()),
            ..Ledger::default()
        };
        for record in tenancy.own_records() {
            let Some(Ok(map)) = &record.revisions else {
                continue;
            };
            let built = map
                .instances
                .values()
                .chain(std::iter::once(&map.cluster_level));
            let named: Vec<(&String, Role)> = if Some(record.name.as_str()) == current {
                built
                    .map(|n| (n, Role::Current))
                    .chain(map.kept_orphans.iter().map(|n| (n, Role::Kept)))
                    .collect()
            } else if take_in_stopped
                && matches!(record.phase.as_str(), PHASE_FAILED | PHASE_PARTIAL)
            {
                ledger.taken_in.push(record.name.clone());
                built.map(|n| (n, Role::Stopped)).collect()
            } else {
                continue;
            };
            for (name, role) in named {
                let Some(revision) = tenancy.revision(name) else {
                    continue;
                };
                for object in &revision.spec.objects {
                    ledger
                        .named
                        .entry(object.resource_id())
                        .or_default()
                        .push(Named {
                            record: record.name.clone(),
                            phase: record.phase.clone(),
                            role: role.clone(),
                            hash: object.hash.clone(),
                            applied: revision.applied.contains_key(&object.hash),
                        });
                }
            }
        }
        ledger.taken_in.sort();
        Some(ledger)
    }

    /// Return the `Failed` and `Partial` records whose leftovers the deploy
    /// takes in, sorted. A run that finalizes supersedes them.
    pub(crate) fn taken_in(&self) -> &[String] {
        &self.taken_in
    }

    /// Return the objects the ledger names that the new build, whose objects
    /// are `made`, does not make: the objects that may be orphans.
    pub(crate) fn candidates<'a>(
        &'a self,
        made: &'a HashSet<ResourceId>,
    ) -> impl Iterator<Item = &'a ResourceId> {
        self.named.keys().filter(move |rid| !made.contains(*rid))
    }

    /// Return the `Failed` or `Partial` record whose revision gives the
    /// object `rid` the build hash `live`.
    fn applied_by(&self, rid: &ResourceId, live: &str) -> Option<&str> {
        self.named(rid)
            .find(|n| n.role == Role::Stopped && n.hash == live)
            .map(|n| n.record.as_str())
    }

    /// Return the current `Degraded` record when its deploy did not reach
    /// `rid`: the live object carries another build hash than the one the
    /// record gives it, or, when the object is gone (`live` is `None`), the
    /// record has no applied hash for it.
    fn left_by_degraded(&self, rid: &ResourceId, live: Option<&str>) -> Option<&str> {
        self.named(rid)
            .find(|n| {
                n.role == Role::Current
                    && n.phase == PHASE_DEGRADED
                    && match live {
                        Some(live) => n.hash != live,
                        None => !n.applied,
                    }
            })
            .map(|n| n.record.as_str())
    }

    /// Return whether the current record names `rid` with build hash
    /// `hash`: the new build leaves the object unchanged.
    fn deployed(&self, rid: &ResourceId, hash: &str) -> bool {
        self.named(rid)
            .any(|n| n.role == Role::Current && n.hash == hash)
    }

    fn named(&self, rid: &ResourceId) -> impl Iterator<Item = &Named> {
        self.named.get(rid).into_iter().flatten()
    }

    /// Return whether the live object `obj` is an orphan the deploy takes
    /// in: the current record or its kept orphans name it, or a `Failed` or
    /// `Partial` record names it with the build hash it carries.
    fn takes_in(&self, rid: &ResourceId, obj: &kube::api::DynamicObject) -> bool {
        let live = build_hash(obj);
        self.named(rid).any(|n| match n.role {
            Role::Current | Role::Kept => true,
            Role::Stopped => live == Some(n.hash.as_str()),
        })
    }
}

/// Return the build hash the live object `obj` carries.
fn build_hash(obj: &kube::api::DynamicObject) -> Option<&str> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
}

fn kind_name(rid: &ResourceId) -> String {
    match rid.group.as_str() {
        "" => rid.kind.clone(),
        group => format!("{}.{group}", rid.kind),
    }
}

/// Decide what a deploy does to each object of `new` and which live objects
/// it takes in as orphans.
///
/// `new` holds the objects the runner applies. `made` holds every object of
/// the new build, which can be more: the operator leaves CRDs and the
/// Activation record out of `new`, and they are still not orphans. `live`
/// holds the live objects of `new` and of every object the ledger names
/// that `made` lacks ([`Ledger::candidates`]). With `reconcile`, an
/// unchanged object is written again.
pub(crate) fn decide(
    new: &[Value],
    made: &HashSet<ResourceId>,
    live: &LiveObjects,
    ledger: &Ledger,
    reconcile: bool,
) -> Decided {
    let mut out = Decided::default();
    for manifest in new {
        let id = ResourceId::from_value(manifest);
        let (action, label) = match live.get(&id) {
            Live::Unread => {
                out.unread.insert(kind_name(&id));
                (ChangeAction::Skip(id.clone()), Label::NotListed)
            }
            Live::Present(obj) if obj.metadata.deletion_timestamp.is_none() => {
                match decide_present(manifest, &id, obj, ledger) {
                    Some((label, action)) => (action, label),
                    None if reconcile => (
                        apply::changed(manifest, Deployed::RerunHash(rerun_hash(obj)), false),
                        Label::Reconciled,
                    ),
                    None => (ChangeAction::Skip(id.clone()), Label::Unchanged),
                }
            }
            // Gone, or being deleted: the apply waits for it to go, then
            // creates it.
            found => {
                let hash = keys::get(manifest, keys::IDENTITY_HASH);
                if hash.is_some_and(|h| ledger.deployed(&id, h)) {
                    out.lost.push(id.clone());
                }
                let deployed = match found {
                    Live::Present(obj) => Deployed::RerunHash(rerun_hash(obj)),
                    Live::Absent | Live::Unread => Deployed::Nothing,
                };
                let label = match ledger.left_by_degraded(&id, None) {
                    Some(record) => Label::LeftByDegraded(record.to_string()),
                    None => Label::Intended,
                };
                (apply::changed(manifest, deployed, false), label)
            }
        };
        out.decisions.push(Decision { id, action, label });
    }

    let mut orphans: Vec<ResourceId> = Vec::new();
    for rid in ledger.candidates(made) {
        match live.get(rid) {
            Live::Present(obj)
                if lifecycle::lifecycle_of_live(obj).prunable() && ledger.takes_in(rid, obj) =>
            {
                orphans.push(rid.clone());
            }
            Live::Unread => {
                out.unread.insert(kind_name(rid));
            }
            Live::Present(_) | Live::Absent => {}
        }
    }
    orphans.sort();
    out.orphans = orphans;
    out
}

/// Apply the three rules to `manifest`, whose live object `obj` the cluster
/// holds. Return `None` when the object is unchanged.
fn decide_present(
    manifest: &Value,
    id: &ResourceId,
    obj: &kube::api::DynamicObject,
    ledger: &Ledger,
) -> Option<(Label, ChangeAction)> {
    let apply = || apply::changed(manifest, Deployed::RerunHash(rerun_hash(obj)), false);
    let live = build_hash(obj);
    let record = lifecycle::is_record(manifest);
    if live != keys::get(manifest, keys::IDENTITY_HASH)
        || (!record && apply::owner_stamps_moved(manifest, obj))
    {
        let label = match live.and_then(|h| ledger.applied_by(id, h)) {
            Some(by) => Label::AppliedByRecord(by.to_string()),
            None => match ledger.left_by_degraded(id, live) {
                Some(by) => Label::LeftByDegraded(by.to_string()),
                None => Label::Intended,
            },
        };
        return Some((label, apply()));
    }
    // No revision names the Activation record, so it has no applied hash
    // to keep.
    if record {
        return None;
    }
    let Some(applied) = ledger.applied.applied(obj) else {
        return Some((Label::AppliedHashMissing, apply()));
    };
    let report = drift::check_object(obj, Some(applied));
    match report.verdict {
        DriftVerdict::Drifted { .. } => Some((Label::RevertsDrift(report), apply())),
        // An object with no Kix field records gives no hash to compare,
        // so nothing shows that it changed.
        DriftVerdict::InSync | DriftVerdict::NoFieldset | DriftVerdict::Unstamped => None,
    }
}

fn rerun_hash(obj: &kube::api::DynamicObject) -> Option<&str> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::RERUN_HASH))
}

#[cfg(test)]
#[path = "decide_tests.rs"]
mod tests;
