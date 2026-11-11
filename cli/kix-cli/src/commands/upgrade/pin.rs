//! Pin a project to a version of Kix: the exact version in `kix.toml`, the
//! release tag in `flake.nix` when the library input names one, and the
//! library in `flake.lock`.

use std::path::Path;

use kix::version::Version;

/// Return `text`, a `kix.toml`, with its `kix` setting set to `version`.
/// The setting is added at the top when the file has none.
pub fn set_kix(text: &str, version: &str) -> String {
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
            out.push(line.clone());
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
    joined
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
    /// Kix cannot tell which url to change. The text names the lines.
    ByHand(String),
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
            let lines: Vec<String> = many
                .iter()
                .map(|(start, _)| (text[..*start].matches('\n').count() + 1).to_string())
                .collect();
            Retag::ByHand(format!(
                "flake.nix names the tag v{from} on lines {}, and Kix cannot tell which one is the Kix library. Change the library's url to v{to}, leave the others, then run `kix upgrade` again.",
                lines.join(" and ")
            ))
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
        .map(|key| &lock["nodes"][key]["original"]);
    let tag = node
        .and_then(|o| o["ref"].as_str())
        .map(|r| r.strip_prefix("refs/tags/").unwrap_or(r).to_string())
        .filter(|r| r.starts_with('v') && r[1..].starts_with(|c: char| c.is_ascii_digit()));
    Ok((name, tag))
}

/// Why Kix could not pin the project.
#[derive(Debug)]
pub enum PinError {
    /// Nix could not move `flake.lock`. Kix put the project's files back.
    Lock(String),
    /// `flake.nix` needs an edit Kix cannot make. Kix changed nothing.
    ByHand(String),
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

/// Pin the project in `dir`, now pinned to `current`, to `version`. Return
/// a note for each file Kix changed. When moving `flake.lock` fails, put
/// `kix.toml`, `flake.nix`, and `flake.lock` back.
pub fn pin(dir: &Path, current: &Version, version: &Version) -> Result<Vec<String>, PinError> {
    let release = version.release();
    let mut notes = Vec::new();
    let toml = Saved::take(dir.join(kix::project::FILE))?;
    let flake = Saved::take(dir.join("flake.nix"))?;
    let lock = Saved::take(dir.join("flake.lock"))?;

    // Work out the flake.nix edit before writing anything.
    let mut new_flake = None;
    let mut hand_edited = false;
    if let (Some(lock_text), Some(flake_text)) = (&lock.1, &flake.1) {
        let parsed: serde_json::Value = serde_json::from_str(lock_text)
            .map_err(|e| format!("could not read {}: {e}", lock.0.display()))?;
        // Touch flake.nix only when the lock says the library is pinned to
        // the tag the project uses now. An unpinned library moves in the
        // lock alone.
        let locked_tag = library_input(&parsed, &release)
            .ok()
            .and_then(|(_, tag)| tag);
        if locked_tag.is_some_and(|t| t == format!("v{}", current.release())) {
            match retag_flake(flake_text, &current.release(), &release) {
                Retag::Moved(text) => new_flake = Some(text),
                Retag::AlreadyMoved => hand_edited = true,
                Retag::NoTag => {}
                Retag::ByHand(message) => return Err(PinError::ByHand(message)),
            }
        }
    }

    let old = toml.1.clone().unwrap_or_default();
    let new = set_kix(&old, &release);
    if new != old {
        std::fs::write(&toml.0, new)
            .map_err(|e| format!("could not write {}: {e}", toml.0.display()))?;
        notes.push(format!("kix.toml: kix = \"{release}\""));
    }
    if let Some(text) = &new_flake {
        std::fs::write(&flake.0, text)
            .map_err(|e| format!("could not write {}: {e}", flake.0.display()))?;
        notes.push(format!("flake.nix: the Kix library input names v{release}"));
    }
    if lock.1.is_none() {
        return Ok(notes);
    }

    let moved = (|| -> Result<bool, String> {
        crate::commands::select_builder_for(dir)?;
        kix::runtime::runtime().map_err(|e| e.to_string())?;
        if new_flake.is_some() || hand_edited {
            // The changed url is enough for Nix to lock the new tag.
            kix::library::lock(dir, &release).map_err(|e| e.to_string())?;
            return Ok(true);
        }
        kix::library::update_to(&dir.display().to_string(), &release, false)
            .map(|u| u.changed)
            .map_err(|e| e.to_string())
    })();
    match moved {
        Ok(changed) => {
            if changed {
                notes.push(format!("flake.lock: the Kix library is {release}"));
            }
            Ok(notes)
        }
        Err(e) => {
            let restored = toml
                .restore()
                .and_then(|()| flake.restore())
                .and_then(|()| lock.restore());
            let mut message = format!(
                "Kix could not move the Kix library to the tag v{release}. Check that the repository the library input names has that tag. Kix put kix.toml, flake.nix, and flake.lock back as they were.\n{e}"
            );
            if let Err(io) = restored {
                message.push_str(&format!(
                    "\nKix could not put the files back: {io}. Restore kix.toml, flake.nix, and flake.lock with git."
                ));
            }
            Err(PinError::Lock(message))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_kix_replaces_or_adds_the_setting() {
        assert_eq!(set_kix("", "0.10.1"), "kix = \"0.10.1\"\n");
        assert_eq!(
            set_kix("builder = \"nix\"\nkix = \"0.9\"\n", "0.10.1"),
            "builder = \"nix\"\nkix = \"0.10.1\"\n"
        );
        assert_eq!(
            set_kix(
                "# project\nbuilder = \"kix\"\n\n[upgrade]\nmin-age = \"7d\"\n",
                "0.10.1"
            ),
            "kix = \"0.10.1\"\n# project\nbuilder = \"kix\"\n\n[upgrade]\nmin-age = \"7d\"\n"
        );
        assert_eq!(
            set_kix("kixx = 1\nkix=\"0.9.0\"\n", "1.0.0"),
            "kixx = 1\nkix = \"1.0.0\"\n"
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
        let Retag::ByHand(message) = retag_flake(both, "0.8.0-rc.1", "0.9.1") else {
            panic!("expected Kix to leave the edit to a person");
        };
        assert!(message.contains("lines 3 and 6"), "{message}");
        assert!(message.contains("v0.9.1"), "{message}");

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
