//! Store path management and cache directory resolution.

use std::path::{Path, PathBuf};

/// Returns the default cache directory: `~/.cache/kix/`.
pub fn default_cache_dir() -> PathBuf {
    directories::ProjectDirs::from("", "", "kix")
        .map(|dirs| dirs.cache_dir().to_path_buf())
        .unwrap_or_else(|| {
            let mut home = dirs_fallback_home();
            home.push(".cache");
            home.push("kix");
            home
        })
}

/// Returns the default path for the eval cache database.
pub fn default_cache_db() -> PathBuf {
    default_cache_dir().join("eval-cache.db")
}

/// Resolve symlinks in a path. Important on macOS where `/tmp` is a
/// symlink to `/private/tmp` — Nix store paths must not traverse symlinks.
pub fn resolve_symlinks(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn dirs_fallback_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/kix"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_cache_dir_is_absolute() {
        let dir = default_cache_dir();
        assert!(dir.is_absolute(), "cache dir should be absolute: {dir:?}");
        assert!(dir.ends_with("kix"));
    }

    #[test]
    fn resolve_symlinks_returns_path_for_nonexistent() {
        let p = Path::new("/nonexistent/path/here");
        assert_eq!(resolve_symlinks(p), p);
    }

    #[test]
    fn resolve_symlinks_resolves_real_path() {
        let resolved = resolve_symlinks(Path::new("/tmp"));
        // On macOS, /tmp -> /private/tmp
        if cfg!(target_os = "macos") {
            assert_eq!(resolved, PathBuf::from("/private/tmp"));
        }
    }
}
