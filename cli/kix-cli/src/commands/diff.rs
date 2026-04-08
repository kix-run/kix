use std::collections::BTreeMap;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::eval::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::diff::display::format_diffs;
use kix::manifest::diff::engine::structural_diff;
use kix::manifest::diff::{DiffConfig, Difference};
use kix::manifest::serialize::load_manifests_from_dir;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::cli::{DiffArgs, OutputFormat};
use crate::output;
use crate::plan::PackageDiff;

use super::CommandContext;

// ── Diff-specific types ──────────────────────────────────────────────

struct DiffResult {
    packages: PackageDiff,
    /// Flat resource list for non-graph old sides (live cluster / snapshot).
    legacy_resource_diff: Option<LegacyResourceDiff>,
    /// Detected stateful migration pairs (doc 67). Phase 1: informational only.
    migration_pairs: Vec<MigrationPair>,
}

/// Fallback for live-cluster or snapshot diffs where we don't have a store graph
/// on the old side — flat resource-level comparison.
struct LegacyResourceDiff {
    identical: usize,
    modified: Vec<(ResourceId, Vec<Difference>)>,
    kix_only: Vec<ResourceId>,
    cluster_only: Vec<ResourceId>,
}

// ── Entry point ──────────────────────────────────────────────────────

pub fn run(args: &DiffArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // Build new side
    let spinner = make_spinner(ctx, &format!("Building cluster '{}'...", args.cluster));
    let new_graph = build_store_graph(&flake_path, &args.cluster, &spinner)?;
    clear_spinner(&spinner);

    // Diff against old side
    let result = if let Some(from_path) = &args.from {
        // Build-to-build diff — both sides are store graphs
        let path = PathBuf::from(from_path);
        if !path.is_dir() {
            return Err(miette!("from directory does not exist: {from_path}"));
        }
        let old_spinner = make_spinner(ctx, "Loading old graph...");
        let old_graph = load_old_graph(&path, &old_spinner)?;
        clear_spinner(&old_spinner);
        diff_graphs(&old_graph, &new_graph)
    } else if let Some(snapshot_dir) = &args.snapshot {
        // Snapshot diff — old side is flat manifests
        let snapshot_path = Path::new(snapshot_dir);
        if !snapshot_path.is_dir() {
            return Err(miette!("snapshot directory does not exist: {snapshot_dir}"));
        }
        let old_manifests = load_manifests_from_dir(snapshot_path)
            .map_err(|e| miette!("failed to load snapshot directory: {e}"))?;
        diff_graph_vs_flat(&new_graph, &old_manifests)
    } else {
        // Live cluster
        let spinner = make_spinner(ctx, "Fetching live cluster state...");
        let global = ctx.global.clone();
        let old_manifests = ctx.runtime.block_on(fetch_live_manifests(&global))?;
        clear_spinner(&spinner);
        diff_graph_vs_flat(&new_graph, &old_manifests)
    };

    let has_diff = result_has_diff(&result);

    match ctx.output_format(OutputFormat::Text) {
        OutputFormat::Json => print_json_output(&result, false)?,
        OutputFormat::Yaml => print_json_output(&result, true)?,
        OutputFormat::Text => print_text_output(&result, &ctx.global),
    }

    if has_diff {
        std::process::exit(2);
    }

    Ok(())
}

// ── Graph construction ───────────────────────────────────────────────

fn build_store_graph(
    flake_path: &Path,
    cluster_name: &str,
    spinner: &Option<indicatif::ProgressBar>,
) -> Result<StoreGraph> {
    let status = |msg: &str| set_spinner(spinner, msg);

    let result_path = build_cluster_activation_with_status(flake_path, cluster_name, &status)
        .map_err(|e| miette!("failed to build cluster activation: {e}"))?;

    let mut graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;

    set_spinner(spinner, "Stamping annotations...");
    stamp_annotations(&mut graph);
    Ok(graph)
}

fn load_old_graph(path: &Path, spinner: &Option<indicatif::ProgressBar>) -> Result<StoreGraph> {
    let status = |msg: &str| set_spinner(spinner, msg);
    let mut graph = StoreGraph::from_result_dir_with_status(path, &status).into_diagnostic()?;
    set_spinner(spinner, "Stamping annotations...");
    stamp_annotations(&mut graph);
    Ok(graph)
}

fn set_spinner(spinner: &Option<indicatif::ProgressBar>, msg: &str) {
    if let Some(sp) = spinner {
        sp.set_message(msg.to_string());
    }
}

// ── Build-to-build diff (both sides are store graphs) ────────────────

fn diff_graphs(old: &StoreGraph, new: &StoreGraph) -> DiffResult {
    let new_manifests: Vec<Value> = new.resources.values().map(|n| n.manifest.clone()).collect();
    let old_manifests: Vec<Value> = old.resources.values().map(|n| n.manifest.clone()).collect();
    let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests);
    DiffResult {
        packages: crate::plan::diff_graphs(old, new),
        legacy_resource_diff: None,
        migration_pairs,
    }
}

// ── Graph vs flat manifests (live cluster / snapshot) ────────────────

fn diff_graph_vs_flat(new_graph: &StoreGraph, old_manifests: &[(ResourceId, Value)]) -> DiffResult {
    let config = DiffConfig::new("kix", "cluster");

    let new_map: BTreeMap<ResourceId, &Value> = new_graph
        .resources
        .values()
        .map(|n| (ResourceId::from_value(&n.manifest), &n.manifest))
        .collect();

    let old_map: BTreeMap<ResourceId, &Value> = old_manifests
        .iter()
        .map(|(id, v)| (id.clone(), v))
        .collect();

    let mut identical = 0usize;
    let mut modified = Vec::new();
    let mut kix_only = Vec::new();
    let mut cluster_only = Vec::new();

    for (id, new_val) in &new_map {
        if let Some(old_val) = old_map.get(id) {
            let diffs = structural_diff(new_val, old_val, "$", &config);
            if diffs.is_empty() {
                identical += 1;
            } else {
                modified.push((id.clone(), diffs));
            }
        } else {
            kix_only.push(id.clone());
        }
    }

    for id in old_map.keys() {
        if !new_map.contains_key(id) {
            cluster_only.push(id.clone());
        }
    }

    // Build package summary from new graph (no old graph available)
    let pkg_count = new_graph.packages.len();

    // Migration pair detection against the flat old side. Note: live-cluster
    // manifests may not carry kix.dev/lifecycle if they pre-date the stamp
    // (first deploy with this feature on). In that case no pairs fire — the
    // detector is fail-closed.
    let new_manifests: Vec<Value> = new_graph
        .resources
        .values()
        .map(|n| n.manifest.clone())
        .collect();
    let old_manifests_vec: Vec<Value> = old_manifests.iter().map(|(_, v)| v.clone()).collect();
    let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests_vec);

    DiffResult {
        packages: PackageDiff {
            added: Vec::new(),
            removed: Vec::new(),
            changed: Vec::new(),
            unchanged: pkg_count,
        },
        legacy_resource_diff: Some(LegacyResourceDiff {
            identical,
            modified,
            kix_only,
            cluster_only,
        }),
        migration_pairs,
    }
}

// ── Live cluster fetch ───────────────────────────────────────────────

async fn fetch_live_manifests(global: &crate::cli::GlobalArgs) -> Result<Vec<(ResourceId, Value)>> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| {
            miette!(
                "failed to connect to cluster: {e}. Check your kubeconfig or try --context <name>"
            )
        })?;

    if !global.quiet {
        eprintln!("Discovering API resources...");
    }

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    if !global.quiet {
        eprintln!(
            "Fetching managed resources ({} resource types)...",
            discovery.len()
        );
    }

    let objects = fetch::fetch_managed_resources(&client, &discovery)
        .await
        .map_err(|e| miette!("failed to fetch resources: {e}"))?;

    if !global.quiet {
        eprintln!("Fetched {} resources", objects.len());
    }

    let mut resources = Vec::new();
    for mut obj in objects {
        fetch::normalize_for_diff(&mut obj);
        let value = serde_json::to_value(&obj.data).into_diagnostic()?;
        let id = ResourceId::from_value(&value);
        resources.push((id, value));
    }

    Ok(resources)
}

// ── Helpers ──────────────────────────────────────────────────────────

fn result_has_diff(result: &DiffResult) -> bool {
    let pkg = &result.packages;
    if !pkg.added.is_empty() || !pkg.removed.is_empty() || !pkg.changed.is_empty() {
        return true;
    }
    if let Some(ref legacy) = result.legacy_resource_diff
        && (!legacy.modified.is_empty()
            || !legacy.kix_only.is_empty()
            || !legacy.cluster_only.is_empty())
    {
        return true;
    }
    if !result.migration_pairs.is_empty() {
        return true;
    }
    false
}

fn make_spinner(ctx: &CommandContext, msg: &str) -> Option<indicatif::ProgressBar> {
    if std::io::stderr().is_terminal() && !ctx.global.quiet {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message(msg.to_string());
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    }
}

fn clear_spinner(spinner: &Option<indicatif::ProgressBar>) {
    if let Some(sp) = spinner {
        sp.finish_and_clear();
    }
}

fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
    if flake.contains(':') {
        Ok(PathBuf::from(flake))
    } else {
        let path = PathBuf::from(flake);
        if path.is_absolute() {
            Ok(path)
        } else {
            let cwd = std::env::current_dir().into_diagnostic()?;
            Ok(cwd.join(path))
        }
    }
}

// ── Text output ──────────────────────────────────────────────────────

fn print_text_output(result: &DiffResult, global: &crate::cli::GlobalArgs) {
    let config = DiffConfig::new("old", "new");
    let color = output::color_enabled();
    let pkg = &result.packages;

    // Package-level summary
    let total_pkgs = pkg.added.len() + pkg.removed.len() + pkg.changed.len() + pkg.unchanged;
    if !global.quiet && total_pkgs > 0 {
        println!(
            "{} packages: {} unchanged, {} changed, {} added, {} removed",
            total_pkgs,
            pkg.unchanged,
            pkg.changed.len(),
            pkg.added.len(),
            pkg.removed.len(),
        );
        println!();
    }

    // Added packages
    for p in &pkg.added {
        let ver = p.version.as_deref().unwrap_or("(no version)");
        println!(
            "  {} {}@{} ({} resources)",
            output::green("+"),
            output::green(&p.key),
            ver,
            p.resource_count,
        );
    }
    if !pkg.added.is_empty() {
        println!();
    }

    // Removed packages
    for p in &pkg.removed {
        let ver = p.version.as_deref().unwrap_or("(no version)");
        println!(
            "  {} {}@{} ({} resources)",
            output::red("-"),
            output::red(&p.key),
            ver,
            p.resource_count,
        );
    }
    if !pkg.removed.is_empty() {
        println!();
    }

    // Changed packages — this is the main output
    for change in &pkg.changed {
        let old_ver = change.old_version.as_deref().unwrap_or("?");
        let new_ver = change.new_version.as_deref().unwrap_or("?");
        let ver_str = if old_ver != new_ver {
            format!("{old_ver} -> {new_ver}")
        } else {
            new_ver.to_string()
        };

        println!(
            "  {} {}@{}",
            output::yellow("~"),
            output::yellow(&change.key),
            ver_str,
        );

        for id in &change.added_resources {
            println!(
                "      {} {}",
                output::green("+"),
                output::green(&id.to_string())
            );
        }
        for id in &change.removed_resources {
            println!(
                "      {} {}",
                output::red("-"),
                output::red(&id.to_string())
            );
        }
        for (id, diffs) in &change.resource_diffs {
            println!(
                "      {} {}",
                output::yellow("~"),
                output::yellow(&id.to_string())
            );
            let formatted = format_diffs(diffs, &config, color, true);
            // Indent the diff output under the resource
            for line in formatted.lines() {
                println!("        {line}");
            }
        }
        println!();
    }

    // Legacy resource diff (live cluster / snapshot — no package grouping on old side)
    if let Some(ref legacy) = result.legacy_resource_diff {
        let total = legacy.identical
            + legacy.modified.len()
            + legacy.kix_only.len()
            + legacy.cluster_only.len();

        if !global.quiet {
            println!(
                "{} resources: {} identical, {} modified, {} kix-only, {} cluster-only",
                total,
                legacy.identical,
                legacy.modified.len(),
                legacy.kix_only.len(),
                legacy.cluster_only.len(),
            );
            println!();
        }

        if !legacy.modified.is_empty() {
            println!("{}", output::bold("Modified:"));
            let live_config = DiffConfig::new("kix", "cluster");
            for (id, diffs) in &legacy.modified {
                println!("  {}", output::yellow(&id.to_string()));
                let formatted = format_diffs(diffs, &live_config, color, true);
                println!("{formatted}");
            }
            println!();
        }

        if !legacy.kix_only.is_empty() {
            println!("{}", output::bold("Only in kix (will be created):"));
            for id in &legacy.kix_only {
                println!("  {}", output::green(&id.to_string()));
            }
            println!();
        }

        if !legacy.cluster_only.is_empty() {
            println!("{}", output::bold("Only in cluster (not managed by kix):"));
            for id in &legacy.cluster_only {
                println!("  {}", output::red(&id.to_string()));
            }
            println!();
        }
    }

    // Stateful migration pairs (doc 67)
    print_migration_pairs(&result.migration_pairs);

    if !result_has_diff(result) {
        println!("{}", output::green("No differences found."));
    }
}

/// Render detected stateful migration pairs. Phase 1 is informational:
/// we tell the user what kix *would* migrate — no execution. See doc 67 §9.
fn print_migration_pairs(pairs: &[MigrationPair]) {
    if pairs.is_empty() {
        return;
    }
    println!(
        "{}",
        output::bold(&format!("Stateful migrations detected ({}):", pairs.len()))
    );
    for p in pairs {
        println!("  {} {}", output::yellow("~"), output::yellow(&p.summary()));
        println!(
            "      source: {}/{}/{}",
            p.source.kind, p.source.namespace, p.source.name
        );
        println!(
            "      target: {}/{}/{}",
            p.target.kind, p.target.namespace, p.target.name
        );
    }
    println!();
    println!(
        "{}",
        output::yellow(
            "Note: data migration is NOT yet automated. See v2_discussions/67_stateful_migration_orchestration.md."
        )
    );
    println!();
}

// ── JSON output ──────────────────────────────────────────────────────

fn print_json_output(result: &DiffResult, as_yaml: bool) -> Result<()> {
    let pkg = &result.packages;
    let mut output = serde_json::json!({
        "packages": {
            "added": pkg.added.iter().map(|p| serde_json::json!({
                "key": p.key, "version": p.version, "resources": p.resource_count,
            })).collect::<Vec<_>>(),
            "removed": pkg.removed.iter().map(|p| serde_json::json!({
                "key": p.key, "version": p.version, "resources": p.resource_count,
            })).collect::<Vec<_>>(),
            "changed": pkg.changed.iter().map(|c| serde_json::json!({
                "key": c.key,
                "old_version": c.old_version,
                "new_version": c.new_version,
                "added_resources": c.added_resources.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
                "removed_resources": c.removed_resources.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
                "modified_resources": c.resource_diffs.iter().map(|(id, diffs)| serde_json::json!({
                    "resource": id.display_id(),
                    "diff_count": diffs.len(),
                })).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
            "unchanged": pkg.unchanged,
        },
    });

    if !result.migration_pairs.is_empty() {
        output["migration_pairs"] = serde_json::Value::Array(
            result
                .migration_pairs
                .iter()
                .map(|p| {
                    serde_json::json!({
                        "slot": p.slot,
                        "source": p.source.display_id(),
                        "target": p.target.display_id(),
                        "reason": p.reason,
                    })
                })
                .collect(),
        );
    }

    if let Some(ref legacy) = result.legacy_resource_diff {
        output["resources"] = serde_json::json!({
            "identical": legacy.identical,
            "modified": legacy.modified.iter().map(|(id, diffs)| serde_json::json!({
                "resource": id.display_id(),
                "diff_count": diffs.len(),
            })).collect::<Vec<_>>(),
            "kix_only": legacy.kix_only.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
            "cluster_only": legacy.cluster_only.iter().map(|id| id.display_id()).collect::<Vec<_>>(),
        });
    }

    if as_yaml {
        print!("{}", serde_yml::to_string(&output).into_diagnostic()?);
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&output).into_diagnostic()?
        );
    }
    Ok(())
}
