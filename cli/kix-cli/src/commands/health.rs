//! Check cluster integrity by walking `kix.run/identity-hash` dependencies.
//!
//! Locates the active Activation CR, fetches Kix-managed resources for the
//! cluster, indexes them by identity hash, and walks their dependency graph
//! without evaluating a Nix flake.

use std::collections::{BTreeMap, HashMap, HashSet};

use miette::{Result, miette};

use crate::client;
use kix::cluster::activation::{OpenedRecords, Records};
use kix::cluster::{discovery, inventory};
use kix::eval::package_index::RecordPackageIndex;
use kix::eval::store_graph::{self, StoreEntry};
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId, to_manifest_value};

use crate::cli::HealthArgs;
use crate::exit::Exit;
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
    /// Store hash of the file named by `kix.run/sops-source`, which the
    /// library also lists in `kix.run/depends-on`.
    sops_source: Option<String>,
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

pub fn run(args: &HealthArgs, ctx: &mut CommandContext) -> Result<Exit> {
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
            .ok_or_else(|| super::no_active_record(&cluster))?;

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

        let sops_source = annotations
            .and_then(|a| keys::get_meta(a, keys::SOPS_SOURCE))
            .map(|p| store_graph::store_hash(std::path::Path::new(p)))
            .filter(|h| !h.is_empty());

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
                sops_source,
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

    let unresolved: HashSet<&str> = live_by_hash
        .values()
        .flat_map(|r| &r.depends_on)
        .filter(|h| !live_by_hash.contains_key(*h))
        .map(String::as_str)
        .collect();
    let store = store_graph::lookup_hashes(unresolved.iter().copied());
    let not_objects = non_object_deps(activation.package_index.as_ref(), &live_by_hash, &store);

    let health_map = walk_graph(&live_by_hash, &not_objects, ctx.global.verbose);

    let packages = group_by_package(&live_by_hash, &health_map, &store);
    display_results(&packages, ctx.global.verbose);

    let has_issues = packages.iter().any(|p| !p.is_healthy());
    Ok(Exit::failure_if(has_issues))
}

/// Return the `(resource, dependency)` pairs whose dependency hash names no
/// Kubernetes object, so its absence from the cluster is not a missing object.
///
/// `kix.run/depends-on` lists every store path a manifest refers to, which
/// includes files such as a Secret's SOPS source. With the active record's
/// package index, only the hashes it lists are objects. Without one, a hash
/// is not an object when the local store holds it under a name that is not a
/// resource, or when it is the object's own `kix.run/sops-source`.
fn non_object_deps(
    index: Option<&RecordPackageIndex>,
    live_by_hash: &HashMap<String, LiveResource>,
    store: &HashMap<String, StoreEntry>,
) -> HashSet<(String, String)> {
    let indexed = index.map(RecordPackageIndex::hashes);
    let mut out = HashSet::new();
    for (hash, resource) in live_by_hash {
        for dep in &resource.depends_on {
            if live_by_hash.contains_key(dep) {
                continue;
            }
            let object = match &indexed {
                Some(indexed) => indexed.contains(dep.as_str()),
                None => {
                    !matches!(store.get(dep), Some(StoreEntry::Other))
                        && resource.sops_source.as_ref() != Some(dep)
                }
            };
            if !object {
                out.insert((hash.clone(), dep.clone()));
            }
        }
    }
    out
}

/// Evaluate each resource's dependencies against `live_by_hash`, skipping the
/// dependencies in `not_objects`.
fn walk_graph(
    live_by_hash: &HashMap<String, LiveResource>,
    not_objects: &HashSet<(String, String)>,
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
            if live_by_hash.contains_key(dep_hash)
                || not_objects.contains(&(hash.clone(), dep_hash.clone()))
            {
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
    store: &HashMap<String, StoreEntry>,
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
        let rid = resolve_hash_to_rid(hash, store);
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

/// Return the identity of the object with identity hash `hash`, read from its
/// manifest in the local store, or an `Unknown` placeholder naming the hash.
fn resolve_hash_to_rid(hash: &str, store: &HashMap<String, StoreEntry>) -> ResourceId {
    if let Some(StoreEntry::Resource(rid)) = store.get(hash) {
        return rid.clone();
    }
    let display_hash = &hash[..12.min(hash.len())];
    ResourceId {
        kind: "Unknown".to_string(),
        namespace: CLUSTER_SCOPED.to_string(),
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
    use kix::eval::package_index::{FORMAT, IndexedPackage};

    fn h(c: char) -> String {
        c.to_string().repeat(32)
    }

    fn live(name: &str, depends_on: &[String], sops_source: Option<String>) -> LiveResource {
        LiveResource {
            rid: ResourceId {
                kind: "Secret".to_string(),
                namespace: "data".to_string(),
                name: name.to_string(),
            },
            identity_hash: String::new(),
            package: "app-db".to_string(),
            package_namespace: "data".to_string(),
            depends_on: depends_on.to_vec(),
            sops_source,
            is_import: false,
            raw: serde_json::Value::Null,
        }
    }

    fn index(resources: &[String]) -> RecordPackageIndex {
        RecordPackageIndex {
            format: FORMAT,
            packages: BTreeMap::from([(
                "data/app-db".to_string(),
                IndexedPackage {
                    instance: h('p'),
                    resources: resources.to_vec(),
                },
            )]),
            cluster_level: vec![],
        }
    }

    /// A Secret depends on its SOPS file and on a ConfigMap. The record's
    /// index lists the ConfigMap only, so only the ConfigMap is missing.
    #[test]
    fn a_hash_the_index_does_not_list_is_not_a_missing_object() {
        let (secret, sops, cm) = (h('s'), h('f'), h('c'));
        let live_by_hash = HashMap::from([(
            secret.clone(),
            live("app-db-credentials", &[sops.clone(), cm.clone()], None),
        )]);
        let index = index(&[secret.clone(), cm.clone()]);

        let not_objects = non_object_deps(Some(&index), &live_by_hash, &HashMap::new());
        let health = walk_graph(&live_by_hash, &not_objects, 0);

        assert!(matches!(health[&cm], ResourceHealth::Missing { .. }));
        assert!(!health.contains_key(&sops));
    }

    #[test]
    fn a_secret_whose_only_store_dependency_is_its_sops_file_is_healthy() {
        let (secret, sops) = (h('s'), h('f'));
        let live_by_hash = HashMap::from([(
            secret.clone(),
            live("app-db-credentials", std::slice::from_ref(&sops), None),
        )]);
        let index = index(std::slice::from_ref(&secret));

        let not_objects = non_object_deps(Some(&index), &live_by_hash, &HashMap::new());
        let health = walk_graph(&live_by_hash, &not_objects, 0);

        assert_eq!(health.len(), 1);
        assert_eq!(health[&secret], ResourceHealth::Healthy);
    }

    /// A record with no package index falls back to the object's own
    /// `kix.run/sops-source` and to what the local store holds.
    #[test]
    fn without_an_index_the_sops_source_and_store_files_are_not_objects() {
        let (secret, sops, script, gone) = (h('s'), h('f'), h('x'), h('g'));
        let live_by_hash = HashMap::from([(
            secret.clone(),
            live(
                "app-db-credentials",
                &[sops.clone(), script.clone(), gone.clone()],
                Some(sops.clone()),
            ),
        )]);
        let store = HashMap::from([(script.clone(), StoreEntry::Other)]);

        let not_objects = non_object_deps(None, &live_by_hash, &store);
        let health = walk_graph(&live_by_hash, &not_objects, 0);

        assert!(!health.contains_key(&sops));
        assert!(!health.contains_key(&script));
        assert!(matches!(health[&gone], ResourceHealth::Missing { .. }));
    }

    #[test]
    fn a_missing_object_is_named_from_its_manifest() {
        let svc = h('a');
        let store = HashMap::from([(
            svc.clone(),
            StoreEntry::Resource(ResourceId {
                kind: "Service".to_string(),
                namespace: "cnpg-system".to_string(),
                name: "cnpg-webhook-service".to_string(),
            }),
        )]);
        assert_eq!(
            resolve_hash_to_rid(&svc, &store).to_string(),
            "Service/cnpg-webhook-service@cnpg-system"
        );
        assert_eq!(
            resolve_hash_to_rid(&h('b'), &HashMap::new()).to_string(),
            "Unknown/(hash: bbbbbbbbbbbb...)"
        );
    }
}
