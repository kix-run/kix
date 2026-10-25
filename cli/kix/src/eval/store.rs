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

/// Resolve symlinks because Nix store paths must not traverse them. On macOS,
/// `/tmp` commonly points to `/private/tmp`.
pub(crate) fn resolve_symlinks(path: &Path) -> PathBuf {
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

    // A missing nix-store binary or an absent store path must not fail deploy
    // bookkeeping.
    let root_link = dir.join(format!("{cluster}.root"));
    let _ = std::fs::remove_file(&root_link);
    if let Err(e) = super::nix::add_gc_root(&root_link, result_dir) {
        tracing::warn!(cluster, ?result_dir, error = %e, "could not protect this deployment build from Nix garbage collection; it may become unavailable for rollback");
    }
    Ok(())
}

/// Keep one Nix GC root, `{cluster}.kept-{identity_hash}`, for every build an
/// Activation lists under `status.orphansKeptFrom`, and remove the roots of
/// builds it no longer lists.
///
/// `listed` pairs each identity hash with the build's result dir on this
/// machine, `None` when it is not here. The `{cluster}.root` of the deployed
/// build moves on the next deploy, so without these a listed build is
/// collectable and every later plan reports it as unreadable. Best-effort:
/// failures are logged, never returned.
pub(crate) fn sync_kept_roots(cluster: &str, listed: &[(String, Option<PathBuf>)]) {
    sync_kept_roots_in(&activations_dir(), cluster, listed, |link, target| {
        super::nix::add_gc_root(link, target).map_err(|e| e.to_string())
    });
}

fn sync_kept_roots_in(
    dir: &Path,
    cluster: &str,
    listed: &[(String, Option<PathBuf>)],
    add_root: impl Fn(&Path, &Path) -> Result<(), String>,
) {
    let prefix = format!("{cluster}.kept-");
    // The hash comes from the cluster and becomes a file name, so anything
    // other than a store hash is ignored.
    let is_hash = |h: &str| !h.is_empty() && h.bytes().all(|b| b.is_ascii_alphanumeric());

    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(hash) = name.to_str().and_then(|n| n.strip_prefix(&prefix)) else {
                continue;
            };
            if is_hash(hash) && !listed.iter().any(|(h, _)| h == hash) {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }

    for (hash, result_dir) in listed {
        let Some(result_dir) = result_dir else {
            continue;
        };
        if !is_hash(hash) {
            continue;
        }
        let link = dir.join(format!("{prefix}{hash}"));
        if link.symlink_metadata().is_ok() {
            continue;
        }
        if let Err(e) = std::fs::create_dir_all(dir) {
            tracing::warn!(error = %e, "could not create the activation cache directory");
            return;
        }
        if let Err(e) = add_root(&link, result_dir) {
            tracing::warn!(cluster, ?result_dir, error = %e, "could not protect a build with kept orphans from Nix garbage collection");
        }
    }
}

/// Load the previously saved activation result directory path.
/// Returns None if no previous deploy is recorded.
///
/// The file is keyed by cluster name only, so two kube contexts that deploy
/// clusters of the same name share it. Check the build against the Active
/// record of the context in use (`build_hash_of`) before planning from it.
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
    if let Some(cached_dir) = load_activation_path(cluster)
        && build_hash_of(&cached_dir).as_deref() == Some(identity_hash)
    {
        return Some(cached_dir);
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

/// The identity hash of the Activation a result dir holds: the first 32
/// characters of the store path its `activation` link points at, which is
/// the hash the Activation record carries. `None` when the link is missing.
pub(crate) fn build_hash_of(result_dir: &Path) -> Option<String> {
    let target = std::fs::read_link(result_dir.join("activation")).ok()?;
    let name = target.file_name()?.to_str()?;
    name.get(..32).map(str::to_string)
}

fn dirs_fallback_home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/kix"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A listed build gains a root, a root whose build is no longer listed
    /// is removed, and other clusters' roots and non-hash names are left
    /// alone.
    #[test]
    fn kept_roots_follow_the_list() {
        let dir = tempfile::tempdir().unwrap();
        let fake_root = |link: &Path, target: &Path| {
            std::os::unix::fs::symlink(target, link).map_err(|e| e.to_string())
        };
        let build = |h: &str| Some(PathBuf::from(format!("/nix/store/{h}-activation")));
        let roots = || {
            let mut names: Vec<String> = std::fs::read_dir(dir.path())
                .unwrap()
                .map(|e| e.unwrap().file_name().into_string().unwrap())
                .collect();
            names.sort();
            names
        };
        std::fs::write(dir.path().join("other.kept-aaa"), "").unwrap();

        sync_kept_roots_in(
            dir.path(),
            "c",
            &[
                ("aaa".into(), build("aaa")),
                ("bbb".into(), build("bbb")),
                ("ccc".into(), None),
                ("not/a.hash".into(), build("x")),
                ("not.a.hash".into(), build("x")),
            ],
            fake_root,
        );
        assert_eq!(roots(), vec!["c.kept-aaa", "c.kept-bbb", "other.kept-aaa"]);
        assert_eq!(
            std::fs::read_link(dir.path().join("c.kept-bbb")).unwrap(),
            PathBuf::from("/nix/store/bbb-activation")
        );

        sync_kept_roots_in(dir.path(), "c", &[("bbb".into(), None)], fake_root);
        assert_eq!(roots(), vec!["c.kept-bbb", "other.kept-aaa"]);

        sync_kept_roots_in(dir.path(), "c", &[], fake_root);
        assert_eq!(roots(), vec!["other.kept-aaa"]);
    }

    #[test]
    fn default_cache_dir_is_absolute() {
        let dir = default_cache_dir();
        assert!(dir.is_absolute(), "cache dir should be absolute: {dir:?}");
        assert!(dir.ends_with("kix"));
    }
}
