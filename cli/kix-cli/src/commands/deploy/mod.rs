//! Build, plan, and deploy a cluster activation.
//!
//! [`super::plan::prepare`] builds and runs [`kix::plan::Planner`], which
//! compares the new build against the active cluster closures by Kubernetes
//! identity (`kind`, `namespace`, and `name`) and identity hash without
//! querying live objects. This module renders the plan, prompts for
//! confirmation, applies the dependency graph, and prunes authorized orphans in
//! reverse dependency order.

mod observer;
mod saved_plan;
#[cfg(test)]
mod tests;

use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use crate::cli::{DeployArgs, OnError};
use crate::client;
use crate::output;
use crate::plan;
use kix::cluster::activation::{OpenedRecords, Records};
use kix::cluster::apply::ChangeAction;
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::cluster::kubernetes_version;
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::{DeployObserver, DeployResult, NodeId};
use kix::cluster::watchdog::StallPolicy;
use kix::plan::document::PlanFlags;
use kix::plan::{CheckedPlan, Target};

use super::CommandContext;
use super::operator::Reconciled;
use super::plan::{document, dry_run, flags_of, prepare, print_text};

pub(crate) use self::observer::StreamCliObserver;
use self::observer::*;
use self::saved_plan::*;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    let saved = match &args.saved_plan {
        Some(path) => Some(load_saved_plan(path, &flags_of(&args.plan))?),
        None => None,
    };
    if args.dry_run {
        return match &saved {
            Some(s) => check_saved_plan(s, &args.plan, ctx),
            None if matches!(
                output::format(),
                crate::cli::OutputFormat::Json | crate::cli::OutputFormat::Yaml
            ) =>
            {
                Err(miette!(
                    "kix deploy --dry-run prints text or Markdown. To keep the plan as data, \
                     write it with `kix plan --save FILE.{}`; `kix deploy --plan FILE --dry-run \
                     -o json` prints the comparison with a saved plan as JSON",
                    kix::plan::file::EXTENSION
                ))
            }
            None => super::plan::run(&args.plan, None, ctx),
        };
    }
    if args.operator {
        return run_operator(args, ctx);
    }

    // When `--plan` is set, use the planning flags recorded in the saved plan
    // rather than `args.plan`.
    let flags = saved.as_ref().map_or(flags_of(&args.plan), |s| s.flags);
    let Some(mut p) = prepare(&args.plan, flags, ctx)? else {
        return Ok(());
    };
    let sops = p.sops_sources(false).map_err(|e| miette!("{e}"))?;
    p.annotate_record(&args.record_annotations)
        .map_err(|e| miette!("{e}"))?;

    if !p.migration_pairs.is_empty() {
        print_migration_pairs(&p.migration_pairs);
        if !p.checked.flags().accept_migrations {
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
        crate::say!(
            "{}",
            output::yellow(
                "--accept-migrations set: continuing deployment. Kix will not copy data. Workloads using the new storage will see only the data already present there."
            )
        );
    }

    // When connected and changes exist, run a server-side dry run so any
    // writes the API server would reject appear in the plan before confirmation.
    let total_apply = p
        .checked
        .plan()
        .nodes()
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
        .count();
    let report = match &p.client {
        Some(client) if total_apply > 0 || !p.checked.orphans().is_empty() => {
            let client = client.clone();
            Some(dry_run(&mut p, false, client, ctx)?)
        }
        _ => None,
    };
    let doc = document(&mut p, report.as_ref(), false);

    if !output::quiet() {
        print_text(&p, &doc, ctx.global.verbose > 0);
    }

    // Refuse to apply when a saved plan no longer matches the current plan.
    if let Some(s) = &saved {
        let mut comparison = kix::plan::saved::compare(&s.reviewed, &doc);
        comparison.plan_sha256 = Some(s.sha256.clone());
        eprintln!();
        eprint!(
            "{}",
            plan::render::render_comparison(&comparison, &s.reviewed, &s.path)
        );
        if !comparison.matches {
            std::process::exit(EXIT_STALE);
        }
    }

    // Under `--on-error stop`, abort before applying anything when the dry run
    // reports a write that the cluster would reject.
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

    let cluster = p.build.graph().cluster_name.clone();
    let active_hash = p.baseline.active_hash().map(str::to_string);

    if total_apply == 0 && p.checked.orphans().is_empty() {
        // Even when no resources changed, an unchanged Job whose previous run
        // failed must be reported, and run again under `kix.run/rerun`.
        // Because the failed deploy did not advance the active activation,
        // the next deploy sees identical hashes and relies on the scheduler's
        // `Skip` path to read the live Job.
        let has_skipped_jobs = p.checked.plan().has_skipped_jobs();
        let failed_jobs = match &p.client {
            Some(client) if has_skipped_jobs => ctx.runtime.block_on(async {
                let discovery = discovery::discover_resources(client)
                    .await
                    .map_err(|e| miette!("{e}"))?;
                Ok::<_, miette::Report>(
                    scheduler::failed_skipped_jobs(client, &discovery, p.checked.plan()).await,
                )
            })?,
            _ => Vec::new(),
        };
        // Under `--current-activation` there is no pre-confirm client, so let
        // the scheduler inspect the live Jobs during execution.
        let engine_decides = p.client.is_none() && has_skipped_jobs;
        if failed_jobs.is_empty() && !engine_decides {
            // Supersede folded-in failed records even when their resources
            // need no changes or pruning, because the scheduler will not run
            // `finalize_deploy` on this early-return path.
            if let Some(client) = &p.client {
                supersede_consumed(ctx, client, &p.baseline.failed().consumed);
            }
            match (p.checked.activation_identity_hash(), active_hash.as_deref()) {
                (Some(new), Some(old)) if new == old => crate::say!(
                    "{} activation identical to active ({}...). Nothing to apply.",
                    output::dim("="),
                    &new[..8.min(new.len())],
                ),
                _ => crate::say!("Nothing to apply."),
            }
            return Ok(());
        }
        if engine_decides {
            crate::say!(
                "{} nothing changed; Kix checks the live Jobs on the cluster to see whether one failed",
                output::yellow("↻"),
            );
        }
        if !failed_jobs.is_empty() {
            let names: Vec<String> = failed_jobs.iter().map(|r| r.to_string()).collect();
            crate::say!(
                "{} nothing changed, but {} failed on the last run (a Job with {} runs again; any other is reported as failed): {}",
                output::yellow("↻"),
                failed_jobs.len(),
                kix::manifest::keys::RERUN,
                names.join(", "),
            );
        }
    }

    // Build the deployment receipt before confirmation so dirty source state
    // is visible in the prompt.
    let receipt = ctx.receipts.of_build(&p.build, &ctx.global.flake);

    print_warnings(&ctx.receipts.warnings(&receipt));

    // Check whether cluster nodes carry the labels referenced by topology
    // spread rules when a pre-confirm client is available.
    if let Some(client) = &p.client
        && !output::quiet()
    {
        report_topology_labels(ctx, client, p.new_manifests());
    }

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
        output::progress_text("\nProceed with deploy? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            output::progress_text("Deploy cancelled.\n");
            return Ok(());
        }
    }

    let global = ctx.global.clone();
    let end = ctx.runtime.block_on(run_deploy_async(
        args,
        &global,
        p.checked,
        &cluster,
        Some(&receipt),
        p.client,
        if args.plan.current_activation {
            active_hash.as_deref()
        } else {
            None
        },
        sops,
    ))?;

    // Update the local activation cache only when this build's record became
    // current. Caching a build whose deploy left nodes unattempted would cause
    // soft `kix gc` to treat the live resources as garbage and the next
    // `--current-activation` plan to skip unapplied nodes.
    if end.current
        && p.build.is_local()
        && let Err(e) = kix::eval::store::save_activation_path(&cluster, &p.build.graph().built_via)
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

/// Outcome of a scheduler run for `kix deploy` or `kix rollback`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct RunEnd {
    /// Whether the command should exit 0. `run_deploy` returns `Ok` with
    /// non-zero failure counts under `--on-error continue` or when a prune
    /// delete fails.
    pub succeeded: bool,
    /// Whether the run's Activation record became current. An `Err` or any
    /// cancelled node marks the record Failed and leaves the previous
    /// activation current.
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

/// Verify that the cached build used by `--current-activation` matches the
/// Active record of `cluster` in the connected Kubernetes context.
///
/// Because the local activation cache is keyed only by cluster name, deploying
/// a cluster with the same name in another context can overwrite it. Planning
/// against another environment's build would treat this cluster's resources as
/// orphans and prune them by name.
pub(super) async fn check_cached_baseline(
    records: Option<&Records>,
    cluster: &str,
    cached_hash: &str,
) -> Result<()> {
    let active = match records {
        Some(records) => records.active(cluster).await.map_err(|e| miette!("{e}"))?,
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

/// Reject pre-flight errors before writing to the cluster: an Activation record
/// name already used by a different build, or namespaced resources missing a
/// namespace.
pub(crate) async fn refuse_before_writing(
    checked: &CheckedPlan,
    records: Option<&Records>,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
) -> Result<()> {
    if let (Some(name), Some(hash)) = (
        checked.activation_name(),
        checked.activation_identity_hash(),
    ) && let Some(records) = records
    {
        refuse_name_taken(records, name, hash).await?;
    }
    refuse_namespaceless(discovery, checked.plan())
}

/// Reject an Activation record name that already exists on the cluster with a
/// different identity hash.
pub(super) async fn refuse_name_taken(records: &Records, name: &str, hash: &str) -> Result<()> {
    if let Some(found) = records
        .identity_hash_of(name)
        .await
        .map_err(|e| miette!("{e}"))?
        && found != hash
    {
        return Err(miette!(
            "the cluster already has an Activation named {name} for another build \
             (identity hash {found}, this build is {hash}). Nothing was applied."
        ));
    }
    Ok(())
}

/// Reject namespaced resources in `plan` that have no `metadata.namespace`.
pub(super) fn refuse_namespaceless(
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
    plan: &kix::cluster::scheduler::DeployPlan,
) -> Result<()> {
    let namespaceless = kix::cluster::apply::namespaceless(
        discovery,
        plan.nodes().iter().filter_map(|n| match &n.id {
            NodeId::Resource(rid) => Some(rid),
            _ => None,
        }),
    );
    if namespaceless.is_empty() {
        return Ok(());
    }
    Err(miette!(
        "{}",
        namespaceless
            .iter()
            .map(|rid| kix::cluster::apply::ApplyError::NoNamespace {
                resource: rid.display_id()
            }
            .to_string())
            .collect::<Vec<_>>()
            .join("\n")
    ))
}

/// Mark `consumed` failed Activation records as Superseded when a deploy
/// returns early without running the scheduler.
///
/// Normal deploys supersede consumed records during `finalize_deploy`. Failures
/// here are logged and retried on the next deploy.
fn supersede_consumed(ctx: &CommandContext, client: &kube::Client, consumed: &[String]) {
    if consumed.is_empty() {
        return;
    }
    let done = ctx.runtime.block_on(async {
        let Ok(discovery) = discovery::discover_resources(client).await else {
            return 0usize;
        };
        let Some(records) = Records::open(client, &discovery)
            .ok()
            .and_then(OpenedRecords::into_records)
        else {
            return 0;
        };
        let mut done = 0;
        for name in consumed {
            match records.supersede(name).await {
                Ok(()) => done += 1,
                Err(e) => tracing::warn!(activation = %name, error = %e, "could not supersede"),
            }
        }
        done
    });
    if done > 0 {
        crate::say!(
            "  {} {done} failed deploy record(s) had nothing left to reconcile; marked superseded",
            output::dim("="),
        );
    }
}

/// Warn before confirmation when cluster nodes lack the labels required by
/// `topologySpreadConstraints`.
///
/// The compiler cannot inspect live cluster nodes, and a missing label under
/// `DoNotSchedule` leaves pods unschedulable until readiness times out.
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
                crate::say!("{tag} {}", finding.describe());
            }
        }
        Ok(NodesOutcome::Forbidden) => {
            crate::say!(
                "{}",
                output::dim("note: topology labels not checked; this account may not list nodes")
            );
        }
        Err(e) => {
            crate::say!(
                "{} could not list nodes to check topology labels: {}",
                output::yellow("warn:"),
                kix::cluster::errors::describe(&e)
            );
        }
    }
}

/// Execute the deploy plan in `checked` using the flags recorded when `checked`
/// was built.
#[allow(clippy::too_many_arguments)]
async fn run_deploy_async(
    args: &DeployArgs,
    global: &crate::cli::GlobalArgs,
    mut checked: CheckedPlan,
    cluster_name: &str,
    receipt: Option<&Value>,
    pre_client: Option<kube::Client>,
    cached_baseline: Option<&str>,
    sops: kix::build_source::SopsSources,
) -> Result<RunEnd> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse the pre-confirm client, which the plan checked the build's
    // binding and Kubernetes version through, or connect now, check both,
    // and filter orphans shared with other Kix clusters.
    let client = match pre_client {
        Some(c) => c,
        None => {
            let client = client::make_client(global.context.as_deref())
                .await
                .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
            let connection = binding::Connection::of_context(global.context.as_deref());
            binding::check(&client, &connection, cluster_name, checked.kubernetes_uid())
                .await
                .map_err(|e| miette!("{e}"))?;
            kubernetes_version::check(
                &client,
                &connection,
                cluster_name,
                checked.kubernetes_version(),
                checked.kubernetes_version_from(),
            )
            .await
            .map_err(|e| miette!("{e}"))?;
            let (_, shared) =
                kix::plan::keep_shared(&client, cluster_name, checked.orphans().to_vec())
                    .await
                    .map_err(|e| miette!("{e}"))?;
            checked.keep_shared(&shared);
            plan::print_shared(&shared);
            client
        }
    };

    let target = Target::connect(client, sops)
        .await
        .map_err(|e| miette!("{e}"))?;
    let discovery = target.discovery();

    // Open `Records` again to enforce the domain migration gate. When
    // `--current-activation` is used, planning reads the local cache without
    // contacting the cluster, so this is the first point that blocks pruning
    // retired CRDs and cascading their Activation records.
    let records = Records::open(target.client(), discovery)
        .map_err(|e| miette!("{e}"))?
        .into_records();

    if let Some(hash) = cached_baseline {
        check_cached_baseline(records.as_ref(), cluster_name, hash).await?;
    }

    refuse_before_writing(&checked, records.as_ref(), discovery).await?;

    let on_error = match args.on_error {
        OnError::Stop => OnErrorPolicy::Stop,
        OnError::Continue => OnErrorPolicy::Continue,
    };

    let config = SchedulerConfig {
        timeout,
        on_error,
        cancel: kix::cluster::cancel::CancelToken::new(),
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        rerun_failed: true,
        check_unchanged: true,
        names_flags: true,
    };
    // Forward SIGINT and SIGTERM to the scheduler so an interrupted run aborts
    // its Activation record instead of leaving it in `Deploying`.
    config.cancel.cancel_on_interrupt();

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

    // In JSON log mode, emit a final NDJSON summary object instead of a text
    // summary line.
    let json_log = (tui_driver.is_none() && args.log_format == crate::cli::LogFormat::Json)
        .then(|| Arc::new(super::deploy_log::JsonObserver::new()));
    let observer: Arc<dyn DeployObserver> = match (&tui_driver, &json_log) {
        (Some(d), _) => d.observer(),
        (None, Some(json)) => json.clone(),
        (None, None) if args.log_format == crate::cli::LogFormat::Pretty && interactive => {
            Arc::new(StreamCliObserver {
                verbose: global.verbose > 0,
            })
        }
        (None, None) => Arc::new(super::deploy_log::LineObserver {
            verbose: global.verbose > 0,
        }),
    };

    let (result, kept) = checked
        .run(target, receipt.cloned(), config, observer)
        .await;

    // Drop the TUI before printing the summary so it lands in normal scrollback.
    drop(tui_driver);

    if let Some(recorded) = kept {
        kix::plan::baseline::sync_kept_roots(cluster_name, &recorded);
    }

    let end = RunEnd::of(&result);
    let counts = match &result {
        Ok(r) => r,
        Err(e) => e.partial(),
    };
    match &json_log {
        Some(json) => json.summary(counts, false, end.succeeded),
        None => {
            println!();
            println!("{}", summary_line(counts, false, end.succeeded));
        }
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

pub(super) fn parse_timeout(s: Option<&str>) -> Result<Duration> {
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

/// Force `prune: true` for operator deploys so pre-flight checks validate all
/// orphan deletions that the operator will perform.
pub(super) fn operator_flags(flags: PlanFlags) -> PlanFlags {
    PlanFlags {
        prune: true,
        prune_mode: None,
        ..flags
    }
}

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    // Run the same plan and pre-flight checks as a direct deploy so invalid
    // builds are rejected before the Activation is submitted to the cluster.
    let Some(p) = prepare(&args.plan, operator_flags(flags_of(&args.plan)), ctx)? else {
        return Ok(());
    };
    let checked = &p.checked;
    let activation_name = checked
        .activation_name()
        .map(str::to_string)
        .ok_or_else(|| miette!("no Activation resource found in cluster manifests"))?;
    if !output::quiet() {
        plan::print_package_plan(checked.pkg_diff(), ctx.global.verbose > 0);
        plan::print_plan_summary(checked.pkg_diff());
        print!(
            "{}",
            plan::render_plan_orphans(
                checked.orphans(),
                "will be deleted; the operator always prunes"
            )
        );
        plan::print_shared(checked.shared_orphans());
    }
    // Enforce `--accept-migrations` on the CLI before delegating to the
    // non-interactive operator.
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
    let cluster = p.build.graph().cluster_name.clone();
    let activation_identity_hash = p.checked.activation_identity_hash().map(str::to_string);
    let kubernetes_uid = p.build.graph().kubernetes_uid.clone();
    let package_index = p.checked.package_index().clone();
    let build = p.build;
    let result_path = build.graph().built_via.clone();

    // Compute provenance on the CLI because the operator has no access to the
    // source repository.
    let receipt = ctx.receipts.of_build(&build, &ctx.global.flake);
    print_warnings(&ctx.receipts.warnings(&receipt));

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

    let global = ctx.global.clone();
    let source_path = result_path.display().to_string();

    let reconciled = ctx.runtime.block_on(async {
        let (_, records) = super::operator::connect_and_verify(global.context.as_deref()).await?;

        crate::say!(
            "Applying Activation CR '{}' (source: {})...",
            output::bold(&activation_name),
            output::dim(&source_path),
        );

        super::operator::apply_activation(
            &records,
            &activation_name,
            &cluster,
            &source_path,
            activation_identity_hash.as_deref(),
            kubernetes_uid.as_deref(),
            Some(&receipt),
            &package_index,
        )
        .await?;

        crate::say!(
            "  {} Activation CR applied. Waiting for operator...",
            output::green("✓"),
        );

        let reconciled =
            super::operator::watch_activation_progress(&records, &activation_name).await?;

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

    // Save the activation path for the next deploy's diff; both `Active` and
    // `Degraded` records are current.
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
