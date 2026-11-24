//! Garbage-collect stale Kix-managed resources from the cluster.
//!
//! Supports three modes:
//! - **Soft (default):** Diff the previous and new activation store graphs
//!   locally, plus any closures listed in the Active record's
//!   `status.orphansKeptFrom` from warn-only deploys. Deletes orphaned
//!   resources in reverse dependency order without scanning every resource kind
//!   on the cluster.
//! - **Full scan (`--full-scan`):** Build the cluster and scan all live Kix-managed
//!   resources attributed to this cluster via `kix.run/activations`
//!   (`inventory::SweepScope::Cluster`). Resources whose `kix.run/identity-hash`
//!   is absent from the new build are garbage (or, for resources stamped before
//!   the domain move, resources whose Kubernetes identity is absent). Unstamped
//!   label carriers, unattributed resources on multi-cluster targets, and
//!   copies other programs made of Kix objects are reported and only deleted when
//!   `--include` names them.
//! - **Operator (`--operator`):** Delete retired Superseded Activation records
//!   and wait for the operator's finalizer.
//!
//! `--dry-run` prints what any mode would delete and changes nothing on the
//! cluster.
//!
//! Soft and full-scan modes never delete resource kinds protected by
//! `lifecycle::never_pruned` (`Namespace`, `CustomResourceDefinition`), listing
//! them as kept instead.
//!
//! All modes retire Superseded Activation records under a shared retention
//! policy (`--keep`, `--keep-max`, and `--keep-for`) via `activation::retire_plan`.
//! Retiring old records bounds the size of the `kix.run/activations` annotation
//! on managed resources, which the next deploy compacts.

mod plan;
mod render;
#[cfg(test)]
mod tests;

use std::collections::HashSet;

use miette::{Result, miette};
use serde_json::Value;

use crate::cli::{GcArgs, Include};
use crate::client;
use crate::exit::{Exit, Stopped};
use crate::output;
use crate::plan::{
    print_never_pruned, print_package_plan, print_plan_summary, print_shared, progress,
};
use kix::build_source::{Build, FlakeBuildError};
use kix::cluster::activation::Records;
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::inventory;
use kix::cluster::prune_guard::{self, Pruned, Removal};
use kix::eval::store;
use kix::eval::store_graph::store_hash;
use kix::manifest::keys;
use kix::manifest::lifecycle;
use kix::manifest::types::ResourceId;
use kix::plan::baseline;
use kix::plan::split_never_pruned;

use self::plan::*;
use self::render::*;
use super::CommandContext;

pub fn run(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::Mutating)?;
        return ctx.runtime()?.block_on(run_operator(args, &cluster, ctx));
    }
    if args.full_scan {
        run_hard(args, ctx)
    } else {
        run_soft(args, ctx)
    }
}

fn run_soft(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    // Resolve the cluster name from the flake before building so we can query
    // the local cache and cluster records first.
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::Mutating)?;

    // Plan Activation record retirement before building so an unreachable
    // cluster fails fast.
    let policy = retention_policy(args)?;
    let global = ctx.global.clone();
    let retirement = ctx
        .runtime()?
        .block_on(plan_record_retirement(&global, &cluster, &policy))?;

    // Validate the cached build path against the Active record so a cache entry
    // written by another context with the same cluster name is not used.
    let (old_path, warning) = baseline::active_build_dir(
        &cluster,
        store::load_activation_path(&cluster),
        retirement.active.as_ref(),
    );
    if let Some(warning) = warning {
        eprintln!("{} {warning}", output::yellow("warning:"));
    }
    let Some(old_result_dir) = old_path else {
        let what = if retirement.active.is_some() {
            "The Active build of"
        } else {
            "No Active record, so no previous build, for"
        };
        crate::say!(
            "{what} '{}' is not on this machine. Run {} first, or use {}.",
            output::bold(&cluster),
            output::bold("kix deploy"),
            output::bold("kix gc --full-scan"),
        );
        return Ok(());
    };

    crate::say!("Loading current deployment's build...");
    let old_graph = Build::local(&old_result_dir, &|_| {})
        .map_err(|e| {
            miette!("could not read the previous build's resources and dependencies: {e}")
        })?
        .into_graph();

    crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
    let status = |msg: &str| output::status_line(msg);
    let flake_path = super::resolve_flake_path(&ctx.global.flake)?;
    let overrides = ctx.global.input_overrides();
    let new_graph = Build::of_flake(&flake_path, &args.cluster, &overrides, &status)
        .map_err(|e| match e {
            FlakeBuildError::Build(e) => miette!("{}: {e}", super::BUILD_FAILED),
            FlakeBuildError::Load(e) => {
                miette!("could not read the new build's resources and dependencies: {e}")
            }
        })?
        .into_graph();
    output::clear_status_line();
    // Refuse to proceed if the built cluster name differs from the pre-build
    // cluster identity used to load the records and previous build.
    if new_graph.cluster_name != cluster {
        return Err(miette!(
            "flake attribute '{}' builds cluster '{}', but the Activation records read before the build are those of cluster '{}'. Nothing was deleted.",
            args.cluster,
            new_graph.cluster_name,
            cluster,
        ));
    }

    let new_hashes: HashSet<String> = new_graph.resources.keys().map(|p| store_hash(p)).collect();
    let new_ids: HashSet<String> = new_graph
        .resources
        .values()
        .map(|r| k8s_identity(&r.manifest))
        .collect();
    let garbage_manifests = soft_garbage(
        old_graph.resources.iter().map(|(p, r)| (p, &r.manifest)),
        &new_hashes,
        &new_ids,
    );

    // Include orphans recorded in `status.orphansKeptFrom` by earlier warn-only
    // deploys, which are absent from `old_graph` when `old_graph` is the latest build.
    let kept_baseline = match &retirement.active {
        Some(active) => baseline::load_kept(active, None, &cluster, &progress::print, None),
        None => baseline::KeptBaseline::default(),
    };
    let kept_garbage = kept_garbage(
        &kept_baseline.closures,
        &garbage_manifests,
        &new_hashes,
        &new_ids,
    );
    let new_activation_hash = lifecycle::record_of(
        &new_graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect::<Vec<_>>(),
    )
    .and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(str::to_string));

    if garbage_manifests.is_empty() && kept_garbage.is_empty() && retirement.plan.retire.is_empty()
    {
        if args.dry_run {
            crate::say!(
                "{}",
                output::green(&format!(
                    "Nothing to delete ({}, {}).",
                    in_use(new_hashes.len()),
                    retirement.kept_note(),
                ))
            );
            return Ok(());
        }
        ctx.runtime()?.block_on(clear_kept(
            &cluster,
            &retirement,
            kept_baseline.unresolved.is_empty(),
            new_activation_hash.as_deref(),
        ));
        crate::say!(
            "{}",
            output::green(&format!(
                "Nothing to delete ({}, {}).",
                in_use(new_hashes.len()),
                retirement.kept_note(),
            ))
        );
        return Ok(());
    }

    // Order deletions in reverse topological order (dependents before
    // dependencies) and exclude resources still deployed by another Kix cluster.
    let kept_rids: Vec<ResourceId> = kept_garbage.iter().map(ResourceId::from_value).collect();
    let garbage_values: Vec<Value> = garbage_manifests
        .values()
        .cloned()
        .chain(kept_garbage)
        .collect();
    let ordered_rids = match ResourceGraph::from_manifests(&garbage_values) {
        Ok(graph) => graph.reverse_topo_ids(),
        Err(_) => garbage_values.iter().map(ResourceId::from_value).collect(),
    };
    let (ordered_rids, kept) = split_never_pruned(ordered_rids);
    let client = ctx
        .runtime()?
        .block_on(client::make_client(global.context.as_deref()))
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    ctx.runtime()?
        .block_on(binding::check(
            &client,
            &binding::Connection::of_context(global.context.as_deref()),
            binding::Action::GarbageCollect,
            &new_graph.cluster_name,
            new_graph.kubernetes_uid.as_deref(),
        ))
        .map_err(|e| miette!("{e}"))?;
    let (ordered_rids, shared) = ctx
        .runtime()?
        .block_on(kix::plan::keep_shared(
            &client,
            &new_graph.cluster_name,
            ordered_rids,
        ))
        .map_err(|e| miette!("{e}"))?;

    if !garbage_manifests.is_empty() {
        let mut pkg_diff = kix::plan::diff_garbage(&old_graph, &new_graph);
        pkg_diff.keep_shared(&shared);
        if !output::quiet() {
            println!();
            println!("{}", output::bold("Garbage collection plan"));
            print_package_plan(&pkg_diff, true);
            print_plan_summary(&pkg_diff);
        }
    }
    let mut kept_rids: Vec<&ResourceId> = kept_rids
        .iter()
        .filter(|r| {
            !lifecycle::never_pruned(r.group_kind()) && !shared.iter().any(|s| &s.rid == *r)
        })
        .collect();
    if !kept_rids.is_empty() {
        crate::say!();
        crate::say!(
            "{}",
            output::bold(&format!(
                "Objects that left the build in earlier deploys, still on the cluster ({} to delete):",
                kept_rids.len()
            ))
        );
        kept_rids.sort();
        for rid in kept_rids {
            crate::say!("  {} {rid}", output::red("-"));
        }
    }
    if !output::quiet() {
        print_record_plan(&retirement, &policy);
        print_never_pruned(&kept);
        print_shared(&shared);
    }
    if ordered_rids.is_empty() && retirement.plan.retire.is_empty() {
        return Ok(());
    }

    if !confirm(
        args,
        &deletion_prompt(ordered_rids.len(), retirement.plan.retire.len()),
    )? {
        return Ok(());
    }

    let done = ctx.runtime()?.block_on(delete_resources(
        &client,
        &new_graph.cluster_name,
        &ordered_rids,
    ))?;
    let (retired, records_failed) = ctx.runtime()?.block_on(delete_records(&retirement))?;
    if done.failed == 0 && done.changed == 0 {
        ctx.runtime()?.block_on(clear_kept(
            &cluster,
            &retirement,
            kept_baseline.unresolved.is_empty(),
            new_activation_hash.as_deref(),
        ));
    }
    finish(
        &args.cluster,
        done.deleted,
        done.failed + records_failed,
        Some((retired, retirement.plan.kept.len())),
    )
}

/// Return `126 objects still in use`: the objects of the current build, which
/// gc does not delete.
fn in_use(objects: usize) -> String {
    match objects {
        1 => "1 object still in use".to_string(),
        n => format!("{n} objects still in use"),
    }
}

/// Clear `status.orphansKeptFrom` on the Active record and remove local GC
/// roots for `cluster` when [`may_clear_kept`] permits.
async fn clear_kept(
    cluster: &str,
    retirement: &RecordRetirement,
    examined_all: bool,
    build_hash: Option<&str>,
) {
    let (Some(records), Some(active)) = (&retirement.records, &retirement.active) else {
        return;
    };
    if !may_clear_kept(active, examined_all, build_hash) {
        return;
    }
    match records.clear_orphans_kept_from(&active.name).await {
        Ok(()) => {
            baseline::sync_kept_roots(cluster, &[]);
            crate::say!(
                "  {} {}: no objects that left the build remain to record",
                output::dim("="),
                active.name
            );
        }
        Err(e) => {
            tracing::warn!(activation = %active.name, error = %e, "could not clear orphansKeptFrom")
        }
    }
}

fn run_hard(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
    let graph =
        super::build_flake(&ctx.global, &args.cluster, &|_| {}, super::BUILD_FAILED)?.into_graph();

    let expected_hashes: HashSet<String> = graph
        .resources
        .values()
        .filter_map(|r| keys::get(&r.manifest, keys::IDENTITY_HASH).map(|s| s.to_string()))
        .collect();
    let expected_ids: HashSet<String> = graph
        .resources
        .values()
        .map(|r| k8s_identity(&r.manifest))
        .collect();

    crate::say!(
        "Cluster {}: {} expected resources",
        output::bold(&graph.cluster_name),
        expected_hashes.len(),
    );

    let build_hash = lifecycle::record_of(
        &graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect::<Vec<_>>(),
    )
    .and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(str::to_string));

    let global = ctx.global.clone();
    let cluster_name = graph.cluster_name.clone();
    ctx.runtime()?.block_on(run_hard_async(
        args,
        &global,
        &expected_hashes,
        &expected_ids,
        &cluster_name,
        graph.kubernetes_uid.as_deref(),
        build_hash.as_deref(),
    ))
}

#[allow(clippy::too_many_arguments)]
async fn run_hard_async(
    args: &GcArgs,
    global: &crate::cli::GlobalArgs,
    expected_hashes: &HashSet<String>,
    expected_ids: &HashSet<String>,
    cluster_name: &str,
    kubernetes_uid: Option<&str>,
    build_hash: Option<&str>,
) -> Result<()> {
    crate::say!("Fetching live cluster state...");

    let client = client::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    binding::check(
        &client,
        &binding::Connection::of_context(global.context.as_deref()),
        binding::Action::GarbageCollect,
        cluster_name,
        kubernetes_uid,
    )
    .await
    .map_err(|e| miette!("{e}"))?;
    let discovery = discovery::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;
    // Open `Records` to enforce the domain migration gate. On an unmigrated
    // cluster, comparing pre-move live identity hashes against a current build
    // would flag almost every resource as garbage.
    let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
    // Scope the sweep to this Kix cluster so another Kix cluster's resources on
    // the same Kubernetes cluster are not flagged as garbage.
    let sweep = inventory::sweep_managed(
        &client,
        &discovery,
        &records,
        inventory::SweepScope::Cluster(cluster_name),
    )
    .await
    .map_err(|e| miette!("failed to fetch live resources: {e}"))?;
    let tenancy = sweep.tenancy.clone();

    if !output::quiet() {
        println!(
            "Found {} live Kix-managed object(s) ({} without a Kix build annotation){}",
            sweep.managed.len(),
            sweep.unstamped.len(),
            crate::output::forbidden_note(&sweep.forbidden),
        );
        if let Some(note) = sweep.foreign_note() {
            println!("{note}");
        }
        if !sweep.unattributed.is_empty() {
            print_unattributed(&sweep.unattributed, args.includes(Include::Unattributed));
        }
        if !sweep.copies.is_empty() {
            print_copies(&sweep.copies, args.includes(Include::Copies));
        }
    }
    let forbidden_none = sweep.forbidden.is_empty();
    let unattributed_judged = sweep.unattributed.is_empty() || args.includes(Include::Unattributed);
    let live = judged_objects(
        sweep,
        args.includes(Include::Unattributed),
        args.includes(Include::Copies),
    );

    // Resources stamped before the domain migration have store hashes under the
    // retired domain that cannot match a current build, so `judge_hard`
    // compares them by Kubernetes identity instead.
    let stale = live
        .iter()
        .filter(|obj| kix::legacy_domain::stamped_before_move(|key| has_key(obj, key)))
        .count();
    if stale > 0 {
        crate::say!(
            "{} {stale} object(s) still carry tracking annotations from before the `{}` \
             move. Their build hashes cannot match a current build, so Kix checks them by \
             Kubernetes kind, namespace, and name instead, the rule `kix gc` without \
             `--full-scan` already uses. One deploy updates their annotations.",
            crate::output::yellow("Note:"),
            keys::DOMAIN,
        );
    }

    let (mut garbage, shared) = judge_hard(&live, expected_hashes, expected_ids, &tenancy);

    // Plan Superseded Activation record retirement. Any listing failure is
    // returned as an error rather than treated as an empty list.
    let policy = retention_policy(args)?;
    let retirement = plan_records_with(records.into_records(), cluster_name, &policy).await?;
    garbage.extend(record_garbage(&retirement.plan));

    // Separate unstamped resources unless `--include unstamped` is set.
    // Protected kinds remain in `garbage` so they are listed as kept below.
    let (unstamped, garbage): (Vec<GarbageEntry>, Vec<GarbageEntry>) =
        garbage.into_iter().partition(|g| {
            g.reason == GarbageReason::NoIdentityHash
                && !args.includes(Include::Unstamped)
                && !lifecycle::never_pruned(g.id.group_kind())
        });
    if !unstamped.is_empty() && !output::quiet() {
        print_unstamped(&unstamped);
    }

    if !shared.is_empty() {
        crate::say!();
        print_shared(&shared);
    }

    // Hard GC has examined all cluster objects when no resource kinds were
    // forbidden and no unattributed objects were skipped.
    let examined_all = forbidden_none && unattributed_judged;

    if garbage.is_empty() {
        if !args.dry_run {
            clear_kept(cluster_name, &retirement, examined_all, build_hash).await;
        }
        crate::say!(
            "{}",
            output::green(&format!("Nothing to delete ({}).", retirement.kept_note()))
        );
        return Ok(());
    }

    let (record_entries, resource_entries): (Vec<GarbageEntry>, Vec<GarbageEntry>) = garbage
        .into_iter()
        .partition(|g| g.reason == GarbageReason::RetiredActivation);
    let (kept, resource_entries): (Vec<GarbageEntry>, Vec<GarbageEntry>) = resource_entries
        .into_iter()
        .partition(|g| lifecycle::never_pruned(g.id.group_kind()));
    if !resource_entries.is_empty() {
        print_garbage_plan(&resource_entries);
    }
    if !output::quiet() {
        let kept: Vec<ResourceId> = kept.into_iter().map(|g| g.id).collect();
        print_never_pruned(&kept);
        print_record_plan(&retirement, &policy);
    }
    if resource_entries.is_empty() && record_entries.is_empty() {
        return Ok(());
    }

    if !confirm(
        args,
        &deletion_prompt(resource_entries.len(), record_entries.len()),
    )? {
        return Ok(());
    }

    let rids: Vec<ResourceId> = resource_entries.iter().map(|g| g.id.clone()).collect();
    let done = delete_resources(&client, cluster_name, &rids).await?;
    let (retired, records_failed) = delete_records(&retirement).await?;
    if done.failed == 0 && done.changed == 0 {
        clear_kept(cluster_name, &retirement, examined_all, build_hash).await;
    }
    finish(
        &args.cluster,
        done.deleted,
        done.failed + records_failed,
        Some((retired, retirement.plan.kept.len())),
    )
}

async fn run_operator(args: &GcArgs, cluster: &str, ctx: &CommandContext) -> Result<()> {
    let (_, records) = super::operator::connect_and_verify(ctx.global.context.as_deref()).await?;

    let policy = retention_policy(args)?;
    let retirement = plan_records_with(Some(records.clone()), cluster, &policy).await?;

    if retirement.plan.retire.is_empty() {
        crate::say!(
            "{} No deployment records to retire ({}).",
            output::green("✓"),
            retirement.kept_note(),
        );
        return Ok(());
    }

    print_record_plan(&retirement, &policy);
    crate::say!(
        "  {}",
        output::dim(
            "The operator removes its finalizer from each deleted deployment record; \
             it deletes no live objects for an earlier deployment record."
        )
    );

    if !confirm(args, &deletion_prompt(0, retirement.plan.retire.len()))? {
        return Ok(());
    }

    let mut deleted = 0usize;
    let mut failed = 0usize;

    for retired in &retirement.plan.retire {
        let name = &retired.record.name;
        crate::say!("Deleting deployment record '{}'...", output::bold(name));

        match records.retire(&retired.record).await {
            Ok(_) => {
                super::operator::wait_for_deletion(&records, name).await?;
                deleted += 1;
            }
            Err(e) => {
                eprintln!("  {} Failed to delete '{}': {}", output::red("!"), name, e);
                failed += 1;
            }
        }
    }

    println!();
    let failed_str = failed.to_string();
    println!(
        "GC via operator complete: {} deleted, {} failed",
        output::green(&deleted.to_string()),
        if failed > 0 {
            output::red(&failed_str)
        } else {
            output::dim(&failed_str)
        },
    );

    if failed > 0 {
        return Err(Stopped(Exit::Failure).into());
    }

    Ok(())
}

/// Delete retired Activation records conditionally on their resource version,
/// returning `(retired, failed)`.
async fn delete_records(retirement: &RecordRetirement) -> Result<(usize, usize)> {
    let Some(records) = &retirement.records else {
        return Ok((0, 0));
    };
    let mut retired = 0usize;
    let mut failed = 0usize;
    for r in &retirement.plan.retire {
        match records.retire(&r.record).await {
            Ok(()) => {
                crate::say!(
                    "  {} deleted Activation/{}",
                    output::red("-"),
                    r.record.name
                );
                retired += 1;
            }
            Err(e) => {
                eprintln!(
                    "  {} Activation/{} not deleted (changed since it was listed?): {}",
                    output::red("!"),
                    r.record.name,
                    e
                );
                failed += 1;
            }
        }
    }
    Ok((retired, failed))
}

/// Counts returned by [`delete_resources`].
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Deletions {
    pub(super) deleted: usize,
    pub(super) failed: usize,
    /// Resources skipped by [`prune_guard::PruneGuard`] because they changed after being
    /// read; their presence prevents `clear_kept` from clearing `orphansKeptFrom`.
    pub(super) changed: usize,
}

/// Delete `resources` for `cluster` in order through
/// [`prune_guard::delete_in_order`], printing a line for each object.
pub(super) async fn delete_resources(
    client: &kube::Client,
    cluster: &str,
    resources: &[ResourceId],
) -> Result<Deletions> {
    let removals = prune_guard::delete_in_order(client, cluster, resources)
        .await
        .map_err(|e| miette!("{e}"))?;
    let mut done = Deletions::default();
    for (rid, removal) in &removals {
        match removal {
            Removal::NeverPruned => {
                eprintln!(
                    "  {} {}: kept because Kix never deletes this kind automatically. Delete it with `kubectl` if you want to remove it.",
                    output::yellow("!"),
                    rid
                );
            }
            Removal::UnknownKind => {
                eprintln!(
                    "  {} {}: not deleted because Kubernetes does not recognize its kind. If its CustomResourceDefinition was removed, Kubernetes already deleted this object with it. Run `kix gc --full-scan` instead to check only objects still on the cluster.",
                    output::red("!"),
                    rid
                );
                done.failed += 1;
            }
            Removal::Pruned(Pruned::Deleted) => {
                println!("  {} deleted {}", output::red("-"), rid);
                done.deleted += 1;
            }
            Removal::Pruned(Pruned::Gone) => {
                println!("  {} {} already gone", output::dim("="), rid);
            }
            Removal::Pruned(outcome @ (Pruned::Kept(_) | Pruned::Changed(_))) => {
                if matches!(outcome, Pruned::Changed(_)) {
                    done.changed += 1;
                }
                let reason = outcome.kept_reason().unwrap_or_default();
                println!("  {} prune: {reason}", output::yellow("="));
            }
            Removal::Failed(e) => {
                eprintln!("  {} {}: {}", output::red("!"), rid, e);
                done.failed += 1;
            }
        }
    }
    Ok(done)
}
