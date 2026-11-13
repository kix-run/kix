//! Move the Kix library a project pins to the release tag of a version of
//! Kix, and check that the project then builds with a library that version
//! can build.
//!
//! Kix reads one source: the lock that `flake.nix` gives now, from
//! `nix flake metadata --no-write-lock-file`. It never decides anything from
//! `flake.lock` on disk. The library is the input of the project's own flake
//! named `kix` or `kixpkgs`, or the one `library-input` in `kix.toml` names.
//! What Kix does depends on what `flake.nix` says that input follows:
//!
//! - no ref, such as `github:kix-run/kix`: Kix locks the tag with
//!   `nix flake lock --override-input` and leaves `flake.nix` alone. Nix keeps
//!   the input's `original` from `flake.nix`, so a later plain evaluation
//!   keeps the lock.
//! - a version tag, such as `github:kix-run/kix/v0.9.1`: Kix changes that tag
//!   in `flake.nix`, then locks.
//! - a branch, a commit, or a local folder: Kix changes nothing, because a
//!   person chose it.
//!
//! A mirror or a fork counts as the library like any other input. One
//! evaluation of the library's version then confirms the result.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::eval::nix::{NixCommandError, command, output};
use crate::library::{LibraryVersion, try_eval_version};
use crate::project::ProjectConfig;
use crate::runtime::Tool;
use crate::version::Version;
use crate::version::policy::{self, Incompatible};

/// The input names that mark the Kix library when `kix.toml` sets no
/// `library-input`.
pub const INPUT_NAMES: [&str; 2] = ["kix", "kixpkgs"];

/// What `flake.nix` says the library input follows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Follows {
    /// No ref: the default branch until something locks it.
    NoRef,
    /// A release tag such as `v0.9.1`.
    Tag(String),
    /// A branch, or a tag that names no release, as `flake.nix` gives it.
    Branch(String),
    /// A commit, shortened.
    Commit(String),
    /// A folder on this machine.
    LocalPath(String),
}

impl Follows {
    /// Return whether Kix moves an input that follows this.
    fn moves(&self) -> bool {
        matches!(self, Follows::NoRef | Follows::Tag(_))
    }

    /// Return the sentence that says Kix leaves the input `input` alone, or
    /// `None` when Kix moves it.
    fn left_alone(&self, input: &str) -> Option<String> {
        let what = match self {
            Follows::NoRef | Follows::Tag(_) => return None,
            Follows::Branch(r) => match r.strip_prefix("refs/tags/") {
                Some(tag) => format!("follows the tag {tag}"),
                None => format!(
                    "follows the branch {}",
                    r.strip_prefix("refs/heads/").unwrap_or(r)
                ),
            },
            Follows::Commit(rev) => format!("follows the commit {rev}"),
            Follows::LocalPath(path) => format!("is the local folder {path}"),
        };
        Some(format!("The input {input} {what}, so Kix leaves it alone."))
    }
}

/// More than one url in `flake.nix` names the library's tag, and Kix cannot
/// tell which one is the library input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandEdit {
    /// The tag the urls name now, such as `v0.8.0-rc.1`.
    pub from_tag: String,
    /// The tag the library input must name, such as `v0.9.1`.
    pub to_tag: String,
    /// Each line that names `from_tag`: its number and its text.
    pub lines: Vec<(usize, String)>,
}

/// Why Kix did not move the library, or moved it and found the wrong
/// version. Each message says what to change. Kix changed no file, or put
/// back the files it changed.
#[derive(Debug, thiserror::Error)]
pub enum PinLibraryError {
    #[error("{0}")]
    Project(#[from] crate::project::ProjectError),

    #[error("Kix could not read the inputs of flake.nix: {0}")]
    Read(Box<NixCommandError>),

    #[error(
        "flake.nix has no input named kix or kixpkgs, so Kix cannot tell which input holds the Kix library. Set library-input in kix.toml to the name of that input, such as library-input = \"kix\"."
    )]
    NotFound,

    #[error(
        "kix.toml sets library-input = \"{0}\", but flake.nix has no input named {0}. Set library-input to the name of the input that holds the Kix library."
    )]
    SettingNotFound(String),

    #[error(
        "flake.nix has an input named kix and an input named kixpkgs, so Kix cannot tell which one holds the Kix library. Set library-input in kix.toml to its name, such as library-input = \"kix\"."
    )]
    BothNames,

    /// The library comes from an input of another flake.
    #[error(
        "{reason} Kix moves only an input that flake.nix declares itself. Add these lines to flake.nix:\n{}",
        .lines.iter().map(|l| format!("  {l}")).collect::<Vec<_>>().join("\n")
    )]
    Nested { reason: String, lines: Vec<String> },

    #[error(
        "The input {input} reads the Kix library from {url}, and Kix can move only a Git repository or a GitHub, GitLab, or SourceHut repository to a release tag. Point the input at the tag {tag}, such as github:kix-run/kix/{tag}."
    )]
    Unsupported {
        input: String,
        url: String,
        tag: String,
    },

    #[error(
        "Kix could not find the tag {from_tag} of the input {input} in flake.nix, so it changed nothing. Change that tag to {to_tag} in flake.nix."
    )]
    TagNotFound {
        input: String,
        from_tag: String,
        to_tag: String,
    },

    #[error(
        "Kix cannot tell which url in flake.nix is the Kix library input, because more than one names the tag {}:\n{}\nChange the tag of the Kix library input to {} in flake.nix, and leave the other inputs on {}.",
        .0.from_tag,
        .0.lines.iter().map(|(n, l)| format!("  flake.nix:{n}:   {l}")).collect::<Vec<_>>().join("\n"),
        .0.to_tag,
        .0.from_tag
    )]
    Edit(HandEdit),

    #[error(
        "Nix could not lock {url}: {source}. Check that {repo} has the tag {tag}. For a mirror, push the tag to the mirror."
    )]
    Lock {
        url: String,
        repo: String,
        tag: String,
        #[source]
        source: Box<NixCommandError>,
    },

    #[error("{0}")]
    Check(String),

    #[error("could not {action} {}: {source}", path.display())]
    Io {
        action: &'static str,
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

impl PinLibraryError {
    /// Return the Nix error output, for a caller that shows only its last
    /// lines.
    pub fn nix_output(&self) -> Option<&str> {
        match self {
            PinLibraryError::Read(e) | PinLibraryError::Lock { source: e, .. } => Some(&e.stderr),
            _ => None,
        }
    }
}

/// What Kix will do to move the library input, worked out before it
/// changes anything.
#[derive(Debug, Clone)]
pub struct Plan {
    dir: PathBuf,
    /// The version of Kix the library must match.
    pub version: Version,
    /// The name of the library input in `flake.nix`.
    pub input: String,
    pub follows: Follows,
    /// The tag, or else the short commit, the lock holds now.
    pub before: String,
    /// The release tag's url, for an input Kix moves.
    tag_url: Option<String>,
    /// The repository the input reads, as a person would write it.
    repo: String,
    /// `flake.nix` with the tag moved, when it must change.
    new_flake: Option<String>,
    /// The `follows` lines that make other inputs use this library.
    follows_lines: Vec<String>,
}

/// What [`Plan::apply`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pinned {
    pub input: String,
    pub follows: Follows,
    /// The tag, or else the short commit, the lock held before.
    pub before: String,
    /// The version of the library the project builds with now.
    pub library: Version,
    /// The files Kix changed, `flake.nix` before `flake.lock`.
    pub changed: Vec<&'static str>,
    pub dry_run: bool,
    /// The version of Kix the library was moved to.
    pub version: Version,
}

impl Pinned {
    /// Return the sentences that say what Kix did, without the files to
    /// commit.
    pub fn summary(&self) -> String {
        let to = self.version.release();
        if let Some(alone) = self.follows.left_alone(&self.input) {
            return format!(
                "{alone} It holds the Kix library {}.",
                self.library.release()
            );
        }
        let retags = matches!(&self.follows, Follows::Tag(t) if *t != format!("v{to}"));
        if self.dry_run {
            if self.before == format!("v{to}") {
                return format!("Kix library is already {to}. This was a dry run.");
            }
            let edit = if retags {
                " Kix would change the tag in flake.nix."
            } else {
                ""
            };
            return format!(
                "Kix library: {} -> {to}.{edit} This was a dry run, so Kix changed no files.",
                self.before
            );
        }
        if self.changed.is_empty() {
            return format!("Kix library is already {to}.");
        }
        let edit = if self.changed.contains(&"flake.nix") {
            " Kix changed the tag in flake.nix."
        } else {
            ""
        };
        format!("Kix library: {} -> {to}.{edit}", self.before)
    }
}

/// Move the Kix library input of the project in `dir` to the release tag of
/// Kix `version`, and check the library version the project then builds
/// with. With `dry_run`, check the tag and write nothing.
pub fn pin_library(
    dir: &Path,
    version: &Version,
    dry_run: bool,
) -> Result<Pinned, PinLibraryError> {
    plan(dir, version)?.apply(dry_run)
}

/// Work out how to move the Kix library input of the project in `dir` to
/// the release tag of Kix `version`, without changing anything.
pub fn plan(dir: &Path, version: &Version) -> Result<Plan, PinLibraryError> {
    let config = ProjectConfig::read(Some(dir), None)?;
    let locks = read_locks(dir)?;
    let flake_path = dir.join("flake.nix");
    let flake = std::fs::read_to_string(&flake_path).map_err(|source| PinLibraryError::Io {
        action: "read",
        path: flake_path,
        source,
    })?;
    decide(
        dir,
        &locks,
        &flake,
        version,
        config.library_input.as_deref(),
    )
}

/// Return the lock that `flake.nix` in `dir` gives now, without writing it.
fn read_locks(dir: &Path) -> Result<Value, PinLibraryError> {
    let read_error = |e| PinLibraryError::Read(Box::new(e));
    let mut cmd = command(Tool::Nix).map_err(read_error)?;
    cmd.args([
        "flake",
        "metadata",
        "--json",
        "--no-write-lock-file",
        "--extra-experimental-features",
        "nix-command flakes",
    ])
    .current_dir(dir);
    let out = output(&mut cmd).map_err(read_error)?;
    let metadata: Value = serde_json::from_slice(&out).map_err(|e| {
        PinLibraryError::Check(format!(
            "Kix could not read the output of `nix flake metadata`: {e}"
        ))
    })?;
    Ok(metadata["locks"].clone())
}

/// Return whether `r`, a ref without `refs/tags/`, names a release.
fn is_release_tag(r: &str) -> bool {
    r.strip_prefix('v')
        .is_some_and(|v| v.starts_with(|c: char| c.is_ascii_digit()))
}

/// Return the key of the root node of `locks` and its inputs.
fn root_inputs(locks: &Value) -> (&str, Option<&serde_json::Map<String, Value>>) {
    let root = locks["root"].as_str().unwrap_or("root");
    (root, locks["nodes"][root]["inputs"].as_object())
}

/// Work out the [`Plan`] from `locks`, the lock that `flake.nix` gives now,
/// and `flake`, the text of `flake.nix`.
fn decide(
    dir: &Path,
    locks: &Value,
    flake: &str,
    version: &Version,
    setting: Option<&str>,
) -> Result<Plan, PinLibraryError> {
    let tag = format!("v{}", version.release());
    let names: Vec<&str> = match setting {
        Some(name) => vec![name],
        None => INPUT_NAMES.to_vec(),
    };
    let (_, inputs) = root_inputs(locks);
    let present: Vec<&str> = names
        .iter()
        .copied()
        .filter(|n| inputs.is_some_and(|i| i.contains_key(*n)))
        .collect();
    let input = match (present.as_slice(), setting) {
        ([one], _) => one.to_string(),
        ([], Some(name)) => {
            return Err(nested(locks, &names, &tag)
                .unwrap_or_else(|| PinLibraryError::SettingNotFound(name.to_string())));
        }
        ([], None) => return Err(nested(locks, &names, &tag).unwrap_or(PinLibraryError::NotFound)),
        _ => return Err(PinLibraryError::BothNames),
    };
    let node_key = match &inputs.expect("the input exists")[&input] {
        Value::String(key) => key.clone(),
        Value::Array(path) => {
            let path: Vec<&str> = path.iter().filter_map(Value::as_str).collect();
            let original = follows_target(locks, &path);
            let url = original
                .map(|o| tagged_url(o, &tag))
                .unwrap_or_else(|| format!("github:kix-run/kix/{tag}"));
            return Err(PinLibraryError::Nested {
                reason: format!(
                    "The input {input} follows {}, so the Kix library comes from another flake.",
                    path.join("/")
                ),
                lines: vec![format!("inputs.{input}.url = \"{url}\";")],
            });
        }
        _ => return Err(PinLibraryError::NotFound),
    };
    let node = &locks["nodes"][&node_key];
    let original = &node["original"];
    let s = |k: &str| original[k].as_str();
    let repo = repo_url(original);
    let follows = if s("type") == Some("path") {
        Follows::LocalPath(s("path").unwrap_or_default().to_string())
    } else if let Some(rev) = s("rev") {
        Follows::Commit(rev.chars().take(7).collect())
    } else if let Some(r) = s("ref") {
        let bare = r.strip_prefix("refs/tags/").unwrap_or(r);
        if is_release_tag(bare) {
            Follows::Tag(bare.to_string())
        } else {
            Follows::Branch(r.to_string())
        }
    } else {
        Follows::NoRef
    };
    let movable = matches!(s("type"), Some("github" | "gitlab" | "sourcehut" | "git"));
    if follows.moves() && !movable {
        return Err(PinLibraryError::Unsupported {
            input,
            url: repo,
            tag,
        });
    }
    let short_rev = || {
        node["locked"]["rev"]
            .as_str()
            .map(|r| r.chars().take(7).collect::<String>())
    };
    let locked_tag = node["locked"]["ref"]
        .as_str()
        .and_then(|r| r.strip_prefix("refs/tags/"))
        .filter(|r| is_release_tag(r))
        .map(str::to_string);
    let before = match &follows {
        Follows::Tag(t) => t.clone(),
        _ => locked_tag
            .or_else(short_rev)
            .unwrap_or_else(|| "an unlocked input".to_string()),
    };
    let new_flake = match &follows {
        Follows::Tag(from) if *from != tag => Some(
            retag_flake(flake, original, from, &tag).map_err(|e| match e {
                Retag::NotFound => PinLibraryError::TagNotFound {
                    input: input.clone(),
                    from_tag: from.clone(),
                    to_tag: tag.clone(),
                },
                Retag::Many(edit) => PinLibraryError::Edit(edit),
            })?,
        ),
        _ => None,
    };
    let follows_lines = other_libraries(locks, &names, &node_key)
        .into_iter()
        .map(|(owner, name)| format!("inputs.{owner}.inputs.{name}.follows = \"{input}\";"))
        .collect();
    Ok(Plan {
        dir: dir.to_path_buf(),
        version: version.clone(),
        tag_url: follows.moves().then(|| tagged_url(original, &tag)),
        input,
        follows,
        before,
        repo,
        new_flake,
        follows_lines,
    })
}

/// Return the `original` of the node that the `follows` path `path` reaches
/// from the root of `locks`.
fn follows_target<'a>(locks: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let (root, _) = root_inputs(locks);
    let mut key = root.to_string();
    for name in path {
        key = locks["nodes"][&key]["inputs"][*name].as_str()?.to_string();
    }
    Some(&locks["nodes"][&key]["original"])
}

/// Return each input `(owner, name)` of a root input `owner` whose own
/// input `name`, one of `names`, is a Kix library other than the node
/// `library`.
fn other_libraries(locks: &Value, names: &[&str], library: &str) -> Vec<(String, String)> {
    let (_, inputs) = root_inputs(locks);
    let mut found = Vec::new();
    for (owner, edge) in inputs.into_iter().flatten() {
        let Some(key) = edge.as_str() else { continue };
        let Some(own) = locks["nodes"][key]["inputs"].as_object() else {
            continue;
        };
        for (name, edge) in own {
            if names.contains(&name.as_str()) && edge.as_str().is_some_and(|k| k != library) {
                found.push((owner.clone(), name.clone()));
            }
        }
    }
    found
}

/// Return the error for a project whose only Kix library is an input of
/// another flake, or `None` when it has none.
fn nested(locks: &Value, names: &[&str], tag: &str) -> Option<PinLibraryError> {
    let (owner, name) = other_libraries(locks, names, "").into_iter().next()?;
    let original = follows_target(locks, &[owner.as_str(), name.as_str()]);
    let url = original
        .map(|o| tagged_url(o, tag))
        .unwrap_or_else(|| format!("github:kix-run/kix/{tag}"));
    Some(PinLibraryError::Nested {
        reason: format!(
            "The Kix library comes from the input {owner}, through its own input {name}."
        ),
        lines: vec![
            format!("inputs.{name}.url = \"{url}\";"),
            format!("inputs.{owner}.inputs.{name}.follows = \"{name}\";"),
        ],
    })
}

/// Return the repository `original` reads, without a ref, as a person would
/// write it in `flake.nix`.
fn repo_url(original: &Value) -> String {
    let s = |k: &str| original[k].as_str().unwrap_or_default();
    match original["type"].as_str() {
        Some(kind @ ("github" | "gitlab" | "sourcehut")) => {
            format!("{kind}:{}/{}", s("owner"), s("repo"))
        }
        Some("path") => format!("path:{}", s("path")),
        Some(kind) => format!("{kind}+{}", s("url")),
        None => "an input of unknown type".to_string(),
    }
}

/// Return the url of the same repository as `original` at the tag `tag`.
fn tagged_url(original: &Value, tag: &str) -> String {
    let s = |k: &str| original[k].as_str();
    match s("type") {
        Some(kind @ ("github" | "gitlab" | "sourcehut")) => {
            let mut url = format!(
                "{kind}:{}/{}/{tag}",
                s("owner").unwrap_or_default(),
                s("repo").unwrap_or_default()
            );
            if let Some(host) = s("host") {
                url.push_str(&format!("?host={host}"));
            }
            url
        }
        _ => format!("git+{}?ref=refs/tags/{tag}", s("url").unwrap_or_default()),
    }
}

/// Why [`retag_flake`] changed nothing.
#[derive(Debug, PartialEq, Eq)]
enum Retag {
    /// No url of the input's repository names the tag.
    NotFound,
    /// More than one does.
    Many(HandEdit),
}

/// Return whether `at` lies on a line that is a comment.
fn in_comment(text: &str, at: usize) -> bool {
    let line_start = text[..at].rfind('\n').map_or(0, |n| n + 1);
    text[line_start..at].trim_start().starts_with('#')
}

/// Return the span of `tag` where it ends `url`'s ref: after a `/` or `=`,
/// and at the end or before `&` or `?`.
fn tag_span(url: &str, tag: &str) -> Option<(usize, usize)> {
    url.match_indices(tag)
        .map(|(at, _)| (at, at + tag.len()))
        .find(|&(at, end)| {
            url[..at].ends_with(['/', '='])
                && (url[end..].is_empty() || url[end..].starts_with(['&', '?']))
        })
}

/// Return the text a url of the repository `original` contains, in lower
/// case: `owner/repo` for a forge, or the url without its scheme for Git.
fn repo_needle(original: &Value) -> String {
    let s = |k: &str| original[k].as_str().unwrap_or_default();
    let needle = match original["type"].as_str() {
        Some("github" | "gitlab" | "sourcehut") => format!("{}/{}", s("owner"), s("repo")),
        _ => {
            let url = s("url");
            let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
            rest.trim_end_matches('/')
                .trim_end_matches(".git")
                .to_string()
        }
    };
    needle.to_ascii_lowercase()
}

/// Return `flake`, a `flake.nix`, with the tag `from` in the url of the
/// repository `original` changed to `to`.
///
/// Kix reads no Nix syntax to do this. It changes the tag only when exactly
/// one url of that repository names `from`. A project can pin a second
/// input to the same url, such as the Kix it builds into an image, and that
/// input must stay. Comment lines are skipped.
fn retag_flake(flake: &str, original: &Value, from: &str, to: &str) -> Result<String, Retag> {
    let needle = repo_needle(original);
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(open) = flake[at..].find('"').map(|i| at + i) {
        let Some(close) = flake[open + 1..].find('"').map(|i| open + 1 + i) else {
            break;
        };
        let literal = &flake[open + 1..close];
        if !in_comment(flake, open)
            && literal.to_ascii_lowercase().contains(&needle)
            && let Some((start, end)) = tag_span(literal, from)
        {
            found.push((open + 1 + start, open + 1 + end));
        }
        at = close + 1;
    }
    match found.as_slice() {
        [] => Err(Retag::NotFound),
        [(start, end)] => Ok(format!("{}{to}{}", &flake[..*start], &flake[*end..])),
        many => Err(Retag::Many(HandEdit {
            from_tag: from.to_string(),
            to_tag: to.to_string(),
            lines: many
                .iter()
                .map(|(start, _)| {
                    let number = flake[..*start].matches('\n').count() + 1;
                    let line = flake.lines().nth(number - 1).unwrap_or_default();
                    (number, line.trim().to_string())
                })
                .collect(),
        })),
    }
}

/// The contents of a file before Kix changed it, `None` when it did not
/// exist.
struct Saved(PathBuf, Option<Vec<u8>>);

impl Saved {
    fn take(path: PathBuf) -> Result<Self, PinLibraryError> {
        match std::fs::read(&path) {
            Ok(bytes) => Ok(Saved(path, Some(bytes))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Saved(path, None)),
            Err(source) => Err(PinLibraryError::Io {
                action: "read",
                path,
                source,
            }),
        }
    }

    fn changed(&self) -> bool {
        std::fs::read(&self.0).ok() != self.1
    }

    fn restore(&self) {
        let result = match &self.1 {
            Some(bytes) => std::fs::write(&self.0, bytes),
            None if self.0.exists() => std::fs::remove_file(&self.0),
            None => Ok(()),
        };
        if let Err(e) = result {
            tracing::warn!(path = %self.0.display(), error = %e, "could not put a file back");
        }
    }
}

impl Plan {
    /// Move the library input as planned, then evaluate the library version
    /// the project builds with and check it against [`Plan::version`]. When
    /// the check fails, put `flake.nix` and `flake.lock` back. With
    /// `dry_run`, evaluate the project with the input on the tag and write
    /// nothing.
    pub fn apply(&self, dry_run: bool) -> Result<Pinned, PinLibraryError> {
        let flake = Saved::take(self.dir.join("flake.nix"))?;
        let lock = Saved::take(self.dir.join("flake.lock"))?;
        let mut overrides = Vec::new();
        if dry_run {
            if let Some(url) = &self.tag_url {
                overrides.push((self.input.clone(), url.clone()));
            }
        } else if self.follows.moves() {
            if let Some(text) = &self.new_flake {
                std::fs::write(&flake.0, text).map_err(|source| PinLibraryError::Io {
                    action: "write",
                    path: flake.0.clone(),
                    source,
                })?;
            }
            // A tag in flake.nix needs only a lock. An input without a ref
            // is locked to the tag for this one command.
            let tag_override = match self.follows {
                Follows::NoRef => self.tag_url.as_deref(),
                _ => None,
            };
            if let Err(e) = self.lock(tag_override) {
                flake.restore();
                lock.restore();
                return Err(e);
            }
        }
        let changed: Vec<&'static str> = [(&flake, "flake.nix"), (&lock, "flake.lock")]
            .into_iter()
            .filter(|(saved, _)| saved.changed())
            .map(|(_, name)| name)
            .collect();
        match self.check(&overrides) {
            Ok(library) => Ok(Pinned {
                input: self.input.clone(),
                follows: self.follows.clone(),
                before: self.before.clone(),
                library,
                changed,
                dry_run,
                version: self.version.clone(),
            }),
            Err(message) => {
                let restored = if changed.is_empty() {
                    ""
                } else {
                    flake.restore();
                    lock.restore();
                    " Kix put flake.nix and flake.lock back."
                };
                Err(PinLibraryError::Check(format!("{message}{restored}")))
            }
        }
    }

    /// Run `nix flake lock`, with the library input locked to `tag_url`
    /// when it is set.
    fn lock(&self, tag_url: Option<&str>) -> Result<(), PinLibraryError> {
        let url = self.tag_url.clone().unwrap_or_default();
        let lock_error = |source| PinLibraryError::Lock {
            url: url.clone(),
            repo: self.repo.clone(),
            tag: format!("v{}", self.version.release()),
            source: Box::new(source),
        };
        let mut cmd = command(Tool::Nix).map_err(lock_error)?;
        cmd.args([
            "flake",
            "lock",
            "--extra-experimental-features",
            "nix-command flakes",
        ]);
        if let Some(url) = tag_url {
            cmd.arg("--override-input").arg(&self.input).arg(url);
        }
        cmd.current_dir(&self.dir);
        output(&mut cmd).map(|_| ()).map_err(lock_error)
    }

    /// Evaluate the library version the project builds with, with
    /// `overrides`, and return it when Kix [`Plan::version`] can build it.
    /// Otherwise return the message that says why not.
    fn check(&self, overrides: &[(String, String)]) -> Result<Version, String> {
        let kix = self.version.release();
        let tag = format!("v{kix}");
        let alone = self.follows.left_alone(&self.input);
        let opening = match &alone {
            Some(alone) => format!("{alone} "),
            None => String::new(),
        };
        let found = match try_eval_version(&self.dir, overrides) {
            Ok(LibraryVersion::Known(v)) => v,
            Ok(LibraryVersion::Older) => {
                return Err(format!(
                    "{opening}The project builds with a Kix library older than 0.8, which Kix {kix} cannot build."
                ));
            }
            Ok(LibraryVersion::Unknown) => {
                return Err(format!(
                    "{opening}Kix could not read the version of the project's Kix library."
                ));
            }
            Err(e) => {
                let detail = e.stderr.trim();
                let last = detail
                    .lines()
                    .rev()
                    .find(|l| l.trim_start().starts_with("error:"))
                    .unwrap_or(detail)
                    .trim();
                return Err(format!(
                    "{opening}Kix could not read the version of the project's Kix library: {last}"
                ));
            }
        };
        let library: Version = found.parse().map_err(|_| {
            format!("{opening}The project's Kix library names the version {found}, which Kix cannot read.")
        })?;
        let reason = match policy::library_compatible(&self.version, &library) {
            Ok(()) => return Ok(library),
            Err(Incompatible::LibraryNewerMinor | Incompatible::LibraryNewerPatch) => {
                format!("which is newer than Kix {kix}")
            }
            Err(Incompatible::LibraryOlderMinor) => format!("which Kix {kix} cannot build"),
        };
        let lib = library.release();
        if alone.is_some() {
            return Err(format!(
                "{opening}It holds the Kix library {lib}, {reason}. Point the input at the tag {tag}, or at a branch that holds the Kix library {kix}."
            ));
        }
        let moved = if overrides.is_empty() {
            format!("Kix moved the input {} to {tag}", self.input)
        } else {
            format!("With the input {} on {tag}", self.input)
        };
        let hint = if self.follows_lines.is_empty() {
            format!(
                "Check that the tag {tag} of {} holds the Kix library {kix}.",
                self.repo
            )
        } else {
            format!(
                "Another input brings its own Kix library. Add {} to flake.nix.",
                self.follows_lines
                    .iter()
                    .map(|l| format!("`{l}`"))
                    .collect::<Vec<_>>()
                    .join(" and ")
            )
        };
        Err(format!(
            "{moved}, but the project builds with the Kix library {lib}, {reason}. {hint}"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn v(text: &str) -> Version {
        text.parse().unwrap()
    }

    fn lock_with(original: Value, locked: Value) -> Value {
        json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "kix": "kix", "nixpkgs": "nixpkgs" } },
                "kix": { "original": original, "locked": locked },
                "nixpkgs": {
                    "original": { "type": "github", "owner": "NixOS", "repo": "nixpkgs" },
                    "locked": { "type": "github", "owner": "NixOS", "repo": "nixpkgs", "rev": "n" }
                }
            }
        })
    }

    fn github(r: Option<&str>) -> Value {
        let mut o = json!({ "type": "github", "owner": "kix-run", "repo": "kix" });
        if let Some(r) = r {
            o["ref"] = json!(r);
        }
        o
    }

    fn locked_github() -> Value {
        json!({ "type": "github", "owner": "kix-run", "repo": "kix", "rev": "0123456789abcdef" })
    }

    fn plan_for(locks: &Value, flake: &str) -> Result<Plan, PinLibraryError> {
        decide(Path::new("/p"), locks, flake, &v("0.10.0"), None)
    }

    #[test]
    fn no_ref_locks_the_tag_and_leaves_flake_nix() {
        let plan = plan_for(
            &lock_with(github(None), locked_github()),
            "inputs.kix.url = \"github:kix-run/kix\";",
        )
        .unwrap();
        assert_eq!(plan.follows, Follows::NoRef);
        assert_eq!(plan.tag_url.as_deref(), Some("github:kix-run/kix/v0.10.0"));
        assert_eq!(plan.new_flake, None);
        assert_eq!(plan.before, "0123456");

        // A Git input records the tag it was locked to.
        let git = json!({ "type": "git", "url": "https://git.example/org/kix.git" });
        let mut locked = git.clone();
        locked["ref"] = json!("refs/tags/v0.9.1");
        locked["rev"] = json!("abcdef0123");
        let plan = plan_for(&lock_with(git, locked), "").unwrap();
        assert_eq!(plan.before, "v0.9.1");
        assert_eq!(
            plan.tag_url.as_deref(),
            Some("git+https://git.example/org/kix.git?ref=refs/tags/v0.10.0")
        );
    }

    #[test]
    fn a_version_tag_is_changed_in_flake_nix() {
        let flake = "{\n  inputs.kix.url = \"github:kix-run/kix/v0.9.1\";\n  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/v0.9.1\";\n}\n";
        let plan = plan_for(&lock_with(github(Some("v0.9.1")), locked_github()), flake).unwrap();
        assert_eq!(plan.follows, Follows::Tag("v0.9.1".into()));
        assert_eq!(plan.before, "v0.9.1");
        assert_eq!(
            plan.new_flake.as_deref(),
            Some(
                "{\n  inputs.kix.url = \"github:kix-run/kix/v0.10.0\";\n  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/v0.9.1\";\n}\n"
            )
        );

        // flake.nix already names the target, so only the lock moves.
        let plan = plan_for(
            &lock_with(github(Some("v0.10.0")), locked_github()),
            "inputs.kix.url = \"github:kix-run/kix/v0.10.0\";",
        )
        .unwrap();
        assert_eq!(plan.new_flake, None);
        assert!(plan.follows.moves());
    }

    #[test]
    fn a_tag_in_two_urls_is_left_to_a_person() {
        let url = "git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1";
        let flake = format!(
            "inputs = {{\n  kix = {{\n    url = \"{url}\";\n  }};\n  image-kix = {{\n    url = \"{url}\";\n  }};\n}};\n"
        );
        let original = json!({
            "type": "git",
            "url": "ssh://git@git.example:30232/org/kixpkgs.git",
            "ref": "refs/tags/v0.8.0-rc.1"
        });
        let Err(PinLibraryError::Edit(edit)) =
            plan_for(&lock_with(original.clone(), original), &flake)
        else {
            panic!("expected Kix to leave the edit to a person");
        };
        assert_eq!(edit.from_tag, "v0.8.0-rc.1");
        assert_eq!(edit.to_tag, "v0.10.0");
        let numbers: Vec<usize> = edit.lines.iter().map(|(n, _)| *n).collect();
        assert_eq!(numbers, [3, 6]);
    }

    #[test]
    fn a_tag_kix_cannot_find_in_flake_nix_is_left_to_a_person() {
        // The input is written as an attribute set, and a comment names
        // the tag.
        let flake = "inputs.kix = { type = \"github\"; owner = \"kix-run\"; repo = \"kix\"; ref = \"v0.9.1\"; };\n# url = \"github:kix-run/kix/v0.9.1\";\n";
        let err = plan_for(&lock_with(github(Some("v0.9.1")), locked_github()), flake)
            .unwrap_err()
            .to_string();
        assert_eq!(
            err,
            "Kix could not find the tag v0.9.1 of the input kix in flake.nix, so it changed nothing. Change that tag to v0.10.0 in flake.nix."
        );
    }

    #[test]
    fn retag_changes_only_the_exact_tag_of_the_input() {
        let original =
            json!({ "type": "git", "url": "ssh://git@git.example:30232/org/kixpkgs.git" });
        let mirror =
            "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=v0.9.1&shallow=1\";";
        assert_eq!(
            retag_flake(mirror, &original, "v0.9.1", "v0.10.0").unwrap(),
            "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=v0.10.0&shallow=1\";"
        );
        // A shorter or longer prerelease, and another repository.
        for from in ["v0.9", "v0.9.1-rc", "v0.9.10"] {
            assert_eq!(
                retag_flake(mirror, &original, from, "v0.10.0"),
                Err(Retag::NotFound),
                "{from}"
            );
        }
        let other = json!({ "type": "git", "url": "ssh://git@git.example:30232/org/other.git" });
        assert_eq!(
            retag_flake(mirror, &other, "v0.9.1", "v0.10.0"),
            Err(Retag::NotFound)
        );
    }

    #[test]
    fn a_branch_a_commit_and_a_folder_are_left_alone() {
        for (original, follows, sentence) in [
            (
                github(Some("main")),
                Follows::Branch("main".into()),
                "The input kix follows the branch main, so Kix leaves it alone.",
            ),
            (
                json!({ "type": "github", "owner": "kix-run", "repo": "kix", "rev": "0123456789abcdef" }),
                Follows::Commit("0123456".into()),
                "The input kix follows the commit 0123456, so Kix leaves it alone.",
            ),
            (
                json!({ "type": "path", "path": "../kix" }),
                Follows::LocalPath("../kix".into()),
                "The input kix is the local folder ../kix, so Kix leaves it alone.",
            ),
        ] {
            let plan = plan_for(&lock_with(original, locked_github()), "").unwrap();
            assert_eq!(plan.follows, follows);
            assert_eq!(plan.tag_url, None);
            assert_eq!(plan.new_flake, None);
            assert_eq!(plan.follows.left_alone("kix").as_deref(), Some(sentence));
        }
    }

    #[test]
    fn a_mirror_or_a_fork_is_the_library_by_name() {
        let fork = json!({ "type": "github", "owner": "someone", "repo": "kix-fork" });
        let plan = plan_for(&lock_with(fork, locked_github()), "").unwrap();
        assert_eq!(
            plan.tag_url.as_deref(),
            Some("github:someone/kix-fork/v0.10.0")
        );
        let enterprise =
            json!({ "type": "github", "owner": "org", "repo": "kix", "host": "github.example" });
        let plan = plan_for(&lock_with(enterprise, locked_github()), "").unwrap();
        assert_eq!(
            plan.tag_url.as_deref(),
            Some("github:org/kix/v0.10.0?host=github.example")
        );
        let tarball = json!({ "type": "tarball", "url": "https://example.com/kix.tar.gz" });
        let err = plan_for(&lock_with(tarball, locked_github()), "").unwrap_err();
        assert!(matches!(err, PinLibraryError::Unsupported { .. }), "{err}");
    }

    #[test]
    fn the_input_is_found_by_name_or_by_the_setting() {
        let mut locks = lock_with(github(None), locked_github());
        locks["nodes"]["root"]["inputs"] = json!({ "kixpkgs": "kix" });
        assert_eq!(plan_for(&locks, "").unwrap().input, "kixpkgs");

        locks["nodes"]["root"]["inputs"] = json!({ "kixpkgs": "kix", "kix": "kix" });
        assert!(matches!(
            plan_for(&locks, ""),
            Err(PinLibraryError::BothNames)
        ));
        let plan = decide(Path::new("/p"), &locks, "", &v("0.10.0"), Some("kixpkgs")).unwrap();
        assert_eq!(plan.input, "kixpkgs");

        locks["nodes"]["root"]["inputs"] = json!({ "platform-lib": "kix" });
        assert!(matches!(
            plan_for(&locks, ""),
            Err(PinLibraryError::NotFound)
        ));
        let err = decide(Path::new("/p"), &locks, "", &v("0.10.0"), Some("lib")).unwrap_err();
        assert!(
            matches!(err, PinLibraryError::SettingNotFound(ref n) if n == "lib"),
            "{err}"
        );
        let plan = decide(
            Path::new("/p"),
            &locks,
            "",
            &v("0.10.0"),
            Some("platform-lib"),
        )
        .unwrap();
        assert_eq!(plan.input, "platform-lib");
    }

    fn platform(root_inputs: Value) -> Value {
        json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": root_inputs },
                "platform": {
                    "inputs": { "kix": "kix_2" },
                    "original": { "type": "github", "owner": "acme", "repo": "platform" },
                    "locked": { "type": "github", "owner": "acme", "repo": "platform", "rev": "p" }
                },
                "kix_2": { "original": github(Some("v0.9.1")), "locked": locked_github() },
                "kix": { "original": github(None), "locked": locked_github() }
            }
        })
    }

    #[test]
    fn a_library_inside_another_input_gets_a_message() {
        let err = plan_for(&platform(json!({ "platform": "platform" })), "")
            .unwrap_err()
            .to_string();
        assert_eq!(
            err,
            "The Kix library comes from the input platform, through its own input kix. Kix moves only an input that flake.nix declares itself. Add these lines to flake.nix:\n  inputs.kix.url = \"github:kix-run/kix/v0.10.0\";\n  inputs.platform.inputs.kix.follows = \"kix\";"
        );

        let err = plan_for(
            &platform(json!({ "platform": "platform", "kix": ["platform", "kix"] })),
            "",
        )
        .unwrap_err()
        .to_string();
        assert!(
            err.starts_with(
                "The input kix follows platform/kix, so the Kix library comes from another flake."
            ),
            "{err}"
        );
        assert!(
            err.ends_with("  inputs.kix.url = \"github:kix-run/kix/v0.10.0\";"),
            "{err}"
        );

        // With its own library input as well, the other one is a hint for
        // the version check.
        let plan = plan_for(
            &platform(json!({ "platform": "platform", "kix": "kix" })),
            "",
        )
        .unwrap();
        assert_eq!(
            plan.follows_lines,
            ["inputs.platform.inputs.kix.follows = \"kix\";"]
        );
    }

    fn pinned(follows: Follows, before: &str, changed: Vec<&'static str>, dry_run: bool) -> Pinned {
        Pinned {
            input: "kix".into(),
            follows,
            before: before.into(),
            library: v("0.10.0"),
            changed,
            dry_run,
            version: v("0.10.0"),
        }
    }

    #[test]
    fn the_summary_says_what_kix_did() {
        assert_eq!(
            pinned(Follows::NoRef, "v0.9.1", vec!["flake.lock"], false).summary(),
            "Kix library: v0.9.1 -> 0.10.0."
        );
        assert_eq!(
            pinned(
                Follows::Tag("v0.9.1".into()),
                "v0.9.1",
                vec!["flake.nix", "flake.lock"],
                false
            )
            .summary(),
            "Kix library: v0.9.1 -> 0.10.0. Kix changed the tag in flake.nix."
        );
        assert_eq!(
            pinned(Follows::Tag("v0.9.1".into()), "v0.9.1", vec![], true).summary(),
            "Kix library: v0.9.1 -> 0.10.0. Kix would change the tag in flake.nix. This was a dry run, so Kix changed no files."
        );
        assert_eq!(
            pinned(Follows::NoRef, "v0.10.0", vec![], false).summary(),
            "Kix library is already 0.10.0."
        );
        assert_eq!(
            pinned(Follows::Branch("main".into()), "abc1234", vec![], false).summary(),
            "The input kix follows the branch main, so Kix leaves it alone. It holds the Kix library 0.10.0."
        );
    }
}
