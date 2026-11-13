//! Revert to a Superseded activation.
//!
//! Finds the previous activation on the cluster, resolves its store path,
//! and re-applies its manifests through the standard reconcile engine.
//! No Nix build is required because the target activation's manifests are already
//! in the local Nix store.

use std::collections::HashSet;
use std::io::Write;
use std::sync::Arc;

use miette::{IntoDiagnostic, Result, miette};

use crate::client;
use kix::build_source::SopsSources;
use kix::cluster::activation::{Record, Records};
use kix::cluster::apply::ChangeAction;
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::cluster::preview::{DryRunOutcome, Refusal};
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::{DeployObserver, DeployResult, NullObserver};
use kix::cluster::watchdog::StallPolicy;
use kix::manifest::types::ResourceId;
use kix::plan::baseline::{self, Baseline};
use kix::plan::document::PlanFlags;
use kix::plan::{CheckedPlan, PlanEvent, Planner, Target};

use crate::cli::{OutputFormat, RollbackArgs};
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &RollbackArgs, ctx: &mut CommandContext) -> Result<()> {
    let lookup = if args.list {
        super::Lookup::ReadOnly
    } else {
        super::Lookup::Mutating
    };
    let cluster = ctx.cluster_identity(&args.cluster, lookup)?;
    if args.list {
        return ctx.runtime.block_on(run_list_async(&cluster, ctx));
    }
    if args.operator {
        return ctx
            .runtime
            .block_on(run_operator_async(args, &cluster, ctx));
    }
    ctx.runtime.block_on(run_async(args, &cluster, ctx))
}

/// Connect to the cluster, list superseded activations, and print the rollback
/// history.
///
/// Works identically for operator-managed and direct-apply clusters because it
/// only inspects `Activation` CRs.
async fn run_list_async(cluster: &str, ctx: &CommandContext) -> Result<()> {
    let client = client::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let discovery = discovery::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    let records = Records::open_installed(&client, &discovery).map_err(|e| miette!("{e}"))?;

    let current = records.active(cluster).await.map_err(|e| miette!("{e}"))?;

    // Include only activations that actually ran on the cluster. A deploy that
    // stopped partway through is marked Superseded once a later deploy folds
    // its leftovers in, so rolling back to it would apply a partial state.
    let superseded = records
        .rollback_targets(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;

    let format = output::format();
    match format {
        OutputFormat::Json | OutputFormat::Yaml => {
            let value = serde_json::json!({
                "cluster": cluster,
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
                            kix::eval::store::resolve_activation_by_hash(cluster, h)
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
                print!("{}", kix::yaml::to_string(&value).into_diagnostic()?);
            } else {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&value).into_diagnostic()?
                );
            }
        }
        OutputFormat::Text | OutputFormat::Markdown => {
            print_history_text(cluster, current.as_ref(), &superseded);
        }
    }

    Ok(())
}

fn print_history_text(cluster: &str, current: Option<&Record>, superseded: &[Record]) {
    println!(
        "{} deployment history for '{}'",
        output::bold("Rollback:"),
        cluster,
    );
    println!();

    if let Some(c) = current {
        let hash_preview = c
            .identity_hash
            .as_deref()
            .map(|h| format!("build {}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no build hash".to_string());
        println!(
            "  {} {} ({})  {}",
            output::green("● current "),
            output::bold(&c.name),
            hash_preview,
            output::dim("← live on the cluster"),
        );
        if let Some(path) = c.built_via.as_deref() {
            println!("    {} {}", output::dim("build:   "), output::dim(path));
        }
        println!();
    }

    if superseded.is_empty() {
        println!(
            "{}",
            output::dim(&format!(
                "No earlier deployments recorded for '{cluster}'. Nothing to roll back to."
            ))
        );
        return;
    }

    println!(
        "  {}",
        output::bold("Earlier deployments (most recent first):")
    );
    println!();
    for (i, s) in superseded.iter().enumerate() {
        let hash_preview = s
            .identity_hash
            .as_deref()
            .map(|h| format!("build {}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no build hash".to_string());
        let ts = s
            .deployed_at
            .clone()
            .filter(|at| !at.is_empty())
            .unwrap_or_else(|| output::dim("unknown time").into_owned());
        let available = s
            .identity_hash
            .as_deref()
            .and_then(|h| kix::eval::store::resolve_activation_by_hash(cluster, h))
            .is_some();
        let availability = if available {
            output::green("available")
        } else {
            output::red("build not on this machine")
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
            println!("      {} {}", output::dim("build:   "), output::dim(path));
        }
        if let Some(prev) = s.previous_activation.as_deref() {
            println!("      {} {}", output::dim("previous:"), output::dim(prev),);
        }
    }
    println!();
    println!("Next:");
    println!(
        "  Run `kix rollback {cluster}` to choose a deployment interactively, or `kix rollback {cluster} -y` to restore [1]."
    );
}

async fn run_async(args: &RollbackArgs, cluster: &str, ctx: &CommandContext) -> Result<()> {
    crate::say!("Connecting to cluster...");

    let client = client::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let target = Target::connect(client.clone(), SopsSources::Local)
        .await
        .map_err(|e| miette!("{e}"))?;

    let records =
        Records::open_installed(&client, target.discovery()).map_err(|e| miette!("{e}"))?;

    let current = records
        .active(cluster)
        .await
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| super::no_active_record(cluster))?;

    print_current(&current);

    // A rollback writes to the cluster with this Kix, so it must not skip a
    // required stop either. With `--operator`, the operator checks instead.
    super::deploy::stops::check(
        cluster,
        current.deployed_with.as_deref(),
        super::deploy::stops::Writer::Rollback,
    );

    let superseded = records
        .rollback_targets(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;

    if superseded.is_empty() {
        return Err(miette!(
            "cannot roll back: no earlier deployment records are available to roll back to. Nothing was applied to the cluster. Next: check out the git commit you want to restore and run `kix deploy {cluster}`."
        ));
    }

    let selected = if args.yes || !output::is_interactive() {
        &superseded[0]
    } else {
        println!();
        println!("Earlier deployments you can roll back to:");
        print_superseded_entries(cluster, &superseded);

        print!("\nSelect deployment to restore [1]: ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim();

        let idx = if input.is_empty() {
            0
        } else {
            input
                .parse::<usize>()
                .map_err(|_| {
                    miette!(
                        "'{}' is not a valid selection. Nothing was applied to the cluster. Next: enter a number from the list.",
                        input
                    )
                })?
                .checked_sub(1)
                .ok_or_else(|| {
                    miette!(
                        "enter a number from the list, starting at 1. Nothing was applied to the cluster."
                    )
                })?
        };

        if idx >= superseded.len() {
            return Err(miette!(
                "selection {} is out of range (1-{max}). Nothing was applied to the cluster. Next: enter a number between 1 and {max}.",
                idx + 1,
                max = superseded.len()
            ));
        }

        &superseded[idx]
    };

    let target_name = selected.name.clone();
    let target_hash = selected.identity_hash.as_ref().ok_or_else(|| {
        miette!(
            "rollback target {name} has no build hash on its deployment record\n  \
             Nothing was applied to the cluster.\n\n  \
             Why:\n    \
             Deployment record {name} has no build hash, so Kix cannot look for its build in Kix's local store.\n\n  \
             Next (choose one):\n    \
             - Run `kix rollback {cluster}` interactively and pick another deployment record marked `[available]`.\n    \
             - Check out the git commit you want to restore and run `kix deploy {cluster}`.",
            name = target_name,
        )
    })?;

    crate::say!(
        "Rollback target:    {} (build {}...)",
        output::bold(&target_name),
        &target_hash[..8.min(target_hash.len())],
    );

    let planned = plan_rollback(
        &client,
        ctx.global.context.as_deref(),
        &records,
        cluster,
        &current,
        selected,
        flags(args.prune, args.force_conflicts),
    )
    .await?;
    if !output::quiet() {
        planned.print(cluster, &target_name, args.prune, ctx.global.verbose > 0);
    }
    let RollbackPlan {
        target_result_dir,
        checked,
    } = planned;

    let refused = refused_writes(&client, &checked).await?;
    if !refused.is_empty() {
        print_refused(&refused);
        let next = if args.force_conflicts {
            String::new()
        } else {
            format!(
                " Run `kix rollback {cluster} --force-conflicts` to take fields another manager owns."
            )
        };
        return Err(miette!(
            "the rollback would stop on {} write(s), so Kix did not start it. Nothing was applied to the cluster.{next}",
            refused.len()
        ));
    }

    let total_apply = checked
        .plan()
        .nodes()
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
        .count();

    if args.dry_run {
        crate::say!();
        crate::say!(
            "{}",
            output::dim("Dry run. Nothing was applied to the cluster.")
        );
        return Ok(());
    }

    if total_apply == 0 && checked.orphans().is_empty() {
        // Same rule as deploy: an unchanged Job whose last run failed is
        // reported, and run again under `kix.run/rerun`; only the engine
        // does that.
        let failed_jobs = if checked.plan().has_skipped_jobs() {
            scheduler::failed_skipped_jobs(&client, target.discovery(), checked.plan()).await
        } else {
            Vec::new()
        };
        if failed_jobs.is_empty() {
            crate::say!(
                "Nothing to change. The cluster already matches the target deployment. Nothing was applied to the cluster."
            );
            return Ok(());
        }
        let names: Vec<String> = failed_jobs.iter().map(|r| r.to_string()).collect();
        crate::say!(
            "{} nothing changed, but {} Job(s) failed on the last run (a Job with {} runs again; any other is reported as failed): {}",
            output::yellow("↻"),
            failed_jobs.len(),
            kix::manifest::keys::RERUN,
            names.join(", "),
        );
    }

    if !args.yes {
        if !output::is_interactive() {
            output::refuse_unconfirmed(output::Unconfirmed::Rollback, cluster);
        }
        print!("\nProceed with rollback? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled. Nothing was applied to the cluster.");
            return Ok(());
        }
    }

    super::deploy::refuse_before_writing(&checked, Some(&records), target.discovery()).await?;

    let config = SchedulerConfig {
        timeout: readiness::DEFAULT_TIMEOUT,
        on_error: OnErrorPolicy::Stop,
        cancel: kix::cluster::cancel::CancelToken::new(),
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        rerun_failed: true,
        check_unchanged: true,
        // Rollback has no --on-error flag, so messages must not suggest it.
        names_flags: false,
    };

    let observer: Arc<dyn DeployObserver> = if !output::is_interactive() {
        Arc::new(super::deploy_log::LineObserver {
            verbose: ctx.global.verbose > 0,
        })
    } else {
        Arc::new(super::deploy::StreamCliObserver {
            verbose: ctx.global.verbose > 0,
        })
    };

    // Forward SIGINT and SIGTERM to the engine so the Activation record is not
    // left in Deploying if the process is interrupted.
    config.cancel.cancel_on_interrupt();

    // Pass `None` for the receipt so the rollback preserves the receipt
    // originally written when the target activation was deployed.
    let (result, kept) = checked.run(target, None, config, observer).await;

    if let Some(recorded) = kept {
        kix::plan::baseline::sync_kept_roots(cluster, &recorded);
    }

    // Save activation path for next deploy's diff, once the target's record
    // is current again.
    let end = super::deploy::RunEnd::of(&result);
    if end.current
        && let Err(e) = kix::eval::store::save_activation_path(cluster, &target_result_dir)
    {
        tracing::warn!(
            "could not save the local build path; later commands may be unable to find this deployment: {e}"
        );
    }

    match &result {
        Ok(r) => {
            println!();
            print_summary(r, end.succeeded);
        }
        Err(e) => {
            print_summary(e.partial(), end.succeeded);
            // The event stream already reports failed nodes and cancellation.
            if !matches!(
                e,
                scheduler::DeployError::NodesFailed { .. }
                    | scheduler::DeployError::Cancelled { .. }
            ) {
                eprintln!("{} {e}", output::red("error:"));
            }
        }
    }
    // A prune delete that fails leaves `result` `Ok` with `failed > 0`.
    if !end.succeeded {
        std::process::exit(1);
    }
    Ok(())
}

async fn run_operator_async(
    args: &RollbackArgs,
    cluster: &str,
    ctx: &CommandContext,
) -> Result<()> {
    let (client, records) =
        super::operator::connect_and_verify(ctx.global.context.as_deref()).await?;

    let current = records
        .active(cluster)
        .await
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| super::no_active_record(cluster))?;

    print_current(&current);

    let superseded = records
        .rollback_targets(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;

    if superseded.is_empty() {
        return Err(miette!(
            "cannot roll back: no earlier deployment records are available to roll back to. Nothing was applied to the cluster. Next: check out the git commit you want to restore and run `kix deploy {cluster}`."
        ));
    }

    let selected = if args.yes || !output::is_interactive() {
        &superseded[0]
    } else {
        println!();
        println!("Earlier deployments you can roll back to:");
        print_superseded_entries(cluster, &superseded);

        print!("\nSelect deployment to restore [1]: ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim();

        let idx = if input.is_empty() {
            0
        } else {
            input
                .parse::<usize>()
                .map_err(|_| {
                    miette!(
                        "'{}' is not a valid selection. Nothing was applied to the cluster. Next: enter a number from the list.",
                        input
                    )
                })?
                .checked_sub(1)
                .ok_or_else(|| {
                    miette!(
                        "enter a number from the list, starting at 1. Nothing was applied to the cluster."
                    )
                })?
        };

        if idx >= superseded.len() {
            return Err(miette!(
                "selection {} is out of range (1-{max}). Nothing was applied to the cluster. Next: enter a number between 1 and {max}.",
                idx + 1,
                max = superseded.len()
            ));
        }

        &superseded[idx]
    };

    let target_name = selected.name.clone();
    let target_hash = selected.identity_hash.clone();

    crate::say!(
        "Rollback target:   {} (via operator)",
        output::bold(&target_name),
    );

    // The plan a direct rollback would show, with its check, though the
    // operator plans again against the live objects and always prunes.
    let planned = plan_rollback(
        &client,
        ctx.global.context.as_deref(),
        &records,
        cluster,
        &current,
        selected,
        flags(true, false),
    )
    .await?;
    if !output::quiet() {
        planned.print(cluster, &target_name, true, ctx.global.verbose > 0);
    }
    let target_source_path = planned.target_result_dir.display().to_string();

    if args.dry_run {
        crate::say!();
        crate::say!(
            "{}",
            output::dim("Dry run. Nothing was applied to the cluster.")
        );
        return Ok(());
    }

    if !args.yes {
        if !output::is_interactive() {
            output::refuse_unconfirmed(output::Unconfirmed::Rollback, cluster);
        }
        print!("\nDelegate rollback to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled. Nothing was applied to the cluster.");
            return Ok(());
        }
    }

    crate::say!(
        "Updating deployment record '{}' to point to rollback target...",
        output::bold(&current.name),
    );

    super::operator::apply_activation(
        &records,
        &current.name,
        cluster,
        &target_source_path,
        target_hash.as_deref(),
        planned.checked.kubernetes_uid(),
        // A rollback re-applies a build from an earlier deploy, which wrote
        // its own receipt. See the non-operator path in this file.
        None,
        planned.checked.package_index(),
    )
    .await?;

    crate::say!(
        "  {} Deployment record updated. Waiting for the Kix operator...",
        output::green("✓"),
    );

    let reconciled = super::operator::watch_activation_progress(&records, &current.name).await?;

    println!();
    match reconciled {
        super::operator::Reconciled::Active => println!(
            "Rollback via operator {}: restored deployment '{}'.",
            output::green("complete"),
            output::bold(&target_name),
        ),
        super::operator::Reconciled::Degraded => {
            println!(
                "Rollback via operator {}: deployment record '{current}' was updated to restore '{}', and '{current}' is {}.",
                output::red("failed"),
                output::bold(&target_name),
                output::yellow("Degraded"),
                current = current.name,
            );
            println!(
                "  Inspect deployment record '{}' on the cluster to see which resources failed to reconcile.",
                current.name
            );
        }
    }

    if reconciled == super::operator::Reconciled::Degraded {
        std::process::exit(1);
    }
    Ok(())
}

/// Print the current active activation name and short identity hash.
fn print_current(current: &Record) {
    let hash_preview = current
        .identity_hash
        .as_deref()
        .map(|h| format!(" (build {}...)", &h[..8.min(h.len())]))
        .unwrap_or_default();
    crate::say!(
        "Current deployment: {}{}",
        output::bold(&current.name),
        hash_preview,
    );
}

/// Planned rollback from the current baseline to a target activation's store
/// path.
struct RollbackPlan {
    target_result_dir: std::path::PathBuf,
    checked: CheckedPlan,
}

impl RollbackPlan {
    fn print(&self, cluster: &str, target_name: &str, prune: bool, verbose: bool) {
        println!();
        println!(
            "{} restoring cluster '{}' to deployment '{}'",
            output::bold("Rollback:"),
            output::bold(cluster),
            output::bold(target_name),
        );
        plan::print_package_plan(self.checked.pkg_diff(), verbose);
        plan::print_plan_summary(self.checked.pkg_diff());
        let fate = if prune {
            "to be deleted after the apply (`--prune`)".to_string()
        } else {
            plan::kept_orphans_fate(cluster)
        };
        print!(
            "{}",
            plan::render_plan_orphans(self.checked.orphans(), &fate)
        );
        plan::print_shared(self.checked.shared_orphans());
    }
}

/// Build [`PlanFlags`] for a rollback.
///
/// A rollback takes conflicting fields only under `--force-conflicts`, and
/// never accepts stateful migrations.
fn flags(prune: bool, force_conflicts: bool) -> PlanFlags {
    PlanFlags {
        prune,
        prune_mode: None,
        reconcile: false,
        force_conflicts,
        accept_migrations: false,
    }
}

/// Plan a rollback of `cluster` from `current` to `selected`, through the
/// kube context `context`.
///
/// The target build is known only once the records have been read, so the
/// binding check runs after that read and before anything is planned or
/// written. The target is a build this Kix cluster deployed here before, so
/// only a target that names another Kubernetes cluster is refused; one from
/// before the definition set `cluster.kubernetes.uid` rolls back as usual.
/// A target made for another Kubernetes version rolls back too, with one
/// line that says so, since a Kubernetes upgrade must not block a rollback
/// during an incident.
async fn plan_rollback(
    client: &kube::Client,
    context: Option<&str>,
    records: &Records,
    cluster: &str,
    current: &Record,
    selected: &Record,
    flags: PlanFlags,
) -> Result<RollbackPlan> {
    // Load the target activation's build from its recorded path or local store
    // hash. Pre-migration builds are allowed here because stamping upgrades
    // their metadata and CRD group names to the current API domain.
    let target_hash = selected.identity_hash.as_deref().ok_or_else(|| {
        miette!(
            "rollback target {name} has no build hash on its deployment record\n  \
             Nothing was applied to the cluster.\n\n  \
             Why:\n    \
             Deployment record {name} has no build hash, so Kix cannot look for its build in Kix's local store.\n\n  \
             Next (choose one):\n    \
             - Run `kix rollback {cluster}` interactively and pick another deployment record marked `[available]`.\n    \
             - Check out the git commit you want to restore and run `kix deploy {cluster}`.",
            name = selected.name,
        )
    })?;
    let target_graph = baseline::target_build(
        cluster,
        &selected.name,
        target_hash,
        selected.built_via.as_deref(),
    )
    .map_err(|e| miette!("{e}"))?;
    let target_result_dir = target_graph.built_via.clone();
    same_cluster(&selected.name, &target_graph.cluster_name, cluster)?;
    if let Some(declared) = target_graph.kubernetes_uid.as_deref() {
        binding::check_declared(
            client,
            &binding::Connection::of_context(context),
            binding::Action::Deploy,
            cluster,
            declared,
        )
        .await
        .map_err(|e| miette!("{e}"))?;
    }
    if let Some(line) = kix::cluster::kubernetes_version::note(
        client,
        &binding::Connection::of_context(context),
        cluster,
        target_graph.kubernetes_version.as_deref(),
    )
    .await
    {
        crate::say!("{line}");
    }

    let report = |event: PlanEvent<'_>| plan::progress::print(event);
    let baseline = Baseline::of_record(records, cluster, current, &report).await;
    let checked = Planner::new(flags, &report)
        .plan(&target_graph, cluster, &baseline, Some(client))
        .await
        .map_err(|e| miette!("{e}"))?;
    Ok(RollbackPlan {
        target_result_dir,
        checked,
    })
}

/// Send the rollback's writes to the apiserver as a dry run, and return each
/// write it refuses with the reason. A rollback that stops halfway leaves the
/// cluster between two builds, so a refusal stops it before any write. A
/// write whose admission webhook could not reach a Service that the rollback
/// writes is not a refusal, because the rollback creates that Service.
async fn refused_writes(
    client: &kube::Client,
    checked: &CheckedPlan,
) -> Result<Vec<(ResourceId, String)>> {
    let target = Target::connect(client.clone(), SopsSources::Local)
        .await
        .map_err(|e| miette!("{e}"))?;
    let config = SchedulerConfig {
        timeout: readiness::DEFAULT_TIMEOUT,
        on_error: OnErrorPolicy::Continue,
        cancel: kix::cluster::cancel::CancelToken::new(),
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        rerun_failed: true,
        check_unchanged: true,
        names_flags: false,
    };
    let (result, answers) = checked
        .dry_run(target, config, Arc::new(NullObserver))
        .await;
    if let Err(e) = &result
        && !matches!(e, scheduler::DeployError::NodesFailed { .. })
    {
        return Err(miette!(
            "the rollback's dry run stopped: {e}. Nothing was applied to the cluster."
        ));
    }
    let written: HashSet<ResourceId> = checked
        .plan()
        .nodes()
        .iter()
        .filter_map(|n| match &n.action {
            ChangeAction::Apply(manifest) => Some(ResourceId::from_value(manifest)),
            ChangeAction::Skip(_) | ChangeAction::Orphan(_) => None,
        })
        .collect();
    let mut refused = Vec::new();
    for a in answers {
        let DryRunOutcome::Refused(r) = a.outcome else {
            continue;
        };
        match r.unreachable_service_written(|rid| written.contains(rid)) {
            Some(service) if !output::quiet() => eprintln!(
                "  {} {}: not checked, because its admission webhook could not reach {}, which this rollback writes",
                output::dim("?"),
                a.rid,
                service.display_id()
            ),
            Some(_) => {}
            None => refused.push((a.rid, describe_refusal(&r))),
        }
    }
    Ok(refused)
}

/// Return one line for a refused write: who owns which fields for a
/// conflict, or the apiserver's message.
fn describe_refusal(refusal: &Refusal) -> String {
    match refusal {
        Refusal::Conflict { owners, .. } if !owners.is_empty() => {
            let owned: Vec<String> = owners
                .iter()
                .map(|o| format!("{} owns {}", o.manager, o.fields.join(", ")))
                .collect();
            format!("field ownership conflict: {}", owned.join("; "))
        }
        other => other.message(),
    }
}

fn print_refused(refused: &[(ResourceId, String)]) {
    eprintln!();
    eprintln!("The rollback would stop on {} write(s):", refused.len());
    for (rid, why) in refused {
        eprintln!("  {} {rid}: {why}", output::red("✗"));
    }
}

/// Reject a rollback target whose build belongs to a different Kix cluster
/// than `cluster`.
fn same_cluster(record: &str, build_cluster: &str, cluster: &str) -> Result<()> {
    if build_cluster == cluster {
        return Ok(());
    }
    Err(miette!(
        "activation '{record}' is a build of Kix cluster '{build_cluster}', not '{cluster}'. Nothing was applied."
    ))
}

/// Print a numbered list of superseded activations with local store
/// availability, source path, and previous activation link.
fn print_superseded_entries(cluster: &str, superseded: &[Record]) {
    for (i, act) in superseded.iter().enumerate() {
        let hash_preview = act
            .identity_hash
            .as_deref()
            .map(|h| format!("build {}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no build hash".to_string());
        let ts = act
            .deployed_at
            .clone()
            .filter(|at| !at.is_empty())
            .unwrap_or_else(|| "unknown time".to_string());
        let available = act
            .identity_hash
            .as_deref()
            .and_then(|h| kix::eval::store::resolve_activation_by_hash(cluster, h))
            .is_some();
        let availability = if available {
            output::green("available")
        } else {
            output::red("build not on this machine")
        };
        println!(
            "  {} {} ({}), deployed {} [{}]",
            output::bold(&format!("[{}]", i + 1)),
            act.name,
            hash_preview,
            ts,
            availability,
        );
        if let Some(path) = act.built_via.as_deref() {
            println!("      {} {}", output::dim("build:   "), output::dim(path));
        }
        if let Some(prev) = act.previous_activation.as_deref() {
            println!("      {} {}", output::dim("previous:"), output::dim(prev),);
        }
    }
}

/// Print the text that closes a rollback: its counts, and when it did not
/// succeed, what was applied and what to run next.
fn print_summary(r: &DeployResult, succeeded: bool) {
    if succeeded {
        println!("Rollback complete: {}", super::deploy::counts(r, false));
    } else if r.failed > 0 {
        println!("Rollback failed: {}", super::deploy::counts(r, true));
        println!(
            "  {} created and {} configured object(s) were applied before the rollback failed; fix the error(s) above and run `kix rollback` again.",
            r.created, r.configured
        );
    } else {
        println!("Rollback stopped: {}", super::deploy::counts(r, true));
        println!(
            "  {} created and {} configured object(s) finished before the rollback stopped, and {} object(s) did not finish; run `kix rollback` again to finish restoring the target build.",
            r.created, r.configured, r.cancelled
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verify that [`same_cluster`] accepts matching cluster names and rejects mismatches.
    #[test]
    fn a_target_built_for_another_cluster_is_refused() {
        assert!(same_cluster("act-1", "prod", "prod").is_ok());
        let err = same_cluster("act-1", "staging", "prod")
            .unwrap_err()
            .to_string();
        assert!(err.contains("'staging'") && err.contains("'prod'"), "{err}");
        assert!(err.contains("Nothing was applied"), "{err}");
    }
}
