use std::collections::BTreeMap;

use miette::{IntoDiagnostic, Result};

use crate::cli::{ListArgs, ListCommand};
use crate::output::{self, CommandResponse};

use super::CommandContext;

// --- Clusters ---

struct ClustersResponse {
    clusters: Vec<String>,
}

impl CommandResponse for ClustersResponse {
    fn format_text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["NAME"]);
        for c in &self.clusters {
            table.add_row([c]);
        }
        table.to_string()
    }

    fn as_json(&self) -> serde_json::Value {
        serde_json::json!(self.clusters)
    }
}

// --- Packages ---

struct PackageRow {
    name: String,
    version: String,
    owner: String,
    status: Option<String>,
    is_import: bool,
}

struct PackagesResponse {
    packages: Vec<PackageRow>,
    show_status: bool,
}

impl CommandResponse for PackagesResponse {
    fn format_text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        let has_owners = self.packages.iter().any(|p| p.owner != "-");
        if self.show_status {
            if has_owners {
                table.set_header(["NAME", "VERSION", "OWNER", "STATUS"]);
                for p in &self.packages {
                    table.add_row([
                        &p.name,
                        &p.version,
                        &p.owner,
                        p.status.as_deref().unwrap_or("-"),
                    ]);
                }
            } else {
                table.set_header(["NAME", "VERSION", "STATUS"]);
                for p in &self.packages {
                    table.add_row([&p.name, &p.version, p.status.as_deref().unwrap_or("-")]);
                }
            }
        } else if has_owners {
            table.set_header(["NAME", "VERSION", "OWNER"]);
            for p in &self.packages {
                table.add_row([&p.name, &p.version, &p.owner]);
            }
        } else {
            table.set_header(["NAME", "VERSION"]);
            for p in &self.packages {
                table.add_row([&p.name, &p.version]);
            }
        }
        table.to_string()
    }

    fn as_json(&self) -> serde_json::Value {
        let entries: Vec<serde_json::Value> = self
            .packages
            .iter()
            .map(|p| {
                let mut m = serde_json::Map::new();
                m.insert("name".into(), serde_json::json!(p.name));
                m.insert("version".into(), serde_json::json!(p.version));
                m.insert("owner".into(), serde_json::json!(p.owner));
                if self.show_status {
                    m.insert("status".into(), serde_json::json!(p.status));
                    m.insert("isImport".into(), serde_json::json!(p.is_import));
                }
                serde_json::Value::Object(m)
            })
            .collect();
        serde_json::json!(entries)
    }
}

pub fn run(args: &ListArgs, ctx: &mut CommandContext) -> Result<()> {
    match &args.command {
        ListCommand::Clusters => run_clusters(ctx),
        ListCommand::Packages(pkg_args) => run_packages(pkg_args.cluster.as_deref(), ctx),
    }
}

fn run_clusters(ctx: &mut CommandContext) -> Result<()> {
    let clusters = ctx.evaluator.list_clusters().into_diagnostic()?;

    if clusters.is_empty() {
        eprintln!("No clusters found in this flake.");
        return Ok(());
    }

    let response = ClustersResponse { clusters };
    output::result(&response)
}

fn run_packages(cluster: Option<&str>, ctx: &mut CommandContext) -> Result<()> {
    let mut rows: BTreeMap<String, PackageRow> = BTreeMap::new();
    let show_status = cluster.is_some();

    if let Some(cluster_name) = cluster {
        // Cluster-scoped: only query cluster info (has versions for everything)
        let cluster_info = ctx
            .evaluator
            .list_cluster_packages(cluster_name)
            .into_diagnostic()?;

        // Add instances
        for (ns, ns_instances) in &cluster_info.instances {
            for (inst_name, inst_info) in ns_instances {
                let status = if inst_info.is_import {
                    format!("import [{ns}]")
                } else if inst_info.auto {
                    format!("installed (auto) [{ns}]")
                } else {
                    format!("installed [{ns}]")
                };

                rows.entry(inst_name.clone())
                    .and_modify(|r| r.status = Some(status.clone()))
                    .or_insert_with(|| PackageRow {
                        name: inst_name.clone(),
                        version: inst_info.version.as_deref().unwrap_or("-").to_string(),
                        owner: inst_info.owner.as_deref().unwrap_or("-").to_string(),
                        status: Some(status),
                        is_import: inst_info.is_import,
                    });
            }
        }

        // Add available packages (not already installed)
        for (name, avail_info) in &cluster_info.available_packages {
            rows.entry(name.clone()).or_insert_with(|| PackageRow {
                name: name.clone(),
                version: avail_info.version.as_deref().unwrap_or("-").to_string(),
                owner: avail_info.owner.as_deref().unwrap_or("-").to_string(),
                status: Some("available".to_string()),
                is_import: false,
            });
        }
    } else {
        // Global: list all packages from the flake
        let global_packages = ctx.evaluator.list_packages().into_diagnostic()?;

        for (name, info) in &global_packages {
            rows.insert(
                name.clone(),
                PackageRow {
                    name: name.clone(),
                    version: info.version.as_deref().unwrap_or("-").to_string(),
                    owner: info.owner.as_deref().unwrap_or("-").to_string(),
                    status: None,
                    is_import: false,
                },
            );
        }
    }

    if rows.is_empty() {
        eprintln!("No packages found.");
        return Ok(());
    }

    let packages: Vec<PackageRow> = rows.into_values().collect();

    let response = PackagesResponse {
        packages,
        show_status,
    };
    output::result(&response)
}
