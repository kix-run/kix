//! Garbage-collect stale Kix-managed resources from the cluster.
//!
//! Every mode keeps what the build of the cluster's Active record contains,
//! the build the cluster runs. That build comes from this machine, or from the
//! current files when they make the same build. gc refuses when it has neither
//! (`check_files_build`), so it never deletes an object of the build a
//! rollback restored, or of a deployed build whose files changed since.
//!
//! Supports three modes:
//! - **Soft (default):** Delete the objects of the builds the Active record
//!   lists under `status.orphansKeptFrom` (orphans that warn-only deploys and
//!   rollbacks kept) that the Active build does not contain. Deletes them in
//!   reverse dependency order without scanning every resource kind on the
//!   cluster.
//! - **Full scan (`--full-scan`):** Scan all live Kix-managed resources
//!   attributed to this cluster via `kix.run/activations`
//!   (`inventory::SweepScope::Cluster`). Resources whose `kix.run/identity-hash`
//!   is absent from the Active build are garbage (or, for resources stamped
//!   before the domain move, resources whose Kubernetes identity is absent).
//!   With no Active record, the build from the current files takes its place.
//!   Unstamped label carriers, resources that name no Activation record,
//!   and copies other programs made of Kix objects are reported and only
//!   deleted when `--include` names them.
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
use crate::plan::{KeptFrom, print_never_pruned, print_shared, progress};
use kix::build_source::Build;
use kix::cluster::activation::{Record, Records};
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::cluster::graph::DeleteOrder;
use kix::cluster::inventory;
use kix::cluster::prune_guard::{self, Pruned, Removal, Step};
use kix::cluster::readiness::{self, DeletePath};
use kix::eval::store;
use kix::eval::store_graph::{StoreGraph, store_hash};
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
    let mut retirement = ctx.runtime()?.block_on(plan_record_retirement(
        &global,
        &cluster,
        &policy,
        !args.dry_run,
    ))?;
    if !args.dry_run {
        retirement.check_writer(&cluster)?;
    }

    let Some(active) = &retirement.active else {
        crate::say!(
            "Cluster '{}' has no active deployment record on this cluster, so there is nothing to clean up. Run {} first.",
            output::bold(&cluster),
            output::bold("kix deploy"),
        );
        return Ok(());
    };
    let stopped = match &retirement.records {
        Some(records) => ctx
            .runtime()?
            .block_on(records.stopped(&cluster))
            .map_err(|e| miette!("{e}"))?,
        None => Vec::new(),
    };
    let graph = active_build(args, ctx, &cluster, active, &stopped)?;

    let hashes: HashSet<String> = graph.resources.keys().map(|p| store_hash(p)).collect();
    let ids: HashSet<String> = graph
        .resources
        .values()
        .map(|r| k8s_identity(&r.manifest))
        .collect();
    let kept_baseline = baseline::load_kept(active, None, &cluster, &progress::print, None);
    let garbage = kept_garbage(&kept_baseline.closures, &hashes, &ids);
    let active_hash = active.identity_hash.as_deref();

    if garbage.is_empty() && retirement.plan.retire.is_empty() {
        if !args.dry_run {
            let examined_all = kept_baseline.unresolved.is_empty();
            let active_hash = active_hash.map(str::to_string);
            ctx.runtime()?.block_on(clear_kept_locked(
                &cluster,
                &mut retirement,
                examined_all,
                active_hash.as_deref(),
            ))?;
        }
        crate::say!(
            "{}",
            output::green(&format!(
                "Nothing to delete ({}, {}).",
                in_use(hashes.len()),
                retirement.kept_note(),
            ))
        );
        return Ok(());
    }

    // Order deletions in reverse topological order (dependents before
    // dependencies) and exclude resources still deployed by another Kix cluster.
    // The dependencies come from the Active build too, so one that passes
    // through an object still in use orders the deletes.
    let known: Vec<Value> = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .chain(garbage.iter().cloned())
        .collect();
    let mut order = DeleteOrder::of_manifests(&known);
    let garbage_ids: HashSet<ResourceId> = garbage.iter().map(ResourceId::from_value).collect();
    order.retain(|rid| garbage_ids.contains(rid));
    for rid in &garbage_ids {
        order.push(rid.clone());
    }
    let (ordered_rids, kept) = split_never_pruned(order.ids().to_vec());
    let client = ctx
        .runtime()?
        .block_on(client::make_client(global.context.as_deref()))
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    ctx.runtime()?
        .block_on(binding::check(
            &client,
            &binding::Connection::of_context(global.context.as_deref()),
            binding::Action::GarbageCollect,
            &cluster,
            graph.kubernetes_uid.as_deref(),
        ))
        .map_err(|e| miette!("{e}"))?;
    let (ordered_rids, held) = ctx
        .runtime()?
        .block_on(kix::plan::keep_held(&client, &cluster, ordered_rids))
        .map_err(|e| miette!("{e}"))?;
    let (ordered_rids, shared) = ctx
        .runtime()?
        .block_on(kix::plan::keep_shared(&client, &cluster, ordered_rids))
        .map_err(|e| miette!("{e}"))?;

    let mut listed: Vec<&ResourceId> = ordered_rids
        .iter()
        .filter(|r| !shared.iter().any(|s| &s.rid == *r))
        .collect();
    if !listed.is_empty() {
        crate::say!();
        crate::say!(
            "{}",
            output::bold(&format!(
                "Objects that left the build in earlier deploys, still on the cluster ({} to delete):",
                listed.len()
            ))
        );
        listed.sort();
        for rid in listed {
            crate::say!("  {} {rid}", output::red("-"));
        }
    }
    if !output::quiet() {
        print_record_plan(&retirement, &policy);
        print_never_pruned(&kept, KeptFrom::LeftTheBuild);
        print_shared(&shared);
        print_held(&held, &cluster);
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

    let deleting: HashSet<&ResourceId> = ordered_rids.iter().collect();
    order.retain(|rid| deleting.contains(rid));
    let budget = super::deploy::parse_timeout(args.timeout.as_deref())?;
    let examined_all = kept_baseline.unresolved.is_empty();
    let active_hash = active_hash.map(str::to_string);
    let (done, retired, records_failed) = ctx.runtime()?.block_on(async {
        let lock = retirement.lock(&client, &cluster).await?;
        let deleted = async {
            let done = delete_resources(&lock.guarded(&client), &cluster, order, budget).await?;
            let (retired, records_failed) = delete_records(&retirement).await?;
            if done.all_gone() {
                clear_kept(&cluster, &retirement, examined_all, active_hash.as_deref()).await;
            }
            Ok::<_, miette::Report>((done, retired, records_failed))
        }
        .await;
        super::lock::release(&lock).await;
        deleted
    })?;
    finish(
        &args.cluster,
        done.deleted,
        done.failed + records_failed,
        Some((retired, retirement.plan.kept.len())),
    )
}

/// Return the build that `active` names, the build gc keeps.
///
/// The build comes from this machine's cache or Kix's local store when it is
/// there. Otherwise gc builds the cluster from the current files and uses
/// that build only when it is the same build. gc deletes nothing the Active
/// build contains, so after a rollback, or with files not yet deployed, it
/// never undoes what the cluster runs.
fn active_build(
    args: &GcArgs,
    ctx: &CommandContext,
    cluster: &str,
    active: &Record,
    stopped: &[Record],
) -> Result<StoreGraph> {
    let (dir, warning) =
        baseline::active_build_dir(cluster, store::load_activation_path(cluster), Some(active));
    if let Some(warning) = warning {
        eprintln!("{} {warning}", output::yellow("warning:"));
    }
    if let Some(dir) = dir {
        crate::say!(
            "Loading current deployment's build for '{}'...",
            output::bold(cluster)
        );
        return Ok(Build::local(&dir, &|_| {})
            .map_err(|e| {
                miette!(
                    "could not read the current deployment's local build: {e}. Nothing was deleted."
                )
            })?
            .into_graph());
    }
    let graph = files_build(args, ctx, cluster)?;
    let built = build_hash(&graph);
    check_files_build(cluster, active, built.as_deref(), stopped)?;
    Ok(graph)
}

/// Build `cluster` from the current files.
fn files_build(args: &GcArgs, ctx: &CommandContext, cluster: &str) -> Result<StoreGraph> {
    crate::say!("Building cluster '{}'...", output::bold(&args.cluster));
    let graph =
        super::build_flake(&ctx.global, &args.cluster, &|_| {}, super::BUILD_FAILED)?.into_graph();
    // The records gc read are those of `cluster`, so a flake attribute that
    // builds another cluster must not be judged against them.
    if graph.cluster_name != cluster {
        return Err(miette!(
            "cluster definition '{}' builds cluster '{}', which does not match the deployment records for '{}' on this cluster. Nothing was deleted. Check `name` in your cluster definition, or run `kix gc` with the matching cluster name.",
            args.cluster,
            graph.cluster_name,
            cluster,
        ));
    }
    Ok(graph)
}

/// Return the identity hash of the Activation record in `graph`, which names
/// the whole build.
fn build_hash(graph: &StoreGraph) -> Option<String> {
    let manifests: Vec<Value> = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();
    lifecycle::record_of(&manifests)
        .and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(str::to_string))
}

/// Refuse to collect garbage against a build from the current files that is
/// not the build `active` names. `built` is that build's identity hash.
/// `stopped` is the cluster's Failed and Partial records. When one of them
/// is a deploy with `--only` of the files' build, the refusal says so.
pub(super) fn check_files_build(
    cluster: &str,
    active: &Record,
    built: Option<&str>,
    stopped: &[Record],
) -> Result<()> {
    let active_hash = active.identity_hash.as_deref();
    if built.is_some() && built == active_hash {
        return Ok(());
    }
    let partial = stopped
        .iter()
        .filter(|r| built.is_some() && r.identity_hash.as_deref() == built)
        .find_map(|r| Some((r, r.partly_deployed()?)))
        .map(|(r, p)| {
            format!(
                "\n  Deployment record {} holds the build from your local files, partly deployed: \
                 `kix deploy --only` applied {}. Run `kix deploy {cluster}` to deploy the rest of it.\n",
                r.name,
                p.only.join(", "),
            )
        })
        .unwrap_or_default();
    let short = |h: Option<&str>| match h {
        Some(h) => h[..8.min(h.len())].to_string(),
        None => "unknown".to_string(),
    };
    Err(miette!(
        "local files for '{cluster}' do not match the active deployment on the cluster\n  \
         Nothing was deleted.\n\n  \
         Active on cluster:        {} (build {})\n  \
         Built from local files:   build {}\n{partial}\n  \
         Why:\n    \
         `kix gc` keeps every resource in the active deployment's build and only deletes leftover objects outside it. That deployed build is not in Kix's local store on this machine, and your local files produce a different build, so Kix cannot tell which resources the cluster still needs.\n\n  \
         Next (choose one):\n    \
         - To keep the current deployment and clean up old objects, run `kix gc {cluster}` on the machine that ran the last deploy or rollback (or from a checkout that builds the active deployment).\n    \
         - To deploy your local files and delete resources they removed, run `kix deploy {cluster} --prune`.",
        active.name,
        short(active_hash),
        short(built),
    ))
}

/// Order the garbage `entries` of a full scan by the `kix.run/depends-on`
/// annotations of every `live` object, dependents first, so a stuck delete
/// holds back what it depends on as in the default mode.
fn live_order(live: &[kube::api::DynamicObject], entries: &[GarbageEntry]) -> DeleteOrder {
    let ids: HashSet<&ResourceId> = entries.iter().map(|g| &g.id).collect();
    let manifests: Vec<Value> = live.iter().map(ordering_stub).collect();
    let mut order = DeleteOrder::of_manifests(&manifests);
    order.retain(|rid| ids.contains(rid));
    for entry in entries {
        order.push(entry.id.clone());
    }
    order
}

/// Return the parts of a live object that ordering reads: its identity and
/// its `kix.run/identity-hash` and `kix.run/depends-on` annotations. Leaving
/// out the rest keeps Secret data and managed fields out of memory.
fn ordering_stub(obj: &kube::api::DynamicObject) -> Value {
    let rid = kix::cluster::drift::resource_id(obj);
    let mut annotations = serde_json::Map::new();
    for key in [keys::IDENTITY_HASH, keys::DEPENDS_ON] {
        if let Some(value) = obj
            .metadata
            .annotations
            .as_ref()
            .and_then(|a| keys::get_meta(a, key))
        {
            annotations.insert(key.to_string(), Value::String(value.to_string()));
        }
    }
    let api_version = obj
        .data
        .get("apiVersion")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| obj.types.as_ref().map(|t| t.api_version.clone()))
        .unwrap_or_else(|| {
            if rid.group.is_empty() {
                "v1".to_string()
            } else {
                format!("{}/v1", rid.group)
            }
        });
    let mut metadata = serde_json::json!({ "name": rid.name, "annotations": annotations });
    if rid.namespace != kix::manifest::types::CLUSTER_SCOPED {
        metadata["namespace"] = Value::String(rid.namespace.clone());
    }
    serde_json::json!({ "apiVersion": api_version, "kind": rid.kind, "metadata": metadata })
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

/// Clear `status.orphansKeptFrom` as [`clear_kept`] does, under the deploy
/// lock, which is taken only when there is something to clear.
async fn clear_kept_locked(
    cluster: &str,
    retirement: &mut RecordRetirement,
    examined_all: bool,
    build_hash: Option<&str>,
) -> Result<()> {
    let (Some(records), Some(active)) = (&retirement.records, &retirement.active) else {
        return Ok(());
    };
    if !may_clear_kept(active, examined_all, build_hash) {
        return Ok(());
    }
    let client = records.client().clone();
    let lock = retirement.lock(&client, cluster).await?;
    clear_kept(cluster, retirement, examined_all, build_hash).await;
    super::lock::release(&lock).await;
    Ok(())
}

fn run_hard(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::Mutating)?;
    let global = ctx.global.clone();
    let (active, stopped) = ctx.runtime()?.block_on(async {
        match open_records(&global, &cluster, !args.dry_run).await? {
            Some(records) => {
                let active = records.active(&cluster).await.map_err(|e| miette!("{e}"))?;
                let stopped = records
                    .stopped(&cluster)
                    .await
                    .map_err(|e| miette!("{e}"))?;
                Ok::<_, miette::Report>((active, stopped))
            }
            None => Ok((None, Vec::new())),
        }
    })?;
    // With no Active record the cluster runs no build, so the build from the
    // current files is the only one to compare with.
    let graph = match &active {
        Some(active) => active_build(args, ctx, &cluster, active, &stopped)?,
        None => files_build(args, ctx, &cluster)?,
    };

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

    let compared = match &active {
        Some(active) => format!("the build of active deployment {}", active.name),
        None => {
            "the build from your local files (the cluster has no active deployment)".to_string()
        }
    };
    crate::say!(
        "Cluster {}: {} resources in {compared}",
        output::bold(&graph.cluster_name),
        expected_hashes.len(),
    );

    let build_hash = build_hash(&graph);
    let cluster_name = graph.cluster_name.clone();
    ctx.runtime()?.block_on(run_hard_async(
        args,
        &global,
        &expected_hashes,
        &expected_ids,
        &cluster_name,
        graph.kubernetes_uid.as_deref(),
        build_hash.as_deref(),
        &compared,
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
    compared: &str,
) -> Result<()> {
    // `run_hard` already named the target when it read the Active record.
    let connection = binding::Connection::of_context(global.context.as_deref());
    let client = client::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    crate::say!("Fetching live cluster state...");
    binding::check(
        &client,
        &connection,
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
            print_unattributed(
                &sweep.unattributed,
                args.includes(Include::Unattributed),
                compared,
            );
        }
        if !sweep.copies.is_empty() {
            print_copies(&sweep.copies, args.includes(Include::Copies), compared);
        }
    }
    let forbidden_none = sweep.forbidden.is_empty();
    let unattributed_judged = sweep.unattributed.is_empty() || args.includes(Include::Unattributed);
    let copies: HashSet<ResourceId> = sweep
        .copies
        .iter()
        .map(kix::cluster::drift::resource_id)
        .collect();
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

    let plan::Judged {
        mut garbage,
        shared,
        held,
    } = judge_hard(&live, expected_hashes, expected_ids, &tenancy);

    // Plan Superseded Activation record retirement. Any listing failure is
    // returned as an error rather than treated as an empty list.
    let policy = retention_policy(args)?;
    let mut retirement = plan_records_with(records.into_records(), cluster_name, &policy).await?;
    if !args.dry_run {
        retirement.check_writer(cluster_name)?;
    }
    garbage.extend(record_garbage(&retirement.plan));

    let (unstamped, garbage) =
        hold_back_unstamped(garbage, &copies, args.includes(Include::Unstamped));
    if !unstamped.is_empty() && !output::quiet() {
        print_unstamped(&unstamped);
    }

    if !shared.is_empty() {
        crate::say!();
        print_shared(&shared);
    }
    if !output::quiet() {
        print_held(&held, cluster_name);
    }

    // Hard GC has examined all cluster objects when no resource kinds were
    // forbidden and no unattributed objects were skipped.
    let examined_all = forbidden_none && unattributed_judged;

    if garbage.is_empty() {
        if !args.dry_run {
            clear_kept_locked(cluster_name, &mut retirement, examined_all, build_hash).await?;
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
        print_garbage_plan(&resource_entries, compared);
    }
    if !output::quiet() {
        let kept: Vec<ResourceId> = kept.into_iter().map(|g| g.id).collect();
        print_never_pruned(&kept, KeptFrom::FullScan);
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

    let budget = super::deploy::parse_timeout(args.timeout.as_deref())?;
    let lock = retirement.lock(&client, cluster_name).await?;
    let deleted = async {
        let done = delete_resources(
            &lock.guarded(&client),
            cluster_name,
            live_order(&live, &resource_entries),
            budget,
        )
        .await?;
        let (retired, records_failed) = delete_records(&retirement).await?;
        if done.all_gone() {
            clear_kept(cluster_name, &retirement, examined_all, build_hash).await;
        }
        Ok::<_, miette::Report>((done, retired, records_failed))
    }
    .await;
    super::lock::release(&lock).await;
    let (done, retired, records_failed) = deleted?;
    finish(
        &args.cluster,
        done.deleted,
        done.failed + records_failed,
        Some((retired, retirement.plan.kept.len())),
    )
}

async fn run_operator(args: &GcArgs, cluster: &str, ctx: &CommandContext) -> Result<()> {
    let (_, records, _) =
        super::operator::connect_and_verify(ctx.global.context.as_deref()).await?;

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
    /// Resources kept because an object whose delete did not finish depends
    /// on them.
    pub(super) held: usize,
}

impl Deletions {
    /// Return whether every object gc set out to delete is gone, so
    /// `clear_kept` may forget the builds they came from.
    pub(super) fn all_gone(&self) -> bool {
        self.failed == 0 && self.changed == 0 && self.held == 0
    }
}

/// Delete the objects of `order` for `cluster` through
/// [`prune_guard::delete_in_order`], which waits for each to be gone, and
/// print a line for each object as it happens. `budget` is how long a wait
/// may go without a finalizer being removed (`--timeout`).
pub(super) async fn delete_resources(
    client: &kube::Client,
    cluster: &str,
    order: DeleteOrder,
    budget: std::time::Duration,
) -> Result<Deletions> {
    let mut done = Deletions::default();
    let mut stuck_any = false;
    let mut waiting: std::collections::HashMap<ResourceId, String> = Default::default();
    let mut report = |rid: &ResourceId, step: Step<'_>| {
        let removal = match step {
            Step::Waiting(status) => {
                if waiting.get(rid).map(String::as_str) != Some(status) {
                    println!("  {} {rid} {}", output::dim("…"), output::dim(status));
                    waiting.insert(rid.clone(), status.to_string());
                }
                return;
            }
            Step::Done(removal) => removal,
        };
        match removal {
            Removal::NeverPruned => {
                eprintln!(
                    "  {} {}: kept because Kix never deletes this kind automatically. Delete it with `kubectl` if you want to remove it.",
                    output::yellow("!"),
                    rid
                );
            }
            Removal::Pruned(Pruned::Deleted { .. } | Pruned::AlreadyDeleting { .. }) => {
                println!("  {} deleted {}", output::red("-"), rid);
                done.deleted += 1;
            }
            Removal::Pruned(gone @ (Pruned::Gone | Pruned::NotServed)) => {
                println!(
                    "  {} {} {}",
                    output::dim("="),
                    rid,
                    gone.already_gone().unwrap_or_default()
                );
            }
            Removal::Pruned(outcome @ (Pruned::Kept(_) | Pruned::Changed(_))) => {
                if matches!(outcome, Pruned::Changed(_)) {
                    done.changed += 1;
                }
                let reason = outcome.kept_reason().unwrap_or_default();
                println!("  {} prune: {reason}", output::yellow("="));
            }
            Removal::Stuck(stuck) => {
                eprintln!(
                    "  {} {}",
                    output::red("!"),
                    readiness::stuck_message(rid, stuck)
                );
                stuck_any = true;
                done.failed += 1;
            }
            Removal::HeldBack { by, shared } => {
                println!(
                    "  {} {}",
                    output::yellow("="),
                    readiness::held_back_reason(rid, by, DeletePath::Gc, *shared)
                );
                done.held += 1;
            }
            Removal::Cycle => {
                eprintln!("  {} {}", output::yellow("!"), readiness::cycle_reason(rid));
                done.held += 1;
            }
            Removal::Cancelled => done.held += 1,
            Removal::Failed(e) => {
                eprintln!("  {} {}: {}", output::red("!"), rid, e);
                done.failed += 1;
            }
        }
    };
    prune_guard::delete_in_order(
        client,
        cluster,
        order,
        budget,
        &kix::cluster::cancel::CancelToken::new(),
        &mut report,
    )
    .await
    .map_err(|e| miette!("{e}"))?;
    if stuck_any {
        eprintln!();
        eprintln!("{}", readiness::stuck_explanation(DeletePath::Gc));
    }
    Ok(done)
}
