//! Store path management and cache directory resolution.
//!
//! Store paths keep their logical form, `/nix/store/<hash>-<name>`,
//! everywhere Kix records them. Kix runs Nix against a store of its own,
//! whose files live under [`store_root`] instead, so code that opens a store
//! path on disk maps it with [`disk_path`] first.

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

use super::store_path::STORE_DIR;

/// The environment variable that selects a relocated Nix store.
pub const STORE_ROOT_VAR: &str = "KIX_STORE_ROOT";

/// Return the root of the store Kix runs Nix against: the directory
/// `KIX_STORE_ROOT` names, or `store` in Kix's cache directory.
///
/// Kix writes Helm renders into this store, which it cannot do in a store
/// that a Nix daemon owns. The store's files live in `<root>/nix/store`. A
/// relative root is taken from the working directory. Links in the root are
/// resolved, because Nix refuses a store with a link in its path.
pub fn store_root() -> PathBuf {
    let root = match std::env::var_os(STORE_ROOT_VAR).filter(|r| !r.is_empty()) {
        Some(root) => std::path::absolute(&root).unwrap_or_else(|_| PathBuf::from(root)),
        None => default_cache_dir().join("store"),
    };
    resolve_existing_links(&root)
}

/// Return `path` with the links in the part of it that exists resolved.
///
/// macOS has links at `/var`, `/tmp` and `/etc`, so a store root under a
/// temporary directory needs this. The part that does not exist yet is kept
/// as written, since Nix creates it.
fn resolve_existing_links(path: &Path) -> PathBuf {
    let mut existing = path;
    let mut missing = Vec::new();
    loop {
        if let Ok(real) = std::fs::canonicalize(existing) {
            return missing.iter().rev().fold(real, |p, name| p.join(name));
        }
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                missing.push(name);
                existing = parent;
            }
            _ => return path.to_path_buf(),
        }
    }
}

/// Return the directory that holds the store's files on disk.
pub fn store_dir() -> PathBuf {
    real_path(Path::new(STORE_DIR))
}

/// Return where the file behind `logical` is on disk. A path under
/// `/nix/store` moves under the store root when one is set. Any other path
/// is returned unchanged.
pub fn real_path(logical: &Path) -> PathBuf {
    real_path_in(Some(&store_root()), logical)
}

fn real_path_in(root: Option<&Path>, logical: &Path) -> PathBuf {
    match (root, logical.strip_prefix("/")) {
        (Some(root), Ok(relative)) if logical.starts_with(STORE_DIR) => root.join(relative),
        _ => logical.to_path_buf(),
    }
}

/// Return the file on disk behind `path`, following links into the store.
///
/// Every link is resolved first, because a link to `/nix/store/...`, such
/// as each entry of a build's result directory, points outside the root.
pub fn disk_path(path: &Path) -> std::io::Result<PathBuf> {
    let root = store_root();
    canonicalize_in(&root, path).map(|p| real_path_in(Some(&root), &p))
}

/// Return whether the file behind `path` exists, as [`disk_path`] finds it.
pub fn exists(path: &Path) -> bool {
    disk_path(path).is_ok_and(|p| p.exists())
}

/// Resolve every link in `path` and return the result in logical form.
///
/// A link whose target is under `/nix/store` is followed into the store
/// root, and the result keeps its `/nix/store` form, so the caller can
/// record it.
pub fn canonicalize(path: &Path) -> std::io::Result<PathBuf> {
    canonicalize_in(&store_root(), path)
}

/// Return `path` with its links resolved when it leads into the store, such
/// as a `result` link that `nix build` made. Otherwise return `path`
/// unchanged.
pub fn follow_into_store(path: &Path) -> PathBuf {
    canonicalize_in(&store_root(), path)
        .ok()
        .filter(|p| p.starts_with(STORE_DIR))
        .unwrap_or_else(|| path.to_path_buf())
}

/// Resolve links in `path` one component at a time, reading each from disk
/// through [`real_path_in`], so a link into `/nix/store` works on a machine
/// with no `/nix`.
fn canonicalize_in(root: &Path, path: &Path) -> std::io::Result<PathBuf> {
    const MAX_LINKS: usize = 40;
    let mut pending: Vec<OsString> = Vec::new();
    let push_all = |pending: &mut Vec<OsString>, p: &Path| {
        let parts: Vec<OsString> = p
            .components()
            .filter_map(|c| match c {
                Component::Normal(n) => Some(n.to_os_string()),
                Component::ParentDir => Some(OsString::from("..")),
                _ => None,
            })
            .collect();
        pending.extend(parts.into_iter().rev());
    };
    push_all(&mut pending, &std::path::absolute(path)?);
    let mut out = PathBuf::from("/");
    let mut links = 0;
    while let Some(part) = pending.pop() {
        if part == ".." {
            out.pop();
            continue;
        }
        out.push(&part);
        // `/nix` itself need not exist when the store is relocated.
        if Path::new(STORE_DIR).starts_with(&out) {
            continue;
        }
        let disk = real_path_in(Some(root), &out);
        if !std::fs::symlink_metadata(&disk)?.file_type().is_symlink() {
            continue;
        }
        links += 1;
        if links > MAX_LINKS {
            return Err(std::io::Error::other(format!(
                "too many levels of links in {}",
                path.display()
            )));
        }
        let target = std::fs::read_link(&disk)?;
        out.pop();
        if target.is_absolute() {
            out = PathBuf::from("/");
        }
        push_all(&mut pending, &target);
    }
    Ok(out)
}

/// Return the default cache directory (`~/.cache/kix/`).
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

/// Return the directory used to persist activation state between deploys.
fn activations_dir() -> PathBuf {
    default_cache_dir().join("activations")
}

/// Save the store path of the deployed build (its `built-via`) after a
/// successful deploy. Next deploy / GC can load this as the "old" activation.
///
/// Also registers a Nix GC root for the build so `nix-collect-garbage`
/// cannot delete the store path the active deploy resolves to (evaluation
/// leaves no root, so nothing else pins it). One root per cluster,
/// re-pointed on each deploy/rollback; deleting the `.root` link releases it.
pub fn save_activation_path(cluster: &str, built_via: &Path) -> std::io::Result<()> {
    let dir = activations_dir();
    std::fs::create_dir_all(&dir)?;
    let file = dir.join(format!("{cluster}.path"));
    std::fs::write(&file, built_via.to_string_lossy().as_bytes())?;

    // A missing nix-store binary or an absent store path must not fail deploy
    // bookkeeping.
    let root_link = dir.join(format!("{cluster}.root"));
    let _ = std::fs::remove_file(&root_link);
    if let Err(e) = super::nix::add_gc_root(&root_link, built_via) {
        tracing::warn!(cluster, ?built_via, error = %e, "could not protect this deployment build from Nix garbage collection; it may become unavailable for rollback");
    }
    Ok(())
}

/// Keep one Nix GC root, `{cluster}.kept-{identity_hash}`, for every build an
/// Activation lists under `status.orphansKeptFrom`, and remove the roots of
/// builds it no longer lists.
///
/// `listed` pairs each identity hash with the build's `built-via` on this
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

/// Load the previously saved store path of the deployed build.
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
        .filter(|p| exists(p))
}

/// Resolve an identity hash to the store path of the build whose
/// Activation it names, from the local activation cache. Returns None when
/// the cache holds another build or its store path is gone (e.g.
/// nix-collect-garbage ran).
pub fn resolve_activation_by_hash(cluster: &str, identity_hash: &str) -> Option<PathBuf> {
    load_activation_path(cluster)
        .filter(|cached| build_hash_of(cached).as_deref() == Some(identity_hash))
}

/// Return the identity hash of the Activation of the build at `built_via`
/// (the first 32 characters of the Activation's store name), or `None` if
/// the build cannot be read.
pub(crate) fn build_hash_of(built_via: &Path) -> Option<String> {
    let activation = super::build_files::BuildFiles::read(built_via)
        .ok()?
        .activation;
    let name = activation.file_name()?.to_str()?;
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

    #[test]
    fn a_store_root_under_a_link_is_resolved() {
        let dir = tempfile::tempdir().unwrap();
        let real = std::fs::canonicalize(dir.path()).unwrap().join("real");
        std::fs::create_dir(&real).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();

        assert_eq!(resolve_existing_links(&link), real);
        assert_eq!(
            resolve_existing_links(&link.join("not-yet/store")),
            real.join("not-yet/store")
        );
    }

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
    fn a_store_path_moves_under_the_root() {
        let root = Path::new("/home/u/.cache/kix/store");
        let logical = Path::new("/nix/store/abc-activation/kix-packages.json");
        assert_eq!(real_path_in(None, logical), logical);
        assert_eq!(
            real_path_in(Some(root), logical),
            Path::new("/home/u/.cache/kix/store/nix/store/abc-activation/kix-packages.json")
        );
        assert_eq!(
            real_path_in(Some(root), Path::new("/nix/store")),
            Path::new("/home/u/.cache/kix/store/nix/store")
        );
        for elsewhere in ["/nix/storefront/x", "/tmp/result", "relative/nix/store"] {
            assert_eq!(
                real_path_in(Some(root), Path::new(elsewhere)),
                Path::new(elsewhere)
            );
        }
    }

    /// A `result` link and a link inside the store both point at logical
    /// store paths that exist only under the root.
    #[test]
    fn links_into_a_relocated_store_resolve_to_logical_paths() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        let store = root.join("nix/store");
        std::fs::create_dir_all(store.join("aaa-result")).unwrap();
        std::fs::write(store.join("bbb-activation"), "{}").unwrap();
        std::os::unix::fs::symlink(
            "/nix/store/bbb-activation",
            store.join("aaa-result/activation"),
        )
        .unwrap();
        std::os::unix::fs::symlink("/nix/store/aaa-result", dir.path().join("result")).unwrap();

        assert_eq!(
            canonicalize_in(&root, Path::new("/nix/store/aaa-result/activation")).unwrap(),
            Path::new("/nix/store/bbb-activation")
        );
        assert_eq!(
            canonicalize_in(&root, &dir.path().join("result/activation")).unwrap(),
            Path::new("/nix/store/bbb-activation")
        );
        assert!(canonicalize_in(&root, Path::new("/nix/store/missing")).is_err());
        assert_eq!(
            real_path_in(
                Some(&root),
                &canonicalize_in(&root, &dir.path().join("result/activation")).unwrap()
            ),
            store.join("bbb-activation")
        );

        std::os::unix::fs::symlink("loop", dir.path().join("loop")).unwrap();
        assert!(canonicalize_in(&root, &dir.path().join("loop")).is_err());
    }

    #[test]
    fn default_cache_dir_is_absolute() {
        let dir = default_cache_dir();
        assert!(dir.is_absolute(), "cache dir should be absolute: {dir:?}");
        assert!(dir.ends_with("kix"));
    }
}
