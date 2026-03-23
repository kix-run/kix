use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

#[test]
fn inspect_default_text() {
    kix()
        .args(["inspect", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Cluster: example"))
        .stdout(predicate::str::contains("Total resources:"))
        .stdout(predicate::str::contains("Resource kinds:"));
}

#[test]
fn inspect_json() {
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
    assert!(parsed["totalResources"].is_number());
    assert!(parsed["namespaces"].is_array());
    assert!(parsed["kindCounts"].is_object());
}

#[test]
fn inspect_yaml() {
    kix()
        .args(["inspect", "example", "-o", "yaml"])
        .assert()
        .success()
        .stdout(predicate::str::contains("cluster: example"));
}

#[test]
fn inspect_nonexistent_fails() {
    kix()
        .args(["inspect", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found"));
}
