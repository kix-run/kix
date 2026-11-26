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
//! - **Records.** Any other Kix cluster is read the way earlier releases
//!   wrote it: every object a deploy touches names the deploying record's
//!   identity hash in `kix.run/activations`, a record also owns the builds it
//!   lists under `status.orphansKeptFrom`, and the package index lists a
//!   record's objects.
//!
//! Records are read through [`Records`](super::activation::Records) after the
//! domain gate runs. Without that gate, a cluster whose records sit under a
//! retired group would appear to have no records, every object would look
//! unattributed, and a view of one Kix cluster would include all of them.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use kube::api::DynamicObject;

use super::activation::{KeptOrphanSource, OpenedRecords, Record, RecordsError};
use super::drift;
use super::head::{self, HeadStatus};
use super::revision::{self, Listed, Revision, RevisionError, RevisionObject, Revisions};
use crate::eval::package_index::RecordPackageIndex;
use crate::manifest::keys;
use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_DEGRADED, PHASE_SUPERSEDED};
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tenancy {
    /// The Kix cluster this tenancy is read for.
    pub(crate) cluster: String,
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

        let listed = match revisions {
            Ok(listed) => listed,
            Err(reason) => {
                tenancy.problems.push(Problem::Revisions { reason });
                None
            }
        };
        if let Some(listed) = listed {
            for (name, status) in heads {
                if tenancy.reads_revisions_by(name, status, &parsed) {
                    tenancy.revision_clusters.insert(name.clone());
                }
            }
            tenancy.claim(heads, &parsed, listed);
        } else {
            for (name, status) in heads {
                tenancy.note_unreadable_current(name, status, &parsed);
            }
        }
        tenancy.read_legacy(records, &parsed);
        tenancy
    }

    /// Return whether Kix cluster `name` reads from revisions: its head names
    /// a current record whose map is readable. Note a current record whose
    /// map cannot be read.
    fn reads_revisions_by(
        &mut self,
        name: &str,
        status: &HeadStatus,
        records: &[(Option<&str>, Record)],
    ) -> bool {
        let Some(current) = self.current_of(name, status, records) else {
            return false;
        };
        match &current.revisions {
            Some(Ok(_)) => true,
            Some(Err(source)) => {
                self.problems.push(Problem::UnreadableMap {
                    cluster: name.to_string(),
                    record: current.name.clone(),
                    source: source.clone(),
                });
                false
            }
            None => false,
        }
    }

    fn note_unreadable_current(
        &mut self,
        name: &str,
        status: &HeadStatus,
        records: &[(Option<&str>, Record)],
    ) {
        if let Some(Record {
            name: record,
            revisions: Some(Err(source)),
            ..
        }) = self.current_of(name, status, records)
        {
            self.problems.push(Problem::UnreadableMap {
                cluster: name.to_string(),
                record: record.clone(),
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

    /// Index the objects that the needed records of each Kix cluster read
    /// from revisions name: the current record, the record the lock holder
    /// deploys, and each record that is not `Superseded`.
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
            let Some(cluster) = owner.filter(|c| self.revision_clusters.contains(*c)) else {
                continue;
            };
            let status = heads.get(cluster);
            let current = status.and_then(|s| s.current.as_deref());
            let deploying = status
                .and_then(|s| s.lock.as_ref())
                .and_then(|l| l.activation.as_deref());
            let needed = record.phase != PHASE_SUPERSEDED
                || Some(record.name.as_str()) == current
                || Some(record.name.as_str()) == deploying;
            let map = match &record.revisions {
                Some(Ok(map)) if needed => map,
                Some(Err(source)) if needed => {
                    if Some(record.name.as_str()) != current {
                        self.problems.push(Problem::UnreadableMap {
                            cluster: cluster.to_string(),
                            record: record.name.clone(),
                            source: source.clone(),
                        });
                    }
                    continue;
                }
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

    /// Read the Kix clusters that are not read from revisions from their
    /// records, and note which identity hashes are settled.
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
            if owner.is_some_and(|o| self.revision_clusters.contains(o)) {
                // A record that is Superseded, or whose map this read
                // indexed, cannot come to name more objects than it does.
                // One that may still gain a map is left unsettled.
                if parsed.phase == PHASE_SUPERSEDED {
                    self.settled.insert(hash.to_string());
                }
                self.settled.extend(kept.map(str::to_string));
                continue;
            }
            self.settled.insert(hash.to_string());
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

    /// Return where the Kix cluster this tenancy is read for is read from.
    pub fn own_source(&self) -> Source {
        self.source_of(&self.cluster)
    }

    /// Return every record of this Kix cluster, in any phase.
    pub(crate) fn own_records(&self) -> &[Record] {
        &self.own
    }

    /// Return the record this Kix cluster's head names as current.
    pub(crate) fn own_current(&self) -> Option<&str> {
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

    /// Return the sorted Kix clusters an object belongs to. A record names
    /// itself through its own identity hash.
    pub fn owners_of(&self, obj: &DynamicObject) -> Vec<String> {
        let legacy = named_hashes(obj).filter_map(|h| {
            if self.legacy.own.contains(h) {
                Some(self.cluster.clone())
            } else {
                self.legacy.others.get(h).cloned()
            }
        });
        let claimed = self.claims_of(obj).iter().map(|c| c.cluster.clone());
        let mut owners: Vec<String> = legacy.chain(claimed).collect();
        owners.sort();
        owners.dedup();
        owners
    }

    /// Return other Kix clusters whose current build contains `obj`, or
    /// whose deploy that is under way, queued, failed, or partly deployed
    /// does. Prune leaves such objects in place. Another cluster's kept
    /// orphans do not count.
    pub fn still_deployed_by_others(&self, obj: &DynamicObject) -> Vec<String> {
        let legacy = named_hashes(obj)
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

    /// Return whether any other Kix cluster deploys anything, so a caller
    /// with nothing to ask can skip reading objects.
    pub(crate) fn others_deploy_anything(&self) -> bool {
        !self.legacy.others_current.is_empty()
            || self.revision_clusters.iter().any(|c| !self.is_own(c))
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
    /// record of this cluster names. Return `None` when this cluster is read
    /// from records, or no revision of it names `obj`, and gc decides as
    /// earlier releases did.
    pub fn gc_may_delete(&self, obj: &DynamicObject) -> Option<bool> {
        if self.own_source() != Source::Revisions {
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
    /// `obj`: those `kix.run/activations` names, and its own build hash, for
    /// a cluster read from records, and the records whose revisions other
    /// than the kept orphans name it, for a cluster read from revisions.
    pub fn records_naming(&self, obj: &DynamicObject) -> Vec<String> {
        if self.own_source() != Source::Revisions {
            return named_hashes(obj).map(str::to_string).collect();
        }
        let mut hashes: Vec<String> = self
            .claims_of(obj)
            .iter()
            .filter(|c| !c.kept && self.is_own(&c.cluster))
            .filter_map(|c| c.record_hash.clone())
            .collect();
        hashes.sort();
        hashes.dedup();
        hashes
    }

    /// Return the identity hashes of this cluster's records whose deploys
    /// applied `obj`. For a cluster read from records, those are the hashes
    /// `kix.run/activations` names. For one read from revisions, those are
    /// the records whose revisions name the object and hold an applied hash
    /// for the build hash they give it.
    pub fn applied_by(&self, obj: &DynamicObject) -> HashSet<String> {
        if self.own_source() != Source::Revisions {
            return stamps(obj).map(str::to_string).collect();
        }
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
            .collect()
    }

    /// Return whether one of the revisions `names` lists names `obj`.
    pub(crate) fn named_by_revisions(&self, obj: &DynamicObject, names: &BTreeSet<String>) -> bool {
        self.claims_of(obj)
            .iter()
            .any(|c| names.contains(&c.revision))
    }

    /// Return the objects earlier deploys left on the cluster, as `active`
    /// lists them: from its kept-orphans revision when this cluster is read
    /// from revisions and `active` has a readable map, else from its
    /// `status.orphansKeptFrom`.
    pub fn kept<'a>(&'a self, active: &'a Record) -> Kept<'a> {
        match &active.revisions {
            Some(Ok(map)) if self.own_source() == Source::Revisions => Kept::Objects(
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
    /// when its Kix cluster is read from revisions and it has a readable
    /// map, else its stored `status.packageIndex`.
    pub fn index_of(&self, record: &Record) -> Option<RecordPackageIndex> {
        let cluster = self.record_cluster.get(&record.name);
        match &record.revisions {
            Some(Ok(map)) if cluster.is_some_and(|c| self.revision_clusters.contains(c)) => {
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

/// Return whether `tenancy` settles every hash `obj` names
/// ([`Tenancy::knows`]), so a tenancy read before `obj` still judges it.
/// The hashes include the object's own identity hash, which names a record
/// only on an Activation record.
pub(crate) fn settles(tenancy: &Tenancy, obj: &DynamicObject) -> bool {
    named_hashes(obj).all(|h| tenancy.knows(h))
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
/// any object names the record's hash, so every object read earlier belongs
/// either to a record and revisions in this read or to ones deleted since.
/// Reading [`Tenancy`] before the objects would miss a concurrent first
/// deploy of another Kix cluster and misattribute its objects as
/// unrecorded.
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
    tenancy.problems.extend(heads_problem);
    Ok(tenancy)
}

#[cfg(test)]
#[path = "tenancy_tests.rs"]
mod tests;
