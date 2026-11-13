//! File-backed eval cache.
//!
//! Each evaluation has one slot file, named by a hash of the flake path, the
//! evaluated attribute, the builder, and the store root. The file holds the
//! full cache key next to the value, and a miss overwrites it. So the cache
//! holds at most one result per project and attribute, and needs no pruning.
//!
//! The key holds the fingerprint Nix gives the flake, which covers every
//! file an evaluation can read. Kix does not work out that set of files
//! itself, because the rules are Nix's: a flake in a Git repository reads the
//! repository's tracked files, and an input with a relative path is read from
//! the same tree.
//!
//! The cache is an optimisation. Every error while reading or writing it is
//! logged and the caller evaluates from source.

use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::value::RawValue;

/// Bump to discard every entry written in an older layout.
const LAYOUT: &str = "v2";

/// The SQLite database earlier Kix releases kept in the cache directory.
const LEGACY_DB: &str = "eval-cache.db";

pub(crate) struct FileCache {
    entries: PathBuf,
}

/// The result of [`FileCache::lookup`]: a cached value when there was one,
/// and where to store a fresh value when there was not.
pub(crate) struct Lookup {
    pub(crate) hit: Option<String>,
    /// `None` when the flake has no fingerprint. Nothing is stored then.
    slot: Option<(PathBuf, String)>,
}

#[derive(Deserialize)]
struct Entry<'a> {
    key: String,
    #[serde(borrow)]
    value: &'a RawValue,
}

impl FileCache {
    /// Use `<cache_dir>/eval-cache` and delete a leftover SQLite database
    /// from an earlier release.
    pub(crate) fn open(cache_dir: &Path) -> Self {
        remove_legacy_db(cache_dir);
        let root = cache_dir.join("eval-cache").join(LAYOUT);
        Self {
            entries: root.join("entries"),
        }
    }

    /// Look up the cached value of `attr` for the flake at `flake_path`.
    ///
    /// `fingerprint` is the flake's fingerprint
    /// ([`super::nix::flake_fingerprint`]). With `None`, the lookup never
    /// hits and never stores.
    pub(crate) fn lookup(
        &self,
        flake_path: &Path,
        attr: &str,
        fingerprint: Option<&str>,
    ) -> Lookup {
        let Some(fingerprint) = fingerprint else {
            tracing::debug!(flake = %flake_path.display(), "the flake has no fingerprint, eval cache skipped");
            return Lookup::none();
        };
        let canonical = super::store::resolve_symlinks(flake_path);
        let key = cache_key(&canonical, attr, fingerprint);
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
}

impl Lookup {
    fn none() -> Self {
        Self {
            hit: None,
            slot: None,
        }
    }
}

/// Return the name of the slot file. It leaves out the fingerprint, so a
/// changed source overwrites the slot.
fn slot_name(canonical: &Path, attr: &str) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(canonical.as_os_str().as_encoded_bytes());
    hasher.update(b"\0attr:");
    hasher.update(attr.as_bytes());
    hash_runtime(&mut hasher);
    hasher.finalize().to_hex().to_string()
}

/// Return the BLAKE3 hash of the flake path, the flake's fingerprint, the
/// attribute, the Kix version, the builder, and the store root.
fn cache_key(canonical: &Path, attr: &str, fingerprint: &str) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(canonical.as_os_str().as_encoded_bytes());
    hasher.update(b"\0fingerprint:");
    hasher.update(fingerprint.as_bytes());
    hasher.update(b"\0attr:");
    hasher.update(attr.as_bytes());
    hash_runtime(&mut hasher);
    hasher.finalize().to_hex().to_string()
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

#[cfg(test)]
mod tests {
    use super::*;

    const FLAKE: &str = "/project";

    fn cache() -> (FileCache, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        (FileCache::open(dir.path()), dir)
    }

    #[test]
    fn store_then_lookup_hits() {
        let (cache, _dir) = cache();
        let miss = cache.lookup(Path::new(FLAKE), "a", Some("f1"));
        assert_eq!(miss.hit, None);
        cache.store(&miss, r#"{"hello":"world"}"#).unwrap();
        let hit = cache.lookup(Path::new(FLAKE), "a", Some("f1"));
        assert_eq!(hit.hit.as_deref(), Some(r#"{"hello":"world"}"#));
        assert_eq!(cache.lookup(Path::new(FLAKE), "b", Some("f1")).hit, None);
        assert_eq!(cache.lookup(Path::new("/other"), "a", Some("f1")).hit, None);
    }

    #[test]
    fn a_new_fingerprint_misses_and_overwrites_the_slot() {
        let (cache, _dir) = cache();
        let first = cache.lookup(Path::new(FLAKE), "a", Some("f1"));
        cache.store(&first, "1").unwrap();
        let after = cache.lookup(Path::new(FLAKE), "a", Some("f2"));
        assert_eq!(after.hit, None);
        cache.store(&after, "2").unwrap();
        let entries = std::fs::read_dir(&cache.entries).unwrap().count();
        assert_eq!(entries, 1);
        assert_eq!(
            cache
                .lookup(Path::new(FLAKE), "a", Some("f2"))
                .hit
                .as_deref(),
            Some("2")
        );
        assert_eq!(cache.lookup(Path::new(FLAKE), "a", Some("f1")).hit, None);
    }

    #[test]
    fn no_fingerprint_neither_hits_nor_stores() {
        let (cache, dir) = cache();
        let lookup = cache.lookup(Path::new(FLAKE), "a", None);
        assert_eq!(lookup.hit, None);
        cache.store(&lookup, "1").unwrap();
        assert!(!dir.path().join("eval-cache").exists());
        // A result stored under a fingerprint is not returned without one.
        let keyed = cache.lookup(Path::new(FLAKE), "a", Some("f1"));
        cache.store(&keyed, "1").unwrap();
        assert_eq!(cache.lookup(Path::new(FLAKE), "a", None).hit, None);
    }

    #[test]
    fn unreadable_entry_is_a_miss() {
        let (cache, _dir) = cache();
        let lookup = cache.lookup(Path::new(FLAKE), "a", Some("f1"));
        let (path, _) = lookup.slot.as_ref().unwrap();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "not json").unwrap();
        assert_eq!(cache.lookup(Path::new(FLAKE), "a", Some("f1")).hit, None);
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
}
