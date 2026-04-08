//! Shared plan display for deploy and gc.
//!
//! Package-grouped, changes-only output inspired by nvd (nix-version-diff).
//! Shows version changes per package and resource-level diffs in verbose mode.

use std::collections::BTreeMap;

use kix::eval::PackageNode;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::diff::display::format_diffs;
use kix::manifest::diff::engine::structural_diff;
use kix::manifest::diff::{DiffConfig, Difference};
use kix::manifest::types::ResourceId;
use serde_json::Value;

use crate::output;

// ── Package-level diff types ─────────────────────────────────────────

pub struct PackageDiff {
    pub added: Vec<PackageInfo>,
    pub removed: Vec<PackageInfo>,
    pub changed: Vec<PackageChangeDiff>,
    pub unchanged: usize,
}

#[derive(Clone)]
pub struct PackageInfo {
    pub key: String, // ns/name
    pub version: Option<String>,
    pub resource_count: usize,
}

pub struct PackageChangeDiff {
    pub key: String,
    pub old_version: Option<String>,
    pub new_version: Option<String>,
    /// Resources with actual manifest field changes (propagation-only diffs filtered out).
    /// Only contains the real (non-propagation) differences.
    pub resource_diffs: Vec<(ResourceId, Vec<Difference>)>,
    /// Resources whose identity-hash changed purely because a dependency's hash
    /// propagated up (via `kix.dev/identity-hash`/`kix.dev/depends-on`/`kix.dev/activations`/
    /// `kix.dev/built-via`). Manifest content is otherwise identical — will redeploy
    /// only to update stamped annotations.
    pub dep_affected_resources: Vec<ResourceId>,
    pub added_resources: Vec<ResourceId>,
    pub removed_resources: Vec<ResourceId>,
}

/// Returns true if a structural-diff path points at a kix.dev stamped annotation
/// whose only purpose is to carry hash propagation (identity, deps, activations,
/// built-via). Used to distinguish real content changes from dependency-propagated
/// hash bumps.
fn is_propagation_path(path: &str) -> bool {
    const PROPAGATION_ANNS: &[&str] = &[
        "kix.dev/identity-hash",
        "kix.dev/depends-on",
        "kix.dev/activations",
        "kix.dev/built-via",
    ];
    // Only match top-level metadata.annotations — pod template annotations
    // (e.g. $.spec.template.metadata.annotations.*) are real content changes.
    for ann in PROPAGATION_ANNS {
        let needle = format!("$.metadata.annotations.{ann}");
        if path == needle || path.starts_with(&format!("{needle}.")) {
            return true;
        }
    }
    false
}

/// Partition a set of differences into (real, propagation-only).
fn partition_propagation(diffs: Vec<Difference>) -> (Vec<Difference>, Vec<Difference>) {
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

// ── Compute package-level diff between two store graphs ──────────────

pub fn diff_graphs(old: &StoreGraph, new: &StoreGraph) -> PackageDiff {
    let config = DiffConfig::new("old", "new");

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

    for (key, new_pkg) in &new_pkgs {
        if let Some(old_pkg) = old_pkgs.get(key) {
            if old_pkg.resource_paths == new_pkg.resource_paths {
                unchanged += 1;
                continue;
            }
            let change = diff_package_resources(key, old_pkg, new_pkg, old, new, &config);
            changed.push(change);
        } else {
            added.push(PackageInfo {
                key: key.clone(),
                version: new_pkg.version.clone(),
                resource_count: new_pkg.resource_paths.len(),
            });
        }
    }

    for (key, old_pkg) in &old_pkgs {
        if !new_pkgs.contains_key(key) {
            removed.push(PackageInfo {
                key: key.clone(),
                version: old_pkg.version.clone(),
                resource_count: old_pkg.resource_paths.len(),
            });
        }
    }

    PackageDiff {
        added,
        removed,
        changed,
        unchanged,
    }
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
    let old_res = resource_map_for_package(old_pkg, old_graph);
    let new_res = resource_map_for_package(new_pkg, new_graph);

    let mut resource_diffs = Vec::new();
    let mut dep_affected_resources = Vec::new();
    let mut added_resources = Vec::new();
    let mut removed_resources = Vec::new();

    for (id, new_val) in &new_res {
        if let Some(old_val) = old_res.get(id) {
            let diffs = structural_diff(new_val, old_val, "$", config);
            if diffs.is_empty() {
                continue;
            }
            let (real, _propagation) = partition_propagation(diffs);
            if real.is_empty() {
                // Only kix.dev propagation annotations changed — identity hash
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
        old_version: old_pkg.version.clone(),
        new_version: new_pkg.version.clone(),
        resource_diffs,
        dep_affected_resources,
        added_resources,
        removed_resources,
    }
}

fn resource_map_for_package<'a>(
    pkg: &PackageNode,
    graph: &'a StoreGraph,
) -> BTreeMap<ResourceId, &'a Value> {
    pkg.resource_paths
        .iter()
        .filter_map(|p| graph.resources.get(p))
        .map(|node| (ResourceId::from_value(&node.manifest), &node.manifest))
        .collect()
}

// ── Build a PackageDiff for garbage (removed resources only) ─────────

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
            // Entire package removed
            removed.push(PackageInfo {
                key: key.clone(),
                version: old_pkg.version.clone(),
                resource_count: old_pkg.resource_paths.len(),
            });
        } else {
            let new_pkg = new_pkgs[key];
            if old_pkg.resource_paths == new_pkg.resource_paths {
                unchanged += 1;
                continue;
            }
            // Package changed — only care about removed resources (garbage)
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
    }
}

// ── Display ──────────────────────────────────────────────────────────

/// Print a package-grouped plan. Only shows changes.
pub fn print_package_plan(diff: &PackageDiff, verbose: bool) {
    let color = output::color_enabled();
    let config = DiffConfig::new("old", "new");

    // Group packages by namespace
    let mut by_ns: BTreeMap<String, Vec<PlanEntry>> = BTreeMap::new();

    for p in &diff.added {
        let (ns, name) = split_key(&p.key);
        by_ns.entry(ns).or_default().push(PlanEntry::Added(name, p));
    }
    for p in &diff.removed {
        let (ns, name) = split_key(&p.key);
        by_ns
            .entry(ns)
            .or_default()
            .push(PlanEntry::Removed(name, p));
    }
    for c in &diff.changed {
        let (ns, name) = split_key(&c.key);
        by_ns
            .entry(ns)
            .or_default()
            .push(PlanEntry::Changed(name, c));
    }

    if by_ns.is_empty() {
        return;
    }

    println!();
    for (ns, entries) in &by_ns {
        println!("  {}", output::bold(ns));
        for entry in entries {
            match entry {
                PlanEntry::Added(name, info) => {
                    let ver = info.version.as_deref().unwrap_or("");
                    let ver_str = if ver.is_empty() {
                        String::new()
                    } else {
                        format!(" {ver}")
                    };
                    println!(
                        "    {} {}{} ({} resources)",
                        output::green("+"),
                        output::green(name),
                        ver_str,
                        info.resource_count,
                    );
                }
                PlanEntry::Removed(name, info) => {
                    let ver = info.version.as_deref().unwrap_or("");
                    let ver_str = if ver.is_empty() {
                        String::new()
                    } else {
                        format!(" {ver}")
                    };
                    println!(
                        "    {} {}{} ({} resources)",
                        output::red("-"),
                        output::red(name),
                        ver_str,
                        info.resource_count,
                    );
                }
                PlanEntry::Changed(name, change) => {
                    let old_ver = change.old_version.as_deref().unwrap_or("");
                    let new_ver = change.new_version.as_deref().unwrap_or("");
                    let ver_str =
                        if !old_ver.is_empty() && !new_ver.is_empty() && old_ver != new_ver {
                            format!(" {} -> {}", old_ver, new_ver)
                        } else if !new_ver.is_empty() {
                            format!(" {new_ver}")
                        } else {
                            String::new()
                        };

                    let mut parts = Vec::new();
                    if !change.resource_diffs.is_empty() {
                        parts.push(format!("{} changed", change.resource_diffs.len()));
                    }
                    if !change.added_resources.is_empty() {
                        parts.push(format!("{} added", change.added_resources.len()));
                    }
                    if !change.removed_resources.is_empty() {
                        parts.push(format!("{} removed", change.removed_resources.len()));
                    }
                    if !change.dep_affected_resources.is_empty() {
                        parts.push(format!(
                            "{} dep-affected",
                            change.dep_affected_resources.len()
                        ));
                    }
                    let detail = if parts.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", parts.join(", "))
                    };

                    println!(
                        "    {} {}{}{}",
                        output::yellow("~"),
                        output::yellow(name),
                        ver_str,
                        detail,
                    );

                    if verbose {
                        for id in &change.added_resources {
                            println!(
                                "      {} {}",
                                output::green("+"),
                                output::green(&id.to_string()),
                            );
                        }
                        for id in &change.removed_resources {
                            println!(
                                "      {} {}",
                                output::red("-"),
                                output::red(&id.to_string()),
                            );
                        }
                        for (id, diffs) in &change.resource_diffs {
                            println!(
                                "      {} {}",
                                output::yellow("~"),
                                output::yellow(&id.to_string()),
                            );
                            let formatted = format_diffs(diffs, &config, color, true);
                            for line in formatted.lines() {
                                println!("        {line}");
                            }
                        }
                        for id in &change.dep_affected_resources {
                            println!(
                                "      {} {} {}",
                                output::dim("~"),
                                output::dim(&id.to_string()),
                                output::dim("(via dependency)"),
                            );
                        }
                    }
                }
            }
        }
    }
}

/// Print a compact wave visualization.
pub fn print_wave_summary(
    waves: &[Vec<petgraph::graph::NodeIndex>],
    graph: &kix::cluster::graph::ResourceGraph,
) {
    if waves.is_empty() {
        return;
    }

    let wave_summaries: Vec<String> = waves
        .iter()
        .map(|wave| {
            let mut kind_counts: BTreeMap<&str, usize> = BTreeMap::new();
            for &idx in wave {
                let kind = &graph.graph[idx].id.kind;
                *kind_counts.entry(kind.as_str()).or_default() += 1;
            }
            let parts: Vec<String> = kind_counts
                .into_iter()
                .map(|(k, n)| {
                    if n == 1 {
                        k.to_string()
                    } else {
                        format!("{n} {k}")
                    }
                })
                .collect();
            format!("[{}]", parts.join(", "))
        })
        .collect();

    println!();
    println!("  {} {}", output::dim("Waves:"), wave_summaries.join(" → "),);
}

/// Print plan summary line.
pub fn print_plan_summary(diff: &PackageDiff) {
    let updated = diff.changed.len();
    let added = diff.added.len();
    let removed = diff.removed.len();

    // Aggregate resource-level counts across all changed packages to
    // distinguish real content changes from dependency-propagated bumps.
    let mut real_resources = 0usize;
    let mut dep_affected_resources = 0usize;
    for c in &diff.changed {
        real_resources +=
            c.resource_diffs.len() + c.added_resources.len() + c.removed_resources.len();
        dep_affected_resources += c.dep_affected_resources.len();
    }

    let mut parts = Vec::new();
    if updated > 0 {
        let s = format!("{updated} updated");
        parts.push(output::yellow(&s).into_owned());
    }
    if added > 0 {
        let s = format!("{added} added");
        parts.push(output::green(&s).into_owned());
    }
    if removed > 0 {
        let s = format!("{removed} removed");
        parts.push(output::red(&s).into_owned());
    }
    if diff.unchanged > 0 {
        let s = format!("{} unchanged", diff.unchanged);
        parts.push(output::dim(&s).into_owned());
    }

    if parts.is_empty() {
        println!();
        println!("  {}", output::green("Everything up to date."));
    } else {
        println!();
        println!("  Plan: {}", parts.join(", "));
        if real_resources > 0 || dep_affected_resources > 0 {
            let res_line = format!(
                "  Resources: {} real content, {} dep-affected",
                real_resources, dep_affected_resources,
            );
            println!("{}", output::dim(&res_line));
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────

enum PlanEntry<'a> {
    Added(&'a str, &'a PackageInfo),
    Removed(&'a str, &'a PackageInfo),
    Changed(&'a str, &'a PackageChangeDiff),
}

/// Split "namespace/name" key into (namespace, name).
fn split_key(key: &str) -> (String, &str) {
    if let Some(idx) = key.find('/') {
        (key[..idx].to_string(), &key[idx + 1..])
    } else {
        ("_cluster".to_string(), key)
    }
}
