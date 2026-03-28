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
    std::fs::canonicalize(path).unwrap_or_else(|e| {
        tracing::warn!(path = ?path, error = %e, "failed to canonicalize path, using as-is");
        path.to_path_buf()
    })
}

/// Directory for persisting activation state between deploys.
fn activations_dir() -> PathBuf {
    default_cache_dir().join("activations")
}

/// Save the activation result directory path after a successful deploy.
/// Next deploy / GC can load this as the "old" activation.
pub fn save_activation_path(cluster: &str, result_dir: &Path) -> std::io::Result<()> {
    let dir = activations_dir();
    std::fs::create_dir_all(&dir)?;
    let file = dir.join(format!("{cluster}.path"));
    std::fs::write(&file, result_dir.to_string_lossy().as_bytes())
}

/// Load the previously saved activation result directory path.
/// Returns None if no previous deploy is recorded.
pub fn load_activation_path(cluster: &str) -> Option<PathBuf> {
    let file = activations_dir().join(format!("{cluster}.path"));
    std::fs::read_to_string(&file)
        .ok()
        .map(|s| PathBuf::from(s.trim()))
        .filter(|p| p.exists())
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
}
