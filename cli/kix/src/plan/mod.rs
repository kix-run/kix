//! Deploy and diff plans for reviewing what a build changes.
//!
//! [`Planner`] builds a deploy plan from a build and the cluster's [`baseline`].
//! [`diff_graphs`] compares two builds package by package into a [`PackageDiff`].
//! [`document::Plan`] is the typed document that `kix plan` and `kix diff` emit.
//! [`objects`] verifies that a deploy only writes or deletes objects shown in the diff.
//! [`saved`] compares a freshly generated plan against a reviewed one.
//! [`live`] builds the operator's plan from live cluster objects.

pub mod baseline;
mod decide;
mod diff;
pub mod document;
pub mod file;
#[cfg(any(test, feature = "test-util"))]
pub mod fixtures;
pub mod live;
#[cfg(test)]
pub(crate) mod migration_tests;
pub mod objects;
pub mod offline;
#[cfg(test)]
mod only_tests;
pub mod origin;
#[cfg(test)]
mod plan_bound_tests;
mod planner;
mod redact;
pub mod saved;
pub mod server;
#[cfg(test)]
mod synthesize_tests;
#[cfg(test)]
mod tests;

pub use crate::cluster::scheduler::LastRuns;
#[cfg(test)]
use diff::is_propagation_path;
pub(crate) use diff::partition_propagation;
pub use diff::{diff_garbage, diff_graphs};
pub use planner::{
    CheckedPlan, Connected, Differences, OldSide, Planned, Planner, Replanned, Settle, Start,
    Target, TargetChecks, Work, keep_held, keep_shared, kinds_leaving,
};
#[cfg(test)]
use redact::LAST_APPLIED;
pub use redact::{
    HASH_CHANGED_NOT_SHOWN, HASH_NOT_SHOWN, MAX_SHOWN_MANIFEST_BYTES, MAX_SHOWN_VALUE_BYTES,
    ManifestIndex, SECRET_CHANGED_NOT_SHOWN, SECRET_NOT_SHOWN, without_secrets,
};
pub(crate) use redact::{Side, shown_value};

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::cluster::activation::{KeptOrphanSource, Record};
use crate::cluster::errors::FetchError;
use crate::cluster::graph::GraphError;
use crate::cluster::readiness::MalformedMarker;
use crate::eval::PackageNode;
use crate::eval::store_graph::StoreGraph;
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::diff::Difference;
use crate::manifest::kinds;
use crate::manifest::lifecycle;
use crate::manifest::types::ResourceId;

/// Progress events emitted by the planner for the caller to display.
#[derive(Debug, Clone, Copy)]
pub enum PlanEvent<'a> {
    /// Connecting to the Kubernetes cluster of this connection before
    /// reading state.
    Connecting(&'a crate::cluster::binding::Connection),
    /// Another run holds the cluster's deploy lock, and the planner watches
    /// it before it reads the cluster.
    LockHeld(&'a crate::cluster::head::LockState),
    /// The first deploy of Kix cluster `cluster`, whose definition names no
    /// Kubernetes cluster, through `connection`. `uid` is the live
    /// `kube-system` UID, or `None` when it could not be read.
    Unbound {
        cluster: &'a str,
        connection: &'a crate::cluster::binding::Connection,
        uid: Option<&'a str>,
    },
    /// `--operator-removed` took Kix cluster `cluster` back from the Kix
    /// operator before the plan read it.
    TookBack {
        cluster: &'a str,
        taken: &'a crate::cluster::activation::features::TakenBack,
    },
    /// `--offline` found no cached build, so this is a first deploy.
    NoCachedBuild,
    /// `--offline` is loading the cached build.
    LoadingCache,
    /// The cluster has no Active record, so this is a first deploy.
    NoActiveRecord,
    /// The Active record that the plan compares against.
    Active {
        name: &'a str,
        identity_hash: &'a str,
    },
    /// The Active record's build is not on this machine (`error` is `None`)
    /// or failed to load, so the plan reads its objects from the cluster.
    ReadingLive { error: Option<&'a str> },
    /// Number of objects in this cluster that name only older builds and are
    /// excluded from the live-cluster reconstruction.
    OlderBuildsLeftOut(usize),
    /// A record is `Deploying` and no run holds the deploy lock for it, so a
    /// Kix without the lock may still be deploying it, and the plan leaves
    /// the leftovers of failed deploys alone.
    DeployInFlight(&'a Record),
    /// The build of a `Failed` or `Partial` record was folded into the plan.
    FailedFolded(&'a Record),
    /// The plan takes in a `Failed` or `Partial` record from its revisions,
    /// and its build is not on this machine. The package diff cannot tell
    /// which live values that deploy wrote, so it lists them as drift.
    FailedValuesUnknown(&'a Record),
    /// A rollback's current build failed to load or did not match the record,
    /// so the rollback compares against an empty build.
    ActiveBuildUnusable {
        activation: &'a str,
        error: &'a str,
        cluster: &'a str,
    },
    /// A rollback's current record has no identity hash, so its build cannot
    /// be looked up or recorded for later pruning.
    ActiveWithoutHash {
        activation: &'a str,
        cluster: &'a str,
    },
    /// A rollback's current build is not on this machine, so the rollback
    /// compares against an empty build.
    ActiveUnresolved {
        record: &'a Record,
        cluster: &'a str,
    },
    /// A failed deploy's build failed to load, so the plan omits what that
    /// deploy applied.
    FailedBuildUnusable { activation: &'a str, error: &'a str },
    /// Failed deploys whose builds are not on this machine and were not read
    /// from the cluster.
    FailedUnresolved {
        records: &'a [Record],
        cluster: &'a str,
    },
    /// Builds from which an earlier deploy kept orphans that were folded into
    /// the plan.
    KeptFolded(&'a [KeptOrphanSource]),
    /// A build from which an earlier deploy kept orphans failed to load, so
    /// the package diff cannot show those orphans.
    KeptBuildUnusable { activation: &'a str, error: &'a str },
    /// Objects the build leaves unchanged that are absent from the cluster
    /// or being deleted. The plan writes them again.
    NotHeld(&'a [ResourceId]),
}

/// Why a plan could not be made.
#[derive(Debug, thiserror::Error)]
pub enum PlanError {
    #[error("failed to connect to cluster: {0}")]
    Connect(Box<FetchError>),
    /// A revision of the build would be too large to store on the cluster.
    #[error("{0}")]
    RevisionTooLarge(Box<crate::cluster::revision::TooLarge>),
    /// The records an older Kix wrote cannot be given revisions.
    #[error("{0}")]
    Conversion(Box<crate::cluster::revision::convert::Refusal>),
    /// The build is bound to another Kubernetes cluster, names none while
    /// this one accepts only builds that name it, or would deploy a cluster
    /// that Kix 0.6 named `cluster` under a new name.
    #[error("{0}")]
    Binding(Box<crate::cluster::binding::BindingError>),
    /// The build was checked against a Kubernetes version this cluster
    /// does not run.
    #[error("{0}")]
    KubernetesVersion(Box<crate::cluster::kubernetes_version::VersionError>),
    #[error("{0}")]
    Discovery(Box<FetchError>),
    #[error("{0}")]
    Domain(LegacyDomainError),
    #[error(
        "cannot reconstruct the previous state from the cluster: {0}. \
         Refusing to plan from a partial view; retry when the apiserver is healthy."
    )]
    Reconstruct(String),
    #[error(
        "cannot read cluster resources from an earlier unfinished deploy: {0}. \
         Nothing was planned or applied to the cluster. Check your cluster connection and \
         permissions, or wait for the Kubernetes API server to recover, then run the command again."
    )]
    FoldedLeftovers(Box<FetchError>),
    /// Kix could not read part of what says which objects this Kix
    /// cluster's records deploy, so it cannot tell which objects are
    /// orphans.
    #[error(
        "{0}. Nothing was planned or applied to the cluster, because Kix cannot tell which objects earlier deploys left"
    )]
    Tenancy(Box<crate::cluster::tenancy::Problem>),
    #[error("cannot read which objects each Kix cluster deploys: {0}")]
    ReadTenancy(Box<crate::cluster::activation::RecordsError>),
    #[error("cannot check whether another Kix cluster deploys an orphan: {0}")]
    SharedOrphans(Box<FetchError>),
    #[error(
        "cannot check whether candidate resources belong to an unfinished deploy: {0}. \
         Nothing was deleted. Check your cluster connection and permissions, or wait for the \
         Kubernetes API server to recover, then run the command again."
    )]
    HeldObjects(Box<FetchError>),
    #[error(
        "cannot read live resources on the cluster: {0}. \
         Nothing was planned or applied to the cluster. \
         Check your cluster connection and credentials, or wait for the Kubernetes API server \
         to recover, then run the command again."
    )]
    ReadLive(Box<FetchError>),
    /// This account may neither list nor get objects the plan must read.
    #[error("{0}. Nothing was planned or applied to the cluster")]
    ReadForbidden(Box<crate::cluster::inventory::ReadForbidden>),
    #[error(
        "cannot read the deploy lock (`ActivationHead`) for this Kix cluster: {}. \
         Nothing was planned or applied to the cluster. \
         Check your cluster connection and permissions on `{}`, \
         or wait for the Kubernetes API server to recover, then run the command again.",
        crate::cluster::errors::describe(.0.as_ref()),
        crate::cluster::head::crd_name()
    )]
    ReadHead(Box<kube::Error>),
    #[error("{0}")]
    Lock(Box<crate::cluster::head::TakeError>),
    #[error("{0}")]
    Graph(GraphError),
    #[error("{0}")]
    Marker(MalformedMarker),
    #[error("{0}")]
    Unshown(objects::Unshown),
    /// The plan `kix deploy --offline` made again from the live cluster
    /// differs from the plan the person confirmed.
    #[error("{0}")]
    OfflinePlanDiffers(Box<offline::OfflinePlanDiffers>),
    #[error(
        "[K8031] cannot move {}: Kubernetes stores both API groups as the same object, \
         so applying the new group and deleting from the old group deletes that object \
         from the cluster. Nothing was planned or applied to the cluster. \
         Next: keep the current apiVersion, or first deploy a build without the object \
         using `kix deploy --prune` and then deploy a build with the new apiVersion.",
        .0.join(", ")
    )]
    AliasedMove(Vec<String>),
    #[error(
        "cannot use `--only` on Kix cluster '{0}' because it has not been deployed in full yet. \
         Nothing was planned or applied to the cluster. A `--only` deploy updates selected \
         instances on top of an active deployment, and '{0}' has no active deployment record on \
         the cluster. Next: deploy the full build first with `kix deploy {0}`, then use `--only` \
         for later updates."
    )]
    OnlyFirstDeploy(String),
    /// A record of the Kix cluster is driven by a Kix operator older than
    /// this Kix.
    #[error(transparent)]
    OperatorWithoutRevisions(Box<crate::cluster::activation::features::OperatorWithoutRevisions>),
    #[error(transparent)]
    OperatorFeatures(Box<crate::cluster::activation::features::FeaturesCheckError>),
    #[error(
        "could not take Kix cluster '{cluster}' back from the Kix operator: {source}. Nothing else was changed on the cluster. Next: run the command again."
    )]
    TakeBack {
        cluster: String,
        source: Box<crate::cluster::activation::features::TakeBackError>,
    },
    #[error(
        "cannot use `--only` on Kix cluster '{cluster}' because its active deployment ({record}) \
         is managed by the Kix operator. Nothing was planned or applied to the cluster. The \
         operator reconciles {record} to match its build, so it would revert changes from `--only` \
         and delete any new resources it creates. Next: deploy the full build with \
         `kix deploy {cluster} --operator`, or take the cluster over from this machine with \
         `kix deploy {cluster}`. If the operator is older than this Kix, upgrade it first; if it \
         was uninstalled, run `kix deploy {cluster} --operator-removed` instead."
    )]
    OnlyUnderOperator { cluster: String, record: String },
    #[error("{0}")]
    UnknownInstances(UnknownInstances),
}

/// Instances that `--only` names and the build does not have.
#[derive(Debug)]
pub struct UnknownInstances {
    pub cluster: String,
    /// The names given that match no instance, as given.
    pub unknown: Vec<String>,
    /// The instances of the build (`namespace/instance`), sorted.
    pub valid: Vec<String>,
}

/// How many instance names an [`UnknownInstances`] error lists.
const LISTED_INSTANCES: usize = 20;

impl std::fmt::Display for UnknownInstances {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let unknown: Vec<String> = self
            .unknown
            .iter()
            .map(|n| format!("'{}'", crate::text::printable_up_to(n, 200)))
            .collect();
        let noun = if unknown.len() == 1 {
            "package instance"
        } else {
            "package instances"
        };
        writeln!(
            f,
            "Kix cluster '{}' has no {noun} {}. Nothing was planned or applied to the cluster.",
            self.cluster,
            unknown.join(", ")
        )?;
        for name in self.unknown.iter().filter(|n| !n.contains('/')) {
            let matches: Vec<&str> = self
                .valid
                .iter()
                .filter(|v| {
                    v.split_once('/')
                        .is_some_and(|(_, instance)| instance == name)
                })
                .map(String::as_str)
                .collect();
            if !matches.is_empty() {
                writeln!(f, "  Did you mean {}?", matches.join(" or "))?;
            }
        }
        writeln!(
            f,
            "  Pass each instance to `--only` as `<namespace>/<instance>` (the format shown in `kix plan`)."
        )?;
        let listed = closest(&self.unknown, &self.valid, LISTED_INSTANCES);
        if listed.is_empty() {
            return write!(f, "  This cluster build defines no package instances.");
        }
        if listed.len() < self.valid.len() {
            writeln!(
                f,
                "  Closest matches among the build's {} instances:",
                self.valid.len()
            )?;
        } else {
            writeln!(f, "  Available instances in this build:")?;
        }
        let lines: Vec<String> = listed.iter().map(|n| format!("    {n}")).collect();
        write!(f, "{}", lines.join("\n"))
    }
}

/// Return up to `max` of `valid`, all of them when they fit, else the ones
/// that share the longest start with any of `given`, in `valid`'s order.
fn closest<'a>(given: &[String], valid: &'a [String], max: usize) -> Vec<&'a str> {
    if valid.len() <= max {
        return valid.iter().map(String::as_str).collect();
    }
    let shared = |name: &str| {
        given
            .iter()
            .map(|g| {
                g.chars()
                    .zip(name.chars())
                    .take_while(|(a, b)| a == b)
                    .count()
            })
            .max()
            .unwrap_or(0)
    };
    let mut ranked: Vec<(usize, usize)> = valid
        .iter()
        .enumerate()
        .map(|(i, name)| (shared(name), i))
        .collect();
    ranked.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let mut picked: Vec<usize> = ranked.into_iter().take(max).map(|(_, i)| i).collect();
    picked.sort();
    picked.into_iter().map(|i| valid[i].as_str()).collect()
}

pub struct PackageDiff {
    pub added: Vec<PackageInfo>,
    pub removed: Vec<PackageInfo>,
    pub changed: Vec<PackageChangeDiff>,
    pub unchanged: usize,
    /// Resources outside any package (Namespaces, CRDs, and cluster-scoped
    /// bundles) that differ. Keyed `_cluster` with empty versions.
    pub cluster_level: Option<PackageChangeDiff>,
    /// Deploy record rotation from old to new. `None` when both sides name
    /// the same record.
    pub activation: Option<RecordChange>,
    /// Whether `labels` was computed via a three-way comparison with the
    /// deployed build. Without it, no field change carries a label.
    pub labelled: bool,
    /// For each modified resource, one label list per entry of its
    /// `resource_diffs`, in order.
    pub labels: HashMap<ResourceId, Vec<Vec<origin::ChangeLabel>>>,
    /// Objects that the diff shows a deploy writing and deleting, as
    /// computed by [`diff_graphs`]. [`objects::of`] verifies the deploy plan
    /// against this set.
    pub shown: Shown,
}

/// Objects that a [`PackageDiff`] shows a deploy writing and deleting, paired
/// with the package key under which each is listed.
#[derive(Clone, Debug, Default)]
pub struct Shown {
    /// Each new-side object listed as added, modified, or dep-affected, plus
    /// the new Activation record, keyed by resource ID and store hash.
    pub writes: BTreeMap<(ResourceId, String), (String, document::WriteChange)>,
    /// Each old-side object listed as removed, excluding kept resources.
    pub deletes: BTreeMap<ResourceId, String>,
}

impl Shown {
    /// Record the new side of `c`'s added, modified, and dep-affected
    /// resources, found in `objects`, and its removed ones.
    pub(super) fn change(
        &mut self,
        c: &PackageChangeDiff,
        objects: &BTreeMap<ResourceId, (&PathBuf, &Value)>,
    ) {
        use document::WriteChange;
        let ids = c
            .added_resources
            .iter()
            .map(|id| (id, WriteChange::Added))
            .chain(
                c.resource_diffs
                    .iter()
                    .map(|(id, _)| (id, WriteChange::Modified)),
            )
            .chain(
                c.dep_affected_resources
                    .iter()
                    .map(|id| (id, WriteChange::DepAffected)),
            );
        for (id, change) in ids {
            if let Some((path, _)) = objects.get(id) {
                self.write(id, path, &c.key, change);
            }
        }
        for id in c.removed_and_kept().0 {
            self.deletes.insert(id.clone(), c.key.clone());
        }
    }

    pub(super) fn write(
        &mut self,
        id: &ResourceId,
        path: &Path,
        key: &str,
        change: document::WriteChange,
    ) {
        self.writes.insert(
            (id.clone(), crate::eval::store_graph::store_hash(path)),
            (key.to_string(), change),
        );
    }
}

/// Old and new deploy record names. Either side may be absent on a first
/// deploy or when the old side carries no record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordChange {
    pub old: Option<String>,
    pub new: Option<String>,
}

impl PackageDiff {
    /// Return each object this diff deletes in one API group and writes in
    /// another group that stores the same objects ([`kinds::ALIASED`]), as
    /// `"<old> to <new>"`, sorted.
    pub fn aliased_moves(&self) -> Vec<String> {
        let mut written: HashMap<(&str, &str), Vec<&ResourceId>> = HashMap::new();
        for (id, _) in self.shown.writes.keys() {
            written
                .entry((id.namespace.as_str(), id.name.as_str()))
                .or_default()
                .push(id);
        }
        let mut moves: Vec<String> = self
            .shown
            .deletes
            .keys()
            .flat_map(|old| {
                written
                    .get(&(old.namespace.as_str(), old.name.as_str()))
                    .into_iter()
                    .flatten()
                    .filter(|new| kinds::aliased(old.group_kind(), new.group_kind()))
                    .map(move |new| format!("{old} to {new}"))
            })
            .collect();
        moves.sort();
        moves
    }

    /// Return true when there is any change to report.
    pub fn has_changes(&self) -> bool {
        !self.added.is_empty()
            || !self.removed.is_empty()
            || !self.changed.is_empty()
            || self.cluster_level.is_some()
            || self.activation.is_some()
    }

    /// Move orphans that another Kix cluster's current build still contains
    /// from removed to kept so pruning preserves them.
    pub fn keep_shared(&mut self, shared: &[crate::cluster::inventory::SharedOrphan]) {
        let ids: std::collections::HashSet<&ResourceId> = shared.iter().map(|s| &s.rid).collect();
        for p in &mut self.removed {
            let more: Vec<ResourceId> = p
                .resources
                .iter()
                .filter(|id| ids.contains(id) && !p.kept.contains(id))
                .cloned()
                .collect();
            p.kept.extend(more);
        }
        for c in self.changed.iter_mut().chain(self.cluster_level.iter_mut()) {
            let (kept, removed) = std::mem::take(&mut c.removed_resources)
                .into_iter()
                .partition(|id| ids.contains(id));
            c.removed_resources = removed;
            c.shared_kept.extend(kept);
        }
        self.shown.deletes.retain(|id, _| !ids.contains(id));
    }

    /// Keep only the writes of the objects in `ids`, for a deploy with
    /// `--only` that writes nothing else. Removed packages and removed
    /// objects go, since such a deploy deletes nothing, and so does the
    /// record rotation, since its record does not become current.
    pub(crate) fn retain_objects(&mut self, ids: &std::collections::HashSet<ResourceId>) {
        self.shown.writes.retain(|(id, _), _| ids.contains(id));
        self.shown.deletes.clear();
        // An added package lists no objects, so its writes in `shown` say
        // how many of its objects the deploy writes.
        let mut written: HashMap<&str, usize> = HashMap::new();
        for (key, _) in self.shown.writes.values() {
            *written.entry(key.as_str()).or_default() += 1;
        }
        self.added
            .retain_mut(|p| match written.get(p.key.as_str()) {
                Some(&n) => {
                    p.resource_count = n;
                    true
                }
                None => false,
            });
        self.removed.clear();
        self.activation = None;
        let keep = |c: &mut PackageChangeDiff| {
            c.resource_diffs.retain(|(id, _)| ids.contains(id));
            c.dep_affected_resources.retain(|id| ids.contains(id));
            c.added_resources.retain(|id| ids.contains(id));
            c.removed_resources.clear();
            c.shared_kept.clear();
        };
        for c in &mut self.changed {
            keep(c);
        }
        self.changed.retain(PackageChangeDiff::any);
        if let Some(c) = &mut self.cluster_level {
            keep(c);
        }
        if !self
            .cluster_level
            .as_ref()
            .is_some_and(PackageChangeDiff::any)
        {
            self.cluster_level = None;
        }
        self.labels.retain(|id, _| ids.contains(id));
    }

    /// Return an iterator over changed packages plus the cluster-level
    /// pseudo-package.
    pub(crate) fn changed_with_cluster_level(&self) -> impl Iterator<Item = &PackageChangeDiff> {
        self.changed.iter().chain(self.cluster_level.iter())
    }

    /// Sum resource counts across `changed_with_cluster_level`. Each
    /// resource lands in one bucket.
    pub fn resource_totals(&self) -> ResourceTotals {
        let mut totals = ResourceTotals::default();
        for c in self.changed_with_cluster_level() {
            let (removed, kept) = c.removed_and_kept();
            totals.real_content += c.resource_diffs.len() + c.added_resources.len() + removed.len();
            totals.kept += kept.len();
            totals.dep_affected += c.dep_affected_resources.len();
        }
        totals
    }
}

/// Resource counts returned by [`PackageDiff::resource_totals`].
#[derive(Default)]
pub struct ResourceTotals {
    /// Modified, added, and removed resources that deploy or `kix gc` deletes.
    pub real_content: usize,
    /// Resources that left the build but are protected by
    /// `lifecycle::never_pruned` or shared with another cluster.
    pub kept: usize,
    /// Resources whose only change is a propagated hash.
    pub dep_affected: usize,
}

impl ResourceTotals {
    /// Return true when at least one resource was counted.
    pub fn any(&self) -> bool {
        self.real_content > 0 || self.kept > 0 || self.dep_affected > 0
    }
}

#[derive(Clone)]
pub struct PackageInfo {
    pub key: String, // ns/name
    pub version: Option<String>,
    pub resource_count: usize,
    /// For a removed package, the resources that remain on the cluster: kinds
    /// protected by `lifecycle::never_pruned` plus any added by
    /// [`PackageDiff::keep_shared`]. Counted in `resource_count`. Empty for
    /// an added package.
    pub kept: Vec<ResourceId>,
    /// For a removed package, every resource it had. Empty for an added package.
    pub resources: Vec<ResourceId>,
}

impl PackageInfo {
    pub(super) fn removed(key: &str, pkg: &PackageNode, graph: &StoreGraph) -> Self {
        let resources: Vec<ResourceId> = pkg
            .resource_paths
            .iter()
            .filter_map(|p| graph.resources.get(p))
            .map(|node| ResourceId::from_value(&node.manifest))
            .collect();
        let kept = resources
            .iter()
            .filter(|rid| lifecycle::never_pruned(rid.group_kind()))
            .cloned()
            .collect();
        PackageInfo {
            key: key.to_string(),
            version: pkg.version.clone(),
            resource_count: pkg.resource_paths.len(),
            kept,
            resources,
        }
    }
}

pub struct PackageChangeDiff {
    pub key: String,
    pub old_version: Option<String>,
    pub new_version: Option<String>,
    /// Resources with actual manifest field changes (propagation-only diffs filtered out).
    /// Only contains the real (non-propagation) differences.
    pub resource_diffs: Vec<(ResourceId, Vec<Difference>)>,
    /// Resources whose identity-hash changed purely because a dependency's hash
    /// propagated up (via `kix.run/identity-hash`/`kix.run/depends-on`/`kix.run/activations`/
    /// `kix.run/built-via`). Manifest content is otherwise identical and redeploys
    /// only to update stamped annotations.
    pub dep_affected_resources: Vec<ResourceId>,
    pub added_resources: Vec<ResourceId>,
    pub removed_resources: Vec<ResourceId>,
    /// Resources that left the build and that another Kix cluster's current
    /// build still contains, moved here from `removed_resources` by
    /// `PackageDiff::keep_shared`.
    pub shared_kept: Vec<ResourceId>,
}

impl PackageChangeDiff {
    /// Return true when any resource was added, removed, modified, or dep-affected.
    pub(super) fn any(&self) -> bool {
        !self.resource_diffs.is_empty()
            || !self.dep_affected_resources.is_empty()
            || !self.added_resources.is_empty()
            || !self.removed_resources.is_empty()
    }

    /// Split `removed_resources` into `(removed, kept)`. `kept` holds the
    /// kinds protected by `lifecycle::never_pruned` followed by `shared_kept`.
    /// Because deploy and `kix gc` never delete kept resources, renderers do
    /// not show them as deletions.
    pub fn removed_and_kept(&self) -> (Vec<&ResourceId>, Vec<&ResourceId>) {
        let (removed, mut kept): (Vec<&ResourceId>, Vec<&ResourceId>) = self
            .removed_resources
            .iter()
            .partition(|id| !lifecycle::never_pruned(id.group_kind()));
        kept.extend(&self.shared_kept);
        (removed, kept)
    }
}

/// Key of the cluster-level pseudo-package in renderers.
pub const CLUSTER_LEVEL_KEY: &str = "_cluster";

/// Split resources that left the build into `(delete, kept)`, keeping each
/// list's order. `kept` holds the kinds `lifecycle::never_pruned` protects,
/// which deploy's prune and `kix gc` report but never delete.
pub fn split_never_pruned(rids: Vec<ResourceId>) -> (Vec<ResourceId>, Vec<ResourceId>) {
    let (kept, delete) = rids
        .into_iter()
        .partition(|rid| lifecycle::never_pruned(rid.group_kind()));
    (delete, kept)
}
