//! File-backed eval cache.
//!
//! Each evaluation has one slot file, named by a hash of the flake path, the
//! evaluated attribute, the builder, and the store root. The file holds the
//! full cache key next to the value, and a miss overwrites it. So the cache
//! holds at most one result per project and attribute, and needs no pruning.
//!
//! The cache is an optimisation. Every error while reading or writing it is
//! logged and the caller evaluates from source.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

/// Bump to discard every entry written in an older layout.
const LAYOUT: &str = "v1";

/// The SQLite database earlier Kix releases kept in the cache directory.
const LEGACY_DB: &str = "eval-cache.db";

pub(crate) struct FileCache {
    entries: PathBuf,
    snapshots: PathBuf,
}

/// The result of [`FileCache::lookup`]: a cached value when there was one,
/// and where to store a fresh value when there was not.
pub(crate) struct Lookup {
    pub(crate) hit: Option<String>,
    /// `None` when no key could be computed, for example for a remote flake
    /// reference. Nothing is stored then.
    slot: Option<(PathBuf, String)>,
}

#[derive(Deserialize)]
struct Entry<'a> {
    key: String,
    #[serde(borrow)]
    value: &'a RawValue,
}

#[derive(Serialize, Deserialize)]
struct Snapshot {
    /// Relative path to modification time in nanoseconds since the epoch.
    files: BTreeMap<String, u64>,
    hash: String,
}

impl FileCache {
    /// Use `<cache_dir>/eval-cache` and delete a leftover SQLite database
    /// from an earlier release.
    pub(crate) fn open(cache_dir: &Path) -> Self {
        remove_legacy_db(cache_dir);
        let root = cache_dir.join("eval-cache").join(LAYOUT);
        Self {
            entries: root.join("entries"),
            snapshots: root.join("snapshots"),
        }
    }

    /// Look up the cached value of `attr` for the flake at `flake_path`.
    pub(crate) fn lookup(&self, flake_path: &Path, attr: &str) -> Lookup {
        let canonical = super::store::resolve_symlinks(flake_path);
        if !canonical.is_dir() {
            tracing::debug!(flake = %flake_path.display(), "not a local directory, eval cache skipped");
            return Lookup {
                hit: None,
                slot: None,
            };
        }
        let key = match self
            .source_fingerprint(&canonical)
            .and_then(|fp| cache_key(&canonical, attr, &fp))
        {
            Ok(key) => key,
            Err(e) => {
                tracing::warn!(flake = %canonical.display(), error = %e, "could not fingerprint the flake's files; skipping the eval cache and evaluating from source");
                return Lookup {
                    hit: None,
                    slot: None,
                };
            }
        };
        let path = self
            .entries
            .join(format!("{}.json", slot_name(&canonical, attr)));
        let hit = read_entry(&path, &key);
        Lookup {
            hit,
            slot: Some((path, key)),
        }
    }

    /// Store `value`, a JSON document, in the slot `lookup` named.
    pub(crate) fn store(&self, lookup: &Lookup, value: &str) -> std::io::Result<()> {
        let Some((path, key)) = &lookup.slot else {
            return Ok(());
        };
        let mut body = Vec::with_capacity(value.len() + key.len() + 24);
        write!(body, "{{\"key\":\"{key}\",\"value\":")?;
        body.extend_from_slice(value.as_bytes());
        body.push(b'}');
        write_atomic(path, &body)
    }

    /// Return a hash that changes when any tracked input file is added,
    /// removed, or modified.
    ///
    /// When the files and their modification times match the stored
    /// snapshot, return the stored hash without reading any file. Otherwise
    /// hash every `(path, content)` pair and store a new snapshot.
    fn source_fingerprint(&self, canonical: &Path) -> std::io::Result<String> {
        let files: BTreeMap<String, u64> = walk_nix_files(canonical)?.into_iter().collect();
        let snapshot_path = self.snapshots.join(format!(
            "{}.json",
            blake3::hash(canonical.as_os_str().as_encoded_bytes()).to_hex()
        ));

        if let Ok(bytes) = std::fs::read(&snapshot_path)
            && let Ok(stored) = serde_json::from_slice::<Snapshot>(&bytes)
            && stored.files == files
        {
            tracing::debug!(flake = %canonical.display(), "source fingerprint: mtime fast path hit");
            return Ok(stored.hash);
        }

        tracing::debug!(flake = %canonical.display(), file_count = files.len(), "source fingerprint: computing content hash");
        let mut hasher = blake3::Hasher::new();
        for rel_path in files.keys() {
            let content = std::fs::read(canonical.join(rel_path))?;
            hasher.update(rel_path.as_bytes());
            hasher.update(&content);
        }
        let hash = hasher.finalize().to_hex().to_string();

        let snapshot = Snapshot {
            files,
            hash: hash.clone(),
        };
        match serde_json::to_vec(&snapshot) {
            Ok(body) => {
                if let Err(e) = write_atomic(&snapshot_path, &body) {
                    tracing::warn!(path = %snapshot_path.display(), error = %e, "could not save the source fingerprint; the next run will hash the flake's files again");
                }
            }
            Err(e) => {
                tracing::warn!(path = %snapshot_path.display(), error = %e, "could not save the source fingerprint; the next run will hash the flake's files again")
            }
        }
        Ok(hash)
    }
}

impl Lookup {
    /// Return a lookup that never hits and never stores.
    pub(crate) fn none() -> Self {
        Self {
            hit: None,
            slot: None,
        }
    }
}

/// Return the name of the slot file. It leaves out the source fingerprint
/// and `flake.lock`, so a changed source overwrites the slot.
fn slot_name(canonical: &Path, attr: &str) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(canonical.as_os_str().as_encoded_bytes());
    hasher.update(b"\0attr:");
    hasher.update(attr.as_bytes());
    hash_runtime(&mut hasher);
    hasher.finalize().to_hex().to_string()
}

/// Return the BLAKE3 hash of the flake path, `flake.lock`, the source
/// fingerprint, the attribute, the Kix version, the builder, and the store
/// root.
fn cache_key(canonical: &Path, attr: &str, source_fingerprint: &str) -> std::io::Result<String> {
    let mut hasher = blake3::Hasher::new();
    hasher.update(canonical.as_os_str().as_encoded_bytes());
    match std::fs::read(canonical.join("flake.lock")) {
        Ok(lock) => {
            hasher.update(&lock);
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    hasher.update(source_fingerprint.as_bytes());
    hasher.update(attr.as_bytes());
    hash_runtime(&mut hasher);
    Ok(hasher.finalize().to_hex().to_string())
}

/// Add the running Kix's version, the builder, and the store root. A result
/// from one builder or store says nothing about what another holds. The
/// version is there because a cache hit skips the check that this Kix can
/// build the project's library, which only an evaluation runs.
fn hash_runtime(hasher: &mut blake3::Hasher) {
    hasher.update(b"\0kix:");
    hasher.update(crate::VERSION.as_bytes());
    hasher.update(b"\0builder:");
    hasher.update(crate::runtime::builder().name().as_bytes());
    match crate::runtime::nix_runner().root() {
        Some(root) => {
            hasher.update(b"\0store-root:");
            hasher.update(root.as_os_str().as_encoded_bytes());
        }
        None => {
            hasher.update(b"\0system-nix");
        }
    }
}

/// Return the value in the slot at `path` when its key is `key`.
fn read_entry(path: &Path, key: &str) -> Option<String> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
        Err(e) => {
            tracing::warn!(path = %path.display(), error = %e, "could not read the eval cache; evaluating from source");
            return None;
        }
    };
    match serde_json::from_slice::<Entry>(&bytes) {
        Ok(entry) if entry.key == key => Some(entry.value.get().to_owned()),
        Ok(_) => None,
        Err(e) => {
            tracing::warn!(path = %path.display(), error = %e, "discarding an unreadable eval cache entry and evaluating from source");
            None
        }
    }
}

/// Write `body` to `path` through a temporary file in the same directory, so
/// a concurrent reader sees the old file or the new one and never a partial
/// one.
fn write_atomic(path: &Path, body: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    tmp.write_all(body)?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

fn remove_legacy_db(cache_dir: &Path) {
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let path = cache_dir.join(format!("{LEGACY_DB}{suffix}"));
        match std::fs::remove_file(&path) {
            Ok(()) => {
                tracing::debug!(path = %path.display(), "removed the old eval cache database")
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                tracing::debug!(path = %path.display(), error = %e, "could not remove the old eval cache database");
            }
        }
    }
}

/// Walk `flake_path` recursively and collect evaluation input files as
/// `(relative_path, mtime_nanos)`.
///
/// Includes `.nix`, `.yaml`, `.yml`, and `.json` files so that changes to files
/// read via `builtins.readFile` invalidate the evaluation cache. Skips `.git`,
/// `.direnv`, `result`, and `node_modules` directories.
pub(crate) fn walk_nix_files(flake_path: &Path) -> std::io::Result<Vec<(String, u64)>> {
    use std::time::UNIX_EPOCH;

    const SKIP_DIRS: &[&str] = &[".git", ".direnv", "result", "node_modules"];
    let mut results = Vec::new();
    let mut stack = vec![flake_path.to_path_buf()];

    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir)? {
            let entry = entry?;
            let file_type = entry.file_type()?;
            let path = entry.path();

            if file_type.is_dir() {
                if let Some(name) = path.file_name().and_then(|n| n.to_str())
                    && !SKIP_DIRS.contains(&name)
                {
                    stack.push(path);
                }
            } else if file_type.is_file()
                && let Some(ext) = path.extension()
                && (ext == "nix" || ext == "yaml" || ext == "yml" || ext == "json")
            {
                let rel = path
                    .strip_prefix(flake_path)
                    .map_err(std::io::Error::other)?
                    .to_string_lossy()
                    .to_string();
                let mtime = std::fs::metadata(&path)?
                    .modified()?
                    .duration_since(UNIX_EPOCH)
                    // An mtime before the Unix epoch cannot match the fast path,
                    // forcing a content-hash recompute.
                    .unwrap_or_default()
                    .as_nanos() as u64;
                results.push((rel, mtime));
            }
        }
    }

    results.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flake() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("flake.nix"), "{ }").unwrap();
        std::fs::write(dir.path().join("lib.nix"), "x: x").unwrap();
        dir
    }

    #[test]
    fn store_then_lookup_hits() {
        let (src, cache_dir) = (flake(), tempfile::tempdir().unwrap());
        let cache = FileCache::open(cache_dir.path());
        let miss = cache.lookup(src.path(), "a");
        assert_eq!(miss.hit, None);
        cache.store(&miss, r#"{"hello":"world"}"#).unwrap();
        let hit = cache.lookup(src.path(), "a");
        assert_eq!(hit.hit.as_deref(), Some(r#"{"hello":"world"}"#));
        assert_eq!(cache.lookup(src.path(), "b").hit, None);
    }

    #[test]
    fn source_change_misses_and_overwrites_the_slot() {
        let (src, cache_dir) = (flake(), tempfile::tempdir().unwrap());
        let cache = FileCache::open(cache_dir.path());
        cache.store(&cache.lookup(src.path(), "a"), "1").unwrap();
        std::fs::write(src.path().join("lib.nix"), "x: x + 1").unwrap();
        let after = cache.lookup(src.path(), "a");
        assert_eq!(after.hit, None);
        cache.store(&after, "2").unwrap();
        let entries = std::fs::read_dir(&cache.entries).unwrap().count();
        assert_eq!(entries, 1);
        assert_eq!(cache.lookup(src.path(), "a").hit.as_deref(), Some("2"));
    }

    #[test]
    fn unreadable_entry_is_a_miss() {
        let (src, cache_dir) = (flake(), tempfile::tempdir().unwrap());
        let cache = FileCache::open(cache_dir.path());
        let lookup = cache.lookup(src.path(), "a");
        let (path, _) = lookup.slot.as_ref().unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "not json").unwrap();
        assert_eq!(cache.lookup(src.path(), "a").hit, None);
    }

    #[test]
    fn remote_reference_skips_the_cache() {
        let cache_dir = tempfile::tempdir().unwrap();
        let cache = FileCache::open(cache_dir.path());
        let lookup = cache.lookup(Path::new("github:org/repo"), "a");
        assert_eq!(lookup.hit, None);
        cache.store(&lookup, "1").unwrap();
        assert!(!cache_dir.path().join("eval-cache").exists());
    }

    #[test]
    fn open_removes_the_legacy_database() {
        let cache_dir = tempfile::tempdir().unwrap();
        std::fs::write(cache_dir.path().join("eval-cache.db"), "x").unwrap();
        std::fs::write(cache_dir.path().join("eval-cache.db-wal"), "x").unwrap();
        FileCache::open(cache_dir.path());
        assert!(!cache_dir.path().join("eval-cache.db").exists());
        assert!(!cache_dir.path().join("eval-cache.db-wal").exists());
    }

    #[test]
    fn fingerprint_stable_when_unchanged() {
        let (src, cache_dir) = (flake(), tempfile::tempdir().unwrap());
        let cache = FileCache::open(cache_dir.path());
        let fp1 = cache.source_fingerprint(src.path()).unwrap();
        let fp2 = cache.source_fingerprint(src.path()).unwrap();
        assert_eq!(fp1, fp2);
    }
}
