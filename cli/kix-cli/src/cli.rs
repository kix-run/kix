use clap::{Parser, Subcommand, ValueEnum};
use clap_complete::Shell;

#[derive(Parser)]
#[command(name = "kix", version, about = "Kubernetes manifest generator")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,

    #[command(flatten)]
    pub global: GlobalArgs,
}

#[derive(clap::Args, Debug, Clone)]
pub struct GlobalArgs {
    /// Output format (yaml, json, table). Default varies by command.
    #[arg(short, long, global = true)]
    pub output: Option<OutputFormat>,

    /// Increase verbosity (-v, -vv, etc.)
    #[arg(short, long, global = true, action = clap::ArgAction::Count)]
    pub verbose: u8,

    /// Suppress non-essential output
    #[arg(short, long, global = true)]
    pub quiet: bool,

    /// Disable colored output (also respects NO_COLOR env per no-color.org spec)
    #[arg(long, global = true)]
    pub no_color: bool,

    /// Kubeconfig context to use
    #[arg(long, global = true)]
    pub context: Option<String>,

    /// Flake reference to evaluate clusters from (default: current directory)
    #[arg(long, global = true, default_value = ".")]
    pub flake: String,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum OutputFormat {
    Text,
    Json,
    Yaml,
}

#[derive(Subcommand)]
pub enum Command {
    /// Render manifests to stdout
    Build(BuildArgs),

    /// Colored diff against live cluster
    Diff(DiffArgs),

    /// Validate: eval + schema + policy
    Check(CheckArgs),

    /// Wave-based deployment with confirmation
    #[command(alias = "apply")]
    Deploy(DeployArgs),

    /// Resource health table
    Status(StatusArgs),

    /// Available clusters in this flake
    List(ListArgs),

    /// Dependency DAG visualization
    Graph(GraphArgs),

    /// Deep-dive: DI deps, parts, out
    Inspect(InspectArgs),

    /// Manage cluster snapshots for CI/offline use
    Snapshot(SnapshotArgs),

    /// Generate shell completions
    Completions(CompletionsArgs),
}

#[derive(clap::Args)]
pub struct BuildArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct DiffArgs {
    /// Cluster name
    pub cluster: String,

    /// Diff against a snapshot directory instead of the live cluster
    #[arg(long)]
    pub snapshot: Option<String>,
}

#[derive(clap::Args)]
pub struct CheckArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct DeployArgs {
    /// Cluster name
    pub cluster: String,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Preview mode: show what would be applied without making changes
    #[arg(long)]
    pub dry_run: bool,

    /// Behavior on error: stop or continue
    #[arg(long, default_value = "stop")]
    pub on_error: OnError,

    /// Timeout for waiting on resource readiness (e.g. "5m", "300s")
    #[arg(long)]
    pub timeout: Option<String>,

    /// Delete resources on cluster that are not in the manifests
    #[arg(long)]
    pub prune: bool,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum OnError {
    Stop,
    Continue,
}

#[derive(clap::Args)]
pub struct StatusArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct ListArgs {}

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

    /// Output format for the graph (tree, dot, json)
    #[arg(long)]
    pub format: Option<GraphFormat>,
}

#[derive(clap::Args)]
pub struct InspectArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct SnapshotArgs {
    #[command(subcommand)]
    pub command: SnapshotCommand,
}

#[derive(Subcommand)]
pub enum SnapshotCommand {
    /// Save a snapshot of the live cluster state
    Save(SnapshotSaveArgs),

    /// Diff a snapshot against the current rendered manifests
    Diff(SnapshotDiffArgs),
}

#[derive(clap::Args)]
pub struct SnapshotSaveArgs {
    /// Directory to save the snapshot
    pub dir: String,
}

#[derive(clap::Args)]
pub struct SnapshotDiffArgs {
    /// Cluster name to diff against
    pub cluster: String,

    /// Directory containing the snapshot
    pub dir: String,
}

#[derive(clap::Args)]
pub struct CompletionsArgs {
    /// Shell to generate completions for
    pub shell: Shell,
}
