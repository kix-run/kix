//! The Kix library a project pins in its `flake.lock`, and the Helm versions
//! it needs.
//!
//! The library names the exact Helm versions it renders charts with, and a
//! version of Kix ships exactly those versions. When the two disagree, Kix stops
//! before it renders and says which side to move ([`HelmMismatch`]).
//! [`crate::pin_library`] moves the project's side.

use std::cmp::Ordering;
use std::fmt;
use std::path::Path;

use serde_json::Value;

use crate::eval::nix::{NixCommandError, command, current_system, output};
use crate::runtime::Tool;
use crate::version::Version;

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
    match try_eval_version(flake_dir, input_overrides) {
        Ok(version) => version,
        Err(e) => {
            tracing::debug!(error = %e, "could not evaluate the Kix library version");
            LibraryVersion::Unknown
        }
    }
}

/// Evaluate the release of the Kix library the flake in `flake_dir` uses,
/// without writing `flake.lock`. Each pair in `input_overrides` replaces an
/// input for this evaluation only. Return [`LibraryVersion::Older`] for a
/// library without the version output, and the Nix error when the
/// evaluation fails for another reason.
pub fn try_eval_version(
    flake_dir: &Path,
    input_overrides: &[(String, String)],
) -> Result<LibraryVersion, NixCommandError> {
    let mut cmd = command(Tool::Nix)?;
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
            Ok(Value::String(v)) => Ok(LibraryVersion::Known(v)),
            _ => Ok(LibraryVersion::Unknown),
        },
        Err(e) if e.missing_attribute() => Ok(LibraryVersion::Older),
        Err(e) => Err(e),
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
                "Run `kix upgrade --to {program}` to move this project to the {program} library, then commit the files it changes."
            ),
            _ => write!(
                f,
                "Run `kix upgrade --to {program}` to move this project to the {program} library and commit the files it changes, or use the version of Kix that matches the library."
            ),
        }
    }
}

impl std::error::Error for HelmMismatch {}

#[cfg(test)]
mod tests {
    use super::*;

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
            "This project's Kix library is 0.8.0 and renders Helm charts with Helm 4.3.1, but Kix is 0.8.1 and ships Helm 4.3.2. Run `kix upgrade --to 0.8.1` to move this project to the 0.8.1 library, then commit the files it changes."
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
            assert!(text.contains("Run `kix upgrade --to 0.8.1`"), "{text}");
            assert!(text.contains("or use the version of Kix"), "{text}");
        }
    }

    #[test]
    fn a_missing_major_lists_every_shipped_helm() {
        let m = mismatch(LibraryVersion::Unknown, "5.0.0", "0.8.1");
        assert!(m.to_string().contains("ships Helm 3.19.1 and 4.3.2."));
    }
}
