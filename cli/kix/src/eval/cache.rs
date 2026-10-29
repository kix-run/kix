//! SQLite-backed eval cache, keyed by BLAKE3 hash of flake path + lockfile + attribute.

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::Connection;

use super::error::KixEvalError;

/// SQLite eval cache for memoizing Nix evaluation results.
pub(crate) struct SqliteCache {
    conn: Connection,
}

impl SqliteCache {
    /// Open (or create) a cache database at the given path.
    pub(crate) fn open(path: &Path) -> Result<Self, KixEvalError> {
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
            );
            CREATE TABLE IF NOT EXISTS source_snapshot (
                flake_path TEXT PRIMARY KEY,
                files_json TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );",
        )
        .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(Self { conn })
    }

    /// Open an in-memory cache (for testing).
    pub(crate) fn open_in_memory() -> Result<Self, KixEvalError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS eval_cache (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE IF NOT EXISTS source_snapshot (
                flake_path TEXT PRIMARY KEY,
                files_json TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                updated_at INTEGER NOT NULL DEFAULT (unixepoch())
            );",
        )
        .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(Self { conn })
    }

    /// Look up a cached evaluation result by key.
    pub(crate) fn get(&self, key: &str) -> Result<Option<String>, KixEvalError> {
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
    pub(crate) fn put(&self, key: &str, value: &str) -> Result<(), KixEvalError> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO eval_cache (key, value) VALUES (?1, ?2)",
                [key, value],
            )
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
        Ok(())
    }

    /// Compute a source fingerprint that changes when any tracked input file is
    /// added, removed, or modified.
    ///
    /// Uses a two-level strategy:
    /// 1. **mtime fast path**: collect file paths and modification times; if
    ///    they match the stored snapshot, return the stored content hash
    ///    without reading file contents.
    /// 2. **content hash**: read all tracked files, compute BLAKE3 over sorted
    ///    `(path, content)` pairs, and store the new snapshot.
    pub(crate) fn compute_source_fingerprint(
        &self,
        flake_path: &Path,
    ) -> Result<String, KixEvalError> {
        let canonical = super::store::resolve_symlinks(flake_path);
        let canonical_str = canonical.to_string_lossy().to_string();
        let files = walk_nix_files(&canonical)?;

        let file_map: BTreeMap<&str, u64> = files.iter().map(|(p, m)| (p.as_str(), *m)).collect();
        let current_json = serde_json::to_string(&file_map)
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;

        let stored: Option<(String, String)> = {
            let mut stmt = self
                .conn
                .prepare_cached(
                    "SELECT files_json, content_hash FROM source_snapshot WHERE flake_path = ?1",
                )
                .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
            stmt.query_row([&canonical_str], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .optional()
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?
        };

        if let Some((stored_json, stored_hash)) = stored
            && stored_json == current_json
        {
            tracing::debug!(flake = %canonical.display(), "source fingerprint: mtime fast path hit");
            return Ok(stored_hash);
        }

        tracing::debug!(flake = %canonical.display(), file_count = files.len(), "source fingerprint: computing content hash");
        let mut hasher = blake3::Hasher::new();
        for (rel_path, _) in &files {
            let full_path = canonical.join(rel_path);
            let content = std::fs::read(&full_path)
                .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
            hasher.update(rel_path.as_bytes());
            hasher.update(&content);
        }
        let content_hash = hasher.finalize().to_hex().to_string();

        self.conn
            .execute(
                "INSERT OR REPLACE INTO source_snapshot (flake_path, files_json, content_hash) VALUES (?1, ?2, ?3)",
                [&canonical_str, &current_json, &content_hash],
            )
            .map_err(|e| KixEvalError::CacheError { source: e.into() })?;

        Ok(content_hash)
    }

    /// Compute a cache key that includes the source fingerprint.
    ///
    /// Key = BLAKE3(canonical_path + flake.lock contents + source_fingerprint + attr).
    pub(crate) fn compute_key_with_source(
        flake_path: &Path,
        attr: &str,
        source_fingerprint: &str,
    ) -> Result<String, KixEvalError> {
        let canonical = super::store::resolve_symlinks(flake_path);
        let mut hasher = blake3::Hasher::new();
        hasher.update(canonical.to_string_lossy().as_bytes());

        let lockfile = canonical.join("flake.lock");
        if lockfile.exists() {
            let lock_contents = std::fs::read(&lockfile)
                .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
            hasher.update(&lock_contents);
        }

        hasher.update(source_fingerprint.as_bytes());
        hasher.update(attr.as_bytes());
        Ok(hasher.finalize().to_hex().to_string())
    }
}

/// Walk `flake_path` recursively and collect evaluation input files as
/// `(relative_path, mtime_secs)`.
///
/// Includes `.nix`, `.yaml`, `.yml`, and `.json` files so that changes to files
/// read via `builtins.readFile` invalidate the evaluation cache. Skips `.git`,
/// `.direnv`, `result`, and `node_modules` directories, and sorts results by
/// relative path for deterministic hashing.
pub(crate) fn walk_nix_files(flake_path: &Path) -> Result<Vec<(String, u64)>, KixEvalError> {
    use std::time::UNIX_EPOCH;

    const SKIP_DIRS: &[&str] = &[".git", ".direnv", "result", "node_modules"];
    let mut results = Vec::new();
    let mut stack = vec![flake_path.to_path_buf()];

    while let Some(dir) = stack.pop() {
        let entries =
            std::fs::read_dir(&dir).map_err(|e| KixEvalError::CacheError { source: e.into() })?;

        for entry in entries {
            let entry = entry.map_err(|e| KixEvalError::CacheError { source: e.into() })?;
            let file_type = entry
                .file_type()
                .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
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
                    .map_err(|e| KixEvalError::CacheError { source: e.into() })?
                    .to_string_lossy()
                    .to_string();
                let metadata = std::fs::metadata(&path)
                    .map_err(|e| KixEvalError::CacheError { source: e.into() })?;
                let mtime = metadata
                    .modified()
                    .map_err(|e| KixEvalError::CacheError { source: e.into() })?
                    .duration_since(UNIX_EPOCH)
                    // An mtime before the Unix epoch cannot match the fast path,
                    // forcing a content-hash recompute.
                    .unwrap_or_default()
                    .as_secs();
                results.push((rel, mtime));
            }
        }
    }

    results.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(results)
}

/// Internal extension trait on `rusqlite::OptionalExtension`.
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
    fn fingerprint_stable_when_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("default.nix"), "{ }").unwrap();
        std::fs::write(dir.path().join("lib.nix"), "x: x").unwrap();

        let cache = SqliteCache::open_in_memory().unwrap();
        let fp1 = cache.compute_source_fingerprint(dir.path()).unwrap();
        let fp2 = cache.compute_source_fingerprint(dir.path()).unwrap();
        assert_eq!(fp1, fp2);
    }
}
