//! Run the installed Kix that matches the project at a step, and read the
//! clusters and packages it lists.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use kix::version::Version;

/// Run `kix` for the project in `dir` with `args`, as the Kix chosen for the
/// project. Return its stdout, or its stderr when it fails.
pub(super) fn run_kix(
    kix: &Path,
    dir: &Path,
    args: &[&str],
) -> std::result::Result<String, String> {
    let chooser = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("kix"));
    let out = Command::new(kix)
        .arg("--flake")
        .arg(dir)
        .args(args)
        .env(crate::select::SELECTED_BY_VAR, chooser)
        .env_remove("KIX_FLAKE")
        .output()
        .map_err(|e| format!("could not run {}: {e}", kix.display()))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() {
            format!("{} exited with {}", kix.display(), out.status)
        } else {
            err
        })
    }
}

/// Return the clusters of the project, as `kix` lists them.
pub(super) fn clusters(kix: &Path, dir: &Path) -> std::result::Result<Vec<String>, String> {
    let out = run_kix(kix, dir, &["-o", "json", "list", "clusters"])?;
    if out.trim().is_empty() {
        return Ok(Vec::new());
    }
    serde_json::from_str(&out)
        .map_err(|e| format!("`kix list clusters` printed no list of clusters: {e}"))
}

/// Return whether Kix `version` takes the command line of Kix 0.10, which
/// renamed the flags this module passes to `kix export` and `kix list
/// packages`. Earlier versions refuse the new names, and later ones refuse
/// the old.
pub(super) fn new_command_line(version: &Version) -> bool {
    let first = Version {
        pre: Some("rc.4".to_string()),
        ..Version::new(0, 10, 0)
    };
    *version >= first
}

/// Return the packages the project's clusters install, or `None` when Kix
/// `version` at `kix` cannot list them. `kix list packages` names instances,
/// so instance names stand in for package names.
pub(super) fn packages_in_use(
    kix: &Path,
    version: &Version,
    dir: &Path,
) -> Option<BTreeSet<String>> {
    let mut in_use = BTreeSet::new();
    for cluster in clusters(kix, dir).ok()? {
        let mut args = vec!["-o", "json", "list", "packages"];
        if !new_command_line(version) {
            args.push("--cluster");
        }
        args.push(&cluster);
        let out = run_kix(kix, dir, &args).ok()?;
        if out.trim().is_empty() {
            continue;
        }
        let rows: Vec<serde_json::Value> = serde_json::from_str(&out).ok()?;
        for row in rows {
            // A row this Kix cannot read leaves the list unknown.
            let (Some(name), Some(status)) = (row["name"].as_str(), row["status"].as_str()) else {
                return None;
            };
            if status != "available" {
                in_use.insert(name.to_string());
            }
        }
    }
    Some(in_use)
}
