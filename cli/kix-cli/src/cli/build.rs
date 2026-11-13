//! Arguments of the commands that build or evaluate a cluster without changing
//! it: `build`, `check`, `graph`, `bundle`, `export`, and `list`.

use clap::Subcommand;

#[derive(clap::Args)]
pub struct BuildArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct CheckArgs {
    /// Cluster to validate
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct GraphArgs {
    /// Cluster name
    pub cluster: String,

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
    #[arg(long, value_name = "FILE")]
    pub out: Option<std::path::PathBuf>,

    /// The output path as a positional argument, which `main` refuses.
    #[arg(hide = true)]
    pub removed_file: Option<std::path::PathBuf>,
}

#[derive(clap::Args)]
pub struct ListResourcesArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct ListImagesArgs {
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

    /// Keep Kix's `kix.run/*` annotations and its own records (`Activation`,
    /// `PackageInstance`), for audit evidence. Without it, the export is plain
    /// Kubernetes YAML for `kubectl apply`, Flux, or Argo CD.
    #[arg(long)]
    pub with_kix_metadata: bool,

    /// Overwrite an existing output directory
    #[arg(long)]
    pub force: bool,
}

#[derive(clap::Args)]
pub struct ListArgs {
    #[command(subcommand)]
    pub command: ListCommand,
}

#[derive(Subcommand)]
pub enum ListCommand {
    /// Available clusters in this project
    Clusters,

    /// Available packages, with what a cluster installs when one is given
    Packages(ListPackagesArgs),

    /// Summarize a cluster's rendered resources by namespace and kind
    Resources(ListResourcesArgs),

    /// List all container images in a cluster's build (for airgap preloading)
    Images(ListImagesArgs),
}

#[derive(clap::Args)]
pub struct ListPackagesArgs {
    /// Show the packages of this cluster, with what it installs
    pub cluster: Option<String>,
}
