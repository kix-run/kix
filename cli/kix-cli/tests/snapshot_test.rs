use assert_cmd::Command;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

#[test]
fn snapshot_build_example_yaml() {
    let output = kix()
        .args(["build", "example"])
        .output()
        .expect("failed to run kix build");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("build_example_yaml", stdout);
}

#[test]
fn snapshot_build_example_json() {
    let output = kix()
        .args(["build", "example", "-o", "json"])
        .output()
        .expect("failed to run kix build");

    let stdout = String::from_utf8_lossy(&output.stdout);
    // Parse and re-serialize for stable key ordering
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("valid JSON");
    let stable = serde_json::to_string_pretty(&parsed).unwrap();
    insta::assert_snapshot!("build_example_json", stable);
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
        .args(["inspect", "example"])
        .output()
        .expect("failed to run kix inspect");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("inspect_example", stdout);
}

#[test]
fn snapshot_graph_tree() {
    let output = kix()
        .args(["graph", "example", "-q"])
        .output()
        .expect("failed to run kix graph");

    let stdout = String::from_utf8_lossy(&output.stdout);
    insta::assert_snapshot!("graph_tree", stdout);
}
