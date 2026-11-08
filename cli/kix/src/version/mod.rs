//! Kix versions: the version of the running Kix, and the versions it reads
//! from a project's Kix library, `kix.toml`, the installed copies, and the
//! release index.
//!
//! Every comparison between two of them goes through [`policy`].

pub mod policy;

use std::cmp::Ordering;
use std::fmt;
use std::str::FromStr;
use std::sync::OnceLock;

/// A semantic version such as `0.8.4`, `0.9.0-rc.1`, or `0.8.4+250`.
///
/// Equality and ordering ignore the build metadata after `+`, so a release
/// build `0.8.4+250` is the same release as `0.8.4`.
#[derive(Debug, Clone)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    pub pre: Option<String>,
    pub build: Option<String>,
}

/// The text is not a version.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a version such as 0.8.4")]
pub struct NotAVersion(pub String);

impl Version {
    pub fn new(major: u64, minor: u64, patch: u64) -> Self {
        Self {
            major,
            minor,
            patch,
            pre: None,
            build: None,
        }
    }

    /// Return the release this version names, without build metadata, such
    /// as `0.8.4` for `0.8.4+250`. Messages that name a version use this.
    pub fn release(&self) -> String {
        match &self.pre {
            Some(pre) => format!("{}.{}.{}-{pre}", self.major, self.minor, self.patch),
            None => format!("{}.{}.{}", self.major, self.minor, self.patch),
        }
    }

    /// Return the major and minor version, which together decide which Kix
    /// library this version builds.
    pub fn minor_key(&self) -> (u64, u64) {
        (self.major, self.minor)
    }

    /// Return the minor as text, such as `0.8`.
    pub fn minor_text(&self) -> String {
        format!("{}.{}", self.major, self.minor)
    }
}

impl FromStr for Version {
    type Err = NotAVersion;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bad = || NotAVersion(s.to_string());
        let (rest, build) = match s.split_once('+') {
            Some((rest, build)) => (rest, Some(build)),
            None => (s, None),
        };
        let (core, pre) = match rest.split_once('-') {
            Some((core, pre)) => (core, Some(pre)),
            None => (rest, None),
        };
        let valid_tag = |t: &str| {
            !t.is_empty()
                && t.split('.').all(|part| {
                    !part.is_empty() && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                })
        };
        if pre.is_some_and(|p| !valid_tag(p)) || build.is_some_and(|b| !valid_tag(b)) {
            return Err(bad());
        }
        let parts: Vec<&str> = core.split('.').collect();
        let [major, minor, patch] = parts.as_slice() else {
            return Err(bad());
        };
        let number = |p: &str| {
            if p.is_empty() || !p.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            p.parse::<u64>().ok()
        };
        Ok(Version {
            major: number(major).ok_or_else(bad)?,
            minor: number(minor).ok_or_else(bad)?,
            patch: number(patch).ok_or_else(bad)?,
            pre: pre.map(str::to_string),
            build: build.map(str::to_string),
        })
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.release())?;
        if let Some(build) = &self.build {
            write!(f, "+{build}")?;
        }
        Ok(())
    }
}

impl PartialEq for Version {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for Version {}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch)
            .cmp(&(other.major, other.minor, other.patch))
            .then_with(|| match (&self.pre, &other.pre) {
                (None, None) => Ordering::Equal,
                (Some(_), None) => Ordering::Less,
                (None, Some(_)) => Ordering::Greater,
                (Some(a), Some(b)) => compare_pre(a, b),
            })
    }
}

/// Compare two pre-release tags the way semver does: numeric identifiers
/// numerically, the rest as text, and a shorter tag before a longer one that
/// it starts.
fn compare_pre(a: &str, b: &str) -> Ordering {
    let mut a_parts = a.split('.');
    let mut b_parts = b.split('.');
    loop {
        match (a_parts.next(), b_parts.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) => {
                let order = match (x.parse::<u64>(), y.parse::<u64>()) {
                    (Ok(x), Ok(y)) => x.cmp(&y),
                    (Ok(_), Err(_)) => Ordering::Less,
                    (Err(_), Ok(_)) => Ordering::Greater,
                    (Err(_), Err(_)) => x.cmp(y),
                };
                if order != Ordering::Equal {
                    return order;
                }
            }
        }
    }
}

/// Return the version of the running Kix.
///
/// A release build sets `KIX_VERSION` at compile time to the crate version
/// with the CI run number as build metadata (`0.8.4+250`), so two released
/// binaries with the same crate version still report different versions.
/// Any other build reports the crate version.
pub fn running() -> &'static Version {
    static RUNNING: OnceLock<Version> = OnceLock::new();
    RUNNING.get_or_init(|| {
        crate::VERSION
            .parse()
            .unwrap_or_else(|e| panic!("this build of Kix has a bad version: {e}"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(s: &str) -> Version {
        s.parse().unwrap()
    }

    #[test]
    fn versions_parse() {
        let plain = v("0.8.4");
        assert_eq!((plain.major, plain.minor, plain.patch), (0, 8, 4));
        assert_eq!(plain.pre, None);
        assert_eq!(plain.build, None);

        let built = v("0.8.4+250");
        assert_eq!(built.build.as_deref(), Some("250"));
        assert_eq!(built.to_string(), "0.8.4+250");
        assert_eq!(built.release(), "0.8.4");

        let rc = v("0.9.0-rc.1");
        assert_eq!(rc.pre.as_deref(), Some("rc.1"));
        assert_eq!(rc.release(), "0.9.0-rc.1");
        assert_eq!(v("0.9.0-rc.1+7").release(), "0.9.0-rc.1");

        for bad in [
            "", "main", "0.8", "0.8.4.1", "v0.8.4", "0.8.x", "0.8.4-", "0.8.4+", "0.8.+4",
            " 0.8.4", "0.8.-4",
        ] {
            assert!(bad.parse::<Version>().is_err(), "{bad:?} parsed");
        }
    }

    #[test]
    fn versions_order_and_ignore_build_metadata() {
        assert!(v("0.8.0") < v("0.8.1"));
        assert!(v("0.10.0") > v("0.9.9"));
        assert_eq!(v("0.8.1+250"), v("0.8.1"));
        assert!(v("0.9.0-rc.1") < v("0.9.0"));
        assert!(v("0.9.0-rc.2") < v("0.9.0-rc.10"));
        assert!(v("0.9.0-rc") < v("0.9.0-rc.1"));
        assert!(v("0.8.9") < v("0.9.0-rc.1"));
    }

    #[test]
    fn the_minor_key_drops_the_patch() {
        assert_eq!(v("0.8.4").minor_key(), (0, 8));
        assert_eq!(v("1.2.3-rc.1").minor_text(), "1.2");
    }

    #[test]
    fn the_running_version_parses() {
        assert_eq!(running().release(), env!("CARGO_PKG_VERSION"));
    }
}
