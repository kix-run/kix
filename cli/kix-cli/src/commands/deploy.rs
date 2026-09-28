//! Build, plan, and deploy a cluster activation.
//!
//! Uses the store graph for proper stamping and dependency tracking.
//! Change detection compares two Nix store graphs
//! by K8s identity (kind+ns+name) and identity-hash, without querying
//! the live cluster.
//!
//! It builds and stamps the requested activation, resolves the current state,
//! displays the package-grouped diff, applies the dependency graph, and prunes
//! authorized orphans in reverse dependency order.

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use crate::commands::baseline;
use kix::cluster::activation;
use kix::cluster::apply::{ApplyAction, ChangeAction};
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::cluster::ops::{ClusterOps, KubeOps, KubeOpsConfig};
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, DeployPlan, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeId, TransitionKind,
    Verdict,
};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::lifecycle;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::cli::{DeployArgs, OnError, PruneMode};
use crate::output;
use crate::plan;

use super::CommandContext;
use kix::manifest::keys;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        return run_operator(args, ctx);
    }

    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // Build the new activation and load its store graph.
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &status)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("{e}"))?;
    // A kixpkgs pin from before the domain move renders Kix's own CRDs under
    // the retired group. Deploying it would put those CRDs back and leave two
    // groups live, which the CLI cannot tell apart. Check before
    // `stamp_annotations`, which upgrades a loaded build to the current
    // domain: after that a stale pin is indistinguishable from a current one.
    kix::legacy_domain::check_build(
        &new_graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| miette!("{e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    // Collect stamped manifests from the new graph.
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

    // Resolve the old activation from the cluster or local cache.
    let (old_graph, active_manifests, pre_client, active) = if args.current_activation {
        // Local cache mode does not connect before confirmation.
        let (og, om) = load_old_from_cache(&args.cluster, &ctx.global);
        let active = cached_as_active(&args.cluster, &om);
        (og, om, None, active)
    } else {
        // Fetch the active Activation from the cluster.
        ctx.runtime
            .block_on(load_old_from_cluster(&args.cluster, &ctx.global))?
    };
    let active_hash = active.as_ref().and_then(|a| a.identity_hash.clone());

    // Builds whose orphans an earlier warn-only deploy kept. The Active
    // closure no longer declares those objects, so without these the plan
    // cannot see them.
    let kept_baseline = match &active {
        Some(active) => baseline::load_kept(active, &args.cluster, ctx.global.quiet),
        None => baseline::KeptBaseline::default(),
    };

    // Include closures from deploys that stopped part way. They applied objects and
    //     never became Active, so neither side of the comparison above knows
    //     about them (kixpkgs#82). Resolved from the local store by hash, so
    //     every input to the plan is still a compiler output.
    //
    //     `--current-activation` has no cluster connection, so it
    //     cannot see the records and says so in its own flag documentation.
    let failed_baseline = match (&pre_client, args.current_activation) {
        (Some(client), false) => ctx.runtime.block_on(async {
            let discovery = fetch::discover_resources(client)
                .await
                .map_err(|e| miette!("{e}"))?;
            let Some((ar, _)) = kix::cluster::activation::find_activation_ar(&discovery)
                .map_err(|e| miette!("{e}"))?
            else {
                return Ok(baseline::FailedBaseline::default());
            };
            // Another deploy still in flight would be applying the very
            // objects this plan might prune, so leave its work alone rather
            // than guessing which of the two is real.
            if let Some(record) = baseline::deploy_in_flight(client, ar, &args.cluster).await {
                baseline::report_in_flight(&record, ctx.global.quiet);
                return Ok(baseline::FailedBaseline::default());
            }
            Ok::<_, miette::Report>(
                baseline::load_failed(client, ar, &args.cluster, ctx.global.quiet).await,
            )
        })?,
        _ => baseline::FailedBaseline::default(),
    };

    // The plan display and the prune ordering both need a manifest for an
    // object that exists only in a failed or kept closure.
    let old_manifests = kix::cluster::apply::baseline_manifests(
        &active_manifests,
        &[
            failed_baseline.closures.as_slice(),
            kept_baseline.closures.as_slice(),
        ]
        .concat(),
    );

    // 4. Local DAG diff: old vs new, then fold in what the failed deploys may
    //    have left. The fold can turn a Skip into an Apply (repair) and can
    //    add orphans (prune); it never invents a change the closures do not
    //    justify.
    let all_actions = kix::cluster::apply::fold_kept_closures(
        kix::cluster::apply::fold_failed_closures(
            kix::cluster::apply::detect_changes(&new_manifests, &active_manifests),
            &new_manifests,
            &failed_baseline.closures,
        ),
        &new_manifests,
        &kept_baseline.closures,
    );

    // What the new record lists under `status.orphansKeptFrom` if this run
    // leaves orphans on the cluster.
    let mut kept_orphans = baseline::orphans_kept_from(
        &new_manifests,
        active.as_ref(),
        &active_manifests,
        &failed_baseline,
        &kept_baseline,
    );
    // The plan did not read the Active record, so its list is carried
    // forward unexamined.
    kept_orphans.carry_current = args.current_activation;

    // Detect stateful migration pairs and require --accept-migrations.
    // Against the Active closure only. A half-applied closure is not a
    // previous intended state, so pairing against it would invent migrations
    // nobody declared.
    let migration_pairs = detect_migration_pairs(&new_manifests, &active_manifests);
    if !migration_pairs.is_empty() {
        print_migration_pairs(&migration_pairs);
        if !args.accept_migrations {
            eprintln!(
                "{}",
                output::red(
                    "Deployment stopped: these changes move workloads to different storage. Migrate the data before continuing."
                )
            );
            eprintln!(
                "{}",
                output::yellow(
                    "Data migration is not automated. Review the source and target resources above, migrate the data yourself, then rerun with --accept-migrations."
                )
            );
            std::process::exit(1);
        }
        if !ctx.global.quiet {
            println!(
                "{}",
                output::yellow(
                    "--accept-migrations set: continuing deployment. Kix will not copy data. Workloads using the new storage will see only the data already present there."
                )
            );
        }
    }

    // --reconcile reapplies resources regardless of identity match.
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

    // Separate apply actions from orphans.
    let mut orphan_rids: Vec<ResourceId> = Vec::new();

    for action in &all_actions {
        if let ChangeAction::Orphan(rid) = action {
            orphan_rids.push(rid.clone());
        }
    }

    // Build the DAG and streaming plan.
    let resource_graph = ResourceGraph::from_manifests(&new_manifests).into_diagnostic()?;

    if resource_graph.graph.node_count() == 0 {
        if !ctx.global.quiet {
            println!("No resources to deploy.");
        }
        return Ok(());
    }

    let plan = DeployPlan::from_graph_and_changes(&resource_graph, &all_actions);

    // Read the Activation name and identity hash from the new manifests.
    let activation_manifest = lifecycle::record_of(&new_manifests);
    let activation_name = activation_manifest.and_then(|m| {
        m.pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    let activation_identity_hash =
        activation_manifest.and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(|s| s.to_string()));

    // Display package-grouped changes.
    if !ctx.global.quiet {
        let pkg_diff = if let Some(old) = &old_graph {
            plan::diff_graphs(old, &new_graph)
        } else if !old_manifests.is_empty() {
            // Synthesize a package view when the old store graph is unavailable
            // a package view from the old manifests so untouched packages
            // show as unchanged instead of everything "added".
            let synthetic = StoreGraph::synthesize(&old_manifests, &new_graph);
            plan::diff_graphs(&synthetic, &new_graph)
        } else {
            // A first deploy adds every package.
            plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph)
        };

        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);
        plan::print_plan_summary(&pkg_diff);

        // Jobs under the rerun rule that changed: the engine deletes and
        // recreates them, so the preview says so before the confirmation.
        let reruns: Vec<String> = plan
            .nodes
            .iter()
            .filter(|n| matches!(n.kind, TransitionKind::Recreate))
            .map(|n| match &n.id {
                NodeId::Resource(rid) => rid.to_string(),
                NodeId::Synthetic(s) => s.clone(),
            })
            .collect();
        if !reruns.is_empty() {
            println!(
                "  {} {} under the rerun rule (deleted first when live): {}",
                output::yellow("↻"),
                reruns.len(),
                reruns.join(", "),
            );
        }

        let fate = if args.prune_mode == Some(PruneMode::No) {
            "kept (--prune-mode=no)".to_string()
        } else if prune_flag_requested(args) {
            "will be deleted".to_string()
        } else {
            format!("kept; {KEPT_ORPHANS_HINT}")
        };
        print!("{}", render_plan_orphans(&orphan_rids, &fate));

        // Where the extra work in this plan came from. Without this the
        // reader sees a deploy of an unchanged config proposing changes, and
        // has no way to tell why.
        if !failed_baseline.is_empty() {
            let names: Vec<&str> = failed_baseline
                .consumed
                .iter()
                .map(String::as_str)
                .collect();
            println!(
                "  {} reconciling what {} left behind ({})",
                output::yellow("!"),
                if names.len() == 1 {
                    "a failed deploy".to_string()
                } else {
                    format!("{} failed deploys", names.len())
                },
                names.join(", "),
            );
        }
    }

    // Imports are applied like any other resource (SSA); readiness polls the
    // cluster for the described resource via `wait_for_import_target`, which
    // is triggered when the import node becomes eligible under the DAG.

    let total_apply = plan
        .nodes
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
        .count();

    if total_apply == 0 && orphan_rids.is_empty() {
        // An unchanged plan can still owe a run: a probe Job under
        // `kix.run/rerun` whose last run failed (the failure kept the
        // activation from switching, so the next deploy sees the same
        // hashes). The engine's Skip path recreates it, but only if the
        // engine runs.
        let has_reruns = plan.nodes.iter().any(|n| n.rerun.is_some());
        let failed_reruns = match &pre_client {
            Some(client) if has_reruns => ctx.runtime.block_on(async {
                let discovery = fetch::discover_resources(client)
                    .await
                    .map_err(|e| miette!("{e}"))?;
                Ok::<_, miette::Report>(
                    scheduler::failed_rerun_nodes(client, &discovery, &plan).await,
                )
            })?,
            _ => Vec::new(),
        };
        // Without a client here (`--current-activation`) the engine's Skip
        // path makes the call instead: it reads the live objects itself.
        let engine_decides = pre_client.is_none() && has_reruns && !args.dry_run;
        if failed_reruns.is_empty() && !engine_decides {
            // A folded-in record still has to be superseded, even when its
            // closure turned out to differ from the plan only in things
            // nothing prunes (a Namespace, the record itself). The engine
            // never runs on this path, and `finalize_deploy` is where records
            // are normally consumed, so do it here or report the same failed
            // deploy on every deploy from now on.
            if let (Some(client), false) = (&pre_client, args.dry_run) {
                supersede_consumed(ctx, client, &failed_baseline.consumed, ctx.global.quiet);
            }
            if !ctx.global.quiet {
                match (&activation_identity_hash, &active_hash) {
                    (Some(new), Some(old)) if new == old => println!(
                        "{} activation identical to active ({}...). Nothing to apply.",
                        output::dim("="),
                        &new[..8.min(new.len())],
                    ),
                    _ => println!("Nothing to apply."),
                }
            }
            return Ok(());
        }
        if !ctx.global.quiet && engine_decides {
            println!(
                "{} nothing changed; the engine reads the live probe Jobs to see whether one must run again",
                output::yellow("↻"),
            );
        }
        if !ctx.global.quiet && !failed_reruns.is_empty() {
            let names: Vec<String> = failed_reruns.iter().map(|r| r.to_string()).collect();
            println!(
                "{} nothing changed, but {} failed on the last run and will run again: {}",
                output::yellow("↻"),
                failed_reruns.len(),
                names.join(", "),
            );
        }
    }

    // An offline dry run classifies Create and Configured from the local
    // identity diff. It cannot perform admission, RBAC, or conflict checks.
    if args.dry_run && pre_client.is_none() {
        return render_offline_dry_run(&plan, &old_manifests, &orphan_rids, &ctx.global);
    }

    // Online dry runs send apply and delete requests with `dryRun=All`, so
    // per-resource outcomes come from the apiserver.
    if args.dry_run && !ctx.global.quiet {
        println!();
        println!("{}", output::dim("Dry run. No changes will be applied."));
    }

    // Build the deployment receipt before confirmation so dirty source state
    // is visible in the prompt.
    let receipt = if args.dry_run {
        None
    } else {
        Some(crate::commands::compliance::receipt::build_receipt(
            &new_graph,
            &ctx.global.flake,
        ))
    };

    if let Some(receipt) = &receipt
        && receipt["source"]["dirty"] == Value::Bool(true)
        && !ctx.global.quiet
    {
        // A dirty tree is allowed, but its recorded commit does not fully
        // describe the deployed source.
        println!();
        println!(
            "{}",
            output::yellow(
                "The working tree has uncommitted changes, so the commit recorded for this deploy"
            )
        );
        println!(
            "{}",
            output::yellow("does not contain what is about to be applied. The record will say so.")
        );
        if let Some(rev) = receipt["source"]["revision"].as_str() {
            println!("  {}", output::dim(rev));
        }
    }

    // The nodes: do they carry the labels the plan's placement rules name?
    // Only when a connection already exists: --current-activation is the
    // no-cluster-before-confirm mode.
    if let Some(client) = &pre_client
        && !ctx.global.quiet
    {
        report_topology_labels(ctx, client, &new_manifests);
    }

    // Confirm before writing to the cluster.
    if !args.yes && !args.dry_run {
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
        plan,
        &orphan_rids,
        &old_manifests,
        &cluster_name,
        activation_name.as_deref(),
        activation_identity_hash.as_deref(),
        receipt.as_ref(),
        pre_client,
        activation_manifest,
        &failed_baseline.consumed,
        kept_orphans,
    ));

    // Save activation path for next deploy's diff and for soft `kix gc`.
    // Never after a dry run: nothing was deployed, and a cache that names a
    // build the cluster does not run makes soft gc treat every resource of
    // the real deploy as garbage.
    if deploy_result.is_ok()
        && !args.dry_run
        && let Err(e) = kix::eval::store::save_activation_path(&args.cluster, &result_path)
    {
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    deploy_result
}

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
                    let manifests: Vec<Value> = old_graph
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
                println!("No previous activation. First deploy.");
            }
            (None, vec![])
        }
    }
}

/// The cached build as the current record, for `--current-activation`, which
/// does not read the cluster's records before confirmation. It has no
/// `orphansKeptFrom`, so orphans kept by earlier deploys are not in its plan;
/// finalize carries the real record's list forward instead.
fn cached_as_active(cluster: &str, manifests: &[Value]) -> Option<activation::ActiveActivation> {
    let record = lifecycle::record_of(manifests)?;
    Some(activation::ActiveActivation {
        name: record.pointer("/metadata/name")?.as_str()?.to_string(),
        identity_hash: keys::get(record, keys::IDENTITY_HASH).map(str::to_string),
        built_via: kix::eval::store::load_activation_path(cluster)
            .map(|p| p.to_string_lossy().into_owned()),
        orphans_kept_from: Vec::new(),
    })
}

/// Connect to cluster, fetch Active Activation, resolve to local store graph.
/// The final tuple element is the Active record, whose identity hash reports
/// a no-op deploy as "activation identical" and whose `orphansKeptFrom` names
/// earlier builds to prune against.
async fn load_old_from_cluster(
    cluster: &str,
    global: &crate::cli::GlobalArgs,
) -> Result<(
    Option<StoreGraph>,
    Vec<Value>,
    Option<kube::Client>,
    Option<activation::ActiveActivation>,
)> {
    if !global.quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    // Try to find the Active Activation on the cluster
    let active = if let Some((ar, _)) =
        activation::find_activation_ar(&discovery).map_err(|e| miette!("{e}"))?
    {
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

            // Prefer built-via, then fall back to the activation hash.
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
                            let manifests: Vec<Value> = old_graph
                                .resources
                                .values()
                                .map(|r| r.manifest.clone())
                                .collect();
                            Ok((Some(old_graph), manifests, Some(client), Some(act)))
                        }
                        Err(e) => {
                            // A store path that exists but will not load is
                            // not a first deploy. Fall back to the cluster
                            // rather than planning against nothing.
                            if !global.quiet {
                                println!(
                                    "  {} previous build at {} would not load ({e}). Reconstructing previous state from cluster",
                                    output::yellow("!"),
                                    result_dir.display(),
                                );
                            }
                            let old_manifests =
                                reconstruct_old_from_live(&client, &discovery).await?;
                            Ok((None, old_manifests, Some(client), Some(act)))
                        }
                    }
                }
                None => {
                    if !global.quiet {
                        println!(
                            "  {} store path for activation not found locally. Reconstructing previous state from cluster",
                            output::yellow("!"),
                        );
                    }
                    let old_manifests = reconstruct_old_from_live(&client, &discovery).await?;
                    Ok((None, old_manifests, Some(client), Some(act)))
                }
            }
        }
        _ => {
            if !global.quiet {
                println!("No previous activation on cluster. First deploy.");
            }
            Ok((None, vec![], Some(client), None))
        }
    }
}

/// Mark records Superseded whose leftovers this run has nothing left to do
/// about.
///
/// Only for the path that returns before the engine starts. Every other route
/// goes through `finalize_deploy`, which does this as part of the lifecycle.
/// Best-effort: a record that will not supersede is reported again next time,
/// which is annoying but not wrong.
fn supersede_consumed(
    ctx: &CommandContext,
    client: &kube::Client,
    consumed: &[String],
    quiet: bool,
) {
    if consumed.is_empty() {
        return;
    }
    let done = ctx.runtime.block_on(async {
        let Ok(discovery) = fetch::discover_resources(client).await else {
            return 0usize;
        };
        let Ok(Some((ar, _))) = kix::cluster::activation::find_activation_ar(&discovery) else {
            return 0;
        };
        let mut done = 0;
        for name in consumed {
            match kix::cluster::activation::supersede_activation(client, ar, name).await {
                Ok(()) => done += 1,
                Err(e) => tracing::warn!(activation = %name, error = %e, "could not supersede"),
            }
        }
        done
    });
    if done > 0 && !quiet {
        println!(
            "  {} {done} failed deploy record(s) had nothing left to reconcile; marked superseded",
            output::dim("="),
        );
    }
}

/// What deletes the orphans a warn-only run keeps. Both work because the
/// record the run finalizes lists the builds they came from under
/// `status.orphansKeptFrom`.
pub(crate) const KEPT_ORPHANS_HINT: &str = "`kix deploy --prune` or `kix gc` deletes them";

/// The topology label preflight, printed above the confirmation. The
/// compiler derives spread on cluster.topology.zoneKey and cannot see a
/// node; under DoNotSchedule a node without the label cannot take the pod,
/// and the first sign would be a readiness stall. One LIST of nodes here
/// names the label instead. Warn only, never a refusal.
fn report_topology_labels(ctx: &CommandContext, client: &kube::Client, manifests: &[Value]) {
    use kix::cluster::topology::{NodesOutcome, assess, list_nodes};

    let keys = kix::cluster::topology::topology_keys(manifests);
    if keys.is_empty() {
        return;
    }
    match ctx.runtime.block_on(list_nodes(client)) {
        Ok(NodesOutcome::Listed(nodes)) => {
            for finding in assess(&keys, &nodes) {
                let tag = if finding.is_warning() {
                    output::yellow("warn:")
                } else {
                    output::dim("note:")
                };
                println!("{tag} {}", finding.describe());
            }
        }
        Ok(NodesOutcome::Forbidden) => {
            println!(
                "{}",
                output::dim("note: topology labels not checked; this account may not list nodes")
            );
        }
        Err(e) => {
            println!(
                "{} could not list nodes to check topology labels: {}",
                output::yellow("warn:"),
                kix::cluster::errors::describe(&e)
            );
        }
    }
}

/// The prune policy the flags ask for. `--prune-mode=no` skips, plain
/// `deploy` reports orphans without deleting (warn-only), `--prune` deletes.
fn prune_policy_for(args: &DeployArgs) -> PrunePolicy {
    match args.prune_mode.unwrap_or(PruneMode::Default) {
        PruneMode::No => PrunePolicy::Skip,
        PruneMode::Default if !args.prune => PrunePolicy::WarnOnly,
        PruneMode::Default => PrunePolicy::Delete,
    }
}

/// Will this run delete orphans? Used to word the plan honestly.
fn prune_flag_requested(args: &DeployArgs) -> bool {
    prune_policy_for(args) == PrunePolicy::Delete
}

/// Reconstruct the previous deploy's manifest set from live cluster state.
///
/// Fallback for when the old activation's store path is gone (garbage-
/// collected, or the deploy came from another machine). Every kix-managed
/// resource carries the identity-hash and depends-on annotations that
/// change detection and prune ordering read, so live objects projected
/// back to manifests substitute for the old store graph. Activation CRs
/// are excluded: their lifecycle is supersede-managed, never prune (same
/// policy as the operator's reconcile).
///
/// A failed sweep is an error, not an empty previous state. Planning
/// against an empty old set would show every resource as "added" and,
/// with `--prune`, would compute no orphans at all: a plan that looks
/// plausible and is wrong.
async fn reconstruct_old_from_live(
    client: &kube::Client,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
) -> Result<Vec<Value>> {
    let objects = fetch::fetch_managed_resources(client, discovery)
        .await
        .map_err(|e| {
            miette!(
                "cannot reconstruct the previous state from the cluster: {e}. \
                 Refusing to plan from a partial view; retry when the apiserver is healthy."
            )
        })?;
    Ok(fetch::kix_owned_manifests(objects.into_iter().filter(
        |obj| lifecycle::lifecycle_of_live(obj).prunable(),
    )))
}

/// Line-oriented observer for DAG-streaming deploys. Emits one line per
/// terminal verdict or phase boundary; readiness
/// heartbeats land on stderr with `-v`.
///
pub(crate) struct StreamCliObserver {
    pub(crate) quiet: bool,
    pub(crate) verbose: bool,
}

impl DeployObserver for StreamCliObserver {
    fn on_event(&self, event: &DeployEvent) {
        match event {
            DeployEvent::PlanComputed { nodes, .. } => {
                if !self.quiet {
                    println!("{} {} nodes", output::dim("plan:"), nodes.len(),);
                }
            }
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => self.render_node_state(node, *kind, verdict, detail.as_ref()),
            DeployEvent::CrdRediscovery => {
                if self.verbose {
                    eprintln!("{} re-running API discovery", output::dim("crd:"));
                }
            }
            DeployEvent::PruneStart {
                resources,
                kept,
                delete,
                ..
            } => print!("{}", render_prune_start(resources, kept, *delete)),
            DeployEvent::Finalized {
                activation,
                previous,
            } => {
                if !self.quiet {
                    if let Some(prev) = previous {
                        println!("  {} activation '{}' → Superseded", output::dim("•"), prev);
                    }
                    println!(
                        "  {} activation '{}' → Active",
                        output::green("•"),
                        activation,
                    );
                }
            }
            DeployEvent::Stopped { reason } => {
                eprintln!("\n{} {}", output::red("✗"), output::red(reason));
            }
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => {
                let line = kix::cluster::watchdog::describe(*idle, in_flight);
                if *aborting {
                    eprintln!("{} {line}; giving up", output::red("stalled:"));
                } else {
                    eprintln!("{} {line}", output::yellow("stalled:"));
                }
            }
            DeployEvent::BestEffortFailed { what, message } => {
                eprintln!("{} {what} failed: {message}", output::yellow("warn:"),);
            }
        }
    }
}

impl StreamCliObserver {
    fn render_node_state(
        &self,
        node: &NodeId,
        kind: TransitionKind,
        verdict: &Verdict,
        detail: Option<&NodeDetail>,
    ) {
        let label = self.node_label(node);
        let tag = kind
            .tag()
            .map(|t| format!("{} ", output::dim(t)))
            .unwrap_or_default();
        match verdict {
            Verdict::Pending => {}
            Verdict::Running => match detail {
                Some(NodeDetail::Applied(action))
                    if (!self.quiet || !matches!(action, ApplyAction::Unchanged)) =>
                {
                    let (symbol, lbl) = apply_symbol(action);
                    println!("  {} {}{} {}", symbol, tag, label, output::dim(lbl));
                }
                Some(NodeDetail::SecretHydrated { keys }) if !self.quiet => {
                    println!(
                        "  {} {} hydrated ({} keys from SOPS)",
                        output::green("🔓"),
                        label,
                        keys,
                    );
                }
                Some(NodeDetail::ReadinessProgress(_)) => {}
                _ => {}
            },
            Verdict::Ready => match detail {
                Some(NodeDetail::Applied(action)) => {
                    // Skip nodes reach Ready via Applied(Unchanged); render them
                    // as a single dim line under `-v`. Non-skip Ready events are
                    // still announced with a terminal ✔ line below.
                    if matches!(kind, TransitionKind::Skip) {
                        if self.verbose {
                            let (_, lbl) = apply_symbol(action);
                            println!(
                                "  {} {}{} {}",
                                output::dim("="),
                                tag,
                                label,
                                output::dim(lbl)
                            );
                        }
                    } else {
                        println!(
                            "  {} {} {}",
                            output::green("✔"),
                            label,
                            output::dim("ready")
                        );
                    }
                }
                Some(NodeDetail::RecreatedInPlace { reason }) => {
                    println!(
                        "  {} {} {} {}",
                        output::yellow("↻"),
                        label,
                        output::yellow("recreated (immutable-field conflict)"),
                        output::dim(reason),
                    );
                }
                Some(NodeDetail::Rerun { reason }) => {
                    println!(
                        "  {} {} {}",
                        output::yellow("↻"),
                        label,
                        output::yellow(&format!("ran again ({reason})")),
                    );
                }
                _ => {
                    println!(
                        "  {} {} {}",
                        output::green("✔"),
                        label,
                        output::dim("ready")
                    );
                }
            },
            Verdict::Failed { message } => {
                let detail_tail = match detail {
                    Some(NodeDetail::ReadinessFailed { missing_keys, .. })
                        if !missing_keys.is_empty() =>
                    {
                        format!(
                            "\n    {} missing key(s): {}",
                            output::red("↳"),
                            missing_keys.join(", "),
                        )
                    }
                    Some(NodeDetail::ReadinessTimeout { elapsed, .. }) => {
                        format!(" {}", output::dim(&format!("({}s)", elapsed.as_secs())))
                    }
                    _ => String::new(),
                };
                eprintln!(
                    "  {} {} {}{}",
                    output::red("⚠"),
                    label,
                    output::red(message),
                    detail_tail,
                );
                // What the container wrote before it exited: a probe's
                // FAIL lines, so the reason is on screen, not one
                // `kubectl logs` away.
                if let Some(NodeDetail::ReadinessFailed { output, .. }) = detail {
                    for line in output {
                        eprintln!("      {}", output::dim(line));
                    }
                }
            }
            Verdict::Cancelled { because } => {
                if self.verbose {
                    let because = match because {
                        CancelReason::PredecessorFailed(rid) => format!("predecessor {rid} failed"),
                        CancelReason::External => "external cancel".to_string(),
                    };
                    println!(
                        "  {} {} {}",
                        output::dim("⊘"),
                        label,
                        output::dim(&format!("cancelled ({because})")),
                    );
                }
            }
            Verdict::AwaitingInput { prompt } => {
                println!(
                    "  {} {} {}",
                    output::yellow("⏯"),
                    label,
                    output::yellow(prompt)
                );
            }
            Verdict::DriftDetected { message, .. } => {
                println!(
                    "  {} {} {}",
                    output::yellow("↻"),
                    label,
                    output::yellow(message),
                );
            }
        }
    }

    fn node_label(&self, node: &NodeId) -> String {
        match node {
            NodeId::Resource(rid) => rid.to_string(),
            NodeId::Synthetic(s) => format!("⟦{s}⟧"),
        }
    }
}

fn apply_symbol(action: &ApplyAction) -> (std::borrow::Cow<'static, str>, &'static str) {
    // Apply-phase glyphs are muted because they share the screen with
    // the terminal ✔ `ready` lines, which should own the green accent.
    // Created: white (neutral new), Configured: yellow (changed), Skipped /
    // Unchanged: dim grey (no-op).
    match action {
        ApplyAction::Created => (std::borrow::Cow::Borrowed("+"), "created"),
        ApplyAction::Configured => (output::yellow("~"), "configured"),
        ApplyAction::Unchanged => (output::dim("="), "unchanged"),
        ApplyAction::Skipped => (output::dim("-"), "skipped"),
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_deploy_async(
    args: &DeployArgs,
    global: &crate::cli::GlobalArgs,
    plan: DeployPlan,
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    cluster_name: &str,
    activation_name: Option<&str>,
    activation_identity_hash: Option<&str>,
    receipt: Option<&Value>,
    pre_client: Option<kube::Client>,
    activation_manifest: Option<&Value>,
    consumed_failed: &[String],
    kept_orphans: activation::KeptOrphans,
) -> Result<()> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse pre-established connection or create a new one
    let client = match pre_client {
        Some(c) => c,
        None => fetch::make_client(global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?,
    };

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    // The gate, again, here. `load_old_from_cluster` checks it too, but
    // `--current-activation` reads the previous build from the local cache
    // and never contacts the cluster before this point. Without this check
    // that flag skips the gate, and with `--prune` the deploy would compute
    // the retired CRDs as orphans and delete them, which cascades away every
    // Activation record on the cluster.
    kix::legacy_domain::check_cluster(
        &discovery
            .iter()
            .filter(|(ar, _)| kix::manifest::lifecycle::is_record_kind(&ar.kind))
            .map(|(ar, _)| ar.group.as_str())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| miette!("{e}"))?;

    let discovery = Arc::new(tokio::sync::RwLock::new(discovery));

    let prune_policy = prune_policy_for(args);
    let on_error = match args.on_error {
        OnError::Stop => OnErrorPolicy::Stop,
        OnError::Continue => OnErrorPolicy::Continue,
    };

    let config = SchedulerConfig {
        timeout,
        on_error,
        prune: prune_policy,
        cancel: kix::cluster::cancel::CancelToken::new(),
        dry_run: args.dry_run,
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        rerun_failed: true,
    };
    // Ctrl-C and SIGTERM now have to reach the engine: the record exists from
    // the start of the run, so a process that just dies leaves it Deploying.
    config.cancel.cancel_on_interrupt();

    let kube_ops = Arc::new(KubeOps::new(
        client.clone(),
        discovery,
        KubeOpsConfig {
            cluster_name: cluster_name.to_string(),
            activation_name: activation_name.map(str::to_string),
            activation_identity_hash: activation_identity_hash.map(str::to_string),
            receipt: receipt.cloned(),
            force_conflicts: args.force_conflicts,
            dry_run: args.dry_run,
            // Create the record before the first wave, so a run that stops
            // part way leaves something that says what it was attempting
            // (kixpkgs#82). The plan applies this same manifest again as its
            // last node, which is then an unchanged no-op.
            activation_manifest: activation_manifest.cloned(),
            consumed_failed: consumed_failed.to_vec(),
            kept_orphans,
            mark_failed_on_abort: true,
        },
    ));
    let ops: Arc<dyn ClusterOps> = kube_ops.clone();

    // Select the TUI, NDJSON, plain line, or colored observer from CLI flags
    // and terminal capabilities.
    let interactive = output::is_interactive();
    let use_tui = args.tui && interactive;
    let tui_driver = if use_tui {
        let axis = if args.group_by_ns {
            super::graph_stream::GroupAxis::Namespace
        } else {
            super::graph_stream::GroupAxis::Package
        };
        match super::graph_stream::GraphStreamDriver::spawn(
            cluster_name.to_string(),
            config.cancel.clone(),
            args.fold_height,
            axis,
            super::graph_stream::GlyphStyle::detect(),
        ) {
            Ok(d) => Some(d),
            Err(e) => {
                eprintln!(
                    "{} {e}. Falling back to plain output",
                    output::yellow("warn: failed to start --tui renderer:"),
                );
                None
            }
        }
    } else {
        None
    };

    let observer: Arc<dyn DeployObserver> = if let Some(d) = &tui_driver {
        d.observer()
    } else {
        match args.log_format {
            crate::cli::LogFormat::Json => {
                Arc::new(super::deploy_log::JsonObserver::new(global.verbose > 0))
            }
            crate::cli::LogFormat::Line => Arc::new(super::deploy_log::LineObserver {
                verbose: global.verbose > 0,
            }),
            crate::cli::LogFormat::Pretty if !interactive => {
                Arc::new(super::deploy_log::LineObserver {
                    verbose: global.verbose > 0,
                })
            }
            crate::cli::LogFormat::Pretty => Arc::new(StreamCliObserver {
                quiet: global.quiet,
                verbose: global.verbose > 0,
            }),
        }
    };

    let result =
        scheduler::run_deploy(ops, plan, orphan_rids, old_manifests, &config, observer).await;

    // Tear down the TUI before the summary prints so it lands in normal
    // scrollback below the history lines.
    drop(tui_driver);

    if let Some(recorded) = kube_ops.recorded_orphans_kept_from() {
        baseline::sync_kept_roots(&args.cluster, &recorded);
    }

    match result {
        Ok(r) => {
            println!();
            print_summary(&r, args.dry_run);
            Ok(())
        }
        Err(e) => {
            if let Some(r) = e.partial() {
                print_summary(r, args.dry_run);
            }
            if matches!(
                e,
                kix::cluster::scheduler::DeployError::DiscoveryFailed { .. }
                    | kix::cluster::scheduler::DeployError::Internal { .. }
            ) {
                eprintln!("{} {e}", output::red("error:"));
            }
            std::process::exit(1);
        }
    }
}

/// Decide whether an offline-dry-run Apply node corresponds to a Create or
/// a Configured action, by checking whether its K8s identity
/// (`kind/namespace/name`) is present in the old activation.
fn classify_offline_apply(
    rid: &ResourceId,
    old_by_k8s_id: &std::collections::HashSet<String>,
) -> kix::cluster::apply::ApplyAction {
    use kix::cluster::apply::ApplyAction;
    let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
    if old_by_k8s_id.contains(&k8s_id) {
        ApplyAction::Configured
    } else {
        ApplyAction::Created
    }
}

/// Offline dry-run preview used without a cluster connection. Walks the plan, classifies each
/// Apply as Created/Configured by checking whether the K8s identity exists
/// in `old_manifests`, prints lines using the same `apply_symbol` glyphs the
/// real-deploy renderer uses, and prints the same summary line. No cluster
/// access. The classification does not run admission
/// webhooks or detect 409 conflicts; that's only possible with an online
/// SSA dry-run.
fn render_offline_dry_run(
    plan: &DeployPlan,
    old_manifests: &[Value],
    orphan_rids: &[ResourceId],
    global: &crate::cli::GlobalArgs,
) -> Result<()> {
    use kix::cluster::apply::ApplyAction;

    if global.quiet {
        return Ok(());
    }

    // Index old manifests by K8s identity so we can ask "did this exist?"
    // using the same identity shape as detect_changes.
    let old_by_k8s_id: std::collections::HashSet<String> = old_manifests
        .iter()
        .map(|m| {
            let rid = ResourceId::from_value(m);
            format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
        })
        .collect();

    println!();
    println!("{}", output::dim("Dry run. No changes will be applied."));

    let mut result = DeployResult::default();

    for node in &plan.nodes {
        let (rid, action) = match &node.action {
            ChangeAction::Apply(m) => {
                let rid = ResourceId::from_value(m);
                let action = classify_offline_apply(&rid, &old_by_k8s_id);
                (rid, action)
            }
            ChangeAction::Skip(rid) => (rid.clone(), ApplyAction::Unchanged),
            ChangeAction::Orphan(_) => continue,
        };

        let (symbol, lbl) = apply_symbol(&action);
        let pkg_tag = match &node.meta.package {
            Some(p) => format!("  {}", output::dim(p)),
            None => String::new(),
        };
        println!("  {} {} {}{}", symbol, rid, output::dim(lbl), pkg_tag);

        match action {
            ApplyAction::Created => result.created += 1,
            ApplyAction::Configured => result.configured += 1,
            ApplyAction::Unchanged => result.unchanged += 1,
            ApplyAction::Skipped => {}
        }
    }

    let (text, pruned) = render_offline_orphans(orphan_rids);
    print!("{text}");
    result.pruned = pruned;

    println!();
    print_summary(&result, true);
    Ok(())
}

/// The orphan lines of deploy's plan. `fate` says what this deploy does with
/// the orphans prune may delete; the kinds `lifecycle::never_pruned` protects
/// are listed apart and are never counted as orphans.
fn render_plan_orphans(orphan_rids: &[ResourceId], fate: &str) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    let (prunable, kept) = plan::split_never_pruned(orphan_rids.to_vec());
    if !prunable.is_empty() {
        let orphan_str = prunable.len().to_string();
        let _ = writeln!(out, "  {} orphaned ({fate})", output::red(&orphan_str));
        for rid in &prunable {
            let _ = writeln!(out, "    {} {}", output::red("-"), rid.display_id());
        }
    }
    out.push_str(&plan::render_never_pruned(&kept));
    out
}

/// The orphan lines of the offline dry run and the number it reports as
/// pruned, which leaves out the kinds `lifecycle::never_pruned` protects.
fn render_offline_orphans(orphan_rids: &[ResourceId]) -> (String, usize) {
    use std::fmt::Write;
    let mut out = String::new();
    let (prunable, kept) = plan::split_never_pruned(orphan_rids.to_vec());
    if !prunable.is_empty() {
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "{} {} resources would be orphaned:",
            output::yellow("Orphans:"),
            prunable.len(),
        );
        for rid in &prunable {
            let _ = writeln!(out, "  {} {}", output::red("-"), rid);
        }
    }
    out.push_str(&plan::render_never_pruned(&kept));
    (out, prunable.len())
}

/// The engine's prune section: the orphans prune deletes or reports, then
/// the ones no prune policy deletes.
fn render_prune_start(resources: &[ResourceId], kept: &[ResourceId], delete: bool) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    if !resources.is_empty() {
        let _ = writeln!(out);
        if delete {
            let _ = writeln!(
                out,
                "{} deleting {} orphaned resources...",
                output::bold("prune:"),
                resources.len(),
            );
        } else {
            let _ = writeln!(
                out,
                "{} {} orphaned resources kept (warn-only; {KEPT_ORPHANS_HINT})",
                output::bold("prune:"),
                resources.len(),
            );
        }
        for rid in resources {
            let _ = writeln!(out, "  {} {}", output::dim("-"), rid.display_id());
        }
    }
    if !kept.is_empty() {
        let _ = writeln!(out);
        let _ = writeln!(
            out,
            "{} {} orphaned resources are never deleted automatically",
            output::bold("prune:"),
            kept.len(),
        );
        for rid in kept {
            let _ = writeln!(out, "  {} {}", output::yellow("!"), rid.display_id());
        }
    }
    out
}

fn print_summary(r: &DeployResult, dry_run: bool) {
    let failed_str = r.failed.to_string();
    let mut cancelled_tail = if r.cancelled > 0 {
        format!(", {} cancelled", output::dim(&r.cancelled.to_string()),)
    } else {
        String::new()
    };
    if r.pruned > 0 {
        cancelled_tail.push_str(&format!(", {} pruned", output::red(&r.pruned.to_string())));
    }
    let prefix = if dry_run {
        "Dry run complete"
    } else {
        "Deploy complete"
    };
    println!(
        "{}: {} created, {} configured, {} unchanged, {} failed{}",
        prefix,
        output::green(&r.created.to_string()),
        output::yellow(&r.configured.to_string()),
        output::dim(&r.unchanged.to_string()),
        if r.failed > 0 {
            output::red(&failed_str)
        } else {
            output::dim(&failed_str)
        },
        cancelled_tail,
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

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // Build the new activation and load its store graph.
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
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &status)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("{e}"))?;
    // The same stale-pin check the direct path makes, and for the same
    // reason: a pin from before the domain move renders Kix's own CRDs under
    // the retired group. Before `stamp_annotations`, which would upgrade
    // them and make a stale pin indistinguishable from a current one. Two
    // deploy paths that answer differently about one build is worse than
    // either answer.
    kix::legacy_domain::check_build(
        &new_graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| miette!("{e}"))?;
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

    // Read the Activation name and identity hash.
    let activation_manifest = lifecycle::record_of(&new_manifests);
    let activation_name = activation_manifest
        .and_then(|m| {
            m.pointer("/metadata/name")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .ok_or_else(|| miette!("no Activation resource found in cluster manifests"))?;
    let activation_identity_hash = activation_manifest.and_then(|m| {
        m.pointer("/metadata/annotations")
            .and_then(|a| a.get(keys::IDENTITY_HASH))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });

    // Show the plan when requested.
    if !ctx.global.quiet {
        let old_graph = if args.current_activation {
            let (og, _) = load_old_from_cache(&args.cluster, &ctx.global);
            og
        } else {
            ctx.runtime
                .block_on(load_old_from_cluster(&args.cluster, &ctx.global))
                .ok()
                .and_then(|(og, _, _, _)| og)
        };

        let pkg_diff = match &old_graph {
            Some(old) => plan::diff_graphs(old, &new_graph),
            None => plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph),
        };

        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);
        plan::print_plan_summary(&pkg_diff);

        // Apply the same migration acknowledgement gate as direct mode.
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
            println!("{}", output::dim("Dry run. No changes applied."));
        }
        return Ok(());
    }

    // The receipt, same as the direct path. The operator has no source tree,
    // so provenance is computed here and written onto the Activation when it
    // is applied.
    let receipt =
        crate::commands::compliance::receipt::build_receipt(&new_graph, &ctx.global.flake);
    if receipt["source"]["dirty"] == Value::Bool(true) && !ctx.global.quiet {
        println!();
        println!(
            "{}",
            output::yellow(
                "The working tree has uncommitted changes, so the commit recorded for this deploy"
            )
        );
        println!(
            "{}",
            output::yellow("does not contain what is about to be applied. The record will say so.")
        );
        if let Some(rev) = receipt["source"]["revision"].as_str() {
            println!("  {}", output::dim(rev));
        }
    }

    // Confirm before submitting the Activation.
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

    // Apply the Activation and watch its progress.
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
            Some(&receipt),
        )
        .await?;

        if !global.quiet {
            println!(
                "  {} Activation CR applied. Waiting for operator...",
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
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    Ok(())
}

/// Render detected stateful migration pairs. The user must handle data movement before
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

    fn orphans() -> Vec<ResourceId> {
        vec![
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
        ]
    }

    /// Deploy's plan counts a Namespace orphan as kept, not as an orphan.
    #[test]
    fn plan_orphans_list_a_namespace_as_kept() {
        let text = render_plan_orphans(&orphans(), "will be deleted");
        assert!(text.contains("1 orphaned (will be deleted)"), "{text}");
        assert!(text.contains("- ConfigMap/old@app"), "{text}");
        assert!(!text.contains("- Namespace"), "{text}");
        assert!(text.contains("! Namespace/gone"), "{text}");
    }

    /// The offline dry run neither lists nor counts a Namespace orphan as
    /// pruned.
    #[test]
    fn offline_dry_run_does_not_count_a_namespace_as_pruned() {
        let (text, pruned) = render_offline_orphans(&orphans());
        assert_eq!(pruned, 1);
        assert!(text.contains("1 resources would be orphaned"), "{text}");
        assert!(!text.contains("- Namespace"), "{text}");
        assert!(text.contains("! Namespace/gone"), "{text}");
    }

    /// The engine's prune section under warn-only lists a Namespace orphan
    /// as kept, apart from the orphans it reports.
    #[test]
    fn prune_section_lists_kept_orphans_apart() {
        let all = orphans();
        let text = render_prune_start(&all[..1], &all[1..], false);
        assert!(
            text.contains("1 orphaned resources kept (warn-only"),
            "{text}"
        );
        assert!(text.contains("- ConfigMap/old@app"), "{text}");
        assert!(
            text.contains(
                "1 orphaned resources are never deleted automatically\n  ! Namespace/gone"
            ),
            "{text}"
        );
    }

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

    // Offline classification uses Kubernetes identity: an existing identity
    // is Configured and an absent identity is Created.

    use kix::cluster::apply::ApplyAction;
    use kix::manifest::types::ResourceId;

    fn old_by_id(rids: &[(&str, &str, &str)]) -> std::collections::HashSet<String> {
        rids.iter()
            .map(|(k, ns, n)| format!("{k}/{ns}/{n}"))
            .collect()
    }

    fn rid(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.to_string(),
            namespace: ns.to_string(),
            name: name.to_string(),
        }
    }

    #[test]
    fn classify_offline_apply_existing_is_configured() {
        let old = old_by_id(&[("Deployment", "lithus-system", "lithus-secret-operator")]);
        let action = classify_offline_apply(
            &rid("Deployment", "lithus-system", "lithus-secret-operator"),
            &old,
        );
        assert!(matches!(action, ApplyAction::Configured));
    }

    #[test]
    fn classify_offline_apply_new_is_created() {
        let old = old_by_id(&[("Service", "default", "other")]);
        let action = classify_offline_apply(&rid("Deployment", "default", "fresh"), &old);
        assert!(matches!(action, ApplyAction::Created));
    }

    #[test]
    fn classify_offline_apply_distinguishes_kind() {
        // The same name and namespace with a different kind is Created;
        // an in-cluster Service and Deployment named "foo" in "default" are
        // genuinely distinct resources.
        let old = old_by_id(&[("Service", "default", "foo")]);
        let action = classify_offline_apply(&rid("Deployment", "default", "foo"), &old);
        assert!(matches!(action, ApplyAction::Created));
    }

    #[test]
    fn classify_offline_apply_distinguishes_namespace() {
        let old = old_by_id(&[("Deployment", "ns-a", "foo")]);
        let action = classify_offline_apply(&rid("Deployment", "ns-b", "foo"), &old);
        assert!(matches!(action, ApplyAction::Created));
    }
}

#[cfg(test)]
mod prune_flag_tests {
    use super::*;
    use crate::cli::{Cli, Command};
    use clap::Parser;

    fn deploy_args(extra: &[&str]) -> DeployArgs {
        let mut argv = vec!["kix", "deploy", "x"];
        argv.extend_from_slice(extra);
        match Cli::try_parse_from(argv).expect("args parse").command {
            Command::Deploy(args) => args,
            _ => unreachable!(),
        }
    }

    #[test]
    fn prune_policy_follows_the_flags() {
        assert_eq!(prune_policy_for(&deploy_args(&[])), PrunePolicy::WarnOnly);
        assert!(!prune_flag_requested(&deploy_args(&[])));
        assert_eq!(
            prune_policy_for(&deploy_args(&["--prune"])),
            PrunePolicy::Delete
        );
        assert!(prune_flag_requested(&deploy_args(&["--prune"])));
        assert_eq!(
            prune_policy_for(&deploy_args(&["--prune", "--prune-mode", "default"])),
            PrunePolicy::Delete
        );
        assert_eq!(
            prune_policy_for(&deploy_args(&["--prune-mode", "default"])),
            PrunePolicy::WarnOnly
        );
        assert_eq!(
            prune_policy_for(&deploy_args(&["--prune", "--prune-mode", "no"])),
            PrunePolicy::Skip
        );
        assert!(!prune_flag_requested(&deploy_args(&[
            "--prune",
            "--prune-mode",
            "no"
        ])));
    }

    /// Reject the removed `eager` value instead of treating it as `--prune`.
    #[test]
    fn eager_is_no_longer_a_prune_mode() {
        let err = match Cli::try_parse_from(["kix", "deploy", "x", "--prune-mode", "eager"]) {
            Ok(_) => panic!("eager must not parse"),
            Err(e) => e,
        };
        assert_eq!(err.kind(), clap::error::ErrorKind::InvalidValue);
    }
}
