//! Pin a project to a version of Kix: the exact version in `kix.toml`, and
//! the Kix library in `flake.nix` and `flake.lock` through
//! [`kix::pin_library`].

use std::path::Path;

use kix::pin_library::{HandEdit, PinLibraryError, Plan};
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

/// Why Kix could not pin the project. Each message is ready to print and
/// ends with a `Next:` line.
#[derive(Debug)]
pub enum PinError {
    /// Nix could not move `flake.lock`. Kix tried to put the files back.
    Lock(String),
    /// A person must change a file. Kix changed nothing, or put it back.
    ByHand(String),
    /// More than one url in `flake.nix` names the tag. Kix changed nothing.
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

/// Work out how to move the Kix library of the project in `dir` to
/// `version`, before Kix installs that version or changes a file. Return
/// `None` when the project has no `flake.nix`, so only `kix.toml` moves.
pub fn prepare(dir: &Path, current: &Version, version: &Version) -> Result<Option<Plan>, PinError> {
    if !dir.join("flake.nix").is_file() {
        return Ok(None);
    }
    crate::commands::select_builder_for(dir)?;
    kix::runtime::runtime().map_err(|e| e.to_string())?;
    match kix::pin_library::plan(dir, version) {
        Ok(plan) => Ok(Some(plan)),
        Err(PinLibraryError::Edit(edit)) => Err(PinError::Edit(edit)),
        Err(e @ PinLibraryError::Read(_)) => {
            Err(PinError::Lock(lock_failed(&e, version, "", None)))
        }
        Err(e) => Err(PinError::ByHand(format!(
            "{e}\nkix.toml, flake.nix, and flake.lock remain at Kix {}.\nNext: make that change, then run `kix upgrade` again.",
            current.release()
        ))),
    }
}

/// Return the message for a Nix command that failed while Kix moved the
/// project to `version`, followed by `restored` and the next step.
fn lock_failed(
    error: &PinLibraryError,
    version: &Version,
    restored: &str,
    tag: Option<&str>,
) -> String {
    let lines: Vec<String> = match error.nix_output() {
        // Nix prints its command line and a trace before the one line
        // that says what went wrong.
        Some(output) => super::out::excerpt(output),
        None => vec![error.to_string()],
    };
    let detail: String = lines.iter().map(|l| format!("  {l}\n")).collect();
    let release = version.release();
    let head = match tag {
        Some(tag) => format!("Cannot lock Kix library tag {tag} for Kix {release}:\n{detail}\n"),
        None => format!("Cannot read the inputs of flake.nix:\n{detail}\n"),
    };
    let next = match tag {
        Some(tag) => format!(
            "Next: check that tag {tag} is reachable in your Kix input repository, then run `kix upgrade` again."
        ),
        None => "Next: fix the error above, then run `kix upgrade` again.".to_string(),
    };
    format!("{head}{restored}{next}")
}

/// Pin the project in `dir`, now pinned to `current`, to `version`: set
/// `kix` in `kix.toml`, and move the Kix library as `plan` says. Return the
/// name of each file Kix changed. When moving the library fails, put
/// `kix.toml`, `flake.nix`, and `flake.lock` back.
pub fn pin(
    dir: &Path,
    current: &Version,
    version: &Version,
    plan: Option<&Plan>,
) -> Result<Vec<&'static str>, PinError> {
    let release = version.release();
    let pinned = current.release();
    let path = dir.join(kix::project::FILE);
    let old = match std::fs::read_to_string(&path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("could not read {}: {e}", path.display()).into()),
    };
    let text = old.clone().unwrap_or_default();
    let new = set_kix(&text, &release).map_err(|_| {
        PinError::ByHand(format!(
            "Cannot update the `kix` version field in kix.toml automatically.\nkix.toml, flake.nix, and flake.lock remain at Kix {pinned}.\nNext: set `kix = \"{release}\"` on a single line in kix.toml, then run `kix upgrade` again."
        ))
    })?;
    let mut notes = Vec::new();
    if new != text {
        std::fs::write(&path, &new)
            .map_err(|e| format!("could not write {}: {e}", path.display()))?;
        notes.push("kix.toml");
    }
    let Some(plan) = plan else {
        return Ok(notes);
    };
    let restore_toml = || match &old {
        Some(text) => std::fs::write(&path, text).is_ok(),
        None => std::fs::remove_file(&path).is_ok(),
    };
    match plan.apply(false) {
        Ok(done) => {
            notes.extend(done.changed);
            Ok(notes)
        }
        Err(e) => {
            let tag = format!("v{release}");
            let restored = if restore_toml() {
                format!("Restored kix.toml, flake.nix, and flake.lock to Kix {pinned}.\n")
            } else {
                format!(
                    "Could not restore kix.toml to Kix {pinned} automatically. Run `git checkout -- kix.toml`.\n"
                )
            };
            match e {
                PinLibraryError::Lock { .. } => Err(PinError::Lock(lock_failed(
                    &e,
                    version,
                    &restored,
                    Some(&tag),
                ))),
                e => Err(PinError::ByHand(format!(
                    "{e}\n{restored}Next: make that change, then run `kix upgrade` again."
                ))),
            }
        }
    }
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
    fn without_flake_nix_only_kix_toml_moves() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        std::fs::write(d.join("kix.toml"), "kix = \"0.9.1\"\n").unwrap();
        let current = "0.9.1".parse().unwrap();
        let target = "0.10.0".parse().unwrap();
        let plan = prepare(d, &current, &target).unwrap();
        assert!(plan.is_none());
        assert_eq!(pin(d, &current, &target, None).unwrap(), ["kix.toml"]);
        assert_eq!(
            std::fs::read_to_string(d.join("kix.toml")).unwrap(),
            "kix = \"0.10.0\"\n"
        );
    }
}
