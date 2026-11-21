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

impl Development {
    /// Return where the development library of the input `input` comes
    /// from, as a message words it.
    pub fn describe(&self, input: &str) -> String {
        match self {
            Development::Folder(path) => {
                format!("the input {input} is the local folder {path}")
            }
            Development::Branch(branch) => {
                format!("the input {input} follows the branch {branch}")
            }
            Development::OwnLibrary => "kix.toml sets library = \"self\"".to_string(),
            Development::Override(url) => format!("--override-input {input} {url}"),
        }
    }
}

impl fmt::Display for Development {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.describe(INPUT))
    }
}

/// Why a lock does not show the Kix library as the project's input `kix`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputError {
    /// The lock has no root node, or its `kix` entry is neither a node nor a
    /// `follows` path.
    Malformed(&'static str),
    /// The root of the lock has no input named `kix`.
    Missing,
    /// The library input has the name Kix 0.9 also accepted. `version` is
    /// the release tag it pins, when it pins one.
    OldName { version: Option<Version> },
    /// The `kix` input follows an input of another flake.
    Follows(String),
}

impl InputError {
    /// Return what is wrong with the input and the change to `flake.nix`
    /// that fixes it, without a final period. `version` is the release the
    /// fixed input should name.
    pub fn change(&self, version: &str) -> String {
        self.change_of(INPUT, version)
    }

    /// Return [`InputError::change`] for the input `input`.
    pub fn change_of(&self, input: &str, version: &str) -> String {
        if input != INPUT {
            return match self {
                InputError::Malformed(message) => {
                    format!("Kix could not read flake.lock: {message}")
                }
                InputError::Missing | InputError::OldName { .. } => format!(
                    "Input `{input}` in kix.toml [versions] is missing from flake.nix or flake.lock. Make sure `inputs.{input}.url = \"github:kix-run/kix/v{version}\";` is set in flake.nix"
                ),
                InputError::Follows(path) => format!(
                    "Input `{input}` in flake.nix uses `follows` (`{path}`) instead of pinning a Kix version directly. Replace `follows` with `inputs.{input}.url = \"github:kix-run/kix/v{version}\";` in flake.nix"
                ),
            };
        }
        match self {
            InputError::Malformed(message) => {
                format!("Kix could not read the lock of flake.nix: {message}")
            }
            InputError::Missing => format!(
                "flake.nix has no input named {INPUT}, so Kix cannot tell which Kix library this project uses. Add `inputs.kix.url = \"github:kix-run/kix/v{version}\";` to flake.nix"
            ),
            InputError::OldName { .. } => format!(
                "[{OLD_NAME_ID}] flake.nix names the Kix library input {OLD_NAME}, and Kix now reads only an input named {INPUT}. Rename the input to {INPUT} in flake.nix"
            ),
            InputError::Follows(path) => format!(
                "The input {INPUT} in flake.nix follows {path}, so the Kix library comes from another flake. Set `inputs.kix.url = \"github:kix-run/kix/v{version}\";` in flake.nix"
            ),
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
    /// The lock does not show the Kix library as the input `kix`.
    Input(InputError),
    /// The `kix` input names no release tag: it has no ref, or it pins a
    /// commit.
    NoVersion,
    /// The lock does not show the Kix library as the input `input`, one
    /// that `[versions]` names beside `kix`.
    OtherInput { input: String, error: InputError },
    /// A person moved the tag of the input `input` in `flake.nix` after
    /// `flake.lock` was written.
    TagMoved {
        input: String,
        locked: Box<Version>,
        asked: Box<Version>,
    },
    /// `kix.toml` has a setting Kix refuses before it chooses a version.
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
            LockError::Input(e @ InputError::OldName { version }) => {
                let current = version.as_ref().map(Version::release);
                write!(
                    f,
                    "{}, then {}",
                    e.change(&v),
                    pin_then_upgrade(current.as_deref())
                )
            }
            LockError::Input(e @ InputError::Malformed(_)) => write!(f, "{}.", e.change(&v)),
            LockError::Input(e) => {
                write!(f, "{}, then run `kix upgrade --to {v}`.", e.change(&v))
            }
            LockError::NoVersion => write!(
                f,
                "flake.nix uses the Kix library without a version, so Kix cannot tell which version this project uses. To pin it, {}",
                pin_then_upgrade(None)
            ),
            LockError::OtherInput {
                input,
                error: error @ InputError::Malformed(_),
            } => write!(f, "{}.", error.change_of(input, "<version>")),
            LockError::OtherInput { input, error } => write!(
                f,
                "{}, then run `kix upgrade {input}`.",
                error.change_of(input, "<version>")
            ),
            LockError::TagMoved {
                input,
                locked,
                asked,
            } if input == INPUT => write!(
                f,
                "flake.nix asks for Kix {}, but flake.lock pins Kix {}. {}",
                asked.release(),
                locked.release(),
                moved_tag_next_step(input, locked, asked)
            ),
            LockError::TagMoved {
                input,
                locked,
                asked,
            } => write!(
                f,
                "For input `{input}`, flake.nix asks for Kix {}, but flake.lock pins Kix {}. {}",
                asked.release(),
                locked.release(),
                moved_tag_next_step(input, locked, asked)
            ),
            LockError::Setting(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for LockError {}

/// Return the steps that pin a project with no version to the one it uses
/// now, then upgrade it with a review of what changes. `current` is that
/// version when Kix knows it. The text starts with a lower-case verb so it
/// can follow another step.
///
/// Pinning a project that has no version builds nothing, so the second step
/// is the one that compares the project before and after.
pub fn pin_then_upgrade(current: Option<&str>) -> String {
    let pin = match current {
        Some(v) => {
            format!("run `kix upgrade --to {v}` to record the version this project uses now")
        }
        None => "run `kix upgrade --to <version>` with the version of Kix this project uses now"
            .to_string(),
    };
    format!("{pin}, then run `kix upgrade` to move to a newer version and review what changes.")
}

/// Return what to do when `flake.nix` asks for Kix `asked` but `flake.lock`
/// pins Kix `locked`. `kix upgrade` only moves a project to a newer version,
/// so an older `asked` gets the two ways out that do not need it.
pub fn moved_tag_next_step(input: &str, locked: &Version, asked: &Version) -> String {
    use crate::version::policy::{UpgradeVerdict, judge_upgrade};
    let command = if input == INPUT {
        "kix upgrade".to_string()
    } else {
        format!("kix upgrade {input}")
    };
    if judge_upgrade(locked, locked, asked) == UpgradeVerdict::Proceed {
        return format!("Run `{command} --to {}`.", asked.release());
    }
    let (locked, asked) = (locked.release(), asked.release());
    if input != INPUT {
        return format!(
            "`{command}` only moves an input to a newer version of Kix. To stay on Kix {locked}, set the tag of `inputs.{input}.url` in flake.nix back to v{locked}. To go back to Kix {asked}, restore flake.nix and flake.lock from a commit where `{input}` pinned Kix {asked}."
        );
    }
    format!(
        "`kix upgrade` only moves a project to a newer version of Kix. To stay on Kix {locked}, set the tag in flake.nix back to v{locked}. To go back to Kix {asked}, restore flake.nix and flake.lock from a commit that pinned it."
    )
}

/// Return which Kix the project in `dir` uses. `overrides` are the
/// `--override-input` pairs of the command. An override of `kix`, or
/// `library = "self"` in `kix.toml`, makes the project use a development
/// library. For a project on a release, a `flake.nix` that now asks for
/// another tag than the lock pins is [`LockError::TagMoved`], found before
/// Nix evaluates and rewrites the lock.
pub fn project_kix(dir: &Path, overrides: &[(String, String)]) -> Result<ProjectKix, LockError> {
    // An override of the input this run's cluster uses makes it a
    // development library.
    let input = crate::versions::chosen_input();
    if let Some((_, url)) = overrides.iter().rev().find(|(name, _)| name == input) {
        return Ok(ProjectKix::Development(Development::Override(url.clone())));
    }
    let library =
        crate::project::library_setting(dir).map_err(|e| LockError::Setting(e.to_string()))?;
    if library == crate::project::Library::OwnFlake {
        return Ok(ProjectKix::Development(Development::OwnLibrary));
    }
    let kix = locked_kix(dir, input);
    // When the lock names no release, this Kix judges the project, and it
    // reads kix.toml before flake.lock. A project on a release hands over to
    // that release, which judges kix.toml itself. A moved tag names releases,
    // so its own advice comes first.
    let no_release = matches!(
        kix,
        Err(LockError::Missing
            | LockError::Unreadable { .. }
            | LockError::Input(_)
            | LockError::OtherInput { .. }
            | LockError::NoVersion)
    );
    if no_release {
        crate::project::kix_setting(dir).map_err(|e| LockError::Setting(e.to_string()))?;
    }
    kix
}

/// Return which Kix the project in `dir` uses for a cluster on the input
/// `input_name`, as [`project_kix`] does for the input this run chose. Kix
/// calls this before it parses the command, when no input is chosen yet.
pub fn project_kix_on(
    dir: &Path,
    overrides: &[(String, String)],
    input_name: &str,
) -> Result<ProjectKix, LockError> {
    if input_name == INPUT {
        return project_kix(dir, overrides);
    }
    if let Some((_, url)) = overrides.iter().rev().find(|(name, _)| name == input_name) {
        return Ok(ProjectKix::Development(Development::Override(url.clone())));
    }
    locked_kix(dir, input_name)
}

/// Return which Kix the input `input_name` pins in the `flake.lock` in
/// `dir`, and refuse a tag moved in `flake.nix` since.
fn locked_kix(dir: &Path, input_name: &str) -> Result<ProjectKix, LockError> {
    let path = dir.join(FILE);
    let unreadable = |message: String| LockError::Unreadable {
        path: path.clone(),
        message,
    };
    let lock = read(dir)?;
    let original = input(&lock, input_name).map_err(|e| match e {
        InputError::Malformed(message) => unreadable(message.to_string()),
        e if input_name != INPUT => LockError::OtherInput {
            input: input_name.to_string(),
            error: e,
        },
        e => LockError::Input(e),
    })?;
    let kix = from_original(original)?;
    if let ProjectKix::Release(locked) = &kix
        && let Ok(flake) = std::fs::read_to_string(dir.join("flake.nix"))
        && let Some(asked) = crate::pin_library::declared_tag(&flake, input_name, original)
        && &asked != locked
    {
        return Err(LockError::TagMoved {
            input: input_name.to_string(),
            locked: Box::new(locked.clone()),
            asked: Box::new(asked),
        });
    }
    Ok(kix)
}

/// Read and parse the `flake.lock` in `dir`.
pub fn read(dir: &Path) -> Result<Value, LockError> {
    let path = dir.join(FILE);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Err(LockError::Missing),
        Err(e) => {
            return Err(LockError::Unreadable {
                path,
                message: e.to_string(),
            });
        }
    };
    serde_json::from_str(&text).map_err(|e| LockError::Unreadable {
        path,
        message: e.to_string(),
    })
}

/// Return each input node of `lock` that has `locked` attributes, as its
/// node name and those attributes. The root node is the project's own flake,
/// so it is left out.
pub fn locked_inputs(
    lock: &Value,
) -> impl Iterator<Item = (&str, &serde_json::Map<String, Value>)> {
    let root = lock["root"].as_str().unwrap_or("root");
    lock["nodes"]
        .as_object()
        .into_iter()
        .flatten()
        .filter(move |(name, _)| name.as_str() != root)
        .filter_map(|(name, node)| Some((name.as_str(), node["locked"].as_object()?)))
}

/// Return the `original` of the root's `kix` input in `lock`: the input as
/// `flake.nix` gave it when Nix wrote the lock.
pub fn kix_input(lock: &Value) -> Result<&Value, InputError> {
    input(lock, INPUT)
}

/// Return the `original` of the root's input `name` in `lock`: the input as
/// `flake.nix` gave it when Nix wrote the lock.
pub fn input<'a>(lock: &'a Value, name: &str) -> Result<&'a Value, InputError> {
    let root = lock["root"].as_str().unwrap_or("root");
    let node = &lock["nodes"][root];
    if !node.is_object() {
        return Err(InputError::Malformed("it has no root node"));
    }
    let inputs = node["inputs"].as_object();
    match inputs.and_then(|i| i.get(name)) {
        Some(Value::String(key)) => Ok(&lock["nodes"][key]["original"]),
        Some(Value::Array(path)) => {
            let path: Vec<&str> = path.iter().filter_map(Value::as_str).collect();
            Err(InputError::Follows(path.join("/")))
        }
        Some(_) => Err(InputError::Malformed(
            "the input kix is neither a node nor a follows path",
        )),
        None => match inputs.and_then(|i| i.get(OLD_NAME)) {
            Some(Value::String(key)) if name == INPUT => Err(InputError::OldName {
                version: match pinned(&lock["nodes"][key]["original"]) {
                    Pinned::Tag(v) => Some(v),
                    _ => None,
                },
            }),
            _ => Err(InputError::Missing),
        },
    }
}

/// Return which Kix an input's `original` pins.
pub fn from_original(original: &Value) -> Result<ProjectKix, LockError> {
    match pinned(original) {
        Pinned::Tag(v) => Ok(ProjectKix::Release(v)),
        Pinned::Development(d) => Ok(ProjectKix::Development(d)),
        Pinned::Nothing => Err(LockError::NoVersion),
    }
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
    if let Some(r) = s("ref").map(bare_ref) {
        return match release_tag(r) {
            Some(v) => Pinned::Tag(v),
            None => Pinned::Development(Development::Branch(r.to_string())),
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

/// Return a Git ref without `refs/tags/` or `refs/heads/`, as `flake.nix`
/// writes it.
pub fn bare_ref(r: &str) -> &str {
    r.strip_prefix("refs/tags/")
        .or_else(|| r.strip_prefix("refs/heads/"))
        .unwrap_or(r)
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
    fn locked_inputs_skip_the_root_and_unlocked_nodes() {
        let lock = json!({
            "root": "self",
            "nodes": {
                "self": { "inputs": { "kix": "kix" }, "locked": { "type": "path" } },
                "kix": { "locked": { "rev": "abc" } },
                "pending": { "original": {} },
            },
        });
        let names: Vec<&str> = locked_inputs(&lock).map(|(name, _)| name).collect();
        assert_eq!(names, ["kix"]);
    }

    #[test]
    fn read_tells_a_missing_lock_from_a_broken_one() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read(dir.path()), Err(LockError::Missing));
        std::fs::write(dir.path().join(FILE), "{").unwrap();
        assert!(matches!(
            read(dir.path()),
            Err(LockError::Unreadable { .. })
        ));
    }

    fn from_lock(lock: &Value) -> Result<ProjectKix, LockError> {
        kix_input(lock)
            .map_err(LockError::Input)
            .and_then(from_original)
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
        assert_eq!(from_lock(&none), Err(LockError::Input(InputError::Missing)));
        let no_inputs = json!({ "root": "root", "nodes": { "root": {} }, "version": 7 });
        assert_eq!(
            from_lock(&no_inputs),
            Err(LockError::Input(InputError::Missing))
        );

        let follows = lock(json!({ "kix": ["platform", "kix"] }), json!({}));
        assert_eq!(
            from_lock(&follows),
            Err(LockError::Input(InputError::Follows("platform/kix".into())))
        );

        let old = lock(
            json!({ "kixpkgs": "kixpkgs" }),
            json!({ "kixpkgs": { "original": { "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.9.2" } } }),
        );
        assert_eq!(
            from_lock(&old),
            Err(LockError::Input(InputError::OldName {
                version: Some(v("0.9.2"))
            }))
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
                input: "kix".into(),
                locked: Box::new(v("0.10.0")),
                asked: Box::new(v("0.10.2"))
            }
        );
        assert_eq!(
            err.to_string(),
            "flake.nix asks for Kix 0.10.2, but flake.lock pins Kix 0.10.0. Run `kix upgrade --to 0.10.2`."
        );
        // An older tag cannot be reached with `kix upgrade`.
        flake("v0.9.2");
        assert_eq!(
            project_kix(dir.path(), &[]).unwrap_err().to_string(),
            "flake.nix asks for Kix 0.9.2, but flake.lock pins Kix 0.10.0. `kix upgrade` only moves a project to a newer version of Kix. To stay on Kix 0.10.0, set the tag in flake.nix back to v0.10.0. To go back to Kix 0.9.2, restore flake.nix and flake.lock from a commit that pinned it."
        );
        // A branch is no release, so it is left to the check after evaluation.
        flake("main");
        assert!(project_kix(dir.path(), &[]).is_ok());
    }

    #[test]
    fn a_moved_tag_names_upgrade_only_for_a_newer_version() {
        let step = |locked: &str, asked: &str| moved_tag_next_step("kix", &v(locked), &v(asked));
        assert_eq!(
            step("0.10.0-rc.2", "0.10.0-rc.3"),
            "Run `kix upgrade --to 0.10.0-rc.3`."
        );
        assert_eq!(
            step("0.10.0-rc.3", "0.10.0"),
            "Run `kix upgrade --to 0.10.0`."
        );
        assert_eq!(
            step("0.10.0-rc.3", "0.10.0-rc.2"),
            "`kix upgrade` only moves a project to a newer version of Kix. To stay on Kix 0.10.0-rc.3, set the tag in flake.nix back to v0.10.0-rc.3. To go back to Kix 0.10.0-rc.2, restore flake.nix and flake.lock from a commit that pinned it."
        );
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
            "flake.nix uses the Kix library without a version, so Kix cannot tell which version this project uses. To pin it, run `kix upgrade --to <version>` with the version of Kix this project uses now, then run `kix upgrade` to move to a newer version and review what changes."
        );
        assert_eq!(
            LockError::Input(InputError::OldName {
                version: Some("0.9.2".parse().unwrap())
            })
            .to_string(),
            "[K9179] flake.nix names the Kix library input kixpkgs, and Kix now reads only an input named kix. Rename the input to kix in flake.nix, then run `kix upgrade --to 0.9.2` to record the version this project uses now, then run `kix upgrade` to move to a newer version and review what changes."
        );
        assert_eq!(
            LockError::Input(InputError::Missing).to_string(),
            format!(
                "flake.nix has no input named kix, so Kix cannot tell which Kix library this project uses. Add `inputs.kix.url = \"github:kix-run/kix/v{v}\";` to flake.nix, then run `kix upgrade --to {v}`."
            )
        );
    }

    #[test]
    fn a_lock_kix_cannot_read_names_its_path() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FILE);
        std::fs::write(&path, r#"{"root":"root","nodes":{}}"#).unwrap();
        assert_eq!(
            project_kix(dir.path(), &[]),
            Err(LockError::Unreadable {
                path,
                message: "it has no root node".into()
            })
        );
    }

    #[test]
    fn a_ref_loses_its_prefix() {
        assert_eq!(bare_ref("refs/tags/v0.10.0"), "v0.10.0");
        assert_eq!(bare_ref("refs/heads/main"), "main");
        assert_eq!(bare_ref("main"), "main");
    }

    #[test]
    fn the_kix_setting_comes_before_the_lock() {
        let dir = tempfile::tempdir().unwrap();
        let original = json!({ "type": "github", "owner": "kix-run", "repo": "kix" });
        std::fs::write(dir.path().join(FILE), with_kix(original).to_string()).unwrap();
        assert_eq!(project_kix(dir.path(), &[]), Err(LockError::NoVersion));
        std::fs::write(dir.path().join("kix.toml"), "kix = \"0.10.0-rc.3\"\n").unwrap();
        let err = project_kix(dir.path(), &[]).unwrap_err().to_string();
        assert!(err.starts_with("[K4476] "), "{err}");
        // A project on a release goes to that release, which reads kix.toml.
        let original =
            json!({ "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.9.2" });
        std::fs::write(dir.path().join(FILE), with_kix(original).to_string()).unwrap();
        assert_eq!(
            project_kix(dir.path(), &[]),
            Ok(ProjectKix::Release(v("0.9.2")))
        );
        // A tag moved in flake.nix names a release, so its advice comes first.
        std::fs::write(
            dir.path().join("flake.nix"),
            "{ inputs.kix.url = \"github:kix-run/kix/v0.10.0\"; }",
        )
        .unwrap();
        assert!(matches!(
            project_kix(dir.path(), &[]),
            Err(LockError::TagMoved { .. })
        ));
    }
}
