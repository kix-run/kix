//! Run the parsed command.
//!
//! Each command declares what it needs in [`Command::needs`] and the formats
//! it prints in [`FORMATS`], and [`run`] sets that up before one `match`
//! calls the command. `needs`, `run`, and the command path that `FORMATS` is
//! read by are exhaustive matches, so a new command does not compile until it
//! says what it needs, where its formats are, and how it runs.

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

/// The `-o` formats of every command, the default first. Each row is a
/// command path, the flags that change the formats as a user types them (as
/// [`Command::format_flags`] returns them), and the formats.
///
/// This is the one list of formats. [`Command::formats`] reads the row of
/// the command a user ran, and [`Command::help_formats`] gives the help every
/// row of a command.
const FORMATS: &[(&str, &str, &[OutputFormat])] = &[
    ("build", "", &[Yaml, Json]),
    ("check", "", &[Text, Json, Yaml, Sarif]),
    ("graph", "", &[Tree, Dot, Json, Yaml]),
    ("diff", "", &[Text, Json, Yaml, Markdown]),
    // A plan is data only as a saved plan file (`--out`).
    ("plan", "", &[Text, Markdown]),
    ("plan", " --read-only", &[Text, Json, Yaml, Markdown]),
    ("deploy", "", TEXT),
    ("deploy", " --dry-run", &[Text, Markdown]),
    ("deploy", " --plan FILE --dry-run", DATA),
    ("rollback", "", TEXT),
    ("history", "", DATA),
    ("status", "", DATA),
    ("list", "", DATA),
    ("pin", "", DATA),
    ("compliance sbom", "", &[Json, Yaml]),
    ("compliance attest", "", &[Json, Yaml]),
    ("compliance audit", "", TEXT),
    ("completions", "", TEXT),
    ("self", "", TEXT),
    ("doctor", "", TEXT),
    ("upgrade", "", TEXT),
    ("bundle", "", TEXT),
    ("gc", "", TEXT),
    ("migrate", "", TEXT),
    ("export", "", TEXT),
    ("logs", "", TEXT),
    ("port-forward", "", TEXT),
    ("snapshot", "", TEXT),
];

/// Return whether `path` is `row` or one of its subcommands, such as
/// `list clusters` for `list`.
fn under(path: &str, row: &str) -> bool {
    path == row
        || path
            .strip_prefix(row)
            .is_some_and(|rest| rest.starts_with(' '))
}

impl Command {
    /// Return the `-o` formats the command prints, the default first, or
    /// `None` when Kix does not decide.
    ///
    /// `main` refuses any other format before the command runs. A plugin
    /// reads `KIX_OUTPUT` itself, so Kix passes any format on.
    pub fn formats(&self) -> Option<&'static [OutputFormat]> {
        let path = self.format_path()?;
        let flags = self.format_flags();
        let row = |flags: &str| {
            FORMATS
                .iter()
                .find(|(p, f, _)| under(path, p) && *f == flags)
                .map(|(_, _, formats)| *formats)
        };
        Some(row(flags).or_else(|| row("")).unwrap_or(TEXT))
    }

    /// Return the command path that [`FORMATS`] lists the command under, or
    /// `None` for a plugin.
    fn format_path(&self) -> Option<&'static str> {
        Some(match self {
            Command::Plugin(_) => return None,
            Command::Compliance(args) => match args.command {
                ComplianceCommand::Sbom(_) => "compliance sbom",
                ComplianceCommand::Attest(_) => "compliance attest",
                ComplianceCommand::Audit(_) => "compliance audit",
            },
            Command::Build(_) => "build",
            Command::Check(_) => "check",
            Command::Graph(_) => "graph",
            Command::Diff(_) => "diff",
            Command::Plan(_) => "plan",
            Command::Deploy(_) => "deploy",
            Command::Rollback(_) => "rollback",
            Command::History(_) => "history",
            Command::Status(_) => "status",
            Command::List(_) => "list",
            Command::Pin(_) => "pin",
            Command::Completions(_) => "completions",
            Command::SelfCmd(_) => "self",
            Command::Doctor => "doctor",
            Command::Upgrade(_) => "upgrade",
            Command::Bundle(_) => "bundle",
            Command::Gc(_) => "gc",
            Command::Migrate(_) => "migrate",
            Command::Export(_) => "export",
            Command::Logs(_) => "logs",
            Command::PortForward(_) => "port-forward",
            Command::Snapshot(_) => "snapshot",
        })
    }

    /// Return the formats that the help of the command at `path`, such as
    /// `compliance sbom`, lists: every format it prints with some flags. The
    /// second value is the default, or `None` for a command such as
    /// `compliance` whose subcommands differ. Return `None` for a path
    /// [`FORMATS`] does not list.
    pub fn help_formats(path: &str) -> Option<(Vec<OutputFormat>, Option<OutputFormat>)> {
        let rows: Vec<&(&str, &str, &[OutputFormat])> = FORMATS
            .iter()
            .filter(|(row, _, _)| under(path, row) || under(row, path))
            .collect();
        let mut formats: Vec<OutputFormat> = Vec::new();
        for f in rows.iter().flat_map(|(_, _, formats)| formats.iter()) {
            if !formats.contains(f) {
                formats.push(*f);
            }
        }
        let default = rows
            .iter()
            .find(|(row, flags, _)| under(path, row) && flags.is_empty())
            .map(|(_, _, formats)| formats[0]);
        (!formats.is_empty()).then_some((formats, default))
    }

    /// Return the flags that changed [`Command::formats`], as a user types
    /// them, so that a refusal names the command the user ran.
    pub fn format_flags(&self) -> &'static str {
        match self {
            Command::Deploy(args) if args.dry_run && args.saved_plan.is_some() => {
                " --plan FILE --dry-run"
            }
            Command::Deploy(args) if args.dry_run => " --dry-run",
            Command::Plan(args) if args.read_only => " --read-only",
            _ => "",
        }
    }

    /// Return advice to add when the command refuses a format.
    pub fn format_hint(&self) -> Option<String> {
        let plan = || {
            format!(
                "To keep the plan as data, write it with `--out FILE.{}`. \
                 `kix plan --read-only -o json` prints a read-only plan as JSON, and \
                 `kix deploy --plan FILE --dry-run -o json` compares a saved plan with the cluster.",
                kix::plan::file::EXTENSION
            )
        };
        match self {
            Command::Plan(_) => Some(plan()),
            Command::Deploy(args) if args.dry_run && args.saved_plan.is_none() => Some(plan()),
            Command::Deploy(args) if !args.dry_run => {
                Some("`--log-format json` prints the deploy as JSON lines.".to_string())
            }
            _ => None,
        }
    }
}

/// Set up what the command needs, run it, and return how `kix` ends.
pub fn run(cli: &Cli) -> Result<Exit> {
    if cli.command.needs() == Needs::Project {
        prepare_project(cli)?;
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
        Command::Upgrade(args) => commands::upgrade::run(args, global).map(Exit::from),
        Command::Build(args) => commands::build::run(args, ctx).map(Exit::from),
        Command::Diff(args) => commands::diff::run(args, ctx),
        Command::Plan(args) if args.read_only => commands::diff::run_read_only(args, ctx),
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
        commands::upgrade::check_deploy(&dir)?;
    }
    // Validate the cluster name before the Nix backend starts, which is slow.
    if let Some(name) = cli.command.cluster_name() {
        validate_cluster_name(name)?;
    }
    // The project's builder decides which Nix every later step runs.
    commands::select_builder(&cli.global)?;
    // Stop before any work when Kix has no runtime, or its runtime comes from
    // another release.
    kix::runtime::runtime().map_err(|e| miette::miette!("{e}"))?;
    Ok(())
}

/// Validate cluster name format.
///
/// SECURITY: This is the primary defense against Nix expression injection.
/// The cluster name is spliced into the flake attribute `nix eval` reads
/// (`kix::eval::nix`) and into the `--apply` expression of `nix eval`
/// (`cluster_name_command`).
/// Only alphanumeric characters, hyphens, and underscores are safe.
fn validate_cluster_name(name: &str) -> Result<()> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
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
            &["kix", "secret", "hash", "f.sops.yaml"],
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

    /// The help of a command lists every format it prints with some flags,
    /// and its default first.
    #[test]
    fn help_lists_the_formats_of_every_mode() {
        let (status, default) = Command::help_formats("status").unwrap();
        assert_eq!((status, default), (DATA.to_vec(), Some(Text)));
        let (deploy, _) = Command::help_formats("deploy").unwrap();
        assert_eq!(deploy, [Text, Markdown, Json, Yaml]);
        let (list, _) = Command::help_formats("list clusters").unwrap();
        assert_eq!(list, DATA);
        let (compliance, default) = Command::help_formats("compliance").unwrap();
        assert_eq!((compliance, default), (vec![Json, Yaml, Text], None));
    }

    /// Every command has a row in [`FORMATS`], so none falls back to text
    /// unnoticed.
    #[test]
    fn every_command_has_formats() {
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
        for path in paths {
            assert!(
                FORMATS
                    .iter()
                    .any(|(row, _, _)| under(&path, row) || under(row, &path)),
                "no formats for `{path}`"
            );
        }
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
