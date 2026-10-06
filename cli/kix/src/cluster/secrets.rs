//! SOPS secret decryption at deploy time.
//!
//! Scans manifests for K8s Secrets with `kix.run/sops-source` annotations,
//! decrypts the SOPS file via the `sops` CLI, optionally verifies the
//! content hash, and injects the plaintext into `stringData`.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

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
        "content hash mismatch for secret '{name}': expected {expected}. \
         Check that you are using the intended SOPS file. If the change is intentional, update the secret's hash in its Nix definition and rebuild."
    )]
    HashMismatch {
        name: String,
        expected: String,
        actual: String,
    },

    #[error("failed to parse SOPS output as YAML/JSON for {path}: {message}")]
    ParseFailed { path: String, message: String },

    /// A bundle's Secret names a SOPS source the bundle does not carry, or
    /// carries none and no content hash.
    #[error("secret '{name}': {message}")]
    NotInBundle { name: String, message: String },

    /// A SOPS file from a bundle is encrypted to something other than age
    /// recipients alone.
    #[error("SOPS file {path} must be encrypted to age recipients only: {message}")]
    NotAgeOnly { path: String, message: String },
}

/// Where SOPS sources are read from.
#[derive(Debug, Clone, Default)]
pub enum SopsSources {
    /// The path in each Secret's `kix.run/sops-source`, on this machine.
    #[default]
    Local,
    /// Only the files a bundle carries ([`SopsSources::from_bundle`]).
    Bundle(Arc<BundleSources>),
}

/// The SOPS files of a bundle, written to a private directory.
#[derive(Debug)]
pub struct BundleSources {
    /// Store path named by `kix.run/sops-source` to the file on disk.
    files: HashMap<String, PathBuf>,
    /// Plan without decrypting: each Secret gets placeholder values for
    /// the keys it declares.
    placeholders: bool,
    _dir: tempfile::TempDir,
}

impl SopsSources {
    /// Write a bundle's SOPS files to a fresh directory, each under its
    /// SHA-256 and its store name (sops tells the format by the extension),
    /// and read them only from there.
    pub fn from_bundle(
        sources: HashMap<String, Vec<u8>>,
        placeholders: bool,
    ) -> std::io::Result<Self> {
        let dir = tempfile::tempdir()?;
        let mut files = HashMap::new();
        for (store_path, bytes) in sources {
            let digest: String = Sha256::digest(&bytes)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            let name = crate::eval::store_path::name_of(&store_path).unwrap_or("source");
            let file = dir.path().join(format!("{digest}-{name}"));
            std::fs::write(&file, &bytes)?;
            files.insert(store_path, file);
        }
        Ok(SopsSources::Bundle(Arc::new(BundleSources {
            files,
            placeholders,
            _dir: dir,
        })))
    }
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
    hydrate_secrets_from(manifests, &SopsSources::Local)
}

/// [`hydrate_secrets`], reading SOPS sources from `sources`.
///
/// From a bundle, a source must be one of the bundle's files, the file must
/// be encrypted to age recipients only (so decrypting never reaches a cloud
/// KMS or Vault with this machine's credentials), and the Secret must
/// declare a content hash. With placeholders, nothing is decrypted: each
/// declared key (`kix.run/secret-keys`) gets a value valid for the Secret's
/// type.
pub fn hydrate_secrets_from(
    manifests: &mut [Value],
    sources: &SopsSources,
) -> Result<Vec<HydrationResult>, SecretError> {
    let mut results = Vec::new();

    for manifest in manifests.iter_mut() {
        if !needs_hydration(manifest) {
            continue;
        }

        let result = match sources {
            SopsSources::Local => hydrate_single(manifest)?,
            SopsSources::Bundle(bundle) => hydrate_from_bundle(manifest, bundle)?,
        };
        results.push(result);
    }

    Ok(results)
}

fn hydrate_from_bundle(
    manifest: &mut Value,
    bundle: &BundleSources,
) -> Result<HydrationResult, SecretError> {
    let rid = ResourceId::from_value(manifest);
    let not_in_bundle = |message: String| SecretError::NotInBundle {
        name: rid.name.clone(),
        message,
    };
    let source = keys::get(manifest, keys::SOPS_SOURCE)
        .unwrap_or_default()
        .to_string();
    let path = bundle
        .files
        .get(&source)
        .ok_or_else(|| not_in_bundle(format!("its SOPS source {source} is not in the bundle")))?;
    let expected = keys::get(manifest, keys::CONTENT_HASH)
        .map(str::to_string)
        .ok_or_else(|| not_in_bundle(format!("it declares no {}", keys::CONTENT_HASH)))?;
    let clear_keys = age_only_keys(path)?;

    let data: BTreeMap<String, String> = if bundle.placeholders {
        placeholders(manifest, &clear_keys)
    } else {
        let data = parse_secret_data(path, &decrypt_sops(path)?)?;
        if compute_content_hash(&data) != expected {
            return Err(SecretError::HashMismatch {
                name: rid.name.clone(),
                expected,
                actual: String::new(),
            });
        }
        data
    };
    let keys_injected = data.len();
    let string_data: serde_json::Map<String, Value> = data
        .into_iter()
        .map(|(k, v)| (k, Value::String(v)))
        .collect();
    if let Some(obj) = manifest.as_object_mut() {
        obj.insert("stringData".to_string(), Value::Object(string_data));
    }
    Ok(HydrationResult { rid, keys_injected })
}

/// A value for each of `keys`, valid for the Secret's type, so a dry run
/// passes the API server's own checks without the real values.
///
/// The keys come from the SOPS file, where they are stored in clear, and
/// not from the Secret's own annotation: they are the keys a deploy will
/// write, so the plan shows exactly those.
fn placeholders(manifest: &Value, keys: &[String]) -> BTreeMap<String, String> {
    let secret_type = manifest
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("Opaque");
    keys.iter()
        .map(|key| {
            let value = match (secret_type, key.as_str()) {
                ("kubernetes.io/dockerconfigjson", ".dockerconfigjson") => r#"{"auths":{}}"#,
                ("kubernetes.io/dockercfg", ".dockercfg") => "{}",
                _ => "kix-placeholder",
            };
            (key.clone(), value.to_string())
        })
        .collect()
}

/// Refuse a SOPS file whose metadata names any key source but age, and
/// return the file's keys (stored in clear; only values are encrypted).
///
/// An allowlist: SOPS adds key sources over time (and `key_groups` can hold
/// any of them), so a field this code does not know is refused.
fn age_only_keys(path: &Path) -> Result<Vec<String>, SecretError> {
    /// Metadata that names no key.
    const NOT_KEYS: &[&str] = &[
        "lastmodified",
        "mac",
        "mac_only_encrypted",
        "version",
        "unencrypted_suffix",
        "encrypted_suffix",
        "unencrypted_regex",
        "encrypted_regex",
        "unencrypted_comment_regex",
        "encrypted_comment_regex",
        "shamir_threshold",
    ];
    let refuse = |message: &str| SecretError::NotAgeOnly {
        path: path.display().to_string(),
        message: message.to_string(),
    };
    let text = std::fs::read_to_string(path).map_err(|e| refuse(&e.to_string()))?;
    let doc: Value = serde_yml::from_str(&text)
        .map_err(|_| refuse("only YAML or JSON SOPS files can come from a bundle"))?;
    let sops = doc
        .get("sops")
        .and_then(Value::as_object)
        .ok_or_else(|| refuse("it has no sops metadata"))?;
    for (field, value) in sops {
        let empty = match value {
            Value::Null => true,
            Value::Array(a) => a.is_empty(),
            Value::String(s) => s.is_empty(),
            _ => false,
        };
        if field != "age" && !NOT_KEYS.contains(&field.as_str()) && !empty {
            return Err(refuse(&format!("it also names {field}")));
        }
    }
    match sops.get("age") {
        Some(Value::Array(a)) if !a.is_empty() => {}
        _ => return Err(refuse("it names no age recipient")),
    }
    Ok(doc
        .as_object()
        .into_iter()
        .flat_map(|o| o.keys())
        .filter(|k| *k != "sops")
        .cloned()
        .collect())
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
/// without flattening nested values because Kubernetes Secret data is flat.
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

    const SOURCE: &str = "/nix/store/yxyad967bhmxvm5120mrjnrrr7ak087w-db.sops.yaml";
    const AGE_ONLY: &str = "password: ENC[AES256_GCM,data:abc]\nsops:\n  kms: []\n  age:\n    - recipient: age1abc\n      enc: x\n  lastmodified: '2026-10-06T00:00:00Z'\n  mac: ENC[x]\n  version: 3.9.0\n";

    fn bundle_secret(source: &str, content_hash: Option<&str>) -> Value {
        let mut annotations = serde_json::json!({
            (keys::SOPS_SOURCE): source,
            (keys::SECRET_KEYS): "password, .dockerconfigjson",
        });
        if let Some(h) = content_hash {
            annotations[keys::CONTENT_HASH] = serde_json::json!(h);
        }
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "type": "kubernetes.io/dockerconfigjson",
            "metadata": {"name": "db", "namespace": "app", "annotations": annotations},
        })
    }

    fn from_bundle(text: &str, placeholders: bool) -> SopsSources {
        SopsSources::from_bundle(
            HashMap::from([(SOURCE.to_string(), text.as_bytes().to_vec())]),
            placeholders,
        )
        .unwrap()
    }

    #[test]
    fn a_plan_from_a_bundle_gets_placeholders_typed_for_the_secret() {
        let mut manifests = [bundle_secret(SOURCE, Some("sha256-x"))];
        let text = format!(".dockerconfigjson: ENC[AES256_GCM,data:def]\n{AGE_ONLY}");
        let results = hydrate_secrets_from(&mut manifests, &from_bundle(&text, true)).unwrap();
        assert_eq!(results[0].keys_injected, 2);
        assert_eq!(manifests[0]["stringData"]["password"], "kix-placeholder");
        assert_eq!(
            manifests[0]["stringData"][".dockerconfigjson"],
            r#"{"auths":{}}"#
        );
    }

    /// The annotation is the bundle's word; the SOPS file is what a deploy
    /// writes.
    #[test]
    fn placeholder_keys_come_from_the_sops_file_not_the_annotation() {
        let mut manifests = [bundle_secret(SOURCE, Some("sha256-x"))];
        manifests[0]["metadata"]["annotations"][keys::SECRET_KEYS] = "only-this".into();
        hydrate_secrets_from(&mut manifests, &from_bundle(AGE_ONLY, true)).unwrap();
        assert_eq!(
            manifests[0]["stringData"],
            json!({"password": "kix-placeholder"})
        );
    }

    #[test]
    fn a_source_the_bundle_does_not_carry_is_refused() {
        let other = "/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn67-db.sops.yaml";
        let mut manifests = [bundle_secret(other, Some("sha256-x"))];
        let err = hydrate_secrets_from(&mut manifests, &from_bundle(AGE_ONLY, true)).unwrap_err();
        assert!(matches!(err, SecretError::NotInBundle { .. }), "{err}");
    }

    #[test]
    fn a_secret_from_a_bundle_must_declare_a_content_hash() {
        let mut manifests = [bundle_secret(SOURCE, None)];
        let err = hydrate_secrets_from(&mut manifests, &from_bundle(AGE_ONLY, true)).unwrap_err();
        assert!(matches!(err, SecretError::NotInBundle { .. }), "{err}");
    }

    #[test]
    fn a_bundle_sops_file_must_name_age_recipients_only() {
        let refused = [
            AGE_ONLY.replace("kms: []", "kms:\n    - arn: arn:aws:kms:x"),
            AGE_ONLY.replace("kms: []", "key_groups:\n    - pgp: [x]"),
            AGE_ONLY.replace("kms: []", "some_new_kms: x"),
            "password: x\nsops:\n  age: []\n".to_string(),
            "password: x\n".to_string(),
        ];
        for text in refused {
            let mut manifests = [bundle_secret(SOURCE, Some("sha256-x"))];
            let err = hydrate_secrets_from(&mut manifests, &from_bundle(&text, true)).unwrap_err();
            assert!(
                matches!(err, SecretError::NotAgeOnly { .. }),
                "{text}: {err}"
            );
        }
    }
}
