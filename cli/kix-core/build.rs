//! Check every change record and build it into Kix as
//! `$OUT_DIR/changes.json`, which `changes::compiled` reads.
//!
//! The records come from `KIX_CHANGES_DIR` when it is set, else from the
//! repository's `changes/` folder. The Nix build sets the variable, since its
//! source holds only `cli/`. With neither, Kix carries no records.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[allow(dead_code)]
#[path = "src/changes/record.rs"]
mod record;

use record::{Compiled, Record};

fn main() {
    println!("cargo:rerun-if-env-changed=KIX_CHANGES_DIR");
    let dir = match std::env::var_os("KIX_CHANGES_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => Path::new(env!("CARGO_MANIFEST_DIR")).join("../../changes"),
    };

    let records = if dir.is_dir() {
        println!("cargo:rerun-if-changed={}", dir.display());
        read_records(&dir)
    } else {
        println!("cargo:rerun-if-changed=build.rs");
        Vec::new()
    };

    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("cargo sets OUT_DIR"));
    let json = serde_json::to_string(&records).expect("records serialize");
    std::fs::write(out.join("changes.json"), json).expect("write changes.json");
}

/// Read the unreleased records at the top of `dir` and the released ones in
/// its `<version>/` folders. Panic, naming the file, when one breaks the
/// format or reuses an id.
fn read_records(dir: &Path) -> Vec<Compiled> {
    let mut found: Vec<(PathBuf, Option<String>)> = Vec::new();
    for entry in sorted_entries(dir) {
        if entry.is_dir() {
            let version = entry.file_name().unwrap().to_string_lossy().into_owned();
            for file in sorted_entries(&entry) {
                if is_record(&file, false) {
                    found.push((file, Some(version.clone())));
                }
            }
        } else if is_record(&entry, true) {
            found.push((entry, None));
        }
    }

    let mut problems = Vec::new();
    let mut records = Vec::new();
    let mut ids: HashMap<String, PathBuf> = HashMap::new();
    for (path, release) in found {
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        match Record::parse(&name, &text) {
            Ok(record) => {
                if let Some(id) = &record.id {
                    if let Some(other) = ids.get(id) {
                        problems.push(format!(
                            "{}: id {id} is also used by {}",
                            path.display(),
                            other.display()
                        ));
                    }
                    ids.insert(id.clone(), path.clone());
                }
                records.push(Compiled { release, record });
            }
            Err(e) => problems.push(format!("{}: {e}", path.display())),
        }
    }
    if !problems.is_empty() {
        panic!(
            "change records break the format (see changes/README.md):\n{}",
            problems.join("\n")
        );
    }
    records
}

fn sorted_entries(dir: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
        .map(|e| e.expect("directory entry").path())
        .collect();
    entries.sort();
    entries
}

/// Return whether `path` is a record file. `README.md` documents the format
/// at the top level.
fn is_record(path: &Path, top_level: bool) -> bool {
    path.is_file()
        && path.extension().is_some_and(|e| e == "md")
        && !(top_level && path.file_name().is_some_and(|n| n == "README.md"))
}
