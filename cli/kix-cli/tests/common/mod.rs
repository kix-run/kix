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

/// Write `contents` to `path` as an executable file.
///
/// Linux refuses to run a file that a process holds open for writing
/// (`ETXTBSY`, "Text file busy"). Test threads start child processes all the
/// time, and a child started while this process held the file open keeps the
/// open file until it runs its own program. A test that ran the file in that
/// moment failed. So this process never opens the file: it writes the
/// contents to a separate temporary file, and a `cp` child process copies
/// them into place and exits before any test runs the file.
pub fn write_executable(path: &Path, contents: impl AsRef<[u8]>) {
    let staged = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(staged.path(), contents).unwrap();
    copy_executable(staged.path(), path);
}

/// Copy the file at `from` to `path` as an executable file, for the reason
/// [`write_executable`] gives.
pub fn copy_executable(from: &Path, path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let status = std::process::Command::new("cp")
        .arg(from)
        .arg(path)
        .status()
        .unwrap();
    assert!(status.success(), "cp {} {}", from.display(), path.display());
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}
