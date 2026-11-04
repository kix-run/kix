use std::ffi::OsString;
use std::path::PathBuf;

use clap::builder::FalseyValueParser;
use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use clap_complete::Shell;

#[derive(Parser)]
#[command(
    name = "kix",
    version = kix::VERSION,
    about = "Kubernetes manifest generator",
    after_help = "Plugins: `kix NAME ARGS...` runs `kix-NAME ARGS...` from PATH."
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,

    #[command(flatten)]
    pub global: GlobalArgs,
}

#[derive(clap::Args, Debug, Clone)]
pub struct GlobalArgs {
    /// Output format (text, json, yaml, markdown). Default varies by command.
    #[arg(short, long, global = true, env = "KIX_OUTPUT")]
    pub output: Option<OutputFormat>,

    /// Increase verbosity (-v, -vv, etc.)
    #[arg(short, long, global = true, env = "KIX_VERBOSE", action = clap::ArgAction::Count)]
    pub verbose: u8,

    /// Suppress non-essential output
    #[arg(short, long, global = true, env = "KIX_QUIET", value_parser = FalseyValueParser::new())]
    pub quiet: bool,

    /// Disable colored output (also respects NO_COLOR env per no-color.org spec)
    #[arg(long, global = true)]
    pub no_color: bool,

    /// Kubeconfig context to use
    #[arg(long, global = true, env = "KIX_CONTEXT")]
    pub context: Option<String>,

    /// Flake reference to evaluate clusters from (default: current directory)
    #[arg(long, global = true, env = "KIX_FLAKE", default_value = ".")]
    pub flake: String,

    /// Skip the SQLite eval cache (always re-evaluate from Nix)
    #[arg(long, global = true, env = "KIX_NO_CACHE", value_parser = FalseyValueParser::new())]
    pub no_cache: bool,

    /// Override a flake input's URL (repeatable: `--override-input INPUT URL`).
    ///
    /// Forwards `--override-input` to every `nix` subprocess. When this flag
    /// is not set, Kix reads space-separated `INPUT URL` pairs from
    /// `KIX_OVERRIDE_INPUT`.
    #[arg(
        long = "override-input",
        global = true,
        num_args = 2,
        value_names = ["INPUT", "URL"],
        action = clap::ArgAction::Append,
    )]
    pub override_input: Vec<String>,
}

impl GlobalArgs {
    /// Pair the `--override-input NAME URL` tokens into `(name, url)` tuples.
    ///
    /// Both clap (for the flag) and `override_input_from_env` (for
    /// `KIX_OVERRIDE_INPUT`) guarantee an even number of elements.
    pub fn input_overrides(&self) -> Vec<(String, String)> {
        self.override_input
            .chunks_exact(2)
            .map(|c| (c[0].clone(), c[1].clone()))
            .collect()
    }
}

/// Global flags that apply only to specific subcommands, paired with the
/// command paths that read them. A command path covers its subcommands, and a
/// parent command is included when any of its subcommands reads the flag.
///
/// `-v`, `-q`, and `--no-color` apply to every command and are omitted here.
const SCOPED_GLOBALS: &[(&str, &[&str])] = &[
    (
        "output",
        &[
            "build",
            "diff",
            "plan",
            "deploy",
            "check",
            "status",
            "list",
            "graph",
            "inspect",
            "rollback",
            "drift",
            "images",
            "compliance sbom",
            "compliance attest",
            "pin",
        ],
    ),
    (
        "context",
        &[
            "diff",
            "plan",
            "deploy",
            "status",
            "gc",
            "migrate",
            "rollback",
            "logs",
            "pf",
            "health",
            "drift",
            "snapshot",
            "compliance attest",
        ],
    ),
    (
        "flake",
        &[
            "build",
            "diff",
            "plan",
            "check",
            "deploy",
            "status",
            "list",
            "graph",
            "inspect",
            "gc",
            "migrate",
            "rollback",
            "health",
            "export",
            "logs",
            "pf",
            "images",
            "compliance",
            "pin",
        ],
    ),
    // Only commands that evaluate through the SQLite eval cache.
    (
        "no_cache",
        &[
            "build",
            "check",
            "status",
            "list",
            "graph",
            "inspect",
            "images",
            "compliance audit",
        ],
    ),
    (
        "override_input",
        &[
            "build",
            "diff",
            "plan",
            "check",
            "deploy",
            "status",
            "list",
            "graph",
            "inspect",
            "gc",
            "migrate",
            "rollback",
            "health",
            "export",
            "logs",
            "pf",
            "images",
            "compliance",
        ],
    ),
];

/// Build the clap `Command` for `kix`, hiding scoped global flags from the
/// `--help` output of subcommands that do not use them.
///
/// Hidden flags are still accepted on every subcommand so wrapper scripts can
/// pass `--flake` or `--context` unconditionally, and shell completions still
/// include them.
pub fn command() -> clap::Command {
    let cmd = Cli::command();
    let globals: Vec<clap::Arg> = cmd
        .get_arguments()
        .filter(|a| a.is_global_set())
        .cloned()
        .collect();
    cmd.mut_subcommands(|sc| hide_unread_globals(sc, "", &globals))
}

/// Hide each scoped global flag that `cmd` does not read.
///
/// Clap propagates a global flag to a subcommand only if the subcommand does
/// not already define an argument with the same ID, so adding a hidden copy
/// overrides the visible global definition. This must run before
/// `Command::build` freezes the parser's argument lookup table.
fn hide_unread_globals(cmd: clap::Command, parent: &str, globals: &[clap::Arg]) -> clap::Command {
    let path = if parent.is_empty() {
        cmd.get_name().to_string()
    } else {
        format!("{parent} {}", cmd.get_name())
    };
    let mut cmd = cmd;
    for (id, readers) in SCOPED_GLOBALS {
        let reads = readers.iter().any(|r| {
            *r == path || r.starts_with(&format!("{path} ")) || path.starts_with(&format!("{r} "))
        });
        if !reads {
            let arg = globals
                .iter()
                .find(|a| a.get_id() == *id)
                .unwrap_or_else(|| panic!("no global flag {id}"));
            cmd = cmd.arg(arg.clone().hide(true));
        }
    }
    cmd.mut_subcommands(|sc| hide_unread_globals(sc, &path, globals))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    Text,
    Json,
    Yaml,
    /// GitHub-flavored markdown suitable for PR comments
    Markdown,
}

#[derive(Subcommand)]
pub enum Command {
    /// Render manifests to stdout
    Build(BuildArgs),

    /// Compare the build with the live cluster or a directory, read-only
    ///
    /// Compares the build against the live cluster's Kix-managed resources
    /// (requiring only `get` and `list` permissions), a snapshot from
    /// `kix snapshot save`, or another build (`--from <DIR>`, which requires
    /// no cluster access). When the currently deployed build is available
    /// locally, field changes are classified as either committed changes or
    /// live drift.
    ///
    /// Because `kix diff` is read-only, it cannot detect write-time effects
    /// such as admission webhook mutations or rejections, server-side apply
    /// ownership conflicts, or deploy-time refusals. Use `kix plan` to check
    /// those with a server-side dry run.
    ///
    /// Exits 2 when any differences are found.
    Diff(DiffArgs),

    /// Preview a deploy as a server-side dry run
    ///
    /// Runs the deploy pipeline with every write sent as a server-side dry run
    /// so the API server reports the exact field changes it would make and any
    /// writes it would reject (field ownership conflicts, admission webhooks,
    /// schema validation, or RBAC). Also reports stateful migrations, live
    /// drift that the deploy would revert, and orphaned resources that pruning
    /// would delete or keep. `kix deploy` prints this same plan before
    /// prompting, and `kix deploy --dry-run` runs this command.
    ///
    /// Because dry-run writes require the same RBAC permissions as real
    /// writes, use `kix diff` when you only have read-only access. A dry run
    /// cannot verify whether Pods will start or pass readiness probes.
    ///
    /// Exits 0 when the deploy would make no changes, 2 when changes would be
    /// made, and 3 when the deploy would be blocked by a rejected write or an
    /// unacknowledged stateful migration (see `--accept-migrations`).
    Plan(PlanCommandArgs),

    /// Evaluate a cluster and report build-time checks and scorecard findings
    ///
    /// Runs constructor validators, cross-resource checks, and error-severity
    /// scorecard rules; any failure marks the `eval` row as `fail`. The
    /// `scorecard` row summarizes findings by severity. To validate rendered
    /// manifests against Kubernetes schemas, run `nix flake check` (via the
    /// `schema-cluster-<name>` check). Exits 1 when any row reports `fail`.
    Check(CheckArgs),

    /// Wave-based deployment with confirmation
    #[command(alias = "apply")]
    Deploy(DeployArgs),

    /// Resource health table
    Status(StatusArgs),

    /// List clusters, packages, or other resources
    List(ListArgs),

    /// Dependency DAG visualization
    Graph(GraphArgs),

    /// Package a built cluster into a standalone `.kixbundle` file
    ///
    /// A bundle (`.kixbundle`) is a seekable zstd archive containing every
    /// store file in the build and its references, allowing `kix plan`,
    /// `kix deploy`, and `kix graph` to run with `--bundle` on machines
    /// without Nix. Readers recompute every store path from its content and
    /// references and reject any mismatch.
    Bundle(BundleArgs),

    /// Summarize a cluster's rendered resources by namespace and kind
    Inspect(InspectArgs),

    /// Garbage-collect stale Kix-managed resources
    Gc(GcArgs),

    /// One-off cluster migrations
    #[command(subcommand)]
    Migrate(MigrateCommand),

    /// Rollback to the previous activation
    Rollback(RollbackArgs),

    /// Export cluster manifests as plain Kubernetes YAML (exit-strategy / audit bundle)
    Export(ExportArgs),

    /// Tail logs for a package's primary workload
    Logs(LogsArgs),

    /// Port-forward to a package's primary workload
    #[command(alias = "port-forward")]
    Pf(PortForwardArgs),

    /// Cluster integrity walk: dependency-presence check via identity-hashes
    Health(HealthArgs),

    /// Content drift check via applied-hash stamps (cluster-only, no build)
    Drift(DriftArgs),

    /// Manage cluster snapshots for CI/offline use
    Snapshot(SnapshotArgs),

    /// List all container images in a cluster activation (for airgap preloading)
    Images(ImagesArgs),

    /// Generate shell completions
    Completions(CompletionsArgs),

    /// Compliance exports: SBOM, SLSA attestations, audit bundles
    Compliance(ComplianceArgs),

    /// Resolve image references and record them in a committed pin file
    #[command(subcommand)]
    Pin(PinCommand),

    /// Run an external `kix-<NAME>` plugin from `PATH`
    #[command(external_subcommand)]
    Plugin(Vec<OsString>),
}

impl Command {
    /// Extract the cluster name from commands that take one, for early validation.
    pub fn cluster_name(&self) -> Option<&str> {
        match self {
            Command::Build(a) => Some(&a.cluster),
            Command::Diff(a) => Some(&a.cluster),
            Command::Plan(a) => Some(&a.plan.cluster),
            Command::Check(a) => Some(&a.cluster),
            Command::Deploy(a) => Some(&a.plan.cluster),
            Command::Status(a) => Some(&a.cluster),
            Command::Graph(a) => Some(&a.cluster),
            Command::Bundle(a) => Some(&a.cluster),
            Command::Inspect(a) => Some(&a.cluster),
            Command::Gc(a) => Some(&a.cluster),
            Command::Migrate(MigrateCommand::Domain(a)) => Some(&a.cluster),
            Command::Health(a) => Some(&a.cluster),
            Command::Rollback(a) => Some(&a.cluster),
            Command::Export(a) => Some(&a.cluster),
            Command::Logs(a) => Some(&a.cluster),
            Command::Pf(a) => Some(&a.cluster),
            Command::Images(a) => Some(&a.cluster),
            Command::List(a) => match &a.command {
                ListCommand::Packages(p) => p.cluster.as_deref(),
                ListCommand::Clusters => None,
            },
            Command::Compliance(a) => match &a.command {
                ComplianceCommand::Sbom(s) => Some(&s.cluster),
                ComplianceCommand::Attest(s) => Some(&s.cluster),
                ComplianceCommand::Audit(s) => Some(&s.cluster),
            },
            Command::Snapshot(a) => match &a.command {
                SnapshotCommand::Save(s) => Some(&s.cluster),
            },
            Command::Completions(_) | Command::Drift(_) | Command::Pin(_) | Command::Plugin(_) => {
                None
            }
        }
    }
}

/// Resolve container image tags to digests and record them in a committed pin file.
///
/// `kix pin` queries the container registry for a tag's current digest, fails
/// if the tag does not exist, and writes the resolved digest into the
/// repository's pin file. It operates directly on the pin file without
/// evaluating the Nix flake, so you can update or repair pins even when
/// cluster evaluation is broken.
#[derive(Subcommand)]
pub enum PinCommand {
    /// Resolve a tag and write it into the pin file
    Set(PinSetArgs),

    /// Remove an entry from the pin file
    Rm(PinRmArgs),

    /// Verify that every pin still resolves to its recorded digest
    Check(PinCheckArgs),

    /// List all entries in a pin file
    List(PinListArgs),
}

#[derive(clap::Args)]
pub struct PinSetArgs {
    /// Pin key read by the cluster definition (`pins.get "<key>"`), or
    /// `<namespace>/<instance>` to set an instance's image option directly
    pub key: String,

    /// Config option path to set for an instance pin (e.g., `server.image`).
    /// Defaults to `image`.
    #[arg(long)]
    pub option: Option<String>,

    /// Image tag to resolve and record alongside the digest
    #[arg(long)]
    pub tag: Option<String>,

    /// Image repository, including the registry host. Required when creating a
    /// new pin; defaults to the existing repository when updating.
    #[arg(long)]
    pub repository: Option<String>,

    /// Record this digest directly instead of querying the registry (for
    /// air-gapped environments)
    #[arg(long, conflicts_with = "no_resolve")]
    pub digest: Option<String>,

    /// Record the tag without resolving a digest from the registry
    #[arg(long)]
    pub no_resolve: bool,

    /// Source revision the image was built from, verified by
    /// `kix pin check --source-rev`
    #[arg(long)]
    pub source_rev: Option<String>,

    /// Identity of the promoter (defaults to the CI run or `user@host`)
    #[arg(long)]
    pub promoted_by: Option<String>,

    /// Free-form note stored on the pin entry. Preserved when re-pinning the
    /// same image, cleared when switching to a different image unless a new
    /// note is provided, or cleared explicitly with `""`.
    #[arg(long)]
    pub note: Option<String>,

    /// Create the pin file if missing, or add a new named pin (not required
    /// for `<namespace>/<instance>` pins)
    #[arg(long)]
    pub init: bool,

    /// Overwrite a pin file that was not generated by `kix pin`
    #[arg(long)]
    pub force: bool,

    /// Path to the pin file. If omitted, Kix searches the working directory,
    /// the flake directory, and the repository for a single `*pins.json` file.
    #[arg(long)]
    pub pins_file: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct PinRmArgs {
    /// Pin key read by the cluster definition (`pins.get "<key>"`), or
    /// `<namespace>/<instance>` to remove an instance's image pin
    pub key: String,

    /// Config option path to remove for an instance pin (e.g., `server.image`).
    /// Defaults to `image`.
    #[arg(long)]
    pub option: Option<String>,

    /// Overwrite a pin file that was not generated by `kix pin`
    #[arg(long)]
    pub force: bool,

    /// Path to the pin file. If omitted, Kix searches the working directory,
    /// the flake directory, and the repository for a single `*pins.json` file.
    #[arg(long)]
    pub pins_file: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct PinCheckArgs {
    /// Check only the specified pin key or `<namespace>/<instance>` (repeatable;
    /// defaults to all pins)
    #[arg(long = "key")]
    pub keys: Vec<String>,

    /// Require every pin that records a source revision to match this value
    #[arg(long)]
    pub source_rev: Option<String>,

    /// Warn instead of failing when a pin has no recorded digest
    #[arg(long)]
    pub allow_unresolved: bool,

    /// Validate the pin file's structure without contacting any registry
    #[arg(long)]
    pub offline: bool,

    /// Path to the pin file. If omitted, Kix searches the working directory,
    /// the flake directory, and the repository for a single `*pins.json` file.
    #[arg(long)]
    pub pins_file: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct PinListArgs {
    /// Path to the pin file. If omitted, Kix searches the working directory,
    /// the flake directory, and the repository for a single `*pins.json` file.
    #[arg(long)]
    pub pins_file: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct ComplianceArgs {
    #[command(subcommand)]
    pub command: ComplianceCommand,
}

#[derive(Subcommand)]
pub enum ComplianceCommand {
    /// CycloneDX Software Bill of Materials (SBOM)
    Sbom(ComplianceSbomArgs),

    /// SLSA v1 provenance attestation (in-toto statement)
    Attest(ComplianceAttestArgs),

    /// Full audit bundle: SARIF + SBOM + SLSA provenance + OSCAL assessment + summary
    Audit(ComplianceAuditArgs),
}

#[derive(clap::Args)]
pub struct ComplianceSbomArgs {
    /// Cluster name
    pub cluster: String,
}

#[derive(clap::Args)]
pub struct ComplianceAttestArgs {
    /// Cluster name
    pub cluster: String,

    /// Builder ID (URI). In CI, pass the workflow run URL.
    #[arg(long)]
    pub builder_id: Option<String>,

    /// Invocation ID (e.g. CI run ID)
    #[arg(long)]
    pub invocation_id: Option<String>,

    /// Read the deploy receipt from the cluster's active Activation resource
    /// instead of evaluating locally, attesting what is currently deployed
    #[arg(long)]
    pub from_cluster: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ComplianceFramework {
    Soc2,
    Iso27001,
    Dora,
    Nis2,
}

#[derive(clap::Args)]
pub struct ComplianceAuditArgs {
    /// Cluster name
    pub cluster: String,

    /// Output directory (created if missing)
    #[arg(long, default_value = "./compliance")]
    pub out: String,

    /// Overwrite an existing output directory
    #[arg(long)]
    pub force: bool,

    /// Regulatory framework to map controls to
    #[arg(long, default_value = "soc2")]
    pub framework: ComplianceFramework,

    /// Builder ID for SLSA provenance (passed through to attest)
    #[arg(long)]
    pub builder_id: Option<String>,
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

    /// Compare against a local directory instead of the live cluster: either a
    /// previous build result (containing `kix-packages.json`) or a manifest
    /// directory from `kix snapshot save` or `kix export`
    #[arg(long, value_name = "DIR")]
    pub from: Option<String>,

    /// Read the target build from a `.kixbundle` file instead of evaluating.
    /// Without `--from` or `--from-bundle`, compares against an empty baseline
    /// without contacting the cluster.
    #[arg(long, value_name = "FILE")]
    pub bundle: Option<std::path::PathBuf>,

    /// Compare against the baseline build in this `.kixbundle` file instead of
    /// the live cluster
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
    /// `kix plan --save`), regardless of `--detail` and `--output`
    #[arg(long, value_name = "FILE")]
    pub save: Option<std::path::PathBuf>,
}

/// Detail level for changed resources in `kix diff` JSON and YAML output.
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
pub struct CheckArgs {
    /// Cluster to validate
    pub cluster: String,

    /// Output SARIF 2.1.0 JSON (for GitHub Code Scanning integration)
    #[arg(long)]
    pub sarif: bool,
}

#[derive(clap::Args)]
pub struct PlanCommandArgs {
    #[command(flatten)]
    pub plan: PlanArgs,

    /// Write the plan to a `.kixplan` file for `kix deploy --plan` or Kix
    /// Enterprise. Includes changed fields, the build's dependency graph, and
    /// full old and new manifests with Secret values redacted.
    #[arg(long, value_name = "FILE")]
    pub save: Option<std::path::PathBuf>,
}

/// Shared planning arguments for `kix plan` and `kix deploy`.
#[derive(clap::Args, Clone, Debug)]
pub struct PlanArgs {
    /// Cluster name
    pub cluster: String,

    /// Use the local activation cache instead of querying the cluster.
    ///
    /// Runs completely offline by comparing the new build against the locally
    /// cached activation. Does not inspect live cluster state, in-flight or
    /// failed deployments, or previously retained orphans, and performs no
    /// server-side dry run.
    #[arg(long)]
    pub current_activation: bool,

    /// Re-apply all resources even if activation identity matches (heal drift)
    #[arg(long)]
    pub reconcile: bool,

    /// Delete orphaned resources left from the previous activation or earlier
    /// deploys (`kix plan` dry-runs each deletion). Without this flag, orphans
    /// are kept and recorded on the new Activation for a later `--prune` or
    /// `kix gc`.
    #[arg(long)]
    pub prune: bool,

    /// Prune mode: default (prune after apply), no (skip pruning)
    #[arg(long, value_name = "MODE")]
    pub prune_mode: Option<PruneMode>,

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
    #[arg(long, value_name = "FILE", conflicts_with = "current_activation")]
    pub bundle: Option<std::path::PathBuf>,

    /// Bundle file for a previously deployed build (active, failed, or retained
    /// orphan source) to use when its store path is not present locally.
    /// Matched by the Activation record's identity hash; repeatable.
    #[arg(long = "deployed-bundle", value_name = "FILE", requires = "bundle")]
    pub deployed_bundles: Vec<std::path::PathBuf>,
}

#[derive(clap::Args)]
pub struct DeployArgs {
    #[command(flatten)]
    pub plan: PlanArgs,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Preview only: run `kix plan` with the same flags and make no changes.
    /// When combined with `--plan`, verify that the saved plan still matches
    /// and exit.
    #[arg(long)]
    pub dry_run: bool,

    /// Deploy only if the current plan matches this `.kixplan` file from
    /// `kix plan --save`. Uses the planning flags recorded in the file and
    /// exits 4 without applying anything if the cluster state, builds, flags,
    /// refusals, reverted drift, or prune deletions have changed.
    #[arg(
        long = "plan",
        id = "saved_plan",
        value_name = "FILE",
        conflicts_with_all = ["current_activation", "operator"]
    )]
    pub saved_plan: Option<std::path::PathBuf>,

    /// Behavior on error: `stop` or `continue`. With `stop`, a deploy whose
    /// plan contains a refused write aborts before applying anything.
    #[arg(long, default_value = "stop")]
    pub on_error: OnError,

    /// Readiness timeout (e.g. "5m", "300s", or bare seconds)
    #[arg(long, value_parser = validate_timeout)]
    pub timeout: Option<String>,

    /// Delegate deployment to the Kix operator instead of applying directly
    /// (requires the build in the cluster's Nix store; incompatible with `--bundle`)
    #[arg(long, conflicts_with = "bundle")]
    pub operator: bool,

    /// Add a `KEY=VALUE` annotation to the Activation record (repeatable).
    /// Keys under `kix.run/`, its subdomains, or retired Kix domains are
    /// reserved and rejected.
    #[arg(
        long = "record-annotation",
        value_name = "KEY=VALUE",
        value_parser = parse_record_annotation,
        conflicts_with = "operator"
    )]
    pub record_annotations: Vec<(String, String)>,

    /// Render a live inline graph-streaming dashboard. Falls back to
    /// line-oriented output on non-interactive terminals.
    #[arg(long)]
    pub tui: bool,

    /// Group the tree view by namespace instead of Kix package. Only affects
    /// rendering; execution order is unchanged.
    #[arg(long)]
    pub group_by_ns: bool,

    /// Cap the live viewport height in rows. Default: half the terminal
    /// height (clamped to [10, 40]). Rows beyond the cap fold into the
    /// scrollback history above.
    #[arg(long, value_name = "ROWS")]
    pub fold_height: Option<u16>,

    /// Output format for the deploy event stream. `pretty` (default on TTY)
    /// is the colored human stream; `line` is the nix-build-L idiom (one
    /// line per terminal verdict, no ANSI); `json` emits NDJSON, one event
    /// per line, suitable for CI/automation. Non-TTY stdout auto-falls-back
    /// to `line` when `pretty` is requested.
    #[arg(long, value_enum, default_value_t = LogFormat::Pretty)]
    pub log_format: LogFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum LogFormat {
    Pretty,
    Line,
    Json,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum PruneMode {
    /// Prune orphans after every apply has finished (default)
    Default,
    /// Skip pruning entirely, defer to `kix gc`
    No,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum OnError {
    Stop,
    Continue,
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

#[derive(clap::Args)]
pub struct RollbackArgs {
    /// Cluster name
    pub cluster: String,

    /// List available Superseded activations without rolling back.
    /// Shows name, identity-hash, timestamp, source store path, and the
    /// previousActivation link so the deploy chain is easy to follow.
    /// Respects `--output json|yaml` for machine consumption.
    #[arg(long)]
    pub list: bool,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Preview mode: show what would be applied without making changes
    #[arg(long)]
    pub dry_run: bool,

    /// Delete orphaned resources from the current activation or earlier deploys
    /// that are not in the rollback target
    #[arg(long)]
    pub prune: bool,

    /// Delegate rollback to the operator instead of applying directly
    #[arg(long)]
    pub operator: bool,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ExportMode {
    /// Plain Kubernetes YAML without Kix metadata, suitable for `kubectl apply`, Flux, or Argo
    Exit,
    /// Preserve `kix.run/*` provenance annotations for audit evidence
    Audit,
}

#[derive(clap::Args)]
pub struct HealthArgs {
    /// Cluster name
    pub cluster: String,
}

/// Compare live cluster objects against their `kix.run/applied-hash`
/// annotations without evaluating a flake.
#[derive(clap::Args)]
pub struct DriftArgs {
    /// Check only objects belonging to this Kix cluster (resolved via its
    /// Activation records). When omitted, checks all Kix-managed objects and
    /// reports their owning clusters.
    #[arg(long)]
    pub cluster: Option<String>,
}

#[derive(clap::Args)]
pub struct StatusArgs {
    /// Cluster name
    pub cluster: String,

    /// Show operator-managed activation status with package-grouped resources
    #[arg(long)]
    pub operator: bool,
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

#[derive(clap::Args)]
pub struct ImagesArgs {
    /// Cluster name
    pub cluster: String,

    /// Show which resources reference each image
    #[arg(long)]
    pub sources: bool,
}

fn parse_record_annotation(s: &str) -> Result<(String, String), String> {
    let (key, value) = s
        .split_once('=')
        .ok_or_else(|| format!("expected KEY=VALUE, got '{s}'"))?;
    // Reserve Kix's own annotation domains (current and retired) for internal
    // metadata such as identity-hash and built-via.
    if key.is_empty() || kix::manifest::keys::is_kix_domain_key(key) {
        return Err(format!(
            "'{key}' is not allowed: the key must be set and not under {}",
            kix::manifest::keys::DOMAIN
        ));
    }
    Ok((key.to_string(), value.to_string()))
}

fn validate_timeout(s: &str) -> Result<String, String> {
    let err = || format!("invalid timeout: '{s}'. Use '5m', '300s', or a number of seconds");
    let s = s.trim();
    if let Some(n) = s.strip_suffix('m') {
        n.parse::<u64>().map_err(|_| err())?;
    } else if let Some(n) = s.strip_suffix('s') {
        n.parse::<u64>().map_err(|_| err())?;
    } else {
        s.parse::<u64>().map_err(|_| err())?;
    }
    Ok(s.to_string())
}

#[derive(clap::Args)]
pub struct CompletionsArgs {
    /// Shell to generate completions for
    pub shell: Shell,
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::FromArgMatches;

    fn long_help(path: &[&str]) -> String {
        let argv = ["kix"].iter().chain(path).chain(&["--help"]);
        let err = command()
            .try_get_matches_from(argv)
            .expect_err("--help exits");
        assert_eq!(err.kind(), clap::error::ErrorKind::DisplayHelp);
        err.render().to_string()
    }

    #[test]
    fn command_is_valid() {
        command().debug_assert();
    }

    #[test]
    fn every_scoped_global_names_a_real_flag_and_command() {
        let cmd = Cli::command();
        for (id, readers) in SCOPED_GLOBALS {
            assert!(
                cmd.get_arguments().any(|a| a.get_id() == *id),
                "no global flag {id}"
            );
            for reader in *readers {
                let mut sc = &cmd;
                for name in reader.split(' ') {
                    sc = sc
                        .find_subcommand(name)
                        .unwrap_or_else(|| panic!("no command `{reader}`"));
                }
            }
        }
    }

    #[test]
    fn completions_help_lists_no_scoped_globals() {
        let help = long_help(&["completions"]);
        for flag in [
            "--output",
            "--context",
            "--flake",
            "--no-cache",
            "--override-input",
        ] {
            assert!(!help.contains(flag), "{flag} in:\n{help}");
        }
        assert!(help.contains("--quiet"));
    }

    #[test]
    fn help_lists_the_globals_a_command_reads() {
        // `deploy --dry-run` prints the plan, so deploy reads `--output`.
        let deploy = long_help(&["deploy"]);
        assert!(deploy.contains("--context") && deploy.contains("--flake"));
        assert!(deploy.contains("--output") && !deploy.contains("--no-cache"));

        let gc = long_help(&["gc"]);
        assert!(!gc.contains("--output"));

        let drift = long_help(&["drift"]);
        assert!(drift.contains("--context") && drift.contains("--output"));
        assert!(!drift.contains("--flake"));

        let sbom = long_help(&["compliance", "sbom"]);
        assert!(sbom.contains("--output") && !sbom.contains("--context"));
        assert!(long_help(&["compliance"]).contains("--context"));
    }

    // Verify that hiding scoped global flags does not shadow `--help` on any
    // subcommand.
    #[test]
    fn every_command_prints_help() {
        fn paths(cmd: &clap::Command, prefix: &[String], out: &mut Vec<Vec<String>>) {
            for sc in cmd.get_subcommands() {
                let mut path = prefix.to_vec();
                path.push(sc.get_name().to_string());
                paths(sc, &path, out);
                out.push(path);
            }
        }
        let mut all = Vec::new();
        paths(&Cli::command(), &[], &mut all);
        for path in all {
            let path: Vec<&str> = path.iter().map(String::as_str).collect();
            long_help(&path);
        }
    }

    #[test]
    fn a_hidden_global_is_still_accepted() {
        let matches = command()
            .try_get_matches_from(["kix", "--flake", "x", "drift"])
            .expect("parses");
        let cli = Cli::from_arg_matches(&matches).expect("converts");
        assert_eq!(cli.global.flake, "x");
    }

    #[test]
    fn a_record_annotation_cannot_use_a_kix_key() {
        assert_eq!(
            parse_record_annotation("lithus.net/statement=abc=="),
            Ok(("lithus.net/statement".into(), "abc==".into()))
        );
        let domain = kix::manifest::keys::DOMAIN;
        let retired = kix::legacy_domain::DOMAINS[0];
        for refused in [
            format!("{}=x", kix::manifest::keys::IDENTITY_HASH),
            format!("deploy.{domain}/x=y"),
            format!("{retired}/built-via=/tmp"),
            "=x".to_string(),
            "no-equals".to_string(),
        ] {
            assert!(parse_record_annotation(&refused).is_err(), "{refused}");
        }
    }
}
