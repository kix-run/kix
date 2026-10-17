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

/// `deploy --dry-run` runs `kix plan`. With `--current-activation` and no
/// cached build it compares the build with nothing, offline, so every
/// package is added, the plan says no cluster was read, and the exit status
/// is 2 because the plan has changes.
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
        .code(2)
        .stdout(predicate::str::contains("Plan:"))
        .stdout(predicate::str::contains("added"))
        .stdout(predicate::str::contains(
            "Two builds compared; nothing was read from or sent to the cluster.",
        ));
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
        .code(2)
        .stdout(predicate::str::contains("Two builds compared"));
}

/// `kix plan --save` writes a plan file that reads back as a plan made
/// from builds, with the build's graph and each added object's manifest.
#[test]
fn plan_save_writes_the_plan_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("plan.kixplan");
    kix()
        .args(["plan", "example", "--current-activation", "--save"])
        .arg(&path)
        .assert()
        .code(2)
        .stderr(predicate::str::contains("Saved the plan to"));
    let file = std::fs::File::open(&path).unwrap();
    let (mut file, _) = kix::plan::file::PlanFile::verify(file).expect("a valid plan file");
    let header = file.header().clone();
    let doc = &header.plan;
    assert_eq!(doc.made_by, kix::plan::document::MadeBy::Builds);
    assert!(doc.conflicts.items().is_empty());
    assert!(!doc.packages.added.is_empty());
    assert!(doc.packages.added.iter().all(|p| p.manifests.is_none()));
    assert!(
        doc.build.store_path.starts_with("/nix/store/"),
        "{}",
        doc.build.store_path
    );
    assert!(doc.build.identity_hash.is_some());
    assert_eq!(doc.flags.map(|f| f.prune), Some(false));
    // A first deploy writes every object of the build, each as added.
    let writes = &doc.objects.as_ref().expect("objects").writes;
    assert!(!writes.is_empty());
    assert!(
        writes
            .iter()
            .all(|w| w.change == kix::plan::document::WriteChange::Added)
    );
    assert!(!header.graph.nodes.is_empty());
    let (id, shown) = header.shown.iter().next().expect("an added object");
    assert!(shown.old.is_none() && shown.new.is_some());
    let manifest = file.new_manifest(id).unwrap().expect("its new manifest");
    assert!(manifest["kind"].is_string());
}

/// `kix plan` prints no JSON or YAML: a plan kept as data is a plan file.
#[test]
fn plan_refuses_json_and_points_at_save() {
    for format in ["json", "yaml"] {
        kix()
            .args(["plan", "example", "--current-activation", "-o", format])
            .assert()
            .code(1)
            .stderr(predicate::str::contains("--save"));
    }
}

/// `kix deploy --plan` reads only plan files: a JSON plan is refused before
/// anything is built, as is a plan file with one byte changed.
#[test]
fn deploy_plan_refuses_json_and_a_changed_plan_file() {
    let dir = tempfile::tempdir().unwrap();
    let json = dir.path().join("plan.json");
    std::fs::write(&json, "{}").unwrap();
    kix()
        .args(["deploy", "example", "--dry-run", "--plan"])
        .arg(&json)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("not a .kixplan"));

    let saved = dir.path().join("plan.kixplan");
    kix()
        .args(["plan", "example", "--current-activation", "--save"])
        .arg(&saved)
        .assert()
        .code(2);
    let mut bytes = std::fs::read(&saved).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 1;
    std::fs::write(&saved, bytes).unwrap();
    kix()
        .args(["deploy", "example", "--dry-run", "--plan"])
        .arg(&saved)
        .assert()
        .code(1)
        .stderr(predicate::str::contains("cannot read the plan"));
}

/// Flake attribute `minimal` builds the cluster named `test-minimal`. The
/// local activation cache, like the Activation records, is keyed by that
/// name, so a deploy of `minimal` finds the build cached as `test-minimal`
/// and plans against it instead of reporting a first deploy.
#[test]
fn deploy_reads_the_cache_under_the_cluster_name_not_the_attribute() {
    let built = std::process::Command::new("nix")
        .args([
            "build",
            ".#cluster-minimal-activation",
            "--no-link",
            "--print-out-paths",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ])
        .current_dir(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .unwrap()
                .parent()
                .unwrap(),
        )
        .output()
        .expect("nix build runs");
    assert!(
        built.status.success(),
        "nix build failed: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let result = String::from_utf8(built.stdout).unwrap();

    let cache = tempfile::tempdir().unwrap();
    let activations = cache.path().join("kix/activations");
    std::fs::create_dir_all(&activations).unwrap();
    std::fs::write(activations.join("test-minimal.path"), result.trim()).unwrap();

    kix()
        .env("XDG_CACHE_HOME", cache.path())
        .args([
            "deploy",
            "minimal",
            "--dry-run",
            "--yes",
            "--current-activation",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Loading previous activation from cache",
        ))
        .stdout(predicate::str::contains("First deploy").not());
}

/// `kix deploy --log-format json` keeps stdout to the log: the build, the
/// plan and everything else a person reads before the run go to stderr.
/// Offline the deploy stops when it connects to apply, after the plan.
#[test]
fn the_json_deploy_log_has_stdout_to_itself() {
    let cache = tempfile::tempdir().unwrap();
    let out = kix()
        .env("XDG_CACHE_HOME", cache.path())
        .args([
            "deploy",
            "example",
            "--current-activation",
            "--yes",
            "--log-format",
            "json",
        ])
        .assert()
        .failure()
        .get_output()
        .clone();
    let stdout = String::from_utf8(out.stdout).unwrap();
    for line in stdout.lines() {
        serde_json::from_str::<serde_json::Value>(line)
            .unwrap_or_else(|e| panic!("stdout line is not JSON ({e}): {line}"));
    }
    let stderr = String::from_utf8(out.stderr).unwrap();
    assert!(stderr.contains("Cluster example:"), "{stderr}");
    assert!(
        stderr.contains("No previous activation. First deploy."),
        "{stderr}"
    );
    assert!(stderr.contains("failed to connect to cluster"), "{stderr}");
}
