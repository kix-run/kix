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

    /// Colored diff against live cluster
    Diff(DiffArgs),

    /// Validate: eval + schema + policy
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

    /// Deep-dive: DI deps, parts, out
    Inspect(InspectArgs),

    /// Garbage-collect stale kix-managed resources
    Gc(GcArgs),

    /// Rollback to the previous activation
    Rollback(RollbackArgs),

    /// Export cluster manifests as plain Kubernetes YAML (exit-strategy / audit bundle)
    Export(ExportArgs),

    /// Tail logs for a package's primary workload
    Logs(LogsArgs),

    /// Port-forward to a package's primary workload
    #[command(alias = "port-forward")]
    Pf(PortForwardArgs),

    /// Drift detection: compare intended state vs live cluster
    Health(HealthArgs),

    /// Manage cluster snapshots for CI/offline use
    Snapshot(SnapshotArgs),

    /// List all container images in a cluster activation (for airgap preloading)
    Images(ImagesArgs),

    /// Generate shell completions
    Completions(CompletionsArgs),

    /// Compliance exports: SBOM, SLSA attestations, audit bundles
    Compliance(ComplianceArgs),
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
            Command::Snapshot(_) | Command::Completions(_) => None,
        }
    }
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

    /// Diff against a snapshot directory instead of the live cluster
    #[arg(long)]
    pub snapshot: Option<String>,

    /// Build-to-build diff: compare against a previous activation result directory
    #[arg(long)]
    pub from: Option<String>,
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

    /// Use local activation cache instead of fetching from cluster
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

    /// Delete orphaned resources (from old activation but not new)
    #[arg(long)]
    pub prune: bool,

    /// Prune mode: default (prune after apply), eager (interleave), no (skip pruning)
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
    /// silent data loss. See v2_discussions/67_stateful_migration_orchestration.md.
    #[arg(long)]
    pub accept_migrations: bool,

    /// Experimental: render a live inline TUI dashboard showing the current
    /// wave, in-flight resources, and queued work. Falls back to the standard
    /// line-oriented output on non-interactive terminals.
    #[arg(long)]
    pub tui: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum PruneMode {
    /// Prune orphans after all apply waves complete (default)
    Default,
    /// Interleave prune waves with apply waves
    Eager,
    /// Skip pruning entirely, defer to `kix gc`
    No,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum OnError {
    Stop,
    Continue,
}

#[derive(clap::Args)]
pub struct GcArgs {
    /// Cluster name
    pub cluster: String,

    /// Skip confirmation prompt
    #[arg(short, long)]
    pub yes: bool,

    /// Full cluster scan (default: diff old vs new activation store graphs)
    #[arg(long)]
    pub hard: bool,

    /// Delegate garbage collection to the operator (deletes superseded Activation CRs)
    #[arg(long)]
    pub operator: bool,
}

#[derive(clap::Args)]
pub struct RollbackArgs {
    /// Cluster name
    pub cluster: String,

    /// List available Superseded activations (history) and exit — no rollback.
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

    /// Delete orphaned resources (resources in current activation but not in target)
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

    /// Export mode: `exit` strips kix.dev/* annotations and skips kix-internal
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

    /// Port specs passed straight to `kubectl port-forward`: `LOCAL:REMOTE`
    /// or a bare `REMOTE` (e.g. `8080:80`, `5432`). One or more.
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
    /// Preserve kix.dev/* provenance annotations for audit evidence
    Audit,
}

#[derive(clap::Args)]
pub struct HealthArgs {
    /// Cluster name
    pub cluster: String,
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
    /// Save a snapshot of the live cluster state
    Save(SnapshotSaveArgs),

    /// Diff a snapshot against the current rendered manifests
    Diff(SnapshotDiffArgs),
}

#[derive(clap::Args)]
pub struct SnapshotSaveArgs {
    /// Directory to save the snapshot to
    pub dir: String,
}

#[derive(clap::Args)]
pub struct SnapshotDiffArgs {
    /// Cluster name to diff against the snapshot
    pub cluster: String,

    /// Path to an existing snapshot directory
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
