//! Pin a project's Kix library to the release tag of a version of Kix, and
//! check that the project then builds with that version of the library.
//!
//! The library is the input of the project's own flake named `kix`
//! (`crate::flake_lock`), or another input that the `[versions]` table of
//! `kix.toml` names (`crate::versions`). Kix writes the tag `v<version>`
//! into that input's url in `flake.nix`, replacing any branch, commit, or older tag, and then
//! locks. It reads the input from the lock that `flake.nix` gives now
//! (`nix flake metadata --no-write-lock-file`), so a project with no
//! `flake.lock`, or one that fell behind `flake.nix`, can be pinned too.
//! One evaluation of the library's version then confirms the result.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::eval::nix::{NixCommandError, command, output};
use crate::flake_lock::{INPUT, InputError, bare_ref};
use crate::runtime::Tool;
use crate::version::Version;
use crate::version::policy::LibraryVersion;

/// More than one url in `flake.nix` names the library's repository as the
/// input does, and Kix cannot tell which one is the library input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandEdit {
    /// The url the library input must name, such as
    /// `github:kix-run/kix/v0.10.3`.
    pub to_url: String,
    /// Each line that names the repository: its number and its text.
    pub lines: Vec<(usize, String)>,
}

/// Why Kix did not pin the library, or pinned it and found the wrong
/// version. Each message says what to change. Kix changed no file, or put
/// back the files it changed.
#[derive(Debug, thiserror::Error)]
pub enum PinLibraryError {
    #[error("Kix could not read the inputs of flake.nix: {0}")]
    Read(Box<NixCommandError>),

    #[error("{}.", .error.change_of(input, version))]
    Input {
        error: InputError,
        input: String,
        version: String,
    },

    #[error(
        "The input {input} is the local folder {path}, which has no versions. Point the input at the tag {tag}, such as github:kix-run/kix/{tag}."
    )]
    Folder {
        input: String,
        path: String,
        tag: String,
    },

    #[error(
        "The input {input} reads the Kix library from {url}, and Kix can pin only a Git repository or a GitHub, GitLab, or SourceHut repository to a release tag. Point the input at the tag {tag}, such as github:kix-run/kix/{tag}."
    )]
    Unsupported {
        input: String,
        url: String,
        tag: String,
    },

    #[error(
        "Kix could not find the url of the input {input} in flake.nix, so it changed nothing. Change that url to {to_url} in flake.nix."
    )]
    UrlNotFound { input: String, to_url: String },

    #[error(
        "Kix cannot tell which url in flake.nix is the Kix library input, because more than one names its repository:\n{}\nChange the url of the Kix library input to {} in flake.nix, and leave the other inputs as they are.",
        .0.lines.iter().map(|(n, l)| format!("  flake.nix:{n}:   {l}")).collect::<Vec<_>>().join("\n"),
        .0.to_url
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

/// What Kix will do to pin the library input, worked out before it changes
/// anything.
#[derive(Debug, Clone)]
pub struct Plan {
    dir: PathBuf,
    /// The input Kix pins.
    input: String,
    /// The version of Kix the library must match.
    pub version: Version,
    /// The release tag's url.
    tag_url: String,
    /// The repository the input reads, as a person would write it.
    repo: String,
    /// `flake.nix` with the input on the tag, when it must change.
    new_flake: Option<String>,
}

/// Work out how to pin the Kix library input `input` of the project in
/// `dir` to the release tag of Kix `version`, without changing anything.
pub fn plan(dir: &Path, input: &str, version: &Version) -> Result<Plan, PinLibraryError> {
    let locks = read_locks(dir)?;
    let flake_path = dir.join("flake.nix");
    let flake = std::fs::read_to_string(&flake_path).map_err(|source| PinLibraryError::Io {
        action: "read",
        path: flake_path,
        source,
    })?;
    decide(dir, &locks, &flake, input, version)
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

/// Work out the [`Plan`] from `locks`, the lock that `flake.nix` gives now,
/// and `flake`, the text of `flake.nix`.
fn decide(
    dir: &Path,
    locks: &Value,
    flake: &str,
    input: &str,
    version: &Version,
) -> Result<Plan, PinLibraryError> {
    let tag = format!("v{}", version.release());
    let original =
        crate::flake_lock::input(locks, input).map_err(|error| PinLibraryError::Input {
            error,
            input: input.to_string(),
            version: version.release(),
        })?;
    let s = |k: &str| original[k].as_str();
    let repo = repo_url(original);
    match s("type") {
        Some("path") => {
            return Err(PinLibraryError::Folder {
                input: input.to_string(),
                path: s("path").unwrap_or_default().to_string(),
                tag,
            });
        }
        Some("github" | "gitlab" | "sourcehut" | "git") => {}
        _ => {
            return Err(PinLibraryError::Unsupported {
                input: input.to_string(),
                url: repo,
                tag,
            });
        }
    }
    let tag_url = tagged_url(original, &tag);
    let new_flake = if s("ref").map(bare_ref) == Some(tag.as_str()) {
        None
    } else {
        Some(
            retag_flake(flake, input, original, &tag, &format!("refs/tags/{tag}")).map_err(
                |e| match e {
                    Retag::NotFound => PinLibraryError::UrlNotFound {
                        input: input.to_string(),
                        to_url: tag_url.clone(),
                    },
                    Retag::Many(lines) => PinLibraryError::Edit(HandEdit {
                        to_url: tag_url.clone(),
                        lines,
                    }),
                },
            )?,
        )
    };
    Ok(Plan {
        dir: dir.to_path_buf(),
        input: input.to_string(),
        version: version.clone(),
        tag_url,
        repo,
        new_flake,
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
    /// No url of the input's repository pins what the input pins.
    NotFound,
    /// More than one does: the number and text of each line.
    Many(Vec<(usize, String)>),
}

/// Return whether `at` lies on a line that is a comment.
fn in_comment(text: &str, at: usize) -> bool {
    let line_start = text[..at].rfind('\n').map_or(0, |n| n + 1);
    text[line_start..at].trim_start().starts_with('#')
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

/// A flake url split into the part before `?` and its query parameters.
struct Url<'a> {
    base: &'a str,
    params: Vec<(&'a str, &'a str)>,
}

impl<'a> Url<'a> {
    fn parse(url: &'a str) -> Self {
        let (base, query) = url.split_once('?').unwrap_or((url, ""));
        let params = query
            .split('&')
            .filter(|p| !p.is_empty())
            .map(|p| p.split_once('=').unwrap_or((p, "")))
            .collect();
        Url { base, params }
    }

    fn param(&self, name: &str) -> Option<&'a str> {
        self.params
            .iter()
            .find(|(k, _)| *k == name)
            .map(|(_, v)| *v)
    }

    /// Return the url with `params`, leaving out `ref` and `rev`.
    fn join(&self, base: &str, extra: Option<(&str, &str)>) -> String {
        let mut params: Vec<String> = self
            .params
            .iter()
            .filter(|(k, _)| !matches!(*k, "ref" | "rev"))
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        if let Some((k, v)) = extra {
            params.push(format!("{k}={v}"));
        }
        if params.is_empty() {
            base.to_string()
        } else {
            format!("{base}?{}", params.join("&"))
        }
    }
}

/// Return what `original` pins as `flake.nix` writes it: a ref without
/// `refs/tags/` or `refs/heads/`, a commit, or `None`.
fn pin_of_original(original: &Value) -> Option<String> {
    let s = |k: &str| original[k].as_str();
    s("ref")
        .or_else(|| s("rev"))
        .map(|p| bare_ref(p).to_string())
}

/// A url in `flake.nix` that names the repository of the library input.
struct RepoUrl {
    /// What the url pins: a ref without `refs/tags/` or `refs/heads/`, a
    /// commit, or `None`.
    pin: Option<String>,
    /// The url without a ref, ready for a new one.
    forge_base: Option<String>,
}

/// Return what `literal`, a url in `flake.nix`, pins when it names the
/// repository of `original`.
fn repo_url_of(literal: &str, original: &Value) -> Option<RepoUrl> {
    if !literal
        .to_ascii_lowercase()
        .contains(&repo_needle(original))
    {
        return None;
    }
    let url = Url::parse(literal);
    let forge = ["github:", "gitlab:", "sourcehut:"]
        .iter()
        .any(|p| url.base.starts_with(p));
    let param_pin = || {
        url.param("ref")
            .or_else(|| url.param("rev"))
            .map(|p| bare_ref(p).to_string())
    };
    if forge {
        let (scheme, path) = url.base.split_once(':')?;
        let parts: Vec<&str> = path.split('/').collect();
        let (owner_repo, pin) = match parts.as_slice() {
            [owner, repo] => (format!("{owner}/{repo}"), None),
            [owner, repo, pin] => (format!("{owner}/{repo}"), Some(pin.to_string())),
            _ => return None,
        };
        if owner_repo.to_ascii_lowercase() != repo_needle(original) {
            return None;
        }
        return Some(RepoUrl {
            pin: pin.or_else(param_pin),
            forge_base: Some(format!("{scheme}:{owner_repo}")),
        });
    }
    if !url.base.starts_with("git+") {
        return None;
    }
    Some(RepoUrl {
        pin: param_pin(),
        forge_base: None,
    })
}

/// Return `literal`, a url in `flake.nix`, moved to the tag `tag`, when it
/// names the repository of `original` and pins what `original` pins. A Git
/// url gets `git_ref` as its `ref`.
fn retarget(literal: &str, original: &Value, tag: &str, git_ref: &str) -> Option<String> {
    let found = repo_url_of(literal, original)?;
    if found.pin != pin_of_original(original) {
        return None;
    }
    let url = Url::parse(literal);
    Some(match found.forge_base {
        Some(base) => url.join(&format!("{base}/{tag}"), None),
        None => url.join(url.base, Some(("ref", git_ref))),
    })
}

/// Return each string literal of `flake` outside a comment, with where it
/// starts and ends.
fn literals(flake: &str) -> Vec<(usize, usize, &str)> {
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(open) = flake[at..].find('"').map(|i| at + i) {
        let Some(close) = flake[open + 1..].find('"').map(|i| open + 1 + i) else {
            break;
        };
        if !in_comment(flake, open) {
            found.push((open + 1, close, &flake[open + 1..close]));
        }
        at = close + 1;
    }
    found
}

/// Return the name of the input that the url literal starting at `start`
/// in `flake`, a `flake.nix`, belongs to, or `None` when Kix cannot tell.
///
/// Kix reads no Nix syntax. It knows the two usual ways to write an input:
/// `inputs.<name>.url = "..."`, and `url = "..."` inside `<name> = { ... }`.
fn owner_of(flake: &str, start: usize) -> Option<String> {
    /// Split `text` into what comes before its last attribute path and the
    /// parts of that path, when `text` ends with `<path> =`.
    fn assigned(text: &str) -> Option<(&str, Vec<&str>)> {
        let before = text.trim_end().strip_suffix('=')?.trim_end();
        let path_start = before
            .rfind(|c: char| !(c.is_ascii_alphanumeric() || "_-.'".contains(c)))
            .map_or(0, |i| i + 1);
        let parts: Vec<&str> = before[path_start..]
            .split('.')
            .filter(|p| !p.is_empty() && *p != "inputs")
            .collect();
        Some((&before[..path_start], parts))
    }
    let (before, parts) = assigned(flake.get(..start.checked_sub(1)?)?)?;
    match parts.as_slice() {
        [name, "url"] => Some(name.to_string()),
        ["url"] => {
            // Find the brace that opens the set this `url` is in.
            let mut depth = 0;
            let open = before.char_indices().rev().find(|(_, c)| {
                match c {
                    '}' => depth += 1,
                    '{' if depth == 0 => return true,
                    '{' => depth -= 1,
                    _ => {}
                }
                false
            })?;
            let (_, parts) = assigned(&before[..open.0])?;
            parts.last().map(|name| name.to_string())
        }
        _ => None,
    }
}

/// Return whether `flake`, a `flake.nix`, assigns a url to the input
/// `input`.
pub fn names_input(flake: &str, input: &str) -> bool {
    literals(flake)
        .into_iter()
        .any(|(start, _, _)| owner_of(flake, start).as_deref() == Some(input))
}

/// Return each url literal of `flake` that may be the url of the input
/// `input`: every literal but the ones that belong to another input.
fn urls_of<'a>(flake: &'a str, input: &str) -> Vec<(usize, usize, &'a str)> {
    literals(flake)
        .into_iter()
        .filter(|(start, _, _)| owner_of(flake, *start).is_none_or(|owner| owner == input))
        .collect()
}

/// Return the release that `flake`, a `flake.nix`, now asks for the input
/// `input`, when it differs from what the lock's `original` of that input
/// pins.
///
/// Kix finds the input's url as [`retag_flake`] does. It returns `None`
/// when a url still pins what the lock pins, or when the urls of the
/// repository do not agree on one release tag, and leaves those cases to
/// the check after evaluation.
pub fn declared_tag(flake: &str, input: &str, original: &Value) -> Option<Version> {
    let pins: Vec<Option<String>> = urls_of(flake, input)
        .into_iter()
        .filter_map(|(_, _, l)| repo_url_of(l, original))
        .map(|u| u.pin)
        .collect();
    let locked = pin_of_original(original);
    if pins.is_empty() || pins.contains(&locked) {
        return None;
    }
    let mut tags = pins
        .iter()
        .map(|p| p.as_deref().and_then(crate::flake_lock::release_tag));
    let first = tags.next()??;
    tags.all(|t| t.as_ref() == Some(&first)).then_some(first)
}

/// Set the url of the input `input` in the `flake.nix` of `dir` back to the
/// tag its `flake.lock` pins, after a person moved it by hand. Return the
/// version flake.nix asked for, or `None` when it already matches.
pub fn reset_moved_tag(dir: &Path, input: &str) -> Result<Option<Version>, PinLibraryError> {
    let read = |path: PathBuf| {
        std::fs::read_to_string(&path).map_err(|source| PinLibraryError::Io {
            action: "read",
            path,
            source,
        })
    };
    let lock: Value = serde_json::from_str(&read(dir.join(crate::flake_lock::FILE))?)
        .map_err(|e| PinLibraryError::Check(format!("Kix could not read flake.lock: {e}")))?;
    let Ok(original) = crate::flake_lock::input(&lock, input) else {
        return Ok(None);
    };
    let flake_path = dir.join("flake.nix");
    let flake = read(flake_path.clone())?;
    let Some(asked) = declared_tag(&flake, input, original) else {
        return Ok(None);
    };
    let Some(locked) = pin_of_original(original) else {
        return Ok(None);
    };
    // Find the url that now pins the moved tag, and move it back. A Git url
    // gets the ref exactly as the lock records it, so Nix sees the input
    // unchanged and keeps the lock.
    let mut moved = original.clone();
    moved["ref"] = Value::String(format!("v{}", asked.release()));
    let git_ref = original["ref"]
        .as_str()
        .map_or_else(|| format!("refs/tags/{locked}"), str::to_string);
    let text = retag_flake(&flake, input, &moved, &locked, &git_ref).map_err(|_| {
        PinLibraryError::UrlNotFound {
            input: input.to_string(),
            to_url: tagged_url(original, &locked),
        }
    })?;
    std::fs::write(&flake_path, text).map_err(|source| PinLibraryError::Io {
        action: "write",
        path: flake_path,
        source,
    })?;
    Ok(Some(asked))
}

/// Return `flake`, a `flake.nix`, with the url of the input `input` moved
/// to the tag `tag`. A Git url gets `git_ref` as its `ref`.
///
/// Kix reads no Nix syntax to do this. It leaves out each url that belongs
/// to another input ([`owner_of`]), and changes a url only when exactly one
/// of the rest names the repository of `original` and pins what it pins. A
/// project can pin a second input to the same url, such as a second version
/// of Kix, and that input must stay. Comment lines are skipped.
fn retag_flake(
    flake: &str,
    input: &str,
    original: &Value,
    tag: &str,
    git_ref: &str,
) -> Result<String, Retag> {
    let found: Vec<(usize, usize, String)> = urls_of(flake, input)
        .into_iter()
        .filter_map(|(start, end, l)| Some((start, end, retarget(l, original, tag, git_ref)?)))
        .collect();
    match found.as_slice() {
        [] => Err(Retag::NotFound),
        [(start, end, new)] => Ok(format!("{}{new}{}", &flake[..*start], &flake[*end..])),
        many => Err(Retag::Many(
            many.iter()
                .map(|(start, _, _)| {
                    let number = flake[..*start].matches('\n').count() + 1;
                    let line = flake.lines().nth(number - 1).unwrap_or_default();
                    (number, line.trim().to_string())
                })
                .collect(),
        )),
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
    /// Pin the library input as planned, then evaluate the library version
    /// the project builds with and check it against [`Plan::version`]. When
    /// the check fails, put `flake.nix` and `flake.lock` back. Return the
    /// files Kix changed, `flake.nix` before `flake.lock`.
    pub fn apply(&self) -> Result<Vec<&'static str>, PinLibraryError> {
        let flake = Saved::take(self.dir.join("flake.nix"))?;
        let lock = Saved::take(self.dir.join(crate::flake_lock::FILE))?;
        if let Some(text) = &self.new_flake {
            std::fs::write(&flake.0, text).map_err(|source| PinLibraryError::Io {
                action: "write",
                path: flake.0.clone(),
                source,
            })?;
        }
        if let Err(e) = self.lock() {
            flake.restore();
            lock.restore();
            return Err(e);
        }
        let changed: Vec<&'static str> = [(&flake, "flake.nix"), (&lock, "flake.lock")]
            .into_iter()
            .filter(|(saved, _)| saved.changed())
            .map(|(_, name)| name)
            .collect();
        if let Err(message) = self.check() {
            let restored = if changed.is_empty() {
                ""
            } else {
                flake.restore();
                lock.restore();
                " Kix put flake.nix and flake.lock back."
            };
            return Err(PinLibraryError::Check(format!("{message}{restored}")));
        }
        Ok(changed)
    }

    /// Run `nix flake lock`, which locks the input to the tag `flake.nix`
    /// now names, and writes `flake.lock` when the project has none.
    fn lock(&self) -> Result<(), PinLibraryError> {
        let lock_error = |source| PinLibraryError::Lock {
            url: self.tag_url.clone(),
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
        ])
        .current_dir(&self.dir);
        output(&mut cmd).map(|_| ()).map_err(lock_error)
    }

    /// Evaluate the library version the project builds with, and return the
    /// message that says why it is not [`Plan::version`].
    fn check(&self) -> Result<(), String> {
        let kix = self.version.release();
        let tag = format!("v{kix}");
        // The outputs of flake.nix read only the input `kix`, so the library
        // of another input is read with that input in its place.
        let overrides = match self.input.as_str() {
            INPUT => Vec::new(),
            other => {
                let swap = crate::flake_lock::read(&self.dir)
                    .ok()
                    .and_then(|lock| crate::versions::locked_ref(&lock, other))
                    .ok_or_else(|| {
                        format!("Kix could not read what flake.lock pins for the input {other}.")
                    })?;
                vec![(INPUT.to_string(), swap)]
            }
        };
        let found = match crate::eval::nix::library_version(&self.dir, &overrides) {
            Ok(LibraryVersion::Known(v)) => v,
            Ok(LibraryVersion::Older) => {
                return Err(format!(
                    "The tag {tag} of {} holds a Kix library older than 0.8, which publishes no version.",
                    self.repo
                ));
            }
            Ok(LibraryVersion::Unknown) => {
                return Err("Kix could not read the version of the project's Kix library.".into());
            }
            Err(crate::eval::error::KixEvalError::Nix(e)) => {
                let detail = e.stderr.trim();
                let last = detail
                    .lines()
                    .rev()
                    .find(|l| l.trim_start().starts_with("error:"))
                    .unwrap_or(detail)
                    .trim();
                return Err(format!(
                    "Kix could not read the version of the project's Kix library: {last}"
                ));
            }
            Err(e) => {
                return Err(format!(
                    "Kix could not read the version of the project's Kix library: {e}"
                ));
            }
        };
        if found == self.version {
            return Ok(());
        }
        Err(format!(
            "Kix moved the input {} to {tag}, but the project builds with the Kix library {}. Check that the tag {tag} of {} holds the Kix library {kix}.",
            self.input,
            found.release(),
            self.repo
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

    fn lock_with(original: Value) -> Value {
        json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "kix": "kix", "nixpkgs": "nixpkgs" } },
                "kix": { "original": original, "locked": {} },
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

    fn plan_for(locks: &Value, flake: &str) -> Result<Plan, PinLibraryError> {
        decide(Path::new("/p"), locks, flake, INPUT, &v("0.10.0"))
    }

    fn new_flake(original: Value, flake: &str) -> String {
        plan_for(&lock_with(original), flake)
            .unwrap()
            .new_flake
            .unwrap()
    }

    #[test]
    fn an_input_without_a_ref_gets_the_tag() {
        assert_eq!(
            new_flake(github(None), "inputs.kix.url = \"github:kix-run/kix\";"),
            "inputs.kix.url = \"github:kix-run/kix/v0.10.0\";"
        );
        let git = json!({ "type": "git", "url": "https://git.example/org/kix.git" });
        assert_eq!(
            new_flake(
                git,
                "kix.url = \"git+https://git.example/org/kix.git?shallow=1\";"
            ),
            "kix.url = \"git+https://git.example/org/kix.git?shallow=1&ref=refs/tags/v0.10.0\";"
        );
        let enterprise =
            json!({ "type": "github", "owner": "org", "repo": "kix", "host": "github.example" });
        assert_eq!(
            new_flake(
                enterprise,
                "kix.url = \"github:org/kix?host=github.example\";"
            ),
            "kix.url = \"github:org/kix/v0.10.0?host=github.example\";"
        );
    }

    #[test]
    fn a_tag_a_branch_or_a_commit_is_replaced() {
        let flake = "{\n  inputs.kix.url = \"github:kix-run/kix/v0.9.1\";\n  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/v0.9.1\";\n}\n";
        assert_eq!(
            new_flake(github(Some("v0.9.1")), flake),
            "{\n  inputs.kix.url = \"github:kix-run/kix/v0.10.0\";\n  inputs.nixpkgs.url = \"github:NixOS/nixpkgs/v0.9.1\";\n}\n"
        );
        assert_eq!(
            new_flake(
                github(Some("main")),
                "kix.url = \"github:kix-run/kix/main\";"
            ),
            "kix.url = \"github:kix-run/kix/v0.10.0\";"
        );
        let commit = json!({ "type": "git", "url": "file:///src/kix", "rev": "0123456789abcdef" });
        assert_eq!(
            new_flake(
                commit,
                "kix.url = \"git+file:///src/kix?rev=0123456789abcdef&dir=kix\";"
            ),
            "kix.url = \"git+file:///src/kix?dir=kix&ref=refs/tags/v0.10.0\";"
        );
        let mirror = json!({ "type": "git", "url": "ssh://git@git.example:30232/org/kix.git", "ref": "v0.9.1" });
        assert_eq!(
            new_flake(
                mirror,
                "url = \"git+ssh://git@git.example:30232/org/kix.git?ref=v0.9.1&shallow=1\";"
            ),
            "url = \"git+ssh://git@git.example:30232/org/kix.git?shallow=1&ref=refs/tags/v0.10.0\";"
        );
    }

    #[test]
    fn the_tag_already_in_flake_nix_needs_only_a_lock() {
        let plan = plan_for(
            &lock_with(github(Some("v0.10.0"))),
            "inputs.kix.url = \"github:kix-run/kix/v0.10.0\";",
        )
        .unwrap();
        assert_eq!(plan.new_flake, None);
        assert_eq!(plan.tag_url, "github:kix-run/kix/v0.10.0");
    }

    #[test]
    fn a_second_input_on_the_same_url_stays() {
        let url = "git+ssh://git@git.example:30232/org/kix.git?ref=refs/tags/v0.8.0-rc.1";
        let flake = format!(
            "inputs = {{\n  kix = {{\n    url = \"{url}\";\n  }};\n  image-kix = {{\n    url = \"{url}\";\n  }};\n}};\n"
        );
        let original = json!({
            "type": "git",
            "url": "ssh://git@git.example:30232/org/kix.git",
            "ref": "refs/tags/v0.8.0-rc.1"
        });
        let plan = plan_for(&lock_with(original), &flake).unwrap();
        let text = plan.new_flake.unwrap();
        assert_eq!(text.matches("refs/tags/v0.10.0").count(), 1, "{text}");
        assert!(
            text.find("refs/tags/v0.10.0") < text.find("image-kix"),
            "{text}"
        );
    }

    #[test]
    fn two_urls_kix_cannot_tell_apart_are_left_to_a_person() {
        let url = "git+ssh://git@git.example:30232/org/kix.git?ref=refs/tags/v0.8.0-rc.1";
        let flake = format!(
            "let\n  library = \"{url}\";\n  image = \"{url}\";\nin {{\n  inputs.kix.url = library;\n}}\n"
        );
        let original = json!({
            "type": "git",
            "url": "ssh://git@git.example:30232/org/kix.git",
            "ref": "refs/tags/v0.8.0-rc.1"
        });
        let Err(PinLibraryError::Edit(edit)) = plan_for(&lock_with(original), &flake) else {
            panic!("expected Kix to leave the edit to a person");
        };
        assert_eq!(
            edit.to_url,
            "git+ssh://git@git.example:30232/org/kix.git?ref=refs/tags/v0.10.0"
        );
        let numbers: Vec<usize> = edit.lines.iter().map(|(n, _)| *n).collect();
        assert_eq!(numbers, [2, 3]);
    }

    #[test]
    fn a_url_kix_cannot_find_is_left_to_a_person() {
        // The input is written as an attribute set, and a comment names
        // the url.
        let flake = "inputs.kix = { type = \"github\"; owner = \"kix-run\"; repo = \"kix\"; ref = \"v0.9.1\"; };\n# url = \"github:kix-run/kix/v0.9.1\";\n";
        let err = plan_for(&lock_with(github(Some("v0.9.1"))), flake)
            .unwrap_err()
            .to_string();
        assert_eq!(
            err,
            "Kix could not find the url of the input kix in flake.nix, so it changed nothing. Change that url to github:kix-run/kix/v0.10.0 in flake.nix."
        );
        // Another pin of the same repository is not the input.
        for other in [
            "github:kix-run/kix/v0.9",
            "github:kix-run/kix/v0.9.10",
            "github:kix-run/kix-fork/v0.9.1",
        ] {
            let flake = format!("kix.url = \"{other}\";");
            assert!(
                matches!(
                    plan_for(&lock_with(github(Some("v0.9.1"))), &flake),
                    Err(PinLibraryError::UrlNotFound { .. })
                ),
                "{other}"
            );
        }
    }

    #[test]
    fn the_declared_tag_is_found_only_when_no_url_still_pins_the_lock() {
        let locked = github(Some("v0.9.1"));
        let one = |url: &str| format!("inputs.kix.url = \"{url}\";");
        assert_eq!(
            declared_tag(&one("github:kix-run/kix/v0.10.0"), INPUT, &locked),
            Some(v("0.10.0"))
        );
        assert_eq!(
            declared_tag(&one("github:kix-run/kix/v0.9.1"), INPUT, &locked),
            None
        );
        // A second input still on the locked tag, a branch, another
        // repository, and an attribute set are left to the later check.
        let two = format!(
            "{}\n{}",
            one("github:kix-run/kix/v0.10.0"),
            one("github:kix-run/kix/v0.9.1")
        );
        assert_eq!(declared_tag(&two, INPUT, &locked), None);
        assert_eq!(
            declared_tag(&one("github:kix-run/kix/main"), INPUT, &locked),
            None
        );
        assert_eq!(
            declared_tag(&one("github:fork/kix/v0.10.0"), INPUT, &locked),
            None
        );
        assert_eq!(
            declared_tag("inputs.kix = { ref = \"v0.10.0\"; };", INPUT, &locked),
            None
        );
    }

    #[test]
    fn a_moved_tag_goes_back_to_the_url_the_lock_records() {
        let dir = tempfile::tempdir().unwrap();
        let reset = |original: Value, flake: &str| {
            std::fs::write(
                dir.path().join(crate::flake_lock::FILE),
                lock_with(original).to_string(),
            )
            .unwrap();
            std::fs::write(dir.path().join("flake.nix"), flake).unwrap();
            let asked = reset_moved_tag(dir.path(), INPUT).unwrap();
            (
                asked,
                std::fs::read_to_string(dir.path().join("flake.nix")).unwrap(),
            )
        };
        // A Git url keeps the ref as the lock records it, with or without
        // `refs/tags/`.
        for (locked, moved) in [
            ("v0.10.0-rc.3", "v0.10.0-rc.2"),
            ("refs/tags/v0.10.0-rc.3", "refs/tags/v0.10.0-rc.2"),
        ] {
            let original = json!({ "type": "git", "url": "file:///src/kix", "ref": locked });
            assert_eq!(
                reset(
                    original,
                    &format!("kix.url = \"git+file:///src/kix?ref={moved}\";")
                ),
                (
                    Some(v("0.10.0-rc.2")),
                    format!("kix.url = \"git+file:///src/kix?ref={locked}\";")
                )
            );
        }
        assert_eq!(
            reset(
                github(Some("v0.10.0-rc.3")),
                "kix.url = \"github:kix-run/kix/v0.10.0-rc.2\";"
            ),
            (
                Some(v("0.10.0-rc.2")),
                "kix.url = \"github:kix-run/kix/v0.10.0-rc.3\";".to_string()
            )
        );
    }

    #[test]
    fn the_input_must_be_a_direct_input_named_kix_that_kix_can_tag() {
        let mut locks = lock_with(github(None));
        locks["nodes"]["root"]["inputs"] = json!({ "kixpkgs": "kix" });
        assert!(matches!(
            plan_for(&locks, ""),
            Err(PinLibraryError::Input {
                error: InputError::OldName { version: None },
                ..
            })
        ));
        locks["nodes"]["root"]["inputs"] = json!({ "nixpkgs": "nixpkgs" });
        assert_eq!(
            plan_for(&locks, "").unwrap_err().to_string(),
            "flake.nix has no input named kix, so Kix cannot tell which Kix library this project uses. Add `inputs.kix.url = \"github:kix-run/kix/v0.10.0\";` to flake.nix."
        );
        locks["nodes"]["root"]["inputs"] = json!({ "kix": ["platform", "kix"] });
        assert!(matches!(
            plan_for(&locks, ""),
            Err(PinLibraryError::Input {
                error: InputError::Follows(_),
                ..
            })
        ));
        let folder = json!({ "type": "path", "path": "../kix" });
        assert!(matches!(
            plan_for(&lock_with(folder), ""),
            Err(PinLibraryError::Folder { .. })
        ));
        let tarball = json!({ "type": "tarball", "url": "https://example.com/kix.tar.gz" });
        assert!(matches!(
            plan_for(&lock_with(tarball), ""),
            Err(PinLibraryError::Unsupported { .. })
        ));
    }

    #[test]
    fn a_url_belongs_to_the_input_it_is_assigned_to() {
        let owner = |flake: &str| {
            let (start, _, _) = literals(flake)[0];
            owner_of(flake, start)
        };
        assert_eq!(owner("inputs.kix.url = \"u\";"), Some("kix".into()));
        assert_eq!(
            owner("inputs.kix-stable.url    = \"u\";"),
            Some("kix-stable".into())
        );
        assert_eq!(
            owner("inputs = {\n  kix-stable.url = \"u\";\n};"),
            Some("kix-stable".into())
        );
        assert_eq!(
            owner("inputs.kix-stable = {\n  flake = true;\n  url = \"u\";\n};"),
            Some("kix-stable".into())
        );
        assert_eq!(
            owner("inputs = { kix = { inputs = { }; url = \"u\"; }; };"),
            Some("kix".into())
        );
        assert_eq!(owner("let u = \"u\"; in"), None);
        assert_eq!(owner("description = \"u\";"), None);
    }

    #[test]
    fn two_inputs_on_one_tag_are_pinned_one_at_a_time() {
        let flake = "{\n  inputs.kix.url = \"github:kix-run/kix/v0.9.1\";\n  inputs.kix-stable.url = \"github:kix-run/kix/v0.9.1\";\n}";
        let original =
            json!({ "type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.9.1" });
        let kix = retag_flake(flake, "kix", &original, "v0.10.0", "refs/tags/v0.10.0").unwrap();
        assert!(
            kix.contains("inputs.kix.url = \"github:kix-run/kix/v0.10.0\""),
            "{kix}"
        );
        assert!(
            kix.contains("inputs.kix-stable.url = \"github:kix-run/kix/v0.9.1\""),
            "{kix}"
        );
        let stable =
            retag_flake(&kix, "kix-stable", &original, "v0.9.2", "refs/tags/v0.9.2").unwrap();
        assert!(
            stable.contains("inputs.kix.url = \"github:kix-run/kix/v0.10.0\""),
            "{stable}"
        );
        assert!(
            stable.contains("inputs.kix-stable.url = \"github:kix-run/kix/v0.9.2\""),
            "{stable}"
        );
        // A moved tag of one input is found beside the other input.
        assert_eq!(declared_tag(&kix, "kix", &original), Some(v("0.10.0")));
        assert_eq!(declared_tag(&kix, "kix-stable", &original), None);
    }
}
