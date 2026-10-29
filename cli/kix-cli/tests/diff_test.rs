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

/// Verify that diffing against an empty manifest directory adds every package.
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

/// Verify that diffing a build against its own `kix export --for audit`
/// manifest directory exercises the flat-side path (loading, synthesis, and
/// the package-grouped diff) without a cluster and reports no differences.
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

fn fixture_bundle(name: &str) -> std::path::PathBuf {
    repo_root().join(format!("cli/kix-bundle/tests/fixtures/{name}.kixbundle"))
}

/// Verify that `kix diff --bundle --from-bundle` compares two bundled builds
/// without a flake or cluster and writes the plan document of two builds.
#[test]
fn diff_of_a_bundle_against_itself_is_identical() {
    let bundle = fixture_bundle("kix-enterprise-test");
    let out = kix()
        .env("KUBECONFIG", "/dev/null")
        .args([
            "-o",
            "json",
            "diff",
            "kix-enterprise-test",
            "--detail",
            "fields",
        ])
        .arg("--bundle")
        .arg(&bundle)
        .arg("--from-bundle")
        .arg(&bundle)
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let doc: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(doc["made_by"], "builds");
    assert_eq!(doc["cluster"], "kix-enterprise-test");
    assert_eq!(doc["packages"]["added"], serde_json::json!([]));
}

/// Verify that `--bundle` alone compares against an empty baseline and adds every package.
#[test]
fn diff_of_a_bundle_alone_adds_everything() {
    let out = kix()
        .env("KUBECONFIG", "/dev/null")
        .args(["-o", "json", "diff", "kix-enterprise-test", "--bundle"])
        .arg(fixture_bundle("kix-enterprise-test"))
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let doc: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(doc["made_by"], "builds");
    assert!(!doc["packages"]["added"].as_array().unwrap().is_empty());
    assert_eq!(doc["deployed"], serde_json::Value::Null);
}

/// Verify that `--from-bundle` rejects a bundle built for a different cluster.
#[test]
fn diff_refuses_a_from_bundle_of_another_cluster() {
    kix()
        .env("KUBECONFIG", "/dev/null")
        .args(["diff", "kix-enterprise-test", "--bundle"])
        .arg(fixture_bundle("kix-enterprise-test"))
        .arg("--from-bundle")
        .arg(fixture_bundle("immich"))
        .assert()
        .failure()
        .stderr(predicate::str::contains("not 'kix-enterprise-test'"));
}

/// Verify that `--from-bundle` rejects a bundle whose content does not match its store paths.
#[test]
fn diff_refuses_a_from_bundle_that_does_not_verify() {
    let bundle = fixture_bundle("kix-enterprise-test");
    let tmp = tempfile::tempdir().unwrap();
    let broken = tmp.path().join("broken.kixbundle");
    let mut bytes = fs::read(&bundle).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 1;
    fs::write(&broken, bytes).unwrap();
    kix()
        .env("KUBECONFIG", "/dev/null")
        .args(["diff", "kix-enterprise-test", "--bundle"])
        .arg(&bundle)
        .arg("--from-bundle")
        .arg(&broken)
        .assert()
        .failure()
        .stderr(predicate::str::contains("cannot use the bundle"));
}

/// Verify that `kix diff --save` writes a plan file whose plan matches `-o json
/// --detail fields` and whose graph matches `kix graph`.
#[test]
fn diff_save_writes_the_document_and_the_graph() {
    let bundle = fixture_bundle("kix-enterprise-test");
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("diff.kixplan");
    let out = kix()
        .env("KUBECONFIG", "/dev/null")
        .args([
            "-o",
            "json",
            "diff",
            "kix-enterprise-test",
            "--detail",
            "fields",
        ])
        .arg("--bundle")
        .arg(&bundle)
        .arg("--save")
        .arg(&path)
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(2),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let printed: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let (mut file, _) = kix::plan::file::PlanFile::verify(fs::File::open(&path).unwrap()).unwrap();
    let header = file.header().clone();
    assert_eq!(serde_json::to_value(&header.plan).unwrap(), printed);

    let graph = kix()
        .args([
            "graph",
            "kix-enterprise-test",
            "--format",
            "json",
            "--bundle",
        ])
        .arg(&bundle)
        .output()
        .unwrap();
    assert!(
        graph.status.success(),
        "{}",
        String::from_utf8_lossy(&graph.stderr)
    );
    let graph: serde_json::Value = serde_json::from_slice(&graph.stdout).unwrap();
    assert_eq!(serde_json::to_value(&header.graph).unwrap(), graph);

    // Every object of the build is added, so each has a new manifest only.
    // The Activation record is the one the plan names under `activation`.
    assert_eq!(header.shown.len() + 1, header.graph.nodes.len());
    for (id, shown) in &header.shown {
        assert!(shown.old.is_none(), "{id}");
        assert!(file.new_manifest(id).unwrap().is_some(), "{id}");
    }
}
