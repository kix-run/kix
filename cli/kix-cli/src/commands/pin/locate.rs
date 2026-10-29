//! Locate the pin file for `kix pin` commands without evaluating the flake.
//!
//! Evaluating a flake to read a pin-file path would copy the repository into
//! `/nix/store/<hash>-source/...` and fail whenever the pin file itself is
//! broken or missing. Instead, the CLI searches in order:
//! 1. `--pins-file <path>`, if passed.
//! 2. `pins.json` in the working directory.
//! 3. `pins.json` in the flake directory.
//! 4. A bounded scan of the Git repository for a single pin file.
//!
//! If the repository scan finds more than one candidate, the command returns an
//! error asking for `--pins-file` rather than guessing.

use std::path::{Path, PathBuf};

use miette::{Result, miette};

/// How the pin file was located.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum How {
    /// Selected explicitly via `--pins-file`.
    Flag,
    /// Found at `./pins.json` in the working directory.
    Cwd,
    /// Found at `pins.json` next to the flake.
    Flake,
    /// Found as the sole pin file in the Git repository.
    Scan,
}

#[derive(Debug, Clone)]
pub struct Location {
    pub path: PathBuf,
    pub how: How,
}

impl Location {
    /// Return a note describing how the file was chosen when `--pins-file` was
    /// not passed.
    pub fn note(&self) -> Option<String> {
        match self.how {
            How::Flag => None,
            How::Cwd => Some(format!("using {}", self.path.display())),
            How::Flake => Some(format!("using {}, next to the flake", self.path.display())),
            How::Scan => Some(format!(
                "using {}, the only pin file in this repository",
                self.path.display()
            )),
        }
    }
}

/// Find the pin file to read, returning `Ok(None)` when none exists and `Err`
/// when multiple candidates exist in the repository.
fn find(explicit: Option<&Path>, flake: &str) -> Result<Option<Location>> {
    if let Some(p) = explicit {
        return Ok(Some(Location {
            path: p.to_path_buf(),
            how: How::Flag,
        }));
    }

    let cwd_candidate = PathBuf::from("pins.json");
    if cwd_candidate.is_file() {
        return Ok(Some(Location {
            path: cwd_candidate,
            how: How::Cwd,
        }));
    }

    if let Some(dir) = flake_dir(flake) {
        let candidate = dir.join("pins.json");
        if candidate.is_file() {
            return Ok(Some(Location {
                path: candidate,
                how: How::Flake,
            }));
        }
    }

    // Scan only inside a Git repository to avoid walking arbitrary directories
    // such as `$HOME` or `/tmp`.
    let root = repo_root();
    let mut found = match &root {
        Some(root) => scan(root),
        None => Vec::new(),
    };
    found.sort();

    decide(found)
}

/// Convert repository scan candidates into a single [`Location`], `Ok(None)`
/// when none were found, or an ambiguity error when several were found.
fn decide(mut found: Vec<PathBuf>) -> Result<Option<Location>> {
    match found.len() {
        1 => Ok(Some(Location {
            path: PathBuf::from(display_from_cwd(&found.remove(0))),
            how: How::Scan,
        })),
        0 => Ok(None),
        _ => Err(miette!(
            "multiple pin files were found in this repository:\n{}\n\nPass --pins-file <path>.",
            found
                .iter()
                .map(|p| format!("  {}", display_from_cwd(p)))
                .collect::<Vec<_>>()
                .join("\n")
        )),
    }
}

/// Find the pin file to read.
pub fn locate(explicit: Option<&Path>, flake: &str) -> Result<Location> {
    find(explicit, flake)?.ok_or_else(|| {
        miette!(
            "no pin file found. Looked for pins.json in the working directory{}{}.\n\nSelect a file with --pins-file <path>, or create one with:\n  kix pin set <key> --repository <registry/repository> --tag <tag> --init",
            match flake_dir(flake) {
                // "." is the working directory, which the first clause
                // already named.
                Some(d) if d != Path::new(".") => format!(", in {}", d.display()),
                _ => String::new(),
            },
            match repo_root() {
                Some(root) => format!(", and for a pin file under {}", root.display()),
                None => ", but skipped the repository search because the working directory is not in a Git repository"
                    .to_string(),
            },
        )
    })
}

/// Find the pin file to read, or return the default path to create for `--init`.
///
/// When no pin file exists yet, defaults to `pins.json` in the flake directory
/// (or the working directory for remote flakes).
pub fn locate_or_init(explicit: Option<&Path>, flake: &str) -> Result<Location> {
    // Propagate ambiguity errors from `find` so `--init` never creates a third
    // pin file when the repository already has two.
    Ok(find(explicit, flake)?.unwrap_or_else(|| Location {
        path: match flake_dir(flake) {
            Some(dir) => dir.join("pins.json"),
            None => PathBuf::from("pins.json"),
        },
        how: How::Flake,
    }))
}

/// Return the local directory referenced by `flake`, or `None` for remote flake
/// URLs such as `github:owner/repo`.
fn flake_dir(flake: &str) -> Option<PathBuf> {
    let without_fragment = flake.split('#').next().unwrap_or(flake);
    let bare = without_fragment
        .strip_prefix("path:")
        .unwrap_or(without_fragment);
    if bare.contains(':') {
        return None;
    }
    let path = PathBuf::from(bare);
    path.is_dir().then_some(path)
}

/// Format `path` relative to the current working directory when possible.
fn display_from_cwd(path: &Path) -> String {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    match path.strip_prefix(&cwd) {
        Ok(rel) => rel.display().to_string(),
        Err(_) => path.display().to_string(),
    }
}

/// Find the enclosing Git repository root above the current working directory.
pub fn repo_root() -> Option<PathBuf> {
    let cwd = std::env::current_dir().ok()?;
    let mut dir = cwd.as_path();
    loop {
        if dir.join(".git").exists() {
            return Some(dir.to_path_buf());
        }
        dir = dir.parent()?;
    }
}

/// Return all pin files under `root` up to [`MAX_DEPTH`].
///
/// Matches files named `pins.json`, plus files ending in `pins.json` whose
/// header contains [`kix::pins::MANAGED_MARKER`] so unrelated JSON files ending
/// in `pins.json` are not treated as pin files. Does not follow symlinks (such
/// as Nix `result` links).
fn scan(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    walk(root, 0, &mut out);
    out
}

fn is_pin_file(path: &Path, name: &str) -> bool {
    if name == "pins.json" {
        return true;
    }
    if !name.ends_with("pins.json") {
        return false;
    }
    // Only the head of the file is read: `managedBy` is the second key
    // `kix pin` writes, and a pin file that has grown large is still a file
    // whose first lines say what it is.
    match std::fs::read_to_string(path) {
        Ok(text) => text
            .lines()
            .take(4)
            .any(|line| line.contains(kix::pins::MANAGED_MARKER)),
        Err(_) => false,
    }
}

const MAX_DEPTH: usize = 8;

fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > MAX_DEPTH || out.len() > 64 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = entry.file_type() else {
            continue;
        };
        if meta.is_symlink() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if meta.is_dir() {
            if name.starts_with('.') || matches!(name.as_ref(), "target" | "node_modules") {
                continue;
            }
            if name.starts_with("result") {
                continue;
            }
            walk(&path, depth + 1, out);
        } else if is_pin_file(&path, &name) {
            out.push(path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_explicit_path_wins_and_is_not_checked_for_existence() {
        // A path that does not exist yet is still the path the reader meant.
        // Refusing here would move the "no such file" error away from the
        // code that can explain it.
        let found = locate(Some(Path::new("nowhere/pins.json")), ".").unwrap();
        assert_eq!(found.path, PathBuf::from("nowhere/pins.json"));
        assert_eq!(found.how, How::Flag);
        assert!(found.note().is_none());
    }

    #[test]
    fn a_remote_flake_reference_names_no_directory() {
        assert!(flake_dir("github:kix-run/kixpkgs").is_none());
        assert!(flake_dir("git+https://example.com/repo").is_none());
    }

    #[test]
    fn a_local_flake_reference_names_its_directory() {
        assert_eq!(flake_dir("."), Some(PathBuf::from(".")));
        assert_eq!(flake_dir("path:."), Some(PathBuf::from(".")));
        assert_eq!(flake_dir(".#cluster-pins"), Some(PathBuf::from(".")));
        assert!(flake_dir("./definitely-not-here").is_none());
    }

    #[test]
    fn nothing_found_is_an_absence_and_several_found_is_an_error() {
        // The distinction `--init` rests on. Two pin files and no
        // `--pins-file` is a question only the reader can settle, and
        // creating a third would answer it with a file nothing reads.
        assert!(decide(Vec::new()).unwrap().is_none());

        let one = decide(vec![PathBuf::from("clusters/pins.json")])
            .unwrap()
            .unwrap();
        assert_eq!(one.how, How::Scan);

        let several = decide(vec![
            PathBuf::from("a/pins.json"),
            PathBuf::from("b/pins.json"),
        ]);
        let message = format!("{:?}", several.unwrap_err());
        assert!(message.contains("multiple pin files"), "{message}");
        assert!(message.contains("a/pins.json"), "{message}");
        assert!(message.contains("b/pins.json"), "{message}");
    }

    #[test]
    fn the_scan_finds_pin_files_and_ignores_the_build_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("clusters/lab1")).unwrap();
        std::fs::write(root.join("clusters/lab1/pins.json"), "{}").unwrap();
        std::fs::write(
            root.join("clusters/image-pins.json"),
            format!(
                "{{\n  \"version\": 1,\n  {},\n  \"images\": {{}}\n}}\n",
                kix::pins::MANAGED_MARKER
            ),
        )
        .unwrap();
        std::fs::write(root.join("clusters/other.nix"), "{ }").unwrap();
        // Some other JSON whose name happens to end in `pins.json`. It does
        // not declare `managedBy`, so it is not a pin file.
        std::fs::write(
            root.join("clusters/test-pins.json"),
            "{\"unrelated\": true}",
        )
        .unwrap();
        std::fs::create_dir_all(root.join("node_modules")).unwrap();
        std::fs::write(root.join("node_modules/pins.json"), "{ }").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(root.join("clusters"), root.join("result")).unwrap();

        let mut found = scan(root);
        found.sort();
        assert_eq!(
            found,
            vec![
                root.join("clusters/image-pins.json"),
                root.join("clusters/lab1/pins.json"),
            ]
        );
    }
}
