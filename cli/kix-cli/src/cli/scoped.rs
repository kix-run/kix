//! The `clap::Command` for `kix`, with each global flag hidden from the
//! help of the commands that do not read it.

use clap::{CommandFactory, ValueEnum};

use super::{Cli, OutputFormat};

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
            "rollback",
            "history",
            "compliance sbom",
            "compliance attest",
            "pin",
        ],
    ),
    (
        "context",
        &[
            "plan",
            "deploy",
            "status",
            "gc",
            "migrate",
            "rollback",
            "history",
            "logs",
            "port-forward",
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
            "list",
            "graph",
            "gc",
            "migrate",
            "rollback",
            "history",
            "export",
            "logs",
            "port-forward",
            "compliance",
            "pin",
            "doctor",
            "upgrade",
        ],
    ),
    // Only commands that evaluate through the SQLite eval cache.
    (
        "no_cache",
        &["build", "check", "list", "graph", "compliance audit"],
    ),
    (
        "override_input",
        &[
            "build",
            "diff",
            "plan",
            "check",
            "deploy",
            "list",
            "graph",
            "gc",
            "migrate",
            "rollback",
            "history",
            "export",
            "logs",
            "port-forward",
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
    crate::removed::register(
        live_command(),
        crate::removed::COMMANDS,
        crate::removed::FLAGS,
    )
}

/// Build the clap `Command` for `kix` without the stubs of removed commands
/// and flags.
pub(crate) fn live_command() -> clap::Command {
    let cmd = Cli::command();
    let globals: Vec<clap::Arg> = cmd
        .get_arguments()
        .filter(|a| a.is_global_set())
        .cloned()
        .collect();
    let template = help_template(&cmd);
    cmd.mut_subcommands(|sc| hide_unread_globals(sc, "", &globals))
        .help_template(template)
}

/// The headings of `kix --help`, each with its commands in the order listed.
const COMMAND_GROUPS: &[(&str, &[&str])] = &[
    (
        "Build and check (no cluster access)",
        &[
            "check", "build", "graph", "list", "diff", "bundle", "export",
        ],
    ),
    (
        "Preview and deploy",
        &["plan", "deploy", "rollback", "history", "gc"],
    ),
    (
        "Operate",
        &["status", "logs", "port-forward", "snapshot", "migrate"],
    ),
    (
        "Project and installation",
        &[
            "upgrade",
            "self",
            "doctor",
            "pin",
            "compliance",
            "completions",
        ],
    ),
];

/// Return the help template of `kix`, which lists the commands under the
/// headings of [`COMMAND_GROUPS`].
fn help_template(cmd: &clap::Command) -> String {
    let name = |sc: &clap::Command| {
        let aliases: Vec<&str> = sc.get_visible_aliases().collect();
        if aliases.is_empty() {
            sc.get_name().to_string()
        } else {
            format!("{} ({})", sc.get_name(), aliases.join(", "))
        }
    };
    let width = cmd
        .get_subcommands()
        .filter(|sc| !sc.is_hide_set())
        .map(|sc| name(sc).len())
        .max()
        .unwrap_or(0);
    let mut groups = String::new();
    for (heading, names) in COMMAND_GROUPS {
        groups.push_str(&format!("{heading}:\n"));
        for sc in names.iter().filter_map(|n| cmd.find_subcommand(n)) {
            let about = sc.get_about().map(|a| a.to_string()).unwrap_or_default();
            groups.push_str(&format!("  {:width$}  {about}\n", name(sc)));
        }
        groups.push('\n');
    }
    format!(
        "{{about-with-newline}}\n{{usage-heading}} {{usage}}\n\n{groups}Options:\n{{options}}{{after-help}}"
    )
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
        let arg = globals
            .iter()
            .find(|a| a.get_id() == *id)
            .unwrap_or_else(|| panic!("no global flag {id}"));
        if !reads {
            cmd = cmd.arg(arg.clone().hide(true));
        } else if *id == "output"
            && let Some(formats) = crate::cli::Command::help_formats(&path)
        {
            cmd = cmd.arg(
                arg.clone()
                    .value_parser(FormatParser(formats))
                    .help("Output format")
                    .long_help(format!(
                        "Output format. The default is {}.",
                        formats[0].name()
                    )),
            );
        }
    }
    cmd.mut_subcommands(|sc| hide_unread_globals(sc, &path, globals))
}

/// Parse `-o` like the global flag, and list only the formats a command
/// prints in its help and shell completions.
///
/// The other formats still parse, so that `main` refuses them with a message
/// that names the formats the command prints.
#[derive(Clone)]
struct FormatParser(&'static [OutputFormat]);

impl clap::builder::TypedValueParser for FormatParser {
    type Value = OutputFormat;

    fn parse_ref(
        &self,
        cmd: &clap::Command,
        arg: Option<&clap::Arg>,
        value: &std::ffi::OsStr,
    ) -> Result<OutputFormat, clap::Error> {
        clap::builder::EnumValueParser::<OutputFormat>::new().parse_ref(cmd, arg, value)
    }

    fn possible_values(
        &self,
    ) -> Option<Box<dyn Iterator<Item = clap::builder::PossibleValue> + '_>> {
        let shown = self.0.iter();
        let hidden = OutputFormat::value_variants()
            .iter()
            .filter(|f| !self.0.contains(f));
        Some(Box::new(shown.filter_map(|f| f.to_possible_value()).chain(
            hidden.filter_map(|f| f.to_possible_value().map(|v| v.hide(true))),
        )))
    }
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

    /// A command missing from [`COMMAND_GROUPS`] would not appear in
    /// `kix --help`.
    #[test]
    fn help_lists_every_command_under_one_heading() {
        let cmd = Cli::command();
        let mut listed: Vec<&str> = COMMAND_GROUPS
            .iter()
            .flat_map(|(_, names)| names.iter().copied())
            .collect();
        for name in &listed {
            assert!(cmd.find_subcommand(name).is_some(), "no command `{name}`");
        }
        let mut visible: Vec<&str> = cmd
            .get_subcommands()
            .filter(|sc| !sc.is_hide_set())
            .map(|sc| sc.get_name())
            .collect();
        listed.sort();
        visible.sort();
        assert_eq!(listed, visible);
        let help = command().render_long_help().to_string();
        assert!(help.starts_with("Kix is a Kubernetes compiler."), "{help}");
        assert!(help.contains("Preview and deploy:\n  plan "), "{help}");
        assert!(help.contains("  port-forward (pf)  "), "{help}");
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

        // `status` reads only the cluster, so it takes no project flags.
        let status = long_help(&["status"]);
        assert!(status.contains("--context") && status.contains("--output"));
        assert!(!status.contains("--flake"));

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
            .try_get_matches_from(["kix", "--flake", "x", "status"])
            .expect("parses");
        let cli = Cli::from_arg_matches(&matches).expect("converts");
        assert_eq!(cli.global.flake, "x");
    }
}
