//! The answer of `kix status`, which `-o json` and `-o yaml` print as it is
//! and the text output renders.
//!
//! `kix-cli/schema/status.schema.json` describes the JSON. Set
//! [`SCHEMA_VERSION`] to the day's date when a change is not backward
//! compatible.

use std::collections::{BTreeMap, BTreeSet};

use kix::cluster::drift::{DriftVerdict, ForeignOwner, UnrecordedScale};
use kix::cluster::observe::{
    ClusterView, ExpectedFrom, ObjectView, Observation, Presence, Readiness,
};
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};
use schemars::JsonSchema;
use serde::Serialize;

use crate::cli::StatusCheck;
use crate::exit::Exit;

/// The date of the last change to the shape of [`StatusDocument`] that is
/// not backward compatible.
pub const SCHEMA_VERSION: &str = "2026-11-13";

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
    pub summary: Summary,
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
    /// `null` for a cluster-scoped object.
    pub namespace: Option<String>,
    pub name: String,
    pub identity_hash: String,
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
    /// The objects that depend on this one, as `Kind namespace/name`, when
    /// it is missing.
    pub needed_by: Vec<String>,
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
    /// The object has no applied-hash stamp yet. The next deploy adds it.
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
    pub not_checked: usize,
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
        self.not_checked += other.not_checked;
    }

    /// Return whether a check found something wrong.
    pub fn has_problems(&self) -> bool {
        self.missing + self.changed + self.not_ready > 0
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
            c.summary = Summary::default();
            for p in &c.packages {
                c.summary.merge(&p.summary);
            }
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
    let mut packages: BTreeMap<Option<String>, Vec<ResourceStatus>> = BTreeMap::new();
    for obj in &view.objects {
        packages
            .entry(obj.package.clone())
            .or_default()
            .push(resource_status(view, obj, checks));
    }
    // Packages by name, then the objects no package owns.
    let (cluster_level, named): (Vec<_>, Vec<_>) =
        packages.into_iter().partition(|(name, _)| name.is_none());
    let packages: Vec<PackageStatus> = named
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
        .collect();
    let mut summary = Summary::default();
    for p in &packages {
        summary.merge(&p.summary);
    }
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
        summary,
    }
}

fn resource_status(view: &ClusterView, obj: &ObjectView, checks: &[StatusCheck]) -> ResourceStatus {
    let present = match obj.presence {
        Presence::Present => Present::Yes,
        Presence::External => Present::External,
        Presence::Missing => Present::No,
        Presence::Unknown => Present::Unknown,
    };
    let on_cluster = matches!(present, Present::Yes | Present::External);
    let mut problems = Vec::new();
    let mut not_checked = present == Present::Unknown;
    if present == Present::No {
        problems.push(Problem::Missing);
    }
    let drift = match (&obj.content, checks.contains(&StatusCheck::Drift)) {
        (Some(verdict), true) => {
            let d = drift_of(verdict);
            match d.verdict {
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
            problems.push(Problem::NotReady);
            (Some(false), Some(reason.clone()))
        }
        _ => (None, None),
    };
    let needed_by = if on_cluster {
        Vec::new()
    } else {
        view.needed_by(&obj.identity_hash)
            .iter()
            .map(|o| label(&o.rid))
            .collect()
    };
    ResourceStatus {
        kind: obj.rid.kind.clone(),
        namespace: (obj.rid.namespace != CLUSTER_SCOPED).then(|| obj.rid.namespace.clone()),
        name: obj.rid.name.clone(),
        identity_hash: obj.identity_hash.clone(),
        named: obj.named,
        present,
        drift,
        ready,
        not_ready_reason,
        needed_by,
        problems,
        not_checked,
    }
}

/// Return `Kind namespace/name`, or `Kind name` for a cluster-scoped object.
pub fn label(rid: &ResourceId) -> String {
    if rid.namespace == CLUSTER_SCOPED {
        format!("{} {}", rid.kind, rid.name)
    } else {
        format!("{} {}/{}", rid.kind, rid.namespace, rid.name)
    }
}

fn drift_of(verdict: &DriftVerdict) -> Drift {
    let owner = |o: &ForeignOwner| Owner {
        manager: o.manager.clone(),
        operation: o.operation.clone(),
        subresource: o.subresource.clone(),
        time: o.time.clone(),
        paths: o.paths.clone(),
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
