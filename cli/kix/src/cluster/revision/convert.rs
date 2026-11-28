//! Give the records an older Kix wrote the revisions this Kix reads.
//!
//! An older Kix recorded what a deploy did on the objects themselves: each
//! object lists the records that name it in its `kix.run/activations` note,
//! and the hash of what Kix applied in its `kix.run/applied-hash` note. A
//! record lists its objects in `status.packageIndex` and the builds whose
//! orphans its deploy kept in `status.orphansKeptFrom`.
//!
//! Before a run writes any object, under the deploy lock, Kix converts each
//! record a later run needs and that has no revision map: the current record
//! and each `Failed` or `Partial` record ([`targets`]). For each one it
//! creates revisions of what the record names, split by package instance,
//! with the applied hashes of the notes in their status, and for the
//! current record a kept-orphans revision. It then names them on the record
//! in one write. From that write on, every reader reads the record from its
//! revisions, and the notes on the objects only remain to be tidied away.
//!
//! A record whose map names format 1 revisions, which Kix built from `main`
//! wrote, is converted the same way: its revisions cannot change, because a
//! revision's name is a hash of its content, so it gets new revisions and a
//! new map.
//!
//! What a record names comes, in this order, from its format 1 revisions,
//! from its package index when the index names the objects, from the live
//! objects whose build hash the index lists, and from the live objects
//! whose note lists the record. What each object depends on comes from the
//! `kix.run/depends-on` note of its live object, and an instance's lifecycle
//! from the `kix.run/lifecycle` note of its live objects, because an older
//! Kix recorded them nowhere else.
//!
//! An older Kix's applied hash left out every `kix.run/*` annotation, and
//! this Kix's covers each one it sends, so no old value can be kept as it
//! is. The conversion carries an applied hash only for an object the
//! record's deploy wrote: its note lists the record and it carries the
//! build hash the record gives it. When such an object still matches the
//! old applied hash, the conversion stores this Kix's applied hash of the
//! live object. Otherwise it stores the old value, which no live object can
//! match, so a plan reports the drift. When the
//! new build makes the same build file for an object, the entry takes the
//! new build's object hash ([`BuildHashes`]), so a deploy that changes
//! nothing writes nothing to it.
//!
//! The conversion is safe to run twice and safe to stop between any two of
//! its writes. A revision's name is a hash of its content, so a second
//! create of it finds it there, and the applied hashes merge. A record that
//! already has a map is not converted again. Each record gets its map in
//! one write, after every revision it names exists. Nothing in the
//! conversion changes an object, so a conversion that stops leaves every
//! note in place for the next one, and the revisions no record names yet
//! are removed by the next cleanup or named by the next conversion.

use std::collections::{BTreeMap, HashMap};

use kube::Client;
use kube::api::DynamicObject;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;
use thiserror::Error;

use super::map::RevisionMap;
use super::spec::{
    MAX_BYTES, Need, Revision, RevisionObject, RevisionSet, RevisionSpec, Slot, TooLarge,
};
use super::store::{RevisionError, Revisions};
use crate::cluster::activation::{Record, Records, RecordsError};
use crate::cluster::field_manager::FieldManager;
use crate::cluster::fieldsv1;
use crate::eval::package_index::{IndexedName, RecordPackageIndex};
use crate::manifest::keys;
use crate::manifest::lifecycle::{self, PHASE_FAILED, PHASE_PARTIAL, PHASE_SUPERSEDED};
use crate::manifest::types::ResourceId;

/// One record the conversion gives a map.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Converted {
    pub record: String,
    pub map: RevisionMap,
    /// The revisions the map names, with the applied hashes of the notes.
    pub revisions: Vec<Revision>,
}

/// What a conversion writes ([`plan`]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Conversion {
    /// The records to convert. The current record comes last.
    records: Vec<Converted>,
}

impl Conversion {
    /// Return whether the conversion writes nothing.
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// Return the map the conversion gives record `name`, if it converts it.
    pub fn map_of(&self, name: &str) -> Option<&RevisionMap> {
        self.records
            .iter()
            .find(|c| c.record == name)
            .map(|c| &c.map)
    }

    /// Return every revision the conversion creates.
    pub fn revisions(&self) -> impl Iterator<Item = &Revision> {
        self.records.iter().flat_map(|c| c.revisions.iter())
    }

    /// Return the records the conversion converts, the current one last.
    pub fn records(&self) -> &[Converted] {
        &self.records
    }
}

/// Why [`plan`] refuses to convert the records of a Kix cluster.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum Refusal {
    /// A revision would pass the size the API server stores.
    #[error(transparent)]
    TooLarge(Box<TooLarge>),
    /// Kix needs the live objects to learn what a record names, and could
    /// not list some kinds.
    #[error(
        "[K9558] cannot convert deployment record `{record}` to PackageInstanceRevision resources because this Kubernetes account cannot `list` {kinds} across the cluster. Nothing was changed on the cluster. \
         Earlier versions of Kix wrote `{record}` without full object names, so this one-time upgrade must list all Kix-labeled objects across the cluster. \
         Next: grant this account cluster-wide `list` permission on {kinds} (or run this first deploy once with an account that has it), then run the command again. Later deploys do not need cluster-wide `list`",
        kinds = .kinds.join(", ")
    )]
    NotListed { record: String, kinds: Vec<String> },
}

/// Why a conversion could not be written.
#[derive(Debug, Error)]
pub enum ConvertError {
    #[error(transparent)]
    Refused(Box<Refusal>),
    #[error(transparent)]
    Revisions(#[from] RevisionError),
    #[error(transparent)]
    Records(#[from] RecordsError),
    #[error(
        "cannot list Kix-labeled objects on the cluster to convert earlier deployment records: {0}"
    )]
    Listing(String),
}

/// Return the record a run that takes the deploy lock treats as current:
/// the one the head names, unless it is gone, `Superseded`, or followed by a
/// record an older Kix wrote, else the newest record with a current phase.
/// Taking the lock writes the same choice into the head.
pub fn current_of<'a>(head_current: Option<&str>, own: &'a [Record]) -> Option<&'a Record> {
    let named = head_current
        .and_then(|c| own.iter().find(|r| r.name == c))
        .filter(|r| {
            r.phase != PHASE_SUPERSEDED
                && !crate::cluster::tenancy::older_kix_deployed_after(r, own)
        });
    named.or_else(|| crate::cluster::activation::current_among(own))
}

/// Return the records of a Kix cluster a run converts: `current`, and each
/// `Failed` or `Partial` record, when it has no revision map or its map
/// names a format 1 revision of `listed`. A record whose map this Kix cannot
/// read is not converted.
pub fn targets<'a>(
    current: Option<&'a Record>,
    own: &'a [Record],
    listed: &[Revision],
) -> Vec<&'a Record> {
    let converts = |r: &Record| match &r.revisions {
        None => true,
        Some(Ok(map)) => format_one_map(map, listed).is_some(),
        Some(Err(_)) => false,
    };
    let mut out: Vec<&Record> = own
        .iter()
        .filter(|r| matches!(r.phase.as_str(), PHASE_FAILED | PHASE_PARTIAL))
        .filter(|r| Some(r.name.as_str()) != current.map(|c| c.name.as_str()))
        .filter(|r| converts(r))
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out.extend(current.filter(|c| converts(c)));
    out
}

/// Return the revisions `map` names, from `listed`, when one of them is in
/// format 1. A revision `listed` does not hold is left out.
fn format_one_map<'a>(map: &RevisionMap, listed: &'a [Revision]) -> Option<Vec<&'a Revision>> {
    let named: Vec<&Revision> = map
        .names()
        .filter_map(|n| listed.iter().find(|r| r.name == n))
        .collect();
    named
        .iter()
        .any(|r| !r.spec.records_edges())
        .then_some(named)
}

/// The new build's hashes of each object, by name: the build hash an older
/// Kix stamped on the objects it applied (`kix.run/identity-hash`), and the
/// object hash this Kix records.
#[derive(Debug, Clone, Default)]
pub struct BuildHashes(HashMap<ResourceId, (String, String)>);

impl BuildHashes {
    /// Return the hashes of the objects the build whose manifests are
    /// `manifests` makes on the cluster ([`lifecycle::makes`]).
    pub fn of(manifests: &[Value]) -> BuildHashes {
        BuildHashes(
            manifests
                .iter()
                .filter(|m| lifecycle::makes(m) && !lifecycle::is_record(m))
                .filter_map(|m| {
                    let identity = keys::get(m, keys::IDENTITY_HASH)?;
                    Some((
                        ResourceId::from_value(m),
                        (identity.to_string(), crate::manifest::hash::object_hash(m)),
                    ))
                })
                .collect(),
        )
    }

    /// Return the object hash of `rid` in the new build when its build file
    /// for `rid` has the build hash `identity`.
    fn object_hash_for(&self, rid: &ResourceId, identity: &str) -> Option<&str> {
        let (built, object) = self.0.get(rid)?;
        (built == identity).then_some(object.as_str())
    }
}

/// The live objects a conversion reads, by object and by build hash.
struct Live<'a> {
    by_id: HashMap<ResourceId, &'a DynamicObject>,
    by_hash: HashMap<&'a str, Vec<&'a DynamicObject>>,
}

impl<'a> Live<'a> {
    fn of(objects: &'a [DynamicObject]) -> Self {
        let mut by_id = HashMap::new();
        let mut by_hash: HashMap<&str, Vec<&DynamicObject>> = HashMap::new();
        for obj in objects {
            if lifecycle::lifecycle_of_live(obj) == lifecycle::Lifecycle::Record {
                continue;
            }
            by_id.insert(crate::cluster::drift::resource_id(obj), obj);
            if let Some(hash) = build_hash(obj) {
                by_hash.entry(hash).or_default().push(obj);
            }
        }
        Live { by_id, by_hash }
    }

    /// Return the live objects whose `kix.run/activations` lists `hash`,
    /// with the build hash each carries.
    fn noting(&self, hash: &str) -> Vec<RevisionObject> {
        let mut out: Vec<RevisionObject> = self
            .by_id
            .iter()
            .filter(|(_, o)| notes(o).any(|h| h == hash))
            .filter_map(|(rid, o)| Some(RevisionObject::of_id(build_hash(o)?, rid)))
            .collect();
        out.sort();
        out
    }

    /// Return `object` with the edges the `kix.run/depends-on` note of its
    /// live object lists, each hash named by the live object that carries
    /// it. The note describes the build that wrote the object last, which
    /// may be a later one than `object` names. Those edges still order its
    /// delete better than none. An edge to an object that no longer carries
    /// the hash is lost.
    fn with_noted_needs(&self, object: RevisionObject) -> RevisionObject {
        let Some(obj) = self.by_id.get(&object.resource_id()) else {
            return object;
        };
        let manifest = crate::manifest::types::to_manifest_value(obj);
        let needs = Need::of_depends_on(&manifest, |hash| {
            let found = self.by_hash.get(hash)?.first()?;
            Some(crate::cluster::drift::resource_id(found))
        });
        object.with_needs(needs)
    }

    /// Return the lifecycle the `kix.run/lifecycle` note gives the first of
    /// `objects` whose live object carries one.
    fn lifecycle_of(&self, objects: &[RevisionObject]) -> Option<String> {
        objects.iter().find_map(|o| {
            let obj = self.by_id.get(&o.resource_id())?;
            keys::get_meta(obj.metadata.annotations.as_ref()?, keys::LIFECYCLE).map(str::to_string)
        })
    }
}

fn build_hash(obj: &DynamicObject) -> Option<&str> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
}

fn notes(obj: &DynamicObject) -> impl Iterator<Item = &str> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(keys::ACTIVATIONS))
        .map(String::as_str)
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|h| !h.is_empty())
}

/// Return the object `hash` names in `index`: from its name in the index,
/// else from the live object that carries the hash.
fn named(index: &RecordPackageIndex, hash: &str, live: &Live<'_>) -> Option<RevisionObject> {
    if let Some(IndexedName::Named(rid)) = index.name_of(hash) {
        return Some(RevisionObject::of_id(hash, &rid));
    }
    let found = live.by_hash.get(hash)?;
    let obj = found.first()?;
    Some(RevisionObject::of_id(
        hash,
        &crate::cluster::drift::resource_id(obj),
    ))
}

/// Return whether Kix needs the live objects to learn what `record` names:
/// it has no package index, or its index does not name every object it
/// lists with its group.
fn needs_listing(record: &Record) -> bool {
    let Some(index) = &record.package_index else {
        return true;
    };
    index
        .packages
        .values()
        .flat_map(|p| std::iter::once(&p.instance).chain(&p.resources))
        .chain(&index.cluster_level)
        .any(|h| !matches!(index.name_of(h), Some(IndexedName::Named(_))))
}

/// Return what `record` names, by instance key, with the objects no
/// instance lists under `None`. See the module docs for the sources.
fn named_by(record: &Record, live: &Live<'_>) -> BTreeMap<Option<String>, Vec<RevisionObject>> {
    let mut out: BTreeMap<Option<String>, Vec<RevisionObject>> = BTreeMap::new();
    if let Some(index) = &record.package_index {
        for (key, package) in &index.packages {
            let objects = std::iter::once(&package.instance)
                .chain(&package.resources)
                .filter_map(|h| named(index, h, live));
            out.entry(Some(key.clone())).or_default().extend(objects);
        }
        let cluster_level = index
            .cluster_level
            .iter()
            .filter_map(|h| named(index, h, live));
        out.entry(None).or_default().extend(cluster_level);
    }
    if let Some(hash) = &record.identity_hash {
        let known: std::collections::HashSet<ResourceId> = out
            .values()
            .flatten()
            .map(RevisionObject::resource_id)
            .collect();
        let noted = live
            .noting(hash)
            .into_iter()
            .filter(|o| !known.contains(&o.resource_id()));
        out.entry(None).or_default().extend(noted);
    }
    for objects in out.values_mut() {
        objects.retain(|o| {
            !lifecycle::is_record_kind(o.resource_id().group_kind()) && !o.is_kix_crd()
        });
        *objects = std::mem::take(objects)
            .into_iter()
            .map(|o| live.with_noted_needs(o))
            .collect();
    }
    out
}

/// Return the `kix.run/applied-hash` note of the live object of `object`
/// when the deploy of the record whose hash is `record` wrote it: the
/// object carries the build hash the revision gives it, and its
/// `kix.run/activations` note lists the record. Another Kix cluster that
/// builds the same file stamps the same build hash, so the build hash alone
/// does not say which Kix cluster wrote the object.
///
/// A revision holds an applied hash only for an object a deploy of its Kix
/// cluster wrote, and a plan reads it so ([`crate::plan::decide`]).
fn noted_applied(object: &RevisionObject, record: &str, live: &Live<'_>) -> Option<String> {
    let obj = live.by_id.get(&object.resource_id())?;
    let annotations = obj.metadata.annotations.as_ref()?;
    (keys::get_meta(annotations, keys::IDENTITY_HASH) == Some(object.hash.as_str())
        && notes(obj).any(|h| h == record))
    .then(|| keys::get_meta(annotations, keys::APPLIED_HASH))
    .flatten()
    .map(str::to_string)
}

/// Where a conversion reads the applied hash an older Kix recorded for an
/// object.
enum OldApplied<'a> {
    /// The `kix.run/applied-hash` notes on the live objects, for the record
    /// whose hash is `record`.
    Notes { live: &'a Live<'a>, record: &'a str },
    /// The `status.applied` of the record's format 1 revisions.
    Revisions(&'a [&'a Revision]),
}

impl OldApplied<'_> {
    fn of(&self, object: &RevisionObject) -> Option<String> {
        match self {
            OldApplied::Notes { live, record } => noted_applied(object, record, live),
            OldApplied::Revisions(revisions) => revisions
                .iter()
                .filter(|r| {
                    r.spec
                        .objects
                        .iter()
                        .any(|x| x.applied_key() == object.applied_key())
                })
                .find_map(|r| r.applied.get(&object.hash).cloned()),
        }
    }
}

/// How a conversion carries an older Kix's entries into revisions of this
/// Kix's format.
struct Carry<'a> {
    live: &'a Live<'a>,
    build: &'a BuildHashes,
    /// The field manager that judges the live objects as the migration
    /// write leaves them: the cluster's own, counting the entry under `kix`
    /// an older Kix applied under.
    manager: FieldManager,
}

impl Carry<'_> {
    /// Return the revision of `spec`'s slot for `objects`, each with the
    /// applied hash an older Kix recorded for it in `old`, carried as the
    /// module docs say.
    fn revision(
        &self,
        cluster: &str,
        slot: Slot,
        objects: Vec<RevisionObject>,
        old: impl Fn(&RevisionObject) -> Option<String>,
    ) -> Revision {
        let mut applied = BTreeMap::new();
        let objects: Vec<RevisionObject> = objects
            .into_iter()
            .map(|object| {
                let carried = old(&object).map(|a| self.applied(&object, a));
                let rid = object.resource_id();
                let object = match self.build.object_hash_for(&rid, &object.hash) {
                    Some(hash) => RevisionObject {
                        hash: hash.to_string(),
                        ..object
                    },
                    None => object,
                };
                if let Some(carried) = carried {
                    applied.insert(object.hash.clone(), carried);
                }
                object
            })
            .collect();
        let mut revision = Revision::new(RevisionSpec::new(cluster, slot, objects));
        revision.applied.extend(
            applied
                .into_iter()
                .filter(|(h, _)| revision.spec.objects.iter().any(|o| &o.hash == h)),
        );
        revision
    }

    /// Return the applied hash to store for `object`, whose older Kix's
    /// applied hash is `old`: this Kix's applied hash of the live object
    /// when the live object carries the build hash the revision gives it and
    /// still matches `old`, and `old` otherwise.
    fn applied(&self, object: &RevisionObject, old: String) -> String {
        let Some(obj) = self.live.by_id.get(&object.resource_id()) else {
            return old;
        };
        if build_hash(obj) != Some(object.hash.as_str())
            || fieldsv1::older_kix_applied_hash(obj, &self.manager).as_deref() != Some(old.as_str())
        {
            return old;
        }
        fieldsv1::applied_content_hash(obj, &self.manager).unwrap_or(old)
    }
}

/// Return what a run that takes the lock writes to give the records of Kix
/// cluster `cluster` revisions: `current` is the record [`current_of`]
/// returns, `own` the cluster's records, `listed` its revisions, `live`
/// every live object that carries Kix's label, `forbidden` the kinds the
/// listing could not read, and `build` the hashes of the build the run
/// deploys. Refuse when a revision would pass the size
/// the API server stores, and when a record needs the listing to say what
/// it names and the listing missed a kind. A conversion written from a
/// partial listing would forget those objects for good.
#[allow(clippy::too_many_arguments)]
pub fn plan(
    cluster: &str,
    current: Option<&Record>,
    own: &[Record],
    listed: &[Revision],
    live: &[DynamicObject],
    forbidden: &[String],
    build: &BuildHashes,
) -> Result<Conversion, Refusal> {
    let live = Live::of(live);
    let carry = Carry {
        live: &live,
        build,
        manager: FieldManager::unmigrated(cluster),
    };
    let mut out = Conversion::default();
    for record in targets(current, own, listed) {
        let is_current = current.is_some_and(|c| c.name == record.name);
        let format_one = match &record.revisions {
            Some(Ok(map)) => format_one_map(map, listed),
            _ => None,
        };
        let reads_kept_notes = is_current
            && record
                .orphans_kept_from
                .iter()
                .any(|source| kept_map(own, &source.identity_hash).is_none());
        if !forbidden.is_empty()
            && format_one.is_none()
            && (needs_listing(record) || reads_kept_notes)
        {
            let mut kinds = forbidden.to_vec();
            kinds.sort();
            kinds.dedup();
            return Err(Refusal::NotListed {
                record: record.name.clone(),
                kinds,
            });
        }
        let (groups, source) = match &format_one {
            Some(revisions) => (
                named_by_revisions(record, revisions, &live),
                OldApplied::Revisions(revisions),
            ),
            None => (
                named_by(record, &live),
                OldApplied::Notes {
                    live: &live,
                    record: record.identity_hash.as_deref().unwrap_or_default(),
                },
            ),
        };
        let old = |o: &RevisionObject| source.of(o);
        let instances: BTreeMap<String, Revision> = groups
            .iter()
            .filter_map(|(key, objects)| {
                let key = key.as_ref()?;
                let (namespace, name) = key.split_once('/').unwrap_or(("", key.as_str()));
                let slot = Slot::Instance {
                    namespace: namespace.to_string(),
                    name: name.to_string(),
                    lifecycle: live.lifecycle_of(objects),
                };
                Some((
                    key.clone(),
                    carry.revision(cluster, slot, objects.clone(), old),
                ))
            })
            .collect();
        let cluster_objects = groups.get(&None).cloned().unwrap_or_default();
        let set = RevisionSet {
            instances,
            cluster_level: carry.revision(cluster, Slot::ClusterLevel, cluster_objects, old),
        };
        if record.package_index.is_none() && set.cluster_level.stored_bytes() > MAX_BYTES {
            return Err(Refusal::TooLarge(Box::new(TooLarge {
                what: format!(
                    "deployment record {} (written without a package index by a version older than Kix 0.6)",
                    record.name
                ),
                objects: set.cluster_level.spec.objects.len(),
                bytes: set.cluster_level.stored_bytes(),
                next: "Without a package index, Kix cannot split the record's objects by package instance. \
                       Deploy an updated build of this cluster once with Kix 0.9 to write a package index, then upgrade Kix and deploy again.",
            })));
        }
        set.check_size()
            .map_err(|e| Refusal::TooLarge(Box::new(e)))?;
        let kept = is_current
            .then(|| kept_of(cluster, record, own, listed, &set, &carry))
            .flatten();
        if let Some(kept) = &kept
            && kept.stored_bytes() > MAX_BYTES
        {
            return Err(Refusal::TooLarge(Box::new(TooLarge {
                what: format!(
                    "the kept-orphans list for deployment record {}",
                    record.name
                ),
                objects: kept.spec.objects.len(),
                bytes: kept.stored_bytes(),
                next: "Run `kix gc` to delete orphaned objects from earlier deploys, then run the deploy again.",
            })));
        }
        let map = RevisionMap {
            kept_orphans: kept.as_ref().map(|k| k.name.clone()),
            ..RevisionMap::of(&set)
        };
        let revisions = set.all().cloned().chain(kept).collect();
        out.records.push(Converted {
            record: record.name.clone(),
            map,
            revisions,
        });
    }
    Ok(out)
}

/// Return the kept-orphans revision of `record`, the current record: the
/// objects of each build its `status.orphansKeptFrom` lists that `set`, the
/// record's own revisions, does not name. A build that is a record with a
/// readable map is read from its revisions, any other from the live
/// objects whose note names it.
fn kept_of(
    cluster: &str,
    record: &Record,
    own: &[Record],
    listed: &[Revision],
    set: &RevisionSet,
    carry: &Carry<'_>,
) -> Option<Revision> {
    let live = carry.live;
    let named: std::collections::HashSet<ResourceId> = set
        .all()
        .flat_map(|r| r.spec.objects.iter().map(RevisionObject::resource_id))
        .collect();
    let mut objects: Vec<RevisionObject> = Vec::new();
    // A record whose map names format 1 revisions keeps its own list.
    if let Some(Ok(map)) = &record.revisions
        && let Some(kept) = map.kept_orphans.as_ref()
        && let Some(revision) = listed.iter().find(|r| &r.name == kept)
    {
        objects.extend(
            revision
                .spec
                .objects
                .iter()
                .cloned()
                .map(|o| live.with_noted_needs(o)),
        );
    }
    for source in &record.orphans_kept_from {
        match kept_map(own, &source.identity_hash) {
            Some(map) => {
                let revisions = map
                    .instances
                    .values()
                    .chain(std::iter::once(&map.cluster_level));
                for name in revisions {
                    if let Some(revision) = listed.iter().find(|r| &r.name == name) {
                        objects.extend(revision.spec.objects.iter().cloned());
                    }
                }
            }
            // An older Kix found a kept orphan by the note on the live
            // object, so only an object whose note names the kept build is
            // one. An object of the same name made since by something else
            // carries no such note.
            None => objects.extend(
                live.noting(&source.identity_hash)
                    .into_iter()
                    .map(|o| live.with_noted_needs(o)),
            ),
        }
    }
    objects.retain(|o| !named.contains(&o.resource_id()));
    (!objects.is_empty()).then(|| carry.revision(cluster, Slot::KeptOrphans, objects, |_| None))
}

/// Return what a record whose map names the format 1 `revisions` names, by
/// instance key, with the cluster level under `None`. Its kept orphans are
/// read apart ([`kept_of`]). Each object takes its edges from the note on
/// its live object, because a format 1 revision does not record them.
fn named_by_revisions(
    record: &Record,
    revisions: &[&Revision],
    live: &Live<'_>,
) -> BTreeMap<Option<String>, Vec<RevisionObject>> {
    let mut out: BTreeMap<Option<String>, Vec<RevisionObject>> = BTreeMap::new();
    let Some(Ok(map)) = &record.revisions else {
        return out;
    };
    let find = |name: &str| revisions.iter().find(|r| r.name == name);
    let objects = |r: &Revision| {
        r.spec
            .objects
            .iter()
            .cloned()
            .map(|o| live.with_noted_needs(o))
            .collect::<Vec<_>>()
    };
    for (key, name) in &map.instances {
        if let Some(revision) = find(name) {
            out.insert(Some(key.clone()), objects(revision));
        }
    }
    if let Some(revision) = find(&map.cluster_level) {
        out.insert(None, objects(revision));
    }
    out
}

/// Return the readable revision map of the record of `own` whose build is
/// `identity_hash`.
fn kept_map<'a>(own: &'a [Record], identity_hash: &str) -> Option<&'a RevisionMap> {
    own.iter()
        .find(|r| r.identity_hash.as_deref() == Some(identity_hash))
        .and_then(|r| r.revisions.as_ref()?.as_ref().ok())
}

/// Write `conversion`: create every revision and write its applied hashes,
/// then name the revisions on each record, one write each, the current
/// record last. Hold the deploy lock while calling this.
pub async fn write(
    client: &Client,
    records: &Records,
    conversion: &Conversion,
) -> Result<(), ConvertError> {
    let store = Revisions::new(client);
    for revision in conversion.revisions() {
        store.create(revision).await?;
        if !revision.applied.is_empty() {
            store
                .write_applied(&revision.name, &revision.applied)
                .await?;
        }
    }
    for converted in &conversion.records {
        records
            .name_revisions(&converted.record, &converted.map)
            .await?;
    }
    Ok(())
}

/// Read what the conversion of Kix cluster `cluster` needs and write it,
/// for a run that deploys the build whose hashes are `build`. Return whether
/// it converted a record. List the live objects, with one request per kind
/// of `discovery`, only when a record needs converting.
pub async fn run(
    client: &Client,
    records: &Records,
    discovery: &[(ApiResource, Scope)],
    cluster: &str,
    build: &BuildHashes,
) -> Result<bool, ConvertError> {
    let own: Vec<Record> = records.of_cluster(cluster).await?;
    let head = crate::cluster::head::read(client, cluster)
        .await
        .ok()
        .flatten();
    let head_current = head
        .as_ref()
        .and_then(|h| h.status.as_ref())
        .and_then(|s| s.current.clone());
    let current = current_of(head_current.as_deref(), &own);
    let listed = store_listed(client, cluster).await?;
    if targets(current, &own, &listed).is_empty() {
        return Ok(false);
    }
    let live = crate::cluster::inventory::list_managed(client, discovery)
        .await
        .map_err(|e| ConvertError::Listing(e.to_string()))?;
    let conversion = plan(
        cluster,
        current,
        &own,
        &listed,
        &live.managed,
        &live.forbidden,
        build,
    )
    .map_err(|e| ConvertError::Refused(Box::new(e)))?;
    write(client, records, &conversion).await?;
    Ok(!conversion.is_empty())
}

async fn store_listed(client: &Client, cluster: &str) -> Result<Vec<Revision>, RevisionError> {
    Ok(Revisions::new(client).list(cluster).await?.readable)
}

#[cfg(test)]
#[path = "convert_tests.rs"]
mod tests;
