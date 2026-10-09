//! Build, plan, and deploy a cluster activation.
//!
//! The plan is `kix plan`'s: [`super::plan::prepare`] builds and runs
//! [`kix::plan::Planner`], which compares the build with the closures the
//! cluster runs by K8s identity (kind+ns+name) and identity hash, without
//! querying the live objects. This module shows the plan, confirms, applies
//! the dependency graph, and prunes authorized orphans in reverse dependency
//! order.

use std::io::Write;
use std::sync::Arc;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::activation::{OpenedRecords, Records};
use kix::cluster::apply::{ApplyAction, ChangeAction};
use kix::cluster::fetch;
use kix::cluster::migrate::MigrationPair;
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeId, TransitionKind,
    Verdict,
};
use kix::cluster::watchdog::StallPolicy;
use kix::manifest::types::ResourceId;
use kix::plan::document::PlanFlags;
use kix::plan::{CheckedPlan, Target};

use crate::cli::{DeployArgs, Detail, OnError, PlanArgs};
use crate::output;
use crate::plan;

use super::CommandContext;
use super::operator::Reconciled;
use super::plan::{document, dry_run, flags_of, prepare, print_text};

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    let saved = match &args.saved_plan {
        Some(path) => Some(load_saved_plan(path, &flags_of(&args.plan))?),
        None => None,
    };
    // A dry run is the plan, made by the same code with the same flags.
    if args.dry_run {
        return match &saved {
            Some(s) => check_saved_plan(s, &args.plan, ctx),
            None => super::plan::run(&args.plan, Detail::Plain, ctx),
        };
    }
    if args.operator {
        return run_operator(args, ctx);
    }

    // The apply reads the planning flags from here and never from
    // `args.plan`, so under `--plan` it does what the reviewed plan does.
    let flags = saved.as_ref().map_or(flags_of(&args.plan), |s| s.flags);
    let Some(mut p) = prepare(&args.plan, flags, ctx)? else {
        return Ok(());
    };
    // A deploy decrypts the SOPS files for real, after review.
    let sops = p.sops_sources(false).map_err(|e| miette!("{e}"))?;
    p.annotate_record(&args.record_annotations)
        .map_err(|e| miette!("{e}"))?;

    // Detect stateful migration pairs and require --accept-migrations.
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
    let doc = document(&mut p, report.as_ref(), Detail::Plain);

    if !ctx.global.quiet {
        print_text(&p, &doc, ctx.global.verbose > 0);
    }

    // A reviewed plan that no longer matches applies nothing.
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

    let cluster = p.build.graph().cluster_name.clone();
    let active_hash = p.baseline.active_hash().map(str::to_string);

    // Imports are applied like any other resource (SSA); readiness polls the
    // cluster for the described resource via `wait_for_import_target`, which
    // is triggered when the import node becomes eligible under the DAG.

    if total_apply == 0 && p.checked.orphans().is_empty() {
        // An unchanged plan can still owe a run: a probe Job under
        // `kix.run/rerun` whose last run failed (the failure kept the
        // activation from switching, so the next deploy sees the same
        // hashes). The engine's Skip path recreates it, but only if the
        // engine runs.
        let has_reruns = p.checked.plan().nodes().iter().any(|n| n.rerun.is_some());
        let failed_reruns = match &p.client {
            Some(client) if has_reruns => ctx.runtime.block_on(async {
                let discovery = fetch::discover_resources(client)
                    .await
                    .map_err(|e| miette!("{e}"))?;
                Ok::<_, miette::Report>(
                    scheduler::failed_rerun_nodes(client, &discovery, p.checked.plan()).await,
                )
            })?,
            _ => Vec::new(),
        };
        // Without a client here (`--current-activation`) the engine's Skip
        // path makes the call instead: it reads the live objects itself.
        let engine_decides = p.client.is_none() && has_reruns;
        if failed_reruns.is_empty() && !engine_decides {
            // A folded-in record still has to be superseded, even when its
            // closure turned out to differ from the plan only in things
            // nothing prunes (a Namespace, the record itself). The engine
            // never runs on this path, and `finalize_deploy` is where records
            // are normally consumed, so do it here or report the same failed
            // deploy on every deploy from now on.
            if let Some(client) = &p.client {
                supersede_consumed(ctx, client, &p.baseline.failed().consumed, ctx.global.quiet);
            }
            if !ctx.global.quiet {
                match (p.checked.activation_identity_hash(), active_hash.as_deref()) {
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
    let receipt = ctx.receipts.of_build(&p.build, &ctx.global.flake);

    if !ctx.global.quiet {
        print_warnings(&ctx.receipts.warnings(&receipt));
    }

    // The nodes: do they carry the labels the plan's placement rules name?
    // Only when a connection already exists: --current-activation is the
    // no-cluster-before-confirm mode.
    if let Some(client) = &p.client
        && !ctx.global.quiet
    {
        report_topology_labels(ctx, client, p.new_manifests());
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

    // Save activation path for next deploy's diff and for soft `kix gc`.
    // Only when this build's record became current. A cache that names a
    // build the cluster does not run (a run that left nodes unattempted)
    // makes soft gc treat the current closure as garbage, and makes the next
    // `--current-activation` plan skip the nodes this run never applied.
    if end.current
        && p.build.is_local()
        && let Err(e) =
            kix::eval::store::save_activation_path(&cluster, &p.build.graph().result_dir)
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

/// Exit status of `kix deploy --plan` when the reviewed plan no longer
/// matches.
const EXIT_STALE: i32 = 4;

/// A reviewed plan read for `kix deploy --plan`, with the planning flags the
/// deploy uses.
struct SavedPlan {
    path: String,
    /// [`kix::plan::saved::digest`] of the file as read.
    sha256: String,
    reviewed: kix::plan::document::Plan,
    flags: PlanFlags,
}

/// Read a saved plan and take its planning flags. Fails before any build
/// when the plan cannot be used or the flags `given` on the command line
/// contradict its flags.
fn load_saved_plan(path: &std::path::Path, given: &PlanFlags) -> Result<SavedPlan> {
    let bytes =
        std::fs::read(path).map_err(|e| miette!("cannot read the plan {}: {e}", path.display()))?;
    let reviewed: kix::plan::document::Plan = serde_json::from_slice(&bytes)
        .map_err(|e| miette!("{} is not a Kix plan document: {e}", path.display()))?;
    if let Some(why) = kix::plan::saved::unusable(&reviewed) {
        return Err(miette!("cannot deploy from {}: {why}", path.display()));
    }
    let flags = kix::plan::saved::flags_for(&reviewed, given)
        .map_err(|e| miette!("cannot deploy from {}: {e}", path.display()))?;
    Ok(SavedPlan {
        path: path.display().to_string(),
        sha256: kix::plan::saved::digest(&bytes),
        reviewed,
        flags,
    })
}

/// `kix deploy --plan <file> --dry-run`: plan again, compare, and exit 0
/// when the reviewed plan matches or [`EXIT_STALE`] when not.
/// The dry run always runs when connected, as `kix plan` does.
fn check_saved_plan(saved: &SavedPlan, args: &PlanArgs, ctx: &mut CommandContext) -> Result<()> {
    let format = ctx.output_format(crate::cli::OutputFormat::Text);
    if format != crate::cli::OutputFormat::Text {
        output::progress_to_stderr();
    }
    let Some(mut p) = prepare(args, saved.flags, ctx)? else {
        return Ok(());
    };
    let report = match p.client.clone() {
        Some(client) => Some(dry_run(&mut p, false, client, ctx)?),
        None => None,
    };
    let doc = document(&mut p, report.as_ref(), Detail::Plain);
    let mut comparison = kix::plan::saved::compare(&saved.reviewed, &doc);
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
            plan::render::render_comparison(&comparison, &saved.reviewed, &saved.path)
        ),
    }
    if !comparison.matches {
        std::process::exit(EXIT_STALE);
    }
    // A matching plan can still be one the deploy stops on, as `kix plan`
    // exits 3 for: a refused write, or migrations not accepted.
    let migrations_refused = !doc.migrations.items().is_empty() && !saved.flags.accept_migrations;
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

/// Refuse a `--current-activation` plan whose cached build is not the Active
/// build of `cluster` in the context this run connected to.
///
/// The activation cache is keyed by cluster name alone, so another context
/// that deploys a cluster of the same name can have written it. A plan made
/// against that build computes another environment's objects as orphans,
/// and the prune deletes by name. The plan has already been confirmed, so
/// this refuses rather than planning again from the cluster's record.
async fn check_cached_baseline(
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

/// Refuse, before anything is written, what would go wrong part way through
/// the run: an Activation record of this name that belongs to another build,
/// and objects the engine would refuse for a missing namespace. Deploy and
/// rollback both run it once connected.
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

/// Refuse a record name the cluster already has for another build.
async fn refuse_name_taken(records: &Records, name: &str, hash: &str) -> Result<()> {
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

/// The engine would refuse each of these on its own, part way through the
/// run; refusing here applies nothing.
fn refuse_namespaceless(
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
    if done > 0 && !quiet {
        println!(
            "  {} {done} failed deploy record(s) had nothing left to reconcile; marked superseded",
            output::dim("="),
        );
    }
}

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

/// `checked` is the plan, with the prune policy and conflict handling of
/// the flags it was checked with: `args.plan`'s, or a saved plan's under
/// `--plan`. The apply never reads `args.plan`'s flags, so it does what the
/// plan it was compared on does.
#[allow(clippy::too_many_arguments)]
async fn run_deploy_async(
    args: &DeployArgs,
    global: &crate::cli::GlobalArgs,
    mut checked: CheckedPlan,
    cluster_name: &str,
    receipt: Option<&Value>,
    pre_client: Option<kube::Client>,
    cached_baseline: Option<&str>,
    sops: kix::cluster::secrets::SopsSources,
) -> Result<RunEnd> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse pre-established connection or create a new one. A plan made
    // without one has not checked its orphans against other Kix clusters.
    let client = match pre_client {
        Some(c) => c,
        None => {
            let client = fetch::make_client(global.context.as_deref())
                .await
                .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
            let (_, shared) =
                kix::plan::keep_shared(&client, cluster_name, checked.orphans().to_vec())
                    .await
                    .map_err(|e| miette!("{e}"))?;
            checked.keep_shared(&shared);
            if !global.quiet {
                plan::print_shared(&shared);
            }
            client
        }
    };

    let target = Target::connect(client, sops)
        .await
        .map_err(|e| miette!("{e}"))?;
    let discovery = target.discovery();

    // The gate, again, here. `Baseline::of_cluster` opens the records too,
    // but `--current-activation` reads the previous build from the local
    // cache and never contacts the cluster before this point. Without this
    // that flag skips the gate, and with `--prune` the deploy would compute
    // the retired CRDs as orphans and delete them, which cascades away every
    // Activation record on the cluster.
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
    };
    // Ctrl-C and SIGTERM now have to reach the engine: the record exists from
    // the start of the run, so a process that just dies leaves it Deploying.
    config.cancel.cancel_on_interrupt();

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

    let (result, kept) = checked
        .run(target, receipt.cloned(), config, observer)
        .await;

    // Tear down the TUI before the summary prints so it lands in normal
    // scrollback below the history lines.
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
                "{} {} orphaned resources kept (warn-only; {})",
                output::bold("prune:"),
                resources.len(),
                plan::KEPT_ORPHANS_HINT,
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

/// The planning flags of an operator deploy. The operator always prunes, so
/// the objects check treats every orphan as deleted, as the operator will.
fn operator_flags(flags: PlanFlags) -> PlanFlags {
    PlanFlags {
        prune: true,
        prune_mode: None,
        ..flags
    }
}

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    // The plan and the objects check of the direct path. The operator plans
    // again against the live objects, but a build whose plan hides an
    // object is refused here, before it reaches the cluster.
    let Some(p) = prepare(&args.plan, operator_flags(flags_of(&args.plan)), ctx)? else {
        return Ok(());
    };
    let checked = &p.checked;
    let activation_name = checked
        .activation_name()
        .map(str::to_string)
        .ok_or_else(|| miette!("no Activation resource found in cluster manifests"))?;
    if !ctx.global.quiet {
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
    let cluster = p.build.graph().cluster_name.clone();
    let activation_identity_hash = p.checked.activation_identity_hash().map(str::to_string);
    let build = p.build;
    let result_path = build.graph().result_dir.clone();

    // The receipt, same as the direct path. The operator has no source tree,
    // so provenance is computed here and written onto the Activation when it
    // is applied.
    let receipt = ctx.receipts.of_build(&build, &ctx.global.flake);
    if !ctx.global.quiet {
        print_warnings(&ctx.receipts.warnings(&receipt));
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
        let (_, records) =
            super::operator::connect_and_verify(global.context.as_deref(), global.quiet).await?;

        if !global.quiet {
            println!(
                "Applying Activation CR '{}' (source: {})...",
                output::bold(&activation_name),
                output::dim(&source_path),
            );
        }

        super::operator::apply_activation(
            &records,
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

        let reconciled =
            super::operator::watch_activation_progress(&records, &activation_name, global.quiet)
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

/// Print `lines` after a blank line, if there are any.
fn print_warnings(lines: &[String]) {
    if lines.is_empty() {
        return;
    }
    println!();
    for line in lines {
        println!("{line}");
    }
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
    use crate::cli::{Cli, Command};
    use clap::Parser;
    use kix::cluster::scheduler::PrunePolicy;

    fn prune_policy(extra: &[&str]) -> PrunePolicy {
        let argv = [&["kix", "deploy", "x"][..], extra].concat();
        let Command::Deploy(args) = Cli::try_parse_from(argv).expect("args parse").command else {
            unreachable!()
        };
        super::flags_of(&args.plan).prune_policy()
    }

    #[test]
    fn prune_policy_follows_the_flags() {
        assert_eq!(prune_policy(&[]), PrunePolicy::WarnOnly);
        assert_eq!(prune_policy(&["--prune"]), PrunePolicy::Delete);
        assert_eq!(
            prune_policy(&["--prune", "--prune-mode", "default"]),
            PrunePolicy::Delete
        );
        assert_eq!(
            prune_policy(&["--prune-mode", "default"]),
            PrunePolicy::WarnOnly
        );
        assert_eq!(
            prune_policy(&["--prune", "--prune-mode", "no"]),
            PrunePolicy::Skip
        );
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
mod cached_baseline_tests {
    use super::*;
    use kix::cluster::activation::PHASE_ACTIVE;
    use kix::cluster::fake_api::FakeApi;
    use kix::manifest::keys;
    use kix::manifest::lifecycle;
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

    /// A cached build of another context's cluster `a` (hash `p9`) is
    /// refused against this context's Active record (`a2`), and so is any
    /// cached build when the context has no Active record for the cluster.
    #[tokio::test]
    async fn a_cached_build_must_be_the_contexts_active_build() {
        let api = FakeApi::new([record("a", "a2", PHASE_ACTIVE)]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let records = Records::open(&client, &discovery).unwrap().into_records();
        let records = records.as_ref();
        assert!(check_cached_baseline(records, "a", "a2").await.is_ok());
        let err = check_cached_baseline(records, "a", "p9")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("Active build is a2"), "{err}");
        let err = check_cached_baseline(records, "b", "p9")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("no Active record"), "{err}");
    }

    /// A record name the cluster has for another build is refused; the same
    /// build's, or an unknown name, is not.
    #[tokio::test]
    async fn a_record_name_held_by_another_build_is_refused() {
        let api = FakeApi::new([record("a", "a2", PHASE_ACTIVE)]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let records = Records::open(&client, &discovery)
            .unwrap()
            .into_records()
            .unwrap();
        assert!(refuse_name_taken(&records, "rec-a2", "a2").await.is_ok());
        assert!(refuse_name_taken(&records, "rec-new", "n1").await.is_ok());
        let err = refuse_name_taken(&records, "rec-a2", "n1")
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("identity hash a2, this build is n1"), "{err}");
    }

    /// A namespaced object without a namespace is refused before the run.
    #[tokio::test]
    async fn an_object_without_its_namespace_is_refused() {
        let api = FakeApi::new([]);
        let discovery = fetch::discover_resources(&api.client()).await.unwrap();
        let plan = kix::cluster::scheduler::DeployPlan::applying(&[json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "c" },
        })]);
        let err = refuse_namespaceless(&discovery, &plan)
            .unwrap_err()
            .to_string();
        assert!(err.contains("ConfigMap"), "{err}");
    }
}

#[cfg(test)]
mod run_end_tests {
    use super::*;
    use kix::cluster::scheduler::{DeployPlan, PrunePolicy};
    use kix::cluster::scripted::{ApplyFailure, Behaviour, NodeScript, ScriptedOps};
    use kix::cluster::stream::NullObserver;
    use kix::manifest::keys;
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

    /// A run's engine settings and its prune policy.
    struct Settings {
        config: SchedulerConfig,
        prune: PrunePolicy,
    }

    fn config(on_error: OnErrorPolicy, prune: PrunePolicy) -> Settings {
        Settings {
            config: SchedulerConfig {
                timeout: Duration::from_secs(300),
                on_error,
                cancel: kix::cluster::cancel::CancelToken::new(),
                concurrency: scheduler::CONCURRENCY,
                stall: StallPolicy::off(),
                rerun_failed: true,
            },
            prune,
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
        settings: &Settings,
    ) -> std::result::Result<DeployResult, scheduler::DeployError> {
        scheduler::run_scripted(
            ops.clone(),
            DeployPlan::applying(manifests),
            orphans,
            old,
            settings.prune,
            &settings.config,
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

#[cfg(test)]
mod operator_tests {
    use super::*;
    use crate::cli::{Cli, Command};
    use clap::Parser;
    use kix::cluster::scheduler::PrunePolicy;

    /// The operator always prunes, so an operator deploy's check holds every
    /// delete to the plan, whatever the prune flags say.
    #[test]
    fn an_operator_deploy_is_checked_as_one_that_prunes() {
        for extra in [&[][..], &["--prune-mode", "no"][..]] {
            let argv = [&["kix", "deploy", "x", "--operator"][..], extra].concat();
            let Command::Deploy(args) = Cli::try_parse_from(argv).expect("args parse").command
            else {
                unreachable!()
            };
            let flags = operator_flags(flags_of(&args.plan));
            assert_eq!(flags.prune_policy(), PrunePolicy::Delete, "{extra:?}");
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
}
