//! `kix deploy` — wave-based deployment with local DAG diff.
//!
//! Uses the store graph for proper stamping and dependency tracking.
//! Change detection is a local operation — diffs two Nix store graphs
//! by K8s identity (kind+ns+name) and identity-hash, without querying
//! the live cluster.
//!
//! Flow:
//!   1. `nix build .#cluster-<name>-activation`  → result dir
//!   2. StoreGraph::from_result_dir              → packages + resources
//!   3. stamp_annotations                        → identity/depends-on
//!   4. Connect to cluster, fetch Active Activation (unless --current-activation)
//!   5. Resolve old activation to local store graph (fallback: reconstruct
//!      old manifests from live kix-managed resources if the path was GC'd)
//!   6. Package-grouped plan display
//!   7. Confirm → Apply wave-by-wave with readiness checks
//!   8. Prune orphans (reverse topo order from old graph)

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::activation;
use kix::cluster::apply::{ApplyAction, ChangeAction};
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::cluster::ops::{ClusterOps, KubeOps, KubeOpsConfig};
use kix::cluster::readiness;
use kix::cluster::scheduler::{self, DeployPlan, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, DeployResult, NodeDetail, NodeId, TransitionKind,
    Verdict,
};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::cli::{DeployArgs, OnError, PruneMode};
use crate::output;
use crate::plan;

use super::CommandContext;

pub fn run(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        return run_operator(args, ctx);
    }

    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // 1. Build new activation and load store graph
    if !ctx.global.quiet {
        println!("Building cluster '{}'...", output::bold(&args.cluster));
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &status)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    // 2. Collect stamped manifests from new graph
    let new_manifests: Vec<Value> = new_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    let manifest_count = new_manifests.len();
    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} manifests",
            output::bold(&new_graph.cluster_name),
            manifest_count,
        );
    }

    if manifest_count == 0 {
        if !ctx.global.quiet {
            println!("Nothing to deploy.");
        }
        return Ok(());
    }

    // 3. Resolve old activation
    //    Default: connect to cluster, fetch Active Activation, resolve to local store graph
    //    --current-activation: use local cache (no cluster connection yet)
    let (old_graph, old_manifests, pre_client, active_hash) = if args.current_activation {
        // Local cache mode — no cluster connection
        let (og, om) = load_old_from_cache(&args.cluster, &ctx.global);
        let hash = find_activation_identity_hash(&om);
        (og, om, None, hash)
    } else {
        // Cluster-aware mode — connect and fetch Active Activation
        let (og, om, client, hash) = ctx
            .runtime
            .block_on(load_old_from_cluster(&args.cluster, &ctx.global))?;
        (og, om, client, hash)
    };

    // 4. Local DAG diff: old vs new
    let all_actions = kix::cluster::apply::detect_changes(&new_manifests, &old_manifests);

    // Stateful migration pair detection (doc 67). Phase 1: detect + refuse
    // to proceed without explicit --accept-migrations. No execution yet.
    let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests);
    if !migration_pairs.is_empty() {
        print_migration_pairs(&migration_pairs);
        if !args.accept_migrations {
            eprintln!(
                "{}",
                output::red(
                    "Refusing to deploy: stateful migration pairs detected but --accept-migrations was not passed."
                )
            );
            eprintln!(
                "{}",
                output::yellow(
                    "Data migration is NOT yet automated. Review the pairs above, handle the data out-of-band, then re-run with --accept-migrations."
                )
            );
            std::process::exit(1);
        }
        if !ctx.global.quiet {
            println!(
                "{}",
                output::yellow(
                    "--accept-migrations set: proceeding with deploy. kix will NOT copy data; consumers on new backing will start empty."
                )
            );
        }
    }

    // --reconcile: force re-apply of all resources regardless of identity match
    let all_actions: Vec<ChangeAction> = if args.reconcile {
        let manifest_by_k8s_id: std::collections::HashMap<String, &Value> = new_manifests
            .iter()
            .map(|m| {
                let rid = ResourceId::from_value(m);
                (format!("{}/{}/{}", rid.kind, rid.namespace, rid.name), m)
            })
            .collect();

        all_actions
            .into_iter()
            .map(|action| match action {
                ChangeAction::Skip(ref rid) => {
                    let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
                    if let Some(&manifest) = manifest_by_k8s_id.get(&k8s_id) {
                        ChangeAction::Apply(manifest.clone())
                    } else {
                        action
                    }
                }
                other => other,
            })
            .collect()
    } else {
        all_actions
    };

    // Separate into apply actions and orphans
    let mut orphan_rids: Vec<ResourceId> = Vec::new();

    for action in &all_actions {
        if let ChangeAction::Orphan(rid) = action {
            orphan_rids.push(rid.clone());
        }
    }

    // 5. Build DAG and streaming plan.
    let resource_graph = ResourceGraph::from_manifests(&new_manifests).into_diagnostic()?;

    if resource_graph.graph.node_count() == 0 {
        if !ctx.global.quiet {
            println!("No resources to deploy.");
        }
        return Ok(());
    }

    let plan = DeployPlan::from_graph_and_changes(&resource_graph, &all_actions);

    // Find the Activation resource name and identity-hash from the new manifests
    let activation_manifest = new_manifests.iter().find(|m| {
        m.get("kind")
            .and_then(|v| v.as_str())
            .is_some_and(|k| k == "Activation")
    });
    let activation_name = activation_manifest.and_then(|m| {
        m.pointer("/metadata/name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });
    let activation_identity_hash = activation_manifest.and_then(|m| {
        m.pointer("/metadata/annotations/kix.dev~1identity-hash")
            .or_else(|| {
                m.pointer("/metadata/annotations")
                    .and_then(|a| a.get("kix.dev/identity-hash"))
            })
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });

    // 6. Display plan — package-grouped, changes only
    if !ctx.global.quiet {
        let pkg_diff = if let Some(old) = &old_graph {
            plan::diff_graphs(old, &new_graph)
        } else if !old_manifests.is_empty() {
            // Old store graph unavailable (live reconstruction) — synthesize
            // a package view from the old manifests so untouched packages
            // show as unchanged instead of everything "added".
            let synthetic = synthesize_old_graph(&old_manifests, &new_graph);
            plan::diff_graphs(&synthetic, &new_graph)
        } else {
            // First deploy — everything is "added"
            plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph)
        };

        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);
        plan::print_plan_summary(&pkg_diff);

        if !orphan_rids.is_empty() {
            let orphan_str = orphan_rids.len().to_string();
            println!("  {} orphaned", output::red(&orphan_str),);
        }
    }

    // Imports are applied like any other resource (SSA); readiness polls the
    // cluster for the described resource via `wait_for_import_target`, which
    // is triggered when the import node becomes eligible under the DAG.

    let total_apply = plan
        .nodes
        .iter()
        .filter(|n| matches!(n.action, ChangeAction::Apply(_)))
        .count();

    if total_apply == 0 && orphan_rids.is_empty() {
        if !ctx.global.quiet {
            match (&activation_identity_hash, &active_hash) {
                (Some(new), Some(old)) if new == old => println!(
                    "{} activation identical to active ({}...) — nothing to apply.",
                    output::dim("="),
                    &new[..8.min(new.len())],
                ),
                _ => println!("Nothing to apply."),
            }
        }
        return Ok(());
    }

    // Offline dry-run (e.g. `--current-activation --dry-run`): we don't
    // have a cluster connection, so we can't route through SSA dry-run.
    // Synthesise the per-node Create/Configured labels from the local
    // identity-hash diff we already have in `old_manifests`, render through
    // the same `apply_symbol` mapping the real path uses, and return
    // without ever reaching for a kubeconfig. Same labels and summary line
    // as the online dry-run path — just no admission/RBAC/conflict
    // validation, which is the price of offline.
    if args.dry_run && pre_client.is_none() {
        return render_offline_dry_run(&plan, &old_manifests, &orphan_rids, &ctx.global);
    }

    // Banner so the streamed output is self-labelling. The actual dry-run
    // semantics ride on `args.dry_run` plumbed all the way to apply_resource
    // and api.delete — there's no parallel render path. SSA + DELETE both
    // route through the apiserver with `?dryRun=All`, so per-resource verbs
    // ("created" / "configured") come from the apiserver's response rather
    // than a CLI guess. See `kix::cluster::scheduler::SchedulerConfig.dry_run`.
    if args.dry_run && !ctx.global.quiet {
        println!();
        println!("{}", output::dim("Dry run — no changes will be applied."));
    }

    // Confirmation
    if !args.yes && !args.dry_run {
        if !output::is_interactive() {
            eprintln!(
                "{}",
                output::yellow(
                    "Non-interactive terminal detected. Use --yes to skip confirmation."
                )
            );
            std::process::exit(1);
        }
        print!("\nProceed with deploy? [y/N] ");
        std::io::stdout().flush().into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Deploy cancelled.");
            return Ok(());
        }
    }

    let global = ctx.global.clone();
    let cluster_name = new_graph.cluster_name.clone();
    let deploy_result = ctx.runtime.block_on(run_deploy_async(
        args,
        &global,
        plan,
        &orphan_rids,
        &old_manifests,
        &cluster_name,
        activation_name.as_deref(),
        activation_identity_hash.as_deref(),
        pre_client,
    ));

    // Save activation path for next deploy's diff
    if deploy_result.is_ok()
        && let Err(e) = kix::eval::store::save_activation_path(&args.cluster, &result_path)
    {
        tracing::warn!("failed to save activation path: {e}");
    }

    deploy_result
}

// ── Old activation resolution ────────────────────────────────────────

/// Load old activation from local cache (--current-activation mode).
fn load_old_from_cache(
    cluster: &str,
    global: &crate::cli::GlobalArgs,
) -> (Option<StoreGraph>, Vec<Value>) {
    let old_path = kix::eval::store::load_activation_path(cluster);
    match old_path {
        Some(old_result_dir) => {
            if !global.quiet {
                println!("Loading previous activation from cache...");
            }
            let noop = |_: &str| {};
            match StoreGraph::from_result_dir_with_status(&old_result_dir, &noop) {
                Ok(mut old_graph) => {
                    stamp_annotations(&mut old_graph);
                    let manifests = old_graph
                        .resources
                        .values()
                        .map(|r| r.manifest.clone())
                        .collect();
                    (Some(old_graph), manifests)
                }
                Err(e) => {
                    tracing::warn!("failed to load old activation: {e}, treating as first deploy");
                    (None, vec![])
                }
            }
        }
        None => {
            if !global.quiet {
                println!("No previous activation — first deploy.");
            }
            (None, vec![])
        }
    }
}

/// Extract the `kix.dev/identity-hash` annotation from the Activation
/// manifest in a manifest set, if present.
fn find_activation_identity_hash(manifests: &[Value]) -> Option<String> {
    manifests
        .iter()
        .find(|m| m.get("kind").and_then(|v| v.as_str()) == Some("Activation"))
        .and_then(|m| {
            m.pointer("/metadata/annotations")
                .and_then(|a| a.get("kix.dev/identity-hash"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
}

/// Connect to cluster, fetch Active Activation, resolve to local store graph.
/// The final tuple element is the active activation's identity hash, used to
/// report a no-op deploy as "activation identical".
async fn load_old_from_cluster(
    cluster: &str,
    global: &crate::cli::GlobalArgs,
) -> Result<(
    Option<StoreGraph>,
    Vec<Value>,
    Option<kube::Client>,
    Option<String>,
)> {
    if !global.quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| {
            miette!(
                "failed to connect to cluster: {e}. Check your kubeconfig or try --context <name>"
            )
        })?;

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;

    // Try to find the Active Activation on the cluster
    let active = if let Some((ar, _)) = activation::find_activation_ar(&discovery) {
        activation::find_active(&client, ar, cluster)
            .await
            .ok()
            .flatten()
    } else {
        None
    };

    match active {
        Some(act) if act.identity_hash.is_some() => {
            let hash = act.identity_hash.as_ref().unwrap();
            if !global.quiet {
                println!(
                    "Active activation: {} ({}...)",
                    output::bold(&act.name),
                    &hash[..8.min(hash.len())],
                );
            }

            // Resolve to local store graph: prefer built-via, fall back to hash lookup
            let result_dir = act
                .built_via
                .as_ref()
                .map(std::path::PathBuf::from)
                .filter(|p| p.join("kix-packages.json").exists())
                .or_else(|| kix::eval::store::resolve_activation_by_hash(cluster, hash));

            match result_dir {
                Some(result_dir) => {
                    let noop = |_: &str| {};
                    match StoreGraph::from_result_dir_with_status(&result_dir, &noop) {
                        Ok(mut old_graph) => {
                            stamp_annotations(&mut old_graph);
                            let manifests = old_graph
                                .resources
                                .values()
                                .map(|r| r.manifest.clone())
                                .collect();
                            Ok((Some(old_graph), manifests, Some(client), Some(hash.clone())))
                        }
                        Err(e) => {
                            // A store path that exists but will not load is
                            // not a first deploy. Fall back to the cluster
                            // rather than planning against nothing.
                            if !global.quiet {
                                println!(
                                    "  {} previous build at {} would not load ({e}) — reconstructing previous state from cluster",
                                    output::yellow("!"),
                                    result_dir.display(),
                                );
                            }
                            let old_manifests =
                                reconstruct_old_from_live(&client, &discovery).await?;
                            Ok((None, old_manifests, Some(client), Some(hash.clone())))
                        }
                    }
                }
                None => {
                    if !global.quiet {
                        println!(
                            "  {} store path for activation not found locally — reconstructing previous state from cluster",
                            output::yellow("!"),
                        );
                    }
                    let old_manifests = reconstruct_old_from_live(&client, &discovery).await?;
                    Ok((None, old_manifests, Some(client), Some(hash.clone())))
                }
            }
        }
        _ => {
            if !global.quiet {
                println!("No previous activation on cluster — first deploy.");
            }
            Ok((None, vec![], Some(client), None))
        }
    }
}

/// Reconstruct the previous deploy's manifest set from live cluster state.
///
/// Fallback for when the old activation's store path is gone (garbage-
/// collected, or the deploy came from another machine). Every kix-managed
/// resource carries the identity-hash and depends-on annotations that
/// change detection and prune ordering read, so live objects projected
/// back to manifests substitute for the old store graph. Activation CRs
/// are excluded: their lifecycle is supersede-managed, never prune (same
/// policy as the operator's reconcile).
///
/// A failed sweep is an error, not an empty previous state. Planning
/// against an empty old set would show every resource as "added" and,
/// with `--prune`, would compute no orphans at all: a plan that looks
/// plausible and is wrong.
async fn reconstruct_old_from_live(
    client: &kube::Client,
    discovery: &[(kube::discovery::ApiResource, kube::discovery::Scope)],
) -> Result<Vec<Value>> {
    let objects = fetch::fetch_managed_resources(client, discovery)
        .await
        .map_err(|e| {
            miette!(
                "cannot reconstruct the previous state from the cluster: {e}. \
                 Refusing to plan from a partial view; retry when the apiserver is healthy."
            )
        })?;
    Ok(objects
        .into_iter()
        .filter(|obj| {
            let kind = obj
                .data
                .get("kind")
                .and_then(|v| v.as_str())
                .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
                .unwrap_or("");
            kind != "Activation"
        })
        .map(|mut obj| {
            fetch::normalize_for_diff(&mut obj);
            kix::cluster::fieldsv1::merge_typed_metadata(&obj)
        })
        .collect())
}

/// Synthesize an "old" StoreGraph from live-reconstructed manifests so the
/// package-grouped plan shows changed/unchanged packages instead of
/// everything "added" when the old store path is gone.
///
/// Resources group by their stamped `kix.dev/package[-namespace]`
/// annotations (cluster-level `_cluster` resources are skipped — real
/// graphs keep them outside any PackageNode). Identity hashes map back
/// onto the NEW graph's store paths: a matched resource reuses the new
/// path and manifest (equal hash ⇒ identical content), so untouched
/// packages compare path-equal and print as unchanged; unmatched
/// resources keep the live manifest under a synthetic path so their diff
/// renders live → new. Versions come from live PackageInstance manifests.
fn synthesize_old_graph(old_manifests: &[Value], new_graph: &StoreGraph) -> StoreGraph {
    use kix::eval::store_graph::{PackageNode, ResourceNode, store_hash};
    use std::collections::{HashMap, HashSet};

    let new_path_by_hash: HashMap<String, &PathBuf> = new_graph
        .resources
        .keys()
        .map(|p| (store_hash(p), p))
        .collect();

    // "ns/instance" → version, from live PackageInstance manifests.
    let mut version_by_key: HashMap<String, String> = HashMap::new();
    for m in old_manifests {
        if m.get("kind").and_then(Value::as_str) != Some("PackageInstance") {
            continue;
        }
        let ns = m
            .pointer("/metadata/namespace")
            .and_then(Value::as_str)
            .unwrap_or("_cluster");
        let name = m
            .pointer("/spec/instanceName")
            .and_then(Value::as_str)
            .or_else(|| m.pointer("/metadata/name").and_then(Value::as_str));
        if let (Some(name), Some(version)) =
            (name, m.pointer("/spec/version").and_then(Value::as_str))
        {
            version_by_key.insert(format!("{ns}/{name}"), version.to_string());
        }
    }

    let mut graph = StoreGraph::empty(&new_graph.cluster_name);
    let mut paths_by_pkg: HashMap<String, Vec<PathBuf>> = HashMap::new();

    for (i, m) in old_manifests.iter().enumerate() {
        let ann = |key: &str| {
            m.pointer("/metadata/annotations")
                .and_then(|a| a.get(key))
                .and_then(Value::as_str)
        };
        let pkg = ann("kix.dev/package").unwrap_or("_cluster");
        let pkg_ns = ann("kix.dev/package-namespace").unwrap_or("_cluster");
        let hash = ann("kix.dev/identity-hash").unwrap_or("");

        let (path, manifest) = match new_path_by_hash.get(hash) {
            Some(&p) => (p.clone(), new_graph.resources[p].manifest.clone()),
            None => (
                PathBuf::from(format!("/nix/store/live-{i}-reconstructed")),
                m.clone(),
            ),
        };
        graph.resources.insert(
            path.clone(),
            ResourceNode {
                store_path: path.clone(),
                manifest,
            },
        );
        if pkg != "_cluster" {
            paths_by_pkg
                .entry(format!("{pkg_ns}/{pkg}"))
                .or_default()
                .push(path);
        }
    }

    let mut keys: Vec<String> = paths_by_pkg.keys().cloned().collect();
    keys.sort();
    for key in keys {
        let paths = paths_by_pkg.remove(&key).unwrap_or_default();
        let (pkg_ns, pkg_name) = key.split_once('/').unwrap_or(("_cluster", key.as_str()));

        // Order shared paths exactly like the new package so an untouched
        // package compares Vec-equal (→ unchanged); extras go last.
        let ordered = match new_graph
            .packages
            .values()
            .find(|p| p.namespace == pkg_ns && p.instance_name == pkg_name)
        {
            Some(new_pkg) => {
                let old_set: HashSet<&PathBuf> = paths.iter().collect();
                let new_set: HashSet<&PathBuf> = new_pkg.resource_paths.iter().collect();
                let mut ordered: Vec<PathBuf> = new_pkg
                    .resource_paths
                    .iter()
                    .filter(|p| old_set.contains(p))
                    .cloned()
                    .collect();
                let mut extras: Vec<PathBuf> = paths
                    .iter()
                    .filter(|p| !new_set.contains(p))
                    .cloned()
                    .collect();
                extras.sort();
                extras.dedup();
                ordered.extend(extras);
                ordered
            }
            None => {
                let mut sorted = paths;
                sorted.sort();
                sorted.dedup();
                sorted
            }
        };

        let store_path = PathBuf::from(format!("/nix/store/live-pkg-{pkg_ns}-{pkg_name}"));
        graph.packages.insert(
            store_path.clone(),
            PackageNode {
                store_path,
                instance_name: pkg_name.to_string(),
                namespace: pkg_ns.to_string(),
                version: version_by_key.get(&key).cloned(),
                lifecycle: None,
                resource_paths: ordered,
                cross_deps: vec![],
            },
        );
    }

    graph
}

// ── Apply engine (async) — DAG-streaming scheduler (doc 99) ─────────

/// Line-oriented observer for DAG-streaming deploy (doc 99 §7 "nix-build-L
/// style"). Emits one line per terminal verdict / phase boundary; readiness
/// heartbeats land on stderr with `-v`.
///
/// Until Stage C lands the tree renderer, this is the default CLI output for
/// every deploy, TTY or not. The design doc's redrawable grid (§5) is built
/// on top of the same event stream.
pub(crate) struct StreamCliObserver {
    pub(crate) quiet: bool,
    pub(crate) verbose: bool,
}

impl DeployObserver for StreamCliObserver {
    fn on_event(&self, event: &DeployEvent) {
        match event {
            DeployEvent::PlanComputed { nodes, .. } => {
                if !self.quiet {
                    println!("{} {} nodes", output::dim("plan:"), nodes.len(),);
                }
            }
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => self.render_node_state(node, *kind, verdict, detail.as_ref()),
            DeployEvent::CrdRediscovery => {
                if self.verbose {
                    eprintln!("{} re-running API discovery", output::dim("crd:"));
                }
            }
            DeployEvent::PruneStart { count } => {
                println!();
                println!(
                    "{} pruning {} orphaned resources...",
                    output::bold("prune:"),
                    count,
                );
            }
            DeployEvent::Finalized {
                activation,
                previous,
            } => {
                if !self.quiet {
                    if let Some(prev) = previous {
                        println!("  {} activation '{}' → Superseded", output::dim("•"), prev);
                    }
                    println!(
                        "  {} activation '{}' → Active",
                        output::green("•"),
                        activation,
                    );
                }
            }
            DeployEvent::Stopped { reason } => {
                eprintln!("\n{} {}", output::red("✗"), output::red(reason));
            }
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => {
                let line = kix::cluster::watchdog::describe(*idle, in_flight);
                if *aborting {
                    eprintln!("{} {line}; giving up", output::red("stalled:"));
                } else {
                    eprintln!("{} {line}", output::yellow("stalled:"));
                }
            }
            DeployEvent::BestEffortFailed { what, message } => {
                eprintln!("{} {what} failed: {message}", output::yellow("warn:"),);
            }
        }
    }
}

impl StreamCliObserver {
    fn render_node_state(
        &self,
        node: &NodeId,
        kind: TransitionKind,
        verdict: &Verdict,
        detail: Option<&NodeDetail>,
    ) {
        let label = self.node_label(node);
        let tag = kind
            .tag()
            .map(|t| format!("{} ", output::dim(t)))
            .unwrap_or_default();
        match verdict {
            Verdict::Pending => {}
            Verdict::Running => match detail {
                Some(NodeDetail::Applied(action))
                    if (!self.quiet || !matches!(action, ApplyAction::Unchanged)) =>
                {
                    let (symbol, lbl) = apply_symbol(action);
                    println!("  {} {}{} {}", symbol, tag, label, output::dim(lbl));
                }
                Some(NodeDetail::SecretHydrated { keys }) if !self.quiet => {
                    println!(
                        "  {} {} hydrated ({} keys from SOPS)",
                        output::green("🔓"),
                        label,
                        keys,
                    );
                }
                Some(NodeDetail::ReadinessProgress(_)) => {}
                _ => {}
            },
            Verdict::Ready => match detail {
                Some(NodeDetail::Applied(action)) => {
                    // Skip nodes reach Ready via Applied(Unchanged); render them
                    // as a single dim line under `-v`. Non-skip Ready events are
                    // still announced with a terminal ✔ line below.
                    if matches!(kind, TransitionKind::Skip) {
                        if self.verbose {
                            let (_, lbl) = apply_symbol(action);
                            println!(
                                "  {} {}{} {}",
                                output::dim("="),
                                tag,
                                label,
                                output::dim(lbl)
                            );
                        }
                    } else {
                        println!(
                            "  {} {} {}",
                            output::green("✔"),
                            label,
                            output::dim("ready")
                        );
                    }
                }
                Some(NodeDetail::RecreatedInPlace { reason }) => {
                    println!(
                        "  {} {} {} {}",
                        output::yellow("↻"),
                        label,
                        output::yellow("recreated (immutable-field conflict)"),
                        output::dim(reason),
                    );
                }
                _ => {
                    println!(
                        "  {} {} {}",
                        output::green("✔"),
                        label,
                        output::dim("ready")
                    );
                }
            },
            Verdict::Failed { message } => {
                let detail_tail = match detail {
                    Some(NodeDetail::ReadinessFailed { missing_keys, .. })
                        if !missing_keys.is_empty() =>
                    {
                        format!(
                            "\n    {} missing key(s): {}",
                            output::red("↳"),
                            missing_keys.join(", "),
                        )
                    }
                    Some(NodeDetail::ReadinessTimeout { elapsed, .. }) => {
                        format!(" {}", output::dim(&format!("({}s)", elapsed.as_secs())))
                    }
                    _ => String::new(),
                };
                eprintln!(
                    "  {} {} {}{}",
                    output::red("⚠"),
                    label,
                    output::red(message),
                    detail_tail,
                );
            }
            Verdict::Cancelled { because } => {
                if self.verbose {
                    let because = match because {
                        CancelReason::PredecessorFailed(rid) => format!("predecessor {rid} failed"),
                        CancelReason::External => "external cancel".to_string(),
                    };
                    println!(
                        "  {} {} {}",
                        output::dim("⊘"),
                        label,
                        output::dim(&format!("cancelled ({because})")),
                    );
                }
            }
            Verdict::AwaitingInput { prompt } => {
                println!(
                    "  {} {} {}",
                    output::yellow("⏯"),
                    label,
                    output::yellow(prompt)
                );
            }
            Verdict::DriftDetected { message, .. } => {
                println!(
                    "  {} {} {}",
                    output::yellow("↻"),
                    label,
                    output::yellow(message),
                );
            }
        }
    }

    fn node_label(&self, node: &NodeId) -> String {
        match node {
            NodeId::Resource(rid) => rid.to_string(),
            NodeId::Synthetic(s) => format!("⟦{s}⟧"),
        }
    }
}

fn apply_symbol(action: &ApplyAction) -> (std::borrow::Cow<'static, str>, &'static str) {
    // Apply-phase glyphs are intentionally muted — they share the screen with
    // the terminal ✔ `ready` lines, which should own the green accent.
    // Created: white (neutral new), Configured: yellow (changed), Skipped /
    // Unchanged: dim grey (no-op).
    match action {
        ApplyAction::Created => (std::borrow::Cow::Borrowed("+"), "created"),
        ApplyAction::Configured => (output::yellow("~"), "configured"),
        ApplyAction::Unchanged => (output::dim("="), "unchanged"),
        ApplyAction::Skipped => (output::dim("-"), "skipped"),
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_deploy_async(
    args: &DeployArgs,
    global: &crate::cli::GlobalArgs,
    plan: DeployPlan,
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    cluster_name: &str,
    activation_name: Option<&str>,
    activation_identity_hash: Option<&str>,
    pre_client: Option<kube::Client>,
) -> Result<()> {
    let timeout = parse_timeout(args.timeout.as_deref())?;

    // Reuse pre-established connection or create a new one
    let client = match pre_client {
        Some(c) => c,
        None => fetch::make_client(global.context.as_deref())
            .await
            .map_err(|e| {
                miette!(
                    "failed to connect to cluster: {e}. Check your kubeconfig or try --context <name>"
                )
            })?,
    };

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("API discovery failed: {e}"))?;
    let discovery = Arc::new(tokio::sync::RwLock::new(discovery));

    let prune_mode = args.prune_mode.unwrap_or(PruneMode::Default);
    let prune_policy = match prune_mode {
        PruneMode::No => PrunePolicy::Skip,
        PruneMode::Default if !args.prune => PrunePolicy::WarnOnly,
        PruneMode::Default | PruneMode::Eager => PrunePolicy::Delete,
    };
    let on_error = match args.on_error {
        OnError::Stop => OnErrorPolicy::Stop,
        OnError::Continue => OnErrorPolicy::Continue,
    };

    let config = SchedulerConfig {
        timeout,
        on_error,
        prune: prune_policy,
        cancel: kix::cluster::cancel::CancelToken::new(),
        dry_run: args.dry_run,
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
    };
    let ops: Arc<dyn ClusterOps> = Arc::new(KubeOps::new(
        client.clone(),
        discovery,
        KubeOpsConfig {
            cluster_name: cluster_name.to_string(),
            activation_name: activation_name.map(str::to_string),
            activation_identity_hash: activation_identity_hash.map(str::to_string),
            force_conflicts: args.force_conflicts,
            dry_run: args.dry_run,
        },
    ));

    // Observer selection (doc 99 §7, Stage D):
    //   --tui            → graph_stream TUI (requires interactive stdout)
    //   --log-format=json → NDJSON
    //   --log-format=line → nix-build-L idiom (no ANSI)
    //   --log-format=pretty on TTY → colored StreamCliObserver
    //   --log-format=pretty non-TTY → auto-fallback to line
    let interactive = output::is_interactive();
    let use_tui = args.tui && interactive;
    let tui_driver = if use_tui {
        let axis = if args.group_by_ns {
            super::graph_stream::GroupAxis::Namespace
        } else {
            super::graph_stream::GroupAxis::Package
        };
        match super::graph_stream::GraphStreamDriver::spawn(
            cluster_name.to_string(),
            config.cancel.clone(),
            args.fold_height,
            axis,
            super::graph_stream::GlyphStyle::detect(),
        ) {
            Ok(d) => Some(d),
            Err(e) => {
                eprintln!(
                    "{} {e} — falling back to plain output",
                    output::yellow("warn: failed to start --tui renderer:"),
                );
                None
            }
        }
    } else {
        None
    };

    let observer: Arc<dyn DeployObserver> = if let Some(d) = &tui_driver {
        d.observer()
    } else {
        match args.log_format {
            crate::cli::LogFormat::Json => {
                Arc::new(super::deploy_log::JsonObserver::new(global.verbose > 0))
            }
            crate::cli::LogFormat::Line => Arc::new(super::deploy_log::LineObserver {
                verbose: global.verbose > 0,
            }),
            crate::cli::LogFormat::Pretty if !interactive => {
                Arc::new(super::deploy_log::LineObserver {
                    verbose: global.verbose > 0,
                })
            }
            crate::cli::LogFormat::Pretty => Arc::new(StreamCliObserver {
                quiet: global.quiet,
                verbose: global.verbose > 0,
            }),
        }
    };

    let result =
        scheduler::run_deploy(ops, plan, orphan_rids, old_manifests, &config, observer).await;

    // Tear down the TUI before the summary prints so it lands in normal
    // scrollback below the history lines.
    drop(tui_driver);

    match result {
        Ok(r) => {
            println!();
            print_summary(&r, args.dry_run);
            Ok(())
        }
        Err(e) => {
            if let Some(r) = e.partial() {
                print_summary(r, args.dry_run);
            }
            if matches!(
                e,
                kix::cluster::scheduler::DeployError::DiscoveryFailed { .. }
                    | kix::cluster::scheduler::DeployError::Internal { .. }
            ) {
                eprintln!("{} {e}", output::red("error:"));
            }
            std::process::exit(1);
        }
    }
}

/// Decide whether an offline-dry-run Apply node corresponds to a Create or
/// a Configured action, by checking whether its K8s identity
/// (`kind/namespace/name`) is present in the old activation. Mirrors the
/// equivalent check that `apply_resource` does via `get_opt` against the
/// live cluster (apply.rs:326) — but locally, against the cached old
/// manifest set.
fn classify_offline_apply(
    rid: &ResourceId,
    old_by_k8s_id: &std::collections::HashSet<String>,
) -> kix::cluster::apply::ApplyAction {
    use kix::cluster::apply::ApplyAction;
    let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
    if old_by_k8s_id.contains(&k8s_id) {
        ApplyAction::Configured
    } else {
        ApplyAction::Created
    }
}

/// Offline dry-run preview — used when we don't have a cluster connection
/// (e.g. `--current-activation --dry-run`). Walks the plan, classifies each
/// Apply as Created/Configured by checking whether the K8s identity exists
/// in `old_manifests`, prints lines using the same `apply_symbol` glyphs the
/// real-deploy renderer uses, and prints the same summary line. No cluster
/// access. The classification is bounded — it doesn't run admission
/// webhooks or detect 409 conflicts; that's only possible with an online
/// SSA dry-run.
fn render_offline_dry_run(
    plan: &DeployPlan,
    old_manifests: &[Value],
    orphan_rids: &[ResourceId],
    global: &crate::cli::GlobalArgs,
) -> Result<()> {
    use kix::cluster::apply::ApplyAction;

    if global.quiet {
        return Ok(());
    }

    // Index old manifests by K8s identity so we can ask "did this exist?"
    // — same shape detect_changes uses internally (apply.rs:132-188).
    let old_by_k8s_id: std::collections::HashSet<String> = old_manifests
        .iter()
        .map(|m| {
            let rid = ResourceId::from_value(m);
            format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
        })
        .collect();

    println!();
    println!("{}", output::dim("Dry run — no changes will be applied."));

    let mut result = DeployResult::default();

    for node in &plan.nodes {
        let (rid, action) = match &node.action {
            ChangeAction::Apply(m) => {
                let rid = ResourceId::from_value(m);
                let action = classify_offline_apply(&rid, &old_by_k8s_id);
                (rid, action)
            }
            ChangeAction::Skip(rid) => (rid.clone(), ApplyAction::Unchanged),
            ChangeAction::Orphan(_) => continue,
        };

        let (symbol, lbl) = apply_symbol(&action);
        let pkg_tag = match &node.meta.package {
            Some(p) => format!("  {}", output::dim(p)),
            None => String::new(),
        };
        println!("  {} {} {}{}", symbol, rid, output::dim(lbl), pkg_tag);

        match action {
            ApplyAction::Created => result.created += 1,
            ApplyAction::Configured => result.configured += 1,
            ApplyAction::Unchanged => result.unchanged += 1,
            ApplyAction::Skipped => {}
        }
    }

    if !orphan_rids.is_empty() {
        println!();
        println!(
            "{} {} resources would be orphaned:",
            output::yellow("Orphans:"),
            orphan_rids.len(),
        );
        for rid in orphan_rids {
            println!("  {} {}", output::red("-"), rid);
        }
        result.pruned = orphan_rids.len();
    }

    println!();
    print_summary(&result, true);
    Ok(())
}

fn print_summary(r: &DeployResult, dry_run: bool) {
    let failed_str = r.failed.to_string();
    let cancelled_tail = if r.cancelled > 0 {
        format!(", {} cancelled", output::dim(&r.cancelled.to_string()),)
    } else {
        String::new()
    };
    let prefix = if dry_run {
        "Dry run complete"
    } else {
        "Deploy complete"
    };
    println!(
        "{}: {} created, {} configured, {} unchanged, {} failed{}",
        prefix,
        output::green(&r.created.to_string()),
        output::yellow(&r.configured.to_string()),
        output::dim(&r.unchanged.to_string()),
        if r.failed > 0 {
            output::red(&failed_str)
        } else {
            output::dim(&failed_str)
        },
        cancelled_tail,
    );
}

fn parse_timeout(s: Option<&str>) -> Result<Duration> {
    let Some(s) = s else {
        return Ok(readiness::DEFAULT_TIMEOUT);
    };

    let s = s.trim();
    if s.is_empty() {
        return Ok(readiness::DEFAULT_TIMEOUT);
    }

    if let Some(minutes) = s.strip_suffix('m')
        && let Ok(m) = minutes.parse::<u64>()
    {
        return Ok(Duration::from_secs(m * 60));
    }
    if let Some(seconds) = s.strip_suffix('s')
        && let Ok(secs) = seconds.parse::<u64>()
    {
        return Ok(Duration::from_secs(secs));
    }
    if let Ok(secs) = s.parse::<u64>() {
        return Ok(Duration::from_secs(secs));
    }

    Err(miette!(
        "invalid timeout format '{s}'. Use '5m', '300s', or a number of seconds"
    ))
}

pub(crate) fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
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

// ── Operator-delegated deploy ────────────────────────────────────────

fn run_operator(args: &DeployArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    // 1. Build new activation and load store graph (same as direct mode)
    if !ctx.global.quiet {
        println!(
            "Building cluster '{}' (operator mode)...",
            output::bold(&args.cluster)
        );
    }
    let status = |msg: &str| {
        if !ctx.global.quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &status)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    let mut new_graph = StoreGraph::from_result_dir_with_status(&result_path, &status)
        .map_err(|e| miette!("failed to load store graph: {e}"))?;
    stamp_annotations(&mut new_graph);
    if !ctx.global.quiet {
        eprint!("\r\x1b[2K");
    }

    let new_manifests: Vec<Value> = new_graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();

    let manifest_count = new_manifests.len();
    if !ctx.global.quiet {
        println!(
            "Cluster {}: {} manifests",
            output::bold(&new_graph.cluster_name),
            manifest_count,
        );
    }

    if manifest_count == 0 {
        if !ctx.global.quiet {
            println!("Nothing to deploy.");
        }
        return Ok(());
    }

    // 2. Find activation name and identity hash from manifests
    let activation_manifest = new_manifests.iter().find(|m| {
        m.get("kind")
            .and_then(|v| v.as_str())
            .is_some_and(|k| k == "Activation")
    });
    let activation_name = activation_manifest
        .and_then(|m| {
            m.pointer("/metadata/name")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .ok_or_else(|| miette!("no Activation resource found in cluster manifests"))?;
    let activation_identity_hash = activation_manifest.and_then(|m| {
        m.pointer("/metadata/annotations")
            .and_then(|a| a.get("kix.dev/identity-hash"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
    });

    // 3. Show plan (optional, same as direct mode)
    if !ctx.global.quiet {
        let old_graph = if args.current_activation {
            let (og, _) = load_old_from_cache(&args.cluster, &ctx.global);
            og
        } else {
            ctx.runtime
                .block_on(load_old_from_cluster(&args.cluster, &ctx.global))
                .ok()
                .and_then(|(og, _, _, _)| og)
        };

        let pkg_diff = match &old_graph {
            Some(old) => plan::diff_graphs(old, &new_graph),
            None => plan::diff_graphs(&StoreGraph::empty(&new_graph.cluster_name), &new_graph),
        };

        plan::print_package_plan(&pkg_diff, ctx.global.verbose > 0);
        plan::print_plan_summary(&pkg_diff);

        // Migration pair detection (doc 67) — same gate as direct mode.
        // Operator-mode is non-interactive on the operator side, so the
        // CLI must enforce the gate before handing off the Activation CR.
        let old_manifests_for_pairs: Vec<Value> = old_graph
            .as_ref()
            .map(|g| g.resources.values().map(|r| r.manifest.clone()).collect())
            .unwrap_or_default();
        let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests_for_pairs);
        if !migration_pairs.is_empty() {
            print_migration_pairs(&migration_pairs);
            if !args.accept_migrations {
                eprintln!(
                    "{}",
                    output::red(
                        "Refusing to delegate to operator: stateful migration pairs detected but --accept-migrations was not passed."
                    )
                );
                std::process::exit(1);
            }
        }
    }

    if args.dry_run {
        if !ctx.global.quiet {
            println!();
            println!("{}", output::dim("Dry run — no changes applied."));
        }
        return Ok(());
    }

    // 4. Confirmation
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
        print!("\nDelegate deploy to operator? [y/N] ");
        std::io::Write::flush(&mut std::io::stdout()).into_diagnostic()?;
        let mut input = String::new();
        std::io::stdin().read_line(&mut input).into_diagnostic()?;
        let input = input.trim().to_lowercase();
        if input != "y" && input != "yes" {
            println!("Deploy cancelled.");
            return Ok(());
        }
    }

    // 5. Apply Activation CR and watch progress
    let global = ctx.global.clone();
    let source_path = result_path.display().to_string();
    let cluster_name = new_graph.cluster_name.clone();

    ctx.runtime.block_on(async {
        let (client, ar) =
            super::operator::connect_and_verify(global.context.as_deref(), global.quiet).await?;

        if !global.quiet {
            println!(
                "Applying Activation CR '{}' (source: {})...",
                output::bold(&activation_name),
                output::dim(&source_path),
            );
        }

        super::operator::apply_activation(
            &client,
            &ar,
            &activation_name,
            &cluster_name,
            &source_path,
            activation_identity_hash.as_deref(),
        )
        .await?;

        if !global.quiet {
            println!(
                "  {} Activation CR applied — waiting for operator...",
                output::green("✓"),
            );
        }

        super::operator::watch_activation_progress(
            &client,
            &ar,
            &activation_name,
            &source_path,
            global.quiet,
        )
        .await?;

        println!();
        println!(
            "Deploy via operator {}: Activation '{}' is {}",
            output::green("complete"),
            output::bold(&activation_name),
            output::green("Active"),
        );

        Ok::<(), miette::Report>(())
    })?;

    // Save activation path for next deploy's diff
    if let Err(e) = kix::eval::store::save_activation_path(&args.cluster, &result_path) {
        tracing::warn!("failed to save activation path: {e}");
    }

    Ok(())
}

/// Render detected stateful migration pairs to stdout. Phase 1 of doc 67:
/// awareness only, the user must handle data movement out-of-band before
/// re-running deploy with --accept-migrations.
fn print_migration_pairs(pairs: &[MigrationPair]) {
    println!();
    println!(
        "{}",
        output::bold(&format!("Stateful migrations detected ({}):", pairs.len()))
    );
    for p in pairs {
        println!("  {} {}", output::yellow("~"), output::yellow(&p.summary()));
        println!(
            "      source: {}/{}/{}",
            p.source.kind, p.source.namespace, p.source.name
        );
        println!(
            "      target: {}/{}/{}",
            p.target.kind, p.target.namespace, p.target.name
        );
    }
    println!();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_timeout_none() {
        let t = parse_timeout(None).unwrap();
        assert_eq!(t, readiness::DEFAULT_TIMEOUT);
    }

    #[test]
    fn parse_timeout_seconds() {
        assert_eq!(parse_timeout(Some("60s")).unwrap(), Duration::from_secs(60));
    }

    #[test]
    fn parse_timeout_minutes() {
        assert_eq!(parse_timeout(Some("5m")).unwrap(), Duration::from_secs(300));
    }

    #[test]
    fn parse_timeout_plain_number() {
        assert_eq!(
            parse_timeout(Some("120")).unwrap(),
            Duration::from_secs(120)
        );
    }

    #[test]
    fn parse_timeout_invalid() {
        assert!(parse_timeout(Some("abc")).is_err());
    }

    // ── Offline-dry-run classification ───────────────────────────────────
    //
    // The dangerous regression #15 surfaced was: an in-place update
    // mis-rendered as a Create. These tests pin the apiserver-shaped
    // semantics that classify_offline_apply implements (mirror of
    // apply_resource's `existed` check at apply.rs:326): when the K8s
    // identity (kind/namespace/name) is in the old activation, it's a
    // Configured; otherwise, it's a Created.

    use kix::cluster::apply::ApplyAction;
    use kix::manifest::types::ResourceId;

    fn old_by_id(rids: &[(&str, &str, &str)]) -> std::collections::HashSet<String> {
        rids.iter()
            .map(|(k, ns, n)| format!("{k}/{ns}/{n}"))
            .collect()
    }

    fn rid(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.to_string(),
            namespace: ns.to_string(),
            name: name.to_string(),
        }
    }

    #[test]
    fn classify_offline_apply_existing_is_configured() {
        let old = old_by_id(&[("Deployment", "lithus-system", "lithus-secret-operator")]);
        let action = classify_offline_apply(
            &rid("Deployment", "lithus-system", "lithus-secret-operator"),
            &old,
        );
        assert!(matches!(action, ApplyAction::Configured));
    }

    #[test]
    fn classify_offline_apply_new_is_created() {
        let old = old_by_id(&[("Service", "default", "other")]);
        let action = classify_offline_apply(&rid("Deployment", "default", "fresh"), &old);
        assert!(matches!(action, ApplyAction::Created));
    }

    #[test]
    fn classify_offline_apply_distinguishes_kind() {
        // Same name+namespace but different kind must classify as Created —
        // an in-cluster Service and Deployment named "foo" in "default" are
        // genuinely distinct resources.
        let old = old_by_id(&[("Service", "default", "foo")]);
        let action = classify_offline_apply(&rid("Deployment", "default", "foo"), &old);
        assert!(matches!(action, ApplyAction::Created));
    }

    #[test]
    fn classify_offline_apply_distinguishes_namespace() {
        let old = old_by_id(&[("Deployment", "ns-a", "foo")]);
        let action = classify_offline_apply(&rid("Deployment", "ns-b", "foo"), &old);
        assert!(matches!(action, ApplyAction::Created));
    }
}
