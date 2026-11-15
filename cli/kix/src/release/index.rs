//! The release index the site serves at `/releases/index.json`.
//!
//! The site build writes it (`web/scripts/release-index.mjs`) and lists only
//! the releases that have a signed `SHA256SUMS`:
//!
//! ```json
//! {
//!   "schema": "kix.run/releases/v1",
//!   "generated": "2026-11-08T12:00:00Z",
//!   "latest": "0.8.4",
//!   "releases": [
//!     {
//!       "version": "0.8.4",
//!       "date": "2026-11-07",
//!       "systems": ["x86_64-linux", "aarch64-linux", "aarch64-darwin"],
//!       "sums": "/releases/v0.8.4/SHA256SUMS",
//!       "signature": "/releases/v0.8.4/SHA256SUMS.sig",
//!       "download": "/download/0.8.4/"
//!     }
//!   ]
//! }
//! ```
//!
//! A prerelease, such as `0.9.0-rc.1`, also has `"prerelease": true` and is
//! never `latest`. Kix tells a prerelease by its version, so it does not read
//! that field.
//!
//! An archive's path is `download` followed by `kix-<system>.tar.gz`. Kix
//! skips fields it does not know and releases whose version it cannot parse,
//! so a newer site can add to the index without breaking an older Kix. The
//! index is not signed. It decides which release Kix fetches, and the signed
//! `SHA256SUMS` decides whether Kix installs it.

use serde::Deserialize;

use crate::version::Version;
use crate::version::policy::{Requirement, satisfies};

/// The path of the index on the site.
pub const PATH: &str = "/releases/index.json";

/// The release index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Index {
    pub latest: Option<String>,
    pub releases: Vec<Release>,
}

/// One release in the index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub version: Version,
    pub systems: Vec<String>,
    /// The site path of `SHA256SUMS`.
    pub sums: String,
    /// The site path of `SHA256SUMS.sig`.
    pub signature: Option<String>,
    /// The site path the archive names are appended to.
    pub download: String,
    /// The release date, `YYYY-MM-DD`, as the index gives it.
    pub date: Option<String>,
}

#[derive(Deserialize)]
struct RawIndex {
    #[serde(default)]
    latest: Option<String>,
    #[serde(default)]
    releases: Vec<RawRelease>,
}

#[derive(Deserialize)]
struct RawRelease {
    version: String,
    #[serde(default)]
    systems: Vec<String>,
    sums: String,
    #[serde(default)]
    signature: Option<String>,
    download: String,
    #[serde(default)]
    date: Option<String>,
}

impl Index {
    /// Parse the index, or say why it cannot be read.
    pub fn parse(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        let raw: RawIndex = serde_json::from_slice(bytes)?;
        let releases = raw
            .releases
            .into_iter()
            .filter_map(|r| {
                Some(Release {
                    version: r.version.parse().ok()?,
                    systems: r.systems,
                    sums: r.sums,
                    signature: r.signature,
                    download: r.download,
                    date: r.date,
                })
            })
            .collect();
        Ok(Index {
            latest: raw.latest,
            releases,
        })
    }

    /// Return the newest release that meets `req` and has an archive for
    /// `system`.
    pub fn newest(&self, req: &Requirement, system: &str) -> Option<&Release> {
        self.releases
            .iter()
            .filter(|r| satisfies(req, &r.version) && r.systems.iter().any(|s| s == system))
            .max_by(|a, b| a.version.cmp(&b.version))
    }

    /// Return the newest release that has an archive for `system`, the one
    /// `kix self upgrade` moves Kix `running` to. Prereleases count only when
    /// `running` is a prerelease of the same release, so trying one leads to
    /// the next one or to its release and no further.
    pub fn latest_for(&self, system: &str, running: &Version) -> Option<&Release> {
        let core = |v: &Version| (v.major, v.minor, v.patch);
        self.releases
            .iter()
            .filter(|r| {
                !r.version.is_prerelease()
                    || (running.is_prerelease() && core(&r.version) == core(running))
            })
            .filter(|r| r.systems.iter().any(|s| s == system))
            .max_by(|a, b| a.version.cmp(&b.version))
    }

    /// Return the newest prerelease of `req`'s minor that has an archive for
    /// `system`, so a message can say how to ask for it.
    pub fn newest_prerelease(&self, req: &Requirement, system: &str) -> Option<&Release> {
        self.releases
            .iter()
            .filter(|r| r.version.is_prerelease() && r.version.minor_key() == req.minor_key())
            .filter(|r| r.systems.iter().any(|s| s == system))
            .max_by(|a, b| a.version.cmp(&b.version))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(version: &str, systems: &[&str]) -> serde_json::Value {
        serde_json::json!({
            "version": version,
            "date": "2026-11-07",
            "systems": systems,
            "sums": format!("/releases/v{version}/SHA256SUMS"),
            "signature": format!("/releases/v{version}/SHA256SUMS.sig"),
            "download": format!("/download/{version}/"),
            "someday": true,
        })
    }

    fn index() -> Index {
        let json = serde_json::json!({
            "schema": "kix.run/releases/v1",
            "generated": "2026-11-08T12:00:00Z",
            "latest": "0.10.0",
            "releases": [
                release("0.10.0", &["x86_64-linux", "aarch64-darwin"]),
                release("0.9.1", &["x86_64-linux", "aarch64-darwin"]),
                release("0.9.2", &["x86_64-linux"]),
                release("0.9.0", &["x86_64-linux", "aarch64-darwin"]),
                release("not-a-version", &["x86_64-linux"]),
            ],
        });
        Index::parse(json.to_string().as_bytes()).unwrap()
    }

    #[test]
    fn the_index_reads_the_site_shape() {
        let index = index();
        assert_eq!(index.latest.as_deref(), Some("0.10.0"));
        assert_eq!(index.releases.len(), 4);
        let first = &index.releases[0];
        assert_eq!(first.version.to_string(), "0.10.0");
        assert_eq!(first.sums, "/releases/v0.10.0/SHA256SUMS");
        assert_eq!(
            first.signature.as_deref(),
            Some("/releases/v0.10.0/SHA256SUMS.sig")
        );
        assert_eq!(first.download, "/download/0.10.0/");
        assert_eq!(first.date.as_deref(), Some("2026-11-07"));
    }

    #[test]
    fn an_empty_index_has_no_releases() {
        let index =
            Index::parse(br#"{"schema": "kix.run/releases/v1", "latest": null, "releases": []}"#)
                .unwrap();
        assert_eq!(index.latest, None);
        assert!(index.releases.is_empty());
        assert!(Index::parse(b"not json").is_err());
    }

    #[test]
    fn newest_takes_the_newest_patch_built_for_the_system() {
        let index = index();
        let minor = Requirement::Minor(0, 9);
        assert_eq!(
            index
                .newest(&minor, "x86_64-linux")
                .unwrap()
                .version
                .to_string(),
            "0.9.2"
        );
        assert_eq!(
            index
                .newest(&minor, "aarch64-darwin")
                .unwrap()
                .version
                .to_string(),
            "0.9.1"
        );
        let exact = Requirement::Exact("0.9.0".parse().unwrap());
        assert_eq!(
            index
                .newest(&exact, "x86_64-linux")
                .unwrap()
                .version
                .to_string(),
            "0.9.0"
        );
        assert!(
            index
                .newest(&Requirement::Minor(0, 8), "x86_64-linux")
                .is_none()
        );
        assert!(index.newest(&minor, "aarch64-linux").is_none());
    }

    #[test]
    fn latest_for_skips_releases_without_the_system() {
        let json = serde_json::json!({
            "latest": "0.10.0",
            "releases": [
                release("0.10.0", &["x86_64-linux"]),
                release("0.9.2", &["x86_64-linux", "aarch64-darwin"]),
                release("0.9.1", &["aarch64-darwin"]),
            ],
        });
        let index = Index::parse(json.to_string().as_bytes()).unwrap();
        let running: Version = "0.9.0".parse().unwrap();
        let latest = |system| {
            index
                .latest_for(system, &running)
                .map(|r| r.version.to_string())
        };
        assert_eq!(latest("x86_64-linux").as_deref(), Some("0.10.0"));
        assert_eq!(latest("aarch64-darwin").as_deref(), Some("0.9.2"));
        assert_eq!(latest("aarch64-linux"), None);
    }

    #[test]
    fn prereleases_are_found_only_when_asked_for() {
        let json = serde_json::json!({
            "latest": "0.9.1",
            "releases": [
                release("0.10.0-rc.2", &["x86_64-linux"]),
                release("0.10.0-rc.1", &["x86_64-linux"]),
                release("0.9.1", &["x86_64-linux"]),
                release("0.9.2-rc.1", &["x86_64-linux"]),
            ],
        });
        let index = Index::parse(json.to_string().as_bytes()).unwrap();
        let version = |r: Option<&Release>| r.map(|r| r.version.to_string());
        let system = "x86_64-linux";
        let latest = |running: &str| version(index.latest_for(system, &running.parse().unwrap()));
        assert_eq!(latest("0.9.1").as_deref(), Some("0.9.1"));
        assert_eq!(latest("0.10.0-rc.1").as_deref(), Some("0.10.0-rc.2"));
        // The newest prerelease of its own release, which update leaves alone.
        assert_eq!(latest("0.9.2-rc.1").as_deref(), Some("0.9.2-rc.1"));
        // A prerelease of an older release moves to releases only.
        assert_eq!(latest("0.8.0-rc.1").as_deref(), Some("0.9.1"));
        assert_eq!(
            version(index.newest(&Requirement::Minor(0, 9), system)).as_deref(),
            Some("0.9.1")
        );
        assert_eq!(
            version(index.newest(&Requirement::Minor(0, 10), system)),
            None
        );
        let rc = Requirement::Exact("0.10.0-rc.1".parse().unwrap());
        assert_eq!(
            version(index.newest(&rc, system)).as_deref(),
            Some("0.10.0-rc.1")
        );
        assert_eq!(
            version(index.newest_prerelease(&Requirement::Minor(0, 10), system)).as_deref(),
            Some("0.10.0-rc.2")
        );
    }
}
