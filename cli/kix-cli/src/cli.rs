//! The command line of `kix`: the global flags, the list of commands, and
//! the arguments of each command, one file per group of commands.

use std::ffi::OsString;

use clap::builder::FalseyValueParser;
use clap::{Parser, Subcommand, ValueEnum};

mod build;
mod compliance;
mod deploy;
mod maintain;
mod observe;
mod pin;
mod plan;
mod project;
mod scoped;

pub use build::*;
pub use compliance::*;
pub use deploy::*;
pub use maintain::*;
pub use observe::*;
pub use pin::*;
pub use plan::*;
pub use project::*;
pub use scoped::command;
#[cfg(test)]
pub(crate) use scoped::live_command;

#[derive(Parser)]
#[command(
    name = "kix",
    version = kix::VERSION,
    about = "Kix is a Kubernetes compiler.",
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
    /// Output format. Each command prints some of these formats and refuses
    /// the others. The default depends on the command.
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum OutputFormat {
    Text,
    Json,
    Yaml,
    /// GitHub-flavored markdown suitable for PR comments
    Markdown,
    /// SARIF 2.1.0 JSON, for GitHub code scanning
    Sarif,
    /// Graphviz DOT
    Dot,
    /// An indented tree
    Tree,
}

impl OutputFormat {
    /// Return the value a user types after `-o`.
    pub fn name(self) -> &'static str {
        match self {
            OutputFormat::Text => "text",
            OutputFormat::Json => "json",
            OutputFormat::Yaml => "yaml",
            OutputFormat::Markdown => "markdown",
            OutputFormat::Sarif => "sarif",
            OutputFormat::Dot => "dot",
            OutputFormat::Tree => "tree",
        }
    }
}

#[derive(Subcommand)]
pub enum Command {
    /// Render manifests to stdout
    Build(BuildArgs),

    /// Compare the build with another build, a snapshot, or an export
    ///
    /// Compares the build with a previous build or a manifest directory
    /// (`--from`), with a bundled build (`--from-bundle`), or, given only
    /// `--bundle`, with nothing. It never contacts a cluster. To compare the build with the live cluster, use
    /// `kix plan --read-only`.
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
    /// writes, use `kix plan --read-only` when you only have read-only
    /// access. A dry run cannot verify whether Pods will start or pass
    /// readiness probes.
    ///
    /// Exits 0 when the deploy would make no changes, 2 when changes would be
    /// made, and 3 when the deploy would be blocked by a rejected write or an
    /// unacknowledged stateful migration (see `--accept-migrations`).
    Plan(PlanCommandArgs),

    /// Evaluate a cluster and report build-time checks and scorecard findings
    ///
    /// Runs constructor validators, cross-resource checks, and error-severity
    /// scorecard rules; any failure marks the `eval` row as `fail`. The
    /// `scorecard` row summarizes findings by severity. Exits 1 when any row
    /// reports `fail`.
    Check(CheckArgs),

    /// Wave-based deployment with confirmation
    Deploy(DeployArgs),

    /// Check that what Kix deployed is present, unchanged, and ready
    ///
    /// Reads the cluster's deploy records and Kix's objects, and runs three
    /// checks on every object of the current deploy: presence (is it on the
    /// cluster), drift (does it still hold what Kix applied), and readiness
    /// (is it ready by the rules `kix deploy` waits on). Needs only a
    /// kubeconfig, no project or build. Objects of a kind this account may
    /// not list are counted as not checked.
    ///
    /// Exits 0 when every selected check passes, 2 when an object is
    /// missing, changed, or not ready, and 1 when Kix could not answer.
    Status(StatusArgs),

    /// List clusters, packages, resources, or images
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

    /// Garbage-collect stale Kix-managed resources
    Gc(GcArgs),

    /// One-off cluster migrations
    #[command(subcommand)]
    Migrate(MigrateCommand),

    /// Rollback to the previous activation
    Rollback(RollbackArgs),

    /// List the earlier deploys that `kix rollback` can go back to
    ///
    /// Shows each deploy record's name, identity hash, time, build, and the
    /// deploy it replaced, so the chain of deploys is easy to follow.
    History(HistoryArgs),

    /// Export cluster manifests as plain Kubernetes YAML
    Export(ExportArgs),

    /// Tail logs for a package's primary workload
    Logs(LogsArgs),

    /// Port-forward to a package's primary workload
    #[command(name = "port-forward", visible_alias = "pf")]
    PortForward(PortForwardArgs),

    /// Save a cluster's Kix-managed objects for offline comparisons
    Snapshot(SnapshotArgs),

    /// Generate shell completions
    Completions(CompletionsArgs),

    /// Check the Kix installation
    ///
    /// Reports where Kix found the Kix runtime (nix, helm, kubectl, sops),
    /// checks that its manifest.json lists the programs Kix expects, and
    /// checks every file against its SHA-256 in the
    /// manifest. Also reports the project's builder and where it was chosen
    /// (kix.toml, or the default), the version of Kix the project needs, and
    /// the installed versions of Kix. Exits 1 when a check fails.
    Doctor,

    /// Compliance exports: SBOM, SLSA attestations, audit bundles
    Compliance(ComplianceArgs),

    /// Resolve image references and record them in a committed pin file
    #[command(subcommand)]
    Pin(PinCommand),

    /// Move this project to a newer version of Kix
    ///
    /// Builds every cluster with the current Kix, pins the project to the
    /// target (the newest release or `--to`, delayed by `[upgrade] min-age` in
    /// kix.toml), and builds again. When that fails, it goes one minor release
    /// at a time and stops at the first release that does not build, leaving
    /// the project pinned there; fix the build and run `kix upgrade` again to
    /// continue. Compares the manifests before and after, lists every breaking,
    /// security, and upgrade note in the range (marking notes whose package
    /// name matches an instance the clusters use with `*` as likely matches,
    /// since Kix cannot tell for certain which notes affect the project), and
    /// writes kix-upgrade.json.
    ///
    /// Exits 0 when the project builds on the target, no object changed in any
    /// cluster, and nothing needs review; 1 when Kix refused or could not start
    /// (bad input, network error, missing baseline builds, or unacknowledged
    /// data migrations from the last upgrade); 2 when a build failed (with the
    /// current Kix or at a step) or the library could not be locked at the new
    /// tag; and 3 when a person must review: any object changed in any cluster,
    /// a breaking change that shows no build error, a release every cluster
    /// must deploy before upgrading further, or a flake.nix edit you must make
    /// by hand.
    Upgrade(UpgradeArgs),

    /// Install, list, and remove versions of Kix
    ///
    /// Versions live under ~/.local/share/kix/<version>. A project names the
    /// version it needs with `kix = "0.8"` in kix.toml, and Kix runs that
    /// version for the project, installing it first when needed.
    #[command(name = "self", subcommand)]
    SelfCmd(SelfCommand),

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
            Command::Status(a) => a.cluster.as_deref(),
            Command::Graph(a) => Some(&a.cluster),
            Command::Bundle(a) => Some(&a.cluster),
            Command::Gc(a) => Some(&a.cluster),
            Command::Migrate(MigrateCommand::Domain(a)) => Some(&a.cluster),
            Command::Rollback(a) => Some(&a.cluster),
            Command::History(a) => Some(&a.cluster),
            Command::Export(a) => Some(&a.cluster),
            Command::Logs(a) => Some(&a.cluster),
            Command::PortForward(a) => Some(&a.cluster),
            Command::List(a) => match &a.command {
                ListCommand::Packages(p) => p.cluster.as_deref(),
                ListCommand::Resources(r) => Some(&r.cluster),
                ListCommand::Images(i) => Some(&i.cluster),
                ListCommand::Clusters => None,
            },
            Command::Compliance(a) => match &a.command {
                ComplianceCommand::Sbom(s) => Some(&s.cluster),
                ComplianceCommand::Attest(s) => Some(&s.cluster),
                ComplianceCommand::Audit(s) => Some(&s.cluster),
            },
            Command::Snapshot(a) => Some(&a.cluster),
            Command::Completions(_)
            | Command::Doctor
            | Command::Pin(_)
            | Command::Upgrade(_)
            | Command::SelfCmd(_)
            | Command::Plugin(_) => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::FromArgMatches;

    #[test]
    fn documented_commands_parse_with_clap() {
        fn walk_mdx(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
            let Ok(entries) = std::fs::read_dir(dir) else {
                return;
            };
            let mut paths: Vec<_> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
            paths.sort();
            for path in paths {
                if path.is_dir() {
                    walk_mdx(&path, out);
                } else if path.extension().and_then(|s| s.to_str()) == Some("mdx") {
                    out.push(path);
                }
            }
        }

        fn extract_command_strings(mdx: &str) -> Vec<String> {
            let mut commands = Vec::new();
            let mut rest = mdx;
            while let Some(start) = rest.find("<Command") {
                let after = &rest[start..];
                let Some(end) = after.find("/>") else {
                    break;
                };
                let block = &after[..end];
                let mut scan = block;
                while let Some(q_start) = scan.find("\"kix ") {
                    let after_q = &scan[q_start + 1..];
                    let Some(q_end) = after_q.find('"') else {
                        break;
                    };
                    commands.push(after_q[..q_end].to_string());
                    scan = &after_q[q_end + 1..];
                }
                rest = &after[end + 2..];
            }

            for fence in ["```sh\n", "```bash\n", "```shell\n"] {
                let mut scan = mdx;
                while let Some(start) = scan.find(fence) {
                    let after = &scan[start + fence.len()..];
                    let Some(end) = after.find("```") else {
                        break;
                    };
                    let body = after[..end].replace("\\\n", " ");
                    for line in body.lines() {
                        let trimmed = line.trim().trim_start_matches("$ ");
                        if trimmed.starts_with("kix ") {
                            commands.push(trimmed.to_string());
                        }
                    }
                    scan = &after[end + 3..];
                }
            }
            commands
        }

        fn normalize_command(raw: &str) -> Vec<String> {
            let mut s = raw.replace("\\\n", " ");
            for sep in [" | ", " > ", " || ", " #"] {
                if let Some(idx) = s.find(sep) {
                    s.truncate(idx);
                }
            }
            let s = s
                .replace(
                    "<64-hex-characters>",
                    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
                )
                .replace("<CLUSTER>", "demo")
                .replace("<DIR>", "/tmp/dir");
            s.split_whitespace().map(str::to_string).collect()
        }

        let docs_root =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/src/content/docs");
        if !docs_root.exists() {
            return;
        }

        let mut mdx_files = Vec::new();
        walk_mdx(&docs_root, &mut mdx_files);
        assert!(!mdx_files.is_empty(), "expected .mdx files in docs");

        let mut checked = 0usize;
        for file in mdx_files {
            let content = std::fs::read_to_string(&file).expect("read mdx file");
            for raw_cmd in extract_command_strings(&content) {
                let argv = normalize_command(&raw_cmd);
                match command().try_get_matches_from(&argv) {
                    Ok(matches) => {
                        if let Some(removed) = crate::removed::find(
                            &matches,
                            crate::removed::COMMANDS,
                            crate::removed::FLAGS,
                        ) {
                            panic!("{}: `{raw_cmd}`: {}", file.display(), removed.message());
                        }
                        let cli = Cli::from_arg_matches(&matches).unwrap_or_else(|e| {
                            panic!("{}: `{raw_cmd}` failed FromArgMatches: {e}", file.display())
                        });
                        if let Some(removed) = crate::removed::refused(&cli.command) {
                            panic!("{}: `{raw_cmd}`: {}", file.display(), removed.message());
                        }
                        if let Command::Plugin(args) = &cli.command {
                            let plugin_name = args.first().and_then(|a| a.to_str()).unwrap_or("");
                            assert_eq!(
                                plugin_name,
                                "enterprise",
                                "{}: `{raw_cmd}` fell back to external subcommand `{plugin_name}` (unknown subcommand?)",
                                file.display()
                            );
                        }
                    }
                    Err(err)
                        if matches!(
                            err.kind(),
                            clap::error::ErrorKind::DisplayHelp
                                | clap::error::ErrorKind::DisplayVersion
                        ) => {}
                    Err(err) => panic!(
                        "{}: documented command `{raw_cmd}` (argv: {argv:?}) failed clap parse:\n{err}",
                        file.display()
                    ),
                }
                checked += 1;
            }
        }
        assert!(
            checked >= 100,
            "expected at least 100 documented kix commands, found {checked}"
        );
    }
}
