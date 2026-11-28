//! The answer of `kix status`, which `-o json` and `-o yaml` print as it is
//! and the text output renders.
//!
//! `kix-cli/schema/status.schema.json` describes the JSON. Set
//! [`SCHEMA_VERSION`] to the day's date when a change is not backward
//! compatible.

use std::collections::{BTreeMap, BTreeSet};

use kix::cluster::drift::{DriftVerdict, ForeignOwner, UnrecordedScale};
use kix::cluster::observe::{
    ClusterView, ExpectedFrom, FailedDeploy, ObjectView, Observation, Presence, Readiness,
};
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId, qualified_kind};
use schemars::JsonSchema;
use serde::Serialize;

use crate::cli::StatusCheck;
use crate::exit::Exit;

/// The date of the last change to the shape of [`StatusDocument`] that is
/// not backward compatible.
pub const SCHEMA_VERSION: &str = "2026-11-15";

/// What `kix status` found. Programs that read it must skip fields they do
/// not know.
#[derive(Debug, Serialize, JsonSchema)]
pub struct StatusDocument {
    pub schema_version: String,
    pub kubernetes: Kubernetes,
    /// The checks that ran.
    pub checks: Vec<StatusCheck>,
    /// Resource types this account may not list, such as `secrets`. Objects
    /// of these kinds that Kix cannot see are not checked.
    pub unreadable: Vec<String>,
    pub clusters: Vec<ClusterStatus>,
    /// The counts over every cluster.
    pub summary: Summary,
}

/// The Kubernetes cluster `kix status` read.
#[derive(Debug, Default, Serialize, JsonSchema)]
pub struct Kubernetes {
    /// The kubeconfig context, when known.
    pub context: Option<String>,
    /// The URL of the context's API server in the kubeconfig, when known.
    pub server: Option<String>,
    /// The UID of the `kube-system` Namespace, which `cluster.kubernetes.uid`
    /// names. `null` when this account may not read it.
    pub uid: Option<String>,
    /// The version the API server reports, such as `v1.33.1`.
    pub version: Option<String>,
}

/// One Kix cluster.
#[derive(Debug, Serialize, JsonSchema)]
pub struct ClusterStatus {
    pub cluster: String,
    pub deploy: Deploy,
    /// Where Kix found the list of objects the deploy made.
    pub objects_from: ObjectsFrom,
    /// Warnings about the cluster, such as a platform interface that
    /// changed.
    pub notes: Vec<String>,
    pub packages: Vec<PackageStatus>,
    /// Objects of this cluster that left its build and are still being
    /// deleted, because a finalizer or a slow shutdown holds them.
    pub leaving: Vec<LeavingStatus>,
    /// The newest deploy that failed after `deploy`, or `null`. A failed
    /// deploy leaves the previous record current, so `deploy` and
    /// `packages` describe that record.
    pub failed_deploy: Option<FailedDeployStatus>,
    /// The run that holds the cluster's deploy lock, or `null` when none
    /// does or this account may not read the lock. `kix status` never waits
    /// for the lock and never takes it.
    pub lock: Option<kix::cluster::head::LockView>,
    pub summary: Summary,
}

/// A deploy that failed after the current one.
#[derive(Debug, Serialize, JsonSchema)]
pub struct FailedDeployStatus {
    pub name: String,
    pub identity_hash: Option<String>,
    /// When it failed (RFC 3339), when the record says.
    pub failed_at: Option<String>,
    /// Why it failed, when the record says.
    pub reason: Option<String>,
    /// The objects of the failed build that the current deploy does not
    /// have, by package, with the same checks as the cluster's `packages`.
    /// They do not count in the cluster's `summary`, which counts the failed
    /// deploy itself under `failed_deploys`.
    pub packages: Vec<PackageStatus>,
    pub summary: Summary,
}

/// An object that left the build and is still being deleted.
#[derive(Debug, Serialize, JsonSchema)]
pub struct LeavingStatus {
    pub kind: String,
    /// The kind's API group. Left out for the core group.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub group: String,
    /// `null` for a cluster-scoped object.
    pub namespace: Option<String>,
    pub name: String,
    /// `namespace/instance` of the package it belonged to, or `null`.
    pub package: Option<String>,
    /// When the delete started (RFC 3339).
    pub deleting_since: String,
    /// The finalizers that still hold it.
    pub finalizers: Vec<String>,
}

/// The current deploy record.
#[derive(Debug, Serialize, JsonSchema)]
pub struct Deploy {
    pub name: String,
    /// `Active`, or `Degraded` when some objects failed.
    pub phase: String,
    pub identity_hash: Option<String>,
    /// When the deploy finished (RFC 3339).
    pub deployed_at: Option<String>,
    /// The version of Kix that made the deploy, when the record says.
    pub deployed_with: Option<String>,
}

/// Where Kix found the list of objects a deploy made.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ObjectsFrom {
    /// The deploy record's package index.
    Index,
    /// The depends-on annotations of the deploy's live objects, for a record
    /// written before Kix stored an index.
    DependsOn,
    /// Nowhere: the record has no index and its own object is gone. No
    /// object was checked.
    Unknown,
}

/// One package, or the cluster-level objects.
#[derive(Debug, Serialize, JsonSchema)]
pub struct PackageStatus {
    /// `namespace/instance`, or `null` for the objects no package owns.
    pub name: Option<String>,
    pub summary: Summary,
    pub resources: Vec<ResourceStatus>,
}

/// One object of the deploy.
#[derive(Debug, Serialize, JsonSchema)]
pub struct ResourceStatus {
    /// The kind, or `Unknown` when Kix cannot name a missing object.
    pub kind: String,
    /// The kind's API group. Left out for the core group.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub group: String,
    /// `null` for a cluster-scoped object.
    pub namespace: Option<String>,
    pub name: String,
    /// The hash the deploy record gives the object. For a deploy by this
    /// version of Kix it is a hash of the manifest Kix sends for it. For a
    /// deploy by an older Kix it is the object's identity hash annotation.
    pub hash: String,
    /// `false` when Kix could not name a missing object. The deploy record
    /// names its objects from Kix 0.10, and Kix's local store names them
    /// when it holds the build.
    pub named: bool,
    pub present: Present,
    /// The drift check, or `null` when it did not run or the object is not
    /// on the cluster.
    pub drift: Option<Drift>,
    /// Whether the object is ready. `null` when the readiness check did not
    /// run, the kind has no readiness (such as a ConfigMap), or the object is
    /// not on the cluster.
    pub ready: Option<bool>,
    /// Why the object is not ready, such as `0/1 ready, 0/1 updated`.
    pub not_ready_reason: Option<String>,
    /// The objects that depend on this one, as `Kind.group namespace/name`
    /// (`Kind namespace/name` for the core group), when it is missing.
    pub needed_by: Vec<String>,
    /// When the object's delete started (RFC 3339), when it is being
    /// deleted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deleting_since: Option<String>,
    /// The finalizers that hold an object being deleted.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub finalizers: Vec<String>,
    /// What the checks found wrong. Empty when the object is fine.
    pub problems: Vec<Problem>,
    /// Whether a selected check could not run on the object.
    pub not_checked: bool,
}

/// Whether an object is on the cluster.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Present {
    Yes,
    /// An import marker, which stands for an object Kix does not manage.
    External,
    No,
    /// This account may not list the object's kind.
    Unknown,
    /// The object's record does not say its API group, and more than one
    /// group on the cluster serves its kind, so Kix cannot look it up.
    Ambiguous,
}

/// Something a check found wrong with an object.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Problem {
    /// The object is not on the cluster. Every check reports it, because
    /// none can run on an object that is gone.
    Missing,
    /// The object no longer holds what Kix applied.
    Changed,
    NotReady,
    /// The object is being deleted, so it will soon be missing. Every check
    /// reports it, in place of `changed` or `not_ready`. The next deploy
    /// waits until it is gone, then creates it again.
    Deleting,
}

/// The drift check of one object.
#[derive(Debug, Serialize, JsonSchema)]
pub struct Drift {
    pub verdict: DriftState,
    /// Other field managers that own fields of the object.
    pub foreign_owners: Vec<Owner>,
    /// A replica count changed through `/scale` that Kubernetes recorded no
    /// owner for.
    pub unrecorded_scale: Option<Scale>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DriftState {
    InSync,
    Changed,
    /// Kix has no applied hash for the object. A `kix deploy` of a Kix
    /// cluster read from revisions applies it again and records one.
    Unstamped,
    /// The object has no field ownership entry for Kix.
    NoFieldset,
}

#[derive(Debug, Serialize, JsonSchema)]
pub struct Owner {
    pub manager: String,
    pub operation: String,
    pub subresource: Option<String>,
    /// When the manager last wrote (RFC 3339), when Kubernetes recorded it.
    pub time: Option<String>,
    pub paths: Vec<String>,
    /// The paths in `paths` that Kix does not also own. Only these can stop
    /// a deploy on a field ownership conflict. A field Kix also owns still
    /// holds the value Kix applied.
    pub unshared_paths: Vec<String>,
}

#[derive(Debug, Serialize, JsonSchema)]
pub struct Scale {
    pub path: String,
    pub deployed: i64,
    pub live: i64,
}

/// Counts of objects. An object with two problems counts under both.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
pub struct Summary {
    pub resources: usize,
    /// Objects that every selected check passed. An object that a check
    /// could not run on counts under `not_checked` instead.
    pub ok: usize,
    pub missing: usize,
    pub changed: usize,
    pub not_ready: usize,
    /// Objects of the build being deleted.
    pub deleting: usize,
    /// Objects that left the build and are still being deleted. They are
    /// not counted in `resources`.
    pub leaving: usize,
    pub not_checked: usize,
    /// Kix clusters whose newest deploy failed after their current one.
    pub failed_deploys: usize,
}

impl Summary {
    fn add(&mut self, r: &ResourceStatus) {
        self.resources += 1;
        if r.problems.is_empty() && !r.not_checked {
            self.ok += 1;
        }
        for p in &r.problems {
            match p {
                Problem::Missing => self.missing += 1,
                Problem::Changed => self.changed += 1,
                Problem::NotReady => self.not_ready += 1,
                Problem::Deleting => self.deleting += 1,
            }
        }
        if r.not_checked {
            self.not_checked += 1;
        }
    }

    fn merge(&mut self, other: &Summary) {
        self.resources += other.resources;
        self.ok += other.ok;
        self.missing += other.missing;
        self.changed += other.changed;
        self.not_ready += other.not_ready;
        self.deleting += other.deleting;
        self.leaving += other.leaving;
        self.not_checked += other.not_checked;
        self.failed_deploys += other.failed_deploys;
    }

    /// Return whether a check found something wrong.
    pub fn has_problems(&self) -> bool {
        self.missing
            + self.changed
            + self.not_ready
            + self.deleting
            + self.leaving
            + self.failed_deploys
            > 0
    }
}

impl StatusDocument {
    /// Return how `kix status` ends: 2 when a check found a problem, 1 when
    /// Kix could not tell which objects a deploy made, and 0 otherwise.
    pub fn exit(&self) -> Exit {
        if self.summary.has_problems() {
            Exit::StatusFoundProblem
        } else if self
            .clusters
            .iter()
            .any(|c| c.objects_from == ObjectsFrom::Unknown)
        {
            Exit::Failure
        } else {
            Exit::Success
        }
    }
}

/// Return the checks to run: those named, or all three.
pub fn selected(named: &[StatusCheck]) -> Vec<StatusCheck> {
    let mut checks = if named.is_empty() {
        vec![
            StatusCheck::Presence,
            StatusCheck::Drift,
            StatusCheck::Readiness,
        ]
    } else {
        named.to_vec()
    };
    checks.sort();
    checks.dedup();
    checks
}

/// Build the answer from what [`kix::cluster::observe::observe`] read.
///
/// `notes` holds warnings for each cluster. `package` narrows each cluster
/// to the packages whose `namespace/instance` or instance name it is. It is
/// an error when no cluster has such a package.
pub fn build(
    observation: &Observation,
    kubernetes: Kubernetes,
    notes: &BTreeMap<String, Vec<String>>,
    checks: &[StatusCheck],
    package: Option<&str>,
) -> Result<StatusDocument, String> {
    let mut clusters: Vec<ClusterStatus> = observation
        .clusters
        .iter()
        .map(|view| cluster_status(view, notes.get(&view.cluster), checks))
        .collect();
    if let Some(wanted) = package {
        let known: BTreeSet<String> = clusters
            .iter()
            .flat_map(|c| &c.packages)
            .filter_map(|p| p.name.clone())
            .collect();
        let matches = |name: &Option<String>| {
            name.as_deref().is_some_and(|n| {
                n == wanted
                    || n.split_once('/')
                        .is_some_and(|(_, instance)| instance == wanted)
            })
        };
        for c in &mut clusters {
            c.packages.retain(|p| matches(&p.name));
            c.leaving.retain(|l| matches(&l.package));
            c.summary = Summary::default();
            for p in &c.packages {
                c.summary.merge(&p.summary);
            }
            c.summary.leaving = c.leaving.len();
            if let Some(failed) = &mut c.failed_deploy {
                failed.packages.retain(|p| matches(&p.name));
                failed.summary = Summary::default();
                for p in &failed.packages {
                    failed.summary.merge(&p.summary);
                }
            }
            c.summary.failed_deploys = usize::from(c.failed_deploy.is_some());
        }
        if clusters.iter().all(|c| c.packages.is_empty()) {
            return Err(no_such_package(wanted, &known));
        }
    }
    let mut summary = Summary::default();
    for c in &clusters {
        summary.merge(&c.summary);
    }
    Ok(StatusDocument {
        schema_version: SCHEMA_VERSION.to_string(),
        kubernetes,
        checks: checks.to_vec(),
        unreadable: observation.unreadable.clone(),
        clusters,
        summary,
    })
}

/// The most package names the `--package` error lists in full. Past it, the
/// error lists the [`CLOSEST`] names.
const LISTED: usize = 10;
/// How many of the closest package names the `--package` error lists.
const CLOSEST: usize = 5;

/// Return the error for a `--package` that names no package in `known`.
fn no_such_package(wanted: &str, known: &BTreeSet<String>) -> String {
    let mut message = format!("No package '{wanted}' in the current deploy.");
    if known.is_empty() {
        return message;
    }
    if known.len() <= LISTED {
        let names: Vec<&str> = known.iter().map(String::as_str).collect();
        message.push_str(&format!(" Packages: {}.", names.join(", ")));
        return message;
    }
    // Score each name by the closer of its full name and its instance name,
    // since `--package` takes either.
    let score = |name: &str| {
        let instance = name.split_once('/').map_or(name, |(_, i)| i);
        strsim::jaro_winkler(wanted, name).max(strsim::jaro_winkler(wanted, instance))
    };
    let mut ranked: Vec<(f64, &str)> = known.iter().map(|n| (score(n), n.as_str())).collect();
    ranked.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(b.1)));
    let closest: Vec<&str> = ranked.iter().take(CLOSEST).map(|(_, n)| *n).collect();
    message.push_str(&format!(
        " It has {} packages. The closest names: {}.",
        known.len(),
        closest.join(", ")
    ));
    message
}

fn cluster_status(
    view: &ClusterView,
    notes: Option<&Vec<String>>,
    checks: &[StatusCheck],
) -> ClusterStatus {
    let packages = group_packages(&view.objects, checks);
    let mut summary = Summary::default();
    for p in &packages {
        summary.merge(&p.summary);
    }
    let leaving: Vec<LeavingStatus> = view
        .leaving
        .iter()
        .map(|l| LeavingStatus {
            kind: l.rid.kind.clone(),
            group: l.rid.group.clone(),
            namespace: (l.rid.namespace != CLUSTER_SCOPED).then(|| l.rid.namespace.clone()),
            name: l.rid.name.clone(),
            package: l.package.clone(),
            deleting_since: l.deleting.since.clone(),
            finalizers: l.deleting.finalizers.clone(),
        })
        .collect();
    summary.leaving = leaving.len();
    let failed_deploy = view
        .failed
        .as_ref()
        .map(|f| failed_deploy_status(f, checks));
    summary.failed_deploys = usize::from(failed_deploy.is_some());
    let record = &view.record;
    ClusterStatus {
        cluster: view.cluster.clone(),
        deploy: Deploy {
            name: record.name.clone(),
            phase: record.phase.clone(),
            identity_hash: record.identity_hash.clone(),
            deployed_at: record.deployed_at.clone(),
            deployed_with: record.deployed_with.clone(),
        },
        objects_from: match view.expected_from {
            ExpectedFrom::Index => ObjectsFrom::Index,
            ExpectedFrom::DependsOn => ObjectsFrom::DependsOn,
            ExpectedFrom::Nothing => ObjectsFrom::Unknown,
        },
        notes: notes.cloned().unwrap_or_default(),
        packages,
        leaving,
        failed_deploy,
        lock: None,
        summary,
    }
}

impl StatusDocument {
    /// Name the run that holds each Kix cluster's deploy lock, from `locks`
    /// keyed by cluster.
    pub fn set_locks(&mut self, locks: &BTreeMap<String, kix::cluster::head::LockView>) {
        for c in &mut self.clusters {
            c.lock = locks.get(&c.cluster).cloned();
        }
    }
}

fn failed_deploy_status(failed: &FailedDeploy, checks: &[StatusCheck]) -> FailedDeployStatus {
    let packages = group_packages(&failed.objects, checks);
    let mut summary = Summary::default();
    for p in &packages {
        summary.merge(&p.summary);
    }
    FailedDeployStatus {
        name: failed.record.name.clone(),
        identity_hash: failed.record.identity_hash.clone(),
        failed_at: failed.record.failed_at.clone(),
        reason: failed.record.failure_reason.clone(),
        packages,
        summary,
    }
}

/// Check `objects` and group them by package: packages by name, then the
/// objects no package owns.
fn group_packages(objects: &[ObjectView], checks: &[StatusCheck]) -> Vec<PackageStatus> {
    let mut packages: BTreeMap<Option<String>, Vec<ResourceStatus>> = BTreeMap::new();
    for obj in objects {
        packages
            .entry(obj.package.clone())
            .or_default()
            .push(resource_status(objects, obj, checks));
    }
    let (cluster_level, named): (Vec<_>, Vec<_>) =
        packages.into_iter().partition(|(name, _)| name.is_none());
    named
        .into_iter()
        .chain(cluster_level)
        .map(|(name, resources)| {
            let mut summary = Summary::default();
            for r in &resources {
                summary.add(r);
            }
            PackageStatus {
                name,
                summary,
                resources,
            }
        })
        .collect()
}

fn resource_status(
    objects: &[ObjectView],
    obj: &ObjectView,
    checks: &[StatusCheck],
) -> ResourceStatus {
    let present = match obj.presence {
        Presence::Present => Present::Yes,
        Presence::External => Present::External,
        Presence::Missing => Present::No,
        Presence::Unknown => Present::Unknown,
        Presence::Ambiguous => Present::Ambiguous,
    };
    let on_cluster = matches!(present, Present::Yes | Present::External);
    let mut problems = Vec::new();
    let mut not_checked = matches!(present, Present::Unknown | Present::Ambiguous);
    if present == Present::No {
        problems.push(Problem::Missing);
    }
    let deleting = obj.deleting.as_ref();
    if deleting.is_some() {
        problems.push(Problem::Deleting);
    }
    let drift = match (&obj.content, checks.contains(&StatusCheck::Drift)) {
        (Some(verdict), true) => {
            let d = drift_of(verdict);
            match d.verdict {
                DriftState::Changed if deleting.is_some() => {}
                DriftState::Changed => problems.push(Problem::Changed),
                DriftState::Unstamped | DriftState::NoFieldset => not_checked = true,
                DriftState::InSync => {}
            }
            Some(d)
        }
        _ => None,
    };
    let (ready, not_ready_reason) = match (&obj.readiness, checks.contains(&StatusCheck::Readiness))
    {
        (Readiness::Ready, true) => (Some(true), None),
        (Readiness::NotReady(reason), true) => {
            if deleting.is_none() {
                problems.push(Problem::NotReady);
            }
            (Some(false), Some(reason.clone()))
        }
        _ => (None, None),
    };
    let needed_by = if on_cluster {
        Vec::new()
    } else {
        objects
            .iter()
            .filter(|o| o.depends_on.contains(&obj.hash))
            .map(|o| label(&o.rid))
            .collect()
    };
    ResourceStatus {
        kind: obj.rid.kind.clone(),
        group: obj.rid.group.clone(),
        namespace: (obj.rid.namespace != CLUSTER_SCOPED).then(|| obj.rid.namespace.clone()),
        name: obj.rid.name.clone(),
        hash: obj.hash.clone(),
        named: obj.named,
        present,
        drift,
        ready,
        not_ready_reason,
        needed_by,
        deleting_since: deleting.map(|d| d.since.clone()),
        finalizers: deleting.map(|d| d.finalizers.clone()).unwrap_or_default(),
        problems,
        not_checked,
    }
}

/// Return `Kind namespace/name`, or `Kind name` for a cluster-scoped object.
pub fn label(rid: &ResourceId) -> String {
    let kind = qualified_kind(&rid.group, &rid.kind);
    if rid.namespace == CLUSTER_SCOPED {
        format!("{kind} {}", rid.name)
    } else {
        format!("{kind} {}/{}", rid.namespace, rid.name)
    }
}

fn drift_of(verdict: &DriftVerdict) -> Drift {
    let owner = |o: &ForeignOwner| Owner {
        manager: o.manager.clone(),
        operation: o.operation.clone(),
        subresource: o.subresource.clone(),
        time: o.time.clone(),
        paths: o.paths.clone(),
        unshared_paths: o.unshared_paths.clone(),
    };
    let scale = |s: &UnrecordedScale| Scale {
        path: s.path.clone(),
        deployed: s.deployed,
        live: s.live,
    };
    match verdict {
        DriftVerdict::InSync => Drift {
            verdict: DriftState::InSync,
            foreign_owners: vec![],
            unrecorded_scale: None,
        },
        DriftVerdict::Unstamped => Drift {
            verdict: DriftState::Unstamped,
            foreign_owners: vec![],
            unrecorded_scale: None,
        },
        DriftVerdict::NoFieldset => Drift {
            verdict: DriftState::NoFieldset,
            foreign_owners: vec![],
            unrecorded_scale: None,
        },
        DriftVerdict::Drifted {
            foreign,
            unrecorded_scale,
        } => Drift {
            verdict: DriftState::Changed,
            foreign_owners: foreign.iter().map(owner).collect(),
            unrecorded_scale: unrecorded_scale.as_ref().map(scale),
        },
    }
}
