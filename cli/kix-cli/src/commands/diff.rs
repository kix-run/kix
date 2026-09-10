use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::eval::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::serialize::load_manifests_from_dir;
use kix::manifest::stamp::stamp_annotations;

use crate::cli::{DiffArgs, OutputFormat};
use crate::output;
use crate::plan::{self, PackageDiff};

use super::CommandContext;

// ── Diff-specific types ──────────────────────────────────────────────

struct DiffResult {
    packages: PackageDiff,
    /// Detected stateful migration pairs (doc 67). Phase 1: informational only.
    migration_pairs: Vec<MigrationPair>,
}

impl DiffResult {
    fn has_diff(&self) -> bool {
        self.packages.has_changes() || !self.migration_pairs.is_empty()
    }
}

// ── Entry point ──────────────────────────────────────────────────────

/// Every mode is one comparison of two store graphs. The new side is
/// always a build. The old side is a build result when `--from` names one,
/// and otherwise a graph synthesized from stamped manifests: a manifest
/// directory (`--from` a snapshot or export), or the live cluster's
/// kix-owned view. Same renderers as the deploy plan, so what `kix diff`
/// shows is what `kix deploy` will show.
pub fn run(args: &DiffArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    let spinner = make_spinner(ctx, &format!("Building cluster '{}'...", args.cluster));
    let overrides = ctx.global.input_overrides();
    let new_graph = build_store_graph(&flake_path, &args.cluster, &overrides, &spinner)?;
    clear_spinner(&spinner);

    let old_graph = if let Some(from) = &args.from {
        let path = PathBuf::from(from);
        if !path.is_dir() {
            return Err(miette!("from directory does not exist: {from}"));
        }
        let spinner = make_spinner(ctx, "Loading old side...");
        let graph = if path.join("kix-packages.json").is_file() {
            load_old_graph(&path, &spinner)?
        } else {
            let manifests: Vec<Value> = load_manifests_from_dir(&path)
                .map_err(|e| miette!("failed to load manifest directory {from}: {e}"))?
                .into_iter()
                .map(|(_, v)| v)
                .collect();
            StoreGraph::synthesize(&manifests, &new_graph)
        };
        clear_spinner(&spinner);
        graph
    } else {
        let spinner = make_spinner(ctx, "Fetching live cluster state...");
        let global = ctx.global.clone();
        let manifests = ctx.runtime.block_on(fetch_live_manifests(&global))?;
        clear_spinner(&spinner);
        StoreGraph::synthesize(&manifests, &new_graph)
    };

    let result = diff_graphs(&old_graph, &new_graph);

    match ctx.output_format(OutputFormat::Text) {
        OutputFormat::Json => print_json_output(&result, false)?,
        OutputFormat::Yaml => print_json_output(&result, true)?,
        OutputFormat::Markdown => print_markdown_output(&result),
        OutputFormat::Text => print_text_output(&result, &ctx.global),
    }

    if result.has_diff() {
        std::process::exit(2);
    }

    Ok(())
}

// ── Graph construction ───────────────────────────────────────────────

fn build_store_graph(
    flake_path: &Path,
    cluster_name: &str,
    input_overrides: &[(String, String)],
    spinner: &Option<indicatif::ProgressBar>,
) -> Result<StoreGraph> {
    let status = |msg: &str| set_spinner(spinner, msg);

    let result_path =
        build_cluster_activation_with_status(flake_path, cluster_name, input_overrides, &status)
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

fn diff_graphs(old: &StoreGraph, new: &StoreGraph) -> DiffResult {
    let new_manifests: Vec<Value> = new.resources.values().map(|n| n.manifest.clone()).collect();
    let old_manifests: Vec<Value> = old.resources.values().map(|n| n.manifest.clone()).collect();
    // Fail-closed: live objects that predate the lifecycle stamp carry no
    // `kix.run/lifecycle`, and then no pairs fire.
    let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests);
    DiffResult {
        packages: plan::diff_graphs(old, new),
        migration_pairs,
    }
}

// ── Live cluster fetch ───────────────────────────────────────────────

async fn fetch_live_manifests(global: &crate::cli::GlobalArgs) -> Result<Vec<Value>> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    if !global.quiet {
        eprintln!("Discovering API resources...");
    }

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    // The gate. `kix diff` reads no Activation record, so it never reaches
    // the check inside `find_activation_ar` that every other cluster command
    // goes through. It still needs one: the live objects below are upgraded
    // to the current domain before they are compared, which on an
    // unmigrated cluster renames the live `activations.<retired>` CRD to the
    // name the build uses and reports it as matching. The answer would be
    // "in sync" about a resource that does not exist under that name.
    kix::legacy_domain::check_cluster(
        &discovery
            .iter()
            .filter(|(ar, _)| kix::manifest::lifecycle::is_record_kind(&ar.kind))
            .map(|(ar, _)| ar.group.as_str())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| miette!("{e}"))?;

    if !global.quiet {
        eprintln!(
            "Fetching managed resources ({} resource types)...",
            discovery.len()
        );
    }

    let sweep = fetch::sweep_managed(&client, &discovery)
        .await
        .map_err(|e| miette!("failed to fetch resources: {e}"))?;

    if !global.quiet {
        eprintln!(
            "Fetched {} resources across {} resource types{}",
            sweep.managed.len(),
            discovery.len() - sweep.forbidden.len(),
            crate::output::forbidden_note(&sweep.forbidden),
        );
    }

    // Only the fields kix's server-side apply owns: server defaults and
    // kix's own bookkeeping never enter the comparison.
    Ok(fetch::kix_owned_manifests(sweep.managed))
}

// ── Helpers ──────────────────────────────────────────────────────────

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
    let pkg = &result.packages;

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
    }

    // The deploy plan renderer, always with resource-level detail: a diff
    // exists to be read.
    plan::print_package_plan(pkg, true);

    if let Some(a) = &pkg.activation {
        println!();
        println!(
            "  {} {} -> {}",
            output::bold("Activation:"),
            output::dim(a.old.as_deref().unwrap_or("(none)")),
            output::green(a.new.as_deref().unwrap_or("(none)")),
        );
    }

    if pkg.has_changes() {
        println!();
    }

    print_migration_pairs(&result.migration_pairs);

    if !result.has_diff() {
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
    // Shared PackageDiff renderer — same structure produced by the deploy
    // modal and the CI PR-comment action. Migration pairs are appended.
    let mut output = serde_json::json!({
        "packages": plan::render_package_diff_json(&result.packages),
    });

    if !result.migration_pairs.is_empty() {
        output["migration_pairs"] = Value::Array(
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

// ── Markdown output (GitHub PR comment format) ──────────────────────

fn print_markdown_output(result: &DiffResult) {
    // Shared package-level renderer. Same producer used by the deploy
    // modal and the CI PR-comment GitHub Action so they stay in sync.
    print!("{}", plan::render_package_diff_markdown(&result.packages));

    if !result.migration_pairs.is_empty() {
        println!(
            "#### Stateful migrations detected ({})",
            result.migration_pairs.len()
        );
        println!();
        for p in &result.migration_pairs {
            println!("- **{}**", p.summary());
            println!(
                "  - source: `{}/{}/{}`",
                p.source.kind, p.source.namespace, p.source.name
            );
            println!(
                "  - target: `{}/{}/{}`",
                p.target.kind, p.target.namespace, p.target.name
            );
        }
        println!();
        println!(
            "> :warning: Data migration is **not** yet automated. See `v2_discussions/67_stateful_migration_orchestration.md`."
        );
        println!();
    }

    if !result.has_diff() {
        println!("No differences found.");
    }
}
