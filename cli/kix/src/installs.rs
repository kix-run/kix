//! The versions of Kix installed under the data directory.
//!
//! The install script and `kix self install` unpack each version's release
//! archive to `<data dir>/<version>/`, which holds `bin/kix` and the Kix
//! runtime in `libexec/kix`. The data directory also holds `receipt.json`,
//! which records how this tree was installed so `kix self update` knows
//! whether it may move the `~/.local/bin/kix` link. Unpacking happens in a
//! `tmp-*` directory beside the versions, so a version directory either holds
//! a whole release or does not exist.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::version::Version;

/// The environment variable that moves the data directory. Kix's own tests
/// set it. Do not document it for users.
pub const DATA_DIR_VAR: &str = "KIX_DATA_DIR";

/// The name of the receipt file in the data directory.
const RECEIPT: &str = "receipt.json";

/// Return the directory that holds the installed versions:
/// `$XDG_DATA_HOME/kix`, or `~/.local/share/kix`.
///
/// macOS gets the same directory as Linux, like Kix's cache. The XDG
/// specification ignores a relative `XDG_DATA_HOME`, and so does Kix.
pub fn data_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os(DATA_DIR_VAR).filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
        .unwrap_or_else(|| home().join(".local").join("share"))
        .join("kix")
}

/// Return the link the install script points at the version it installed.
pub fn link_path() -> PathBuf {
    home().join(".local").join("bin").join("kix")
}

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/kix"))
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
    installed_in(&data_dir())
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
}

impl Receipt {
    /// The `installer` value the install script writes.
    pub const SCRIPT: &str = "script";

    /// Read the receipt, or `None` when there is none or it is unreadable.
    pub fn read() -> Option<Self> {
        let text = std::fs::read_to_string(data_dir().join(RECEIPT)).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn write(&self) -> std::io::Result<()> {
        let dir = data_dir();
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
    }
}
