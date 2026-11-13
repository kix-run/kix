//! Which Kix a project needs, and which Kix library a Kix can build.
//!
//! This is the only place that compares the version of Kix with the version
//! of a Kix library or with a project's `kix` setting. Before 1.0, Kix and the
//! library must have the same minor, and Kix's patch must be at least the
//! library's, because a patch release may add a Helm version and never
//! removes one. The change at 1.0, where a newer Kix builds older libraries
//! back to a cutoff, happens here and in the `specVersion` the library writes
//! into chart fetch specs (`fetchSpec` in `kix/lib/helm.nix`).

use std::fmt;
use std::str::FromStr;

use super::Version;

/// The first minor release of Kix that reads the `kix` setting in
/// `kix.toml`. Kix 0.7 and older refuse a `kix.toml` that sets it, so a
/// project cannot ask for one of them.
pub const FIRST_SELECTING: (u64, u64) = (0, 8);

/// The Kix a project asks for with `kix` in `kix.toml`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Requirement {
    /// Any Kix of this major and minor, such as `kix = "0.8"`.
    Minor(u64, u64),
    /// Exactly this version, such as `kix = "0.8.3"` or
    /// `kix = "0.9.0-rc.1"`.
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

    /// Return whether the Kix this requirement names reads the `kix` setting
    /// ([`FIRST_SELECTING`]).
    pub fn reads_kix_setting(&self) -> bool {
        self.minor_key() >= FIRST_SELECTING
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
/// project or a command names it exactly, so trying one never moves anyone
/// else onto it.
pub fn satisfies(req: &Requirement, v: &Version) -> bool {
    match req {
        Requirement::Minor(major, minor) => v.minor_key() == (*major, *minor) && !v.is_prerelease(),
        Requirement::Exact(exact) => v == exact,
    }
}

/// Return the version among `installed` that a project asking for `req`
/// runs: the newest patch of the minor, or the exact version.
pub fn choose(req: &Requirement, installed: &[Version]) -> Option<Version> {
    installed
        .iter()
        .filter(|v| satisfies(req, v))
        .max()
        .cloned()
}

/// Why a Kix cannot build a Kix library.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Incompatible {
    /// The library's minor is newer than Kix's.
    LibraryNewerMinor,
    /// The library's minor is older than Kix's.
    LibraryOlderMinor,
    /// The minors agree, and the library is newer than Kix: a newer patch,
    /// or the release that follows Kix's prerelease.
    LibraryNewerPatch,
}

/// Check that Kix `kix` can build a project whose Kix library is `library`.
pub fn library_compatible(kix: &Version, library: &Version) -> Result<(), Incompatible> {
    match library.minor_key().cmp(&kix.minor_key()) {
        std::cmp::Ordering::Greater => Err(Incompatible::LibraryNewerMinor),
        std::cmp::Ordering::Less => Err(Incompatible::LibraryOlderMinor),
        // Version ordering ignores build metadata, and puts a prerelease
        // before its release, which may add Helm versions the prerelease
        // lacks.
        std::cmp::Ordering::Equal if library > kix => Err(Incompatible::LibraryNewerPatch),
        std::cmp::Ordering::Equal => Ok(()),
    }
}

/// A project's Kix library that the running Kix cannot build, with the fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryIncompatible {
    pub kix: Version,
    pub library: Version,
    pub reason: Incompatible,
    /// The project's `kix` setting in `kix.toml`, if it has one. The fix
    /// depends on it, because Kix chooses a version only from that setting.
    pub requirement: Option<Requirement>,
}

impl fmt::Display for LibraryIncompatible {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let lib = self.library.release();
        let kix = self.kix.release();
        // A minor never matches a prerelease, so a project on a prerelease
        // library has to name that prerelease.
        let lib_minor = if self.library.is_prerelease() {
            lib.clone()
        } else {
            self.library.minor_text()
        };
        match self.reason {
            Incompatible::LibraryOlderMinor => {
                write!(
                    f,
                    "This project's Kix library is {lib}, but this is Kix {kix}. Run `kix lib update` to move the project to the {kix} library and commit flake.lock."
                )?;
                if self.library.minor_key() >= FIRST_SELECTING {
                    write!(
                        f,
                        " To keep this project on Kix {lib_minor} instead, set kix = \"{lib_minor}\" in kix.toml."
                    )?;
                }
                Ok(())
            }
            Incompatible::LibraryNewerMinor => {
                if let Some(req) = &self.requirement
                    && req.minor_key() != self.library.minor_key()
                {
                    write!(
                        f,
                        "kix.toml asks for Kix {req}, but flake.lock has the {lib} library. "
                    )?;
                }
                write!(
                    f,
                    "This project's Kix library is {lib}, but this is Kix {kix}. Set kix = \"{lib_minor}\" in kix.toml so Kix runs {lib_minor} for this project."
                )
            }
            // Selection runs the newest installed patch of the minor a
            // project names, so installing one is enough. An exact version
            // has to be raised, and without a setting the Kix on PATH runs.
            Incompatible::LibraryNewerPatch => {
                write!(
                    f,
                    "This project's Kix library is {lib}, which needs Kix {lib} or newer, and this is Kix {kix}. "
                )?;
                match &self.requirement {
                    _ if self.library.is_prerelease() => write!(
                        f,
                        "Set kix = \"{lib}\" in kix.toml so Kix installs and runs {lib} for this project."
                    ),
                    Some(Requirement::Minor(major, minor)) => write!(
                        f,
                        "Run `kix self install {major}.{minor}`, and Kix runs the new version for this project."
                    ),
                    Some(Requirement::Exact(_)) => write!(
                        f,
                        "Set kix = \"{lib}\" in kix.toml so Kix installs and runs {lib} for this project."
                    ),
                    None => write!(f, "Run `kix self upgrade`."),
                }
            }
        }
    }
}

impl std::error::Error for LibraryIncompatible {}

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
        let installed = [v("0.9.0-rc.1"), v("0.9.0-rc.2")];
        assert_eq!(choose(&Requirement::Minor(0, 9), &installed), None);
        assert_eq!(
            choose(&Requirement::Exact(v("0.9.0-rc.1")), &installed),
            Some(v("0.9.0-rc.1"))
        );
    }

    #[test]
    fn choose_takes_the_newest_patch_or_the_exact_version() {
        let installed = [v("0.8.4"), v("0.8.6"), v("0.9.0"), v("0.7.9")];
        assert_eq!(
            choose(&Requirement::Minor(0, 8), &installed),
            Some(v("0.8.6"))
        );
        assert_eq!(
            choose(&Requirement::Exact(v("0.8.4")), &installed),
            Some(v("0.8.4"))
        );
        assert_eq!(choose(&Requirement::Exact(v("0.8.5")), &installed), None);
        assert_eq!(choose(&Requirement::Minor(0, 10), &installed), None);
    }

    #[test]
    fn a_library_must_share_the_minor_and_not_be_newer() {
        let kix = v("0.8.4+250");
        assert_eq!(library_compatible(&kix, &v("0.8.4")), Ok(()));
        assert_eq!(library_compatible(&kix, &v("0.8.0")), Ok(()));
        assert_eq!(
            library_compatible(&kix, &v("0.8.5")),
            Err(Incompatible::LibraryNewerPatch)
        );
        assert_eq!(
            library_compatible(&kix, &v("0.9.0")),
            Err(Incompatible::LibraryNewerMinor)
        );
        assert_eq!(
            library_compatible(&kix, &v("0.7.9")),
            Err(Incompatible::LibraryOlderMinor)
        );
        assert_eq!(
            library_compatible(&kix, &v("1.8.0")),
            Err(Incompatible::LibraryNewerMinor)
        );
    }

    #[test]
    fn a_prerelease_builds_its_own_library_and_older_ones() {
        let rc = v("0.9.0-rc.2+31");
        assert_eq!(library_compatible(&rc, &v("0.9.0-rc.2")), Ok(()));
        assert_eq!(library_compatible(&rc, &v("0.9.0-rc.1")), Ok(()));
        assert_eq!(
            library_compatible(&rc, &v("0.9.0")),
            Err(Incompatible::LibraryNewerPatch)
        );
        assert_eq!(
            library_compatible(&rc, &v("0.9.0-rc.3")),
            Err(Incompatible::LibraryNewerPatch)
        );
        assert_eq!(library_compatible(&v("0.9.0"), &v("0.9.0-rc.2")), Ok(()));
    }

    #[test]
    fn a_prerelease_library_is_named_exactly() {
        assert_eq!(
            message("0.8.3", "0.9.0-rc.1", Incompatible::LibraryNewerMinor, None),
            "This project's Kix library is 0.9.0-rc.1, but this is Kix 0.8.3. Set kix = \"0.9.0-rc.1\" in kix.toml so Kix runs 0.9.0-rc.1 for this project."
        );
        assert_eq!(
            message(
                "0.9.0",
                "0.9.1-rc.1",
                Incompatible::LibraryNewerPatch,
                Some("0.9")
            ),
            "This project's Kix library is 0.9.1-rc.1, which needs Kix 0.9.1-rc.1 or newer, and this is Kix 0.9.0. Set kix = \"0.9.1-rc.1\" in kix.toml so Kix installs and runs 0.9.1-rc.1 for this project."
        );
        assert_eq!(
            message(
                "0.10.0",
                "0.9.0-rc.1",
                Incompatible::LibraryOlderMinor,
                None
            ),
            "This project's Kix library is 0.9.0-rc.1, but this is Kix 0.10.0. Run `kix lib update` to move the project to the 0.10.0 library and commit flake.lock. To keep this project on Kix 0.9.0-rc.1 instead, set kix = \"0.9.0-rc.1\" in kix.toml."
        );
    }

    fn message(kix: &str, library: &str, reason: Incompatible, req: Option<&str>) -> String {
        LibraryIncompatible {
            kix: v(kix),
            library: v(library),
            reason,
            requirement: req.map(|r| r.parse().unwrap()),
        }
        .to_string()
    }

    #[test]
    fn an_older_library_names_lib_update_and_a_selectable_minor() {
        assert_eq!(
            message("0.8.1", "0.7.0", Incompatible::LibraryOlderMinor, None),
            "This project's Kix library is 0.7.0, but this is Kix 0.8.1. Run `kix lib update` to move the project to the 0.8.1 library and commit flake.lock."
        );
        assert_eq!(
            message(
                "0.9.1+12",
                "0.8.0",
                Incompatible::LibraryOlderMinor,
                Some("0.9")
            ),
            "This project's Kix library is 0.8.0, but this is Kix 0.9.1. Run `kix lib update` to move the project to the 0.9.1 library and commit flake.lock. To keep this project on Kix 0.8 instead, set kix = \"0.8\" in kix.toml."
        );
    }

    #[test]
    fn a_newer_library_minor_names_the_kix_setting() {
        assert_eq!(
            message("0.8.1", "0.9.0", Incompatible::LibraryNewerMinor, None),
            "This project's Kix library is 0.9.0, but this is Kix 0.8.1. Set kix = \"0.9\" in kix.toml so Kix runs 0.9 for this project."
        );
        assert_eq!(
            message(
                "0.8.1",
                "0.9.0",
                Incompatible::LibraryNewerMinor,
                Some("0.8")
            ),
            "kix.toml asks for Kix 0.8, but flake.lock has the 0.9.0 library. This project's Kix library is 0.9.0, but this is Kix 0.8.1. Set kix = \"0.9\" in kix.toml so Kix runs 0.9 for this project."
        );
        assert_eq!(
            message(
                "0.8.1",
                "0.9.0",
                Incompatible::LibraryNewerMinor,
                Some("0.9")
            ),
            message("0.8.1", "0.9.0", Incompatible::LibraryNewerMinor, None)
        );
    }

    #[test]
    fn a_newer_library_patch_names_an_exact_version() {
        assert_eq!(
            message(
                "0.8.1",
                "0.8.3",
                Incompatible::LibraryNewerPatch,
                Some("0.8")
            ),
            "This project's Kix library is 0.8.3, which needs Kix 0.8.3 or newer, and this is Kix 0.8.1. Run `kix self install 0.8`, and Kix runs the new version for this project."
        );
        assert_eq!(
            message(
                "0.8.1",
                "0.8.3",
                Incompatible::LibraryNewerPatch,
                Some("0.8.1")
            ),
            "This project's Kix library is 0.8.3, which needs Kix 0.8.3 or newer, and this is Kix 0.8.1. Set kix = \"0.8.3\" in kix.toml so Kix installs and runs 0.8.3 for this project."
        );
        assert_eq!(
            message("0.8.1", "0.8.3", Incompatible::LibraryNewerPatch, None),
            "This project's Kix library is 0.8.3, which needs Kix 0.8.3 or newer, and this is Kix 0.8.1. Run `kix self upgrade`."
        );
    }

    #[test]
    fn only_kix_0_8_and_newer_read_the_setting() {
        assert!(!Requirement::Minor(0, 7).reads_kix_setting());
        assert!(!Requirement::Exact(v("0.7.9")).reads_kix_setting());
        assert!(Requirement::Minor(0, 8).reads_kix_setting());
        assert!(Requirement::Exact(v("1.0.0")).reads_kix_setting());
    }
}
