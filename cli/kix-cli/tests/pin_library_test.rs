//! `kix upgrade --to <version>` on a project that pins no version, and the
//! check of a library tag that moved after the lock, against a local Git
//! repository that stands in for the Kix library, so the tests need no
//! network. Needs a Kix runtime (`KIX_RUNTIME_DIR` in the development shell).

use std::path::{Path, PathBuf};
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

/// A library repository with the tags `v0.0.1` and `v<VERSION>`, and a
/// newer commit on its branch `main`.
struct Library {
    dir: PathBuf,
    /// The revision of `v<VERSION>`.
    release_rev: String,
}

impl Library {
    fn new(dir: &Path) -> Self {
        std::fs::create_dir_all(dir).unwrap();
        git(dir, &["init", "-q", "-b", "main"]);
        std::fs::write(
            dir.join("flake.nix"),
            "{ outputs = _: { version = builtins.readFile ./VERSION; }; }\n",
        )
        .unwrap();
        let mut release_rev = String::new();
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
                release_rev = git(dir, &["rev-parse", "HEAD"]);
            }
        }
        Library {
            dir: dir.to_path_buf(),
            release_rev,
        }
    }

    fn url(&self) -> String {
        format!("git+file://{}", self.dir.display())
    }
}

/// Write a project whose inputs are `inputs` (name and url), and whose Kix
/// library is the input `library`.
fn project(dir: &Path, inputs: &[(&str, &str)], library: &str) {
    std::fs::create_dir_all(dir).unwrap();
    let lines: String = inputs
        .iter()
        .map(|(name, url)| format!("  inputs.{name}.url = \"{url}\";\n"))
        .collect();
    std::fs::write(
        dir.join("flake.nix"),
        format!(
            r#"{{
{lines}  outputs = inputs: {{
    legacyPackages = builtins.listToAttrs (map (system: {{
      name = system;
      value.kixLibrary.version = inputs.{library}.version;
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

fn locked_rev(dir: &Path, input: &str) -> String {
    let lock: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("flake.lock")).unwrap()).unwrap();
    lock["nodes"][input]["locked"]["rev"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn upgrade(project: &Path) -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true")
        .env("KIX_DATA_DIR", project.join(".kix-data"))
        .env_remove("KIX_SELECTED_BY")
        .env_remove("KIX_AUTO_INSTALL")
        .env_remove("KIX_FLAKE")
        .arg("--flake")
        .arg(project)
        .args(["upgrade", "--to", VERSION]);
    cmd
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap()
}

#[test]
fn a_branch_or_a_commit_is_pinned_to_the_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let tagged = format!("{}?ref=refs/tags/v{VERSION}", lib.url());
    let main_rev = git(&lib.dir, &["rev-parse", "main"]);
    for (name, url) in [
        ("branch", format!("{}?ref=main", lib.url())),
        ("commit", format!("{}?rev={main_rev}", lib.url())),
    ] {
        let proj = tmp.path().join(name);
        project(&proj, &[("kix", &url)], "kix");
        nix(&proj, &["flake", "lock"]);

        upgrade(&proj).assert().success().stdout(format!(
            "Pinned the Kix library to {VERSION} (updated flake.nix, flake.lock). This project's flake.lock pinned no version of Kix before, so Kix built nothing to compare.\nCommit flake.nix and flake.lock.\n"
        ));
        assert!(read(&proj.join("flake.nix")).contains(&format!("\"{tagged}\"")));
        assert_eq!(locked_rev(&proj, "kix"), lib.release_rev);

        // A plain evaluation keeps the lock where Kix put it.
        let system_attr = format!(
            ".#legacyPackages.{}.kixLibrary.version",
            kix::eval::nix::current_system()
        );
        assert_eq!(nix(&proj, &["eval", "--raw", &system_attr]), VERSION);
        assert_eq!(locked_rev(&proj, "kix"), lib.release_rev);

        upgrade(&proj)
            .assert()
            .success()
            .stdout(format!("Already on Kix {VERSION}. Nothing to upgrade.\n"));
    }
}

#[test]
fn two_urls_of_the_repository_are_left_to_a_person() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let main = format!("{}?ref=main", lib.url());
    project(&proj, &[("kix", &main), ("image-kix", &main)], "kix");
    nix(&proj, &["flake", "lock"]);
    let flake = read(&proj.join("flake.nix"));
    let lock = read(&proj.join("flake.lock"));

    upgrade(&proj)
        .assert()
        .code(1)
        .stdout(predicate::str::starts_with(
            "Cannot update flake.nix automatically: two inputs use the Kix library's repository:\n  flake.nix:2:   inputs.kix.url",
        ));
    assert_eq!(read(&proj.join("flake.nix")), flake);
    assert_eq!(read(&proj.join("flake.lock")), lock);
}

#[test]
fn a_folder_has_no_versions_to_pin() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let path = format!("path:{}", lib.dir.display());
    let proj = tmp.path().join("project");
    project(&proj, &[("kix", &path)], "kix");
    upgrade(&proj)
        .assert()
        .code(1)
        .stdout(predicate::str::starts_with(format!(
            "The input kix is the local folder {}, which has no versions. Point the input at the tag v{VERSION}",
            lib.dir.display()
        )));
}

#[test]
fn lib_update_is_refused_with_the_new_command() {
    Command::cargo_bin("kix")
        .unwrap()
        .env("NO_COLOR", "true")
        .args(["lib", "update", "--dry-run"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(format!(
            "[K6054] `kix lib update` was removed. Use `kix upgrade --to {VERSION}` instead."
        )));
}

#[test]
fn secret_hash_is_refused_with_its_change_record() {
    Command::cargo_bin("kix")
        .unwrap()
        .env("NO_COLOR", "true")
        .args(["secret", "hash", "secrets/db.yaml"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "[K4732] `kix secret hash` was removed. Kix now records the SHA-256",
        ));
}

#[test]
fn a_tag_moved_after_the_lock_is_caught() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let tagged = format!("{}?ref=refs/tags/v{VERSION}", lib.url());
    project(&proj, &[("kix", &tagged)], "kix");
    nix(&proj, &["flake", "lock"]);
    // A person moves the tag in flake.nix, and the lock still pins this Kix.
    let flake = read(&proj.join("flake.nix")).replace(&format!("v{VERSION}"), "v0.0.1");
    std::fs::write(proj.join("flake.nix"), flake).unwrap();

    Command::cargo_bin("kix")
        .unwrap()
        .env("NO_COLOR", "true")
        .env("KIX_NO_CACHE", "1")
        .env_remove("KIX_SELECTED_BY")
        .env_remove("KIX_FLAKE")
        .arg("--flake")
        .arg(&proj)
        .args(["build", "c"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(format!(
            "flake.lock pins Kix {VERSION}, but flake.nix now asks for 0.0.1. Run `kix upgrade --to 0.0.1`."
        )));
}
