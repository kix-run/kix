//! Arguments of the commands that read a live cluster: `status`, `logs`,
//! `pf`, and `snapshot`.

use clap::Subcommand;

/// Arguments of `kix status`.
#[derive(clap::Args)]
pub struct StatusArgs {
    /// Kix cluster to check. Without it, every Kix cluster that has a deploy
    /// on this Kubernetes cluster.
    pub cluster: Option<String>,

    /// Run only this check. Repeat it to run more than one. Without it, all
    /// three run.
    #[arg(long = "check", value_name = "CHECK")]
    pub checks: Vec<StatusCheck>,

    /// Show only this package, by instance name or `namespace/instance`
    #[arg(long, value_name = "NAME")]
    pub package: Option<String>,
}

/// One check of `kix status`.
#[derive(
    Debug,
    Clone,
    Copy,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    clap::ValueEnum,
    serde::Serialize,
    schemars::JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum StatusCheck {
    /// Is every object of the current deploy on the cluster?
    Presence,
    /// Does each object still hold what Kix applied?
    Drift,
    /// Is each object ready, by the rules a deploy waits on?
    Readiness,
}

#[derive(clap::Args)]
pub struct LogsArgs {
    /// Cluster name
    pub cluster: String,

    /// Package instance name (e.g. `vaultwarden`) or `<namespace>/<name>`
    /// for disambiguation when the instance name isn't unique.
    pub package: String,

    /// Stream logs (`kubectl logs -f`)
    #[arg(short, long)]
    pub follow: bool,

    /// Number of lines to show from the tail (`kubectl logs --tail`)
    #[arg(long)]
    pub tail: Option<u64>,

    /// Container name when the workload has multiple containers
    #[arg(short = 'c', long)]
    pub container: Option<String>,

    /// Only show logs newer than a relative duration (`5m`, `2h`, `1h30m`)
    #[arg(long)]
    pub since: Option<String>,

    /// Show logs from the previous terminated container (`kubectl logs --previous`)
    #[arg(short = 'p', long)]
    pub previous: bool,
}

#[derive(clap::Args)]
pub struct PortForwardArgs {
    /// Cluster name
    pub cluster: String,

    /// Package instance name (e.g. `vaultwarden`) or `<namespace>/<name>`
    pub package: String,

    /// One or more port specs passed to `kubectl port-forward`.
    /// Use `8080:80` to bind a specific local port, `5432` to use the same
    /// port on both sides, or `:80` to let kubectl choose a free local port.
    #[arg(required = true)]
    pub ports: Vec<String>,

    /// Address(es) to listen on locally (`kubectl port-forward --address`)
    #[arg(long)]
    pub address: Option<String>,
}

#[derive(clap::Args)]
pub struct SnapshotArgs {
    #[command(subcommand)]
    pub command: SnapshotCommand,
}

#[derive(Subcommand)]
pub enum SnapshotCommand {
    /// Save a snapshot of one Kix cluster's live objects
    Save(SnapshotSaveArgs),
}

/// Save live objects belonging to a single Kix cluster, identified via its
/// Activation records without evaluating a flake.
#[derive(clap::Args)]
pub struct SnapshotSaveArgs {
    /// Kix cluster whose objects to save
    pub cluster: String,

    /// Directory to save the snapshot to
    pub dir: String,
}
