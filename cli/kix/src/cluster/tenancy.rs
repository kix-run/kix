//! Which Kix cluster, and which of its records, deploys a live object.
//!
//! [`Tenancy`] answers for every Kix cluster on a Kubernetes cluster, each
//! from its own source:
//!
//! - **Revisions.** A Kix cluster whose current record, as its head names
//!   it, has a readable `status.revisions` map is read from its revisions. An
//!   object belongs to a record when one of the record's revisions names its
//!   group, kind, namespace, and name. It belongs to the Kix cluster when a
//!   revision named by the current record, the record a lock holder is
//!   deploying, a queued, `Failed`, or `Partial` record, or the kept-orphans
//!   revision names it.
//! - **Records.** Any other Kix cluster is one an older Kix deployed last,
//!   and is read the way that Kix wrote it: every object a deploy touches
//!   names the deploying record's identity hash in `kix.run/activations`, a
//!   record also owns the builds it lists under `status.orphansKeptFrom`,
//!   and the package index lists a record's objects. The current record by
//!   the head must not be `Superseded`, and no record an older Kix wrote may
//!   be current by phase after it ([`older_kix_deployed_after`]), or the
//!   Kix cluster is read from records too.
//!
//! Records are read through [`Records`](super::activation::Records) after the
//! domain gate runs. Without that gate, a cluster whose records sit under a
//! retired group would appear to have no records, every object would look
//! unattributed, and a view of one Kix cluster would include all of them.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use kube::api::DynamicObject;

use super::activation::{KeptOrphanSource, OpenedRecords, Record, RecordsError};
use super::drift;
use super::field_manager::{self, FieldManager};
use super::head::{self, HeadStatus};
use super::revision::{self, Listed, Revision, RevisionError, RevisionObject, Revisions};
use crate::eval::package_index::RecordPackageIndex;
use crate::manifest::keys;
use crate::manifest::lifecycle::{
    Lifecycle, PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_QUEUED, PHASE_SUPERSEDED,
    lifecycle_of_live,
};
use crate::manifest::types::ResourceId;

/// Where [`Tenancy`] reads a Kix cluster's objects from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `kix.run/activations`, `status.orphansKeptFrom`, and the package
    /// index, which earlier releases wrote.
    Records,
    /// The revisions its records name.
    Revisions,
}

/// Why [`Tenancy`] could not read part of what decides which objects a Kix
/// cluster deploys.
///
/// A command that deletes objects refuses on any of these. A command that
/// only reads reports them and continues with what it read.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Problem {
    #[error(
        "deployment record `{record}` of Kix cluster {cluster} names {} `{revision}`, which is not on the cluster. {}",
        revision::KIND,
        remedy(*kept)
    )]
    MissingRevision {
        cluster: String,
        record: String,
        revision: String,
        /// The record names it as its kept-orphans revision.
        kept: bool,
    },
    #[error(
        "deployment record `{record}` of Kix cluster {cluster} names {} `{revision}`, which Kix cannot read: {reason}. {}",
        revision::KIND,
        remedy(*kept)
    )]
    UnreadableRevision {
        cluster: String,
        record: String,
        revision: String,
        reason: String,
        kept: bool,
    },
    #[error(
        "deployment record `{record}` of Kix cluster {cluster} cannot be read by this version of Kix: {source}. A later version of Kix probably wrote it, so this version cannot tell which objects the record deploys"
    )]
    UnreadableMap {
        cluster: String,
        record: String,
        source: revision::UnreadableMap,
    },
    #[error(
        "cannot list the {} objects: {reason}. Kix reads which objects each Kix cluster deploys the way earlier versions wrote it. Check that this account has `list` permission on `{}`",
        head::KIND,
        head::crd_name()
    )]
    Heads { reason: String },
    #[error(
        "cannot list the {} objects: {reason}. Check that this account has `list` permission on `{}`",
        revision::KIND,
        revision::crd_name()
    )]
    Revisions { reason: String },
}

fn remedy(kept: bool) -> &'static str {
    if kept {
        "It lists the objects earlier deploys left on the cluster, so Kix cannot tell which of them are still the Kix cluster's to delete"
    } else {
        "A deploy of that record's build writes it again"
    }
}

impl Problem {
    /// Return the Kix cluster the problem is about, or `None` when it is
    /// about every Kix cluster.
    pub fn cluster(&self) -> Option<&str> {
        match self {
            Problem::MissingRevision { cluster, .. }
            | Problem::UnreadableRevision { cluster, .. }
            | Problem::UnreadableMap { cluster, .. } => Some(cluster),
            Problem::Heads { .. } | Problem::Revisions { .. } => None,
        }
    }

    fn record(&self) -> Option<&str> {
        match self {
            Problem::MissingRevision { record, .. }
            | Problem::UnreadableRevision { record, .. }
            | Problem::UnreadableMap { record, .. } => Some(record),
            Problem::Heads { .. } | Problem::Revisions { .. } => None,
        }
    }

    fn kept(&self) -> bool {
        matches!(
            self,
            Problem::MissingRevision { kept: true, .. }
                | Problem::UnreadableRevision { kept: true, .. }
        )
    }
}

/// One revision that names an object, and the record that names it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Claim {
    cluster: String,
    record: String,
    record_hash: Option<String>,
    revision: String,
    /// The build hash the revision gives the object.
    hash: String,
    /// The record names the revision as its kept-orphans revision.
    kept: bool,
    /// The record is queued, deploying, failed, or partly deployed.
    pending: bool,
}

/// The objects of the Kix clusters read from revisions.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Claims {
    by_object: HashMap<ResourceId, Vec<Claim>>,
    /// Every revision a needed record names that was read, by name.
    revisions: HashMap<String, Revision>,
}

/// The objects of the Kix clusters read from records.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct Legacy {
    /// Identity hashes of this cluster's records, across every phase, and of
    /// the builds they list under `status.orphansKeptFrom`.
    own: HashSet<String>,
    /// Map from identity hash to owning cluster for every other record and
    /// the builds it lists under `status.orphansKeptFrom`. A record without a
    /// `kix.run/cluster` label is listed under `?`.
    others: HashMap<String, String>,
    /// Hashes in `others` whose record is not Superseded (builds another
    /// cluster runs, is deploying, or left partially applied).
    others_current: HashSet<String>,
    /// Map from identity hash to record name for each record of this
    /// cluster whose deploy has neither become current nor been superseded:
    /// one that is queued, deploying, failed, or partly deployed.
    own_pending: HashMap<String, String>,
}

/// Which Kix clusters on a Kubernetes cluster deploy which objects, read for
/// one Kix cluster. Build it with [`read`] after listing the objects it
/// judges.
#[derive(Debug, Clone, PartialEq)]
pub struct Tenancy {
    /// The Kix cluster this tenancy is read for.
    pub(crate) cluster: String,
    /// The field manager of `cluster`.
    manager: FieldManager,
    /// The Kix clusters read from revisions. Every other one is read from
    /// records.
    revision_clusters: BTreeSet<String>,
    legacy: Legacy,
    claims: Claims,
    /// The Kix cluster of each record, by record name.
    record_cluster: HashMap<String, String>,
    /// Identity hashes whose records a later read cannot show to deploy more
    /// objects than this read did ([`Tenancy::knows`]).
    settled: HashSet<String>,
    /// Whether this cluster has any record.
    own_records: bool,
    /// Every other Kix cluster with a record. A record without a
    /// `kix.run/cluster` label is listed under `?`.
    other_clusters: BTreeSet<String>,
    /// Every record of this Kix cluster, in any phase.
    own: Vec<Record>,
    /// The record this Kix cluster's head names as current.
    own_current: Option<String>,
    problems: Vec<Problem>,
    /// What the read found, kept so a plan can read the same state with the
    /// conversion a deploy would write ([`Tenancy::with_conversion`]).
    raw: Raw,
}

/// The heads, records, and revisions one read found.
#[derive(Debug, Clone, PartialEq)]
struct Raw {
    heads: BTreeMap<String, HeadStatus>,
    records: Vec<DynamicObject>,
    revisions: Result<Option<Listed>, String>,
    /// The problem listing the heads gave, if any.
    heads_problem: Option<Problem>,
}

/// The objects earlier deploys left on the cluster, as a record lists them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kept<'a> {
    /// The record's `status.orphansKeptFrom`: whole builds, read from the
    /// local store or the live objects.
    Builds(&'a [KeptOrphanSource]),
    /// The objects its kept-orphans revision names. Empty when it names
    /// none, or when the revision could not be read ([`Tenancy::problems`]
    /// says so).
    Objects(Vec<&'a RevisionObject>),
}

/// Return whether an older Kix deployed a Kix cluster after the record
/// `current` its head names, given `own`, the cluster's records: another
/// record is current by phase, has no revision map, and `current` still has
/// a current phase. A
/// deploy by this Kix always writes a map, so only an older Kix wrote that
/// record. A deploy by this Kix that stopped between making its record
/// current on the head and setting the phases leaves its record without a
/// current phase, so it does not count.
pub(crate) fn older_kix_deployed_after(current: &Record, own: &[Record]) -> bool {
    super::activation::current_among(own).is_some_and(|by_phase| {
        by_phase.name != current.name
            && by_phase.revisions.is_none()
            && super::activation::phase_is_current(&current.phase)
    })
}

/// Return whether a reader needs `record`, of a Kix cluster whose head reads
/// `head`: it is the current record, the record the lock holder deploys, or
/// any record that is not `Superseded`.
fn needed(head: Option<&HeadStatus>, record: &Record) -> bool {
    let current = head.and_then(|s| s.current.as_deref());
    let deploying = head
        .and_then(|s| s.lock.as_ref())
        .and_then(|l| l.activation.as_deref());
    record.phase != PHASE_SUPERSEDED
        || Some(record.name.as_str()) == current
        || Some(record.name.as_str()) == deploying
}

fn is_pending(phase: &str) -> bool {
    !matches!(phase, PHASE_SUPERSEDED | PHASE_ACTIVE | PHASE_DEGRADED)
}

fn cluster_label(record: &DynamicObject) -> Option<&str> {
    record
        .metadata
        .labels
        .as_ref()
        .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
}

impl Tenancy {
    /// Return an empty tenancy for `cluster`.
    pub(crate) fn empty(cluster: &str) -> Self {
        Tenancy {
            cluster: cluster.to_string(),
            manager: FieldManager::of(cluster),
            revision_clusters: BTreeSet::new(),
            legacy: Legacy::default(),
            claims: Claims::default(),
            record_cluster: HashMap::new(),
            settled: HashSet::new(),
            own_records: false,
            other_clusters: BTreeSet::new(),
            own: Vec::new(),
            own_current: None,
            problems: Vec::new(),
            raw: Raw {
                heads: BTreeMap::new(),
                records: Vec::new(),
                revisions: Ok(None),
                heads_problem: None,
            },
        }
    }

    /// Build a [`Tenancy`] that reads every Kix cluster from `records`, for
    /// tests. Outside tests, a tenancy is read through [`read`] past the
    /// domain gate.
    #[cfg(any(test, feature = "test-util"))]
    pub fn fixture(records: &[DynamicObject], cluster: &str) -> Self {
        Self::from_records(records, cluster)
    }

    /// Build a [`Tenancy`] from heads, records, and revisions, for tests.
    #[cfg(any(test, feature = "test-util"))]
    pub fn fixture_of_state(
        cluster: &str,
        heads: &BTreeMap<String, HeadStatus>,
        records: &[DynamicObject],
        revisions: &[Revision],
    ) -> Self {
        let listed = Listed {
            readable: revisions.to_vec(),
            unreadable: Vec::new(),
        };
        Self::from_state(cluster, heads, records, Ok(Some(&listed)))
    }

    /// Read every Kix cluster from `records` the way earlier releases wrote
    /// them. An empty `cluster` owns no records, so every record is treated
    /// as belonging to another cluster.
    #[cfg(any(test, feature = "test-util"))]
    pub(crate) fn from_records(records: &[DynamicObject], cluster: &str) -> Self {
        Self::from_state(cluster, &BTreeMap::new(), records, Ok(None))
    }

    /// Build a tenancy for `cluster` from the heads, records, and revisions
    /// one read found. `revisions` is `Ok(None)` when they were not listed,
    /// because no current record has a readable map, and `Err` with the
    /// reason when the list failed. A Kix cluster whose source would be
    /// revisions is then read from records.
    pub(crate) fn from_state(
        cluster: &str,
        heads: &BTreeMap<String, HeadStatus>,
        records: &[DynamicObject],
        revisions: Result<Option<&Listed>, String>,
    ) -> Self {
        let mut tenancy = Tenancy::empty(cluster);
        tenancy.raw = Raw {
            heads: heads.clone(),
            records: records.to_vec(),
            revisions: revisions.clone().map(|l| l.cloned()),
            heads_problem: None,
        };
        tenancy.own_current = heads.get(cluster).and_then(|h| h.current.clone());
        let parsed: Vec<(Option<&str>, Record)> = records
            .iter()
            .map(|r| (cluster_label(r), Record::of(r)))
            .collect();
        for (owner, record) in &parsed {
            let owner = owner.unwrap_or("?");
            tenancy
                .record_cluster
                .insert(record.name.clone(), owner.to_string());
            if !cluster.is_empty() && owner == cluster {
                tenancy.own_records = true;
                tenancy.own.push(record.clone());
            } else {
                tenancy.other_clusters.insert(owner.to_string());
            }
        }
        for (name, status) in heads {
            if tenancy.reads_revisions_by(name, status, &parsed) {
                tenancy.revision_clusters.insert(name.clone());
            }
        }
        tenancy.note_unreadable_maps(heads, &parsed);
        match revisions {
            Ok(Some(listed)) => tenancy.claim(heads, &parsed, listed),
            Ok(None) => {}
            Err(reason) => tenancy.problems.push(Problem::Revisions { reason }),
        }
        tenancy.read_legacy(records, &parsed);
        tenancy
    }

    /// Return this tenancy as it reads once `conversion` is written: each
    /// record it converts names its revisions, and the read holds them.
    pub(crate) fn with_conversion(&self, conversion: &revision::Conversion) -> Tenancy {
        if conversion.is_empty() {
            return self.clone();
        }
        let mut records = self.raw.records.clone();
        for record in &mut records {
            let name = record.metadata.name.as_deref().unwrap_or_default();
            if let Some(map) = conversion.map_of(name) {
                record.data["status"]["revisions"] = map.to_value();
            }
        }
        let mut listed = match &self.raw.revisions {
            Ok(Some(listed)) => listed.clone(),
            Ok(None) | Err(_) => Listed {
                readable: Vec::new(),
                unreadable: Vec::new(),
            },
        };
        for revision in conversion.revisions() {
            listed.readable.retain(|r| r.name != revision.name);
            listed.readable.push(revision.clone());
        }
        let revisions = match &self.raw.revisions {
            Err(reason) => Err(reason.clone()),
            Ok(_) => Ok(Some(&listed)),
        };
        let mut tenancy = Tenancy::from_state(&self.cluster, &self.raw.heads, &records, revisions);
        tenancy.problems.extend(self.raw.heads_problem.clone());
        tenancy.raw.heads_problem = self.raw.heads_problem.clone();
        tenancy
    }

    /// Return the revisions of this Kix cluster the read listed, readable
    /// ones only, whatever record names them.
    pub(crate) fn own_listed_revisions(&self) -> Vec<Revision> {
        match &self.raw.revisions {
            Ok(Some(listed)) => listed
                .readable
                .iter()
                .filter(|r| r.spec.cluster == self.cluster)
                .cloned()
                .collect(),
            Ok(None) | Err(_) => Vec::new(),
        }
    }

    /// Return whether Kix cluster `name` reads from revisions: its head names
    /// a current record whose map is readable, that is not `Superseded`,
    /// and that no record an older Kix wrote follows. This says only which
    /// record a reader shows as current. What each record names is read
    /// from its own source.
    fn reads_revisions_by(
        &self,
        name: &str,
        status: &HeadStatus,
        records: &[(Option<&str>, Record)],
    ) -> bool {
        let Some(current) = self.current_of(name, status, records) else {
            return false;
        };
        let own: Vec<Record> = records
            .iter()
            .filter(|(owner, _)| *owner == Some(name))
            .map(|(_, r)| r.clone())
            .collect();
        current.phase != PHASE_SUPERSEDED
            && !older_kix_deployed_after(current, &own)
            && matches!(current.revisions, Some(Ok(_)))
    }

    /// Note each record whose map this Kix cannot read and that a reader
    /// needs: the current record of its Kix cluster, the record its lock
    /// holder deploys, and every record that is not `Superseded`.
    fn note_unreadable_maps(
        &mut self,
        heads: &BTreeMap<String, HeadStatus>,
        records: &[(Option<&str>, Record)],
    ) {
        for (owner, record) in records {
            let Some(Err(source)) = &record.revisions else {
                continue;
            };
            let cluster = owner.unwrap_or("?");
            if !needed(heads.get(cluster), record) {
                continue;
            }
            self.problems.push(Problem::UnreadableMap {
                cluster: cluster.to_string(),
                record: record.name.clone(),
                source: source.clone(),
            });
        }
    }

    fn current_of<'a>(
        &self,
        name: &str,
        status: &HeadStatus,
        records: &'a [(Option<&str>, Record)],
    ) -> Option<&'a Record> {
        let current = status.current.as_deref()?;
        records
            .iter()
            .find(|(owner, r)| *owner == Some(name) && r.name == current)
            .map(|(_, r)| r)
    }

    /// Index the objects that the revisions of each needed record with a
    /// readable map name, of every Kix cluster: the current record, the
    /// record the lock holder deploys, and each record that is not
    /// `Superseded`.
    fn claim(
        &mut self,
        heads: &BTreeMap<String, HeadStatus>,
        records: &[(Option<&str>, Record)],
        listed: &Listed,
    ) {
        let readable: HashMap<&str, &Revision> = listed
            .readable
            .iter()
            .map(|r| (r.name.as_str(), r))
            .collect();
        let unreadable: HashMap<&str, &revision::ReadError> =
            listed.unreadable.iter().map(|e| (e.name(), e)).collect();
        for (owner, record) in records {
            let cluster = owner.unwrap_or("?");
            let map = match &record.revisions {
                Some(Ok(map)) if needed(heads.get(cluster), record) => map,
                _ => continue,
            };
            let named = map
                .instances
                .values()
                .chain(std::iter::once(&map.cluster_level))
                .map(|n| (n, false))
                .chain(map.kept_orphans.iter().map(|n| (n, true)));
            for (name, kept) in named {
                let problem = |reason: Option<String>| match reason {
                    Some(reason) => Problem::UnreadableRevision {
                        cluster: cluster.to_string(),
                        record: record.name.clone(),
                        revision: name.clone(),
                        reason,
                        kept,
                    },
                    None => Problem::MissingRevision {
                        cluster: cluster.to_string(),
                        record: record.name.clone(),
                        revision: name.clone(),
                        kept,
                    },
                };
                let Some(revision) = readable.get(name.as_str()) else {
                    let reason = unreadable.get(name.as_str()).map(|e| e.to_string());
                    self.problems.push(problem(reason));
                    continue;
                };
                for object in &revision.spec.objects {
                    self.claims
                        .by_object
                        .entry(object.resource_id())
                        .or_default()
                        .push(Claim {
                            cluster: cluster.to_string(),
                            record: record.name.clone(),
                            record_hash: record.identity_hash.clone(),
                            revision: name.clone(),
                            hash: object.hash.clone(),
                            kept,
                            pending: is_pending(&record.phase),
                        });
                }
                self.claims
                    .revisions
                    .entry(name.clone())
                    .or_insert_with(|| (*revision).clone());
            }
            if let Some(hash) = &record.identity_hash {
                self.settled.insert(hash.clone());
            }
        }
    }

    /// Read each record without a map from what an older Kix wrote: the
    /// objects whose `kix.run/activations` names it, and the builds it lists
    /// under `status.orphansKeptFrom`. Note which identity hashes are
    /// settled.
    fn read_legacy(&mut self, objects: &[DynamicObject], records: &[(Option<&str>, Record)]) {
        let cluster = self.cluster.clone();
        for ((owner, parsed), record) in records.iter().zip(objects) {
            let Some(hash) = record
                .metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
            else {
                continue;
            };
            let kept = parsed
                .orphans_kept_from
                .iter()
                .map(|source| source.identity_hash.as_str());
            if parsed.revisions.is_some() {
                // A record with a map is read from its revisions. One that
                // is Superseded, or whose map this read indexed, cannot come
                // to name more objects than it does. One whose map could not
                // be read is left unsettled.
                if parsed.phase == PHASE_SUPERSEDED {
                    self.settled.insert(hash.to_string());
                }
                self.settled.extend(kept.map(str::to_string));
                continue;
            }
            // A record still queued or deploying may gain a map when this
            // Kix deploys it, and name objects that carry no note.
            if !matches!(parsed.phase.as_str(), "" | PHASE_QUEUED | PHASE_DEPLOYING) {
                self.settled.insert(hash.to_string());
            }
            self.settled.extend(kept.clone().map(str::to_string));
            let legacy = &mut self.legacy;
            if !cluster.is_empty() && *owner == Some(cluster.as_str()) {
                legacy.own.insert(hash.to_string());
                legacy.own.extend(kept.map(str::to_string));
                if is_pending(&parsed.phase) {
                    legacy
                        .own_pending
                        .insert(hash.to_string(), parsed.name.clone());
                }
                continue;
            }
            if parsed.phase != PHASE_SUPERSEDED {
                legacy.others_current.insert(hash.to_string());
            }
            let owner = owner.unwrap_or("?").to_string();
            for kept in kept {
                legacy
                    .others
                    .entry(kept.to_string())
                    .or_insert_with(|| owner.clone());
            }
            legacy.others.insert(hash.to_string(), owner);
        }
    }

    /// Reject a tenancy whose cluster has no records when other clusters do,
    /// because the cluster name is likely a typo and its view would be empty.
    pub fn require_records(&self) -> Result<(), String> {
        if self.own_records || self.other_clusters.is_empty() {
            return Ok(());
        }
        let cluster = &self.cluster;
        let known = self
            .other_clusters
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join(", ");
        Err(format!(
            "no deployment records for '{cluster}' on this Kubernetes cluster\n  \
             Nothing was changed on the cluster.\n\n  \
             Kix clusters with deployment records on this cluster: {known}\n\n  \
             Why:\n    \
             This Kubernetes cluster holds deployment records for {known}, and none for '{cluster}'. Either '{cluster}' is a typo, your kubeconfig points at the cluster for {known}, or '{cluster}' has never been deployed here.\n\n  \
             Next (choose one):\n    \
             - If you meant a cluster already on this Kubernetes cluster, run the command with that name ({known}).\n    \
             - If '{cluster}' is on another Kubernetes cluster, pass `--context <name>` for that cluster and run the command again.\n    \
             - If '{cluster}' belongs on this Kubernetes cluster and has not been deployed yet, run `kix deploy {cluster}`."
        ))
    }

    /// Return where Kix cluster `cluster` is read from.
    pub fn source_of(&self, cluster: &str) -> Source {
        if self.revision_clusters.contains(cluster) {
            Source::Revisions
        } else {
            Source::Records
        }
    }

    /// Return the field manager to read the objects of Kix cluster
    /// `cluster` with. A Kix cluster an older Kix deployed last holds its
    /// fields under the legacy manager `kix` ([`FieldManager::unmigrated`]).
    pub fn manager_of(&self, cluster: &str) -> FieldManager {
        match self.source_of(cluster) {
            Source::Revisions => FieldManager::of(cluster),
            Source::Records => FieldManager::unmigrated(cluster),
        }
    }

    /// Return where the Kix cluster this tenancy is read for is read from.
    pub fn own_source(&self) -> Source {
        self.source_of(&self.cluster)
    }

    /// Return every record of this Kix cluster, in any phase.
    pub(crate) fn own_records(&self) -> &[Record] {
        &self.own
    }

    /// Return the record this Kix cluster's head names as current.
    pub fn own_current(&self) -> Option<&str> {
        self.own_current.as_deref()
    }

    /// Return whether a later read cannot show the record with identity hash
    /// `hash` to deploy more objects than this read does. That holds for a
    /// record of a Kix cluster read from records, and for a record of a Kix
    /// cluster read from revisions that is `Superseded` or whose map this
    /// read indexed. A record that may still name revisions it does not name
    /// yet, such as a queued one, is not settled.
    pub(crate) fn knows(&self, hash: &str) -> bool {
        self.settled.contains(hash)
    }

    /// Return what this read could not read, for a command that only reads
    /// to report.
    pub fn problems(&self) -> &[Problem] {
        &self.problems
    }

    /// Return the first problem, for a command that deletes to refuse on.
    pub fn complete(&self) -> Result<(), Problem> {
        self.first(|_| true)
    }

    /// Return the first problem about another Kix cluster, or about every
    /// Kix cluster, for a prune that asks which objects other Kix clusters
    /// deploy.
    pub fn complete_for_others(&self) -> Result<(), Problem> {
        let own = self.cluster.as_str();
        self.first(|p| p.cluster() != Some(own))
    }

    /// Return the first problem about the records of this Kix cluster named
    /// in `records`, or about every Kix cluster.
    pub fn complete_for_records(&self, records: &[&str]) -> Result<(), Problem> {
        let own = self.cluster.as_str();
        self.first(|p| match p.cluster() {
            None => true,
            Some(c) => c == own && p.record().is_some_and(|r| records.contains(&r)),
        })
    }

    /// Return the first problem about this Kix cluster's kept-orphans
    /// revision, its current record's map, or every Kix cluster.
    pub fn complete_for_kept(&self) -> Result<(), Problem> {
        let own = self.cluster.as_str();
        self.first(|p| match p.cluster() {
            None => true,
            Some(c) => c == own && (p.kept() || matches!(p, Problem::UnreadableMap { .. })),
        })
    }

    /// Return whether every problem this read found is that this Kix
    /// cluster's kept-orphans revision is missing or cannot be read, and
    /// there is at least one. `kix gc --full-scan` can then rebuild the
    /// list from the live objects ([`Tenancy::unlisted_own`]).
    pub fn only_kept_unreadable(&self) -> bool {
        let own = self.cluster.as_str();
        !self.problems.is_empty()
            && self
                .problems
                .iter()
                .all(|p| p.kept() && p.cluster() == Some(own))
    }

    /// Return whether this Kix cluster applied `obj` and no revision of a
    /// needed record of this cluster other than the kept-orphans revision
    /// names it: an object that only a kept-orphans list can name. The
    /// cluster applied it when it has an `Apply` entry under the cluster's
    /// manager, or when its `kix.run/activations` names a record of this
    /// cluster an older Kix wrote and its fields are still under `kix`.
    pub fn unlisted_own(&self, obj: &DynamicObject) -> bool {
        let entries = obj.metadata.managed_fields.iter().flatten();
        let mut own = false;
        let mut legacy = false;
        for e in entries {
            if e.operation.as_deref() == Some("Apply") && e.subresource.is_none() {
                own |= e.manager.as_deref() == Some(self.manager.name());
                legacy |= e.manager.as_deref() == Some(field_manager::LEGACY);
            }
        }
        let applied = own || (legacy && stamps(obj).any(|h| self.legacy.own.contains(h)));
        applied
            && !self
                .claims_of(obj)
                .iter()
                .any(|c| !c.kept && self.is_own(&c.cluster))
    }

    /// Return the first problem about this Kix cluster, or about every Kix
    /// cluster.
    pub fn complete_for_own(&self) -> Result<(), Problem> {
        let own = self.cluster.as_str();
        self.first(|p| p.cluster().is_none_or(|c| c == own))
    }

    fn first(&self, about: impl Fn(&Problem) -> bool) -> Result<(), Problem> {
        match self.problems.iter().find(|p| about(p)) {
            Some(p) => Err(p.clone()),
            None => Ok(()),
        }
    }

    fn claims_of(&self, obj: &DynamicObject) -> &[Claim] {
        if self.claims.by_object.is_empty() {
            return &[];
        }
        self.claims
            .by_object
            .get(&drift::resource_id(obj))
            .map_or(&[], Vec::as_slice)
    }

    fn is_own(&self, cluster: &str) -> bool {
        !self.cluster.is_empty() && cluster == self.cluster
    }

    /// Return the sorted Kix clusters an object belongs to. An Activation
    /// record belongs to the Kix cluster this read found it under, whatever
    /// that cluster is read from. No revision names a record, so a cluster
    /// read from revisions would otherwise own none of its records.
    pub fn owners_of(&self, obj: &DynamicObject) -> Vec<String> {
        let legacy = named_hashes(obj).filter_map(|h| {
            if self.legacy.own.contains(h) {
                Some(self.cluster.clone())
            } else {
                self.legacy.others.get(h).cloned()
            }
        });
        let claimed = self.claims_of(obj).iter().map(|c| c.cluster.clone());
        let record = (lifecycle_of_live(obj) == Lifecycle::Record)
            .then_some(obj.metadata.name.as_ref())
            .flatten()
            .and_then(|name| self.record_cluster.get(name))
            .cloned();
        let mut owners: Vec<String> = legacy.chain(claimed).chain(record).collect();
        owners.sort();
        owners.dedup();
        owners
    }

    /// Return other Kix clusters whose current build contains `obj`, or
    /// whose deploy that is under way, queued, failed, or partly deployed
    /// does, or that have an `Apply` entry under their own field manager on
    /// `obj`. Prune leaves such objects in place. Another cluster's kept
    /// orphans do not count.
    ///
    /// An `Apply` entry counts whatever the other cluster's records say. A
    /// Kix cluster that adds back an object it applied before may find it
    /// unchanged and write nothing to it, so its entry is the one sign on
    /// the object that it deploys it again ([`super::prune_guard`]).
    pub fn still_deployed_by_others(&self, obj: &DynamicObject) -> Vec<String> {
        let legacy = named_hashes(obj)
            .filter(|h| self.legacy.others_current.contains(*h))
            .filter_map(|h| self.legacy.others.get(h).cloned());
        let claimed = self
            .claims_of(obj)
            .iter()
            .filter(|c| !c.kept && !self.is_own(&c.cluster))
            .map(|c| c.cluster.clone());
        let applying = field_manager::other_clusters_applying(
            &self.manager,
            obj.metadata.managed_fields.as_deref().unwrap_or_default(),
        )
        .into_iter()
        .map(str::to_string);
        let mut clusters: Vec<String> = legacy.chain(claimed).chain(applying).collect();
        clusters.sort();
        clusters.dedup();
        clusters
    }

    /// Return the sorted names of this cluster's pending records that deploy
    /// `obj`: records whose deploy is queued, deploying, failed, or partly
    /// deployed. Such a deploy wrote the object, or is about to, so gc must
    /// not judge it against the current record's build alone. The current
    /// record is left out, because gc compares with its build.
    pub fn pending_records_of(&self, obj: &DynamicObject) -> Vec<String> {
        let legacy = named_hashes(obj).filter_map(|h| self.legacy.own_pending.get(h).cloned());
        let claimed = self
            .claims_of(obj)
            .iter()
            .filter(|c| c.pending && !c.kept && self.is_own(&c.cluster))
            .map(|c| c.record.clone());
        let mut records: Vec<String> = legacy.chain(claimed).collect();
        records.sort();
        records.dedup();
        records
    }

    /// Return whether `kix gc` may delete `obj`, one of this cluster's
    /// objects that the build it compares with lacks. gc may delete only what
    /// the kept-orphans revision names and no other revision of a needed
    /// record of this cluster names. Return `None` when a record of this
    /// cluster without a map names `obj` through its note, or no revision of
    /// this cluster names it, and gc decides as earlier releases did.
    pub fn gc_may_delete(&self, obj: &DynamicObject) -> Option<bool> {
        if stamps(obj).any(|h| self.legacy.own.contains(h)) {
            return None;
        }
        let own: Vec<&Claim> = self
            .claims_of(obj)
            .iter()
            .filter(|c| self.is_own(&c.cluster))
            .collect();
        (!own.is_empty()).then(|| own.iter().all(|c| c.kept))
    }

    /// Return the identity hashes of this cluster's records that deploy
    /// `obj`: the records with a map whose revisions other than the kept
    /// orphans name it, and the records without one whose hash
    /// `kix.run/activations` lists. The object's own build hash is listed
    /// too, so a record names itself.
    pub fn records_naming(&self, obj: &DynamicObject) -> Vec<String> {
        let mut hashes: Vec<String> = self
            .claims_of(obj)
            .iter()
            .filter(|c| !c.kept && self.is_own(&c.cluster))
            .filter_map(|c| c.record_hash.clone())
            .chain(named_hashes(obj).map(str::to_string))
            .collect();
        hashes.sort();
        hashes.dedup();
        hashes
    }

    /// Return the identity hashes of this cluster's records whose deploys
    /// applied `obj`: the records with a map whose revisions name the object
    /// and hold an applied hash for the build hash they give it, and the
    /// records without one whose hash `kix.run/activations` lists.
    pub fn applied_by(&self, obj: &DynamicObject) -> HashSet<String> {
        self.claims_of(obj)
            .iter()
            .filter(|c| !c.kept && self.is_own(&c.cluster))
            .filter(|c| {
                self.claims
                    .revisions
                    .get(&c.revision)
                    .is_some_and(|r| r.applied.contains_key(&c.hash))
            })
            .filter_map(|c| c.record_hash.clone())
            .chain(
                stamps(obj)
                    .filter(|h| self.legacy.own.contains(*h))
                    .map(str::to_string),
            )
            .collect()
    }

    /// Return whether a record of this Kix cluster names `obj`: a revision
    /// of a needed record, its kept-orphans revision included, or the note
    /// of a record without a map.
    pub fn named_by_own(&self, obj: &DynamicObject) -> bool {
        self.claims_of(obj).iter().any(|c| self.is_own(&c.cluster))
            || stamps(obj).any(|h| self.legacy.own.contains(h))
    }

    /// Return the other Kix clusters whose records deploy `obj`, sorted: a
    /// revision other than the kept orphans of a needed record names it, or
    /// its `kix.run/activations` lists a record without a map that is not
    /// `Superseded`.
    pub fn named_by_others(&self, obj: &DynamicObject) -> Vec<String> {
        let legacy = stamps(obj)
            .filter(|h| self.legacy.others_current.contains(*h))
            .filter_map(|h| self.legacy.others.get(h).cloned());
        let claimed = self
            .claims_of(obj)
            .iter()
            .filter(|c| !c.kept && !self.is_own(&c.cluster))
            .map(|c| c.cluster.clone());
        let mut clusters: Vec<String> = legacy.chain(claimed).collect();
        clusters.sort();
        clusters.dedup();
        clusters
    }

    /// Return whether `obj`'s `kix.run/activations` lists a record of
    /// another Kix cluster that has no map. An older Kix reads such an
    /// object's note to tell which Kix clusters still deploy it.
    pub fn noted_by_older_kix(&self, obj: &DynamicObject) -> bool {
        stamps(obj).any(|h| self.legacy.others.contains_key(h))
    }

    /// Return the hashes `obj`'s `kix.run/activations` lists that name a
    /// record of another Kix cluster without a map, or a build such a
    /// record lists under `status.orphansKeptFrom`.
    pub(crate) fn older_kix_hashes<'a>(&self, obj: &'a DynamicObject) -> Vec<&'a str> {
        stamps(obj)
            .filter(|h| self.legacy.others.contains_key(*h))
            .collect()
    }

    /// Return whether one of the revisions `names` lists names `obj`.
    pub(crate) fn named_by_revisions(&self, obj: &DynamicObject, names: &BTreeSet<String>) -> bool {
        self.claims_of(obj)
            .iter()
            .any(|c| names.contains(&c.revision))
    }

    /// Return the objects earlier deploys left on the cluster, as `active`
    /// lists them: from its kept-orphans revision when it has a readable
    /// map, else from its `status.orphansKeptFrom`.
    pub fn kept<'a>(&'a self, active: &'a Record) -> Kept<'a> {
        match &active.revisions {
            Some(Ok(map)) => Kept::Objects(
                map.kept_orphans
                    .as_deref()
                    .and_then(|name| self.claims.revisions.get(name))
                    .map(|r| r.spec.objects.iter().collect())
                    .unwrap_or_default(),
            ),
            _ => Kept::Builds(&active.orphans_kept_from),
        }
    }

    /// Return every revision that a needed record of a Kix cluster read
    /// from revisions names and that this read found.
    pub fn revisions(&self) -> impl Iterator<Item = &Revision> {
        self.claims.revisions.values()
    }

    /// Return the revision named `name`, when a needed record names it and
    /// this read found it.
    pub fn revision(&self, name: &str) -> Option<&Revision> {
        self.claims.revisions.get(name)
    }

    /// Return the package index of `record`'s build: from its revisions
    /// when it has a readable map this read indexed, else its stored
    /// `status.packageIndex`.
    pub fn index_of(&self, record: &Record) -> Option<RecordPackageIndex> {
        match &record.revisions {
            Some(Ok(map)) if map.names().all(|n| self.claims.revisions.contains_key(n)) => {
                Some(map.package_index(|name| self.claims.revisions.get(name)))
            }
            _ => record.package_index.clone(),
        }
    }
}

/// Return the record identity hashes `kix.run/activations` lists on `obj`.
fn stamps(obj: &DynamicObject) -> impl Iterator<Item = &str> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::ACTIVATIONS))
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// Return an iterator over the record identity hashes `obj` names: every entry
/// of `kix.run/activations` plus its own `kix.run/identity-hash`. A record in
/// its first wave is not yet stamped with its own hash in `kix.run/activations`,
/// so including `kix.run/identity-hash` ensures it attributes to itself.
fn named_hashes(obj: &DynamicObject) -> impl Iterator<Item = &str> {
    let own = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH));
    stamps(obj).chain(own)
}

/// Return whether `tenancy` settles every record hash `obj` names
/// ([`Tenancy::knows`]), so a tenancy read before `obj` still judges it.
/// Those are the entries of `kix.run/activations`, and the object's own
/// identity hash when it is an Activation record. On any other object the
/// identity hash is the hash of its manifest, which names no record.
pub(crate) fn settles(tenancy: &Tenancy, obj: &DynamicObject) -> bool {
    let record = lifecycle_of_live(obj) == Lifecycle::Record;
    let named = if record {
        named_hashes(obj).collect::<Vec<_>>()
    } else {
        stamps(obj).collect()
    };
    named.into_iter().all(|h| tenancy.knows(h))
}

/// Read the [`Tenancy`] for `cluster`: the heads of every Kix cluster, then
/// every Activation record, then, when a current record has a readable map,
/// every revision. Each is one list request. If the cluster does not serve
/// the Activation kind, return an empty tenancy. A head or revision kind
/// the cluster does not serve reads as no heads or no revisions.
///
/// Callers must read [`Tenancy`] after listing the objects it will attribute
/// (as [`super::inventory::sweep_managed`] and [`super::prune_guard::PruneGuard`]
/// do). A deploy creates its record, and the revisions its map names, before
/// it writes any object, so every object read earlier belongs either to a
/// record and revisions in this read or to ones deleted since. Reading
/// [`Tenancy`] before the objects would miss a concurrent first deploy of
/// another Kix cluster and misattribute its objects as unrecorded. A record
/// is read from its revisions whenever it has a map, whatever the head of
/// its Kix cluster names, so a deploy that finishes between the reads of
/// the heads and the records does not hide its revisions.
pub async fn read(records: &OpenedRecords, cluster: &str) -> Result<Tenancy, RecordsError> {
    let Some(records) = records.records() else {
        return Ok(Tenancy::empty(cluster));
    };
    let client = records.client();
    let heads = head::list_all(client).await;
    let all = records.all().await?;
    let (heads, heads_problem) = match heads {
        Ok(heads) => (heads, None),
        Err(e) => (
            BTreeMap::new(),
            Some(Problem::Heads {
                reason: super::errors::describe(&e),
            }),
        ),
    };
    let any_map = all
        .iter()
        .any(|r| matches!(Record::of(r).revisions, Some(Ok(_))));
    let listed = if any_map {
        match Revisions::new(client).list_all().await {
            Ok(listed) => Ok(Some(listed)),
            Err(RevisionError::List {
                source: kube::Error::Api(e),
                ..
            }) if e.code == 404 => Ok(Some(Listed {
                readable: Vec::new(),
                unreadable: Vec::new(),
            })),
            Err(e) => Err(e.to_string()),
        }
    } else {
        Ok(None)
    };
    let mut tenancy = match &listed {
        Ok(listed) => Tenancy::from_state(cluster, &heads, &all, Ok(listed.as_ref())),
        Err(reason) => Tenancy::from_state(cluster, &heads, &all, Err(reason.clone())),
    };
    tenancy.problems.extend(heads_problem.clone());
    tenancy.raw.heads_problem = heads_problem;
    Ok(tenancy)
}

#[cfg(test)]
#[path = "tenancy_tests.rs"]
mod tests;
