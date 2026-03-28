//! Deploy-specific integration tests.

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    cmd.current_dir(repo_root);
    cmd
}

#[test]
fn deploy_dry_run_shows_plan() {
    kix()
        .args(["deploy", "example", "--dry-run", "--yes"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Deployment plan"))
        .stdout(predicate::str::contains("Wave"))
        .stdout(predicate::str::contains("Dry run"));
}

#[test]
fn apply_alias_works() {
    kix()
        .args(["apply", "example", "--dry-run", "--yes"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Dry run"));
}
