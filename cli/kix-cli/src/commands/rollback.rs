//! Revert to a Superseded activation.
//!
//! Finds the previous activation on the cluster, resolves its store path,
//! and re-applies its manifests through the standard reconcile engine.
//! No Nix build is required because the target activation's manifests are already
//! in the local Nix store.

use std::io::Write;
use std::sync::Arc;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::build_source::Build;
use kix::cluster::activation::{Record, Records};
use kix::cluster::apply::ChangeAction;
use kix::cluster::fetch;
use kix::cluster::ops::{ClusterOps, KubeOps, KubeOpsConfig};
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::{DeployObserver, DeployResult};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::StoreGraph;
use kix::plan::baseline::Baseline;
use kix::plan::document::PlanFlags;
use kix::plan::{CheckedPlan, PlanEvent, Planner};

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

/// Read-only: connect, enumerate Superseded activations, print history, exit.
/// Works the same whether the cluster is operator-managed or direct-apply
/// because it only inspects Activation CRs. Supports `--output json|yaml`.
async fn run_list_async(cluster: &str, ctx: &CommandContext) -> Result<()> {
    let client = fetch::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    let records = Records::open_installed(&client, &discovery).map_err(|e| miette!("{e}"))?;

    // The current Active activation is an optional position marker
    // in the history listing, but we must still print even if none exists.
    let current = records.active(cluster).await.map_err(|e| miette!("{e}"))?;

    // Only records that really were the cluster's state. A deploy that
    // stopped part way is Superseded once a later plan folded its leftovers
    // in, but it was never running, so rolling back to it would apply a state
    // the cluster has never been in.
    let superseded = records
        .rollback_targets(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;

    let format = ctx.output_format(OutputFormat::Text);
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
                print!("{}", serde_yml::to_string(&value).into_diagnostic()?);
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
        "{} activation history for '{}'",
        output::bold("Rollback:"),
        cluster,
    );
    println!();

    if let Some(c) = current {
        let hash_preview = c
            .identity_hash
            .as_deref()
            .map(|h| format!("{}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no hash".to_string());
        println!(
            "  {} {} ({})  {}",
            output::green("● active  "),
            output::bold(&c.name),
            hash_preview,
            output::dim("← you are here"),
        );
        if let Some(path) = c.built_via.as_deref() {
            println!("    {} {}", output::dim("source:  "), output::dim(path));
        }
        println!();
    }

    if superseded.is_empty() {
        println!(
            "  {}",
            output::dim("No superseded activations. Nothing to roll back to.")
        );
        return;
    }

    println!("  {}", output::bold("Superseded (most recent first):"));
    println!();
    for (i, s) in superseded.iter().enumerate() {
        let hash_preview = s
            .identity_hash
            .as_deref()
            .map(|h| format!("{}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no hash".to_string());
        let ts = s
            .deployed_at
            .clone()
            .filter(|at| !at.is_empty())
            .unwrap_or_else(|| output::dim("unknown").into_owned());
        let available = s
            .identity_hash
            .as_deref()
            .and_then(|h| kix::eval::store::resolve_activation_by_hash(cluster, h))
            .is_some();
        let availability = if available {
            output::green("available")
        } else {
            output::red("store path missing")
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
            println!("      {} {}", output::dim("source:  "), output::dim(path));
        }
        if let Some(prev) = s.previous_activation.as_deref() {
            println!("      {} {}", output::dim("previous:"), output::dim(prev),);
        }
    }
    println!();
    println!(
        "  {}",
        output::dim(
            "Run `kix rollback <cluster>` (or `--yes` for most recent) to switch activations."
        )
    );
}

async fn run_async(args: &RollbackArgs, cluster: &str, ctx: &CommandContext) -> Result<()> {
    // 1. Connect to cluster
    if !ctx.global.quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(ctx.global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    let records = Records::open_installed(&client, &discovery).map_err(|e| miette!("{e}"))?;

    // 2. Find current Active activation
    let current = records
        .active(cluster)
        .await
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| {
            miette!(
                "no active deployment record found for cluster '{}'",
                cluster
            )
        })?;

    if !ctx.global.quiet {
        let hash_preview = current
            .identity_hash
            .as_deref()
            .map(|h| format!(" ({}...)", &h[..8.min(h.len())]))
            .unwrap_or_default();
        println!(
            "Current activation: {}{}",
            output::bold(&current.name),
            hash_preview,
        );
    }

    // 3. Find available Superseded activations
    // Only records that really were the cluster's state. A deploy that
    // stopped part way is Superseded once a later plan folded its leftovers
    // in, but it was never running, so rolling back to it would apply a state
    // the cluster has never been in.
    let superseded = records
        .rollback_targets(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;

    if superseded.is_empty() {
        return Err(miette!(
            "no previous deployments are available to roll back to"
        ));
    }

    // In interactive mode, let the user pick; with --yes, use most recent
    let selected = if args.yes || !output::is_interactive() {
        &superseded[0] // most recent (list is sorted by deployed_at desc)
    } else {
        println!();
        println!("Available activations to rollback to:");
        print_superseded_entries(cluster, &superseded);

        print!("\nSelect activation [1]: ");
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
                        "'{}' is not a valid selection. Enter a number from the list",
                        input
                    )
                })?
                .checked_sub(1)
                .ok_or_else(|| miette!("enter a number from the list, starting at 1"))?
        };

        if idx >= superseded.len() {
            return Err(miette!(
                "selection {} out of range (1-{})",
                idx + 1,
                superseded.len()
            ));
        }

        &superseded[idx]
    };

    let target_name = selected.name.clone();
    let target_hash = selected.identity_hash.as_ref().ok_or_else(|| {
        miette!(
            "superseded activation '{}' has no identity hash",
            target_name
        )
    })?;

    if !ctx.global.quiet {
        println!(
            "Rollback target:   {} ({}...)",
            output::bold(&target_name),
            &target_hash[..8.min(target_hash.len())],
        );
    }

    let planned = plan_rollback(
        &client,
        &records,
        cluster,
        &current,
        selected,
        args.prune,
        ctx.global.quiet,
    )
    .await?;
    if !ctx.global.quiet {
        planned.print(cluster, &target_name, args.prune, ctx.global.verbose > 0);
    }
    // The merged set, so `prune_order` can topologically sort an orphan
    // that exists in no current closure.
    let baseline_manifests = planned.baseline.manifests();
    let RollbackPlan {
        target_result_dir,
        target_graph,
        target_manifests,
        baseline,
        checked,
    } = planned;
    let record = kix::manifest::lifecycle::record_of(&target_manifests);

    let total_apply = checked
        .plan()
        .nodes
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
        .count();

    if args.dry_run {
        if !ctx.global.quiet {
            println!();
            println!("{}", output::dim("Dry run. No changes applied."));
        }
        return Ok(());
    }

    if total_apply == 0 && checked.orphans().is_empty() {
        // Same rule as deploy: an unchanged probe under `kix.run/rerun`
        // whose last run failed still runs, and only the engine does that.
        let failed_reruns = if checked.plan().nodes.iter().any(|n| n.rerun.is_some()) {
            scheduler::failed_rerun_nodes(&client, &discovery, checked.plan()).await
        } else {
            Vec::new()
        };
        if failed_reruns.is_empty() {
            if !ctx.global.quiet {
                println!("Nothing to change. Cluster already matches target activation.");
            }
            return Ok(());
        }
        if !ctx.global.quiet {
            let names: Vec<String> = failed_reruns.iter().map(|r| r.to_string()).collect();
            println!(
                "{} nothing changed, but {} failed on the last run and will run again: {}",
                output::yellow("↻"),
                failed_reruns.len(),
                names.join(", "),
            );
        }
    }

    // 8. Confirmation
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
        print!("\nProceed with rollback? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled.");
            return Ok(());
        }
    }

    // 9. Apply via DAG-streaming scheduler.
    let config = SchedulerConfig {
        timeout: readiness::DEFAULT_TIMEOUT,
        on_error: OnErrorPolicy::Stop,
        prune: checked.flags().prune_policy(),
        cancel: kix::cluster::cancel::CancelToken::new(),
        dry_run: false,
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        rerun_failed: true,
    };

    let observer: Arc<dyn DeployObserver> = if !output::is_interactive() {
        Arc::new(super::deploy_log::LineObserver {
            verbose: ctx.global.verbose > 0,
        })
    } else {
        Arc::new(super::deploy::StreamCliObserver {
            quiet: ctx.global.quiet,
            verbose: ctx.global.verbose > 0,
        })
    };

    let cluster_name = target_graph.cluster_name.clone();
    let discovery = Arc::new(tokio::sync::RwLock::new(discovery));
    // Ctrl-C and SIGTERM now have to reach the engine: the record exists from
    // the start of the run, so a process that just dies leaves it Deploying.
    config.cancel.cancel_on_interrupt();

    let kube_ops = Arc::new(KubeOps::new(
        client.clone(),
        discovery,
        KubeOpsConfig {
            cluster_name,
            activation_name: checked.activation_name().map(str::to_string),
            activation_identity_hash: checked.activation_identity_hash().map(str::to_string),
            // A rollback re-applies a build from an earlier deploy, and that
            // deploy wrote its own receipt. Writing a fresh one here would
            // record the machine running the rollback as the provenance of a
            // build it did not make.
            receipt: None,
            // A rollback's target record already exists on the cluster as a
            // Superseded one, so this re-asserts it and marks it Deploying
            // for the duration, the same as a deploy.
            activation_manifest: record.cloned(),
            consumed_failed: baseline.failed().consumed.clone(),
            kept_orphans: checked.kept_orphans().clone(),
            mark_failed_on_abort: true,
            sops: Default::default(),
            force_conflicts: checked.flags().force_conflicts,
            dry_run: false,
        },
    ));
    let ops: Arc<dyn ClusterOps> = kube_ops.clone();

    let result = checked
        .run(ops, &baseline_manifests, config, observer)
        .await;

    if let Some(recorded) = kube_ops.recorded_orphans_kept_from() {
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
    // 1. Connect and find current + superseded activations
    let (client, records) =
        super::operator::connect_and_verify(ctx.global.context.as_deref(), ctx.global.quiet)
            .await?;

    // 2. Find current Active activation
    let current = records
        .active(cluster)
        .await
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| {
            miette!(
                "no active deployment record found for cluster '{}'",
                cluster
            )
        })?;

    if !ctx.global.quiet {
        let hash_preview = current
            .identity_hash
            .as_deref()
            .map(|h| format!(" ({}...)", &h[..8.min(h.len())]))
            .unwrap_or_default();
        println!(
            "Current activation: {}{}",
            output::bold(&current.name),
            hash_preview,
        );
    }

    // 3. Find superseded activations
    // Only records that really were the cluster's state. A deploy that
    // stopped part way is Superseded once a later plan folded its leftovers
    // in, but it was never running, so rolling back to it would apply a state
    // the cluster has never been in.
    let superseded = records
        .rollback_targets(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;

    if superseded.is_empty() {
        return Err(miette!(
            "no previous deployments are available to roll back to"
        ));
    }

    // Interactive selection or auto-select most recent
    let selected = if args.yes || !output::is_interactive() {
        &superseded[0]
    } else {
        println!();
        println!("Available activations to rollback to:");
        print_superseded_entries(cluster, &superseded);

        print!("\nSelect activation [1]: ");
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
                        "'{}' is not a valid selection. Enter a number from the list",
                        input
                    )
                })?
                .checked_sub(1)
                .ok_or_else(|| miette!("enter a number from the list, starting at 1"))?
        };

        if idx >= superseded.len() {
            return Err(miette!(
                "selection {} out of range (1-{})",
                idx + 1,
                superseded.len()
            ));
        }

        &superseded[idx]
    };

    let target_name = selected.name.clone();
    let target_hash = selected.identity_hash.clone();

    if !ctx.global.quiet {
        println!(
            "Rollback target:   {} (via operator)",
            output::bold(&target_name),
        );
    }

    // The plan a direct rollback would show, with its check, though the
    // operator plans again against the live objects and always prunes.
    let planned = plan_rollback(
        &client,
        &records,
        cluster,
        &current,
        selected,
        true,
        ctx.global.quiet,
    )
    .await?;
    if !ctx.global.quiet {
        planned.print(cluster, &target_name, true, ctx.global.verbose > 0);
    }
    let target_source_path = planned.target_result_dir.display().to_string();

    if args.dry_run {
        if !ctx.global.quiet {
            println!();
            println!("{}", output::dim("Dry run. No changes applied."));
        }
        return Ok(());
    }

    // 5. Confirmation
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
        print!("\nDelegate rollback to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled.");
            return Ok(());
        }
    }

    // 6. Patch the current Activation CR to point to the target's source path
    //    The operator will detect the source change and reconcile.
    if !ctx.global.quiet {
        println!(
            "Updating Activation CR '{}' to point to rollback target...",
            output::bold(&current.name),
        );
    }

    super::operator::apply_activation(
        &records,
        &current.name,
        cluster,
        &target_source_path,
        target_hash.as_deref(),
        // A rollback re-applies a build from an earlier deploy, which wrote
        // its own receipt. See the non-operator path in this file.
        None,
    )
    .await?;

    if !ctx.global.quiet {
        println!(
            "  {} Activation CR updated. Waiting for operator...",
            output::green("✓"),
        );
    }

    let reconciled =
        super::operator::watch_activation_progress(&records, &current.name, ctx.global.quiet)
            .await?;

    println!();
    match reconciled {
        super::operator::Reconciled::Active => println!(
            "Rollback via operator {}: rolled back to '{}'",
            output::green("complete"),
            output::bold(&target_name),
        ),
        super::operator::Reconciled::Degraded => println!(
            "Rollback via operator {}: rolled back to '{}', which is {}",
            output::red("failed"),
            output::bold(&target_name),
            output::yellow("Degraded"),
        ),
    }

    if reconciled == super::operator::Reconciled::Degraded {
        std::process::exit(1);
    }
    Ok(())
}

/// A rollback to one record, planned the way `kix deploy` plans: the target
/// build against the current one, with what failed and kept deploys left.
struct RollbackPlan {
    target_result_dir: std::path::PathBuf,
    target_graph: StoreGraph,
    target_manifests: Vec<Value>,
    baseline: Baseline,
    checked: CheckedPlan,
}

impl RollbackPlan {
    fn print(&self, cluster: &str, target_name: &str, prune: bool, verbose: bool) {
        println!();
        println!(
            "{} Rolling back cluster '{}' to activation '{}'",
            output::bold("Rollback:"),
            output::bold(cluster),
            output::bold(target_name),
        );
        plan::print_package_plan(self.checked.pkg_diff(), verbose);
        plan::print_plan_summary(self.checked.pkg_diff());
        let fate = if prune {
            "will be deleted".to_string()
        } else {
            format!("kept; {}", plan::KEPT_ORPHANS_HINT)
        };
        print!(
            "{}",
            plan::render_plan_orphans(self.checked.orphans(), &fate)
        );
        plan::print_shared(self.checked.shared_orphans());
    }
}

/// A rollback's planning flags: only whether it prunes. A rollback
/// re-applies a known-good prior activation; conflicts fail loudly rather
/// than silently overwriting whatever the cluster has.
fn flags(prune: bool) -> PlanFlags {
    PlanFlags {
        prune,
        prune_mode: None,
        reconcile: false,
        force_conflicts: false,
        accept_migrations: false,
    }
}

/// Plan a rollback of `cluster`, which runs `current`, to `selected`, with
/// the pieces of [`Planner`]: the current record's baseline, the changes,
/// and the checked plan. Refuses a target whose plan writes or deletes an
/// object the diff leaves out, as `kix deploy` does.
async fn plan_rollback(
    client: &kube::Client,
    records: &Records,
    cluster: &str,
    current: &Record,
    selected: &Record,
    prune: bool,
    quiet: bool,
) -> Result<RollbackPlan> {
    // The target's build: the path its record was built via, or a build in
    // the local store with its identity hash.
    let target_result_dir = selected
        .built_via
        .as_ref()
        .map(std::path::PathBuf::from)
        .filter(|p| p.join("kix-packages.json").exists())
        .or_else(|| {
            kix::eval::store::resolve_activation_by_hash(cluster, selected.identity_hash.as_deref()?)
        })
        .ok_or_else(|| {
            miette!(
                "store path for activation '{}' not found locally (hash: {}). \
                 The build may have been garbage-collected or created on another machine. Restore it to the local Nix store or run the rollback on a machine that still has it.",
                selected.name,
                selected.identity_hash.as_deref().unwrap_or("none"),
            )
        })?;

    // Not refused for a retired domain (`Build::installable`). A rollback
    // target can be a build from before the domain move, and refusing it
    // would make every record the migration carefully preserved unusable.
    // Stamping upgrades its keys, its record's API group and Kix's own CRDs,
    // so what gets applied names the current domain throughout.
    let target_graph = Build::local(&target_result_dir, &|_| {})
        .map_err(|e| miette!("failed to load target activation: {e}"))?
        .into_graph();

    let target_manifests: Vec<Value> = target_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    let report = |event: PlanEvent<'_>| plan::progress::print(event, quiet);
    let baseline = Baseline::of_record(records, cluster, current, &report).await;
    // The records and the orphans another Kix cluster deploys are looked up
    // under `cluster`, the name the rollback resolved its records by.
    let checked = Planner::new(flags(prune), &report)
        .plan(&target_graph, cluster, &baseline, Some(client))
        .await
        .map_err(|e| miette!("{e}"))?;
    Ok(RollbackPlan {
        target_result_dir,
        target_graph,
        target_manifests,
        baseline,
        checked,
    })
}

/// Shared formatter for a list of superseded activations used by both the
/// interactive rollback selector and `kix rollback --list`. Shows store path
/// availability, source directory, and the `previousActivation` link so the
/// operator sees exactly what each history entry points at.
fn print_superseded_entries(cluster: &str, superseded: &[Record]) {
    for (i, act) in superseded.iter().enumerate() {
        let hash_preview = act
            .identity_hash
            .as_deref()
            .map(|h| format!("{}...", &h[..8.min(h.len())]))
            .unwrap_or_else(|| "no hash".to_string());
        let ts = act
            .deployed_at
            .clone()
            .filter(|at| !at.is_empty())
            .unwrap_or_else(|| "unknown".to_string());
        let available = act
            .identity_hash
            .as_deref()
            .and_then(|h| kix::eval::store::resolve_activation_by_hash(cluster, h))
            .is_some();
        let availability = if available {
            output::green("available")
        } else {
            output::red("store path missing")
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
            println!("      {} {}", output::dim("source:  "), output::dim(path));
        }
        if let Some(prev) = act.previous_activation.as_deref() {
            println!("      {} {}", output::dim("previous:"), output::dim(prev),);
        }
    }
}

/// The last line of a rollback, worded as `kix deploy`'s summary line is.
fn print_summary(r: &DeployResult, succeeded: bool) {
    let failed_str = r.failed.to_string();
    let ending = if succeeded {
        "complete"
    } else if r.failed > 0 {
        "failed"
    } else {
        "stopped"
    };
    println!(
        "Rollback {ending}: {} created, {} configured, {} unchanged, {} failed",
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
