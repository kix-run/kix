//! Deploy-specific integration tests.

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    // Belt-and-braces: tests must never reach for the user's kubeconfig and
    // hit a real cluster. `--current-activation --dry-run` should be
    // entirely offline, but if any future change introduces a stray client
    // call we'd rather fail fast against `/dev/null` than auth against
    // whatever cluster the developer happens to be pointed at.
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
fn deploy_dry_run_shows_plan() {
    kix()
        .args([
            "deploy",
            "example",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Plan:"))
        // Offline-dry-run banner (kixpkgs#15): must lead the per-resource list.
        .stdout(predicate::str::contains(
            "Dry run. No changes will be applied.",
        ))
        // No prior activation cache for the example flake → every Apply node
        // classifies as Created and uses the runtime "created" verb (not the
        // pre-fix "would create"). This pins the regression on #15.
        .stdout(predicate::str::contains("created"))
        // The "Dry run complete:" summary line (vs "Deploy complete:") is the
        // single most-visible signal that the path was taken.
        .stdout(predicate::str::contains("Dry run complete:"));
}

#[test]
fn apply_alias_works() {
    kix()
        .args([
            "apply",
            "example",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Dry run complete:"));
}
