//! The one planner: what a deploy does to each object of a Kix cluster read
//! from revisions.
//!
//! [`decide`] reads three stored facts: the new build, the live objects, and
//! the records and revisions of the Kix cluster ([`Ledger`]). `kix plan`,
//! `kix deploy`, `kix rollback`, and the operator's deploy and repair all
//! decide through it. For each object of the new build it applies one rule:
//!
//! > Skip the object when a revision this Kix cluster needs holds an applied
//! > hash for the object with the new build's object hash, and the live
//! > object still matches that applied hash. In every other case, apply it
//! > and record the applied hash.
//!
//! The object hash ([`crate::manifest::hash::object_hash`]) and the applied
//! hash ([`crate::cluster::fieldsv1::applied_content_hash`]) cover the same
//! things: every field Kix sends, every `kix.run/*` annotation among them,
//! and none of the retired notes. Nothing on the live object says which build
//! wrote it, so the revisions say it, by the object's name.
//!
//! When the revision holds an applied hash for the new build's object hash
//! and the live object differs from it, the apply reverts drift
//! ([`drift::check_object`]): the fields the object cedes are out of that
//! hash, and the apply leaves out each ceded field another manager owns, so
//! a forced apply does not take it back. A runner that never forces (the
//! operator) applies the build without the fields another manager took from
//! Kix's own `Apply` entry, because the apply would be refused on them. It
//! reports those fields and records no applied hash, so the report stays
//! until the drift is gone. When another Kix cluster owns such a field,
//! every runner applies without force, so Kubernetes refuses only a value
//! that differs, with an error that names that Kix cluster.
//!
//! The live object can also match an applied hash another revision holds,
//! when a `Failed` or `Partial` deploy wrote it. Then the apply is no drift
//! and is sent without force.
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
//! `Partial` record's revisions name. An object that a `Degraded`, `Failed`,
//! or `Partial` record names is taken in only when this Kix cluster wrote
//! it, because that deploy may never have reached it. For a `Failed` or
//! `Partial` record that means an `Apply` entry under this Kix cluster's own
//! field manager. The manager `kix` an older Kix shared between Kix clusters
//! does not count, so a deploy never takes in an object only another Kix
//! cluster wrote before the upgrade.
//!
//! Every record a plan reads has a revision map: a run gives the records an
//! older Kix wrote revisions before it writes anything
//! ([`crate::cluster::revision::convert`]), and a plan reads the same
//! conversion from memory ([`Tenancy::with_conversion`]). A tenancy that
//! could not read this Kix cluster's records or revisions gives an error, so
//! the plan fails closed.
//!
//! [`decide`] also lists each object that needs the migration write
//! ([`crate::cluster::migration_write`]). It judges drift on such an object
//! as the write leaves it: the entry under `kix` that the write moves to
//! this Kix cluster's manager counts as this cluster's own, and only on an
//! object a record of this cluster names ([`migration_write::takes_legacy`]).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use serde_json::Value;

use crate::cluster::apply::{self, ChangeAction, Deployed};
use crate::cluster::drift::{self, DriftReport};
use crate::cluster::edges::{Edges, Prior};
use crate::cluster::field_manager::FieldManager;
use crate::cluster::fieldsv1;
use crate::cluster::inventory::{Live, LiveObjects, ReadForbidden};
use crate::cluster::migration_write;
use crate::cluster::revision::{AppliedHashes, Need, RevisionObject};
use crate::cluster::tenancy::{Problem, Tenancy};
use crate::manifest::hash;
use crate::manifest::keys;
use crate::manifest::lifecycle::{self, PHASE_DEGRADED, PHASE_FAILED, PHASE_PARTIAL};
use crate::manifest::types::ResourceId;

/// Why a decision writes an object, or why it leaves it alone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Label {
    /// The new build changes the object, or the cluster does not hold it.
    Intended,
    /// The live object matches the applied hash that a revision of this
    /// `Failed` or `Partial` record holds for it: that deploy wrote it.
    AppliedByRecord(String),
    /// This `Degraded` record names the object and holds no applied hash
    /// for it: its deploy did not reach it.
    LeftByDegraded(String),
    /// A revision this Kix cluster needs names the object with the new
    /// build's object hash, and holds no applied hash for it.
    AppliedHashMissing,
    /// A revision of this `Failed` or `Partial` record names the object and
    /// holds no applied hash for it, and the live object matches no applied
    /// hash a revision holds. A deploy of this Kix cluster that did not
    /// finish may have written it. With a drift report, a revision holds an
    /// applied hash for the new build's object hash, and the apply takes
    /// back what differs from it as [`Label::RevertsDrift`] does.
    Unfinished {
        record: String,
        drift: Option<DriftReport>,
    },
    /// The live object's Kix-owned fields changed since Kix applied it.
    RevertsDrift(DriftReport),
    /// Another Kix cluster, or the manager `kix` an older Kix applies
    /// under, holds fields the build sets. The apply is sent without force:
    /// it adds this Kix cluster's entry when the values agree, and
    /// Kubernetes refuses it with an error that names that manager when
    /// they differ. Taking the fields by force would only move the refusal
    /// to the other Kix cluster's next deploy. The operator sends it too
    /// when this Kix cluster has no `Apply` entry of its own on the object.
    HeldByOtherCluster(DriftReport),
    /// The live object's Kix-owned fields changed since Kix applied it, and
    /// another manager took fields the build sets. A runner that never
    /// forces applies the build without those fields, reports them, and
    /// records no applied hash.
    DriftReported(DriftReport),
    /// Unchanged, and written again because the deploy runs with
    /// `--reconcile`.
    Reconciled,
    /// Unchanged: nothing is written to it.
    Unchanged,
}

impl Label {
    /// Return whether the CLI applies the object with force, taking back
    /// the fields another manager changed.
    pub(crate) fn reverts_drift(&self) -> bool {
        matches!(
            self,
            Label::RevertsDrift(_) | Label::Unfinished { drift: Some(_), .. }
        )
    }
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
    /// The candidates whose kind the cluster does not serve, with each build
    /// hash a record gives them, sorted. Nothing shows whether they are
    /// still on the cluster, so the run's kept-orphans revision names them
    /// again.
    pub unknown: Vec<RevisionObject>,
    /// The objects of the new build that need the migration write, sorted.
    pub migrations: Vec<ResourceId>,
    /// The objects of `migrations` whose entry under `kix` the write moves
    /// to this Kix cluster's manager ([`migration_write::renames`]).
    pub renamed: Vec<ResourceId>,
    /// The objects a runner that never forces applies without the fields
    /// another manager holds ([`Label::DriftReported`]). The run records no
    /// applied hash for them.
    pub unrecorded: Vec<ResourceId>,
    /// The orphans that need the migration write, sorted. A run writes it
    /// to those it leaves on the cluster, once it has recorded them.
    pub orphan_migrations: Vec<ResourceId>,
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
    /// The hash the revision gives the object ([`RevisionObject::hash`]).
    hash: String,
    /// What the revision says the object depends on.
    needs: Vec<Need>,
    /// The applied hash the revision holds for the object.
    applied: Option<String>,
}

/// What the records and revisions of one Kix cluster say about its objects.
#[derive(Debug)]
pub(crate) struct Ledger {
    /// The field manager of the Kix cluster the ledger is read for.
    manager: FieldManager,
    named: HashMap<ResourceId, Vec<Named>>,
    applied: AppliedHashes,
    taken_in: Vec<String>,
    /// Which Kix clusters name each object, which decides whose fields the
    /// entry under `kix` holds.
    tenancy: Tenancy,
    /// The identity hash of the record the run deploys.
    record: Option<String>,
    /// A run first gives records an older Kix wrote revisions.
    converts: bool,
}

impl Ledger {
    /// Read the ledger of the Kix cluster `tenancy` is read for, from the
    /// revisions of its records. Pass a tenancy that holds the conversion a
    /// run writes first ([`Tenancy::with_conversion`]), so every record it
    /// reads has a map.
    ///
    /// Refuse when `tenancy` could not read something about this Kix
    /// cluster or about every Kix cluster ([`Tenancy::complete_for_own`]),
    /// such as the revision list or a record's map. Kix could not tell then
    /// which objects its records name.
    ///
    /// With `take_in_stopped`, the revisions of each `Failed` or `Partial`
    /// record name objects the deploy takes in. Without it, another deploy
    /// may still be applying them, so they are left out.
    pub(crate) fn of(tenancy: &Tenancy, take_in_stopped: bool) -> Result<Ledger, Problem> {
        tenancy.complete_for_own()?;
        let mut ledger = Ledger {
            manager: FieldManager::of(&tenancy.cluster),
            named: HashMap::new(),
            applied: AppliedHashes::of(tenancy.own_records(), tenancy.revisions()),
            taken_in: Vec::new(),
            tenancy: tenancy.clone(),
            record: None,
            converts: false,
        };
        let current = crate::cluster::revision::convert::current_of(
            tenancy.own_current(),
            tenancy.own_records(),
        )
        .map(|r| r.name.clone());
        for record in tenancy.own_records() {
            let role = if Some(&record.name) == current.as_ref() {
                Role::Current
            } else if take_in_stopped
                && matches!(record.phase.as_str(), PHASE_FAILED | PHASE_PARTIAL)
                && matches!(record.revisions, Some(Ok(_)))
            {
                ledger.taken_in.push(record.name.clone());
                Role::Stopped
            } else {
                continue;
            };
            ledger.name_revisions(tenancy, record, role);
        }
        ledger.taken_in.sort();
        Ok(ledger)
    }

    /// Name every object the revisions of `record` name, in `role`: the
    /// built revisions, and the kept-orphans revision for the current
    /// record.
    fn name_revisions(
        &mut self,
        tenancy: &Tenancy,
        record: &crate::cluster::activation::Record,
        role: Role,
    ) {
        let Some(Ok(map)) = &record.revisions else {
            return;
        };
        let built = map
            .instances
            .values()
            .chain(std::iter::once(&map.cluster_level))
            .map(|n| (n, role.clone()));
        let kept = map
            .kept_orphans
            .iter()
            .filter(|_| role == Role::Current)
            .map(|n| (n, Role::Kept));
        for (name, role) in built.chain(kept) {
            let Some(revision) = tenancy.revision(name) else {
                continue;
            };
            for object in &revision.spec.objects {
                self.named
                    .entry(object.resource_id())
                    .or_default()
                    .push(Named {
                        record: record.name.clone(),
                        phase: record.phase.clone(),
                        role: role.clone(),
                        hash: object.hash.clone(),
                        needs: object.needs.clone(),
                        applied: revision.applied.get(&object.hash).cloned(),
                    });
            }
        }
    }

    /// Set the identity hash of the record the run deploys, which the
    /// migration write keeps in a note it keeps for an older Kix.
    pub(crate) fn deploying(&mut self, record: Option<&str>) {
        self.record = record.map(str::to_string);
    }

    /// Return the identity hash of the record the run deploys.
    pub(crate) fn record(&self) -> Option<&str> {
        self.record.as_deref()
    }

    /// Note whether a run first gives records an older Kix wrote
    /// revisions, which the ledger already reads.
    pub(crate) fn set_converts(&mut self, converts: bool) {
        self.converts = converts;
    }

    /// Return whether a run first gives records an older Kix wrote
    /// revisions.
    pub(crate) fn converts(&self) -> bool {
        self.converts
    }

    /// Return whether `obj` needs the migration write.
    fn migrates(&self, obj: &kube::api::DynamicObject) -> bool {
        migration_write::needed(obj, &self.manager, &self.tenancy, self.record()).is_some()
    }

    /// Return the field manager to judge `obj` with: as the migration write
    /// leaves it. The write moves an entry under `kix` to this Kix cluster's
    /// manager only when the entry holds this cluster's fields
    /// ([`migration_write::takes_legacy`]).
    fn view_of(&self, obj: &kube::api::DynamicObject) -> FieldManager {
        migration_write::view_of(obj, &self.manager, &self.tenancy)
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

    /// Return the `Failed` or `Partial` record whose revision holds the
    /// applied hash `live` for the object `rid`: that deploy wrote what the
    /// live object holds.
    fn applied_by(&self, rid: &ResourceId, live: &str) -> Option<&str> {
        self.named(rid)
            .find(|n| n.role == Role::Stopped && n.applied.as_deref() == Some(live))
            .map(|n| n.record.as_str())
    }

    /// Return the current `Degraded` record when its revision names `rid`
    /// and holds no applied hash for it: its deploy did not reach it.
    fn left_by_degraded(&self, rid: &ResourceId) -> Option<&str> {
        self.named(rid)
            .find(|n| n.role == Role::Current && n.phase == PHASE_DEGRADED && n.applied.is_none())
            .map(|n| n.record.as_str())
    }

    /// Return a `Failed` or `Partial` record whose revision names `rid` and
    /// holds no applied hash for it, when the live object, whose applied
    /// hash is `live`, matches no applied hash a revision holds for it. A
    /// deploy that was killed records no applied hashes, so such a record
    /// may have written the object.
    fn unfinished(&self, rid: &ResourceId, live: Option<&str>) -> Option<&str> {
        if live.is_some_and(|l| self.applied.holds(rid, l)) {
            return None;
        }
        self.named(rid)
            .find(|n| n.role == Role::Stopped && n.applied.is_none())
            .map(|n| n.record.as_str())
    }

    /// Return whether a revision this Kix cluster needs names `rid` with
    /// hash `hash` and holds no applied hash for it.
    fn names_unapplied(&self, rid: &ResourceId, hash: &str) -> bool {
        self.named(rid)
            .any(|n| n.hash == hash && n.applied.is_none())
    }

    /// Return whether the current record names `rid` with hash `hash`: the
    /// new build leaves the object unchanged.
    fn deployed(&self, rid: &ResourceId, hash: &str) -> bool {
        self.named(rid)
            .any(|n| n.role == Role::Current && n.hash == hash)
    }

    fn named(&self, rid: &ResourceId) -> impl Iterator<Item = &Named> {
        self.named.get(rid).into_iter().flatten()
    }

    /// Return `rid` with each hash a record gives it, once each, and the
    /// edges the records give it with that hash.
    fn named_objects(&self, rid: &ResourceId) -> Vec<RevisionObject> {
        let mut by_hash: BTreeMap<&str, Vec<Need>> = BTreeMap::new();
        for n in self.named(rid) {
            by_hash
                .entry(n.hash.as_str())
                .or_default()
                .extend(n.needs.iter().cloned());
        }
        by_hash
            .into_iter()
            .map(|(hash, needs)| RevisionObject::of_id(hash, rid).with_needs(needs))
            .collect()
    }

    /// Return the dependency edges that the revisions of this Kix cluster's
    /// records record. An object that only format 1 revisions name takes its
    /// edges from its manifest in `in_hand`
    /// ([`Edges::with_format_one_annotations`]).
    pub(crate) fn edges(&self, in_hand: &[Value]) -> Edges {
        Edges::of_own_revisions(&self.tenancy, in_hand)
    }

    /// Return the objects earlier deploys made, as `manifests` describe
    /// them, with the edges and the hashes this Kix cluster's revisions
    /// give them.
    pub(crate) fn prior(&self, manifests: Vec<Value>) -> Prior {
        let hashes = self
            .named
            .iter()
            .map(|(rid, named)| (rid.clone(), named.iter().map(|n| n.hash.clone()).collect()))
            .collect();
        Prior {
            edges: self.edges(&manifests),
            manifests,
            hashes,
        }
    }

    /// Return whether the live object `obj` is an orphan the deploy takes
    /// in: an `Active` current record or its kept orphans name it, or a
    /// record whose deploy may not have reached it names it and this Kix
    /// cluster wrote it. Such a record is a `Degraded` current record, or a
    /// `Failed` or `Partial` record. For the latter only an `Apply` entry
    /// under this Kix cluster's own manager counts, not the entry under
    /// `kix` that an older Kix shared between Kix clusters. An object with
    /// no entry of this cluster came from elsewhere, such as another Kix
    /// cluster that deploys an object of the same name.
    fn takes_in(&self, rid: &ResourceId, obj: &kube::api::DynamicObject) -> bool {
        let entries = obj.metadata.managed_fields.as_deref().unwrap_or_default();
        let view = self.view_of(obj);
        let written_here = || {
            entries
                .iter()
                .any(|e| view.counts_as_own(e.manager.as_deref()))
        };
        let applied_here = || self.manager.apply_entry(entries).is_some();
        self.named(rid).any(|n| match n.role {
            Role::Current if n.phase == PHASE_DEGRADED => written_here(),
            Role::Current | Role::Kept => true,
            Role::Stopped => applied_here(),
        })
    }
}

/// Return the build hash the live Activation record `obj` carries.
fn record_hash(obj: &kube::api::DynamicObject) -> Option<&str> {
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
        let (action, label) = match live.get(&id) {
            Live::Unread => {
                forbidden.extend(live.forbidden_resource(&id).map(str::to_string));
                continue;
            }
            Live::Present(obj) if obj.metadata.deletion_timestamp.is_none() => {
                if !lifecycle::is_record(manifest) && ledger.migrates(obj) {
                    out.migrations.push(id.clone());
                    if migration_write::renames(obj, &ledger.manager, &ledger.tenancy) {
                        out.renamed.push(id.clone());
                    }
                }
                match decide_present(manifest, &id, obj, ledger, forces) {
                    Some((label, action)) => {
                        if matches!(label, Label::DriftReported(_)) {
                            out.unrecorded.push(id.clone());
                        }
                        (action, label)
                    }
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
                if ledger.deployed(&id, &hash::object_hash(manifest)) {
                    out.lost.push(id.clone());
                }
                let deployed = match found {
                    Live::Present(obj) => Deployed::RerunHash(rerun_hash(obj)),
                    Live::Absent | Live::Unserved | Live::Unread => Deployed::Nothing,
                };
                let label = match ledger.left_by_degraded(&id) {
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
                if ledger.migrates(obj) {
                    out.orphan_migrations.push(rid.clone());
                }
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
    out.migrations.sort();
    out.renamed.sort();
    out.unrecorded.sort();
    out.orphan_migrations.sort();
    Ok(out)
}

/// Apply the rule to `manifest`, whose live object `obj` the cluster holds.
/// Return `None` when the object is unchanged.
fn decide_present(
    manifest: &Value,
    id: &ResourceId,
    obj: &kube::api::DynamicObject,
    ledger: &Ledger,
    forces: bool,
) -> Option<(Label, ChangeAction)> {
    let apply = |m: &Value| apply::changed(m, Deployed::RerunHash(rerun_hash(obj)), false);
    // No revision names the Activation record. Its name and its identity
    // hash say which build it records.
    if lifecycle::is_record(manifest) {
        return (record_hash(obj) != keys::get(manifest, keys::IDENTITY_HASH))
            .then(|| (Label::Intended, apply(manifest)));
    }
    let hash = hash::object_hash(manifest);
    let manager = ledger.view_of(obj);
    let live = fieldsv1::applied_content_hash(obj, &manager);
    let recorded = ledger.applied.entry(id, &hash);
    if recorded.is_some() && recorded == live.as_deref() {
        return None;
    }
    if let Some(by) = live.as_deref().and_then(|l| ledger.applied_by(id, l)) {
        return Some((Label::AppliedByRecord(by.to_string()), apply(manifest)));
    }
    if let Some(by) = ledger.left_by_degraded(id) {
        return Some((Label::LeftByDegraded(by.to_string()), apply(manifest)));
    }
    let unfinished = ledger.unfinished(id, live.as_deref()).map(str::to_string);
    let Some(applied) = recorded else {
        let label = if ledger.names_unapplied(id, &hash) {
            Label::AppliedHashMissing
        } else if let Some(record) = unfinished {
            Label::Unfinished {
                record,
                drift: None,
            }
        } else {
            Label::Intended
        };
        return Some((label, apply(manifest)));
    };
    // The live object matches what a deploy of this Kix cluster applied,
    // which is no drift.
    if live.as_deref().is_some_and(|l| ledger.applied.holds(id, l)) {
        return Some((Label::Intended, apply(manifest)));
    }
    // Kix recorded what it applied, so an object that now has no Kix field
    // records lost every field Kix owned.
    let report = drift::check_object(obj, Some(applied), &manager);
    // A field another manager took from Kix's own entry holds a value that
    // differs, so a runner that never forces sends the build without it.
    // Without an entry of its own Kix took nothing, so ownership says
    // nothing about values, and the apply goes on.
    let entries = obj.metadata.managed_fields.as_deref().unwrap_or_default();
    let own_entry = manager.apply_entry(entries).is_some();
    if !forces && own_entry && drift::conflicts(obj, manifest, &manager) {
        let sent = drift::without_taken(manifest, obj, &manager);
        return Some((Label::DriftReported(report), apply(&sent)));
    }
    if !drift::held_by_other_clusters(obj, manifest, &manager).is_empty() {
        return Some((Label::HeldByOtherCluster(report), apply(manifest)));
    }
    // A forced apply leaves out each ceded field another manager holds on
    // the object it reads right before it writes, so a field taken after
    // the plan is left too. A runner that never forces sends the manifest
    // without the fields held now.
    let sent = if forces {
        manifest.clone()
    } else {
        drift::without_ceded_taken(manifest, obj, &manager)
    };
    let label = match unfinished {
        Some(record) => Label::Unfinished {
            record,
            drift: Some(report),
        },
        None => Label::RevertsDrift(report),
    };
    Some((label, apply(&sent)))
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
