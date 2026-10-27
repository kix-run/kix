//! Consolidated CLI smoke tests — one test per command to verify basic functionality.
//! These invoke the real binary with `assert_cmd`, so they require `nix`.

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    // Tests must never reach for the user's kubeconfig and hit a real
    // cluster. Pin to /dev/null so any stray client call fails fast.
    cmd.env("KUBECONFIG", "/dev/null");
    cmd.env_remove("KUBE_CONTEXT");
    let repo_root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    cmd.current_dir(repo_root);
    cmd
}

#[test]
fn list_clusters() {
    kix()
        .args(["list", "clusters"])
        .assert()
        .success()
        .stdout(predicate::str::contains("example"));
}

#[test]
fn build_yaml() {
    kix()
        .args(["build", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("apiVersion"));
}

#[test]
fn check_passes() {
    kix()
        .args(["check", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("pass"));
}

#[test]
fn graph_tree() {
    kix()
        .args(["graph", "example"])
        .assert()
        .success()
        .stdout(predicate::str::is_empty().not());
}

#[test]
fn inspect_text() {
    kix()
        .args(["inspect", "example"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Cluster: example"));
}

/// `deploy --dry-run` is `kix plan`. With `--current-activation` it compares
/// two builds offline, says so, and exits 2 because the plan has changes.
#[test]
fn deploy_dry_run() {
    kix()
        .args([
            "deploy",
            "example",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .code(2)
        .stdout(predicate::str::contains("Plan:"))
        .stdout(predicate::str::contains("Two builds compared"));
}

/// `kix bundle` reads back what it writes, so a build the bundle reader
/// would refuse fails here.
#[test]
fn bundle_reads_back() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("example.kixbundle");
    kix()
        .args(["bundle", "example"])
        .arg(&file)
        .assert()
        .success();
    kix()
        .args(["graph", "example", "--bundle"])
        .arg(&file)
        .assert()
        .success();
}

/// Every cluster `kix list clusters` names makes a bundle that reads back
/// as the build it was written from: `kix bundle` refuses one whose graph
/// differs from the result directory's. Builds every test cluster, about
/// ten minutes, so it runs only when asked: `cargo test -p kix-cli --test
/// commands_test -- --ignored every_test_cluster_bundles`.
#[test]
#[ignore]
fn every_test_cluster_bundles() {
    let listed = kix()
        .args(["list", "clusters", "-o", "json"])
        .output()
        .unwrap();
    assert!(listed.status.success());
    let clusters: Vec<String> = serde_json::from_slice(&listed.stdout).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mut failed = Vec::new();
    for name in &clusters {
        let out = kix()
            .args(["--quiet", "bundle", name])
            .arg(dir.path().join(format!("{name}.kixbundle")))
            .output()
            .unwrap();
        if !out.status.success() {
            failed.push(format!("{name}: {}", String::from_utf8_lossy(&out.stderr)));
        }
    }
    assert!(!clusters.is_empty());
    assert!(failed.is_empty(), "{}", failed.join("\n"));
}

/// An instance that names one resource under two parts still makes a
/// bundle `kix bundle` reads back.
#[test]
fn bundle_reads_back_an_aliased_resource() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("bundle-alias.kixbundle");
    kix()
        .args(["bundle", "bundle-alias"])
        .arg(&file)
        .assert()
        .success();
}

/// A platform that hosts a consumer, and the consumer, which renders no
/// Namespace for the namespaces the platform creates, each make a bundle
/// `kix bundle` reads back.
#[test]
fn bundle_reads_back_a_platform_and_its_consumer() {
    let dir = tempfile::tempdir().unwrap();
    for name in ["consumers-platform", "consumers-acme"] {
        kix()
            .args(["bundle", name])
            .arg(dir.path().join(format!("{name}.kixbundle")))
            .assert()
            .success();
    }
}

#[test]
fn nonexistent_cluster_fails() {
    kix()
        .args(["build", "nonexistent"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not found").or(predicate::str::contains("not a valid")));
}
