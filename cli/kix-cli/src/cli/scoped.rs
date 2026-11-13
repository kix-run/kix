//! The `clap::Command` for `kix`, with each global flag hidden from the
//! help of the commands that do not read it.

use clap::CommandFactory;

use super::Cli;

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
            "lib",
            "doctor",
            "upgrade",
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
}
