//! Deploy-specific integration tests.

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    // Belt-and-braces: tests must never reach for the user's kubeconfig and
    // hit a real cluster. `--current-activation --dry-run` should be
    // entirely offline, but if any future change introduces a stray client
    // call we'd rather fail fast against `/dev/null` than auth against
    // whatever cluster the developer happens to be pointed at.
    cmd.env("KUBECONFIG", "/dev/null");
    cmd.env_remove("KUBE_CONTEXT");
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
        .args([
            "deploy",
            "example",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Plan:"))
        .stdout(predicate::str::contains("Dry run"));
}

#[test]
fn apply_alias_works() {
    kix()
        .args([
            "apply",
            "example",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Dry run"));
}
