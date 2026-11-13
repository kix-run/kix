//! Refuse commands and flags that a release removed or renamed.
//!
//! A removed command or flag keeps working for at least one minor release as
//! a refusal: Kix prints what replaces it and the id of the change record
//! that removed it, and exits with [`Exit::Usage`]. To remove one, add it to
//! [`COMMANDS`] or [`FLAGS`]. `cli::command` registers each as a hidden stub,
//! so clap still parses it, `kix <old command>` does not go looking for a
//! plugin, and `--help` does not list it.

use clap::parser::ValueSource;
use clap::{Arg, ArgAction, ArgMatches};

use crate::exit::Exit;

/// Top-level commands that a release removed.
pub const COMMANDS: &[RemovedCommand] = &[];

/// Flags that a release removed from a command.
pub const FLAGS: &[RemovedFlag] = &[];

/// What a user typed that no longer works, and what to type instead.
#[derive(Debug, PartialEq, Eq)]
pub struct Removed {
    /// The old form as the user would type it, such as `kix gc --hard`.
    pub old: &'static str,
    /// The form that replaces it, such as `kix gc --full-scan`.
    pub new: &'static str,
    /// The id of the change record that removed it, such as `K1234`.
    pub id: &'static str,
}

/// A removed top-level command, such as `kix health`.
#[derive(Debug)]
pub struct RemovedCommand {
    /// The command word, such as `health`.
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
        format!(
            "[{}] `{}` was removed. Use `{}` instead.",
            self.id, self.old, self.new
        )
    }

    /// Print the refusal and return the exit for a command line Kix no
    /// longer accepts.
    pub fn refuse(&self) -> Exit {
        eprintln!("{} {}", crate::output::red("error:"), self.message());
        Exit::Usage
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
        cmd = cmd.subcommand(
            clap::Command::new(c.name)
                .hide(true)
                .disable_help_flag(true)
                .arg(
                    Arg::new("args")
                        .num_args(0..)
                        .trailing_var_arg(true)
                        .allow_hyphen_values(true),
                ),
        );
    }
    for f in flags {
        let words: Vec<&str> = f.command.split(' ').collect();
        cmd = add_flag(cmd, &words, f);
    }
    cmd
}

fn add_flag(cmd: clap::Command, path: &[&str], flag: &RemovedFlag) -> clap::Command {
    match path.split_first() {
        Some((word, rest)) => cmd.mut_subcommand(*word, |sc| add_flag(sc, rest, flag)),
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

/// Return the removed command or flag that `matches` uses, if any.
pub fn find<'a>(
    matches: &ArgMatches,
    commands: &'a [RemovedCommand],
    flags: &'a [RemovedFlag],
) -> Option<&'a Removed> {
    if let Some(name) = matches.subcommand_name()
        && let Some(c) = commands.iter().find(|c| c.name == name)
    {
        return Some(&c.removed);
    }
    flags.iter().map(|f| (f, &f.removed)).find_map(|(f, r)| {
        let mut m = matches;
        for word in f.command.split(' ') {
            m = m.subcommand_matches(word)?;
        }
        (m.value_source(flag_id(f)) == Some(ValueSource::CommandLine)).then_some(r)
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
            },
        },
    ];

    fn command() -> clap::Command {
        register(crate::cli::command(), COMMANDS, FLAGS)
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
        assert_eq!(FLAGS[0].removed.refuse(), Exit::Usage);
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
        let live = crate::cli::command();
        for c in super::COMMANDS {
            assert!(live.find_subcommand(c.name).is_none(), "{}", c.name);
        }
        register(live, super::COMMANDS, super::FLAGS).debug_assert();
    }
}
