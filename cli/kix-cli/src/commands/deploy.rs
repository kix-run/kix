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

use kix_cluster::activation;
use kix_cluster::apply::{ApplyAction, ChangeAction};
use kix_cluster::fetch;
use kix_cluster::graph::ResourceGraph;
use kix_cluster::readiness::{self, ReadinessResult};
use kix_cluster::waves::compute_waves;
use kix_eval::build::build_cluster_activation_with_status;
use kix_eval::store_graph::StoreGraph;
use kix_manifest::stamp::stamp_annotations;
use kix_manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::{DeployArgs, OnError, PruneMode};
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
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
    let all_actions = kix_cluster::apply::detect_changes(&new_manifests, &old_manifests);

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
        && let Err(e) = kix_eval::store::save_activation_path(&args.cluster, &result_path)
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
    let old_path = kix_eval::store::load_activation_path(cluster);
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

            // Resolve identity-hash to local store graph
            match kix_eval::store::resolve_activation_by_hash(cluster, hash) {
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

// ── Apply engine (async) ─────────────────────────────────────────────

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

    let mut total_created = 0usize;
    let mut total_configured = 0usize;
    let mut total_unchanged = 0usize;
    let mut total_failed = 0usize;

    // Determine resume point (if a previous deploy crashed mid-wave)
    let activation_ar = activation::find_activation_ar(&discovery).map(|(ar, _)| ar.clone());
    let resume_from = if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
        match activation::resume_point(&client, ar, act_name).await {
            Ok(Some(idx)) if idx > 0 => {
                if !global.quiet {
                    println!(
                        "Resuming from wave {} (waves 1-{} already complete)",
                        idx + 1,
                        idx,
                    );
                }
                idx
            }
            _ => 0,
        }
    } else {
        0
    };

    // Record deploy start on the Activation CR
    if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name)
        && let Err(e) = activation::begin_deploy(&client, ar, act_name, wave_actions.len()).await
    {
        tracing::warn!("failed to set Deploying phase: {e}");
    }

    // Apply waves (creates and updates only)
    for (wave_idx, actions) in wave_actions.iter().enumerate() {
        // Skip waves completed in a previous (crashed) deploy
        if wave_idx < resume_from {
            let wave_count = actions.len();
            if !global.quiet {
                println!(
                    "\n{} {} resources (already complete, skipping)",
                    output::bold(&format!("Wave {}:", wave_idx + 1)),
                    wave_count,
                );
            }
            total_unchanged += wave_count;
            continue;
        }
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
            // Record wave as complete (all skipped)
            if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
                let _ = activation::record_wave(
                    &client,
                    ar,
                    act_name,
                    &activation::WaveRecord {
                        wave_index: wave_idx,
                        status: activation::WaveStatus::Complete,
                        resource_count: actions.len(),
                        applied: 0,
                        failed: 0,
                    },
                )
                .await;
            }
            continue;
        }

        if !global.quiet {
            println!(
                "\n{} applying {} resources...",
                output::bold(&format!("Wave {}:", wave_idx + 1)),
                apply_count,
            );
        }

        let results = kix_cluster::apply::apply_wave(
            &client,
            &discovery,
            actions,
            false,
            activation_identity_hash,
        )
        .await;

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

        // Readiness polling for this wave
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
                        let ns = if rid.namespace == CLUSTER_SCOPED {
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

        // Re-discover API resources if this wave created CRDs
        let wave_had_crds = actions.iter().any(|a| {
            if let ChangeAction::Apply(m) = a {
                ResourceId::from_value(m).kind == "CustomResourceDefinition"
            } else {
                false
            }
        });
        if wave_had_crds && let Ok(new_disc) = fetch::discover_resources(&client).await {
            discovery = new_disc;
        }

        // Record wave progress on the Activation CR
        if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
            let wave_applied = results
                .iter()
                .filter(|(_, r)| {
                    r.as_ref().is_ok_and(|r| {
                        matches!(r.action, ApplyAction::Created | ApplyAction::Configured)
                    })
                })
                .count();
            let wave_failed_count = results.iter().filter(|(_, r)| r.is_err()).count();
            let status = if wave_failed {
                activation::WaveStatus::Failed
            } else {
                activation::WaveStatus::Complete
            };
            let _ = activation::record_wave(
                &client,
                ar,
                act_name,
                &activation::WaveRecord {
                    wave_index: wave_idx,
                    status,
                    resource_count: actions.len(),
                    applied: wave_applied,
                    failed: wave_failed_count,
                },
            )
            .await;
        }
    }

    // Prune orphans (after all apply waves)
    let prune_mode = args.prune_mode.unwrap_or(PruneMode::Default);
    if !orphan_rids.is_empty() && prune_mode != PruneMode::No {
        // Compute reverse topo order for orphans from old manifests
        let ordered_orphans = compute_prune_order(orphan_rids, old_manifests);

        if prune_mode == PruneMode::Default && !args.prune {
            // Warn about orphans but don't delete
            println!();
            println!(
                "{} {} resources on cluster not in new activation (use --prune to delete):",
                output::yellow("Orphans:"),
                ordered_orphans.len(),
            );
            for rid in &ordered_orphans {
                println!("  {} {}", output::yellow("-"), rid);
            }
        } else {
            // Actually prune
            let ar_by_kind: std::collections::HashMap<
                String,
                (&kube::discovery::ApiResource, kube::discovery::Scope),
            > = discovery
                .iter()
                .map(|(ar, scope)| (ar.kind.clone(), (ar, scope.clone())))
                .collect();

            println!();
            println!(
                "{} Pruning {} orphaned resources...",
                output::bold("Prune:"),
                ordered_orphans.len(),
            );

            for rid in &ordered_orphans {
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
                        let ns = if rid.namespace == CLUSTER_SCOPED {
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
        }
    }

    // Finalize activation lifecycle (mark old as Superseded, new as Active)
    if total_failed == 0
        && let Some(act_name) = activation_name
        && let Some((ar, _)) = activation::find_activation_ar(&discovery)
    {
        // Find the previously Active activation
        let old_activation = activation::find_active(&client, ar, cluster_name)
            .await
            .ok()
            .flatten()
            // Don't supersede ourselves (first deploy or redeploy of same name)
            .filter(|old| old.name != act_name);

        if let Err(e) = activation::finalize_deploy(
            &client,
            ar,
            cluster_name,
            act_name,
            old_activation.as_ref(),
        )
        .await
        {
            tracing::warn!("failed to finalize activation lifecycle: {e}");
        } else if !global.quiet {
            if let Some(ref old) = old_activation {
                println!(
                    "  {} Activation '{}' → Superseded",
                    output::dim("•"),
                    old.name,
                );
            }
            println!(
                "  {} Activation '{}' → Active",
                output::green("•"),
                act_name,
            );
        }
    }

    // Summary
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

/// Compute prune order: reverse topological order from old graph (dependents first).
fn compute_prune_order(orphan_rids: &[ResourceId], old_manifests: &[Value]) -> Vec<ResourceId> {
    // Build graph from old manifests that are orphans
    let orphan_set: std::collections::HashSet<String> = orphan_rids
        .iter()
        .map(|rid| format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
        .collect();

    let orphan_manifests: Vec<Value> = old_manifests
        .iter()
        .filter(|m| {
            let rid = ResourceId::from_value(m);
            orphan_set.contains(&format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
        })
        .cloned()
        .collect();

    match ResourceGraph::from_manifests(&orphan_manifests) {
        Ok(graph) => {
            let waves = compute_waves(&graph);
            // Reverse: delete dependents (later waves) first
            let mut ordered: Vec<ResourceId> = Vec::new();
            for wave in waves.into_iter().rev() {
                for idx in wave {
                    ordered.push(graph.graph[idx].id.clone());
                }
            }
            ordered
        }
        Err(_) => {
            // If graph construction fails, fall back to unordered
            orphan_rids.to_vec()
        }
    }
}

fn print_summary(created: usize, configured: usize, unchanged: usize, failed: usize) {
    let failed_str = failed.to_string();
    println!(
        "Deploy complete: {} created, {} configured, {} unchanged, {} failed",
        output::green(&created.to_string()),
        output::yellow(&configured.to_string()),
        output::dim(&unchanged.to_string()),
        if failed > 0 {
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
