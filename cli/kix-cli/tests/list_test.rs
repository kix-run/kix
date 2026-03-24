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
fn list_default() {
    kix()
        .arg("list")
        .assert()
        .success()
        .stdout(predicate::str::contains("example"))
        .stdout(predicate::str::contains("nw1"));
}

#[test]
fn list_json() {
    let output = kix()
        .args(["list", "-o", "json"])
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
fn list_yaml() {
    kix()
        .args(["list", "-o", "yaml"])
        .assert()
        .success()
        .stdout(predicate::str::contains("example"));
}
