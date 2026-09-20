//! Secret hydration — SOPS decryption at deploy time.
//!
//! Scans manifests for K8s Secrets with `kix.run/sops-source` annotations,
//! decrypts the SOPS file via the `sops` CLI, optionally verifies the
//! content hash, and injects the plaintext into `stringData`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::manifest::keys;
use crate::manifest::types::ResourceId;

#[derive(Error, Debug)]
pub enum SecretError {
    #[error("SOPS decryption failed for {path}: {message}")]
    DecryptionFailed { path: String, message: String },

    #[error("SOPS source file not found: {path}")]
    SourceNotFound { path: String },

    #[error(
        "content hash mismatch for secret '{name}': expected {expected}, got {actual}. \
         Check that you are using the intended SOPS file. If the change is intentional, update the secret's hash in its Nix definition and rebuild."
    )]
    HashMismatch {
        name: String,
        expected: String,
        actual: String,
    },

    #[error("failed to parse SOPS output as YAML/JSON for {path}: {message}")]
    ParseFailed { path: String, message: String },
}

/// Result of hydrating a single secret.
#[derive(Debug)]
pub struct HydrationResult {
    pub rid: ResourceId,
    pub keys_injected: usize,
}

/// Check if a manifest is a Secret that needs SOPS hydration.
pub fn needs_hydration(manifest: &Value) -> bool {
    let kind = manifest
        .pointer("/kind")
        .and_then(Value::as_str)
        .unwrap_or("");
    if kind != "Secret" {
        return false;
    }
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::SOPS_SOURCE))
        .and_then(Value::as_str)
        .is_some_and(|s| !s.is_empty())
}

/// Hydrate all secrets in a list of manifests (mutates in place).
///
/// For each Secret with a `kix.run/sops-source` annotation:
/// 1. Locate the SOPS file (store path or repo-relative path)
/// 2. Decrypt via `sops --decrypt`
/// 3. Verify content hash if `kix.run/content-hash` is present
/// 4. Inject decrypted key-value pairs into `stringData`
///
/// Returns the list of hydrated secrets, or the first error encountered.
pub fn hydrate_secrets(manifests: &mut [Value]) -> Result<Vec<HydrationResult>, SecretError> {
    let mut results = Vec::new();

    for manifest in manifests.iter_mut() {
        if !needs_hydration(manifest) {
            continue;
        }

        let result = hydrate_single(manifest)?;
        results.push(result);
    }

    Ok(results)
}

/// Hydrate a single Secret manifest.
fn hydrate_single(manifest: &mut Value) -> Result<HydrationResult, SecretError> {
    let rid = ResourceId::from_value(manifest);

    let sops_source = manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::SOPS_SOURCE))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    let expected_hash = manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::CONTENT_HASH))
        .and_then(Value::as_str)
        .map(|s| s.to_string());

    // Resolve the SOPS file path
    let sops_path = resolve_sops_path(&sops_source)?;

    // Decrypt
    let plaintext = decrypt_sops(&sops_path)?;

    // Parse the decrypted YAML/JSON into key-value pairs
    let data = parse_secret_data(&sops_path, &plaintext)?;

    // Verify content hash if declared
    if let Some(ref expected) = expected_hash {
        let actual = compute_content_hash(&data);
        if &actual != expected {
            return Err(SecretError::HashMismatch {
                name: rid.name.clone(),
                expected: expected.clone(),
                actual,
            });
        }
    }

    let keys_injected = data.len();

    // Inject into stringData
    let string_data: serde_json::Map<String, Value> = data
        .into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();

    if let Some(obj) = manifest.as_object_mut() {
        obj.insert("stringData".to_string(), Value::Object(string_data));
    }

    Ok(HydrationResult { rid, keys_injected })
}

/// Resolve a SOPS source path.
///
/// The path may be:
/// - An absolute path (Nix store path or repo path)
/// - A relative path (relative to CWD / repo root)
fn resolve_sops_path(source: &str) -> Result<PathBuf, SecretError> {
    let path = PathBuf::from(source);

    if path.exists() {
        return Ok(path);
    }

    // Try relative to CWD
    if let Ok(cwd) = std::env::current_dir() {
        let relative = cwd.join(&path);
        if relative.exists() {
            return Ok(relative);
        }
    }

    Err(SecretError::SourceNotFound {
        path: source.to_string(),
    })
}

/// Decrypt a SOPS file using the `sops` CLI.
fn decrypt_sops(path: &Path) -> Result<String, SecretError> {
    let output = Command::new("sops")
        .args(["--decrypt", "--output-type", "json"])
        .arg(path)
        .output()
        .map_err(|e| SecretError::DecryptionFailed {
            path: path.display().to_string(),
            message: format!("failed to run sops: {e}"),
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(SecretError::DecryptionFailed {
            path: path.display().to_string(),
            message: stderr.trim().to_string(),
        });
    }

    String::from_utf8(output.stdout).map_err(|e| SecretError::DecryptionFailed {
        path: path.display().to_string(),
        message: format!("invalid UTF-8 in decrypted output: {e}"),
    })
}

/// Parse decrypted SOPS output into a flat key-value map.
///
/// Supports both flat YAML/JSON (`{ key: value }`) and nested structures
/// (flattened with dot notation isn't needed — K8s Secret data is always flat).
fn parse_secret_data(
    path: &Path,
    plaintext: &str,
) -> Result<BTreeMap<String, String>, SecretError> {
    let value: Value = serde_json::from_str(plaintext).map_err(|e| SecretError::ParseFailed {
        path: path.display().to_string(),
        message: e.to_string(),
    })?;

    let obj = value.as_object().ok_or_else(|| SecretError::ParseFailed {
        path: path.display().to_string(),
        message: "expected a JSON object at top level".to_string(),
    })?;

    let mut data = BTreeMap::new();
    for (key, val) in obj {
        let string_val = match val {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            Value::Bool(b) => b.to_string(),
            other => other.to_string(),
        };
        data.insert(key.clone(), string_val);
    }

    Ok(data)
}

/// Compute a SHA-256 content hash of secret data.
///
/// Uses canonical form: sorted keys, each line is `key=value\n`.
/// Returns `sha256-<base64>` format (matching Nix SRI hashes).
pub fn compute_content_hash(data: &BTreeMap<String, String>) -> String {
    let mut hasher = Sha256::new();
    for (key, value) in data {
        hasher.update(key.as_bytes());
        hasher.update(b"=");
        hasher.update(value.as_bytes());
        hasher.update(b"\n");
    }
    let hash = hasher.finalize();
    let b64 = base64_encode(&hash);
    format!("sha256-{b64}")
}

/// Base64 encode bytes (standard encoding, no padding trimming).
fn base64_encode(bytes: &[u8]) -> String {
    use std::io::Write;
    let mut buf = Vec::new();
    {
        let mut encoder = Base64Encoder::new(&mut buf);
        encoder.write_all(bytes).unwrap();
        encoder.finish().unwrap();
    }
    String::from_utf8(buf).unwrap()
}

/// Minimal base64 encoder (standard alphabet with padding).
struct Base64Encoder<W: std::io::Write> {
    inner: W,
    buf: [u8; 3],
    len: usize,
}

const BASE64_CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

impl<W: std::io::Write> Base64Encoder<W> {
    fn new(inner: W) -> Self {
        Self {
            inner,
            buf: [0; 3],
            len: 0,
        }
    }

    fn flush_buf(&mut self) -> std::io::Result<()> {
        if self.len == 0 {
            return Ok(());
        }
        let b = self.buf;
        let out = match self.len {
            3 => [
                BASE64_CHARS[(b[0] >> 2) as usize],
                BASE64_CHARS[((b[0] & 0x03) << 4 | b[1] >> 4) as usize],
                BASE64_CHARS[((b[1] & 0x0f) << 2 | b[2] >> 6) as usize],
                BASE64_CHARS[(b[2] & 0x3f) as usize],
            ],
            2 => [
                BASE64_CHARS[(b[0] >> 2) as usize],
                BASE64_CHARS[((b[0] & 0x03) << 4 | b[1] >> 4) as usize],
                BASE64_CHARS[((b[1] & 0x0f) << 2) as usize],
                b'=',
            ],
            1 => [
                BASE64_CHARS[(b[0] >> 2) as usize],
                BASE64_CHARS[((b[0] & 0x03) << 4) as usize],
                b'=',
                b'=',
            ],
            _ => unreachable!(),
        };
        self.inner.write_all(&out)?;
        self.len = 0;
        self.buf = [0; 3];
        Ok(())
    }

    fn finish(mut self) -> std::io::Result<W> {
        self.flush_buf()?;
        Ok(self.inner)
    }
}

impl<W: std::io::Write> std::io::Write for Base64Encoder<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        let mut written = 0;
        for &byte in data {
            self.buf[self.len] = byte;
            self.len += 1;
            if self.len == 3 {
                self.flush_buf()?;
            }
            written += 1;
        }
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_needs_hydration_with_sops_source() {
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "test-secret",
                "namespace": "default",
                "annotations": {
                    keys::SOPS_SOURCE: "/nix/store/abc123-secrets.yaml"
                }
            }
        });
        assert!(needs_hydration(&manifest));
    }

    #[test]
    fn test_needs_hydration_without_sops_source() {
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "test-secret",
                "namespace": "default"
            },
            "stringData": {
                "password": "test"
            }
        });
        assert!(!needs_hydration(&manifest));
    }

    #[test]
    fn test_needs_hydration_non_secret() {
        let manifest = json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "app",
                "namespace": "default"
            }
        });
        assert!(!needs_hydration(&manifest));
    }

    #[test]
    fn test_parse_secret_data() {
        let plaintext = r#"{"username": "admin", "password": "s3cret", "port": 5432}"#;
        let data = parse_secret_data(Path::new("test.yaml"), plaintext).unwrap();
        assert_eq!(data.get("username").unwrap(), "admin");
        assert_eq!(data.get("password").unwrap(), "s3cret");
        assert_eq!(data.get("port").unwrap(), "5432");
    }

    #[test]
    fn test_compute_content_hash() {
        let mut data = BTreeMap::new();
        data.insert("password".to_string(), "s3cret".to_string());
        data.insert("username".to_string(), "admin".to_string());
        let hash = compute_content_hash(&data);
        assert!(hash.starts_with("sha256-"));
        // Hash is deterministic for same input
        let hash2 = compute_content_hash(&data);
        assert_eq!(hash, hash2);
    }

    #[test]
    fn test_content_hash_order_independent() {
        // BTreeMap sorts keys, so insertion order doesn't matter
        let mut data1 = BTreeMap::new();
        data1.insert("a".to_string(), "1".to_string());
        data1.insert("b".to_string(), "2".to_string());

        let mut data2 = BTreeMap::new();
        data2.insert("b".to_string(), "2".to_string());
        data2.insert("a".to_string(), "1".to_string());

        assert_eq!(compute_content_hash(&data1), compute_content_hash(&data2));
    }
}
