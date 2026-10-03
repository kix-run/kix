//! Consolidated CLI smoke tests — one test per command to verify basic functionality.
//! These invoke the real binary with `assert_cmd`, so they require Nix FFI.

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    // Tests must never reach for the user's kubeconfig and hit a real
    // cluster. Pin to /dev/null so any stray client call fails fast.
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
fn list_clusters() {
    kix()
        .args(["list", "clusters"])
        .assert()
        .success()
        .stdout(predicate::str::contains("example"));
}

#[test]
fn build_yaml() {
    kix()
        .args(["build", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("apiVersion"));
}

#[test]
fn check_passes() {
    kix()
        .args(["check", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("pass"));
}

#[test]
fn graph_tree() {
    kix()
        .args(["graph", "example"])
        .assert()
        .success()
        .stdout(predicate::str::is_empty().not());
}

#[test]
fn inspect_text() {
    kix()
        .args(["inspect", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Cluster: example"));
}

/// `deploy --dry-run` is `kix plan`. With `--current-activation` it compares
/// two builds offline, says so, and exits 2 because the plan has changes.
#[test]
fn deploy_dry_run() {
    kix()
        .args([
            "deploy",
            "example",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .code(2)
        .stdout(predicate::str::contains("Plan:"))
        .stdout(predicate::str::contains("Two builds compared"));
}

#[test]
fn nonexistent_cluster_fails() {
    kix()
        .args(["build", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found").or(predicate::str::contains("not a valid")));
}
