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
//!    fields: apply, reverting drift ([`drift::check_object`]). The fields
//!    the object cedes are out of that hash. The apply leaves out each ceded
//!    field another manager owns, so a forced apply does not take it back.
//!    A runner that never forces (the operator) does not write an object
//!    whose changed fields another manager owns, because the apply would be
//!    refused. It reports the drift instead. A runner that forces does not
//!    force the apply when another Kix cluster owns such a field, so the
//!    apply is refused with an error that names that Kix cluster.
//!
//! Otherwise the object is unchanged and nothing is written to it.
//!
//! The live objects give three answers for an object: present, absent, or
//! not known (its kind is not served). An object of the new build whose kind
//! is not served is absent, and the apply waits for its kind. An orphan
//! candidate whose kind is not served keeps its place in the kept-orphans
//! revision ([`Decided::unknown`]). An object this account may neither list
//! nor get stops the plan ([`ReadForbidden`]).
//!
//! An orphan is a live object that the new build does not make and that the
//! current record's revisions, the kept-orphans revision, or a `Failed` or
//! `Partial` record's revisions name. A `Failed` or `Partial` record left an
//! object only when the live object carries the build hash that record's
//! revision gives it, so a run that died before it wrote applied hashes
//! still leaves objects the next deploy takes in. An object that a `Degraded`,
//! `Failed`, or `Partial` record names is taken in only when it has an entry
//! under this Kix cluster's field manager, because that deploy may never have
//! reached it.
//!
//! A Kix cluster that is not read from revisions has no [`Ledger`]
//! ([`Ledger::of`] returns `None`), and its plans compare builds. A tenancy
//! that could not read this Kix cluster's records or revisions gives an
//! error rather than `None`, so the choice fails closed.

use std::collections::{BTreeSet, HashMap, HashSet};

use serde_json::Value;

use crate::cluster::apply::{self, ChangeAction, Deployed};
use crate::cluster::drift::{self, DriftReport, DriftVerdict};
use crate::cluster::field_manager::FieldManager;
use crate::cluster::inventory::{Live, LiveObjects, ReadForbidden};
use crate::cluster::revision::{AppliedHashes, RevisionObject};
use crate::cluster::tenancy::{Problem, Source, Tenancy};
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
    /// The live object's Kix-owned fields changed because another Kix
    /// cluster applied fields the build sets with other values. The apply
    /// is sent without force, so Kubernetes refuses it and the error names
    /// that Kix cluster. Taking the fields back by force would only move
    /// the refusal to the other Kix cluster's next deploy.
    HeldByOtherCluster(DriftReport),
    /// The live object's Kix-owned fields changed since Kix applied it, and
    /// another manager owns fields the build sets. A runner that never
    /// forces reports this and writes nothing, because Kubernetes would
    /// refuse the apply. The live object carries the build's hash, so what
    /// depends on it goes on.
    DriftReported(DriftReport),
    /// Unchanged, and written again because the deploy runs with
    /// `--reconcile`.
    Reconciled,
    /// Unchanged: nothing is written to it.
    Unchanged,
}

/// What a deploy does to one object of the new build.
#[derive(Debug, Clone)]
pub(crate) struct Decision {
    pub id: ResourceId,
    pub action: ChangeAction,
    pub label: Label,
    /// The `resourceVersion` of the live object the decision read, or
    /// `None` when the cluster does not hold it.
    pub resource_version: Option<String>,
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
    /// The candidates whose kind the cluster does not serve, with each build
    /// hash a record gives them, sorted. Nothing shows whether they are
    /// still on the cluster, so the run's kept-orphans revision names them
    /// again.
    pub unknown: Vec<RevisionObject>,
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
#[derive(Debug)]
pub(crate) struct Ledger {
    /// The field manager of the Kix cluster the ledger is read for.
    manager: FieldManager,
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
    /// Refuse when `tenancy` could not read something about this Kix
    /// cluster or about every Kix cluster ([`Tenancy::complete_for_own`]),
    /// such as the revision list or the current record's map. Kix could
    /// not tell then whether this Kix cluster is read from revisions, or
    /// which objects its records name.
    ///
    /// With `take_in_stopped`, the revisions of each `Failed` or `Partial`
    /// record name objects the deploy takes in. Without it, another deploy
    /// may still be applying them, so they are left out.
    pub(crate) fn of(tenancy: &Tenancy, take_in_stopped: bool) -> Result<Option<Ledger>, Problem> {
        tenancy.complete_for_own()?;
        if tenancy.own_source() != Source::Revisions {
            return Ok(None);
        }
        let current = tenancy.own_current();
        let mut ledger = Ledger {
            manager: FieldManager::of(&tenancy.cluster),
            named: HashMap::new(),
            applied: AppliedHashes::of(tenancy.own_records(), tenancy.revisions()),
            taken_in: Vec::new(),
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
        Ok(Some(ledger))
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

    /// Return `rid` with each build hash a record gives it, once each.
    fn named_objects(&self, rid: &ResourceId) -> Vec<RevisionObject> {
        let mut out: Vec<RevisionObject> = self
            .named(rid)
            .map(|n| RevisionObject::of_id(&n.hash, rid))
            .collect();
        out.sort();
        out.dedup();
        out
    }

    /// Return whether the live object `obj` is an orphan the deploy takes
    /// in: an `Active` current record or its kept orphans name it, or a
    /// record whose deploy may not have reached it names it and this Kix
    /// cluster wrote it. Such a record is a `Degraded` current record, or a
    /// `Failed` or `Partial` record that names it with the build hash it
    /// carries. An object with no entry under this cluster's field manager
    /// came from elsewhere, such as another Kix cluster that deploys an
    /// object of the same name.
    fn takes_in(&self, rid: &ResourceId, obj: &kube::api::DynamicObject) -> bool {
        let live = build_hash(obj);
        let written_here = || {
            obj.metadata
                .managed_fields
                .iter()
                .flatten()
                .any(|e| self.manager.counts_as_own(e.manager.as_deref()))
        };
        self.named(rid).any(|n| match n.role {
            Role::Current if n.phase == PHASE_DEGRADED => written_here(),
            Role::Current | Role::Kept => true,
            Role::Stopped => live == Some(n.hash.as_str()) && written_here(),
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

/// Decide what a deploy does to each object of `new` and which live objects
/// it takes in as orphans.
///
/// `new` holds the objects the runner applies. `made` holds every object of
/// the new build, which can be more: the operator leaves CRDs and the
/// Activation record out of `new`, and they are still not orphans. `live`
/// holds the live objects of `new` and of every object the ledger names
/// that `made` lacks ([`Ledger::candidates`]). With `reconcile`, an
/// unchanged object is written again. `forces` says whether the runner
/// applies the objects that revert drift with force, as the CLI does and
/// the operator does not.
///
/// Refuse when this account may neither list nor get an object of `new` or
/// a candidate.
pub(crate) fn decide(
    new: &[Value],
    made: &HashSet<ResourceId>,
    live: &LiveObjects,
    ledger: &Ledger,
    reconcile: bool,
    forces: bool,
) -> Result<Decided, ReadForbidden> {
    let mut out = Decided::default();
    let mut forbidden: BTreeSet<String> = BTreeSet::new();
    for manifest in new {
        let id = ResourceId::from_value(manifest);
        let mut resource_version = None;
        let (action, label) = match live.get(&id) {
            Live::Unread => {
                forbidden.extend(live.forbidden_resource(&id).map(str::to_string));
                continue;
            }
            Live::Present(obj) if obj.metadata.deletion_timestamp.is_none() => {
                resource_version = obj.metadata.resource_version.clone();
                match decide_present(manifest, &id, obj, ledger, forces) {
                    Some((label, action)) => (action, label),
                    None if reconcile => (
                        apply::changed(manifest, Deployed::RerunHash(rerun_hash(obj)), false),
                        Label::Reconciled,
                    ),
                    None => (ChangeAction::Skip(id.clone()), Label::Unchanged),
                }
            }
            // Gone, being deleted, or of a kind not served yet: the apply
            // waits for it to go, or for its kind, then creates it.
            found => {
                let hash = keys::get(manifest, keys::IDENTITY_HASH);
                if hash.is_some_and(|h| ledger.deployed(&id, h)) {
                    out.lost.push(id.clone());
                }
                let deployed = match found {
                    Live::Present(obj) => Deployed::RerunHash(rerun_hash(obj)),
                    Live::Absent | Live::Unserved | Live::Unread => Deployed::Nothing,
                };
                let label = match ledger.left_by_degraded(&id, None) {
                    Some(record) => Label::LeftByDegraded(record.to_string()),
                    None => Label::Intended,
                };
                (apply::changed(manifest, deployed, false), label)
            }
        };
        out.decisions.push(Decision {
            id,
            action,
            label,
            resource_version,
        });
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
                forbidden.extend(live.forbidden_resource(rid).map(str::to_string));
            }
            Live::Unserved => out.unknown.extend(ledger.named_objects(rid)),
            Live::Present(_) | Live::Absent => {}
        }
    }
    if !forbidden.is_empty() {
        return Err(ReadForbidden {
            resources: forbidden.into_iter().collect(),
        });
    }
    orphans.sort();
    out.orphans = orphans;
    out.unknown.sort();
    Ok(out)
}

/// Apply the three rules to `manifest`, whose live object `obj` the cluster
/// holds. Return `None` when the object is unchanged.
fn decide_present(
    manifest: &Value,
    id: &ResourceId,
    obj: &kube::api::DynamicObject,
    ledger: &Ledger,
    forces: bool,
) -> Option<(Label, ChangeAction)> {
    let apply = |m: &Value| apply::changed(m, Deployed::RerunHash(rerun_hash(obj)), false);
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
        return Some((label, apply(manifest)));
    }
    // No revision names the Activation record, so it has no applied hash
    // to keep.
    if record {
        return None;
    }
    let Some(applied) = ledger.applied.applied(obj) else {
        return Some((Label::AppliedHashMissing, apply(manifest)));
    };
    let report = drift::check_object(obj, Some(applied), &ledger.manager);
    match report.verdict {
        // Kix recorded what it applied, so an object that now has no Kix
        // field records lost every field Kix owned.
        DriftVerdict::Drifted { .. } | DriftVerdict::NoFieldset => {
            if !forces && drift::conflicts(obj, manifest, &ledger.manager) {
                return Some((Label::DriftReported(report), ChangeAction::Skip(id.clone())));
            }
            if !drift::held_by_other_clusters(obj, manifest, &ledger.manager).is_empty() {
                return Some((Label::HeldByOtherCluster(report), apply(manifest)));
            }
            let sent = drift::without_ceded_taken(manifest, obj, &ledger.manager);
            Some((Label::RevertsDrift(report), apply(&sent)))
        }
        DriftVerdict::InSync | DriftVerdict::Unstamped => None,
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
