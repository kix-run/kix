//! The files of one build, found from the store path Kix records for it.
//!
//! Kix records a build by one store path: `kix.run/built-via` on the
//! Activation record, `spec.source.path`, the local activation cache, and a
//! plan's `deployed.store_path`. That path is one of two forms:
//!
//! - an index file, `kix-activation-<cluster>.json`, that the library's
//!   `activationIndex` writes. It is a JSON object that names each file's
//!   store path, and its string context makes it reference every file it
//!   names.
//! - a result directory of links, one per file (`activation`,
//!   `kix-packages.json`, `kix-scorecard.json`, and so on). Records and
//!   saved builds written by Kix 0.6 and earlier name this form, so Kix
//!   keeps reading it.
//!
//! [`BuildFiles::read`] reads either form. Every path it returns is a
//! logical store path, so callers open it through [`super::store::disk_path`].

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

use super::error::KixEvalError;
use super::store;

/// The index format this binary reads.
const INDEX_VERSION: u64 = 1;

/// The store paths of one build's files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildFiles {
    /// The Activation record's manifest.
    pub activation: PathBuf,
    /// `kix-packages.json`, the index of packages to their resources.
    pub packages: PathBuf,
    /// The scorecard report, when the cluster enables the scorecard.
    pub scorecard: Option<PathBuf>,
    /// Images that operators pull, when any package lists them.
    pub extra_images: Option<PathBuf>,
    /// Where each image option value came from.
    pub image_sources: Option<PathBuf>,
    /// Each consumer's interface file, by consumer name.
    pub interfaces: BTreeMap<String, PathBuf>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndexFile {
    version: u64,
    activation: PathBuf,
    packages: PathBuf,
    #[serde(default)]
    scorecard: Option<PathBuf>,
    #[serde(default)]
    extra_images: Option<PathBuf>,
    #[serde(default)]
    image_sources: Option<PathBuf>,
    #[serde(default)]
    interfaces: BTreeMap<String, PathBuf>,
}

impl BuildFiles {
    /// Read the files of the build at `location`, an index file or a result
    /// directory.
    pub fn read(location: &Path) -> Result<Self, KixEvalError> {
        let read = || match open(location)? {
            Opened::Dir(dir) => Self::read_result_dir(&dir),
            Opened::Index(bytes) => Self::parse_index(&bytes),
        };
        read().map_err(|what| unreadable(location, what))
    }

    /// Return the store path of `kix-packages.json` of the build at
    /// `location`. A result directory needs no other file for this.
    pub fn packages_of(location: &Path) -> Result<PathBuf, KixEvalError> {
        let read = || match open(location)? {
            Opened::Dir(dir) => {
                entry(&dir, "kix-packages.json").map_err(|e| format!("no kix-packages.json: {e}"))
            }
            Opened::Index(bytes) => Self::parse_index(&bytes).map(|files| files.packages),
        };
        read().map_err(|what| unreadable(location, what))
    }

    /// Return whether `location` holds a build in either form: an index
    /// file, or a directory with `kix-packages.json`.
    pub fn is_build(location: &Path) -> bool {
        Self::packages_of(location).is_ok()
    }

    fn parse_index(bytes: &[u8]) -> Result<Self, String> {
        let index: IndexFile = serde_json::from_slice(bytes)
            .map_err(|e| format!("it is not a Kix build index: {e}"))?;
        if index.version != INDEX_VERSION {
            return Err(format!(
                "it is a build index of version {}, and this kix reads version {INDEX_VERSION}. \
                 Use the kix binary of the same release as the Kix library that made the build",
                index.version
            ));
        }
        Ok(Self {
            activation: index.activation,
            packages: index.packages,
            scorecard: index.scorecard,
            extra_images: index.extra_images,
            image_sources: index.image_sources,
            interfaces: index.interfaces,
        })
    }

    /// Read a result directory of links ([`entry`]). `activation` and
    /// `kix-packages.json` must be present. The other files are optional.
    fn read_result_dir(dir: &Path) -> Result<Self, String> {
        let link = |name: &str| entry(dir, name);
        let optional = |name: &str| link(name).ok();
        let activation = link("activation").map_err(|e| format!("no activation link: {e}"))?;
        let packages =
            link("kix-packages.json").map_err(|e| format!("no kix-packages.json link: {e}"))?;
        let mut interfaces = BTreeMap::new();
        for listed in std::fs::read_dir(store::real_path(dir)).map_err(|e| e.to_string())? {
            let name = listed.map_err(|e| e.to_string())?.file_name();
            let Some(name) = name.to_str() else { continue };
            if let Some(consumer) = name
                .strip_prefix("kix-interface-")
                .and_then(|n| n.strip_suffix(".json"))
                && let Some(path) = optional(name)
            {
                interfaces.insert(consumer.to_string(), path);
            }
        }
        Ok(Self {
            activation,
            packages,
            scorecard: optional("kix-scorecard.json"),
            extra_images: optional("kix-extra-images.json"),
            image_sources: optional("kix-image-sources.json"),
            interfaces,
        })
    }
}

enum Opened {
    /// A result directory, in logical form with its links resolved.
    Dir(PathBuf),
    /// The bytes of an index file.
    Index(Vec<u8>),
}

fn open(location: &Path) -> Result<Opened, String> {
    let on_disk = store::disk_path(location).map_err(|e| e.to_string())?;
    if std::fs::metadata(&on_disk)
        .map_err(|e| e.to_string())?
        .is_dir()
    {
        let dir = store::canonicalize(location).map_err(|e| e.to_string())?;
        return Ok(Opened::Dir(dir));
    }
    std::fs::read(&on_disk)
        .map(Opened::Index)
        .map_err(|e| e.to_string())
}

/// Return the store path that the entry `name` of the result directory
/// `dir` names. A link is read and not followed, so the store path it names
/// need not be present. An entry that is a file is its own path.
fn entry(dir: &Path, name: &str) -> std::io::Result<PathBuf> {
    let entry = dir.join(name);
    let on_disk = store::real_path(&entry);
    if std::fs::symlink_metadata(&on_disk)?
        .file_type()
        .is_symlink()
    {
        Ok(dir.join(std::fs::read_link(&on_disk)?))
    } else {
        Ok(entry)
    }
}

fn unreadable(location: &Path, what: String) -> KixEvalError {
    KixEvalError::StoreGraphError {
        message: format!("failed to read the build at {}: {what}", location.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    /// Both forms of one build name the same files.
    #[test]
    fn an_index_and_a_result_dir_name_the_same_files() {
        let tmp = tempfile::tempdir().unwrap();
        let file = |name: &str| {
            let path = tmp.path().join(name);
            std::fs::write(&path, "{}").unwrap();
            path
        };
        let activation = file("x-k8s-Activation");
        let packages = file("x-kix-packages.json");
        let scorecard = file("x-kix-scorecard.json");
        let interface = file("x-kix-interface-acme.json");

        let dir = tmp.path().join("result");
        std::fs::create_dir(&dir).unwrap();
        symlink(&activation, dir.join("activation")).unwrap();
        symlink(&packages, dir.join("kix-packages.json")).unwrap();
        symlink(&scorecard, dir.join("kix-scorecard.json")).unwrap();
        symlink(&interface, dir.join("kix-interface-acme.json")).unwrap();

        let index = tmp.path().join("kix-activation-c.json");
        std::fs::write(
            &index,
            serde_json::json!({
                "version": 1,
                "activation": activation,
                "packages": packages,
                "scorecard": scorecard,
                "extraImages": null,
                "imageSources": null,
                "interfaces": { "acme": interface },
            })
            .to_string(),
        )
        .unwrap();

        let from_dir = BuildFiles::read(&dir).unwrap();
        let from_index = BuildFiles::read(&index).unwrap();
        assert_eq!(from_dir, from_index);
        assert_eq!(from_index.activation, activation);
        assert_eq!(from_index.extra_images, None);
        assert_eq!(from_index.interfaces["acme"], interface);
    }

    /// An index of another version, a file that is no index, and a
    /// directory without a package index are not builds.
    #[test]
    fn other_files_are_not_builds() {
        let tmp = tempfile::tempdir().unwrap();
        let newer = tmp.path().join("newer.json");
        std::fs::write(&newer, r#"{"version":2,"activation":"/a","packages":"/p"}"#).unwrap();
        let err = BuildFiles::read(&newer).unwrap_err().to_string();
        assert!(err.contains("version 2"), "{err}");

        let manifest = tmp.path().join("deployment.json");
        std::fs::write(&manifest, r#"{"kind":"Deployment"}"#).unwrap();
        assert!(!BuildFiles::is_build(&manifest));

        let snapshot = tmp.path().join("snapshot");
        std::fs::create_dir(&snapshot).unwrap();
        std::fs::write(snapshot.join("deployment.yaml"), "kind: Deployment").unwrap();
        assert!(!BuildFiles::is_build(&snapshot));
        assert!(!BuildFiles::is_build(&tmp.path().join("missing")));

        // A directory with a package index is a build whose files are
        // read when it loads.
        std::fs::write(snapshot.join("kix-packages.json"), "{}").unwrap();
        assert!(BuildFiles::is_build(&snapshot));
        assert!(BuildFiles::read(&snapshot).is_err());
    }
}
