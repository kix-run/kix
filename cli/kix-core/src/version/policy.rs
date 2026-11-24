//! Which release a command asks for, and the comparisons between the running
//! Kix and a project's Kix library.
//!
//! This is the only place that compares the version of Kix with the version
//! of a Kix library. It holds the check after evaluation
//! ([`check_library`]) and the advice for a library that needs a Helm the
//! running Kix does not ship ([`library_next_step`]). A project names its Kix by the release tag its
//! `flake.lock` pins (`crate::flake_lock`), and Kix runs exactly that
//! version, so the library and Kix match by construction. A tag moved by
//! hand in `flake.nix` stops before evaluation (`LockError::TagMoved`). The
//! check after evaluation ([`check_library`]) catches the moves that check
//! cannot find, such as an input written as an attribute set or pointed at
//! another repository. It also holds the rule for which versions
//! `kix upgrade` may move a project to ([`judge_upgrade`]).

use std::fmt;
use std::str::FromStr;

use super::Version;

/// The release a command asks for, such as `kix self install 0.10` or
/// `kix upgrade --to 0.10.3`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Requirement {
    /// The newest release of this major and minor, such as `0.10`.
    Minor(u64, u64),
    /// Exactly this version, such as `0.10.3` or `0.11.0-rc.1`.
    Exact(Version),
}

/// The text is neither a minor nor an exact version.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "{0:?} is not a Kix version. Write a minor such as \"0.8\", an exact version such as \"0.8.3\", or a prerelease such as \"0.9.0-rc.1\""
)]
pub struct BadRequirement(pub String);

impl FromStr for Requirement {
    type Err = BadRequirement;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || BadRequirement(s.to_string());
        // A prerelease is named in full, such as 0.9.0-rc.1. Build metadata
        // names a build, not a release, so a requirement cannot carry it.
        if s.contains('-') {
            return match s.parse::<Version>() {
                Ok(v) if v.is_prerelease() && v.build.is_none() => Ok(Requirement::Exact(v)),
                _ => Err(bad()),
            };
        }
        let numbers = s
            .split('.')
            .map(|p| {
                (!p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
                    .then(|| p.parse::<u64>().ok())
                    .flatten()
            })
            .collect::<Option<Vec<u64>>>()
            .ok_or_else(bad)?;
        match numbers.as_slice() {
            [major, minor] => Ok(Requirement::Minor(*major, *minor)),
            [major, minor, patch] => Ok(Requirement::Exact(Version::new(*major, *minor, *patch))),
            _ => Err(bad()),
        }
    }
}

impl Requirement {
    /// Return the major and minor version this requirement names.
    pub fn minor_key(&self) -> (u64, u64) {
        match self {
            Requirement::Minor(major, minor) => (*major, *minor),
            Requirement::Exact(v) => v.minor_key(),
        }
    }
}

impl fmt::Display for Requirement {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Requirement::Minor(major, minor) => write!(f, "{major}.{minor}"),
            Requirement::Exact(v) => f.write_str(&v.release()),
        }
    }
}

/// Return whether Kix `v` meets `req`.
///
/// A minor never matches a prerelease. A prerelease runs only where a
/// command names it exactly, so trying one never moves anyone else onto it.
pub fn satisfies(req: &Requirement, v: &Version) -> bool {
    match req {
        Requirement::Minor(major, minor) => v.minor_key() == (*major, *minor) && !v.is_prerelease(),
        Requirement::Exact(exact) => v == exact,
    }
}

/// The Kix library a project evaluated is not the version of Kix that runs
/// it. This happens when `flake.nix` moved the library's tag after Kix chose
/// its version from `flake.lock`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryMismatch {
    /// The running Kix.
    pub kix: Version,
    /// The version `flake.lock` pinned when Kix chose which version runs.
    pub pinned: Version,
    /// The version of the library the project evaluated.
    pub library: Version,
}

/// Check that the Kix library a project evaluated, `library`, is Kix `kix`.
/// `pinned` is the version `flake.lock` pinned when Kix chose which version
/// runs. A project in development mode is never checked.
pub fn check_library(
    kix: &Version,
    pinned: &Version,
    library: &Version,
) -> Result<(), Box<LibraryMismatch>> {
    if library == kix {
        return Ok(());
    }
    Err(Box::new(LibraryMismatch {
        kix: kix.clone(),
        pinned: pinned.clone(),
        library: library.clone(),
    }))
}

impl fmt::Display for LibraryMismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let pinned = self.pinned.release();
        if self.pinned == self.kix {
            write!(
                f,
                "flake.lock pins Kix {pinned}, but flake.nix now asks for {}. {}",
                self.library.release(),
                crate::flake_lock::moved_tag_next_step(
                    crate::versions::chosen_input(),
                    &self.pinned,
                    &self.library
                )
            )
        } else {
            write!(
                f,
                "flake.lock pins Kix {pinned}, but this is Kix {}. Unset KIX_SELECTED_BY, so Kix runs {pinned} for this project.",
                self.kix.release()
            )
        }
    }
}

impl std::error::Error for LibraryMismatch {}

/// What Kix knows about the version of a project's Kix library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryVersion {
    Known(Version),
    /// The library predates the version output.
    Older,
    /// Kix could not read the version.
    Unknown,
}

impl LibraryVersion {
    /// Return the version that `text`, the library's `kixLibrary.version`,
    /// names, or [`LibraryVersion::Unknown`] when it names none.
    pub fn parse(text: &str) -> Self {
        text.parse()
            .map_or(LibraryVersion::Unknown, LibraryVersion::Known)
    }
}

/// Return what to do when a project's Kix library, `library`, needs
/// something Kix `kix` does not ship, such as a Helm version. An older
/// library moves to Kix, a newer one needs a newer Kix, and when Kix cannot
/// tell, the advice gives both.
pub fn library_next_step(kix: &Version, library: &LibraryVersion) -> String {
    let release = kix.release();
    let older = match library {
        LibraryVersion::Older => Some(true),
        LibraryVersion::Known(lib) if lib < kix => Some(true),
        LibraryVersion::Known(lib) if lib > kix => Some(false),
        LibraryVersion::Known(_) | LibraryVersion::Unknown => None,
    };
    match (older, library) {
        (Some(true), _) => format!(
            "Run `kix upgrade --to {release}` to move this project to the {release} library, then commit the files it changes."
        ),
        (Some(false), LibraryVersion::Known(lib)) => format!("Upgrade Kix to {}.", lib.release()),
        _ => format!(
            "Run `kix upgrade --to {release}` to move this project to the {release} library and commit the files it changes, or use the version of Kix that matches the library."
        ),
    }
}

/// What `kix upgrade` makes of a target version, by [`judge_upgrade`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpgradeVerdict {
    /// The target is newer than the baseline and not below the pin.
    Proceed,
    /// The target is the version the project is pinned to and the upgrade
    /// started from, so there is nothing to move.
    AlreadyThere,
    /// The target is older than the version the project is pinned to.
    Older,
}

/// Judge `target` for an upgrade of a project that `flake.lock` pins to
/// `pinned`. `baseline` is the version the upgrade builds the project with
/// to compare against: `pinned` on a new run, and the version a stopped run
/// started from when it resumes.
///
/// `kix upgrade` never moves a project below its pin, and moves only to a
/// version newer than its baseline. A resumed run pinned to the step that
/// failed may therefore aim at that same step again.
pub fn judge_upgrade(pinned: &Version, baseline: &Version, target: &Version) -> UpgradeVerdict {
    if target < pinned {
        UpgradeVerdict::Older
    } else if target <= baseline {
        UpgradeVerdict::AlreadyThere
    } else {
        UpgradeVerdict::Proceed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    #[test]
    fn requirements_parse() {
        assert_eq!("0.8".parse(), Ok(Requirement::Minor(0, 8)));
        assert_eq!("0.8.3".parse(), Ok(Requirement::Exact(v("0.8.3"))));
        assert_eq!("0.8".parse::<Requirement>().unwrap().to_string(), "0.8");
        assert_eq!("0.8.3".parse::<Requirement>().unwrap().to_string(), "0.8.3");
        assert_eq!(
            "0.9.0-rc.1".parse(),
            Ok(Requirement::Exact(v("0.9.0-rc.1")))
        );
        assert_eq!(
            "0.9.0-rc.1".parse::<Requirement>().unwrap().to_string(),
            "0.9.0-rc.1"
        );
        for bad in [
            "",
            "0",
            "8",
            "0.8.3.1",
            "0.8.x",
            "v0.8",
            "0.8.3+1",
            "0.9-rc.1",
            "0.9.0-",
            "0.9.0-rc.1+7",
            "0..8",
        ] {
            let err = bad.parse::<Requirement>().unwrap_err().to_string();
            assert!(
                err.contains("\"0.8\"")
                    && err.contains("\"0.8.3\"")
                    && err.contains("\"0.9.0-rc.1\""),
                "{err}"
            );
        }
    }

    #[test]
    fn a_minor_takes_any_patch_and_an_exact_version_one() {
        let minor = Requirement::Minor(0, 8);
        assert!(satisfies(&minor, &v("0.8.0")));
        assert!(satisfies(&minor, &v("0.8.9+250")));
        assert!(!satisfies(&minor, &v("0.9.0")));
        assert!(!satisfies(&minor, &v("1.8.0")));

        let exact = Requirement::Exact(v("0.8.3"));
        assert!(satisfies(&exact, &v("0.8.3")));
        assert!(satisfies(&exact, &v("0.8.3+250")));
        assert!(!satisfies(&exact, &v("0.8.4")));
    }

    #[test]
    fn only_an_exact_requirement_matches_a_prerelease() {
        let rc = v("0.9.0-rc.1");
        assert!(!satisfies(&Requirement::Minor(0, 9), &rc));
        assert!(satisfies(&Requirement::Exact(v("0.9.0-rc.1")), &rc));
        assert!(!satisfies(&Requirement::Exact(v("0.9.0-rc.2")), &rc));
        assert!(!satisfies(&Requirement::Exact(v("0.9.0")), &rc));
    }

    #[test]
    fn the_library_must_be_the_running_kix() {
        let kix = v("0.10.3+250");
        assert_eq!(check_library(&kix, &kix, &v("0.10.3")), Ok(()));
        for library in ["0.10.2", "0.10.4", "0.11.0", "0.10.3-rc.1"] {
            assert!(check_library(&kix, &kix, &v(library)).is_err(), "{library}");
        }
    }

    #[test]
    fn a_library_kix_cannot_serve_names_the_side_to_move() {
        let kix = v("0.8.1+250");
        let step = |library| library_next_step(&kix, &library);
        let update = "Run `kix upgrade --to 0.8.1` to move this project to the 0.8.1 library, then commit the files it changes.";
        assert_eq!(step(LibraryVersion::Known(v("0.8.0"))), update);
        assert_eq!(step(LibraryVersion::Older), update);
        assert_eq!(
            step(LibraryVersion::Known(v("0.8.2"))),
            "Upgrade Kix to 0.8.2."
        );
        for library in [LibraryVersion::Unknown, LibraryVersion::Known(v("0.8.1"))] {
            assert_eq!(
                step(library),
                "Run `kix upgrade --to 0.8.1` to move this project to the 0.8.1 library and commit the files it changes, or use the version of Kix that matches the library."
            );
        }
        assert_eq!(
            LibraryVersion::parse("0.8.0"),
            LibraryVersion::Known(v("0.8.0"))
        );
        assert_eq!(LibraryVersion::parse("dev"), LibraryVersion::Unknown);
    }

    #[test]
    fn a_moved_tag_names_the_upgrade() {
        let kix = v("0.10.3");
        assert_eq!(
            check_library(&kix, &kix, &v("0.10.4"))
                .unwrap_err()
                .to_string(),
            "flake.lock pins Kix 0.10.3, but flake.nix now asks for 0.10.4. Run `kix upgrade --to 0.10.4`."
        );
        assert!(
            check_library(&kix, &kix, &v("0.10.2"))
                .unwrap_err()
                .to_string()
                .starts_with("flake.lock pins Kix 0.10.3, but flake.nix now asks for 0.10.2. `kix upgrade` only moves a project to a newer version of Kix.")
        );
        assert_eq!(
            check_library(&kix, &v("0.10.1"), &v("0.10.1"))
                .unwrap_err()
                .to_string(),
            "flake.lock pins Kix 0.10.1, but this is Kix 0.10.3. Unset KIX_SELECTED_BY, so Kix runs 0.10.1 for this project."
        );
    }

    #[test]
    fn an_upgrade_never_goes_below_the_pin_and_always_past_the_baseline() {
        let v = |t: &str| t.parse::<Version>().unwrap();
        let judge = |pinned: &str, baseline: &str, target: &str| {
            judge_upgrade(&v(pinned), &v(baseline), &v(target))
        };
        // A new run: the pin is the baseline.
        assert_eq!(judge("0.9.2", "0.9.2", "0.10.0"), UpgradeVerdict::Proceed);
        assert_eq!(
            judge("0.9.2", "0.9.2", "0.9.2"),
            UpgradeVerdict::AlreadyThere
        );
        assert_eq!(judge("0.9.2", "0.9.2", "0.9.1"), UpgradeVerdict::Older);
        assert_eq!(
            judge("0.10.0-rc.4", "0.10.0-rc.4", "0.9.2"),
            UpgradeVerdict::Older
        );
        assert_eq!(
            judge("0.10.0-rc.4", "0.10.0-rc.4", "0.10.0"),
            UpgradeVerdict::Proceed
        );
        // A resumed run pinned to the step that failed builds it again.
        assert_eq!(
            judge("0.10.0-rc.4", "0.9.2", "0.10.0-rc.4"),
            UpgradeVerdict::Proceed
        );
        assert_eq!(
            judge("0.10.0-rc.4", "0.9.2", "0.9.2"),
            UpgradeVerdict::Older
        );
        // A resumed run that pinned nothing yet has nowhere to go at its
        // baseline.
        assert_eq!(
            judge("0.9.2", "0.9.2", "0.9.2"),
            UpgradeVerdict::AlreadyThere
        );
    }
}
