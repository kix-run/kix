//! The versions of Kix installed under the data directory.
//!
//! The install script and `kix self install` unpack each version's release
//! archive to `<data dir>/<version>/`, which holds `bin/kix` and the Kix
//! runtime in `libexec/kix`. The data directory also holds `receipt.json`,
//! which records how this tree was installed and which `kix` link the
//! install script made, so `kix self update` knows whether it may move that
//! link. Unpacking happens in a
//! `tmp-*` directory beside the versions, so a version directory either holds
//! a whole release or does not exist.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::version::Version;

/// The environment variable that moves the data directory. Kix's own tests
/// set it. Do not document it for users.
pub const DATA_DIR_VAR: &str = "KIX_DATA_DIR";

/// The name of the receipt file in the data directory.
const RECEIPT: &str = "receipt.json";

/// Why Kix has no data directory.
pub const NO_HOME: &str =
    "Kix cannot find a home directory to install into. Set HOME or XDG_DATA_HOME.";

/// Return the directory that holds the installed versions:
/// `$XDG_DATA_HOME/kix`, or `~/.local/share/kix`. Return `None` when neither
/// variable is set, so no two users ever share a fallback directory.
///
/// macOS gets the same directory as Linux, like Kix's cache. The XDG
/// specification ignores a relative `XDG_DATA_HOME`, and so does Kix.
pub fn data_dir() -> Option<PathBuf> {
    data_dir_from(
        std::env::var_os(DATA_DIR_VAR).as_deref(),
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
}

fn data_dir_from(
    test_dir: Option<&OsStr>,
    xdg_data_home: Option<&OsStr>,
    home: Option<&OsStr>,
) -> Option<PathBuf> {
    if let Some(dir) = test_dir.filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    xdg_data_home
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
        .or_else(|| home_from(home).map(|home| home.join(".local").join("share")))
        .map(|dir| dir.join("kix"))
}

/// Return the link the install script makes by default, or `None` without a
/// home directory.
pub fn link_path() -> Option<PathBuf> {
    home_from(std::env::var_os("HOME").as_deref())
        .map(|home| home.join(".local").join("bin").join("kix"))
}

fn home_from(home: Option<&OsStr>) -> Option<PathBuf> {
    home.filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
}

/// One installed version of Kix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Install {
    pub version: Version,
    pub dir: PathBuf,
}

impl Install {
    /// Return the path of this version's `kix`.
    pub fn bin(&self) -> PathBuf {
        self.dir.join("bin").join("kix")
    }
}

/// Return the installed versions, newest first. A directory counts when its
/// name is a version and it holds `bin/kix`.
pub fn installed() -> Vec<Install> {
    data_dir().map_or_else(Vec::new, |dir| installed_in(&dir))
}

fn installed_in(dir: &Path) -> Vec<Install> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut installs: Vec<Install> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let version = entry.file_name().to_str()?.parse::<Version>().ok()?;
            let install = Install {
                version,
                dir: entry.path(),
            };
            install.bin().is_file().then_some(install)
        })
        .collect();
    installs.sort_by(|a, b| b.version.cmp(&a.version));
    installs
}

/// Return the install the running Kix belongs to, or `None` when it runs from
/// somewhere else, such as a Nix profile or a build directory.
pub fn running_install() -> Option<Install> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    installed()
        .into_iter()
        .find(|install| install.bin().canonicalize().is_ok_and(|bin| bin == exe))
}

/// Return the first `kix` on `PATH`, with links resolved.
pub fn on_path() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join("kix"))
        .find(|file| file.is_file())
        .and_then(|file| file.canonicalize().ok())
}

/// Return the installed version whose `kix` is `bin`, a resolved path.
pub fn version_of(bin: &Path) -> Option<Version> {
    installed()
        .into_iter()
        .find(|install| install.bin().canonicalize().is_ok_and(|b| b == bin))
        .map(|install| install.version)
}

/// Remove the directory tree at `path`. A release archive unpacks files and
/// directories without write permission, which a plain recursive removal
/// cannot delete, so this makes each directory writable first.
pub fn remove_tree(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    if !meta.is_dir() {
        return std::fs::remove_file(path);
    }
    for entry in walkdir::WalkDir::new(path).follow_links(false) {
        let entry = entry.map_err(std::io::Error::other)?;
        if entry.file_type().is_dir() {
            let mut perms = entry
                .metadata()
                .map_err(std::io::Error::other)?
                .permissions();
            if perms.mode() & 0o700 != 0o700 {
                perms.set_mode(perms.mode() | 0o700);
                std::fs::set_permissions(entry.path(), perms)?;
            }
        }
    }
    std::fs::remove_dir_all(path)
}

/// How the versions in the data directory were installed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Receipt {
    /// `script` when the install script made this tree.
    pub installer: String,
    /// The version the installer last linked.
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed_at: Option<String>,
    /// The `kix` link the installer made, which `kix self update` moves.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link: Option<PathBuf>,
}

impl Receipt {
    /// The `installer` value the install script writes.
    pub const SCRIPT: &str = "script";

    /// Read the receipt, or `None` when there is none or it is unreadable.
    pub fn read() -> Option<Self> {
        let text = std::fs::read_to_string(data_dir()?.join(RECEIPT)).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn write(&self) -> std::io::Result<()> {
        let dir = data_dir().ok_or_else(|| std::io::Error::other(NO_HOME))?;
        std::fs::create_dir_all(&dir)?;
        let tmp = dir.join(format!("{RECEIPT}.tmp-{}", std::process::id()));
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(tmp, dir.join(RECEIPT))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_install(data: &Path, name: &str, with_bin: bool) {
        let bin = data.join(name).join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        if with_bin {
            std::fs::write(bin.join("kix"), "#!/bin/sh\n").unwrap();
        }
    }

    #[test]
    fn installs_are_version_directories_with_a_kix() {
        let data = tempfile::tempdir().unwrap();
        fake_install(data.path(), "0.8.4", true);
        fake_install(data.path(), "0.10.0", true);
        fake_install(data.path(), "0.8.6+250", true);
        fake_install(data.path(), "0.9.0", false);
        fake_install(data.path(), "tmp-0.9.1-123", true);
        fake_install(data.path(), "latest", true);
        std::fs::write(data.path().join(RECEIPT), "{}").unwrap();

        let found: Vec<String> = installed_in(data.path())
            .iter()
            .map(|i| i.version.to_string())
            .collect();
        assert_eq!(found, ["0.10.0", "0.8.6+250", "0.8.4"]);
        assert_eq!(
            installed_in(data.path())[0].bin(),
            data.path().join("0.10.0/bin/kix")
        );
        assert!(installed_in(&data.path().join("missing")).is_empty());
    }

    #[test]
    fn a_read_only_tree_is_removed() {
        use std::os::unix::fs::PermissionsExt;
        let data = tempfile::tempdir().unwrap();
        let tree = data.path().join("0.8.4");
        fake_install(data.path(), "0.8.4", true);
        let bin = tree.join("bin");
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o555)).unwrap();
        std::fs::set_permissions(&tree, std::fs::Permissions::from_mode(0o555)).unwrap();
        remove_tree(&tree).unwrap();
        assert!(!tree.exists());
        remove_tree(&tree).unwrap();
    }

    #[test]
    fn a_receipt_reads_what_the_script_writes() {
        let receipt: Receipt =
            serde_json::from_str(r#"{"installer": "script", "version": "0.8.4", "extra": 1}"#)
                .unwrap();
        assert_eq!(receipt.installer, Receipt::SCRIPT);
        assert_eq!(receipt.version, "0.8.4");
        assert_eq!(receipt.installed_at, None);
        assert_eq!(receipt.link, None);

        let receipt: Receipt = serde_json::from_str(
            r#"{"installer": "script", "version": "0.8.4", "link": "/opt/bin/kix"}"#,
        )
        .unwrap();
        assert_eq!(receipt.link, Some(PathBuf::from("/opt/bin/kix")));
    }

    #[test]
    fn without_home_or_xdg_data_home_there_is_no_data_directory() {
        let os = |s: &'static str| Some(OsStr::new(s));
        assert_eq!(data_dir_from(None, None, None), None);
        assert_eq!(data_dir_from(None, os("relative"), os("")), None);
        assert_eq!(
            data_dir_from(None, None, os("/home/a")),
            Some(PathBuf::from("/home/a/.local/share/kix"))
        );
        assert_eq!(
            data_dir_from(None, os("/xdg"), None),
            Some(PathBuf::from("/xdg/kix"))
        );
        assert_eq!(
            data_dir_from(os("/test"), None, None),
            Some(PathBuf::from("/test"))
        );
    }
}
