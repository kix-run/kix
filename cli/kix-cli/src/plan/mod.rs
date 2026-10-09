//! The plan as people read it: text for the terminal and Markdown for a PR
//! comment, for deploy, gc, diff, plan, and rollback.
//!
//! Package-grouped, changes-only output inspired by nvd (nix-version-diff).
//! Shows version changes per package and resource-level diffs in verbose mode.
//! The diff itself, [`kix::plan::PackageDiff`], and the plan document,
//! [`kix::plan::document::Plan`], come from the library; this module and
//! [`render`] only display them.

pub mod progress;
pub mod render;

use std::collections::BTreeMap;

use kix::cluster::fetch::SharedOrphan;
use kix::manifest::diff::DiffConfig;
use kix::manifest::diff::display::format_diffs;
use kix::manifest::types::ResourceId;
use kix::plan::{
    CLUSTER_LEVEL_KEY, PackageChangeDiff, PackageDiff, PackageInfo, split_never_pruned,
    without_secrets,
};

use crate::output;

// These are the canonical PackageDiff Markdown producers. The deploy modal,
// `kix diff`, rollback change summary, and the CI PR-comment GitHub Action
// all consume the same output here so formats stay in sync. See
// v2_discussions/84_m0_m1_implementation_plan.md §5.

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
            "**Activation:** `{}` → `{}`",
            a.old.as_deref().unwrap_or("(none)"),
            a.new.as_deref().unwrap_or("(none)"),
        );
        let _ = writeln!(out);
    }

    out
}

/// Print a package-grouped plan, on the way to an answer. Only shows
/// changes.
pub fn print_package_plan(diff: &PackageDiff, verbose: bool) {
    output::progress_text(&render_package_plan(diff, verbose));
}

/// The text `print_package_plan` prints.
pub fn render_package_plan(diff: &PackageDiff, verbose: bool) -> String {
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
                            let labels = diff.labels.get(id);
                            for (i, d) in diffs.iter().enumerate() {
                                let shown = without_secrets(change.secrets.contains(id), d);
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

/// The parenthesised count after a package name: `3 resources`, or for a
/// removed package that leaves kept resources behind, `2 removed, 1 kept`.
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

/// This binary, as a plan document names the Kix that made it: its own
/// crate version, not the library's.
pub fn kix_build() -> kix::plan::document::KixBuild {
    kix::plan::document::KixBuild::current(env!("CARGO_PKG_VERSION"))
}

/// What deletes the orphans a warn-only run keeps. Both work because the
/// record the run finalizes lists the builds they came from under
/// `status.orphansKeptFrom`.
pub const KEPT_ORPHANS_HINT: &str = "`kix deploy --prune` or `kix gc` deletes them";

/// The orphan lines of a deploy's or rollback's plan. `fate` says what the
/// run does with the orphans prune may delete; the kinds
/// `lifecycle::never_pruned` protects are listed apart and are never
/// counted as orphans.
pub fn render_plan_orphans(orphans: &[ResourceId], fate: &str) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    let (prunable, kept) = split_never_pruned(orphans.to_vec());
    if !prunable.is_empty() {
        let orphan_str = prunable.len().to_string();
        let _ = writeln!(out, "  {} orphaned ({fate})", output::red(&orphan_str));
        for rid in &prunable {
            let _ = writeln!(out, "    {} {}", output::red("-"), rid.display_id());
        }
    }
    out.push_str(&render_never_pruned(&kept));
    out
}

/// One line per orphan the prune keeps because another Kix cluster still
/// deploys it.
pub fn print_shared(shared: &[SharedOrphan]) {
    for s in shared {
        crate::say!("  {} prune: {}", output::yellow("="), s.describe());
    }
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
        crate::say!();
        crate::say!("  {}", output::green("Everything up to date."));
    } else if parts.is_empty() {
        crate::say!();
        crate::say!(
            "  Plan: {}",
            output::dim("only the activation record changes")
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
                "  Resources: {} real content{kept}, {} dep-affected",
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

    /// The `packages` section of the plan document for `diff`.
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

        let json = packages_json(&d, Detail::Plain);
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
            let json = packages_json(&d, Detail::Plain);
            assert_eq!(
                json["removed"][0]["kept_resources"],
                json!(["CustomResourceDefinition/widgets.example.com"])
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

        let json = packages_json(&d, Detail::Plain);
        assert_eq!(json["cluster_level"]["key"], json!(CLUSTER_LEVEL_KEY));
        assert_eq!(json["activation"]["old"], json!("c-old"));
        assert_eq!(json["activation"]["new"], json!("c-new"));

        let md = render_package_diff_markdown(&d);
        assert!(md.contains("#### Cluster-level resources"), "{md}");
        assert!(md.contains("**Activation:** `c-old` → `c-new`"), "{md}");
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
                kind: "ConfigMap".into(),
                name: "old".into(),
                namespace: "app".into(),
            },
            ResourceId {
                kind: "Namespace".into(),
                name: "gone".into(),
                namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
            },
        ];
        let text = render_plan_orphans(&orphans, "will be deleted");
        assert!(text.contains("1 orphaned (will be deleted)"), "{text}");
        assert!(text.contains("- ConfigMap/old@app"), "{text}");
        assert!(!text.contains("- Namespace"), "{text}");
        assert!(text.contains("! Namespace/gone"), "{text}");
    }
}
