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
    let saved = match &args.saved_plan {
        Some(path) => Some(load_saved_plan(path, &args.plan)?),
        None => None,
    };
    let plan_args = match &saved {
        Some(s) => &s.args,
        None => &args.plan,
    };
    // A dry run is the plan, made by the same code with the same flags.
    if args.dry_run {
        return match &saved {
            Some(s) => check_saved_plan(s, ctx),
            None => super::plan::run(&args.plan, Detail::Plain, ctx),
        };
    }
    if args.operator {
        return run_operator(args, ctx);
    }

    let Some(mut p) = prepare(plan_args, ctx)? else {
        return Ok(());
    };
    // A deploy decrypts a bundle's SOPS files for real, after review.
    if let Some(b) = &mut p.bundle {
        p.sops = b.sops(false)?;
    }
    annotate_record(&mut p, &args.record_annotations);

    // Detect stateful migration pairs and require --accept-migrations.
    if !p.migration_pairs.is_empty() {
        print_migration_pairs(&p.migration_pairs);
        if !plan_args.accept_migrations {
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
            Some(super::plan::dry_run(&p, plan_args, client, ctx)?)
        }
        _ => None,
    };
    let doc = super::plan::document(&mut p, report.as_ref(), plan_args, Detail::Plain);

    if !ctx.global.quiet {
        super::plan::print_text(&p, &doc, plan_args, ctx.global.verbose > 0);
    }

    // A reviewed plan that no longer matches applies nothing.
    if let Some(s) = &saved {
        let mut comparison = plan::saved::compare(&s.reviewed, &doc);
        comparison.plan_sha256 = Some(s.sha256.clone());
        eprintln!();
        eprint!(
            "{}",
            plan::saved::render_text(&comparison, &s.reviewed, &s.path)
        );
        if !comparison.matches {
            std::process::exit(plan::saved::EXIT_STALE);
        }
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
        bundle,
        sops,
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
    let receipt = match &bundle {
        Some(b) => crate::commands::compliance::receipt::from_bundle(&new_graph, b),
        None => crate::commands::compliance::receipt::build_receipt(&new_graph, &ctx.global.flake),
    };

    if !ctx.global.quiet {
        print_dirty_source_warning(&receipt, bundle.is_some());
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
        plan_args,
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
        if plan_args.current_activation {
            active_hash.as_deref()
        } else {
            None
        },
        sops,
    ))?;

    // Save activation path for next deploy's diff and for soft `kix gc`.
    // Only when this build's record became current. A cache that names a
    // build the cluster does not run (a run that left nodes unattempted)
    // makes soft gc treat the current closure as garbage, and makes the next
    // `--current-activation` plan skip the nodes this run never applied.
    if end.current
        && bundle.is_none()
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

/// A reviewed plan read for `kix deploy --plan`, with the planning flags the
/// deploy uses.
pub(crate) struct SavedPlan {
    pub path: String,
    /// [`plan::saved::digest`] of the file as read.
    pub sha256: String,
    pub reviewed: plan::document::Plan,
    pub args: PlanArgs,
}

/// Read a saved plan and take its planning flags. Fails before any build
/// when the plan cannot be used or the command line contradicts its flags.
fn load_saved_plan(path: &std::path::Path, given: &PlanArgs) -> Result<SavedPlan> {
    let bytes =
        std::fs::read(path).map_err(|e| miette!("cannot read the plan {}: {e}", path.display()))?;
    let reviewed: plan::document::Plan = serde_json::from_slice(&bytes)
        .map_err(|e| miette!("{} is not a Kix plan document: {e}", path.display()))?;
    if let Some(why) = plan::saved::unusable(&reviewed) {
        return Err(miette!("cannot deploy from {}: {why}", path.display()));
    }
    let flags = plan::saved::flags_for(&reviewed, &super::plan::flags_of(given))
        .map_err(|e| miette!("cannot deploy from {}: {e}", path.display()))?;
    let mut args = given.clone();
    args.prune = flags.prune;
    args.prune_mode = flags.prune_mode.map(|m| match m {
        plan::document::PruneModeFlag::Default => PruneMode::Default,
        plan::document::PruneModeFlag::No => PruneMode::No,
    });
    args.reconcile = flags.reconcile;
    args.force_conflicts = flags.force_conflicts;
    args.accept_migrations = flags.accept_migrations;
    Ok(SavedPlan {
        path: path.display().to_string(),
        sha256: plan::saved::digest(&bytes),
        reviewed,
        args,
    })
}

/// `kix deploy --plan <file> --dry-run`: plan again, compare, and exit 0
/// when the reviewed plan matches or [`plan::saved::EXIT_STALE`] when not.
/// The dry run always runs when connected, as `kix plan` does.
fn check_saved_plan(saved: &SavedPlan, ctx: &mut CommandContext) -> Result<()> {
    let format = ctx.output_format(crate::cli::OutputFormat::Text);
    if format != crate::cli::OutputFormat::Text {
        output::progress_to_stderr();
    }
    let Some(mut p) = prepare(&saved.args, ctx)? else {
        return Ok(());
    };
    if let Some(b) = &mut p.bundle {
        p.sops = b.sops(false)?;
    }
    let report = match &p.pre_client {
        Some(client) => Some(super::plan::dry_run(&p, &saved.args, client.clone(), ctx)?),
        None => None,
    };
    let doc = super::plan::document(&mut p, report.as_ref(), &saved.args, Detail::Plain);
    let mut comparison = plan::saved::compare(&saved.reviewed, &doc);
    comparison.plan_sha256 = Some(saved.sha256.clone());
    match format {
        crate::cli::OutputFormat::Json => println!(
            "{}",
            serde_json::to_string_pretty(&comparison).into_diagnostic()?
        ),
        crate::cli::OutputFormat::Yaml => {
            print!("{}", serde_yml::to_string(&comparison).into_diagnostic()?)
        }
        _ => print!(
            "{}",
            plan::saved::render_text(&comparison, &saved.reviewed, &saved.path)
        ),
    }
    if !comparison.matches {
        std::process::exit(plan::saved::EXIT_STALE);
    }
    // A matching plan can still be one the deploy stops on, as `kix plan`
    // exits 3 for: a refused write, or migrations not accepted.
    let migrations_refused = !doc.migrations.items().is_empty() && !saved.args.accept_migrations;
    if doc.stops() || migrations_refused {
        if format == crate::cli::OutputFormat::Text {
            eprintln!(
                "{}",
                output::yellow(
                    "The deploy would stop: the plan has a refused write or a migration not accepted."
                )
            );
        }
        std::process::exit(super::plan::EXIT_WOULD_STOP);
    }
    Ok(())
}

/// Write `--record-annotation` pairs onto the Activation record, both where
/// the engine creates it before the first wave and where the plan applies
/// it last, so the two stay the same manifest.
fn annotate_record(p: &mut Prepared, annotations: &[(String, String)]) {
    if annotations.is_empty() {
        return;
    }
    let annotate = |manifest: &mut Value| {
        if !lifecycle::is_record(manifest) {
            return;
        }
        let meta = manifest
            .as_object_mut()
            .and_then(|m| m.get_mut("metadata"))
            .and_then(Value::as_object_mut);
        if let Some(meta) = meta {
            let map = meta
                .entry("annotations")
                .or_insert_with(|| Value::Object(Default::default()));
            if let Some(map) = map.as_object_mut() {
                for (k, v) in annotations {
                    map.insert(k.clone(), Value::String(v.clone()));
                }
            }
        }
    };
    p.new_manifests.iter_mut().for_each(annotate);
    for node in p.plan.nodes.iter_mut() {
        if let ChangeAction::Apply(manifest) = &mut node.action {
            annotate(manifest);
        }
    }
}

/// Everything a deploy decides before it writes: the two builds compared,
/// the actions, and the engine plan. `kix plan` and `kix deploy` share it,
/// so a plan made with the deploy's flags is the deploy's plan.
pub(crate) struct Prepared {
    pub result_path: PathBuf,
    /// The bundle the new side came from (`--bundle`), when it did.
    pub bundle: Option<super::bundle::LoadedBundle>,
    /// Where SOPS sources come from. A caller sets it for a bundle: `kix
    /// plan` with placeholders, `kix deploy` with the real files.
    pub sops: kix::cluster::secrets::SopsSources,
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
    /// Every object `plan` writes and the prune deletes, each shown in
    /// `pkg_diff` or re-applied; see [`plan::objects`].
    pub objects: plan::document::Objects,
}

/// Build, load the old side, and compute the actions and the engine plan.
/// `None` when the build has nothing to deploy. Progress lines go through
/// [`crate::say!`], so `kix plan -o json` keeps them off stdout.
pub(crate) fn prepare(args: &PlanArgs, ctx: &mut CommandContext) -> Result<Option<Prepared>> {
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    // The new side: a bundle, or a build of the flake.
    let mut bundle = None;
    let (result_path, mut new_graph) = match &args.bundle {
        Some(path) => {
            if !ctx.global.quiet {
                crate::say!("Reading bundle {}...", path.display());
            }
            let (loaded, graph) = super::bundle::load(path)?;
            if loaded.cluster() != args.cluster {
                return Err(miette!(
                    "the bundle {} is for cluster '{}', not '{}'",
                    path.display(),
                    output::printable(loaded.cluster()),
                    args.cluster
                ));
            }
            super::bundle::register_deployed(&args.deployed_bundles)?;
            bundle = Some(loaded);
            (graph.result_dir.clone(), graph)
        }
        None => {
            let flake_path = resolve_flake_path(&ctx.global.flake)?;
            if !ctx.global.quiet {
                crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
            }
            let overrides = ctx.global.input_overrides();
            let result_path = build_cluster_activation_with_status(
                &flake_path,
                &args.cluster,
                &overrides,
                &status,
            )
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
            let graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
                .map_err(|e| miette!("{e}"))?;
            (result_path, graph)
        }
    };
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

    let all_actions = actions(
        &new_manifests,
        &active_manifests,
        &failed_baseline.closures,
        &kept_baseline.closures,
        args.reconcile,
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

    // With a client the plan read the cluster, and its `prune` section
    // lists every orphan.
    let listed_deletes: &[ResourceId] = match &pre_client {
        Some(_) => &orphan_rids,
        None => &[],
    };
    let objects = plan::objects::of(
        &pkg_diff.shown,
        &new_graph,
        &plan,
        &deletes_of(prune_policy_for(args), &orphan_rids),
        listed_deletes,
        active_manifests
            .iter()
            .chain(failed_baseline.closures.iter().flatten())
            .chain(kept_baseline.closures.iter().flatten()),
    )
    .map_err(|e| miette!("{e}"))?;

    Ok(Some(Prepared {
        result_path,
        bundle,
        sops: Default::default(),
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
        objects,
    }))
}

/// The change for each object of the new build and each orphan: `new`
/// against the Active closure, then what the failed deploys may have left
/// and the orphans kept deploys left, then `--reconcile`. The folds can turn
/// a Skip into an Apply (repair) and can add orphans (prune); they never
/// invent a change the closures do not justify.
fn actions(
    new_manifests: &[Value],
    active_manifests: &[Value],
    failed_closures: &[Vec<Value>],
    kept_closures: &[Vec<Value>],
    reconcile: bool,
) -> Vec<ChangeAction> {
    let all_actions = kix::cluster::apply::fold_kept_closures(
        kix::cluster::apply::fold_failed_closures(
            kix::cluster::apply::detect_changes(new_manifests, active_manifests),
            new_manifests,
            failed_closures,
        ),
        new_manifests,
        kept_closures,
    );
    if !reconcile {
        return all_actions;
    }
    // --reconcile applies every object again, changed or not.
    let by_id: std::collections::HashMap<ResourceId, &Value> = new_manifests
        .iter()
        .map(|m| (ResourceId::from_value(m), m))
        .collect();
    all_actions
        .into_iter()
        .map(|action| match &action {
            ChangeAction::Skip(rid) => by_id
                .get(rid)
                .map_or(action.clone(), |m| ChangeAction::Apply((*m).clone())),
            _ => action,
        })
        .collect()
}

/// The orphans a run's prune deletes: under `PrunePolicy::Delete`, all but
/// the kinds `lifecycle::never_pruned` protects.
pub(crate) fn deletes_of(prune: PrunePolicy, orphan_rids: &[ResourceId]) -> Vec<ResourceId> {
    if prune != PrunePolicy::Delete {
        return Vec::new();
    }
    orphan_rids
        .iter()
        .filter(|rid| !lifecycle::never_pruned(&rid.kind))
        .cloned()
        .collect()
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

            // A `--deployed-bundle`, then built-via, then the local cache.
            match crate::commands::baseline::record_graph(cluster, hash, act.built_via.as_deref()) {
                Ok(Some(mut old_graph)) => {
                    stamp_annotations(&mut old_graph);
                    let manifests: Vec<Value> = old_graph
                        .resources
                        .values()
                        .map(|r| r.manifest.clone())
                        .collect();
                    Ok((Some(old_graph), manifests, Some(client), Some(act)))
                }
                found => {
                    // A build that will not load, or is not the record's,
                    // is not a first deploy. Fall back to the cluster rather
                    // than planning against nothing.
                    if !global.quiet {
                        match &found {
                            Err(e) => crate::say!(
                                "  {} {e}. Reconstructing previous state from cluster",
                                output::yellow("!"),
                            ),
                            _ => crate::say!(
                                "  {} store path for activation not found locally. Reconstructing previous state from cluster",
                                output::yellow("!"),
                            ),
                        }
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

/// `plan_args` are the planning flags the deploy uses: `args.plan`, or a
/// saved plan's flags under `--plan`. The apply reads them from here and
/// never from `args.plan`, so it does what the plan it was compared on does.
#[allow(clippy::too_many_arguments)]
async fn run_deploy_async(
    args: &DeployArgs,
    plan_args: &PlanArgs,
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
    sops: kix::cluster::secrets::SopsSources,
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

    if let (Some(name), Some(hash)) = (activation_name, activation_identity_hash)
        && let Some((ar, _)) =
            activation::find_activation_ar(&discovery).map_err(|e| miette!("{e}"))?
        && let Some(found) = activation::identity_hash_of(&client, ar, name)
            .await
            .map_err(|e| miette!("{e}"))?
        && found != hash
    {
        return Err(miette!(
            "the cluster already has an Activation named {name} for another build \
             (identity hash {found}, this build is {hash}). Nothing was applied."
        ));
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

    let prune_policy = prune_policy_for(plan_args);
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
            force_conflicts: plan_args.force_conflicts,
            dry_run: false,
            // Create the record before the first wave, so a run that stops
            // part way leaves something that says what it was attempting
            // (kixpkgs#82). The plan applies this same manifest again as its
            // last node, which is then an unchanged no-op.
            activation_manifest: activation_manifest.cloned(),
            consumed_failed: consumed_failed.to_vec(),
            kept_orphans,
            mark_failed_on_abort: true,
            sops,
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

/// The planning flags of an operator deploy. The operator always prunes, so
/// the objects check treats every orphan as deleted, as the operator will.
fn operator_plan_args(args: &PlanArgs) -> PlanArgs {
    PlanArgs {
        prune: true,
        prune_mode: None,
        ..args.clone()
    }
}

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    // The plan and the objects check of the direct path. The operator plans
    // again against the live objects, but a build whose plan hides an
    // object is refused here, before it reaches the cluster.
    let Some(p) = prepare(&operator_plan_args(&args.plan), ctx)? else {
        return Ok(());
    };
    let activation_name = p
        .activation_name
        .clone()
        .ok_or_else(|| miette!("no Activation resource found in cluster manifests"))?;
    if !ctx.global.quiet {
        plan::print_package_plan(&p.pkg_diff, ctx.global.verbose > 0);
        plan::print_plan_summary(&p.pkg_diff);
        print!(
            "{}",
            render_plan_orphans(
                &p.orphan_rids,
                "will be deleted; the operator always prunes"
            )
        );
        super::shared_orphans::print(&p.shared_orphans);
    }
    // Operator-mode is non-interactive on the operator side, so the CLI
    // must enforce the migration gate before handing off the Activation CR.
    if !p.migration_pairs.is_empty() {
        print_migration_pairs(&p.migration_pairs);
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
    let Prepared {
        result_path,
        new_graph,
        cluster,
        activation_identity_hash,
        ..
    } = p;

    // The receipt, same as the direct path. The operator has no source tree,
    // so provenance is computed here and written onto the Activation when it
    // is applied.
    let receipt =
        crate::commands::compliance::receipt::build_receipt(&new_graph, &ctx.global.flake);
    if !ctx.global.quiet {
        print_dirty_source_warning(&receipt, false);
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

/// Print [`dirty_source_warning`], if any.
fn print_dirty_source_warning(receipt: &Value, from_bundle: bool) {
    let Some((warning, revision)) = dirty_source_warning(receipt, from_bundle) else {
        return;
    };
    println!();
    for line in warning {
        println!("{}", output::yellow(line));
    }
    if let Some(rev) = revision {
        println!("  {}", output::dim(&rev));
    }
}

/// The warning to print before confirming a deploy whose receipt records a
/// dirty source, and the recorded revision. A dirty tree is allowed, but
/// its recorded commit does not fully describe the deployed source. A
/// bundle's receipt says what the machine that made the bundle recorded,
/// so the revision is shown with its control characters escaped.
fn dirty_source_warning(
    receipt: &Value,
    from_bundle: bool,
) -> Option<([&'static str; 2], Option<String>)> {
    if receipt["source"]["dirty"] != Value::Bool(true) {
        return None;
    }
    let warning = if from_bundle {
        [
            "The bundle was made from a source tree with uncommitted changes, so the commit it",
            "records does not contain what is about to be applied. The record will say so.",
        ]
    } else {
        [
            "The working tree has uncommitted changes, so the commit recorded for this deploy",
            "does not contain what is about to be applied. The record will say so.",
        ]
    };
    Some((
        warning,
        receipt["source"]["revision"]
            .as_str()
            .map(output::printable),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A bundle's receipt is written by whoever made the bundle: its text
    /// reaches the terminal without control characters, and the warning
    /// is about the bundle's source, not the operator's tree.
    #[test]
    fn a_dirty_bundle_source_is_named_as_the_bundles_and_escaped() {
        let receipt = serde_json::json!({"source": {
            "dirty": true, "revision": "abc\u{1b}[2J\u{202e}-dirty"}});
        let (warning, revision) = dirty_source_warning(&receipt, true).unwrap();
        let text = warning.join(" ");
        assert!(text.contains("bundle"), "{text}");
        assert!(!text.contains("working tree"), "{text}");
        let revision = revision.unwrap();
        assert!(
            !revision.chars().any(|c| c.is_control() || c == '\u{202e}'),
            "{revision:?}"
        );
        let (warning, _) = dirty_source_warning(&receipt, false).unwrap();
        assert!(warning.join(" ").contains("working tree"));
    }

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

/// A deploy refuses an object its plan does not show. Each build here is
/// the `kix-enterprise-test` bundle changed after `Bundle::read`, past
/// `StoreGraph::validate`, so the objects check alone stands between it
/// and the cluster. The steps are the ones `prepare` takes.
#[cfg(test)]
mod plan_bound_properties;

#[cfg(test)]
pub(crate) mod plan_bound_tests {
    use super::*;
    use crate::cli::{Cli, Command};
    use crate::plan::document::{Objects, WriteChange};
    use crate::plan::objects::Unshown;
    use clap::Parser;
    use kix::eval::bundle::Bundle;
    use kix::eval::store_graph::store_hash;
    use kix::eval::{PackageNode, ResourceNode};
    use kix::manifest::types;
    use serde_json::json;
    use std::path::Path;

    const FIXTURE: &[u8] =
        include_bytes!("../../../kix/tests/fixtures/bundles/kix-enterprise-test.kixbundle");

    const NS: &str = "kix-enterprise-test-data";

    pub(crate) fn build() -> StoreGraph {
        Bundle::read(std::io::Cursor::new(FIXTURE)).unwrap().1
    }

    fn deploy_args(extra: &[&str]) -> PlanArgs {
        let mut argv = vec!["kix", "deploy", "x"];
        argv.extend_from_slice(extra);
        match Cli::try_parse_from(argv).expect("args parse").command {
            Command::Deploy(args) => args.plan,
            _ => unreachable!(),
        }
    }

    pub(crate) fn stamped(graph: &StoreGraph) -> (StoreGraph, Vec<Value>) {
        let mut graph = graph.clone();
        stamp_annotations(&mut graph);
        let manifests = graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect();
        (graph, manifests)
    }

    /// What `prepare` checks for a deploy of `new` to a cluster that runs
    /// `old`, or nothing, with the flags `extra`, before the plan reads the
    /// cluster.
    fn objects(
        old: Option<&StoreGraph>,
        new: &StoreGraph,
        extra: &[&str],
    ) -> Result<Objects, Unshown> {
        let args = deploy_args(extra);
        let (new_graph, new_manifests) = stamped(new);
        let (old_graph, active_manifests) = match old {
            Some(old) => stamped(old),
            None => (StoreGraph::empty(&new.cluster_name), Vec::new()),
        };
        let all_actions = actions(&new_manifests, &active_manifests, &[], &[], args.reconcile);
        let orphan_rids: Vec<ResourceId> = all_actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect();
        let resource_graph = ResourceGraph::from_manifests(&new_manifests).unwrap();
        let plan = DeployPlan::from_graph_and_changes(&resource_graph, &all_actions).unwrap();
        let pkg_diff = plan::diff_graphs(&old_graph, &new_graph);
        plan::objects::of(
            &pkg_diff.shown,
            &new_graph,
            &plan,
            &deletes_of(prune_policy_for(&args), &orphan_rids),
            &[],
            active_manifests.iter(),
        )
    }

    /// A store path whose hash is `seed`, padded, for a file named `name`.
    fn path(seed: &str, name: &str) -> PathBuf {
        PathBuf::from(format!("/nix/store/{seed:0<32}-k8s-{name}"))
    }

    fn add(graph: &mut StoreGraph, path: &Path, manifest: Value) {
        graph.resources.insert(
            path.to_path_buf(),
            ResourceNode {
                store_path: path.to_path_buf(),
                manifest,
            },
        );
    }

    pub(crate) fn package_instance(name: &str, instance: Option<&str>) -> Value {
        let mut spec = json!({"namespaceName": NS});
        if let Some(instance) = instance {
            spec["instanceName"] = json!(instance);
        }
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::PACKAGE_INSTANCE_KIND,
            "metadata": {"name": name, "namespace": NS},
            "spec": spec,
        })
    }

    fn cluster_role_binding(name: &str) -> Value {
        json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRoleBinding",
            "metadata": {"name": name},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"},
            "subjects": [{"kind": "ServiceAccount", "name": "default", "namespace": NS}],
        })
    }

    /// Add a package that the graph names `instance` in [`NS`], made from
    /// `pi` and holding one ClusterRoleBinding, before every other package.
    pub(crate) fn add_package(
        graph: &mut StoreGraph,
        seed: &str,
        pi: Value,
        instance: &str,
    ) -> ResourceId {
        let pi_path = path(&format!("{seed}p"), "PackageInstance-pi");
        let crb = cluster_role_binding(&format!("{seed}-admin"));
        let crb_path = path(&format!("{seed}c"), "ClusterRoleBinding-admin");
        let id = ResourceId::from_value(&crb);
        add(graph, &pi_path, pi);
        add(graph, &crb_path, crb);
        graph
            .resource_owner
            .insert(crb_path.clone(), pi_path.clone());
        graph.packages.shift_insert(
            0,
            pi_path.clone(),
            PackageNode {
                store_path: pi_path,
                instance_name: instance.to_string(),
                namespace: NS.to_string(),
                version: None,
                lifecycle: None,
                resource_paths: vec![crb_path],
                cross_deps: Vec::new(),
            },
        );
        id
    }

    fn refused_writes(result: Result<Objects, Unshown>) -> Vec<String> {
        match result {
            Ok(objects) => panic!("the deploy was not refused: {objects:?}"),
            Err(unshown) => unshown.writes,
        }
    }

    /// The operator always prunes, so an operator deploy's check holds every
    /// delete to the plan, whatever the prune flags say.
    #[test]
    fn an_operator_deploy_is_checked_as_one_that_prunes() {
        for extra in [&[][..], &["--prune-mode", "no"][..]] {
            let args = operator_plan_args(&deploy_args(&[&["--operator"][..], extra].concat()));
            assert_eq!(prune_policy_for(&args), PrunePolicy::Delete, "{extra:?}");
        }
    }

    /// The operator reads the build from the Nix store, and a bundle's build
    /// is not there: with `--bundle` it would be handed a path it cannot read.
    #[test]
    fn an_operator_deploy_does_not_take_a_bundle() {
        let parsed = Cli::try_parse_from([
            "kix",
            "deploy",
            "x",
            "--operator",
            "--bundle",
            "x.kixbundle",
        ]);
        assert!(parsed.is_err());
    }

    /// Two PackageInstances of one instance: the plan keys packages by
    /// namespace and instance, so it shows one of them, and the deploy
    /// would apply both.
    #[test]
    fn a_package_hidden_behind_another_of_its_instance_is_refused() {
        let mut new = build();
        let id = add_package(
            &mut new,
            "evil",
            package_instance("shop-2", Some("shop")),
            "shop",
        );
        let refused = refused_writes(objects(None, &new, &[]));
        let hidden: Vec<&str> = refused
            .iter()
            .map(|w| w.split(' ').next().unwrap())
            .collect();
        let pi = format!("{}/shop-2@{NS}", lifecycle::PACKAGE_INSTANCE_KIND);
        assert_eq!(hidden, vec![id.display_id(), pi], "{refused:?}");
    }

    /// An object whose owner is a package the graph does not hold is in no
    /// package and not cluster-level, so no section of the plan lists it.
    #[test]
    fn an_object_owned_by_a_missing_package_is_refused() {
        let mut new = build();
        let crb = cluster_role_binding("orphaned-admin");
        let id = ResourceId::from_value(&crb);
        let crb_path = path("orphaned", "ClusterRoleBinding-orphaned-admin");
        add(&mut new, &crb_path, crb);
        new.resource_owner
            .insert(crb_path, path("missing", "PackageInstance-missing"));
        let refused = refused_writes(objects(None, &new, &[]));
        assert_eq!(refused.len(), 1, "{refused:?}");
        assert!(refused[0].starts_with(&id.display_id()), "{refused:?}");
    }

    /// The plan shows one Activation record; a second is applied unseen.
    #[test]
    fn a_second_activation_record_is_refused() {
        let mut new = build();
        let record = new.resources[&new.activation_path].manifest.clone();
        let mut second = record.clone();
        second["metadata"]["name"] = json!("kix-enterprise-test-second");
        add(&mut new, &path("second", "Activation-second"), second);
        let refused = refused_writes(objects(None, &new, &[]));
        assert_eq!(refused.len(), 1, "{refused:?}");
        assert!(refused[0].starts_with("Activation/"), "{refused:?}");
    }

    /// Two files of one object: the deploy applies one of them, and which
    /// one the plan shows is not fixed.
    #[test]
    fn two_files_of_one_object_are_refused() {
        let mut new = build();
        let (at, node) = new
            .resources
            .iter()
            .find(|(_, n)| n.manifest["kind"] == "ConfigMap")
            .map(|(p, n)| (p.clone(), n.clone()))
            .unwrap();
        let mut copy = node.manifest.clone();
        copy["data"] = json!({"other": "value"});
        let copy_path = path("copy", "ConfigMap-copy");
        add(&mut new, &copy_path, copy);
        let owner = new.resource_owner[&at].clone();
        new.resource_owner.insert(copy_path, owner);
        let refused = refused_writes(objects(None, &new, &[]));
        assert!(
            refused.iter().any(|w| w.contains("in 2 build files")),
            "{refused:?}"
        );
    }

    /// A deploy deletes only what the plan lists as removed.
    #[test]
    fn a_delete_the_plan_does_not_show_is_refused() {
        let new = build();
        let (new_graph, new_manifests) = stamped(&new);
        let all_actions = actions(&new_manifests, &new_manifests, &[], &[], false);
        let resource_graph = ResourceGraph::from_manifests(&new_manifests).unwrap();
        let plan = DeployPlan::from_graph_and_changes(&resource_graph, &all_actions).unwrap();
        let pkg_diff = plan::diff_graphs(&new_graph, &new_graph);
        let stray = ResourceId {
            kind: "ConfigMap".into(),
            namespace: NS.into(),
            name: "not-in-any-build".into(),
        };
        let refused = plan::objects::of(
            &pkg_diff.shown,
            &new_graph,
            &plan,
            std::slice::from_ref(&stray),
            &[],
            new_manifests.iter(),
        )
        .unwrap_err();
        assert_eq!(refused.deletes, vec![stray.display_id()]);
        // The plan's prune section, when it read the cluster, lists it.
        assert!(
            plan::objects::of(
                &pkg_diff.shown,
                &new_graph,
                &plan,
                std::slice::from_ref(&stray),
                std::slice::from_ref(&stray),
                new_manifests.iter(),
            )
            .is_ok()
        );
    }

    /// A first deploy writes every object, each listed as added.
    #[test]
    fn a_first_deploy_writes_every_object_the_plan_shows() {
        let new = build();
        let objects = objects(None, &new, &[]).unwrap();
        assert_eq!(objects.writes.len(), new.resources.len());
        assert!(
            objects
                .writes
                .iter()
                .all(|w| w.change == WriteChange::Added)
        );
        assert!(objects.deletes.is_empty());
    }

    #[test]
    fn a_redeploy_of_the_deployed_build_writes_nothing() {
        let build = build();
        let objects = objects(Some(&build), &build, &["--prune"]).unwrap();
        assert_eq!(objects, Objects::default());
    }

    /// `--reconcile` writes every object again, each re-applied: the
    /// deployed build holds the same file for it.
    #[test]
    fn reconcile_reapplies_the_deployed_build() {
        let build = build();
        let objects = objects(Some(&build), &build, &["--reconcile"]).unwrap();
        assert_eq!(objects.writes.len(), build.resources.len());
        assert!(
            objects
                .writes
                .iter()
                .all(|w| w.change == WriteChange::Reapplied)
        );
    }

    /// A PackageInstance that changed while its resources did not is
    /// applied, so the plan shows its package as changed.
    #[test]
    fn a_package_instance_changed_alone_is_shown() {
        let old = build();
        let mut new = old.clone();
        let at = new
            .packages
            .iter()
            .find(|(_, p)| p.instance_name == "shop")
            .map(|(at, _)| at.clone())
            .unwrap();
        let mut node = new.packages.shift_remove(&at).unwrap();
        let mut pi = new.resources.remove(&at).unwrap().manifest;
        pi["spec"]["version"] = json!("2.0.0");
        let moved = path("shopv2", "PackageInstance-shop");
        add(&mut new, &moved, pi);
        for owner in new.resource_owner.values_mut() {
            if *owner == at {
                *owner = moved.clone();
            }
        }
        node.store_path = moved.clone();
        new.packages.insert(moved, node);
        let objects = objects(Some(&old), &new, &[]).unwrap();
        let written: Vec<(&str, &str, WriteChange)> = objects
            .writes
            .iter()
            .map(|w| (w.kind.as_str(), w.package.as_str(), w.change))
            .collect();
        assert_eq!(
            written,
            vec![(
                lifecycle::PACKAGE_INSTANCE_KIND,
                "kix-enterprise-test-data/shop",
                WriteChange::Modified
            )]
        );
    }

    /// A package left out of the build is deleted under `--prune`, each of
    /// its objects listed as removed.
    #[test]
    fn a_removed_package_is_deleted_as_shown() {
        let old = build();
        let mut new = old.clone();
        let at = new
            .packages
            .iter()
            .find(|(_, p)| p.instance_name == "landing")
            .map(|(at, _)| at.clone())
            .unwrap();
        let node = new.packages.shift_remove(&at).unwrap();
        for p in node.resource_paths.iter().chain([&at]) {
            new.resources.remove(p);
            new.resource_owner.remove(p);
        }
        let objects = objects(Some(&old), &new, &["--prune"]).unwrap();
        assert!(objects.writes.is_empty(), "{:?}", objects.writes);
        assert!(!objects.deletes.is_empty());
    }

    /// A namespaced object with no namespace and one in `default` pass the
    /// build's one-object rule, which compares (kind, namespace, name)
    /// exactly, and both are applied to the one live object in `default`.
    /// The plan lists both, each with its own store hash, so the reviewer
    /// sees both manifests and the digest binds both.
    #[test]
    fn an_object_without_a_namespace_and_one_in_default_are_both_shown() {
        let mut new = build();
        let shop = package_at(&new, "shop");
        for (seed, namespace) in [("bare", None), ("dflt", Some("default"))] {
            let mut cm = json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": "twin"},
                "data": {"from": seed},
            });
            if let Some(namespace) = namespace {
                cm["metadata"]["namespace"] = json!(namespace);
            }
            let at = path(seed, "ConfigMap-twin");
            add(&mut new, &at, cm);
            new.resource_owner.insert(at.clone(), shop.clone());
            new.packages[&shop].resource_paths.push(at);
        }
        new.validate().unwrap();
        let objects = objects(None, &new, &[]).unwrap();
        let twins: Vec<(&str, WriteChange)> = objects
            .writes
            .iter()
            .filter(|w| w.name == "twin")
            .map(|w| (w.namespace.as_str(), w.change))
            .collect();
        assert_eq!(
            twins,
            vec![
                (types::CLUSTER_SCOPED, WriteChange::Added),
                ("default", WriteChange::Added)
            ]
        );
    }

    /// The build's one-record rule counts every manifest of kind
    /// Activation, whatever its API group, so another group's Activation
    /// cannot sit beside kix's record.
    #[test]
    fn another_groups_activation_is_refused_by_the_build() {
        let mut new = build();
        let mut foreign = new.resources[&new.activation_path].manifest.clone();
        foreign["apiVersion"] = json!("example.com/v1");
        foreign["metadata"]["name"] = json!("foreign");
        add(&mut new, &path("foreign", "Activation-foreign"), foreign);
        let err = new.validate().unwrap_err().to_string();
        assert!(err.contains("one Activation record"), "{err}");
    }

    /// Another group's PackageInstance listed as a package is shown as that
    /// package's PackageInstance, and its store hash, which covers its
    /// `apiVersion`, is in the digest. Not listed, it is a cluster-level
    /// object like any other.
    #[test]
    fn another_groups_package_instance_is_shown_with_its_store_hash() {
        let mut new = build();
        let mut pi = package_instance("foreign", Some("foreign"));
        pi["apiVersion"] = json!("example.com/v1");
        add_package(&mut new, "listed", pi.clone(), "foreign");
        pi["metadata"]["name"] = json!("unlisted");
        let unlisted = path("unlisted", "PackageInstance-unlisted");
        add(&mut new, &unlisted, pi);
        new.validate().unwrap();
        let objects = objects(None, &new, &[]).unwrap();
        let pis: Vec<(&str, &str, &str)> = objects
            .writes
            .iter()
            .filter(|w| w.name == "foreign" || w.name == "unlisted")
            .map(|w| (w.name.as_str(), w.package.as_str(), w.store_hash.as_str()))
            .collect();
        let listed_hash = store_hash(&path("listedp", "PackageInstance-pi"));
        let unlisted_hash = store_hash(&unlisted);
        assert_eq!(
            pis,
            vec![
                (
                    "foreign",
                    "kix-enterprise-test-data/foreign",
                    listed_hash.as_str()
                ),
                ("unlisted", plan::CLUSTER_LEVEL_KEY, unlisted_hash.as_str()),
            ]
        );
    }

    /// Whether a deploy of `deployed` from a plan reviewed for `reviewed`,
    /// both over `old`, is refused, and on which rules. Both builds carry
    /// one Activation record, so the build rule alone lets it through.
    fn saved_rules(
        old: Option<&StoreGraph>,
        reviewed: &StoreGraph,
        deployed: &StoreGraph,
        extra: &[&str],
    ) -> Vec<plan::saved::Rule> {
        let doc = |graph: &StoreGraph| {
            let (stamped_graph, _) = stamped(graph);
            let empty = plan::diff_graphs(&stamped_graph, &stamped_graph);
            let mut doc = plan::document::Plan::new(
                plan::document::MadeBy::DryRun,
                &graph.cluster_name,
                plan::document::Build::of(&stamped_graph),
                &empty,
                plan::document::Detail::Plain,
                &[],
                plan::document::NotCheckedReason::BuildsOnly,
            );
            let objects = objects(old, graph, extra).unwrap();
            doc.objects_digest = Some(plan::objects::digest(&objects));
            doc.objects = Some(objects);
            doc
        };
        let (reviewed, fresh) = (doc(reviewed), doc(deployed));
        assert_eq!(reviewed.build, fresh.build, "one Activation record");
        plan::saved::compare(&reviewed, &fresh)
            .mismatches
            .iter()
            .map(|m| m.rule)
            .collect()
    }

    fn package_at(graph: &StoreGraph, instance: &str) -> PathBuf {
        graph
            .packages
            .iter()
            .find(|(_, p)| p.instance_name == instance)
            .map(|(at, _)| at.clone())
            .unwrap()
    }

    /// An object added under a package of a build with the reviewed
    /// Activation record is another set of objects.
    #[test]
    fn a_saved_plan_refuses_an_object_added_under_its_activation() {
        let reviewed = build();
        let mut deployed = reviewed.clone();
        let shop = package_at(&deployed, "shop");
        let crb_path = path("added", "ClusterRoleBinding-added");
        add(&mut deployed, &crb_path, cluster_role_binding("added"));
        deployed
            .resource_owner
            .insert(crb_path.clone(), shop.clone());
        deployed.packages[&shop].resource_paths.push(crb_path);
        assert_eq!(
            saved_rules(None, &reviewed, &deployed, &[]),
            vec![plan::saved::Rule::Objects]
        );
    }

    /// The same files under another package stamp another owner on what
    /// the deploy applies.
    #[test]
    fn a_saved_plan_refuses_another_owner_for_the_same_files() {
        let reviewed = build();
        let mut deployed = reviewed.clone();
        let (shop, cache) = (
            package_at(&deployed, "shop"),
            package_at(&deployed, "cache"),
        );
        let moved = deployed.packages[&shop].resource_paths.remove(0);
        deployed.packages[&cache].resource_paths.push(moved.clone());
        deployed.resource_owner.insert(moved, cache);
        assert_eq!(
            saved_rules(None, &reviewed, &deployed, &[]),
            vec![plan::saved::Rule::Objects]
        );
    }

    /// A manifest missing from the deployed build is an orphan, and
    /// `--prune` would delete its live object.
    #[test]
    fn a_saved_plan_refuses_a_build_that_lost_a_manifest() {
        let reviewed = build();
        let mut deployed = reviewed.clone();
        let landing = package_at(&deployed, "landing");
        let lost = deployed.packages[&landing].resource_paths.remove(0);
        deployed.resources.remove(&lost);
        deployed.resource_owner.remove(&lost);
        assert_eq!(
            saved_rules(Some(&reviewed), &reviewed, &deployed, &["--prune"]),
            vec![plan::saved::Rule::Objects]
        );
    }
}
