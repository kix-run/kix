use std::path::PathBuf;

use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
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
    /// Output format (text, json, yaml, markdown). Default varies by command.
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

    /// Skip the SQLite eval cache (always re-evaluate from Nix)
    #[arg(long, global = true)]
    pub no_cache: bool,

    /// Override a flake input's URL. Mirrors `nix --override-input`.
    /// Repeatable; takes a name and a URL each time:
    ///   `--override-input kixpkgs path:/nix/store/...kixpkgs`
    /// All overrides are forwarded to every underlying `nix` subprocess.
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
    /// Pair up the raw `--override-input NAME URL` tokens into `(name, url)`.
    /// clap's `num_args = 2` guarantees the vector length is always even.
    pub fn input_overrides(&self) -> Vec<(String, String)> {
        self.override_input
            .chunks_exact(2)
            .map(|c| (c[0].clone(), c[1].clone()))
            .collect()
    }
}

/// The global flags that only some commands read, each with the command
/// paths that read it. A path covers its subcommands, and a command group
/// counts as reading a flag when any of its subcommands does.
///
/// `-v`, `-q` and `--no-color` are read by every command and are not listed.
const SCOPED_GLOBALS: &[(&str, &[&str])] = &[
    (
        "output",
        &[
            "build",
            "diff",
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

/// The clap command for `kix`, with each scoped global flag hidden from the
/// `--help` of the commands that ignore it.
///
/// A hidden flag is still accepted there, so a wrapper that passes
/// `--flake` or `--context` ahead of every subcommand keeps working.
/// clap_complete's generators include hidden flags, so shell completions
/// still offer them.
pub fn command() -> clap::Command {
    let cmd = Cli::command();
    let globals: Vec<clap::Arg> = cmd
        .get_arguments()
        .filter(|a| a.is_global_set())
        .cloned()
        .collect();
    cmd.mut_subcommands(|sc| hide_unread_globals(sc, "", &globals))
}

/// Gives `cmd` a hidden copy of each scoped global flag it does not read.
///
/// clap copies a global flag into a subcommand only when the subcommand has
/// no argument with that id, so the hidden copy takes its place. This has to
/// happen before `Command::build`: an argument changed after the build keeps
/// a stale position in the parser's lookup table.
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

    /// Colored diff against the live cluster, or against a directory with --from
    Diff(DiffArgs),

    /// Evaluate a cluster and report build-time checks and scorecard findings
    ///
    /// Evaluation runs the constructor validators, the cross-resource checks
    /// and every error-severity scorecard rule; a failure in any of them
    /// reports `eval` as `fail`. The `scorecard` row counts findings at each
    /// severity. `kix check` does not validate the rendered manifests against
    /// Kubernetes schemas; `nix flake check` does, through the
    /// `schema-cluster-<name>` check. Exits 1 when a row reports `fail`.
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

    /// Summarise a cluster's rendered resources by namespace and kind
    Inspect(InspectArgs),

    /// Garbage-collect stale kix-managed resources
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
}

impl Command {
    /// Extract the cluster name from commands that take one, for early validation.
    pub fn cluster_name(&self) -> Option<&str> {
        match self {
            Command::Build(a) => Some(&a.cluster),
            Command::Diff(a) => Some(&a.cluster),
            Command::Check(a) => Some(&a.cluster),
            Command::Deploy(a) => Some(&a.cluster),
            Command::Status(a) => Some(&a.cluster),
            Command::Graph(a) => Some(&a.cluster),
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
            Command::Completions(_) | Command::Drift(_) | Command::Pin(_) => None,
        }
    }
}

/// Promote a built cluster with `kix pin`.
///
/// A cluster definition that decides an image reference at deploy time has no
/// committed answer to "what is running", and a clean checkout of it renders
/// something nobody meant to deploy. `kix pin` writes that decision down: it
/// asks the registry what a tag resolves to, refuses a tag that does not
/// exist, and records the digest in a pin file next to the cluster.
///
/// It needs no cluster evaluation or flake. The state in
/// which you most need to run it is the state in which evaluation is
/// unhappy, so it takes a file path and nothing else.
#[derive(Subcommand)]
pub enum PinCommand {
    /// Resolve a tag and write it into the pin file
    Set(PinSetArgs),

    /// Verify every pin still resolves, by digest
    Check(PinCheckArgs),

    /// Show what a pin file holds
    List(PinListArgs),
}

#[derive(clap::Args)]
pub struct PinSetArgs {
    /// Pin name, as the cluster definition reads it: `pins.get "<key>"`
    pub key: String,

    /// Tag to promote to. Kept in the file because it is what a human reads.
    #[arg(long)]
    pub tag: Option<String>,

    /// Repository including the registry host. Required for a new pin;
    /// otherwise the existing repository is kept.
    #[arg(long)]
    pub repository: Option<String>,

    /// Record this digest instead of asking the registry. For an air-gapped
    /// promotion where the digest is already known.
    #[arg(long, conflicts_with = "no_resolve")]
    pub digest: Option<String>,

    /// Write the pin without a digest. Honest, and weaker: nothing then
    /// verifies that the tag exists, now or later.
    #[arg(long)]
    pub no_resolve: bool,

    /// Revision of the source this image was built from. `kix pin check
    /// --source-rev` later asserts the promotion actually ran.
    #[arg(long)]
    pub source_rev: Option<String>,

    /// Who promoted it. Defaults to the CI run, or to user@host.
    #[arg(long)]
    pub promoted_by: Option<String>,

    /// A note about this entry, kept for whoever reads the file later. Kix
    /// never reads it and a promotion never discards it. Pass an empty
    /// string to clear one.
    #[arg(long)]
    pub note: Option<String>,

    /// Create the pin file, or add a pin that is not in it yet.
    #[arg(long)]
    pub init: bool,

    /// Rewrite a pin file that `kix pin` did not write, discarding its
    /// comments and layout.
    #[arg(long)]
    pub force: bool,

    /// Path to the pin file. Found rather than required: Kix looks in the
    /// working directory, then next to the flake, then for the only
    /// `*pins.json` in the repository.
    #[arg(long)]
    pub pins_file: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct PinCheckArgs {
    /// Check only these pins. Repeatable. Default: all of them.
    #[arg(long = "key")]
    pub keys: Vec<String>,

    /// Fail unless every pin that records a source revision records this one.
    /// This is what catches a promotion step that silently did not run.
    #[arg(long)]
    pub source_rev: Option<String>,

    /// Treat a pin with no digest as a warning rather than a failure.
    #[arg(long)]
    pub allow_unresolved: bool,

    /// Check the file's shape without contacting any registry.
    #[arg(long)]
    pub offline: bool,

    /// Path to the pin file. Found rather than required: Kix looks in the
    /// working directory, then next to the flake, then for the only
    /// `*pins.json` in the repository.
    #[arg(long)]
    pub pins_file: Option<PathBuf>,
}

#[derive(clap::Args)]
pub struct PinListArgs {
    /// Path to the pin file. Found rather than required: Kix looks in the
    /// working directory, then next to the flake, then for the only
    /// `*pins.json` in the repository.
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

    /// Read the deploy receipt off the cluster's active Activation instead of
    /// building. This attests what is deployed rather than what would be, and
    /// works from a machine that has never built this cluster.
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

    /// Compare against a directory instead of the live cluster: a previous
    /// build result (`kix-packages.json` inside) or a manifest directory
    /// written by `kix snapshot save` or `kix export`
    #[arg(long, value_name = "DIR")]
    pub from: Option<String>,

    /// How much of each change `--output json` and `--output yaml` include.
    /// Text and Markdown output are the same at every level.
    #[arg(long, value_enum, default_value_t = DiffDetail::Plain)]
    pub detail: DiffDetail,
}

/// What `kix diff --output json|yaml` says about each changed resource.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DiffDetail {
    /// Which resources change, and how many fields of each.
    Plain,
    /// Also each changed field, with its old and new value.
    Fields,
    /// Also the old and new manifest of each changed, added, or removed
    /// resource.
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
pub struct DeployArgs {
    /// Cluster name
    pub cluster: String,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Preview mode: show what would be applied without making changes
    #[arg(long)]
    pub dry_run: bool,

    /// Use local activation cache instead of fetching from cluster.
    ///
    /// Plans entirely offline, so it cannot see the records of deploys that
    /// stopped part way and will not reconcile what they left behind, and it
    /// cannot see orphans that earlier deploys kept. It records those builds
    /// on the new activation again, so a later plain `kix deploy --prune` or
    /// `kix gc` still deletes their orphans.
    #[arg(long)]
    pub current_activation: bool,

    /// Behavior on error: stop or continue
    #[arg(long, default_value = "stop")]
    pub on_error: OnError,

    /// Readiness timeout (e.g. "5m", "300s", or bare seconds)
    #[arg(long, value_parser = validate_timeout)]
    pub timeout: Option<String>,

    /// Re-apply all resources even if activation identity matches (heal drift)
    #[arg(long)]
    pub reconcile: bool,

    /// Delete orphaned resources (in the old activation, or kept by an earlier
    /// deploy, and not in the new one). Without it they are listed, kept, and
    /// recorded on the new activation for a later `--prune` or `kix gc`
    #[arg(long)]
    pub prune: bool,

    /// Prune mode: default (prune after apply), no (skip pruning)
    #[arg(long, value_name = "MODE")]
    pub prune_mode: Option<PruneMode>,

    /// Delegate deployment to the kix operator instead of applying directly
    #[arg(long)]
    pub operator: bool,

    /// Take ownership of fields currently owned by other field managers (SSA conflict override).
    /// Without this, conflicts surface as a 409 with the conflicting field paths and current owner.
    /// Useful when migrating resources from kubectl/helm to kix for the first time.
    #[arg(long)]
    pub force_conflicts: bool,

    /// Acknowledge detected stateful migration pairs and proceed. Without
    /// this flag, a deploy that would remove + add stateful resources in
    /// the same logical slot is rejected (even with --yes) to prevent
    /// silent data loss. Kix does not copy data between them.
    #[arg(long)]
    pub accept_migrations: bool,

    /// Render a live inline graph-streaming dashboard. Falls back to
    /// line-oriented output on non-interactive terminals.
    #[arg(long)]
    pub tui: bool,

    /// Group the tree view by namespace instead of kix package. Only affects
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
    /// Prune orphans after all apply waves complete (default)
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
    /// Move this cluster's Kix records to Kix's current API group.
    ///
    /// Kix used to stamp its annotations and register its CRDs under a
    /// domain we do not own. Records made before the move still sit under
    /// the old API group, and Kix refuses to touch such a cluster until this
    /// has run.
    ///
    /// It copies every Activation record to the new group with its history
    /// intact, verifies each copy by name and by phase, clears the operator
    /// finalizer from the old records, and deletes the old CRDs. PackageInstance records are not copied: the
    /// next deploy re-creates them from the build.
    ///
    /// Scale the kix operator to 0 first if this cluster runs one. While it
    /// watches the old API group it re-adds its finalizer to the records, and
    /// deleting the old CRDs would then make it delete every resource in the
    /// activation. The command tests this rather than trusting it: it clears
    /// the finalizers, waits, and reads them back. Only a running operator
    /// puts one back, and if one does, it stops there having copied and
    /// deleted nothing.
    ///
    /// Run it once per cluster. If it is interrupted, run it again: it skips
    /// what it already copied and repairs a copy whose status did not land.
    /// Then upgrade the operator image, scale it back up, and deploy.
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

    /// Also delete resources that carry the kix label but no kix.run/identity-hash.
    /// kix never applied those, so by default --hard only reports them.
    #[arg(long)]
    pub include_unstamped: bool,

    /// With --hard, also judge Kix objects that name no Activation record
    /// on the cluster. When another Kix cluster has records here, Kix cannot
    /// tell whose those objects are, so by default --hard only reports them.
    #[arg(long, requires = "hard")]
    pub include_unattributed: bool,

    /// Always keep at least this many of the newest Superseded Activation
    /// records (rollback history), whatever their age. Applies in every
    /// mode. 0 keeps none.
    #[arg(long, value_name = "N", default_value_t = kix::cluster::activation::DEFAULT_KEEP_MIN)]
    pub keep: usize,

    /// Never keep more than this many Superseded records. Each record still
    /// on the cluster keeps one entry in kix.run/activations on every
    /// managed resource, and that annotation has a hard size cap.
    #[arg(long, value_name = "N", default_value_t = kix::cluster::activation::DEFAULT_KEEP_MAX)]
    pub keep_max: usize,

    /// Beyond --keep, retire records older than this (30d, 12h, 45m; a bare
    /// number is days). "0" or "off" disables the age rule.
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

    /// Delete orphaned resources (in the current activation, or kept by an
    /// earlier deploy, and not in the target)
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

    /// Export mode: `exit` strips kix.run/* annotations and skips kix-internal
    /// CRs (Activation, PackageInstance) for a neutral handoff. `audit`
    /// preserves everything for compliance evidence.
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
    /// Neutral kix-free YAML suitable for `kubectl apply` / Flux / Argo
    Exit,
    /// Preserve kix.run/* provenance annotations for audit evidence
    Audit,
}

#[derive(clap::Args)]
pub struct HealthArgs {
    /// Cluster name
    pub cluster: String,
}

/// No flake argument: the check compares live objects against the
/// `kix.run/applied-hash` stamps written at deploy time, so it runs from any
/// kubeconfig-only context. Uses the global `--context` and `--output` flags.
#[derive(clap::Args)]
pub struct DriftArgs {
    /// Check only this Kix cluster's objects, found through its Activation
    /// records. Without it every Kix object is checked and each report names
    /// the Kix clusters it belongs to.
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

/// Reads the cluster's Activation records to tell its objects from those of
/// other Kix clusters on the same Kubernetes cluster. Needs no flake.
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
        let deploy = long_help(&["deploy"]);
        assert!(deploy.contains("--context") && deploy.contains("--flake"));
        assert!(!deploy.contains("--output") && !deploy.contains("--no-cache"));

        let drift = long_help(&["drift"]);
        assert!(drift.contains("--context") && drift.contains("--output"));
        assert!(!drift.contains("--flake"));

        let sbom = long_help(&["compliance", "sbom"]);
        assert!(sbom.contains("--output") && !sbom.contains("--context"));
        assert!(long_help(&["compliance"]).contains("--context"));
    }

    /// Every command, including each one that hides a global flag, still
    /// resolves `--help` to the help flag.
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
}
