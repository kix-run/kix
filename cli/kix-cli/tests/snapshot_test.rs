//! Snapshots of what `kix` prints. The build and graph snapshots protect the
//! shape of each output format, so they use the smallest cluster
//! (`minimal`). The Change kind workflow (`scripts/change-kind.py`) compares
//! every manifest of the larger clusters between a pull request and its base.

use assert_cmd::Command;

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
fn snapshot_build_minimal_yaml() {
    let output = kix()
        .args(["build", "minimal"])
        .output()
        .expect("failed to run kix build");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("build_minimal_yaml", stdout);
}

#[test]
fn snapshot_build_minimal_json() {
    let output = kix()
        .args(["build", "minimal", "-o", "json"])
        .output()
        .expect("failed to run kix build");

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Parse and re-serialize for stable key ordering
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("valid JSON");
    let stable = serde_json::to_string_pretty(&parsed).unwrap();
    insta::assert_snapshot!("build_minimal_json", stable);
}

#[test]
fn snapshot_list_default() {
    let output = kix()
        .args(["list"])
        .output()
        .expect("failed to run kix list");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("list_default", stdout);
}

#[test]
fn snapshot_inspect_example() {
    let output = kix()
        .args(["list", "resources", "example"])
        .output()
        .expect("failed to run kix list resources");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("inspect_example", stdout);
}

#[test]
fn snapshot_graph_tree() {
    let output = kix()
        .args(["graph", "minimal", "-q"])
        .output()
        .expect("failed to run kix graph");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("graph_tree", stdout);
}
