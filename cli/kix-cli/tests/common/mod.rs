//! Helpers shared by the integration tests.
#![allow(dead_code)]

use std::ops::Deref;
use std::path::Path;

/// A temporary directory that is deleted even when it holds a Kix local store.
///
/// Kix makes the files of its store read-only, as Nix does, so
/// `tempfile::TempDir` cannot delete them. Each test run then left about
/// 175,000 files in the temporary folder. This type makes every directory
/// under it writable before `tempfile` deletes it.
pub struct TempDir(tempfile::TempDir);

/// Create a [`TempDir`]. Use it in place of `tempfile::tempdir()`.
pub fn tempdir() -> TempDir {
    TempDir(tempfile::tempdir().unwrap())
}

impl Deref for TempDir {
    type Target = tempfile::TempDir;

    fn deref(&self) -> &tempfile::TempDir {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        make_writable(self.0.path());
    }
}

/// Give the owner write access to `dir` and every directory under it. It does
/// not follow symbolic links.
fn make_writable(dir: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let Ok(meta) = std::fs::symlink_metadata(dir) else {
        return;
    };
    if !meta.is_dir() {
        return;
    }
    let mut perms = meta.permissions();
    if perms.mode() & 0o700 != 0o700 {
        perms.set_mode(perms.mode() | 0o700);
        let _ = std::fs::set_permissions(dir, perms);
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        make_writable(&entry.path());
    }
}
