use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

#[test]
fn check_example_passes() {
    kix()
        .args(["check", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("eval"))
        .stdout(predicate::str::contains("pass"));
}

#[test]
fn check_json() {
    let output = kix()
        .args(["check", "example", "-o", "json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert!(parsed.is_array(), "JSON output should be an array");
    let arr = parsed.as_array().unwrap();
    assert!(!arr.is_empty(), "should have at least one check result");
    assert_eq!(arr[0]["tool"], "eval");
}

#[test]
fn check_yaml() {
    kix()
        .args(["check", "example", "-o", "yaml"])
        .assert()
        .success()
        .stdout(predicate::str::contains("tool: eval"));
}

#[test]
fn check_nonexistent_fails() {
    kix()
        .args(["check", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found"));
}
