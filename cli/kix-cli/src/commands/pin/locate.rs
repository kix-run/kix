//! Finding the pin file when nobody named one.
//!
//! `--pins-file` used to be required in practice, because its default was
//! `pins.json` in the working directory and a pin file normally sits next to
//! the cluster definition rather than next to the shell. Every documented
//! example therefore repeated the same path on every line, which is the shape
//! of a flag that should have been a default.
//!
//! The flake cannot supply it without a cost. A path literal inside a flake
//! evaluates to a store path (`/nix/store/<hash>-source/clusters/pins.json`),
//! not to a file you can write, so reading a declaration out of the flake
//! means evaluating the flake and then reconstructing the source path from
//! `self`. That trades away the property `kix pin` exists to have: it works
//! when evaluation does not. So the CLI finds the file instead of being told.
//!
//! The order is: what you passed, then the working directory, then the flake
//! directory, then a bounded scan of the repository. Ambiguity is refused
//! rather than guessed, because writing a digest into the wrong file is a
//! quiet failure and being asked which one is a loud one.

use std::path::{Path, PathBuf};

use miette::{Result, miette};

/// How the pin file was found, so the command can say so.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum How {
    /// `--pins-file` said so.
    Flag,
    /// It was in the working directory.
    Cwd,
    /// It was next to the flake.
    Flake,
    /// It was the only one in the repository.
    Scan,
}

#[derive(Debug, Clone)]
pub struct Location {
    pub path: PathBuf,
    pub how: How,
}

impl Location {
    /// A short phrase for the line the command prints when it chose the file
    /// itself. Nothing is printed for `--pins-file`, because the reader wrote
    /// it and does not need telling.
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

/// Find the pin file to read, or say plainly that there is not one.
///
/// `Ok(None)` means nothing was found, which `--init` is allowed to act on.
/// `Err` means something was found and it was not one thing, which nothing is
/// allowed to act on.
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

    // Only inside a repository. Scanning an arbitrary working directory
    // means scanning whatever happens to be under it, which on a home
    // directory is slow and on a temp directory is somebody else's files.
    let root = repo_root();
    let mut found = match &root {
        Some(root) => scan(root),
        None => Vec::new(),
    };
    found.sort();

    decide(found)
}

/// What the scan's result means. Split out because the distinction it draws
/// is the one that is easy to get wrong: nothing found is an absence that
/// `--init` may answer, and several found is an error that it may not.
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

/// Find the pin file to read, or the path to create when there is none.
///
/// `kix pin set --init` is the one command that is allowed to invent a path,
/// and it invents a predictable one: next to the flake, because that is where
/// the cluster definition that reads it lives.
pub fn locate_or_init(explicit: Option<&Path>, flake: &str) -> Result<Location> {
    // `find` returning Err means there is more than one pin file. Creating
    // another one is the worst possible answer to that, so it propagates.
    Ok(find(explicit, flake)?.unwrap_or_else(|| Location {
        path: match flake_dir(flake) {
            Some(dir) => dir.join("pins.json"),
            None => PathBuf::from("pins.json"),
        },
        how: How::Flake,
    }))
}

/// The local directory a flake reference names, if it names one at all.
/// `github:owner/repo` and friends have no directory to look in.
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

/// A path as the reader would type it, when it is below the working
/// directory. An absolute path is correct but harder to retype.
fn display_from_cwd(path: &Path) -> String {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    match path.strip_prefix(&cwd) {
        Ok(rel) => rel.display().to_string(),
        Err(_) => path.display().to_string(),
    }
}

/// The git root above the working directory, if there is one.
///
/// Shared with the workflow check, which needs a repository root to express a
/// path the way a `paths:` filter sees it.
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

/// Every pin file under `root`, to a bounded depth.
///
/// A pin file is one called `pins.json`, or one whose name ends in
/// `pins.json` and that declares `managedBy`. The second condition keeps an
/// unrelated JSON file that happens to end in `pins.json` from being read as
/// a pin file and reported as a second candidate.
///
/// Symlinks are not followed. A `nix build` leaves a `result` symlink into the
/// store, and walking into it is both slow and wrong.
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
