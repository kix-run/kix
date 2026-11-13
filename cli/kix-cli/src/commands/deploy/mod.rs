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
pub(crate) mod stops;
#[cfg(test)]
mod tests;

use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use crate::cli::{DeployArgs, GroupBy, LogFormat, OnError};
use crate::client;
use crate::exit::Exit;
use crate::output;
use crate::plan;
use kix::cluster::activation::{OpenedRecords, Records};
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::{DeployObserver, DeployResult, NodeId};
use kix::cluster::watchdog::StallPolicy;
use kix::plan::document::PlanFlags;
use kix::plan::{CheckedPlan, Target};

use super::CommandContext;
use super::operator::Reconciled;
use super::plan::{document, dry_run, flags_of, prepare, print_text};

use self::observer::*;
pub(crate) use self::observer::{StreamCliObserver, counts, held_back};
#[cfg(test)]
pub(crate) use self::saved_plan::ComparisonResponse;
use self::saved_plan::*;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<Exit> {
    let saved = match &args.saved_plan {
        Some(path) => Some(load_saved_plan(
            path,
            &flags_of(&args.plan),
            &args.plan.cluster,
        )?),
        None => None,
    };
    if args.dry_run {
        return match &saved {
            Some(s) => check_saved_plan(s, &args.plan, ctx),
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
        return Ok(Exit::Success);
    };
    // A cluster that has never run a required stop must deploy it first.
    stops::check(
        &args.plan.cluster,
        p.baseline.active().and_then(|r| r.deployed_with.as_deref()),
        stops::Writer::Deploy,
    )?;
    let sops = p.sops_sources(false).map_err(|e| miette!("{e}"))?;
    p.annotate_record(&args.record_annotations)
        .map_err(|e| miette!("{e}"))?;

    // A saved plan is compared first, because a stale plan is exit 4 whatever
    // the current build would migrate.
    if saved.is_none() && !migration_gate(&p) {
        return Ok(Exit::Failure);
    }

    // When connected and changes exist, run a server-side dry run so any
    // writes the API server would reject appear in the plan before confirmation.
    let total_apply = p
        .checked
        .plan()
        .nodes()
        .iter()
        .filter(|n| n.action.written().is_some())
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
            plan::render::render_comparison(&comparison, &s.reviewed, &s.path, &s.cluster)
        );
        if !comparison.matches {
            return Ok(Exit::StalePlan);
        }
        if !migration_gate(&p) {
            return Ok(Exit::Failure);
        }
    }

    // Under `--on-error stop`, abort before applying anything when the dry run
    // reports a write that the cluster would reject.
    if doc.stops() && matches!(args.on_error, OnError::Stop) {
        eprintln!();
        eprintln!(
            "{}",
            output::red(
                "Deployment stopped before writing anything to the cluster: the dry run shows writes the cluster would refuse."
            )
        );
        for line in stop_advice(&doc) {
            eprintln!("{}", output::yellow(&line));
        }
        return Ok(Exit::Failure);
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
            Some(client) if has_skipped_jobs => ctx.runtime()?.block_on(async {
                let discovery = discovery::discover_resources(client)
                    .await
                    .map_err(|e| miette!("{e}"))?;
                Ok::<_, miette::Report>(
                    scheduler::failed_skipped_jobs(client, &discovery, p.checked.plan()).await,
                )
            })?,
            _ => Vec::new(),
        };
        // Under `--offline` there is no pre-confirm client, so let
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
            return Ok(Exit::Success);
        }
        if engine_decides {
            crate::say!(
                "{} nothing changed; Kix checks the live Jobs on the cluster and reruns any failed Job with {}",
                output::yellow("↻"),
                kix::manifest::keys::RERUN,
            );
        }
        if !failed_jobs.is_empty() {
            let names: Vec<String> = failed_jobs.iter().map(|r| r.to_string()).collect();
            crate::say!(
                "{} nothing changed, but {} Job(s) failed on the last run (a Job with {} runs again; any other is reported as failed): {}",
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
            return Err(output::refuse_unconfirmed(
                output::Unconfirmed::Deploy,
                &cluster,
            ));
        }
        output::progress_text("\nProceed with deploy? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            output::progress_text("Deploy cancelled.\n");
            return Ok(Exit::Success);
        }
    }

    let previous = if args.plan.offline {
        Previous::Unknown
    } else {
        match p.baseline.active() {
            Some(record) => Previous::Active(record.name.clone()),
            None => Previous::FirstDeploy,
        }
    };
    let global = ctx.global.clone();
    let end = ctx.runtime()?.block_on(run_deploy_async(
        args,
        &global,
        p.checked,
        &cluster,
        Some(&receipt),
        p.client,
        if args.plan.offline {
            active_hash.as_deref()
        } else {
            None
        },
        previous,
        sops,
    ))?;

    // Update the local activation cache only when this build's record became
    // current. Caching a build whose deploy left nodes unattempted would cause
    // soft `kix gc` to treat the live resources as garbage and the next
    // `--offline` plan to skip unapplied nodes.
    if end.current
        && p.build.is_local()
        && let Err(e) = kix::eval::store::save_activation_path(&cluster, &p.build.graph().built_via)
    {
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    Ok(Exit::failure_if(!end.succeeded))
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

/// Verify that the cached build used by `--offline` matches the
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
    context: Option<&str>,
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
    let cached = short(cached_hash);
    let next = match context {
        Some(context) => format!("kix deploy {cluster} --context {context}"),
        None => format!("kix deploy {cluster}"),
    };
    let Some(active) = active else {
        let (headline, label) = match context {
            Some(context) => (
                format!(
                    "cached build {cached} does not match context '{context}', which has no active deployment record"
                ),
                format!("Active on cluster ('{context}'):       none"),
            ),
            None => (
                format!(
                    "cached build {cached} does not match the cluster, which has no active deployment record"
                ),
                "Active on cluster:                     none".to_string(),
            ),
        };
        return Err(miette!(
            "{headline}\n  \
             Nothing was applied to the cluster.\n\n  \
             Planned offline against cached build:  {cached}\n  \
             {label}\n\n  \
             Why:\n    \
             Applying an offline plan built against {cached} when the cluster has no active deployment record would compare against the wrong baseline.\n\n  \
             Next:\n    \
             Run `{next}` without `--offline`."
        ));
    };
    let name = &active.name;
    let build = match (&active.identity_hash, &active.deployed_at) {
        (Some(h), Some(at)) if !at.is_empty() => format!(" (build {}, deployed at {at})", short(h)),
        (Some(h), _) => format!(" (build {})", short(h)),
        (None, Some(at)) if !at.is_empty() => format!(" (deployed at {at})"),
        (None, _) => String::new(),
    };
    let (headline, label) = match context {
        Some(context) => (
            format!(
                "cached build {cached} does not match the active deployment on context '{context}'"
            ),
            format!("Active on cluster ('{context}'):       {name}{build}"),
        ),
        None => (
            format!("cached build {cached} does not match the active deployment on the cluster"),
            format!("Active on cluster:                     {name}{build}"),
        ),
    };
    Err(miette!(
        "{headline}\n  \
         Nothing was applied to the cluster.\n\n  \
         Planned offline against cached build:  {cached}\n  \
         {label}\n\n  \
         Why:\n    \
         Applying a plan made against {cached} would compare against the wrong build: objects belonging to {name} could be treated as orphans and deleted.\n\n  \
         Next:\n    \
         Run `{next}` without `--offline`."
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
            "deployment record '{name}' already exists on the cluster for a different build\n  \
             Nothing was applied to the cluster.\n\n  \
             Existing record '{name}' on cluster:  {found}\n  \
             This build:                           {hash}\n\n  \
             Why:\n    \
             The record name '{name}' is written into this build, and the cluster already has a record with that name for another build hash.\n\n  \
             Next:\n    \
             Inspect the existing record on the cluster to see what created it:\n      \
             kubectl get {}/{name} -o yaml",
            kix::manifest::keys::ACTIVATIONS_CRD,
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
    // The caller made a client, so the runtime exists and this cannot fail.
    let Ok(runtime) = ctx.runtime() else {
        return;
    };
    let done = runtime.block_on(async {
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
    // The caller made a client, so the runtime exists and this cannot fail.
    let Ok(runtime) = ctx.runtime() else {
        return;
    };
    match runtime.block_on(list_nodes(client)) {
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

/// Return the height of the tui view that `KIX_TUI_HEIGHT` sets, or `None`
/// for the default.
fn tui_height() -> Option<u16> {
    let value = std::env::var("KIX_TUI_HEIGHT").ok()?;
    match value.trim().parse::<u16>() {
        Ok(rows) if rows > 0 => Some(rows),
        _ => {
            eprintln!(
                "{} KIX_TUI_HEIGHT is {value:?}, which is not a positive number of rows. Kix uses the default height. Set KIX_TUI_HEIGHT to a positive number of rows, or unset it.",
                output::yellow("warning:"),
            );
            None
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
    previous: Previous,
    sops: kix::build_source::SopsSources,
) -> Result<RunEnd> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse the pre-confirm client, which the plan ran the target checks
    // through, or connect now, run them, and filter orphans shared with
    // other Kix clusters.
    let client = match pre_client {
        Some(c) => c,
        None => {
            let client = client::make_client(global.context.as_deref())
                .await
                .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
            let connection = binding::Connection::of_context(global.context.as_deref());
            checked
                .target_checks()
                .run(&client, &connection)
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
    // `--offline` is used, planning reads the local cache without
    // contacting the cluster, so this is the first point that blocks pruning
    // retired CRDs and cascading their Activation records.
    let records = Records::open(target.client(), discovery)
        .map_err(|e| miette!("{e}"))?
        .into_records();

    if let Some(hash) = cached_baseline {
        let context = binding::Connection::of_context(global.context.as_deref());
        let context = match &context {
            binding::Connection::Context { name, .. } => name.as_deref(),
            binding::Connection::InCluster => None,
        };
        check_cached_baseline(records.as_ref(), cluster_name, hash, context).await?;
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
    let use_tui = args.log_format == LogFormat::Tui && interactive;
    let tui_driver = if use_tui {
        let axis = match args.group_by {
            GroupBy::Namespace => super::graph_stream::GroupAxis::Namespace,
            GroupBy::Package => super::graph_stream::GroupAxis::Package,
        };
        match super::graph_stream::GraphStreamDriver::spawn(
            cluster_name.to_string(),
            config.cancel.clone(),
            tui_height(),
            axis,
            super::graph_stream::GlyphStyle::detect(),
        ) {
            Ok(d) => Some(d),
            Err(e) => {
                eprintln!(
                    "{} {e}. Falling back to plain output",
                    output::yellow("warn: failed to start the tui view:"),
                );
                None
            }
        }
    } else {
        None
    };

    // In JSON log mode, emit a final NDJSON summary object instead of a text
    // summary line.
    let json_log = (tui_driver.is_none() && args.log_format == LogFormat::Json)
        .then(|| Arc::new(super::deploy_log::JsonObserver::new()));
    let observer: Arc<dyn DeployObserver> = match (&tui_driver, &json_log) {
        (Some(d), _) => d.observer(),
        (None, Some(json)) => json.clone(),
        (None, None)
            if matches!(args.log_format, LogFormat::Pretty | LogFormat::Tui) && interactive =>
        {
            Arc::new(StreamCliObserver {
                verbose: global.verbose > 0,
            })
        }
        (None, None) => Arc::new(super::deploy_log::LineObserver {
            verbose: global.verbose > 0,
        }),
    };

    let record = checked.activation_name().map(str::to_string);
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
        None if end.succeeded => {
            println!();
            println!("{}", summary_line(counts, false, true));
        }
        None => {
            let interrupted = match &result {
                Err(scheduler::DeployError::Cancelled { reason, .. }) => Some(reason.as_str()),
                _ => None,
            };
            let closing = Closing {
                cluster: cluster_name,
                record: record.as_deref(),
                previous,
                interrupted,
                current: end.current,
                on_error_continue: args.on_error == OnError::Continue,
            };
            println!();
            println!("{}", observer::closing(counts, &closing));
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

/// Report the stateful migrations the plan makes. Return false, after saying
/// why, when the deploy must stop because `--accept-migrations` is not set.
fn migration_gate(p: &kix::plan::Planned) -> bool {
    if p.migration_pairs.is_empty() {
        return true;
    }
    let pairs = plan::migrations::of_pairs(&p.migration_pairs);
    let prune = p.checked.flags().prune;
    if !p.checked.flags().accept_migrations {
        let fate = if prune {
            plan::migrations::SourceFate::Pruned
        } else {
            plan::migrations::SourceFate::Kept
        };
        let cluster = &p.build.graph().cluster_name;
        eprintln!();
        eprint!("{}", plan::migrations::stop(cluster, &pairs, fate));
        return false;
    }
    output::progress_text(&format!("\n{}", plan::migrations::accepted(&pairs, prune)));
    true
}

/// Say what to do about the writes the dry run says the cluster would refuse,
/// by the kind of refusal. `--on-error continue` is offered only when every
/// stop is a write the user fixes in the build, because it does not resolve
/// a conflict or bring a webhook back.
pub(super) fn stop_advice(doc: &kix::plan::document::Plan) -> Vec<String> {
    let conflicts = !doc.conflicts.items().is_empty();
    let webhooks = doc
        .admission
        .items()
        .iter()
        .any(|r| r.webhook_unreachable());
    let others = doc
        .admission
        .items()
        .iter()
        .any(|r| !r.webhook_unreachable())
        || doc
            .prune
            .items()
            .iter()
            .any(|p| p.fate == kix::plan::document::PruneFate::DeleteRefused);
    let mut lines = Vec::new();
    if conflicts {
        lines.push(
            "For each field ownership conflict, take the fields with --force-conflicts, or set `ownership.cede` on the resource to leave them to the other manager.".to_string(),
        );
    }
    if webhooks {
        lines.push(
            "For each webhook Kix could not reach, get its backend running again, for example by scaling its Deployment back up.".to_string(),
        );
    }
    if others {
        lines.push(if conflicts || webhooks {
            "Fix the other refused writes.".to_string()
        } else {
            "Fix the refused writes.".to_string()
        });
    }
    lines.push(if others && !conflicts && !webhooks {
        "Then deploy again, or rerun with --on-error continue to apply everything else.".to_string()
    } else {
        "Then deploy again.".to_string()
    });
    lines
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

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<Exit> {
    // Run the same plan and pre-flight checks as a direct deploy so invalid
    // builds are rejected before the Activation is submitted to the cluster.
    let Some(p) = prepare(&args.plan, operator_flags(flags_of(&args.plan)), ctx)? else {
        return Ok(Exit::Success);
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
                "to be deleted after the apply (the operator always prunes)"
            )
        );
        plan::print_shared(checked.shared_orphans());
    }
    // Enforce `--accept-migrations` on the CLI before delegating to the
    // non-interactive operator.
    if !p.migration_pairs.is_empty() && !args.plan.accept_migrations {
        let pairs = plan::migrations::of_pairs(&p.migration_pairs);
        let cluster = &p.build.graph().cluster_name;
        eprintln!();
        eprint!(
            "{}",
            plan::migrations::stop(
                cluster,
                &pairs,
                plan::migrations::SourceFate::OperatorPrunes
            )
        );
        return Ok(Exit::Failure);
    }
    let cluster = p.build.graph().cluster_name.clone();
    // A plan made from the local cache (`--offline`) did not
    // connect, so the target checks run once the command connects below.
    let target_checks = p
        .client
        .is_none()
        .then(|| p.checked.target_checks().clone());
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
            return Err(output::refuse_unconfirmed(
                output::Unconfirmed::Deploy,
                &cluster,
            ));
        }
        print!("\nDelegate deploy to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Deploy cancelled.");
            return Ok(Exit::Success);
        }
    }

    let global = ctx.global.clone();
    let source_path = result_path.display().to_string();

    let reconciled = ctx.runtime()?.block_on(async {
        let (client, records) =
            super::operator::connect_and_verify(global.context.as_deref()).await?;
        if let Some(checks) = &target_checks {
            let connection = binding::Connection::of_context(global.context.as_deref());
            checks
                .run(&client, &connection)
                .await
                .map_err(|e| miette!("{e}"))?;
        }

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

    Ok(Exit::failure_if(reconciled == Reconciled::Degraded))
}
