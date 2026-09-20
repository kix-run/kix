//! `kix gc` — garbage-collect stale kix-managed resources from the cluster.
//!
//! Three modes:
//!   - **Soft (default):** Diff old vs new activation store graphs locally.
//!     Resources only in the old graph are garbage. Deletes in reverse
//!     dependency order (dependents first). Fast: no cluster-wide resource scan.
//!     This is the same diff that deploy computes — soft GC is essentially
//!     "deploy's prune phase, run separately."
//!   - **Hard (`--hard`):** Full cluster scan — fetches all kix-managed resources,
//!     compares identity hashes against the expected set from all active
//!     activations, deletes orphans.
//!   - **Operator (`--operator`):** Deletes retired Activation records and lets
//!     the operator's finalizer do the rest.
//!
//! In every mode, Superseded Activation records are retired under one
//! retention policy: always keep the `--keep` newest (default 10), never more
//! than `--keep-max` (default 50), and beyond the floor retire anything older
//! than `--keep-for` (default 30d). They are the rollback history, so recent
//! ones stay, but each record still on the cluster keeps one entry alive in
//! `kix.run/activations` on every managed resource, and that annotation has a
//! 256 KiB cap. `activation::retire_plan` decides which go; deletes are
//! conditional on the record being unchanged since it was listed; the next
//! deploy drops the retired hashes from the resources. Soft mode needs the
//! cluster for this, so it is no longer an offline command.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::store;
use kix::eval::store_graph::{StoreGraph, store_hash};
use kix::manifest::lifecycle;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::GcArgs;
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        return ctx.runtime.block_on(run_operator(args, ctx));
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
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // 1. Load old activation (from last deploy)
    let old_path = store::load_activation_path(&args.cluster);
    let Some(old_result_dir) = old_path else {
        if !ctx.global.quiet {
            println!(
                "No previous activation saved for '{}'. Run {} first, or use {}.",
                output::bold(&args.cluster),
                output::bold("kix deploy"),
                output::bold("kix gc --hard"),
            );
        }
        return Ok(());
    };

    // 2. Activation records under the retention policy. Needs the cluster;
    //    done before the build so an unreachable cluster fails fast and the
    //    connection is reused for the deletes.
    let policy = retention_policy(args)?;
    let global = ctx.global.clone();
    let records = ctx
        .runtime
        .block_on(plan_record_retirement(&global, &args.cluster, &policy))?;

    if !ctx.global.quiet {
        println!("Loading old activation...");
    }
    let noop = |_: &str| {};
    let mut old_graph =
        StoreGraph::from_result_dir_with_status(&old_result_dir, &noop).map_err(|e| {
            miette!("could not read the previous build's resources and dependencies: {e}")
        })?;
    stamp_annotations(&mut old_graph);

    // 3. Build new activation
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let overrides = ctx.global.input_overrides();
    let new_result_dir =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &status)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&new_result_dir, &status)
        .map_err(|e| miette!("could not read the new build's resources and dependencies: {e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
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

    if garbage_manifests.is_empty() && records.plan.retire.is_empty() {
        if !ctx.global.quiet {
            println!(
                "{} ({} resources unchanged, {})",
                output::green("No garbage found."),
                new_hashes.len(),
                records.kept_note(),
            );
        }
        return Ok(());
    }

    // 5. Display package-grouped garbage plan.
    //    Always render per-resource detail — GC is destructive, the user
    //    must see what exactly will be deleted before confirming.
    if !garbage_manifests.is_empty() {
        let pkg_diff = plan::diff_garbage(&old_graph, &new_graph);
        if !ctx.global.quiet {
            println!();
            println!("{}", output::bold("Garbage collection plan"));
            plan::print_package_plan(&pkg_diff, true);
            plan::print_plan_summary(&pkg_diff);
        }
    }
    if !ctx.global.quiet {
        print_record_plan(&records, &policy);
    }

    // 6. Reverse-topological ordering for deletion (dependents first so a
    //    provider still exists when its consumer is torn down).
    let garbage_values: Vec<Value> = garbage_manifests.values().cloned().collect();
    let ordered_rids = match ResourceGraph::from_manifests(&garbage_values) {
        Ok(graph) => graph.reverse_topo_ids(),
        Err(_) => garbage_values.iter().map(ResourceId::from_value).collect(),
    };

    // 7. Confirm once for both, delete resources first, then records, then
    //    one summary.
    if !confirm(
        args,
        &deletion_prompt(ordered_rids.len(), records.plan.retire.len()),
    )? {
        return Ok(());
    }

    let (deleted, failed) = if ordered_rids.is_empty() {
        (0, 0)
    } else {
        ctx.runtime
            .block_on(delete_resources(&global, &ordered_rids))?
    };
    let (retired, records_failed) = ctx.runtime.block_on(delete_records(&global, &records))?;
    finish(
        &global,
        deleted,
        failed + records_failed,
        Some((retired, records.plan.kept.len())),
    )
}

// ---------------------------------------------------------------------------
// Hard GC: full cluster scan
// ---------------------------------------------------------------------------

fn run_hard(args: &GcArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // 1. Build new activation
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let noop = |_: &str| {};
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &noop)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut graph =
        StoreGraph::from_result_dir_with_status(&result_path, &noop).map_err(|e| miette!("{e}"))?;
    stamp_annotations(&mut graph);

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

    // 3. Fetch ALL live kix-managed resources
    let global = ctx.global.clone();
    let cluster_name = graph.cluster_name.clone();
    ctx.runtime.block_on(run_hard_async(
        args,
        &global,
        &expected_hashes,
        &expected_ids,
        &cluster_name,
    ))
}

async fn run_hard_async(
    args: &GcArgs,
    global: &crate::cli::GlobalArgs,
    expected_hashes: &HashSet<String>,
    expected_ids: &HashSet<String>,
    cluster_name: &str,
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
    let sweep = fetch::sweep_managed(&client, &discovery)
        .await
        .map_err(|e| miette!("failed to fetch live resources: {e}"))?;

    if !global.quiet {
        println!(
            "Found {} live kix-managed resources ({} unstamped label carriers){}",
            sweep.managed.len(),
            sweep.unstamped.len(),
            crate::output::forbidden_note(&sweep.forbidden),
        );
    }
    let live: Vec<_> = sweep.managed.into_iter().chain(sweep.unstamped).collect();

    // Refuse on a cluster that has been migrated but not deployed since.
    //
    // The expected set above comes from a build made now, so every hash in
    // it is a post-move hash, while every object here still carries the
    // pre-move one. Every single resource would read as HashNotExpected and
    // be deleted. `check_cluster` cannot catch this: discovery shows only
    // the current group, because the migration is what moved it.
    let has_key = |obj: &kube::api::DynamicObject, key: &str| {
        obj.data
            .pointer("/metadata/annotations")
            .and_then(|a| a.as_object())
            .is_some_and(|m| m.contains_key(key))
            || obj
                .metadata
                .annotations
                .as_ref()
                .is_some_and(|a| a.contains_key(key))
    };
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
    // Skip Activation CRs here — they're handled separately below.
    let mut garbage: Vec<GarbageEntry> = Vec::new();
    for obj in &live {
        if kix::manifest::lifecycle::lifecycle_of_live(obj)
            == kix::manifest::lifecycle::Lifecycle::Record
        {
            continue; // handled in the stale-activation block below
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

        let kind = obj
            .data
            .get("kind")
            .and_then(|v| v.as_str())
            .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
            .unwrap_or("Unknown")
            .to_string();
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

    // Superseded Activation records under the retention policy. A listing
    // failure is an error, not an empty list: gc must never plan on a
    // partial view. Listed here for display; deleted with preconditions by
    // `delete_records`, not by kind lookup.
    let policy = retention_policy(args)?;
    let records = plan_records_with(&client, &discovery, cluster_name, &policy).await?;
    garbage.extend(record_garbage(&records.plan));

    // Unstamped resources carry the kix label but no identity hash: kix never
    // applied them (a controller child that inherited the label, a render
    // someone kubectl-applied). Report them, but delete only on request.
    let (unstamped, garbage): (Vec<GarbageEntry>, Vec<GarbageEntry>) = garbage
        .into_iter()
        .partition(|g| g.reason == GarbageReason::NoIdentityHash && !args.include_unstamped);
    if !unstamped.is_empty() && !global.quiet {
        print_unstamped(&unstamped);
    }

    if garbage.is_empty() {
        if !global.quiet {
            println!(
                "{} ({})",
                output::green("No garbage found."),
                records.kept_note()
            );
        }
        return Ok(());
    }

    let (record_entries, resource_entries): (Vec<GarbageEntry>, Vec<GarbageEntry>) = garbage
        .into_iter()
        .partition(|g| g.reason == GarbageReason::RetiredActivation);
    if !resource_entries.is_empty() {
        print_garbage_plan(&resource_entries);
    }
    if !global.quiet {
        print_record_plan(&records, &policy);
    }

    if !confirm(
        args,
        &deletion_prompt(resource_entries.len(), record_entries.len()),
    )? {
        return Ok(());
    }

    let rids: Vec<ResourceId> = resource_entries.iter().map(|g| g.id.clone()).collect();
    let (deleted, failed) = if rids.is_empty() {
        (0, 0)
    } else {
        delete_resources(global, &rids).await?
    };
    let (retired, records_failed) = delete_records(global, &records).await?;
    finish(
        global,
        deleted,
        failed + records_failed,
        Some((retired, records.plan.kept.len())),
    )
}

// ---------------------------------------------------------------------------
// Hard GC: garbage entry + display
// ---------------------------------------------------------------------------

/// Why a live resource is flagged as garbage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GarbageReason {
    /// Resource carries a `kix.run/identity-hash` that isn't in the expected set.
    HashNotExpected,
    /// Resource has no `kix.run/identity-hash` annotation — it looks kix-managed
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

async fn run_operator(args: &GcArgs, ctx: &CommandContext) -> Result<()> {
    let (client, ar) =
        super::operator::connect_and_verify(ctx.global.context.as_deref(), ctx.global.quiet)
            .await?;

    let discovery = kix::cluster::fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    let (activation_ar, _) = kix::cluster::activation::find_activation_ar(&discovery)
        .map_err(|e| miette!("{e}"))?
        .ok_or_else(|| miette!("the Kix Activation resource type is not installed on this cluster. Check the Kubernetes context and deploy the Kix CRDs before retrying."))?
        .clone();

    // Superseded activations under the retention policy
    let policy = retention_policy(args)?;
    let records = plan_records_with(&client, &discovery, &args.cluster, &policy).await?;

    if records.plan.retire.is_empty() {
        if !ctx.global.quiet {
            println!(
                "{} No activation records to retire ({}).",
                output::green("✓"),
                records.kept_note(),
            );
        }
        return Ok(());
    }

    print_record_plan(&records, &policy);
    if !ctx.global.quiet {
        println!(
            "  {}",
            output::dim("The operator runs its cleanup step for each deleted record.")
        );
    }

    if !confirm(args, &deletion_prompt(0, records.plan.retire.len()))? {
        return Ok(());
    }

    // Delete each retired Activation CR (only if unchanged since listed)
    // and watch for finalizer cleanup
    let mut deleted = 0usize;
    let mut failed = 0usize;

    for retired in &records.plan.retire {
        let name = &retired.record.name;
        if !ctx.global.quiet {
            println!("Deleting Activation '{}'...", output::bold(name));
        }

        match kix::cluster::activation::delete_activation_if_unchanged(
            &client,
            &activation_ar,
            &retired.record,
        )
        .await
        {
            Ok(_) => {
                // Wait for finalizer to complete deletion
                super::operator::wait_for_deletion(&client, &ar, name, ctx.global.quiet).await?;
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

use kix::cluster::activation::{RetentionPolicy, Retirement};
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

/// The records to retire, with the connection that listed them so the
/// deletes reuse it. `conn` is `None` when the cluster has no Activation
/// CRD, which also means it has no records.
struct RecordRetirement {
    conn: Option<(kube::Client, kube::discovery::ApiResource)>,
    plan: Retirement,
}

impl RecordRetirement {
    fn kept_note(&self) -> String {
        if self.conn.is_none() {
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
    plan_records_with(&client, &discovery, cluster, policy).await
}

/// List and plan on an existing connection.
async fn plan_records_with(
    client: &kube::Client,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
    cluster: &str,
    policy: &RetentionPolicy,
) -> Result<RecordRetirement> {
    // The gate error must not be read as "no Activation CRD". On a cluster
    // still under the retired group, hard gc would compare live objects
    // stamped with retired identity hashes against a current build, find no
    // match for most of them, and plan to delete them.
    let Some((ar, _)) =
        kix::cluster::activation::find_activation_ar(discovery).map_err(|e| miette!("{e}"))?
    else {
        return Ok(RecordRetirement {
            conn: None,
            plan: Default::default(),
        });
    };
    let superseded = kix::cluster::activation::list_superseded_activations(client, ar, cluster)
        .await
        .map_err(|e| miette!("failed to list superseded activations: {e}"))?;
    let plan = kix::cluster::activation::retire_plan(superseded, policy);
    Ok(RecordRetirement {
        conn: Some((client.clone(), ar.clone())),
        plan,
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
        Some(d) => format!(
            ", and anything newer than {}",
            kix::cluster::activation::humanize(d)
        ),
        None => String::new(),
    };
    format!(
        "keeping at least the {} newest, at most {}{age}",
        policy.keep_min,
        policy.keep_max.max(policy.keep_min)
    )
}

/// Print which records will go, why, and which stay.
fn print_record_plan(records: &RecordRetirement, policy: &RetentionPolicy) {
    let plan = &records.plan;
    if plan.retire.is_empty() {
        println!("  {}", output::dim(&records.kept_note()));
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
        let when = if retired.record.deployed_at.is_empty() {
            "no deployed-at".to_string()
        } else {
            retired.record.deployed_at.clone()
        };
        println!(
            "  {} Activation/{} {}",
            output::red("-"),
            retired.record.name,
            output::dim(&format!("({when}; {})", retired.reason))
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
    records: &RecordRetirement,
) -> Result<(usize, usize)> {
    let Some((client, ar)) = &records.conn else {
        return Ok((0, 0));
    };
    let mut retired = 0usize;
    let mut failed = 0usize;
    for r in &records.plan.retire {
        match kix::cluster::activation::delete_activation_if_unchanged(client, ar, &r.record).await
        {
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

/// Delete resources in the given order. Returns `(deleted, failed)`; the
/// caller prints the summary and sets the exit code.
async fn delete_resources(
    global: &crate::cli::GlobalArgs,
    resources: &[ResourceId],
) -> Result<(usize, usize)> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    let ar_by_kind: HashMap<String, (&kube::discovery::ApiResource, kube::discovery::Scope)> =
        discovery
            .iter()
            .map(|(ar, scope)| (ar.kind.clone(), (ar, scope.clone())))
            .collect();

    let mut deleted = 0usize;
    let mut failed = 0usize;

    for rid in resources {
        if rid.kind == "Namespace" {
            println!(
                "  {} {}: Namespace deletion is skipped; delete it manually if needed",
                output::yellow("!"),
                rid,
            );
            continue;
        }

        let Some(&(ar, ref scope)) = ar_by_kind.get(&rid.kind) else {
            eprintln!(
                "  {} {}: Kubernetes does not recognize this kind; skipping it",
                output::red("!"),
                rid
            );
            failed += 1;
            continue;
        };

        let api: kube::api::Api<kube::api::DynamicObject> = match scope {
            kube::discovery::Scope::Namespaced => {
                let ns = if rid.namespace == CLUSTER_SCOPED {
                    "default"
                } else {
                    &rid.namespace
                };
                kube::api::Api::namespaced_with(client.clone(), ns, ar)
            }
            kube::discovery::Scope::Cluster => kube::api::Api::all_with(client.clone(), ar),
        };

        match api
            .delete(&rid.name, &kube::api::DeleteParams::default())
            .await
        {
            Ok(_) => {
                println!("  {} deleted {}", output::red("-"), rid);
                deleted += 1;
            }
            Err(e) => {
                eprintln!("  {} {}: {}", output::red("!"), rid, e);
                failed += 1;
            }
        }
    }

    Ok((deleted, failed))
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
mod record_garbage_tests {
    use super::*;
    use kix::cluster::activation::{RetentionPolicy, SupersededActivation, retire_plan};

    fn rec(name: &str, at: &str) -> SupersededActivation {
        SupersededActivation {
            name: name.into(),
            identity_hash: Some(format!("{name}hash")),
            deployed_at: at.into(),
            built_via: None,
            previous_activation: None,
            uid: None,
            resource_version: None,
            failed_at: None,
            created_at: None,
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
