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

// --- graph ---

#[test]
fn graph_tree_output() {
    kix()
        .args(["graph", "example"])
        .assert()
        .success()
        .stdout(predicate::str::is_empty().not());
}

#[test]
fn graph_json_output() {
    let output = kix()
        .args(["graph", "example", "--format", "json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert!(parsed["nodes"].is_array(), "should have nodes array");
    assert!(parsed["edges"].is_array(), "should have edges array");
}

#[test]
fn graph_dot_output() {
    kix()
        .args(["graph", "example", "--format", "dot"])
        .assert()
        .success()
        .stdout(predicate::str::contains("digraph"));
}

// --- inspect ---

#[test]
fn inspect_text_output() {
    kix()
        .args(["inspect", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Cluster: example"))
        .stdout(predicate::str::contains("Total resources:"));
}

#[test]
fn inspect_json_output() {
    let output = kix()
        .args(["inspect", "example", "-o", "json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert_eq!(parsed["cluster"], "example");
}

// --- check ---

#[test]
fn check_passes_for_example() {
    kix()
        .args(["check", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("eval"))
        .stdout(predicate::str::contains("pass"));
}

#[test]
fn check_nonexistent_fails() {
    kix()
        .args(["check", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found"));
}

// --- deploy --dry-run ---

#[test]
fn deploy_dry_run() {
    kix()
        .args(["deploy", "example", "--dry-run", "--yes"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Wave"))
        .stdout(predicate::str::contains("Dry run"));
}
