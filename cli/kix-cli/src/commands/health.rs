//! `kix health` — cluster-side integrity check via Merkle walk.
//!
//! No nix build required. Finds the active Activation CR, fetches all
//! kix-managed resources, builds an identity-hash index, and walks the
//! dependency graph to verify integrity.

use std::collections::{BTreeMap, HashMap};

use miette::{Result, miette};

use kix::cluster::activation::{self, ActiveActivation};
use kix::cluster::fetch;
use kix::manifest::types::ResourceId;

use crate::cli::HealthArgs;
use crate::output;

use super::CommandContext;

// Annotation keys
const IDENTITY_HASH: &str = "kix.dev/identity-hash";
const DEPENDS_ON: &str = "kix.dev/depends-on";
const PACKAGE: &str = "kix.dev/package";
const PACKAGE_NAMESPACE: &str = "kix.dev/package-namespace";

/// A live resource with its parsed annotations.
#[allow(dead_code)]
struct LiveResource {
    rid: ResourceId,
    identity_hash: String,
    package: String,
    package_namespace: String,
    depends_on: Vec<String>,
    raw: serde_json::Value,
}

/// Per-resource health status after graph walk.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ResourceHealth {
    /// Reachable from activation root, all deps present.
    Healthy,
    /// Referenced in depends-on but not found in live resources.
    Missing { expected_by: String },
    /// Resource itself is OK, but depends on something unhealthy.
    AtRisk { reason: String },
}

/// Package-level health summary.
struct PackageHealth {
    display_name: String,
    resources: Vec<(ResourceId, ResourceHealth)>,
}

impl PackageHealth {
    fn status_label(&self) -> &'static str {
        let has_missing = self
            .resources
            .iter()
            .any(|(_, h)| matches!(h, ResourceHealth::Missing { .. }));
        let has_at_risk = self
            .resources
            .iter()
            .any(|(_, h)| matches!(h, ResourceHealth::AtRisk { .. }));

        if has_missing {
            "DEGRADED"
        } else if has_at_risk {
            "AT RISK"
        } else {
            "healthy"
        }
    }

    fn healthy_count(&self) -> usize {
        self.resources
            .iter()
            .filter(|(_, h)| matches!(h, ResourceHealth::Healthy))
            .count()
    }

    fn is_healthy(&self) -> bool {
        self.resources
            .iter()
            .all(|(_, h)| matches!(h, ResourceHealth::Healthy))
    }
}

pub fn run(args: &HealthArgs, ctx: &mut CommandContext) -> Result<()> {
    // 1. Connect to cluster
    if !ctx.global.quiet {
        println!("Connecting to cluster...");
    }

    let (activation, resources) = ctx.runtime.block_on(async {
        let client = fetch::make_client(ctx.global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect: {e}"))?;

        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("API discovery failed: {e}"))?;

        // 2. Find active Activation CR
        let activation_ar = activation::find_activation_ar(&discovery)
            .ok_or_else(|| miette!("Activation CRD not registered on cluster"))?;

        let active = activation::find_active(&client, &activation_ar.0, &args.cluster)
            .await
            .map_err(|e| miette!("failed to find activation: {e}"))?
            .ok_or_else(|| miette!("no active activation found for cluster '{}'", args.cluster))?;

        // 3. Fetch all kix-managed resources
        let live_objects = fetch::fetch_managed_resources(&client, &discovery)
            .await
            .map_err(|e| miette!("failed to fetch resources: {e}"))?;

        Ok::<_, miette::Report>((active, live_objects))
    })?;

    if !ctx.global.quiet {
        println!(
            "Activation: {} (hash: {})",
            output::bold(&activation.name),
            activation.identity_hash.as_deref().unwrap_or("unknown"),
        );
    }

    // 4. Parse live resources and build identity-hash index
    let mut live_by_hash: HashMap<String, LiveResource> = HashMap::new();

    for mut obj in resources {
        // Merge typed metadata back into raw data (LIST responses may omit it)
        if let Some(map) = obj.data.as_object_mut() {
            let meta = map
                .entry("metadata")
                .or_insert_with(|| serde_json::json!({}));
            if let Some(meta_obj) = meta.as_object_mut() {
                if let Some(name) = &obj.metadata.name {
                    meta_obj
                        .entry("name")
                        .or_insert_with(|| serde_json::Value::String(name.clone()));
                }
                if let Some(ns) = &obj.metadata.namespace {
                    meta_obj
                        .entry("namespace")
                        .or_insert_with(|| serde_json::Value::String(ns.clone()));
                }
            }
        }

        let rid = ResourceId::from_value(&obj.data);

        // Read annotations from typed metadata (more reliable than raw data)
        let annotations = obj.metadata.annotations.as_ref();
        let identity_hash = annotations
            .and_then(|a| a.get(IDENTITY_HASH))
            .cloned()
            .unwrap_or_default();
        let package = annotations
            .and_then(|a| a.get(PACKAGE))
            .cloned()
            .unwrap_or_else(|| "_cluster".to_string());
        let package_namespace = annotations
            .and_then(|a| a.get(PACKAGE_NAMESPACE))
            .cloned()
            .unwrap_or_else(|| "_cluster".to_string());
        let depends_on_str = annotations
            .and_then(|a| a.get(DEPENDS_ON))
            .cloned()
            .unwrap_or_default();
        let depends_on: Vec<String> = depends_on_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| {
                // Strip dependency type prefix (e.g. "requires:hash" → "hash")
                s.rsplit_once(':')
                    .map(|(_, hash)| hash)
                    .unwrap_or(s)
                    .to_string()
            })
            .collect();

        if identity_hash.is_empty() {
            continue; // Skip resources without identity hash (not kix-stamped)
        }

        live_by_hash.insert(
            identity_hash.clone(),
            LiveResource {
                rid,
                identity_hash,
                package,
                package_namespace,
                depends_on,
                raw: obj.data,
            },
        );
    }

    // 5. Filter to only resources reachable from the active activation.
    //    Old/superseded activations and their orphaned deps are excluded so
    //    they don't pollute the health report.
    let active_hash = activation.identity_hash.as_deref().unwrap_or("");
    let reachable = reachable_from(active_hash, &live_by_hash);
    let live_by_hash: HashMap<String, LiveResource> = live_by_hash
        .into_iter()
        .filter(|(h, _)| reachable.contains(h))
        .collect();

    if !ctx.global.quiet {
        println!("{} kix-managed resources on cluster", live_by_hash.len());
    }

    // 6. Walk the dependency graph from activation root
    let health_map = walk_graph(&activation, &live_by_hash, ctx.global.verbose);

    // 7. Group by package and display
    let packages = group_by_package(&live_by_hash, &health_map);
    display_results(&packages, ctx.global.verbose, ctx.global.quiet);

    let has_issues = packages.iter().any(|p| !p.is_healthy());
    if has_issues {
        std::process::exit(1);
    }

    Ok(())
}

/// Check every resource's dependencies against the live index.
/// No root needed — we check all resources and verify their deps exist.
fn walk_graph(
    _activation: &ActiveActivation,
    live_by_hash: &HashMap<String, LiveResource>,
    verbose: u8,
) -> BTreeMap<String, ResourceHealth> {
    let mut health: BTreeMap<String, ResourceHealth> = BTreeMap::new();
    let mut missing_hashes: BTreeMap<String, String> = BTreeMap::new(); // hash → expected_by

    // First pass: check each resource's direct dependencies
    for (hash, resource) in live_by_hash {
        if verbose > 1 {
            println!(
                "  {} checking {} ({})",
                output::dim("→"),
                resource.rid,
                &hash[..8.min(hash.len())],
            );
        }

        let mut all_deps_ok = true;
        let mut broken_dep: Option<String> = None;

        for dep_hash in &resource.depends_on {
            if !live_by_hash.contains_key(dep_hash) {
                all_deps_ok = false;
                let dep_label = &dep_hash[..8.min(dep_hash.len())];
                missing_hashes
                    .entry(dep_hash.clone())
                    .or_insert_with(|| format!("{}", resource.rid));
                broken_dep = Some(format!("hash {}... (MISSING)", dep_label));

                if verbose > 1 {
                    println!(
                        "    {} dependency {}... MISSING",
                        output::red("✗"),
                        dep_label,
                    );
                }
            }
        }

        if all_deps_ok {
            health.insert(hash.clone(), ResourceHealth::Healthy);
        } else {
            let reason = broken_dep.unwrap_or_else(|| "dependency missing".to_string());
            health.insert(hash.clone(), ResourceHealth::AtRisk { reason });
        }
    }

    // Second pass: propagate at-risk forward through transitive deps.
    // If resource A depends on B and B is at-risk, A becomes at-risk too.
    let mut changed = true;
    while changed {
        changed = false;
        let current_health = health.clone();
        for (hash, resource) in live_by_hash {
            if !matches!(current_health.get(hash), Some(ResourceHealth::Healthy)) {
                continue;
            }
            for dep_hash in &resource.depends_on {
                if matches!(
                    current_health.get(dep_hash),
                    Some(ResourceHealth::AtRisk { .. })
                ) {
                    let dep_label = if let Some(dep_res) = live_by_hash.get(dep_hash) {
                        format!("{} (AT RISK)", dep_res.rid)
                    } else {
                        format!("{}... (MISSING)", &dep_hash[..8.min(dep_hash.len())])
                    };
                    health.insert(hash.clone(), ResourceHealth::AtRisk { reason: dep_label });
                    changed = true;
                    break;
                }
            }
        }
    }

    // Record missing resources
    for (hash, expected_by) in missing_hashes {
        health
            .entry(hash)
            .or_insert(ResourceHealth::Missing { expected_by });
    }

    health
}

/// BFS from a root hash to find all transitively reachable identity hashes.
fn reachable_from(
    root_hash: &str,
    live_by_hash: &HashMap<String, LiveResource>,
) -> std::collections::HashSet<String> {
    let mut visited = std::collections::HashSet::new();
    let mut queue = std::collections::VecDeque::new();

    if live_by_hash.contains_key(root_hash) {
        queue.push_back(root_hash.to_string());
        visited.insert(root_hash.to_string());
    }

    while let Some(hash) = queue.pop_front() {
        if let Some(resource) = live_by_hash.get(&hash) {
            for dep_hash in &resource.depends_on {
                if live_by_hash.contains_key(dep_hash) && visited.insert(dep_hash.clone()) {
                    queue.push_back(dep_hash.clone());
                }
            }
        }
    }

    visited
}

/// Group resources by package for display.
fn group_by_package(
    live_by_hash: &HashMap<String, LiveResource>,
    health_map: &BTreeMap<String, ResourceHealth>,
) -> Vec<PackageHealth> {
    let mut pkg_map: BTreeMap<(String, String), Vec<(ResourceId, ResourceHealth)>> =
        BTreeMap::new();

    // Add live resources grouped by package
    for (hash, resource) in live_by_hash {
        let health = health_map
            .get(hash)
            .cloned()
            .unwrap_or(ResourceHealth::Healthy);

        pkg_map
            .entry((resource.package_namespace.clone(), resource.package.clone()))
            .or_default()
            .push((resource.rid.clone(), health));
    }

    // Add missing resources (no live resource, just a hash)
    for (hash, health) in health_map {
        if let ResourceHealth::Missing { .. } = health
            && !live_by_hash.contains_key(hash)
        {
            let rid = resolve_hash_to_rid(hash);
            pkg_map
                .entry(("_cluster".to_string(), "_missing".to_string()))
                .or_default()
                .push((rid, health.clone()));
        }
    }

    pkg_map
        .into_iter()
        .map(|((namespace, instance_name), mut resources)| {
            resources.sort_by(|(a, _), (b, _)| a.cmp(b));
            let display_name = if namespace == "_cluster" {
                if instance_name == "_missing" {
                    "(missing resources)".to_string()
                } else if instance_name == "_cluster" {
                    "(cluster-level)".to_string()
                } else {
                    instance_name.clone()
                }
            } else {
                format!("{} ({})", instance_name, namespace)
            };
            PackageHealth {
                display_name,
                resources,
            }
        })
        .collect()
}

fn display_results(packages: &[PackageHealth], verbose: u8, quiet: bool) {
    if !quiet {
        println!();
    }

    // Package summary table
    println!("{}", output::bold("Packages:"));
    for pkg in packages {
        let total = pkg.resources.len();
        let healthy = pkg.healthy_count();
        let status = pkg.status_label();

        let status_colored = match status {
            "healthy" => output::green("✓"),
            "DEGRADED" => output::red("✗"),
            "AT RISK" => output::yellow("!"),
            _ => output::dim("?"),
        };

        let counts = format!("{}/{} resources healthy", healthy, total);
        let counts_colored = if healthy == total {
            output::green(&counts)
        } else if healthy == 0 {
            output::red(&counts)
        } else {
            output::yellow(&counts)
        };

        if pkg.is_healthy() {
            println!(
                "  {} {:<40} {}",
                status_colored, pkg.display_name, counts_colored,
            );
        } else {
            let issues = summarize_issues(&pkg.resources);
            println!(
                "  {} {:<40} {} — {}",
                status_colored,
                pkg.display_name,
                counts_colored,
                match status {
                    "DEGRADED" => output::red(&issues),
                    "AT RISK" => output::yellow(&issues),
                    _ => output::dim(&issues),
                },
            );
        }
    }

    // Detailed resource-level output for unhealthy packages
    let unhealthy_packages: Vec<&PackageHealth> =
        packages.iter().filter(|p| !p.is_healthy()).collect();

    if !unhealthy_packages.is_empty() {
        println!();

        for pkg in &unhealthy_packages {
            println!("{}", output::bold(&format!("{}:", pkg.display_name)));

            let missing: Vec<_> = pkg
                .resources
                .iter()
                .filter(|(_, h)| matches!(h, ResourceHealth::Missing { .. }))
                .collect();
            let at_risk: Vec<_> = pkg
                .resources
                .iter()
                .filter(|(_, h)| matches!(h, ResourceHealth::AtRisk { .. }))
                .collect();

            if !missing.is_empty() {
                for (rid, health) in &missing {
                    if let ResourceHealth::Missing { expected_by } = health {
                        println!(
                            "  {} {} {} {}",
                            output::red("!"),
                            output::red("MISSING"),
                            rid,
                            output::dim(&format!("(expected by {})", expected_by)),
                        );
                    }
                }
            }

            if !at_risk.is_empty() {
                println!(
                    "  {} {}",
                    output::yellow("⚠"),
                    output::yellow("AT RISK (depends on broken resources):"),
                );
                for (rid, health) in &at_risk {
                    if let ResourceHealth::AtRisk { reason } = health {
                        println!(
                            "    {} {} {} {}",
                            output::yellow("→"),
                            rid,
                            output::dim("← depends on"),
                            output::dim(reason),
                        );
                    }
                }
            }

            println!();
        }

        if verbose == 0 {
            println!(
                "{}",
                output::dim("Use -vv for detailed graph traversal output.")
            );
        }
    }

    // Summary line
    let total_healthy: usize = packages.iter().map(|p| p.healthy_count()).sum();
    let total_missing: usize = packages
        .iter()
        .flat_map(|p| &p.resources)
        .filter(|(_, h)| matches!(h, ResourceHealth::Missing { .. }))
        .count();
    let total_at_risk: usize = packages
        .iter()
        .flat_map(|p| &p.resources)
        .filter(|(_, h)| matches!(h, ResourceHealth::AtRisk { .. }))
        .count();

    let healthy_str = total_healthy.to_string();
    let missing_str = total_missing.to_string();
    let at_risk_str = total_at_risk.to_string();

    println!();
    print!("Health: {} in-sync", output::green(&healthy_str));
    if total_missing > 0 {
        print!(", {} missing", output::red(&missing_str));
    }
    if total_at_risk > 0 {
        print!(", {} at risk", output::yellow(&at_risk_str));
    }
    let pkg_healthy = packages.iter().filter(|p| p.is_healthy()).count();
    let pkg_total = packages.len();
    print!(" ({}/{} packages healthy)", pkg_healthy, pkg_total,);
    println!();
}

/// Try to resolve a nix store hash to a ResourceId via `nix-store -q --outputs`.
/// Store paths follow the convention: /nix/store/{hash}-k8s-{Kind}-{namespace}-{name}
fn resolve_hash_to_rid(hash: &str) -> ResourceId {
    // Use nix-store --query to resolve the hash to a path
    if let Ok(output) = std::process::Command::new("nix-store")
        .args(["--query", "--outputs", &format!("/nix/store/{}", hash)])
        .output()
    {
        // nix-store --query fails if the path doesn't exist, but the error message
        // contains the attempted path. Instead, just try to stat the store path prefix.
        let _ = output; // nix-store --query --outputs needs a full path, not a hash prefix
    }

    // Direct approach: nix store paths are addressable by hash.
    // Try to find the path with a shell glob via ls.
    if let Ok(output) = std::process::Command::new("bash")
        .args([
            "-c",
            &format!("ls -d /nix/store/{}-* 2>/dev/null | head -1", hash),
        ])
        .output()
        && output.status.success()
    {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty()
            && let Some(filename) = std::path::Path::new(&path).file_name()
        {
            let name_str = filename.to_string_lossy();
            let prefix = format!("{}-", hash);
            if let Some(rest) = name_str.strip_prefix(&prefix) {
                let parts: Vec<&str> = rest.splitn(4, '-').collect();
                if parts.len() == 4 && parts[0] == "k8s" {
                    let kind = parts[1].to_string();
                    let namespace = if parts[2] == "_cluster_" {
                        "_cluster".to_string()
                    } else {
                        parts[2].to_string()
                    };
                    let name = parts[3].to_string();
                    return ResourceId {
                        kind,
                        namespace,
                        name,
                    };
                }
            }
        }
    }

    // Fallback: just show the hash
    let display_hash = &hash[..12.min(hash.len())];
    ResourceId {
        kind: "Unknown".to_string(),
        namespace: "_cluster".to_string(),
        name: format!("(hash: {}...)", display_hash),
    }
}

fn summarize_issues(resources: &[(ResourceId, ResourceHealth)]) -> String {
    let missing = resources
        .iter()
        .filter(|(_, h)| matches!(h, ResourceHealth::Missing { .. }))
        .count();
    let at_risk = resources
        .iter()
        .filter(|(_, h)| matches!(h, ResourceHealth::AtRisk { .. }))
        .count();

    let mut parts = Vec::new();
    if missing > 0 {
        parts.push(format!("{} missing", missing));
    }
    if at_risk > 0 {
        parts.push(format!("{} at risk", at_risk));
    }
    parts.join(", ")
}
