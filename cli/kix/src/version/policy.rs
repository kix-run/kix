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

/// The Kix a project asks for with `kix` in `kix.toml`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Requirement {
    /// Any Kix of this major and minor, such as `kix = "0.8"`.
    Minor(u64, u64),
    /// Exactly this version, such as `kix = "0.8.3"`.
    Exact(Version),
}

/// The text is neither a minor nor an exact version.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "{0:?} is not a Kix version. Write a minor such as \"0.8\", or an exact version such as \"0.8.3\""
)]
pub struct BadRequirement(pub String);

impl FromStr for Requirement {
    type Err = BadRequirement;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || BadRequirement(s.to_string());
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

impl fmt::Display for Requirement {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Requirement::Minor(major, minor) => write!(f, "{major}.{minor}"),
            Requirement::Exact(v) => f.write_str(&v.release()),
        }
    }
}

/// Return whether Kix `v` meets `req`.
pub fn satisfies(req: &Requirement, v: &Version) -> bool {
    match req {
        Requirement::Minor(major, minor) => v.minor_key() == (*major, *minor),
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
    /// The minors agree, and the library's patch is newer than Kix's.
    LibraryNewerPatch,
}

/// Check that Kix `kix` can build a project whose Kix library is `library`.
pub fn library_compatible(kix: &Version, library: &Version) -> Result<(), Incompatible> {
    match library.minor_key().cmp(&kix.minor_key()) {
        std::cmp::Ordering::Greater => Err(Incompatible::LibraryNewerMinor),
        std::cmp::Ordering::Less => Err(Incompatible::LibraryOlderMinor),
        std::cmp::Ordering::Equal if library.patch > kix.patch => {
            Err(Incompatible::LibraryNewerPatch)
        }
        std::cmp::Ordering::Equal => Ok(()),
    }
}

/// A project's Kix library that the running Kix cannot build, with the fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryIncompatible {
    pub kix: Version,
    pub library: Version,
    pub reason: Incompatible,
}

impl fmt::Display for LibraryIncompatible {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let lib = self.library.release();
        let kix = self.kix.release();
        let lib_minor = self.library.minor_text();
        let kix_minor = self.kix.minor_text();
        write!(f, "This project's Kix library is {lib}, but Kix is {kix}. ")?;
        match self.reason {
            Incompatible::LibraryNewerMinor => write!(
                f,
                "Kix {kix_minor} cannot build a {lib_minor} library. Run `kix self install {lib_minor}`, or set kix = \"{lib_minor}\" in kix.toml so Kix picks that version for this project."
            ),
            Incompatible::LibraryOlderMinor => write!(
                f,
                "Run `kix lib update` to move the project to the {kix} library and commit flake.lock, or run `kix self install {lib_minor}` to use the Kix that matches the library."
            ),
            Incompatible::LibraryNewerPatch => write!(
                f,
                "A {lib_minor} library needs Kix {lib} or newer. Run `kix self install {lib_minor}`."
            ),
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
        for bad in [
            "",
            "0",
            "8",
            "0.8.3.1",
            "0.8.x",
            "v0.8",
            "0.8.3+1",
            "0.9.0-rc.1",
            "0..8",
        ] {
            let err = bad.parse::<Requirement>().unwrap_err().to_string();
            assert!(
                err.contains("\"0.8\"") && err.contains("\"0.8.3\""),
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

    fn message(kix: &str, library: &str, reason: Incompatible) -> String {
        LibraryIncompatible {
            kix: v(kix),
            library: v(library),
            reason,
        }
        .to_string()
    }

    #[test]
    fn each_incompatibility_names_its_fix() {
        assert_eq!(
            message("0.7.0+12", "0.8.1", Incompatible::LibraryNewerMinor),
            "This project's Kix library is 0.8.1, but Kix is 0.7.0. Kix 0.7 cannot build a 0.8 library. Run `kix self install 0.8`, or set kix = \"0.8\" in kix.toml so Kix picks that version for this project."
        );
        assert_eq!(
            message("0.8.4", "0.7.2", Incompatible::LibraryOlderMinor),
            "This project's Kix library is 0.7.2, but Kix is 0.8.4. Run `kix lib update` to move the project to the 0.8.4 library and commit flake.lock, or run `kix self install 0.7` to use the Kix that matches the library."
        );
        assert_eq!(
            message("0.8.4", "0.8.6", Incompatible::LibraryNewerPatch),
            "This project's Kix library is 0.8.6, but Kix is 0.8.4. A 0.8 library needs Kix 0.8.6 or newer. Run `kix self install 0.8`."
        );
    }
}
