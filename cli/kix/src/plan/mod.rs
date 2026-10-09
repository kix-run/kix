//! What a deploy of a build would change, as people review it.
//!
//! [`Planner`] makes the plan of a deploy from a build and what the cluster
//! runs ([`baseline`]). [`diff_graphs`] compares two builds package by
//! package into a [`PackageDiff`]; [`document::Plan`] is the typed document
//! `kix plan` and `kix diff` emit; [`objects`] holds a deploy to the objects
//! the diff shows; [`saved`] compares a plan made now with a reviewed one.
//! [`live`] is the operator's plan, made from the live objects.
//! Turning any of these into text is the caller's job.

pub mod baseline;
pub mod document;
#[cfg(any(test, feature = "test-util"))]
pub mod fixtures;
pub mod live;
pub mod objects;
pub mod origin;
#[cfg(test)]
mod plan_bound_properties;
#[cfg(test)]
mod plan_bound_tests;
mod planner;
pub mod saved;
pub mod server;

pub use planner::{CheckedPlan, OldSide, Planned, Planner, Target, keep_shared};

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::cluster::activation::{KeptOrphanSource, Record};
use crate::cluster::fetch::FetchError;
use crate::cluster::graph::GraphError;
use crate::cluster::readiness::MalformedMarker;
use crate::eval::PackageNode;
use crate::eval::store_graph::StoreGraph;
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::diff::engine::structural_diff;
use crate::manifest::diff::{DiffConfig, Difference};
use crate::manifest::keys;
use crate::manifest::lifecycle;
use crate::manifest::types::{self, ResourceId};

/// What the planner found, as it goes, for the caller to show.
#[derive(Debug, Clone, Copy)]
pub enum PlanEvent<'a> {
    /// Connecting to the cluster, before anything is read.
    Connecting,
    /// `--current-activation` found no cached build: a first deploy.
    NoCachedBuild,
    /// `--current-activation` is loading the cached build.
    LoadingCache,
    /// The cluster has no Active record for the cluster: a first deploy.
    NoActiveRecord,
    /// The Active record the plan compares against.
    Active {
        name: &'a str,
        identity_hash: &'a str,
    },
    /// The Active record's build is not on this machine (`error` is `None`)
    /// or will not load, so the plan reads its objects from the cluster.
    ReadingLive { error: Option<&'a str> },
    /// Objects of this cluster that name only older builds, which the plan
    /// read from the cluster leaves out.
    OlderBuildsLeftOut(usize),
    /// Another deploy of the cluster may still be running, so the plan
    /// leaves the leftovers of failed deploys alone.
    DeployInFlight(&'a Record),
    /// A failed deploy's build is in the plan.
    FailedFolded(&'a Record),
    /// A rollback's current build was found but will not load, or is not
    /// the record's; the rollback compares with no current build.
    ActiveBuildUnusable { activation: &'a str, error: &'a str },
    /// A failed deploy's build was found but will not load; the plan leaves
    /// out what that deploy applied.
    FailedBuildUnusable { activation: &'a str, error: &'a str },
    /// A failed deploy's build is not on this machine.
    FailedUnresolved {
        record: &'a Record,
        cluster: &'a str,
    },
    /// The builds an earlier deploy kept orphans from that are in the plan.
    KeptFolded(&'a [KeptOrphanSource]),
    /// A build an earlier deploy kept orphans from was found but will not
    /// load; the plan cannot list or delete those orphans.
    KeptBuildUnusable { activation: &'a str, error: &'a str },
    /// A build an earlier deploy kept orphans from is not on this machine.
    KeptUnresolved {
        source: &'a KeptOrphanSource,
        cluster: &'a str,
    },
}

/// Why a plan could not be made.
#[derive(Debug, thiserror::Error)]
pub enum PlanError {
    #[error("failed to connect to cluster: {0}")]
    Connect(Box<FetchError>),
    #[error("{0}")]
    Discovery(Box<FetchError>),
    #[error("{0}")]
    Domain(LegacyDomainError),
    #[error(
        "cannot reconstruct the previous state from the cluster: {0}. \
         Refusing to plan from a partial view; retry when the apiserver is healthy."
    )]
    Reconstruct(String),
    #[error("cannot check whether another Kix cluster deploys an orphan: {0}")]
    SharedOrphans(Box<FetchError>),
    #[error("{0}")]
    Graph(GraphError),
    #[error("{0}")]
    Marker(MalformedMarker),
    #[error("{0}")]
    Unshown(objects::Unshown),
}

pub struct PackageDiff {
    pub added: Vec<PackageInfo>,
    pub removed: Vec<PackageInfo>,
    pub changed: Vec<PackageChangeDiff>,
    pub unchanged: usize,
    /// Resources outside any package (Namespaces, CRDs, cluster-scoped
    /// bundles) that differ. Keyed `_cluster`, versions empty.
    pub cluster_level: Option<PackageChangeDiff>,
    /// The deploy record rotates whenever anything changed; one line, not a
    /// create plus a delete. `None` when both sides name the same record.
    pub activation: Option<RecordChange>,
    /// Whether `labels` was computed: a three-way comparison with the
    /// deployed build. Without it no field change carries a label.
    pub labelled: bool,
    /// For each modified resource, one label list per entry of its
    /// `resource_diffs`, in order.
    pub labels: HashMap<ResourceId, Vec<Vec<origin::ChangeLabel>>>,
    /// The objects the lists above show a deploy writing and deleting, as
    /// [`diff_graphs`] made them. [`objects::of`] holds a deploy to them.
    pub shown: Shown,
}

/// The objects a [`PackageDiff`] shows a deploy writing and deleting, each
/// with the package key it is listed under.
#[derive(Clone, Debug, Default)]
pub struct Shown {
    /// Each new-side object listed as added, modified, or dep-affected, and
    /// the new Activation record, by its id and the store hash of its file.
    pub writes: BTreeMap<(ResourceId, String), (String, document::WriteChange)>,
    /// Each old-side object listed as removed, kept ones aside.
    pub deletes: BTreeMap<ResourceId, String>,
}

impl Shown {
    /// Record the new side of `c`'s added, modified, and dep-affected
    /// resources, found in `objects`, and its removed ones.
    fn change(
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

    fn write(&mut self, id: &ResourceId, path: &Path, key: &str, change: document::WriteChange) {
        self.writes.insert(
            (id.clone(), crate::eval::store_graph::store_hash(path)),
            (key.to_string(), change),
        );
    }
}

/// Old and new deploy record names; either side may be absent (first
/// deploy, or an old side that carries no record).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordChange {
    pub old: Option<String>,
    pub new: Option<String>,
}

impl PackageDiff {
    /// Anything at all to report.
    pub fn has_changes(&self) -> bool {
        !self.added.is_empty()
            || !self.removed.is_empty()
            || !self.changed.is_empty()
            || self.cluster_level.is_some()
            || self.activation.is_some()
    }

    /// Show the orphans another Kix cluster's current build still contains
    /// as kept rather than removed: the prune keeps them.
    pub fn keep_shared(&mut self, shared: &[crate::cluster::fetch::SharedOrphan]) {
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

    /// Changed packages plus the cluster-level pseudo-package, for renderers
    /// that walk resource-level detail.
    pub fn changed_with_cluster_level(&self) -> impl Iterator<Item = &PackageChangeDiff> {
        self.changed.iter().chain(self.cluster_level.iter())
    }

    /// Resource counts summed over `changed_with_cluster_level`. Each
    /// resource lands in exactly one bucket.
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

/// See `PackageDiff::resource_totals`.
#[derive(Default)]
pub struct ResourceTotals {
    /// Modified, added, and removed resources that deploy or gc delete.
    pub real_content: usize,
    /// Resources that left the build but whose kind `lifecycle::never_pruned`
    /// protects.
    pub kept: usize,
    /// Resources whose only change is a propagated hash.
    pub dep_affected: usize,
}

impl ResourceTotals {
    /// Any resource counted at all.
    pub fn any(&self) -> bool {
        self.real_content > 0 || self.kept > 0 || self.dep_affected > 0
    }
}

#[derive(Clone)]
pub struct PackageInfo {
    pub key: String, // ns/name
    pub version: Option<String>,
    pub resource_count: usize,
    /// For a removed package, the resources that stay on the cluster: kinds
    /// `lifecycle::never_pruned` protects, and any `PackageDiff::keep_shared`
    /// adds. Counted in `resource_count`. Empty for an added package.
    pub kept: Vec<ResourceId>,
    /// For a removed package, every resource it had. Empty for an added one.
    pub resources: Vec<ResourceId>,
}

impl PackageInfo {
    fn removed(key: &str, pkg: &PackageNode, graph: &StoreGraph) -> Self {
        let resources: Vec<ResourceId> = pkg
            .resource_paths
            .iter()
            .filter_map(|p| graph.resources.get(p))
            .map(|node| ResourceId::from_value(&node.manifest))
            .collect();
        let kept = resources
            .iter()
            .filter(|rid| lifecycle::never_pruned(&rid.kind))
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
    /// The resources in `resource_diffs` that are Secrets (see
    /// `types::is_secret`) on either side. Renderers hide their values.
    pub secrets: BTreeSet<ResourceId>,
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
    /// Any resource added, removed, modified, or dep-affected.
    fn any(&self) -> bool {
        !self.resource_diffs.is_empty()
            || !self.dep_affected_resources.is_empty()
            || !self.added_resources.is_empty()
            || !self.removed_resources.is_empty()
    }

    /// `removed_resources` split into `(removed, kept)`. `kept` holds the
    /// kinds `lifecycle::never_pruned` protects, then `shared_kept`: they
    /// left the build, but deploy and `kix gc` do not delete them, so
    /// renderers do not show them as deletions.
    pub fn removed_and_kept(&self) -> (Vec<&ResourceId>, Vec<&ResourceId>) {
        let (removed, mut kept): (Vec<&ResourceId>, Vec<&ResourceId>) = self
            .removed_resources
            .iter()
            .partition(|id| !lifecycle::never_pruned(&id.kind));
        kept.extend(&self.shared_kept);
        (removed, kept)
    }
}

/// Returns true if a structural-diff path points at a kix.run stamped annotation
/// whose only purpose is to carry hash propagation (identity, deps, activations,
/// built-via). Used to distinguish real content changes from dependency-propagated
/// hash bumps.
fn is_propagation_path(path: &str) -> bool {
    const PROPAGATION_ANNS: &[&str] = &[
        keys::IDENTITY_HASH,
        keys::DEPENDS_ON,
        keys::ACTIVATIONS,
        keys::BUILT_VIA,
    ];
    // The same four under any retired domain: a diff against a cluster whose
    // objects predate a domain move shows both spellings, and the retired one
    // is propagation noise just as much as the current one.
    let legacy: Vec<String> = PROPAGATION_ANNS
        .iter()
        .flat_map(|k| crate::legacy_domain::legacy_spellings(k))
        .collect();
    // Match only top-level metadata.annotations. Pod template annotations
    // (e.g. $.spec.template.metadata.annotations.*) are real content changes.
    // The match is exact: the path joins keys with `.`, so a prefix would
    // also take an annotation such as `kix.run/identity-hash.x`, whose
    // change the plan would then not show.
    PROPAGATION_ANNS
        .iter()
        .map(|s| (*s).to_string())
        .chain(legacy)
        .any(|ann| path == format!("$.metadata.annotations.{ann}"))
}

/// Partition a set of differences into (real, propagation-only).
pub(crate) fn partition_propagation(diffs: Vec<Difference>) -> (Vec<Difference>, Vec<Difference>) {
    let mut real = Vec::new();
    let mut propagation = Vec::new();
    for d in diffs {
        if is_propagation_path(&d.path) {
            propagation.push(d);
        } else {
            real.push(d);
        }
    }
    (real, propagation)
}

pub fn diff_graphs(old: &StoreGraph, new: &StoreGraph) -> PackageDiff {
    let config = DiffConfig::new("old", "new").in_order();

    let old_pkgs: BTreeMap<String, &PackageNode> = old
        .packages
        .values()
        .map(|p| (format!("{}/{}", p.namespace, p.instance_name), p))
        .collect();
    let new_pkgs: BTreeMap<String, &PackageNode> = new
        .packages
        .values()
        .map(|p| (format!("{}/{}", p.namespace, p.instance_name), p))
        .collect();

    let mut added = Vec::new();
    let mut removed = Vec::new();
    let mut changed = Vec::new();
    let mut unchanged = 0usize;
    let mut shown = Shown::default();

    for (key, new_pkg) in &new_pkgs {
        let new_objects = objects_of_package(new_pkg, new);
        if let Some(old_pkg) = old_pkgs.get(key) {
            let same_resources = old_pkg.resource_paths == new_pkg.resource_paths;
            if same_resources && old_pkg.store_path == new_pkg.store_path {
                unchanged += 1;
                continue;
            }
            // A PackageInstance that changed alone is a change: the deploy
            // applies it.
            let change = diff_package_resources(key, old_pkg, new_pkg, old, new, &config);
            if same_resources && !change.any() {
                unchanged += 1;
                continue;
            }
            shown.change(&change, &new_objects);
            changed.push(change);
        } else {
            for (id, (path, _)) in &new_objects {
                shown.write(id, path, key, document::WriteChange::Added);
            }
            added.push(PackageInfo {
                key: key.clone(),
                version: new_pkg.version.clone(),
                resource_count: new_pkg.resource_paths.len(),
                kept: Vec::new(),
                resources: Vec::new(),
            });
        }
    }

    for (key, old_pkg) in &old_pkgs {
        if !new_pkgs.contains_key(key) {
            let info = PackageInfo::removed(key, old_pkg, old);
            for id in resource_map_for_package(old_pkg, old).into_keys() {
                if !info.kept.contains(&id) {
                    shown.deletes.insert(id, key.clone());
                }
            }
            removed.push(info);
        }
    }

    // Resources no package owns: real graphs keep Namespaces, CRDs and
    // the cluster-scoped bundles outside every PackageNode, and a
    // synthesized graph does the same for anything without a package
    // annotation. The deploy record is handled separately below.
    let cluster_level = {
        let old_res = unowned_resources(old);
        let new_res = unowned_resources(new);
        let d = diff_resource_maps(
            CLUSTER_LEVEL_KEY,
            None,
            None,
            &values_of(&old_res),
            &values_of(&new_res),
            &config,
        );
        d.any().then(|| {
            shown.change(&d, &new_res);
            d
        })
    };

    let old_record = record_name(old);
    let new_record = record_name(new);
    if old_record != new_record
        && let Some(name) = &new_record
    {
        for (path, node) in &new.resources {
            let m = &node.manifest;
            if m.get("kind")
                .and_then(Value::as_str)
                .is_some_and(lifecycle::is_record_kind)
                && m.pointer("/metadata/name").and_then(Value::as_str) == Some(name)
            {
                let id = ResourceId::from_value(m);
                shown.write(&id, path, CLUSTER_LEVEL_KEY, document::WriteChange::Added);
            }
        }
    }
    let activation = (old_record != new_record).then_some(RecordChange {
        old: old_record,
        new: new_record,
    });

    PackageDiff {
        added,
        removed,
        changed,
        unchanged,
        cluster_level,
        activation,
        labelled: false,
        labels: HashMap::new(),
        shown,
    }
}

/// Key of the cluster-level pseudo-package in renderers.
pub const CLUSTER_LEVEL_KEY: &str = "_cluster";

/// Resources in `graph.resources` that no package owns, minus the
/// PackageInstances (each belongs with its package, see
/// `resource_map_for_package`) and the deploy record.
fn unowned_resources(graph: &StoreGraph) -> BTreeMap<ResourceId, (&PathBuf, &Value)> {
    graph
        .resources
        .iter()
        .filter(|(path, _)| {
            !graph.resource_owner.contains_key(*path) && !graph.packages.contains_key(*path)
        })
        .map(|(path, node)| {
            (
                ResourceId::from_value(&node.manifest),
                (path, &node.manifest),
            )
        })
        .filter(|(id, _)| !lifecycle::is_record_kind(&id.kind))
        .collect()
}

/// The manifests of `objects`.
fn values_of<'a>(
    objects: &BTreeMap<ResourceId, (&'a PathBuf, &'a Value)>,
) -> BTreeMap<ResourceId, &'a Value> {
    objects
        .iter()
        .map(|(id, (_, m))| (id.clone(), *m))
        .collect()
}

/// Name of the deploy record in the graph, if it carries one.
fn record_name(graph: &StoreGraph) -> Option<String> {
    graph
        .resources
        .values()
        .map(|node| &node.manifest)
        .find(|m| {
            m.get("kind")
                .and_then(Value::as_str)
                .is_some_and(lifecycle::is_record_kind)
        })
        .and_then(|m| m.pointer("/metadata/name").and_then(Value::as_str))
        .map(str::to_string)
}

/// Diff resources within a changed package.
fn diff_package_resources(
    key: &str,
    old_pkg: &PackageNode,
    new_pkg: &PackageNode,
    old_graph: &StoreGraph,
    new_graph: &StoreGraph,
    config: &DiffConfig,
) -> PackageChangeDiff {
    diff_resource_maps(
        key,
        old_pkg.version.clone(),
        new_pkg.version.clone(),
        &resource_map_for_package(old_pkg, old_graph),
        &resource_map_for_package(new_pkg, new_graph),
        config,
    )
}

/// Diff two resource sets keyed by identity: content changes, propagation-
/// only bumps, additions, removals.
fn diff_resource_maps(
    key: &str,
    old_version: Option<String>,
    new_version: Option<String>,
    old_res: &BTreeMap<ResourceId, &Value>,
    new_res: &BTreeMap<ResourceId, &Value>,
    config: &DiffConfig,
) -> PackageChangeDiff {
    let mut resource_diffs = Vec::new();
    let mut secrets = BTreeSet::new();
    let mut dep_affected_resources = Vec::new();
    let mut added_resources = Vec::new();
    let mut removed_resources = Vec::new();

    for (id, new_val) in new_res {
        if let Some(old_val) = old_res.get(id) {
            // Old first: `config` labels side a "old" and side b "new",
            // and the whole report reads as what a deploy would change.
            let diffs = structural_diff(old_val, new_val, "$", config);
            if diffs.is_empty() {
                continue;
            }
            let (real, _propagation) = partition_propagation(diffs);
            if real.is_empty() {
                // Only kix.run propagation annotations changed. The identity hash
                // bumped because a dependency changed, but content is the same.
                dep_affected_resources.push(id.clone());
            } else {
                if types::is_secret(old_val) || types::is_secret(new_val) {
                    secrets.insert(id.clone());
                }
                resource_diffs.push((id.clone(), real));
            }
        } else {
            added_resources.push(id.clone());
        }
    }

    for id in old_res.keys() {
        if !new_res.contains_key(id) {
            removed_resources.push(id.clone());
        }
    }

    PackageChangeDiff {
        key: key.to_string(),
        old_version,
        new_version,
        resource_diffs,
        secrets,
        dep_affected_resources,
        added_resources,
        removed_resources,
        shared_kept: Vec::new(),
    }
}

/// A package's resources plus its own PackageInstance (the graph keeps the
/// PI at the package's store path, outside `resource_paths`).
fn resource_map_for_package<'a>(
    pkg: &'a PackageNode,
    graph: &'a StoreGraph,
) -> BTreeMap<ResourceId, &'a Value> {
    values_of(&objects_of_package(pkg, graph))
}

/// [`resource_map_for_package`] with the store path of each manifest.
fn objects_of_package<'a>(
    pkg: &'a PackageNode,
    graph: &'a StoreGraph,
) -> BTreeMap<ResourceId, (&'a PathBuf, &'a Value)> {
    pkg.resource_paths
        .iter()
        .chain(std::iter::once(&pkg.store_path))
        .filter_map(|p| graph.resources.get_key_value(p))
        .map(|(path, node)| {
            (
                ResourceId::from_value(&node.manifest),
                (path, &node.manifest),
            )
        })
        .collect()
}

pub fn diff_garbage(old: &StoreGraph, new: &StoreGraph) -> PackageDiff {
    let old_pkgs: BTreeMap<String, &PackageNode> = old
        .packages
        .values()
        .map(|p| (format!("{}/{}", p.namespace, p.instance_name), p))
        .collect();
    let new_pkgs: BTreeMap<String, &PackageNode> = new
        .packages
        .values()
        .map(|p| (format!("{}/{}", p.namespace, p.instance_name), p))
        .collect();

    let mut removed = Vec::new();
    let mut changed = Vec::new();
    let mut unchanged = 0usize;

    for (key, old_pkg) in &old_pkgs {
        if !new_pkgs.contains_key(key) {
            removed.push(PackageInfo::removed(key, old_pkg, old));
        } else {
            let new_pkg = new_pkgs[key];
            if old_pkg.resource_paths == new_pkg.resource_paths {
                unchanged += 1;
                continue;
            }
            // Garbage collection only needs removed resources.
            let old_res = resource_map_for_package(old_pkg, old);
            let new_res = resource_map_for_package(new_pkg, new);
            let removed_resources: Vec<ResourceId> = old_res
                .keys()
                .filter(|id| !new_res.contains_key(id))
                .cloned()
                .collect();
            if !removed_resources.is_empty() {
                changed.push(PackageChangeDiff {
                    key: key.clone(),
                    old_version: old_pkg.version.clone(),
                    new_version: new_pkg.version.clone(),
                    resource_diffs: Vec::new(),
                    secrets: BTreeSet::new(),
                    dep_affected_resources: Vec::new(),
                    added_resources: Vec::new(),
                    removed_resources,
                    shared_kept: Vec::new(),
                });
            } else {
                unchanged += 1;
            }
        }
    }

    PackageDiff {
        added: Vec::new(),
        removed,
        changed,
        unchanged,
        cluster_level: None,
        activation: None,
        labelled: false,
        labels: HashMap::new(),
        shown: Shown::default(),
    }
}

/// The side of a diff a manifest comes from.
#[derive(Clone, Copy)]
pub enum Side {
    Old,
    New,
}

/// The old and new manifest of every resource a diff compared, by resource
/// id, for `--detail manifests`. Built from the two graphs; `kix plan`
/// replaces each object the apiserver answered with the live object and the
/// dry-run result ([`ManifestIndex::answered`]).
pub struct ManifestIndex<'a> {
    old_graph: &'a StoreGraph,
    new_graph: &'a StoreGraph,
    old: HashMap<ResourceId, Value>,
    new: HashMap<ResourceId, Value>,
}

impl<'a> ManifestIndex<'a> {
    pub fn new(old_graph: &'a StoreGraph, new_graph: &'a StoreGraph) -> Self {
        let index = |g: &StoreGraph| {
            g.resources
                .values()
                .map(|node| {
                    (
                        ResourceId::from_value(&node.manifest),
                        node.manifest.clone(),
                    )
                })
                .collect()
        };
        Self {
            old_graph,
            new_graph,
            old: index(old_graph),
            new: index(new_graph),
        }
    }

    /// Show `live` as the old side of `rid` and `result` as the new side,
    /// each side absent when `None`.
    pub fn answered(&mut self, rid: &ResourceId, live: Option<Value>, result: Option<Value>) {
        for (side, value) in [(&mut self.old, live), (&mut self.new, result)] {
            match value {
                Some(v) => side.insert(rid.clone(), v),
                None => side.remove(rid),
            };
        }
    }

    /// The resources of the package `key` (`namespace/name`) on one side,
    /// its PackageInstance included.
    pub fn package_resources(&self, key: &str, side: Side) -> Vec<ResourceId> {
        let graph = match side {
            Side::Old => self.old_graph,
            Side::New => self.new_graph,
        };
        graph
            .packages
            .values()
            .find(|p| format!("{}/{}", p.namespace, p.instance_name) == key)
            .map(|p| resource_map_for_package(p, graph).into_keys().collect())
            .unwrap_or_default()
    }

    /// The old and new manifest of each of `ids`, each side present when
    /// that side holds the resource.
    pub fn render<'i>(
        &self,
        ids: impl IntoIterator<Item = &'i ResourceId>,
    ) -> BTreeMap<String, document::ManifestSides> {
        ids.into_iter()
            .map(|id| {
                let old = self.old.get(id);
                let new = self.new.get(id);
                let is_secret =
                    old.is_some_and(types::is_secret) || new.is_some_and(types::is_secret);
                let sides = document::ManifestSides {
                    old: old.map(|o| shown_manifest(is_secret, o, None)),
                    new: new.map(|n| shown_manifest(is_secret, n, old)),
                };
                (id.display_id(), sides)
            })
            .collect()
    }
}

/// Stands in for a value the JSON diff leaves out because it is secret: a
/// Secret's `data` and `stringData` values, a Secret's
/// `kix.run/content-hash` and `kix.run/applied-hash`, and every
/// `checksum/*` annotation (Helm charts put a hash of a Secret there, and a
/// hash of a weak secret can be brute-forced).
pub const SECRET_NOT_SHOWN: &str = "(secret, not shown)";

/// Stands in for a secret value on the new side when the old side has a
/// different value at the same path, so a line diff of the two manifests
/// still shows the line as changed.
pub const SECRET_CHANGED_NOT_SHOWN: &str = "(secret, changed, not shown)";

/// A manifest larger than this, serialized, is left out of the JSON diff
/// at `--detail manifests`.
pub const MAX_SHOWN_MANIFEST_BYTES: usize = 256 * 1024;

/// A value larger than this, serialized, is left out of the JSON diff, so
/// a changed CRD schema or a large ConfigMap file does not swell a plan
/// that CI uploads.
pub const MAX_SHOWN_VALUE_BYTES: usize = 16 * 1024;

/// A whole manifest, hidden and capped as [`shown_value`] does, at
/// [`MAX_SHOWN_MANIFEST_BYTES`].
fn shown_manifest(is_secret: bool, manifest: &Value, old: Option<&Value>) -> Value {
    shown_value(is_secret, "$", manifest, old, MAX_SHOWN_MANIFEST_BYTES)
}

/// `value`, found at `path`, with every secret value in it hidden (see
/// [`hide_secrets`]), or a size note when it is larger than `max_bytes`.
/// `old` is the old side's value at the same path, given for a new value.
pub fn shown_value(
    is_secret: bool,
    path: &str,
    value: &Value,
    old: Option<&Value>,
    max_bytes: usize,
) -> Value {
    let mut value = value.clone();
    hide_secrets(is_secret, path, &mut value, old);
    let bytes = value.to_string().len();
    if bytes > max_bytes {
        return Value::String(format!("({bytes} bytes, not shown)"));
    }
    value
}

/// `d` with the values [`is_secret_path`] covers hidden, for the text plan.
/// Unlike the JSON it keeps large values, which the text diff prints line
/// by line.
pub fn without_secrets(is_secret: bool, d: &Difference) -> Difference {
    let mut d = d.clone();
    let old = d.a_value.clone();
    if let Some(value) = &mut d.a_value {
        hide_secrets(is_secret, &d.path, value, None);
    }
    if let Some(value) = &mut d.b_value {
        hide_secrets(is_secret, &d.path, value, old.as_ref());
    }
    d
}

/// Replace every secret value in `value` with [`SECRET_NOT_SHOWN`]. When
/// `old` (the old side's value at the same path) holds a different value
/// there, the replacement is [`SECRET_CHANGED_NOT_SHOWN`]. Array elements
/// are matched to `old` by position.
fn hide_secrets(is_secret: bool, path: &str, value: &mut Value, old: Option<&Value>) {
    if is_secret_path(is_secret, path) {
        let changed = old.is_some_and(|o| o != value);
        let marker = if changed {
            SECRET_CHANGED_NOT_SHOWN
        } else {
            SECRET_NOT_SHOWN
        };
        *value = Value::String(marker.into());
        return;
    }
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                let old_child = old.and_then(|o| o.get(key));
                hide_secrets(is_secret, &format!("{path}.{key}"), child, old_child);
            }
        }
        Value::Array(items) => {
            for (i, child) in items.iter_mut().enumerate() {
                let old_child = old.and_then(|o| o.get(i));
                hide_secrets(is_secret, &format!("{path}[{i}]"), child, old_child);
            }
        }
        _ => {}
    }
}

/// Whether the value at `path` is secret. Annotation keys contain dots and
/// slashes, and diff paths do not escape them, so a key is matched by its
/// prefix after `annotations.`.
///
/// On a Secret this covers `kubectl.kubernetes.io/last-applied-configuration`,
/// which holds the whole Secret as `kubectl apply` last sent it, and the
/// content and applied hashes under every domain Kix has stamped, since a
/// live object can still carry a retired spelling.
fn is_secret_path(is_secret: bool, path: &str) -> bool {
    if path.contains(".annotations.checksum/") {
        return true;
    }
    if !is_secret {
        return false;
    }
    let under = |field: &str| {
        path.starts_with(&format!("{field}.")) || path.starts_with(&format!("{field}["))
    };
    let Some(annotation) = path.strip_prefix("$.metadata.annotations.") else {
        return under("$.data") || under("$.stringData");
    };
    annotation == LAST_APPLIED
        || [keys::CONTENT_HASH, keys::APPLIED_HASH].iter().any(|k| {
            annotation == *k
                || crate::legacy_domain::legacy_spellings(k)
                    .iter()
                    .any(|l| annotation == l)
        })
}

/// The annotation `kubectl apply` keeps the whole applied object in.
const LAST_APPLIED: &str = "kubectl.kubernetes.io/last-applied-configuration";

/// Split resources that left the build into `(delete, kept)`, keeping each
/// list's order. `kept` holds the kinds `lifecycle::never_pruned` protects,
/// which deploy's prune and `kix gc` report but never delete.
pub fn split_never_pruned(rids: Vec<ResourceId>) -> (Vec<ResourceId>, Vec<ResourceId>) {
    let (kept, delete) = rids
        .into_iter()
        .partition(|rid| lifecycle::never_pruned(&rid.kind));
    (delete, kept)
}

#[cfg(test)]
mod diff_graph_tests {
    use super::fixtures::*;
    use super::*;
    use crate::manifest::keys;
    use serde_json::json;

    /// The `packages` section of the plan document for `diff`.
    fn packages_json(diff: &PackageDiff, detail: document::Detail) -> Value {
        serde_json::to_value(document::Packages::of(diff, detail)).expect("packages serialize")
    }

    /// An annotation whose key begins with a propagated one is content:
    /// the plan shows its change.
    #[test]
    fn an_annotation_named_after_a_propagated_one_is_a_real_change() {
        let path = |key: &str| format!("$.metadata.annotations.{key}");
        assert!(is_propagation_path(&path(keys::IDENTITY_HASH)));
        for key in [
            format!("{}.x", keys::IDENTITY_HASH),
            format!("{}.extra", keys::DEPENDS_ON),
        ] {
            assert!(!is_propagation_path(&path(&key)), "{key}");
        }
    }

    /// The reported difference has to read old-to-new: the value the
    /// cluster has now on the `old` side, the value the build wants on
    /// the `new` side. Rendering them the other way round tells the
    /// reader to expect the opposite of what a deploy would do.
    #[test]
    fn a_changed_value_is_reported_from_old_to_new() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        let d = diff_of(&baseline(), &new);

        let change = d
            .changed
            .iter()
            .find(|c| c.key == "app/web")
            .expect("web package changed");
        let (_, diffs) = change
            .resource_diffs
            .iter()
            .find(|(id, _)| id.kind == "ConfigMap")
            .expect("ConfigMap diff");
        let d0 = diffs.iter().find(|d| d.path == "$.spec.k").expect("spec.k");

        assert_eq!(
            d0.a_value.as_ref().and_then(|v| v.as_str()),
            Some("v"),
            "side a is labelled `old`, so it must carry what the old side had"
        );
        assert_eq!(
            d0.b_value.as_ref().and_then(|v| v.as_str()),
            Some("wanted"),
            "side b is labelled `new`, so it must carry what the build wants"
        );
    }

    /// A field only the build has is an addition, not a removal.
    #[test]
    fn a_field_only_the_new_side_has_is_an_addition() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "v", "added": "yes"}),
        );
        let d = diff_of(&baseline(), &new);
        let change = d.changed.iter().find(|c| c.key == "app/web").unwrap();
        let (_, diffs) = change
            .resource_diffs
            .iter()
            .find(|(id, _)| id.kind == "ConfigMap")
            .unwrap();
        let d0 = diffs
            .iter()
            .find(|d| d.path == "$.spec.added")
            .expect("spec.added");
        assert_eq!(
            d0.kind,
            crate::manifest::diff::DiffKind::ExtraInB,
            "a field the build adds must read as extra on the new side"
        );
    }

    /// The spellings `kix diff` reported on a converged kind cluster when
    /// the live objects carried no applied-hash stamp to compare by: a
    /// package whose live objects differ from its build only in them reads
    /// unchanged.
    #[test]
    fn server_spellings_of_the_built_objects_read_unchanged() {
        let pod = |live: bool| {
            let mut container = json!({
                "name": "app",
                "image": "app:1",
                "env": [{"name": "POD", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}}],
                "resources": {"limits": {"cpu": 1}},
                "readinessProbe": {"httpGet": {"path": "/"}, "failureThreshold": null},
                "volumeMounts": [{"name": "s", "mountPath": "/s", "readOnly": false}],
                "envFrom": [],
            });
            if live {
                container["env"][0]["valueFrom"]["fieldRef"]["apiVersion"] = json!("v1");
                container["resources"]["limits"]["cpu"] = json!("1");
                container["readinessProbe"]["failureThreshold"] = json!(3);
                let c = container.as_object_mut().unwrap();
                c.remove("envFrom");
                c["volumeMounts"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("readOnly");
            }
            let mut template =
                json!({"metadata": {"annotations": null}, "spec": {"containers": [container]}});
            if live {
                template["metadata"] = json!({});
            }
            template
        };
        let claim = |live: bool| {
            let mut claim = json!({
                "metadata": {"name": "data"},
                "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "8Gi"}}},
            });
            if live {
                claim["apiVersion"] = json!("v1");
                claim["kind"] = json!("PersistentVolumeClaim");
                claim["spec"]["volumeMode"] = json!("Filesystem");
                claim["status"] = json!({"phase": "Pending"});
            }
            claim
        };
        let side = |live: bool| {
            vec![
                record("c-1", &h("rec")),
                package_instance("app", "web", "1.0.0", &h("pi")),
                stamped(
                    "StatefulSet",
                    "app",
                    "web",
                    ("app", "web"),
                    &h("sts"),
                    json!({"template": pod(live), "volumeClaimTemplates": [claim(live)]}),
                ),
            ]
        };
        // A build names each store path by the resource's identity hash,
        // which is how a live object finds the manifest it came from.
        let synthetic = StoreGraph::synthesize(&side(false), &StoreGraph::empty("c"));
        let rename = |p: &std::path::PathBuf| {
            let manifest = &synthetic.resources[p].manifest;
            let hash = keys::get(manifest, keys::IDENTITY_HASH).unwrap();
            std::path::PathBuf::from(format!("/nix/store/{hash}-k8s"))
        };
        let mut build = StoreGraph::empty("c");
        for (path, node) in &synthetic.resources {
            let mut node = node.clone();
            node.store_path = rename(path);
            build.resources.insert(rename(path), node);
        }
        for (path, owner) in &synthetic.resource_owner {
            build.resource_owner.insert(rename(path), rename(owner));
        }
        for (path, pkg) in &synthetic.packages {
            let mut pkg = pkg.clone();
            pkg.store_path = rename(path);
            pkg.resource_paths = pkg.resource_paths.iter().map(&rename).collect();
            build.packages.insert(rename(path), pkg);
        }
        let live = StoreGraph::synthesize(&side(true), &build);

        let d = diff_graphs(&live, &build);
        let changed: Vec<&str> = d.changed.iter().map(|c| c.key.as_str()).collect();
        assert!(!d.has_changes(), "unexpected changes: {changed:?}");
        assert_eq!(d.unchanged, 1);
    }

    #[test]
    fn identical_sides_have_nothing_to_report() {
        let d = diff_of(&baseline(), &baseline());
        assert!(!d.has_changes(), "unexpected changes");
        assert_eq!(d.unchanged, 1);
        assert_eq!(d.activation, None);
    }

    #[test]
    fn a_content_change_is_modified_and_its_dependants_are_dep_affected() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "v2"}),
        );
        // The Deployment only saw its dependency's hash move.
        new[4]["metadata"]["annotations"][keys::DEPENDS_ON] = json!(h("cm2"));
        new[4]["metadata"]["annotations"][keys::IDENTITY_HASH] = json!(h("dep2"));

        let d = diff_of(&baseline(), &new);
        assert_eq!(d.changed.len(), 1);
        let c = &d.changed[0];
        let modified: Vec<String> = c
            .resource_diffs
            .iter()
            .map(|(id, _)| id.to_string())
            .collect();
        assert_eq!(modified, vec!["ConfigMap/web@app"]);
        let dep: Vec<String> = c
            .dep_affected_resources
            .iter()
            .map(|id| id.to_string())
            .collect();
        assert_eq!(dep, vec!["Deployment/web@app"]);
        assert!(d.cluster_level.is_none());
        assert_eq!(
            d.activation,
            Some(RecordChange {
                old: Some("c-old".into()),
                new: Some("c-new".into())
            })
        );
    }

    #[test]
    fn a_reordered_list_is_modified_and_shows_the_new_order() {
        // The last `--auth` flag wins, so the order is the setting.
        let deployment = |hash: &str, args: Value, app_first: bool| {
            let app = json!({"name": "app", "args": args});
            let proxy = json!({"name": "proxy"});
            let containers = if app_first {
                json!([app, proxy])
            } else {
                json!([proxy, app])
            };
            let spec = json!({"template": {"spec": {"containers": containers}}});
            stamped("Deployment", "app", "web", ("app", "web"), hash, spec)
        };
        let mut old = baseline();
        old[4] = deployment(&h("dep"), json!(["--auth=off", "--auth=on"]), true);
        let cases = [
            (
                json!(["--auth=on", "--auth=off"]),
                true,
                "$.spec.template.spec.containers[app].args",
            ),
            (
                json!(["--auth=off", "--auth=on"]),
                false,
                "$.spec.template.spec.containers",
            ),
        ];
        for (args, app_first, path) in cases {
            let mut new = baseline();
            new[4] = deployment(&h("dep2"), args, app_first);
            let d = diff_of(&old, &new);
            let c = &d.changed[0];
            assert!(c.dep_affected_resources.is_empty(), "{path}");
            let (id, diffs) = &c.resource_diffs[0];
            assert_eq!(id.to_string(), "Deployment/web@app");
            let paths: Vec<&str> = diffs.iter().map(|d| d.path.as_str()).collect();
            assert_eq!(paths, [path]);
        }
    }

    #[test]
    fn drift_under_the_same_stamp_is_a_content_change() {
        // Old side: the live object, replicas changed externally, stamp intact.
        let mut old = baseline();
        old[4] = stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep"),
            json!({"replicas": 3}),
        );
        let d = diff_of(&old, &baseline());
        assert_eq!(d.changed.len(), 1);
        let (id, diffs) = &d.changed[0].resource_diffs[0];
        assert_eq!(id.to_string(), "Deployment/web@app");
        assert_eq!(diffs[0].path, "$.spec.replicas");
    }

    #[test]
    fn cluster_level_resources_are_compared_outside_any_package() {
        let mut new = baseline();
        new[1] = cluster_level("Namespace", "app", &h("ns2"), json!({"finalizers": ["x"]}));
        new.push(cluster_level(
            "CustomResourceDefinition",
            "things.example.com",
            &h("crd"),
            json!({}),
        ));

        let d = diff_of(&baseline(), &new);
        assert!(d.changed.is_empty());
        let cl = d.cluster_level.expect("cluster-level section");
        assert_eq!(cl.key, CLUSTER_LEVEL_KEY);
        assert_eq!(cl.resource_diffs.len(), 1);
        assert_eq!(cl.resource_diffs[0].0.to_string(), "Namespace/app");
        assert_eq!(
            cl.added_resources[0].to_string(),
            "CustomResourceDefinition/things.example.com"
        );
    }

    #[test]
    fn an_empty_old_side_is_a_first_deploy() {
        let d = diff_of(&[], &baseline());
        assert_eq!(d.added.len(), 1);
        assert_eq!(d.added[0].key, "app/web");
        // Namespace and record show up too: nothing is hidden on a first deploy.
        assert!(d.cluster_level.is_some());
        assert_eq!(
            d.activation.as_ref().and_then(|a| a.new.as_deref()),
            Some("c-old")
        );
    }

    /// Added and removed packages share one JSON shape.
    #[test]
    fn an_added_package_has_an_empty_kept_list() {
        let mut new = baseline();
        new.push(package_instance("app", "api", "2.0.0", &h("pi2")));
        let json = packages_json(&diff_of(&baseline(), &new), document::Detail::Plain);
        assert_eq!(json["added"][0]["kept_resources"], json!([]));
    }

    /// The `changes` of the modified resource named `resource` in `web`.
    fn json_changes(d: &PackageDiff, resource: &str) -> Value {
        let json = packages_json(d, document::Detail::Fields);
        let web = json["changed"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["key"] == "app/web")
            .expect("web changed")
            .clone();
        let modified = web["modified_resources"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["resource"] == resource)
            .unwrap_or_else(|| panic!("{resource} modified: {web}"))
            .clone();
        assert_eq!(
            modified["diff_count"].as_u64(),
            Some(modified["changes"].as_array().unwrap().len() as u64)
        );
        modified["changes"].clone()
    }

    /// Each field change reads old to new, with an absent side left out.
    #[test]
    fn json_lists_each_field_change() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted", "extra": 1}),
        );
        let changes = json_changes(&diff_of(&baseline(), &new), "ConfigMap/web@app");
        assert_eq!(
            changes,
            json!([
                {"path": "$.spec.extra", "change": "added", "new": 1},
                {"path": "$.spec.k", "change": "changed", "old": "v", "new": "wanted"},
            ])
        );
    }

    /// No Secret value, and no hash of one, reaches the JSON.
    #[test]
    fn json_hides_secret_values_and_their_hashes() {
        let secret = |hash: &str, fields: Value| web_resource("Secret", hash, fields);
        let mut old = baseline();
        old.push(secret(
            &h("s1"),
            json!({"data": {"password": "b2xkLXBhc3M="}, "type": "Opaque"}),
        ));
        let mut new = baseline();
        let mut s = secret(
            &h("s2"),
            json!({
                "data": {"password": "bmV3LXBhc3M="},
                "stringData": {"token": "plain-token"},
                "type": "kubernetes.io/basic-auth",
            }),
        );
        s["metadata"]["annotations"][keys::CONTENT_HASH] = json!("content-hash-value");
        new.push(s);
        new[4] = stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep2"),
            json!({"template": {"metadata": {"annotations": {"checksum/secret": "abc123"}}}}),
        );
        let d = diff_of(&old, &new);
        let text = packages_json(&d, document::Detail::Fields).to_string();
        for leaked in [
            "b2xkLXBhc3M=",
            "bmV3LXBhc3M=",
            "plain-token",
            "content-hash-value",
            "abc123",
        ] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }

        let changes = json_changes(&d, "Secret/web@app");
        let by_path = |p: &str| {
            changes
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["path"] == p)
                .unwrap_or_else(|| panic!("{p} in {changes}"))
                .clone()
        };
        assert_eq!(
            by_path("$.data.password"),
            json!({"path": "$.data.password", "change": "changed",
                   "old": SECRET_NOT_SHOWN, "new": SECRET_CHANGED_NOT_SHOWN})
        );
        assert_eq!(
            by_path("$.stringData")["new"],
            json!({"token": SECRET_NOT_SHOWN})
        );
        assert_eq!(by_path("$.type")["new"], json!("kubernetes.io/basic-auth"));

        let changes = json_changes(&d, "Deployment/web@app");
        assert!(changes.to_string().contains(SECRET_NOT_SHOWN), "{changes}");
    }

    /// A value too large to show is replaced by its size.
    #[test]
    fn json_leaves_out_a_large_value() {
        let big = "x".repeat(MAX_SHOWN_VALUE_BYTES + 1);
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": big}),
        );
        let changes = json_changes(&diff_of(&baseline(), &new), "ConfigMap/web@app");
        assert_eq!(changes[0]["old"], json!("v"));
        assert_eq!(
            changes[0]["new"],
            json!(format!("({} bytes, not shown)", MAX_SHOWN_VALUE_BYTES + 3))
        );
    }
    /// The default level names the changes and counts the fields, but does
    /// not list them.
    #[test]
    fn json_plain_counts_fields_without_listing_them() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        let json = packages_json(&diff_of(&baseline(), &new), document::Detail::Plain);
        let modified = &json["changed"][0]["modified_resources"][0];
        assert_eq!(modified["diff_count"], json!(1));
        assert!(modified.get("changes").is_none(), "{modified}");
        assert!(json["changed"][0].get("manifests").is_none(), "{json}");
    }

    /// The manifests level adds the old and new manifest of every modified,
    /// added, and removed resource, and of an added package's resources.
    #[test]
    fn json_manifests_carry_each_side_that_exists() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        new.remove(4);
        new.push(stamped(
            "Service",
            "app",
            "web",
            ("app", "web"),
            &h("svc"),
            json!({"port": 80}),
        ));
        new.push(package_instance("app", "api", "2.0.0", &h("pi2")));
        new.push(stamped(
            "ConfigMap",
            "app",
            "api",
            ("app", "api"),
            &h("api-cm"),
            json!({"a": "b"}),
        ));
        let (old_graph, new_graph) = graphs_of(&baseline(), &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let json = packages_json(
            &d,
            document::Detail::Manifests(&ManifestIndex::new(&old_graph, &new_graph)),
        );
        let web = json["changed"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["key"] == "app/web")
            .expect("web changed");
        assert!(
            web["modified_resources"][0].get("changes").is_some(),
            "fields come with manifests: {web}"
        );
        let manifests = &web["manifests"];
        let cm = &manifests["ConfigMap/web@app"];
        assert_eq!(cm["old"]["spec"]["k"], json!("v"));
        assert_eq!(cm["new"]["spec"]["k"], json!("wanted"));
        let svc = &manifests["Service/web@app"];
        assert!(svc.get("old").is_none(), "{svc}");
        assert_eq!(svc["new"]["spec"]["port"], json!(80));
        let dep = &manifests["Deployment/web@app"];
        assert_eq!(dep["old"]["spec"]["replicas"], json!(2));
        assert!(dep.get("new").is_none(), "{dep}");

        let api = &json["added"][0];
        assert_eq!(api["key"], json!("app/api"));
        assert_eq!(
            api["manifests"]["ConfigMap/api@app"]["new"]["spec"]["a"],
            json!("b")
        );
        assert!(
            api["manifests"]["PackageInstance/api@app"]
                .get("new")
                .is_some(),
            "{api}"
        );
    }

    /// No Secret value or hash of one reaches the manifests, and a hidden
    /// value that changed reads differently on the new side, so a line diff
    /// of the two manifests shows it.
    #[test]
    fn json_manifests_hide_secrets_and_mark_the_changed_ones() {
        let secret = |hash: &str, fields: Value| web_resource("Secret", hash, fields);
        let mut old = baseline();
        old.push(secret(
            &h("s1"),
            json!({"data": {"password": "b2xkLXBhc3M=", "user": "YWRtaW4="}}),
        ));
        let mut new = baseline();
        let mut s = secret(
            &h("s2"),
            json!({
                "data": {"password": "bmV3LXBhc3M=", "user": "YWRtaW4="},
                "stringData": {"token": "plain-token"},
            }),
        );
        s["metadata"]["annotations"][keys::CONTENT_HASH] = json!("content-hash-value");
        new.push(s);
        new[4] = stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep2"),
            json!({"template": {"metadata": {"annotations": {"checksum/secret": "abc123"}}}}),
        );
        let (old_graph, new_graph) = graphs_of(&old, &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let json = packages_json(
            &d,
            document::Detail::Manifests(&ManifestIndex::new(&old_graph, &new_graph)),
        );
        let text = json.to_string();
        for leaked in [
            "b2xkLXBhc3M=",
            "bmV3LXBhc3M=",
            "YWRtaW4=",
            "plain-token",
            "content-hash-value",
            "abc123",
        ] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }
        let secret = &json["changed"][0]["manifests"]["Secret/web@app"];
        assert_eq!(secret["old"]["data"]["password"], json!(SECRET_NOT_SHOWN));
        assert_eq!(
            secret["new"]["data"]["password"],
            json!(SECRET_CHANGED_NOT_SHOWN)
        );
        assert_eq!(secret["new"]["data"]["user"], json!(SECRET_NOT_SHOWN));
        assert_eq!(
            secret["new"]["stringData"]["token"],
            json!(SECRET_NOT_SHOWN)
        );
        assert_eq!(
            secret["new"]["metadata"]["annotations"][keys::CONTENT_HASH],
            json!(SECRET_NOT_SHOWN)
        );
        let dep = &json["changed"][0]["manifests"]["Deployment/web@app"];
        assert_eq!(
            dep["new"]["spec"]["template"]["metadata"]["annotations"]["checksum/secret"],
            json!(SECRET_NOT_SHOWN)
        );
    }

    /// An answered object's sides replace the graphs' manifests: a live
    /// object and a dry-run result, or no old side when nothing is live.
    #[test]
    fn answered_objects_show_the_live_object_and_the_dry_run_result() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        let (old_graph, new_graph) = graphs_of(&baseline(), &new);
        let mut index = ManifestIndex::new(&old_graph, &new_graph);
        let cm = ResourceId::from_value(&new[3]);
        let dep = ResourceId::from_value(&new[4]);
        index.answered(
            &cm,
            Some(json!({"spec": {"k": "live"}})),
            Some(json!({"spec": {"k": "server"}})),
        );
        index.answered(&dep, None, Some(json!({"spec": {"replicas": 5}})));
        let shown = index.render([&cm, &dep]);
        let cm = &shown["ConfigMap/web@app"];
        assert_eq!(cm.old, Some(json!({"spec": {"k": "live"}})));
        assert_eq!(cm.new, Some(json!({"spec": {"k": "server"}})));
        let dep = &shown["Deployment/web@app"];
        assert_eq!(dep.old, None);
        assert_eq!(dep.new, Some(json!({"spec": {"replicas": 5}})));
    }

    /// A Secret once applied with kubectl carries its whole data in
    /// `last-applied-configuration`; the manifests hide it, under the
    /// retired domain's hash spellings too.
    #[test]
    fn manifests_hide_a_secret_in_last_applied_and_legacy_hashes() {
        let (old_graph, new_graph) = graphs_of(&baseline(), &baseline());
        let mut index = ManifestIndex::new(&old_graph, &new_graph);
        let rid = ResourceId {
            kind: "Secret".into(),
            namespace: "app".into(),
            name: "s".into(),
        };
        let legacy = crate::legacy_domain::legacy_spellings(keys::CONTENT_HASH)
            .pop()
            .expect("a retired domain");
        let live = json!({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "s", "annotations": {
            LAST_APPLIED: "{\"data\":{\"p\":\"cGxhaW4=\"}}",
            legacy.clone(): "sha256-legacy-hash"}},
            "data": {"p": "b2xk"}});
        index.answered(&rid, Some(live.clone()), Some(live));
        let text = serde_json::to_string(&index.render([&rid])).unwrap();
        for leaked in ["cGxhaW4=", "b2xk", "sha256-legacy-hash"] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }
    }

    /// A manifest too large to show is replaced by its size.
    #[test]
    fn json_manifests_leave_out_a_large_manifest() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "x".repeat(MAX_SHOWN_MANIFEST_BYTES)}),
        );
        let (old_graph, new_graph) = graphs_of(&baseline(), &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let json = packages_json(
            &d,
            document::Detail::Manifests(&ManifestIndex::new(&old_graph, &new_graph)),
        );
        let cm = &json["changed"][0]["manifests"]["ConfigMap/web@app"];
        assert_eq!(cm["old"]["spec"]["k"], json!("v"));
        let note = cm["new"].as_str().expect("a size note");
        assert!(
            note.starts_with('(') && note.ends_with(" bytes, not shown)"),
            "{note}"
        );
    }
}

#[cfg(test)]
mod never_pruned_tests {
    use super::*;
    use crate::manifest::types::CLUSTER_SCOPED;

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            name: name.into(),
            namespace: CLUSTER_SCOPED.into(),
        }
    }

    /// A CRD or Namespace dropped from the build is kept; everything else,
    /// including custom resources of a kept CRD, is deleted in the given order.
    #[test]
    fn crds_and_namespaces_are_kept() {
        let garbage = vec![
            rid("Widget", "w1"),
            rid("CustomResourceDefinition", "widgets.example.com"),
            rid("ConfigMap", "old"),
            rid("Namespace", "gone"),
        ];
        let (delete, kept) = split_never_pruned(garbage);
        assert_eq!(delete, vec![rid("Widget", "w1"), rid("ConfigMap", "old")]);
        assert_eq!(
            kept,
            vec![
                rid("CustomResourceDefinition", "widgets.example.com"),
                rid("Namespace", "gone"),
            ]
        );
    }
}
