//! `kix explain` run as a binary. Needs no Nix, runtime, or project.
//!
//! The records built into the test binary are the repository's, which may
//! hold no record with an id, so these tests cover the refusals and how
//! `main` prints them. `commands::explain`'s unit tests cover a found
//! record and the hint with fixture records.

use assert_cmd::Command;
use predicates::prelude::*;

fn kix(dir: &tempfile::TempDir) -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true")
        .env("KIX_DATA_DIR", dir.path())
        .env_remove("KIX_SELECTED_BY")
        .env_remove("KIX_FLAKE")
        .current_dir(dir.path());
    cmd
}

#[test]
fn explain_refuses_an_unknown_id() {
    let dir = tempfile::tempdir().unwrap();
    kix(&dir)
        .args(["explain", "[k9999]"])
        .assert()
        .code(1)
        .stdout(predicate::str::is_empty())
        .stderr(predicate::str::starts_with("Error: "))
        .stderr(predicate::str::contains("has no change record K9999"))
        .stderr(predicate::str::contains("kix explain").not());
}

#[test]
fn explain_refuses_a_text_that_is_no_id() {
    let dir = tempfile::tempdir().unwrap();
    kix(&dir)
        .args(["explain", "replicaCount"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "'replicaCount' is not a change record id. An id is K and four digits, such as K0001.",
        ));
}

#[test]
fn explain_is_listed_in_help() {
    let dir = tempfile::tempdir().unwrap();
    kix(&dir)
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("explain"));
}
