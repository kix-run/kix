//! Package-by-package structural diffs and garbage collection diffs between store graphs.

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;

use serde_json::Value;

use super::{
    CLUSTER_LEVEL_KEY, PackageChangeDiff, PackageDiff, PackageInfo, RecordChange, Shown, document,
};
use crate::eval::PackageNode;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::diff::engine::structural_diff;
use crate::manifest::diff::{DiffConfig, Difference};
use crate::manifest::keys;
use crate::manifest::lifecycle;
use crate::manifest::sent;
use crate::manifest::types::ResourceId;

/// Return true when a structural-diff path points at a `kix.run` stamped
/// annotation that only carries hash propagation (`identity-hash`,
/// `depends-on`, `activations`, or `built-via`).
pub(super) fn is_propagation_path(path: &str) -> bool {
    const PROPAGATION_ANNS: &[&str] = &[
        keys::IDENTITY_HASH,
        keys::DEPENDS_ON,
        keys::ACTIVATIONS,
        keys::BUILT_VIA,
    ];
    // Include retired domains because a diff against a cluster whose objects
    // predate a domain move shows both spellings.
    let legacy: Vec<String> = PROPAGATION_ANNS
        .iter()
        .flat_map(|k| crate::legacy_domain::legacy_spellings(k))
        .collect();
    // Match only top-level metadata.annotations. Pod template annotations
    // (e.g. $.spec.template.metadata.annotations.*) are real content changes.
    // Match the exact path so an annotation with a shared prefix (such as
    // `kix.run/identity-hash.x`) still shows as a content change.
    PROPAGATION_ANNS
        .iter()
        .map(|s| (*s).to_string())
        .chain(legacy)
        .any(|ann| path == format!("$.metadata.annotations.{ann}"))
}

/// Return true when a structural-diff path points at a retired note in the
/// top-level annotations ([`sent::is_retired_note`]). Kix sends none of
/// them, so a difference in one says nothing about what a deploy writes.
fn is_retired_note_path(path: &str) -> bool {
    path.strip_prefix("$.metadata.annotations.")
        .is_some_and(sent::is_retired_note)
}

/// Partition the differences between a live object and the dry-run answer to
/// the apply Kix sends for it into (real, retired notes only).
pub(crate) fn partition_retired(diffs: Vec<Difference>) -> (Vec<Difference>, Vec<Difference>) {
    diffs
        .into_iter()
        .partition(|d| !is_retired_note_path(&d.path))
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

/// What [`diff_graphs`] and [`diff_sent`] compare.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Compare {
    /// Two builds as they are. A resource whose only differences are the
    /// annotations that carry hash propagation is dependency-affected.
    Builds,
    /// What Kix sends for each side ([`sent::of`]). A resource whose only
    /// differences are notes Kix does not send is unchanged.
    Sent,
}

/// Compare two builds package by package. A resource whose manifest changed
/// only in the annotations a changed dependency moves is listed as
/// dependency-affected, so `kix diff` between two builds still says that
/// only its dependencies changed.
pub fn diff_graphs(old: &StoreGraph, new: &StoreGraph) -> PackageDiff {
    diff_graphs_as(old, new, Compare::Builds)
}

/// Compare `old`, the deployed side of a plan, with the new build `new`, as
/// a deploy compares them: what Kix sends for each object. A resource whose
/// dependencies changed and whose own manifest did not is unchanged, because
/// the deploy does not write it, so the diff lists no dependency-affected
/// resource.
pub fn diff_sent(old: &StoreGraph, new: &StoreGraph) -> PackageDiff {
    diff_graphs_as(old, new, Compare::Sent)
}

fn diff_graphs_as(old: &StoreGraph, new: &StoreGraph, compare: Compare) -> PackageDiff {
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
            let change = diff_package_resources(key, old_pkg, new_pkg, old, new, &config, compare);
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

    // Real graphs keep Namespaces, CRDs, and cluster-scoped bundles outside
    // every PackageNode, and a synthesized graph does the same for resources
    // without a package annotation. The deploy record is handled separately
    // below.
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
            compare,
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
            if lifecycle::is_record(m)
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

/// Return the resources in `graph.resources` that no package owns, excluding
/// PackageInstances (see [`resource_map_for_package`]) and the deploy record.
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
        .filter(|(id, _)| !lifecycle::is_record_kind(id.group_kind()))
        .collect()
}

/// Return the manifests from `objects`.
fn values_of<'a>(
    objects: &BTreeMap<ResourceId, (&'a PathBuf, &'a Value)>,
) -> BTreeMap<ResourceId, &'a Value> {
    objects
        .iter()
        .map(|(id, (_, m))| (id.clone(), *m))
        .collect()
}

/// Return the name of the deploy record in `graph`, if present.
fn record_name(graph: &StoreGraph) -> Option<String> {
    graph
        .resources
        .values()
        .map(|node| &node.manifest)
        .find(|m| lifecycle::is_record(m))
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
    compare: Compare,
) -> PackageChangeDiff {
    diff_resource_maps(
        key,
        old_pkg.version.clone(),
        new_pkg.version.clone(),
        &resource_map_for_package(old_pkg, old_graph),
        &resource_map_for_package(new_pkg, new_graph),
        config,
        compare,
    )
}

/// Diff two resource maps keyed by identity into content changes,
/// propagation-only bumps, additions, and removals.
fn diff_resource_maps(
    key: &str,
    old_version: Option<String>,
    new_version: Option<String>,
    old_res: &BTreeMap<ResourceId, &Value>,
    new_res: &BTreeMap<ResourceId, &Value>,
    config: &DiffConfig,
    compare: Compare,
) -> PackageChangeDiff {
    let mut resource_diffs = Vec::new();
    let mut dep_affected_resources = Vec::new();
    let mut added_resources = Vec::new();
    let mut removed_resources = Vec::new();

    for (id, new_val) in new_res {
        if let Some(old_val) = old_res.get(id) {
            // Pass `old_val` first because `config` labels side a "old" and
            // side b "new".
            let diffs = match compare {
                Compare::Builds => structural_diff(old_val, new_val, "$", config),
                Compare::Sent => {
                    let (old_sent, new_sent) = (sent::of(old_val), sent::of(new_val));
                    let (real, _) =
                        partition_retired(structural_diff(&old_sent, &new_sent, "$", config));
                    real
                }
            };
            if diffs.is_empty() {
                continue;
            }
            let (real, _propagation) = partition_propagation(diffs);
            if real.is_empty() && compare == Compare::Sent {
                continue;
            }
            if real.is_empty() {
                // Only kix.run propagation annotations changed. The identity hash
                // bumped because a dependency changed, but content is the same.
                dep_affected_resources.push(id.clone());
            } else {
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
        dep_affected_resources,
        added_resources,
        removed_resources,
        shared_kept: Vec::new(),
    }
}

/// Return a package's resources plus its own PackageInstance (stored at the
/// package's store path, outside `resource_paths`).
pub(super) fn resource_map_for_package<'a>(
    pkg: &'a PackageNode,
    graph: &'a StoreGraph,
) -> BTreeMap<ResourceId, &'a Value> {
    values_of(&objects_of_package(pkg, graph))
}

/// Return [`resource_map_for_package`] paired with the store path of each manifest.
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
