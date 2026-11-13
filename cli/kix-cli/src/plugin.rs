//! External subcommand dispatch (`kix <NAME> <ARGS>...` runs `kix-<NAME>` from `PATH`).
//!
//! `kix` replaces its own process with the plugin executable so the plugin's
//! exit status and signal handling apply directly. Global flags passed before
//! `<NAME>` are forwarded via their corresponding `KIX_*` environment
//! variables (`KIX_FLAKE`, `KIX_CONTEXT`, `KIX_OUTPUT`, and others on
//! `GlobalArgs`), and `--no-color` is forwarded as `NO_COLOR`. `KIX_BIN` is
//! set to the path of the current `kix` binary so the plugin can invoke the
//! exact same version.

use std::ffi::{OsStr, OsString};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

use clap::ValueEnum;

use crate::cli::{self, GlobalArgs};
use crate::exit::Exit;

/// Execute the external plugin named by `args`, replacing the current process.
/// Returns only if the plugin cannot be found or executed.
pub fn run(args: &[OsString], global: &GlobalArgs) -> miette::Result<Exit> {
    let (name, rest) = args.split_first().expect("clap passes the name first");
    let path = std::env::var_os("PATH").unwrap_or_default();
    let Some(program) = name.to_str().and_then(|name| find(name, &path)) else {
        // Re-parse with external subcommands disabled so clap emits its
        // standard unknown-subcommand error and "did you mean" suggestion.
        let error = cli::command()
            .allow_external_subcommands(false)
            .external_subcommand_value_parser(clap::builder::Resettable::Reset)
            .try_get_matches()
            .expect_err("clap accepted an unknown command");
        return Ok(crate::exit::clap_error(&error));
    };
    if let Some(value) = global
        .override_input
        .iter()
        .find(|v| v.is_empty() || v.contains(char::is_whitespace))
    {
        return Err(miette::miette!(
            "cannot pass --override-input {value:?} to a plugin: KIX_OVERRIDE_INPUT separates values with spaces, so a value can't be empty or hold one"
        ));
    }
    let kix = std::env::current_exe().map_err(|e| {
        miette::miette!(
            "could not resolve the path to `kix` while starting {}: {e}",
            program.display()
        )
    })?;
    let error = command(&program, rest, global, &kix).exec();
    // The file exists, so `NotFound` from `exec` indicates a missing `#!` interpreter.
    let hint = match error.kind() {
        std::io::ErrorKind::NotFound => " (is its #! interpreter installed?)",
        _ => "",
    };
    Err(miette::miette!(
        "could not run {}: {error}{hint}",
        program.display()
    ))
}

/// Find the first executable `kix-<name>` in an absolute directory of `path`.
///
/// Rejects names containing characters other than ASCII letters, digits, `-`,
/// and `_`, and skips relative `PATH` entries so `kix ../x` cannot execute
/// paths outside `PATH`.
fn find(name: &str, path: &OsStr) -> Option<PathBuf> {
    let word = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !word {
        return None;
    }
    std::env::split_paths(path)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join(format!("kix-{name}")))
        .find(|file| {
            file.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

/// Build the [`std::process::Command`] for `program`, forwarding global flags
/// via the environment variables `kix` reads them from.
fn command(
    program: &Path,
    args: &[OsString],
    global: &GlobalArgs,
    kix: &Path,
) -> std::process::Command {
    let output = global.output.map(|format| {
        format
            .to_possible_value()
            .expect("no output format is skipped")
            .get_name()
            .to_owned()
    });
    let vars = [
        ("KIX_OUTPUT", output),
        ("KIX_VERBOSE", Some(global.verbose.to_string())),
        ("KIX_QUIET", Some(global.quiet.to_string())),
        ("KIX_CONTEXT", global.context.clone()),
        ("KIX_FLAKE", Some(global.flake.clone())),
        ("KIX_NO_CACHE", Some(global.no_cache.to_string())),
        (
            "KIX_OVERRIDE_INPUT",
            (!global.override_input.is_empty()).then(|| global.override_input.join(" ")),
        ),
        ("NO_COLOR", global.no_color.then(|| "1".to_owned())),
    ];
    let mut command = std::process::Command::new(program);
    // A `kix` the plugin runs is a new command, which selects its own Kix.
    command
        .args(args)
        .env("KIX_BIN", kix)
        .env_remove(crate::select::SELECTED_BY_VAR);
    for (var, value) in vars {
        if let Some(value) = value {
            command.env(var, value);
        }
    }
    command
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::FromArgMatches;

    /// Return the environment variables `command` sets for `argv`, and the
    /// ones it removes.
    fn changes(argv: &[&str]) -> (Vec<(String, String)>, Vec<String>) {
        let matches = cli::command().get_matches_from(argv);
        let global = cli::Cli::from_arg_matches(&matches).unwrap().global;
        let text = |s: &OsStr| s.to_str().unwrap().to_owned();
        let mut set = Vec::new();
        let mut removed = Vec::new();
        for (k, v) in command(Path::new("/p/kix-x"), &[], &global, Path::new("/p/kix")).get_envs() {
            match v {
                Some(v) => set.push((text(k), text(v))),
                None => removed.push(text(k)),
            }
        }
        (set, removed)
    }

    /// Return the environment variables set by `command` for `argv`.
    fn vars(argv: &[&str]) -> Vec<(String, String)> {
        changes(argv).0
    }

    #[test]
    fn a_plugin_selects_its_own_kix_again() {
        assert_eq!(changes(&["kix", "x"]).1, [crate::select::SELECTED_BY_VAR]);
    }

    // Verify that every global flag is forwarded to plugins via an environment
    // variable (`--no-color` maps to `NO_COLOR`, and `--override-input` maps to
    // `KIX_OVERRIDE_INPUT`).
    #[test]
    fn every_global_flag_reaches_a_plugin() {
        let set = vars(&[
            "kix",
            "-vv",
            "-q",
            "--no-color",
            "--no-cache",
            "-o",
            "json",
            "--context",
            "c",
            "--flake",
            "f",
            "--override-input",
            "a",
            "u",
            "x",
        ]);
        for arg in cli::command().get_arguments().filter(|a| a.is_global_set()) {
            let var = match arg.get_id().as_str() {
                "no_color" => "NO_COLOR",
                // Read in `main`: see `override_input_from_env`.
                "override_input" => "KIX_OVERRIDE_INPUT",
                id => arg
                    .get_env()
                    .unwrap_or_else(|| panic!("the global flag {id} has no environment variable"))
                    .to_str()
                    .unwrap(),
            };
            assert!(
                set.iter().any(|(k, _)| k == var),
                "{var} is not passed: {set:?}"
            );
        }
    }

    #[test]
    fn unset_flags_are_left_out() {
        let set = vars(&["kix", "x"]);
        let get = |var: &str| set.iter().find(|(k, _)| k == var).map(|(_, v)| v.as_str());
        assert_eq!(get("KIX_BIN"), Some("/p/kix"));
        for unset in [
            "KIX_OUTPUT",
            "KIX_CONTEXT",
            "KIX_OVERRIDE_INPUT",
            "NO_COLOR",
        ] {
            assert_eq!(get(unset), None, "{unset}");
        }
    }

    #[test]
    fn only_a_plain_word_names_a_plugin() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("kix-x");
        std::fs::write(&file, "").unwrap();
        let path = std::env::join_paths(["relative", dir.path().to_str().unwrap()]).unwrap();
        assert_eq!(find("x", &path), None, "not executable");
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(find("x", &path), Some(file));
        for name in ["", "../x", "x/y", "x y"] {
            assert_eq!(find(name, &path), None, "{name:?}");
        }
    }
}
