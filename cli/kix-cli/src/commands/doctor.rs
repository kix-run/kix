//! `kix doctor`: check the installation Kix runs from, the project's
//! builder, and the version of Kix the project needs.

use kix::installs;
use kix::project::{BuilderKind, BuilderSource, FILE, ProjectConfig};
use kix::runtime;
use kix::system_nix;
use kix::version::{self, policy};
use miette::miette;

use crate::cli::GlobalArgs;
use crate::output::{green, red, yellow};

/// Run every check, print one line per result, and fail when any check
/// fails.
pub fn run(global: &GlobalArgs) -> miette::Result<()> {
    ok(&kix_line());
    let failures = check_runtime() + check_builder(&global.flake) + check_version(&global.flake);
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

/// Report the version of Kix the project needs. Return 1 when the running
/// Kix does not meet it.
fn check_version(flake: &str) -> usize {
    let Some(dir) = super::project_dir(flake) else {
        return 0;
    };
    // The builder check reports a kix.toml that cannot be read.
    let Ok(config) = ProjectConfig::read(Some(&dir), None) else {
        return 0;
    };
    let running = version::running();
    match (&config.kix, &config.kix_source) {
        (Some(req), Some(path)) if policy::satisfies(req, running) => {
            ok(&format!("Project needs Kix {req} ({})", path.display()));
            0
        }
        (Some(req), path) => {
            let from = path
                .as_ref()
                .map_or_else(|| "kix.toml".to_string(), |p| p.display().to_string());
            fail(&format!(
                "Project needs Kix {req} ({from}), and this is Kix {}",
                running.release()
            ));
            detail(&format!(
                "Run `kix self install {req}`, then run kix doctor again."
            ));
            1
        }
        (None, _) => {
            if let Some(line) =
                missing_kix_setting(&dir.join("flake.nix"), &dir.join(FILE), running)
            {
                warn(&line);
            }
            0
        }
    }
}

/// Return the warning for a project with no `kix` setting, or `None` when
/// there is nothing to warn about: the directory is not a project, or the
/// running Kix is older than any version the setting can name.
fn missing_kix_setting(
    flake_nix: &std::path::Path,
    kix_toml: &std::path::Path,
    running: &version::Version,
) -> Option<String> {
    if !flake_nix.exists() || running.minor_key() < policy::FIRST_SELECTING {
        return None;
    }
    // A minor never matches a prerelease, so a prerelease suggests itself.
    let minor = if running.is_prerelease() {
        running.release()
    } else {
        running.minor_text()
    };
    Some(if kix_toml.exists() {
        format!(
            "kix.toml sets no kix version. Add kix = \"{minor}\" so everyone runs a matching Kix"
        )
    } else {
        format!(
            "This project has no kix.toml. Add one with kix = \"{minor}\" so everyone runs a matching Kix"
        )
    })
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
fn detail(text: &str) {
    println!("  {text}");
}

/// Check the Kix runtime: that Kix finds it, that it holds the program
/// versions this release ships, and that no file has changed since install. Return the number of failed checks.
fn check_runtime() -> usize {
    let rt = match runtime::runtime() {
        Ok(rt) => rt,
        Err(e) => {
            fail("Kix runtime not found");
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
                "Kix runtime{from} can't be checked: it has no manifest.json"
            ));
            return 0;
        }
        Err(e) => {
            fail(&format!(
                "Kix runtime{from} doesn't match this version of Kix"
            ));
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

    #[test]
    fn a_project_without_a_kix_setting_is_told_which_file_to_change() {
        let dir = tempfile::tempdir().unwrap();
        let flake = dir.path().join("flake.nix");
        let toml = dir.path().join(FILE);
        let v = |s: &str| s.parse::<version::Version>().unwrap();
        assert_eq!(missing_kix_setting(&flake, &toml, &v("0.8.1")), None);

        std::fs::write(&flake, "{}").unwrap();
        assert_eq!(
            missing_kix_setting(&flake, &toml, &v("0.8.1+3")).as_deref(),
            Some(
                "This project has no kix.toml. Add one with kix = \"0.8\" so everyone runs a matching Kix"
            )
        );
        std::fs::write(&toml, "builder = \"kix\"\n").unwrap();
        assert_eq!(
            missing_kix_setting(&flake, &toml, &v("0.9.0")).as_deref(),
            Some("kix.toml sets no kix version. Add kix = \"0.9\" so everyone runs a matching Kix")
        );
        assert_eq!(missing_kix_setting(&flake, &toml, &v("0.7.2")), None);
        assert_eq!(
            missing_kix_setting(&flake, &toml, &v("0.9.0-rc.1+4")).as_deref(),
            Some(
                "kix.toml sets no kix version. Add kix = \"0.9.0-rc.1\" so everyone runs a matching Kix"
            )
        );
    }
}
