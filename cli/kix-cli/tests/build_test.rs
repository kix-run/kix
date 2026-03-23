use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

#[test]
fn build_example_yaml() {
    kix()
        .args(["build", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("apiVersion"))
        .stdout(predicate::str::contains("kind"));
}

#[test]
fn build_example_json() {
    let output = kix()
        .args(["build", "example", "-o", "json"])
        .assert()
        .success()
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert!(parsed.is_array(), "JSON output should be an array");
}

#[test]
fn build_nonexistent_fails() {
    kix()
        .args(["build", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found"));
}

#[test]
fn build_quiet_no_spinner() {
    kix()
        .args(["build", "example", "-q"])
        .assert()
        .success()
        .stderr(predicate::str::is_empty());
}
