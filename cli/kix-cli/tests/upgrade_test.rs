//! `kix upgrade` against a release site and a data directory in temporary
//! directories. Each released Kix is a shell script that lists the
//! project's clusters and packages from files in `fake/`, and exports a
//! cluster by copying `fake/out-<version>/<cluster>` (or `fake/out`). A file
//! `fake/fail-<version>` makes that version's builds fail. The project's
//! Kix library is a local Git repository with a tag for each version, so
//! the tests need no network. They need a Kix runtime (`KIX_RUNTIME_DIR` in
//! the development shell), since Kix pins the library with Nix.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use assert_cmd::Command;
use base64::Engine;
use predicates::prelude::*;
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};

const FAKE: &str = r#"#!/bin/sh
V=__VERSION__
flake=""
while [ $# -gt 0 ]; do
  case "$1" in
    --flake) flake="$2"; shift 2 ;;
    -o) shift 2 ;;
    *) break ;;
  esac
done
f="$flake/fake"
echo "$V $*" >> "$f/calls.log"
case "$1" in
  list)
    if [ "$2" = clusters ]; then cat "$f/clusters.json"; else cat "$f/packages.json"; fi ;;
  export)
    c="$2"; out="$4"
    if [ -e "$f/fail-$V" ]; then
      echo "error: [K0001] cluster $c sets replicaCount, which Kix $V renamed" >&2
      exit 1
    fi
    src="$f/out-$V"; [ -d "$src" ] || src="$f/out"
    mkdir -p "$out"; cp -R "$src/$c/." "$out/" ;;
  *) echo "fake kix $V: $*" ;;
esac
"#;

struct Setup {
    _tmp: common::TempDir,
    data: PathBuf,
    project: PathBuf,
    site: PathBuf,
    cache: PathBuf,
    signer: Ed25519KeyPair,
    /// The url of the library repository.
    library: String,
}

impl Setup {
    /// A project on Kix 9.1.0 with clusters `east` and `west`, which install
    /// the packages `web` and `db`.
    fn new() -> Self {
        let tmp = common::tempdir();
        let root = tmp.path().canonicalize().unwrap();
        let library = library_repo(&root.join("library"), LIBRARY_VERSIONS);
        let s = Setup {
            library,
            data: root.join("data"),
            project: root.join("project"),
            site: root.join("site"),
            cache: root.join("cache"),
            signer: {
                let rng = ring::rand::SystemRandom::new();
                let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
                Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
            },
            _tmp: tmp,
        };
        for d in [&s.data, &s.site, &s.cache] {
            std::fs::create_dir_all(d).unwrap();
        }
        s.pin_to("9.1.0");
        s.write("fake/clusters.json", r#"["east", "west"]"#);
        s.write(
            "fake/packages.json",
            r#"[{"name": "web", "status": "installed [shop]"},
                {"name": "db", "status": "installed [shop]"},
                {"name": "echo-server", "status": "available"}]"#,
        );
        for cluster in ["east", "west"] {
            s.manifest("out", cluster, "Deployment", "web", "web", "image: web:1");
            s.manifest(
                "out",
                cluster,
                "ClusterRole",
                "db-reader",
                "db",
                "rules: []",
            );
        }
        s
    }

    fn write(&self, rel: &str, text: &str) {
        let path = self.project.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn read(&self, rel: &str) -> String {
        std::fs::read_to_string(self.project.join(rel)).unwrap()
    }

    /// Write a flake.nix whose `kix` input is `url` and lock it.
    fn flake(&self, url: &str) {
        self.write("flake.nix", &project_flake(&[("kix", url)]));
        lock_flake(&self.project);
    }

    /// Pin the project to the library tag of `version`, as a person would.
    fn pin_to(&self, version: &str) {
        self.flake(&format!("{}?ref=refs/tags/v{version}", self.library));
    }

    /// Return the version the project's flake.lock pins.
    fn pinned(&self) -> String {
        match kix::flake_lock::project_kix(&self.project, &[]) {
            Ok(kix::flake_lock::ProjectKix::Release(v)) => v.release(),
            other => panic!("flake.lock pins no release: {other:?}"),
        }
    }

    /// Write one exported object of `cluster` under `fake/<out>`.
    fn manifest(
        &self,
        out: &str,
        cluster: &str,
        kind: &str,
        name: &str,
        package: &str,
        spec: &str,
    ) {
        let namespace = if kind == "ClusterRole" {
            "_cluster"
        } else {
            "shop"
        };
        let ns_line = if kind == "ClusterRole" {
            String::new()
        } else {
            "  namespace: shop\n".to_string()
        };
        self.write(
            &format!("fake/{out}/{cluster}/{namespace}/{kind}-{name}.yaml"),
            &format!(
                "apiVersion: v1\nkind: {kind}\nmetadata:\n  name: {name}\n{ns_line}  annotations:\n    {key}: {package}\nspec:\n  {spec}\n",
                key = kix::manifest::keys::PACKAGE
            ),
        );
    }

    /// Copy `fake/out` to `fake/out-<version>` so a test can change one
    /// version's builds.
    fn out_for(&self, version: &str) {
        let from = self.project.join("fake/out");
        let to = self.project.join(format!("fake/out-{version}"));
        copy_dir(&from, &to);
    }

    fn calls(&self) -> String {
        std::fs::read_to_string(self.project.join("fake/calls.log")).unwrap_or_default()
    }

    fn kix(&self) -> Command {
        let mut cmd = Command::new(assert_cmd::cargo::cargo_bin("kix"));
        cmd.env("NO_COLOR", "true")
            .env("KIX_DATA_DIR", &self.data)
            .env("KIX_RELEASE_SOURCE", &self.site)
            .env(
                "KIX_RELEASE_TEST_KEY",
                hex(self.signer.public_key().as_ref()),
            )
            .env("XDG_CACHE_HOME", &self.cache)
            .env_remove("KIX_SELECTED_BY")
            .env_remove("KIX_AUTO_INSTALL")
            .env_remove("KIX_FLAKE")
            .arg("--flake")
            .arg(&self.project);
        cmd
    }

    fn upgrade(&self, args: &[&str]) -> (i32, String) {
        let out = self.kix().arg("upgrade").args(args).output().unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        (out.status.code().unwrap_or(-1), text)
    }

    fn state(&self) -> serde_json::Value {
        serde_json::from_str(&self.read("kix-upgrade.json")).unwrap()
    }

    fn installed(&self) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(&self.data)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.chars().next().is_some_and(|c| c.is_ascii_digit()))
            .collect();
        v.sort();
        v
    }

    /// Publish a fake Kix `version` of `date` on the site, with `records` as
    /// its change records, or none when `records` is `None`.
    fn publish(&self, version: &str, date: &str, records: Option<serde_json::Value>) {
        let system = kix::release::system().unwrap();
        let file = format!("kix-{system}.tar.gz");
        let download = self.site.join("download").join(version);
        std::fs::create_dir_all(&download).unwrap();
        let archive = download.join(&file);
        let script = FAKE.replace("__VERSION__", version);
        let gz = flate2::write::GzEncoder::new(
            std::fs::File::create(&archive).unwrap(),
            flate2::Compression::fast(),
        );
        let mut tar = tar::Builder::new(gz);
        let mut header = tar::Header::new_gnu();
        header.set_size(script.len() as u64);
        header.set_mode(0o755);
        tar.append_data(
            &mut header,
            format!("kix-{version}-{system}/bin/kix"),
            script.as_bytes(),
        )
        .unwrap();
        tar.into_inner().unwrap().finish().unwrap();

        let mut sums = format!(
            "{}  {file}\n",
            hex(&Sha256::digest(std::fs::read(&archive).unwrap()))
        );
        if let Some(mut records) = records {
            // The script always writes these two fields.
            for r in records.as_array_mut().unwrap() {
                for key in ["touchesData", "requiredStop"] {
                    if r.get(key).is_none() {
                        r[key] = serde_json::json!(false);
                    }
                }
            }
            let doc = serde_json::json!({
                "schema": kix::changes::SCHEMA,
                "version": version,
                "records": records,
            })
            .to_string();
            let name = format!("kix-{version}-changes.json");
            std::fs::write(download.join(&name), &doc).unwrap();
            sums.push_str(&format!(
                "{}  {name}\n",
                hex(&Sha256::digest(doc.as_bytes()))
            ));
        }
        let releases = self.site.join("releases").join(format!("v{version}"));
        std::fs::create_dir_all(&releases).unwrap();
        std::fs::write(releases.join("SHA256SUMS"), &sums).unwrap();
        let key: [u8; 32] = self.signer.public_key().as_ref().try_into().unwrap();
        std::fs::write(
            releases.join("SHA256SUMS.sig"),
            format!(
                "kix-release-signature v1\nkeyid={}\nsignature={}\n",
                kix::release::verify::keyid(&key),
                base64::engine::general_purpose::STANDARD
                    .encode(self.signer.sign(sums.as_bytes()).as_ref())
            ),
        )
        .unwrap();

        let index_path = self.site.join("releases").join("index.json");
        let mut index: serde_json::Value = std::fs::read_to_string(&index_path)
            .map(|t| serde_json::from_str(&t).unwrap())
            .unwrap_or_else(|_| serde_json::json!({"latest": null, "releases": []}));
        index["latest"] = serde_json::json!(version);
        index["releases"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!({
                "version": version,
                "date": date,
                "systems": [system],
                "sums": format!("/releases/v{version}/SHA256SUMS"),
                "signature": format!("/releases/v{version}/SHA256SUMS.sig"),
                "download": format!("/download/{version}/"),
            }));
        std::fs::write(index_path, index.to_string()).unwrap();
    }

    /// Publish 9.1.0, 9.2.0, 9.2.1, and 9.3.0, each dated long ago. 9.2.0
    /// renames an option of `web` (K0001) and the flag `--old-flag`. 9.2.1
    /// has no change records. `extra` adds records to 9.3.0.
    fn releases(&self, extra: Vec<serde_json::Value>) {
        self.publish("9.1.0", "2026-01-01", Some(serde_json::json!([])));
        self.publish(
            "9.2.0",
            "2026-02-01",
            Some(serde_json::json!([{
                "name": "rename-replica-count",
                "kind": "error",
                "id": "K0001",
                "packages": ["web"],
                "cli": ["--old-flag"],
                "body": "`web` renames `replicaCount` to `replicas`. Set `replicas` instead.",
            }, {
                "name": "echo-only",
                "kind": "error",
                "id": "K0002",
                "packages": ["echo-server"],
                "body": "`echo-server` renames `port`.",
            }, {
                "name": "new-thing",
                "kind": "added",
                "body": "A new thing.",
            }])),
        );
        self.publish("9.2.1", "2026-02-10", None);
        self.publish("9.3.0", "2026-03-01", Some(serde_json::Value::Array(extra)));
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let dest = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &dest);
        } else {
            std::fs::copy(entry.path(), dest).unwrap();
        }
    }
}

/// Change the web Deployment in 9.3.0's builds, which K0001 explains.
fn explained_change(s: &Setup) {
    s.out_for("9.3.0");
    for cluster in ["east", "west"] {
        s.manifest(
            "out-9.3.0",
            cluster,
            "Deployment",
            "web",
            "web",
            "image: web:2",
        );
    }
}

#[test]
fn dry_run_lists_the_steps_and_records_and_changes_nothing() {
    let s = Setup::new();
    s.releases(vec![]);
    let (code, out) = s.upgrade(&["--dry-run"]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.starts_with("Kix 9.1.0 -> 9.3.0 (dry run, no files changed)\n"),
        "{out}"
    );
    assert!(
        out.contains("Release 9.2.1 predated structured release notes"),
        "{out}"
    );
    // Kix 9.1.0 is not installed, so every change counts.
    assert!(out.contains("current Kix 9.1.0 is not installed"), "{out}");
    assert!(
        out.contains("    [K0001] web (9.2.0): `web` renames"),
        "{out}"
    );
    assert!(out.contains("    [K0002] echo-server (9.2.0)"), "{out}");
    assert!(
        out.contains("Check scripts and CI for `--old-flag`."),
        "{out}"
    );
    assert!(out.ends_with("Next: run `kix upgrade`.\n"), "{out}");
    // The steps are printed only with -v.
    assert!(!out.contains("Stepping plan"), "{out}");
    assert_eq!(s.pinned(), "9.1.0");
    assert!(!s.project.join("kix-upgrade.json").exists());
    assert!(s.installed().is_empty());
}

#[test]
fn dry_run_asks_the_installed_kix_which_packages_are_in_use() {
    let s = Setup::new();
    s.releases(vec![]);
    let bin = s.data.join("9.1.0/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("kix"), FAKE.replace("__VERSION__", "9.1.0")).unwrap();
    std::fs::set_permissions(bin.join("kix"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let (code, out) = s.upgrade(&["--dry-run"]);
    assert_eq!(code, 0, "{out}");
    // Every note is listed. The one whose package an instance is named
    // after is marked as a likely match.
    assert!(out.contains("2 changes between 9.1.0 and 9.3.0:\n  * may affect your 2 clusters (package name matches an instance in use)\n"), "{out}");
    assert!(out.contains("  * [K0001] web (9.2.0):"), "{out}");
    assert!(out.contains("    [K0002] echo-server (9.2.0):"), "{out}");
    assert!(
        s.calls().contains("9.1.0 list packages east"),
        "{}",
        s.calls()
    );
}

#[test]
fn nothing_to_upgrade_exits_0() {
    let s = Setup::new();
    s.releases(vec![]);
    s.pin_to("9.3.0");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    assert_eq!(
        out,
        "Already on the latest Kix release (9.3.0). Nothing to upgrade.\n"
    );
}

#[test]
fn a_jump_that_builds_pins_the_target_and_removes_nothing_it_keeps() {
    let s = Setup::new();
    s.releases(vec![]);
    explained_change(&s);
    let (code, out) = s.upgrade(&[]);
    // Any changed object needs a person.
    assert_eq!(code, 3, "{out}");
    assert_eq!(s.pinned(), "9.3.0");
    assert!(out.starts_with("Upgrading Kix 9.1.0 -> 9.3.0\n"), "{out}");
    assert!(
        out.contains("Building 2 clusters with current Kix 9.1.0 (east, west)... ok"),
        "{out}"
    );
    assert!(
        out.contains("Upgrading Kix 9.1.0 -> 9.3.0\nNote: Kix 9.2.1 has no release notes; see CHANGELOG.md.\n"),
        "{out}"
    );
    assert!(
        out.contains("  east, west:\n    ~ Deployment/web@shop (web)\n"),
        "{out}"
    );
    assert!(
        out.ends_with("Upgraded to Kix 9.3.0, but review before deploying:\n  1. 2 objects changed in clusters east, west; read the changes above, or run\n     `kix plan <cluster>`, before you deploy.\n"),
        "{out}"
    );
    let calls = s.calls();
    assert!(calls.contains("9.1.0 export east"), "{calls}");
    assert!(calls.contains("9.3.0 export west"), "{calls}");
    assert!(!calls.contains("9.2.1"), "{calls}");
    assert_eq!(s.installed(), ["9.1.0", "9.3.0"]);
    let state = s.state();
    assert_eq!(
        state["schema"],
        format!("{}/upgrade/v1", kix::manifest::keys::DOMAIN)
    );
    assert_eq!(state["status"], "needs-person");
    assert_eq!(state["from"], "9.1.0");
    assert_eq!(state["to"], "9.3.0");
    assert_eq!(
        state["records"]["error"],
        serde_json::json!(["K0001", "K0002"])
    );
    assert!(state.get("unexplainedChanges").is_none());
    assert_eq!(state["sensitiveChanges"], 0);
}

#[test]
fn a_failed_jump_steps_and_stops_at_the_first_failing_minor_then_resumes() {
    let s = Setup::new();
    s.releases(vec![]);
    s.write("fake/fail-9.2.1", "");
    s.write("fake/fail-9.3.0", "");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 2, "{out}");
    assert!(
        out.contains("Building 2 clusters with Kix 9.3.0... failed (east, west)\nStepping one minor release at a time (9.2.1 -> 9.3.0):"),
        "{out}"
    );
    assert!(
        out.contains("  Cluster east:\n    error: [K0001] cluster east sets replicaCount, which Kix 9.2.1 renamed\n    Full build log: "),
        "{out}"
    );
    assert!(
        out.contains("  Config changes required in Kix 9.2.0:\n    * may affect this project (package name matches an instance in use)\n  * [K0001] web:"),
        "{out}"
    );
    assert!(
        out.contains("Stopped at Kix 9.2.1 (step 1 of 2 toward 9.3.0)."),
        "{out}"
    );
    assert!(
        out.ends_with("Next: fix the error above, then run `kix upgrade` to continue to 9.3.0.\n"),
        "{out}"
    );
    assert_eq!(s.pinned(), "9.2.1");
    let state = s.state();
    assert_eq!(state["status"], "fix-needed");
    let steps: Vec<(String, String)> = state["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|st| {
            (
                st["version"].as_str().unwrap().into(),
                st["result"].as_str().unwrap().into(),
            )
        })
        .collect();
    assert_eq!(
        steps,
        [
            ("9.3.0".to_string(), "failed".to_string()),
            ("9.2.1".to_string(), "failed".to_string())
        ]
    );
    // 9.3.0 was installed only to try the jump.
    assert_eq!(s.installed(), ["9.1.0", "9.2.1"]);

    // The user fixes the project for 9.2.1. The next run reuses the builds
    // from 9.1.0 and stops at 9.3.0.
    std::fs::remove_file(s.project.join("fake/fail-9.2.1")).unwrap();
    std::fs::remove_file(s.project.join("fake/calls.log")).unwrap();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 2, "{out}");
    assert!(
        out.starts_with(
            "Resuming upgrade Kix 9.1.0 -> 9.3.0 (from 9.2.1, reusing 9.1.0 baseline)\n"
        ),
        "{out}"
    );
    assert!(!s.calls().contains("9.1.0 export"), "{}", s.calls());
    assert_eq!(s.pinned(), "9.3.0");
    // A resume does not repeat the note about releases without notes.
    assert!(!out.contains("no release notes"), "{out}");
    // The failing step is the target, so there is nothing to continue to.
    assert!(
        out.contains("Stopped at Kix 9.3.0 (step 2 of 2).\nflake.nix and flake.lock are pinned to 9.3.0 so you can fix the build.\nNext: fix the error above, then run `kix upgrade` to finish the upgrade.\n"),
        "{out}"
    );

    std::fs::remove_file(s.project.join("fake/fail-9.3.0")).unwrap();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    assert_eq!(s.state()["status"], "done");
    assert_eq!(s.pinned(), "9.3.0");
}

#[test]
fn a_required_stop_ends_the_upgrade_at_that_minor() {
    let s = Setup::new();
    s.publish("9.1.0", "2026-01-01", None);
    s.publish(
        "9.2.0",
        "2026-02-01",
        Some(serde_json::json!([{
            "name": "move-records",
            "kind": "note",
            "state": true,
            "requiredStop": true,
            "body": "Kix moves its records.",
        }])),
    );
    s.publish("9.2.1", "2026-02-10", None);
    s.publish("9.3.0", "2026-03-01", None);
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    assert!(
        out.ends_with("Next: commit this 9.2.1 step and deploy every cluster with `kix deploy <cluster>`, then run `kix upgrade` to continue to 9.3.0.\n"),
        "{out}"
    );
    assert_eq!(s.pinned(), "9.2.1");
    assert_eq!(s.state()["status"], "required-stop");
}

#[test]
fn min_age_in_kix_toml_skips_new_releases() {
    let s = Setup::new();
    s.publish("9.1.0", "2026-01-01", None);
    s.publish("9.2.0", "2026-02-01", None);
    let today = chrono::Utc::now()
        .date_naive()
        .format("%Y-%m-%d")
        .to_string();
    s.publish("9.3.0", &today, None);
    let (_, out) = s.upgrade(&["--dry-run"]);
    assert!(out.starts_with("Kix 9.1.0 -> 9.3.0 (dry run"), "{out}");
    s.write("kix.toml", "[upgrade]\nmin-age = \"7d\"\n");
    let (_, out) = s.upgrade(&["--dry-run"]);
    assert!(out.starts_with("Kix 9.1.0 -> 9.2.0 (dry run"), "{out}");
    // The flag is gone: the delay is a project setting.
    let (code, out) = s.upgrade(&["--dry-run", "--min-age", "0d"]);
    assert_eq!(code, 1, "{out}");
    // A malformed value is refused.
    s.write("kix.toml", "[upgrade]\nmin-age = \"1w\"\n");
    let (code, out) = s.upgrade(&["--dry-run"]);
    assert_eq!(code, 1, "{out}");
}

#[test]
fn a_sensitive_change_needs_a_person() {
    let s = Setup::new();
    s.releases(vec![]);
    s.out_for("9.3.0");
    s.manifest(
        "out-9.3.0",
        "west",
        "ClusterRole",
        "db-reader",
        "db",
        "rules: [x]",
    );
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    assert!(out.contains("  east: no objects changed\n"), "{out}");
    assert!(
        out.contains("  west:\n    ~ ClusterRole/db-reader (db) [review: ClusterRole]\n"),
        "{out}"
    );
    assert!(
        out.contains("Upgraded to Kix 9.3.0, but review before deploying:\n  1. 1 ClusterRole changed in cluster west (ClusterRole/db-reader).\n  2. 1 object changed in cluster west; read the changes above, or run `kix plan\n     west`, before you deploy.\n"),
        "{out}"
    );
    let state = s.state();
    assert_eq!(state["status"], "needs-person");
    assert_eq!(state["sensitiveChanges"], 1);
}

#[test]
fn lines_that_use_a_changed_flag_are_listed() {
    let s = Setup::new();
    s.releases(vec![]);
    s.write("ci/deploy.sh", "set -e\nkix deploy east --old-flag\n");
    s.write("CHANGELOG.md", "--old-flag\n");
    let git = |args: &[&str]| {
        let st = std::process::Command::new("git")
            .args(args)
            .current_dir(&s.project)
            .output()
            .unwrap();
        assert!(st.status.success(), "{st:?}");
    };
    git(&["init", "-q"]);
    git(&["add", "-A"]);
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.contains(
            "Project files matching changed commands or flags:\n  ci/deploy.sh:2: --old-flag"
        ),
        "{out}"
    );
    assert!(!out.contains("CHANGELOG.md:"), "{out}");
    assert_eq!(s.state()["cliHits"][0]["file"], "ci/deploy.sh");
}

#[test]
fn a_data_change_stops_deploys_until_acknowledged() {
    let s = Setup::new();
    s.releases(vec![serde_json::json!({
        "name": "move-data",
        "kind": "silent",
        "packages": ["db"],
        "touchesData": true,
        "body": "`db` keeps its data in a new volume.",
    })]);
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    assert!(out.contains("kix upgrade --acknowledge move-data"), "{out}");

    // Set as if selection chose this Kix, which it does in a real project.
    let chosen = |mut cmd: Command| {
        cmd.env("KIX_SELECTED_BY", "/usr/bin/kix");
        cmd
    };
    chosen(s.kix())
        .args(["deploy", "east"])
        .assert()
        .code(1)
        .stderr(predicate::str::starts_with(
            "Deploy blocked: upgrade to Kix 9.3.0 includes an unacknowledged data migration.",
        ))
        .stderr(predicate::str::contains(
            "  [move-data] (9.3.0, moves stored data):\n    `db` keeps its data in a new volume.",
        ))
        .stderr(predicate::str::contains(
            "  kix upgrade --acknowledge move-data\n",
        ));

    s.kix()
        .args(["upgrade", "--acknowledge", "nope"])
        .assert()
        .code(1)
        .stdout(predicate::str::contains("(pending: move-data)"));
    s.kix()
        .args(["upgrade", "--acknowledge", "move-data"])
        .assert()
        .success()
        .stdout("Acknowledged move-data in kix-upgrade.json. You can now run `kix deploy`.\n");
    assert_eq!(s.state()["acknowledged"], serde_json::json!(["move-data"]));

    // The deploy now goes past the check and starts to build, which stops
    // at once for want of a Kix runtime.
    let runtime = s.cache.join("empty-runtime");
    std::fs::create_dir_all(&runtime).unwrap();
    let out = chosen(s.kix())
        .env("KIX_RUNTIME_DIR", &runtime)
        .args(["deploy", "east"])
        .output()
        .unwrap();
    let all = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(all.contains("Building cluster 'east'"), "{all}");
    assert!(!all.contains("move-data"), "{all}");
}

#[test]
fn a_prerelease_project_steps_through_its_own_release() {
    let s = Setup::new();
    s.releases(vec![]);
    s.pin_to("9.1.0-rc.1");
    let (code, out) = s.upgrade(&["--dry-run", "-v"]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.starts_with("Kix 9.1.0-rc.1 -> 9.3.0 (dry run, no files changed)\n"),
        "{out}"
    );
    assert!(
        out.contains("Stepping plan if direct jump fails: 9.1.0, 9.2.1, 9.3.0 (3 versions would be installed)."),
        "{out}"
    );
}

/// Run `kix deploy east` as the Kix selection chose, with an empty Kix
/// runtime so that a deploy past the check stops as it starts to build,
/// and return its exit code and output.
fn deploy(s: &Setup) -> (i32, String) {
    let runtime = s.cache.join("empty-runtime");
    std::fs::create_dir_all(&runtime).unwrap();
    let out = s
        .kix()
        .env("KIX_SELECTED_BY", "/usr/bin/kix")
        .env("KIX_RUNTIME_DIR", &runtime)
        .args(["deploy", "east"])
        .output()
        .unwrap();
    (
        out.status.code().unwrap_or(-1),
        format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ),
    )
}

fn data_record(name: &str, package: &str) -> serde_json::Value {
    serde_json::json!({
        "name": name,
        "kind": "silent",
        "packages": [package],
        "touchesData": true,
        "body": "Data moves.",
    })
}

#[test]
fn a_silent_record_applies_whatever_the_instance_is_called() {
    let s = Setup::new();
    // No instance is called `postgres`: the cluster's database instance is `db`.
    s.releases(vec![data_record("move-pg-data", "postgres")]);
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    let state = s.state();
    assert_eq!(state["status"], "needs-person");
    assert_eq!(state["dataChanges"][0]["reference"], "move-pg-data");
    let (code, out) = deploy(&s);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("move-pg-data"), "{out}");
}

#[test]
fn a_silent_record_without_data_needs_a_person_and_does_not_block_deploys() {
    let s = Setup::new();
    s.releases(vec![serde_json::json!({
        "name": "new-default",
        "kind": "silent",
        "packages": ["web"],
        "body": "A default changes.",
    })]);
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    let state = s.state();
    assert_eq!(state["status"], "needs-person");
    assert_eq!(
        state["records"]["silent"],
        serde_json::json!(["new-default"])
    );
    assert_eq!(state["dataChanges"], serde_json::json!([]));
    let (_, out) = deploy(&s);
    assert!(out.contains("Building cluster 'east'"), "{out}");
}

#[test]
fn a_second_upgrade_waits_for_acknowledged_data_changes() {
    let s = Setup::new();
    s.releases(vec![data_record("move-data", "db")]);
    let (code, _) = s.upgrade(&["--to", "9.2.1"]);
    // 9.2.1 carries no data change; the first upgrade stops at 9.2.1.
    assert_eq!(code, 0);
    s.upgrade(&[]);
    assert_eq!(s.pinned(), "9.3.0");
    let before = s.read("kix-upgrade.json");

    s.publish("9.4.0", "2026-04-01", Some(serde_json::json!([])));
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("--acknowledge move-data"), "{out}");
    assert_eq!(s.read("kix-upgrade.json"), before);
    assert_eq!(s.pinned(), "9.3.0");

    s.kix()
        .args(["upgrade", "--acknowledge", "move-data"])
        .assert()
        .success();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    assert_eq!(s.pinned(), "9.4.0");
    // An acknowledgement belongs to the upgrade it was given for.
    assert_eq!(s.state()["acknowledged"], serde_json::json!([]));
}

#[test]
fn resuming_works_out_a_required_stop_again() {
    let s = Setup::new();
    s.publish("9.1.0", "2026-01-01", None);
    s.publish(
        "9.2.0",
        "2026-02-01",
        Some(serde_json::json!([{
            "name": "move-records",
            "kind": "note",
            "state": true,
            "requiredStop": true,
            "body": "Kix moves its records.",
        }])),
    );
    s.publish("9.2.1", "2026-02-10", None);
    s.publish("9.3.0", "2026-03-01", None);
    s.write("fake/fail-9.2.1", "");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 2, "{out}");
    assert_eq!(s.state()["status"], "fix-needed");
    assert_eq!(s.state()["to"], "9.2.1");

    std::fs::remove_file(s.project.join("fake/fail-9.2.1")).unwrap();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    assert_eq!(s.state()["status"], "required-stop");
    assert_eq!(s.pinned(), "9.2.1");
}

#[test]
fn resuming_without_the_first_builds_is_refused() {
    let s = Setup::new();
    s.releases(vec![]);
    s.write("fake/fail-9.3.0", "");
    s.write("fake/fail-9.2.1", "");
    let (code, _) = s.upgrade(&[]);
    assert_eq!(code, 2);
    let before = std::path::PathBuf::from(s.state()["before"].as_str().unwrap());
    std::fs::remove_dir_all(&before).unwrap();
    std::fs::remove_file(s.project.join("fake/calls.log")).unwrap();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("kix-upgrade.json"), "{out}");
    assert_eq!(s.calls(), "", "Kix built nothing");
    assert_eq!(s.pinned(), "9.2.1");
}

#[test]
fn pruning_leaves_a_version_installed_before_the_run() {
    let s = Setup::new();
    s.releases(vec![]);
    let bin = s.data.join("9.2.1/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("kix"), FAKE.replace("__VERSION__", "9.2.1")).unwrap();
    std::fs::set_permissions(bin.join("kix"), std::fs::Permissions::from_mode(0o755)).unwrap();
    s.write("fake/fail-9.3.0", "");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 2, "{out}");
    assert_eq!(s.pinned(), "9.3.0");
    assert_eq!(s.installed(), ["9.1.0", "9.2.1", "9.3.0"]);
}

#[test]
fn an_explained_sensitive_change_still_needs_a_person() {
    let s = Setup::new();
    s.releases(vec![serde_json::json!({
        "name": "db-reader-rules",
        "kind": "changed",
        "packages": ["db"],
        "body": "`db` reads more.",
    })]);
    s.out_for("9.3.0");
    for cluster in ["east", "west"] {
        s.manifest(
            "out-9.3.0",
            cluster,
            "ClusterRole",
            "db-reader",
            "db",
            "rules: [x]",
        );
    }
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    let state = s.state();
    assert_eq!(state["sensitiveChanges"], 2);
    assert_eq!(state["status"], "needs-person");
}

#[test]
fn a_plain_change_needs_a_person() {
    let s = Setup::new();
    s.releases(vec![]);
    s.out_for("9.3.0");
    s.manifest("out-9.3.0", "east", "ConfigMap", "extra", "web", "data: {}");
    s.manifest(
        "out-9.3.0",
        "east",
        "ConfigMap",
        "cache",
        "cache",
        "data: {}",
    );
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    let state = s.state();
    assert_eq!(state["status"], "needs-person");
    assert_eq!(state["sensitiveChanges"], 0);
    assert!(
        out.contains("  1. 2 objects changed in cluster east;"),
        "{out}"
    );
}

#[test]
fn an_interrupted_run_leaves_a_state_and_resumes() {
    let s = Setup::new();
    s.releases(vec![]);
    s.write("fake/fail-9.3.0", "");
    let system = kix::release::system().unwrap();
    let archive = s.site.join(format!("download/9.2.1/kix-{system}.tar.gz"));
    let hidden = archive.with_extension("hidden");
    std::fs::rename(&archive, &hidden).unwrap();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 1, "{out}");
    assert!(
        out.contains("Installing Kix 9.2.1... failed\n\nCannot download Kix 9.2.1: "),
        "{out}"
    );
    assert!(
        out.ends_with(
            "Next: check your network connection, then run `kix upgrade` to resume at Kix 9.2.1.\n"
        ),
        "{out}"
    );
    let state = s.state();
    assert_eq!(state["status"], "fix-needed");
    let last = state["steps"].as_array().unwrap().last().unwrap().clone();
    assert_eq!(last["version"], "9.2.1");
    assert_eq!(last["result"], "started");

    std::fs::rename(&hidden, &archive).unwrap();
    std::fs::remove_file(s.project.join("fake/fail-9.3.0")).unwrap();
    std::fs::remove_file(s.project.join("fake/calls.log")).unwrap();
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    // The project is pinned to the target from the failed jump, so the
    // opening line names no step.
    assert!(
        out.starts_with("Resuming upgrade Kix 9.1.0 -> 9.3.0 (reusing 9.1.0 baseline)\n\n"),
        "{out}"
    );
    assert!(
        out.ends_with("Upgraded to Kix 9.3.0. Ready to deploy.\n"),
        "{out}"
    );
    assert!(!s.calls().contains("9.1.0 "), "{}", s.calls());
    assert!(s.calls().contains("9.2.1 export"), "{}", s.calls());
    assert_eq!(s.state()["status"], "done");
    assert_eq!(s.pinned(), "9.3.0");
}

/// Run `git` in `dir` with an identity and without signing.
fn git(dir: &Path, args: &[&str]) {
    let out = std::process::Command::new("git")
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
}

/// The versions the test library repository has a tag for.
const LIBRARY_VERSIONS: &[&str] = &[
    "9.1.0-rc.1",
    "9.1.0",
    "9.2.0-rc.1",
    "9.2.0",
    "9.2.1",
    "9.3.0",
    "9.4.0",
];

/// Return a project flake.nix with `inputs` (name and url), whose Kix
/// library is the input `kix`, or else the first input.
fn project_flake(inputs: &[(&str, &str)]) -> String {
    let lines: String = inputs
        .iter()
        .map(|(name, url)| format!("  inputs.{name}.url = \"{url}\";\n"))
        .collect();
    let library = inputs
        .iter()
        .find(|(name, _)| *name == "kix")
        .unwrap_or(&inputs[0])
        .0;
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
    )
}

/// Make a Kix library repository in `dir` with a tag `v<version>` for each
/// of `versions`, and return its flake url.
fn library_repo(dir: &Path, versions: &[&str]) -> String {
    std::fs::create_dir_all(dir).unwrap();
    git(dir, &["init", "-q", "-b", "main"]);
    std::fs::write(
        dir.join("flake.nix"),
        "{ outputs = _: { version = builtins.readFile ./VERSION; }; }\n",
    )
    .unwrap();
    for version in versions {
        std::fs::write(dir.join("VERSION"), version).unwrap();
        git(dir, &["add", "-A"]);
        git(dir, &["commit", "-q", "-m", version]);
        git(dir, &["tag", &format!("v{version}")]);
    }
    format!("git+file://{}", dir.display())
}

/// Lock the project's flake with the Nix in the Kix runtime.
fn lock_flake(dir: &Path) {
    let nix =
        kix::runtime::program_path(kix::runtime::Tool::Nix, kix::runtime::Want::Shipped).unwrap();
    let out = std::process::Command::new(nix)
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "flake",
            "lock",
        ])
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(out.status.success(), "nix flake lock: {out:?}");
}

/// Needs a Kix runtime (`KIX_RUNTIME_DIR` in the development shell), since
/// Kix reads the library input with Nix.
/// Needs a Kix runtime (`KIX_RUNTIME_DIR` in the development shell), since
/// Kix reads the library input with Nix.
#[test]
fn two_inputs_on_one_tag_stop_for_an_edit_before_installing() {
    let s = Setup::new();
    s.releases(vec![]);
    let url = format!("{}?ref=refs/tags/v9.1.0", s.library);
    let flake = project_flake(&[("kix", &url), ("image-kix", &url)]);
    s.write("flake.nix", &flake);
    lock_flake(&s.project);
    let lock = s.read("flake.lock");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 3, "{out}");
    assert!(
        out.contains(&format!(
            "Cannot update flake.nix automatically: two inputs use the Kix library's repository:\n  flake.nix:2:   inputs.kix.url = \"{url}\";\n  flake.nix:3:   inputs.image-kix.url"
        )),
        "{out}"
    );
    assert!(
        out.contains("flake.nix and flake.lock were not changed. Upgrade state is saved in kix-upgrade.json (the 9.1.0 baseline build is cached)."),
        "{out}"
    );
    assert!(
        out.trim_end().ends_with("then run `kix upgrade` again."),
        "{out}"
    );
    assert_eq!(s.state()["status"], "edit-needed");
    assert_eq!(s.read("flake.nix"), flake);
    assert_eq!(s.read("flake.lock"), lock);
    assert_eq!(s.installed(), ["9.1.0"]);

    // After the person's edit, the rerun resumes from the version the
    // project is still on, locks the tag, and finishes.
    s.write("flake.nix", &flake.replacen("v9.1.0", "v9.3.0", 1));
    let (code, out) = s.upgrade(&[]);
    assert!(
        out.starts_with("Resuming upgrade Kix 9.1.0 -> 9.3.0 (reusing 9.1.0 baseline)\n"),
        "{out}"
    );
    assert!(
        out.contains("Pinned project to Kix 9.3.0 (updated flake.lock)"),
        "{out}"
    );
    assert_eq!(code, 0, "{out}");
    assert_eq!(s.pinned(), "9.3.0");
}

#[test]
fn a_project_that_does_not_build_now_is_left_alone() {
    let s = Setup::new();
    s.releases(vec![]);
    s.write("fake/fail-9.1.0", "");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 2, "{out}");
    assert!(
        out.contains("Building 2 clusters with current Kix 9.1.0 (east, west)... failed (2 of 2 failed: east, west)"),
        "{out}"
    );
    assert!(
        out.contains("Cannot start upgrade: clusters east, west do not build with your current Kix 9.1.0.\nNo project files were modified.\nNext: fix the build on Kix 9.1.0, then run `kix upgrade` again.\n"),
        "{out}"
    );
    assert_eq!(s.pinned(), "9.1.0");
    assert!(!s.project.join("kix-upgrade.json").exists());
}

#[test]
fn a_security_note_shows_its_cves_and_workaround() {
    let s = Setup::new();
    s.releases(vec![serde_json::json!({
        "name": "tls-fix",
        "kind": "security",
        "packages": ["web"],
        "cve": ["CVE-2026-0001"],
        "workaround": "Set `tls.minVersion` to 1.3.",
        "body": "`web` no longer accepts TLS 1.0.",
    })]);
    let (code, out) = s.upgrade(&["--dry-run"]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.contains("  Security fixes (builds cleanly, recommended for this upgrade):\n    [tls-fix] web (9.3.0, CVE-2026-0001): `web` no longer accepts TLS 1.0.\n      Without upgrading: Set `tls.minVersion` to 1.3.\n"),
        "{out}"
    );
}

#[test]
fn a_range_without_listed_notes_says_so() {
    let s = Setup::new();
    s.publish("9.1.0", "2026-01-01", Some(serde_json::json!([])));
    s.publish(
        "9.2.0",
        "2026-02-01",
        Some(serde_json::json!([{"name": "a", "kind": "fixed", "body": "Fixed."}])),
    );
    let (code, out) = s.upgrade(&["--dry-run"]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.contains("No breaking, security, or upgrade notes between 9.1.0 and 9.2.0.\n\n  1 minor feature or bugfix change"),
        "{out}"
    );
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.ends_with("Upgraded to Kix 9.2.0. Ready to deploy.\n"),
        "{out}"
    );
    assert_eq!(s.state()["status"], "done");
}

#[test]
fn the_kix_toml_delay_names_itself_when_nothing_is_old_enough() {
    let s = Setup::new();
    let today = chrono::Utc::now().date_naive();
    let day = |ago: i64| {
        (today - chrono::Duration::days(ago))
            .format("%Y-%m-%d")
            .to_string()
    };
    s.publish("9.1.0", &day(10), None);
    s.publish("9.2.0", &day(3), None);
    s.write("kix.toml", "[upgrade]\nmin-age = \"30d\"\n");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 1, "{out}");
    assert!(out.starts_with("No Kix release for "), "{out}");
    assert!(
        out.contains("is at least 30 days old (`min-age = \"30d\"` in kix.toml; newest release is 3 days old).\nNext: lower `min-age` in kix.toml"),
        "{out}"
    );
    s.write("kix.toml", "[upgrade]\nmin-age = \"7d\"\n");
    let (code, out) = s.upgrade(&[]);
    assert_eq!(code, 0, "{out}");
    assert_eq!(
        out,
        "Already on Kix 9.1.0 (matches target 9.1.0 for `min-age = \"7d\"` in kix.toml). Nothing to upgrade.\n"
    );
}

#[test]
fn a_prerelease_named_in_full_is_a_target() {
    let s = Setup::new();
    s.publish("9.1.0", "2026-01-01", None);
    s.publish("9.2.0-rc.1", "2026-01-02", None);
    s.pin_to("9.1.0");
    let (code, out) = s.upgrade(&["--to", "9.2.0-rc.1"]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.starts_with("Upgrading Kix 9.1.0 -> 9.2.0-rc.1\n"),
        "{out}"
    );
    assert_eq!(s.pinned(), "9.2.0-rc.1");

    // Without its full name, a prerelease is never chosen.
    let (code, out) = s.upgrade(&["--to", "9.2"]);
    assert_eq!(code, 1, "{out}");
}

#[test]
fn the_version_the_project_is_on_needs_no_release_index() {
    let s = Setup::new();
    // No release site: Kix must not read the index.
    let lock = s.read("flake.lock");
    let (code, out) = s.upgrade(&["--to", "9.1.0"]);
    assert_eq!(code, 0, "{out}");
    assert_eq!(out, "Already on Kix 9.1.0. Nothing to upgrade.\n");
    assert_eq!(s.read("flake.lock"), lock);
    assert!(!s.project.join("kix-upgrade.json").exists());
}

#[test]
fn a_project_that_pins_no_version_is_pinned_without_builds() {
    let s = Setup::new();
    // A local repository with no ref follows its checkout.
    s.flake(&s.library);
    let (code, out) = s.upgrade(&["--to", "9.3.0"]);
    assert_eq!(code, 0, "{out}");
    assert!(
        out.starts_with("Pinned the Kix library to 9.3.0 (updated flake.nix, flake.lock)."),
        "{out}"
    );
    assert!(out.ends_with("Commit flake.nix and flake.lock.\n"), "{out}");
    assert_eq!(s.pinned(), "9.3.0");
    assert!(
        s.read("flake.nix")
            .contains(&format!("{}?ref=refs/tags/v9.3.0", s.library)),
        "{}",
        s.read("flake.nix")
    );
    assert_eq!(s.calls(), "", "Kix built nothing");

    // Without a flake.lock, Kix creates it.
    std::fs::remove_file(s.project.join("flake.lock")).unwrap();
    let (code, out) = s.upgrade(&["--to", "9.2.1"]);
    assert_eq!(code, 0, "{out}");
    assert_eq!(s.pinned(), "9.2.1");
}

#[test]
fn the_old_input_name_and_the_kix_setting_are_refused() {
    let s = Setup::new();
    let url = format!("{}?ref=refs/tags/v9.1.0", s.library);
    s.write("flake.nix", &project_flake(&[("kixpkgs", &url)]));
    lock_flake(&s.project);
    let (code, out) = s.upgrade(&["--to", "9.3.0"]);
    assert_eq!(code, 1, "{out}");
    assert!(
        out.starts_with("[K9179] flake.nix names the Kix library input kixpkgs"),
        "{out}"
    );

    s.pin_to("9.1.0");
    s.write("kix.toml", "kix = \"9.1\"\n");
    let (code, out) = s.upgrade(&["--to", "9.3.0"]);
    assert_ne!(code, 0, "{out}");
    assert!(out.contains("[K4476]"), "{out}");
}
