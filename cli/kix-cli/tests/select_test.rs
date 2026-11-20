//! Version selection, the hand-over between two versions of Kix, and
//! `kix self`, against a data directory and a release site in temporary
//! directories. Installed versions are shell scripts that print how they were
//! run. Needs no Nix and no network.

mod common;

use std::path::{Path, PathBuf};

use assert_cmd::Command;
use base64::Engine;
use predicates::prelude::*;
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// A script that stands in for an installed Kix.
const FAKE: &str = "#!/bin/sh\necho \"FAKE $0 $* KIX_SELECTED_BY=$KIX_SELECTED_BY\"\n";

struct Setup {
    _tmp: tempfile::TempDir,
    data: PathBuf,
    project: PathBuf,
    site: PathBuf,
}

impl Setup {
    /// Make a data directory, and a project whose flake.lock pins the Kix
    /// library tag `v<kix>`.
    fn new(kix: &str) -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let data = root.join("data");
        let project = root.join("project");
        let site = root.join("site");
        std::fs::create_dir_all(&data).unwrap();
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("flake.nix"), "{ outputs = _: { }; }\n").unwrap();
        std::fs::write(project.join("flake.lock"), lock(&format!("v{kix}"))).unwrap();
        Setup {
            _tmp: tmp,
            data,
            project,
            site,
        }
    }

    /// Install a fake Kix of `version` and return its path.
    fn fake(&self, version: &str) -> PathBuf {
        let bin = self.data.join(version).join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let kix = bin.join("kix");
        common::write_executable(&kix, FAKE);
        kix
    }

    /// Return `kix` run as `bin` with a clean environment for selection.
    fn kix_at(&self, bin: &Path) -> Command {
        let mut cmd = Command::new(bin);
        cmd.env("NO_COLOR", "true")
            .env("KIX_DATA_DIR", &self.data)
            .env("KIX_RELEASE_SOURCE", &self.site)
            .env_remove("KIX_SELECTED_BY")
            .env_remove("KIX_AUTO_INSTALL")
            .env_remove("KIX_FLAKE")
            .env_remove("KIX_RELEASE_TEST_KEY");
        cmd
    }

    fn kix(&self) -> Command {
        self.kix_at(&real_kix())
    }
}

/// Return a flake.lock whose `kix` input pins the ref `r` of the Kix
/// repository.
fn lock(r: &str) -> String {
    serde_json::json!({
        "root": "root",
        "version": 7,
        "nodes": {
            "root": { "inputs": { "kix": "kix" } },
            "kix": {
                "original": { "type": "github", "owner": "kix-run", "repo": "kix", "ref": r },
                "locked": { "type": "github", "owner": "kix-run", "repo": "kix", "rev": "0123456789abcdef0123456789abcdef01234567" }
            }
        }
    })
    .to_string()
}

fn real_kix() -> PathBuf {
    assert_cmd::cargo::cargo_bin("kix")
}

fn stdout(cmd: &mut Command) -> String {
    stdout_of(cmd).0
}

fn stdout_of(cmd: &mut Command) -> (String, String) {
    let out = cmd.output().unwrap();
    assert!(out.status.success(), "{out:?}");
    (
        String::from_utf8(out.stdout).unwrap(),
        String::from_utf8(out.stderr).unwrap(),
    )
}

#[test]
fn an_older_kix_hands_over_with_its_arguments_unchanged() {
    let s = Setup::new("9.9.1");
    let fake = s.fake("9.9.1");
    let out = stdout(s.kix().arg("--flake").arg(&s.project).args([
        "list",
        "clusters",
        "--some-future-flag",
    ]));
    let chooser = real_kix();
    let chosen_by = [chooser.clone(), chooser.canonicalize().unwrap()]
        .map(|p| format!("KIX_SELECTED_BY={}", p.display()));
    assert!(
        out.starts_with(&format!(
            "FAKE {} --flake {} list clusters --some-future-flag KIX_SELECTED_BY=",
            fake.display(),
            s.project.display()
        )),
        "{out}"
    );
    assert!(
        chosen_by.iter().any(|c| out.trim_end().ends_with(c)),
        "{out}"
    );
}

#[test]
fn a_chosen_kix_never_selects_again_and_says_who_chose_it() {
    let s = Setup::new("9.9.1");
    s.fake("9.9.1");
    let bin = s.data.join(VERSION).join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    common::copy_executable(&real_kix(), &bin.join("kix"));

    s.kix_at(&bin.join("kix"))
        .env("KIX_SELECTED_BY", "/opt/newer/bin/kix")
        .arg("--flake")
        .arg(&s.project)
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"))
        .stderr(predicate::str::contains(
            "  started from /opt/newer/bin/kix",
        ));
}

#[test]
fn selection_reads_only_flake_lock() {
    let s = Setup::new("9.9.1");
    std::fs::write(s.project.join("kix.toml"), "kix = \"9.8\"\nfuture = 1\n").unwrap();
    let fake = s.fake("9.9.1");
    s.fake("9.9.2");
    let out = stdout(
        s.kix()
            .arg("--flake")
            .arg(&s.project)
            .args(["list", "clusters"]),
    );
    assert!(
        out.starts_with(&format!("FAKE {} ", fake.display())),
        "{out}"
    );
}

#[test]
fn a_project_without_a_versioned_lock_is_refused_with_the_fix() {
    let s = Setup::new("9.9.1");
    let running = format!("kix upgrade --to {VERSION}");
    let refused = |expected: &str| {
        s.kix()
            .arg("--flake")
            .arg(&s.project)
            .args(["list", "clusters"])
            .assert()
            .code(1)
            .stderr(predicate::str::contains(expected.to_string()));
    };
    std::fs::remove_file(s.project.join("flake.lock")).unwrap();
    refused(&format!(
        "This project has no flake.lock. Run `{running}` to pin the Kix library and create it."
    ));

    let untagged = lock("v9.9.1").replace(",\"ref\":\"v9.9.1\"", "");
    assert!(!untagged.contains("ref"), "{untagged}");
    std::fs::write(s.project.join("flake.lock"), untagged).unwrap();
    refused(
        "flake.nix uses the Kix library without a version, so Kix cannot tell which version this project uses. To pin it, run `kix upgrade --to <version>` with the version of Kix this project uses now, then run `kix upgrade` to move to a newer version and review what changes.",
    );

    let old = lock("v9.9.1").replace("{\"kix\":\"kix\"}", "{\"kixpkgs\":\"kix\"}");
    assert!(old.contains("kixpkgs"), "{old}");
    std::fs::write(s.project.join("flake.lock"), old).unwrap();
    refused(
        "[K9179] flake.nix names the Kix library input kixpkgs, and Kix now reads only an input named kix. Rename the input to kix in flake.nix, then run `kix upgrade --to 9.9.1` to record the version this project uses now, then run `kix upgrade` to move to a newer version and review what changes.",
    );

    // A directory without flake.nix is no project, so the command runs here.
    let empty = s.project.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    s.kix()
        .arg("--flake")
        .arg(&empty)
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"));
}

#[test]
fn a_development_library_runs_here_and_says_so() {
    let s = Setup::new("9.9.1");
    s.fake("9.9.1");
    std::fs::write(s.project.join("flake.lock"), lock("main")).unwrap();
    s.kix()
        .arg("--flake")
        .arg(&s.project)
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"))
        .stderr(predicate::str::contains(
            "  this project uses a development Kix library: the input kix follows the branch main",
        ));
    // An override of the input on the command line counts as one too.
    std::fs::write(s.project.join("flake.lock"), lock("v9.9.1")).unwrap();
    s.kix()
        .arg("--flake")
        .arg(&s.project)
        .args(["--override-input", "kix", "path:/src/kix", "--version"])
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"))
        .stderr(predicate::str::contains(
            "--override-input kix path:/src/kix",
        ));
}

#[test]
fn the_kix_setting_in_kix_toml_is_refused() {
    let s = Setup::new(VERSION);
    std::fs::write(s.project.join("kix.toml"), "kix = \"0.9\"\n").unwrap();
    s.kix()
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .assert()
        .code(1)
        .stderr(
            predicate::str::contains("[K4476]").and(predicate::str::contains(
                "Delete the kix line from kix.toml, then run `kix upgrade --to 0.9` to record the version this project uses now, then run `kix upgrade`",
            )),
        );
}

/// A project set up for Kix 0.9 names its version in kix.toml and pins no
/// version in flake.lock. Every command, `kix doctor` included, reports the
/// kix.toml error first, because its steps also pin the lock.
#[test]
fn a_kix_09_project_gets_the_kix_setting_error_first() {
    let s = Setup::new(VERSION);
    let untagged = lock("v0").replace(",\"ref\":\"v0\"", "");
    assert!(!untagged.contains("ref"), "{untagged}");
    std::fs::write(s.project.join("flake.lock"), untagged).unwrap();
    std::fs::write(s.project.join("kix.toml"), "kix = \"0.10.0-rc.3\"\n").unwrap();
    let path = s.project.join("kix.toml");
    let expected = format!(
        "[K4476] {} sets kix = \"0.10.0-rc.3\", but Kix now takes this project's version from the Kix library tag in flake.lock. Run these steps with Kix 0.10 or later, because `kix upgrade` in Kix 0.9 writes the kix line back. Delete the kix line from kix.toml, then run `kix upgrade --to 0.10.0-rc.3` to record the version this project uses now, then run `kix upgrade` to move to a newer version and review what changes.",
        path.display()
    );
    for command in [&["list", "clusters"][..], &["doctor"], &["upgrade"]] {
        let out = s
            .kix()
            .arg("--flake")
            .arg(&s.project)
            .args(command)
            .output()
            .unwrap();
        assert!(!out.status.success(), "{command:?}: {out:?}");
        let text = String::from_utf8_lossy(&out.stdout).to_string()
            + &String::from_utf8_lossy(&out.stderr);
        // miette wraps long lines, so compare the words.
        let words = |t: &str| t.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(
            words(&text).contains(&words(&expected)),
            "{command:?}: {text}"
        );
        assert!(!text.contains("without a version"), "{command:?}: {text}");
    }
}

#[test]
fn version_runs_an_installed_match_and_never_installs() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    s.kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .arg("--flake")
        .arg(&s.project)
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"))
        .stderr(predicate::str::contains(
            "  this project uses Kix 9.9.1, which is not installed. Any other kix command installs it.",
        ));
    assert!(!s.data.join("9.9.1").exists());

    let fake = s.fake("9.9.1");
    let out = stdout(s.kix().arg("--flake").arg(&s.project).arg("--version"));
    assert!(
        out.starts_with(&format!("FAKE {} --flake", fake.display())),
        "{out}"
    );
}

#[test]
fn without_a_home_directory_nothing_is_installed() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let message = "Kix cannot find a home directory to install into. Set HOME or XDG_DATA_HOME.";
    let homeless = |cmd: &mut Command| {
        cmd.env_remove("KIX_DATA_DIR")
            .env_remove("HOME")
            .env_remove("XDG_DATA_HOME")
            .env("KIX_RELEASE_TEST_KEY", signer.public_hex());
    };
    let mut cmd = s.kix();
    homeless(&mut cmd);
    cmd.args(["self", "install", "9.9"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(message));

    let mut cmd = s.kix();
    homeless(&mut cmd);
    cmd.arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(message));
}

#[test]
fn without_auto_install_a_missing_version_is_refused() {
    let s = Setup::new("9.9.1");
    s.kix()
        .env("KIX_AUTO_INSTALL", "0")
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "This project uses Kix 9.9.1 (flake.lock), and Kix 9.9.1 is not installed. Automatic installs are off (KIX_AUTO_INSTALL=0). Run `kix self install 9.9.1`.",
        ));
}

#[test]
fn self_and_completions_run_in_the_kix_the_user_started() {
    let s = Setup::new("9.9.1");
    s.fake("9.9.1");
    let list = stdout(
        s.kix()
            .arg("--flake")
            .arg(&s.project)
            .args(["self", "list"]),
    );
    assert!(!list.contains("FAKE"), "{list}");
    assert!(
        list.contains(&format!("  9.9.1  {}", s.data.join("9.9.1").display())),
        "{list}"
    );

    let completions = stdout(
        s.kix()
            .current_dir(&s.project)
            .args(["completions", "bash"]),
    );
    assert!(!completions.contains("FAKE"), "{completions}");
    assert!(completions.contains("complete"), "{completions}");
}

#[test]
fn a_project_on_this_version_runs_here() {
    let running: kix::version::Version = VERSION.parse().unwrap();
    let s = Setup::new(VERSION);
    s.fake(&format!(
        "{}.{}.{}",
        running.major,
        running.minor,
        running.patch + 1
    ));
    s.kix()
        .arg("--flake")
        .arg(&s.project)
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"))
        .stderr(predicate::str::contains("started from").not());
}

#[test]
fn version_without_auto_install_says_how_to_install() {
    let s = Setup::new("9.9.1");
    s.kix()
        .env("KIX_AUTO_INSTALL", "0")
        .arg("--flake")
        .arg(&s.project)
        .arg("--version")
        .assert()
        .success()
        .stdout(format!("kix {VERSION}\n"))
        .stderr(predicate::str::contains(
            "  this project uses Kix 9.9.1, which is not installed. Run `kix self install 9.9.1`.",
        ));
}

/// Signs releases for a fixture site.
struct Signer {
    pair: Ed25519KeyPair,
}

impl Signer {
    fn new() -> Self {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
        Signer {
            pair: Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap(),
        }
    }

    fn public_hex(&self) -> String {
        hex(self.pair.public_key().as_ref())
    }

    fn signature_file(&self, bytes: &[u8]) -> String {
        self.signature_as(bytes, "kix-release-signature v1")
    }

    fn signature_as(&self, bytes: &[u8], header: &str) -> String {
        let key: [u8; 32] = self.pair.public_key().as_ref().try_into().unwrap();
        format!(
            "{header}\nkeyid={}\nsignature={}\n",
            kix::release::verify::keyid(&key),
            base64::engine::general_purpose::STANDARD.encode(self.pair.sign(bytes).as_ref())
        )
    }

    /// Write `index` as the site's release index, signed, with `generated`
    /// set `age` ago and `expires` a week after that.
    fn write_index(&self, site: &Path, mut index: serde_json::Value, age: chrono::Duration) {
        let generated = chrono::Utc::now() - age;
        let stamp =
            |t: chrono::DateTime<chrono::Utc>| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        index["schema"] = serde_json::json!("kix.run/releases/v1");
        index["generated"] = serde_json::json!(stamp(generated));
        index["expires"] = serde_json::json!(stamp(generated + chrono::Duration::days(7)));
        let bytes = index.to_string();
        let dir = site.join("releases");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("index.json"), &bytes).unwrap();
        std::fs::write(
            dir.join("index.json.sig"),
            self.signature_as(bytes.as_bytes(), "kix-index-signature v1"),
        )
        .unwrap();
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// How the fixture site signs its release.
enum Signed {
    Yes,
    Tampered,
    Missing,
}

/// Publish release `version` of a fake Kix on the fixture site.
fn publish(s: &Setup, signer: &Signer, version: &str, signed: Signed) {
    let system = kix::release::system().unwrap();
    let file = format!("kix-{system}.tar.gz");
    let download = s.site.join("download").join(version);
    std::fs::create_dir_all(&download).unwrap();
    let archive = download.join(&file);
    let gz = flate2::write::GzEncoder::new(
        std::fs::File::create(&archive).unwrap(),
        flate2::Compression::fast(),
    );
    let mut tar = tar::Builder::new(gz);
    let mut header = tar::Header::new_gnu();
    header.set_size(FAKE.len() as u64);
    header.set_mode(0o755);
    tar.append_data(
        &mut header,
        format!("kix-{version}-{system}/bin/kix"),
        FAKE.as_bytes(),
    )
    .unwrap();
    tar.into_inner().unwrap().finish().unwrap();

    let sha = hex(&Sha256::digest(std::fs::read(&archive).unwrap()));
    let sums = format!("{sha}  {file}\n");
    let releases = s.site.join("releases").join(format!("v{version}"));
    std::fs::create_dir_all(&releases).unwrap();
    std::fs::write(releases.join("SHA256SUMS"), &sums).unwrap();
    match signed {
        Signed::Yes => std::fs::write(
            releases.join("SHA256SUMS.sig"),
            signer.signature_file(sums.as_bytes()),
        )
        .unwrap(),
        Signed::Tampered => std::fs::write(
            releases.join("SHA256SUMS.sig"),
            signer.signature_file(b"other sums"),
        )
        .unwrap(),
        Signed::Missing => {}
    }
    signer.write_index(
        &s.site,
        serde_json::json!({
            "latest": version,
            "releases": [index_entry(version, &system)],
        }),
        chrono::Duration::zero(),
    );
}

fn index_entry(version: &str, system: &str) -> serde_json::Value {
    serde_json::json!({
        "version": version,
        "date": "2026-11-07",
        "systems": [system],
        "sums": format!("/releases/v{version}/SHA256SUMS"),
        "signature": format!("/releases/v{version}/SHA256SUMS.sig"),
        "download": format!("/download/{version}/"),
    })
}

fn leftovers(data: &Path) -> Vec<String> {
    std::fs::read_dir(data)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.starts_with("tmp-"))
        .collect()
}

#[test]
fn a_missing_version_is_installed_then_run() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let out = s
        .kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{stderr}");
    assert!(
        stderr.contains("Installing Kix 9.9.1 (this project uses 9.9.1)"),
        "{stderr}"
    );
    assert!(
        stdout.starts_with(&format!(
            "FAKE {} --flake",
            s.data.join("9.9.1/bin/kix").display()
        )),
        "{stdout}"
    );
    assert!(leftovers(&s.data).is_empty());

    // The next run finds it installed.
    let again = stdout_of(
        s.kix()
            .arg("--flake")
            .arg(&s.project)
            .args(["list", "clusters"]),
    );
    assert!(!again.1.contains("Installing"), "{}", again.1);
}

#[test]
fn a_prerelease_is_installed_when_the_lock_pins_it() {
    let s = Setup::new("9.9.0-rc.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.0-rc.1", Signed::Yes);
    let out = s
        .kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success(), "{stderr}");
    assert!(
        stderr.contains("Installing Kix 9.9.0-rc.1 (this project uses 9.9.0-rc.1)"),
        "{stderr}"
    );
    assert!(
        stdout.starts_with(&format!(
            "FAKE {} --flake",
            s.data.join("9.9.0-rc.1/bin/kix").display()
        )),
        "{stdout}"
    );
}

#[test]
fn a_release_whose_signature_does_not_verify_is_not_installed() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Tampered);
    s.kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "the release signature for Kix 9.9.1 does not verify against any key built into Kix",
        ));
    assert!(!s.data.join("9.9.1").exists());
    assert!(leftovers(&s.data).is_empty());

    // A key that did not sign the release does not help either.
    let other = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let system = kix::release::system().unwrap();
    other.write_index(
        &s.site,
        serde_json::json!({ "latest": "9.9.1", "releases": [index_entry("9.9.1", &system)] }),
        chrono::Duration::zero(),
    );
    s.kix()
        .env("KIX_RELEASE_TEST_KEY", other.public_hex())
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("does not verify"));
    assert!(!s.data.join("9.9.1").exists());
}

#[test]
fn a_release_without_a_signature_is_not_installed() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Missing);
    s.kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .args(["self", "install", "9.9"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "Kix 9.9.1 has no release signature, so Kix cannot verify it",
        ));
    assert!(!s.data.join("9.9.1").exists());
}

/// Run `kix self install <req>` against the fixture site with `signer`'s
/// key trusted.
fn self_install(s: &Setup, signer: &Signer, req: &str) -> assert_cmd::assert::Assert {
    s.kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .args(["self", "install", req])
        .assert()
}

#[test]
fn an_index_without_a_valid_signature_installs_nothing() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let sig = s.site.join("releases").join("index.json.sig");

    std::fs::remove_file(&sig).unwrap();
    self_install(&s, &signer, "9.9").code(1).stderr(
        predicate::str::contains("the release index from").and(predicate::str::contains(
            "has no signature, so Kix cannot trust it",
        )),
    );

    // A signature over other bytes, or one made with a release header.
    std::fs::write(&sig, signer.signature_as(b"{}", "kix-index-signature v1")).unwrap();
    self_install(&s, &signer, "9.9")
        .code(1)
        .stderr(predicate::str::contains(
            "Kix did not trust the release index",
        ));
    let index = std::fs::read(s.site.join("releases").join("index.json")).unwrap();
    std::fs::write(&sig, signer.signature_file(&index)).unwrap();
    self_install(&s, &signer, "9.9")
        .code(1)
        .stderr(predicate::str::contains(
            "index.json.sig is not a Kix signature file",
        ));
    assert!(!s.data.join("9.9.1").exists());
}

#[test]
fn an_expired_index_installs_nothing() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let system = kix::release::system().unwrap();
    signer.write_index(
        &s.site,
        serde_json::json!({ "latest": "9.9.1", "releases": [index_entry("9.9.1", &system)] }),
        chrono::Duration::days(8),
    );
    self_install(&s, &signer, "9.9")
        .code(1)
        .stderr(predicate::str::contains("it expired at"));
    assert!(!s.data.join("9.9.1").exists());
}

#[test]
fn an_index_older_than_one_already_accepted_installs_nothing() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.0", Signed::Yes);
    publish(&s, &signer, "9.9.1", Signed::Yes);
    self_install(&s, &signer, "9.9.1").success();
    assert!(s.data.join("release-index.json").is_file());

    // The site serves an index from before 9.9.1, made an hour earlier.
    let system = kix::release::system().unwrap();
    signer.write_index(
        &s.site,
        serde_json::json!({ "latest": "9.9.0", "releases": [index_entry("9.9.0", &system)] }),
        chrono::Duration::hours(1),
    );
    self_install(&s, &signer, "9.9.0")
        .code(1)
        .stderr(predicate::str::contains(
            "this machine already accepted an index made at",
        ));
    assert!(!s.data.join("9.9.0").exists());
}

#[test]
fn a_withdrawn_release_is_never_installed() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.0", Signed::Yes);
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let system = kix::release::system().unwrap();
    signer.write_index(
        &s.site,
        serde_json::json!({
            "latest": "9.9.0",
            "releases": [index_entry("9.9.0", &system)],
            "withdrawn": [{ "version": "9.9.1", "reason": "it deletes Secrets", "use": "9.9.0" }],
        }),
        chrono::Duration::zero(),
    );

    self_install(&s, &signer, "9.9.1").code(1).stderr(predicate::str::contains(
        "Kix 9.9.1 was withdrawn, so Kix did not install it: it deletes Secrets. Use Kix 9.9.0 instead. In a project, run `kix upgrade --to 9.9.0`",
    ));
    assert!(!s.data.join("9.9.1").exists());

    // A minor takes the newest release that was not withdrawn.
    self_install(&s, &signer, "9.9").success();
    assert!(s.data.join("9.9.0").exists());
    assert!(!s.data.join("9.9.1").exists());

    // The project pins 9.9.1, so selection refuses to install it too.
    s.kix()
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .arg("--flake")
        .arg(&s.project)
        .args(["list", "clusters"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("Kix 9.9.1 was withdrawn"));
}

// `release::verify` tests that the test key is never trusted for a site.
// This checks the binary sends a site source to the network and does not
// treat it as a directory.
#[test]
fn a_site_source_is_fetched_over_the_network() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    s.kix()
        .env("KIX_RELEASE_SOURCE", "https://127.0.0.1:9")
        .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
        .args(["self", "install", "9.9"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "could not reach https://127.0.0.1:9",
        ));
}

#[test]
fn self_install_list_and_prune() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    s.fake("9.8.0");
    s.fake("9.7.0");

    let (out, err) = stdout_of(
        s.kix()
            .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
            .args(["self", "install", "9.9"]),
    );
    assert!(err.contains("Installing Kix 9.9.1"), "{err}");
    assert_eq!(
        out,
        format!(
            "Installed Kix 9.9.1 to {}\n",
            s.data.join("9.9.1").display()
        )
    );

    let (out, _) = stdout_of(
        s.kix()
            .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
            .args(["self", "install", "9.9.1"]),
    );
    assert_eq!(
        out,
        format!(
            "Kix 9.9.1 is already installed in {}\n",
            s.data.join("9.9.1").display()
        )
    );

    let (out, _) = stdout_of(s.kix().args(["self", "list"]));
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 3, "{out}");
    assert!(lines[0].starts_with("  9.9.1  "), "{out}");
    assert!(lines[2].starts_with("  9.7.0  "), "{out}");

    let (out, _) = stdout_of(s.kix().args(["self", "prune", "--keep", "1", "--dry-run"]));
    assert!(out.contains("Would remove Kix 9.8.0"), "{out}");
    assert!(s.data.join("9.8.0").exists());

    let (out, _) = stdout_of(s.kix().args(["self", "prune", "--keep", "1"]));
    assert!(out.contains("Removed Kix 9.8.0"), "{out}");
    assert!(out.contains("Removed Kix 9.7.0"), "{out}");
    assert!(s.data.join("9.9.1/bin/kix").exists());
    assert!(!s.data.join("9.8.0").exists());

    s.kix()
        .args(["self", "install", "0.8.x"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains("\"0.8.x\" is not a Kix version"));
}

#[test]
fn self_upgrade_refuses_a_kix_the_script_did_not_install() {
    let s = Setup::new("9.9.1");
    s.kix()
        .args(["self", "upgrade"])
        .assert()
        .code(1)
        .stderr(predicate::str::contains(
            "was not installed by the install script. Upgrade it the way you installed it",
        ));
}

#[test]
fn self_upgrade_installs_the_newest_release_and_moves_the_link() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let bin = s.data.join(VERSION).join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    common::copy_executable(&real_kix(), &bin.join("kix"));
    std::fs::write(
        s.data.join("receipt.json"),
        format!(r#"{{"installer": "script", "version": "{VERSION}"}}"#),
    )
    .unwrap();
    let home = s.data.parent().unwrap().join("home");
    let link = home.join(".local/bin/kix");
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(bin.join("kix"), &link).unwrap();

    let (out, _) = stdout_of(
        s.kix_at(&bin.join("kix"))
            .env("HOME", &home)
            .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
            .args(["self", "upgrade"]),
    );
    assert_eq!(out, format!("Kix {VERSION} -> 9.9.1\n"));
    assert_eq!(
        std::fs::read_link(&link).unwrap(),
        s.data.join("9.9.1/bin/kix")
    );
    let receipt = std::fs::read_to_string(s.data.join("receipt.json")).unwrap();
    assert!(receipt.contains("\"version\": \"9.9.1\""), "{receipt}");
}

#[test]
fn self_upgrade_moves_the_link_the_receipt_names() {
    let s = Setup::new("9.9.1");
    let signer = Signer::new();
    publish(&s, &signer, "9.9.1", Signed::Yes);
    let bin = s.data.join(VERSION).join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    common::copy_executable(&real_kix(), &bin.join("kix"));
    let root = s.data.parent().unwrap();
    let link = root.join("opt/bin/kix");
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(bin.join("kix"), &link).unwrap();
    std::fs::write(
        s.data.join("receipt.json"),
        serde_json::json!({
            "installer": "script",
            "version": VERSION,
            "link": link,
        })
        .to_string(),
    )
    .unwrap();
    let home = root.join("home");

    let (out, _) = stdout_of(
        s.kix_at(&bin.join("kix"))
            .env("HOME", &home)
            .env("KIX_RELEASE_TEST_KEY", signer.public_hex())
            .args(["self", "upgrade"]),
    );
    assert_eq!(out, format!("Kix {VERSION} -> 9.9.1\n"));
    assert_eq!(
        std::fs::read_link(&link).unwrap(),
        s.data.join("9.9.1/bin/kix")
    );
    assert!(!home.join(".local/bin/kix").exists());
    let receipt: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(s.data.join("receipt.json")).unwrap())
            .unwrap();
    assert_eq!(receipt["link"], serde_json::json!(link));
    assert_eq!(receipt["version"], "9.9.1");
}
