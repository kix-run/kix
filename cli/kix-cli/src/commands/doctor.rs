//! `kix doctor`: check the installation Kix runs from and the project's
//! builder.

use kix::project::{BuilderSource, ProjectConfig};
use kix::runtime::{self, Runtime};
use miette::miette;

use crate::cli::GlobalArgs;
use crate::output::{green, red, yellow};

/// Run every check, print one line per result, and fail when any check
/// fails.
pub fn run(global: &GlobalArgs) -> miette::Result<()> {
    let failures = check_runtime() + check_builder(&global.flake);
    if failures > 0 {
        return Err(miette!(
            "{failures} check{} failed",
            if failures == 1 { "" } else { "s" }
        ));
    }
    Ok(())
}

/// Check the Kix runtime: which directory Kix uses, whether its manifest
/// belongs to this binary, and whether every file matches its hash. Return
/// the number of failed checks.
fn check_runtime() -> usize {
    let rt = match runtime::runtime() {
        Ok(rt) => rt,
        Err(e) => {
            println!("{}  {e}", red("fail"));
            return 1;
        }
    };
    println!(
        "{}  Kix runtime in {} ({})",
        green("ok  "),
        rt.dir.display(),
        rt.found_by
    );
    verify(&rt)
}

/// Report the project's builder and where the choice came from. Return 1
/// when `kix.toml` cannot be read or names a builder this Kix cannot use.
fn check_builder(flake: &str) -> usize {
    let dir = super::project_dir(flake);
    let config = match ProjectConfig::read_with_env(dir.as_deref()) {
        Ok(config) => config,
        Err(e) => {
            println!("{}  {e}", red("fail"));
            return 1;
        }
    };
    let line = builder_line(&config);
    match config.check_supported() {
        Ok(()) => {
            println!("{}  {line}", green("ok  "));
            0
        }
        Err(e) => {
            println!("{}  {line}", red("fail"));
            println!("      {e}");
            1
        }
    }
}

fn builder_line(config: &ProjectConfig) -> String {
    let from = match &config.builder_source {
        BuilderSource::File(path) => format!("set in {}", path.display()),
        BuilderSource::Default => "the default, since no kix.toml sets a builder".to_string(),
        BuilderSource::TestOverride => {
            format!("set by {}", kix::project::TEST_BUILDER_VAR)
        }
    };
    format!("builder: {} ({from})", config.builder)
}

fn verify(rt: &Runtime) -> usize {
    let manifest = match runtime::read_manifest(&rt.dir) {
        Ok(manifest) => manifest,
        Err(_) if !rt.dir.join("manifest.json").exists() => {
            println!(
                "{}  the runtime has no manifest.json, so Kix cannot check its programs",
                yellow("warn")
            );
            return 0;
        }
        Err(e) => {
            println!("{}  {e}", red("fail"));
            return 1;
        }
    };
    let programs: Vec<String> = manifest
        .programs
        .iter()
        .map(|p| format!("{} {}", p.name, p.version))
        .collect();
    println!(
        "{}  it ships the programs this kix expects: {}",
        green("ok  "),
        programs.join(", ")
    );

    let verification = match runtime::verify_files(&rt.dir) {
        Ok(v) => v,
        Err(e) => {
            println!("{}  {e}", red("fail"));
            return 1;
        }
    };
    if verification.problems.is_empty() {
        println!(
            "{}  all {} files match the SHA-256 in manifest.json",
            green("ok  "),
            verification.files
        );
        return 0;
    }
    println!(
        "{}  {} of {} files differ from manifest.json:",
        red("fail"),
        verification.problems.len(),
        verification.files
    );
    for p in &verification.problems {
        println!(
            "        {} ({}): {}",
            p.path.display(),
            p.program,
            p.problem
        );
    }
    println!(
        "      Reinstall Kix from its release archive if this was not intentional. A file you replaced on purpose, such as your own build of an LGPL program, shows here too."
    );
    1
}
