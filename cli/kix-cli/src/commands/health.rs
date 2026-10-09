//! Check cluster integrity by walking identity-hash dependencies.
//!
//! No nix build required. Finds the active Activation CR, fetches all
//! kix-managed resources, builds an identity-hash index, and walks the
//! dependency graph to verify integrity.

use std::collections::{BTreeMap, HashMap};

use miette::{Result, miette};

use kix::cluster::activation::{Record, Records};
use kix::cluster::fetch;
use kix::manifest::types::ResourceId;

use crate::cli::HealthArgs;
use crate::output;

use super::CommandContext;
use kix::manifest::keys;
use kix::manifest::lifecycle::declares_own_deletion;

// Annotation keys
const IDENTITY_HASH: &str = keys::IDENTITY_HASH;
const DEPENDS_ON: &str = keys::DEPENDS_ON;
const PACKAGE: &str = keys::PACKAGE;
const PACKAGE_NAMESPACE: &str = keys::PACKAGE_NAMESPACE;

/// A live resource with its parsed annotations.
#[allow(dead_code)]
struct LiveResource {
    rid: ResourceId,
    identity_hash: String,
    package: String,
    package_namespace: String,
    depends_on: Vec<String>,
    is_import: bool,
    raw: serde_json::Value,
}

/// Per-resource health status after graph walk.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ResourceHealth {
    /// Reachable from activation root, all deps present.
    Healthy,
    /// Import marker for an external resource.
    External,
    /// Referenced in depends-on but not found in live resources.
    Missing { expected_by: String },
    /// Run-to-completion resource that declared its own deletion (a hook Job
    /// with `hook-succeeded` delete policy, or `ttlSecondsAfterFinished`) and
    /// is gone. Absence is the success path, not a fault.
    Reaped { expected_by: String },
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
        let all_external = self
            .resources
            .iter()
            .all(|(_, h)| matches!(h, ResourceHealth::External));
        let has_missing = self
            .resources
            .iter()
            .any(|(_, h)| matches!(h, ResourceHealth::Missing { .. }));
        let has_at_risk = self
            .resources
            .iter()
            .any(|(_, h)| matches!(h, ResourceHealth::AtRisk { .. }));
        let all_reaped = self
            .resources
            .iter()
            .all(|(_, h)| matches!(h, ResourceHealth::Reaped { .. }));

        if all_external {
            "external"
        } else if all_reaped {
            "completed"
        } else if has_missing {
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
            .filter(|(_, h)| {
                matches!(
                    h,
                    ResourceHealth::Healthy
                        | ResourceHealth::External
                        | ResourceHealth::Reaped { .. }
                )
            })
            .count()
    }

    fn is_healthy(&self) -> bool {
        self.resources.iter().all(|(_, h)| {
            matches!(
                h,
                ResourceHealth::Healthy | ResourceHealth::External | ResourceHealth::Reaped { .. }
            )
        })
    }

    fn reaped_count(&self) -> usize {
        self.resources
            .iter()
            .filter(|(_, h)| matches!(h, ResourceHealth::Reaped { .. }))
            .count()
    }
}

pub fn run(args: &HealthArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::ReadOnly)?;

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
            .map_err(|e| miette!("{e}"))?;

        // 2. Find active Activation CR
        let records = Records::open_installed(&client, &discovery).map_err(|e| miette!("{e}"))?;

        let active = records
            .active(&cluster)
            .await
            .map_err(|e| miette!("failed to find activation: {e}"))?
            .ok_or_else(|| miette!("no active deployment record found for cluster '{cluster}'"))?;

        // 3. Fetch this cluster's kix-managed resources
        let live_objects = fetch::fetch_managed_resources(
            &client,
            &discovery,
            fetch::SweepScope::Cluster(&cluster),
        )
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

    for obj in resources {
        // Whole object: metadata lives on the typed field, not in `.data`.
        let rid = ResourceId::from_value(&fetch::to_manifest_value(&obj));

        // Read annotations from typed metadata (more reliable than raw data)
        let annotations = obj.metadata.annotations.as_ref();
        let identity_hash = annotations
            .and_then(|a| keys::get_meta(a, IDENTITY_HASH))
            .map(str::to_string)
            .unwrap_or_default();
        let package = annotations
            .and_then(|a| keys::get_meta(a, PACKAGE))
            .map(str::to_string)
            .unwrap_or_else(|| "_cluster".to_string());
        let package_namespace = annotations
            .and_then(|a| keys::get_meta(a, PACKAGE_NAMESPACE))
            .map(str::to_string)
            .unwrap_or_else(|| "_cluster".to_string());
        let is_import = kix::manifest::lifecycle::lifecycle_of_live(&obj)
            == kix::manifest::lifecycle::Lifecycle::Marker;
        let depends_on_str = annotations
            .and_then(|a| keys::get_meta(a, DEPENDS_ON))
            .map(str::to_string)
            .unwrap_or_default();
        let depends_on: Vec<String> = depends_on_str
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| {
                // Strip an optional dependency type prefix.
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
                is_import,
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
/// Checks all resources directly; no root is required.
fn walk_graph(
    _activation: &Record,
    live_by_hash: &HashMap<String, LiveResource>,
    verbose: u8,
) -> BTreeMap<String, ResourceHealth> {
    let mut health: BTreeMap<String, ResourceHealth> = BTreeMap::new();
    let mut missing_hashes: BTreeMap<String, String> = BTreeMap::new(); // hash to expected_by
    let mut reaped_hashes: BTreeMap<String, String> = BTreeMap::new(); // hash to expected_by

    // Pre-pass: an absent dependency is only a fault if it was supposed to
    // still be there. Hook Jobs delete themselves on success (delete policy)
    // or are reaped by the TTL controller, so their absence is the success
    // path. The manifest is not on the cluster to ask, but the seal that
    // minted the hash is in the local Nix store. That is what
    // `resolve_hash_to_rid` already reads to name missing resources.
    let reaped: std::collections::HashSet<String> = live_by_hash
        .values()
        .filter(|r| !r.is_import)
        .flat_map(|r| r.depends_on.iter())
        .filter(|dep| !live_by_hash.contains_key(*dep))
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .filter(|dep| read_seal(dep).is_some_and(|m| declares_own_deletion(&m)))
        .cloned()
        .collect();

    // First pass: check each resource's direct dependencies
    for (hash, resource) in live_by_hash {
        // Import markers refer to external resources.
        if resource.is_import {
            health.insert(hash.clone(), ResourceHealth::External);
            continue;
        }

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
            if live_by_hash.contains_key(dep_hash) {
                continue;
            }
            let dep_label = &dep_hash[..8.min(dep_hash.len())];

            if reaped.contains(dep_hash) {
                reaped_hashes
                    .entry(dep_hash.clone())
                    .or_insert_with(|| format!("{}", resource.rid));

                if verbose > 1 {
                    println!(
                        "    {} dependency {}... completed and reaped",
                        output::green("✓"),
                        dep_label,
                    );
                }
                continue;
            }

            all_deps_ok = false;
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

    // Record reaped run-to-completion resources
    for (hash, expected_by) in reaped_hashes {
        health
            .entry(hash)
            .or_insert(ResourceHealth::Reaped { expected_by });
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

    // Add resources that exist only as a hash: never applied (missing) or
    // applied, completed and removed on purpose (reaped).
    for (hash, health) in health_map {
        if live_by_hash.contains_key(hash) {
            continue;
        }
        let bucket = match health {
            ResourceHealth::Missing { .. } => "_missing",
            ResourceHealth::Reaped { .. } => "_reaped",
            _ => continue,
        };
        let rid = resolve_hash_to_rid(hash);
        pkg_map
            .entry(("_cluster".to_string(), bucket.to_string()))
            .or_default()
            .push((rid, health.clone()));
    }

    pkg_map
        .into_iter()
        .map(|((namespace, instance_name), mut resources)| {
            resources.sort_by(|(a, _), (b, _)| a.cmp(b));
            let display_name = if namespace == "_cluster" {
                if instance_name == "_missing" {
                    "(missing resources)".to_string()
                } else if instance_name == "_reaped" {
                    "(completed hooks)".to_string()
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
            "external" => output::dim("→"),
            "completed" => output::dim("✓"),
            "DEGRADED" => output::red("✗"),
            "AT RISK" => output::yellow("!"),
            _ => output::dim("?"),
        };

        let external_count = pkg
            .resources
            .iter()
            .filter(|(_, h)| matches!(h, ResourceHealth::External))
            .count();
        let reaped_count = pkg.reaped_count();
        let counts = if reaped_count == total {
            format!("{} completed, then removed", total)
        } else if external_count == total {
            format!("{} imported", total)
        } else if external_count > 0 {
            format!(
                "{}/{} resources healthy, {} imported",
                healthy - external_count,
                total - external_count,
                external_count
            )
        } else {
            format!("{}/{} resources healthy", healthy, total)
        };
        let counts_colored = if status == "completed" {
            output::dim(&counts)
        } else if healthy == total {
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
                "  {} {:<40} {}. {}",
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

    // Detailed resource-level output for anything not plainly in-sync.
    // Reaped hooks are named too: they used to read as MISSING, so saying
    // which ones completed is the point of the section.
    let detailed_packages: Vec<&PackageHealth> = packages
        .iter()
        .filter(|p| !p.is_healthy() || p.reaped_count() > 0)
        .collect();

    if !detailed_packages.is_empty() {
        println!();

        for pkg in &detailed_packages {
            println!("{}", output::bold(&format!("{}:", pkg.display_name)));

            let reaped: Vec<_> = pkg
                .resources
                .iter()
                .filter(|(_, h)| matches!(h, ResourceHealth::Reaped { .. }))
                .collect();
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

            if !reaped.is_empty() {
                for (rid, health) in &reaped {
                    if let ResourceHealth::Reaped { expected_by } = health {
                        println!(
                            "  {} {} {} {}",
                            output::dim("✓"),
                            output::dim("COMPLETED"),
                            rid,
                            output::dim(&format!(
                                "(ran, then removed itself; required by {})",
                                expected_by
                            )),
                        );
                    }
                }
            }

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
    let total_healthy: usize = packages
        .iter()
        .flat_map(|p| &p.resources)
        .filter(|(_, h)| matches!(h, ResourceHealth::Healthy))
        .count();
    let total_external: usize = packages
        .iter()
        .flat_map(|p| &p.resources)
        .filter(|(_, h)| matches!(h, ResourceHealth::External))
        .count();
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
    let total_reaped: usize = packages.iter().map(|p| p.reaped_count()).sum();

    let healthy_str = total_healthy.to_string();
    let external_str = total_external.to_string();
    let missing_str = total_missing.to_string();
    let at_risk_str = total_at_risk.to_string();
    let reaped_str = total_reaped.to_string();

    println!();
    print!("Health: {} in-sync", output::green(&healthy_str));
    if total_external > 0 {
        print!(", {} imported", output::dim(&external_str));
    }
    if total_reaped > 0 {
        print!(", {} completed", output::dim(&reaped_str));
    }
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

/// Locate the seal that minted an identity hash in the local nix store.
///
/// A hash names exactly one store path, so a directory scan for the
/// `{hash}-` prefix is the whole lookup. Returns `None` when the store does
/// not have it, for example when health runs on a machine that never built this
/// activation, or after a `nix-collect-garbage`.
fn store_path_for_hash(hash: &str) -> Option<std::path::PathBuf> {
    let prefix = format!("{}-", hash);
    std::fs::read_dir("/nix/store")
        .ok()?
        .filter_map(Result::ok)
        .find(|e| e.file_name().to_string_lossy().starts_with(&prefix))
        .map(|e| e.path())
}

/// Read the sealed manifest behind an identity hash from the local nix store.
/// The seal is the manifest JSON as it was at eval time, which is how health
/// can still reason about a resource that is no longer on the cluster.
fn read_seal(hash: &str) -> Option<serde_json::Value> {
    let path = store_path_for_hash(hash)?;
    let contents = std::fs::read_to_string(path).ok()?;
    let mut value: serde_json::Value = serde_json::from_str(&contents).ok()?;
    // Until the first deploy after the domain move, the hashes that reach
    // here are pre-move store hashes, so the seal behind them spells its
    // annotations under the retired domain. These are Nix-rendered keys, not
    // CLI stamps, and readers here look them up by exact name: an
    // un-upgraded seal makes every self-deleting hook Job read as Missing
    // and `kix health` exit 1 on a healthy cluster.
    kix::legacy_domain::upgrade_manifest(&mut value);
    Some(value)
}

/// Try to resolve a nix store hash to a ResourceId.
/// Store paths follow the convention: /nix/store/{hash}-k8s-{Kind}-{namespace}-{name}
fn resolve_hash_to_rid(hash: &str) -> ResourceId {
    if let Some(path) = store_path_for_hash(hash)
        && let Some(filename) = path.file_name()
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reaped_counts_as_healthy() {
        let pkg = PackageHealth {
            display_name: "(completed hooks)".to_string(),
            resources: vec![(
                ResourceId {
                    kind: "Job".to_string(),
                    namespace: "data".to_string(),
                    name: "postgres-reflect".to_string(),
                },
                ResourceHealth::Reaped {
                    expected_by: "PackageInstance/postgres@data".to_string(),
                },
            )],
        };
        assert!(pkg.is_healthy());
        assert_eq!(pkg.status_label(), "completed");
        assert_eq!(pkg.reaped_count(), 1);
    }
}
