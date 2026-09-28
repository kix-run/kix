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
use kix::manifest::keys;
use kix::manifest::lifecycle;

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
    pub fn keep_shared(&mut self, shared: &[kix::cluster::fetch::SharedOrphan]) {
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
    fn any(&self) -> bool {
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

    /// The parenthesised count after a package name: `3 resources`, or for
    /// a removed package that leaves kept resources behind,
    /// `2 removed, 1 kept`.
    fn counts(&self) -> String {
        if self.kept.is_empty() {
            return format!("{} resources", self.resource_count);
        }
        let removed = self.resource_count - self.kept.len();
        if removed == 0 {
            format!("{} kept", self.kept.len())
        } else {
            format!("{removed} removed, {} kept", self.kept.len())
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
        .flat_map(|k| kix::legacy_domain::legacy_spellings(k))
        .collect();
    // Match only top-level metadata.annotations. Pod template annotations
    // (e.g. $.spec.template.metadata.annotations.*) are real content changes.
    for ann in PROPAGATION_ANNS
        .iter()
        .map(|s| (*s).to_string())
        .chain(legacy)
    {
        let needle = format!("$.metadata.annotations.{ann}");
        if path == needle || path.starts_with(&format!("{needle}.")) {
            return true;
        }
    }
    false
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
                kept: Vec::new(),
                resources: Vec::new(),
            });
        }
    }

    for (key, old_pkg) in &old_pkgs {
        if !new_pkgs.contains_key(key) {
            removed.push(PackageInfo::removed(key, old_pkg, old));
        }
    }

    // Resources no package owns: real graphs keep Namespaces, CRDs and
    // the cluster-scoped bundles outside every PackageNode, and a
    // synthesized graph does the same for anything without a package
    // annotation. The deploy record is handled separately below.
    let cluster_level = {
        let old_res = unowned_resources(old);
        let new_res = unowned_resources(new);
        let d = diff_resource_maps(CLUSTER_LEVEL_KEY, None, None, &old_res, &new_res, &config);
        (!d.resource_diffs.is_empty()
            || !d.dep_affected_resources.is_empty()
            || !d.added_resources.is_empty()
            || !d.removed_resources.is_empty())
        .then_some(d)
    };

    let old_record = record_name(old);
    let new_record = record_name(new);
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
    }
}

/// Key of the cluster-level pseudo-package in renderers.
pub const CLUSTER_LEVEL_KEY: &str = "_cluster";

/// Resources in `graph.resources` that no package owns, minus the
/// PackageInstances (each belongs with its package, see
/// `resource_map_for_package`) and the deploy record.
fn unowned_resources(graph: &StoreGraph) -> BTreeMap<ResourceId, &Value> {
    graph
        .resources
        .iter()
        .filter(|(path, _)| {
            !graph.resource_owner.contains_key(*path) && !graph.packages.contains_key(*path)
        })
        .map(|(_, node)| (ResourceId::from_value(&node.manifest), &node.manifest))
        .filter(|(id, _)| !kix::manifest::lifecycle::is_record_kind(&id.kind))
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
                .is_some_and(kix::manifest::lifecycle::is_record_kind)
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

/// A package's resources plus its own PackageInstance (the graph keeps the
/// PI at the package's store path, outside `resource_paths`).
fn resource_map_for_package<'a>(
    pkg: &PackageNode,
    graph: &'a StoreGraph,
) -> BTreeMap<ResourceId, &'a Value> {
    pkg.resource_paths
        .iter()
        .chain(std::iter::once(&pkg.store_path))
        .filter_map(|p| graph.resources.get(p))
        .map(|node| (ResourceId::from_value(&node.manifest), &node.manifest))
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
    }
}

// These are the canonical PackageDiff JSON and Markdown producers. The
// deploy modal, `kix diff`, rollback change summary, and the CI PR-comment
// GitHub Action all consume the same output here so formats stay in sync.
// See v2_discussions/84_m0_m1_implementation_plan.md §5.

/// Render a `PackageDiff` as a JSON value suitable for machine consumption
/// or as the base of a larger document (e.g. `kix diff` wraps it with
/// legacy resource / migration-pair sections).
pub fn render_package_diff_json(diff: &PackageDiff) -> Value {
    serde_json::json!({
        "added": diff.added.iter().map(render_package_info_json).collect::<Vec<_>>(),
        "removed": diff.removed.iter().map(render_package_info_json).collect::<Vec<_>>(),
        "changed": diff.changed.iter().map(render_change_json).collect::<Vec<_>>(),
        "cluster_level": diff.cluster_level.as_ref().map(render_change_json),
        "activation": diff.activation.as_ref().map(|a| serde_json::json!({
            "old": a.old,
            "new": a.new,
        })),
        "unchanged": diff.unchanged,
        "summary": {
            "added": diff.added.len(),
            "removed": diff.removed.len(),
            "changed": diff.changed.len(),
            "unchanged": diff.unchanged,
        },
    })
}

/// `resources` counts every resource of the package, including the ones in
/// `kept_resources`.
fn render_package_info_json(p: &PackageInfo) -> Value {
    serde_json::json!({
        "key": p.key,
        "version": p.version,
        "resources": p.resource_count,
        "kept_resources": p.kept.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
    })
}

fn render_change_json(c: &PackageChangeDiff) -> Value {
    let (removed, kept) = c.removed_and_kept();
    serde_json::json!({
        "key": c.key,
        "old_version": c.old_version,
        "new_version": c.new_version,
        "added_resources": c.added_resources.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
        "removed_resources": removed.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
        "kept_resources": kept.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
        "modified_resources": c.resource_diffs.iter().map(|(id, diffs)| serde_json::json!({
            "resource": id.display_id(),
            "diff_count": diffs.len(),
        })).collect::<Vec<_>>(),
        "dep_affected_resources": c.dep_affected_resources.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
    })
}

fn render_change_markdown(out: &mut String, c: &PackageChangeDiff) {
    use std::fmt::Write;
    let old_ver = c.old_version.as_deref().unwrap_or("?");
    let new_ver = c.new_version.as_deref().unwrap_or("?");
    let ver_str = if old_ver != new_ver {
        format!("{old_ver} → {new_ver}")
    } else {
        new_ver.to_string()
    };

    let mut parts = Vec::new();
    if !c.resource_diffs.is_empty() {
        parts.push(format!("{} changed", c.resource_diffs.len()));
    }
    if !c.added_resources.is_empty() {
        parts.push(format!("{} added", c.added_resources.len()));
    }
    let (removed, kept) = c.removed_and_kept();
    if !removed.is_empty() {
        parts.push(format!("{} removed", removed.len()));
    }
    if !kept.is_empty() {
        parts.push(format!("{} kept", kept.len()));
    }
    if !c.dep_affected_resources.is_empty() {
        parts.push(format!("{} dep-affected", c.dep_affected_resources.len()));
    }
    let detail = if parts.is_empty() {
        String::new()
    } else {
        format!(" ({})", parts.join(", "))
    };

    let _ = writeln!(out, "<details>");
    let _ = writeln!(
        out,
        "<summary><code>{}</code> {ver_str}{detail}</summary>",
        c.key
    );
    let _ = writeln!(out);

    if !c.added_resources.is_empty() {
        let _ = writeln!(out, "**Added resources:**");
        let _ = writeln!(out);
        for id in &c.added_resources {
            let _ = writeln!(out, "- `{}`", id);
        }
        let _ = writeln!(out);
    }
    if !removed.is_empty() {
        let _ = writeln!(out, "**Removed resources:**");
        let _ = writeln!(out);
        for id in &removed {
            let _ = writeln!(out, "- `{}`", id);
        }
        let _ = writeln!(out);
    }
    if !kept.is_empty() {
        let _ = writeln!(out, "**Left the build, never deleted automatically:**");
        let _ = writeln!(out);
        for id in &kept {
            let _ = writeln!(out, "- `{}`", id);
        }
        let _ = writeln!(out);
    }
    if !c.resource_diffs.is_empty() {
        let _ = writeln!(out, "**Modified resources:**");
        let _ = writeln!(out);
        for (id, diffs) in &c.resource_diffs {
            let _ = writeln!(out, "- `{}` ({} diffs)", id, diffs.len());
        }
        let _ = writeln!(out);
    }
    if !c.dep_affected_resources.is_empty() {
        let _ = writeln!(out, "**Dep-affected (hash bump only, no content change):**");
        let _ = writeln!(out);
        for id in &c.dep_affected_resources {
            let _ = writeln!(out, "- `{}`", id);
        }
        let _ = writeln!(out);
    }

    let _ = writeln!(out, "</details>");
    let _ = writeln!(out);
}

/// Render a `PackageDiff` as GitHub-flavored markdown suitable for a PR comment.
/// Uses collapsed `<details>` blocks so a large diff doesn't flood the comment.
pub fn render_package_diff_markdown(diff: &PackageDiff) -> String {
    use std::fmt::Write;
    let mut out = String::new();

    let added = diff.added.len();
    let removed = diff.removed.len();
    let changed = diff.changed.len();

    let _ = writeln!(out, "### kix diff");
    let _ = writeln!(out);

    if !diff.has_changes() {
        let _ = writeln!(
            out,
            "No package-level changes ({} unchanged).",
            diff.unchanged
        );
        return out;
    }

    let totals = diff.resource_totals();

    let _ = writeln!(
        out,
        "**Plan:** {changed} updated, {added} added, {removed} removed, {} unchanged",
        diff.unchanged
    );
    if totals.any() {
        let kept = if totals.kept > 0 {
            format!(", {} kept (never deleted automatically)", totals.kept)
        } else {
            String::new()
        };
        let _ = writeln!(
            out,
            "**Resources:** {} with real content changes{kept}, {} dep-affected (hash bump only)",
            totals.real_content, totals.dep_affected,
        );
    }
    let _ = writeln!(out);

    if !diff.added.is_empty() {
        let _ = writeln!(out, "#### Added packages");
        let _ = writeln!(out);
        for p in &diff.added {
            let ver = p
                .version
                .as_deref()
                .map(|v| format!(" `{v}`"))
                .unwrap_or_default();
            let _ = writeln!(out, "- `{}`{ver} ({})", p.key, p.counts());
        }
        let _ = writeln!(out);
    }

    if !diff.removed.is_empty() {
        let _ = writeln!(out, "#### Removed packages");
        let _ = writeln!(out);
        for p in &diff.removed {
            let ver = p
                .version
                .as_deref()
                .map(|v| format!(" `{v}`"))
                .unwrap_or_default();
            let _ = writeln!(out, "- `{}`{ver} ({})", p.key, p.counts());
            for id in &p.kept {
                let _ = writeln!(out, "  - kept, never deleted automatically: `{id}`");
            }
        }
        let _ = writeln!(out);
    }

    if !diff.changed.is_empty() {
        let _ = writeln!(out, "#### Changed packages");
        let _ = writeln!(out);
        for c in &diff.changed {
            render_change_markdown(&mut out, c);
        }
    }

    if let Some(c) = &diff.cluster_level {
        let _ = writeln!(out, "#### Cluster-level resources");
        let _ = writeln!(out);
        render_change_markdown(&mut out, c);
    }

    if let Some(a) = &diff.activation {
        let _ = writeln!(
            out,
            "**Activation:** `{}` → `{}`",
            a.old.as_deref().unwrap_or("(none)"),
            a.new.as_deref().unwrap_or("(none)"),
        );
        let _ = writeln!(out);
    }

    out
}

/// Print a package-grouped plan. Only shows changes.
pub fn print_package_plan(diff: &PackageDiff, verbose: bool) {
    print!("{}", render_package_plan(diff, verbose));
}

/// The text `print_package_plan` prints.
fn render_package_plan(diff: &PackageDiff, verbose: bool) -> String {
    use std::fmt::Write;
    let mut out = String::new();
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
    if let Some(c) = &diff.cluster_level {
        by_ns
            .entry(CLUSTER_LEVEL_KEY.to_string())
            .or_default()
            .push(PlanEntry::Changed("cluster-level resources", c));
    }

    if by_ns.is_empty() {
        return out;
    }

    let _ = writeln!(out);
    for (ns, entries) in &by_ns {
        let _ = writeln!(out, "  {}", output::bold(ns));
        for entry in entries {
            match entry {
                PlanEntry::Added(name, info) => {
                    let ver = info.version.as_deref().unwrap_or("");
                    let ver_str = if ver.is_empty() {
                        String::new()
                    } else {
                        format!(" {ver}")
                    };
                    let _ = writeln!(
                        out,
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
                    let _ = writeln!(
                        out,
                        "    {} {}{} ({})",
                        output::red("-"),
                        output::red(name),
                        ver_str,
                        info.counts(),
                    );
                    if verbose {
                        for id in &info.kept {
                            write_kept_line(&mut out, id);
                        }
                    }
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
                    let (removed, kept) = change.removed_and_kept();
                    if !removed.is_empty() {
                        parts.push(format!("{} removed", removed.len()));
                    }
                    if !kept.is_empty() {
                        parts.push(format!("{} kept", kept.len()));
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

                    let _ = writeln!(
                        out,
                        "    {} {}{}{}",
                        output::yellow("~"),
                        output::yellow(name),
                        ver_str,
                        detail,
                    );

                    if verbose {
                        for id in &change.added_resources {
                            let _ = writeln!(
                                out,
                                "      {} {}",
                                output::green("+"),
                                output::green(&id.to_string()),
                            );
                        }
                        for id in &removed {
                            let _ = writeln!(
                                out,
                                "      {} {}",
                                output::red("-"),
                                output::red(&id.to_string()),
                            );
                        }
                        for id in &kept {
                            write_kept_line(&mut out, id);
                        }
                        for (id, diffs) in &change.resource_diffs {
                            let _ = writeln!(
                                out,
                                "      {} {}",
                                output::yellow("~"),
                                output::yellow(&id.to_string()),
                            );
                            let formatted = format_diffs(diffs, &config, color, true);
                            for line in formatted.lines() {
                                let _ = writeln!(out, "        {line}");
                            }
                        }
                        for id in &change.dep_affected_resources {
                            let _ = writeln!(
                                out,
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
    out
}

/// A resource that left the build, but deploy and gc never delete.
fn write_kept_line(out: &mut String, id: &ResourceId) {
    use std::fmt::Write;
    let _ = writeln!(
        out,
        "      {} {} {}",
        output::yellow("!"),
        output::yellow(&id.to_string()),
        output::dim("(kept)"),
    );
}

/// Split resources that left the build into `(delete, kept)`, keeping each
/// list's order. `kept` holds the kinds `lifecycle::never_pruned` protects,
/// which deploy's prune and `kix gc` report but never delete.
pub fn split_never_pruned(rids: Vec<ResourceId>) -> (Vec<ResourceId>, Vec<ResourceId>) {
    let (kept, delete) = rids
        .into_iter()
        .partition(|rid| lifecycle::never_pruned(&rid.kind));
    (delete, kept)
}

/// List resources that left the build and stay in place because deleting
/// them would also delete objects outside the build.
pub fn print_never_pruned(kept: &[ResourceId]) {
    print!("{}", render_never_pruned(kept));
}

pub fn render_never_pruned(kept: &[ResourceId]) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    if kept.is_empty() {
        return out;
    }
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "{} {} resources are not in the build but are never deleted automatically:",
        output::bold("Kept:"),
        kept.len(),
    );
    for rid in kept {
        let _ = writeln!(out, "    {} {}", output::yellow("!"), rid);
    }
    let _ = writeln!(
        out,
        "  {}",
        output::dim(
            "Deleting a Namespace deletes everything in it, and deleting a \
             CustomResourceDefinition deletes every resource of that kind. \
             Delete them with kubectl if that is intended."
        ),
    );
    out
}

/// Print plan summary line.
pub fn print_plan_summary(diff: &PackageDiff) {
    let updated = diff.changed.len();
    let added = diff.added.len();
    let removed = diff.removed.len();

    let totals = diff.resource_totals();

    let mut parts = Vec::new();
    if diff.cluster_level.is_some() {
        parts.push(output::yellow("cluster-level changes").into_owned());
    }
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

    if parts.is_empty() && diff.activation.is_none() {
        println!();
        println!("  {}", output::green("Everything up to date."));
    } else if parts.is_empty() {
        println!();
        println!(
            "  Plan: {}",
            output::dim("only the activation record changes")
        );
    } else {
        println!();
        println!("  Plan: {}", parts.join(", "));
        if totals.any() {
            let kept = if totals.kept > 0 {
                format!(", {} kept", totals.kept)
            } else {
                String::new()
            };
            let res_line = format!(
                "  Resources: {} real content{kept}, {} dep-affected",
                totals.real_content, totals.dep_affected,
            );
            println!("{}", output::dim(&res_line));
        }
    }
}

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

#[cfg(test)]
mod diff_graph_tests {
    use super::*;
    use kix::manifest::keys;
    use serde_json::json;

    fn stamped(
        kind: &str,
        ns: &str,
        name: &str,
        pkg: (&str, &str),
        hash: &str,
        spec: Value,
    ) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {
                    keys::PACKAGE: pkg.1,
                    keys::PACKAGE_NAMESPACE: pkg.0,
                    keys::IDENTITY_HASH: hash,
                    keys::DEPENDS_ON: "",
                }
            },
            "spec": spec,
        })
    }

    fn package_instance(ns: &str, name: &str, version: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": kix::manifest::lifecycle::PACKAGE_INSTANCE_KIND,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {keys::IDENTITY_HASH: hash}
            },
            "spec": {"instanceName": name, "namespaceName": ns, "version": version},
        })
    }

    fn cluster_level(kind: &str, name: &str, hash: &str, spec: Value) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {"name": name, "annotations": {keys::IDENTITY_HASH: hash}},
            "spec": spec,
        })
    }

    fn record(name: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": kix::manifest::lifecycle::RECORD_KIND,
            "metadata": {"name": name, "annotations": {keys::IDENTITY_HASH: hash}},
            "spec": {"cluster": "c"},
        })
    }

    fn h(seed: &str) -> String {
        format!("{seed:a<32}")
    }

    /// New side is a build; old side is whatever the cluster (or a
    /// snapshot) said, synthesized against that build.
    fn diff_of(old: &[Value], new: &[Value]) -> PackageDiff {
        let new_graph = StoreGraph::synthesize(new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(old, &new_graph);
        diff_graphs(&old_graph, &new_graph)
    }

    fn baseline() -> Vec<Value> {
        vec![
            record("c-old", &h("rec1")),
            cluster_level("Namespace", "app", &h("ns"), json!({})),
            package_instance("app", "web", "1.0.0", &h("pi")),
            stamped(
                "ConfigMap",
                "app",
                "web",
                ("app", "web"),
                &h("cm"),
                json!({"k": "v"}),
            ),
            stamped(
                "Deployment",
                "app",
                "web",
                ("app", "web"),
                &h("dep"),
                json!({"replicas": 2}),
            ),
        ]
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
            kix::manifest::diff::DiffKind::ExtraInB,
            "a field the build adds must read as extra on the new side"
        );
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

    fn crd(name: &str, pkg: (&str, &str), hash: &str) -> Value {
        json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {
                "name": name,
                "annotations": {
                    keys::PACKAGE: pkg.1,
                    keys::PACKAGE_NAMESPACE: pkg.0,
                    keys::IDENTITY_HASH: hash,
                    keys::DEPENDS_ON: "",
                }
            },
            "spec": {},
        })
    }

    #[test]
    fn a_kept_kind_that_left_the_build_is_not_shown_as_a_deletion() {
        let mut old = baseline();
        old.push(crd("widgets.example.com", ("app", "web"), &h("crd")));
        let new_graph = StoreGraph::synthesize(&baseline(), &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&old, &new_graph);
        let text = render_package_plan(&diff_garbage(&old_graph, &new_graph), true);
        assert!(text.contains("~ web 1.0.0 (1 kept)"), "{text}");
        assert!(
            text.contains("! CustomResourceDefinition/widgets.example.com (kept)"),
            "{text}"
        );
        assert!(!text.contains("- CustomResourceDefinition"), "{text}");
    }

    /// `kix diff` renders the same removal the same way in every format.
    #[test]
    fn diff_renderers_list_a_kept_kind_apart_from_removals() {
        let mut old = baseline();
        old.push(crd("widgets.example.com", ("app", "web"), &h("crd")));
        let d = diff_of(&old, &baseline());

        let text = render_package_plan(&d, true);
        assert!(text.contains("(1 kept)"), "{text}");
        assert!(!text.contains("- CustomResourceDefinition"), "{text}");

        let md = render_package_diff_markdown(&d);
        assert!(md.contains("(1 kept)"), "{md}");
        assert!(!md.contains("**Removed resources:**"), "{md}");
        assert!(
            md.contains("**Left the build, never deleted automatically:**\n\n- `CustomResourceDefinition/widgets.example.com`"),
            "{md}"
        );

        let json = render_package_diff_json(&d);
        let web = &json["changed"][0];
        assert_eq!(web["removed_resources"], json!([]));
        assert_eq!(
            web["kept_resources"],
            json!(["CustomResourceDefinition/widgets.example.com"])
        );
    }

    /// A removed package lists the protected resources it leaves behind
    /// apart from the ones it removes.
    #[test]
    fn a_removed_package_lists_its_kept_resources() {
        let mut old = baseline();
        old.push(crd("widgets.example.com", ("app", "web"), &h("crd")));
        let new = vec![
            record("c-old", &h("rec1")),
            cluster_level("Namespace", "app", &h("ns"), json!({})),
        ];
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&old, &new_graph);
        for d in [
            diff_garbage(&old_graph, &new_graph),
            diff_graphs(&old_graph, &new_graph),
        ] {
            assert_eq!(d.removed.len(), 1);
            let removed = d.removed[0].resource_count - 1;
            let text = render_package_plan(&d, true);
            assert!(
                text.contains(&format!("- web 1.0.0 ({removed} removed, 1 kept)")),
                "{text}"
            );
            assert!(
                text.contains("! CustomResourceDefinition/widgets.example.com (kept)"),
                "{text}"
            );
            let md = render_package_diff_markdown(&d);
            assert!(
                md.contains(&format!(
                    "({removed} removed, 1 kept)\n  - kept, never deleted automatically: `CustomResourceDefinition/widgets.example.com`"
                )),
                "{md}"
            );
            let json = render_package_diff_json(&d);
            assert_eq!(
                json["removed"][0]["kept_resources"],
                json!(["CustomResourceDefinition/widgets.example.com"])
            );
            assert_eq!(json["removed"][0]["resources"], json!(removed + 1));
        }
    }

    /// Added and removed packages share one JSON shape.
    #[test]
    fn an_added_package_has_an_empty_kept_list() {
        let mut new = baseline();
        new.push(package_instance("app", "api", "2.0.0", &h("pi2")));
        let json = render_package_diff_json(&diff_of(&baseline(), &new));
        assert_eq!(json["added"][0]["kept_resources"], json!([]));
    }

    /// A kept resource counts as kept in the resource totals, not as a real
    /// content change.
    #[test]
    fn resource_totals_count_a_kept_resource_once() {
        let mut old = baseline();
        old.push(crd("widgets.example.com", ("app", "web"), &h("crd")));
        let mut new = baseline();
        new.remove(3);
        let d = diff_of(&old, &new);
        let totals = d.resource_totals();
        assert_eq!((totals.real_content, totals.kept), (1, 1));
        let md = render_package_diff_markdown(&d);
        assert!(
            md.contains(
                "**Resources:** 1 with real content changes, 1 kept (never deleted automatically),"
            ),
            "{md}"
        );
    }

    #[test]
    fn a_prunable_resource_that_left_the_build_is_a_deletion() {
        let mut new = baseline();
        new.remove(3);
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&baseline(), &new_graph);
        let text = render_package_plan(&diff_garbage(&old_graph, &new_graph), true);
        assert!(text.contains("~ web 1.0.0 (1 removed)"), "{text}");
        assert!(text.contains("- ConfigMap/web@app"), "{text}");
    }

    #[test]
    fn renderers_carry_the_new_sections() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[1] = cluster_level("Namespace", "app", &h("ns2"), json!({"finalizers": ["x"]}));
        let d = diff_of(&baseline(), &new);

        let json = render_package_diff_json(&d);
        assert_eq!(json["cluster_level"]["key"], json!(CLUSTER_LEVEL_KEY));
        assert_eq!(json["activation"]["old"], json!("c-old"));
        assert_eq!(json["activation"]["new"], json!("c-new"));

        let md = render_package_diff_markdown(&d);
        assert!(md.contains("#### Cluster-level resources"), "{md}");
        assert!(md.contains("**Activation:** `c-old` → `c-new`"), "{md}");
    }
}

#[cfg(test)]
mod never_pruned_tests {
    use super::*;
    use kix::manifest::types::CLUSTER_SCOPED;

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
