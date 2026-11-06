//! `kix doctor`: check the installation Kix runs from.

use kix::runtime::{self, Runtime};
use miette::miette;

use crate::output::{green, red, yellow};

/// Run every check, print one line per result, and fail when any check
/// fails.
pub fn run() -> miette::Result<()> {
    let failures = check_runtime();
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
