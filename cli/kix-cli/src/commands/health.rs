//! `kix health` — drift detection between intended state and live cluster.
//!
//! Builds the cluster activation, normalizes manifests, fetches live state,
//! and compares content hashes to detect drift.

use miette::{Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::cluster::normalize::{self, DriftStatus};
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;

use crate::cli::HealthArgs;
use crate::output;

use super::CommandContext;

pub fn run(args: &HealthArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = super::deploy::resolve_flake_path(&ctx.global.flake)?;

    // 1. Build new activation and load store graph
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let result_path = build_cluster_activation_with_status(&flake_path, &args.cluster, &status)
        .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    stamp_annotations(&mut graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    // 2. Collect intended manifests
    let intended: Vec<Value> = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} manifests",
            output::bold(&graph.cluster_name),
            intended.len(),
        );
    }

    if intended.is_empty() {
        if !ctx.global.quiet {
            println!("No resources to check.");
        }
        return Ok(());
    }

    // 3. Connect and fetch live resources
    if !ctx.global.quiet {
        println!("Connecting to cluster...");
    }

    let reports = ctx.runtime.block_on(async {
        let client = fetch::make_client(ctx.global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect: {e}"))?;

        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("API discovery failed: {e}"))?;

        normalize::detect_drift(&client, &discovery, &intended)
            .await
            .map_err(|e| miette!("drift detection failed: {e}"))
    })?;

    // 4. Display results
    let in_sync = reports
        .iter()
        .filter(|r| matches!(r.status, DriftStatus::InSync))
        .count();
    let drifted: Vec<_> = reports
        .iter()
        .filter(|r| matches!(r.status, DriftStatus::Drifted { .. }))
        .collect();
    let missing: Vec<_> = reports
        .iter()
        .filter(|r| matches!(r.status, DriftStatus::Missing))
        .collect();

    if !ctx.global.quiet {
        println!();
    }

    if !missing.is_empty() {
        println!(
            "{} {} resources missing from cluster:",
            output::red("Missing:"),
            missing.len(),
        );
        for report in &missing {
            println!("  {} {}", output::red("!"), report.rid);
        }
        println!();
    }

    if !drifted.is_empty() {
        println!(
            "{} {} resources have drifted:",
            output::yellow("Drifted:"),
            drifted.len(),
        );
        for report in &drifted {
            println!("  {} {}", output::yellow("~"), report.rid);
            if ctx.global.verbose > 0
                && let DriftStatus::Drifted { diff } = &report.status
            {
                for line in diff.lines() {
                    if let Some(rest) = line.strip_prefix('+') {
                        println!("    {}{}", output::green("+"), output::green(rest));
                    } else if let Some(rest) = line.strip_prefix('-') {
                        println!("    {}{}", output::red("-"), output::red(rest));
                    } else {
                        println!("    {line}");
                    }
                }
                println!();
            }
        }
        if ctx.global.verbose == 0 && !drifted.is_empty() {
            println!(
                "  {}",
                output::dim("Use -v to show diffs for drifted resources.")
            );
        }
        println!();
    }

    // Summary
    let in_sync_str = in_sync.to_string();
    let drifted_str = drifted.len().to_string();
    let missing_str = missing.len().to_string();
    println!(
        "Health: {} in-sync, {} drifted, {} missing",
        output::green(&in_sync_str),
        if drifted.is_empty() {
            output::dim(&drifted_str)
        } else {
            output::yellow(&drifted_str)
        },
        if missing.is_empty() {
            output::dim(&missing_str)
        } else {
            output::red(&missing_str)
        },
    );

    if !drifted.is_empty() || !missing.is_empty() {
        std::process::exit(1);
    }

    Ok(())
}
