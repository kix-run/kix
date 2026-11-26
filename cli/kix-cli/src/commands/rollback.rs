//! Revert to a Superseded activation.
//!
//! Finds the previous activation on the cluster, resolves its store path,
//! and re-applies its manifests through the standard reconcile engine.
//! No Nix build is required because the target activation's manifests are already
//! in the local Nix store.

use std::fmt::Write as _;
use std::io::Write;

use miette::{IntoDiagnostic, Result, miette};

use crate::client;
use kix::cluster::activation::{Record, Records};
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::plan::baseline;
use kix::plan::document::PlanFlags;
use kix::plan::{PlanEvent, Planned, Planner};

use crate::cli::{HistoryArgs, RollbackArgs};
use crate::exit::Exit;
use crate::output::{self, CommandResponse};
use crate::plan;

use super::CommandContext;
use super::deploy::{Command, Previous, RunOptions, Runner};

pub fn run(args: &RollbackArgs, ctx: &mut CommandContext) -> Result<Exit> {
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::Mutating)?;
    if args.operator {
        // The operator writes this rollback with its own Kix.
        super::deploy::withdrawn::warn();
        return ctx
            .runtime()?
            .block_on(run_operator_async(args, &cluster, ctx));
    }
    run_direct(args, &cluster, ctx)
}

/// Run `kix history`: list the deploys `kix rollback` can go back to.
pub fn history(args: &HistoryArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::ReadOnly)?;
    ctx.runtime()?.block_on(run_list_async(&cluster, ctx))
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
    let connection = binding::Connection::of_context(ctx.global.context.as_deref());

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

    output::result(&HistoryResponse {
        cluster: cluster.to_string(),
        kubernetes: (&connection).into(),
        connection,
        current: current.map(|c| CurrentDeploy {
            name: c.name,
            identity_hash: c.identity_hash,
            built_via: c.built_via,
        }),
        superseded: earlier_deploys(cluster, superseded),
    })
}

/// Describe the deploys a rollback can go back to, and whether this machine
/// has the build each one needs.
fn earlier_deploys(cluster: &str, records: Vec<Record>) -> Vec<EarlierDeploy> {
    earlier_deploys_with(records, |hash, built_via| {
        kix::plan::baseline::checked_dir(cluster, hash, built_via)
    })
}

/// Run [`earlier_deploys`] with `find` in place of the search for a record's
/// build.
fn earlier_deploys_with(
    records: Vec<Record>,
    find: impl Fn(&str, Option<&str>) -> Result<Option<std::path::PathBuf>, String>,
) -> Vec<EarlierDeploy> {
    records
        .into_iter()
        .map(|s| {
            let build = match s.identity_hash.as_deref() {
                Some(hash) => match find(hash, s.built_via.as_deref()) {
                    Ok(Some(_)) => BuildState::Available,
                    Ok(None) => BuildState::Missing,
                    Err(_) => BuildState::Broken,
                },
                None => BuildState::Missing,
            };
            EarlierDeploy {
                name: s.name,
                identity_hash: s.identity_hash,
                deployed_at: s.deployed_at,
                built_via: s.built_via,
                previous_activation: s.previous_activation,
                available_locally: build == BuildState::Available,
                build,
            }
        })
        .collect()
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum BuildState {
    Available,
    Missing,
    Broken,
}

/// The deploys of a cluster that `kix rollback` can go back to.
#[derive(serde::Serialize, schemars::JsonSchema)]
pub(crate) struct HistoryResponse {
    cluster: String,
    /// The Kubernetes cluster whose deploy records these are.
    kubernetes: binding::Target,
    #[serde(skip)]
    #[schemars(skip)]
    connection: binding::Connection,
    /// The deploy live on the cluster, or null when there is none.
    current: Option<CurrentDeploy>,
    /// Earlier deploys that ran to completion, most recent first.
    superseded: Vec<EarlierDeploy>,
}

#[derive(serde::Serialize, schemars::JsonSchema)]
struct CurrentDeploy {
    /// The name of the deploy record.
    name: String,
    identity_hash: Option<String>,
    /// The store path of the build.
    built_via: Option<String>,
}

#[derive(serde::Serialize, schemars::JsonSchema)]
struct EarlierDeploy {
    /// The name of the deploy record.
    name: String,
    identity_hash: Option<String>,
    /// When the deploy finished, in RFC 3339.
    deployed_at: Option<String>,
    /// The store path of the build.
    built_via: Option<String>,
    /// The deploy record this one replaced.
    previous_activation: Option<String>,
    /// Whether this machine has the build, which `kix rollback` needs.
    available_locally: bool,
    #[serde(skip)]
    #[schemars(skip)]
    build: BuildState,
}

/// Write the numbered list of earlier deploys that `kix history` and the
/// `kix rollback` picker both show.
fn write_earlier_deploys(out: &mut String, deploys: &[EarlierDeploy]) {
    for (i, s) in deploys.iter().enumerate() {
        let ts = s
            .deployed_at
            .clone()
            .filter(|at| !at.is_empty())
            .unwrap_or_else(|| output::dim("unknown time").into_owned());
        let availability = match s.build {
            BuildState::Available => output::green("available"),
            BuildState::Missing => output::red("build not on this machine"),
            BuildState::Broken => output::red("build on this machine does not load"),
        };
        let _ = writeln!(
            out,
            "  {} {} ({})  deployed {}  [{}]",
            output::bold(&format!("[{}]", i + 1)),
            s.name,
            hash_preview(s.identity_hash.as_deref()),
            ts,
            availability,
        );
        if let Some(path) = s.built_via.as_deref() {
            let _ = writeln!(
                out,
                "      {} {}",
                output::dim("build:   "),
                output::dim(path)
            );
        }
        if let Some(prev) = s.previous_activation.as_deref() {
            let _ = writeln!(
                out,
                "      {} {}",
                output::dim("previous:"),
                output::dim(prev)
            );
        }
    }
}

/// Return `build <first 8 characters>...` for an identity hash.
fn hash_preview(hash: Option<&str>) -> String {
    hash.map(|h| format!("build {}...", &h[..8.min(h.len())]))
        .unwrap_or_else(|| "no build hash".to_string())
}

impl CommandResponse for HistoryResponse {
    fn text(&self) -> String {
        let cluster = &self.cluster;
        let mut out = format!(
            "Deployment history for '{}' on {}\n\n",
            output::bold(cluster),
            self.connection.describe()
        );

        if let Some(c) = &self.current {
            let _ = writeln!(
                out,
                "  {} {} ({})  {}",
                output::green("● current "),
                output::bold(&c.name),
                hash_preview(c.identity_hash.as_deref()),
                output::dim("← live on the cluster"),
            );
            if let Some(path) = c.built_via.as_deref() {
                let _ = writeln!(
                    out,
                    "    {} {}",
                    output::dim("build:   "),
                    output::dim(path)
                );
            }
            out.push('\n');
        }

        if self.superseded.is_empty() {
            let _ = writeln!(
                out,
                "{}",
                output::dim(&format!(
                    "No earlier deployments recorded for '{cluster}'. Nothing to roll back to."
                ))
            );
            return out;
        }

        let _ = writeln!(
            out,
            "  {}\n",
            output::bold("Earlier deployments (most recent first):")
        );
        write_earlier_deploys(&mut out, &self.superseded);
        let _ = write!(
            out,
            "\nNext:\n  Run `kix rollback {cluster}` to choose a deployment interactively, or `kix rollback {cluster} -y` to restore [1].\n"
        );
        out
    }
}

/// Roll `cluster` back by deploying an earlier record's build, through the
/// steps `kix deploy` takes once it has a plan (see `super::deploy`).
fn run_direct(args: &RollbackArgs, cluster: &str, ctx: &CommandContext) -> Result<Exit> {
    // A dry run writes nothing, so a withdrawn Kix only warns there.
    let withdrawn_kix = if args.dry_run {
        super::deploy::withdrawn::warn();
        None
    } else {
        super::deploy::withdrawn::check(cluster, super::deploy::stops::Writer::Rollback)?
    };
    let (current, target, mut p, downgrade) = ctx.runtime()?.block_on(async {
        let (client, connection) = client::connect(ctx.global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
        let discovery = discovery::discover_resources(&client)
            .await
            .map_err(|e| miette!("{e}"))?;
        let records = Records::open_installed(&client, &discovery).map_err(|e| miette!("{e}"))?;
        let current = records
            .active(cluster)
            .await
            .map_err(|e| miette!("{e}"))?
            .ok_or_else(|| super::no_active_record(cluster))?;
        print_current(&current);

        // A rollback writes to the cluster with this Kix, so this Kix must be
        // one that may deploy the cluster, whichever Kix built the target.
        // With `--operator`, the operator checks instead.
        // A dry run writes nothing, so it only warns.
        let downgrade = if args.dry_run {
            super::deploy::stops::warn(cluster, Some(&current));
            None
        } else {
            super::deploy::stops::check(
                cluster,
                Some(&current),
                super::deploy::stops::Writer::Rollback,
            )?
        };

        let superseded = records
            .rollback_targets(cluster)
            .await
            .map_err(|e| miette!("{e}"))?;
        let selected = select_target(args, cluster, &superseded)?;
        let target_hash = target_hash(cluster, selected)?;
        crate::say!(
            "Rollback target:    {} (build {}...)",
            output::bold(&selected.name),
            &target_hash[..8.min(target_hash.len())],
        );
        let p = plan_rollback(
            &client,
            connection,
            &records,
            cluster,
            &current,
            selected,
            flags(args.prune, args.force_conflicts, args.accept_migrations),
        )
        .await?;
        Ok::<_, miette::Report>((current, selected.name.clone(), p, downgrade))
    })?;

    if let Some(version) = &withdrawn_kix {
        p.note_withdrawn_kix(version);
    }
    if let Some(from) = &downgrade {
        p.note_downgrade(from);
    }
    if !super::deploy::migration_gate(&p, Command::Rollback, Runner::Cli) {
        return Ok(Exit::Failure);
    }
    if !output::quiet() {
        print_header(cluster, &target);
    }
    let doc = super::deploy::preview(&mut p, ctx)?;
    if super::deploy::refused(&doc, Command::Rollback) {
        return Ok(Exit::Failure);
    }

    if args.dry_run {
        crate::say!();
        crate::say!(
            "{}",
            output::dim("Dry run. Nothing was applied to the cluster.")
        );
        return Ok(Exit::Success);
    }

    if let Some(connected) = &p.connected
        && ctx
            .runtime()?
            .block_on(super::deploy::start(
                &connected.client,
                &p.checked,
                &connected.last_runs,
            ))
            .is_some()
    {
        crate::say!(
            "Nothing to change. The cluster already matches the target deployment. Nothing was applied to the cluster."
        );
        return Ok(Exit::Success);
    }

    if !super::deploy::confirm(Command::Rollback, cluster, args.yes)? {
        return Ok(Exit::Success);
    }

    let sops = p.sops_sources(false).map_err(|e| miette!("{e}"))?;
    // A rollback passes no receipt, so the target record keeps the receipt
    // its own deploy wrote.
    let end = super::deploy::run_planned(
        ctx,
        Command::Rollback,
        p,
        &RunOptions::rollback(),
        None,
        sops,
        Previous::Active(current.name),
        None,
    )?;
    Ok(Exit::failure_if(!end.succeeded))
}

/// Return the record the user picks from `superseded`, or the most recent
/// one under `--yes` or with no one to ask.
fn select_target<'a>(
    args: &RollbackArgs,
    cluster: &str,
    superseded: &'a [Record],
) -> Result<&'a Record> {
    if superseded.is_empty() {
        return Err(miette!(
            "cannot roll back: no earlier deployment records are available to roll back to. Nothing was applied to the cluster. Next: check out the git commit you want to restore and run `kix deploy {cluster}`."
        ));
    }
    if args.yes || !output::is_interactive() {
        return Ok(&superseded[0]);
    }
    println!();
    println!("Earlier deployments you can roll back to:");
    let mut list = String::new();
    write_earlier_deploys(&mut list, &earlier_deploys(cluster, superseded.to_vec()));
    print!("{list}");

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
    superseded.get(idx).ok_or_else(|| {
        miette!(
            "selection {} is out of range (1-{max}). Nothing was applied to the cluster. Next: enter a number between 1 and {max}.",
            idx + 1,
            max = superseded.len()
        )
    })
}

/// Return the identity hash of rollback target `selected`, which names the
/// build to look for.
fn target_hash<'a>(cluster: &str, selected: &'a Record) -> Result<&'a str> {
    selected.identity_hash.as_deref().ok_or_else(|| {
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
    })
}

async fn run_operator_async(
    args: &RollbackArgs,
    cluster: &str,
    ctx: &CommandContext,
) -> Result<Exit> {
    let (client, records, connection) =
        super::operator::connect_and_verify(ctx.global.context.as_deref()).await?;
    super::operator::require_requests(&client).await?;

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

    let selected = select_target(args, cluster, &superseded)?;

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
        connection,
        &records,
        cluster,
        &current,
        selected,
        flags(true, false, args.accept_migrations),
    )
    .await?;
    if !output::quiet() {
        print_header(cluster, &target_name);
        let fate = plan::orphans_fate(planned.checked.flags(), true, cluster);
        plan::print_checked(&planned.checked, &fate, ctx.global.verbose > 0);
        plan::print_shared(planned.checked.shared_orphans());
    }
    // Enforce `--accept-migrations` on the CLI before delegating to the
    // non-interactive operator.
    if !super::deploy::migration_gate(&planned, Command::Rollback, Runner::Operator) {
        return Ok(Exit::Failure);
    }
    let target_source_path = planned.build.graph().built_via.display().to_string();

    if args.dry_run {
        crate::say!();
        crate::say!(
            "{}",
            output::dim("Dry run. Nothing was applied to the cluster.")
        );
        return Ok(Exit::Success);
    }

    if !args.yes {
        if !output::is_interactive() {
            return Err(output::refuse_unconfirmed(
                output::Unconfirmed::Rollback,
                cluster,
            ));
        }
        print!("\nDelegate rollback to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Rollback cancelled. Nothing was applied to the cluster.");
            return Ok(Exit::Success);
        }
    }

    // The request queues the target record again. The operator then deploys
    // it as a new record and supersedes the current one, as a direct
    // rollback does.
    crate::say!(
        "Asking the Kix operator to restore deployment '{}'...",
        output::bold(&target_name),
    );
    let request = super::operator::apply_activation(
        &records,
        &target_name,
        cluster,
        &target_source_path,
        target_hash.as_deref(),
        planned.checked.kubernetes_uid(),
        // A rollback passes no receipt, so the target record keeps the
        // receipt its own deploy wrote.
        None,
        planned.checked.package_index(),
    )
    .await?;

    crate::say!(
        "  {} Request sent. Waiting for the Kix operator...",
        output::green("✓"),
    );

    let reconciled =
        super::operator::watch_activation_progress(&records, &target_name, &request).await?;

    println!();
    match reconciled {
        super::operator::Reconciled::Active => println!(
            "Rollback via operator {}: restored deployment '{}'.",
            output::green("complete"),
            output::bold(&target_name),
        ),
        super::operator::Reconciled::Degraded => {
            println!(
                "Rollback via operator {}: deployment '{target}' is now current, with status {} (one or more resources failed).",
                output::red("failed"),
                output::yellow("Degraded"),
                target = target_name,
            );
            println!(
                "  Run `kubectl describe {}/{target_name}` to see which resources failed.",
                kix::manifest::keys::ACTIVATIONS_CRD,
            );
        }
    }

    Ok(Exit::failure_if(
        reconciled == super::operator::Reconciled::Degraded,
    ))
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

/// Print the line that heads a rollback's plan.
fn print_header(cluster: &str, target: &str) {
    println!();
    println!(
        "{} restoring cluster '{}' to deployment '{}'",
        output::bold("Rollback:"),
        output::bold(cluster),
        output::bold(target),
    );
}

/// Build [`PlanFlags`] for a rollback.
///
/// A rollback takes conflicting fields only under `--force-conflicts`, and
/// replaces an object that holds data only under `--accept-migrations`, as a
/// deploy does.
fn flags(prune: bool, force_conflicts: bool, accept_migrations: bool) -> PlanFlags {
    PlanFlags {
        prune: PlanFlags::prune_policy_of(prune, false),
        reconcile: false,
        force_conflicts,
        accept_migrations,
        only: Vec::new(),
    }
}

/// Plan a rollback of `cluster` from `current` to `selected`, through
/// `client`, which talks to the Kubernetes cluster of `connection`.
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
    connection: binding::Connection,
    records: &Records,
    cluster: &str,
    current: &Record,
    selected: &Record,
    flags: PlanFlags,
) -> Result<Planned> {
    let build = baseline::target_build(
        cluster,
        &selected.name,
        target_hash(cluster, selected)?,
        selected.built_via.as_deref(),
    )
    .map_err(|e| miette!("{e}"))?;
    let graph = build.graph();
    same_cluster(&selected.name, &graph.cluster_name, cluster)?;
    if let Some(declared) = graph.kubernetes_uid.as_deref() {
        binding::check_declared(
            client,
            &connection,
            binding::Action::Deploy,
            cluster,
            declared,
        )
        .await
        .map_err(|e| miette!("{e}"))?;
    }
    if let Some(line) = kix::cluster::kubernetes_version::note(
        client,
        &connection,
        cluster,
        graph.kubernetes_version.as_deref(),
    )
    .await
    {
        crate::say!("{line}");
    }

    let report = |event: PlanEvent<'_>| plan::progress::print(event);
    Planner::new(flags, &report)
        .rollback(build, records, current, client.clone(), connection)
        .await
        .map_err(|e| miette!("{e}"))
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

    /// A rollback plans with `--accept-migrations` only when the user
    /// passes it, so the gate deploy uses stops it otherwise.
    #[test]
    fn a_rollback_accepts_migrations_only_when_asked() {
        assert!(!flags(false, false, false).accept_migrations);
        assert!(flags(false, false, true).accept_migrations);
    }

    fn record(name: &str, hash: Option<&str>, built_via: Option<&str>) -> Record {
        Record {
            name: name.to_string(),
            identity_hash: hash.map(str::to_string),
            built_via: built_via.map(str::to_string),
            ..Default::default()
        }
    }

    /// `kix history` marks each earlier deploy by what the rollback's own
    /// search finds: a build, no build, or a build that does not load.
    #[test]
    fn history_marks_a_deploy_by_what_rollback_would_find() {
        let records = vec![
            record("found", Some("a"), Some("/nix/store/a-build")),
            record("gone", Some("b"), Some("/nix/store/b-build")),
            record("broken", Some("c"), Some("/nix/store/c-build")),
            record("unhashed", None, None),
        ];
        let deploys = earlier_deploys_with(records, |hash, built_via| match hash {
            "a" => Ok(built_via.map(std::path::PathBuf::from)),
            "b" => Ok(None),
            _ => Err("the build would not load".to_string()),
        });
        let available: Vec<bool> = deploys.iter().map(|d| d.available_locally).collect();
        assert_eq!(available, [true, false, false, false]);

        let mut text = String::new();
        write_earlier_deploys(&mut text, &deploys);
        let lines: Vec<&str> = text.lines().filter(|l| l.contains("deployed")).collect();
        assert!(lines[0].ends_with("[available]"), "{text}");
        assert!(lines[1].ends_with("[build not on this machine]"), "{text}");
        assert!(
            lines[2].ends_with("[build on this machine does not load]"),
            "{text}"
        );
        assert!(lines[3].ends_with("[build not on this machine]"), "{text}");
    }
}
