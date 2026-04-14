//! `kix gc` — garbage-collect stale kix-managed resources from the cluster.
//!
//! Two modes:
//!   - **Soft (default):** Diff old vs new activation store graphs locally.
//!     Resources only in the old graph are garbage. Deletes in reverse
//!     dependency order (dependents first). Fast: no cluster-wide resource scan.
//!     This is the same diff that deploy computes — soft GC is essentially
//!     "deploy's prune phase, run separately."
//!   - **Hard (`--hard`):** Full cluster scan — fetches all kix-managed resources,
//!     compares identity hashes against the expected set from all active
//!     activations, deletes orphans.

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

    if !ctx.global.quiet {
        println!("Loading old activation...");
    }
    let noop = |_: &str| {};
    let mut old_graph = StoreGraph::from_result_dir_with_status(&old_result_dir, &noop)
        .map_err(|e| miette!("failed to load old store graph: {e}"))?;
    stamp_annotations(&mut old_graph);

    // 2. Build new activation
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let new_result_dir = build_cluster_activation_with_status(&flake_path, &args.cluster, &status)
        .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&new_result_dir, &status)
        .map_err(|e| miette!("failed to load new store graph: {e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    // 3. Diff: identity hashes in old but not in new = garbage
    let new_hashes: HashSet<String> = new_graph.resources.keys().map(|p| store_hash(p)).collect();

    // Collect garbage manifests (from old graph, for kind/name/ns info)
    let mut garbage_manifests: HashMap<String, Value> = HashMap::new();
    for (path, res) in &old_graph.resources {
        let hash = store_hash(path);
        if !new_hashes.contains(&hash) {
            garbage_manifests.insert(hash, res.manifest.clone());
        }
    }

    if garbage_manifests.is_empty() {
        if !ctx.global.quiet {
            println!(
                "{} ({} resources unchanged)",
                output::green("No garbage found."),
                new_hashes.len(),
            );
        }
        return Ok(());
    }

    // 4. Display package-grouped garbage plan.
    //    Always render per-resource detail — GC is destructive, the user
    //    must see what exactly will be deleted before confirming.
    let pkg_diff = plan::diff_garbage(&old_graph, &new_graph);
    if !ctx.global.quiet {
        println!();
        println!("{}", output::bold("Garbage collection plan"));
        plan::print_package_plan(&pkg_diff, true);
        plan::print_plan_summary(&pkg_diff);
    }

    // 5. Reverse-topological ordering for deletion (dependents first so a
    //    provider still exists when its consumer is torn down).
    let garbage_values: Vec<Value> = garbage_manifests.values().cloned().collect();
    let ordered_rids = match ResourceGraph::from_manifests(&garbage_values) {
        Ok(graph) => graph.reverse_topo_ids(),
        Err(_) => garbage_values.iter().map(ResourceId::from_value).collect(),
    };

    // 6. Confirm and delete
    if !args.yes {
        if !output::is_interactive() {
            eprintln!(
                "{}",
                output::yellow("Non-interactive terminal. Use --yes to confirm deletion.")
            );
            std::process::exit(1);
        }
        print!("\nDelete {} resources? [y/N] ", ordered_rids.len());
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("GC cancelled.");
            return Ok(());
        }
    }

    let global = ctx.global.clone();
    ctx.runtime
        .block_on(delete_resources(&global, &ordered_rids))
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
    let result_path = build_cluster_activation_with_status(&flake_path, &args.cluster, &noop)
        .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut graph = StoreGraph::from_result_dir_with_status(&result_path, &noop)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    stamp_annotations(&mut graph);

    // 2. Collect expected identity hashes
    let expected_hashes: HashSet<String> = graph
        .resources
        .values()
        .filter_map(|r| {
            r.manifest
                .pointer("/metadata/annotations")
                .and_then(|a| a.get("kix.dev/identity-hash"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
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
        &cluster_name,
    ))
}

async fn run_hard_async(
    args: &GcArgs,
    global: &crate::cli::GlobalArgs,
    expected_hashes: &HashSet<String>,
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
        .map_err(|e| miette!("API discovery failed: {e}"))?;
    let live = fetch::fetch_managed_resources(&client, &discovery)
        .await
        .map_err(|e| miette!("failed to fetch live resources: {e}"))?;

    if !global.quiet {
        println!("Found {} live kix-managed resources", live.len());
    }

    // Find resources with identity-hash not in expected set.
    // Skip Activation CRs here — they're handled separately below.
    let mut garbage: Vec<GarbageEntry> = Vec::new();
    for obj in &live {
        let obj_kind = obj
            .data
            .get("kind")
            .and_then(|v| v.as_str())
            .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
            .unwrap_or("");
        if obj_kind == "Activation" {
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
                .and_then(|a| a.get(key))
                .cloned()
        };

        let identity_hash = ann_get("kix.dev/identity-hash");

        let reason = match &identity_hash {
            Some(hash) if expected_hashes.contains(hash) => continue,
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
            package: ann_get("kix.dev/package"),
            package_namespace: ann_get("kix.dev/package-namespace"),
            activations: ann_get("kix.dev/activations"),
            reason,
        });
    }

    // Find Superseded activations (status.phase == Superseded) for this cluster
    if let Some((ar, _)) = kix::cluster::activation::find_activation_ar(&discovery)
        && let Ok(superseded) =
            kix::cluster::activation::list_superseded(&client, ar, cluster_name).await
    {
        for name in superseded {
            garbage.push(GarbageEntry {
                id: ResourceId {
                    kind: "Activation".to_string(),
                    namespace: CLUSTER_SCOPED.to_string(),
                    name,
                },
                identity_hash: None,
                package: None,
                package_namespace: None,
                activations: None,
                reason: GarbageReason::SupersededActivation,
            });
        }
    }

    if garbage.is_empty() {
        if !global.quiet {
            println!("{}", output::green("No garbage found."));
        }
        return Ok(());
    }

    print_garbage_plan(&garbage);

    if !args.yes {
        if !output::is_interactive() {
            eprintln!(
                "{}",
                output::yellow("Non-interactive terminal. Use --yes to confirm deletion.")
            );
            std::process::exit(1);
        }
        print!("\nDelete {} resources? [y/N] ", garbage.len());
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("GC cancelled.");
            return Ok(());
        }
    }

    let rids: Vec<ResourceId> = garbage.iter().map(|g| g.id.clone()).collect();
    delete_resources(global, &rids).await
}

// ---------------------------------------------------------------------------
// Hard GC: garbage entry + display
// ---------------------------------------------------------------------------

/// Why a live resource is flagged as garbage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GarbageReason {
    /// Resource carries a `kix.dev/identity-hash` that isn't in the expected set.
    HashNotExpected,
    /// Resource has no `kix.dev/identity-hash` annotation — it looks kix-managed
    /// (matched the managed-by label) but was never properly stamped.
    NoIdentityHash,
    /// An `Activation` CR in phase `Superseded` — kept for rollback history,
    /// but GC will remove it.
    SupersededActivation,
}

impl GarbageReason {
    fn label(&self) -> &'static str {
        match self {
            GarbageReason::HashNotExpected => "identity-hash not in expected set",
            GarbageReason::NoIdentityHash => "missing kix.dev/identity-hash",
            GarbageReason::SupersededActivation => "superseded activation",
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
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    let (activation_ar, _) = kix::cluster::activation::find_activation_ar(&discovery)
        .ok_or_else(|| miette!("Activation CRD not registered on cluster"))?
        .clone();

    // Find all superseded activations
    let superseded =
        kix::cluster::activation::list_superseded(&client, &activation_ar, &args.cluster)
            .await
            .map_err(|e| miette!("failed to list superseded activations: {e}"))?;

    if superseded.is_empty() {
        if !ctx.global.quiet {
            println!(
                "{} No superseded activations to clean up.",
                output::green("✓"),
            );
        }
        return Ok(());
    }

    println!(
        "{} {} superseded activation(s) to delete:",
        output::bold("Garbage:"),
        superseded.len(),
    );
    for name in &superseded {
        println!("  {} Activation/{}", output::red("-"), name);
    }

    // Confirmation
    if !args.yes {
        if !output::is_interactive() {
            eprintln!(
                "{}",
                output::yellow("Non-interactive terminal. Use --yes to confirm deletion.")
            );
            std::process::exit(1);
        }
        print!(
            "\nDelete {} superseded activation(s)? (operator finalizer will GC resources) [y/N] ",
            superseded.len()
        );
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("GC cancelled.");
            return Ok(());
        }
    }

    // Delete each superseded Activation CR and watch for finalizer cleanup
    let mut deleted = 0usize;
    let mut failed = 0usize;

    for name in &superseded {
        if !ctx.global.quiet {
            println!("Deleting Activation '{}'...", output::bold(name));
        }

        match kix::cluster::activation::delete_activation(&client, &activation_ar, name).await {
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
// Shared: delete a list of resources from the cluster
// ---------------------------------------------------------------------------

async fn delete_resources(global: &crate::cli::GlobalArgs, resources: &[ResourceId]) -> Result<()> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

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
                "  {} {} — skipping Namespace — delete manually",
                output::yellow("!"),
                rid,
            );
            continue;
        }

        let Some(&(ar, ref scope)) = ar_by_kind.get(&rid.kind) else {
            eprintln!("  {} {} — unknown kind, skipping", output::red("!"), rid);
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

    println!();
    let failed_str = failed.to_string();
    println!(
        "GC complete: {} deleted, {} failed",
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
