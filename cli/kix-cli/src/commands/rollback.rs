//! `kix rollback` — revert to the most recent Superseded activation.
//!
//! Finds the previous activation on the cluster, resolves its store path,
//! and re-applies its manifests through the standard reconcile engine.
//! No nix build is required — the old activation's manifests are already
//! in the local Nix store.

use std::io::Write;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::activation;
use kix::cluster::apply::ChangeAction;
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::readiness;
use kix::cluster::reconcile::{
    OnErrorPolicy, PrunePolicy, ReconcileConfig, ReconcileEvent, ReconcileObserver, ReconcileResult,
};
use kix::cluster::waves::compute_waves;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::cli::RollbackArgs;
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &RollbackArgs, ctx: &mut CommandContext) -> Result<()> {
    ctx.runtime.block_on(run_async(args, ctx))
}

async fn run_async(args: &RollbackArgs, ctx: &CommandContext) -> Result<()> {
    // 1. Connect to cluster
    if !ctx.global.quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let mut discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    let (activation_ar, _) = activation::find_activation_ar(&discovery)
        .ok_or_else(|| miette!("Activation CRD not registered on cluster"))?
        .clone();

    // 2. Find current Active activation
    let current = activation::find_active(&client, &activation_ar, &args.cluster)
        .await
        .map_err(|e| miette!("failed to find active activation: {e}"))?
        .ok_or_else(|| miette!("no active activation found for cluster '{}'", args.cluster))?;

    if !ctx.global.quiet {
        let hash_preview = current
            .identity_hash
            .as_deref()
            .map(|h| format!(" ({}...)", &h[..8.min(h.len())]))
            .unwrap_or_default();
        println!(
            "Current activation: {}{}",
            output::bold(&current.name),
            hash_preview,
        );
    }

    // 3. Find available Superseded activations
    let superseded =
        activation::list_superseded_activations(&client, &activation_ar, &args.cluster)
            .await
            .map_err(|e| miette!("failed to list superseded activations: {e}"))?;

    if superseded.is_empty() {
        return Err(miette!(
            "no superseded activations found — nothing to rollback to"
        ));
    }

    // In interactive mode, let the user pick; with --yes, use most recent
    let selected = if args.yes || !output::is_interactive() {
        &superseded[0] // most recent (list is sorted by deployed_at desc)
    } else {
        println!();
        println!("Available activations to rollback to:");
        for (i, act) in superseded.iter().enumerate() {
            let hash_preview = act
                .identity_hash
                .as_deref()
                .map(|h| format!("{}...", &h[..8.min(h.len())]))
                .unwrap_or_else(|| "no hash".to_string());
            let ts = if act.deployed_at.is_empty() {
                "unknown".to_string()
            } else {
                act.deployed_at.clone()
            };
            let available = act
                .identity_hash
                .as_deref()
                .and_then(|h| kix::eval::store::resolve_activation_by_hash(&args.cluster, h))
                .is_some();
            let availability = if available {
                output::green("available")
            } else {
                output::red("store path missing")
            };
            println!(
                "  {} {} ({}) — deployed {} [{}]",
                output::bold(&format!("[{}]", i + 1)),
                act.name,
                hash_preview,
                ts,
                availability,
            );
        }

        print!("\nSelect activation [1]: ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim();

        let idx = if input.is_empty() {
            0
        } else {
            input
                .parse::<usize>()
                .map_err(|_| miette!("invalid selection: '{}'", input))?
                .checked_sub(1)
                .ok_or_else(|| miette!("selection must be >= 1"))?
        };

        if idx >= superseded.len() {
            return Err(miette!(
                "selection {} out of range (1-{})",
                idx + 1,
                superseded.len()
            ));
        }

        &superseded[idx]
    };

    let target_name = selected.name.clone();
    let target_hash = selected.identity_hash.as_ref().ok_or_else(|| {
        miette!(
            "superseded activation '{}' has no identity hash",
            target_name
        )
    })?;

    if !ctx.global.quiet {
        println!(
            "Rollback target:   {} ({}...)",
            output::bold(&target_name),
            &target_hash[..8.min(target_hash.len())],
        );
    }

    // 4. Resolve target activation to local store graph.
    //    Prefer built-via annotation (direct path), fall back to hash-based lookup.
    let target_result_dir = selected
        .built_via
        .as_ref()
        .map(std::path::PathBuf::from)
        .filter(|p| p.join("kix-packages.json").exists())
        .or_else(|| kix::eval::store::resolve_activation_by_hash(&args.cluster, target_hash))
        .ok_or_else(|| {
            miette!(
                "store path for activation '{}' not found locally (hash: {}). \
                 Was it garbage-collected?",
                target_name,
                target_hash,
            )
        })?;

    let noop = |_: &str| {};
    let mut target_graph = StoreGraph::from_result_dir_with_status(&target_result_dir, &noop)
        .map_err(|e| miette!("failed to load target activation: {e}"))?;
    stamp_annotations(&mut target_graph);

    let target_manifests: Vec<Value> = target_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    // 5. Resolve current activation to local store graph (for diff).
    //    Prefer built-via, fall back to hash-based lookup.
    let noop2 = |_: &str| {};
    let current_result_dir = current
        .built_via
        .as_ref()
        .map(std::path::PathBuf::from)
        .filter(|p| p.join("kix-packages.json").exists())
        .or_else(|| {
            let hash = current.identity_hash.as_deref().unwrap_or("");
            kix::eval::store::resolve_activation_by_hash(&args.cluster, hash)
        });
    let (current_graph, current_manifests) = match current_result_dir {
        Some(dir) => match StoreGraph::from_result_dir_with_status(&dir, &noop2) {
            Ok(mut g) => {
                stamp_annotations(&mut g);
                let m = g.resources.values().map(|r| r.manifest.clone()).collect();
                (Some(g), m)
            }
            Err(_) => (None, vec![]),
        },
        None => (None, vec![]),
    };

    // 6. Compute changes (current → target)
    let all_actions = kix::cluster::apply::detect_changes(&target_manifests, &current_manifests);

    let mut orphan_rids: Vec<ResourceId> = Vec::new();
    for action in &all_actions {
        if let ChangeAction::Orphan(rid) = action {
            orphan_rids.push(rid.clone());
        }
    }

    let resource_graph = ResourceGraph::from_manifests(&target_manifests).into_diagnostic()?;
    let waves = compute_waves(&resource_graph);

    // Map wave nodes to change actions
    let new_manifest_actions: std::collections::HashMap<String, &ChangeAction> = {
        let mut map = std::collections::HashMap::new();
        for action in &all_actions {
            let k8s_id = match action {
                ChangeAction::Apply(m) => {
                    let rid = ResourceId::from_value(m);
                    format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
                }
                ChangeAction::Skip(rid) => {
                    format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
                }
                ChangeAction::Orphan(_) => continue,
            };
            map.insert(k8s_id, action);
        }
        map
    };

    let wave_actions: Vec<Vec<ChangeAction>> = waves
        .iter()
        .map(|wave| {
            wave.iter()
                .map(|&idx| {
                    let node = &resource_graph.graph[idx];
                    let k8s_id = format!("{}/{}/{}", node.id.kind, node.id.namespace, node.id.name);
                    match new_manifest_actions.get(&k8s_id) {
                        Some(ChangeAction::Apply(m)) => ChangeAction::Apply(m.clone()),
                        Some(ChangeAction::Skip(rid)) => ChangeAction::Skip(rid.clone()),
                        _ => ChangeAction::Skip(node.id.clone()),
                    }
                })
                .collect()
        })
        .collect();

    // Find the target activation name and identity hash
    let activation_name = target_manifests.iter().find_map(|m| {
        let kind = m.get("kind")?.as_str()?;
        if kind == "Activation" {
            m.pointer("/metadata/name")?.as_str().map(|s| s.to_string())
        } else {
            None
        }
    });
    let activation_identity_hash = target_manifests.iter().find_map(|m| {
        let kind = m.get("kind")?.as_str()?;
        if kind == "Activation" {
            m.pointer("/metadata/annotations")
                .and_then(|a| a.get("kix.dev/identity-hash"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        } else {
            None
        }
    });

    // 7. Display plan
    if !ctx.global.quiet {
        let pkg_diff = match &current_graph {
            Some(old) => plan::diff_graphs(old, &target_graph),
            None => plan::diff_graphs(
                &StoreGraph::empty(&target_graph.cluster_name),
                &target_graph,
            ),
        };

        println!();
        println!(
            "{} Rolling back cluster '{}' to activation '{}'",
            output::bold("Rollback:"),
            output::bold(&args.cluster),
            output::bold(&target_name),
        );
        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);
        plan::print_wave_summary(&waves, &resource_graph);
        plan::print_plan_summary(&pkg_diff);
    }

    let total_apply = wave_actions
        .iter()
        .flat_map(|w| w.iter())
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .count();

    if args.dry_run {
        if !ctx.global.quiet {
            println!();
            println!("{}", output::dim("Dry run — no changes applied."));
        }
        return Ok(());
    }

    if total_apply == 0 && orphan_rids.is_empty() {
        if !ctx.global.quiet {
            println!("Nothing to change — cluster already matches target activation.");
        }
        return Ok(());
    }

    // 8. Confirmation
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
        print!("\nProceed with rollback? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled.");
            return Ok(());
        }
    }

    // 9. Apply via reconcile engine
    let config = ReconcileConfig {
        timeout: readiness::DEFAULT_TIMEOUT,
        on_error: OnErrorPolicy::Stop,
        prune: if args.prune {
            PrunePolicy::Delete
        } else {
            PrunePolicy::WarnOnly
        },
    };

    let observer = CliObserver {
        quiet: ctx.global.quiet,
    };

    let cluster_name = target_graph.cluster_name.clone();

    let result = kix::cluster::reconcile::reconcile(
        &client,
        &mut discovery,
        &wave_actions,
        &orphan_rids,
        &current_manifests,
        &cluster_name,
        activation_name.as_deref(),
        activation_identity_hash.as_deref(),
        &config,
        &observer,
    )
    .await;

    // Save activation path for next deploy's diff
    if result.is_ok()
        && let Err(e) = kix::eval::store::save_activation_path(&args.cluster, &target_result_dir)
    {
        tracing::warn!("failed to save activation path: {e}");
    }

    match result {
        Ok(r) => {
            println!();
            print_summary(&r);
            Ok(())
        }
        Err(e) => {
            let partial = match &e {
                kix::cluster::reconcile::ReconcileError::WaveFailed { partial_result, .. } => {
                    Some(partial_result)
                }
                kix::cluster::reconcile::ReconcileError::ReadinessTimeout {
                    partial_result,
                    ..
                } => Some(partial_result),
                kix::cluster::reconcile::ReconcileError::ReadinessFailed {
                    partial_result, ..
                } => Some(partial_result),
                _ => None,
            };
            if let Some(r) = partial {
                print_summary(r);
            }
            std::process::exit(1);
        }
    }
}

fn print_summary(r: &ReconcileResult) {
    let failed_str = r.failed.to_string();
    println!(
        "Rollback complete: {} created, {} configured, {} unchanged, {} failed",
        output::green(&r.created.to_string()),
        output::yellow(&r.configured.to_string()),
        output::dim(&r.unchanged.to_string()),
        if r.failed > 0 {
            output::red(&failed_str)
        } else {
            output::dim(&failed_str)
        },
    );
}

/// CLI observer — reuse the same pattern as deploy.
struct CliObserver {
    quiet: bool,
}

impl ReconcileObserver for CliObserver {
    fn on_event(&self, event: &ReconcileEvent) {
        match event {
            ReconcileEvent::WaveSkipped {
                wave_index, count, ..
            } => {
                if !self.quiet {
                    println!(
                        "\n{} {} resources (already complete, skipping)",
                        output::bold(&format!("Wave {}:", wave_index + 1)),
                        count,
                    );
                }
            }
            ReconcileEvent::WaveUnchanged {
                wave_index, count, ..
            } => {
                if !self.quiet {
                    println!(
                        "\n{} {} resources unchanged",
                        output::bold(&format!("Wave {}:", wave_index + 1)),
                        count,
                    );
                }
            }
            ReconcileEvent::WaveStart {
                wave_index,
                apply_count,
                ..
            } => {
                if !self.quiet {
                    println!(
                        "\n{} applying {} resources...",
                        output::bold(&format!("Wave {}:", wave_index + 1)),
                        apply_count,
                    );
                }
            }
            ReconcileEvent::ResourceApplied { rid, action } => {
                use kix::cluster::apply::ApplyAction;
                let (symbol, label) = match action {
                    ApplyAction::Created => (output::green("+"), "created"),
                    ApplyAction::Configured => (output::yellow("~"), "configured"),
                    ApplyAction::Unchanged => (output::dim("="), "unchanged"),
                    ApplyAction::Skipped => (output::dim("-"), "skipped"),
                };
                if !self.quiet || !matches!(action, ApplyAction::Unchanged) {
                    println!("  {} {} {}", symbol, rid, output::dim(label));
                }
            }
            ReconcileEvent::ResourceFailed { rid, error } => {
                eprintln!("  {} {} {}", output::red("!"), rid, output::red(error));
            }
            ReconcileEvent::ReadinessWaiting { rid } => {
                if !self.quiet {
                    print!("  Waiting for {} ...", output::dim(&rid.to_string()));
                    std::io::stdout().flush().ok();
                }
            }
            ReconcileEvent::ReadinessReady { .. } => {
                if !self.quiet {
                    println!(" {}", output::green("ready"));
                }
            }
            ReconcileEvent::ReadinessTimeout {
                elapsed, message, ..
            } => {
                println!(
                    " {} ({}s): {}",
                    output::yellow("timed out"),
                    elapsed.as_secs(),
                    message,
                );
            }
            ReconcileEvent::ReadinessFailed { message, .. } => {
                println!(" {}: {}", output::red("failed"), message);
            }
            ReconcileEvent::Stopped { reason } => {
                eprintln!("\n{}", output::red(reason));
            }
            ReconcileEvent::CrdRediscovery => {}
            ReconcileEvent::WaveComplete { .. } => {}
            ReconcileEvent::PruneStart { count } => {
                println!();
                println!(
                    "{} Pruning {} orphaned resources...",
                    output::bold("Prune:"),
                    count,
                );
            }
            ReconcileEvent::PruneSkipped { rid, reason } => {
                println!("  {} {} — {}", output::yellow("!"), rid, reason);
            }
            ReconcileEvent::PruneOk { rid } => {
                println!(
                    "  {} pruned {}/{}@{}",
                    output::red("-"),
                    rid.kind,
                    rid.name,
                    rid.namespace,
                );
            }
            ReconcileEvent::PruneFailed { rid, error } => {
                eprintln!("  {} {}: {}", output::red("!"), rid, output::red(error));
            }
            ReconcileEvent::Finalized { activation, old } => {
                if !self.quiet {
                    if let Some(old) = old {
                        println!("  {} Activation '{}' → Superseded", output::dim("•"), old);
                    }
                    println!(
                        "  {} Activation '{}' → Active",
                        output::green("•"),
                        activation,
                    );
                }
            }
        }
    }
}
