//! Run the parsed command.
//!
//! Each command declares what it needs in [`Command::needs`] and how it
//! prints in [`Command::format_mode`], and [`run`] sets that up before one
//! `match` calls the command. `needs`, `format_mode`, [`FormatMode::formats`],
//! and `run` are exhaustive matches, so a new command does not compile until
//! it says what it needs, what it prints, and how it runs.

use miette::Result;

use crate::cli::{Cli, Command, ComplianceCommand, MigrateCommand, OutputFormat};
use crate::commands::{self, CommandContext};
use crate::exit::Exit;

/// What `main` sets up before a command runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Needs {
    /// Only the command line and a [`CommandContext`].
    ///
    /// The command must work where the others stop: outside a project, with
    /// a broken Kix runtime, or when the project does not evaluate. It loads
    /// `kix.toml` itself if it reads it.
    Nothing,
    /// A project: a valid cluster name, the Nix runner the project's builder
    /// in `kix.toml` chooses, and a Kix runtime from this release.
    Project,
}

impl Command {
    /// Return what the command needs before it runs.
    pub fn needs(&self) -> Needs {
        match self {
            // Runs another program in place of Kix.
            Command::Plugin(_) => Needs::Nothing,
            Command::Completions(_) => Needs::Nothing,
            // Installs and lists versions of Kix, inside a project or not.
            Command::SelfCmd(_) => Needs::Nothing,
            // Reports a broken runtime instead of stopping on it.
            Command::Doctor => Needs::Nothing,
            // Edits the pin file without evaluating the project, so it works
            // when evaluation fails.
            Command::Pin(_) => Needs::Nothing,
            // Runs every evaluation in the Kix version of each step.
            Command::Upgrade(_) => Needs::Nothing,
            // Reads only the cluster, so it works from a bare kubeconfig
            // outside any project.
            Command::Status(_) => Needs::Nothing,
            Command::Build(_)
            | Command::Diff(_)
            | Command::Plan(_)
            | Command::Check(_)
            | Command::Deploy(_)
            | Command::List(_)
            | Command::Graph(_)
            | Command::Bundle(_)
            | Command::Gc(_)
            | Command::Migrate(_)
            | Command::Rollback(_)
            | Command::History(_)
            | Command::Export(_)
            | Command::Logs(_)
            | Command::PortForward(_)
            | Command::Snapshot(_)
            | Command::Compliance(_) => Needs::Project,
        }
    }
}

use OutputFormat::{Dot, Json, Markdown, Sarif, Text, Tree, Yaml};

/// Formats of a command that prints only text for a person.
const TEXT: &[OutputFormat] = &[Text];
/// Formats of a command whose answer is data.
const DATA: &[OutputFormat] = &[Text, Json, Yaml];

/// Declare [`FormatMode`] and [`FormatMode::ALL`] from one list of variants,
/// so `ALL` cannot leave one out.
macro_rules! format_modes {
    ($($(#[$doc:meta])* $mode:ident,)*) => {
        /// One way a command prints, as its command line selects it.
        ///
        /// [`Command::format_mode`] picks the mode of a parsed command, and
        /// [`FormatMode::formats`] lists its formats. Both are exhaustive
        /// matches, so a new command or mode does not compile until it says
        /// what it prints.
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum FormatMode {
            $($(#[$doc])* $mode,)*
        }

        impl FormatMode {
            /// Every mode, for the help of each command.
            pub const ALL: &[FormatMode] = &[$(FormatMode::$mode,)*];
        }
    };
}

format_modes! {
    Build,
    Check,
    Graph,
    Diff,
    Plan,
    /// `kix plan --read-only`.
    PlanReadOnly,
    Deploy,
    /// `kix deploy --dry-run`.
    DeployDryRun,
    /// `kix deploy --plan FILE --dry-run`.
    DeploySavedPlanDryRun,
    Rollback,
    History,
    Status,
    List,
    Pin,
    ComplianceSbom,
    ComplianceAttest,
    ComplianceAudit,
    Completions,
    SelfCmd,
    Doctor,
    Upgrade,
    Bundle,
    Gc,
    Migrate,
    Export,
    Logs,
    PortForward,
    Snapshot,
}

impl FormatMode {
    /// Return the `-o` formats the mode prints, the default first.
    pub fn formats(self) -> &'static [OutputFormat] {
        use FormatMode as M;
        match self {
            M::Build => &[Yaml, Json],
            M::Check => &[Text, Json, Yaml, Sarif],
            M::Graph => &[Tree, Dot, Json, Yaml],
            M::Diff => &[Text, Json, Yaml, Markdown],
            // A plan is data only as a saved plan file (`--out`).
            M::Plan => &[Text, Markdown],
            M::PlanReadOnly => &[Text, Json, Yaml, Markdown],
            M::Deploy => TEXT,
            M::DeployDryRun => &[Text, Markdown],
            M::DeploySavedPlanDryRun => DATA,
            M::History | M::Status | M::List | M::Pin => DATA,
            M::ComplianceSbom | M::ComplianceAttest => &[Json, Yaml],
            M::Rollback
            | M::ComplianceAudit
            | M::Completions
            | M::SelfCmd
            | M::Doctor
            | M::Upgrade
            | M::Bundle
            | M::Gc
            | M::Migrate
            | M::Export
            | M::Logs
            | M::PortForward
            | M::Snapshot => TEXT,
        }
    }

    /// Return the command path of the mode as a user types it, such as
    /// `compliance sbom`. The mode covers every subcommand of the path.
    pub fn path(self) -> &'static str {
        use FormatMode as M;
        match self {
            M::Build => "build",
            M::Check => "check",
            M::Graph => "graph",
            M::Diff => "diff",
            M::Plan | M::PlanReadOnly => "plan",
            M::Deploy | M::DeployDryRun | M::DeploySavedPlanDryRun => "deploy",
            M::Rollback => "rollback",
            M::History => "history",
            M::Status => "status",
            M::List => "list",
            M::Pin => "pin",
            M::ComplianceSbom => "compliance sbom",
            M::ComplianceAttest => "compliance attest",
            M::ComplianceAudit => "compliance audit",
            M::Completions => "completions",
            M::SelfCmd => "self",
            M::Doctor => "doctor",
            M::Upgrade => "upgrade",
            M::Bundle => "bundle",
            M::Gc => "gc",
            M::Migrate => "migrate",
            M::Export => "export",
            M::Logs => "logs",
            M::PortForward => "port-forward",
            M::Snapshot => "snapshot",
        }
    }

    /// Return the flags that select the mode as a user types them, such as
    /// `--dry-run`, or `None` when the command needs none.
    pub fn flags(self) -> Option<&'static str> {
        match self {
            FormatMode::PlanReadOnly => Some("--read-only"),
            FormatMode::DeployDryRun => Some("--dry-run"),
            FormatMode::DeploySavedPlanDryRun => Some("--plan FILE --dry-run"),
            _ => None,
        }
    }

    /// Return advice to add when the mode refuses a format.
    pub fn hint(self) -> Option<String> {
        let plan = || {
            format!(
                "To save the plan to a file, run `kix plan --out FILE.{}`. \
                 For JSON output, run `kix plan --read-only -o json` for a read-only plan, \
                 or `kix deploy --plan FILE --dry-run -o json` to check a saved plan \
                 against the cluster.",
                kix::plan::file::EXTENSION
            )
        };
        match self {
            FormatMode::Plan | FormatMode::PlanReadOnly | FormatMode::DeployDryRun => Some(plan()),
            FormatMode::Deploy => {
                Some("Pass `--log-format json` to print one JSON event per line.".to_string())
            }
            _ => None,
        }
    }
}

/// A format that the help of a command lists.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HelpFormat {
    pub format: OutputFormat,
    /// The flags the command prints the format with, as a user types them,
    /// such as `--dry-run`, or `None` when it needs none.
    pub needs: Option<&'static str>,
}

/// Return whether `path` is `parent` or one of its subcommands, such as
/// `list clusters` for `list`.
fn under(path: &str, parent: &str) -> bool {
    path == parent
        || path
            .strip_prefix(parent)
            .is_some_and(|rest| rest.starts_with(' '))
}

/// Return the modes that the help of the command at `path` covers: the
/// modes of the command and of its subcommands.
fn modes_at(path: &str) -> impl Iterator<Item = FormatMode> + '_ {
    FormatMode::ALL
        .iter()
        .copied()
        .filter(move |m| under(path, m.path()) || under(m.path(), path))
}

/// Return whether the command at `path` shows `-o` in its help: whether it,
/// or one of its subcommands, prints something other than text.
pub fn reads_output(path: &str) -> bool {
    modes_at(path).any(|m| m.formats() != TEXT)
}

impl Command {
    /// Return how the command prints, or `None` for a plugin, which decides
    /// for itself.
    pub fn format_mode(&self) -> Option<FormatMode> {
        use FormatMode as M;
        Some(match self {
            Command::Plugin(_) => return None,
            Command::Compliance(args) => match args.command {
                ComplianceCommand::Sbom(_) => M::ComplianceSbom,
                ComplianceCommand::Attest(_) => M::ComplianceAttest,
                ComplianceCommand::Audit(_) => M::ComplianceAudit,
            },
            Command::Build(_) => M::Build,
            Command::Check(_) => M::Check,
            Command::Graph(_) => M::Graph,
            Command::Diff(_) => M::Diff,
            Command::Plan(args) if args.read_only => M::PlanReadOnly,
            Command::Plan(_) => M::Plan,
            Command::Deploy(args) if args.dry_run && args.saved_plan.is_some() => {
                M::DeploySavedPlanDryRun
            }
            Command::Deploy(args) if args.dry_run => M::DeployDryRun,
            Command::Deploy(_) => M::Deploy,
            Command::Rollback(_) => M::Rollback,
            Command::History(_) => M::History,
            Command::Status(_) => M::Status,
            Command::List(_) => M::List,
            Command::Pin(_) => M::Pin,
            Command::Completions(_) => M::Completions,
            Command::SelfCmd(_) => M::SelfCmd,
            Command::Doctor => M::Doctor,
            Command::Upgrade(_) => M::Upgrade,
            Command::Bundle(_) => M::Bundle,
            Command::Gc(_) => M::Gc,
            Command::Migrate(_) => M::Migrate,
            Command::Export(_) => M::Export,
            Command::Logs(_) => M::Logs,
            Command::PortForward(_) => M::PortForward,
            Command::Snapshot(_) => M::Snapshot,
        })
    }

    /// Return the `-o` formats the command prints, the default first, or
    /// `None` when Kix does not decide.
    ///
    /// `main` refuses any other format before the command runs. Kix passes
    /// any format on to a plugin as `--output`, and the plugin decides.
    pub fn formats(&self) -> Option<&'static [OutputFormat]> {
        self.format_mode().map(FormatMode::formats)
    }

    /// Return the formats that the help of the command at `path`, such as
    /// `compliance sbom`, lists: every format it prints with some flags,
    /// each with the flags it needs, or `None` when the command prints it
    /// without flags. The second value is the default, or `None` for a
    /// command such as `compliance` whose subcommands differ. Return `None`
    /// for a path no mode covers.
    pub fn help_formats(path: &str) -> Option<(Vec<HelpFormat>, Option<OutputFormat>)> {
        let default = modes_at(path)
            .find(|m| under(path, m.path()) && m.flags().is_none())
            .map(|m| m.formats()[0]);
        // Modes that need no flags come first, so that a format one of them
        // lists needs none. A subcommand's mode, as `compliance sbom` is to
        // `compliance`, needs no flags of the command at `path`.
        let (plain, flagged): (Vec<_>, Vec<_>) = modes_at(path)
            .map(|m| {
                let flags = if under(path, m.path()) {
                    m.flags()
                } else {
                    None
                };
                (flags, m.formats())
            })
            .partition(|(flags, _)| flags.is_none());
        let mut formats: Vec<HelpFormat> = Vec::new();
        for (needs, list) in plain.into_iter().chain(flagged) {
            for f in list {
                if !formats.iter().any(|h| h.format == *f) {
                    formats.push(HelpFormat { format: *f, needs });
                }
            }
        }
        (!formats.is_empty()).then_some((formats, default))
    }
}

/// Set up what the command needs, run it, and return how `kix` ends.
pub fn run(cli: &Cli) -> Result<Exit> {
    if cli.command.needs() == Needs::Project {
        prepare_project(cli)?;
        // Deploy and rollback refuse a withdrawn Kix themselves.
        if !matches!(cli.command, Command::Deploy(_) | Command::Rollback(_)) {
            commands::deploy::withdrawn::warn();
        }
    }
    let mut ctx = CommandContext::new(
        &cli.global,
        &commands::compliance::receipt::ComplianceReceipts,
    );
    let ctx = &mut ctx;
    let global = &cli.global;
    match &cli.command {
        Command::Plugin(args) => crate::plugin::run(args, global),
        Command::Completions(args) => commands::completions::run(args, global).map(Exit::from),
        Command::SelfCmd(command) => commands::self_cmd::run(command).map(Exit::from),
        Command::Doctor => commands::doctor::run(global).map(Exit::from),
        Command::Pin(command) => commands::pin::run(command, ctx),
        Command::Upgrade(args) => commands::upgrade::run(args, global),
        Command::Build(args) => commands::build::run(args, ctx).map(Exit::from),
        Command::Diff(args) => commands::diff::run(args, ctx),
        Command::Plan(args) if args.read_only => commands::plan::run_read_only(args, ctx),
        Command::Plan(args) => commands::plan::run(&args.plan, args.out.as_deref(), ctx),
        Command::Check(args) => commands::check::run(args, ctx),
        Command::Deploy(args) => commands::deploy::run(args, ctx),
        Command::Status(args) => commands::status::run(args, ctx),
        Command::List(args) => commands::list::run(args, ctx).map(Exit::from),
        Command::Graph(args) => commands::graph::run(args, ctx).map(Exit::from),
        Command::Bundle(args) => commands::bundle::run(args, ctx).map(Exit::from),
        Command::Gc(args) => commands::gc::run(args, ctx).map(Exit::from),
        Command::Migrate(MigrateCommand::Domain(args)) => {
            commands::migrate::run(args, ctx).map(Exit::from)
        }
        Command::Rollback(args) => commands::rollback::run(args, ctx),
        Command::History(args) => commands::rollback::history(args, ctx).map(Exit::from),
        Command::Export(args) => commands::export::run(args, ctx).map(Exit::from),
        Command::Logs(args) => commands::logs::run(args, ctx).map(Exit::from),
        Command::PortForward(args) => commands::port_forward::run(args, ctx).map(Exit::from),
        Command::Snapshot(args) => commands::snapshot::run(args, ctx).map(Exit::from),
        Command::Compliance(args) => commands::compliance::run(args, ctx).map(Exit::from),
    }
}

/// Check and set up the project for a [`Needs::Project`] command, cheapest
/// check first.
fn prepare_project(cli: &Cli) -> Result<()> {
    // A deploy waits for a person to acknowledge each change to stored data
    // that the last `kix upgrade` found.
    if let Command::Deploy(args) = &cli.command
        && !args.dry_run
        && let Some(dir) = commands::project_dir(&cli.global.flake)
    {
        commands::upgrade::check_deploy(&dir, &args.plan.cluster)?;
    }
    prepare_evaluation(&cli.global, cli.command.cluster_name())
}

/// Set up what an evaluation of the project needs: the Kix library input of
/// `cluster`, the builder, and the runtime.
pub fn prepare_evaluation(global: &crate::cli::GlobalArgs, cluster: Option<&str>) -> Result<()> {
    // Validate the cluster name before the Nix backend starts, which is slow.
    if let Some(name) = cluster {
        validate_cluster_name(name)?;
    }
    // A project with several versions of Kix evaluates with the library of
    // the input this cluster uses.
    if let Some(dir) = commands::project_dir(&global.flake) {
        kix::versions::choose(&dir, cluster).map_err(|e| miette::miette!("{e}"))?;
        warn_unused_override(global);
    }
    // The project's builder decides which Nix every later step runs.
    commands::select_builder(global)?;
    if let Some(dir) = commands::project_dir(&global.flake) {
        require_flake(&dir)?;
    }
    // Stop before any work when Kix has no runtime, or its runtime comes from
    // another release.
    kix::runtime::runtime().map_err(|e| miette::miette!("{e}"))?;
    Ok(())
}

/// Warn when the command overrides the input `kix` and its cluster uses
/// another input, where the override changes nothing.
fn warn_unused_override(global: &crate::cli::GlobalArgs) {
    let Some(chosen) = kix::versions::chosen().filter(|c| c.swap.is_some()) else {
        return;
    };
    let overridden = |name: &str| {
        global
            .override_input
            .chunks_exact(2)
            .any(|pair| pair[0] == name)
    };
    if overridden(kix::flake_lock::INPUT) && !overridden(&chosen.input) {
        eprintln!(
            "warning: ignoring `--override-input kix` because this cluster uses input `{input}` in kix.toml [versions]. Kix will evaluate with `{input}` from flake.lock. Pass `--override-input {input} <url>` to override this cluster's Kix library.",
            input = chosen.input
        );
    }
}

/// Refuse to evaluate `dir` when neither it nor any folder above it holds a
/// `flake.nix`, because Nix would then stop with an error that does not
/// mention `--flake`. A `flake.nix` in a folder above `dir` is left to Nix,
/// which looks for one there itself.
fn require_flake(dir: &std::path::Path) -> Result<()> {
    if dir.ancestors().any(|d| d.join("flake.nix").is_file()) {
        return Ok(());
    }
    Err(miette::miette!(
        "no Kix project found in {dir}: neither it nor any parent directory contains `flake.nix`. Nothing was built or changed.\n\
         Next: run the command from the directory containing your project's `flake.nix`, or pass `--flake <path>`.",
        dir = dir.display()
    ))
}

/// Refuse a cluster name that [`kix::eval::nix::is_valid_cluster_name`]
/// rejects, with a message for the person who typed it.
fn validate_cluster_name(name: &str) -> Result<()> {
    if !kix::eval::nix::is_valid_cluster_name(name) {
        return Err(miette::miette!(
            "'{}' is not a valid cluster name. Use a name like 'example' or 'nw1', not a file path.",
            name
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::FromArgMatches;

    fn needs(args: &[&str]) -> Needs {
        let matches = crate::cli::command()
            .try_get_matches_from(args)
            .expect("arguments parse");
        Cli::from_arg_matches(&matches)
            .expect("arguments convert")
            .command
            .needs()
    }

    /// These commands must run where a project cannot be loaded, so none of
    /// them may wait for the project's builder or the Kix runtime.
    #[test]
    fn commands_that_must_work_without_a_project_need_nothing() {
        for args in [
            &["kix", "status"][..],
            &["kix", "status", "c", "--check", "drift"],
            &["kix", "pin", "list"],
            &["kix", "upgrade"],
            &["kix", "doctor"],
            &["kix", "self", "list"],
            &["kix", "completions", "bash"],
            &["kix", "some-plugin"],
        ] {
            assert_eq!(needs(args), Needs::Nothing, "{args:?}");
        }
    }

    #[test]
    fn commands_that_build_need_the_project() {
        for args in [
            &["kix", "build", "c"][..],
            &["kix", "plan", "c"],
            &["kix", "deploy", "c"],
            &["kix", "history", "c"],
            &["kix", "list", "clusters"],
        ] {
            assert_eq!(needs(args), Needs::Project, "{args:?}");
        }
    }

    fn formats(args: &[&str]) -> Option<&'static [OutputFormat]> {
        let matches = crate::cli::command()
            .try_get_matches_from(args)
            .expect("arguments parse");
        Cli::from_arg_matches(&matches)
            .expect("arguments convert")
            .command
            .formats()
    }

    #[test]
    fn each_command_lists_its_formats_default_first() {
        assert_eq!(formats(&["kix", "build", "c"]), Some(&[Yaml, Json][..]));
        assert_eq!(formats(&["kix", "graph", "c"]).unwrap()[0], Tree);
        assert!(formats(&["kix", "check", "c"]).unwrap().contains(&Sarif));
        assert_eq!(formats(&["kix", "list", "clusters"]), Some(DATA));
        assert_eq!(formats(&["kix", "gc", "c"]), Some(TEXT));
        assert_eq!(formats(&["kix", "history", "c"]), Some(DATA));
        assert_eq!(formats(&["kix", "plan", "c"]), Some(&[Text, Markdown][..]));
        assert!(
            formats(&["kix", "plan", "c", "--read-only"])
                .unwrap()
                .contains(&Json)
        );
        assert_eq!(formats(&["kix", "deploy", "c"]), Some(TEXT));
        assert_eq!(
            formats(&["kix", "deploy", "c", "--dry-run", "--plan", "p.kixplan"]),
            Some(DATA)
        );
        assert_eq!(formats(&["kix", "some-plugin"]), None);
    }

    fn help(
        path: &str,
    ) -> (
        Vec<(OutputFormat, Option<&'static str>)>,
        Option<OutputFormat>,
    ) {
        let (formats, default) = Command::help_formats(path).unwrap();
        let formats = formats.iter().map(|h| (h.format, h.needs)).collect();
        (formats, default)
    }

    /// The help of a command lists every format it prints, its default
    /// first, and the flags each format needs.
    #[test]
    fn help_lists_each_format_with_the_flags_it_needs() {
        assert_eq!(
            help("status"),
            (vec![(Text, None), (Json, None), (Yaml, None)], Some(Text))
        );
        let dry_run = Some("--dry-run");
        let saved = Some("--plan FILE --dry-run");
        assert_eq!(
            help("deploy").0,
            [
                (Text, None),
                (Markdown, dry_run),
                (Json, saved),
                (Yaml, saved)
            ]
        );
        let read_only = Some("--read-only");
        assert_eq!(
            help("plan").0,
            [
                (Text, None),
                (Markdown, None),
                (Json, read_only),
                (Yaml, read_only)
            ]
        );
        assert_eq!(
            help("list clusters").0,
            [(Text, None), (Json, None), (Yaml, None)]
        );
        assert_eq!(
            help("compliance"),
            (vec![(Json, None), (Yaml, None), (Text, None)], None)
        );
    }

    /// A format the help lists without flags is one the command prints
    /// without flags, and one it lists with flags is one the command prints
    /// with exactly those flags. So the help never offers a format that
    /// `main` refuses.
    #[test]
    fn help_agrees_with_what_each_command_accepts() {
        let cases: &[(&str, &[&str])] = &[
            ("deploy", &["kix", "deploy", "c"]),
            ("deploy", &["kix", "deploy", "c", "--dry-run"]),
            (
                "deploy",
                &["kix", "deploy", "c", "--dry-run", "--plan", "p.kixplan"],
            ),
            ("plan", &["kix", "plan", "c"]),
            ("plan", &["kix", "plan", "c", "--read-only"]),
            ("status", &["kix", "status"]),
            ("build", &["kix", "build", "c"]),
        ];
        for (path, argv) in cases {
            let accepted = formats(argv).unwrap();
            let typed = argv.get(3..).unwrap_or_default().join(" ");
            let typed = typed.replace("p.kixplan", "FILE");
            for h in Command::help_formats(path).unwrap().0 {
                let offered = match h.needs {
                    None => true,
                    Some(flags) => {
                        let mut want: Vec<&str> = flags.split(' ').collect();
                        let mut have: Vec<&str> = typed.split(' ').collect();
                        want.sort();
                        have.sort();
                        want == have
                    }
                };
                assert_eq!(
                    offered,
                    accepted.contains(&h.format),
                    "{argv:?}: help says {:?} needs {:?}",
                    h.format,
                    h.needs
                );
            }
        }
    }

    /// Return every visible command path of the clap tree, such as
    /// `compliance sbom`.
    fn command_paths() -> Vec<String> {
        fn walk(cmd: &clap::Command, prefix: &str, out: &mut Vec<String>) {
            for sc in cmd.get_subcommands().filter(|sc| !sc.is_hide_set()) {
                let path = format!("{prefix}{}", sc.get_name()).trim().to_string();
                if sc.get_name() != "help" {
                    out.push(path.clone());
                    walk(sc, &format!("{path} "), out);
                }
            }
        }
        let mut paths = Vec::new();
        walk(&crate::cli::command(), "", &mut paths);
        paths
    }

    /// Every command path has a mode, so its help lists formats, and every
    /// mode names a command path that exists, so no mode's formats are lost
    /// from the help.
    #[test]
    fn modes_and_command_paths_agree() {
        let paths = command_paths();
        for path in &paths {
            assert!(
                modes_at(path).next().is_some(),
                "no format mode for `{path}`"
            );
        }
        for mode in FormatMode::ALL {
            assert!(
                paths.iter().any(|p| p == mode.path()),
                "{mode:?} names `{}`, which is not a command",
                mode.path()
            );
        }
    }

    /// The help shows `-o` exactly on the commands that print more than
    /// text.
    #[test]
    fn output_flag_shows_where_a_command_prints_data() {
        for path in [
            "build",
            "plan",
            "deploy",
            "list clusters",
            "compliance",
            "pin",
        ] {
            assert!(reads_output(path), "{path}");
        }
        for path in ["rollback", "gc", "compliance audit", "self", "doctor"] {
            assert!(!reads_output(path), "{path}");
        }
    }

    #[test]
    fn a_folder_without_a_flake_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let project = root.path().join("prod");
        std::fs::create_dir(&project).unwrap();
        // Skip when a folder above the temporary directory holds a flake.
        if root
            .path()
            .ancestors()
            .any(|d| d.join("flake.nix").is_file())
        {
            return;
        }
        let err = require_flake(root.path()).unwrap_err().to_string();
        assert!(err.contains("--flake <path>"), "{err}");
        std::fs::write(project.join("flake.nix"), "{}").unwrap();
        assert!(require_flake(&project).is_ok());
        let clusters = project.join("clusters");
        std::fs::create_dir(&clusters).unwrap();
        assert!(require_flake(&clusters).is_ok());
    }

    #[test]
    fn a_cluster_name_is_a_plain_word() {
        assert!(validate_cluster_name("nw1").is_ok());
        assert!(validate_cluster_name("homelab-kind_2").is_ok());
        for bad in ["", "../x", "a.b", "a b", "x\"; builtins.exec"] {
            assert!(validate_cluster_name(bad).is_err(), "{bad}");
        }
    }
}
