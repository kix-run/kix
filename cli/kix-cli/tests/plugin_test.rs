//! `kix NAME` runs the plugin `kix-NAME` from PATH. These tests put shell
//! scripts on PATH as plugins, so they need no Nix and no cluster.

mod common;

use std::path::Path;

use assert_cmd::Command;
use predicates::prelude::*;

/// Writes an executable `kix-NAME` into `dir`.
fn plugin(dir: &Path, name: &str, body: &str) {
    let file = dir.join(format!("kix-{name}"));
    common::write_executable(&file, format!("#!/bin/sh\n{body}\n"));
}

/// `kix`, with `dir` first on PATH.
fn kix(dir: &Path) -> Command {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let path = std::env::join_paths(
        std::iter::once(dir.to_path_buf()).chain(std::env::split_paths(&path)),
    )
    .unwrap();
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("PATH", path).env("KUBECONFIG", "/dev/null");
    for var in [
        "KIX_OUTPUT",
        "KIX_VERBOSE",
        "KIX_QUIET",
        "KIX_CONTEXT",
        "KIX_FLAKE",
        "KIX_NO_CACHE",
        "KIX_OVERRIDE_INPUT",
        "NO_COLOR",
    ] {
        cmd.env_remove(var);
    }
    cmd
}

/// A plugin that prints its arguments and the variables kix sets.
const SHOW: &str = r#"printf 'arg %s\n' "$@"
for v in KIX_OUTPUT KIX_VERBOSE KIX_QUIET KIX_CONTEXT KIX_FLAKE KIX_NO_CACHE KIX_OVERRIDE_INPUT NO_COLOR; do
  eval "printf '%s=%s\n' $v \"\${$v-unset}\""
done"#;

const FLAGS: &[&str] = &[
    "-vv",
    "-q",
    "--no-color",
    "--no-cache",
    "-o",
    "json",
    "--context",
    "ctx",
    "--flake",
    "github:o/r",
    "--override-input",
    "a",
    "path:/a",
    "--override-input",
    "b",
    "path:/b",
];

const SHOWN: &str = "arg --output
arg json
arg one
arg --two
arg -o
KIX_OUTPUT=unset
KIX_VERBOSE=2
KIX_QUIET=true
KIX_CONTEXT=ctx
KIX_FLAKE=github:o/r
KIX_NO_CACHE=true
KIX_OVERRIDE_INPUT=a path:/a b path:/b
NO_COLOR=1
";

/// The flags before the plugin's name become variables, except `-o`, which
/// comes first in the plugin's arguments as `--output FORMAT`. The arguments
/// after the name reach the plugin unchanged, flags included.
#[test]
fn a_plugin_gets_its_arguments_and_the_global_flags() {
    let dir = tempfile::tempdir().unwrap();
    plugin(dir.path(), "show", SHOW);
    kix(dir.path())
        .args(FLAGS)
        .args(["show", "one", "--two", "-o"])
        .assert()
        .success()
        .stdout(SHOWN);
}

/// A kix the plugin runs reads the variables, so it has the user's flags
/// without being given any: here it passes them on, unchanged, to a second
/// plugin. The format reaches the second plugin because the first passes its
/// arguments on.
#[test]
fn a_kix_the_plugin_runs_has_the_same_flags() {
    let dir = tempfile::tempdir().unwrap();
    plugin(dir.path(), "show", SHOW);
    plugin(dir.path(), "outer", r#"exec "$KIX_BIN" show "$@""#);
    kix(dir.path())
        .args(FLAGS)
        .args(["outer", "one", "--two", "-o"])
        .assert()
        .success()
        .stdout(SHOWN);
}

#[test]
fn the_plugin_exit_status_is_kix_exit_status() {
    let dir = tempfile::tempdir().unwrap();
    plugin(dir.path(), "fail", "echo failed >&2; exit 7");
    kix(dir.path())
        .arg("fail")
        .assert()
        .code(7)
        .stderr("failed\n");
}

/// A name that is neither a command nor a plugin gets clap's usual error.
#[test]
fn an_unknown_command_is_still_an_error() {
    let dir = tempfile::tempdir().unwrap();
    kix(dir.path())
        .arg("deplyo")
        .assert()
        .code(1)
        .stderr(predicate::str::contains("unrecognized subcommand 'deplyo'"))
        .stderr(predicate::str::contains("deploy"));
}

/// A switch's variable is off for `false`, `0`, `no`, `off` or empty, and
/// on for any other value.
#[test]
fn a_switch_variable_takes_the_usual_values() {
    let dir = tempfile::tempdir().unwrap();
    plugin(dir.path(), "show", SHOW);
    for (value, set) in [
        ("1", "true"),
        ("yes", "true"),
        ("0", "false"),
        ("no", "false"),
        ("", "false"),
    ] {
        kix(dir.path())
            .env("KIX_QUIET", value)
            .env("KIX_NO_CACHE", value)
            .arg("show")
            .assert()
            .success()
            .stdout(predicate::str::contains(format!("KIX_QUIET={set}\n")))
            .stdout(predicate::str::contains(format!("KIX_NO_CACHE={set}\n")));
    }
}

/// `--override-input` keeps a value with a space whole, as it always did.
/// The variable can't carry such a value, or an empty one, so kix refuses
/// to pass either to a plugin.
#[test]
fn an_override_the_variable_cannot_carry_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    plugin(dir.path(), "show", SHOW);
    for value in ["path:/x y", ""] {
        kix(dir.path())
            .args(["--override-input", "a", value, "show"])
            .assert()
            .failure()
            .stderr(predicate::str::contains(format!(
                "cannot pass --override-input {value:?} to a plugin"
            )));
    }
}

#[test]
fn override_input_in_the_variable_must_be_pairs() {
    let dir = tempfile::tempdir().unwrap();
    plugin(dir.path(), "show", SHOW);
    kix(dir.path())
        .env("KIX_OVERRIDE_INPUT", "a")
        .arg("show")
        .assert()
        .failure()
        .stderr(predicate::str::contains("pairs of an input name and a URL"));
}
