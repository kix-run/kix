//! Cross-checks between the change records built into Kix and the source
//! that prints their ids. Skipped outside the repository.

use std::path::{Path, PathBuf};

use kix_core::changes::{self, Kind};

/// Files that write ids only as examples: the records module, the
/// `kix explain` command, and this test.
const EXAMPLES: &[&str] = &[
    "cli/kix-core/src/changes/",
    "cli/kix-core/tests/changes_ids.rs",
    "cli/kix-cli/src/commands/explain.rs",
];

fn repository() -> Option<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    (root.join("kix").is_dir() && root.join("changes").is_dir() && root.join("cli").is_dir())
        .then(|| root.canonicalize().unwrap())
}

/// Return every `.rs` and `.nix` file under `kix/` and `cli/`, except
/// test fixtures, build output, and [`EXAMPLES`], with its text.
fn sources(root: &Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for top in ["kix", "cli"] {
        let walk = walkdir::WalkDir::new(root.join(top))
            .into_iter()
            .filter_entry(|e| {
                let name = e.file_name().to_string_lossy();
                !(e.file_type().is_dir() && (name == "fixtures" || name == "target"))
            });
        for entry in walk {
            let entry = entry.unwrap();
            let path = entry.path();
            if !entry.file_type().is_file()
                || !path.extension().is_some_and(|e| e == "rs" || e == "nix")
            {
                continue;
            }
            let rel = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .into_owned();
            if EXAMPLES.iter().any(|x| rel.starts_with(x)) {
                continue;
            }
            if let Ok(text) = std::fs::read_to_string(path) {
                out.push((rel, text));
            }
        }
    }
    out
}

#[test]
fn changes_ids_in_source_are_known_records() {
    let Some(root) = repository() else {
        eprintln!("skipped: not in the Kix repository");
        return;
    };
    let mut unknown = Vec::new();
    for (rel, text) in sources(&root) {
        for id in changes::ids_in(&text) {
            if changes::find(&id).is_none() {
                unknown.push(format!("{rel}: [{id}]"));
            }
        }
    }
    assert!(
        unknown.is_empty(),
        "these ids have no change record under changes/. Add one, or fix the id:\n{}",
        unknown.join("\n")
    );
}

#[test]
fn changes_unreleased_error_ids_are_printed() {
    let Some(root) = repository() else {
        eprintln!("skipped: not in the Kix repository");
        return;
    };
    let sources = sources(&root);
    let missing: Vec<String> = changes::compiled()
        .iter()
        .filter(|c| c.release.is_none() && c.record.kind == Kind::Error)
        .filter_map(|c| c.record.id.as_deref())
        .filter(|id| {
            let bracketed = format!("[{id}]");
            !sources.iter().any(|(_, text)| text.contains(&bracketed))
        })
        .map(str::to_owned)
        .collect();
    assert!(
        missing.is_empty(),
        "these `kind = \"error\"` records have an id that no error under kix/ or cli/ prints. \
         Start the error's message with the id in brackets: {}",
        missing.join(", ")
    );
}

#[test]
fn changes_compiled_records_include_the_repository() {
    let Some(root) = repository() else {
        eprintln!("skipped: not in the Kix repository");
        return;
    };
    if std::env::var_os("KIX_CHANGES_DIR").is_some() {
        return;
    }
    let on_disk = std::fs::read_dir(root.join("changes"))
        .unwrap()
        .filter_map(Result::ok)
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            name.ends_with(".md") && name != "README.md"
        })
        .count();
    let unreleased = changes::compiled()
        .iter()
        .filter(|c| c.release.is_none())
        .count();
    assert_eq!(unreleased, on_disk);
}
