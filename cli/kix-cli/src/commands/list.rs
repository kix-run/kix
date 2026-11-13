use std::collections::BTreeMap;

use miette::{IntoDiagnostic, Result};

use crate::cli::{ListArgs, ListCommand};
use crate::output::{self, CommandResponse};

use super::CommandContext;

/// The clusters this project defines. JSON and YAML print the bare list of
/// names.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(transparent)]
pub(crate) struct ClustersResponse {
    clusters: Vec<String>,
}

impl CommandResponse for ClustersResponse {
    fn text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        table.set_header(["NAME"]);
        for c in &self.clusters {
            table.add_row([c]);
        }
        table.to_string()
    }
}

/// One package of `kix list packages`.
#[derive(serde::Serialize, schemars::JsonSchema)]
pub(crate) struct PackageRow {
    name: String,
    /// The package's version, or `-`.
    version: String,
    /// The package's owner, or `-`.
    owner: String,
    /// With a cluster: `installed [<namespace>]`, `installed (auto)
    /// [<namespace>]`, `import [<namespace>]`, or `available`. Absent
    /// without a cluster.
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<String>,
    /// With a cluster: whether the instance is an import. Absent without a
    /// cluster.
    #[serde(rename = "isImport", skip_serializing_if = "Option::is_none")]
    is_import: Option<bool>,
}

/// The packages of the project or of one cluster. JSON and YAML print the
/// bare list.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(transparent)]
pub(crate) struct PackagesResponse {
    packages: Vec<PackageRow>,
}

impl CommandResponse for PackagesResponse {
    fn text(&self) -> String {
        let show_status = self.packages.iter().any(|p| p.status.is_some());
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        let has_owners = self.packages.iter().any(|p| p.owner != "-");
        if show_status {
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
}

pub fn run(args: &ListArgs, ctx: &mut CommandContext) -> Result<()> {
    match &args.command {
        ListCommand::Clusters => run_clusters(ctx),
        ListCommand::Packages(pkg_args) => run_packages(pkg_args.cluster.as_deref(), ctx),
        ListCommand::Resources(args) => super::inspect::run(args, ctx),
        ListCommand::Images(args) => super::images::run(args, ctx),
    }
}

fn run_clusters(ctx: &mut CommandContext) -> Result<()> {
    let clusters = ctx.evaluator()?.list_clusters().into_diagnostic()?;

    if clusters.is_empty() {
        eprintln!("No clusters found in this flake.");
        return Ok(());
    }

    let response = ClustersResponse { clusters };
    output::result(&response)
}

fn run_packages(cluster: Option<&str>, ctx: &mut CommandContext) -> Result<()> {
    let mut rows: BTreeMap<String, PackageRow> = BTreeMap::new();

    if let Some(cluster_name) = cluster {
        let cluster_info = ctx
            .evaluator()?
            .list_cluster_packages(cluster_name)
            .into_diagnostic()?;

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
                        is_import: Some(inst_info.is_import),
                    });
            }
        }

        for (name, avail_info) in &cluster_info.available_packages {
            rows.entry(name.clone()).or_insert_with(|| PackageRow {
                name: name.clone(),
                version: avail_info.version.as_deref().unwrap_or("-").to_string(),
                owner: avail_info.owner.as_deref().unwrap_or("-").to_string(),
                status: Some("available".to_string()),
                is_import: Some(false),
            });
        }
    } else {
        let global_packages = ctx.evaluator()?.list_packages().into_diagnostic()?;

        for (name, info) in &global_packages {
            rows.insert(
                name.clone(),
                PackageRow {
                    name: name.clone(),
                    version: info.version.as_deref().unwrap_or("-").to_string(),
                    owner: info.owner.as_deref().unwrap_or("-").to_string(),
                    status: None,
                    is_import: None,
                },
            );
        }
    }

    if rows.is_empty() {
        eprintln!("No packages found.");
        return Ok(());
    }

    let packages: Vec<PackageRow> = rows.into_values().collect();

    let response = PackagesResponse { packages };
    output::result(&response)
}
