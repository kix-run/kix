//! `kix upgrade --to <the version the project is on>` against a local Git
//! repository that stands in for the Kix library, so the test needs no
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

/// Write a project whose inputs are `inputs` (name and url), whose Kix
/// library is the input `library`, and whose `kix.toml` names this Kix.
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
    std::fs::write(dir.join("kix.toml"), format!("kix = \"{VERSION}\"\n")).unwrap();
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

fn repair(project: &Path) -> Command {
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

#[test]
fn an_input_without_a_ref_is_locked_to_the_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let url = lib.url();
    project(&proj, &[("kix", &url)], "kix");
    nix(
        &proj,
        &[
            "flake",
            "lock",
            "--override-input",
            "kix",
            &format!("{url}?ref=refs/tags/v0.0.1"),
        ],
    );
    let old_rev = locked_rev(&proj, "kix");
    let flake = std::fs::read_to_string(proj.join("flake.nix")).unwrap();

    repair(&proj)
        .arg("--dry-run")
        .assert()
        .success()
        .stdout(format!(
            "Kix library: 0.0.1 -> {VERSION}. This was a dry run, so Kix changed no files.\nNext: run `kix upgrade --to {VERSION}` to make these changes.\n"
        ));
    assert_eq!(locked_rev(&proj, "kix"), old_rev);

    repair(&proj).assert().success().stdout(format!(
        "Kix library: 0.0.1 -> {VERSION}.\nCommit flake.lock.\n"
    ));
    assert_eq!(locked_rev(&proj, "kix"), lib.release_rev);
    assert_eq!(
        std::fs::read_to_string(proj.join("flake.nix")).unwrap(),
        flake
    );

    // A plain evaluation keeps the lock where Kix put it.
    let system_attr = format!(
        ".#legacyPackages.{}.kixLibrary.version",
        kix::eval::nix::current_system()
    );
    assert_eq!(nix(&proj, &["eval", "--raw", &system_attr]), VERSION);
    assert_eq!(locked_rev(&proj, "kix"), lib.release_rev);

    repair(&proj)
        .assert()
        .success()
        .stdout(format!("Kix library is already {VERSION}.\n"));
}

#[test]
fn a_version_tag_is_changed_in_flake_nix() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let old = format!("{}?ref=refs/tags/v0.0.1", lib.url());
    project(&proj, &[("kixpkgs", &old)], "kixpkgs");
    nix(&proj, &["flake", "lock"]);

    repair(&proj).assert().success().stdout(format!(
        "Kix library: 0.0.1 -> {VERSION}. Kix changed the tag in flake.nix.\nCommit flake.nix and flake.lock.\n"
    ));
    assert!(
        std::fs::read_to_string(proj.join("flake.nix"))
            .unwrap()
            .contains(&format!("{}?ref=refs/tags/v{VERSION}\"", lib.url()))
    );
    assert_eq!(locked_rev(&proj, "kixpkgs"), lib.release_rev);
}

#[test]
fn two_urls_on_the_tag_are_left_to_a_person() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let old = format!("{}?ref=refs/tags/v0.0.1", lib.url());
    project(&proj, &[("kix", &old), ("image-kix", &old)], "kix");
    nix(&proj, &["flake", "lock"]);
    let flake = std::fs::read_to_string(proj.join("flake.nix")).unwrap();
    let lock = std::fs::read_to_string(proj.join("flake.lock")).unwrap();

    repair(&proj)
        .assert()
        .code(1)
        .stdout(predicate::str::starts_with(
            "Kix cannot tell which url in flake.nix is the Kix library input, because more than one names the tag v0.0.1:\n  flake.nix:2:   inputs.kix.url",
        ));
    assert_eq!(
        std::fs::read_to_string(proj.join("flake.nix")).unwrap(),
        flake
    );
    assert_eq!(
        std::fs::read_to_string(proj.join("flake.lock")).unwrap(),
        lock
    );
}

#[test]
fn a_branch_or_a_folder_is_left_alone_and_checked() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let branch = format!("{}?ref=main", lib.url());
    project(&proj, &[("kix", &branch)], "kix");
    nix(&proj, &["flake", "lock"]);
    let lock = std::fs::read_to_string(proj.join("flake.lock")).unwrap();
    repair(&proj).assert().code(1).stdout(predicate::str::starts_with(
        format!("The input kix follows the branch main, so Kix leaves it alone. It holds the Kix library 99.0.0-dev, which is newer than Kix {VERSION}. Point the input at the tag v{VERSION}, or at a branch that holds the Kix library {VERSION}.")
    ));
    assert_eq!(
        std::fs::read_to_string(proj.join("flake.lock")).unwrap(),
        lock
    );

    // A folder that holds the matching library passes the check.
    git(&lib.dir, &["checkout", "-q", &format!("v{VERSION}")]);
    let folder = tmp.path().join("folder");
    std::fs::create_dir(&folder).unwrap();
    for file in ["flake.nix", "VERSION"] {
        std::fs::copy(lib.dir.join(file), folder.join(file)).unwrap();
    }
    let path = format!("path:{}", folder.display());
    let proj = tmp.path().join("project-folder");
    project(&proj, &[("kix", &path)], "kix");
    repair(&proj).assert().success().stdout(format!(
        "The input kix is the local folder {}, so Kix leaves it alone. It holds the Kix library {VERSION}.\n",
        folder.display()
    ));
}

#[test]
fn two_library_names_need_the_setting() {
    let tmp = tempfile::tempdir().unwrap();
    let lib = Library::new(&tmp.path().join("lib"));
    let proj = tmp.path().join("project");
    let old = format!("{}?ref=refs/tags/v0.0.1", lib.url());
    project(&proj, &[("kix", &lib.url()), ("kixpkgs", &old)], "kixpkgs");
    repair(&proj)
        .assert()
        .code(1)
        .stdout(predicate::str::contains(
            "flake.nix has an input named kix and an input named kixpkgs",
        ));

    std::fs::write(
        proj.join("kix.toml"),
        format!("kix = \"{VERSION}\"\nlibrary-input = \"kixpkgs\"\n"),
    )
    .unwrap();
    repair(&proj)
        .assert()
        .success()
        .stdout(predicate::str::contains(format!(
            "Kix library: 0.0.1 -> {VERSION}. Kix changed the tag in flake.nix."
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
fn a_library_of_another_minor_is_refused_with_the_fix() {
    let tmp = tempfile::tempdir().unwrap();
    let proj = tmp.path().join("project");
    std::fs::create_dir(&proj).unwrap();
    std::fs::write(
        proj.join("flake.nix"),
        r#"{
  outputs = _: {
    legacyPackages = builtins.listToAttrs (map (system: {
      name = system;
      value.kixLibrary.version = "0.1.0";
    }) [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ]);
  };
}
"#,
    )
    .unwrap();

    Command::cargo_bin("kix")
        .unwrap()
        .env("NO_COLOR", "true")
        .env("KIX_NO_CACHE", "1")
        .arg("--flake")
        .arg(&proj)
        .args(["build", "c"])
        .assert()
        .failure()
        .stderr(predicate::str::contains(format!(
            "This project's Kix library is 0.1.0, but this is Kix {VERSION}. Run `kix upgrade --to {VERSION}` to move the project to the {VERSION} library"
        )));
}
