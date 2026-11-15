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
use kix::cluster::activation::Records;
use kix::cluster::apply::RerunReason;
use kix::cluster::binding;
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::{DeployObserver, DeployResult, NodeId};
use kix::plan::document::{AdmissionRefusal, Plan, PlanFlags, RefusalReason};
use kix::plan::{CheckedPlan, Connected, LastRuns, Planned, Start, Target, Work};

use super::CommandContext;
use super::operator::Reconciled;
use super::plan::{document, dry_run, flags_of, prepare, print_text, scheduler_config};

use self::observer::*;
pub(crate) use self::observer::{Previous, StreamCliObserver, held_back};
#[cfg(test)]
pub(crate) use self::saved_plan::ComparisonResponse;
use self::saved_plan::*;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<Exit> {
    refuse_operator_timeout(args)?;
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
    if saved.is_none() && !migration_gate(&p, Command::Deploy, Runner::Cli) {
        return Ok(Exit::Failure);
    }

    let doc = preview(&mut p, ctx)?;

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
        if !migration_gate(&p, Command::Deploy, Runner::Cli) {
            return Ok(Exit::Failure);
        }
    }

    // Under `--on-error continue` the run applies everything else.
    if args.on_error == OnError::Stop && refused(&doc, Command::Deploy) {
        return Ok(Exit::Failure);
    }

    let cluster = p.build.graph().cluster_name.clone();
    let active_hash = p.baseline.active_hash().map(str::to_string);

    // A plan made from the local cache (`--offline`) has not read its Jobs,
    // so it decides once the run connects.
    if let Some(connected) = &p.connected
        && !ctx
            .runtime()?
            .block_on(start(&connected.client, &p.checked, &connected.last_runs))
    {
        say_nothing_to_apply(&p.checked, active_hash.as_deref());
        return Ok(Exit::Success);
    }

    // Build the deployment receipt before confirmation so dirty source state
    // is visible in the prompt.
    let receipt = ctx.receipts.of_build(&p.build, &ctx.global.flake);

    print_warnings(&ctx.receipts.warnings(&receipt));

    // Check whether cluster nodes carry the labels referenced by topology
    // spread rules when a pre-confirm client is available.
    if let Some(client) = p.client()
        && !output::quiet()
    {
        report_topology_labels(ctx, client, p.new_manifests());
    }

    if !confirm(Command::Deploy, &cluster, args.yes)? {
        return Ok(Exit::Success);
    }

    let previous = if args.plan.offline {
        Previous::Unknown
    } else {
        match p.baseline.active() {
            Some(record) => Previous::Active(record.name.clone()),
            None => Previous::FirstDeploy,
        }
    };
    let options = RunOptions {
        timeout: parse_timeout(args.timeout.as_deref())?,
        on_error: args.on_error,
        log_format: args.log_format,
        group_by: args.group_by,
    };
    let cached_baseline = if args.plan.offline { active_hash } else { None };
    let end = run_planned(
        ctx,
        Command::Deploy,
        p,
        &options,
        Some(receipt),
        sops,
        previous,
        cached_baseline.as_deref(),
    )?;
    Ok(Exit::failure_if(!end.succeeded))
}

/// The command that runs a plan. `kix deploy` and `kix rollback` share every
/// step after the plan, and differ in the words they print and the flags
/// they offer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Command {
    Deploy,
    Rollback,
}

impl Command {
    /// Return the noun that starts the command's summary lines.
    pub(crate) fn noun(self) -> &'static str {
        match self {
            Command::Deploy => "Deploy",
            Command::Rollback => "Rollback",
        }
    }

    /// Return what a user types to run the command.
    pub(crate) fn invocation(self) -> &'static str {
        match self {
            Command::Deploy => "kix deploy",
            Command::Rollback => "kix rollback",
        }
    }

    /// Return whether the command takes `--on-error`, so its messages may
    /// suggest it.
    fn takes_on_error(self) -> bool {
        self == Command::Deploy
    }

    fn unconfirmed(self) -> output::Unconfirmed {
        match self {
            Command::Deploy => output::Unconfirmed::Deploy,
            Command::Rollback => output::Unconfirmed::Rollback,
        }
    }
}

/// How a run is carried out. `kix deploy` takes these as flags; `kix
/// rollback` uses [`RunOptions::rollback`].
pub(crate) struct RunOptions {
    pub timeout: Duration,
    pub on_error: OnError,
    pub log_format: LogFormat,
    pub group_by: GroupBy,
}

impl RunOptions {
    /// Return the settings of a rollback, which takes none of these flags.
    /// It stops at the first failure, because a rollback that goes on past
    /// one leaves the cluster between two builds.
    pub(crate) fn rollback() -> Self {
        RunOptions {
            timeout: readiness::DEFAULT_TIMEOUT,
            on_error: OnError::Stop,
            log_format: LogFormat::Pretty,
            group_by: GroupBy::Namespace,
        }
    }
}

/// Check the plan's writes with the apiserver as a dry run when Kix is
/// connected and the plan writes or prunes, then build the plan document and
/// print it. The dry run decrypts the build's SOPS Secrets, as the run does.
pub(crate) fn preview(p: &mut Planned, ctx: &CommandContext) -> Result<Plan> {
    let writes = p
        .checked
        .plan()
        .nodes()
        .iter()
        .any(|n| n.action.written().is_some());
    let report = match p.client() {
        Some(client) if writes || !p.checked.orphans().is_empty() => {
            let client = client.clone();
            Some(dry_run(p, false, client, ctx)?)
        }
        _ => None,
    };
    let doc = document(p, report.as_ref(), false);
    if !output::quiet() {
        print_text(p, &doc, ctx.global.verbose > 0);
    }
    Ok(doc)
}

/// Return true, after saying why and what to do, when the dry run in `doc`
/// shows writes the cluster would refuse, so `command` stops before it
/// writes anything.
pub(crate) fn refused(doc: &Plan, command: Command) -> bool {
    if !doc.stops() {
        return false;
    }
    eprintln!();
    eprintln!(
        "{}",
        output::red(&format!(
            "{} stopped: one or more changes failed the dry run. Nothing was applied to the cluster.",
            command.noun()
        ))
    );
    for line in stop_advice(doc, command) {
        eprintln!("{}", output::yellow(&line));
    }
    true
}

/// Ask whether to go on with `command` on `cluster`, unless `yes` is set,
/// and return false when the user declines. Refuse when no one can answer.
pub(crate) fn confirm(command: Command, cluster: &str, yes: bool) -> Result<bool> {
    if yes {
        return Ok(true);
    }
    if !output::is_interactive() {
        return Err(output::refuse_unconfirmed(command.unconfirmed(), cluster));
    }
    output::progress_text(&format!(
        "\nProceed with {}? [y/N] ",
        command.noun().to_lowercase()
    ));
    std::io::stdout().flush().into_diagnostic()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).into_diagnostic()?;
    let input = input.trim().to_lowercase();
    if input != "y" && input != "yes" {
        output::progress_text(&format!(
            "{} cancelled. Nothing was applied to the cluster.\n",
            command.noun()
        ));
        return Ok(false);
    }
    Ok(true)
}

/// Run the plan of `p` for `command` with `options`, print how the run
/// ended, and save the build as this machine's copy of the cluster's build
/// once the run's record became current. `receipt` is the provenance the
/// record gets; a rollback passes `None` and keeps the receipt its target
/// record already has. `cached_baseline` is the identity hash an
/// `--offline` plan was made against.
#[allow(clippy::too_many_arguments)]
pub(crate) fn run_planned(
    ctx: &CommandContext,
    command: Command,
    p: Planned,
    options: &RunOptions,
    receipt: Option<Value>,
    sops: kix::build_source::SopsSources,
    previous: Previous,
    cached_baseline: Option<&str>,
) -> Result<RunEnd> {
    let cluster = p.build.graph().cluster_name.clone();
    let global = ctx.global.clone();
    let end = ctx.runtime()?.block_on(run_deploy_async(
        command,
        options,
        &global,
        p.checked,
        &cluster,
        receipt,
        p.connected,
        cached_baseline,
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
    Ok(end)
}

/// Decide whether a deploy or a rollback of `checked` starts its run, and
/// return true when it does ([`CheckedPlan::start`]). With nothing to do,
/// say how many failed deploy records were marked Superseded; the caller
/// says that nothing was applied. When only Jobs remain, say why the run
/// still starts.
pub(crate) async fn start(
    client: &kube::Client,
    checked: &CheckedPlan,
    last_runs: &LastRuns,
) -> bool {
    match checked.start(client, last_runs).await {
        Start::Nothing { superseded } => {
            if superseded > 0 {
                crate::say!(
                    "  {} Marked {superseded} earlier failed deployment record(s) Superseded (nothing left to change).",
                    output::dim("="),
                );
            }
            false
        }
        Start::Run => {
            if checked.work(last_runs) == Work::JobsOnly {
                say_failed_jobs(last_runs);
            }
            true
        }
    }
}

/// Say why a run whose plan writes and prunes nothing still starts:
/// `last_runs` lists the unchanged Jobs whose last run failed, or says Kix
/// could not read every Job.
fn say_failed_jobs(last_runs: &LastRuns) {
    match last_runs {
        LastRuns::Read { failed } if failed.is_empty() => {}
        LastRuns::Read { failed } => {
            let names: Vec<String> = failed.iter().map(|r| r.to_string()).collect();
            crate::say!(
                "{} nothing changed, but {} Job(s) failed on the last run and are reported as failed: {}",
                output::yellow("↻"),
                failed.len(),
                names.join(", "),
            );
        }
        LastRuns::Unreadable => crate::say!(
            "{} nothing changed; Kix checks the live Jobs during the deploy, reruns any failed Job with {}, and reports any other failed Job",
            output::yellow("↻"),
            kix::manifest::keys::RERUN,
        ),
    }
}

/// Run `checked` against `target` for `kix deploy` or `kix rollback`, and
/// keep this machine's copy of the kept orphans in step with what the run's
/// finalize wrote for Kix cluster `cluster`. An interrupt cancels the run,
/// which then marks its Activation record Failed instead of leaving it
/// Deploying.
pub(crate) async fn run_plan(
    checked: CheckedPlan,
    target: Target,
    receipt: Option<Value>,
    config: SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
    cluster: &str,
) -> (Result<DeployResult, scheduler::DeployError>, RunEnd) {
    crate::interrupt::cancel_on_interrupt(&config.cancel);
    let (result, kept) = checked.run(target, receipt, config, observer).await;
    if let Some(recorded) = kept {
        kix::plan::baseline::sync_kept_roots(cluster, &recorded);
    }
    let end = RunEnd::of(&result);
    (result, end)
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

/// Say that the deploy has nothing to apply, and whether its build is the
/// one the record `active_hash` names.
fn say_nothing_to_apply(checked: &CheckedPlan, active_hash: Option<&str>) {
    match (checked.activation_identity_hash(), active_hash) {
        (Some(new), Some(old)) if new == old => crate::say!(
            "{} activation identical to active ({}...). Nothing to apply.",
            output::dim("="),
            &new[..8.min(new.len())],
        ),
        _ => crate::say!("Nothing to apply."),
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
    command: Command,
    options: &RunOptions,
    global: &crate::cli::GlobalArgs,
    mut checked: CheckedPlan,
    cluster_name: &str,
    receipt: Option<Value>,
    connected: Option<Connected>,
    cached_baseline: Option<&str>,
    previous: Previous,
    sops: kix::build_source::SopsSources,
) -> Result<RunEnd> {
    // Reuse the pre-confirm client, which the plan ran the target checks
    // through and read the Jobs with, or connect now, run the checks, filter
    // orphans shared with other Kix clusters, and read the Jobs.
    let (client, offline_runs) = match connected {
        Some(c) => (c.client, None),
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
            // The plan read the cache, so it learns the last runs of its
            // Jobs only now.
            let last_runs = checked
                .read_last_runs(&client)
                .await
                .map_err(|e| miette!("{e}"))?;
            plan::print_reruns(checked.plan(), &[RerunReason::LastRunFailed]);
            (client, Some(last_runs))
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

    // A plan made without connecting (`--offline`) learns only now whether
    // it has anything to do: it had not read its Jobs, and orphans another
    // Kix cluster deploys were still in its prune.
    if let Some(last_runs) = &offline_runs
        && !start(target.client(), &checked, last_runs).await
    {
        say_nothing_to_apply(&checked, cached_baseline);
        return Ok(RunEnd {
            succeeded: true,
            current: false,
        });
    }

    refuse_before_writing(&checked, records.as_ref(), discovery).await?;

    let on_error = match options.on_error {
        OnError::Stop => OnErrorPolicy::Stop,
        OnError::Continue => OnErrorPolicy::Continue,
    };

    let config = scheduler_config(options.timeout, on_error, command.takes_on_error());

    let interactive = output::is_interactive();
    let use_tui = options.log_format == LogFormat::Tui && interactive;
    let tui_driver = if use_tui {
        let axis = match options.group_by {
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
    let json_log = (tui_driver.is_none() && options.log_format == LogFormat::Json)
        .then(|| Arc::new(super::deploy_log::JsonObserver::new()));
    let observer: Arc<dyn DeployObserver> = match (&tui_driver, &json_log) {
        (Some(d), _) => d.observer(),
        (None, Some(json)) => json.clone(),
        (None, None)
            if matches!(options.log_format, LogFormat::Pretty | LogFormat::Tui) && interactive =>
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
    let (result, end) = run_plan(checked, target, receipt, config, observer, cluster_name).await;

    // Drop the TUI before printing the summary so it lands in normal scrollback.
    drop(tui_driver);

    let counts = match &result {
        Ok(r) => r,
        Err(e) => e.partial(),
    };
    match &json_log {
        Some(json) => json.summary(counts, false, end.succeeded),
        None if end.succeeded => {
            println!();
            println!("{}", summary_line(counts, command, true));
        }
        None => {
            let interrupted = match &result {
                Err(scheduler::DeployError::Cancelled { reason, .. }) => Some(reason.as_str()),
                _ => None,
            };
            let closing = Closing {
                command,
                cluster: cluster_name,
                record: record.as_deref(),
                previous,
                interrupted,
                current: end.current,
                on_error_continue: options.on_error == OnError::Continue,
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

/// What carries out a run: this command, or the Kix operator, which always
/// prunes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Runner {
    Cli,
    Operator,
}

/// Report the stateful migrations the plan makes. Return false, after saying
/// why, when `command` must stop because `--accept-migrations` is not set.
/// `kix deploy` and `kix rollback` stop the same way.
pub(crate) fn migration_gate(p: &kix::plan::Planned, command: Command, runner: Runner) -> bool {
    if p.migration_pairs.is_empty() {
        return true;
    }
    let pairs = plan::migrations::of_pairs(&p.migration_pairs);
    let prune = p.checked.flags().prune == PrunePolicy::Delete;
    if !p.checked.flags().accept_migrations {
        let fate = match runner {
            Runner::Operator => plan::migrations::SourceFate::OperatorPrunes,
            Runner::Cli if prune => plan::migrations::SourceFate::Pruned,
            Runner::Cli => plan::migrations::SourceFate::Kept,
        };
        let cluster = &p.build.graph().cluster_name;
        eprintln!();
        eprint!("{}", plan::migrations::stop(cluster, &pairs, fate, command));
        return false;
    }
    output::progress_text(&format!("\n{}", plan::migrations::accepted(&pairs, prune)));
    true
}

/// Say what to do about the writes the dry run says the cluster would refuse,
/// by the kind of refusal. `--on-error continue` is offered only when every
/// stop is a write the user fixes in the build, because it does not resolve
/// a conflict or bring a webhook back.
pub(super) fn stop_advice(doc: &Plan, command: Command) -> Vec<String> {
    let conflicts = !doc.conflicts.items().is_empty();
    let unreachable = |r: &AdmissionRefusal| r.reason == RefusalReason::WebhookUnreachable;
    let webhooks = doc.admission.items().iter().any(unreachable);
    let others = doc.admission.items().iter().any(|r| !unreachable(r))
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
    let again = match command {
        Command::Deploy => "Then deploy again",
        Command::Rollback => "Then roll back again",
    };
    lines.push(
        if others && !conflicts && !webhooks && command.takes_on_error() {
            format!("{again}, or rerun with --on-error continue to apply everything else.")
        } else {
            format!("{again}.")
        },
    );
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

/// Force [`PrunePolicy::Delete`] for operator deploys so pre-flight checks
/// validate all orphan deletions that the operator will perform.
pub(super) fn operator_flags(flags: PlanFlags) -> PlanFlags {
    PlanFlags {
        prune: PrunePolicy::Delete,
        ..flags
    }
}

/// The id of the change record that made `--operator --timeout` an error.
const OPERATOR_TIMEOUT_ID: &str = "K7218";

/// Refuse `--timeout` with `--operator`. The CLI does not send it to the
/// operator, which waits with its own readiness timeout.
fn refuse_operator_timeout(args: &DeployArgs) -> Result<()> {
    if args.operator && args.timeout.is_some() {
        return Err(miette!(
            "[{OPERATOR_TIMEOUT_ID}] `kix deploy --operator` does not accept `--timeout`. The Kix operator uses a fixed 300-second readiness timeout for each resource. Nothing was applied to the cluster. Remove `--timeout` to deploy with the operator, or remove `--operator` to use `--timeout`."
        ));
    }
    Ok(())
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
        plan::print_checked(
            checked,
            "to be deleted after the apply (the operator always prunes)",
            ctx.global.verbose > 0,
        );
        plan::print_shared(checked.shared_orphans());
    }
    // Enforce `--accept-migrations` on the CLI before delegating to the
    // non-interactive operator.
    if !migration_gate(&p, Command::Deploy, Runner::Operator) {
        return Ok(Exit::Failure);
    }
    let cluster = p.build.graph().cluster_name.clone();
    // A plan made from the local cache (`--offline`) did not
    // connect, so the target checks run once the command connects below.
    let target_checks = p
        .connected
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
        super::operator::require_requests(&client).await?;
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

        let request = super::operator::apply_activation(
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
            super::operator::watch_activation_progress(&records, &activation_name, &request)
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

    // Save the activation path for the next deploy's diff; both `Active` and
    // `Degraded` records are current.
    if let Err(e) = kix::eval::store::save_activation_path(&cluster, &result_path) {
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    Ok(Exit::failure_if(reconciled == Reconciled::Degraded))
}
