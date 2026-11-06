//! Check cluster integrity by walking `kix.run/identity-hash` dependencies.
//!
//! Locates the active Activation CR, fetches Kix-managed resources for the
//! cluster, indexes them by identity hash, and walks their dependency graph
//! without evaluating a Nix flake.

use std::collections::{BTreeMap, HashMap};

use miette::{Result, miette};

use crate::client;
use kix::cluster::activation::{OpenedRecords, Record, Records};
use kix::cluster::{discovery, inventory};
use kix::manifest::types::{ResourceId, to_manifest_value};

use crate::cli::HealthArgs;
use crate::output;

use super::CommandContext;
use kix::manifest::keys;

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

/// Per-resource health status after walking the dependency graph.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ResourceHealth {
    /// Reachable from the activation root with all dependencies present.
    Healthy,
    /// Import marker for an external resource.
    External,
    /// Referenced in `depends-on` but absent from live resources.
    Missing { expected_by: String },
    /// Resource is present on the cluster, but depends on an unhealthy resource.
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
        if all_external {
            "external"
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
            .filter(|(_, h)| matches!(h, ResourceHealth::Healthy | ResourceHealth::External))
            .count()
    }

    fn is_healthy(&self) -> bool {
        self.resources
            .iter()
            .all(|(_, h)| matches!(h, ResourceHealth::Healthy | ResourceHealth::External))
    }
}

pub fn run(args: &HealthArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::ReadOnly)?;

    crate::say!("Connecting to cluster...");

    let (activation, resources) = ctx.runtime.block_on(async {
        let client = client::make_client(ctx.global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect: {e}"))?;

        let discovery = discovery::discover_resources(&client)
            .await
            .map_err(|e| miette!("{e}"))?;

        let records = Records::open_installed(&client, &discovery).map_err(|e| miette!("{e}"))?;

        let active = records
            .active(&cluster)
            .await
            .map_err(|e| miette!("{e}"))?
            .ok_or_else(|| miette!("no active deployment record found for cluster '{cluster}'"))?;

        let live_objects = inventory::fetch_managed_resources(
            &client,
            &discovery,
            &OpenedRecords::from(records.clone()),
            inventory::SweepScope::Cluster(&cluster),
        )
        .await
        .map_err(|e| miette!("failed to fetch resources: {e}"))?;

        Ok::<_, miette::Report>((active, live_objects))
    })?;

    crate::say!(
        "Activation: {} (hash: {})",
        output::bold(&activation.name),
        activation.identity_hash.as_deref().unwrap_or("unknown"),
    );

    let mut live_by_hash: HashMap<String, LiveResource> = HashMap::new();

    for obj in resources {
        // `DynamicObject` stores metadata on its typed `metadata` field rather than in `data`.
        let rid = ResourceId::from_value(&to_manifest_value(&obj));

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
                // Strip an optional `<kind>:` prefix from the dependency entry.
                s.rsplit_once(':')
                    .map(|(_, hash)| hash)
                    .unwrap_or(s)
                    .to_string()
            })
            .collect();

        if identity_hash.is_empty() {
            continue;
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

    // Keep only resources reachable from the active activation so superseded
    // activations and orphaned dependencies do not appear in the report.
    let active_hash = activation.identity_hash.as_deref().unwrap_or("");
    let reachable = reachable_from(active_hash, &live_by_hash);
    let live_by_hash: HashMap<String, LiveResource> = live_by_hash
        .into_iter()
        .filter(|(h, _)| reachable.contains(h))
        .collect();

    crate::say!("{} kix-managed resources on cluster", live_by_hash.len());

    let health_map = walk_graph(&activation, &live_by_hash, ctx.global.verbose);

    let packages = group_by_package(&live_by_hash, &health_map);
    display_results(&packages, ctx.global.verbose);

    let has_issues = packages.iter().any(|p| !p.is_healthy());
    if has_issues {
        std::process::exit(1);
    }

    Ok(())
}

/// Evaluate each resource's dependencies against `live_by_hash`.
fn walk_graph(
    _activation: &Record,
    live_by_hash: &HashMap<String, LiveResource>,
    verbose: u8,
) -> BTreeMap<String, ResourceHealth> {
    let mut health: BTreeMap<String, ResourceHealth> = BTreeMap::new();
    let mut missing_hashes: BTreeMap<String, String> = BTreeMap::new();

    for (hash, resource) in live_by_hash {
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

    // Propagate `AtRisk` transitively to resources that depend on an `AtRisk`
    // resource.
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

    for (hash, expected_by) in missing_hashes {
        health
            .entry(hash)
            .or_insert(ResourceHealth::Missing { expected_by });
    }

    health
}

/// Return all identity hashes transitively reachable from `root_hash`.
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

fn group_by_package(
    live_by_hash: &HashMap<String, LiveResource>,
    health_map: &BTreeMap<String, ResourceHealth>,
) -> Vec<PackageHealth> {
    let mut pkg_map: BTreeMap<(String, String), Vec<(ResourceId, ResourceHealth)>> =
        BTreeMap::new();

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

    // Bucket missing dependencies, which exist only in `health_map` and not
    // in `live_by_hash`.
    for (hash, health) in health_map {
        if live_by_hash.contains_key(hash) || !matches!(health, ResourceHealth::Missing { .. }) {
            continue;
        }
        let rid = resolve_hash_to_rid(hash);
        pkg_map
            .entry(("_cluster".to_string(), "_missing".to_string()))
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

fn display_results(packages: &[PackageHealth], verbose: u8) {
    crate::say!();

    println!("{}", output::bold("Packages:"));
    for pkg in packages {
        let total = pkg.resources.len();
        let healthy = pkg.healthy_count();
        let status = pkg.status_label();

        let status_colored = match status {
            "healthy" => output::green("✓"),
            "external" => output::dim("→"),
            "DEGRADED" => output::red("✗"),
            "AT RISK" => output::yellow("!"),
            _ => output::dim("?"),
        };

        let external_count = pkg
            .resources
            .iter()
            .filter(|(_, h)| matches!(h, ResourceHealth::External))
            .count();
        let counts = if external_count == total {
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

    // Print per-resource detail for unhealthy packages.
    let detailed_packages: Vec<&PackageHealth> =
        packages.iter().filter(|p| !p.is_healthy()).collect();

    if !detailed_packages.is_empty() {
        println!();

        for pkg in &detailed_packages {
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

    let healthy_str = total_healthy.to_string();
    let external_str = total_external.to_string();
    let missing_str = total_missing.to_string();
    let at_risk_str = total_at_risk.to_string();

    println!();
    print!("Health: {} in-sync", output::green(&healthy_str));
    if total_external > 0 {
        print!(", {} imported", output::dim(&external_str));
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

/// Find the store path in `/nix/store` matching `{hash}-*`, or `None` if the
/// local store does not have that derivation.
fn store_path_for_hash(hash: &str) -> Option<std::path::PathBuf> {
    let prefix = format!("{}-", hash);
    std::fs::read_dir("/nix/store")
        .ok()?
        .filter_map(Result::ok)
        .find(|e| e.file_name().to_string_lossy().starts_with(&prefix))
        .map(|e| e.path())
}

/// Parse a `ResourceId` from the `/nix/store/{hash}-k8s-{Kind}-{namespace}-{name}`
/// store path filename, or fall back to an `Unknown` placeholder.
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
