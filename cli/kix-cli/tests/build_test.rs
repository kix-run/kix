use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    // Run from the repo root so the flake is found
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    cmd.current_dir(repo_root);
    cmd
}

/// Check if FFI evaluation is available (requires Nix C libraries).
fn ffi_available() -> bool {
    let output = Command::cargo_bin("kix")
        .unwrap()
        .env("NO_COLOR", "true")
        .current_dir(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .unwrap()
                .parent()
                .unwrap(),
        )
        .args(["list"])
        .output();
    matches!(output, Ok(o) if o.status.success())
}

#[test]
fn build_example_yaml() {
    if !ffi_available() {
        eprintln!("skipping: FFI not available");
        return;
    }
    kix()
        .args(["build", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("apiVersion"))
        .stdout(predicate::str::contains("kind"));
}

#[test]
fn build_example_json() {
    if !ffi_available() {
        eprintln!("skipping: FFI not available");
        return;
    }
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
        .stderr(predicate::str::contains("not found").or(predicate::str::contains("not a valid")));
}

#[test]
fn build_quiet_no_spinner() {
    if !ffi_available() {
        eprintln!("skipping: FFI not available");
        return;
    }
    kix()
        .args(["build", "example", "-q"])
        .assert()
        .success()
        .stderr(predicate::str::is_empty());
}
