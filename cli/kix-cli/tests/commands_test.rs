//! Consolidated CLI smoke tests: one test per command to verify basic functionality.
//! These invoke the real binary with `assert_cmd`, so they need a Kix runtime.
//! The development shell names one in `KIX_RUNTIME_DIR`.

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

/// Verify that `deploy --dry-run` (equivalent to `kix plan`) with
/// `--current-activation` compares two builds offline and exits 2 when the
/// plan has changes.
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

/// Verify that `kix bundle` reads back what it writes, so a build the bundle
/// reader would refuse fails immediately.
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

/// Verify that every cluster `kix list clusters` names produces a bundle that
/// reads back as the build it was written from (`kix bundle` refuses a bundle
/// whose graph differs from the result directory's). Builds every test
/// cluster (about ten minutes), so it runs only when asked: `cargo test -p
/// kix-cli --test commands_test -- --ignored every_test_cluster_bundles`.
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

/// Verify that the evaluation-only flake checks of every flake in the
/// repository pass when Kix renders their Helm charts: the
/// `pi-wiring-cluster-<name>` check of each cluster and
/// `every-package-evaluates`. Plain `nix flake check` stops at the first
/// chart, because only `kix` renders charts. Evaluates every cluster, so it
/// runs only when asked: `cargo test -p kix-cli --test commands_test --
/// --ignored flake_checks_evaluate_with_helm`.
#[test]
#[ignore]
fn flake_checks_evaluate_with_helm() {
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap();
    let system = kix::eval::nix::current_system();
    let mut failed = Vec::new();
    let mut evaluated = 0;
    for flake in [".", "clusters", "ludo"] {
        let dir = repo.join(flake);
        let checks = format!(".#checks.{system}");
        let names = kix::eval::nix::eval_with_helm(
            &dir,
            &[
                &checks,
                "--apply",
                "c: builtins.concatStringsSep \" \" (builtins.attrNames c)",
            ],
            &[],
            &|_| {},
        )
        .unwrap();
        for name in names
            .split_whitespace()
            .filter(|n| n.starts_with("pi-wiring-cluster-") || *n == "every-package-evaluates")
        {
            evaluated += 1;
            let attr = format!("{checks}.{name}.drvPath");
            if let Err(e) = kix::eval::nix::eval_with_helm(&dir, &[&attr], &[], &|_| {}) {
                failed.push(format!("{flake}#{name}: {e}"));
            }
        }
    }
    assert!(evaluated > 0);
    assert!(failed.is_empty(), "{}", failed.join("\n"));
}

/// Verify that an instance naming one resource under two parts still produces
/// a bundle `kix bundle` reads back.
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

/// Verify that both a platform hosting a consumer and the consumer itself
/// (which renders no Namespace for namespaces the platform creates) produce
/// bundles `kix bundle` reads back.
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

#[test]
fn pin_rm_removes_package_and_instance_pins_and_errors_when_missing() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("pins.json");
    let digest = format!("sha256:{}", "a".repeat(64));

    for (key, repo) in [("nginx", "docker.io/library/nginx"), ("ns/app", "r/app")] {
        kix()
            .args([
                "pin",
                "set",
                key,
                "--init",
                "--repository",
                repo,
                "--tag",
                "1.0",
                "--digest",
                &digest,
            ])
            .arg("--pins-file")
            .arg(&file)
            .assert()
            .success();
    }

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(doc["version"], 2);

    kix()
        .args(["pin", "rm", "nginx", "--pins-file"])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("removed nginx"));

    kix()
        .args(["pin", "rm", "ns/app", "--pins-file"])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("removed ns/app image"));

    let doc: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(doc["version"], 1);
    assert!(doc.get("instances").is_none());

    kix()
        .args(["pin", "rm", "nginx", "--pins-file"])
        .arg(&file)
        .assert()
        .failure()
        .stderr(
            predicate::str::contains("has no pin named").and(predicate::str::contains("'nginx'")),
        );
}

/// Without a runtime, a command that runs Nix stops with the error that says
/// where Kix looked, and never runs `nix` from `PATH`. `kix doctor` reports
/// the same problem, and `kix --version` still works.
#[test]
fn without_a_runtime_kix_refuses_to_run_programs() {
    // A `nix` on PATH that would succeed if Kix ran it.
    let bin = tempfile::tempdir().unwrap();
    let fake = bin.path().join("nix");
    std::fs::write(&fake, "#!/bin/sh\necho 'fake nix ran' >&2\nexit 0\n").unwrap();
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:/usr/bin:/bin", bin.path().display());

    let without_runtime = || {
        let mut cmd = kix();
        cmd.env_remove("KIX_RUNTIME_DIR").env("PATH", &path);
        cmd
    };

    without_runtime()
        .args(["build", "minimal"])
        .assert()
        .failure()
        .stderr(
            predicate::str::contains("Kix could not find its runtime")
                .and(predicate::str::contains("KIX_RUNTIME_DIR (not set)"))
                .and(predicate::str::contains("fake nix ran").not()),
        );

    without_runtime().arg("doctor").assert().failure().stdout(
        predicate::str::contains("✗ Kix runtime not found")
            .and(predicate::str::contains("Kix could not find its runtime")),
    );

    without_runtime().arg("--version").assert().success();
}

/// A project's kix.toml chooses the builder. `kix doctor` reports the choice,
/// and a builder or setting this version of Kix cannot use stops a command before it
/// runs Nix.
#[test]
fn kix_toml_chooses_the_builder() {
    let project = tempfile::tempdir().unwrap();
    let flake = project.path().display().to_string();
    let file = project.path().join("kix.toml");
    let run = |args: &[&str]| {
        let mut cmd = kix();
        cmd.env_remove("KIX_TEST_BUILDER")
            .env_remove("KIX_STORE_ROOT")
            .args(["--flake", &flake])
            .args(args);
        cmd
    };

    run(&["doctor"])
        .assert()
        .success()
        .stdout(predicate::str::contains("✓ Builder: kix (default)"));

    std::fs::write(&file, "builder = \"remote\"\n").unwrap();
    run(&["build", "minimal"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("cannot use a remote builder"));
    run(&["doctor"]).assert().failure().stdout(
        predicate::str::contains("✗ Builder: remote (set in")
            .and(predicate::str::contains("cannot use a remote builder")),
    );

    std::fs::write(&file, "builder = \"kix\"\nbuidler = \"nix\"\n").unwrap();
    run(&["list", "clusters"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("`buidler`"));

    std::fs::write(&file, "builder = \"kix\"\n").unwrap();
    run(&["doctor"])
        .assert()
        .success()
        .stdout(predicate::str::contains("✓ Builder: kix (set in"));
}
