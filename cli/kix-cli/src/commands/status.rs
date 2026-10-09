use std::collections::HashMap;

use miette::{IntoDiagnostic, Result, miette};

use crate::cli::StatusArgs;
use crate::output::{self, CommandResponse};
use kix::build_source::Build;
use kix::cluster::activation::Records;
use kix::cluster::readiness;
use kix::cluster::{client, discovery, inventory};
use kix::eval::store_graph::StoreGraph;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::CommandContext;
use kix::manifest::keys;

#[derive(serde::Serialize)]
struct ResourceStatus {
    name: String,
    namespace: String,
    kind: String,
    ready: String,
    status: String,
    age: String,
}

struct StatusResponse {
    statuses: Vec<ResourceStatus>,
}

impl CommandResponse for StatusResponse {
    fn format_text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["NAME", "NAMESPACE", "KIND", "READY", "STATUS", "AGE"]);
        for s in &self.statuses {
            table.add_row([&s.name, &s.namespace, &s.kind, &s.ready, &s.status, &s.age]);
        }
        table.to_string()
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::to_value(&self.statuses).unwrap_or_default()
    }
}

#[derive(serde::Serialize)]
struct PackageStatus {
    name: String,
    namespace: String,
    total: usize,
    healthy: usize,
    degraded: usize,
    resources: Vec<PackageResourceStatus>,
}

#[derive(serde::Serialize)]
struct PackageResourceStatus {
    name: String,
    kind: String,
    namespace: String,
    ready: bool,
    status: String,
    identity_hash: String,
    age: String,
}

#[derive(serde::Serialize)]
struct ActivationStatus {
    name: String,
    phase: String,
    identity_hash: String,
    age: String,
}

#[derive(serde::Serialize)]
struct OperatorStatusResponse {
    cluster: String,
    activation: Option<ActivationStatus>,
    packages: Vec<PackageStatus>,
    unowned: Vec<PackageResourceStatus>,
}

impl CommandResponse for OperatorStatusResponse {
    fn format_text(&self) -> String {
        let mut out = String::new();

        // Cluster header
        out.push_str(&format!("Cluster: {}\n", output::bold(&self.cluster)));

        // Activation info
        match &self.activation {
            Some(act) => {
                let phase_str = match act.phase.as_str() {
                    "Active" => output::green(&act.phase),
                    "Deploying" | "Queued" | "Degraded" => output::yellow(&act.phase),
                    "Failed" => output::red(&act.phase),
                    _ => output::dim(&act.phase),
                };
                let hash_short = if act.identity_hash.len() > 8 {
                    &act.identity_hash[..8]
                } else {
                    &act.identity_hash
                };
                out.push_str(&format!(
                    "Activation: {}  {}  {}  {}\n",
                    output::bold(&act.name),
                    phase_str,
                    output::dim(&format!("({}..)", hash_short)),
                    output::dim(&act.age),
                ));
            }
            None => {
                out.push_str(&format!(
                    "Activation: {}\n",
                    output::dim("none (no active activation found)"),
                ));
            }
        }

        out.push('\n');

        if self.packages.is_empty() && self.unowned.is_empty() {
            out.push_str(&output::dim("No resources found.\n"));
            return out;
        }

        // Package summaries
        out.push_str("Packages:\n");
        for pkg in &self.packages {
            let degraded_label = format!("{} degraded", pkg.degraded);
            let health = if pkg.degraded == 0 {
                output::green("healthy")
            } else {
                output::red(&degraded_label)
            };
            let res_label = if pkg.total == 1 {
                "resource"
            } else {
                "resources"
            };
            out.push_str(&format!(
                "  {:<28} {} {}   {}\n",
                output::bold(&pkg.name),
                pkg.total,
                output::dim(res_label),
                health,
            ));
        }

        // Detailed resource view for packages with degraded resources,
        // or all packages in verbose mode (handled by caller via output format)
        let has_degraded: Vec<&PackageStatus> =
            self.packages.iter().filter(|p| p.degraded > 0).collect();

        if !has_degraded.is_empty() {
            out.push('\n');
            for pkg in has_degraded {
                out.push_str(&format!("  {}:\n", output::bold(&pkg.name)));
                out.push_str(&format!(
                    "    {:<28} {:<20} {:<8} {:<12} {:<12} {}\n",
                    output::dim("NAME"),
                    output::dim("KIND"),
                    output::dim("READY"),
                    output::dim("STATUS"),
                    output::dim("HASH"),
                    output::dim("AGE"),
                ));
                for r in &pkg.resources {
                    let ready_str = if r.ready {
                        "True".to_string()
                    } else {
                        output::red("False").to_string()
                    };
                    let hash_short = if r.identity_hash.len() > 8 {
                        format!("{}..", &r.identity_hash[..8])
                    } else {
                        r.identity_hash.clone()
                    };
                    out.push_str(&format!(
                        "    {:<28} {:<20} {:<8} {:<12} {:<12} {}\n",
                        r.name, r.kind, ready_str, r.status, hash_short, r.age,
                    ));
                }
            }
        }

        if !self.unowned.is_empty() {
            out.push_str(&format!(
                "\n  {} (not matched to a package):\n",
                output::dim("Unowned resources"),
            ));
            for r in &self.unowned {
                let ready_str = if r.ready { "True" } else { "False" };
                out.push_str(&format!(
                    "    {:<28} {:<20} {:<8} {}\n",
                    r.name, r.kind, ready_str, r.status,
                ));
            }
        }

        out
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or_default()
    }
}

pub fn run(args: &StatusArgs, ctx: &mut CommandContext) -> Result<()> {
    if args.operator {
        return run_operator(args, ctx);
    }

    // Legacy: flat resource view
    let built = ctx.eval_cluster_or_suggest(&args.cluster)?;
    let cluster = match built.cluster_name() {
        Some(name) => name.to_string(),
        None => ctx.cluster_identity(&args.cluster, super::Lookup::ReadOnly)?,
    };
    let global = ctx.global.clone();
    ctx.runtime.block_on(run_flat_async(&cluster, &global))
}

fn run_operator(args: &StatusArgs, ctx: &mut CommandContext) -> Result<()> {
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::ReadOnly)?;
    let global = ctx.global.clone();
    ctx.runtime.block_on(run_operator_async(&cluster, &global))
}

async fn run_operator_async(cluster_name: &str, global: &crate::cli::GlobalArgs) -> Result<()> {
    let spinner = output::spinner("Fetching cluster status...");

    // 1. Connect and discover
    let client = client::make_client(global.context.as_deref())
        .await
        .into_diagnostic()?;
    let discovery = discovery::discover_resources(&client)
        .await
        .into_diagnostic()?;

    // 2. Find the Active Activation CR
    let opened = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
    let active = match opened.records() {
        Some(records) => records.active(cluster_name).await.into_diagnostic()?,
        None => None,
    };
    let built_via = active.as_ref().and_then(|act| act.built_via.clone());
    let activation_status = active.map(|act| ActivationStatus {
        age: compute_age(act.created_at),
        identity_hash: act.identity_hash.unwrap_or_default(),
        phase: act.phase,
        name: act.name,
    });

    // 3. Load store graph for package grouping (if we have a built-via path)
    let store_graph = built_via
        .as_ref()
        .map(std::path::PathBuf::from)
        .filter(|p| p.join("kix-packages.json").exists())
        .and_then(|result_dir| Build::local(&result_dir, &|_| {}).ok())
        .map(Build::into_graph);

    // 4. Fetch this cluster's live resources
    let sweep = inventory::sweep_managed(
        &client,
        &discovery,
        &opened,
        inventory::SweepScope::Cluster(cluster_name),
    )
    .await
    .into_diagnostic()?;

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }
    for note in sweep.scope_notes() {
        crate::esay!("{note}");
    }
    let live_resources = sweep.managed;

    // Index live objects by resource identity.
    let live_by_id: HashMap<String, &kube::api::DynamicObject> = live_resources
        .iter()
        .map(|obj| {
            let rid = resource_id_from_obj(obj);
            (format!("{}/{}/{}", rid.kind, rid.namespace, rid.name), obj)
        })
        .collect();

    // 6. Build package-grouped output
    let (packages, unowned) = match &store_graph {
        Some(graph) => build_package_view(graph, &live_by_id),
        None => {
            // Without a store graph, every resource is unowned.
            let unowned = live_resources
                .iter()
                .map(resource_status_from_obj)
                .collect();
            (vec![], unowned)
        }
    };

    let response = OperatorStatusResponse {
        cluster: cluster_name.to_string(),
        activation: activation_status,
        packages,
        unowned,
    };

    output::result(&response)
}

/// Build the package-grouped view by joining store graph packages with live cluster resources.
fn build_package_view(
    graph: &StoreGraph,
    live_by_id: &HashMap<String, &kube::api::DynamicObject>,
) -> (Vec<PackageStatus>, Vec<PackageResourceStatus>) {
    let mut packages = Vec::new();
    let mut matched_ids: std::collections::HashSet<String> = std::collections::HashSet::new();

    for (_store_path, pkg) in &graph.packages {
        let mut resources = Vec::new();

        for res_path in &pkg.resource_paths {
            let Some(res_node) = graph.resources.get(res_path) else {
                continue;
            };
            let rid = ResourceId::from_value(&res_node.manifest);
            let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);

            let (ready, status_str, age, identity_hash) = if let Some(obj) = live_by_id.get(&k8s_id)
            {
                let kind = rid.kind.as_str();
                let is_ready = readiness::check_readiness(obj, kind);
                let status = compute_status(obj, kind);
                let age = compute_age_from_obj(obj);
                let hash = obj
                    .metadata
                    .annotations
                    .as_ref()
                    .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
                    .map(str::to_string)
                    .unwrap_or_default();
                (is_ready, status, age, hash)
            } else {
                (
                    false,
                    "NotFound".to_string(),
                    "-".to_string(),
                    String::new(),
                )
            };

            matched_ids.insert(k8s_id);

            resources.push(PackageResourceStatus {
                name: rid.name,
                kind: rid.kind,
                namespace: rid.namespace,
                ready,
                status: status_str,
                identity_hash,
                age,
            });
        }

        resources.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.name.cmp(&b.name)));

        let total = resources.len();
        let healthy = resources.iter().filter(|r| r.ready).count();
        let degraded = total - healthy;

        packages.push(PackageStatus {
            name: pkg.instance_name.clone(),
            namespace: pkg.namespace.clone(),
            total,
            healthy,
            degraded,
            resources,
        });
    }

    // Sort packages alphabetically
    packages.sort_by(|a, b| a.name.cmp(&b.name));

    // Unowned: live resources not matched to any package
    let mut unowned: Vec<PackageResourceStatus> = live_by_id
        .iter()
        .filter(|(id, _)| !matched_ids.contains(id.as_str()))
        .map(|(_, obj)| resource_status_from_obj(obj))
        .collect();
    unowned.sort_by(|a, b| a.kind.cmp(&b.kind).then_with(|| a.name.cmp(&b.name)));

    (packages, unowned)
}

fn resource_id_from_obj(obj: &kube::api::DynamicObject) -> ResourceId {
    let kind = obj
        .data
        .get("kind")
        .and_then(|v| v.as_str())
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("Unknown")
        .to_string();
    let namespace = obj
        .metadata
        .namespace
        .as_deref()
        .unwrap_or(CLUSTER_SCOPED)
        .to_string();
    let name = obj
        .metadata
        .name
        .as_deref()
        .unwrap_or("unknown")
        .to_string();
    ResourceId {
        kind,
        namespace,
        name,
    }
}

fn resource_status_from_obj(obj: &kube::api::DynamicObject) -> PackageResourceStatus {
    let rid = resource_id_from_obj(obj);
    let is_ready = readiness::check_readiness(obj, &rid.kind);
    let status = compute_status(obj, &rid.kind);
    let age = compute_age_from_obj(obj);
    let hash = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
        .map(str::to_string)
        .unwrap_or_default();
    PackageResourceStatus {
        name: rid.name,
        kind: rid.kind,
        namespace: rid.namespace,
        ready: is_ready,
        status,
        identity_hash: hash,
        age,
    }
}

fn compute_age_from_obj(obj: &kube::api::DynamicObject) -> String {
    compute_age(obj.metadata.creation_timestamp.as_ref().map(|t| t.0))
}

/// How long ago `created` was, or "-" without one.
fn compute_age(created: Option<chrono::DateTime<chrono::Utc>>) -> String {
    match created {
        Some(created) => {
            let now = chrono::Utc::now();
            let duration = now.signed_duration_since(created);
            format_duration(duration)
        }
        None => "-".into(),
    }
}

async fn run_flat_async(cluster: &str, global: &crate::cli::GlobalArgs) -> Result<()> {
    let spinner = output::spinner("Fetching cluster status...");

    let client = client::make_client(global.context.as_deref())
        .await
        .into_diagnostic()?;
    let discovery = discovery::discover_resources(&client)
        .await
        .into_diagnostic()?;
    // Past the domain gate: on a cluster whose records sit under a retired
    // group every object would be listed as this cluster's.
    let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
    let sweep = inventory::sweep_managed(
        &client,
        &discovery,
        &records,
        inventory::SweepScope::Cluster(cluster),
    )
    .await
    .into_diagnostic()?;

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }

    for note in sweep.scope_notes() {
        crate::esay!("{note}");
    }
    let resources = sweep.managed;
    if resources.is_empty() {
        eprintln!("No resources of Kix cluster {cluster} found on the cluster.");
        return Ok(());
    }

    let mut statuses: Vec<ResourceStatus> = resources
        .iter()
        .map(|obj| {
            let rid = resource_id_from_obj(obj);
            let is_ready = readiness::check_readiness(obj, &rid.kind);
            let ready_str = if is_ready { "True" } else { "False" }.to_string();
            let status_str = compute_status(obj, &rid.kind);
            let age_str = compute_age_from_obj(obj);

            ResourceStatus {
                name: rid.name,
                namespace: rid.namespace,
                kind: rid.kind,
                ready: ready_str,
                status: status_str,
                age: age_str,
            }
        })
        .collect();

    statuses.sort_by(|a, b| {
        a.namespace
            .cmp(&b.namespace)
            .then_with(|| a.kind.cmp(&b.kind))
            .then_with(|| a.name.cmp(&b.name))
    });

    let response = StatusResponse { statuses };
    output::result(&response)
}

/// Compute a human-readable status string for a resource.
fn compute_status(obj: &kube::api::DynamicObject, kind: &str) -> String {
    match kind {
        "Deployment" | "StatefulSet" => {
            let desired = obj
                .data
                .pointer("/spec/replicas")
                .and_then(|v| v.as_i64())
                .unwrap_or(1);
            let ready = obj
                .data
                .pointer("/status/readyReplicas")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            format!("{ready}/{desired}")
        }
        "DaemonSet" => {
            let desired = obj
                .data
                .pointer("/status/desiredNumberScheduled")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let ready = obj
                .data
                .pointer("/status/numberReady")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            format!("{ready}/{desired}")
        }
        "Job" => {
            let succeeded = obj
                .data
                .pointer("/status/succeeded")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let active = obj
                .data
                .pointer("/status/active")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            if succeeded > 0 {
                "Complete".into()
            } else if active > 0 {
                "Running".into()
            } else {
                "Pending".into()
            }
        }
        "PersistentVolumeClaim" => obj
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("Unknown")
            .to_string(),
        _ => {
            if let Some(conditions) = obj
                .data
                .pointer("/status/conditions")
                .and_then(|v| v.as_array())
            {
                for c in conditions {
                    let ctype = c.get("type").and_then(|v| v.as_str()).unwrap_or("");
                    let status = c.get("status").and_then(|v| v.as_str()).unwrap_or("");
                    if (ctype == "Ready" || ctype == "Available") && status == "True" {
                        return ctype.to_string();
                    }
                }
            }
            "Active".into()
        }
    }
}

/// Format a chrono::Duration as a human-readable age string.
fn format_duration(d: chrono::Duration) -> String {
    let total_seconds = d.num_seconds();
    if total_seconds < 0 {
        return "0s".into();
    }

    let days = total_seconds / 86400;
    let hours = (total_seconds % 86400) / 3600;
    let minutes = (total_seconds % 3600) / 60;

    if days > 0 {
        format!("{}d{}h", days, hours)
    } else if hours > 0 {
        format!("{}h{}m", hours, minutes)
    } else if minutes > 0 {
        format!("{}m", minutes)
    } else {
        format!("{}s", total_seconds)
    }
}
