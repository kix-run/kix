//! Garbage-collect stale kix-managed resources from the cluster.
//!
//! Three modes:
//!   - **Soft (default):** Diff old vs new activation store graphs locally.
//!     Resources only in the old graph are garbage, and so are resources only
//!     in a build the Active record lists under `status.orphansKeptFrom`
//!     (orphans a warn-only deploy kept). Deletes in reverse dependency order
//!     (dependents first). Fast: no cluster-wide resource scan. This is the
//!     same diff that deploy computes; soft GC is "deploy's prune phase, run
//!     separately."
//!   - **Hard (`--hard`):** Builds the cluster now and lists every live
//!     resource carrying the kix label that belongs to this Kix cluster, by
//!     the Activation record hashes in its `kix.run/activations`
//!     (`fetch::SweepScope::Cluster`). A resource whose identity hash is not
//!     in that build is garbage; one stamped before the domain move is judged
//!     by Kubernetes identity instead. Unstamped label carriers are reported
//!     and deleted only with `--include-unstamped`. When another Kix cluster
//!     has records here, objects naming no record at all are reported and
//!     judged only with `--include-unattributed`, and an object another
//!     cluster's current build contains is kept.
//!   - **Operator (`--operator`):** Deletes retired Activation records. They
//!     are Superseded, so the operator's finalizer deletes no resources.
//!
//! Soft and hard mode never delete a kind that `lifecycle::never_pruned`
//! protects (Namespace, CustomResourceDefinition); they list it as kept.
//!
//! In every mode, Superseded Activation records are retired under one
//! retention policy: always keep the `--keep` newest rollback targets
//! (default 10), never more than `--keep-max` records in all (default 50),
//! and beyond the floor retire anything older than `--keep-for` (default
//! 30d). A record of a deploy that never finished is no rollback target: it
//! is kept by age alone, and goes first when the cap is reached. The records
//! are the rollback history, so recent ones stay, but each record still on
//! the cluster keeps one entry alive in `kix.run/activations` on every
//! managed resource, and that annotation has a 256 KiB cap. `activation::retire_plan` decides which go; deletes are
//! conditional on the record being unchanged since it was listed; the next
//! deploy drops the retired hashes from the resources. Soft mode needs the
//! cluster for this, so it is no longer an offline command.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::build_source::{Build, FlakeBuildError};
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::prune_guard::{PruneGuard, Pruned};
use kix::eval::store;
use kix::eval::store_graph::store_hash;
use kix::manifest::lifecycle;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::GcArgs;
use crate::output;
use crate::plan::{self, print_never_pruned};
use kix::plan::baseline;
use kix::plan::split_never_pruned;

use super::CommandContext;

pub fn run(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::Mutating)?;
        return ctx.runtime.block_on(run_operator(args, &cluster, ctx));
    }
    if args.hard {
        run_hard(args, ctx)
    } else {
        run_soft(args, ctx)
    }
}

// ---------------------------------------------------------------------------
// Soft GC: diff old vs new activation store graphs
// ---------------------------------------------------------------------------

fn run_soft(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    // The cache and the records are read before the build, so the name comes
    // from the flake rather than from `new_graph`.
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::Mutating)?;

    // 1. Activation records under the retention policy. Needs the cluster;
    //    done before the build so an unreachable cluster fails fast and the
    //    connection is reused for the deletes.
    let policy = retention_policy(args)?;
    let global = ctx.global.clone();
    let retirement = ctx
        .runtime
        .block_on(plan_record_retirement(&global, &cluster, &policy))?;

    // 2. The old build: the Active record's. The local cache is keyed by
    //    cluster name only, and a build another context deployed under the
    //    same name would make this context's objects look like garbage.
    let (old_path, warning) = baseline::active_build_dir(
        &cluster,
        store::load_activation_path(&cluster),
        retirement.active.as_ref(),
    );
    if let Some(warning) = warning {
        eprintln!("{} {warning}", output::yellow("warning:"));
    }
    let Some(old_result_dir) = old_path else {
        if !ctx.global.quiet {
            let what = if retirement.active.is_some() {
                "The Active build of"
            } else {
                "No Active record, so no previous build, for"
            };
            println!(
                "{what} '{}' is not on this machine. Run {} first, or use {}.",
                output::bold(&cluster),
                output::bold("kix deploy"),
                output::bold("kix gc --hard"),
            );
        }
        return Ok(());
    };

    if !ctx.global.quiet {
        println!("Loading old activation...");
    }
    let old_graph = Build::local(&old_result_dir, &|_| {})
        .map_err(|e| {
            miette!("could not read the previous build's resources and dependencies: {e}")
        })?
        .into_graph();

    // 3. Build new activation
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
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
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }
    // The records and the old build were read under the name resolved before
    // the build. Under any other name they belong to another cluster, and
    // the comparison would list this cluster's objects as garbage.
    if new_graph.cluster_name != cluster {
        return Err(miette!(
            "flake attribute '{}' builds cluster '{}', but the Activation records read before the build are those of cluster '{}'. Nothing was deleted.",
            args.cluster,
            new_graph.cluster_name,
            cluster,
        ));
    }

    // 4. Diff: resources in the old build that the new build no longer has.
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

    // Orphans a warn-only deploy kept. The cached build is usually the one
    // that deploy made, so the diff above cannot see them.
    let kept_baseline = match &retirement.active {
        Some(active) => {
            let quiet = ctx.global.quiet;
            baseline::load_kept(active, None, &cluster, &|e| plan::progress::print(e, quiet))
        }
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
        ctx.runtime.block_on(clear_kept(
            &cluster,
            &retirement,
            kept_baseline.unresolved.is_empty(),
            new_activation_hash.as_deref(),
            ctx.global.quiet,
        ));
        if !ctx.global.quiet {
            println!(
                "{} ({} resources unchanged, {})",
                output::green("No garbage found."),
                new_hashes.len(),
                retirement.kept_note(),
            );
        }
        return Ok(());
    }

    // 5. Reverse-topological ordering for deletion (dependents first so a
    //    provider still exists when its consumer is torn down), less what
    //    another Kix cluster still deploys.
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
        .runtime
        .block_on(fetch::make_client(global.context.as_deref()))
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let (ordered_rids, shared) = ctx
        .runtime
        .block_on(kix::plan::keep_shared(
            &client,
            &new_graph.cluster_name,
            ordered_rids,
        ))
        .map_err(|e| miette!("{e}"))?;

    // 6. Display package-grouped garbage plan.
    //    Always render per-resource detail because the user
    //    must see what exactly will be deleted before confirming.
    if !garbage_manifests.is_empty() {
        let mut pkg_diff = kix::plan::diff_garbage(&old_graph, &new_graph);
        pkg_diff.keep_shared(&shared);
        if !ctx.global.quiet {
            println!();
            println!("{}", output::bold("Garbage collection plan"));
            plan::print_package_plan(&pkg_diff, true);
            plan::print_plan_summary(&pkg_diff);
        }
    }
    let mut kept_rids: Vec<&ResourceId> = kept_rids
        .iter()
        .filter(|r| !lifecycle::never_pruned(&r.kind) && !shared.iter().any(|s| &s.rid == *r))
        .collect();
    if !kept_rids.is_empty() && !ctx.global.quiet {
        println!();
        println!(
            "{}",
            output::bold("Orphans kept by earlier deploys (warn-only)")
        );
        kept_rids.sort();
        for rid in kept_rids {
            println!("  {} {rid}", output::red("-"));
        }
    }
    if !ctx.global.quiet {
        print_record_plan(&retirement, &policy);
        print_never_pruned(&kept);
        plan::print_shared(&shared);
    }
    if ordered_rids.is_empty() && retirement.plan.retire.is_empty() {
        return Ok(());
    }

    // 7. Confirm once for both, delete resources first, then records, then
    //    one summary.
    if !confirm(
        args,
        &deletion_prompt(ordered_rids.len(), retirement.plan.retire.len()),
    )? {
        return Ok(());
    }

    let done = ctx.runtime.block_on(delete_resources(
        &client,
        &new_graph.cluster_name,
        &ordered_rids,
    ))?;
    let (retired, records_failed) = ctx.runtime.block_on(delete_records(&global, &retirement))?;
    if done.failed == 0 && done.changed == 0 {
        ctx.runtime.block_on(clear_kept(
            &cluster,
            &retirement,
            kept_baseline.unresolved.is_empty(),
            new_activation_hash.as_deref(),
            ctx.global.quiet,
        ));
    }
    finish(
        &global,
        done.deleted,
        done.failed + records_failed,
        Some((retired, retirement.plan.kept.len())),
    )
}

/// Manifests from kept closures (`status.orphansKeptFrom`) that the new build
/// no longer has, by the rule [`soft_garbage`] uses, and that `garbage` does
/// not already name by Kubernetes identity.
fn kept_garbage(
    closures: &[Vec<Value>],
    garbage: &HashMap<String, Value>,
    new_hashes: &HashSet<String>,
    new_ids: &HashSet<String>,
) -> Vec<Value> {
    let mut seen: HashSet<String> = garbage.values().map(k8s_identity).collect();
    let mut out = Vec::new();
    for manifest in closures.iter().flatten() {
        let Some(hash) = keys::get(manifest, keys::IDENTITY_HASH) else {
            continue;
        };
        if !lifecycle::lifecycle_of(manifest).prunable()
            || new_hashes.contains(hash)
            || new_ids.contains(&k8s_identity(manifest))
        {
            continue;
        }
        if seen.insert(k8s_identity(manifest)) {
            out.push(manifest.clone());
        }
    }
    out
}

/// Remove `status.orphansKeptFrom` from the Active record once this gc has
/// deleted what it describes, and drop the GC roots this machine keeps for
/// those builds under `cluster`. See [`may_clear_kept`] for when. Best-effort: a list left behind
/// makes the next deploy's plan name objects that are already gone, and
/// deleting those is a no-op.
async fn clear_kept(
    cluster: &str,
    retirement: &RecordRetirement,
    examined_all: bool,
    build_hash: Option<&str>,
    quiet: bool,
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
            if !quiet {
                println!(
                    "  {} Activation/{}: no kept orphans left to record",
                    output::dim("="),
                    active.name
                );
            }
        }
        Err(e) => {
            tracing::warn!(activation = %active.name, error = %e, "could not clear orphansKeptFrom")
        }
    }
}

/// Whether a gc that deleted its garbage without failures may clear the
/// Active record's `orphansKeptFrom`.
///
/// Only when the build gc compared against is the Active one: against a
/// different build, an object the Active build lacks but this build declares
/// was not deleted and is still an orphan. And only when `examined_all`: soft
/// gc resolved every listed build, or hard gc was allowed to list every kind.
fn may_clear_kept(active: &Record, examined_all: bool, build_hash: Option<&str>) -> bool {
    !active.orphans_kept_from.is_empty()
        && examined_all
        && build_hash.is_some()
        && active.identity_hash.as_deref() == build_hash
}

// ---------------------------------------------------------------------------
// Hard GC: full cluster scan
// ---------------------------------------------------------------------------

fn run_hard(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    // 1. Build new activation
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let graph =
        super::build_flake(&ctx.global, &args.cluster, &|_| {}, super::BUILD_FAILED)?.into_graph();

    // 2. Collect expected identity hashes, and the Kubernetes identities
    //    behind them, for objects whose hash cannot be compared.
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

    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} expected resources",
            output::bold(&graph.cluster_name),
            expected_hashes.len(),
        );
    }

    let build_hash = lifecycle::record_of(
        &graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect::<Vec<_>>(),
    )
    .and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(str::to_string));

    // 3. Fetch ALL live kix-managed resources
    let global = ctx.global.clone();
    let cluster_name = graph.cluster_name.clone();
    ctx.runtime.block_on(run_hard_async(
        args,
        &global,
        &expected_hashes,
        &expected_ids,
        &cluster_name,
        build_hash.as_deref(),
    ))
}

async fn run_hard_async(
    args: &GcArgs,
    global: &crate::cli::GlobalArgs,
    expected_hashes: &HashSet<String>,
    expected_ids: &HashSet<String>,
    cluster_name: &str,
    build_hash: Option<&str>,
) -> Result<()> {
    if !global.quiet {
        println!("Fetching live cluster state...");
    }

    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;
    // Only this Kix cluster's objects. Another Kix cluster's objects are
    // absent from this build too, and judging them against it would delete
    // them.
    let sweep = fetch::sweep_managed(
        &client,
        &discovery,
        fetch::SweepScope::Cluster(cluster_name),
    )
    .await
    .map_err(|e| miette!("failed to fetch live resources: {e}"))?;
    let tenancy = sweep.tenancy.clone();

    if !global.quiet {
        println!(
            "Found {} live kix-managed resources ({} unstamped label carriers){}",
            sweep.managed.len(),
            sweep.unstamped.len(),
            crate::output::forbidden_note(&sweep.forbidden),
        );
        for (owner, n) in &sweep.foreign {
            println!(
                "Skipped {n} resources that belong to Kix cluster {}.",
                output::bold(owner)
            );
        }
        if !sweep.unattributed.is_empty() {
            print_unattributed(&sweep.unattributed, args.include_unattributed);
        }
    }
    let forbidden_none = sweep.forbidden.is_empty();
    let unattributed_judged = sweep.unattributed.is_empty() || args.include_unattributed;
    let unattributed = if args.include_unattributed {
        sweep.unattributed
    } else {
        Vec::new()
    };
    let live: Vec<_> = sweep
        .managed
        .into_iter()
        .chain(sweep.unstamped)
        .chain(unattributed)
        .collect();

    // Refuse on a cluster that has been migrated but not deployed since.
    //
    // The expected set above comes from a build made now, so every hash in
    // it is a post-move hash, while every object here still carries the
    // pre-move one. Every single resource would read as HashNotExpected and
    // be deleted. The domain gate cannot catch this: discovery shows only
    // the current group, because the migration is what moved it.
    let stale = live
        .iter()
        .filter(|obj| kix::legacy_domain::stamped_before_move(|key| has_key(obj, key)))
        .count();
    if stale > 0 && !global.quiet {
        println!(
            "{} {stale} resources still carry identity annotations from before the {} \
             move. Their hashes cannot match a build made now, so they are judged by \
             Kubernetes identity instead, the rule soft gc already uses. One deploy \
             re-stamps them.",
            crate::output::yellow("Note:"),
            keys::DOMAIN,
        );
    }

    // Find resources with identity-hash not in expected set.
    // Activation CRs are handled separately below.
    let (mut garbage, shared) = judge_hard(&live, expected_hashes, expected_ids, &tenancy);

    // Superseded Activation records under the retention policy. A listing
    // failure is an error, not an empty list: gc must never plan on a
    // partial view. Listed here for display; deleted with preconditions by
    // `delete_records`, not by kind lookup.
    let policy = retention_policy(args)?;
    // The gate error must not be read as "no Activation CRD". On a cluster
    // still under the retired group, this gc would compare live objects
    // stamped with retired identity hashes against a current build, find no
    // match for most of them, and plan to delete them.
    let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
    let retirement = plan_records_with(records, cluster_name, &policy).await?;
    garbage.extend(record_garbage(&retirement.plan));

    // Unstamped resources carry the kix label but no identity hash: kix never
    // applied them (a controller child that inherited the label, a render
    // someone kubectl-applied). Report them, but delete only on request.
    // Protected kinds stay in `garbage` and are listed as kept below, since
    // --include-unstamped does not delete them either.
    let (unstamped, garbage): (Vec<GarbageEntry>, Vec<GarbageEntry>) =
        garbage.into_iter().partition(|g| {
            g.reason == GarbageReason::NoIdentityHash
                && !args.include_unstamped
                && !lifecycle::never_pruned(&g.id.kind)
        });
    if !unstamped.is_empty() && !global.quiet {
        print_unstamped(&unstamped);
    }

    if !shared.is_empty() && !global.quiet {
        println!();
        plan::print_shared(&shared);
    }

    // Hard gc judges every live object against the build, so once it has
    // deleted without failures no kept orphan is left, whether or not this
    // machine can resolve the builds the Active record names. Kinds the
    // sweep was forbidden to list, and unattributed objects left out without
    // --include-unattributed, were not judged.
    let examined_all = forbidden_none && unattributed_judged;

    if garbage.is_empty() {
        clear_kept(
            cluster_name,
            &retirement,
            examined_all,
            build_hash,
            global.quiet,
        )
        .await;
        if !global.quiet {
            println!(
                "{} ({})",
                output::green("No garbage found."),
                retirement.kept_note()
            );
        }
        return Ok(());
    }

    let (record_entries, resource_entries): (Vec<GarbageEntry>, Vec<GarbageEntry>) = garbage
        .into_iter()
        .partition(|g| g.reason == GarbageReason::RetiredActivation);
    let (kept, resource_entries): (Vec<GarbageEntry>, Vec<GarbageEntry>) = resource_entries
        .into_iter()
        .partition(|g| lifecycle::never_pruned(&g.id.kind));
    if !resource_entries.is_empty() {
        print_garbage_plan(&resource_entries);
    }
    if !global.quiet {
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
    let (retired, records_failed) = delete_records(global, &retirement).await?;
    if done.failed == 0 && done.changed == 0 {
        clear_kept(
            cluster_name,
            &retirement,
            examined_all,
            build_hash,
            global.quiet,
        )
        .await;
    }
    finish(
        global,
        done.deleted,
        done.failed + records_failed,
        Some((retired, retirement.plan.kept.len())),
    )
}

/// Judge each live object of this cluster against the build. Returns the
/// garbage, and apart from it the objects the build dropped that another Kix
/// cluster's current build still contains. Activation records are skipped:
/// retention decides those.
fn judge_hard(
    live: &[kube::api::DynamicObject],
    expected_hashes: &HashSet<String>,
    expected_ids: &HashSet<String>,
    tenancy: &kix::cluster::tenancy::Tenancy,
) -> (Vec<GarbageEntry>, Vec<fetch::SharedOrphan>) {
    let mut garbage: Vec<GarbageEntry> = Vec::new();
    let mut shared: Vec<fetch::SharedOrphan> = Vec::new();
    for obj in live {
        if kix::manifest::lifecycle::lifecycle_of_live(obj)
            == kix::manifest::lifecycle::Lifecycle::Record
        {
            continue; // the retention policy decides records
        }

        let annotations_from_data = obj
            .data
            .pointer("/metadata/annotations")
            .and_then(|a| a.as_object());

        let ann_get = |key: &str| -> Option<String> {
            if let Some(map) = annotations_from_data
                && let Some(v) = map.get(key).and_then(|v| v.as_str())
            {
                return Some(v.to_string());
            }
            obj.metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, key))
                .map(str::to_string)
        };

        let identity_hash = ann_get(keys::IDENTITY_HASH);

        let reason = match &identity_hash {
            Some(hash) if expected_hashes.contains(hash) => continue,
            // An object still stamped by a pre-move Kix cannot be judged by
            // hash at all. Its hash was computed from a store path under the
            // old domain, and the move changed every path, so it can never
            // appear in a current expected set. Judging it by hash would
            // condemn every resource the deploy after a migration has not
            // reached yet, which is most of a cluster.
            //
            // Judge it by Kubernetes identity instead, the rule soft gc and
            // deploy's prune already use. Present in the build means still
            // ours, waiting to be re-stamped. Absent means garbage, whatever
            // it is stamped with.
            Some(_)
                if kix::legacy_domain::stamped_before_move(|key| has_key(obj, key))
                    && expected_ids.contains(&live_identity(obj)) =>
            {
                continue;
            }
            Some(_) => GarbageReason::HashNotExpected,
            None => GarbageReason::NoIdentityHash,
        };

        // A protected kind is kept anyway and listed with the others.
        let others = tenancy.still_deployed_by_others(obj);
        if !others.is_empty() && !lifecycle::never_pruned(&live_kind(obj)) {
            shared.push(fetch::SharedOrphan {
                rid: ResourceId::from_value(&fetch::to_manifest_value(obj)),
                clusters: others,
            });
            continue;
        }

        let kind = live_kind(obj);
        let name = obj
            .metadata
            .name
            .as_deref()
            .unwrap_or("unknown")
            .to_string();
        let namespace = obj
            .metadata
            .namespace
            .as_deref()
            .unwrap_or(CLUSTER_SCOPED)
            .to_string();

        garbage.push(GarbageEntry {
            id: ResourceId {
                kind,
                name,
                namespace,
            },
            identity_hash,
            package: ann_get(keys::PACKAGE),
            package_namespace: ann_get(keys::PACKAGE_NAMESPACE),
            activations: ann_get(keys::ACTIVATIONS),
            reason,
        });
    }
    (garbage, shared)
}

fn live_kind(obj: &kube::api::DynamicObject) -> String {
    obj.data
        .get("kind")
        .and_then(|v| v.as_str())
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("Unknown")
        .to_string()
}

/// Does the object carry this annotation, in its raw data or typed metadata?
fn has_key(obj: &kube::api::DynamicObject, key: &str) -> bool {
    obj.data
        .pointer("/metadata/annotations")
        .and_then(|a| a.as_object())
        .is_some_and(|m| m.contains_key(key))
        || obj
            .metadata
            .annotations
            .as_ref()
            .is_some_and(|a| a.contains_key(key))
}

// ---------------------------------------------------------------------------
// Hard GC: garbage entry + display
// ---------------------------------------------------------------------------

/// Why a live resource is flagged as garbage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GarbageReason {
    /// Resource carries a `kix.run/identity-hash` that isn't in the expected set.
    HashNotExpected,
    /// Resource has no `kix.run/identity-hash` annotation. It looks kix-managed
    /// (matched the managed-by label) but was never properly stamped.
    NoIdentityHash,
    /// An `Activation` CR in phase `Superseded` older than the `--keep`
    /// newest. Rollback history beyond the retention window.
    RetiredActivation,
}

impl GarbageReason {
    fn label(&self) -> &'static str {
        match self {
            GarbageReason::HashNotExpected => "identity-hash not in expected set",
            GarbageReason::NoIdentityHash => "missing identity-hash",
            GarbageReason::RetiredActivation => "superseded activation older than --keep",
        }
    }
}

struct GarbageEntry {
    id: ResourceId,
    identity_hash: Option<String>,
    package: Option<String>,
    package_namespace: Option<String>,
    activations: Option<String>,
    reason: GarbageReason,
}

/// List resources that carry the kix label but were never stamped, and say
/// why gc leaves them alone.
fn print_unstamped(unstamped: &[GarbageEntry]) {
    println!();
    println!(
        "{} {} resources carry the kix label but no {}:",
        output::bold("Unstamped:"),
        unstamped.len(),
        keys::IDENTITY_HASH,
    );
    for entry in unstamped {
        println!(
            "    {} {}/{}/{}",
            output::dim("?"),
            entry.id.namespace,
            entry.id.kind,
            entry.id.name,
        );
    }
    println!(
        "  {}",
        output::dim(
            "kix never applied these, so gc does not delete them. \
             Pass --include-unstamped to delete them too."
        ),
    );
}

/// List the objects that name no Activation record while another Kix cluster
/// has records here, and say whether this run judges them.
fn print_unattributed(objects: &[kube::api::DynamicObject], included: bool) {
    println!();
    println!(
        "{} {} Kix objects name no Activation record on this cluster, and another \
         Kix cluster deploys here, so Kix cannot tell whose they are:",
        output::bold("Unattributed:"),
        objects.len(),
    );
    let mut ids: Vec<ResourceId> = objects
        .iter()
        .map(|o| ResourceId::from_value(&fetch::to_manifest_value(o)))
        .collect();
    ids.sort();
    for rid in &ids {
        println!("    {} {rid}", output::dim("?"));
    }
    let note = if included {
        "--include-unattributed: judged against this build like this cluster's own objects."
    } else {
        "Kept. Review them and pass --include-unattributed to judge them against this build."
    };
    println!("  {}", output::dim(note));
}

/// Print grouped, per-resource garbage plan with reasons and owning activation.
fn print_garbage_plan(garbage: &[GarbageEntry]) {
    use std::collections::BTreeMap;

    println!();
    println!(
        "{} {} resources to delete:",
        output::bold("Garbage:"),
        garbage.len(),
    );

    // Group by (namespace, kind) for readable output.
    let mut by_ns: BTreeMap<&str, BTreeMap<&str, Vec<&GarbageEntry>>> = BTreeMap::new();
    for entry in garbage {
        by_ns
            .entry(entry.id.namespace.as_str())
            .or_default()
            .entry(entry.id.kind.as_str())
            .or_default()
            .push(entry);
    }

    for (ns, by_kind) in &by_ns {
        println!();
        println!("  {}", output::bold(ns));
        for (kind, entries) in by_kind {
            for entry in entries {
                let hash_short = entry
                    .identity_hash
                    .as_deref()
                    .map(|h| format!(" hash={}", &h[..12.min(h.len())]))
                    .unwrap_or_default();
                println!(
                    "    {} {}/{}{}",
                    output::red("-"),
                    kind,
                    entry.id.name,
                    output::dim(&hash_short),
                );

                let reason_line = format!("reason: {}", entry.reason.label());
                println!("        {}", output::dim(&reason_line));

                if let Some(pkg) = &entry.package {
                    let pkg_display = match &entry.package_namespace {
                        Some(pns) if pns != "_cluster" => format!("package: {pns}/{pkg}"),
                        _ => format!("package: {pkg}"),
                    };
                    println!("        {}", output::dim(&pkg_display));
                }
                if let Some(acts) = &entry.activations {
                    let acts_short: Vec<String> = acts
                        .split(',')
                        .map(|a| a.trim())
                        .filter(|a| !a.is_empty())
                        .map(|a| a[..12.min(a.len())].to_string())
                        .collect();
                    if !acts_short.is_empty() {
                        let line = format!("activations: {}", acts_short.join(", "));
                        println!("        {}", output::dim(&line));
                    }
                }
            }
        }
    }
    println!();
}

// ---------------------------------------------------------------------------
// Operator-delegated GC: delete Superseded Activation CRs
// ---------------------------------------------------------------------------

async fn run_operator(args: &GcArgs, cluster: &str, ctx: &CommandContext) -> Result<()> {
    let (_, records) =
        super::operator::connect_and_verify(ctx.global.context.as_deref(), ctx.global.quiet)
            .await?;

    // Superseded activations under the retention policy
    let policy = retention_policy(args)?;
    let retirement = plan_records_with(Some(records.clone()), cluster, &policy).await?;

    if retirement.plan.retire.is_empty() {
        if !ctx.global.quiet {
            println!(
                "{} No activation records to retire ({}).",
                output::green("✓"),
                retirement.kept_note(),
            );
        }
        return Ok(());
    }

    print_record_plan(&retirement, &policy);
    if !ctx.global.quiet {
        println!(
            "  {}",
            output::dim(
                "The operator removes its finalizer from each deleted record; \
                 it deletes no resources for a Superseded record."
            )
        );
    }

    if !confirm(args, &deletion_prompt(0, retirement.plan.retire.len()))? {
        return Ok(());
    }

    // Delete each retired Activation CR (only if unchanged since listed)
    // and watch for finalizer cleanup
    let mut deleted = 0usize;
    let mut failed = 0usize;

    for retired in &retirement.plan.retire {
        let name = &retired.record.name;
        if !ctx.global.quiet {
            println!("Deleting Activation '{}'...", output::bold(name));
        }

        match records.retire(&retired.record).await {
            Ok(_) => {
                // Wait for finalizer to complete deletion
                super::operator::wait_for_deletion(&records, name, ctx.global.quiet).await?;
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
        std::process::exit(1);
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Shared: activation record retention (--keep, --keep-max, --keep-for)
// ---------------------------------------------------------------------------

use kix::cluster::activation::{
    Record, Records, RetentionPolicy, RetireReason, Retirement, retire_plan,
};
use kix::manifest::keys;

/// The policy from the flags. `--keep-max` below `--keep` is raised to it
/// (the floor wins) and said so.
fn retention_policy(args: &GcArgs) -> Result<RetentionPolicy> {
    let keep_for = parse_retention_duration(&args.keep_for)?;
    if args.keep_max < args.keep && !args.yes {
        eprintln!(
            "{}",
            output::yellow(&format!(
                "--keep-max {} is below --keep {}; keeping {}.",
                args.keep_max, args.keep, args.keep
            ))
        );
    }
    if args.keep == 0 && !args.yes {
        eprintln!(
            "{}",
            output::yellow(
                "--keep 0: every rollback target older than --keep-for will be retired."
            )
        );
    }
    Ok(RetentionPolicy {
        keep_min: args.keep,
        keep_max: args.keep_max.max(args.keep),
        keep_for,
        now: chrono::Utc::now(),
    })
}

/// `30d`, `12h`, `45m`, `30s`; a bare number is days; `0` or `off` turns the
/// age rule off.
fn parse_retention_duration(s: &str) -> Result<Option<chrono::Duration>> {
    let s = s.trim();
    if s == "0" || s.eq_ignore_ascii_case("off") || s.eq_ignore_ascii_case("never") {
        return Ok(None);
    }
    let (digits, unit) = match s.find(|c: char| !c.is_ascii_digit()) {
        Some(i) => s.split_at(i),
        None => (s, "d"),
    };
    let n: i64 = digits
        .parse()
        .map_err(|_| miette!("--keep-for: expected a number with d, h, m or s (got '{s}')"))?;
    let d = match unit.trim() {
        "d" | "day" | "days" => chrono::Duration::days(n),
        "h" | "hour" | "hours" => chrono::Duration::hours(n),
        "m" | "min" | "minute" | "minutes" => chrono::Duration::minutes(n),
        "s" | "sec" | "second" | "seconds" => chrono::Duration::seconds(n),
        other => {
            return Err(miette!(
                "--keep-for: unknown unit '{other}' (use d, h, m or s, or 0 to disable)"
            ));
        }
    };
    Ok(Some(d))
}

/// The records to retire, with the handle that listed them so the deletes
/// reuse it. `records` is `None` when the cluster has no Activation CRD, which
/// also means it has no records.
struct RecordRetirement {
    records: Option<Records>,
    plan: Retirement,
    /// The cluster's Active or Degraded record, for its `orphansKeptFrom`.
    active: Option<Record>,
}

impl RecordRetirement {
    fn kept_note(&self) -> String {
        if self.records.is_none() {
            "no Activation records on this cluster".to_string()
        } else {
            format!("{} activation records kept", self.plan.kept.len())
        }
    }
}

/// Connect, then list and plan. A listing failure is an error, never an
/// empty plan.
async fn plan_record_retirement(
    global: &crate::cli::GlobalArgs,
    cluster: &str,
    policy: &RetentionPolicy,
) -> Result<RecordRetirement> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;
    let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
    plan_records_with(records, cluster, policy).await
}

/// List and plan through the opened records.
async fn plan_records_with(
    records: Option<Records>,
    cluster: &str,
    policy: &RetentionPolicy,
) -> Result<RecordRetirement> {
    let Some(records) = records else {
        return Ok(RecordRetirement {
            records: None,
            plan: Default::default(),
            active: None,
        });
    };
    let superseded = records
        .superseded(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;
    let plan = retire_plan(superseded, policy);
    let active = records.active(cluster).await.map_err(|e| miette!("{e}"))?;
    Ok(RecordRetirement {
        records: Some(records),
        plan,
        active,
    })
}

/// Hard-mode garbage entries for the records a plan retires. Never the kept
/// ones.
fn record_garbage(plan: &Retirement) -> Vec<GarbageEntry> {
    plan.retire
        .iter()
        .map(|retired| GarbageEntry {
            id: ResourceId {
                kind: kix::manifest::lifecycle::RECORD_KIND.to_string(),
                namespace: CLUSTER_SCOPED.to_string(),
                name: retired.record.name.clone(),
            },
            identity_hash: retired.record.identity_hash.clone(),
            package: None,
            package_namespace: None,
            activations: None,
            reason: GarbageReason::RetiredActivation,
        })
        .collect()
}

/// One line describing the policy in words.
fn describe_policy(policy: &RetentionPolicy) -> String {
    let age = match policy.keep_for {
        Some(d) => format!(", and anything newer than {}", humanize(d)),
        None => String::new(),
    };
    format!(
        "keeping at least the {} newest, at most {}{age}",
        policy.keep_min,
        policy.keep_max.max(policy.keep_min)
    )
}

/// Why a record is retired, in words.
fn describe_reason(reason: &RetireReason) -> String {
    match reason {
        RetireReason::BeyondMax(n) => format!("beyond the {n} newest"),
        RetireReason::OlderThan(d) => format!("older than {}", humanize(*d)),
        RetireReason::UnknownAge => "age unknown".to_string(),
    }
}

/// `30d`, `12h`, `45m`, `30s`: the largest unit that divides evenly.
fn humanize(d: chrono::Duration) -> String {
    let secs = d.num_seconds();
    if secs > 0 && secs % 86_400 == 0 {
        format!("{}d", secs / 86_400)
    } else if secs > 0 && secs % 3_600 == 0 {
        format!("{}h", secs / 3_600)
    } else if secs > 0 && secs % 60 == 0 {
        format!("{}m", secs / 60)
    } else {
        format!("{secs}s")
    }
}

/// Print which records will go, why, and which stay.
fn print_record_plan(retirement: &RecordRetirement, policy: &RetentionPolicy) {
    let plan = &retirement.plan;
    if plan.retire.is_empty() {
        println!("  {}", output::dim(&retirement.kept_note()));
        return;
    }
    println!();
    println!(
        "{} {} activation record(s), {}:",
        output::bold("Retire:"),
        plan.retire.len(),
        describe_policy(policy),
    );
    for retired in &plan.retire {
        let when = retired
            .record
            .deployed_at
            .clone()
            .filter(|at| !at.is_empty())
            .unwrap_or_else(|| "no deployed-at".to_string());
        println!(
            "  {} Activation/{} {}",
            output::red("-"),
            retired.record.name,
            output::dim(&format!("({when}; {})", describe_reason(&retired.reason)))
        );
    }
    println!(
        "  {}",
        output::dim(&format!(
            "{} kept. Kix cannot roll back to a retired record. The next deploy drops its \
             hash from {} on every resource.",
            plan.kept.len(),
            keys::ACTIVATIONS
        ))
    );
}

/// Delete the retired records, each only if unchanged since it was listed.
/// Returns `(retired, failed)`; the caller prints the summary and sets the
/// exit code.
async fn delete_records(
    global: &crate::cli::GlobalArgs,
    retirement: &RecordRetirement,
) -> Result<(usize, usize)> {
    let Some(records) = &retirement.records else {
        return Ok((0, 0));
    };
    let mut retired = 0usize;
    let mut failed = 0usize;
    for r in &retirement.plan.retire {
        match records.retire(&r.record).await {
            Ok(()) => {
                if !global.quiet {
                    println!(
                        "  {} deleted Activation/{}",
                        output::red("-"),
                        r.record.name
                    );
                }
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

/// The one closing line, then the exit code. `records` is
/// `(retired, kept)` when the run considered records.
fn finish(
    global: &crate::cli::GlobalArgs,
    deleted: usize,
    failed: usize,
    records: Option<(usize, usize)>,
) -> Result<()> {
    if !global.quiet {
        println!();
        let failed_str = failed.to_string();
        let records_note = match records {
            Some((retired, kept)) if retired > 0 || kept > 0 => {
                format!(", {retired} activation record(s) retired, {kept} kept")
            }
            _ => String::new(),
        };
        println!(
            "GC complete: {} deleted, {} failed{records_note}",
            output::green(&deleted.to_string()),
            if failed > 0 {
                output::red(&failed_str)
            } else {
                output::dim(&failed_str)
            },
        );
    }
    if failed > 0 {
        std::process::exit(1);
    }
    Ok(())
}

/// The confirmation question for a deletion of `resources` resources and
/// `records` activation records.
fn deletion_prompt(resources: usize, records: usize) -> String {
    match (resources, records) {
        (0, r) => format!("Delete {r} activation record(s)? [y/N] "),
        (n, 0) => format!("Delete {n} resources? [y/N] "),
        (n, r) => format!("Delete {n} resources and {r} activation record(s)? [y/N] "),
    }
}

/// Ask unless `--yes`. Exits 1 on a non-interactive terminal without
/// `--yes`. Returns `false` when the user declines; the caller returns
/// `Ok(())` so the run ends with exit code 0, as `kix deploy` does.
fn confirm(args: &GcArgs, prompt: &str) -> Result<bool> {
    if args.yes {
        return Ok(true);
    }
    if !output::is_interactive() {
        eprintln!(
            "{}",
            output::yellow("Non-interactive terminal. Use --yes to confirm deletion.")
        );
        std::process::exit(1);
    }
    print!("\n{prompt}");
    std::io::stdout().flush().into_diagnostic()?;
    let mut input = String::new();
    std::io::stdin().read_line(&mut input).into_diagnostic()?;
    let input = input.trim().to_lowercase();
    if input != "y" && input != "yes" {
        println!("GC cancelled.");
        return Ok(false);
    }
    Ok(true)
}

// ---------------------------------------------------------------------------
// Shared: delete a list of resources from the cluster
// ---------------------------------------------------------------------------

/// What [`delete_resources`] did.
#[derive(Debug, Default, PartialEq, Eq)]
struct Deletions {
    deleted: usize,
    failed: usize,
    /// Objects the prune guard left because they changed after it read
    /// them. They are still this cluster's garbage, so the kept-orphan
    /// record must not be cleared.
    changed: usize,
}

/// Delete `cluster`'s garbage in the given order, each through
/// [`PruneGuard`], which keeps an object another Kix cluster's current build
/// still contains or that changed since it was read. The caller prints the
/// summary and sets the exit code. Kinds that `lifecycle::never_pruned`
/// protects are skipped with a message and count as nothing; callers list
/// them with `print_never_pruned` beforehand.
async fn delete_resources(
    client: &kube::Client,
    cluster: &str,
    resources: &[ResourceId],
) -> Result<Deletions> {
    let (resources, kept) = split_never_pruned(resources.to_vec());
    for rid in &kept {
        eprintln!(
            "  {} {}: never deleted automatically; skipping it",
            output::yellow("!"),
            rid
        );
    }
    let mut done = Deletions::default();
    if resources.is_empty() {
        return Ok(done);
    }
    let discovery = fetch::discover_resources(client)
        .await
        .map_err(|e| miette!("{e}"))?;
    let guard = PruneGuard::new(client.clone(), &discovery, cluster);

    for rid in &resources {
        let Some((ar, scope)) = discovery.iter().find(|(ar, _)| ar.kind == rid.kind) else {
            eprintln!(
                "  {} {}: Kubernetes does not recognize this kind; skipping it",
                output::red("!"),
                rid
            );
            done.failed += 1;
            continue;
        };
        match guard
            .delete(ar, scope, rid, &kube::api::DeleteParams::default())
            .await
        {
            Ok(Pruned::Deleted) => {
                println!("  {} deleted {}", output::red("-"), rid);
                done.deleted += 1;
            }
            // A kept orphan someone already removed by hand. Nothing is left
            // to delete, so it is not a failure.
            Ok(Pruned::Gone) => {
                println!("  {} {} already gone", output::dim("="), rid);
            }
            Ok(outcome @ (Pruned::Kept(_) | Pruned::Changed(_))) => {
                if matches!(outcome, Pruned::Changed(_)) {
                    done.changed += 1;
                }
                let reason = outcome.kept_reason().unwrap_or_default();
                println!("  {} prune: {reason}", output::yellow("="));
            }
            Err(e) => {
                eprintln!("  {} {}: {}", output::red("!"), rid, e);
                done.failed += 1;
            }
        }
    }

    Ok(done)
}

/// `kind/namespace/name` for a live object, in the shape [`k8s_identity`]
/// produces for a manifest.
fn live_identity(obj: &kube::api::DynamicObject) -> String {
    let kind = obj
        .data
        .get("kind")
        .and_then(|v| v.as_str())
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("Unknown");
    let namespace = obj
        .metadata
        .namespace
        .as_deref()
        .unwrap_or(kix::manifest::types::CLUSTER_SCOPED);
    let name = obj.metadata.name.as_deref().unwrap_or("unknown");
    format!("{kind}/{namespace}/{name}")
}

/// `kind/namespace/name`, the identity deploy's change detection matches on.
fn k8s_identity(manifest: &Value) -> String {
    let rid = ResourceId::from_value(manifest);
    format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
}

/// Old manifests the new build no longer has, keyed by store hash.
///
/// "No longer has" means the Kubernetes identity (kind, namespace, name) is
/// absent from the new build, the same rule deploy's prune uses. A changed
/// store hash alone is not garbage: the resource still exists under the same
/// name with new content, and soft gc deletes by name, so listing it would
/// delete the live object the new build wants. Before this rule soft gc did
/// exactly that whenever the cached "last deployed" build differed from the
/// live one (found while testing `--keep` against stage2).
///
/// The deploy record is never garbage here either: its store hash changes on
/// every build (kixpkgs#59). Records are retired by `--keep` in every mode.
fn soft_garbage<'a>(
    old: impl IntoIterator<Item = (&'a PathBuf, &'a Value)>,
    new_hashes: &HashSet<String>,
    new_ids: &HashSet<String>,
) -> HashMap<String, Value> {
    let mut garbage = HashMap::new();
    for (path, manifest) in old {
        if lifecycle::is_record(manifest) {
            continue;
        }
        let hash = store_hash(path);
        if new_hashes.contains(&hash) || new_ids.contains(&k8s_identity(manifest)) {
            continue;
        }
        garbage.insert(hash, manifest.clone());
    }
    garbage
}

#[cfg(test)]
mod soft_garbage_tests {
    use super::*;
    use serde_json::json;

    fn path(hash32: &str, name: &str) -> PathBuf {
        PathBuf::from(format!("/nix/store/{hash32}-{name}"))
    }

    #[test]
    fn only_resources_absent_by_identity_are_garbage() {
        let record = json!({"kind": lifecycle::RECORD_KIND, "metadata": {"name": "stage1-aaaa"}});
        let removed = json!({"kind": "ConfigMap", "metadata": {"name": "old", "namespace": "d"}});
        let changed = json!({"kind": "Deployment", "metadata": {"name": "web", "namespace": "d"}});
        let old_record_path = path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "activation");
        let old_cm_path = path("cccccccccccccccccccccccccccccccc", "configmap");
        let old_dep_path = path("dddddddddddddddddddddddddddddddd", "deployment");
        let old = vec![
            (&old_record_path, &record),
            (&old_cm_path, &removed),
            (&old_dep_path, &changed),
        ];
        // The new build: a different record hash, the Deployment with new
        // content (new hash, same name), and no ConfigMap.
        let new_hashes: HashSet<String> = [
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_string(),
            "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee".to_string(),
        ]
        .into();
        let new_ids: HashSet<String> = ["Deployment/d/web".to_string()].into();
        let garbage = soft_garbage(old, &new_hashes, &new_ids);
        assert_eq!(
            garbage.keys().collect::<Vec<_>>(),
            vec!["cccccccccccccccccccccccccccccccc"],
            "the changed Deployment and the rebuilt record are not garbage: {garbage:?}"
        );
    }
}

#[cfg(test)]
mod kept_garbage_tests {
    use super::*;
    use serde_json::json;

    fn m(kind: &str, name: &str, hash: &str) -> Value {
        json!({
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "d",
                "annotations": { keys::IDENTITY_HASH: hash },
            },
        })
    }

    /// Soft gc after a warn-only deploy: the cached build equals the new one,
    /// so only the kept closure names the dropped ConfigMap.
    #[test]
    fn objects_only_a_kept_closure_has_are_garbage_once() {
        let kept = vec![
            vec![
                m("Deployment", "web", "h0"),
                m("ConfigMap", "old", "h1"),
                json!({"kind": lifecycle::RECORD_KIND, "metadata": {"name": "c-v1", "annotations": { keys::IDENTITY_HASH: "h2" }}}),
            ],
            vec![m("ConfigMap", "old", "h1"), m("Secret", "listed", "h3")],
        ];
        let new_hashes: HashSet<String> = ["h9".to_string()].into();
        let new_ids: HashSet<String> = ["Deployment/d/web".to_string()].into();
        let mut already = HashMap::new();
        already.insert("h3".to_string(), m("Secret", "listed", "h3"));

        let got: Vec<String> = kept_garbage(&kept, &already, &new_hashes, &new_ids)
            .iter()
            .map(k8s_identity)
            .collect();
        assert_eq!(got, vec!["ConfigMap/d/old"]);
    }

    /// gc clears the list only against the Active build, only when it
    /// examined everything, and only when there is a list.
    #[test]
    fn kept_list_is_cleared_only_after_a_complete_gc_of_the_active_build() {
        use kix::cluster::activation::KeptOrphanSource;
        let active = |kept: bool| Record {
            name: "c-v2".into(),
            identity_hash: Some("h-v2".into()),
            orphans_kept_from: if kept {
                vec![KeptOrphanSource {
                    activation: "c-v1".into(),
                    identity_hash: "h-v1".into(),
                    built_via: None,
                }]
            } else {
                vec![]
            },
            ..Default::default()
        };
        assert!(may_clear_kept(&active(true), true, Some("h-v2")));
        assert!(!may_clear_kept(&active(false), true, Some("h-v2")));
        assert!(!may_clear_kept(&active(true), false, Some("h-v2")));
        assert!(!may_clear_kept(&active(true), true, Some("h-v3")));
        assert!(!may_clear_kept(&active(true), true, None));
        let unhashed = Record {
            identity_hash: None,
            ..active(true)
        };
        assert!(!may_clear_kept(&unhashed, true, None));
    }
}

#[cfg(test)]
mod record_garbage_tests {
    use super::*;

    fn rec(name: &str, at: &str) -> Record {
        Record {
            name: name.into(),
            identity_hash: Some(format!("{name}hash")),
            deployed_at: Some(at.into()),
            ..Default::default()
        }
    }

    /// Hard mode lists exactly the retired records, never a kept one, as
    /// cluster-scoped Activation entries with the retirement reason.
    #[test]
    fn hard_mode_garbage_is_exactly_the_retired_records() {
        let policy = RetentionPolicy {
            keep_min: 1,
            keep_max: 1,
            keep_for: None,
            now: chrono::Utc::now(),
        };
        let plan = retire_plan(
            vec![
                rec("c-1", "2026-09-01T00:00:00Z"),
                rec("c-2", "2026-09-02T00:00:00Z"),
                rec("c-3", "2026-09-03T00:00:00Z"),
            ],
            &policy,
        );
        let entries = record_garbage(&plan);
        let names: Vec<&str> = entries.iter().map(|e| e.id.name.as_str()).collect();
        assert_eq!(names, vec!["c-2", "c-1"]);
        assert!(entries.iter().all(|e| {
            e.reason == GarbageReason::RetiredActivation
                && e.id.kind == lifecycle::RECORD_KIND
                && e.id.namespace == CLUSTER_SCOPED
        }));
        assert!(!names.contains(&"c-3"), "the kept record is never garbage");
        assert_eq!(entries[0].identity_hash.as_deref(), Some("c-2hash"));
    }

    #[test]
    fn retention_durations_parse() {
        let d = |s: &str| parse_retention_duration(s).unwrap();
        assert_eq!(d("30d"), Some(chrono::Duration::days(30)));
        assert_eq!(d("30"), Some(chrono::Duration::days(30)));
        assert_eq!(d("12h"), Some(chrono::Duration::hours(12)));
        assert_eq!(d("45m"), Some(chrono::Duration::minutes(45)));
        assert_eq!(d("10s"), Some(chrono::Duration::seconds(10)));
        assert_eq!(d("0"), None);
        assert_eq!(d("off"), None);
        assert!(parse_retention_duration("3w").is_err());
        assert!(parse_retention_duration("soon").is_err());
    }

    #[test]
    fn humanize_picks_the_largest_even_unit() {
        use chrono::Duration;
        assert_eq!(humanize(Duration::days(30)), "30d");
        assert_eq!(humanize(Duration::hours(36)), "36h");
        assert_eq!(humanize(Duration::minutes(90)), "90m");
        assert_eq!(humanize(Duration::seconds(45)), "45s");
    }

    #[test]
    fn retire_reasons_in_words() {
        let reason = |r: RetireReason| describe_reason(&r);
        assert_eq!(
            reason(RetireReason::OlderThan(chrono::Duration::days(30))),
            "older than 30d"
        );
        assert_eq!(reason(RetireReason::BeyondMax(3)), "beyond the 3 newest");
        assert_eq!(reason(RetireReason::UnknownAge), "age unknown");
    }
}

#[cfg(test)]
mod prompt_tests {
    use super::deletion_prompt;

    #[test]
    fn prompt_names_what_is_deleted() {
        assert_eq!(deletion_prompt(3, 0), "Delete 3 resources? [y/N] ");
        assert_eq!(
            deletion_prompt(0, 2),
            "Delete 2 activation record(s)? [y/N] "
        );
        assert_eq!(
            deletion_prompt(3, 2),
            "Delete 3 resources and 2 activation record(s)? [y/N] "
        );
    }
}

#[cfg(test)]
mod delete_tests {
    use super::*;
    use kix::cluster::activation::PHASE_ACTIVE;
    use kix::cluster::fake_api::FakeApi;
    use serde_json::json;

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            name: name.into(),
            namespace: CLUSTER_SCOPED.into(),
        }
    }

    /// `delete_resources` drops protected kinds before any request, so a
    /// list of only a CRD and a Namespace deletes nothing.
    #[tokio::test]
    async fn delete_resources_skips_protected_kinds() {
        let api = FakeApi::new([json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "gone" },
        })]);
        let resources = vec![
            rid("CustomResourceDefinition", "widgets.example.com"),
            rid("Namespace", "gone"),
        ];
        let done = delete_resources(&api.client(), "a", &resources)
            .await
            .unwrap();
        assert_eq!(done, Deletions::default());
        assert!(api.requests().is_empty(), "{:?}", api.requests());
    }

    fn record(cluster: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        })
    }

    fn role(name: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": { "name": name, "annotations": { (keys::ACTIVATIONS): activations } },
        })
    }

    /// gc of `a` deletes its own garbage, keeps what `b`'s current build
    /// contains, and leaves an object that changed after the read without
    /// counting it as failed.
    #[tokio::test]
    async fn delete_resources_goes_through_the_prune_guard() {
        let api = FakeApi::new([
            record("a", "a1"),
            record("b", "b1"),
            role("mine", "a1"),
            role("shared", "a1,b1"),
            role("racing", "a1"),
        ]);
        api.after_get("racing", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("a1,b1");
        });
        let resources = vec![
            rid("ClusterRole", "mine"),
            rid("ClusterRole", "shared"),
            rid("ClusterRole", "racing"),
        ];
        let done = delete_resources(&api.client(), "a", &resources)
            .await
            .unwrap();
        assert_eq!(
            done,
            Deletions {
                deleted: 1,
                failed: 0,
                changed: 1,
            }
        );
        assert_eq!(api.names("ClusterRole"), vec!["racing", "shared"]);
    }
}

#[cfg(test)]
mod hard_scope_tests {
    use super::*;
    use kix::cluster::activation::PHASE_ACTIVE;
    use kix::cluster::tenancy::Tenancy;
    use kube::api::DynamicObject;
    use serde_json::json;

    fn live(kind: &str, name: &str, hash: Option<&str>, activations: &str) -> DynamicObject {
        let mut annotations = serde_json::Map::new();
        if let Some(h) = hash {
            annotations.insert(keys::IDENTITY_HASH.into(), json!(h));
        }
        if !activations.is_empty() {
            annotations.insert(keys::ACTIVATIONS.into(), json!(activations));
        }
        serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": { "name": name, "namespace": "d", "annotations": annotations },
        }))
        .unwrap()
    }

    fn record(cluster: &str, hash: &str) -> DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": cluster,
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        }))
        .unwrap()
    }

    fn names(entries: &[GarbageEntry]) -> Vec<&str> {
        let mut v: Vec<&str> = entries.iter().map(|g| g.id.name.as_str()).collect();
        v.sort();
        v
    }

    /// `kix gc a --hard` over a Kubernetes cluster that also runs Kix cluster
    /// `b`: `b`'s objects never reach the plan, an object both deploy is kept,
    /// and objects naming no record are left for the flag.
    #[test]
    fn hard_gc_judges_only_this_clusters_objects() {
        let tenancy = Tenancy::from_records(&[record("a", "a2"), record("b", "b1")], "a");
        let sweep = fetch::partition_sweep(vec![
            live("ConfigMap", "a-current", Some("h-cur"), "a2"),
            live("ConfigMap", "a-stale", Some("h-old"), "a2"),
            live("ConfigMap", "b-web", Some("h-b"), "b1"),
            live("ClusterRole", "shared", Some("h-shared"), "a2,b1"),
            live("ConfigMap", "leftover", Some("h-left"), "retired"),
        ]);
        let sweep = fetch::scope_sweep(sweep, fetch::SweepScope::Cluster("a"), tenancy.clone());
        assert_eq!(sweep.foreign.get("b"), Some(&1));
        assert_eq!(sweep.unattributed.len(), 1);

        let expected: HashSet<String> = ["h-cur".to_string()].into();
        let (garbage, shared) = judge_hard(&sweep.managed, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["a-stale"]);
        assert_eq!(shared.len(), 1);
        assert_eq!(shared[0].rid.name, "shared");
        assert_eq!(shared[0].clusters, vec!["b".to_string()]);

        // --include-unattributed judges the leftover too.
        let mut with_flag = sweep.managed.clone();
        with_flag.extend(sweep.unattributed);
        let (garbage, _) = judge_hard(&with_flag, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["a-stale", "leftover"]);
    }

    /// With one Kix cluster the plan is what it was before scoping: a
    /// leftover naming a retired record is garbage without any flag.
    #[test]
    fn hard_gc_on_a_single_cluster_is_unchanged() {
        let tenancy = Tenancy::from_records(&[record("a", "a2")], "a");
        let sweep = fetch::partition_sweep(vec![
            live("ConfigMap", "a-current", Some("h-cur"), "a2"),
            live("ConfigMap", "leftover", Some("h-left"), "retired"),
        ]);
        let sweep = fetch::scope_sweep(sweep, fetch::SweepScope::Cluster("a"), tenancy.clone());
        assert!(sweep.unattributed.is_empty());
        let expected: HashSet<String> = ["h-cur".to_string()].into();
        let (garbage, shared) = judge_hard(&sweep.managed, &expected, &HashSet::new(), &tenancy);
        assert_eq!(names(&garbage), vec!["leftover"]);
        assert!(shared.is_empty());
    }
}
