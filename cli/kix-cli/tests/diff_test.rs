//! Diff-specific integration tests.

use std::fs;
use std::path::Path;

use assert_cmd::Command;
use predicates::prelude::*;

fn repo_root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
}

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd.current_dir(repo_root());
    cmd
}

#[test]
fn diff_snapshot_against_minimal() {
    let tmp = tempfile::tempdir().unwrap();
    let snapshot_dir = tmp.path().join("snapshot");
    fs::create_dir_all(&snapshot_dir).unwrap();

    kix()
        .args([
            "diff",
            "minimal",
            "--snapshot",
            snapshot_dir.to_str().unwrap(),
        ])
        .assert()
        .code(2)
        .stdout(predicate::str::contains("Only in kix"));
}

#[test]
fn diff_from_self_is_identical() {
    let output = std::process::Command::new("nix")
        .args([
            "build",
            ".#cluster-minimal-activation",
            "--no-link",
            "--print-out-paths",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ])
        .current_dir(repo_root())
        .output()
        .expect("nix build should succeed");

    if !output.status.success() {
        panic!(
            "nix build failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let result_path = String::from_utf8_lossy(&output.stdout).trim().to_string();

    kix()
        .args(["diff", "minimal", "--from", &result_path])
        .assert()
        .success()
        .stdout(predicate::str::contains("No differences"));
}
