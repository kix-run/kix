//! Pin a project's Kix library to the release tag of a version of Kix, and
//! check that the project then builds with that version of the library.
//!
//! The library is the input of the project's own flake named `kix`
//! (`crate::flake_lock`). Kix writes the tag `v<version>` into that input's
//! url in `flake.nix`, replacing any branch, commit, or older tag, and then
//! locks. It reads the input from the lock that `flake.nix` gives now
//! (`nix flake metadata --no-write-lock-file`), so a project with no
//! `flake.lock`, or one that fell behind `flake.nix`, can be pinned too.
//! One evaluation of the library's version then confirms the result.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::eval::nix::{NixCommandError, command, output};
use crate::flake_lock::{INPUT, OLD_NAME, OLD_NAME_ID};
use crate::library::{LibraryVersion, try_eval_version};
use crate::runtime::Tool;
use crate::version::Version;

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

    #[error(
        "flake.nix has no input named kix, which Kix reads the project's Kix library from. Add `inputs.kix.url = \"github:kix-run/kix/{tag}\";` to flake.nix."
    )]
    NotFound { tag: String },

    #[error(
        "[{OLD_NAME_ID}] flake.nix names the Kix library input {OLD_NAME}, and Kix now reads only an input named {INPUT}. Rename the input to {INPUT} in flake.nix."
    )]
    OldName,

    #[error(
        "The input kix in flake.nix follows {path}, so the Kix library comes from another flake. Set `inputs.kix.url = \"github:kix-run/kix/{tag}\";` in flake.nix."
    )]
    Follows { path: String, tag: String },

    #[error(
        "The input kix is the local folder {path}, which has no versions. Point the input at the tag {tag}, such as github:kix-run/kix/{tag}."
    )]
    Folder { path: String, tag: String },

    #[error(
        "The input kix reads the Kix library from {url}, and Kix can pin only a Git repository or a GitHub, GitLab, or SourceHut repository to a release tag. Point the input at the tag {tag}, such as github:kix-run/kix/{tag}."
    )]
    Unsupported { url: String, tag: String },

    #[error(
        "Kix could not find the url of the input kix in flake.nix, so it changed nothing. Change that url to {to_url} in flake.nix."
    )]
    UrlNotFound { to_url: String },

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
    /// The version of Kix the library must match.
    pub version: Version,
    /// The release tag's url.
    tag_url: String,
    /// The repository the input reads, as a person would write it.
    repo: String,
    /// `flake.nix` with the input on the tag, when it must change.
    new_flake: Option<String>,
}

/// Work out how to pin the Kix library input of the project in `dir` to the
/// release tag of Kix `version`, without changing anything.
pub fn plan(dir: &Path, version: &Version) -> Result<Plan, PinLibraryError> {
    let locks = read_locks(dir)?;
    let flake_path = dir.join("flake.nix");
    let flake = std::fs::read_to_string(&flake_path).map_err(|source| PinLibraryError::Io {
        action: "read",
        path: flake_path,
        source,
    })?;
    decide(dir, &locks, &flake, version)
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
    version: &Version,
) -> Result<Plan, PinLibraryError> {
    let tag = format!("v{}", version.release());
    let root = locks["root"].as_str().unwrap_or("root");
    let inputs = locks["nodes"][root]["inputs"].as_object();
    let node_key = match inputs.and_then(|i| i.get(INPUT)) {
        Some(Value::String(key)) => key,
        Some(Value::Array(path)) => {
            let path: Vec<&str> = path.iter().filter_map(Value::as_str).collect();
            return Err(PinLibraryError::Follows {
                path: path.join("/"),
                tag,
            });
        }
        _ if inputs.is_some_and(|i| i.contains_key(OLD_NAME)) => {
            return Err(PinLibraryError::OldName);
        }
        _ => return Err(PinLibraryError::NotFound { tag }),
    };
    let original = &locks["nodes"][node_key]["original"];
    let s = |k: &str| original[k].as_str();
    let repo = repo_url(original);
    match s("type") {
        Some("path") => {
            return Err(PinLibraryError::Folder {
                path: s("path").unwrap_or_default().to_string(),
                tag,
            });
        }
        Some("github" | "gitlab" | "sourcehut" | "git") => {}
        _ => return Err(PinLibraryError::Unsupported { url: repo, tag }),
    }
    let tag_url = tagged_url(original, &tag);
    let new_flake = if s("ref").map(|r| r.strip_prefix("refs/tags/").unwrap_or(r)) == Some(&tag) {
        None
    } else {
        Some(retag_flake(flake, original, &tag).map_err(|e| match e {
            Retag::NotFound => PinLibraryError::UrlNotFound {
                to_url: tag_url.clone(),
            },
            Retag::Many(lines) => PinLibraryError::Edit(HandEdit {
                to_url: tag_url.clone(),
                lines,
            }),
        })?)
    };
    Ok(Plan {
        dir: dir.to_path_buf(),
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
        .map(bare_ref)
        .or_else(|| s("rev").map(str::to_string))
}

fn bare_ref(r: &str) -> String {
    r.strip_prefix("refs/tags/")
        .or_else(|| r.strip_prefix("refs/heads/"))
        .unwrap_or(r)
        .to_string()
}

/// Return `literal`, a url in `flake.nix`, moved to the tag `tag`, when it
/// names the repository of `original` and pins what `original` pins.
fn retarget(literal: &str, original: &Value, tag: &str) -> Option<String> {
    if !literal
        .to_ascii_lowercase()
        .contains(&repo_needle(original))
    {
        return None;
    }
    let want = pin_of_original(original);
    let url = Url::parse(literal);
    let forge = ["github:", "gitlab:", "sourcehut:"]
        .iter()
        .any(|p| url.base.starts_with(p));
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
        let pin = pin
            .or_else(|| url.param("ref").map(bare_ref))
            .or_else(|| url.param("rev").map(str::to_string));
        if pin != want {
            return None;
        }
        return Some(url.join(&format!("{scheme}:{owner_repo}/{tag}"), None));
    }
    if !url.base.starts_with("git+") {
        return None;
    }
    let pin = url
        .param("ref")
        .map(bare_ref)
        .or_else(|| url.param("rev").map(str::to_string));
    if pin != want {
        return None;
    }
    Some(url.join(url.base, Some(("ref", &format!("refs/tags/{tag}")))))
}

/// Return `flake`, a `flake.nix`, with the url of the library input moved to
/// the tag `tag`.
///
/// Kix reads no Nix syntax to do this. It changes the url only when exactly
/// one url names the repository of `original` and pins what it pins. A
/// project can pin a second input to the same url, such as the Kix it builds
/// into an image, and that input must stay. Comment lines are skipped.
fn retag_flake(flake: &str, original: &Value, tag: &str) -> Result<String, Retag> {
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(open) = flake[at..].find('"').map(|i| at + i) {
        let Some(close) = flake[open + 1..].find('"').map(|i| open + 1 + i) else {
            break;
        };
        let literal = &flake[open + 1..close];
        if !in_comment(flake, open)
            && let Some(new) = retarget(literal, original, tag)
        {
            found.push((open + 1, close, new));
        }
        at = close + 1;
    }
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
        let found = match try_eval_version(&self.dir, &[]) {
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
            Err(e) => {
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
        };
        if found.parse::<Version>().is_ok_and(|v| v == self.version) {
            return Ok(());
        }
        Err(format!(
            "Kix moved the input kix to {tag}, but the project builds with the Kix library {found}. Check that the tag {tag} of {} holds the Kix library {kix}.",
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
        decide(Path::new("/p"), locks, flake, &v("0.10.0"))
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
        let mirror = json!({ "type": "git", "url": "ssh://git@git.example:30232/org/kixpkgs.git", "ref": "v0.9.1" });
        assert_eq!(
            new_flake(
                mirror,
                "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=v0.9.1&shallow=1\";"
            ),
            "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?shallow=1&ref=refs/tags/v0.10.0\";"
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
    fn two_urls_of_the_repository_are_left_to_a_person() {
        let url = "git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1";
        let flake = format!(
            "inputs = {{\n  kix = {{\n    url = \"{url}\";\n  }};\n  image-kix = {{\n    url = \"{url}\";\n  }};\n}};\n"
        );
        let original = json!({
            "type": "git",
            "url": "ssh://git@git.example:30232/org/kixpkgs.git",
            "ref": "refs/tags/v0.8.0-rc.1"
        });
        let Err(PinLibraryError::Edit(edit)) = plan_for(&lock_with(original), &flake) else {
            panic!("expected Kix to leave the edit to a person");
        };
        assert_eq!(
            edit.to_url,
            "git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.10.0"
        );
        let numbers: Vec<usize> = edit.lines.iter().map(|(n, _)| *n).collect();
        assert_eq!(numbers, [3, 6]);
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
    fn the_input_must_be_a_direct_input_named_kix_that_kix_can_tag() {
        let mut locks = lock_with(github(None));
        locks["nodes"]["root"]["inputs"] = json!({ "kixpkgs": "kix" });
        assert!(matches!(
            plan_for(&locks, ""),
            Err(PinLibraryError::OldName)
        ));
        locks["nodes"]["root"]["inputs"] = json!({ "nixpkgs": "nixpkgs" });
        assert_eq!(
            plan_for(&locks, "").unwrap_err().to_string(),
            "flake.nix has no input named kix, which Kix reads the project's Kix library from. Add `inputs.kix.url = \"github:kix-run/kix/v0.10.0\";` to flake.nix."
        );
        locks["nodes"]["root"]["inputs"] = json!({ "kix": ["platform", "kix"] });
        assert!(matches!(
            plan_for(&locks, ""),
            Err(PinLibraryError::Follows { .. })
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
}
