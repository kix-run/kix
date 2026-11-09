//! Check that `kix-lib` builds from its own directory alone.
//!
//! crane's `vendorCargoDeps`, `cargo vendor`, and `cargo package` copy only the
//! files under the crate root. A file that `include_str!` or `include_bytes!`
//! reads from outside it builds in this workspace and fails everywhere else.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

/// Return the path each `include_str!` and `include_bytes!` in `source` names,
/// skipping comment lines.
fn included_paths(source: &str) -> Vec<String> {
    let code: String = source
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .map(|line| format!("{line}\n"))
        .collect();
    let mut paths = Vec::new();
    for marker in ["include_str!(", "include_bytes!("] {
        let mut rest = code.as_str();
        while let Some(at) = rest.find(marker) {
            rest = rest[at + marker.len()..].trim_start();
            if let Some(literal) = rest.strip_prefix('"')
                && let Some(end) = literal.find('"')
            {
                paths.push(literal[..end].to_string());
            }
        }
    }
    paths
}

/// Resolve `.` and `..` in `path` without touching the file system.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

#[test]
fn every_included_file_is_in_the_package() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    let output = Command::new(env!("CARGO"))
        .args(["package", "-p", "kix-lib", "--list", "--allow-dirty"])
        .current_dir(root)
        .output()
        .expect("cargo runs");
    assert!(
        output.status.success(),
        "cargo package --list failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let packaged: BTreeSet<String> = String::from_utf8(output.stdout)
        .expect("cargo prints UTF-8")
        .lines()
        .map(str::to_string)
        .collect();

    let mut missing = Vec::new();
    for entry in walkdir::WalkDir::new(root.join("src")) {
        let entry = entry.expect("src is readable");
        if entry.path().extension().is_none_or(|e| e != "rs") {
            continue;
        }
        let source = std::fs::read_to_string(entry.path()).expect("source is readable");
        let dir = entry.path().parent().expect("a file has a parent");
        for included in included_paths(&source) {
            let target = normalize(&dir.join(&included));
            let relative = target
                .strip_prefix(root)
                .ok()
                .and_then(|p| p.to_str())
                .map(|p| p.replace('\\', "/"));
            if !relative.is_some_and(|r| packaged.contains(&r)) {
                missing.push(format!("{}: {included}", entry.path().display()));
            }
        }
    }
    assert!(
        missing.is_empty(),
        "these files are compiled into kix-lib but are not in its package, \
         so a vendored build of kix-lib fails. Keep them under cli/kix/:\n{}",
        missing.join("\n")
    );
}
