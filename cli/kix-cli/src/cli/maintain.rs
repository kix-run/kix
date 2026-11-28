//! Arguments of `kix gc` and `kix migrate`.

use clap::{Parser, Subcommand, ValueEnum};

#[derive(Parser, Debug)]
pub struct GcArgs {
    /// Cluster name
    pub cluster: String,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Print what gc would delete, and delete nothing
    #[arg(long)]
    pub dry_run: bool,

    /// Scan every Kix-managed object on the cluster and delete the ones this
    /// cluster's build does not contain. Without it, gc compares the previous
    /// deploy's build with the new build on this machine.
    #[arg(long)]
    pub full_scan: bool,

    /// Delegate garbage collection to the operator (deletes the Activation records the retention policy retires)
    #[arg(long)]
    pub operator: bool,

    /// How long to wait for each deleted object to be gone while no
    /// finalizer is removed, up to 5m per object (e.g. "5m", "300s", or bare
    /// seconds; default 3m)
    #[arg(long, value_parser = super::deploy::validate_timeout, conflicts_with = "operator")]
    pub timeout: Option<String>,

    /// Also judge objects that `--full-scan` only reports, as a
    /// comma-separated list. `unattributed`: Kix objects that name no deployment record on the
    /// cluster, so Kix cannot tell which Kix cluster owns them. `copies`: objects Kix never wrote that
    /// carry Kix's labels, which another program, usually an operator, copied
    /// from an object Kix made.
    #[arg(
        long,
        value_enum,
        value_delimiter = ',',
        value_name = "KINDS",
        requires = "full_scan"
    )]
    pub include: Vec<Include>,

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

/// Objects that `kix gc --full-scan` judges only when `--include` names them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Include {
    /// Removed. Kix refuses it before `kix gc` runs
    /// ([`crate::removed::GC_INCLUDE_UNSTAMPED`]).
    #[value(hide = true)]
    Unstamped,
    Unattributed,
    Copies,
}

impl GcArgs {
    /// Return whether `--include` names `kind`.
    pub fn includes(&self, kind: Include) -> bool {
        self.include.contains(&kind)
    }
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
