//! `kix migrate domain <cluster>`: move a cluster's Kix records off a
//! retired API group.
//!
//! Part of the compatibility layer described in
//! `cli/kix/src/legacy_domain/`. It goes when that goes.

use std::io::Write;
use std::path::PathBuf;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::legacy_domain::{KubeMigrationOps, migrate};
use kix::manifest::keys;
use kix::manifest::stamp::stamp_annotations;

use crate::cli::MigrateArgs;
use crate::output;

use super::CommandContext;

pub fn run(args: &MigrateArgs, ctx: &mut CommandContext) -> Result<()> {
    let crds = kix_crds_from_build(args, ctx)?;

    let client = ctx
        .runtime
        .block_on(fetch::make_client(ctx.global.context.as_deref()))
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let ops = KubeMigrationOps::new(client);

    // A dry run first, always: it is the only way to show the plan before
    // asking, and it writes nothing.
    let plan = ctx
        .runtime
        .block_on(migrate::run(&ops, &crds, true))
        .map_err(|e| miette!("{e}"))?;

    if !plan.needed() {
        println!(
            "Cluster '{}' has no Kix records under a retired API group. Nothing to do.",
            output::bold(&args.cluster)
        );
        return Ok(());
    }

    let from = plan.from_group.clone().unwrap_or_default();
    print_plan(&args.cluster, &from, &plan);

    if args.dry_run {
        return Ok(());
    }
    if !confirm(args)? {
        return Ok(());
    }

    let report = ctx
        .runtime
        .block_on(migrate::run(&ops, &crds, false))
        .map_err(|e| miette!("{e}"))?;

    print_report(&report);
    Ok(())
}

/// The two CustomResourceDefinition manifests from the cluster's own build.
///
/// Taken from the build rather than written here, so the migration installs
/// exactly the CRDs the next deploy expects.
fn kix_crds_from_build(args: &MigrateArgs, ctx: &mut CommandContext) -> Result<Vec<Value>> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let noop = |_: &str| {};
    let overrides = ctx.global.input_overrides();
    let result_dir =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &noop)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut graph =
        StoreGraph::from_result_dir_with_status(&result_dir, &noop).map_err(|e| miette!("{e}"))?;
    // A pin from before the domain move renders Kix's own CRDs under the
    // retired group, and this command would then install CRDs synthesised
    // from it. Checked BEFORE stamping, for the same reason `kix deploy`
    // checks before stamping: stamping upgrades a loaded build to the
    // current domain, and after that a stale pin looks exactly like a
    // current one. The `crds.len() != wanted.len()` check below cannot
    // stand in for this, because upgrading is what makes the names match.
    kix::legacy_domain::check_build(
        &graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| miette!("{e}"))?;

    // Stamp, so the CRDs this installs carry an identity hash like every
    // other object Kix applies. An unstamped object carrying the managed-by
    // label is what `kix gc --hard --include-unstamped` deletes, and
    // deleting `activations.<current>` cascades to every Activation record
    // on the cluster.
    stamp_annotations(&mut graph);

    let wanted = [
        migrate::crd_name(migrate::ACTIVATION, keys::GROUP),
        migrate::crd_name(migrate::PACKAGE_INSTANCE, keys::GROUP),
    ];
    let crds: Vec<Value> = graph
        .resources
        .values()
        .map(|r| &r.manifest)
        .filter(|m| {
            m.get("kind").and_then(Value::as_str) == Some("CustomResourceDefinition")
                && m.pointer("/metadata/name")
                    .and_then(Value::as_str)
                    .is_some_and(|n| wanted.iter().any(|w| w == n))
        })
        .cloned()
        .collect();

    if crds.len() != wanted.len() {
        return Err(miette!(
            "this build does not render Kix's own CustomResourceDefinitions ({}). \
             The kixpkgs pin is older than the domain move; update it first.",
            wanted.join(", ")
        ));
    }
    Ok(crds)
}

fn print_plan(cluster: &str, from: &str, plan: &migrate::Report) {
    println!();
    println!(
        "{} on '{}': {} → {}",
        output::bold("Domain migration"),
        output::bold(cluster),
        from,
        keys::GROUP,
    );
    println!();
    println!("  {} activation records to copy:", plan.activations.len());
    for name in &plan.activations {
        println!("    {name}");
    }
    println!();
    println!("  Then, in the same run:");
    println!("    clear the operator finalizer from the old records");
    println!(
        "    delete {} and {}",
        migrate::crd_name(migrate::PACKAGE_INSTANCE, from),
        migrate::crd_name(migrate::ACTIVATION, from),
    );
    println!();
    println!(
        "  {}",
        output::dim(
            "PackageInstance records are not copied. The next deploy re-creates \
             them from the build, import markers included."
        )
    );
    println!(
        "  {}",
        output::dim(
            "Scale the kix operator to 0 first if this cluster runs one. While it \
             watches the old group it re-adds its finalizer, and deleting the old \
             CRDs would then make it delete every resource in the activation."
        )
    );
    if plan.current_records.len() > 1 {
        println!();
        println!(
            "  {} {} records are Active or Degraded at once: {}.",
            output::yellow("Warning:"),
            plan.current_records.len(),
            plan.current_records.join(", "),
        );
        println!("  The migration copies every phase as it finds it, so this is not its");
        println!("  doing and it will not make it worse. But the deploy after it picks");
        println!("  whichever the apiserver returns first, which may be the wrong build.");
        println!("  Supersede the ones that are not current before deploying.");
    }
    if plan.finalizers_present {
        println!();
        println!("  Some of these records carry the operator's finalizer. That alone does");
        println!("  not mean an operator is running: it is added on every reconcile and");
        println!("  removed only when a record is deleted, so a record one ever touched");
        println!("  keeps it. The migration clears them, waits, and reads them back. If any");
        println!("  returns, an operator is running and the migration stops there, having");
        println!("  copied and deleted nothing.");
    }
}

fn print_report(report: &migrate::Report) {
    println!();
    println!(
        "{} {} copied, {} already present, {} CRDs deleted.",
        output::bold("Migrated:"),
        report.copied.len(),
        report.already_present.len(),
        report.crds_deleted.len(),
    );
    println!();
    println!("Next:");
    println!("  If this cluster runs the kix operator, upgrade its image and scale");
    println!("  it back up. It watches the new group.");
    println!("  Then deploy. Every resource is applied once, to move its annotations.");
    println!("  Almost nothing restarts: a package that hashes a ConfigMap into its");
    println!("  pod template rolls its pods once (valkey, n8n).");
}

/// Ask unless `--yes`. Exits 1 on a non-interactive terminal without `--yes`,
/// as `kix gc` does.
fn confirm(args: &MigrateArgs) -> Result<bool> {
    if args.yes {
        return Ok(true);
    }
    if !output::is_interactive() {
        eprintln!(
            "{}",
            output::yellow("Non-interactive terminal. Use --yes to confirm the migration.")
        );
        std::process::exit(1);
    }
    print!("\nCopy the records and delete the old CRDs? [y/N] ");
    std::io::stdout().flush().into_diagnostic()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).into_diagnostic()?;
    let input = input.trim().to_lowercase();
    if input != "y" && input != "yes" {
        println!("Migration cancelled.");
        return Ok(false);
    }
    Ok(true)
}

fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
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
