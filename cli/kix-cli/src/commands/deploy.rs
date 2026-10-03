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

use crate::cli::{DeployArgs, Detail, OnError, PlanArgs, PruneMode};
use crate::output;
use crate::plan;

use super::CommandContext;
use super::operator::Reconciled;
use kix::manifest::keys;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    // A dry run is the plan, made by the same code with the same flags.
    if args.dry_run {
        return super::plan::run(&args.plan, Detail::Plain, ctx);
    }
    if args.operator {
        return run_operator(args, ctx);
    }

    let Some(mut p) = prepare(&args.plan, ctx)? else {
        return Ok(());
    };

    // Detect stateful migration pairs and require --accept-migrations.
    if !p.migration_pairs.is_empty() {
        print_migration_pairs(&p.migration_pairs);
        if !args.plan.accept_migrations {
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

    // The plan the deploy shows is the one `kix plan` makes: when connected
    // and there is something to write, every write is first sent as a dry
    // run, so what the apiserver would refuse shows before anything is
    // applied.
    let total_apply = p
        .plan
        .nodes
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
        .count();
    let report = match &p.pre_client {
        Some(client) if total_apply > 0 || !p.orphan_rids.is_empty() => {
            let client = client.clone();
            Some(super::plan::dry_run(&p, &args.plan, client, ctx)?)
        }
        _ => None,
    };
    let doc = super::plan::document(&mut p, report.as_ref(), &args.plan, Detail::Plain);

    if !ctx.global.quiet {
        super::plan::print_text(&p, &doc, &args.plan, ctx.global.verbose > 0);
    }

    // Under `--on-error stop` the deploy would halt at the first refused
    // write, part way through. Stopping here applies nothing instead.
    if doc.stops() && matches!(args.on_error, OnError::Stop) {
        eprintln!();
        eprintln!(
            "{}",
            output::red(
                "Deployment stopped before applying anything: the dry run shows writes the cluster would refuse."
            )
        );
        eprintln!(
            "{}",
            output::yellow(
                "Fix them and deploy again, or rerun with --on-error continue to apply everything else."
            )
        );
        std::process::exit(1);
    }

    let Prepared {
        result_path,
        new_manifests,
        cluster,
        old_manifests,
        pre_client,
        active_hash,
        failed_baseline,
        kept_orphans,
        plan,
        orphan_rids,
        activation_name,
        activation_identity_hash,
        new_graph,
        ..
    } = p;

    // Imports are applied like any other resource (SSA); readiness polls the
    // cluster for the described resource via `wait_for_import_target`, which
    // is triggered when the import node becomes eligible under the DAG.

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
        let engine_decides = pre_client.is_none() && has_reruns;
        if failed_reruns.is_empty() && !engine_decides {
            // A folded-in record still has to be superseded, even when its
            // closure turned out to differ from the plan only in things
            // nothing prunes (a Namespace, the record itself). The engine
            // never runs on this path, and `finalize_deploy` is where records
            // are normally consumed, so do it here or report the same failed
            // deploy on every deploy from now on.
            if let Some(client) = &pre_client {
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

    // Build the deployment receipt before confirmation so dirty source state
    // is visible in the prompt.
    let receipt =
        crate::commands::compliance::receipt::build_receipt(&new_graph, &ctx.global.flake);

    if receipt["source"]["dirty"] == Value::Bool(true) && !ctx.global.quiet {
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

    let activation_manifest = lifecycle::record_of(&new_manifests);
    let global = ctx.global.clone();
    let end = ctx.runtime.block_on(run_deploy_async(
        args,
        &global,
        plan,
        &orphan_rids,
        &old_manifests,
        &cluster,
        activation_name.as_deref(),
        activation_identity_hash.as_deref(),
        Some(&receipt),
        pre_client,
        activation_manifest,
        &failed_baseline.consumed,
        kept_orphans,
        if args.plan.current_activation {
            active_hash.as_deref()
        } else {
            None
        },
    ))?;

    // Save activation path for next deploy's diff and for soft `kix gc`.
    // Only when this build's record became current. A cache that names a
    // build the cluster does not run (a run that left nodes unattempted)
    // makes soft gc treat the current closure as garbage, and makes the next
    // `--current-activation` plan skip the nodes this run never applied.
    if end.current
        && let Err(e) = kix::eval::store::save_activation_path(&cluster, &result_path)
    {
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    if !end.succeeded {
        std::process::exit(1);
    }
    Ok(())
}

/// Everything a deploy decides before it writes: the two builds compared,
/// the actions, and the engine plan. `kix plan` and `kix deploy` share it,
/// so a plan made with the deploy's flags is the deploy's plan.
pub(crate) struct Prepared {
    pub result_path: PathBuf,
    pub new_graph: StoreGraph,
    pub new_manifests: Vec<Value>,
    /// The name the build gives the cluster, which keys its records and the
    /// local cache.
    pub cluster: String,
    /// The deployed build, when its store path loaded. `None` when there is
    /// no previous deploy or its manifests were reconstructed from the live
    /// objects.
    pub old_graph: Option<StoreGraph>,
    /// The Active record's closure.
    pub active_manifests: Vec<Value>,
    /// `active_manifests` with the failed and kept closures merged in.
    pub old_manifests: Vec<Value>,
    /// `None` under `--current-activation`, which plans without connecting.
    pub pre_client: Option<kube::Client>,
    pub active_hash: Option<String>,
    /// The Active record the plan compares against.
    pub active: Option<activation::ActiveActivation>,
    pub failed_baseline: baseline::FailedBaseline,
    pub kept_orphans: activation::KeptOrphans,
    /// Against the Active closure only.
    pub migration_pairs: Vec<MigrationPair>,
    pub plan: DeployPlan,
    /// Orphans this cluster's prune may delete; ones another Kix cluster
    /// still deploys are in `shared_orphans` instead.
    pub orphan_rids: Vec<ResourceId>,
    pub shared_orphans: Vec<fetch::SharedOrphan>,
    pub activation_name: Option<String>,
    pub activation_identity_hash: Option<String>,
    /// The package-grouped comparison of the old side with the new build.
    pub pkg_diff: plan::PackageDiff,
}

/// Build, load the old side, and compute the actions and the engine plan.
/// `None` when the build has nothing to deploy. Progress lines go through
/// [`crate::say!`], so `kix plan -o json` keeps them off stdout.
pub(crate) fn prepare(args: &PlanArgs, ctx: &mut CommandContext) -> Result<Option<Prepared>> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // Build the new activation and load its store graph.
    if !ctx.global.quiet {
        crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
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
    // Records and the local cache are keyed by the name the build gives the
    // cluster, which need not match the flake attribute in `args.cluster`.
    let cluster = new_graph.cluster_name.clone();

    // Collect stamped manifests from the new graph.
    let new_manifests: Vec<Value> = new_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    let manifest_count = new_manifests.len();
    if !ctx.global.quiet {
        crate::say!(
            "Cluster {}: {} manifests",
            output::bold(&new_graph.cluster_name),
            manifest_count,
        );
    }

    if manifest_count == 0 {
        if !ctx.global.quiet {
            crate::say!("Nothing to deploy.");
        }
        return Ok(None);
    }

    // Resolve the old activation from the cluster or local cache.
    let (old_graph, active_manifests, pre_client, active) = if args.current_activation {
        // Local cache mode does not connect before confirmation.
        let (og, om) = load_old_from_cache(&cluster, &ctx.global);
        let active = cached_as_active(&cluster, &om);
        (og, om, None, active)
    } else {
        // Fetch the active Activation from the cluster.
        ctx.runtime
            .block_on(load_old_from_cluster(&cluster, &ctx.global))?
    };
    let active_hash = active.as_ref().and_then(|a| a.identity_hash.clone());

    // Builds whose orphans an earlier warn-only deploy kept. The Active
    // closure no longer declares those objects, so without these the plan
    // cannot see them.
    let kept_baseline = match &active {
        Some(active) => baseline::load_kept(active, &cluster, ctx.global.quiet),
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
            if let Some(record) = baseline::deploy_in_flight(client, ar, &cluster).await {
                baseline::report_in_flight(&record, ctx.global.quiet);
                return Ok(baseline::FailedBaseline::default());
            }
            Ok::<_, miette::Report>(
                baseline::load_failed(client, ar, &cluster, ctx.global.quiet).await,
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

    // Stateful migration pairs, against the Active closure only. A
    // half-applied closure is not a previous intended state, so pairing
    // against it would invent migrations nobody declared.
    let migration_pairs = detect_migration_pairs(&new_manifests, &active_manifests);

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
    // `--current-activation` has no client yet; `run_deploy_async` checks
    // once it connects.
    let (orphan_rids, shared_orphans) = match &pre_client {
        Some(client) => ctx.runtime.block_on(super::shared_orphans::keep_shared(
            client,
            &new_graph.cluster_name,
            orphan_rids,
        ))?,
        None => (orphan_rids, Vec::new()),
    };

    // Build the DAG and streaming plan.
    let resource_graph = ResourceGraph::from_manifests(&new_manifests).into_diagnostic()?;

    if resource_graph.graph.node_count() == 0 {
        if !ctx.global.quiet {
            crate::say!("No resources to deploy.");
        }
        return Ok(None);
    }

    let plan =
        DeployPlan::from_graph_and_changes(&resource_graph, &all_actions).into_diagnostic()?;

    // Read the Activation name and identity hash from the new manifests.
    let activation_manifest = lifecycle::record_of(&new_manifests);
    let activation_name = activation_manifest.and_then(|m| {
        m.pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    let activation_identity_hash =
        activation_manifest.and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(|s| s.to_string()));

    let mut pkg_diff = if let Some(old) = &old_graph {
        plan::diff_graphs(old, &new_graph)
    } else if !old_manifests.is_empty() {
        // Synthesize a package view from the old manifests when the old
        // store graph is unavailable, so untouched packages show as
        // unchanged instead of everything "added".
        let synthetic = StoreGraph::synthesize(&old_manifests, &new_graph);
        plan::diff_graphs(&synthetic, &new_graph)
    } else {
        // A first deploy adds every package.
        plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph)
    };
    pkg_diff.keep_shared(&shared_orphans);

    Ok(Some(Prepared {
        result_path,
        new_graph,
        new_manifests,
        cluster,
        old_graph,
        active_manifests,
        old_manifests,
        pre_client,
        active_hash,
        active,
        failed_baseline,
        kept_orphans,
        migration_pairs,
        plan,
        orphan_rids,
        shared_orphans,
        activation_name,
        activation_identity_hash,
        pkg_diff,
    }))
}

/// How an engine run ends `kix deploy` and `kix rollback`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RunEnd {
    /// The command exits zero. `run_deploy` returns `Ok` with failures in
    /// the counts under `--on-error continue` and when a prune delete fails,
    /// so `Ok` alone does not mean every operation succeeded.
    pub succeeded: bool,
    /// The run's record became the current one. An `Err` or an `Ok` with
    /// cancelled nodes means the engine marked the record Failed and the
    /// previous activation stays current.
    pub current: bool,
}

impl RunEnd {
    pub(crate) fn of(result: &Result<DeployResult, scheduler::DeployError>) -> Self {
        match result {
            Ok(r) => RunEnd {
                succeeded: r.failed == 0 && r.cancelled == 0,
                current: r.cancelled == 0,
            },
            Err(_) => RunEnd {
                succeeded: false,
                current: false,
            },
        }
    }
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
                crate::say!("Loading previous activation from cache...");
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
                crate::say!("No previous activation. First deploy.");
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

/// Refuse a `--current-activation` plan whose cached build is not the Active
/// build of `cluster` in the context this run connected to.
///
/// The activation cache is keyed by cluster name alone, so another context
/// that deploys a cluster of the same name can have written it. A plan made
/// against that build computes another environment's objects as orphans,
/// and the prune deletes by name. The plan has already been confirmed, so
/// this refuses rather than planning again from the cluster's record.
async fn check_cached_baseline(
    client: &kube::Client,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
    cluster: &str,
    cached_hash: &str,
) -> Result<()> {
    let active = match activation::find_activation_ar(discovery).map_err(|e| miette!("{e}"))? {
        Some((ar, _)) => activation::find_active(client, ar, cluster)
            .await
            .map_err(|e| miette!("failed to find the active activation: {e}"))?,
        None => None,
    };
    let active_hash = active.as_ref().and_then(|a| a.identity_hash.as_deref());
    if active_hash == Some(cached_hash) {
        return Ok(());
    }
    let short = |h: &str| h[..8.min(h.len())].to_string();
    let found = match active_hash {
        Some(h) => format!("its Active build is {}...", short(h)),
        None => "it has no Active record".to_string(),
    };
    Err(miette!(
        "the cached build {}... that --current-activation planned against is not the Active build of cluster '{cluster}' in this context: {found}. \
         Nothing was applied. Rerun without --current-activation to plan against this context's record.",
        short(cached_hash),
    ))
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
        crate::say!("Connecting to cluster...");
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
                crate::say!(
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
                                crate::say!(
                                    "  {} previous build at {} would not load ({e}). Reconstructing previous state from cluster",
                                    output::yellow("!"),
                                    result_dir.display(),
                                );
                            }
                            let old_manifests = reconstruct_old_from_live(
                                &client,
                                &discovery,
                                cluster,
                                &act,
                                global.quiet,
                            )
                            .await?;
                            Ok((None, old_manifests, Some(client), Some(act)))
                        }
                    }
                }
                None => {
                    if !global.quiet {
                        crate::say!(
                            "  {} store path for activation not found locally. Reconstructing previous state from cluster",
                            output::yellow("!"),
                        );
                    }
                    let old_manifests =
                        reconstruct_old_from_live(&client, &discovery, cluster, &act, global.quiet)
                            .await?;
                    Ok((None, old_manifests, Some(client), Some(act)))
                }
            }
        }
        _ => {
            if !global.quiet {
                crate::say!("No previous activation on cluster. First deploy.");
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
pub(crate) fn prune_policy_for(args: &PlanArgs) -> PrunePolicy {
    match args.prune_mode.unwrap_or(PruneMode::Default) {
        PruneMode::No => PrunePolicy::Skip,
        PruneMode::Default if !args.prune => PrunePolicy::WarnOnly,
        PruneMode::Default => PrunePolicy::Delete,
    }
}

/// Will this run delete orphans? Used to word the plan honestly.
pub(crate) fn prune_flag_requested(args: &PlanArgs) -> bool {
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
/// Only objects naming the Active record, a Failed record of this cluster,
/// or a build the Active record lists under `status.orphansKeptFrom`: the
/// closures the store-graph path would read. Objects of other Kix clusters
/// on the same Kubernetes cluster name none of these, so they never become
/// orphans. This cluster's objects that name only older builds are left out
/// too, and unless `quiet` a line says how many and that `kix gc --hard`
/// finds them.
///
/// A failed sweep is an error, not an empty previous state. Planning
/// against an empty old set would show every resource as "added" and,
/// with `--prune`, would compute no orphans at all: a plan that looks
/// plausible and is wrong.
async fn reconstruct_old_from_live(
    client: &kube::Client,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
    cluster: &str,
    active: &activation::ActiveActivation,
    quiet: bool,
) -> Result<Vec<Value>> {
    let refuse = |e: &dyn std::fmt::Display| {
        miette!(
            "cannot reconstruct the previous state from the cluster: {e}. \
             Refusing to plan from a partial view; retry when the apiserver is healthy."
        )
    };
    let mut hashes: std::collections::HashSet<String> =
        active.identity_hash.iter().cloned().collect();
    hashes.extend(
        active
            .orphans_kept_from
            .iter()
            .map(|s| s.identity_hash.clone()),
    );
    if let Some((ar, _)) = activation::find_activation_ar(discovery).map_err(|e| miette!("{e}"))? {
        let failed = activation::find_failed(client, ar, cluster)
            .await
            .map_err(|e| refuse(&e))?;
        hashes.extend(failed.into_iter().filter_map(|f| f.identity_hash));
    }
    let scope = fetch::SweepScope::Records {
        cluster,
        hashes: &hashes,
    };
    let sweep = fetch::sweep_managed(client, discovery, scope)
        .await
        .map_err(|e| refuse(&e))?;
    if sweep.other_builds > 0 && !quiet {
        crate::say!(
            "  {} {} objects of this Kix cluster name only older builds, so this plan leaves them; `kix gc --hard` finds them",
            output::dim("note:"),
            sweep.other_builds,
        );
    }
    Ok(fetch::kix_owned_manifests(
        sweep
            .managed
            .into_iter()
            .filter(|obj| lifecycle::lifecycle_of_live(obj).prunable()),
    ))
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
            DeployEvent::PruneKept { reason, .. } => {
                println!("  {} prune: {reason}", output::yellow("="));
            }
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
                Some(NodeDetail::PendingRestart { stale, message }) => {
                    println!(
                        "  {} {} {} {}",
                        output::yellow("✔"),
                        label,
                        output::yellow(&format!(
                            "ready, {stale} pods pending manual restart (OnDelete):"
                        )),
                        output::dim(message),
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
    cached_baseline: Option<&str>,
) -> Result<RunEnd> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse pre-established connection or create a new one. A plan made
    // without one has not checked its orphans against other Kix clusters.
    let (client, orphan_rids) = match pre_client {
        Some(c) => (c, orphan_rids.to_vec()),
        None => {
            let client = fetch::make_client(global.context.as_deref())
                .await
                .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
            let (prune, shared) =
                super::shared_orphans::keep_shared(&client, cluster_name, orphan_rids.to_vec())
                    .await?;
            if !global.quiet {
                super::shared_orphans::print(&shared);
            }
            (client, prune)
        }
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

    if let Some(hash) = cached_baseline {
        check_cached_baseline(&client, &discovery, cluster_name, hash).await?;
    }

    // The engine would refuse each of these on its own, part way through
    // the run; refusing here applies nothing.
    let namespaceless = kix::cluster::apply::namespaceless(
        &discovery,
        plan.nodes.iter().filter_map(|n| match &n.id {
            NodeId::Resource(rid) => Some(rid),
            _ => None,
        }),
    );
    if !namespaceless.is_empty() {
        return Err(miette!(
            "{}",
            namespaceless
                .iter()
                .map(|rid| kix::cluster::apply::ApplyError::NoNamespace {
                    resource: rid.display_id()
                }
                .to_string())
                .collect::<Vec<_>>()
                .join("\n")
        ));
    }

    let discovery = Arc::new(tokio::sync::RwLock::new(discovery));

    let prune_policy = prune_policy_for(&args.plan);
    let on_error = match args.on_error {
        OnError::Stop => OnErrorPolicy::Stop,
        OnError::Continue => OnErrorPolicy::Continue,
    };

    let config = SchedulerConfig {
        timeout,
        on_error,
        prune: prune_policy,
        cancel: kix::cluster::cancel::CancelToken::new(),
        dry_run: false,
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
            force_conflicts: args.plan.force_conflicts,
            dry_run: false,
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

    // The JSON log ends with a summary object in place of the summary line,
    // so its stdout stays NDJSON.
    let json_log = (tui_driver.is_none() && args.log_format == crate::cli::LogFormat::Json)
        .then(|| Arc::new(super::deploy_log::JsonObserver::new(global.verbose > 0)));
    let observer: Arc<dyn DeployObserver> = match (&tui_driver, &json_log) {
        (Some(d), _) => d.observer(),
        (None, Some(json)) => json.clone(),
        (None, None) if args.log_format == crate::cli::LogFormat::Pretty && interactive => {
            Arc::new(StreamCliObserver {
                quiet: global.quiet,
                verbose: global.verbose > 0,
            })
        }
        (None, None) => Arc::new(super::deploy_log::LineObserver {
            verbose: global.verbose > 0,
        }),
    };

    let result =
        scheduler::run_deploy(ops, plan, &orphan_rids, old_manifests, &config, observer).await;

    // Tear down the TUI before the summary prints so it lands in normal
    // scrollback below the history lines.
    drop(tui_driver);

    if let Some(recorded) = kube_ops.recorded_orphans_kept_from() {
        baseline::sync_kept_roots(cluster_name, &recorded);
    }

    let end = RunEnd::of(&result);
    let counts = match &result {
        Ok(r) => Some(r),
        Err(e) => e.partial(),
    };
    match (&json_log, counts) {
        (Some(json), counts) => json.summary(counts, false, end.succeeded),
        (None, Some(r)) => {
            println!();
            println!("{}", summary_line(r, false, end.succeeded));
        }
        (None, None) => {}
    }
    // The event stream already reports failed nodes and cancellation.
    if let Err(e) = &result
        && !matches!(
            e,
            scheduler::DeployError::NodesFailed { .. } | scheduler::DeployError::Cancelled { .. }
        )
    {
        eprintln!("{} {e}", output::red("error:"));
    }
    Ok(end)
}

/// The orphan lines of deploy's plan. `fate` says what this deploy does with
/// the orphans prune may delete; the kinds `lifecycle::never_pruned` protects
/// are listed apart and are never counted as orphans.
pub(crate) fn render_plan_orphans(orphan_rids: &[ResourceId], fate: &str) -> String {
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

/// The last line of a deploy. Its first words say how the run ended:
/// `complete` when nothing failed, `failed` when a resource operation did,
/// and `stopped` when the run ended early with no failure, as on Ctrl-C.
fn summary_line(r: &DeployResult, dry_run: bool, succeeded: bool) -> String {
    let failed_str = r.failed.to_string();
    let mut cancelled_tail = if r.cancelled > 0 {
        format!(", {} cancelled", output::dim(&r.cancelled.to_string()),)
    } else {
        String::new()
    };
    if r.pruned > 0 {
        cancelled_tail.push_str(&format!(", {} pruned", output::red(&r.pruned.to_string())));
    }
    let run = if dry_run { "Dry run" } else { "Deploy" };
    let ending = if succeeded {
        "complete"
    } else if r.failed > 0 {
        "failed"
    } else {
        "stopped"
    };
    format!(
        "{run} {ending}: {} created, {} configured, {} unchanged, {} failed{}",
        output::green(&r.created.to_string()),
        output::yellow(&r.configured.to_string()),
        output::dim(&r.unchanged.to_string()),
        if r.failed > 0 {
            output::red(&failed_str)
        } else {
            output::dim(&failed_str)
        },
        cancelled_tail,
    )
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
            output::bold(&args.plan.cluster)
        );
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.plan.cluster, &overrides, &status)
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
    // Keyed by the build's cluster name, as in the direct path.
    let cluster = new_graph.cluster_name.clone();

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
        let old_graph = if args.plan.current_activation {
            let (og, _) = load_old_from_cache(&cluster, &ctx.global);
            og
        } else {
            ctx.runtime
                .block_on(load_old_from_cluster(&cluster, &ctx.global))
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
            if !args.plan.accept_migrations {
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

    let reconciled = ctx.runtime.block_on(async {
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
            &cluster,
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

        let reconciled = super::operator::watch_activation_progress(
            &client,
            &ar,
            &activation_name,
            &source_path,
            global.quiet,
        )
        .await?;

        let (ending, phase) = match reconciled {
            Reconciled::Active => (output::green("complete"), output::green("Active")),
            Reconciled::Degraded => (output::red("failed"), output::yellow("Degraded")),
        };
        println!();
        println!(
            "Deploy via operator {ending}: Activation '{}' is {phase}",
            output::bold(&activation_name),
        );

        Ok::<_, miette::Report>(reconciled)
    })?;

    // Save activation path for next deploy's diff. A Degraded record is
    // current too.
    if let Err(e) = kix::eval::store::save_activation_path(&cluster, &result_path) {
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    if reconciled == Reconciled::Degraded {
        std::process::exit(1);
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
}

#[cfg(test)]
mod prune_flag_tests {
    use super::*;
    use crate::cli::{Cli, Command};
    use clap::Parser;

    fn deploy_args(extra: &[&str]) -> PlanArgs {
        let mut argv = vec!["kix", "deploy", "x"];
        argv.extend_from_slice(extra);
        match Cli::try_parse_from(argv).expect("args parse").command {
            Command::Deploy(args) => args.plan,
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

#[cfg(test)]
mod rebuild_from_live_tests {
    use super::*;
    use kix::cluster::activation::{
        ActiveActivation, KeptOrphanSource, PHASE_ACTIVE, PHASE_FAILED, PHASE_SUPERSEDED,
    };
    use kix::cluster::fake_api::FakeApi;
    use serde_json::json;

    fn record(cluster: &str, hash: &str, phase: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): cluster,
                },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": phase },
        })
    }

    fn cm(name: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": name,
                "namespace": "app",
                "labels": { "app.kubernetes.io/managed-by": "kix" },
                "annotations": {
                    (keys::IDENTITY_HASH): format!("h-{name}"),
                    (keys::ACTIVATIONS): activations,
                },
            },
        })
    }

    /// A cached build of another context's cluster `a` (hash `p9`) is
    /// refused against this context's Active record (`a2`), and so is any
    /// cached build when the context has no Active record for the cluster.
    #[tokio::test]
    async fn a_cached_build_must_be_the_contexts_active_build() {
        let api = FakeApi::new([record("a", "a2", PHASE_ACTIVE)]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        assert!(
            check_cached_baseline(&client, &discovery, "a", "a2")
                .await
                .is_ok()
        );
        let err = check_cached_baseline(&client, &discovery, "a", "p9")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("Active build is a2"), "{err}");
        let err = check_cached_baseline(&client, &discovery, "b", "p9")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("no Active record"), "{err}");
    }

    /// The previous state of `a`, rebuilt from live objects, is the closures
    /// of its Active record, its Failed record and the build its Active
    /// record kept orphans from. Leftovers of a Superseded build, and every
    /// object only `b` deploys, are not in it.
    #[tokio::test]
    async fn the_previous_state_is_the_active_failed_and_kept_closures() {
        let api = FakeApi::new([
            record("a", "a1", PHASE_SUPERSEDED),
            record("a", "a2", PHASE_ACTIVE),
            record("a", "af", PHASE_FAILED),
            record("b", "b1", PHASE_ACTIVE),
            cm("current", "a2"),
            cm("failed-left", "af"),
            cm("kept-left", "ak"),
            cm("superseded-left", "a1"),
            cm("b-web", "b1"),
            cm("shared", "a2,b1"),
        ]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let active = ActiveActivation {
            name: "rec-a2".into(),
            identity_hash: Some("a2".into()),
            built_via: None,
            orphans_kept_from: vec![KeptOrphanSource {
                activation: "rec-ak".into(),
                identity_hash: "ak".into(),
                built_via: None,
            }],
        };
        let old = reconstruct_old_from_live(&client, &discovery, "a", &active, true)
            .await
            .unwrap();
        let mut names: Vec<&str> = old
            .iter()
            .filter_map(|m| m.pointer("/metadata/name")?.as_str())
            .collect();
        names.sort();
        assert_eq!(names, vec!["current", "failed-left", "kept-left", "shared"]);
    }
}

#[cfg(test)]
mod run_end_tests {
    use super::*;
    use kix::cluster::ops::scripted::{ApplyFailure, Behaviour, NodeScript, ScriptedOps};
    use kix::cluster::stream::NullObserver;
    use serde_json::json;

    fn deployment(name: &str, deps: &[&str]) -> Value {
        let mut annotations = serde_json::Map::new();
        annotations.insert(keys::IDENTITY_HASH.into(), json!(format!("h_{name}")));
        if !deps.is_empty() {
            let deps: Vec<String> = deps.iter().map(|d| format!("h_{d}")).collect();
            annotations.insert(keys::DEPENDS_ON.into(), json!(deps.join(",")));
        }
        json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": { "name": name, "namespace": "default", "annotations": annotations },
        })
    }

    fn deployment_id(name: &str) -> ResourceId {
        ResourceId {
            kind: "Deployment".into(),
            namespace: "default".into(),
            name: name.into(),
        }
    }

    fn apply_all(manifests: &[Value]) -> DeployPlan {
        let graph = ResourceGraph::from_manifests(manifests).unwrap();
        let changes: Vec<ChangeAction> =
            manifests.iter().cloned().map(ChangeAction::Apply).collect();
        DeployPlan::from_graph_and_changes(&graph, &changes).unwrap()
    }

    fn config(on_error: OnErrorPolicy, prune: PrunePolicy) -> SchedulerConfig {
        SchedulerConfig {
            timeout: Duration::from_secs(300),
            on_error,
            prune,
            cancel: kix::cluster::cancel::CancelToken::new(),
            dry_run: false,
            concurrency: scheduler::CONCURRENCY,
            stall: StallPolicy::off(),
            rerun_failed: true,
        }
    }

    /// `a` fails to apply; every other node applies.
    fn ops_failing_a() -> Arc<ScriptedOps> {
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            deployment_id("a"),
            NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
        );
        ops
    }

    async fn run(
        ops: &Arc<ScriptedOps>,
        manifests: &[Value],
        orphans: &[ResourceId],
        old: &[Value],
        config: &SchedulerConfig,
    ) -> std::result::Result<DeployResult, scheduler::DeployError> {
        let ops: Arc<dyn ClusterOps> = ops.clone();
        scheduler::run_deploy(
            ops,
            apply_all(manifests),
            orphans,
            old,
            config,
            Arc::new(NullObserver),
        )
        .await
    }

    /// Under `--on-error continue`, a failed node whose siblings all
    /// applied finalizes the record (Degraded), so the build is current,
    /// and the command exits non-zero.
    #[tokio::test]
    async fn continue_with_a_failed_node_exits_non_zero() {
        let manifests = [deployment("a", &[]), deployment("b", &[])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&ops_failing_a(), &manifests, &[], &[], &cfg).await;
        assert_eq!(result.as_ref().unwrap().failed, 1);
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: true,
            }
        );
    }

    /// Under `--on-error continue`, a failed node cancels its dependent.
    /// The engine marks the record Failed, so the build is not current
    /// and the command exits non-zero.
    #[tokio::test]
    async fn continue_with_a_cancelled_dependent_is_not_current() {
        let manifests = [deployment("a", &[]), deployment("b", &["a"])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&ops_failing_a(), &manifests, &[], &[], &cfg).await;
        let counts = result.as_ref().unwrap();
        assert_eq!((counts.failed, counts.cancelled), (1, 1));
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: false,
            }
        );
    }

    /// Under the default `--on-error stop`, every node applying but a
    /// prune delete failing still exits non-zero.
    #[tokio::test]
    async fn a_failed_prune_delete_exits_non_zero() {
        let ops = Arc::new(ScriptedOps::new());
        ops.delete_behaviour(Behaviour::Now(Err("forbidden".into())));
        let cfg = config(OnErrorPolicy::Stop, PrunePolicy::Delete);
        let result = run(
            &ops,
            &[deployment("a", &[])],
            &[deployment_id("old")],
            &[deployment("old", &[])],
            &cfg,
        )
        .await;
        assert_eq!(result.as_ref().unwrap().failed, 1);
        assert!(!RunEnd::of(&result).succeeded);
    }

    /// Every node applies but the record will not finalize: the build is
    /// not current and the command exits non-zero.
    #[tokio::test]
    async fn a_failed_finalize_is_neither_succeeded_nor_current() {
        let ops = Arc::new(ScriptedOps::new());
        ops.finalize_behaviour(Behaviour::Now(Err("conflict".into())));
        let cfg = config(OnErrorPolicy::Stop, PrunePolicy::WarnOnly);
        let result = run(&ops, &[deployment("a", &[])], &[], &[], &cfg).await;
        assert!(
            matches!(result, Err(scheduler::DeployError::FinalizeFailed { .. })),
            "{result:?}"
        );
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: false,
            }
        );
    }

    /// A run that left a node unattempted and could not mark its record
    /// Failed is still neither succeeded nor current.
    #[tokio::test]
    async fn a_failed_abort_is_neither_succeeded_nor_current() {
        let ops = ops_failing_a();
        ops.abort_behaviour(Behaviour::Now(Err("conflict".into())));
        let manifests = [deployment("a", &[]), deployment("b", &["a"])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&ops, &manifests, &[], &[], &cfg).await;
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: false,
                current: false,
            }
        );
    }

    #[tokio::test]
    async fn a_clean_run_succeeds() {
        let manifests = [deployment("a", &[]), deployment("b", &["a"])];
        let cfg = config(OnErrorPolicy::Continue, PrunePolicy::WarnOnly);
        let result = run(&Arc::new(ScriptedOps::new()), &manifests, &[], &[], &cfg).await;
        assert_eq!(
            RunEnd::of(&result),
            RunEnd {
                succeeded: true,
                current: true,
            }
        );
    }

    #[test]
    fn the_summary_line_names_a_failed_run() {
        let counts = DeployResult {
            created: 2,
            unchanged: 348,
            failed: 2,
            cancelled: 3,
            ..DeployResult::default()
        };
        let line = summary_line(&counts, false, false);
        assert!(line.starts_with("Deploy failed: "), "{line}");
        assert!(line.contains("2 failed"), "{line}");
        let stopped = summary_line(&DeployResult::default(), false, false);
        assert!(stopped.starts_with("Deploy stopped: "), "{stopped}");
        let ok = summary_line(&DeployResult::default(), true, true);
        assert!(ok.starts_with("Dry run complete: "), "{ok}");
    }
}
