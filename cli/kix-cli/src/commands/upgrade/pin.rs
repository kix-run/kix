//! Pin a project to a version of Kix: the exact version in `kix.toml`, the
//! release tag in `flake.nix` when the library input names one, and the
//! library in `flake.lock`.

use std::path::Path;

use kix::version::Version;

/// Return `text`, a `kix.toml`, with its `kix` setting set to `version`.
/// The setting is added at the top when the file has none, and a comment
/// after it stays. Refuse when the result does not read back as that
/// version, such as when `kix` is written across lines.
pub fn set_kix(text: &str, version: &str) -> Result<String, String> {
    let line = format!("kix = \"{version}\"");
    let mut out = Vec::new();
    let mut done = false;
    let mut in_table = false;
    for l in text.lines() {
        let trimmed = l.trim_start();
        if trimmed.starts_with('[') {
            in_table = true;
        }
        let is_kix = !in_table
            && trimmed
                .strip_prefix("kix")
                .is_some_and(|rest| rest.trim_start().starts_with('='));
        if is_kix && !done {
            match l.find('#') {
                Some(at) => out.push(format!("{line} {}", &l[at..])),
                None => out.push(line.clone()),
            }
            done = true;
        } else if !is_kix {
            out.push(l.to_string());
        }
    }
    if !done {
        out.insert(0, line);
    }
    let mut joined = out.join("\n");
    joined.push('\n');
    let reads_back = toml::from_str::<toml::Table>(&joined)
        .ok()
        .and_then(|t| t.get("kix").and_then(|v| v.as_str()).map(str::to_string));
    if reads_back.as_deref() != Some(version) {
        return Err(format!(
            "Kix could not set kix = \"{version}\" in kix.toml. Set it by hand, then run `kix upgrade` again."
        ));
    }
    Ok(joined)
}

/// The input names that mark the Kix library when `flake.lock` has more
/// than one input on the Kix library's repository.
const LIBRARY_INPUT_NAMES: &[&str] = &["kixpkgs", "kix"];

/// Return whether `at` lies on a line that is a comment.
fn in_comment(text: &str, at: usize) -> bool {
    let line_start = text[..at].rfind('\n').map_or(0, |n| n + 1);
    text[line_start..at].trim_start().starts_with('#')
}

/// Return the span of the tag `v<version>` that ends `url`'s ref: after a
/// `/` or `=`, and at the end or before `&` or `?`.
fn tag_span(url: &str, version: &str) -> Option<(usize, usize)> {
    let tag = format!("v{version}");
    url.match_indices(&tag)
        .map(|(at, _)| (at, at + tag.len()))
        .find(|&(at, end)| {
            url[..at].ends_with(['/', '='])
                && (url[end..].is_empty() || url[end..].starts_with(['&', '?']))
        })
}

/// What [`retag_flake`] found.
#[derive(Debug, PartialEq, Eq)]
pub enum Retag {
    /// `flake.nix` with the tag moved.
    Moved(String),
    /// A Kix url already names the new tag, so a person made the edit.
    AlreadyMoved,
    /// No Kix url names the old tag, so the lock alone moves the library.
    NoTag,
    /// Kix cannot tell which url to change.
    ByHand(HandEdit),
}

/// A `flake.nix` edit Kix leaves to a person: more than one Kix url names
/// the tag the project uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandEdit {
    /// The tag the urls name now, such as `v0.8.0-rc.1`.
    pub from_tag: String,
    /// The tag the library input must name, such as `v0.9.1`.
    pub to_tag: String,
    /// Each line that names `from_tag`: its number and its text.
    pub lines: Vec<(usize, String)>,
}

/// Return the span of the tag `v<version>` in each url in `text`, a
/// `flake.nix`, that names Kix. A url is a string with a `:` that contains
/// `kix`, such as the repository or a mirror named `kixpkgs.git`. Comment
/// lines are skipped.
fn kix_tags(text: &str, version: &str) -> Vec<(usize, usize)> {
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(open) = text[at..].find('"').map(|i| at + i) {
        let Some(close) = text[open + 1..].find('"').map(|i| open + 1 + i) else {
            break;
        };
        let literal = &text[open + 1..close];
        if !in_comment(text, open)
            && literal.contains(':')
            && literal.to_ascii_lowercase().contains("kix")
            && let Some((start, end)) = tag_span(literal, version)
        {
            found.push((open + 1 + start, open + 1 + end));
        }
        at = close + 1;
    }
    found
}

/// Move the Kix library's release tag `v<from>` in `text`, a `flake.nix`,
/// to `v<to>`.
///
/// Kix reads no Nix syntax to do this. It changes the tag only when exactly
/// one Kix url names `v<from>`. A project can pin a second input to the
/// same tag, such as the Kix it builds into an image, and that input must
/// stay. With more than one such url, Kix changes nothing and names the
/// lines, so a person or an agent makes the edit and runs `kix upgrade`
/// again.
pub fn retag_flake(text: &str, from: &str, to: &str) -> Retag {
    if !kix_tags(text, to).is_empty() {
        return Retag::AlreadyMoved;
    }
    match kix_tags(text, from).as_slice() {
        [] => Retag::NoTag,
        [(start, end)] => Retag::Moved(format!("{}v{to}{}", &text[..*start], &text[*end..])),
        many => {
            let lines = many
                .iter()
                .map(|(start, _)| {
                    let number = text[..*start].matches('\n').count() + 1;
                    let line = text.lines().nth(number - 1).unwrap_or_default();
                    (number, line.trim().to_string())
                })
                .collect();
            Retag::ByHand(HandEdit {
                from_tag: format!("v{from}"),
                to_tag: format!("v{to}"),
                lines,
            })
        }
    }
}

/// Return the top-level Kix library input in `lock`, a parsed `flake.lock`,
/// as `kix lib update` identifies it, and the tag its entry in `flake.nix`
/// names, if any.
fn library_input(
    lock: &serde_json::Value,
    release: &str,
) -> Result<(String, Option<String>), String> {
    let test_repo = std::env::var(kix::library::TEST_REPO_VAR)
        .ok()
        .filter(|v| !v.is_empty());
    let top: Vec<String> = kix::library::library_inputs(lock, release, test_repo.as_deref())
        .into_iter()
        .filter(|i| i.path.len() == 1)
        .map(|i| i.path[0].clone())
        .collect();
    let name = match top.as_slice() {
        [one] => one.clone(),
        [] => return Err("flake.lock has no input for the Kix library".to_string()),
        many => {
            let named: Vec<&String> = many
                .iter()
                .filter(|n| LIBRARY_INPUT_NAMES.contains(&n.as_str()))
                .collect();
            match named.as_slice() {
                [one] => (*one).clone(),
                _ => {
                    return Err(format!(
                        "flake.lock has more than one input on the Kix library's repository ({}), and Kix cannot tell which one the project builds its clusters from. Kix changed nothing. Set the url of the Kix library input in flake.nix to the tag v{release}, then run `kix upgrade` again.",
                        many.join(", ")
                    ));
                }
            }
        }
    };
    let root = lock["root"].as_str().unwrap_or("root");
    let node = lock["nodes"][root]["inputs"][&name]
        .as_str()
        .map(|key| &lock["nodes"][key]);
    let tag = node
        .and_then(|n| {
            n["original"]["ref"]
                .as_str()
                .or(n["locked"]["ref"].as_str())
        })
        .map(|r| r.strip_prefix("refs/tags/").unwrap_or(r).to_string())
        .filter(|r| r.starts_with('v') && r[1..].starts_with(|c: char| c.is_ascii_digit()));
    Ok((name, tag))
}

/// Why Kix could not pin the project. Each message is ready to print and
/// ends with a `Next:` line.
#[derive(Debug)]
pub enum PinError {
    /// Nix could not move `flake.lock`. Kix tried to put the files back.
    Lock(String),
    /// A person must change a file. Kix changed nothing, or put it back.
    ByHand(String),
    /// More than one Kix url in `flake.nix` names the tag. Kix changed
    /// nothing.
    Edit(HandEdit),
    Other(String),
}

impl From<String> for PinError {
    fn from(message: String) -> Self {
        PinError::Other(message)
    }
}

impl std::fmt::Display for PinError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PinError::Lock(m) | PinError::ByHand(m) | PinError::Other(m) => f.write_str(m),
            PinError::Edit(e) => write!(f, "flake.nix names {} more than once", e.from_tag),
        }
    }
}

/// The contents of a file before Kix changed it, `None` when it did not
/// exist.
struct Saved(std::path::PathBuf, Option<String>);

impl Saved {
    fn take(path: std::path::PathBuf) -> Result<Self, String> {
        match std::fs::read_to_string(&path) {
            Ok(text) => Ok(Saved(path, Some(text))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Saved(path, None)),
            Err(e) => Err(format!("could not read {}: {e}", path.display())),
        }
    }

    fn restore(&self) -> std::io::Result<()> {
        match &self.1 {
            Some(text) => std::fs::write(&self.0, text),
            None if self.0.exists() => std::fs::remove_file(&self.0),
            None => Ok(()),
        }
    }
}

/// Work out the change to `flake.nix` that moves the project from `current`
/// to `release`.
///
/// Kix touches `flake.nix` only when the lock says the library is pinned to
/// the tag the project uses now. An unpinned library moves in the lock
/// alone.
fn flake_edit(
    flake: &Saved,
    lock: &Saved,
    current: &Version,
    release: &str,
) -> Result<Retag, String> {
    let (Some(lock_text), Some(flake_text)) = (&lock.1, &flake.1) else {
        return Ok(Retag::NoTag);
    };
    let parsed: serde_json::Value = serde_json::from_str(lock_text)
        .map_err(|e| format!("could not read {}: {e}", lock.0.display()))?;
    if !kix_tags(flake_text, release).is_empty() {
        return Ok(Retag::AlreadyMoved);
    }
    if locked_tag(&parsed, release).is_some_and(|t| t == format!("v{}", current.release())) {
        Ok(retag_flake(flake_text, &current.release(), release))
    } else {
        Ok(Retag::NoTag)
    }
}

/// Return the tag the Kix library input of `lock` is locked to, if any.
fn locked_tag(lock: &serde_json::Value, release: &str) -> Option<String> {
    library_input(lock, release).ok().and_then(|(_, tag)| tag)
}

/// Return the tag the library input of the `flake.lock` in `dir` names.
fn tag_on_disk(dir: &Path, release: &str) -> Option<String> {
    let text = std::fs::read_to_string(dir.join("flake.lock")).ok()?;
    let lock: serde_json::Value = serde_json::from_str(&text).ok()?;
    locked_tag(&lock, release)
}

/// Return what a person must change in `flake.nix` before Kix can move the
/// project from `current` to `version`, or `None` when Kix can do it.
pub fn needs_hand_edit(dir: &Path, current: &Version, version: &Version) -> Option<HandEdit> {
    let flake = Saved::take(dir.join("flake.nix")).ok()?;
    let lock = Saved::take(dir.join("flake.lock")).ok()?;
    match flake_edit(&flake, &lock, current, &version.release()) {
        Ok(Retag::ByHand(edit)) => Some(edit),
        _ => None,
    }
}

/// Pin the project in `dir`, now pinned to `current`, to `version`. Return
/// the name of each file Kix changed. When moving `flake.lock` fails, put
/// `kix.toml`, `flake.nix`, and `flake.lock` back.
pub fn pin(
    dir: &Path,
    current: &Version,
    version: &Version,
) -> Result<Vec<&'static str>, PinError> {
    let release = version.release();
    let target_tag = format!("v{release}");
    let mut notes = Vec::new();
    let toml = Saved::take(dir.join(kix::project::FILE))?;
    let flake = Saved::take(dir.join("flake.nix"))?;
    let lock = Saved::take(dir.join("flake.lock"))?;

    // Work out every change before writing anything.
    let (new_flake, hand_edited) = match flake_edit(&flake, &lock, current, &release)? {
        Retag::Moved(text) => (Some(text), false),
        Retag::AlreadyMoved => (None, true),
        Retag::NoTag => (None, false),
        Retag::ByHand(edit) => return Err(PinError::Edit(edit)),
    };
    let pinned = current.release();
    let old = toml.1.clone().unwrap_or_default();
    let new = set_kix(&old, &release).map_err(|_| {
        PinError::ByHand(format!(
            "Cannot update the `kix` version field in kix.toml automatically.\nkix.toml, flake.nix, and flake.lock remain at Kix {pinned}.\nNext: set `kix = \"{release}\"` on a single line in kix.toml, then run `kix upgrade` again."
        ))
    })?;

    if new != old {
        std::fs::write(&toml.0, new)
            .map_err(|e| format!("could not write {}: {e}", toml.0.display()))?;
        notes.push("kix.toml");
    }
    if let Some(text) = &new_flake {
        std::fs::write(&flake.0, text)
            .map_err(|e| format!("could not write {}: {e}", flake.0.display()))?;
        notes.push("flake.nix");
    }
    if lock.1.is_none() || tag_on_disk(dir, &release).as_deref() == Some(target_tag.as_str()) {
        return Ok(notes);
    }

    let moved = (|| -> Result<(), String> {
        crate::commands::select_builder_for(dir)?;
        kix::runtime::runtime().map_err(|e| e.to_string())?;
        if new_flake.is_some() || hand_edited {
            // The changed url is enough for Nix to lock the new tag.
            kix::library::lock(dir, &release).map_err(|e| e.to_string())
        } else {
            kix::library::update_to(&dir.display().to_string(), &release, false)
                .map(|_| ())
                .map_err(|e| e.to_string())
        }
    })();
    let restore = || {
        toml.restore()
            .and_then(|()| flake.restore())
            .and_then(|()| lock.restore())
            .is_ok()
    };
    let not_restored = |tag: &str| {
        format!(
            "Could not restore kix.toml, flake.nix, and flake.lock to Kix {pinned} automatically.\nNext: run `git checkout -- kix.toml flake.nix flake.lock`, make sure tag {tag} is reachable, then run `kix upgrade` again."
        )
    };
    if let Err(e) = moved {
        // Nix prints its command line and a trace before the one line
        // that says what went wrong.
        let error: String = super::out::excerpt(&e)
            .iter()
            .map(|l| format!("  {l}\n"))
            .collect();
        let head =
            format!("Cannot lock Kix library tag {target_tag} for Kix {release}:\n{error}\n");
        return Err(PinError::Lock(if restore() {
            format!(
                "{head}Restored kix.toml, flake.nix, and flake.lock to Kix {pinned}.\nNext: check that tag {target_tag} is reachable in your Kix input repository, then run `kix upgrade` again."
            )
        } else {
            format!("{head}{}", not_restored(&target_tag))
        }));
    }
    // A lock naming any other tag means the library did not move.
    if let Some(locked) = tag_on_disk(dir, &release)
        && locked != target_tag
    {
        let head = format!(
            "Locked flake.lock, but the Kix library input is still on {locked} instead of {target_tag}.\n"
        );
        return Err(PinError::ByHand(if restore() {
            format!(
                "{head}Restored kix.toml, flake.nix, and flake.lock to Kix {pinned}.\nNext: update the Kix library input in flake.nix to use tag {target_tag}, then run `kix upgrade` again."
            )
        } else {
            format!("{head}{}", not_restored(&target_tag))
        }));
    }
    notes.push("flake.lock");
    Ok(notes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_kix_replaces_or_adds_the_setting() {
        let set = |text: &str, v: &str| set_kix(text, v).unwrap();
        assert_eq!(set("", "0.10.1"), "kix = \"0.10.1\"\n");
        assert_eq!(
            set("builder = \"nix\"\nkix = \"0.9\"\n", "0.10.1"),
            "builder = \"nix\"\nkix = \"0.10.1\"\n"
        );
        assert_eq!(
            set(
                "# project\nbuilder = \"kix\"\n\n[upgrade]\nmin-age = \"7d\"\n",
                "0.10.1"
            ),
            "kix = \"0.10.1\"\n# project\nbuilder = \"kix\"\n\n[upgrade]\nmin-age = \"7d\"\n"
        );
        assert_eq!(
            set("kixx = 1\nkix=\"0.9.0\"\n", "1.0.0"),
            "kixx = 1\nkix = \"1.0.0\"\n"
        );
        assert_eq!(
            set("kix = \"0.9\" # the team's version\n", "0.10.1"),
            "kix = \"0.10.1\" # the team's version\n"
        );
    }

    #[test]
    fn set_kix_refuses_what_it_cannot_read_back() {
        assert!(set_kix("kix = \"\"\"\n0.9\n\"\"\"\n", "0.10.1").is_err());
        assert!(set_kix("not toml = = \n", "0.10.1").is_err());
    }

    #[test]
    fn a_lock_already_at_the_target_needs_no_nix() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let lock = serde_json::json!({
            "root": "root",
            "nodes": {
                "root": {"inputs": {"kix": "kix"}},
                "kix": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.10.0"}}
            }
        });
        std::fs::write(d.join("kix.toml"), "kix = \"0.9.1\"\n").unwrap();
        std::fs::write(
            d.join("flake.nix"),
            "{ inputs.kix.url = \"github:kix-run/kix/v0.10.0\"; }",
        )
        .unwrap();
        std::fs::write(d.join("flake.lock"), lock.to_string()).unwrap();
        pin(d, &"0.9.1".parse().unwrap(), &"0.10.0".parse().unwrap()).unwrap();
        assert_eq!(
            std::fs::read_to_string(d.join("kix.toml")).unwrap(),
            "kix = \"0.10.0\"\n"
        );
    }

    fn moved(text: &str, from: &str, to: &str) -> String {
        match retag_flake(text, from, to) {
            Retag::Moved(text) => text,
            other => panic!("expected the tag to move, got {other:?}"),
        }
    }

    #[test]
    fn retag_flake_moves_the_tag_in_each_url_form() {
        let cases = [
            (
                "inputs.kix.url = \"github:kix-run/kix/v0.9.1\";",
                "inputs.kix.url = \"github:kix-run/kix/v0.10.0\";",
            ),
            (
                "inputs.kix.url = \"git+https://github.com/kix-run/kix?ref=refs/tags/v0.9.1\";",
                "inputs.kix.url = \"git+https://github.com/kix-run/kix?ref=refs/tags/v0.10.0\";",
            ),
            (
                "kixpkgs = {\n  url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=v0.9.1&shallow=1\";\n};",
                "kixpkgs = {\n  url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=v0.10.0&shallow=1\";\n};",
            ),
        ];
        for (before, after) in cases {
            assert_eq!(moved(before, "0.9.1", "0.10.0"), after);
        }
        let mirror =
            "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1\";";
        assert_eq!(
            moved(mirror, "0.8.0-rc.1", "0.8.2"),
            "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.2\";"
        );
    }

    #[test]
    fn retag_flake_changes_nothing_it_is_not_sure_of() {
        let mirror =
            "url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1\";";
        // Another version, and a shorter or longer prerelease.
        for from in ["0.8.0", "0.8.0-rc", "0.8.0-rc.10"] {
            assert_eq!(retag_flake(mirror, from, "0.8.2"), Retag::NoTag, "{from}");
        }
        // No tag, an input that is not Kix, a comment, and a built string.
        for text in [
            "url = \"github:kix-run/kix\";",
            "url = \"github:NixOS/nixpkgs/v0.9.1\";",
            "# url = \"github:kix-run/kix/v0.9.1\";",
            "url = \"github:kix-run/kix/${tag}\";",
        ] {
            assert_eq!(retag_flake(text, "0.9.1", "0.10.0"), Retag::NoTag, "{text}");
        }
    }

    #[test]
    fn retag_flake_leaves_two_inputs_on_one_tag_to_a_person() {
        // A project that also pins the Kix inside its images.
        let both = "inputs = {\n  kixpkgs = {\n    url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1\";\n  };\n  image-kix = {\n    url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1\";\n  };\n};\n";
        let Retag::ByHand(edit) = retag_flake(both, "0.8.0-rc.1", "0.9.1") else {
            panic!("expected Kix to leave the edit to a person");
        };
        let numbers: Vec<usize> = edit.lines.iter().map(|(n, _)| *n).collect();
        assert_eq!(numbers, [3, 6]);
        assert!(
            edit.lines[0].1.starts_with("url = \"git+ssh://"),
            "{edit:?}"
        );
        assert_eq!(edit.to_tag, "v0.9.1");

        // After the person moved the library's url, Kix changes nothing,
        // and does not move the other input.
        let edited = both.replacen("v0.8.0-rc.1", "v0.9.1", 1);
        assert_eq!(
            retag_flake(&edited, "0.8.0-rc.1", "0.9.1"),
            Retag::AlreadyMoved
        );
        // The next step moves the library on, and still leaves the other.
        let stepped = moved(&edited, "0.9.1", "0.9.2");
        assert!(stepped.contains("image-kix = {\n    url = \"git+ssh://git@git.example:30232/org/kixpkgs.git?ref=refs/tags/v0.8.0-rc.1\""));
        assert_eq!(stepped.matches("v0.9.2").count(), 1);
    }

    #[test]
    fn the_library_input_is_the_one_kix_lib_update_finds() {
        let lock = serde_json::json!({
            "root": "root",
            "nodes": {
                "root": {"inputs": {"kixpkgs": "kixpkgs", "nixpkgs": "nixpkgs"}},
                "nixpkgs": {"original": {"type": "github", "owner": "NixOS", "repo": "nixpkgs"}},
                "kixpkgs": {
                    "locked": {"type": "git", "rev": "abc"},
                    "original": {"type": "git", "url": "ssh://git@git.example:30232/org/kixpkgs.git", "ref": "refs/tags/v0.8.0-rc.1"}
                }
            }
        });
        assert_eq!(
            library_input(&lock, "0.9.1").unwrap(),
            ("kixpkgs".to_string(), Some("v0.8.0-rc.1".to_string()))
        );

        let two = serde_json::json!({
            "root": "root",
            "nodes": {
                "root": {"inputs": {"kix": "kix", "kix-images": "kix_2"}},
                "kix": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.9.1"}},
                "kix_2": {"original": {"type": "github", "owner": "kix-run", "repo": "kix", "ref": "v0.9.1"}}
            }
        });
        assert_eq!(library_input(&two, "0.10.0").unwrap().0, "kix");
    }
}
