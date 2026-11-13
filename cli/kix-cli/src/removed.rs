//! Refuse commands and flags that a release removed or renamed.
//!
//! A removed command or flag keeps working for at least one minor release as
//! a refusal: Kix prints what replaces it and the id of the change record
//! that removed it, and exits with [`Exit::Failure`]. To remove one, add it to
//! [`COMMANDS`] or [`FLAGS`]. `cli::command` registers each as a hidden stub,
//! so clap still parses it, `kix <old command>` does not go looking for a
//! plugin, and `--help` does not list it.

use clap::parser::ValueSource;
use clap::{Arg, ArgAction, ArgMatches};

use crate::exit::Exit;

/// Commands that a release removed.
pub const COMMANDS: &[RemovedCommand] = &[
    RemovedCommand {
        name: "health",
        removed: Removed {
            old: "kix health <cluster>",
            new: "kix status <cluster> --check presence",
            id: STATUS_MERGE,
            note: "",
        },
    },
    RemovedCommand {
        name: "drift",
        removed: Removed {
            old: "kix drift",
            new: "kix status [cluster] --check drift",
            id: STATUS_MERGE,
            note: "",
        },
    },
    RemovedCommand {
        name: "apply",
        removed: Removed {
            old: "kix apply",
            new: "kix deploy",
            id: "K9947",
            note: "",
        },
    },
    RemovedCommand {
        name: "inspect",
        removed: Removed {
            old: "kix inspect",
            new: "kix list resources",
            id: "K0450",
            note: "",
        },
    },
    RemovedCommand {
        name: "images",
        removed: Removed {
            old: "kix images",
            new: "kix list images",
            id: "K0450",
            note: "",
        },
    },
    RemovedCommand {
        name: "snapshot save",
        removed: Removed {
            old: "kix snapshot save CLUSTER DIR",
            new: "kix snapshot CLUSTER --out DIR",
            id: "K2314",
            note: "",
        },
    },
    RemovedCommand {
        name: "self update",
        removed: Removed {
            old: "kix self update",
            new: "kix self upgrade",
            id: "K4616",
            note: "",
        },
    },
];

/// `kix bundle CLUSTER FILE`, which names the file with a positional
/// argument.
pub const BUNDLE_FILE: Removed = Removed {
    old: "kix bundle CLUSTER FILE",
    new: "kix bundle CLUSTER --out FILE",
    id: "K2314",
    note: "",
};

/// `kix diff CLUSTER` with neither a bundle nor a build to compare against,
/// which compared the build with the live cluster.
pub const DIFF_WITHOUT_BASELINE: Removed = Removed {
    old: "kix diff CLUSTER",
    new: "kix plan CLUSTER --read-only",
    id: "K3143",
    note: "`kix diff` now only compares two builds, and needs `--from`, `--from-bundle`, or `--bundle`.",
};

/// Flags that a release removed from a command.
pub const FLAGS: &[RemovedFlag] = &[
    RemovedFlag {
        command: "plan",
        long: "current-activation",
        takes_value: false,
        removed: Removed {
            old: "kix plan --current-activation",
            new: "kix plan --offline",
            id: "K3428",
            note: "",
        },
    },
    RemovedFlag {
        command: "plan",
        long: "prune-mode",
        takes_value: true,
        removed: Removed {
            old: "kix plan --prune-mode",
            new: "kix plan --skip-orphan-check",
            id: "K4285",
            note: "For `--prune-mode default`, leave the flag out.",
        },
    },
    RemovedFlag {
        command: "deploy",
        long: "current-activation",
        takes_value: false,
        removed: Removed {
            old: "kix deploy --current-activation",
            new: "kix deploy --offline",
            id: "K3428",
            note: "",
        },
    },
    RemovedFlag {
        command: "deploy",
        long: "prune-mode",
        takes_value: true,
        removed: Removed {
            old: "kix deploy --prune-mode",
            new: "kix deploy --skip-orphan-check",
            id: "K4285",
            note: "For `--prune-mode default`, leave the flag out.",
        },
    },
    RemovedFlag {
        command: "plan",
        long: "save",
        takes_value: true,
        removed: Removed {
            old: "kix plan --save FILE",
            new: "kix plan --out FILE",
            id: "K2314",
            note: "",
        },
    },
    RemovedFlag {
        command: "diff",
        long: "save",
        takes_value: true,
        removed: Removed {
            old: "kix diff --save FILE",
            new: "kix diff --out FILE",
            id: "K2314",
            note: "",
        },
    },
    RemovedFlag {
        command: "deploy",
        long: "tui",
        takes_value: false,
        removed: Removed {
            old: "kix deploy --tui",
            new: "kix deploy --log-format tui",
            id: "K5429",
            note: "",
        },
    },
    RemovedFlag {
        command: "deploy",
        long: "group-by-ns",
        takes_value: false,
        removed: Removed {
            old: "kix deploy --group-by-ns",
            new: "kix deploy --group-by namespace",
            id: "K5429",
            note: "",
        },
    },
    RemovedFlag {
        command: "deploy",
        long: "fold-height",
        takes_value: true,
        removed: Removed {
            old: "kix deploy --fold-height N",
            new: "KIX_TUI_HEIGHT=N kix deploy",
            id: "K5429",
            note: "",
        },
    },
    RemovedFlag {
        command: "rollback",
        long: "list",
        takes_value: false,
        removed: Removed {
            old: "kix rollback CLUSTER --list",
            new: "kix history CLUSTER",
            id: "K5914",
            note: "",
        },
    },
    RemovedFlag {
        command: "gc",
        long: "hard",
        takes_value: false,
        removed: Removed {
            old: "kix gc --hard",
            new: "kix gc --full-scan",
            id: "K9205",
            note: "",
        },
    },
    RemovedFlag {
        command: "gc",
        long: "include-unstamped",
        takes_value: false,
        removed: Removed {
            old: "kix gc --include-unstamped",
            new: "kix gc --full-scan --include unstamped",
            id: "K9205",
            note: "",
        },
    },
    RemovedFlag {
        command: "gc",
        long: "include-unattributed",
        takes_value: false,
        removed: Removed {
            old: "kix gc --include-unattributed",
            new: "kix gc --full-scan --include unattributed",
            id: "K9205",
            note: "",
        },
    },
    RemovedFlag {
        command: "gc",
        long: "include-copies",
        takes_value: false,
        removed: Removed {
            old: "kix gc --include-copies",
            new: "kix gc --full-scan --include copies",
            id: "K9205",
            note: "",
        },
    },
    RemovedFlag {
        command: "list packages",
        long: "cluster",
        takes_value: true,
        removed: Removed {
            old: "kix list packages --cluster CLUSTER",
            new: "kix list packages CLUSTER",
            id: "K0450",
            note: "",
        },
    },
    RemovedFlag {
        command: "export",
        long: "for",
        takes_value: true,
        removed: Removed {
            old: "kix export --for",
            new: "kix export --with-kix-metadata",
            id: "K6794",
            note: "That keeps Kix's annotations and records, as `--for audit` did. For `--for exit`, leave the flag out.",
        },
    },
    RemovedFlag {
        command: "upgrade",
        long: "preview",
        takes_value: false,
        removed: Removed {
            old: "kix upgrade --preview",
            new: "kix upgrade --dry-run",
            id: "K4616",
            note: "",
        },
    },
    RemovedFlag {
        command: "upgrade",
        long: "ack",
        takes_value: true,
        removed: Removed {
            old: "kix upgrade --ack ID",
            new: "kix upgrade --acknowledge ID",
            id: "K4616",
            note: "",
        },
    },
    RemovedFlag {
        command: "check",
        long: "sarif",
        takes_value: false,
        removed: Removed {
            old: "kix check --sarif",
            new: "kix check -o sarif",
            id: "K0719",
            note: "",
        },
    },
    RemovedFlag {
        command: "graph",
        long: "format",
        takes_value: true,
        removed: Removed {
            old: "kix graph --format",
            new: "kix graph -o tree|dot|json",
            id: "K4721",
            note: "",
        },
    },
    RemovedFlag {
        command: "status",
        long: "operator",
        takes_value: false,
        removed: Removed {
            old: "kix status --operator",
            new: "kix status <cluster>",
            id: STATUS_MERGE,
            note: "",
        },
    },
];

/// The id of the change record that merged `kix health` and `kix drift`
/// into `kix status`. The refusal prints it as `[K6116]`.
const STATUS_MERGE: &str = "K6116";

/// What a user typed that no longer works, and what to type instead.
#[derive(Debug, PartialEq, Eq)]
pub struct Removed {
    /// The old form as the user would type it, such as `kix gc --hard`.
    pub old: &'static str,
    /// The form that replaces it, such as `kix gc --full-scan`.
    pub new: &'static str,
    /// The id of the change record that removed it, such as `K1234`.
    pub id: &'static str,
    /// A sentence to add after the replacement, or "".
    pub note: &'static str,
}

/// A removed command, such as `kix health` or `kix self update`.
#[derive(Debug)]
pub struct RemovedCommand {
    /// The command path, such as `health` or `self update`.
    pub name: &'static str,
    pub removed: Removed,
}

/// A removed flag of one command.
#[derive(Debug)]
pub struct RemovedFlag {
    /// The command path that took the flag, such as `gc` or
    /// `compliance audit`.
    pub command: &'static str,
    /// The long name without dashes, such as `hard`.
    pub long: &'static str,
    /// Whether the flag took a value. A stub that takes no value would leave
    /// the value to a positional argument.
    pub takes_value: bool,
    pub removed: Removed,
}

impl Removed {
    /// Return the line that tells the user what to type instead.
    pub fn message(&self) -> String {
        let message = format!(
            "[{}] `{}` was removed. Use `{}` instead.",
            self.id, self.old, self.new
        );
        if self.note.is_empty() {
            message
        } else {
            format!("{message} {}", self.note)
        }
    }

    /// Print the refusal and return the exit for a command line Kix no
    /// longer accepts.
    pub fn refuse(&self) -> Exit {
        eprintln!("{} {}", crate::output::red("error:"), self.message());
        Exit::Failure
    }
}

/// Add a hidden stub to `cmd` for each command in `commands` and each flag in
/// `flags`.
pub fn register(
    mut cmd: clap::Command,
    commands: &[RemovedCommand],
    flags: &[RemovedFlag],
) -> clap::Command {
    for c in commands {
        let words: Vec<&'static str> = c.name.split(' ').collect();
        cmd = add_command(cmd, &words);
    }
    for f in flags {
        let words: Vec<&str> = f.command.split(' ').collect();
        cmd = add_flag(cmd, &words, f);
    }
    cmd
}

fn add_command(cmd: clap::Command, path: &[&'static str]) -> clap::Command {
    match path {
        [] => cmd,
        [name] => cmd.subcommand(
            clap::Command::new(*name)
                .hide(true)
                .disable_help_flag(true)
                .arg(
                    Arg::new("args")
                        .num_args(0..)
                        .trailing_var_arg(true)
                        .allow_hyphen_values(true),
                ),
        ),
        [word, rest @ ..] => cmd.mut_subcommands(|sc| {
            if sc.get_name() == *word {
                // A stub below a command that takes required arguments, such
                // as `snapshot save`, must parse without them.
                let takes_arguments = sc.get_arguments().any(|a| a.is_required_set());
                add_command(sc.subcommand_negates_reqs(takes_arguments), rest)
            } else {
                sc
            }
        }),
    }
}

fn add_flag(cmd: clap::Command, path: &[&str], flag: &RemovedFlag) -> clap::Command {
    match path.split_first() {
        // `mut_subcommand` would move the command to the end of the list,
        // which reorders completions and the CLI surface snapshot.
        Some((word, rest)) => cmd.mut_subcommands(|sc| {
            if sc.get_name() == *word {
                add_flag(sc, rest, flag)
            } else {
                sc
            }
        }),
        None => {
            let arg = Arg::new(flag_id(flag)).long(flag.long).hide(true);
            cmd.arg(if flag.takes_value {
                arg.action(ArgAction::Set)
            } else {
                arg.action(ArgAction::SetTrue)
            })
        }
    }
}

/// Return the id of a flag's stub, which differs from the id of any live
/// argument.
fn flag_id(flag: &RemovedFlag) -> &'static str {
    // clap ids are `&'static str` without its `string` feature. The process
    // builds the command line a handful of times, so the leak stays small.
    Box::leak(format!("removed-{}", flag.long).into_boxed_str())
}

/// Return the removed form that a parsed command uses, for the forms that
/// [`find`] cannot see: a removed positional argument, and `kix diff` with
/// nothing to compare against.
pub fn refused(command: &crate::cli::Command) -> Option<&'static Removed> {
    use crate::cli::Command;
    match command {
        Command::Bundle(args) if args.removed_file.is_some() => Some(&BUNDLE_FILE),
        Command::Diff(args)
            if args.from.is_none() && args.from_bundle.is_none() && args.bundle.is_none() =>
        {
            Some(&DIFF_WITHOUT_BASELINE)
        }
        _ => None,
    }
}

/// Return the removed command or flag that `matches` uses, if any.
pub fn find<'a>(
    matches: &ArgMatches,
    commands: &'a [RemovedCommand],
    flags: &'a [RemovedFlag],
) -> Option<&'a Removed> {
    let used = |path: &str| {
        let mut m = matches;
        for word in path.split(' ') {
            m = m.subcommand_matches(word)?;
        }
        Some(m)
    };
    if let Some(c) = commands.iter().find(|c| used(c.name).is_some()) {
        return Some(&c.removed);
    }
    flags.iter().find_map(|f| {
        let m = used(f.command)?;
        (m.value_source(flag_id(f)) == Some(ValueSource::CommandLine)).then_some(&f.removed)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::FromArgMatches;

    const COMMANDS: &[RemovedCommand] = &[RemovedCommand {
        name: "lint",
        removed: Removed {
            old: "kix lint",
            new: "kix check",
            id: "K9001",
            note: "",
        },
    }];

    const FLAGS: &[RemovedFlag] = &[
        RemovedFlag {
            command: "gc",
            long: "everything",
            takes_value: false,
            removed: Removed {
                old: "kix gc --everything",
                new: "kix gc --full-scan",
                id: "K9002",
                note: "",
            },
        },
        RemovedFlag {
            command: "compliance audit",
            long: "dir",
            takes_value: true,
            removed: Removed {
                old: "kix compliance audit --dir",
                new: "kix compliance audit --out",
                id: "K9003",
                note: "",
            },
        },
    ];

    fn command() -> clap::Command {
        register(crate::cli::live_command(), COMMANDS, FLAGS)
    }

    fn found(args: &[&str]) -> Option<&'static str> {
        let matches = command().try_get_matches_from(args).expect("parses");
        find(&matches, COMMANDS, FLAGS).map(|r| r.id)
    }

    #[test]
    fn the_refusal_names_the_replacement_and_the_change_record() {
        let message = FLAGS[0].removed.message();
        assert!(message.starts_with("[K9002] "), "{message}");
        assert!(message.contains("`kix gc --full-scan`"), "{message}");
        assert_eq!(FLAGS[0].removed.refuse(), Exit::Failure);
    }

    /// Without the stub, clap would hand `kix lint` to the plugin lookup.
    #[test]
    fn a_removed_command_is_refused_before_the_plugin_lookup() {
        assert_eq!(found(&["kix", "lint", "c", "--help"]), Some("K9001"));
        assert_eq!(found(&["kix", "-q", "lint"]), Some("K9001"));
        assert_eq!(found(&["kix", "status", "c"]), None);
    }

    #[test]
    fn a_removed_flag_is_found_on_its_command() {
        assert_eq!(found(&["kix", "gc", "c", "--everything"]), Some("K9002"));
        assert_eq!(found(&["kix", "gc", "c"]), None);
        assert_eq!(
            found(&["kix", "compliance", "audit", "--dir", "out", "c"]),
            Some("K9003")
        );
    }

    /// The stub takes the old flag's value, so the positional argument still
    /// parses and the command line reaches the refusal.
    #[test]
    fn a_removed_flag_keeps_its_value_away_from_positionals() {
        let matches = command()
            .try_get_matches_from(["kix", "compliance", "audit", "--dir", "out", "c"])
            .expect("parses");
        let cli = crate::cli::Cli::from_arg_matches(&matches).expect("converts");
        let crate::cli::Command::Compliance(args) = cli.command else {
            panic!("not compliance");
        };
        let crate::cli::ComplianceCommand::Audit(audit) = args.command else {
            panic!("not audit");
        };
        assert_eq!(audit.cluster, "c");
    }

    #[test]
    fn the_old_format_flags_are_refused() {
        let found = |args: &[&str]| {
            let matches = crate::cli::command()
                .try_get_matches_from(args)
                .expect("parses");
            find(&matches, super::COMMANDS, super::FLAGS).map(|r| r.id)
        };
        assert_eq!(found(&["kix", "check", "c", "--sarif"]), Some("K0719"));
        assert_eq!(
            found(&["kix", "graph", "c", "--format", "dot"]),
            Some("K4721")
        );
        assert_eq!(found(&["kix", "graph", "c", "-o", "dot"]), None);
        let messages: Vec<String> = super::FLAGS.iter().map(|f| f.removed.message()).collect();
        assert!(
            messages.iter().any(|m| m.starts_with("[K0719] ")),
            "{messages:?}"
        );
        assert!(
            messages.iter().any(|m| m.starts_with("[K4721] ")),
            "{messages:?}"
        );
    }

    #[test]
    fn stubs_stay_out_of_help() {
        let help = command().render_long_help().to_string();
        assert!(!help.contains("lint"), "{help}");
        let mut gc = command();
        let gc = gc.find_subcommand_mut("gc").expect("gc");
        assert!(!gc.render_long_help().to_string().contains("everything"));
    }

    /// A stub must not shadow a live command or flag.
    #[test]
    fn the_real_stubs_do_not_shadow_live_commands() {
        let live = crate::cli::live_command();
        for c in super::COMMANDS {
            let mut cmd = Some(&live);
            for word in c.name.split(' ') {
                cmd = cmd.and_then(|cmd| cmd.find_subcommand(word));
            }
            assert!(cmd.is_none(), "{}", c.name);
        }
        register(live, super::COMMANDS, super::FLAGS).debug_assert();
    }

    fn refused_id(args: &[&str]) -> Option<&'static str> {
        let matches = crate::cli::command()
            .try_get_matches_from(args)
            .expect("parses");
        if let Some(r) = find(&matches, super::COMMANDS, super::FLAGS) {
            return Some(r.id);
        }
        let cli = crate::cli::Cli::from_arg_matches(&matches).expect("converts");
        refused(&cli.command).map(|r| r.id)
    }

    /// Each renamed command and flag of 0.10 is refused with its record's id,
    /// and its replacement parses.
    #[test]
    fn the_0_10_renames_are_refused() {
        for (old, new, id) in [
            (
                &["kix", "apply", "c"][..],
                &["kix", "deploy", "c"][..],
                "[K9947]",
            ),
            (
                &["kix", "inspect", "c"],
                &["kix", "list", "resources", "c"],
                "[K0450]",
            ),
            (
                &["kix", "images", "c", "--sources"],
                &["kix", "list", "images", "c", "--sources"],
                "[K0450]",
            ),
            (
                &["kix", "list", "packages", "--cluster", "c"],
                &["kix", "list", "packages", "c"],
                "[K0450]",
            ),
            (
                &["kix", "snapshot", "save", "c", "d"],
                &["kix", "snapshot", "c", "--out", "d"],
                "[K2314]",
            ),
            (
                &["kix", "bundle", "c", "f"],
                &["kix", "bundle", "c", "--out", "f"],
                "[K2314]",
            ),
            (
                &["kix", "plan", "c", "--save", "f"],
                &["kix", "plan", "c", "--out", "f"],
                "[K2314]",
            ),
            (
                &["kix", "diff", "c", "--from", "x", "--save", "f"],
                &["kix", "diff", "c", "--from", "x", "--out", "f"],
                "[K2314]",
            ),
            (
                &["kix", "diff", "c"],
                &["kix", "plan", "c", "--read-only"],
                "[K3143]",
            ),
            (
                &["kix", "plan", "c", "--current-activation"],
                &["kix", "plan", "c", "--offline"],
                "[K3428]",
            ),
            (
                &["kix", "deploy", "c", "--current-activation"],
                &["kix", "deploy", "c", "--offline"],
                "[K3428]",
            ),
            (
                &["kix", "deploy", "c", "--prune-mode", "no"],
                &["kix", "deploy", "c", "--skip-orphan-check"],
                "[K4285]",
            ),
            (
                &["kix", "deploy", "c", "--tui"],
                &["kix", "deploy", "c", "--log-format", "tui"],
                "[K5429]",
            ),
            (
                &["kix", "deploy", "c", "--group-by-ns"],
                &["kix", "deploy", "c", "--group-by", "namespace"],
                "[K5429]",
            ),
            (
                &["kix", "deploy", "c", "--fold-height", "9"],
                &["kix", "deploy", "c"],
                "[K5429]",
            ),
            (
                &["kix", "rollback", "c", "--list"],
                &["kix", "history", "c"],
                "[K5914]",
            ),
            (
                &["kix", "gc", "c", "--hard"],
                &["kix", "gc", "c", "--full-scan"],
                "[K9205]",
            ),
            (
                &["kix", "gc", "c", "--hard", "--include-unstamped"],
                &[
                    "kix",
                    "gc",
                    "c",
                    "--full-scan",
                    "--include",
                    "unstamped,copies",
                ],
                "[K9205]",
            ),
            (
                &["kix", "export", "c", "--for", "audit"],
                &["kix", "export", "c", "--with-kix-metadata"],
                "[K6794]",
            ),
            (
                &["kix", "self", "update"],
                &["kix", "self", "upgrade"],
                "[K4616]",
            ),
            (
                &["kix", "upgrade", "--preview"],
                &["kix", "upgrade", "--dry-run"],
                "[K4616]",
            ),
            (
                &["kix", "upgrade", "--ack", "m"],
                &["kix", "upgrade", "--acknowledge", "m"],
                "[K4616]",
            ),
        ] {
            assert_eq!(
                refused_id(old).map(|id| format!("[{id}]")).as_deref(),
                Some(id),
                "{old:?}"
            );
            assert_eq!(refused_id(new), None, "{new:?}");
        }
    }
}
