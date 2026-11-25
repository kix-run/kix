//! SOPS secret decryption at deploy time.
//!
//! Scans manifests for K8s Secrets with `kix.run/sops-source` annotations,
//! checks the SOPS file against `kix.run/sops-digest`, decrypts it via the
//! `sops` CLI, and injects the plaintext into `stringData`.

use std::cell::Cell;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::de::{DeserializeSeed, IgnoredAny};
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::build_source::{CarriedSources, SopsSources};
use crate::eval::store::disk_path;
use crate::manifest::keys;
use crate::manifest::types::ResourceId;
use crate::runtime::{self, RuntimeError, Tool, Want};

#[derive(Error, Debug)]
pub(crate) enum SecretError {
    #[error("SOPS decryption failed for {path}: {message}")]
    DecryptionFailed { path: String, message: String },

    /// `sops` exited with [`SOPS_NO_DATA_KEY`]: no key the file is encrypted
    /// to gave it the data key. `message` is what `sops` wrote to stderr.
    #[error(
        "cannot decrypt SOPS file {}: `sops` could not get a decryption key\n  \
         Kix did not apply this Secret, and any existing Secret on the cluster is unchanged. \
         No matching key is configured, or `sops` could not reach or use the key service (age, PGP, cloud KMS, or Vault).\n\n  \
         Next:\n    \
         - For `kix plan`, `kix deploy`, or `kix rollback`: set `SOPS_AGE_KEY_FILE` (or configure your cloud KMS, Vault, or PGP key) on the machine running `kix`, then run the command again.\n    \
         - With `--operator`: configure the key on the Kix operator pod. The operator retries every 30 seconds (up to 10 times by default; set `KIX_DEPLOY_RETRIES` to change this) before marking the deploy `Failed`. If it is already `Failed`, run the command again. See https://kix.run/docs/reference/cli/operator-mode/#secrets-from-sops-files.\n\n  \
         sops error:\n    {}",
        sops_file_name(path),
        message.replace('\n', "\n    ")
    )]
    NoKey { path: String, message: String },

    #[error("SOPS source file not found: {path}")]
    SourceNotFound { path: String },

    /// The SOPS file's bytes do not match the `kix.run/sops-digest` the build
    /// recorded. `sops_source` is the Secret's `kix.run/sops-source`.
    #[error(
        "SOPS file {} for Secret '{name}' is not the file Kix built from: its SHA-256 does not match the digest the build recorded. Nothing was decrypted. Build the cluster again, or create a new bundle with `kix bundle <cluster>`, and run the command again.",
        sops_file_name(sops_source)
    )]
    DigestMismatch { name: String, sops_source: String },

    /// A bundle made by Kix 0.9 or earlier carries a hash of the SOPS file's
    /// values instead of a digest of the file, and the decrypted values do
    /// not match it.
    // Remove six months after 0.10.0, when no supported bundle lacks a digest.
    #[error(
        "the values in SOPS file {} do not match the hash the bundle records for Secret '{name}'. Create a new bundle with `kix bundle <cluster>` and run `kix deploy` again.",
        sops_file_name(sops_source)
    )]
    HashMismatch { name: String, sops_source: String },

    #[error("failed to parse SOPS output as YAML/JSON for {path}: {message}")]
    ParseFailed { path: String, message: String },

    /// A top-level value of the SOPS file is a map, a list, or null, so it has
    /// no text to write as the value of a Secret key.
    #[error(
        "[K6746] SOPS file {file}: top-level key \"{key}\" is {found}\n      \
         Kix cannot build this Secret from the file; any existing Secret on the cluster is unchanged.\n\n      \
         Each top-level key in {file} becomes a Secret key, so every value must be a string, a number, `true`, or `false` (store JSON for a single key as a string). \
         Use a flat YAML or JSON map (local deploys also accept dotenv; bundles do not). \
         INI files cannot be used because `sops` groups keys into section maps such as \"DEFAULT\".\n\n      \
         If {file} is an encrypted Kubernetes Secret manifest (for example from Flux):\n        \
         1. Check `.sops.yaml`: the rule matching <new-file> must not set `encrypted_regex` (`^(data|stringData)$` leaves a flat file in plain text).\n        \
         2. Extract the keys and encrypt the new file:\n             \
         sops decrypt --extract '[\"stringData\"]' <flux-file> > <new-file>\n             \
         sops encrypt --in-place <new-file>\n           \
         If the manifest uses `data` instead of `stringData`, base64-decode those values before encrypting.\n        \
         3. Confirm every value in <new-file> is `ENC[...]`, and delete any plain-text copies.\n      \
         Then run `kix deploy` again (for a bundle, build a new one with `kix bundle <cluster>` first). \
         If `kix rollback` hit this error, editing {file} now will not change that older build: pick a newer deployment record, or check out the commit you want, convert {file}, and run `kix deploy`.",
        file = sops_file_name(path)
    )]
    NotFlat {
        path: String,
        key: String,
        found: &'static str,
    },

    /// A Secret names a SOPS source the build does not carry, or records no
    /// digest of it, when the build carries its SOPS files.
    #[error("secret '{name}': {message}")]
    NotCarried { name: String, message: String },

    /// A SOPS file the build carries is encrypted to something other than
    /// age recipients alone.
    #[error(
        "cannot use bundled SOPS file {path}\n  \
         Nothing was applied to the cluster.\n\n  \
         Why:\n    \
         {message}\n\n  \
         Next:\n    \
         Fix the SOPS file in your project, create a new bundle with `kix bundle <cluster>`, and run `kix deploy` again."
    )]
    NotAgeOnly { path: String, message: String },
}

/// Return the file name of a SOPS source for messages, without the store
/// hash that Kix's local store puts in front of it.
fn sops_file_name(source: &str) -> &str {
    let base = Path::new(source)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(source);
    match base.split_at_checked(33) {
        Some((prefix, name))
            if !name.is_empty()
                && prefix.ends_with('-')
                && prefix[..32]
                    .bytes()
                    .all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()) =>
        {
            name
        }
        _ => base,
    }
}

/// Return the SHA-256 of the file at `path` in hex, as `builtins.hashFile
/// "sha256"` writes it to `kix.run/sops-digest`.
fn file_digest(path: &Path) -> Result<String, SecretError> {
    let bytes = std::fs::read(path).map_err(|_| SecretError::SourceNotFound {
        path: path.display().to_string(),
    })?;
    Ok(Sha256::digest(&bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// Check `actual`, the digest of the SOPS file Kix is about to decrypt,
/// against the Secret's `kix.run/sops-digest`. A build without the annotation
/// passes.
fn check_digest(manifest: &Value, actual: &str) -> Result<(), SecretError> {
    match keys::get(manifest, keys::SOPS_DIGEST) {
        Some(expected) if expected != actual => Err(SecretError::DigestMismatch {
            name: ResourceId::from_value(manifest).name,
            sops_source: keys::get(manifest, keys::SOPS_SOURCE)
                .unwrap_or_default()
                .to_string(),
        }),
        _ => Ok(()),
    }
}

/// Result of hydrating a single secret.
#[derive(Debug)]
pub(crate) struct HydrationResult {
    pub rid: ResourceId,
    pub keys_injected: usize,
}

/// Check if a manifest is a Secret that needs SOPS hydration.
pub(crate) fn needs_hydration(manifest: &Value) -> bool {
    if !crate::manifest::types::is_secret(manifest) {
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
/// 2. Check its bytes against `kix.run/sops-digest` when present
/// 3. Decrypt via `sops --decrypt`
/// 4. Inject decrypted key-value pairs into `stringData`
///
/// Returns the list of hydrated secrets, or the first error encountered.
///
/// When `sources` is [`SopsSources::Carried`], every referenced source must be
/// present in the carried files, encrypted to `age` recipients only (so
/// decryption never calls a cloud KMS or Vault with local credentials), and
/// match the `kix.run/sops-digest` annotation on the `Secret`. When
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

/// Cached digest, keys, format, and decrypted values for a carried SOPS
/// source.
struct ReadSource {
    digest: String,
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
    let source_name = keys::get(manifest, keys::SOPS_SOURCE)
        .unwrap_or_default()
        .to_string();
    let path = carried
        .files
        .get(&source_name)
        .ok_or_else(|| not_carried(format!("its SOPS source {source_name} is not in the build")))?;
    // A bundle from Kix 0.9 or earlier records a hash of the decrypted values
    // instead of a digest of the file.
    let old_hash = keys::get(manifest, keys::CONTENT_HASH)
        .filter(|_| keys::get(manifest, keys::SOPS_DIGEST).is_none())
        .map(str::to_string);
    if old_hash.is_none() && keys::get(manifest, keys::SOPS_DIGEST).is_none() {
        return Err(not_carried(format!("it records no {}", keys::SOPS_DIGEST)));
    }
    let source = match read.entry(path.clone()) {
        std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
        std::collections::hash_map::Entry::Vacant(e) => {
            let digest = file_digest(path)?;
            let (keys, input_type) = age_only_keys(path)?;
            e.insert(ReadSource {
                digest,
                keys,
                input_type,
                data: None,
            })
        }
    };
    check_digest(manifest, &source.digest)?;

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
        if let Some(expected) = old_hash
            && compute_content_hash(&data) != expected
        {
            return Err(SecretError::HashMismatch {
                name: rid.name.clone(),
                sops_source: source_name,
            });
        }
        data
    };
    let keys_injected = data.len();
    merge_string_data(manifest, data);
    Ok(HydrationResult { rid, keys_injected })
}

/// Add the decrypted keys to the Secret's `stringData`, keeping the keys
/// the build wrote there in plain text. A Secret can mix the two: a database
/// credentials Secret carries `username` and `host` inline and `password`
/// from the SOPS file. A key in both takes the SOPS value.
fn merge_string_data(manifest: &mut Value, data: BTreeMap<String, String>) {
    let Some(obj) = manifest.as_object_mut() else {
        return;
    };
    let string_data = obj
        .entry("stringData")
        .or_insert_with(|| Value::Object(serde_json::Map::new()));
    if !string_data.is_object() {
        *string_data = Value::Object(serde_json::Map::new());
    }
    if let Some(map) = string_data.as_object_mut() {
        for (key, value) in data {
            map.insert(key, Value::String(value));
        }
    }
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
    let text = std::fs::read_to_string(path).map_err(|e| {
        refuse(&format!(
            "Kix could not read the file from the bundle: {e}."
        ))
    })?;
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
        _ => serde_saphyr::with_deserializer_from_str_with_options(
            &text,
            sops_read_options(),
            |de| seed.deserialize(de),
        )
        .is_ok(),
    };
    if !checked {
        return Err(refuse(
            problem
                .get()
                .unwrap_or("Bundles only support YAML or JSON SOPS files. Re-encrypt this secret as a YAML or JSON SOPS file."),
        ));
    }
    let doc: Value = match input_type {
        "json" => serde_json::from_str(&text).map_err(|e| e.to_string()),
        _ => serde_saphyr::from_str_with_options(&text, sops_read_options())
            .map_err(|e| e.to_string()),
    }
    .map_err(|_| refuse("Bundles only support YAML or JSON SOPS files. Re-encrypt this secret as a YAML or JSON SOPS file."))?;
    // Go's `encoding/json` matches `"sops"` case-insensitively.
    if let Some(key) = doc
        .as_object()
        .filter(|_| input_type == "json")
        .into_iter()
        .flat_map(|o| o.keys())
        .find(|k| *k != "sops" && folds_to_sops(k))
    {
        return Err(refuse(&format!(
            "It contains a top-level key named `{key}`, which `sops` reserves for its own metadata and would not decrypt as secret data."
        )));
    }
    let sops = doc
        .get("sops")
        .and_then(Value::as_object)
        .ok_or_else(|| refuse("It has no `sops` metadata block, so it is not encrypted with `sops` (encrypt it with `sops` before bundling)."))?;
    for (field, value) in sops {
        let empty = match value {
            Value::Null => true,
            Value::Array(a) => a.is_empty(),
            Value::String(s) => s.is_empty(),
            _ => false,
        };
        if field != "age" && !NOT_KEYS.contains(&field.as_str()) && !empty {
            return Err(refuse(&format!(
                "Its `sops` metadata uses `{field}`, and bundled SOPS files must be encrypted to `age` recipients only."
            )));
        }
    }
    match sops.get("age") {
        Some(Value::Array(a)) if !a.is_empty() => {}
        _ => {
            return Err(refuse(
                "Its `sops` metadata lists no `age` recipients, and bundled SOPS files must be encrypted to at least one `age` recipient.",
            ));
        }
    }
    let entries = doc
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(k, _)| *k != "sops");
    let keys = flat_values(path, entries)?.into_keys().collect();
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

/// Return the YAML reader options for a carried SOPS file.
///
/// [`UniqueKeys`] counts every value an alias expands to and refuses past
/// [`MAX_SOPS_TEXT_BYTES`] with a message that says so. The YAML reader's own
/// cap on replayed alias events is raised above what that count admits, so the
/// count refuses first. Each counted value is at most two events.
fn sops_read_options() -> serde_saphyr::Options {
    let mut options = crate::yaml::read_options();
    options.alias_limits.max_total_replayed_events = 2 * MAX_SOPS_TEXT_BYTES + 1024;
    options
}

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
                "Its keys and values (counting each YAML alias at the full size of its target) exceed the 8 MiB limit for a bundled SOPS file.",
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
                return self.refuse("A mapping in this file defines the same key more than once, which could cause Kix and `sops` to read different values.");
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

    let sops_path = resolve_sops_path(&sops_source)?;
    if keys::get(manifest, keys::SOPS_DIGEST).is_some() {
        check_digest(manifest, &file_digest(&sops_path)?)?;
    }
    let plaintext = decrypt_sops(&sops_path, None)?;
    let data = parse_secret_data(&sops_path, &plaintext)?;

    let keys_injected = data.len();
    merge_string_data(manifest, data);
    Ok(HydrationResult { rid, keys_injected })
}

/// Resolve a SOPS source path.
///
/// The path may be:
/// - An absolute path (Nix store path or repo path)
/// - A relative path (relative to CWD / repo root)
fn resolve_sops_path(source: &str) -> Result<PathBuf, SecretError> {
    let path = PathBuf::from(source);

    if let Ok(on_disk) = disk_path(&path)
        && on_disk.exists()
    {
        return Ok(on_disk);
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

/// The exit status `sops` returns when no key the file is encrypted to
/// yields the data key (`CouldNotRetrieveKey` in sops'
/// `cmd/sops/codes/codes.go`). It covers a missing key, a key that does not
/// match, a denied key service, and a key service that cannot be reached.
const SOPS_NO_DATA_KEY: i32 = 128;

/// Decrypt a SOPS file using the `sops` CLI.
fn decrypt_sops(path: &Path, input_type: Option<&str>) -> Result<String, SecretError> {
    let failed = |message: String| SecretError::DecryptionFailed {
        path: path.display().to_string(),
        message,
    };
    let output = decrypt_command(path, input_type)
        .map_err(|e| failed(e.to_string()))?
        .output()
        .map_err(|e| failed(format!("failed to run sops: {e}")))?;
    decrypted(path, output)
}

/// Return the plaintext `sops` wrote for `path`, or the error its exit
/// status and stderr describe.
fn decrypted(path: &Path, output: std::process::Output) -> Result<String, SecretError> {
    let path_text = path.display().to_string();
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(match output.status.code() {
            Some(SOPS_NO_DATA_KEY) => SecretError::NoKey {
                path: path_text,
                message,
            },
            _ => SecretError::DecryptionFailed {
                path: path_text,
                message,
            },
        });
    }

    String::from_utf8(output.stdout).map_err(|e| SecretError::DecryptionFailed {
        path: path_text,
        message: format!("invalid UTF-8 in decrypted output: {e}"),
    })
}

/// Build the `sops` command that decrypts `path` to JSON, passing
/// `--input-type` when `input_type` is `Some`.
fn decrypt_command(path: &Path, input_type: Option<&str>) -> Result<Command, RuntimeError> {
    let mut command = runtime::tool(Tool::Sops, Want::Shipped)?;
    command.arg("--decrypt");
    if let Some(input_type) = input_type {
        command.args(["--input-type", input_type]);
    }
    command.args(["--output-type", "json"]).arg(path);
    Ok(command)
}

/// Parse decrypted SOPS output into the Secret's keys and values.
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
    flat_values(path, obj.iter())
}

/// Return each top-level entry of a SOPS document as a Secret key and its
/// text, or refuse the first value that has no text.
///
/// A Secret holds one string per key, so a value must be a string, a number,
/// or a boolean. A map, a list, or null is refused. A Kubernetes manifest
/// in the file fails this check at its `metadata`.
///
/// `sops` keeps the shape of a document when it encrypts it, so the check
/// gives the same answer on the encrypted file as on the decrypted one.
fn flat_values<'a>(
    path: &Path,
    entries: impl IntoIterator<Item = (&'a String, &'a Value)>,
) -> Result<BTreeMap<String, String>, SecretError> {
    entries
        .into_iter()
        .map(|(key, value)| {
            let text = match value {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Object(_) | Value::Array(_) | Value::Null => {
                    return Err(SecretError::NotFlat {
                        path: path.display().to_string(),
                        key: key.clone(),
                        found: match value {
                            Value::Object(_) => "a map",
                            Value::Array(_) => "a list",
                            _ => "empty (`null`)",
                        },
                    });
                }
            };
            Ok((key.clone(), text))
        })
        .collect()
}

/// Compute the hash of secret data that Kix 0.9 and earlier wrote to
/// `kix.run/content-hash`: SHA-256 over sorted `key=value\n` lines, as
/// `sha256-<base64>`.
fn compute_content_hash(data: &BTreeMap<String, String>) -> String {
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

        let mut custom = manifest;
        custom["apiVersion"] = json!("example.com/v1");
        assert!(
            !needs_hydration(&custom),
            "a custom kind named Secret gets no decrypted values"
        );
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

    /// A Flux SOPS file holds a whole Secret manifest. Its top-level keys are
    /// the manifest's fields, so it must not become a Secret with keys
    /// `apiVersion`, `kind`, `metadata`, and `stringData`.
    #[test]
    fn a_decrypted_document_that_is_not_flat_is_refused() {
        let cases = [
            (
                r#"{"apiVersion":"v1","kind":"Secret","metadata":{"name":"api"},"stringData":{"password":"p"},"type":"Opaque"}"#,
                "metadata",
                "a map",
            ),
            (r#"{"password":"p","hosts":["a","b"]}"#, "hosts", "a list"),
            (
                r#"{"password":"p","token":null}"#,
                "token",
                "empty (`null`)",
            ),
        ];
        for (plaintext, want_key, want_found) in cases {
            let err = parse_secret_data(Path::new("/x/api.enc.yaml"), plaintext).unwrap_err();
            assert!(
                matches!(&err, SecretError::NotFlat { key, found, .. } if key == want_key && *found == want_found),
                "{plaintext}: {err}"
            );
            assert!(err.to_string().starts_with("[K6746] "), "{err}");
        }

        // sops decrypts an INI file into sections, so it fails at `DEFAULT`,
        // and the message says INI cannot be used.
        let ini = r#"{"DEFAULT":{"username":"app","password":"p"}}"#;
        let err = parse_secret_data(Path::new("/x/api.enc.ini"), ini).unwrap_err();
        assert!(
            matches!(&err, SecretError::NotFlat { key, .. } if key == "DEFAULT"),
            "{err}"
        );
        assert!(
            err.to_string().contains("INI files cannot be used"),
            "{err}"
        );
    }

    /// `sops` keeps a document's shape when it encrypts it, so a plan on a
    /// carried build refuses a Flux manifest before anything is decrypted.
    #[test]
    fn a_carried_sops_file_that_is_not_flat_is_refused_without_decrypting() {
        let text = AGE_ONLY.replace(
            "password: ENC[AES256_GCM,data:abc]\n",
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: api\nstringData:\n  password: ENC[AES256_GCM,data:abc]\ntype: Opaque\n",
        );
        let mut manifests = [carried_secret(SOURCE, Some(&digest_of(&text)))];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(&text, true)).unwrap_err();
        assert!(
            matches!(&err, SecretError::NotFlat { key, .. } if key == "metadata"),
            "{err}"
        );
    }

    /// Encrypt a Flux Secret manifest and a flat file with the `sops` that
    /// Kix ships, then read both the way a deploy and a bundle plan do. The
    /// key is the test-only key in `clusters/dev-secrets/age-key.txt`.
    #[test]
    fn real_sops_files_are_refused_or_accepted_by_shape() {
        const RECIPIENT: &str = "age12uaczkdv3uvyrw6kmvc4s4srykpwtd9uqzejlqt9yzajd986qp8qvtfjmv";
        const IDENTITY: &str =
            "AGE-SECRET-KEY-17GL4UCEWMVTVSTEJKYL6PA4KMKC88MEV9E5CG8E8UQ7TSY4WA2HQ9XDQMR\n";
        let dir = tempfile::tempdir().unwrap();
        let key_file = dir.path().join("age-key.txt");
        std::fs::write(&key_file, IDENTITY).unwrap();
        let encrypt = |name: &str, text: &str, regex: Option<&str>| {
            let path = dir.path().join(name);
            std::fs::write(&path, text).unwrap();
            let mut command = runtime::tool(Tool::Sops, Want::Shipped).unwrap();
            command
                .current_dir(dir.path())
                .args(["encrypt", "--age", RECIPIENT]);
            if let Some(regex) = regex {
                command.args(["--encrypted-regex", regex]);
            }
            let out = command.arg("--in-place").arg(&path).output().unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            path
        };
        let flux = encrypt(
            "flux.yaml",
            "apiVersion: v1\nkind: Secret\nmetadata:\n  name: api\nstringData:\n  username: app\n  password: s3cr3t\ntype: Opaque\n",
            Some("^(data|stringData)$"),
        );
        let flat = encrypt(
            "flat.yaml",
            "username: app\npassword: s3cr3t\nport: 5432\n",
            None,
        );
        let decrypt = |path: &Path| {
            let out = decrypt_command(path, None)
                .unwrap()
                .env("SOPS_AGE_KEY_FILE", &key_file)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            parse_secret_data(path, &String::from_utf8(out.stdout).unwrap())
        };

        let err = decrypt(&flux).unwrap_err();
        assert!(
            matches!(&err, SecretError::NotFlat { key, .. } if key == "metadata"),
            "{err}"
        );
        assert!(err.to_string().starts_with("[K6746] "), "{err}");
        let data = decrypt(&flat).unwrap();
        assert_eq!(
            data,
            BTreeMap::from([
                ("password".into(), "s3cr3t".into()),
                ("port".into(), "5432".into()),
                ("username".into(), "app".into()),
            ])
        );

        let bundle = |path: &Path, placeholders: bool| {
            let text = std::fs::read_to_string(path).unwrap();
            let mut manifests = [carried_secret(SOURCE, Some(&digest_of(&text)))];
            manifests[0]["type"] = json!("Opaque");
            hydrate_secrets_from(&mut manifests, &from_carried(&text, placeholders))
                .map(|_| manifests[0]["stringData"].clone())
        };
        for placeholders in [true, false] {
            let err = bundle(&flux, placeholders).unwrap_err();
            assert!(
                matches!(&err, SecretError::NotFlat { key, .. } if key == "metadata"),
                "{err}"
            );
        }
        assert_eq!(
            bundle(&flat, true).unwrap(),
            json!({"password": "kix-placeholder", "port": "kix-placeholder", "username": "kix-placeholder"})
        );
    }

    /// A process with no age identity gets `sops`' no-data-key exit status,
    /// and the error names the file and says no key here decrypts it. The
    /// same file decrypts once the identity is given.
    #[test]
    fn a_sops_file_with_no_key_here_says_so() {
        const RECIPIENT: &str = "age12uaczkdv3uvyrw6kmvc4s4srykpwtd9uqzejlqt9yzajd986qp8qvtfjmv";
        const IDENTITY: &str =
            "AGE-SECRET-KEY-17GL4UCEWMVTVSTEJKYL6PA4KMKC88MEV9E5CG8E8UQ7TSY4WA2HQ9XDQMR\n";
        let dir = tempfile::tempdir().unwrap();
        let key_file = dir.path().join("age-key.txt");
        std::fs::write(&key_file, IDENTITY).unwrap();
        let path = dir.path().join("app-db.sops.yaml");
        std::fs::write(&path, "password: s3cr3t\n").unwrap();
        let out = runtime::tool(Tool::Sops, Want::Shipped)
            .unwrap()
            .args(["encrypt", "--age", RECIPIENT, "--in-place"])
            .arg(&path)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );

        // Keep the test runner's own keys out of `sops`' reach.
        let run = |key: Option<&Path>| {
            let mut command = decrypt_command(&path, None).unwrap();
            for var in [
                "SOPS_AGE_KEY",
                "SOPS_AGE_KEY_FILE",
                "SOPS_AGE_KEY_CMD",
                "SOPS_AGE_SSH_PRIVATE_KEY_FILE",
                "SOPS_AGE_SSH_PRIVATE_KEY_CMD",
            ] {
                command.env_remove(var);
            }
            command
                .env("HOME", dir.path())
                .env("XDG_CONFIG_HOME", dir.path());
            if let Some(key) = key {
                command.env("SOPS_AGE_KEY_FILE", key);
            }
            decrypted(&path, command.output().unwrap())
        };

        let err = run(None).unwrap_err();
        assert!(matches!(err, SecretError::NoKey { .. }), "{err:?}");
        let text = err.to_string();
        assert!(
            text.starts_with(
                "cannot decrypt SOPS file app-db.sops.yaml: `sops` could not get a decryption key"
            ),
            "{text}"
        );
        assert!(text.contains("Kix operator"), "{text}");
        assert!(
            text.contains("sops error:\n    Failed to get the data key"),
            "{text}"
        );

        let plaintext = run(Some(&key_file)).unwrap();
        assert_eq!(
            parse_secret_data(&path, &plaintext).unwrap(),
            BTreeMap::from([("password".into(), "s3cr3t".into())])
        );
    }

    #[test]
    fn a_sops_file_is_named_without_its_store_hash() {
        assert_eq!(
            sops_file_name("/nix/store/0123456789abcdfghijklmnpqrsvwxyz-app-db.sops.yaml"),
            "app-db.sops.yaml"
        );
        assert_eq!(
            sops_file_name("/nix/store/0123456789abcdfghijklmnpqrsvwxyz-source/secrets/db.yaml"),
            "db.yaml"
        );
        assert_eq!(
            sops_file_name("secrets/app-db.sops.yaml"),
            "app-db.sops.yaml"
        );
    }

    /// A digest mismatch names the file without its store path.
    #[test]
    fn a_digest_mismatch_names_the_file() {
        let err = SecretError::DigestMismatch {
            name: "app-db-password".into(),
            sops_source: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-app-db.sops.yaml".into(),
        };
        let message = err.to_string();
        assert!(
            message.starts_with("SOPS file app-db.sops.yaml for Secret 'app-db-password'"),
            "{message}"
        );
        assert!(!message.contains("/nix/store"), "{message}");
    }

    /// A local deploy checks the file's bytes before it runs `sops`.
    #[test]
    fn a_local_sops_file_that_does_not_match_its_digest_is_not_decrypted() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db.sops.yaml");
        std::fs::write(&path, AGE_ONLY).unwrap();
        let mut manifest = carried_secret(path.to_str().unwrap(), Some(&digest_of("other")));
        let err = hydrate_single(&mut manifest).unwrap_err();
        assert!(matches!(err, SecretError::DigestMismatch { .. }), "{err}");
    }

    /// `builtins.hashFile "sha256"` writes lowercase hex.
    #[test]
    fn a_file_digest_is_the_hex_sha256_of_its_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.yaml");
        std::fs::write(&path, "abc").unwrap();
        assert_eq!(
            file_digest(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
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

    fn digest_of(text: &str) -> String {
        Sha256::digest(text.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    fn carried_secret(source: &str, digest: Option<&str>) -> Value {
        let mut annotations = serde_json::json!({
            (keys::SOPS_SOURCE): source,
            (keys::SECRET_KEYS): "password, .dockerconfigjson",
        });
        if let Some(d) = digest {
            annotations[keys::SOPS_DIGEST] = serde_json::json!(d);
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
        let text = format!(".dockerconfigjson: ENC[AES256_GCM,data:def]\n{AGE_ONLY}");
        let mut manifests = [carried_secret(SOURCE, Some(&digest_of(&text)))];
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
        let mut manifests = [carried_secret(SOURCE, Some(&digest_of(AGE_ONLY)))];
        manifests[0]["metadata"]["annotations"][keys::SECRET_KEYS] = "only-this".into();
        hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap();
        assert_eq!(
            manifests[0]["stringData"],
            json!({"password": "kix-placeholder"})
        );
    }

    /// A Secret that mixes plain keys with SOPS keys keeps both after a deploy
    /// fills it.
    #[test]
    fn hydration_keeps_the_plain_keys_the_build_wrote() {
        let mut manifests = [carried_secret(SOURCE, Some(&digest_of(AGE_ONLY)))];
        manifests[0]["stringData"] = json!({"username": "app", "password": "stale"});
        hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap();
        assert_eq!(
            manifests[0]["stringData"],
            json!({"username": "app", "password": "kix-placeholder"})
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
    fn a_secret_from_a_carried_build_must_record_a_digest() {
        let mut manifests = [carried_secret(SOURCE, None)];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap_err();
        assert!(matches!(err, SecretError::NotCarried { .. }), "{err}");
    }

    /// A carried file that is not the one the build read is refused before
    /// a plan or a deploy reads its keys.
    #[test]
    fn a_carried_sops_file_that_does_not_match_its_digest_is_refused() {
        let mut manifests = [carried_secret(SOURCE, Some(&digest_of("other")))];
        let err = hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap_err();
        assert!(matches!(err, SecretError::DigestMismatch { .. }), "{err}");
    }

    /// A bundle from Kix 0.9 records a hash of the values and no digest.
    #[test]
    fn a_carried_build_with_only_the_old_hash_is_accepted() {
        let mut manifests = [carried_secret(SOURCE, None)];
        manifests[0]["metadata"]["annotations"][keys::CONTENT_HASH] = json!("sha256-x");
        hydrate_secrets_from(&mut manifests, &from_carried(AGE_ONLY, true)).unwrap();
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
            let command = decrypt_command(&path, Some(input_type)).unwrap();
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
    /// `sops` exactly. Kix's YAML reader refuses a repeated key too.
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
        let digest = digest_of(AGE_ONLY);
        let mut manifests: Vec<Value> = (0..1000)
            .map(|i| {
                let mut secret = carried_secret(SOURCE, Some(&digest));
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
