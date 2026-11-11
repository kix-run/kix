//! `kix migrate domain <cluster>`: move a cluster's Kix records off a
//! retired API group.
//!
//! Uses the compatibility layer in `cli/kix/src/legacy_domain/`.

use std::io::Write;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use crate::client;
use kix::build_source::InstallableBuild;
use kix::legacy_domain::{KubeMigrationOps, migrate};
use kix::manifest::keys;

use crate::cli::MigrateArgs;
use crate::output;

use super::CommandContext;

pub fn run(args: &MigrateArgs, ctx: &mut CommandContext) -> Result<()> {
    let crds = kix_crds_from_build(args, ctx)?;

    let client = ctx
        .runtime
        .block_on(client::make_client(ctx.global.context.as_deref()))
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let ops = KubeMigrationOps::new(client);

    // Run a dry-run pass first so we can display the migration plan before
    // prompting for confirmation.
    let plan = ctx
        .runtime
        .block_on(migrate::run(&ops, &args.cluster, &crds, true))
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
    if !confirm(args, &from)? {
        return Ok(());
    }

    let report = ctx
        .runtime
        .block_on(migrate::run(&ops, &args.cluster, &crds, false))
        .map_err(|e| miette!("{e}"))?;

    print_report(&args.cluster, &report);
    Ok(())
}

/// Build the cluster and extract Kix's two CustomResourceDefinition manifests.
///
/// Taking the CRDs from the cluster's own build guarantees that the migration
/// installs the exact definitions the next deploy expects.
fn kix_crds_from_build(args: &MigrateArgs, ctx: &mut CommandContext) -> Result<Vec<Value>> {
    crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
    // Stamp the build so the installed CRDs carry an identity hash like every
    // other Kix-managed object. Without a stamp, `kix gc --hard
    // --include-unstamped` would delete `activations.<current>` and cascade
    // to every Activation record on the cluster.
    //
    // `installable()` also rejects builds pinned to a pre-migration revision
    // that still renders CRDs under the retired API group.
    let build = super::build_flake(&ctx.global, &args.cluster, &|_| {}, super::BUILD_FAILED)?
        .installable()
        .map_err(|e| miette!("{e}"))?;
    kix_crds(&build)
}

/// Extract the `Activation` and `PackageInstance` CRD manifests from `build`.
fn kix_crds(build: &InstallableBuild) -> Result<Vec<Value>> {
    let graph = build.graph();
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
             The project's Kix library is older than the domain move; update it first.",
            wanted.join(", ")
        ));
    }
    Ok(crds)
}

fn print_plan(cluster: &str, from: &str, plan: &migrate::Report) {
    let to = keys::GROUP;
    let pi_crd = migrate::crd_name(migrate::PACKAGE_INSTANCE, from);
    let act_crd = migrate::crd_name(migrate::ACTIVATION, from);
    println!();
    println!(
        "{} on '{}': {from} -> {to}",
        output::bold("Domain migration"),
        output::bold(cluster),
    );
    println!();
    println!(
        "  {} deployment record(s) to copy to {to}:",
        plan.activations.len()
    );
    for name in &plan.activations {
        println!("    {name}");
    }
    println!();
    println!("  Then, in the same run:");
    println!("    - remove any Kix operator marks from the old {from} records");
    println!(
        "    - delete the old {pi_crd} and {act_crd} resource types (package records under {pi_crd} are not copied; the next `kix deploy {cluster}` recreates them from the build)"
    );
    println!();
    println!("  Before answering `y`:");
    println!(
        "    If the Kix operator runs on this cluster, scale its Deployment to 0 replicas first. While an older operator watches {from}, deleting {act_crd} would cause it to delete every live workload in the deployment."
    );
    if plan.finalizers_present {
        println!();
        println!("  Note on operator marks:");
        println!(
            "    Some of these deployment records carry a mark written by the Kix operator. Any record the operator ever touched keeps that mark, so the mark alone does not mean an operator is running now. Before copying or deleting anything, this migration clears the marks on the old {from} records, waits briefly, and checks them again. If any mark comes back, an operator is running and the migration stops before copying or deleting anything."
        );
    }
    if plan.current_records.len() > 1 {
        println!();
        println!(
            "  {} ({} records are marked Active or Degraded at once: {}):",
            output::yellow("Warning"),
            plan.current_records.len(),
            plan.current_records.join(", "),
        );
        println!(
            "    The migration copies each deployment record as it is. When more than one record is Active or Degraded, the next `kix deploy {cluster}` compares against the most recently deployed one. If an older record is the one you want as current, or to clean this up before migrating, mark each record that should not be current as Superseded:"
        );
        for name in &plan.current_records {
            println!(
                "      kubectl patch {act_crd}/{name} --subresource=status --type=merge -p '{{\"status\":{{\"phase\":\"Superseded\"}}}}'"
            );
        }
    }
}

fn print_report(cluster: &str, report: &migrate::Report) {
    println!();
    println!(
        "{} {} deployment record(s) copied, {} already present, {} old resource type(s) deleted.",
        output::bold(&format!("Migrated '{cluster}':")),
        report.copied.len(),
        report.already_present.len(),
        report.crds_deleted.len(),
    );
    println!();
    println!("Next:");
    println!(
        "  1. If this cluster runs the Kix operator, upgrade its image to match this version of Kix (so it watches `{}`) and scale it back up.",
        keys::GROUP
    );
    println!(
        "  2. Run `kix deploy {cluster}`. Every resource is applied once to update its Kix tracking annotations. Only pods whose template hashes a ConfigMap or Secret (such as `valkey` or `coredns`) restart."
    );
}

/// Prompt the user for confirmation unless `--yes` was passed.
///
/// Exits with code 1 when stdin is not interactive and `--yes` is absent.
fn confirm(args: &MigrateArgs, from: &str) -> Result<bool> {
    if args.yes {
        return Ok(true);
    }
    if !output::is_interactive() {
        output::refuse_unconfirmed(output::Unconfirmed::MigrateDomain, &args.cluster);
    }
    print!(
        "\nCopy the deployment records and delete the old {} resource types? [y/N] ",
        from
    );
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
