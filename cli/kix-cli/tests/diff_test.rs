use std::fs;

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

/// Create a temp dir with a `result/` subdir containing a YAML manifest
/// and a `snapshot/` subdir. Returns the temp dir path.
fn setup_fixture(
    kix_manifests: &[serde_json::Value],
    cluster_manifests: &[serde_json::Value],
) -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();

    // Write kix-side manifests into result/
    let result_dir = tmp.path().join("result");
    fs::create_dir_all(&result_dir).unwrap();
    for manifest in kix_manifests {
        let rid = resource_filename(manifest);
        let yaml = serde_yml::to_string(manifest).unwrap();
        fs::write(result_dir.join(&rid), yaml).unwrap();
    }

    // Write cluster-side manifests into snapshot/
    let snapshot_dir = tmp.path().join("snapshot");
    fs::create_dir_all(&snapshot_dir).unwrap();
    for manifest in cluster_manifests {
        let rid = resource_filename(manifest);
        let yaml = serde_yml::to_string(manifest).unwrap();
        fs::write(snapshot_dir.join(&rid), yaml).unwrap();
    }

    tmp
}

fn resource_filename(manifest: &serde_json::Value) -> String {
    let kind = manifest["kind"]
        .as_str()
        .unwrap_or("Unknown")
        .to_lowercase();
    let ns = manifest["metadata"]["namespace"]
        .as_str()
        .unwrap_or("_cluster");
    let name = manifest["metadata"]["name"].as_str().unwrap_or("unknown");
    format!("{ns}--{name}-{kind}.yaml")
}

fn ns_manifest() -> serde_json::Value {
    serde_json::json!({
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": { "name": "test" }
    })
}

fn configmap_manifest(key: &str, value: &str) -> serde_json::Value {
    serde_json::json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": { "name": "app-config", "namespace": "test" },
        "data": { key: value }
    })
}

#[test]
fn diff_matching_snapshot_exits_0() {
    let ns = ns_manifest();
    let tmp = setup_fixture(std::slice::from_ref(&ns), std::slice::from_ref(&ns));

    kix()
        .args(["diff", "example", "--snapshot", "snapshot"])
        .current_dir(tmp.path())
        .assert()
        .success()
        .stdout(predicate::str::contains("No differences"));
}

#[test]
fn diff_modified_snapshot_exits_2() {
    let ns = ns_manifest();
    let cm_kix = configmap_manifest("key", "value-kix");
    let cm_cluster = configmap_manifest("key", "value-cluster");

    let tmp = setup_fixture(&[ns.clone(), cm_kix], &[ns, cm_cluster]);

    kix()
        .args(["diff", "example", "--snapshot", "snapshot"])
        .current_dir(tmp.path())
        .assert()
        .code(2);
}

#[test]
fn diff_json_output() {
    let ns = ns_manifest();
    let cm_kix = configmap_manifest("key", "value-kix");
    let cm_cluster = configmap_manifest("key", "value-cluster");

    let tmp = setup_fixture(&[ns.clone(), cm_kix], &[ns, cm_cluster]);

    let output = kix()
        .args(["diff", "example", "--snapshot", "snapshot", "-o", "json"])
        .current_dir(tmp.path())
        .assert()
        .code(2)
        .get_output()
        .stdout
        .clone();

    let parsed: serde_json::Value =
        serde_json::from_slice(&output).expect("stdout should be valid JSON");
    assert!(parsed["summary"].is_object(), "should have summary field");
    assert!(
        parsed["summary"]["modified"].as_u64().unwrap() > 0,
        "should report modified resources"
    );
}

#[test]
fn diff_nonexistent_cluster() {
    // Use an empty temp dir with no result/ directory — diff should fail
    // because there's no build output to compare against.
    let tmp = tempfile::tempdir().unwrap();
    let snapshot_dir = tmp.path().join("snapshot");
    fs::create_dir_all(&snapshot_dir).unwrap();

    kix()
        .args(["diff", "nonexistent", "--snapshot", "snapshot"])
        .current_dir(tmp.path())
        .assert()
        .failure()
        .stderr(predicate::str::contains("no build output found"));
}
