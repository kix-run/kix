//! SOPS secret decryption at deploy time.
//!
//! Scans manifests for K8s Secrets with `kix.run/sops-source` annotations,
//! decrypts the SOPS file via the `sops` CLI, optionally verifies the
//! content hash, and injects the plaintext into `stringData`.

use std::cell::Cell;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::de::{DeserializeSeed, IgnoredAny};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::build_source::{CarriedSources, SopsSources};
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

#[derive(Error, Debug)]
pub(crate) enum SecretError {
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

    /// A Secret names a SOPS source the build does not carry, or declares
    /// no content hash, when the build carries its SOPS files.
    #[error("secret '{name}': {message}")]
    NotCarried { name: String, message: String },

    /// A SOPS file the build carries is encrypted to something other than
    /// age recipients alone.
    #[error("SOPS file {path} must be encrypted to age recipients only: {message}")]
    NotAgeOnly { path: String, message: String },
}

/// Result of hydrating a single secret.
#[derive(Debug)]
pub(crate) struct HydrationResult {
    pub rid: ResourceId,
    pub keys_injected: usize,
}

/// Check if a manifest is a Secret that needs SOPS hydration.
pub(crate) fn needs_hydration(manifest: &Value) -> bool {
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

/// Hydrate all secrets in a list of manifests (mutates in place), reading
/// SOPS sources from `sources`.
///
/// For each Secret with a `kix.run/sops-source` annotation:
/// 1. Locate the SOPS file (store path or repo-relative path)
/// 2. Decrypt via `sops --decrypt`
/// 3. Verify content hash if `kix.run/content-hash` is present
/// 4. Inject decrypted key-value pairs into `stringData`
///
/// Returns the list of hydrated secrets, or the first error encountered.
///
/// When `sources` is [`SopsSources::Carried`], every referenced source must be
/// present in the carried files, encrypted to `age` recipients only (so
/// decryption never calls a cloud KMS or Vault with local credentials), and
/// paired with a `kix.run/content-hash` annotation on the `Secret`. When
/// `placeholders` is enabled, each key from the SOPS file receives a
/// placeholder value valid for the `Secret` type without running `sops`.
pub(crate) fn hydrate_secrets_from(
    manifests: &mut [Value],
    sources: &SopsSources,
) -> Result<Vec<HydrationResult>, SecretError> {
    let mut results = Vec::new();
    // Validate and decrypt each shared SOPS source at most once.
    let mut read = HashMap::new();

    for manifest in manifests.iter_mut() {
        if !needs_hydration(manifest) {
            continue;
        }

        let result = match sources {
            SopsSources::Local => hydrate_single(manifest)?,
            SopsSources::Carried(carried) => hydrate_carried(manifest, carried, &mut read)?,
        };
        results.push(result);
    }

    Ok(results)
}

/// Cached keys, format, and decrypted values for a carried SOPS source.
struct ReadSource {
    keys: Vec<String>,
    input_type: &'static str,
    data: Option<BTreeMap<String, String>>,
}

fn hydrate_carried(
    manifest: &mut Value,
    carried: &CarriedSources,
    read: &mut HashMap<PathBuf, ReadSource>,
) -> Result<HydrationResult, SecretError> {
    let rid = ResourceId::from_value(manifest);
    let not_carried = |message: String| SecretError::NotCarried {
        name: rid.name.clone(),
        message,
    };
    let source = keys::get(manifest, keys::SOPS_SOURCE)
        .unwrap_or_default()
        .to_string();
    let path = carried
        .files
        .get(&source)
        .ok_or_else(|| not_carried(format!("its SOPS source {source} is not in the build")))?;
    let expected = keys::get(manifest, keys::CONTENT_HASH)
        .map(str::to_string)
        .ok_or_else(|| not_carried(format!("it declares no {}", keys::CONTENT_HASH)))?;
    let source = match read.entry(path.clone()) {
        std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
        std::collections::hash_map::Entry::Vacant(e) => {
            let (keys, input_type) = age_only_keys(path)?;
            e.insert(ReadSource {
                keys,
                input_type,
                data: None,
            })
        }
    };

    let data: BTreeMap<String, String> = if carried.placeholders {
        placeholders(manifest, &source.keys)
    } else {
        let data = match &source.data {
            Some(data) => data.clone(),
            None => {
                let data = parse_secret_data(path, &decrypt_sops(path, Some(source.input_type))?)?;
                source.data.insert(data).clone()
            }
        };
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

/// Generate a placeholder value for each key in `keys` that is valid for
/// `manifest`'s `Secret` type.
///
/// `keys` are read from the cleartext keys of the SOPS file rather than
/// `kix.run/secret-keys` so a dry run validates the exact keys a deploy will
/// write.
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

/// Validate that `path` is a SOPS file encrypted to `age` recipients only, and
/// return its cleartext top-level keys and format (`"json"` or `"yaml"`).
///
/// Uses an allowlist of known SOPS metadata fields so unknown key sources are
/// rejected. Returns the detected format so `sops --input-type` does not rely
/// on the file extension.
fn age_only_keys(path: &Path) -> Result<(Vec<String>, &'static str), SecretError> {
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
    #[cfg(test)]
    AGE_CHECKS.with(|n| n.set(n.get() + 1));
    let text = std::fs::read_to_string(path).map_err(|e| refuse(&e.to_string()))?;
    let input_type = match serde_json::from_str::<IgnoredAny>(&text) {
        Ok(_) => "json",
        Err(_) => "yaml",
    };
    // Reject duplicate keys and oversized expansions before parsing into
    // `Value`, because `Value` keeps the last duplicate key while `sops`
    // rejects duplicates in YAML or merges them in JSON.
    let left = Cell::new(MAX_SOPS_TEXT_BYTES);
    let problem = Cell::new(None);
    let seed = UniqueKeys {
        left: &left,
        problem: &problem,
    };
    let checked = match input_type {
        "json" => {
            let mut de = serde_json::Deserializer::from_str(&text);
            seed.deserialize(&mut de).and_then(|()| de.end()).is_ok()
        }
        _ => seed
            .deserialize(serde_yml::Deserializer::from_str(&text))
            .is_ok(),
    };
    if !checked {
        return Err(refuse(
            problem
                .get()
                .unwrap_or("only YAML or JSON SOPS files can come with a build"),
        ));
    }
    let doc: Value = match input_type {
        "json" => serde_json::from_str(&text).map_err(|e| e.to_string()),
        _ => serde_yml::from_str(&text).map_err(|e| e.to_string()),
    }
    .map_err(|_| refuse("only YAML or JSON SOPS files can come with a build"))?;
    // Go's `encoding/json` matches `"sops"` case-insensitively.
    if let Some(key) = doc
        .as_object()
        .filter(|_| input_type == "json")
        .into_iter()
        .flat_map(|o| o.keys())
        .find(|k| *k != "sops" && folds_to_sops(k))
    {
        return Err(refuse(&format!(
            "sops would read its key {key} as metadata"
        )));
    }
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
    let keys = doc
        .as_object()
        .into_iter()
        .flat_map(|o| o.keys())
        .filter(|k| *k != "sops")
        .cloned()
        .collect();
    Ok((keys, input_type))
}

/// Return whether Go's `encoding/json` matches `key` to the `"sops"` field
/// under Unicode simple case folding (where `ſ`, U+017F, folds to `s`).
fn folds_to_sops(key: &str) -> bool {
    let mut chars = key.chars();
    "sops".chars().all(|want| {
        chars
            .next()
            .is_some_and(|c| c.to_ascii_lowercase() == want || (want == 's' && c == 'ſ'))
    }) && chars.next().is_none()
}

/// Maximum size of a carried SOPS document in bytes, counting one byte per
/// value plus key and string lengths, with YAML aliases counted each time they
/// are expanded.
const MAX_SOPS_TEXT_BYTES: usize = 8 * 1024 * 1024;

/// Deserializer seed that rejects duplicate map keys and documents exceeding
/// [`MAX_SOPS_TEXT_BYTES`] without allocating a value tree.
#[derive(Clone, Copy)]
struct UniqueKeys<'a> {
    left: &'a Cell<usize>,
    problem: &'a Cell<Option<&'static str>>,
}

impl UniqueKeys<'_> {
    /// Count a value, or a key, of `text` bytes.
    fn count<E: serde::de::Error>(self, text: usize) -> Result<(), E> {
        match self.left.get().checked_sub(1 + text) {
            Some(left) => {
                self.left.set(left);
                Ok(())
            }
            None => self.refuse(
                "its keys and values, each YAML alias counted as its anchor's, take more than 8 MiB",
            ),
        }
    }

    fn refuse<E: serde::de::Error>(self, why: &'static str) -> Result<(), E> {
        self.problem.set(Some(why));
        Err(E::custom(why))
    }
}

impl<'de> serde::de::DeserializeSeed<'de> for UniqueKeys<'_> {
    type Value = ();

    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<(), D::Error> {
        d.deserialize_any(self)
    }
}

impl<'de> serde::de::Visitor<'de> for UniqueKeys<'_> {
    type Value = ();

    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a JSON or YAML value")
    }

    fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<(), E> {
        self.count(0)
    }

    fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<(), E> {
        self.count(0)
    }

    fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<(), E> {
        self.count(0)
    }

    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<(), E> {
        self.count(0)
    }

    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<(), E> {
        self.count(v.len())
    }

    fn visit_unit<E: serde::de::Error>(self) -> Result<(), E> {
        self.count(0)
    }

    fn visit_none<E: serde::de::Error>(self) -> Result<(), E> {
        self.count(0)
    }

    fn visit_some<D: serde::Deserializer<'de>>(self, d: D) -> Result<(), D::Error> {
        d.deserialize_any(self)
    }

    fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut seq: A) -> Result<(), A::Error> {
        self.count(0)?;
        while seq.next_element_seed(self)?.is_some() {}
        Ok(())
    }

    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        self.count(0)?;
        let mut seen = std::collections::HashSet::new();
        while let Some(key) = map.next_key::<String>()? {
            self.count(key.len())?;
            if !seen.insert(key) {
                return self.refuse("an object in it repeats a key");
            }
            map.next_value_seed(self)?;
        }
        Ok(())
    }
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

    let sops_path = resolve_sops_path(&sops_source)?;
    let plaintext = decrypt_sops(&sops_path, None)?;
    let data = parse_secret_data(&sops_path, &plaintext)?;

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
fn decrypt_sops(path: &Path, input_type: Option<&str>) -> Result<String, SecretError> {
    let output =
        decrypt_command(path, input_type)
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

/// Build the `sops` command that decrypts `path` to JSON, passing
/// `--input-type` when `input_type` is `Some`.
fn decrypt_command(path: &Path, input_type: Option<&str>) -> Command {
    let mut command = Command::new("sops");
    command.arg("--decrypt");
    if let Some(input_type) = input_type {
        command.args(["--input-type", input_type]);
    }
    command.args(["--output-type", "json"]).arg(path);
    command
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
pub(crate) fn compute_content_hash(data: &BTreeMap<String, String>) -> String {
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

    /// A store name may be 211 characters, and a file name only 255 bytes.
    #[test]
    fn a_carried_source_with_the_longest_store_name_is_written() {
        let name = format!("{}.sops.yaml", "a".repeat(201));
        let path = format!("/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn67-{name}");
        let sources = HashMap::from([(path, b"x: 1\n".to_vec())]);
        assert!(SopsSources::carried(sources, true).is_ok());
    }

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

    fn carried_secret(source: &str, content_hash: Option<&str>) -> Value {
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

    fn from_carried(text: &str, placeholders: bool) -> SopsSources {
        SopsSources::carried(
            HashMap::from([(SOURCE.to_string(), text.as_bytes().to_vec())]),
            placeholders,
        )
        .unwrap()
    }

    #[test]
    fn a_plan_from_a_carried_build_gets_placeholders_typed_for_the_secret() {
        let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
        let text = format!(".dockerconfigjson: ENC[AES256_GCM,data:def]\n{AGE_ONLY}");
        let results = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap();
        assert_eq!(results[0].keys_injected, 2);
        assert_eq!(manifests[0]["stringData"]["password"], "kix-placeholder");
        assert_eq!(
            manifests[0]["stringData"][".dockerconfigjson"],
            r#"{"auths":{}}"#
        );
    }

    /// The annotation is the carried build's word; the SOPS file is what a deploy
    /// writes.
    #[test]
    fn placeholder_keys_come_from_the_sops_file_not_the_annotation() {
        let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
        manifests[0]["metadata"]["annotations"][keys::SECRET_KEYS] = "only-this".into();
        hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap();
        assert_eq!(
            manifests[0]["stringData"],
            json!({"password": "kix-placeholder"})
        );
    }

    #[test]
    fn a_source_the_build_does_not_carry_is_refused() {
        let other = "/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn67-db.sops.yaml";
        let mut manifests = [carried_secret(other, Some("sha256-x"))];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap_err();
        assert!(matches!(err, SecretError::NotCarried { .. }), "{err}");
    }

    #[test]
    fn a_secret_from_a_carried_build_must_declare_a_content_hash() {
        let mut manifests = [carried_secret(SOURCE, None)];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap_err();
        assert!(matches!(err, SecretError::NotCarried { .. }), "{err}");
    }

    /// sops reads a file in the format its extension names unless told
    /// otherwise, and a carried build chooses the name.
    #[test]
    fn a_carried_sops_file_is_decrypted_in_the_format_kix_checked() {
        let json = r#"{"password":"ENC[x]","sops":{"age":[{"recipient":"age1abc","enc":"x"}],"mac":"ENC[x]","version":"3.9.0"}}"#;
        let dir = tempfile::tempdir().unwrap();
        for (text, name, format) in [(AGE_ONLY, "s.ini", "yaml"), (json, "s.yaml", "json")] {
            let path = dir.path().join(name);
            std::fs::write(&path, text).unwrap();
            let (_, input_type) = age_only_keys(&path).unwrap();
            let command = decrypt_command(&path, Some(input_type));
            let args: Vec<&std::ffi::OsStr> = command.get_args().collect();
            assert!(
                args.windows(2).any(|w| w == ["--input-type", format]),
                "{name}: {args:?}"
            );
        }
    }

    /// sops reads JSON metadata with Go's encoding/json, which takes a key
    /// that matches `sops` ignoring case (Unicode simple folding, so `ſ`
    /// matches `s`) and merges a repeated key into the one before it.
    /// serde_json keeps the last of a repeated key and reads `SOPS` as data,
    /// so it could see age alone where sops sees a cloud KMS.
    #[test]
    fn a_json_sops_file_that_go_reads_differently_is_refused() {
        let age = r#"{"age":[{"recipient":"age1abc","enc":"x"}],"mac":"ENC[x]","version":"3.9.0"}"#;
        let kms = r#"{"kms":[{"arn":"arn:aws:kms:eu-west-1:000000000000:key/x"}]}"#;
        let refused = [
            format!(r#"{{"data":"ENC[x]","sops":{age},"SOPS":{kms}}}"#),
            format!(r#"{{"data":"ENC[x]","ſops":{kms},"sops":{age}}}"#),
            format!(r#"{{"data":"ENC[x]","sops":{kms},"sops":{age}}}"#),
            r#"{"data":"ENC[x]","sops":{"kms":[],"age":[],"age":[{"recipient":"age1abc"}]}}"#
                .to_string(),
        ];
        for text in refused {
            let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
            let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
            assert!(
                matches!(err, SecretError::NotAgeOnly { .. }),
                "{text}: {err}"
            );
        }
    }

    /// yaml.v3 matches `sops` exactly, so in YAML a key `SOPS` is data.
    #[test]
    fn a_yaml_sops_file_may_hold_a_key_named_sops_in_capitals() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.yaml");
        let text = AGE_ONLY.replace("password: ", "SOPS: ");
        std::fs::write(&path, text).unwrap();
        let (keys, input_type) = age_only_keys(&path).unwrap();
        assert_eq!((keys, input_type), (vec!["SOPS".to_string()], "yaml"));
    }

    /// sops reads YAML with yaml.v3, which refuses a repeated key and matches
    /// `sops` exactly. serde_yml refuses a repeated key too.
    #[test]
    fn a_yaml_sops_file_with_a_repeated_key_is_refused() {
        let text = format!("sops:\n  kms:\n    - arn: arn:aws:kms:x\n{AGE_ONLY}");
        let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
        assert!(matches!(err, SecretError::NotAgeOnly { .. }), "{err}");
    }

    #[test]
    fn a_carried_sops_file_must_name_age_recipients_only() {
        let refused = [
            AGE_ONLY.replace("kms: []", "kms:\n    - arn: arn:aws:kms:x"),
            AGE_ONLY.replace("kms: []", "key_groups:\n    - pgp: [x]"),
            AGE_ONLY.replace("kms: []", "some_new_kms: x"),
            "password: x\nsops:\n  age: []\n".to_string(),
            "password: x\n".to_string(),
        ];
        for text in refused {
            let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
            let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
            assert!(
                matches!(err, SecretError::NotAgeOnly { .. }),
                "{text}: {err}"
            );
        }
    }

    /// A plan parses a carried build's SOPS file before anyone approves it. The
    /// JSON and YAML parsers' own nesting limits refuse deep nesting before
    /// the check recurses far.
    #[test]
    fn a_deeply_nested_carried_sops_file_is_refused() {
        let deep = format!("{}0{}", "[".repeat(1000), "]".repeat(1000));
        let json = format!(
            r#"{{"x":{deep},"password":"ENC[x]","sops":{{"age":[{{"recipient":"age1abc","enc":"x"}}],"mac":"ENC[x]","version":"3.9.0"}}}}"#
        );
        let yaml = format!("x: {deep}\n{AGE_ONLY}");
        for text in [json, yaml] {
            let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
            let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
            assert!(matches!(&err, SecretError::NotAgeOnly { .. }), "{err}");
        }
    }

    /// Each YAML alias stands for every value of its anchor, so a small
    /// file can stand for many values. Each counts, before the file is
    /// parsed into values.
    #[test]
    fn a_yaml_sops_file_whose_aliases_stand_for_too_many_values_is_refused() {
        let anchor = format!("a: &a [{}]\n", vec!["0"; 5000].join(","));
        let aliases = format!("b: [{}]\n", vec!["*a"; 2000].join(","));
        let text = format!("{anchor}{aliases}{AGE_ONLY}");
        let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
        assert!(
            matches!(&err, SecretError::NotAgeOnly { message, .. } if message.contains("8 MiB")),
            "{err}"
        );
    }

    /// Expanding a YAML alias of a long string copies the string on each use,
    /// so key and string bytes are counted with aliases expanded before
    /// building a `Value`.
    #[test]
    fn a_yaml_sops_file_whose_aliases_stand_for_too_many_bytes_is_refused() {
        let anchor = format!("a: &a {}\n", "x".repeat(1 << 20));
        let aliases = format!("b: [{}]\n", ["*a"; 10].join(","));
        let text = format!("{anchor}{aliases}{AGE_ONLY}");
        let mut manifests = [carried_secret(SOURCE, Some("sha256-x"))];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
        assert!(
            matches!(&err, SecretError::NotAgeOnly { message, .. } if message.contains("8 MiB")),
            "{err}"
        );
    }

    /// Any number of Secrets may name one source, and a plan checks it
    /// once.
    #[test]
    fn a_source_many_secrets_name_is_checked_once() {
        let mut manifests: Vec<Value> = (0..1000)
            .map(|i| {
                let mut secret = carried_secret(SOURCE, Some("sha256-x"));
                secret["metadata"]["name"] = json!(format!("db{i}"));
                secret
            })
            .collect();
        AGE_CHECKS.with(|n| n.set(0));
        let results = hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap();
        assert_eq!(results.len(), 1000);
        assert_eq!(AGE_CHECKS.with(|n| n.get()), 1);
    }
}

#[cfg(test)]
thread_local! {
    /// How many SOPS files [`age_only_keys`] has checked on this thread.
    static AGE_CHECKS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}
