//! Arguments of `kix gc` and `kix migrate`.

use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
pub struct GcArgs {
    /// Cluster name
    pub cluster: String,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Full cluster scan (default: diff old vs new activation store graphs)
    #[arg(long)]
    pub hard: bool,

    /// Delegate garbage collection to the operator (deletes the Activation records the retention policy retires)
    #[arg(long)]
    pub operator: bool,

    /// Also delete resources that carry the Kix label but no `kix.run/identity-hash`.
    /// Kix never applied those, so by default `--hard` only reports them.
    #[arg(long)]
    pub include_unstamped: bool,

    /// With `--hard`, also evaluate Kix resources that reference no Activation
    /// record on the cluster. When multiple Kix clusters share a Kubernetes
    /// cluster, Kix cannot tell which cluster owns unattributed resources, so
    /// by default `--hard` only reports them.
    #[arg(long, requires = "hard")]
    pub include_unattributed: bool,

    /// With `--hard`, also check copies against the build. A copy carries
    /// Kix's labels and annotations, but Kix never wrote it: another program,
    /// usually an operator, copied them from an object Kix made. By default
    /// `--hard` only lists copies.
    #[arg(long, requires = "hard")]
    pub include_copies: bool,

    /// Minimum number of newest completed (`Superseded`) Activation records to
    /// retain as rollback targets, regardless of age (`0` retains none)
    #[arg(long, value_name = "N", default_value_t = kix::cluster::activation::DEFAULT_KEEP_MIN)]
    pub keep: usize,

    /// Maximum number of `Superseded` Activation records to retain, bounding
    /// the size of the `kix.run/activations` annotation on managed resources
    #[arg(long, value_name = "N", default_value_t = kix::cluster::activation::DEFAULT_KEEP_MAX)]
    pub keep_max: usize,

    /// Beyond `--keep`, retire records older than this duration (`30d`, `12h`,
    /// `45m`, or a bare number of days; `0` or `off` disables age-based
    /// retirement)
    #[arg(long, value_name = "DURATION", default_value = "30d")]
    pub keep_for: String,
}

#[derive(Subcommand, Debug)]
pub enum MigrateCommand {
    /// Migrate this cluster's Kix records from a retired API group to `kix.run`.
    ///
    /// Copies every Activation record to the current API group with its status
    /// history intact, verifies each copy by name and phase, removes the
    /// operator finalizer from the old records, and deletes the old CRDs.
    /// PackageInstance records are not copied because the next deploy
    /// recreates them from the build.
    ///
    /// If the Kix operator runs on this cluster, scale it to 0 before running
    /// this command. An older operator watching the retired API group will
    /// re-add its finalizer and delete active resources when the old CRDs are
    /// removed. Before copying or deleting anything, this command clears the
    /// old finalizers, waits briefly, and aborts if an operator re-adds them.
    ///
    /// Safe to rerun if interrupted: existing copies are skipped and missing
    /// status subresources are repaired. After migration completes, upgrade
    /// the operator image, scale it back up, and deploy.
    Domain(MigrateArgs),
}

#[derive(Parser, Debug)]
pub struct MigrateArgs {
    /// Cluster name
    pub cluster: String,

    /// Print the plan and stop
    #[arg(long)]
    pub dry_run: bool,

    /// Skip the confirmation prompt
    #[arg(short, long)]
    pub yes: bool,
}
