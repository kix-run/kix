//! `kix deploy` — wave-based deployment with local DAG diff.
//!
//! Uses the store graph for proper stamping and dependency tracking.
//! Change detection is a local operation — diffs two Nix store graphs
//! by K8s identity (kind+ns+name) and identity-hash, without querying
//! the live cluster.
//!
//! Flow:
//!   1. `nix build .#cluster-<name>-activation`  → result dir
//!   2. StoreGraph::from_result_dir              → packages + resources
//!   3. stamp_annotations                        → identity/depends-on
//!   4. Connect to cluster, fetch Active Activation (unless --current-activation)
//!   5. Resolve old activation to local store graph
//!   6. Package-grouped plan display
//!   7. Confirm → Apply wave-by-wave with readiness checks
//!   8. Prune orphans (reverse topo order from old graph)

use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::activation;
use kix::cluster::apply::{ApplyAction, ChangeAction};
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::cluster::readiness::{self, ImportTarget};
use kix::cluster::reconcile::{
    OnErrorPolicy, PrunePolicy, ReconcileConfig, ReconcileEvent, ReconcileObserver, ReconcileResult,
};
use kix::cluster::waves::compute_waves;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::cli::{DeployArgs, OnError, PruneMode};
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        return run_operator(args, ctx);
    }

    let flake_path = resolve_flake_path(&ctx.global.flake)?;

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
    let mut new_graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    // 2. Collect stamped manifests from new graph
    let new_manifests: Vec<Value> = new_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    let manifest_count = new_manifests.len();
    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} manifests",
            output::bold(&new_graph.cluster_name),
            manifest_count,
        );
    }

    if manifest_count == 0 {
        if !ctx.global.quiet {
            println!("Nothing to deploy.");
        }
        return Ok(());
    }

    // 3. Resolve old activation
    //    Default: connect to cluster, fetch Active Activation, resolve to local store graph
    //    --current-activation: use local cache (no cluster connection yet)
    let (old_graph, old_manifests, pre_client) = if args.current_activation {
        // Local cache mode — no cluster connection
        let (og, om) = load_old_from_cache(&args.cluster, &ctx.global);
        (og, om, None)
    } else {
        // Cluster-aware mode — connect and fetch Active Activation
        let (og, om, client) = ctx
            .runtime
            .block_on(load_old_from_cluster(&args.cluster, &ctx.global))?;
        (og, om, client)
    };

    // 4. Local DAG diff: old vs new
    let all_actions = kix::cluster::apply::detect_changes(&new_manifests, &old_manifests);

    // Stateful migration pair detection (doc 67). Phase 1: detect + refuse
    // to proceed without explicit --accept-migrations. No execution yet.
    let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests);
    if !migration_pairs.is_empty() {
        print_migration_pairs(&migration_pairs);
        if !args.accept_migrations {
            eprintln!(
                "{}",
                output::red(
                    "Refusing to deploy: stateful migration pairs detected but --accept-migrations was not passed."
                )
            );
            eprintln!(
                "{}",
                output::yellow(
                    "Data migration is NOT yet automated. Review the pairs above, handle the data out-of-band, then re-run with --accept-migrations."
                )
            );
            std::process::exit(1);
        }
        if !ctx.global.quiet {
            println!(
                "{}",
                output::yellow(
                    "--accept-migrations set: proceeding with deploy. kix will NOT copy data; consumers on new backing will start empty."
                )
            );
        }
    }

    // --reconcile: force re-apply of all resources regardless of identity match
    let all_actions: Vec<ChangeAction> = if args.reconcile {
        let manifest_by_k8s_id: std::collections::HashMap<String, &Value> = new_manifests
            .iter()
            .map(|m| {
                let rid = ResourceId::from_value(m);
                (format!("{}/{}/{}", rid.kind, rid.namespace, rid.name), m)
            })
            .collect();

        all_actions
            .into_iter()
            .map(|action| match action {
                ChangeAction::Skip(ref rid) => {
                    let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
                    if let Some(&manifest) = manifest_by_k8s_id.get(&k8s_id) {
                        ChangeAction::Apply(manifest.clone())
                    } else {
                        action
                    }
                }
                other => other,
            })
            .collect()
    } else {
        all_actions
    };

    // Separate into apply actions and orphans
    let mut orphan_rids: Vec<ResourceId> = Vec::new();

    for action in &all_actions {
        if let ChangeAction::Orphan(rid) = action {
            orphan_rids.push(rid.clone());
        }
    }

    // 5. Build DAG from ALL new manifests (for wave computation)
    let resource_graph = ResourceGraph::from_manifests(&new_manifests).into_diagnostic()?;
    let waves = compute_waves(&resource_graph);

    if waves.is_empty() {
        if !ctx.global.quiet {
            println!("No resources to deploy.");
        }
        return Ok(());
    }

    // Map each wave node to its change action
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

    // Build wave actions: for each wave, map nodes to their ChangeAction
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

    // Find the Activation resource name and identity-hash from the new manifests
    let activation_manifest = new_manifests.iter().find(|m| {
        m.get("kind")
            .and_then(|v| v.as_str())
            .is_some_and(|k| k == "Activation")
    });
    let activation_name = activation_manifest.and_then(|m| {
        m.pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    let activation_identity_hash = activation_manifest.and_then(|m| {
        m.pointer("/metadata/annotations/kix.dev~1identity-hash")
            .or_else(|| {
                m.pointer("/metadata/annotations")
                    .and_then(|a| a.get("kix.dev/identity-hash"))
            })
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });

    // 6. Display plan — package-grouped, changes only
    if !ctx.global.quiet {
        let pkg_diff = match (&old_graph, &Some(&new_graph)) {
            (Some(old), Some(new)) => plan::diff_graphs(old, new),
            _ => {
                // First deploy — everything is "added"
                plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph)
            }
        };

        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);
        plan::print_wave_summary(&waves, &resource_graph);
        plan::print_plan_summary(&pkg_diff);

        if !orphan_rids.is_empty() {
            let orphan_str = orphan_rids.len().to_string();
            println!("  {} orphaned", output::red(&orphan_str),);
        }
    }

    // Imports are no longer special-cased by deploy: they're applied like
    // any other resource (SSA), and wave readiness polls the cluster for the
    // described resource via `wait_for_import_target`. This means an import
    // whose installer is in the same deploy (e.g. a CRD marker with
    // `installedBy = operator.deployment`) is naturally wave-ordered after
    // the installer and only polls once its wave runs.

    let total_apply = wave_actions
        .iter()
        .flat_map(|w| w.iter())
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .count();

    if args.dry_run {
        if !ctx.global.quiet {
            if !orphan_rids.is_empty() {
                println!();
                println!(
                    "{} {} resources would be orphaned:",
                    output::yellow("Orphans:"),
                    orphan_rids.len(),
                );
                for rid in &orphan_rids {
                    println!("  {} {}", output::red("-"), rid);
                }
            }
            println!();
            println!("{}", output::dim("Dry run — no changes applied."));
        }
        return Ok(());
    }

    if total_apply == 0 && orphan_rids.is_empty() {
        return Ok(());
    }

    // Confirmation
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

    let global = ctx.global.clone();
    let cluster_name = new_graph.cluster_name.clone();
    let deploy_result = ctx.runtime.block_on(run_deploy_async(
        args,
        &global,
        &wave_actions,
        &orphan_rids,
        &old_manifests,
        &cluster_name,
        activation_name.as_deref(),
        activation_identity_hash.as_deref(),
        pre_client,
    ));

    // Save activation path for next deploy's diff
    if deploy_result.is_ok()
        && let Err(e) = kix::eval::store::save_activation_path(&args.cluster, &result_path)
    {
        tracing::warn!("failed to save activation path: {e}");
    }

    deploy_result
}

// ── Old activation resolution ────────────────────────────────────────

/// Load old activation from local cache (--current-activation mode).
fn load_old_from_cache(
    cluster: &str,
    global: &crate::cli::GlobalArgs,
) -> (Option<StoreGraph>, Vec<Value>) {
    let old_path = kix::eval::store::load_activation_path(cluster);
    match old_path {
        Some(old_result_dir) => {
            if !global.quiet {
                println!("Loading previous activation from cache...");
            }
            let noop = |_: &str| {};
            match StoreGraph::from_result_dir_with_status(&old_result_dir, &noop) {
                Ok(mut old_graph) => {
                    stamp_annotations(&mut old_graph);
                    let manifests = old_graph
                        .resources
                        .values()
                        .map(|r| r.manifest.clone())
                        .collect();
                    (Some(old_graph), manifests)
                }
                Err(e) => {
                    tracing::warn!("failed to load old activation: {e}, treating as first deploy");
                    (None, vec![])
                }
            }
        }
        None => {
            if !global.quiet {
                println!("No previous activation — first deploy.");
            }
            (None, vec![])
        }
    }
}

/// Connect to cluster, fetch Active Activation, resolve to local store graph.
async fn load_old_from_cluster(
    cluster: &str,
    global: &crate::cli::GlobalArgs,
) -> Result<(Option<StoreGraph>, Vec<Value>, Option<kube::Client>)> {
    if !global.quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| {
            miette!(
                "failed to connect to cluster: {e}. Check your kubeconfig or try --context <name>"
            )
        })?;

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    // Try to find the Active Activation on the cluster
    let active = if let Some((ar, _)) = activation::find_activation_ar(&discovery) {
        activation::find_active(&client, ar, cluster)
            .await
            .ok()
            .flatten()
    } else {
        None
    };

    match active {
        Some(act) if act.identity_hash.is_some() => {
            let hash = act.identity_hash.as_ref().unwrap();
            if !global.quiet {
                println!(
                    "Active activation: {} ({}...)",
                    output::bold(&act.name),
                    &hash[..8.min(hash.len())],
                );
            }

            // Resolve to local store graph: prefer built-via, fall back to hash lookup
            let result_dir = act
                .built_via
                .as_ref()
                .map(std::path::PathBuf::from)
                .filter(|p| p.join("kix-packages.json").exists())
                .or_else(|| kix::eval::store::resolve_activation_by_hash(cluster, hash));

            match result_dir {
                Some(result_dir) => {
                    let noop = |_: &str| {};
                    match StoreGraph::from_result_dir_with_status(&result_dir, &noop) {
                        Ok(mut old_graph) => {
                            stamp_annotations(&mut old_graph);
                            let manifests = old_graph
                                .resources
                                .values()
                                .map(|r| r.manifest.clone())
                                .collect();
                            Ok((Some(old_graph), manifests, Some(client)))
                        }
                        Err(e) => {
                            tracing::warn!(
                                "failed to load old activation store graph: {e}, treating as first deploy"
                            );
                            Ok((None, vec![], Some(client)))
                        }
                    }
                }
                None => {
                    if !global.quiet {
                        println!(
                            "  {} store path for activation not found locally — treating as first deploy",
                            output::yellow("!"),
                        );
                    }
                    Ok((None, vec![], Some(client)))
                }
            }
        }
        _ => {
            if !global.quiet {
                println!("No previous activation on cluster — first deploy.");
            }
            Ok((None, vec![], Some(client)))
        }
    }
}

// ── Apply engine (async) — thin wrapper around reconcile() ──────────

/// Build the display label for a readiness-watched resource, matching the
/// rendering used for import markers elsewhere in the CLI.
fn readiness_label(rid: &ResourceId, import_target: Option<&ImportTarget>) -> String {
    if let Some(target) = import_target {
        format!("↪ import {}/{}", target.kind, target.name)
    } else {
        rid.to_string()
    }
}

/// CLI observer that prints colored progress to stdout/stderr.
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
            ReconcileEvent::ResourceApplied {
                rid,
                action,
                import_target,
            } => {
                let (symbol, label) = match action {
                    ApplyAction::Created => (output::green("+"), "created"),
                    ApplyAction::Configured => (output::yellow("~"), "configured"),
                    ApplyAction::Unchanged => (output::dim("="), "unchanged"),
                    ApplyAction::Skipped => (output::dim("-"), "skipped"),
                };
                if !self.quiet || !matches!(action, ApplyAction::Unchanged) {
                    // Imports render with a discrete leading arrow and show the
                    // target they describe rather than the marker's own rid.
                    if let Some(target) = import_target {
                        println!(
                            "  {} {} {} {}",
                            symbol,
                            output::dim("↪ import"),
                            output::dim(&format!("{}/{}", target.kind, target.name)),
                            output::dim(label),
                        );
                    } else {
                        println!("  {} {} {}", symbol, rid, output::dim(label));
                    }
                }
            }
            ReconcileEvent::ResourceFailed { rid, error } => {
                eprintln!("  {} {} {}", output::red("!"), rid, output::red(error),);
            }
            ReconcileEvent::ResourceRecreated { rid, reason } => {
                println!(
                    "  {} {} {} {}",
                    output::yellow("↻"),
                    rid,
                    output::yellow("recreated (immutable-field conflict)"),
                    output::dim(reason),
                );
            }
            ReconcileEvent::Cancelled { at } => {
                eprintln!("\n{} deploy cancelled at {}", output::red("✗"), at);
            }
            ReconcileEvent::ReadinessWaiting { rid, import_target } => {
                if !self.quiet {
                    let label = readiness_label(rid, import_target.as_ref());
                    print!("\r\x1b[2K  Waiting for {} ...", output::dim(&label));
                    std::io::stdout().flush().ok();
                }
            }
            ReconcileEvent::ReadinessProgress {
                rid,
                import_target,
                message,
            } => {
                if !self.quiet {
                    let label = readiness_label(rid, import_target.as_ref());
                    print!(
                        "\r\x1b[2K  Waiting for {} — {}",
                        output::dim(&label),
                        output::dim(message),
                    );
                    std::io::stdout().flush().ok();
                }
            }
            ReconcileEvent::ReadinessReady { rid, import_target } => {
                if !self.quiet {
                    let label = readiness_label(rid, import_target.as_ref());
                    println!(
                        "\r\x1b[2K  Waiting for {} ... {}",
                        output::dim(&label),
                        output::green("ready"),
                    );
                }
            }
            ReconcileEvent::ReadinessTimeout {
                rid,
                import_target,
                elapsed,
                message,
            } => {
                let label = readiness_label(rid, import_target.as_ref());
                println!(
                    "\r\x1b[2K  Waiting for {} ... {} ({}s): {}",
                    output::dim(&label),
                    output::yellow("timed out"),
                    elapsed.as_secs(),
                    message,
                );
            }
            ReconcileEvent::ReadinessFailed {
                rid,
                import_target,
                message,
                missing_keys,
            } => {
                let label = readiness_label(rid, import_target.as_ref());
                println!(
                    "\r\x1b[2K  Waiting for {} ... {}: {}",
                    output::dim(&label),
                    output::red("failed"),
                    message,
                );
                if !missing_keys.is_empty() {
                    println!(
                        "    {} missing key(s): {}",
                        output::red("↳"),
                        missing_keys.join(", "),
                    );
                }
            }
            ReconcileEvent::SecretHydrated { rid, keys } => {
                if !self.quiet {
                    println!(
                        "  {} {} hydrated ({} keys from SOPS)",
                        output::green("🔓"),
                        rid,
                        keys,
                    );
                }
            }
            ReconcileEvent::SecretHydrationFailed { rid, error } => {
                eprintln!(
                    "  {} {} secret hydration failed: {}",
                    output::red("!"),
                    rid,
                    output::red(error),
                );
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
                println!("  {} {} — {}", output::yellow("!"), rid, reason,);
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
                eprintln!("  {} {}: {}", output::red("!"), rid, output::red(error),);
            }
            ReconcileEvent::Finalized { activation, old } => {
                if !self.quiet {
                    if let Some(old) = old {
                        println!("  {} Activation '{}' → Superseded", output::dim("•"), old,);
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

#[allow(clippy::too_many_arguments)]
async fn run_deploy_async(
    args: &DeployArgs,
    global: &crate::cli::GlobalArgs,
    wave_actions: &[Vec<ChangeAction>],
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    cluster_name: &str,
    activation_name: Option<&str>,
    activation_identity_hash: Option<&str>,
    pre_client: Option<kube::Client>,
) -> Result<()> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse pre-established connection or create a new one
    let client = match pre_client {
        Some(c) => c,
        None => fetch::make_client(global.context.as_deref())
            .await
            .map_err(|e| {
                miette!(
                    "failed to connect to cluster: {e}. Check your kubeconfig or try --context <name>"
                )
            })?,
    };

    let mut discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    // Map CLI args to reconcile config
    let prune_mode = args.prune_mode.unwrap_or(PruneMode::Default);
    let prune_policy = match prune_mode {
        PruneMode::No => PrunePolicy::Skip,
        PruneMode::Default if !args.prune => PrunePolicy::WarnOnly,
        PruneMode::Default | PruneMode::Eager => PrunePolicy::Delete,
    };
    let on_error = match args.on_error {
        OnError::Stop => OnErrorPolicy::Stop,
        OnError::Continue => OnErrorPolicy::Continue,
    };

    let config = ReconcileConfig {
        timeout,
        on_error,
        prune: prune_policy,
        force_conflicts: args.force_conflicts,
        cancel: kix::cluster::cancel::CancelToken::new(),
    };

    // Select observer. --tui opts into the experimental inline dashboard,
    // but only when stdout is a real terminal; otherwise fall back to the
    // line-oriented CliObserver so CI logs and piped output stay sane.
    let cli_observer = CliObserver {
        quiet: global.quiet,
    };
    let use_tui = args.tui && super::deploy_tui::is_supported();
    let tui_driver = if use_tui {
        match super::deploy_tui::TuiDriver::spawn(
            cluster_name.to_string(),
            wave_actions.len(),
            config.cancel.clone(),
        ) {
            Ok(d) => Some(d),
            Err(e) => {
                eprintln!(
                    "{} {e} — falling back to plain output",
                    output::yellow("warn: failed to start --tui renderer:"),
                );
                None
            }
        }
    } else {
        None
    };

    let tui_observer = tui_driver.as_ref().map(|d| d.observer());
    let observer_ref: &dyn ReconcileObserver = match &tui_observer {
        Some(o) => o,
        None => &cli_observer,
    };

    let result = kix::cluster::reconcile::reconcile(
        &client,
        &mut discovery,
        wave_actions,
        orphan_rids,
        old_manifests,
        cluster_name,
        activation_name,
        activation_identity_hash,
        &config,
        observer_ref,
    )
    .await;

    // Tear down the TUI before printing the final summary so the summary
    // lands in the normal scrollback and isn't clobbered by the viewport.
    drop(tui_observer);
    drop(tui_driver);

    match result {
        Ok(r) => {
            println!();
            print_summary(&r);
            Ok(())
        }
        Err(e) => {
            // Extract partial result from error variants for summary
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
        "Deploy complete: {} created, {} configured, {} unchanged, {} failed",
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

pub(crate) fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
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

// ── Operator-delegated deploy ────────────────────────────────────────

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // 1. Build new activation and load store graph (same as direct mode)
    if !ctx.global.quiet {
        println!(
            "Building cluster '{}' (operator mode)...",
            output::bold(&args.cluster)
        );
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let result_path = build_cluster_activation_with_status(&flake_path, &args.cluster, &status)
        .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    let new_manifests: Vec<Value> = new_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    let manifest_count = new_manifests.len();
    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} manifests",
            output::bold(&new_graph.cluster_name),
            manifest_count,
        );
    }

    if manifest_count == 0 {
        if !ctx.global.quiet {
            println!("Nothing to deploy.");
        }
        return Ok(());
    }

    // 2. Find activation name and identity hash from manifests
    let activation_manifest = new_manifests.iter().find(|m| {
        m.get("kind")
            .and_then(|v| v.as_str())
            .is_some_and(|k| k == "Activation")
    });
    let activation_name = activation_manifest
        .and_then(|m| {
            m.pointer("/metadata/name")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .ok_or_else(|| miette!("no Activation resource found in cluster manifests"))?;
    let activation_identity_hash = activation_manifest.and_then(|m| {
        m.pointer("/metadata/annotations")
            .and_then(|a| a.get("kix.dev/identity-hash"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });

    // 3. Show plan (optional, same as direct mode)
    if !ctx.global.quiet {
        let old_graph = if args.current_activation {
            let (og, _) = load_old_from_cache(&args.cluster, &ctx.global);
            og
        } else {
            ctx.runtime
                .block_on(load_old_from_cluster(&args.cluster, &ctx.global))
                .ok()
                .and_then(|(og, _, _)| og)
        };

        let pkg_diff = match &old_graph {
            Some(old) => plan::diff_graphs(old, &new_graph),
            None => plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph),
        };

        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);

        let resource_graph = ResourceGraph::from_manifests(&new_manifests).into_diagnostic()?;
        let waves = compute_waves(&resource_graph);
        plan::print_wave_summary(&waves, &resource_graph);
        plan::print_plan_summary(&pkg_diff);

        // Migration pair detection (doc 67) — same gate as direct mode.
        // Operator-mode is non-interactive on the operator side, so the
        // CLI must enforce the gate before handing off the Activation CR.
        let old_manifests_for_pairs: Vec<Value> = old_graph
            .as_ref()
            .map(|g| g.resources.values().map(|r| r.manifest.clone()).collect())
            .unwrap_or_default();
        let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests_for_pairs);
        if !migration_pairs.is_empty() {
            print_migration_pairs(&migration_pairs);
            if !args.accept_migrations {
                eprintln!(
                    "{}",
                    output::red(
                        "Refusing to delegate to operator: stateful migration pairs detected but --accept-migrations was not passed."
                    )
                );
                std::process::exit(1);
            }
        }
    }

    if args.dry_run {
        if !ctx.global.quiet {
            println!();
            println!("{}", output::dim("Dry run — no changes applied."));
        }
        return Ok(());
    }

    // 4. Confirmation
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
        print!("\nDelegate deploy to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Deploy cancelled.");
            return Ok(());
        }
    }

    // 5. Apply Activation CR and watch progress
    let global = ctx.global.clone();
    let source_path = result_path.display().to_string();
    let cluster_name = new_graph.cluster_name.clone();

    ctx.runtime.block_on(async {
        let (client, ar) =
            super::operator::connect_and_verify(global.context.as_deref(), global.quiet).await?;

        if !global.quiet {
            println!(
                "Applying Activation CR '{}' (source: {})...",
                output::bold(&activation_name),
                output::dim(&source_path),
            );
        }

        super::operator::apply_activation(
            &client,
            &ar,
            &activation_name,
            &cluster_name,
            &source_path,
            activation_identity_hash.as_deref(),
        )
        .await?;

        if !global.quiet {
            println!(
                "  {} Activation CR applied — waiting for operator...",
                output::green("✓"),
            );
        }

        super::operator::watch_activation_progress(
            &client,
            &ar,
            &activation_name,
            &source_path,
            global.quiet,
        )
        .await?;

        println!();
        println!(
            "Deploy via operator {}: Activation '{}' is {}",
            output::green("complete"),
            output::bold(&activation_name),
            output::green("Active"),
        );

        Ok::<(), miette::Report>(())
    })?;

    // Save activation path for next deploy's diff
    if let Err(e) = kix::eval::store::save_activation_path(&args.cluster, &result_path) {
        tracing::warn!("failed to save activation path: {e}");
    }

    Ok(())
}

/// Render detected stateful migration pairs to stdout. Phase 1 of doc 67:
/// awareness only, the user must handle data movement out-of-band before
/// re-running deploy with --accept-migrations.
fn print_migration_pairs(pairs: &[MigrationPair]) {
    println!();
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
