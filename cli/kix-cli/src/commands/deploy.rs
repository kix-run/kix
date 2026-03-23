//! `kix deploy` — wave-based deployment with confirmation.

use std::io::Write;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};

use kix_cluster::apply::{ApplyAction, ChangeAction};
use kix_cluster::fetch;
use kix_cluster::graph::ResourceGraph;
use kix_cluster::readiness::{self, ReadinessResult};
use kix_cluster::waves::compute_waves;
use kix_manifest::types::ResourceId;

use crate::cli::{DeployArgs, OnError};
use crate::output;

use super::CommandContext;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    // 1. Eval cluster
    let cluster = ctx
        .evaluator
        .eval_cluster(&args.cluster)
        .into_diagnostic()?;
    let manifest_count = cluster.raw_manifests.len();

    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} manifests",
            output::bold(&cluster.name),
            manifest_count,
        );
    }

    if manifest_count == 0 {
        println!("Nothing to deploy.");
        return Ok(());
    }

    // 2. Build DAG
    let graph = ResourceGraph::from_manifests(&cluster.raw_manifests).into_diagnostic()?;

    // 3. Compute waves
    let waves = compute_waves(&graph);

    if waves.is_empty() {
        println!("No resources to deploy.");
        return Ok(());
    }

    let global = ctx.global.clone();
    ctx.runtime.block_on(run_deploy_async(
        args,
        &global,
        &graph,
        &waves,
        &cluster.raw_manifests,
    ))
}

async fn run_deploy_async(
    args: &DeployArgs,
    global: &crate::cli::GlobalArgs,
    graph: &ResourceGraph,
    waves: &[Vec<petgraph::graph::NodeIndex>],
    raw_manifests: &[serde_json::Value],
) -> Result<()> {
    let timeout = parse_timeout(args.timeout.as_deref())?;
    let _ = raw_manifests; // manifests accessed via graph nodes

    // Build wave manifests: Vec<Vec<&Value>> indexed by wave
    let wave_manifests: Vec<Vec<&serde_json::Value>> = waves
        .iter()
        .map(|wave| wave.iter().map(|&idx| &graph.graph[idx].manifest).collect())
        .collect();

    // 4. If not dry-run, fetch live state and detect changes
    let wave_actions: Vec<Vec<ChangeAction>> = if args.dry_run {
        // In dry-run mode, treat everything as Apply
        wave_manifests
            .iter()
            .map(|wave| {
                wave.iter()
                    .map(|m| ChangeAction::Apply((*m).clone()))
                    .collect()
            })
            .collect()
    } else {
        // Fetch live state
        if !global.quiet {
            println!("Fetching live cluster state...");
        }
        let client = fetch::make_client(global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("API discovery failed: {e}"))?;
        let live = fetch::fetch_managed_resources(&client, &discovery)
            .await
            .map_err(|e| miette!("failed to fetch live resources: {e}"))?;

        if !global.quiet {
            println!("Found {} live managed resources", live.len());
        }

        // Detect changes per wave
        wave_manifests
            .iter()
            .map(|wave| {
                let wave_values: Vec<serde_json::Value> =
                    wave.iter().map(|m| (*m).clone()).collect();
                kix_cluster::apply::detect_changes(&wave_values, &live)
            })
            .collect()
    };

    // 5. Display plan
    print_plan(waves, &wave_actions, graph, global);

    let total_apply = wave_actions
        .iter()
        .flat_map(|w| w.iter())
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .count();
    let total_skip = wave_actions
        .iter()
        .flat_map(|w| w.iter())
        .filter(|a| matches!(a, ChangeAction::Skip(_)))
        .count();
    let total_prune = wave_actions
        .iter()
        .flat_map(|w| w.iter())
        .filter(|a| matches!(a, ChangeAction::Prune(_)))
        .count();

    if !global.quiet {
        println!();
        println!(
            "Plan: {} to apply, {} unchanged, {} to prune",
            output::green(&total_apply.to_string()),
            output::dim(&total_skip.to_string()),
            if total_prune > 0 {
                output::red(&total_prune.to_string())
            } else {
                output::dim(&total_prune.to_string())
            },
        );
    }

    if args.dry_run {
        println!();
        println!("{}", output::dim("Dry run — no changes applied."));
        return Ok(());
    }

    if total_apply == 0 && total_prune == 0 {
        println!();
        println!("{}", output::green("Everything up to date."));
        return Ok(());
    }

    // 6. Confirmation
    if !args.yes {
        if !output::is_interactive() {
            eprintln!(
                "{}",
                output::yellow(
                    "Non-interactive terminal detected. Use --yes to skip confirmation."
                )
            );
            std::process::exit(1);
        }
        print!("\nProceed with deploy? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Deploy cancelled.");
            return Ok(());
        }
    }

    // 7. Apply waves
    let client = if global.context.is_some() {
        fetch::make_client(global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?
    } else {
        fetch::make_client(None)
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?
    };

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    let mut total_created = 0usize;
    let mut total_configured = 0usize;
    let mut total_unchanged = 0usize;
    let mut total_failed = 0usize;

    for (wave_idx, actions) in wave_actions.iter().enumerate() {
        let apply_count = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .count();

        if apply_count == 0 {
            if !global.quiet {
                println!(
                    "\n{} {} resources unchanged",
                    output::bold(&format!("Wave {}:", wave_idx + 1)),
                    actions.len(),
                );
            }
            total_unchanged += actions.len();
            continue;
        }

        if !global.quiet {
            println!(
                "\n{} applying {} resources...",
                output::bold(&format!("Wave {}:", wave_idx + 1)),
                apply_count,
            );
        }

        let results = kix_cluster::apply::apply_wave(&client, &discovery, actions, false).await;

        let mut wave_failed = false;
        for (rid, result) in &results {
            match result {
                Ok(apply_result) => {
                    let (symbol, label) = match apply_result.action {
                        ApplyAction::Created => {
                            total_created += 1;
                            (output::green("+"), "created")
                        }
                        ApplyAction::Configured => {
                            total_configured += 1;
                            (output::yellow("~"), "configured")
                        }
                        ApplyAction::Unchanged => {
                            total_unchanged += 1;
                            (output::dim("="), "unchanged")
                        }
                        ApplyAction::Skipped => {
                            total_unchanged += 1;
                            (output::dim("-"), "skipped")
                        }
                    };
                    if !global.quiet || apply_result.action != ApplyAction::Unchanged {
                        println!("  {} {} {}", symbol, rid, output::dim(label));
                    }
                }
                Err(e) => {
                    total_failed += 1;
                    wave_failed = true;
                    eprintln!(
                        "  {} {} {}",
                        output::red("!"),
                        rid,
                        output::red(&e.to_string())
                    );
                }
            }
        }

        // Check failure mode
        if wave_failed {
            match args.on_error {
                OnError::Stop => {
                    eprintln!(
                        "\n{}",
                        output::red("Deploy stopped due to errors (--on-error=stop).")
                    );
                    print_summary(
                        total_created,
                        total_configured,
                        total_unchanged,
                        total_failed,
                    );
                    std::process::exit(1);
                }
                OnError::Continue => {
                    eprintln!(
                        "  {}",
                        output::yellow("Continuing despite errors (--on-error=continue)...")
                    );
                }
            }
        }

        // 8. Readiness polling for this wave (skip if all failed)
        if !wave_failed || matches!(args.on_error, OnError::Continue) {
            for action in actions {
                if let ChangeAction::Apply(manifest) = action {
                    let rid = ResourceId::from_value(manifest);

                    if !results.iter().any(|(r, res)| *r == rid && res.is_ok()) {
                        continue;
                    }

                    let kind = &rid.kind;

                    if readiness::is_immediate_kind(kind) {
                        continue;
                    }

                    let ar_scope = discovery.iter().find(|(ar, _)| ar.kind == rid.kind);

                    if let Some((ar, scope)) = ar_scope {
                        let ns = if rid.namespace == "_cluster" {
                            None
                        } else {
                            Some(rid.namespace.as_str())
                        };

                        if !global.quiet {
                            print!("  Waiting for {} ...", output::dim(&rid.to_string()));
                            std::io::stdout().flush().ok();
                        }

                        match readiness::wait_for_ready(
                            &client, ar, scope, &rid.name, ns, kind, timeout,
                        )
                        .await
                        {
                            Ok(ReadinessResult::Ready) => {
                                if !global.quiet {
                                    println!(" {}", output::green("ready"));
                                }
                            }
                            Ok(ReadinessResult::TimedOut { elapsed, message }) => {
                                println!(
                                    " {} ({}s): {}",
                                    output::yellow("timed out"),
                                    elapsed.as_secs(),
                                    message,
                                );
                                if matches!(args.on_error, OnError::Stop) {
                                    eprintln!(
                                        "\n{}",
                                        output::red("Deploy stopped: readiness timeout.")
                                    );
                                    print_summary(
                                        total_created,
                                        total_configured,
                                        total_unchanged,
                                        total_failed,
                                    );
                                    std::process::exit(1);
                                }
                            }
                            Ok(ReadinessResult::Failed(msg)) => {
                                println!(" {}: {}", output::red("failed"), msg);
                                total_failed += 1;
                                if matches!(args.on_error, OnError::Stop) {
                                    eprintln!(
                                        "\n{}",
                                        output::red("Deploy stopped: readiness failure.")
                                    );
                                    print_summary(
                                        total_created,
                                        total_configured,
                                        total_unchanged,
                                        total_failed,
                                    );
                                    std::process::exit(1);
                                }
                            }
                            Err(e) => {
                                println!(" {}: {}", output::red("error"), e);
                            }
                        }
                    }
                }
            }
        }
    }

    // Prune warnings
    let prune_candidates: Vec<ResourceId> = wave_actions
        .iter()
        .flat_map(|w| w.iter())
        .filter_map(|a| match a {
            ChangeAction::Prune(rid) => Some(rid.clone()),
            _ => None,
        })
        .collect();

    if !prune_candidates.is_empty() {
        if args.prune {
            let ar_by_kind: std::collections::HashMap<
                String,
                (&kube::discovery::ApiResource, kube::discovery::Scope),
            > = discovery
                .iter()
                .map(|(ar, scope)| (ar.kind.clone(), (ar, scope.clone())))
                .collect();

            println!();
            println!(
                "{} Pruning {} resources...",
                output::bold("Prune:"),
                prune_candidates.len(),
            );

            for rid in &prune_candidates {
                if rid.kind == "Namespace" {
                    println!(
                        "  {} {} — skipping Namespace pruning — use kubectl delete ns manually",
                        output::yellow("!"),
                        rid,
                    );
                    continue;
                }

                let Some(&(ar, ref scope)) = ar_by_kind.get(&rid.kind) else {
                    eprintln!(
                        "  {} {} — unknown kind, cannot prune",
                        output::red("!"),
                        rid,
                    );
                    total_failed += 1;
                    continue;
                };

                let api: kube::api::Api<kube::api::DynamicObject> = match scope {
                    kube::discovery::Scope::Namespaced => {
                        let ns = if rid.namespace == "_cluster" {
                            "default"
                        } else {
                            &rid.namespace
                        };
                        kube::api::Api::namespaced_with(client.clone(), ns, ar)
                    }
                    kube::discovery::Scope::Cluster => kube::api::Api::all_with(client.clone(), ar),
                };

                match api
                    .delete(&rid.name, &kube::api::DeleteParams::default())
                    .await
                {
                    Ok(_) => {
                        println!(
                            "  {} pruned {}/{}@{}",
                            output::red("-"),
                            rid.kind,
                            rid.name,
                            rid.namespace,
                        );
                    }
                    Err(e) => {
                        eprintln!(
                            "  {} {}: {}",
                            output::red("!"),
                            rid,
                            output::red(&e.to_string()),
                        );
                        total_failed += 1;
                    }
                }
            }
        } else {
            println!();
            println!(
                "{} {} resources on cluster not in manifests (use --prune to delete):",
                output::yellow("Warning:"),
                prune_candidates.len(),
            );
            for rid in &prune_candidates {
                println!("  {} {}", output::yellow("-"), rid);
            }
        }
    }

    // 9. Summary
    println!();
    print_summary(
        total_created,
        total_configured,
        total_unchanged,
        total_failed,
    );

    if total_failed > 0 {
        std::process::exit(1);
    }

    Ok(())
}

fn print_plan(
    waves: &[Vec<petgraph::graph::NodeIndex>],
    wave_actions: &[Vec<ChangeAction>],
    graph: &ResourceGraph,
    global: &crate::cli::GlobalArgs,
) {
    if global.quiet {
        return;
    }

    println!();
    println!(
        "{} ({} waves)",
        output::bold("Deployment plan"),
        waves.len(),
    );

    for (i, (wave_nodes, actions)) in waves.iter().zip(wave_actions.iter()).enumerate() {
        let apply = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .count();
        let skip = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Skip(_)))
            .count();
        let prune = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Prune(_)))
            .count();

        println!();
        println!(
            "{} ({} resources)",
            output::bold(&format!("Wave {}", i + 1)),
            wave_nodes.len(),
        );

        for (action, node_idx) in actions.iter().zip(wave_nodes.iter()) {
            let node = &graph.graph[*node_idx];
            let rid = &node.id;
            match action {
                ChangeAction::Apply(_) => {
                    println!("  {} {}", output::green("+"), rid);
                }
                ChangeAction::Skip(_) => {
                    println!("  {} {}", output::dim("="), rid);
                }
                ChangeAction::Prune(_) => {
                    println!("  {} {}", output::red("-"), rid);
                }
            }
        }

        if apply > 0 || skip > 0 || prune > 0 {
            let mut parts = Vec::new();
            if apply > 0 {
                parts.push(output::green(&format!("{apply} apply")));
            }
            if skip > 0 {
                parts.push(output::dim(&format!("{skip} skip")));
            }
            if prune > 0 {
                parts.push(output::red(&format!("{prune} prune")));
            }
            println!("  {}", parts.join(", "));
        }
    }
}

fn print_summary(created: usize, configured: usize, unchanged: usize, failed: usize) {
    println!(
        "Deploy complete: {} created, {} configured, {} unchanged, {} failed",
        output::green(&created.to_string()),
        output::yellow(&configured.to_string()),
        output::dim(&unchanged.to_string()),
        if failed > 0 {
            output::red(&failed.to_string())
        } else {
            output::dim(&failed.to_string())
        },
    );
}

fn parse_timeout(s: Option<&str>) -> Result<Duration> {
    let Some(s) = s else {
        return Ok(readiness::DEFAULT_TIMEOUT);
    };

    let s = s.trim();
    if s.is_empty() {
        return Ok(readiness::DEFAULT_TIMEOUT);
    }

    if let Some(minutes) = s.strip_suffix('m')
        && let Ok(m) = minutes.parse::<u64>()
    {
        return Ok(Duration::from_secs(m * 60));
    }
    if let Some(seconds) = s.strip_suffix('s')
        && let Ok(secs) = seconds.parse::<u64>()
    {
        return Ok(Duration::from_secs(secs));
    }
    if let Ok(secs) = s.parse::<u64>() {
        return Ok(Duration::from_secs(secs));
    }

    Err(miette!(
        "invalid timeout format '{s}'. Use '5m', '300s', or a number of seconds"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_timeout_none() {
        let t = parse_timeout(None).unwrap();
        assert_eq!(t, readiness::DEFAULT_TIMEOUT);
    }

    #[test]
    fn parse_timeout_seconds() {
        assert_eq!(parse_timeout(Some("60s")).unwrap(), Duration::from_secs(60));
    }

    #[test]
    fn parse_timeout_minutes() {
        assert_eq!(parse_timeout(Some("5m")).unwrap(), Duration::from_secs(300));
    }

    #[test]
    fn parse_timeout_plain_number() {
        assert_eq!(
            parse_timeout(Some("120")).unwrap(),
            Duration::from_secs(120)
        );
    }

    #[test]
    fn parse_timeout_invalid() {
        assert!(parse_timeout(Some("abc")).is_err());
    }
}
