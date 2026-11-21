//! `kix doctor`: check the installation Kix runs from, the project's
//! builder, and the version of Kix the project uses.

use kix::flake_lock::{self, ProjectKix};
use kix::installs;
use kix::project::{BuilderKind, BuilderSource, ProjectConfig};
use kix::runtime;
use kix::system_nix;
use kix::version;
use miette::miette;

use crate::cli::GlobalArgs;
use crate::output::{green, red, yellow};

/// Run every check, print one line per result, and fail when any check
/// fails.
pub fn run(global: &GlobalArgs) -> miette::Result<()> {
    ok(&kix_line());
    let failures = check_runtime() + check_builder(&global.flake) + check_version(global);
    report_installs();
    if failures > 0 {
        return Err(miette!(
            "{failures} check{} failed",
            if failures == 1 { "" } else { "s" }
        ));
    }
    Ok(())
}

/// Return the first line: the running version, where it runs from, and
/// which Kix chose it.
fn kix_line() -> String {
    let mut line = format!("Kix {}", version::running());
    if let Ok(exe) = std::env::current_exe().and_then(|p| p.canonicalize()) {
        line.push_str(&format!(" ({})", exe.display()));
    }
    if let Some(by) = std::env::var_os(crate::select::SELECTED_BY_VAR).filter(|v| !v.is_empty()) {
        line.push_str(&format!(
            ", chosen by {}",
            std::path::Path::new(&by).display()
        ));
    }
    line
}

/// Report the version of Kix the project uses, from its `flake.lock`, and
/// warn when Git does not track that file. Return 1 when the running Kix is
/// not that version, or Kix cannot tell which version it is.
fn check_version(global: &GlobalArgs) -> usize {
    let Some(dir) = super::project_dir(&global.flake) else {
        return 0;
    };
    if !dir.join("flake.nix").is_file() {
        return 0;
    }
    let running = version::running();
    let failed = match flake_lock::project_kix(&dir, &global.input_overrides()) {
        Ok(ProjectKix::Release(v)) if &v == running => {
            ok(&format!("Project uses Kix {} (flake.lock)", v.release()));
            0
        }
        Ok(ProjectKix::Release(v)) => {
            fail(&format!(
                "Project uses Kix {} (flake.lock), and this is Kix {}",
                v.release(),
                running.release()
            ));
            detail(&format!(
                "Run `kix self install {}`, then run kix doctor again.",
                v.release()
            ));
            1
        }
        Ok(ProjectKix::Development(from)) => {
            ok(&format!("Project uses a development Kix library ({from})"));
            0
        }
        Err(e) => {
            fail("Project's version of Kix: unknown");
            detail(&e.to_string());
            1
        }
    };
    let failed = failed + check_versions(&dir);
    if let Some(line) = untracked_lock(&dir) {
        warn(&line);
    }
    failed
}

/// Report each version of Kix a project with a `[versions]` table in
/// `kix.toml` holds, and the clusters on it. Return 1 when the table and
/// `flake.lock` do not agree.
fn check_versions(dir: &std::path::Path) -> usize {
    let versions = match kix::versions::Versions::read(dir) {
        Ok(Some(versions)) => versions,
        Ok(None) => return 0,
        Err(e) => {
            fail("kix.toml [versions] is invalid");
            detail(&e.to_string());
            return 1;
        }
    };
    let Ok(lock) = flake_lock::read(dir) else {
        return 0;
    };
    if let Err(e) = versions.check(&lock, &kix::versions::flake_text(dir)) {
        fail("kix.toml [versions] does not match flake.lock");
        detail(&e.to_string());
        return 1;
    }
    for input in versions.inputs() {
        let what = match flake_lock::input(&lock, input).map(flake_lock::from_original) {
            Ok(Ok(ProjectKix::Release(v))) => format!("pins Kix {}", v.release()),
            Ok(Ok(ProjectKix::Development(from))) => {
                format!("uses a development Kix library ({})", from.describe(input))
            }
            _ => "has an unknown version of Kix".to_string(),
        };
        let clusters = versions.clusters_of(input);
        let used_by = if clusters.is_empty() {
            "used by no clusters".to_string()
        } else {
            format!("used by {}", clusters.join(", "))
        };
        ok(&format!("Input {input} {what}, {used_by}"));
    }
    0
}

/// Return the warning for a project in Git whose `flake.lock` Git does not
/// track, or `None`.
fn untracked_lock(dir: &std::path::Path) -> Option<String> {
    if !dir.join(flake_lock::FILE).is_file() {
        return None;
    }
    let out = std::process::Command::new("git")
        .args(["ls-files", "--", flake_lock::FILE])
        .current_dir(dir)
        .output()
        .ok()?;
    // Outside a Git repository there is nothing to track the file.
    if !out.status.success() || !out.stdout.is_empty() {
        return None;
    }
    Some(
        "Git does not track flake.lock, so other clones of this project can run another version of Kix. Run `git add flake.lock` and commit it.".to_string(),
    )
}

/// Report the installed versions. This never fails a check, since Kix can
/// run from outside the data directory, such as from a Nix profile.
fn report_installs() {
    let Some(data) = installs::data_dir() else {
        warn(&format!("No versions installed. {}", installs::NO_HOME));
        return;
    };
    let all = installs::installed();
    if all.is_empty() {
        warn(&format!("No versions installed under {}", data.display()));
        return;
    }
    let versions: Vec<String> = all.iter().map(|i| i.version.release()).collect();
    ok(&format!(
        "Installed versions: {} ({})",
        versions.join(", "),
        data.display()
    ));
}

fn ok(text: &str) {
    println!("{} {text}", green("✓"));
}

fn warn(text: &str) {
    println!("{} {text}", yellow("!"));
}

fn fail(text: &str) {
    println!("{} {text}", red("✗"));
}

/// Print a line under the one before it, such as the fix for a problem.
/// Print `text` under a check line, indenting each of its lines.
fn detail(text: &str) {
    for line in text.lines() {
        if line.is_empty() {
            println!();
        } else {
            println!("  {line}");
        }
    }
}

/// Check the Kix runtime: that Kix finds it, that it holds the program
/// versions this release ships, and that no file has changed since install. Return the number of failed checks.
fn check_runtime() -> usize {
    let rt = match runtime::runtime() {
        Ok(rt) => rt,
        Err(e) => {
            fail("Kix runtime: not usable");
            detail(&e.to_string());
            return 1;
        }
    };
    // Only an override is worth showing. Otherwise the runtime is where the
    // install put it.
    let from = match rt.found_by {
        runtime::FoundBy::Env => format!(" (from KIX_RUNTIME_DIR, {})", rt.dir.display()),
        runtime::FoundBy::BesideBinary | runtime::FoundBy::BuiltIn => String::new(),
    };

    let manifest = match runtime::read_manifest(&rt.dir) {
        Ok(manifest) => manifest,
        Err(_) if !rt.dir.join("manifest.json").exists() => {
            warn(&format!(
                "Kix runtime{from}: cannot verify program versions because {}/manifest.json is absent",
                rt.dir.display()
            ));
            detail(
                "Kix allows a custom runtime in `KIX_RUNTIME_DIR`, so `kix doctor` continues. To use the standard Kix runtime instead, unset `KIX_RUNTIME_DIR`.",
            );
            return 0;
        }
        Err(e) => {
            fail(&format!("Kix runtime{from}: cannot read manifest.json"));
            detail(&e.to_string());
            return 1;
        }
    };
    let programs: Vec<String> = manifest
        .programs
        .iter()
        .map(|p| format!("{} {}", p.name, p.version))
        .collect();
    ok(&format!("Kix runtime{from}: {}", programs.join(", ")));

    let verification = match runtime::verify_files(&rt.dir) {
        Ok(v) => v,
        Err(e) => {
            fail("Kix runtime can't be read");
            detail(&e.to_string());
            return 1;
        }
    };
    if verification.problems.is_empty() {
        ok("Kix runtime is intact");
        return 0;
    }
    let changed = verification.problems.len();
    fail(&format!(
        "Kix runtime is damaged: {changed} file{} changed since install",
        if changed == 1 { "" } else { "s" }
    ));
    for p in &verification.problems {
        detail(&format!("  {} ({})", p.path.display(), p.problem));
    }
    detail("Reinstall Kix from its release archive, unless you changed these files yourself.");
    1
}

/// Report the project's builder and where the choice came from. Return 1
/// when `kix.toml` cannot be read or names a builder this version of Kix cannot use.
fn check_builder(flake: &str) -> usize {
    let dir = super::project_dir(flake);
    let config = match ProjectConfig::read_with_env(dir.as_deref()) {
        Ok(config) => config,
        Err(e) => {
            fail("Builder: kix.toml can't be read");
            detail(&e.to_string());
            return 1;
        }
    };
    let line = builder_line(&config);
    if let Err(e) = config.check_supported() {
        fail(&line);
        detail(&e.to_string());
        return 1;
    }
    ok(&line);
    if config.builder == BuilderKind::Nix {
        check_system_nix()
    } else {
        0
    }
}

/// Check the machine's Nix, which the nix builder uses. Return 1 when it is
/// missing, too old, or Lix.
fn check_system_nix() -> usize {
    let version = match system_nix::version_line()
        .and_then(|line| system_nix::check_version(&line).map(|()| line))
    {
        Ok(version) => version,
        Err(e) => {
            fail("Nix on this machine can't be used");
            detail(&e.to_string());
            return 1;
        }
    };
    // `nix --version` prints "nix (Nix) 2.28.3". Show only the version.
    let version = version.rsplit(' ').next().unwrap_or(&version);
    ok(&format!("Nix {version} (from PATH)"));
    match system_nix::import_from_derivation_allowed() {
        Some(true) => ok("Nix can render Helm charts"),
        Some(false) => {
            warn("Nix can't render Helm charts: allow-import-from-derivation is off");
            detail("Add `allow-import-from-derivation = true` to nix.conf.");
        }
        None => {
            warn("Unknown whether Nix can render Helm charts");
            detail(
                "Nix did not report allow-import-from-derivation. To be sure, add `allow-import-from-derivation = true` to nix.conf.",
            );
        }
    }
    0
}

fn builder_line(config: &ProjectConfig) -> String {
    let from = match &config.builder_source {
        BuilderSource::File(path) => format!("set in {}", path.display()),
        BuilderSource::Default => "default".to_string(),
        BuilderSource::TestOverride => {
            format!("set by {}", kix::project::TEST_BUILDER_VAR)
        }
    };
    format!("Builder: {} ({from})", config.builder)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git(dir: &std::path::Path, args: &[&str]) {
        let out = std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {out:?}");
    }

    #[test]
    fn an_untracked_lock_in_git_gets_a_warning() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        assert_eq!(untracked_lock(d), None);
        std::fs::write(d.join("flake.lock"), "{}").unwrap();
        // Outside Git there is nothing to track the file.
        assert_eq!(untracked_lock(d), None);
        git(d, &["init", "-q"]);
        assert!(untracked_lock(d).is_some_and(|w| w.starts_with("Git does not track flake.lock")),);
        git(d, &["add", "flake.lock"]);
        assert_eq!(untracked_lock(d), None);
    }
}
