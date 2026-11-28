//! Garbage-collect stale Kix-managed resources from the cluster.
//!
//! Every mode keeps what the build of the cluster's Active record contains,
//! the build the cluster runs. That build comes from this machine, or from the
//! current files when they make the same build. gc refuses when it has neither
//! (`check_files_build`), so it never deletes an object of the build a
//! rollback restored, or of a deployed build whose files changed since.
//!
//! Supports three modes:
//! - **Soft (default):** Delete the objects the Active record lists as kept
//!   orphans (orphans that warn-only deploys and rollbacks kept) that the
//!   Active build does not contain: the objects its kept-orphans revision
//!   names, or the objects of the builds it lists under
//!   `status.orphansKeptFrom` for a Kix cluster not read from revisions
//!   ([`Tenancy::kept`]). Deletes them in reverse dependency order without
//!   scanning every resource kind on the cluster, then names a kept-orphans
//!   revision of what remains on the record.
//! - **Full scan (`--full-scan`):** Scan all live Kix-managed resources
//!   that belong to this cluster ([`Tenancy`],
//!   `inventory::SweepScope::Cluster`). Resources whose kind, namespace, and
//!   name the Active build does not make are garbage, unless a record of the
//!   Kix cluster that may still be deploying names them or another Kix
//!   cluster deploys them. For a Kix cluster read from revisions, only the
//!   objects the kept-orphans revision alone names are garbage.
//!   With no Active record, the build from the current files takes its place.
//!   Resources that name no Activation record, and copies other programs
//!   made of Kix objects, are reported and only deleted when `--include`
//!   names them.
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
use kix::cluster::activation::{OpenedRecords, Record, Records};
use kix::cluster::binding;
use kix::cluster::discovery;
use kix::cluster::edges::Edges;
use kix::cluster::graph::DeleteOrder;
use kix::cluster::inventory;
use kix::cluster::prune_guard::{self, Pruned, Removal, Step};
use kix::cluster::readiness::{self, DeletePath};
use kix::cluster::revision::{
    self, Revision, RevisionImport, RevisionObject, RevisionSpec, Revisions, Slot, keep,
};
use kix::cluster::tenancy::{self, Kept, Source, Tenancy};
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
    let records = retirement.records.clone().ok_or_else(|| {
        miette!("could not read deployment records for '{cluster}'. Nothing was deleted.")
    })?;
    let tenancy = ctx.runtime()?.block_on(read_tenancy(&records, &cluster))?;
    let kept_baseline = ctx.runtime()?.block_on(async {
        let discovery = match tenancy.own_source() {
            Source::Revisions => discovery::discover_resources(records.client())
                .await
                .map_err(|e| miette!("{e}"))?,
            Source::Records => Vec::new(),
        };
        baseline::kept_of(
            records.client(),
            &discovery,
            &tenancy,
            active,
            None,
            &Default::default(),
            &progress::print,
            None,
        )
        .await
        .map_err(|e| miette!("{e}"))
    })?;
    let garbage = kept_garbage(&kept_baseline.closures, &ids);
    let update = KeptUpdate::of(
        &kept_baseline,
        &graph,
        active.identity_hash.as_deref(),
        kept_baseline.unresolved.is_empty(),
    );

    if garbage.is_empty() && retirement.plan.retire.is_empty() {
        if !args.dry_run {
            ctx.runtime()?
                .block_on(clear_kept_locked(&cluster, &mut retirement, &update))?;
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

    // Exclude resources still deployed by another Kix cluster below.
    let built: Vec<Value> = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();
    let mut order = soft_order(built, &garbage, &tenancy);
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
    let (done, retired, records_failed) = ctx.runtime()?.block_on(async {
        let lock = retirement.lock(&client, &cluster).await?;
        let deleted = async {
            let done = delete_resources(&lock.guarded(&client), &cluster, order, budget).await?;
            let (retired, records_failed) = delete_records(&retirement).await?;
            update_kept(&cluster, &retirement, &update, &done).await?;
            clean_revisions(&cluster, &retirement).await;
            Ok::<_, miette::Report>((done, retired, records_failed))
        }
        .await;
        super::lock::release(&lock).await;
        deleted
    })?;
    finish(
        &args.cluster,
        done.deleted,
        done.failed + done.changed + records_failed,
        done.left(),
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
                "\n  Deployment record {} already deployed part of your local build (`kix deploy --only` \
                 applied {}). Run `kix deploy {cluster}` to finish deploying it, then run `kix gc {cluster}` again.\n",
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

/// Order the kept orphans `garbage` of the default mode in reverse
/// topological order, dependents before dependencies. The dependencies come
/// from the Active build `built` too, so one that passes through an object
/// still in use orders the deletes. For a Kix cluster read from revisions the
/// garbage manifests are live objects, so their edges come from the
/// revisions. Otherwise they come from the builds that kept them.
fn soft_order(built: Vec<Value>, garbage: &[Value], tenancy: &Tenancy) -> DeleteOrder {
    let edges = match tenancy.own_source() {
        Source::Revisions => Edges::of_build(&built).or(Edges::of_own_revisions(tenancy, garbage)),
        Source::Records => Edges::of_build(&[built.as_slice(), garbage].concat()),
    };
    let known: Vec<Value> = built.into_iter().chain(garbage.iter().cloned()).collect();
    let mut order = DeleteOrder::of(&known, &edges);
    let garbage_ids: HashSet<ResourceId> = garbage.iter().map(ResourceId::from_value).collect();
    order.retain(|rid| garbage_ids.contains(rid));
    for rid in garbage.iter().map(ResourceId::from_value) {
        order.push(rid);
    }
    order
}

/// Order the garbage `entries` of a full scan by the edges between the
/// `live` objects, dependents first, so a stuck delete holds back what it
/// depends on as in the default mode. The edges come from the revisions of
/// the Kix cluster `tenancy` is read for. An object no revision names has
/// none. For a Kix cluster whose records an older Kix wrote, which have no
/// revisions, they come from the notes on the live objects.
fn live_order(
    live: &[kube::api::DynamicObject],
    entries: &[GarbageEntry],
    tenancy: &Tenancy,
) -> DeleteOrder {
    let ids: HashSet<&ResourceId> = entries.iter().map(|g| &g.id).collect();
    let manifests: Vec<Value> = live.iter().map(ordering_stub).collect();
    let edges = match tenancy.own_source() {
        Source::Revisions => Edges::of_own_revisions(tenancy, &manifests),
        Source::Records => Edges::of_older_kix_notes(&manifests),
    };
    let mut order = DeleteOrder::of(&manifests, &edges);
    order.retain(|rid| ids.contains(rid));
    for entry in entries {
        order.push(entry.id.clone());
    }
    order
}

/// Return the parts of a live object that ordering reads: its identity and
/// its `kix.run/identity-hash` and `kix.run/depends-on` annotations, which
/// order only the objects of records without revisions or with format 1
/// ones. Leaving out the rest keeps Secret data and managed fields out of
/// memory.
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

/// What gc writes about the objects earlier deploys left, once it has
/// deleted what it could.
pub(super) enum KeptUpdate {
    /// The Active record lists whole builds under `status.orphansKeptFrom`.
    /// gc clears the list when [`may_clear_kept`] permits and every object
    /// it set out to delete is gone.
    Builds {
        listed: bool,
        examined_all: bool,
        build_hash: Option<String>,
    },
    /// The Active record's kept-orphans revision names `listed`. gc writes
    /// a new one that names what remains: the objects that are not known to
    /// be gone, because they are still on the cluster (`live`) or the read
    /// could not tell (`unknown`), that gc did not delete and that the
    /// Active build does not hold (`in_build`).
    Objects {
        listed: Vec<RevisionObject>,
        /// The import markers the revision lists. The new one lists those
        /// the remaining objects depend on.
        imports: Vec<RevisionImport>,
        live: HashSet<ResourceId>,
        unknown: HashSet<ResourceId>,
        in_build: HashSet<ResourceId>,
    },
}

impl KeptUpdate {
    /// Return the update for a soft gc that read `kept` against the Active
    /// build `graph`, whose Activation record has identity hash
    /// `build_hash`.
    fn of(
        kept: &baseline::KeptBaseline,
        graph: &StoreGraph,
        build_hash: Option<&str>,
        examined_all: bool,
    ) -> KeptUpdate {
        match &kept.listed {
            Some(listed) => KeptUpdate::Objects {
                listed: listed.clone(),
                imports: kept.imports.clone(),
                live: kept
                    .closures
                    .iter()
                    .flatten()
                    .map(ResourceId::from_value)
                    .collect(),
                unknown: kept.unknown.clone(),
                in_build: ids_of(graph),
            },
            None => KeptUpdate::Builds {
                listed: !kept.sources.is_empty() || !kept.unresolved.is_empty(),
                examined_all,
                build_hash: build_hash.map(str::to_string),
            },
        }
    }

    /// Return the objects that remain kept after gc found `gone` gone, or
    /// `None` when the list stays as it is.
    fn remaining(&self, gone: &HashSet<ResourceId>) -> Option<Vec<RevisionObject>> {
        let KeptUpdate::Objects {
            listed,
            live,
            unknown,
            in_build,
            ..
        } = self
        else {
            return None;
        };
        let remaining: Vec<RevisionObject> = listed
            .iter()
            .filter(|o| {
                let rid = o.resource_id();
                (live.contains(&rid) || unknown.contains(&rid))
                    && !gone.contains(&rid)
                    && !in_build.contains(&rid)
            })
            .cloned()
            .collect();
        (remaining.len() != listed.len()).then_some(remaining)
    }

    /// Return whether gc must write to the Active record when it deletes
    /// nothing.
    fn writes_without_deletes(&self, active: &Record) -> bool {
        match self {
            KeptUpdate::Builds {
                listed,
                examined_all,
                build_hash,
            } => *listed && may_clear_kept(active, *examined_all, build_hash.as_deref()),
            KeptUpdate::Objects { .. } => self.remaining(&HashSet::new()).is_some(),
        }
    }
}

/// Return the group, kind, namespace, and name of every object of `graph`.
fn ids_of(graph: &StoreGraph) -> HashSet<ResourceId> {
    graph
        .resources
        .values()
        .map(|r| ResourceId::from_value(&r.manifest))
        .collect()
}

/// Write what `update` says about the kept orphans to the Active record,
/// after gc deleted what `done` reports. Call it after
/// [`RecordRetirement::lock`], so the writes go through the lock.
///
/// For a record that lists builds, clear `status.orphansKeptFrom` and
/// remove local GC roots for `cluster` when every object gc set out to
/// delete is gone and [`may_clear_kept`] permits, and only warn when the
/// write fails. For a record with a kept-orphans revision, create a revision
/// of what remains and name it on the record, or remove the name and the
/// list when nothing remains. Refuse when that write fails, because the old
/// revision would go on naming deleted objects.
async fn update_kept(
    cluster: &str,
    retirement: &RecordRetirement,
    update: &KeptUpdate,
    done: &Deletions,
) -> Result<()> {
    let (Some(records), Some(active)) = (&retirement.records, &retirement.active) else {
        return Ok(());
    };
    match update {
        KeptUpdate::Builds {
            listed,
            examined_all,
            build_hash,
        } => {
            if *listed
                && done.all_gone()
                && may_clear_kept(active, *examined_all, build_hash.as_deref())
            {
                clear_kept(cluster, records, active).await;
            }
            Ok(())
        }
        KeptUpdate::Objects { imports, .. } => {
            let Some(remaining) = update.remaining(&done.gone) else {
                return Ok(());
            };
            if remaining.is_empty() {
                records
                    .clear_orphans_kept_from(active)
                    .await
                    .map_err(|e| miette!("{e}"))?;
                baseline::sync_kept_roots(cluster, &[]);
                crate::say!(
                    "  {} {}: cleared kept-orphans list (no kept orphaned objects remain to track)",
                    output::dim("="),
                    active.name
                );
                return Ok(());
            }
            let revision = Revision::new(
                RevisionSpec::new(cluster, Slot::KeptOrphans, remaining)
                    .with_imports_reached(imports.iter().cloned()),
            );
            Revisions::new(records.client())
                .create(&revision)
                .await
                .map_err(|e| miette!("{e}"))?;
            records
                .name_kept_orphans(&active.name, &revision.name)
                .await
                .map_err(|e| miette!("{e}"))?;
            Ok(())
        }
    }
}

/// Clear `status.orphansKeptFrom` on `active`, and remove local GC roots for
/// `cluster`. A failed write only warns, because the next gc clears it.
async fn clear_kept(cluster: &str, records: &Records, active: &Record) {
    match records.clear_orphans_kept_from(active).await {
        Ok(()) => {
            baseline::sync_kept_roots(cluster, &[]);
            crate::say!(
                "  {} {}: cleared kept-orphans list (no kept orphaned objects remain to track)",
                output::dim("="),
                active.name
            );
        }
        Err(e) => {
            tracing::warn!(activation = %active.name, error = %e, "could not clear orphansKeptFrom")
        }
    }
}

/// Write what `update` says about the kept orphans when gc deletes nothing,
/// and delete the revisions no record needs, under the deploy lock. The
/// lock is taken only when there is something to write or delete.
async fn clear_kept_locked(
    cluster: &str,
    retirement: &mut RecordRetirement,
    update: &KeptUpdate,
) -> Result<()> {
    let Some(records) = &retirement.records else {
        return Ok(());
    };
    let write = retirement
        .active
        .as_ref()
        .is_some_and(|active| update.writes_without_deletes(active));
    let unneeded = match keep::unneeded(records.client(), records, cluster).await {
        Ok(names) => !names.is_empty(),
        Err(e) => {
            tracing::warn!(
                error = %e,
                "could not list unused PackageInstanceRevision objects; unless this run updates the kept-orphans list, revision cleanup will wait until the next deploy or `kix gc`"
            );
            false
        }
    };
    if !write && !unneeded {
        return Ok(());
    }
    let client = records.client().clone();
    let lock = retirement.lock(&client, cluster).await?;
    let written = update_kept(cluster, retirement, update, &Deletions::default()).await;
    clean_revisions(cluster, retirement).await;
    super::lock::release(&lock).await;
    written
}

/// Read which objects the Kix clusters on the cluster deploy, for gc of
/// `cluster`, and refuse when part of it cannot be read.
async fn read_tenancy(records: &Records, cluster: &str) -> Result<Tenancy> {
    let tenancy = tenancy::read(&OpenedRecords::from(records.clone()), cluster)
        .await
        .map_err(|e| miette!("{e}"))?;
    tenancy
        .complete()
        .map_err(|e| miette!("{e}. Nothing was deleted."))?;
    Ok(tenancy)
}

/// Delete the revisions no record of `cluster` needs. Call it after
/// [`RecordRetirement::lock`], so the records write through the lock. A
/// failure only warns, because the next deploy or `kix gc` deletes them.
async fn clean_revisions(cluster: &str, retirement: &RecordRetirement) {
    let Some(records) = &retirement.records else {
        return;
    };
    if let Err(e) = keep::clean(records.client(), records, cluster).await {
        tracing::warn!(error = %e, "could not delete unused PackageInstanceRevision objects; the next deploy or `kix gc` will delete them");
    }
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
        expected_ids.len(),
    );

    let build_hash = build_hash(&graph);
    let cluster_name = graph.cluster_name.clone();
    let in_build = ids_of(&graph);
    ctx.runtime()?.block_on(run_hard_async(
        args,
        &global,
        &expected_ids,
        &in_build,
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
    expected_ids: &HashSet<String>,
    in_build: &HashSet<ResourceId>,
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
    if !args.dry_run {
        super::operator::refuse_older_operator(&client, cluster_name).await?;
    }
    // A write that the scan below decides is bound to the generation read
    // before it, so a run that changed the Kix cluster since refuses it.
    let generation = kix::cluster::head::generation_of(
        kix::cluster::head::read(&client, cluster_name)
            .await
            .map_err(|e| miette!("{e}"))?
            .as_ref(),
    );
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
    if tenancy.only_kept_unreadable() {
        return rebuild_kept_list(
            args,
            global,
            &client,
            &records,
            &sweep,
            (expected_ids, in_build),
            (cluster_name, generation),
            kubernetes_uid,
            build_hash,
            compared,
        )
        .await;
    }
    tenancy
        .complete()
        .map_err(|e| miette!("{e}. Nothing was deleted."))?;

    if !output::quiet() {
        println!(
            "Found {} live Kix-managed object(s){}",
            sweep.managed.len(),
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
    let unread: HashSet<String> = sweep.forbidden.iter().cloned().collect();
    // A kept object of a kind the sweep could not list, or of a kind the
    // cluster does not serve now, is not known to be gone.
    let not_known = |rid: &ResourceId| match discovery::find(&discovery, &rid.group, &rid.kind) {
        None => true,
        Some((ar, _)) if ar.group.is_empty() => unread.contains(&ar.plural),
        Some((ar, _)) => unread.contains(&format!("{}.{}", ar.plural, ar.group)),
    };
    let unattributed_judged = sweep.unattributed.is_empty() || args.includes(Include::Unattributed);
    let live = judged_objects(
        sweep,
        args.includes(Include::Unattributed),
        args.includes(Include::Copies),
    );

    let plan::Judged {
        mut garbage,
        shared,
        held,
    } = judge_hard(&live, expected_ids, &tenancy);

    // Plan Superseded Activation record retirement. Any listing failure is
    // returned as an error rather than treated as an empty list.
    let policy = retention_policy(args)?;
    let mut retirement = plan_records_with(records.into_records(), cluster_name, &policy).await?;
    if !args.dry_run {
        retirement.check_writer(cluster_name)?;
    }
    garbage.extend(record_garbage(&retirement.plan));

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
    let update = match retirement.active.as_ref().map(|a| tenancy.kept(a)) {
        Some(Kept::Objects(objects)) => KeptUpdate::Objects {
            unknown: objects
                .iter()
                .map(|o| o.resource_id())
                .filter(|rid| not_known(rid))
                .collect(),
            listed: objects.into_iter().cloned().collect(),
            imports: retirement
                .active
                .as_ref()
                .map(|a| tenancy.kept_imports(a).to_vec())
                .unwrap_or_default(),
            live: live.iter().map(kix::cluster::drift::resource_id).collect(),
            in_build: in_build.clone(),
        },
        Some(Kept::Builds(sources)) => KeptUpdate::Builds {
            listed: !sources.is_empty(),
            examined_all,
            build_hash: build_hash.map(str::to_string),
        },
        None => KeptUpdate::Builds {
            listed: false,
            examined_all,
            build_hash: None,
        },
    };

    if garbage.is_empty() {
        if !args.dry_run {
            clear_kept_locked(cluster_name, &mut retirement, &update).await?;
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
            live_order(&live, &resource_entries, &tenancy),
            budget,
        )
        .await?;
        let (retired, records_failed) = delete_records(&retirement).await?;
        update_kept(cluster_name, &retirement, &update, &done).await?;
        clean_revisions(cluster_name, &retirement).await;
        Ok::<_, miette::Report>((done, retired, records_failed))
    }
    .await;
    super::lock::release(&lock).await;
    let (done, retired, records_failed) = deleted?;
    finish(
        &args.cluster,
        done.deleted,
        done.failed + done.changed + records_failed,
        done.left(),
        Some((retired, retirement.plan.kept.len())),
    )
}

/// Rebuild the kept-orphans list of Kix cluster `cluster_name` when the
/// revision its current record names is missing or cannot be read, then
/// run the full scan again. The new list names every live object the
/// cluster applied that no other revision of the cluster names and that
/// the build compared with does not hold
/// ([`kix::cluster::tenancy::Tenancy::unlisted_own`]). The write is bound to
/// `generation`, which the head had before the scan. With `--dry-run`, say
/// what the list would name and change nothing.
#[allow(clippy::too_many_arguments)]
async fn rebuild_kept_list(
    args: &GcArgs,
    global: &crate::cli::GlobalArgs,
    client: &kube::Client,
    records: &OpenedRecords,
    sweep: &inventory::ManagedSweep,
    build: (&HashSet<String>, &HashSet<ResourceId>),
    (cluster_name, generation): (&str, u64),
    kubernetes_uid: Option<&str>,
    build_hash: Option<&str>,
    compared: &str,
) -> Result<()> {
    let (expected_ids, in_build) = build;
    let tenancy = &sweep.tenancy;
    let problem = tenancy
        .problems()
        .first()
        .map(ToString::to_string)
        .unwrap_or_default();
    let objects = kept_to_rebuild(sweep, in_build);
    crate::say!(
        "{} {problem}. Rebuilding the kept-orphans list from {} live object(s) applied by this Kix cluster that are absent from {compared} and from this cluster's other revisions.",
        output::yellow("Note:"),
        objects.len(),
    );
    if args.dry_run {
        crate::say!("`--dry-run` is set, so nothing was changed on the cluster.");
        return Ok(());
    }
    let Some(record) = tenancy.own_current().map(str::to_string) else {
        return Err(miette!(
            "{problem}. Kix cluster '{cluster_name}' has no current deployment record to save the rebuilt kept-orphans list on. Nothing was deleted."
        ));
    };
    let Some(opened) = records.records() else {
        return Err(miette!(
            "could not read deployment records for '{cluster_name}'. Nothing was deleted."
        ));
    };
    let name = write_rebuilt(client, opened, cluster_name, &record, objects, generation).await?;
    crate::say!("Saved rebuilt kept-orphans revision {name} on deployment record {record}.");
    Box::pin(run_hard_async(
        args,
        global,
        expected_ids,
        in_build,
        cluster_name,
        kubernetes_uid,
        build_hash,
        compared,
    ))
    .await
}

/// Return what a rebuilt kept-orphans list names: each labelled, prunable
/// live object of `sweep` that the Kix cluster applied, that no other
/// revision of it names, and that the build compared with, whose objects
/// are `in_build`, lacks. Nothing says which build wanted each object, so
/// each gets the hash [`revision::REBUILT`], which no object hash equals,
/// and no edges.
fn kept_to_rebuild(
    sweep: &inventory::ManagedSweep,
    in_build: &HashSet<ResourceId>,
) -> Vec<RevisionObject> {
    let tenancy = &sweep.tenancy;
    let mut objects: Vec<RevisionObject> = sweep
        .managed
        .iter()
        .chain(&sweep.unattributed)
        .filter(|obj| lifecycle::lifecycle_of_live(obj).prunable())
        .filter(|obj| tenancy.unlisted_own(obj))
        .map(kix::cluster::drift::resource_id)
        .filter(|rid| !in_build.contains(rid))
        .map(|rid| RevisionObject::of_id(revision::REBUILT, &rid))
        .collect();
    objects.sort();
    objects.dedup();
    objects
}

/// Name a kept-orphans revision of `objects` on record `record` of Kix
/// cluster `cluster`, under the deploy lock taken at `generation`, the one
/// the scan read. Return the revision's name. A run that changed the Kix
/// cluster since the scan raised the generation, so the lock refuses.
async fn write_rebuilt(
    client: &kube::Client,
    records: &Records,
    cluster: &str,
    record: &str,
    objects: Vec<RevisionObject>,
    generation: u64,
) -> Result<String> {
    let lock = super::lock::take(
        client,
        cluster,
        "kix gc",
        kix::cluster::head::Purpose::Gc,
        None,
        Some(generation),
    )
    .await?;
    let guarded = lock.guarded(client);
    let written = kix::cluster::revision::keep::rebuild_kept(
        &guarded,
        &records.through(&guarded),
        cluster,
        record,
        objects,
    )
    .await;
    super::lock::release(&lock).await;
    written.map_err(|e| {
        miette!("could not save the rebuilt kept-orphans list on deployment record `{record}`: {e}. Nothing was deleted.")
    })
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
    /// on them, or because they form a dependency cycle.
    pub(super) held: usize,
    /// The resources in `held` that stay because an object another Kix
    /// cluster deploys depends on them.
    pub(super) held_shared: usize,
    /// The resources gc deleted or found gone, which the kept-orphans
    /// revision stops naming.
    pub(super) gone: HashSet<ResourceId>,
}

impl Deletions {
    /// Return whether every object gc set out to delete is gone, so
    /// `clear_kept` may forget the builds they came from.
    pub(super) fn all_gone(&self) -> bool {
        self.failed == 0 && self.changed == 0 && self.held == 0
    }

    /// Return how many of this cluster's resources gc left on the cluster
    /// without a failure of their own. Resources another Kix cluster keeps
    /// are not counted.
    pub(super) fn left(&self) -> usize {
        self.held - self.held_shared
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
                done.gone.insert(rid.clone());
            }
            Removal::Pruned(gone @ (Pruned::Gone | Pruned::NotServed)) => {
                println!(
                    "  {} {} {}",
                    output::dim("="),
                    rid,
                    gone.already_gone().unwrap_or_default()
                );
                done.gone.insert(rid.clone());
            }
            Removal::Pruned(shared @ Pruned::Kept(_)) => {
                let reason = shared.kept_reason().unwrap_or_default();
                println!("  {} prune: {reason}", output::yellow("="));
            }
            Removal::Pruned(changed @ Pruned::Changed(_)) => {
                let reason = changed.kept_reason().unwrap_or_default();
                eprintln!("  {} prune: {reason}", output::red("!"));
                done.changed += 1;
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
                if *shared {
                    done.held_shared += 1;
                }
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
