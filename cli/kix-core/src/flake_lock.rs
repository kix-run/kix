//! Read which Kix a project uses from its `flake.lock`.
//!
//! The project's Kix library is the input of its own flake named `kix`. When
//! that input pins a release tag `v<version>`, the version is the project's
//! Kix, exactly. When it is a local folder or a branch, or when the library
//! is part of the project's own flake, the project uses a development
//! library and has no release version.
//!
//! `flake.lock` is JSON, so this needs no Nix and no network. Kix reads it
//! before it parses its arguments, to choose which version runs
//! (`select` in the `kix` binary), and again when it checks the library
//! the project evaluated (`eval::nix`).

use std::fmt;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::version::Version;

/// The name of the lock file beside `flake.nix`.
pub const FILE: &str = "flake.lock";

/// The name of the flake input that holds the Kix library.
pub const INPUT: &str = "kix";

/// The input name Kix 0.9 also accepted. Kix refuses it with
/// [`OLD_NAME_ID`], so a project renames it.
pub const OLD_NAME: &str = "kixpkgs";

/// The id of the change record that renamed the library input.
pub const OLD_NAME_ID: &str = "K9179";

/// Which Kix a project uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectKix {
    /// The `kix` input pins the release tag of this version.
    Release(Version),
    /// The project uses a development Kix library, so it has no release
    /// version.
    Development(Development),
}

/// Where a development Kix library comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Development {
    /// The `kix` input is a folder on this machine.
    Folder(String),
    /// The `kix` input follows a branch, or a tag that names no release.
    Branch(String),
    /// `library = "self"` in `kix.toml`: the project's flake provides the
    /// Kix library itself, as the Kix repository does.
    OwnLibrary,
    /// `--override-input kix` replaces the input for this command.
    Override(String),
}

impl fmt::Display for Development {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Development::Folder(path) => write!(f, "the input kix is the local folder {path}"),
            Development::Branch(branch) => write!(f, "the input kix follows the branch {branch}"),
            Development::OwnLibrary => f.write_str("kix.toml sets library = \"self\""),
            Development::Override(url) => write!(f, "--override-input kix {url}"),
        }
    }
}

/// Why Kix cannot tell which Kix a project uses. Each message names one fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockError {
    /// The project has no `flake.lock`.
    Missing,
    /// `flake.lock` is not a lock Kix can read.
    Unreadable { path: PathBuf, message: String },
    /// The root of the lock has no input named `kix`.
    NoInput,
    /// The library input has the name Kix 0.9 also accepted. `version` is
    /// the release tag it pins, when it pins one.
    OldName { version: Option<Version> },
    /// The `kix` input follows an input of another flake.
    Follows(String),
    /// The `kix` input names no release tag: it has no ref, or it pins a
    /// commit.
    NoVersion,
    /// A person moved the tag in `flake.nix` after `flake.lock` was written.
    TagMoved {
        locked: Box<Version>,
        asked: Box<Version>,
    },
    /// `kix.toml` sets `library` to a value Kix does not know.
    Setting(String),
}

impl fmt::Display for LockError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let v = crate::version::running().release();
        match self {
            LockError::Missing => write!(
                f,
                "This project has no flake.lock. Run `kix upgrade --to {v}` to pin the Kix library and create it."
            ),
            LockError::Unreadable { path, message } => {
                write!(f, "Kix could not read {}: {message}", path.display())
            }
            LockError::NoInput => write!(
                f,
                "flake.lock has no input named kix, so Kix cannot tell which Kix library this project uses. Add `inputs.kix.url = \"github:kix-run/kix/v{v}\";` to flake.nix if it has no such input, then run `kix upgrade --to {v}`."
            ),
            LockError::OldName { version } => {
                let to = version.as_ref().map_or(v, Version::release);
                write!(
                    f,
                    "[{OLD_NAME_ID}] flake.nix names the Kix library input {OLD_NAME}, and Kix now reads only an input named {INPUT}. Rename the input to {INPUT} in flake.nix, then run `kix upgrade --to {to}`."
                )
            }
            LockError::Follows(path) => write!(
                f,
                "The input kix in flake.nix follows {path}, so the Kix library comes from another flake. Set `inputs.kix.url = \"github:kix-run/kix/v{v}\";` in flake.nix, then run `kix upgrade --to {v}`."
            ),
            LockError::NoVersion => write!(
                f,
                "flake.nix uses the Kix library without a version. Run `kix upgrade --to {v}` to pin one."
            ),
            LockError::TagMoved { locked, asked } => {
                let asked = asked.release();
                write!(
                    f,
                    "flake.nix asks for Kix {asked}, but flake.lock pins Kix {}. Run `kix upgrade --to {asked}`.",
                    locked.release()
                )
            }
            LockError::Setting(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for LockError {}

/// Return which Kix the project in `dir` uses. `overrides` are the
/// `--override-input` pairs of the command. An override of `kix`, or
/// `library = "self"` in `kix.toml`, makes the project use a development
/// library. For a project on a release, a `flake.nix` that now asks for
/// another tag than the lock pins is [`LockError::TagMoved`], found before
/// Nix evaluates and rewrites the lock.
pub fn project_kix(dir: &Path, overrides: &[(String, String)]) -> Result<ProjectKix, LockError> {
    if let Some((_, url)) = overrides.iter().rev().find(|(name, _)| name == INPUT) {
        return Ok(ProjectKix::Development(Development::Override(url.clone())));
    }
    if crate::project::library_is_self(dir).map_err(|e| LockError::Setting(e.to_string()))? {
        return Ok(ProjectKix::Development(Development::OwnLibrary));
    }
    let path = dir.join(FILE);
    let unreadable = |message: String| LockError::Unreadable {
        path: path.clone(),
        message,
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(LockError::Missing),
        Err(e) => return Err(unreadable(e.to_string())),
    };
    let lock: Value = serde_json::from_str(&text).map_err(|e| unreadable(e.to_string()))?;
    let kix = from_lock(&lock).map_err(|e| match e {
        LockError::Unreadable { message, .. } => unreadable(message),
        e => e,
    })?;
    if let ProjectKix::Release(locked) = &kix
        && let Some(original) = input_original(&lock)
        && let Ok(flake) = std::fs::read_to_string(dir.join("flake.nix"))
        && let Some(asked) = crate::pin_library::declared_tag(&flake, original)
        && &asked != locked
    {
        return Err(LockError::TagMoved {
            locked: Box::new(locked.clone()),
            asked: Box::new(asked),
        });
    }
    Ok(kix)
}

/// Return the `original` of the root's `kix` input in `lock`: the input as
/// `flake.nix` gave it when Nix wrote the lock.
pub fn input_original(lock: &Value) -> Option<&Value> {
    let root = lock["root"].as_str().unwrap_or("root");
    let key = lock["nodes"][root]["inputs"][INPUT].as_str()?;
    Some(&lock["nodes"][key]["original"])
}

/// Return which Kix the lock `lock` pins.
fn from_lock(lock: &Value) -> Result<ProjectKix, LockError> {
    let root = lock["root"].as_str().unwrap_or("root");
    let node = &lock["nodes"][root];
    if !node.is_object() {
        return Err(LockError::Unreadable {
            path: PathBuf::new(),
            message: "it has no root node".to_string(),
        });
    }
    let inputs = node["inputs"].as_object();
    let key = match inputs.and_then(|i| i.get(INPUT)) {
        None => return no_input(lock, inputs),
        Some(Value::String(key)) => key,
        Some(Value::Array(path)) => {
            let path: Vec<&str> = path.iter().filter_map(Value::as_str).collect();
            return Err(LockError::Follows(path.join("/")));
        }
        Some(_) => {
            return Err(LockError::Unreadable {
                path: PathBuf::new(),
                message: "the input kix is neither a node nor a follows path".to_string(),
            });
        }
    };
    match pinned(&lock["nodes"][key]["original"]) {
        Pinned::Tag(v) => Ok(ProjectKix::Release(v)),
        Pinned::Development(d) => Ok(ProjectKix::Development(d)),
        Pinned::Nothing => Err(LockError::NoVersion),
    }
}

/// Return the error for a lock whose root has no `kix` input.
fn no_input(
    lock: &Value,
    inputs: Option<&serde_json::Map<String, Value>>,
) -> Result<ProjectKix, LockError> {
    if let Some(Value::String(key)) = inputs.and_then(|i| i.get(OLD_NAME)) {
        let version = match pinned(&lock["nodes"][key]["original"]) {
            Pinned::Tag(v) => Some(v),
            _ => None,
        };
        return Err(LockError::OldName { version });
    }
    Err(LockError::NoInput)
}

/// What an input's `original` in a lock pins.
enum Pinned {
    Tag(Version),
    Development(Development),
    Nothing,
}

/// Return what `original`, the input as `flake.nix` gives it, pins.
fn pinned(original: &Value) -> Pinned {
    let s = |k: &str| original[k].as_str();
    let kind = s("type").unwrap_or_default();
    if kind == "path" {
        return Pinned::Development(Development::Folder(
            s("path").unwrap_or_default().to_string(),
        ));
    }
    if let Some(r) = s("ref") {
        let bare = r.strip_prefix("refs/tags/").unwrap_or(r);
        return match release_tag(bare) {
            Some(v) => Pinned::Tag(v),
            None => Pinned::Development(Development::Branch(
                r.strip_prefix("refs/heads/").unwrap_or(r).to_string(),
            )),
        };
    }
    // A Git repository on this machine with no ref follows its checkout.
    if kind == "git"
        && let Some(path) = s("url").and_then(|u| u.strip_prefix("file://"))
        && s("rev").is_none()
    {
        return Pinned::Development(Development::Folder(path.to_string()));
    }
    Pinned::Nothing
}

/// Return the version a release tag such as `v0.10.3` names.
pub fn release_tag(tag: &str) -> Option<Version> {
    tag.strip_prefix('v')?
        .parse::<Version>()
        .ok()
        .filter(|v| v.build.is_none())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn lock(inputs: Value, nodes: Value) -> Value {
        let mut all = json!({ "root": { "inputs": inputs } });
        for (k, v) in nodes.as_object().unwrap() {
            all[k] = v.clone();
        }
        json!({ "root": "root", "nodes": all, "version": 7 })
    }

    fn with_kix(original: Value) -> Value {
        lock(
            json!({ "kix": "kix", "nixpkgs": "nixpkgs" }),
            json!({ "kix": { "original": original, "locked": {} } }),
        )
    }

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    #[test]
    fn a_release_tag_is_the_version() {
        for original in [
            json!({ "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.10.3" }),
            json!({ "type": "git", "url": "ssh://git@git.example/org/kix.git", "ref": "refs/tags/v0.10.3" }),
            json!({ "type": "gitlab", "owner": "org", "repo": "kix", "ref": "v0.10.3" }),
        ] {
            assert_eq!(
                from_lock(&with_kix(original)),
                Ok(ProjectKix::Release(v("0.10.3")))
            );
        }
        let rc =
            json!({ "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.11.0-rc.1" });
        assert_eq!(
            from_lock(&with_kix(rc)),
            Ok(ProjectKix::Release(v("0.11.0-rc.1")))
        );
    }

    #[test]
    fn a_folder_or_a_branch_is_development() {
        let cases = [
            (
                json!({ "type": "path", "path": "../kix" }),
                Development::Folder("../kix".into()),
            ),
            (
                json!({ "type": "github", "owner": "kix-run", "repo": "kix", "ref": "main" }),
                Development::Branch("main".into()),
            ),
            (
                json!({ "type": "git", "url": "https://git.example/kix.git", "ref": "refs/heads/next" }),
                Development::Branch("next".into()),
            ),
            (
                json!({ "type": "git", "url": "file:///src/kix", "dir": "kix" }),
                Development::Folder("/src/kix".into()),
            ),
        ];
        for (original, development) in cases {
            assert_eq!(
                from_lock(&with_kix(original)),
                Ok(ProjectKix::Development(development))
            );
        }
    }

    #[test]
    fn no_ref_or_a_commit_has_no_version() {
        for original in [
            json!({ "type": "github", "owner": "kix-run", "repo": "kix" }),
            json!({ "type": "github", "owner": "kix-run", "repo": "kix", "rev": "0123456789abcdef" }),
            json!({ "type": "git", "url": "file:///src/kix", "rev": "0123456789abcdef" }),
            json!({ "type": "tarball", "url": "https://example.com/kix.tar.gz" }),
        ] {
            assert_eq!(from_lock(&with_kix(original)), Err(LockError::NoVersion));
        }
    }

    #[test]
    fn the_input_must_be_a_direct_input_named_kix() {
        let none = lock(json!({ "nixpkgs": "nixpkgs" }), json!({}));
        assert_eq!(from_lock(&none), Err(LockError::NoInput));
        let no_inputs = json!({ "root": "root", "nodes": { "root": {} }, "version": 7 });
        assert_eq!(from_lock(&no_inputs), Err(LockError::NoInput));

        let follows = lock(json!({ "kix": ["platform", "kix"] }), json!({}));
        assert_eq!(
            from_lock(&follows),
            Err(LockError::Follows("platform/kix".into()))
        );

        let old = lock(
            json!({ "kixpkgs": "kixpkgs" }),
            json!({ "kixpkgs": { "original": { "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.9.2" } } }),
        );
        assert_eq!(
            from_lock(&old),
            Err(LockError::OldName {
                version: Some(v("0.9.2"))
            })
        );
    }

    #[test]
    fn an_override_of_kix_is_development() {
        let dir = tempfile::tempdir().unwrap();
        let overrides = [("kix".to_string(), "path:/src/kix".to_string())];
        assert_eq!(
            project_kix(dir.path(), &overrides),
            Ok(ProjectKix::Development(Development::Override(
                "path:/src/kix".into()
            )))
        );
        assert_eq!(project_kix(dir.path(), &[]), Err(LockError::Missing));
    }

    #[test]
    fn library_self_in_kix_toml_is_development() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("kix.toml"), "library = \"self\"\n").unwrap();
        assert_eq!(
            project_kix(dir.path(), &[]),
            Ok(ProjectKix::Development(Development::OwnLibrary))
        );
        std::fs::write(dir.path().join("kix.toml"), "library = \"kix\"\n").unwrap();
        assert!(matches!(
            project_kix(dir.path(), &[]),
            Err(LockError::Setting(_))
        ));
    }

    #[test]
    fn a_tag_moved_in_flake_nix_is_found_before_nix_runs() {
        let dir = tempfile::tempdir().unwrap();
        let original =
            json!({ "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.10.0" });
        std::fs::write(dir.path().join(FILE), with_kix(original).to_string()).unwrap();
        let flake = |tag: &str| {
            std::fs::write(
                dir.path().join("flake.nix"),
                format!("{{ inputs.kix.url = \"github:kix-run/kix/{tag}\"; }}"),
            )
            .unwrap()
        };
        flake("v0.10.0");
        assert_eq!(
            project_kix(dir.path(), &[]),
            Ok(ProjectKix::Release(v("0.10.0")))
        );
        flake("v0.10.2");
        let err = project_kix(dir.path(), &[]).unwrap_err();
        assert_eq!(
            err,
            LockError::TagMoved {
                locked: Box::new(v("0.10.0")),
                asked: Box::new(v("0.10.2"))
            }
        );
        assert_eq!(
            err.to_string(),
            "flake.nix asks for Kix 0.10.2, but flake.lock pins Kix 0.10.0. Run `kix upgrade --to 0.10.2`."
        );
        // A branch is no release, so it is left to the check after evaluation.
        flake("main");
        assert!(project_kix(dir.path(), &[]).is_ok());
    }

    #[test]
    fn the_messages_name_one_fix() {
        let v = crate::version::running().release();
        assert_eq!(
            LockError::Missing.to_string(),
            format!(
                "This project has no flake.lock. Run `kix upgrade --to {v}` to pin the Kix library and create it."
            )
        );
        assert_eq!(
            LockError::NoVersion.to_string(),
            format!(
                "flake.nix uses the Kix library without a version. Run `kix upgrade --to {v}` to pin one."
            )
        );
        assert_eq!(
            LockError::OldName {
                version: Some("0.9.2".parse().unwrap())
            }
            .to_string(),
            "[K9179] flake.nix names the Kix library input kixpkgs, and Kix now reads only an input named kix. Rename the input to kix in flake.nix, then run `kix upgrade --to 0.9.2`."
        );
    }
}
