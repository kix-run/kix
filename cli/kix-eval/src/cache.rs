//! SQLite-backed eval cache, keyed by BLAKE3 hash of flake path + lockfile + attribute.

use std::path::Path;

use rusqlite::Connection;

use crate::error::KixEvalError;

/// SQLite eval cache for memoizing Nix evaluation results.
pub struct SqliteCache {
    conn: Connection,
}

impl SqliteCache {
    /// Open (or create) a cache database at the given path.
    pub fn open(path: &Path) -> Result<Self, KixEvalError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        }
        let conn =
            Connection::open(path).map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS eval_cache (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (unixepoch())
            );",
        )
        .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(Self { conn })
    }

    /// Open an in-memory cache (for testing).
    pub fn open_in_memory() -> Result<Self, KixEvalError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS eval_cache (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (unixepoch())
            );",
        )
        .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(Self { conn })
    }

    /// Look up a cached evaluation result by key.
    pub fn get(&self, key: &str) -> Result<Option<String>, KixEvalError> {
        let mut stmt = self
            .conn
            .prepare_cached("SELECT value FROM eval_cache WHERE key = ?1")
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        let result = stmt
            .query_row([key], |row| row.get(0))
            .optional()
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(result)
    }

    /// Store an evaluation result.
    pub fn put(&self, key: &str, value: &str) -> Result<(), KixEvalError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO eval_cache (key, value) VALUES (?1, ?2)",
                [key, value],
            )
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(())
    }

    /// Compute a cache key from flake path, lockfile contents, and attribute name.
    ///
    /// The key is a BLAKE3 hash of: canonical flake path + flake.lock contents + attr.
    /// If flake.lock doesn't exist, the flake path alone is hashed with the attr
    /// (the cache will still work, but won't invalidate on dependency changes).
    pub fn compute_key(flake_path: &Path, attr: &str) -> Result<String, KixEvalError> {
        let canonical = crate::store::resolve_symlinks(flake_path);
        let mut hasher = blake3::Hasher::new();
        hasher.update(canonical.to_string_lossy().as_bytes());

        let lockfile = canonical.join("flake.lock");
        if lockfile.exists() {
            let lock_contents = std::fs::read(&lockfile)
                .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
            hasher.update(&lock_contents);
        }

        hasher.update(attr.as_bytes());
        Ok(hasher.finalize().to_hex().to_string())
    }
}

/// Extension trait on `rusqlite::OptionalExtension` — re-export for internal use.
trait OptionalExt<T> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error>;
}

impl<T> OptionalExt<T> for Result<T, rusqlite::Error> {
    fn optional(self) -> Result<Option<T>, rusqlite::Error> {
        match self {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_put_and_get() {
        let cache = SqliteCache::open_in_memory().unwrap();
        cache.put("key1", r#"{"hello":"world"}"#).unwrap();
        let val = cache.get("key1").unwrap();
        assert_eq!(val, Some(r#"{"hello":"world"}"#.to_string()));
    }

    #[test]
    fn cache_get_missing_returns_none() {
        let cache = SqliteCache::open_in_memory().unwrap();
        let val = cache.get("nonexistent").unwrap();
        assert_eq!(val, None);
    }

    #[test]
    fn cache_put_replaces_existing() {
        let cache = SqliteCache::open_in_memory().unwrap();
        cache.put("key1", "old").unwrap();
        cache.put("key1", "new").unwrap();
        let val = cache.get("key1").unwrap();
        assert_eq!(val, Some("new".to_string()));
    }

    #[test]
    fn compute_key_is_deterministic() {
        let dir = tempfile::tempdir().unwrap();
        let k1 = SqliteCache::compute_key(dir.path(), "cluster-nw1").unwrap();
        let k2 = SqliteCache::compute_key(dir.path(), "cluster-nw1").unwrap();
        assert_eq!(k1, k2);
    }

    #[test]
    fn compute_key_differs_by_attr() {
        let dir = tempfile::tempdir().unwrap();
        let k1 = SqliteCache::compute_key(dir.path(), "cluster-nw1").unwrap();
        let k2 = SqliteCache::compute_key(dir.path(), "cluster-ja2").unwrap();
        assert_ne!(k1, k2);
    }

    #[test]
    fn compute_key_includes_lockfile() {
        let dir = tempfile::tempdir().unwrap();
        let k_before = SqliteCache::compute_key(dir.path(), "test").unwrap();

        std::fs::write(dir.path().join("flake.lock"), r#"{"version":1}"#).unwrap();
        let k_after = SqliteCache::compute_key(dir.path(), "test").unwrap();

        assert_ne!(k_before, k_after);
    }

    #[test]
    fn open_creates_parent_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("nested").join("deep").join("cache.db");
        let cache = SqliteCache::open(&db_path).unwrap();
        cache.put("test", "value").unwrap();
        assert_eq!(cache.get("test").unwrap(), Some("value".to_string()));
    }
}
