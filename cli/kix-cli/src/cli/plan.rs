//! Arguments of `kix diff` and `kix plan`, and the planning flags `kix deploy`
//! shares.

use clap::ValueEnum;

#[derive(clap::Args)]
pub struct DiffArgs {
    /// Cluster name
    pub cluster: String,

    /// The build to compare against: a previous build (its
    /// `kix.run/built-via` store path, or a result directory containing
    /// `kix-packages.json`) or a manifest directory from `kix snapshot` or
    /// `kix export`
    #[arg(long, value_name = "PATH")]
    pub from: Option<String>,

    /// Read the target build from a `.kixbundle` file instead of evaluating.
    /// Without `--from` or `--from-bundle`, compares against an empty
    /// baseline.
    #[arg(long, value_name = "FILE")]
    pub bundle: Option<std::path::PathBuf>,

    /// Compare against the build in this `.kixbundle` file
    #[arg(
        long,
        value_name = "FILE",
        requires = "bundle",
        conflicts_with = "from"
    )]
    pub from_bundle: Option<std::path::PathBuf>,

    /// Detail level for `--output json` and `--output yaml` (text and Markdown
    /// output are unaffected)
    #[arg(long, value_enum, default_value_t = Detail::Plain)]
    pub detail: Detail,

    /// Write the comparison to a `.kixplan` file (same format as
    /// `kix plan --out`), regardless of `--detail` and `--output`
    #[arg(long, value_name = "FILE")]
    pub out: Option<std::path::PathBuf>,
}

/// Detail level for changed resources in JSON and YAML output of `kix diff`
/// and `kix plan --read-only`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Detail {
    /// Resource names and changed field counts only.
    Plain,
    /// Include each changed field with its old and new values.
    Fields,
    /// Include the full old and new manifests for each changed, added, or
    /// removed resource.
    Manifests,
}

#[derive(clap::Args)]
pub struct PlanCommandArgs {
    #[command(flatten)]
    pub plan: PlanArgs,

    /// Compare the build with the live cluster using only `get` and `list`
    /// permissions, with no server-side dry run.
    ///
    /// When the deployed build is available locally, field changes are
    /// classified as either committed changes or live drift. A read-only plan
    /// cannot see what only a write shows: admission webhook mutations or
    /// rejections, field ownership conflicts, and deploy-time refusals. It
    /// lists these as not checked.
    #[arg(
        long,
        conflicts_with_all = [
            "offline",
            "reconcile",
            "prune",
            "skip_orphan_check",
            "force_conflicts",
            "accept_migrations",
            "deployed_bundles",
        ]
    )]
    pub read_only: bool,

    /// Detail level for `--output json` and `--output yaml` of a read-only
    /// plan (text and Markdown output are unaffected)
    #[arg(long, value_enum, default_value_t = Detail::Plain, requires = "read_only")]
    pub detail: Detail,

    /// Write the plan to a `.kixplan` file for `kix deploy --plan` or Kix
    /// Enterprise. Includes changed fields, the build's dependency graph, and
    /// full old and new manifests with Secret values redacted.
    #[arg(long, value_name = "FILE")]
    pub out: Option<std::path::PathBuf>,
}

/// Shared planning arguments for `kix plan` and `kix deploy`.
#[derive(clap::Args, Clone, Debug)]
pub struct PlanArgs {
    /// Cluster name
    pub cluster: String,

    /// Compare with the build of the last deploy from this machine instead
    /// of querying the cluster.
    ///
    /// Does not contact the cluster. Does not inspect live cluster state,
    /// in-flight or failed deployments, or previously retained orphans, and
    /// performs no server-side dry run.
    #[arg(long)]
    pub offline: bool,

    /// Re-apply all resources even if activation identity matches (heal drift)
    #[arg(long)]
    pub reconcile: bool,

    /// Delete orphaned resources left from the previous activation or earlier
    /// deploys (`kix plan` dry-runs each deletion). Without this flag, orphans
    /// are kept and recorded on the new Activation for a later `--prune` or
    /// `kix gc`.
    #[arg(long)]
    pub prune: bool,

    /// Do not look for orphaned resources at all, and leave them to `kix gc`
    #[arg(long, conflicts_with = "prune")]
    pub skip_orphan_check: bool,

    /// Take ownership of fields currently owned by other field managers (SSA conflict override).
    /// Without this, conflicts surface as a 409 with the conflicting field paths and current owner.
    /// Useful when migrating resources from kubectl/helm to Kix for the first time.
    #[arg(long)]
    pub force_conflicts: bool,

    /// Acknowledge detected stateful migration pairs. Without this flag, a
    /// deploy that would remove and add stateful resources in the same
    /// logical slot is rejected (even with --yes) to prevent silent data
    /// loss, and `kix plan` exits 3. Kix does not copy data between them.
    #[arg(long)]
    pub accept_migrations: bool,

    /// Read the target build from a `.kixbundle` file instead of evaluating,
    /// verifying every store path against its content first
    #[arg(long, value_name = "FILE", conflicts_with = "offline")]
    pub bundle: Option<std::path::PathBuf>,

    /// Bundle file for a previously deployed build (active, failed, or retained
    /// orphan source) to use when its store path is not present locally.
    /// Matched by the Activation record's identity hash; repeatable.
    #[arg(long = "deployed-bundle", value_name = "FILE", requires = "bundle")]
    pub deployed_bundles: Vec<std::path::PathBuf>,
}
