//! `kix pin` with instance pins. None of these reach a registry: each pin is
//! written with `--digest`, and `check` runs `--offline`.

use std::path::PathBuf;

use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

fn digest(c: char) -> String {
    format!("sha256:{}", c.to_string().repeat(64))
}

/// A fresh directory for one test's pin file.
fn pins_file(test: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("kix-pin-test-{}-{test}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("pins.json")
}

fn read(path: &PathBuf) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn set_writes_an_instance_pin_as_version_2() {
    let file = pins_file("set");
    kix()
        .args(["pin", "set", "monitoring/grafana", "--init"])
        .args([
            "--repository",
            "docker.io/grafana/grafana",
            "--tag",
            "13.1.3",
        ])
        .args(["--digest", &digest('a')])
        .arg("--pins-file")
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("added monitoring/grafana image"));

    let doc = read(&file);
    assert_eq!(doc["version"], 2);
    let pin = &doc["instances"]["monitoring/grafana"]["image"];
    assert_eq!(pin["tag"], "13.1.3");
    assert_eq!(pin["digest"], digest('a'));

    // Moving the pin keeps the repository and needs no --init.
    kix()
        .args(["pin", "set", "monitoring/grafana", "--tag", "13.1.4"])
        .args(["--digest", &digest('b')])
        .arg("--pins-file")
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("updated monitoring/grafana image"));
    let pin = read(&file)["instances"]["monitoring/grafana"]["image"].clone();
    assert_eq!(pin["repository"], "docker.io/grafana/grafana");
    assert_eq!(pin["tag"], "13.1.4");
}

#[test]
fn set_names_another_option_with_option() {
    let file = pins_file("option");
    std::fs::write(
        &file,
        "{\"version\":1,\"managedBy\":\"kix pin\",\"images\":{}}\n",
    )
    .unwrap();
    // A new instance pin in an existing file needs a repository, and no
    // --init: evaluation refuses a pin for an instance the cluster lacks.
    kix()
        .args(["pin", "set", "monitoring/alloy", "--option", "server.image"])
        .args(["--tag", "v1", "--digest", &digest('c')])
        .arg("--pins-file")
        .arg(&file)
        .assert()
        .failure()
        .stderr(
            predicate::str::contains("a new pin needs a repository")
                .and(predicate::str::contains("--option"))
                .and(predicate::str::contains("server.image")),
        );
    kix()
        .args(["pin", "set", "monitoring/alloy", "--option", "server.image"])
        .args(["--repository", "docker.io/grafana/alloy", "--tag", "v1"])
        .args(["--digest", &digest('c')])
        .arg("--pins-file")
        .arg(&file)
        .assert()
        .success();
    assert_eq!(
        read(&file)["instances"]["monitoring/alloy"]["server.image"]["tag"],
        "v1"
    );
}

#[test]
fn option_is_refused_for_a_pin_name() {
    let file = pins_file("refuse");
    kix()
        .args(["pin", "set", "web", "--option", "image", "--init"])
        .args([
            "--repository",
            "r/web",
            "--tag",
            "1",
            "--digest",
            &digest('d'),
        ])
        .arg("--pins-file")
        .arg(&file)
        .assert()
        .failure()
        .stderr(predicate::str::contains("<namespace>/<instance>"));
}

#[test]
fn list_and_check_cover_both_maps() {
    let file = pins_file("list");
    for (key, repo) in [("web", "r/web"), ("apps/api", "r/api")] {
        kix()
            .args([
                "pin",
                "set",
                key,
                "--init",
                "--repository",
                repo,
                "--tag",
                "1",
            ])
            .args(["--digest", &digest('e')])
            .arg("--pins-file")
            .arg(&file)
            .assert()
            .success();
    }

    kix()
        .args(["pin", "list", "--pins-file"])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("web").and(predicate::str::contains("apps/api image")));

    kix()
        .args(["pin", "check", "--offline", "--pins-file"])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("2 pins checked, 0 failed"));

    // --key with an instance selects that instance's pins.
    kix()
        .args([
            "pin",
            "check",
            "--offline",
            "--key",
            "apps/api",
            "--pins-file",
        ])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("1 pins checked"));

    let listed: serde_json::Value = serde_json::from_slice(
        &kix()
            .args(["--output", "json", "pin", "list", "--pins-file"])
            .arg(&file)
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();
    assert_eq!(listed["images"]["web"]["repository"], "r/web");
    assert_eq!(
        listed["instances"]["apps/api"]["image"]["repository"],
        "r/api"
    );
}

/// A note describes the image it was written for: moving the pin drops it
/// and says so, setting the same image again keeps it, and `--note` with a
/// move sets the new one.
#[test]
fn moving_a_pin_drops_its_note() {
    let file = pins_file("note");
    let set = |tag: &str, d: char, note: Option<&str>| {
        let mut cmd = kix();
        cmd.args(["pin", "set", "monitoring/grafana", "--init"])
            .args(["--repository", "docker.io/grafana/grafana", "--tag", tag])
            .args(["--digest", &digest(d)])
            .arg("--pins-file")
            .arg(&file);
        if let Some(note) = note {
            cmd.args(["--note", note]);
        }
        cmd.assert().success()
    };
    let note =
        |file: &PathBuf| read(file)["instances"]["monitoring/grafana"]["image"]["note"].clone();

    set("13.1.3", 'a', Some("Held back: see the 13.1.4 regression."));
    // The same image again: the note stays.
    set("13.1.3", 'a', None);
    assert_eq!(note(&file), "Held back: see the 13.1.4 regression.");

    // A move: the note goes, and the output quotes it.
    set("13.1.5", 'b', None).stdout(predicate::str::contains(
        "dropped the note, which described the old image: Held back: see the 13.1.4 regression.",
    ));
    assert!(note(&file).is_null());

    // A move with a note of its own keeps that one.
    set("13.1.6", 'c', Some("Watch memory after this one."));
    assert_eq!(note(&file), "Watch memory after this one.");
}

#[test]
fn rm_removes_package_and_instance_pins_and_reverts_version_to_1() {
    let file = pins_file("rm");
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
            ])
            .args(["--digest", &digest('a')])
            .arg("--pins-file")
            .arg(&file)
            .assert()
            .success();
    }
    assert_eq!(read(&file)["version"], 2);

    kix()
        .args(["pin", "rm", "nginx", "--pins-file"])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("removed nginx"));
    assert!(read(&file)["images"]["nginx"].is_null());
    assert_eq!(read(&file)["version"], 2);

    kix()
        .args(["pin", "rm", "ns/app", "--pins-file"])
        .arg(&file)
        .assert()
        .success()
        .stdout(predicate::str::contains("removed ns/app image"));
    let doc = read(&file);
    assert_eq!(doc["version"], 1);
    assert!(doc.get("instances").is_none());

    kix()
        .args(["pin", "rm", "ns/app", "--pins-file"])
        .arg(&file)
        .assert()
        .failure()
        .stderr(
            predicate::str::contains("has no pin named")
                .and(predicate::str::contains("'ns/app image'")),
        );
}
