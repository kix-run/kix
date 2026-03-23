use assert_cmd::Command;
use predicates::prelude::*;

fn kix() -> Command {
    let mut cmd = Command::cargo_bin("kix").unwrap();
    cmd.env("NO_COLOR", "true");
    cmd
}

#[test]
fn deploy_dry_run_yes() {
    kix()
        .args(["deploy", "example", "--dry-run", "--yes"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Wave"))
        .stdout(predicate::str::contains("Dry run"));
}

#[test]
fn apply_alias_works() {
    kix()
        .args(["apply", "example", "--dry-run", "--yes"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Dry run"));
}

#[test]
fn completions_fish() {
    kix()
        .args(["completions", "fish"])
        .assert()
        .success()
        .stdout(predicate::str::contains("complete"));
}

#[test]
fn completions_bash() {
    kix()
        .args(["completions", "bash"])
        .assert()
        .success()
        .stdout(predicate::str::is_empty().not());
}

#[test]
fn help_shows_commands() {
    kix()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("build"))
        .stdout(predicate::str::contains("diff"))
        .stdout(predicate::str::contains("deploy"))
        .stdout(predicate::str::contains("status"))
        .stdout(predicate::str::contains("list"))
        .stdout(predicate::str::contains("graph"));
}

#[test]
fn deploy_help_flags() {
    kix()
        .args(["deploy", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("--dry-run"))
        .stdout(predicate::str::contains("--yes"))
        .stdout(predicate::str::contains("--prune"))
        .stdout(predicate::str::contains("--on-error"))
        .stdout(predicate::str::contains("--timeout"));
}
