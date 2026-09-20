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
///
/// Also registers a Nix GC root for the result dir so `nix-collect-garbage`
/// cannot delete the store path the active deploy resolves to (builds run
/// with `--no-link`, so nothing else pins it). One root per cluster,
/// re-pointed on each deploy/rollback; deleting the `.root` link releases it.
pub fn save_activation_path(cluster: &str, result_dir: &Path) -> std::io::Result<()> {
    let dir = activations_dir();
    std::fs::create_dir_all(&dir)?;
    let file = dir.join(format!("{cluster}.path"));
    std::fs::write(&file, result_dir.to_string_lossy().as_bytes())?;

    // Best-effort GC root — a missing nix-store binary or a store path that
    // is already gone should not fail the deploy bookkeeping.
    let root_link = dir.join(format!("{cluster}.root"));
    let _ = std::fs::remove_file(&root_link);
    match std::process::Command::new("nix-store")
        .arg("--add-root")
        .arg(&root_link)
        .arg("--realise")
        .arg(result_dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
    {
        Ok(status) if status.success() => {}
        Ok(status) => {
            tracing::warn!(cluster, ?result_dir, %status, "could not protect this deployment build from Nix garbage collection; it may become unavailable for rollback");
        }
        Err(e) => {
            tracing::warn!(cluster, ?result_dir, error = %e, "could not run nix-store --add-root; this deployment build may be garbage-collected and become unavailable for rollback");
        }
    }
    Ok(())
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

/// Resolve an identity-hash to the activation result directory.
///
/// Checks the local cache first (fast path). If that doesn't match,
/// tries to find the store path by globbing `/nix/store/{hash}*`.
/// Returns None if the store path is gone (e.g. nix-collect-garbage ran).
pub fn resolve_activation_by_hash(cluster: &str, identity_hash: &str) -> Option<PathBuf> {
    // Fast path: check if the cached result dir matches this hash
    if let Some(cached_dir) = load_activation_path(cluster) {
        let activation_link = cached_dir.join("activation");
        if let Ok(target) = std::fs::read_link(&activation_link) {
            let target_hash = target
                .file_name()
                .and_then(|n| n.to_str())
                .filter(|n| n.len() >= 32)
                .map(|n| &n[..32]);
            if target_hash == Some(identity_hash) {
                return Some(cached_dir);
            }
        }
    }

    // Slow path: find a matching store path and check if it has a result dir structure
    // The identity-hash is the first 32 chars of the store path basename
    let store_dir = PathBuf::from("/nix/store");
    if let Ok(entries) = std::fs::read_dir(&store_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with(identity_hash)
                && name_str.len() > 32
                && name_str.as_bytes()[32] == b'-'
                && name_str.contains("activation")
            {
                let path = entry.path();
                // Check if this looks like a result dir (has kix-packages.json)
                if path.join("kix-packages.json").exists() {
                    return Some(path);
                }
            }
        }
    }

    None
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
