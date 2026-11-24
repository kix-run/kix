//! `kix list`: the clusters and packages a project defines, and the
//! resources ([`resources`]) and container images ([`images`]) of one
//! cluster.

pub mod images;
pub mod resources;

use std::collections::{BTreeMap, BTreeSet};

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
    /// The Kix each cluster uses, in a project whose kix.toml has a
    /// [versions] table. The text form shows it.
    #[serde(skip)]
    #[schemars(skip)]
    versions: Option<Vec<ClusterKix>>,
}

/// The version of Kix one cluster uses.
struct ClusterKix {
    /// The release, or what the input follows when it pins none.
    kix: String,
    /// The input of flake.nix that [versions] lists the cluster under.
    input: String,
}

impl CommandResponse for ClustersResponse {
    fn text(&self) -> String {
        let mut table = comfy_table::Table::new();
        table.load_preset(comfy_table::presets::NOTHING);
        match &self.versions {
            None => {
                table.set_header(["NAME"]);
                for c in &self.clusters {
                    table.add_row([c]);
                }
            }
            Some(versions) => {
                table.set_header(["NAME", "KIX", "INPUT"]);
                for (c, v) in self.clusters.iter().zip(versions) {
                    table.add_row([c, &v.kix, &v.input]);
                }
            }
        }
        table.to_string()
    }
}

/// Return the Kix each of `clusters` uses, when the project in `dir` has a
/// `[versions]` table. A cluster the table leaves out shows as not listed,
/// since every command on it fails until it is.
fn cluster_versions(dir: &std::path::Path, clusters: &[String]) -> Option<Vec<ClusterKix>> {
    use kix::flake_lock::{self, ProjectKix};
    let versions = kix::versions::Versions::read(dir).ok()??;
    let lock = flake_lock::read(dir).ok()?;
    let kix_of = |input: &str| match flake_lock::input(&lock, input).map(flake_lock::from_original)
    {
        Ok(Ok(ProjectKix::Release(v))) => v.release(),
        Ok(Ok(ProjectKix::Development(_))) => "development".to_string(),
        _ => "unknown".to_string(),
    };
    Some(
        clusters
            .iter()
            .map(|cluster| match versions.input_of(cluster) {
                Some(input) => ClusterKix {
                    kix: kix_of(input),
                    input: input.to_string(),
                },
                None => ClusterKix {
                    kix: "-".to_string(),
                    input: "not listed in [versions]".to_string(),
                },
            })
            .collect(),
    )
}

/// One package of `kix list packages`.
#[derive(serde::Serialize, schemars::JsonSchema)]
pub(crate) struct PackageRow {
    name: String,
    /// The package's version, or `-`.
    version: String,
    /// The package's owner, or `-`.
    owner: String,
    /// The id of one of Kix's own packages (`harbor`,
    /// `experimental/coredns`), the id change records use. `null` for a
    /// project's own package, an inline package, or an import.
    package: Option<String>,
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
        ListCommand::Resources(args) => resources::run(args, ctx),
        ListCommand::Images(args) => images::run(args, ctx),
    }
}

fn run_clusters(ctx: &mut CommandContext) -> Result<()> {
    let clusters = ctx.evaluator()?.list_clusters().into_diagnostic()?;

    if clusters.is_empty() {
        eprintln!("No clusters found in this flake.");
        return Ok(());
    }

    let versions =
        super::project_dir(&ctx.global.flake).and_then(|dir| cluster_versions(&dir, &clusters));
    let response = ClustersResponse { clusters, versions };
    output::result(&response)
}

fn run_packages(cluster: Option<&str>, ctx: &mut CommandContext) -> Result<()> {
    // Rows sort by name, then by namespace. A row that is not an instance
    // has an empty namespace.
    let mut rows: BTreeMap<(String, String), PackageRow> = BTreeMap::new();

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

                rows.insert(
                    (inst_name.clone(), ns.clone()),
                    PackageRow {
                        name: inst_name.clone(),
                        version: inst_info.version.as_deref().unwrap_or("-").to_string(),
                        owner: inst_info.owner.as_deref().unwrap_or("-").to_string(),
                        package: inst_info.package.clone(),
                        status: Some(status),
                        is_import: Some(inst_info.is_import),
                    },
                );
            }
        }

        // An available package that an instance is named after is listed as
        // that instance.
        let installed: BTreeSet<String> = rows.keys().map(|(name, _)| name.clone()).collect();
        for (name, avail_info) in &cluster_info.available_packages {
            if installed.contains(name) {
                continue;
            }
            rows.insert(
                (name.clone(), String::new()),
                PackageRow {
                    name: name.clone(),
                    version: avail_info.version.as_deref().unwrap_or("-").to_string(),
                    owner: avail_info.owner.as_deref().unwrap_or("-").to_string(),
                    package: avail_info.package.clone(),
                    status: Some("available".to_string()),
                    is_import: Some(false),
                },
            );
        }
    } else {
        let global_packages = ctx.evaluator()?.list_packages().into_diagnostic()?;

        for (name, info) in &global_packages {
            rows.insert(
                (name.clone(), String::new()),
                PackageRow {
                    name: name.clone(),
                    version: info.version.as_deref().unwrap_or("-").to_string(),
                    owner: info.owner.as_deref().unwrap_or("-").to_string(),
                    package: info.package.clone(),
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
