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
fn graph_default_tree() {
    kix()
        .args(["graph", "example"])
        .assert()
        .success()
        // Stats go to stderr, not stdout
        .stderr(predicate::str::contains("resources,"));
}

#[test]
fn graph_format_dot() {
    kix()
        .args(["graph", "example", "--format", "dot"])
        .assert()
        .success()
        .stdout(predicate::str::contains("digraph kix"))
        .stdout(predicate::str::contains("rankdir=LR"));
}

#[test]
fn graph_format_json() {
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
fn graph_format_tree() {
    // Explicit --format tree should work the same as default
    kix()
        .args(["graph", "example", "--format", "tree"])
        .assert()
        .success();
}

#[test]
fn graph_global_json_fallback() {
    // When --format is not set, -o json should produce JSON output
    let output = kix()
        .args(["graph", "example", "-o", "json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert!(parsed["nodes"].is_array());
}

#[test]
fn graph_nonexistent_fails() {
    kix()
        .args(["graph", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found"));
}

#[test]
fn graph_quiet_suppresses_stats() {
    kix()
        .args(["graph", "example", "-q"])
        .assert()
        .success()
        .stderr(predicate::str::is_empty());
}
