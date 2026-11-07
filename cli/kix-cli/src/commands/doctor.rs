//! `kix doctor`: check the installation Kix runs from and the project's
//! builder.

use kix::project::{BuilderKind, BuilderSource, ProjectConfig};
use kix::runtime;
use kix::system_nix;
use miette::miette;

use crate::cli::GlobalArgs;
use crate::output::{green, red, yellow};

/// Run every check, print one line per result, and fail when any check
/// fails.
pub fn run(global: &GlobalArgs) -> miette::Result<()> {
    ok(&format!("Kix {}", env!("CARGO_PKG_VERSION")));
    let failures = check_runtime() + check_builder(&global.flake);
    if failures > 0 {
        return Err(miette!(
            "{failures} check{} failed",
            if failures == 1 { "" } else { "s" }
        ));
    }
    Ok(())
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
/// when `kix.toml` cannot be read or names a builder this Kix cannot use.
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
            detail("`nix config show` did not list allow-import-from-derivation.");
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
