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
fn diff_nonexistent_cluster() {
    let tmp = tempfile::tempdir().unwrap();
    let snapshot_dir = tmp.path().join("snapshot");
    fs::create_dir_all(&snapshot_dir).unwrap();

    kix()
        .args([
            "diff",
            "nonexistent-cluster-xyz",
            "--snapshot",
            snapshot_dir.to_str().unwrap(),
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("nonexistent-cluster-xyz"));
}

#[test]
fn diff_snapshot_against_minimal() {
    // Diff minimal cluster against an empty snapshot — all resources should be kix-only.
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
    // Build-to-build diff of minimal against itself — should show no differences.
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

#[test]
fn diff_json_output() {
    let tmp = tempfile::tempdir().unwrap();
    let snapshot_dir = tmp.path().join("snapshot");
    fs::create_dir_all(&snapshot_dir).unwrap();

    let output = kix()
        .args([
            "diff",
            "minimal",
            "--snapshot",
            snapshot_dir.to_str().unwrap(),
            "-o",
            "json",
        ])
        .assert()
        .code(2)
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert!(parsed["packages"].is_object(), "should have packages field");
    assert!(
        parsed["resources"].is_object(),
        "should have resources field"
    );
    assert!(
        !parsed["resources"]["kix_only"].as_array().unwrap().is_empty(),
        "should report kix-only resources"
    );
}
