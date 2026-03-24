use std::io::IsTerminal;

use miette::{IntoDiagnostic, Result};

use crate::cli::{OutputFormat, StatusArgs};
use crate::output::{self, CommandResponse};
use kix_manifest::types::CLUSTER_SCOPED;

use super::CommandContext;

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

pub fn run(args: &StatusArgs, ctx: &mut CommandContext) -> Result<()> {
    // Evaluate the cluster to know what resources we expect
    let _cluster = ctx.eval_cluster_or_suggest(&args.cluster)?;

    let global = ctx.global.clone();
    ctx.runtime.block_on(run_async(args, &global))
}

async fn run_async(_args: &StatusArgs, global: &crate::cli::GlobalArgs) -> Result<()> {
    let spinner = if std::io::stderr().is_terminal() && !global.quiet {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message("Fetching cluster status...");
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    };

    // Connect to cluster
    let client = kix_cluster::fetch::make_client(global.context.as_deref())
        .await
        .into_diagnostic()?;

    // Discover and fetch managed resources
    let discovery = kix_cluster::fetch::discover_resources(&client)
        .await
        .into_diagnostic()?;
    let resources = kix_cluster::fetch::fetch_managed_resources(&client, &discovery)
        .await
        .into_diagnostic()?;

    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }

    if resources.is_empty() {
        eprintln!("No kix-managed resources found on the cluster.");
        return Ok(());
    }

    let mut statuses: Vec<ResourceStatus> = resources
        .iter()
        .map(|obj| {
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

            let is_ready = kix_cluster::readiness::check_readiness(obj, &kind);
            let ready_str = if is_ready { "True" } else { "False" }.to_string();

            let status_str = compute_status(obj, &kind);
            let age_str = compute_age(obj);

            ResourceStatus {
                name,
                namespace,
                kind,
                ready: ready_str,
                status: status_str,
                age: age_str,
            }
        })
        .collect();

    // Sort by namespace, then kind, then name
    statuses.sort_by(|a, b| {
        a.namespace
            .cmp(&b.namespace)
            .then_with(|| a.kind.cmp(&b.kind))
            .then_with(|| a.name.cmp(&b.name))
    });

    let response = StatusResponse { statuses };
    let format = global.output.unwrap_or(OutputFormat::Text);
    println!("{}", output::render(&response, format)?);

    Ok(())
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
            // Check conditions for a status summary
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

/// Compute age from creationTimestamp.
fn compute_age(obj: &kube::api::DynamicObject) -> String {
    let timestamp = obj.metadata.creation_timestamp.as_ref().map(|t| t.0);

    match timestamp {
        Some(created) => {
            let now = chrono::Utc::now();
            let duration = now.signed_duration_since(created);
            format_duration(duration)
        }
        None => "-".into(),
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
