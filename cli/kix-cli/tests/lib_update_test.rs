//! `kix lib update` against a local Git repository that stands in for
//! github:kix-run/kixpkgs, so the test needs no network. The repository is
//! named in `KIX_LIB_UPDATE_TEST_REPO`. Needs a Kix runtime
//! (`KIX_RUNTIME_DIR` in the development shell).

use std::path::Path;
use std::process::Command as Process;

use assert_cmd::Command;
use kix::runtime::{Tool, Want};
use predicates::prelude::*;
use serde_json::Value;

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Process::new("git")
        .args([
            "-c",
            "user.name=test",
            "-c",
            "user.email=test@example.com",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "tag.gpgSign=false",
        ])
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {out:?}");
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// Make a library repository with the tags `v0.0.1` and `v<VERSION>` and a
/// newer commit on its branch. Return the revision of `v<VERSION>`.
fn library_repo(dir: &Path) -> String {
    git(dir, &["init", "-q", "-b", "main"]);
    std::fs::write(
        dir.join("flake.nix"),
        "{ outputs = _: { version = builtins.readFile ./VERSION; }; }\n",
    )
    .unwrap();
    let mut tagged = String::new();
    for (version, tag) in [
        ("0.0.1", Some("v0.0.1".to_string())),
        (VERSION, Some(format!("v{VERSION}"))),
        ("99.0.0-dev", None),
    ] {
        std::fs::write(dir.join("VERSION"), version).unwrap();
        git(dir, &["add", "-A"]);
        git(dir, &["commit", "-q", "-m", version]);
        if let Some(tag) = tag {
            git(dir, &["tag", &tag]);
            tagged = git(dir, &["rev-parse", "HEAD"]);
        }
    }
    tagged
}

/// Write a project flake whose `kixpkgs` input is `url`, exposing the
/// library's version where Kix looks for it.
fn project(dir: &Path, url: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(
        dir.join("flake.nix"),
        format!(
            r#"{{
  inputs.kixpkgs.url = "{url}";
  outputs = inputs: {{
    legacyPackages = builtins.listToAttrs (map (system: {{
      name = system;
      value.kixLibrary.version = inputs.kixpkgs.version;
    }}) [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]);
  }};
}}
"#
        ),
    )
    .unwrap();
}

fn nix(dir: &Path, args: &[&str]) -> String {
    let nix = kix::runtime::program_path(Tool::Nix, Want::Shipped).unwrap();
    let out = Process::new(nix)
        .args(["--extra-experimental-features", "nix-command flakes"])
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "nix {args:?}: {out:?}");
    String::from_utf8(out.stdout).unwrap()
}

fn locked_rev(dir: &Path) -> String {
    let lock: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("flake.lock")).unwrap()).unwrap();
    lock["nodes"]["kixpkgs"]["locked"]["rev"]
        .as_str()
        .unwrap()
        .to_string()
}

fn kix(project: &Path, repo: &str) -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true")
        .env("KIX_LIB_UPDATE_TEST_REPO", repo)
        .arg("--flake")
        .arg(project)
        .args(["lib", "update"]);
    cmd
}

#[test]
fn lib_update_moves_the_lock_to_the_release_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = tmp.path().join("kixpkgs");
    std::fs::create_dir(&lib).unwrap();
    let release_rev = library_repo(&lib);
    let repo = format!("file://{}", lib.display());

    let proj = tmp.path().join("project");
    project(&proj, &format!("git+{repo}"));
    nix(
        &proj,
        &[
            "flake",
            "lock",
            "--override-input",
            "kixpkgs",
            &format!("git+{repo}?ref=refs/tags/v0.0.1"),
        ],
    );
    let old_rev = locked_rev(&proj);

    kix(&proj, &repo)
        .arg("--dry-run")
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "Kix library: 0.0.1 -> {VERSION}. This was a dry run"
        )));
    assert_eq!(locked_rev(&proj), old_rev);

    kix(&proj, &repo)
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "Kix library: 0.0.1 -> {VERSION}. Commit flake.lock to share this with your team."
        )));
    assert_eq!(locked_rev(&proj), release_rev);

    // A plain evaluation keeps the lock where `kix lib update` put it.
    let system_attr = format!(
        ".#legacyPackages.{}.kixLibrary.version",
        kix::eval::nix::current_system()
    );
    assert_eq!(nix(&proj, &["eval", "--raw", &system_attr]), VERSION);
    assert_eq!(locked_rev(&proj), release_rev);

    kix(&proj, &repo)
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "Kix library is already {VERSION}."
        )));
}

#[test]
fn lib_update_will_not_override_a_pin_in_flake_nix() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = tmp.path().join("kixpkgs");
    std::fs::create_dir(&lib).unwrap();
    library_repo(&lib);
    let repo = format!("file://{}", lib.display());

    let proj = tmp.path().join("project");
    project(&proj, &format!("git+{repo}?ref=refs/tags/v0.0.1"));
    nix(&proj, &["flake", "lock"]);
    let old_rev = locked_rev(&proj);

    kix(&proj, &repo).assert().failure().stderr(
        predicate::str::contains("flake.nix pins the input `kixpkgs`")
            .and(predicate::str::contains(format!("v{VERSION}")))
            .and(predicate::str::contains("then run `kix lib update` again")),
    );
    assert_eq!(locked_rev(&proj), old_rev);
}

#[test]
fn lib_update_without_a_library_input_fails() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(
        tmp.path().join("flake.lock"),
        r#"{"nodes":{"root":{}},"root":"root","version":7}"#,
    )
    .unwrap();
    kix(tmp.path(), "")
        .assert()
        .failure()
        .stderr(predicate::str::contains(
            "flake.lock has no input for the Kix library",
        ));
}
