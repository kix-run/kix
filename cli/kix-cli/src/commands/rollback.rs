//! `kix rollback` — revert to the most recent Superseded activation.
//!
//! Finds the previous activation on the cluster, resolves its store path,
//! and re-applies its manifests through the standard reconcile engine.
//! No nix build is required — the old activation's manifests are already
//! in the local Nix store.

use std::io::Write;
use std::sync::Arc;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::activation;
use kix::cluster::apply::ChangeAction;
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::ops::{ClusterOps, KubeOps, KubeOpsConfig};
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, DeployPlan, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::{DeployObserver, DeployResult};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::cli::{OutputFormat, RollbackArgs};
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &RollbackArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.list {
        return ctx.runtime.block_on(run_list_async(args, ctx));
    }
    if args.operator {
        return ctx.runtime.block_on(run_operator_async(args, ctx));
    }
    ctx.runtime.block_on(run_async(args, ctx))
}

// ── Rollback history listing (`kix rollback --list`) ────────────────

/// Read-only: connect, enumerate Superseded activations, print history, exit.
/// Works the same whether the cluster is operator-managed or direct-apply
/// because it only inspects Activation CRs. Supports `--output json|yaml`.
async fn run_list_async(args: &RollbackArgs, ctx: &CommandContext) -> Result<()> {
    let client = fetch::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    let (activation_ar, _) = activation::find_activation_ar(&discovery)
        .ok_or_else(|| miette!("Activation CRD not registered on cluster"))?
        .clone();

    // Current Active activation — optional: useful as a "you are here" marker
    // in the history listing, but we must still print even if none exists.
    let current = activation::find_active(&client, &activation_ar, &args.cluster)
        .await
        .map_err(|e| miette!("failed to find active activation: {e}"))?;

    let superseded =
        activation::list_superseded_activations(&client, &activation_ar, &args.cluster)
            .await
            .map_err(|e| miette!("failed to list superseded activations: {e}"))?;

    let format = ctx.output_format(OutputFormat::Text);
    match format {
        OutputFormat::Json | OutputFormat::Yaml => {
            let value = serde_json::json!({
                "cluster": args.cluster,
                "current": current.as_ref().map(|c| serde_json::json!({
                    "name": c.name,
                    "identity_hash": c.identity_hash,
                    "built_via": c.built_via,
                })),
                "superseded": superseded.iter().map(|s| {
                    let available = s
                        .identity_hash
                        .as_deref()
                        .and_then(|h| {
                            kix::eval::store::resolve_activation_by_hash(&args.cluster, h)
                        })
                        .is_some();
                    serde_json::json!({
                        "name": s.name,
                        "identity_hash": s.identity_hash,
                        "deployed_at": s.deployed_at,
                        "built_via": s.built_via,
                        "previous_activation": s.previous_activation,
                        "available_locally": available,
                    })
                }).collect::<Vec<_>>(),
            });
            if matches!(format, OutputFormat::Yaml) {
                print!("{}", serde_yml::to_string(&value).into_diagnostic()?);
            } else {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&value).into_diagnostic()?
                );
            }
        }
        OutputFormat::Text | OutputFormat::Markdown => {
            print_history_text(&args.cluster, current.as_ref(), &superseded);
        }
    }

    Ok(())
}

fn print_history_text(
    cluster: &str,
    current: Option<&kix::cluster::activation::ActiveActivation>,
    superseded: &[kix::cluster::activation::SupersededActivation],
) {
    println!(
        "{} activation history for '{}'",
        output::bold("Rollback:"),
        cluster,
    );
    println!();

    if let Some(c) = current {
        let hash_preview = c
            .identity_hash
            .as_deref()
            .map(|h| format!("{}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no hash".to_string());
        println!(
            "  {} {} ({})  {}",
            output::green("● active  "),
            output::bold(&c.name),
            hash_preview,
            output::dim("← you are here"),
        );
        if let Some(path) = c.built_via.as_deref() {
            println!("    {} {}", output::dim("source:  "), output::dim(path));
        }
        println!();
    }

    if superseded.is_empty() {
        println!(
            "  {}",
            output::dim("No superseded activations — nothing to roll back to.")
        );
        return;
    }

    println!("  {}", output::bold("Superseded (most recent first):"));
    println!();
    for (i, s) in superseded.iter().enumerate() {
        let hash_preview = s
            .identity_hash
            .as_deref()
            .map(|h| format!("{}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no hash".to_string());
        let ts = if s.deployed_at.is_empty() {
            output::dim("unknown").into_owned()
        } else {
            s.deployed_at.clone()
        };
        let available = s
            .identity_hash
            .as_deref()
            .and_then(|h| kix::eval::store::resolve_activation_by_hash(cluster, h))
            .is_some();
        let availability = if available {
            output::green("available")
        } else {
            output::red("store path missing")
        };
        println!(
            "  {} {} ({})  deployed {}  [{}]",
            output::bold(&format!("[{}]", i + 1)),
            s.name,
            hash_preview,
            ts,
            availability,
        );
        if let Some(path) = s.built_via.as_deref() {
            println!("      {} {}", output::dim("source:  "), output::dim(path));
        }
        if let Some(prev) = s.previous_activation.as_deref() {
            println!("      {} {}", output::dim("previous:"), output::dim(prev),);
        }
    }
    println!();
    println!(
        "  {}",
        output::dim(
            "Run `kix rollback <cluster>` (or `--yes` for most recent) to switch activations."
        )
    );
}

async fn run_async(args: &RollbackArgs, ctx: &CommandContext) -> Result<()> {
    // 1. Connect to cluster
    if !ctx.global.quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let discovery = fetch::discover_resources(&client)
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
        print_superseded_entries(&args.cluster, &superseded);

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
    let plan = DeployPlan::from_graph_and_changes(&resource_graph, &all_actions);

    // Find the target activation name and identity hash
    let record = kix::manifest::lifecycle::record_of(&target_manifests);
    let activation_name =
        record.and_then(|m| m.pointer("/metadata/name")?.as_str().map(|s| s.to_string()));
    let activation_identity_hash = record.and_then(|m| {
        m.pointer("/metadata/annotations")
            .and_then(|a| a.get("kix.dev/identity-hash"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
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
        plan::print_plan_summary(&pkg_diff);
    }

    let total_apply = plan
        .nodes
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
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

    // 9. Apply via DAG-streaming scheduler.
    let config = SchedulerConfig {
        timeout: readiness::DEFAULT_TIMEOUT,
        on_error: OnErrorPolicy::Stop,
        prune: if args.prune {
            PrunePolicy::Delete
        } else {
            PrunePolicy::WarnOnly
        },
        cancel: kix::cluster::cancel::CancelToken::new(),
        dry_run: false,
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
    };

    let observer: Arc<dyn DeployObserver> = if !output::is_interactive() {
        Arc::new(super::deploy_log::LineObserver {
            verbose: ctx.global.verbose > 0,
        })
    } else {
        Arc::new(super::deploy::StreamCliObserver {
            quiet: ctx.global.quiet,
            verbose: ctx.global.verbose > 0,
        })
    };

    let cluster_name = target_graph.cluster_name.clone();
    let discovery = Arc::new(tokio::sync::RwLock::new(discovery));
    let ops: Arc<dyn ClusterOps> = Arc::new(KubeOps::new(
        client.clone(),
        discovery,
        KubeOpsConfig {
            cluster_name,
            activation_name: activation_name.clone(),
            activation_identity_hash: activation_identity_hash.clone(),
            // Rollback re-applies a known-good prior activation; conflicts
            // fail loudly rather than silently overwriting whatever the
            // cluster has.
            force_conflicts: false,
            dry_run: false,
        },
    ));

    let result = scheduler::run_deploy(
        ops,
        plan,
        &orphan_rids,
        &current_manifests,
        &config,
        observer,
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
            let partial = e.partial();
            if let Some(r) = partial {
                print_summary(r);
            }
            std::process::exit(1);
        }
    }
}

// ── Operator-delegated rollback ──────────────────────────────────────

async fn run_operator_async(args: &RollbackArgs, ctx: &CommandContext) -> Result<()> {
    // 1. Connect and find current + superseded activations
    let (client, ar) =
        super::operator::connect_and_verify(ctx.global.context.as_deref(), ctx.global.quiet)
            .await?;

    let discovery = kix::cluster::fetch::discover_resources(&client)
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

    // 3. Find superseded activations
    let superseded =
        activation::list_superseded_activations(&client, &activation_ar, &args.cluster)
            .await
            .map_err(|e| miette!("failed to list superseded activations: {e}"))?;

    if superseded.is_empty() {
        return Err(miette!(
            "no superseded activations found — nothing to rollback to"
        ));
    }

    // Interactive selection or auto-select most recent
    let selected = if args.yes || !output::is_interactive() {
        &superseded[0]
    } else {
        println!();
        println!("Available activations to rollback to:");
        print_superseded_entries(&args.cluster, &superseded);

        print!("\nSelect activation [1]: ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
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
    let target_hash = selected.identity_hash.clone();

    // 4. Resolve the target's store path
    let target_source_path = selected
        .built_via
        .as_ref()
        .filter(|p| std::path::Path::new(p).join("kix-packages.json").exists())
        .cloned()
        .or_else(|| {
            target_hash.as_ref().and_then(|h| {
                kix::eval::store::resolve_activation_by_hash(&args.cluster, h)
                    .map(|p| p.display().to_string())
            })
        })
        .ok_or_else(|| {
            miette!(
                "store path for activation '{}' not found locally. Was it garbage-collected?",
                target_name,
            )
        })?;

    if !ctx.global.quiet {
        println!(
            "Rollback target:   {} (via operator)",
            output::bold(&target_name),
        );
    }

    if args.dry_run {
        if !ctx.global.quiet {
            println!();
            println!("{}", output::dim("Dry run — no changes applied."));
        }
        return Ok(());
    }

    // 5. Confirmation
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
        print!("\nDelegate rollback to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled.");
            return Ok(());
        }
    }

    // 6. Patch the current Activation CR to point to the target's source path
    //    The operator will detect the source change and reconcile.
    if !ctx.global.quiet {
        println!(
            "Updating Activation CR '{}' to point to rollback target...",
            output::bold(&current.name),
        );
    }

    super::operator::apply_activation(
        &client,
        &ar,
        &current.name,
        &args.cluster,
        &target_source_path,
        target_hash.as_deref(),
    )
    .await?;

    if !ctx.global.quiet {
        println!(
            "  {} Activation CR updated — waiting for operator...",
            output::green("✓"),
        );
    }

    super::operator::watch_activation_progress(
        &client,
        &ar,
        &current.name,
        &target_source_path,
        ctx.global.quiet,
    )
    .await?;

    println!();
    println!(
        "Rollback via operator {}: rolled back to '{}'",
        output::green("complete"),
        output::bold(&target_name),
    );

    Ok(())
}

/// Shared formatter for a list of superseded activations — used by both the
/// interactive rollback selector and `kix rollback --list`. Shows store path
/// availability, source directory, and the `previousActivation` link so the
/// operator sees exactly what each history entry points at.
fn print_superseded_entries(
    cluster: &str,
    superseded: &[kix::cluster::activation::SupersededActivation],
) {
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
            .and_then(|h| kix::eval::store::resolve_activation_by_hash(cluster, h))
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
        if let Some(path) = act.built_via.as_deref() {
            println!("      {} {}", output::dim("source:  "), output::dim(path));
        }
        if let Some(prev) = act.previous_activation.as_deref() {
            println!("      {} {}", output::dim("previous:"), output::dim(prev),);
        }
    }
}

fn print_summary(r: &DeployResult) {
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
