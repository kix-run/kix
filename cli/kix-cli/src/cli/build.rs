//! Arguments of the commands that build or evaluate a cluster without changing
//! it: `build`, `check`, `graph`, `bundle`, `inspect`, `images`, `export`, and
//! `list`.

use clap::{Subcommand, ValueEnum};

#[derive(clap::Args)]
pub struct BuildArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct CheckArgs {
    /// Cluster to validate
    pub cluster: String,

    /// Output SARIF 2.1.0 JSON (for GitHub Code Scanning integration)
    #[arg(long)]
    pub sarif: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum GraphFormat {
    Tree,
    Dot,
    Json,
}

#[derive(clap::Args)]
pub struct GraphArgs {
    /// Cluster name
    pub cluster: String,

    /// Graph output format (tree, dot, json)
    #[arg(long)]
    pub format: Option<GraphFormat>,

    /// Read the target build from a `.kixbundle` file instead of evaluating
    #[arg(long, value_name = "FILE")]
    pub bundle: Option<std::path::PathBuf>,
}

#[derive(clap::Args)]
pub struct BundleArgs {
    /// Cluster name
    pub cluster: String,

    /// Output path for the bundle [default: <CLUSTER>.kixbundle]
    // Preserve literal `<CLUSTER>` placeholder for clap `--help` output.
    #[allow(rustdoc::invalid_html_tags)]
    #[arg(value_name = "FILE")]
    pub file: Option<std::path::PathBuf>,
}

#[derive(clap::Args)]
pub struct InspectArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct ImagesArgs {
    /// Cluster name
    pub cluster: String,

    /// Show which resources reference each image
    #[arg(long)]
    pub sources: bool,
}

#[derive(clap::Args)]
pub struct ExportArgs {
    /// Cluster name
    pub cluster: String,

    /// Output directory (nested: `<out>/<namespace>/<Kind>-<name>.yaml`)
    #[arg(long, default_value = "./kix-export")]
    pub out: String,

    /// Export mode: `exit` strips `kix.run/*` annotations and omits Kix-internal
    /// CRs (`Activation`, `PackageInstance`) for a clean handoff; `audit`
    /// preserves all metadata for compliance evidence.
    #[arg(long = "for", value_name = "MODE", default_value = "exit")]
    pub for_mode: ExportMode,

    /// Overwrite an existing output directory
    #[arg(long)]
    pub force: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ExportMode {
    /// Plain Kubernetes YAML without Kix metadata, suitable for `kubectl apply`, Flux, or Argo
    Exit,
    /// Preserve `kix.run/*` provenance annotations for audit evidence
    Audit,
}

#[derive(clap::Args)]
pub struct ListArgs {
    #[command(subcommand)]
    pub command: ListCommand,
}

#[derive(Subcommand)]
pub enum ListCommand {
    /// Available clusters in this flake
    Clusters,

    /// Available packages (optionally scoped to a cluster)
    Packages(ListPackagesArgs),
}

#[derive(clap::Args)]
pub struct ListPackagesArgs {
    /// Show packages for a specific cluster (adds installed status)
    #[arg(long)]
    pub cluster: Option<String>,
}
