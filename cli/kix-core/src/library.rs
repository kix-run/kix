//! The Kix library a project pins in its `flake.lock`, and moving it to the
//! version that matches this version of Kix.
//!
//! The library names the exact Helm versions it renders charts with, and a
//! version of Kix ships exactly those versions. When the two disagree, Kix stops
//! before it renders and says which side to move ([`HelmMismatch`]).
//! `kix lib update` ([`update`]) moves the project's side: it locks the
//! library input to the release tag `v<version>` of this version of Kix with
//! `nix flake lock --override-input`. That records the tag's revision in
//! `flake.lock` and keeps the input's `original` from `flake.nix`, so a later
//! plain evaluation keeps the lock as it is.

use std::cmp::Ordering;
use std::fmt;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::eval::nix::{NixCommandError, command, current_system, output};
use crate::runtime::Tool;
use crate::version::Version;

/// The GitHub owner and repository of the Kix library.
pub const LIBRARY_OWNER: &str = "kix-run";
pub const LIBRARY_REPO: &str = "kix";
/// The Kix library as a flake URL without a ref.
pub const LIBRARY_FLAKE: &str = "github:kix-run/kix";

/// The repository the library lived in up to 0.8.0-rc.1. It gets no new
/// releases, so `kix lib update` asks the user to point the input at
/// [`LIBRARY_FLAKE`] instead of moving it.
const FORMER_REPO: &str = "kixpkgs";

/// A Git URL whose nodes in `flake.lock` count as the Kix library, in place of
/// [`LIBRARY_FLAKE`]. Only tests set it, to run `kix lib update` against
/// a local repository.
pub const TEST_REPO_VAR: &str = "KIX_LIB_UPDATE_TEST_REPO";

/// The flake output that holds the library's version (`kix/lib/mkFlake.nix`).
fn version_attr() -> String {
    format!("legacyPackages.{}.kixLibrary.version", current_system())
}

/// What Kix knows about the release of a project's Kix library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryVersion {
    Known(String),
    /// The library predates the version output.
    Older,
    /// Kix could not read the version.
    Unknown,
}

/// Evaluate the release of the Kix library the flake in `flake_dir` uses.
/// This never fails. A failed evaluation gives [`LibraryVersion::Unknown`].
pub fn eval_version(flake_dir: &Path, input_overrides: &[(String, String)]) -> LibraryVersion {
    let mut cmd = match command(Tool::Nix) {
        Ok(cmd) => cmd,
        Err(_) => return LibraryVersion::Unknown,
    };
    cmd.args(["eval", "--json", "--no-write-lock-file"])
        .arg(format!(".#{}", version_attr()))
        .args([
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
    for (name, url) in input_overrides {
        cmd.arg("--override-input").arg(name).arg(url);
    }
    cmd.current_dir(flake_dir);
    match output(&mut cmd) {
        Ok(out) => match serde_json::from_slice::<Value>(&out) {
            Ok(Value::String(v)) => LibraryVersion::Known(v),
            _ => LibraryVersion::Unknown,
        },
        Err(e) if e.missing_attribute() => LibraryVersion::Older,
        Err(e) => {
            tracing::debug!(error = %e, "could not evaluate the Kix library version");
            LibraryVersion::Unknown
        }
    }
}

/// The library asks for a Helm version this version of Kix does not ship.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelmMismatch {
    pub library: LibraryVersion,
    /// The Helm version the library renders charts with.
    pub wanted: String,
    /// This program's release.
    pub program: String,
    /// The Helm versions this version of Kix ships.
    pub shipped: Vec<String>,
}

/// Which side of a [`HelmMismatch`] should move.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fix {
    /// The library is older: move the project to this program's library.
    UpdateLibrary,
    /// The library is newer: install the program of its release.
    UpgradeProgram,
    /// Kix cannot tell, so the message gives both fixes.
    Either,
}

impl HelmMismatch {
    pub fn fix(&self) -> Fix {
        match &self.library {
            LibraryVersion::Older => Fix::UpdateLibrary,
            LibraryVersion::Unknown => Fix::Either,
            LibraryVersion::Known(lib) => match (lib.parse::<Version>(), self.program.parse()) {
                (Ok(lib), Ok(program)) => match lib.cmp(&program) {
                    Ordering::Less => Fix::UpdateLibrary,
                    Ordering::Greater => Fix::UpgradeProgram,
                    Ordering::Equal => Fix::Either,
                },
                _ => Fix::Either,
            },
        }
    }

    /// Return the shipped Helm of the wanted major version, or all of them
    /// when none matches.
    fn shipped_text(&self) -> String {
        let major = |v: &str| v.split('.').next().map(str::to_string);
        let same: Vec<&String> = self
            .shipped
            .iter()
            .filter(|s| major(s) == major(&self.wanted))
            .collect();
        let list: Vec<&String> = if same.is_empty() {
            self.shipped.iter().collect()
        } else {
            same
        };
        match list.as_slice() {
            [] => "no Helm".to_string(),
            versions => format!(
                "Helm {}",
                versions
                    .iter()
                    .map(|v| v.as_str())
                    .collect::<Vec<_>>()
                    .join(" and ")
            ),
        }
    }
}

impl fmt::Display for HelmMismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let wanted = &self.wanted;
        let program = &self.program;
        match &self.library {
            LibraryVersion::Known(lib) => write!(
                f,
                "This project's Kix library is {lib} and renders Helm charts with Helm {wanted}"
            )?,
            LibraryVersion::Older => write!(
                f,
                "This project uses an older Kix library, which renders Helm charts with Helm {wanted}"
            )?,
            LibraryVersion::Unknown => write!(
                f,
                "This project's Kix library renders Helm charts with Helm {wanted}"
            )?,
        }
        write!(
            f,
            ", but Kix is {program} and ships {}. ",
            self.shipped_text()
        )?;
        match (self.fix(), &self.library) {
            (Fix::UpgradeProgram, LibraryVersion::Known(lib)) => write!(f, "Upgrade Kix to {lib}."),
            (Fix::UpdateLibrary, _) => write!(
                f,
                "Run `kix lib update` to move this project to the {program} library, then commit flake.lock."
            ),
            _ => write!(
                f,
                "Run `kix lib update` to move this project to the {program} library and commit flake.lock, or use the version of Kix that matches the library."
            ),
        }
    }
}

impl std::error::Error for HelmMismatch {}

/// Why `kix lib update` did not move the library.
#[derive(Debug, thiserror::Error)]
pub enum UpdateError {
    #[error(
        "`kix lib update` changes flake.lock on disk, so --flake must name a local directory, not {0}"
    )]
    NotLocal(String),

    #[error(
        "{} has no flake.lock. Run `kix lib update` in the directory that holds your project's flake.nix and flake.lock",
        .0.display()
    )]
    NoLock(PathBuf),

    #[error("could not read {}: {message}", path.display())]
    BadLock { path: PathBuf, message: String },

    #[error(
        "flake.lock has no input for the Kix library. Kix looks for an input locked to {LIBRARY_FLAKE}"
    )]
    NotFound,

    #[error("Kix cannot move this project's Kix library to {version} by itself.\n{}", .steps.iter().map(|s| format!("- {s}")).collect::<Vec<_>>().join("\n"))]
    ByHand { version: String, steps: Vec<String> },

    #[error("could not move the Kix library to v{version}: {source}")]
    Nix {
        version: String,
        #[source]
        source: NixCommandError,
    },
}

/// One Kix library input in `flake.lock`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryInput {
    /// The input names from the root flake to the input that declares this
    /// node, never through a `follows`.
    pub path: Vec<String>,
    /// The locked revision.
    pub rev: Option<String>,
    pub action: Action,
}

/// What `kix lib update` does with a [`LibraryInput`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Lock it to `url` with `--override-input`.
    Move { url: String },
    /// Kix cannot move it. The text says what to do by hand.
    ByHand(String),
}

impl LibraryInput {
    /// Return the input path as `--override-input` takes it.
    pub fn override_path(&self) -> String {
        self.path.join("/")
    }
}

/// Return the Kix library inputs in `lock`, a parsed `flake.lock`, with what
/// to do to move each to the release `version`.
///
/// An input counts as the library when it is locked to [`LIBRARY_FLAKE`] (or
/// to `test_repo`). An input named `kixpkgs` or `kix`, or a repository named
/// `kixpkgs` or `kix` elsewhere, counts too, so that the former repository, a
/// fork, or a local path gets instructions instead of being skipped.
pub fn library_inputs(lock: &Value, version: &str, test_repo: Option<&str>) -> Vec<LibraryInput> {
    let nodes = &lock["nodes"];
    let root = lock["root"].as_str().unwrap_or("root");
    let mut found = Vec::new();
    let mut seen = std::collections::HashSet::from([root.to_string()]);
    let mut queue = std::collections::VecDeque::from([(root.to_string(), Vec::<String>::new())]);
    while let Some((key, path)) = queue.pop_front() {
        let Some(inputs) = nodes[&key]["inputs"].as_object() else {
            continue;
        };
        for (name, edge) in inputs {
            // A `follows` points at a node that its owner declares.
            let Some(child) = edge.as_str() else { continue };
            if !seen.insert(child.to_string()) {
                continue;
            }
            let mut child_path = path.clone();
            child_path.push(name.clone());
            let node = &nodes[child];
            match classify(node, name, version, test_repo) {
                Some(action) => found.push(LibraryInput {
                    rev: node["locked"]["rev"].as_str().map(str::to_string),
                    action: action(&child_path),
                    path: child_path,
                }),
                None => queue.push_back((child.to_string(), child_path)),
            }
        }
    }
    found
}

type ActionFn = Box<dyn Fn(&[String]) -> Action>;

/// Return how to move `node`, the input `name`, when it is the Kix library.
fn classify(node: &Value, name: &str, version: &str, test_repo: Option<&str>) -> Option<ActionFn> {
    let original = node["original"].clone();
    let tag = format!("v{version}");
    let official = test_repo.is_some_and(|t| original["url"].as_str() == Some(t))
        || kix_run_repo(&original).is_some_and(|r| r.eq_ignore_ascii_case(LIBRARY_REPO));
    if !official {
        let named = matches!(name, "kixpkgs" | "kix");
        let is_lib_name =
            |r: &str| r.eq_ignore_ascii_case(FORMER_REPO) || r.eq_ignore_ascii_case(LIBRARY_REPO);
        let repo = original["repo"].as_str().is_some_and(is_lib_name)
            || original["url"].as_str().is_some_and(|u| {
                let u = u.trim_end_matches('/').trim_end_matches(".git");
                u.rsplit('/').next().is_some_and(is_lib_name)
            });
        if !named && !repo {
            return None;
        }
        let from = flake_url(&original);
        if kix_run_repo(&original).is_some_and(|r| r.eq_ignore_ascii_case(FORMER_REPO)) {
            return Some(Box::new(move |path| {
                Action::ByHand(format!(
                    "The input `{}` reads the Kix library from {from}, which has moved to {LIBRARY_FLAKE} and gets no new releases. Point the input at {LIBRARY_FLAKE} in flake.nix, then run `kix lib update` again.",
                    path.join("/")
                ))
            }));
        }
        return Some(Box::new(move |path| {
            Action::ByHand(format!(
                "The input `{}` reads the Kix library from {from} instead of {LIBRARY_FLAKE}, so Kix cannot move it. Point it at {LIBRARY_FLAKE}/{tag}, or move that copy to the {tag} release.",
                path.join("/")
            ))
        }));
    }
    let target = tagged_url(&original, &tag);
    let pinned = original.get("rev").is_some()
        || original["ref"].as_str().is_some_and(|r| {
            let r = r.strip_prefix("refs/tags/").unwrap_or(r);
            r != tag && r.starts_with('v') && r[1..].starts_with(|c: char| c.is_ascii_digit())
        });
    if !pinned {
        return Some(Box::new(move |_| Action::Move {
            url: target.clone(),
        }));
    }
    let from = flake_url(&original);
    Some(Box::new(move |path| {
        Action::ByHand(match path {
            [only] => format!(
                "flake.nix pins the input `{only}` to {from}. Change it to {target} in flake.nix, then run `kix lib update` again."
            ),
            [owners @ .., last] => {
                let attr = path
                    .iter()
                    .map(|p| format!("inputs.{p}"))
                    .collect::<Vec<_>>()
                    .join(".");
                format!(
                    "The input `{owner}` pins its input `{last}` to {from} in its own flake.nix. Move `{owner}` to a release that uses Kix {version}, or add `{attr}.url = \"{target}\";` to your flake.nix. Then run `kix lib update` again.",
                    owner = owners.join("/"),
                    version = &tag[1..],
                )
            }
            [] => unreachable!("an input path has at least one name"),
        })
    }))
}

/// Return the repository name when `original` points at a repository of
/// [`LIBRARY_OWNER`] on github.com.
fn kix_run_repo(original: &Value) -> Option<&str> {
    match original["type"].as_str() {
        Some("github") => {
            let owner = original["owner"].as_str()?;
            (original.get("host").is_none() && owner.eq_ignore_ascii_case(LIBRARY_OWNER))
                .then(|| original["repo"].as_str())
                .flatten()
        }
        Some("git") => {
            let url = original["url"].as_str()?;
            let rest = url
                .strip_prefix("https://")
                .or_else(|| url.strip_prefix("ssh://git@"))
                .unwrap_or(url);
            let rest = rest.trim_end_matches('/').trim_end_matches(".git");
            let (host, path) = rest.split_once('/')?;
            if !host.eq_ignore_ascii_case("github.com") {
                return None;
            }
            let (owner, repo) = path.split_once('/')?;
            (owner.eq_ignore_ascii_case(LIBRARY_OWNER) && !repo.contains('/')).then_some(repo)
        }
        _ => None,
    }
}

/// Return the flake URL of the same repository at the tag `tag`.
fn tagged_url(original: &Value, tag: &str) -> String {
    match original["type"].as_str() {
        Some("github") => format!(
            "github:{}/{}/{tag}",
            original["owner"].as_str().unwrap_or_default(),
            original["repo"].as_str().unwrap_or_default()
        ),
        _ => format!(
            "git+{}?ref=refs/tags/{tag}",
            original["url"].as_str().unwrap_or_default()
        ),
    }
}

/// Return a flake URL for the `original` of a lock node, as a person would
/// write it in `flake.nix`.
pub fn flake_url(original: &Value) -> String {
    let s = |k: &str| original[k].as_str();
    match s("type") {
        Some("github" | "gitlab" | "sourcehut") => {
            let mut url = format!(
                "{}:{}/{}",
                s("type").unwrap_or_default(),
                s("owner").unwrap_or_default(),
                s("repo").unwrap_or_default()
            );
            if let Some(r) = s("ref").or(s("rev")) {
                url.push('/');
                url.push_str(r);
            }
            url
        }
        Some("path") => format!("path:{}", s("path").unwrap_or_default()),
        Some(kind) => {
            let mut url = format!("{kind}+{}", s("url").unwrap_or_default());
            let query: Vec<String> = ["ref", "rev"]
                .iter()
                .filter_map(|k| s(k).map(|v| format!("{k}={v}")))
                .collect();
            if !query.is_empty() {
                url.push('?');
                url.push_str(&query.join("&"));
            }
            url
        }
        None => "an input of unknown type".to_string(),
    }
}

/// Return the locked revision of the input at `path` in `lock`, following
/// `follows`.
fn rev_at(lock: &Value, path: &[String]) -> Option<String> {
    fn node_at(lock: &Value, path: &[String], depth: usize) -> Option<String> {
        if depth > 32 {
            return None;
        }
        let mut key = lock["root"].as_str().unwrap_or("root").to_string();
        for name in path {
            let edge = &lock["nodes"][&key]["inputs"][name];
            key = match edge {
                Value::String(k) => k.clone(),
                Value::Array(follows) => {
                    let follows: Vec<String> = follows
                        .iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect();
                    node_at(lock, &follows, depth + 1)?
                }
                _ => return None,
            };
        }
        Some(key)
    }
    let key = node_at(lock, path, 0)?;
    lock["nodes"][&key]["locked"]["rev"]
        .as_str()
        .map(str::to_string)
}

/// What [`update`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Updated {
    /// The library release before the update.
    pub from: LibraryVersion,
    /// The library release the lock now pins.
    pub to: String,
    /// Whether any locked revision changed.
    pub changed: bool,
}

/// Move the Kix library inputs of the flake in `flake` to the version of Kix
/// running now, the tag `v<release>`. With `dry_run`, work out the new lock
/// without writing it.
pub fn update(flake: &str, dry_run: bool) -> Result<Updated, UpdateError> {
    update_to(flake, &crate::version::running().release(), dry_run)
}

/// Move the Kix library inputs of the flake in `flake` to the tag
/// `v<release>`. With `dry_run`, work out the new lock without writing it.
pub fn update_to(flake: &str, release: &str, dry_run: bool) -> Result<Updated, UpdateError> {
    let dir = Path::new(flake);
    if !dir.is_dir() {
        return Err(UpdateError::NotLocal(flake.to_string()));
    }
    let lock_path = dir.join("flake.lock");
    if !lock_path.is_file() {
        return Err(UpdateError::NoLock(dir.to_path_buf()));
    }
    let lock = read_lock(&lock_path)?;
    let test_repo = std::env::var(TEST_REPO_VAR).ok().filter(|v| !v.is_empty());
    let release = release.to_string();
    let inputs = library_inputs(&lock, &release, test_repo.as_deref());
    if inputs.is_empty() {
        return Err(UpdateError::NotFound);
    }
    let by_hand: Vec<String> = inputs
        .iter()
        .filter_map(|i| match &i.action {
            Action::ByHand(text) => Some(text.clone()),
            Action::Move { .. } => None,
        })
        .collect();
    if !by_hand.is_empty() {
        return Err(UpdateError::ByHand {
            version: release,
            steps: by_hand,
        });
    }

    let from = eval_version(dir, &[]);
    let nix_error = |source| UpdateError::Nix {
        version: release.clone(),
        source,
    };
    let mut cmd = command(Tool::Nix).map_err(nix_error)?;
    if dry_run {
        cmd.args(["flake", "metadata", "--json", "--no-write-lock-file"]);
    } else {
        cmd.args(["flake", "lock"]);
    }
    cmd.args(["--extra-experimental-features", "nix-command flakes"]);
    for input in &inputs {
        if let Action::Move { url } = &input.action {
            cmd.arg("--override-input")
                .arg(input.override_path())
                .arg(url);
        }
    }
    cmd.current_dir(dir);
    let out = output(&mut cmd).map_err(nix_error)?;
    let new_lock = if dry_run {
        let metadata: Value = serde_json::from_slice(&out).map_err(|e| UpdateError::BadLock {
            path: lock_path.clone(),
            message: format!("`nix flake metadata` printed no JSON: {e}"),
        })?;
        metadata["locks"].clone()
    } else {
        read_lock(&lock_path)?
    };
    let changed = inputs.iter().any(|i| rev_at(&new_lock, &i.path) != i.rev);
    Ok(Updated {
        from,
        to: release,
        changed,
    })
}

/// Run `nix flake lock` in `dir`, which locks each input whose entry in
/// `flake.nix` changed, such as a Kix library input moved to another tag.
pub fn lock(dir: &Path, release: &str) -> Result<(), UpdateError> {
    let nix_error = |source| UpdateError::Nix {
        version: release.to_string(),
        source,
    };
    let mut cmd = command(Tool::Nix).map_err(nix_error)?;
    cmd.args([
        "flake",
        "lock",
        "--extra-experimental-features",
        "nix-command flakes",
    ])
    .current_dir(dir);
    output(&mut cmd).map(|_| ()).map_err(nix_error)
}

fn read_lock(path: &Path) -> Result<Value, UpdateError> {
    let bad = |message: String| UpdateError::BadLock {
        path: path.to_path_buf(),
        message,
    };
    let text = std::fs::read_to_string(path).map_err(|e| bad(e.to_string()))?;
    serde_json::from_str(&text).map_err(|e| bad(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn github(owner: &str, rev: &str) -> Value {
        json!({
            "locked": { "type": "github", "owner": owner, "repo": "kix", "rev": rev },
            "original": { "type": "github", "owner": owner, "repo": "kix" }
        })
    }

    #[test]
    fn the_library_flake_names_the_owner_and_repository() {
        assert_eq!(
            LIBRARY_FLAKE,
            format!("github:{LIBRARY_OWNER}/{LIBRARY_REPO}")
        );
    }

    fn nixpkgs() -> Value {
        json!({
            "locked": { "type": "github", "owner": "NixOS", "repo": "nixpkgs", "rev": "n" },
            "original": { "type": "github", "owner": "NixOS", "repo": "nixpkgs" }
        })
    }

    fn moves(inputs: &[LibraryInput]) -> Vec<(String, String)> {
        inputs
            .iter()
            .map(|i| match &i.action {
                Action::Move { url } => (i.override_path(), url.clone()),
                Action::ByHand(text) => (i.override_path(), format!("by hand: {text}")),
            })
            .collect()
    }

    #[test]
    fn finds_a_direct_input() {
        let lock = json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "kixpkgs": "kixpkgs", "nixpkgs": "nixpkgs" } },
                "kixpkgs": github("kix-run", "a"),
                "nixpkgs": nixpkgs(),
            }
        });
        let found = library_inputs(&lock, "0.8.1", None);
        assert_eq!(
            moves(&found),
            [("kixpkgs".into(), "github:kix-run/kix/v0.8.1".into())]
        );
        assert_eq!(found[0].rev.as_deref(), Some("a"));
    }

    #[test]
    fn finds_an_input_of_an_input() {
        let lock = json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "platform": "platform" } },
                "platform": {
                    "inputs": { "kix": "kixpkgs" },
                    "locked": { "type": "github", "owner": "acme", "repo": "platform", "rev": "p" },
                    "original": { "type": "github", "owner": "acme", "repo": "platform" }
                },
                "kixpkgs": github("kix-run", "a"),
            }
        });
        assert_eq!(
            moves(&library_inputs(&lock, "0.8.1", None)),
            [("platform/kix".into(), "github:kix-run/kix/v0.8.1".into())]
        );
    }

    #[test]
    fn moves_the_owner_of_a_follows() {
        let lock = json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "kixpkgs": ["platform", "kixpkgs"], "platform": "platform" } },
                "platform": {
                    "inputs": { "kixpkgs": "kixpkgs_2" },
                    "locked": { "type": "github", "owner": "acme", "repo": "platform", "rev": "p" },
                    "original": { "type": "github", "owner": "acme", "repo": "platform" }
                },
                "kixpkgs_2": github("kix-run", "a"),
            }
        });
        let found = library_inputs(&lock, "0.8.1", None);
        assert_eq!(
            moves(&found),
            [(
                "platform/kixpkgs".into(),
                "github:kix-run/kix/v0.8.1".into()
            )]
        );
        assert_eq!(
            rev_at(&lock, &["kixpkgs".to_string()]).as_deref(),
            Some("a")
        );
    }

    #[test]
    fn a_path_input_is_by_hand() {
        let lock = json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "kixpkgs": "kixpkgs" } },
                "kixpkgs": {
                    "locked": { "type": "path", "path": "/src/kixpkgs", "narHash": "x" },
                    "original": { "type": "path", "path": "/src/kixpkgs" }
                },
            }
        });
        let [input] = &library_inputs(&lock, "0.8.1", None)[..] else {
            panic!("one input")
        };
        let Action::ByHand(text) = &input.action else {
            panic!("by hand")
        };
        assert!(text.contains("path:/src/kixpkgs"), "{text}");
        assert!(text.contains("github:kix-run/kix/v0.8.1"), "{text}");
    }

    #[test]
    fn a_fork_is_by_hand() {
        let lock = json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "infra": "kixpkgs" } },
                "kixpkgs": github("someone", "a"),
            }
        });
        let [input] = &library_inputs(&lock, "0.8.1", None)[..] else {
            panic!("one input")
        };
        assert!(
            matches!(&input.action, Action::ByHand(t) if t.contains("github:someone/kix")),
            "{input:?}"
        );
    }

    #[test]
    fn the_former_repository_is_by_hand() {
        let former = |original: Value| {
            json!({
                "root": "root",
                "nodes": {
                    "root": { "inputs": { "kixpkgs": "kixpkgs" } },
                    "kixpkgs": { "locked": original.clone(), "original": original }
                }
            })
        };
        for original in [
            json!({ "type": "github", "owner": "kix-run", "repo": "kixpkgs", "ref": "v0.7.0" }),
            json!({ "type": "github", "owner": "kix-run", "repo": "kixpkgs" }),
            json!({ "type": "git", "url": "https://github.com/kix-run/kixpkgs.git" }),
        ] {
            let [input] = &library_inputs(&former(original.clone()), "0.8.1", None)[..] else {
                panic!("one input for {original}")
            };
            let Action::ByHand(text) = &input.action else {
                panic!("by hand for {original}")
            };
            assert!(
                text.contains("which has moved to github:kix-run/kix"),
                "{text}"
            );
        }
    }

    #[test]
    fn a_pinned_tag_is_by_hand() {
        let mut node = github("kix-run", "a");
        node["original"]["ref"] = json!("v0.8.0");
        let lock = json!({
            "root": "root",
            "nodes": { "root": { "inputs": { "kixpkgs": "kixpkgs" } }, "kixpkgs": node }
        });
        let [input] = &library_inputs(&lock, "0.8.1", None)[..] else {
            panic!("one input")
        };
        assert_eq!(
            input.action,
            Action::ByHand(
                "flake.nix pins the input `kixpkgs` to github:kix-run/kix/v0.8.0. Change it to github:kix-run/kix/v0.8.1 in flake.nix, then run `kix lib update` again.".into()
            )
        );
    }

    #[test]
    fn a_pin_in_another_flake_is_by_hand() {
        let mut node = github("kix-run", "a");
        node["original"]["rev"] = json!("0123abc");
        let lock = json!({
            "root": "root",
            "nodes": {
                "root": { "inputs": { "platform": "platform" } },
                "platform": {
                    "inputs": { "kixpkgs": "kixpkgs" },
                    "locked": { "type": "github", "owner": "acme", "repo": "platform", "rev": "p" },
                    "original": { "type": "github", "owner": "acme", "repo": "platform" }
                },
                "kixpkgs": node,
            }
        });
        let [input] = &library_inputs(&lock, "0.8.1", None)[..] else {
            panic!("one input")
        };
        let Action::ByHand(text) = &input.action else {
            panic!("by hand")
        };
        assert!(
            text.contains(
                "add `inputs.platform.inputs.kixpkgs.url = \"github:kix-run/kix/v0.8.1\";`"
            ),
            "{text}"
        );
    }

    #[test]
    fn the_matching_tag_or_a_branch_moves() {
        for r in ["v0.8.1", "refs/tags/v0.8.1", "main"] {
            let mut node = github("kix-run", "a");
            node["original"]["ref"] = json!(r);
            let lock = json!({
                "root": "root",
                "nodes": { "root": { "inputs": { "kixpkgs": "kixpkgs" } }, "kixpkgs": node }
            });
            assert!(
                matches!(
                    library_inputs(&lock, "0.8.1", None)[0].action,
                    Action::Move { .. }
                ),
                "{r}"
            );
        }
    }

    #[test]
    fn a_git_url_and_the_test_repo_move() {
        let git = |url: &str| {
            json!({
                "root": "root",
                "nodes": {
                    "root": { "inputs": { "k": "k" } },
                    "k": {
                        "locked": { "type": "git", "url": url, "rev": "a" },
                        "original": { "type": "git", "url": url }
                    }
                }
            })
        };
        assert_eq!(
            moves(&library_inputs(
                &git("https://github.com/kix-run/kix.git"),
                "0.8.1",
                None
            )),
            [(
                "k".into(),
                "git+https://github.com/kix-run/kix.git?ref=refs/tags/v0.8.1".into()
            )]
        );
        assert!(library_inputs(&git("file:///tmp/lib"), "0.8.1", None).is_empty());
        assert_eq!(
            moves(&library_inputs(
                &git("file:///tmp/lib"),
                "0.8.1",
                Some("file:///tmp/lib")
            )),
            [(
                "k".into(),
                "git+file:///tmp/lib?ref=refs/tags/v0.8.1".into()
            )]
        );
    }

    fn mismatch(library: LibraryVersion, wanted: &str, program: &str) -> HelmMismatch {
        HelmMismatch {
            library,
            wanted: wanted.into(),
            program: program.into(),
            shipped: vec!["3.19.1".into(), "4.3.2".into()],
        }
    }

    #[test]
    fn an_older_library_is_told_to_update() {
        let m = mismatch(LibraryVersion::Known("0.8.0".into()), "4.3.1", "0.8.1");
        assert_eq!(m.fix(), Fix::UpdateLibrary);
        assert_eq!(
            m.to_string(),
            "This project's Kix library is 0.8.0 and renders Helm charts with Helm 4.3.1, but Kix is 0.8.1 and ships Helm 4.3.2. Run `kix lib update` to move this project to the 0.8.1 library, then commit flake.lock."
        );
    }

    #[test]
    fn a_newer_library_is_told_to_upgrade_kix() {
        let m = HelmMismatch {
            shipped: vec!["3.19.1".into(), "4.3.1".into()],
            ..mismatch(LibraryVersion::Known("0.8.1".into()), "4.3.2", "0.8.0")
        };
        assert_eq!(m.fix(), Fix::UpgradeProgram);
        assert_eq!(
            m.to_string(),
            "This project's Kix library is 0.8.1 and renders Helm charts with Helm 4.3.2, but Kix is 0.8.0 and ships Helm 4.3.1. Upgrade Kix to 0.8.1."
        );
    }

    #[test]
    fn a_library_without_a_version_is_older() {
        let m = mismatch(LibraryVersion::Older, "4.3.1", "0.8.1");
        assert_eq!(m.fix(), Fix::UpdateLibrary);
        assert!(
            m.to_string()
                .starts_with("This project uses an older Kix library, which renders")
        );
    }

    #[test]
    fn an_unknown_or_equal_version_gives_both_fixes() {
        for library in [
            LibraryVersion::Unknown,
            LibraryVersion::Known("0.8.1".into()),
        ] {
            let m = mismatch(library, "4.3.1", "0.8.1");
            assert_eq!(m.fix(), Fix::Either);
            let text = m.to_string();
            assert!(text.contains("Run `kix lib update`"), "{text}");
            assert!(text.contains("or use the version of Kix"), "{text}");
        }
    }

    #[test]
    fn a_missing_major_lists_every_shipped_helm() {
        let m = mismatch(LibraryVersion::Unknown, "5.0.0", "0.8.1");
        assert!(m.to_string().contains("ships Helm 3.19.1 and 4.3.2."));
    }
}
