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
//! What a record names comes, in this order, from its package index when
//! the index names the objects, from the live objects whose build hash the
//! index lists, and from the live objects whose note lists the record.
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
use thiserror::Error;

use super::map::RevisionMap;
use super::spec::{MAX_BYTES, Revision, RevisionObject, RevisionSet, RevisionSpec, Slot, TooLarge};
use super::store::{RevisionError, Revisions};
use crate::cluster::activation::{Record, Records, RecordsError};
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
/// `Failed` or `Partial` record, when it has no revision map. A record whose
/// map this Kix cannot read is not converted.
pub fn targets<'a>(current: Option<&'a Record>, own: &'a [Record]) -> Vec<&'a Record> {
    let mut out: Vec<&Record> = own
        .iter()
        .filter(|r| matches!(r.phase.as_str(), PHASE_FAILED | PHASE_PARTIAL))
        .filter(|r| Some(r.name.as_str()) != current.map(|c| c.name.as_str()))
        .filter(|r| r.revisions.is_none())
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out.extend(current.filter(|c| c.revisions.is_none()));
    out
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
        objects.retain(|o| o.kind != lifecycle::RECORD_KIND);
    }
    out
}

/// Return the applied hash of each object of `objects` whose live object
/// carries the build hash the revision gives it and an applied-hash note.
fn applied_of(objects: &[RevisionObject], live: &Live<'_>) -> BTreeMap<String, String> {
    objects
        .iter()
        .filter_map(|o| {
            let obj = live.by_id.get(&o.resource_id())?;
            let annotations = obj.metadata.annotations.as_ref()?;
            (keys::get_meta(annotations, keys::IDENTITY_HASH) == Some(o.hash.as_str()))
                .then(|| keys::get_meta(annotations, keys::APPLIED_HASH))
                .flatten()
                .map(|applied| (o.hash.clone(), applied.to_string()))
        })
        .collect()
}

fn with_applied(spec: RevisionSpec, live: &Live<'_>) -> Revision {
    let mut revision = Revision::new(spec);
    revision.applied = applied_of(&revision.spec.objects, live);
    revision
}

/// Return what a run that takes the lock writes to give the records of Kix
/// cluster `cluster` revisions: `current` is the record [`current_of`]
/// returns, `own` the cluster's records, `listed` its revisions, `live`
/// every live object that carries Kix's label, and `forbidden` the kinds
/// the listing could not read. Refuse when a revision would pass the size
/// the API server stores, and when a record needs the listing to say what
/// it names and the listing missed a kind. A conversion written from a
/// partial listing would forget those objects for good.
pub fn plan(
    cluster: &str,
    current: Option<&Record>,
    own: &[Record],
    listed: &[Revision],
    live: &[DynamicObject],
    forbidden: &[String],
) -> Result<Conversion, Refusal> {
    let live = Live::of(live);
    let mut out = Conversion::default();
    for record in targets(current, own) {
        let is_current = current.is_some_and(|c| c.name == record.name);
        let reads_kept_notes = is_current
            && record
                .orphans_kept_from
                .iter()
                .any(|source| kept_map(own, &source.identity_hash).is_none());
        if !forbidden.is_empty() && (needs_listing(record) || reads_kept_notes) {
            let mut kinds = forbidden.to_vec();
            kinds.sort();
            kinds.dedup();
            return Err(Refusal::NotListed {
                record: record.name.clone(),
                kinds,
            });
        }
        let groups = named_by(record, &live);
        let instances: BTreeMap<String, Revision> = groups
            .iter()
            .filter_map(|(key, objects)| {
                let key = key.as_ref()?;
                let (namespace, name) = key.split_once('/').unwrap_or(("", key.as_str()));
                let slot = Slot::Instance {
                    namespace: namespace.to_string(),
                    name: name.to_string(),
                };
                let spec = RevisionSpec::new(cluster, slot, objects.clone());
                Some((key.clone(), with_applied(spec, &live)))
            })
            .collect();
        let cluster_objects = groups.get(&None).cloned().unwrap_or_default();
        let set = RevisionSet {
            instances,
            cluster_level: with_applied(
                RevisionSpec::new(cluster, Slot::ClusterLevel, cluster_objects),
                &live,
            ),
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
            .then(|| kept_of(cluster, record, own, listed, &set, &live))
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
    live: &Live<'_>,
) -> Option<Revision> {
    let named: std::collections::HashSet<ResourceId> = set
        .all()
        .flat_map(|r| r.spec.objects.iter().map(RevisionObject::resource_id))
        .collect();
    let mut objects: Vec<RevisionObject> = Vec::new();
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
            None => objects.extend(live.noting(&source.identity_hash)),
        }
    }
    objects.retain(|o| !named.contains(&o.resource_id()));
    (!objects.is_empty())
        .then(|| Revision::new(RevisionSpec::new(cluster, Slot::KeptOrphans, objects)))
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

/// Read what the conversion of Kix cluster `cluster` needs and write it.
/// Return whether it converted a record. List the live objects, with one
/// request per kind of `discovery`, only when a record needs converting.
pub async fn run(
    client: &Client,
    records: &Records,
    discovery: &[(ApiResource, Scope)],
    cluster: &str,
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
    if targets(current, &own).is_empty() {
        return Ok(false);
    }
    let listed = store_listed(client, cluster).await?;
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
