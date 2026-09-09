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

/// An empty manifest directory is a cluster with nothing on it: every
/// package is added.
#[test]
fn diff_from_empty_manifest_dir_adds_everything() {
    let tmp = tempfile::tempdir().unwrap();
    let snapshot_dir = tmp.path().join("snapshot");
    fs::create_dir_all(&snapshot_dir).unwrap();

    kix()
        .args(["diff", "minimal", "--from", snapshot_dir.to_str().unwrap()])
        .assert()
        .code(2)
        .stdout(predicate::str::contains("added"));
}

/// `kix export --for audit` writes the build as a manifest directory in
/// the layout `kix snapshot save` uses. Diffing the build against its own
/// export exercises the whole flat-side path — loading, synthesis, the
/// package-grouped diff — with no cluster, and must come back clean.
#[test]
fn diff_from_own_audit_export_is_identical() {
    let tmp = tempfile::tempdir().unwrap();
    let export_dir = tmp.path().join("export");

    kix()
        .args([
            "export",
            "minimal",
            "--for",
            "audit",
            "--out",
            export_dir.to_str().unwrap(),
        ])
        .assert()
        .success();

    kix()
        .args(["diff", "minimal", "--from", export_dir.to_str().unwrap()])
        .assert()
        .success()
        .stdout(predicate::str::contains("No differences"));
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
