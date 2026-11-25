//! Terminal text and GitHub-flavored Markdown rendering for `kix plan`,
//! `kix diff`, `kix deploy`, `kix gc`, and `kix rollback`.
//!
//! Renders package-grouped, changes-only summaries (inspired by `nvd`) with
//! resource-level diffs in verbose mode. The underlying diff
//! ([`kix::plan::PackageDiff`]) and plan document
//! ([`kix::plan::document::Plan`]) are computed in `kix`; this module and
//! [`render`] format them for display.

pub mod migrations;
pub mod progress;
pub mod render;

use std::collections::BTreeMap;
use std::io::{BufReader, BufWriter};
use std::path::Path;

use miette::miette;

use kix::cluster::apply::{ChangeAction, RerunReason};
use kix::cluster::inventory::SharedOrphan;
use kix::cluster::scheduler::{DeployPlan, PrunePolicy};
use kix::cluster::stream::NodeId;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::diff::DiffConfig;
use kix::manifest::diff::display::format_diffs;
use kix::manifest::types::ResourceId;
use kix::plan::document::{Plan, PlanFlags};
use kix::plan::file;
use kix::plan::{
    CLUSTER_LEVEL_KEY, CheckedPlan, PackageChangeDiff, PackageDiff, PackageInfo,
    split_never_pruned, without_secrets,
};

use crate::output;

/// Write `doc` (a plan generated at `--detail manifests`) and the dependency
/// graph of `build` to `path` as a `.kixplan` file, returning its SHA-256 hex
/// digest.
///
/// Writes to a temporary file in the same directory, verifies it with
/// [`file::PlanFile::verify`], and atomically renames it into place so an
/// invalid plan file is never left at `path`.
pub(crate) fn save(doc: Plan, build: &StoreGraph, path: &Path) -> miette::Result<String> {
    let graph = file::graph_of(build).map_err(|e| miette!("{e}"))?;
    let dir = match path.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => Path::new("."),
    };
    let mut temp = tempfile::NamedTempFile::new_in(dir)
        .map_err(|e| miette!("cannot write in {}: {e}", dir.display()))?;
    file::write(doc, graph, BufWriter::new(temp.as_file_mut())).map_err(|e| {
        if e.kind() == std::io::ErrorKind::InvalidInput {
            miette!(
                "cannot write plan file {path}: {e}; {path} was not written. Next: plan fewer objects in this cluster, or run `kix plan` or `kix diff` without `--out`.",
                path = path.display()
            )
        } else {
            miette!("cannot write the plan {}: {e}", path.display())
        }
    })?;
    let stored = temp
        .as_file()
        .metadata()
        .map_err(|e| miette!("cannot read back the plan {}: {e}", path.display()))?
        .len();
    if stored > file::MAX_STORED_BYTES {
        return Err(miette!(
            "cannot write plan file {path}: the saved file would be {stored} bytes, over the 64 MiB limit ({} bytes); {path} was not written. Next: plan fewer objects in this cluster, or run `kix plan` or `kix diff` without `--out`.",
            file::MAX_STORED_BYTES,
            path = path.display()
        ));
    }
    let written = std::fs::File::open(temp.path())
        .map_err(|e| miette!("cannot read back the plan {}: {e}", path.display()))?;
    let (_, sha256) = file::PlanFile::verify(BufReader::new(written))
        .map_err(|e| miette!("the plan did not make a valid plan file: {e}"))?;
    temp.persist(path)
        .map_err(|e| miette!("cannot write the plan {}: {e}", path.display()))?;
    Ok(sha256)
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
        parts.push(format!(
            "{} tracking annotation only",
            c.dep_affected_resources.len()
        ));
    }
    let detail = if parts.is_empty() {
        String::new()
    } else {
        format!(" ({})", parts.join(", "))
    };

    let _ = writeln!(out, "<details>");
    let _ = writeln!(
        out,
        "<summary><code>{}</code> {}{detail}</summary>",
        output::printable(&c.key),
        output::printable(&ver_str)
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
        let _ = writeln!(
            out,
            "**Tracking annotation only (dependency changed, no spec change or restart):**"
        );
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
            "**Resources:** {} changed in content{kept}, {} tracking annotation only (no spec change or restart)",
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
                .map(|v| format!(" `{}`", output::printable(v)))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "- `{}`{ver} ({})",
                output::printable(&p.key),
                counts(p)
            );
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
                .map(|v| format!(" `{}`", output::printable(v)))
                .unwrap_or_default();
            let _ = writeln!(
                out,
                "- `{}`{ver} ({})",
                output::printable(&p.key),
                counts(p)
            );
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
            "**Deployment record:** `{}` → `{}`",
            a.old.as_deref().unwrap_or("(none)"),
            a.new.as_deref().unwrap_or("(none)"),
        );
        let _ = writeln!(out);
    }

    out
}

/// Print a package-grouped plan showing only changed packages.
pub fn print_package_plan(diff: &PackageDiff, verbose: bool) {
    output::progress_text(&render_package_plan(diff, verbose));
}

/// Render the package-grouped text plan printed by [`print_package_plan`].
pub fn render_package_plan(diff: &PackageDiff, verbose: bool) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    let color = output::color_enabled();
    let config = DiffConfig::new("old", "new");

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
        let _ = writeln!(out, "  {}", output::bold(&output::printable(ns)));
        for entry in entries {
            match entry {
                PlanEntry::Added(name, info) => {
                    let name = &output::printable(name);
                    let ver = &output::printable(info.version.as_deref().unwrap_or(""));
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
                    let name = &output::printable(name);
                    let ver = &output::printable(info.version.as_deref().unwrap_or(""));
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
                        counts(info),
                    );
                    if verbose {
                        for id in &info.kept {
                            write_kept_line(&mut out, id);
                        }
                    }
                }
                PlanEntry::Changed(name, change) => {
                    let name = &output::printable(name);
                    let old_ver = &output::printable(change.old_version.as_deref().unwrap_or(""));
                    let new_ver = &output::printable(change.new_version.as_deref().unwrap_or(""));
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
                            "{} tracking annotation only",
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
                            let labels = diff.labels.get(id);
                            for (i, d) in diffs.iter().enumerate() {
                                let shown = without_secrets(
                                    id.group_kind() == kix::manifest::kinds::SECRET,
                                    d,
                                );
                                let formatted = format_diffs(
                                    std::slice::from_ref(&shown),
                                    &config,
                                    color,
                                    true,
                                );
                                let tag = labels
                                    .and_then(|l| l.get(i))
                                    .map(|l| render::label_tag(l))
                                    .unwrap_or_default();
                                for (n, line) in formatted.lines().enumerate() {
                                    if n == 0 && !tag.is_empty() {
                                        let _ = writeln!(out, "        {line}  {tag}");
                                    } else {
                                        let _ = writeln!(out, "        {line}");
                                    }
                                }
                            }
                        }
                        for id in &change.dep_affected_resources {
                            let _ = writeln!(
                                out,
                                "      {} {} {}",
                                output::dim("~"),
                                output::dim(&id.to_string()),
                                output::dim(
                                    "(tracking annotation only; no spec change or restart)"
                                ),
                            );
                        }
                    }
                }
            }
        }
    }
    out
}

/// Format the resource count summary for `info` (e.g., `3 resources` or
/// `2 removed, 1 kept`).
fn counts(info: &PackageInfo) -> String {
    if info.kept.is_empty() {
        return format!("{} resources", info.resource_count);
    }
    let removed = info.resource_count - info.kept.len();
    if removed == 0 {
        format!("{} kept", info.kept.len())
    } else {
        format!("{removed} removed, {} kept", info.kept.len())
    }
}

/// Write a line for a resource that left the build but is never deleted
/// automatically.
fn write_kept_line(out: &mut String, id: &ResourceId) {
    use std::fmt::Write;
    let _ = writeln!(
        out,
        "      {} {} {}",
        output::yellow("!"),
        output::yellow(&id.to_string()),
        output::dim("(kept; never deleted automatically)"),
    );
}

/// Print resources that left the build and are retained because deleting them
/// would also delete objects outside the build.
/// Why the objects a never-pruned list shows are candidates for deletion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeptFrom {
    /// They were in an earlier build of this cluster and left it.
    LeftTheBuild,
    /// A full scan found them on the cluster. Some may never have been in
    /// this cluster's build, such as objects that name no deployment record.
    FullScan,
}

pub fn print_never_pruned(kept: &[ResourceId], from: KeptFrom) {
    print!("{}", render_never_pruned(kept, from));
}

/// Render the objects kept because Kix never deletes their kind, with a
/// heading that says why they came up for deletion only where `from` makes
/// that true.
pub fn render_never_pruned(kept: &[ResourceId], from: KeptFrom) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    if kept.is_empty() {
        return out;
    }
    let _ = writeln!(out);
    let count = kept.len();
    let what = match from {
        KeptFrom::LeftTheBuild => format!("{count} left the build, never deleted automatically"),
        KeptFrom::FullScan => format!("{count} never deleted automatically"),
    };
    let _ = writeln!(out, "{} ({what}):", output::bold("Kept on the cluster"));
    for rid in kept {
        let _ = writeln!(out, "    {} {}", output::yellow("!"), rid);
    }
    let _ = writeln!(
        out,
        "  {}",
        output::dim(
            "Deleting a Namespace deletes every resource in it, and deleting a \
             CustomResourceDefinition deletes every resource of that kind. \
             Delete them with `kubectl` if that is intended."
        ),
    );
    out
}

/// Return the [`kix::plan::document::KixBuild`] metadata for this CLI binary.
pub fn kix_build() -> kix::plan::document::KixBuild {
    kix::plan::document::KixBuild::current(&kix::version::running().to_string())
}

/// Print the plan every command that deploys shows for `checked`: the
/// package plan and its summary, the Jobs that run again, and the orphans,
/// with what happens to them (`fate`).
pub fn print_checked(checked: &CheckedPlan, fate: &str, verbose: bool) {
    print_package_plan(checked.pkg_diff(), verbose);
    print_plan_summary(checked.pkg_diff());
    print_reruns(
        checked.plan(),
        &[RerunReason::Changed, RerunReason::LastRunFailed],
    );
    output::progress_text(&render_plan_orphans(checked.orphans(), fate));
}

/// Return what a run of a plan made with `flags` does with the orphans of
/// `cluster`. `connected` says whether the plan has read the cluster.
pub fn orphans_fate(flags: PlanFlags, connected: bool, cluster: &str) -> String {
    match flags.prune {
        PrunePolicy::Skip => {
            "still on the cluster (`--skip-orphan-check`, not deleted)".to_string()
        }
        // A plan that has not read the cluster cannot yet tell which orphans
        // another Kix cluster deploys.
        PrunePolicy::Delete if !connected => "to be deleted after the apply (`--prune`) except \
            any still deployed by another Kix cluster (checked once connected)"
            .to_string(),
        PrunePolicy::Delete => "to be deleted after the apply (`--prune`)".to_string(),
        PrunePolicy::WarnOnly => kept_orphans_fate(cluster),
    }
}

/// Return the fate of orphans a deploy of `cluster` keeps without `--prune`.
/// The new Activation records them under `status.orphansKeptFrom`.
pub fn kept_orphans_fate(cluster: &str) -> String {
    format!(
        "still on the cluster; `kix deploy {cluster} --prune` or `kix gc {cluster}` deletes them"
    )
}

/// Render the orphaned and protected-resource sections of a deploy or rollback
/// plan. `fate` describes how prunable orphans will be handled, while kinds
/// protected by `lifecycle::never_pruned` are listed separately.
pub fn render_plan_orphans(orphans: &[ResourceId], fate: &str) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    let (prunable, kept) = split_never_pruned(orphans.to_vec());
    if !prunable.is_empty() {
        let orphan_str = prunable.len().to_string();
        let _ = writeln!(
            out,
            "  {} object(s) left the build, {fate}:",
            output::red(&orphan_str)
        );
        for rid in &prunable {
            let _ = writeln!(out, "    {} {}", output::red("-"), rid.display_id());
        }
    }
    out.push_str(&render_never_pruned(&kept, KeptFrom::LeftTheBuild));
    out
}

/// Print each orphan retained because another Kix cluster still deploys it.
pub fn print_shared(shared: &[SharedOrphan]) {
    for s in shared {
        crate::say!("  {} prune: {}", output::yellow("="), s.describe());
    }
}

/// Print the Jobs under `kix.run/rerun` that `plan` deletes and recreates so
/// they run again for one of `reasons`, grouped by the reason.
pub fn print_reruns(plan: &DeployPlan, reasons: &[RerunReason]) {
    for (reason, why) in [
        (RerunReason::Changed, "changed their own content"),
        (RerunReason::LastRunFailed, "failed on their last run"),
    ] {
        if !reasons.contains(&reason) {
            continue;
        }
        let jobs: Vec<String> = plan
            .nodes()
            .iter()
            .filter_map(|n| match (&n.action, &n.id) {
                (ChangeAction::Recreate(_, r), NodeId::Resource(rid)) if *r == reason => {
                    Some(rid.to_string())
                }
                _ => None,
            })
            .collect();
        if !jobs.is_empty() {
            crate::say!(
                "  {} {} Job(s) with {} {why} and will be deleted and recreated so they run again: {}",
                output::yellow("↻"),
                jobs.len(),
                kix::manifest::keys::RERUN,
                jobs.join(", "),
            );
        }
    }
}

/// Print plan summary line.
pub fn print_plan_summary(diff: &PackageDiff) {
    let updated = diff.changed.len();
    let added = diff.added.len();
    let removed = diff.removed.len();

    let totals = diff.resource_totals();

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
    if diff.cluster_level.is_some() {
        let s = if parts.is_empty() {
            "cluster-level changes"
        } else {
            "plus cluster-level changes"
        };
        parts.push(output::yellow(s).into_owned());
    }

    if parts.is_empty() && diff.activation.is_none() {
        crate::say!();
        crate::say!("  {}", output::green("Everything up to date."));
    } else if parts.is_empty() {
        crate::say!();
        crate::say!(
            "  Plan: {}",
            output::dim("only the deployment record changes (no object changes)")
        );
    } else {
        crate::say!();
        crate::say!("  Plan: {}", parts.join(", "));
        if totals.any() {
            let kept = if totals.kept > 0 {
                format!(", {} kept", totals.kept)
            } else {
                String::new()
            };
            let res_line = format!(
                "  Resources: {} changed in content{kept}, {} tracking annotation only (no spec change or restart)",
                totals.real_content, totals.dep_affected,
            );
            crate::say!("{}", output::dim(&res_line));
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
mod render_tests {
    use super::*;
    use kix::eval::store_graph::StoreGraph;
    use kix::plan::document::{Detail, Packages};
    use kix::plan::fixtures::*;
    use kix::plan::{ManifestIndex, diff_garbage, diff_graphs};
    use serde_json::{Value, json};

    /// Serialize the `packages` section of the plan document for `diff`.
    fn packages_json(diff: &PackageDiff, detail: Detail) -> Value {
        serde_json::to_value(Packages::of(diff, detail)).expect("packages serialize")
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
            text.contains(
                "! CustomResourceDefinition.apiextensions.k8s.io/widgets.example.com (kept; never deleted automatically)"
            ),
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
            md.contains("**Left the build, never deleted automatically:**\n\n- `CustomResourceDefinition.apiextensions.k8s.io/widgets.example.com`"),
            "{md}"
        );

        let json = packages_json(&d, Detail::Plain);
        let web = &json["changed"][0];
        assert_eq!(web["removed_resources"], json!([]));
        assert_eq!(
            web["kept_resources"],
            json!(["CustomResourceDefinition.apiextensions.k8s.io/widgets.example.com"])
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
                text.contains("! CustomResourceDefinition.apiextensions.k8s.io/widgets.example.com (kept; never deleted automatically)"),
                "{text}"
            );
            let md = render_package_diff_markdown(&d);
            assert!(
                md.contains(&format!(
                    "({removed} removed, 1 kept)\n  - kept, never deleted automatically: `CustomResourceDefinition.apiextensions.k8s.io/widgets.example.com`"
                )),
                "{md}"
            );
            let json = packages_json(&d, Detail::Plain);
            assert_eq!(
                json["removed"][0]["kept_resources"],
                json!(["CustomResourceDefinition.apiextensions.k8s.io/widgets.example.com"])
            );
            assert_eq!(json["removed"][0]["resources"], json!(removed + 1));
        }
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
                "**Resources:** 1 changed in content, 1 kept (never deleted automatically),"
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

        let json = packages_json(&d, Detail::Plain);
        assert_eq!(json["cluster_level"]["key"], json!(CLUSTER_LEVEL_KEY));
        assert_eq!(json["activation"]["old"], json!("c-old"));
        assert_eq!(json["activation"]["new"], json!("c-new"));

        let md = render_package_diff_markdown(&d);
        assert!(md.contains("#### Cluster-level resources"), "{md}");
        assert!(
            md.contains("**Deployment record:** `c-old` → `c-new`"),
            "{md}"
        );
    }

    /// An object of another API group with kind Secret is not a Kubernetes
    /// Secret: its values show in the field changes, the manifests, and
    /// the text plan.
    #[test]
    fn a_custom_resource_named_secret_shows_its_values() {
        let custom = |hash: &str, value: &str| {
            let mut v = web_resource("Secret", hash, json!({"data": {"password": value}}));
            v["apiVersion"] = json!("x.example/v1");
            v
        };
        let mut old = baseline();
        old.push(custom(&h("s1"), "old-value"));
        let mut new = baseline();
        new.push(custom(&h("s2"), "new-value"));
        let (old_graph, new_graph) = graphs_of(&old, &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let manifests = ManifestIndex::new(&old_graph, &new_graph);
        for shown in [
            packages_json(&d, Detail::Fields).to_string(),
            packages_json(&d, Detail::Manifests(&manifests)).to_string(),
            render_package_plan(&d, true),
        ] {
            assert!(
                shown.contains("old-value") && shown.contains("new-value"),
                "{shown}"
            );
        }
    }

    /// A deploy's plan counts a Namespace orphan as kept, not as an orphan.
    #[test]
    fn plan_orphans_list_a_namespace_as_kept() {
        let orphans = [
            ResourceId {
                group: String::new(),
                kind: "ConfigMap".into(),
                name: "old".into(),
                namespace: "app".into(),
            },
            ResourceId {
                group: String::new(),
                kind: "Namespace".into(),
                name: "gone".into(),
                namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
            },
        ];
        let text = render_plan_orphans(&orphans, "to be deleted after the apply (`--prune`)");
        assert!(
            text.contains("1 object(s) left the build, to be deleted after the apply (`--prune`):"),
            "{text}"
        );
        assert!(text.contains("- ConfigMap/old@app"), "{text}");
        assert!(!text.contains("- Namespace"), "{text}");
        assert!(text.contains("! Namespace/gone"), "{text}");
    }
}

#[cfg(test)]
mod never_pruned_tests {
    use super::*;

    /// A full scan may keep a Namespace that was never in this cluster's
    /// build, so only a list of objects that left the build says they did.
    #[test]
    fn only_objects_that_left_the_build_are_said_to_have_left_it() {
        let ns = ResourceId {
            group: String::new(),
            kind: "Namespace".into(),
            namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
            name: "second".into(),
        };
        let left = render_never_pruned(std::slice::from_ref(&ns), KeptFrom::LeftTheBuild);
        assert!(
            left.contains("1 left the build, never deleted automatically"),
            "{left}"
        );
        let scan = render_never_pruned(std::slice::from_ref(&ns), KeptFrom::FullScan);
        assert!(scan.contains("(1 never deleted automatically)"), "{scan}");
        assert!(!scan.contains("left the build"), "{scan}");
    }
}
