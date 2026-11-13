//! Committed record of resolved container image digests.
//!
//! A pin file is JSON stored alongside the cluster definition that reads it.
//! Using JSON rather than Nix avoids evaluating code when reading a pin file
//! and avoids escaping registry-supplied strings as Nix source when a bot
//! rewrites the file on every build.
//!
//! Using JSON also matches the rest of Kix's build outputs (`kix-packages.json`,
//! `kix-scorecard.json`, `kix-extra-images.json`, the SBOM, the provenance,
//! and the OSCAL assessment). The evaluation cache fingerprints `.nix`,
//! `.yaml`, `.yml`, and `.json` (`crate::eval::cache`), so a JSON pin file is
//! included in the cache fingerprint automatically.
//!
//! ```json
//! {
//!   "version": 2,
//!   "managedBy": "kix pin",
//!   "images": {
//!     "atlas-server-prod": {
//!       "repository": "harbor.example.com/team/server",
//!       "tag": "main",
//!       "digest": "sha256:00f522cf…",
//!       "sourceRev": "5d5dda2e5c…",
//!       "promotedBy": "ci:deploy.yaml#3981",
//!       "resolvedAt": "2026-09-09T14:02:11Z",
//!       "note": "Held back while we investigate the memory leak."
//!     }
//!   },
//!   "instances": {
//!     "monitoring/grafana": {
//!       "image": {
//!         "repository": "docker.io/grafana/grafana",
//!         "tag": "13.1.3",
//!         "digest": "sha256:9a1c…"
//!       }
//!     }
//!   }
//! }
//! ```
//!
//! The file has two maps. The cluster's code reads an `images` pin by name,
//! `pins.get "atlas-server-prod"`. Kix applies an `instances` pin itself,
//! as a definition of that instance's option, when the cluster passes the
//! file to `kix.buildCluster { pins = ...; }`; no code reads it. The option
//! path is relative to the instance's config, so `image` is
//! `instances.monitoring.grafana.config.image`.
//!
//! Version 1 has `images` only, and version 2 adds `instances`. A file with
//! no instance pins is written as version 1, so a Kix that reads only
//! version 1 can still read it.
//!
//! The tag names a stream and does not move per build: `main`, not
//! `sha-5d5dda2`. The digest is the part that changes, which is what makes
//! the file regenerable and keeps CI out of the cluster definition.
//!
//! `note` is there so a person can say why an entry is what it is. JSON has
//! no comments, and a field survives a rewrite where a comment would not.
//! The file keeps it as written; `kix pin set` drops it when it moves the
//! entry to another image, since the note described the old one.
//!
//! Writing produces the canonical form above, which is why `kix pin set`
//! refuses to overwrite a file that does not declare `managedBy`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::registry::is_sha256_digest;

/// The value of `managedBy` in a file `kix pin` wrote, and the substring a
/// scan looks for to tell a pin file from any other JSON.
pub const MANAGED_MARKER: &str = "\"managedBy\": \"kix pin\"";

/// What `managedBy` has to say for the file to be safe to rewrite.
const MANAGED_BY: &str = "kix pin";

/// The schema version of a file with `images` only.
const VERSION_IMAGES: u32 = 1;

/// The schema version of a file with `instances`.
const VERSION_INSTANCES: u32 = 2;

/// The option an instance pin sets when none is named.
pub const DEFAULT_OPTION: &str = "image";

/// One image reference resolved at promotion time.
///
/// Uses `deny_unknown_fields` because the Nix reader rejects unknown fields.
/// Accepting an unknown field here and dropping it on the next write would
/// silently delete user data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Pin {
    /// Repository including the registry host.
    pub repository: String,
    /// Tag requested before digest resolution, naming a release stream rather
    /// than a specific build.
    pub tag: String,
    /// Manifest digest that `tag` resolved to, or `None` when the pin has not
    /// been resolved against a registry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    /// Source revision this image was built from, or `None` for upstream
    /// images.
    #[serde(rename = "sourceRev", default, skip_serializing_if = "Option::is_none")]
    pub source_rev: Option<String>,
    /// Identity of the actor or CI job that promoted this pin.
    #[serde(
        rename = "promotedBy",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub promoted_by: Option<String>,
    /// RFC 3339 timestamp when the digest was resolved.
    #[serde(
        rename = "resolvedAt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub resolved_at: Option<String>,
    /// Human note about this entry. Kix preserves it across digest updates,
    /// and `kix pin set` drops it when switching the entry to a different
    /// image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl Pin {
    /// Format `repository:tag` for registry requests.
    pub fn reference(&self) -> String {
        format!("{}:{}", self.repository, self.tag)
    }

    /// Format `repository@digest` when a digest is present, for freshness
    /// checks against the registry.
    pub fn digest_reference(&self) -> Option<String> {
        self.digest
            .as_ref()
            .map(|d| format!("{}@{}", self.repository, d))
    }
}

/// On-disk JSON envelope, kept separate from `PinFile` so `PinFile` can carry
/// the file path and managed flag. Fields serialize in declaration order.
#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    #[serde(rename = "managedBy")]
    managed_by: String,
    #[serde(default)]
    images: BTreeMap<String, Pin>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    instances: BTreeMap<String, BTreeMap<String, Pin>>,
}

/// Key identifying an entry in a pin file.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum PinKey {
    /// An `images` pin read with `pins.get`.
    Image(String),
    /// An `instances` pin where `instance` is `<namespace>/<instance>` and
    /// `option` is a package option path such as `image`.
    Instance { instance: String, option: String },
}

impl PinKey {
    /// Parse a CLI pin key: either a plain image pin name, or
    /// `<namespace>/<instance>` with an optional `--option` path (defaulting
    /// to `image`).
    pub fn parse(key: &str, option: Option<&str>) -> Result<Self, String> {
        if key.contains('/') {
            check_instance_key(key)?;
            let option = option.unwrap_or(DEFAULT_OPTION);
            check_option_path(key, option)?;
            Ok(Self::Instance {
                instance: key.to_string(),
                option: option.to_string(),
            })
        } else if let Some(option) = option {
            Err(format!(
                "--option {option} names an option of an instance, and '{key}' is a pin name. Name the instance as <namespace>/<instance>."
            ))
        } else if key.is_empty() {
            Err("A pin name cannot be empty.".to_string())
        } else {
            Ok(Self::Image(key.to_string()))
        }
    }

    /// Format the `kix pin set` CLI arguments that address this pin.
    pub fn arguments(&self) -> String {
        match self {
            Self::Image(name) => name.clone(),
            Self::Instance { instance, option } if option == DEFAULT_OPTION => instance.clone(),
            Self::Instance { instance, option } => format!("{instance} --option {option}"),
        }
    }
}

impl std::fmt::Display for PinKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Image(name) => write!(f, "{name}"),
            Self::Instance { instance, option } => write!(f, "{instance} {option}"),
        }
    }
}

/// A whole pin file. Ordered, so writing it back is deterministic and a diff
/// shows only what changed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PinFile {
    pub path: PathBuf,
    /// The `images` map, by pin name.
    pub pins: BTreeMap<String, Pin>,
    /// The `instances` map, by `<namespace>/<instance>`, then option path.
    pub instances: BTreeMap<String, BTreeMap<String, Pin>>,
    /// Whether the file on disk declared `managedBy`.
    pub managed: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum PinError {
    #[error(
        "no pin file at {path}. Create one along with its first pin:\n  kix pin set <key> --repository <registry/repository> --tag <tag> --init"
    )]
    NoFile { path: String },

    #[error("could not read {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },

    #[error("could not write {path}: {source}")]
    Write {
        path: String,
        #[source]
        source: std::io::Error,
    },

    #[error("{path} is not a valid pin file.\n{detail}")]
    Invalid { path: String, detail: String },

    #[error(
        "{path} was not written by `kix pin`, so Kix has not overwritten it. Review the file, then rerun with --force if you want Kix to replace it."
    )]
    NotManaged { path: String },
}

impl PinFile {
    /// Read a pin file. A missing file is an error, not an empty file: the
    /// caller that wants to create one says so with `--init`.
    pub fn read(path: &Path) -> Result<Self, PinError> {
        if !path.exists() {
            return Err(PinError::NoFile {
                path: path.display().to_string(),
            });
        }
        let text = std::fs::read_to_string(path).map_err(|e| PinError::Read {
            path: path.display().to_string(),
            source: e,
        })?;
        Self::parse(&text, path)
    }

    /// Parse a pin file's text, for a caller that read it from somewhere
    /// other than the disk, such as a forge's API. `path` is where the file
    /// lives, for error messages and for `write`.
    pub fn parse(text: &str, path: &Path) -> Result<Self, PinError> {
        let mut file = parse_file(text).map_err(|detail| PinError::Invalid {
            path: path.display().to_string(),
            detail,
        })?;
        file.path = path.to_path_buf();
        Ok(file)
    }

    /// Create an empty, managed pin file for `path`.
    pub fn empty(path: &Path) -> Self {
        Self {
            path: path.to_path_buf(),
            managed: true,
            ..Self::default()
        }
    }

    /// Return the pin for `key`, if present.
    pub fn get(&self, key: &PinKey) -> Option<&Pin> {
        match key {
            PinKey::Image(name) => self.pins.get(name),
            PinKey::Instance { instance, option } => self.instances.get(instance)?.get(option),
        }
    }

    /// Insert or replace the pin at `key`.
    pub fn insert(&mut self, key: PinKey, pin: Pin) {
        match key {
            PinKey::Image(name) => {
                self.pins.insert(name, pin);
            }
            PinKey::Instance { instance, option } => {
                self.instances
                    .entry(instance)
                    .or_default()
                    .insert(option, pin);
            }
        }
    }

    /// Remove the pin at `key`, pruning the instance map entry when its last
    /// option pin is removed.
    pub fn remove(&mut self, key: &PinKey) -> Option<Pin> {
        match key {
            PinKey::Image(name) => self.pins.remove(name),
            PinKey::Instance { instance, option } => {
                let options = self.instances.get_mut(instance)?;
                let pin = options.remove(option);
                if options.is_empty() {
                    self.instances.remove(instance);
                }
                pin
            }
        }
    }

    /// Iterate over every pin in key order, yielding `images` before
    /// `instances`.
    pub fn entries(&self) -> impl Iterator<Item = (PinKey, &Pin)> {
        let images = self
            .pins
            .iter()
            .map(|(name, pin)| (PinKey::Image(name.clone()), pin));
        let instances = self.instances.iter().flat_map(|(instance, options)| {
            options.iter().map(move |(option, pin)| {
                (
                    PinKey::Instance {
                        instance: instance.clone(),
                        option: option.clone(),
                    },
                    pin,
                )
            })
        });
        images.chain(instances)
    }

    pub fn is_empty(&self) -> bool {
        self.pins.is_empty() && self.instances.is_empty()
    }

    /// Read the file if it is there, otherwise start an empty one.
    pub fn read_or_empty(path: &Path) -> Result<Self, PinError> {
        match Self::read(path) {
            Ok(f) => Ok(f),
            Err(PinError::NoFile { .. }) => Ok(Self::empty(path)),
            Err(e) => Err(e),
        }
    }

    /// Render the canonical JSON representation.
    pub fn render(&self) -> String {
        let envelope = Envelope {
            version: if self.instances.is_empty() {
                VERSION_IMAGES
            } else {
                VERSION_INSTANCES
            },
            managed_by: MANAGED_BY.to_string(),
            images: self.pins.clone(),
            instances: self.instances.clone(),
        };
        let mut out = serde_json::to_string_pretty(&envelope)
            .expect("a pin file is plain data and always serialises");
        out.push('\n');
        out
    }

    /// Write the canonical JSON representation to `self.path`, refusing to
    /// overwrite an existing file that lacks `managedBy` unless `force` is
    /// true.
    pub fn write(&self, force: bool) -> Result<(), PinError> {
        // Run the same validation as `parse` so Kix never writes a file it
        // would later refuse to read.
        check_pins(&self.pins)
            .and_then(|()| check_instances(&self.instances))
            .map_err(|detail| PinError::Invalid {
                path: self.path.display().to_string(),
                detail,
            })?;
        if self.path.exists() && !self.managed && !force {
            return Err(PinError::NotManaged {
                path: self.path.display().to_string(),
            });
        }
        if let Some(parent) = self.path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent).map_err(|e| PinError::Write {
                path: self.path.display().to_string(),
                source: e,
            })?;
        }
        std::fs::write(&self.path, self.render()).map_err(|e| PinError::Write {
            path: self.path.display().to_string(),
            source: e,
        })
    }
}

/// Parse a pin file's JSON text, leaving `path` empty for the caller to populate.
///
/// Accepts either the canonical envelope or a bare map of image pins. A bare
/// map is marked unmanaged so `kix pin set` refuses to overwrite it without
/// `--force`.
fn parse_file(text: &str) -> Result<PinFile, String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|e| {
        format!("It is not JSON: {e}. A pin file is JSON written by `kix pin set`.")
    })?;

    let obj = value
        .as_object()
        .ok_or_else(|| "A pin file must be a JSON object.".to_string())?;

    if ["version", "images", "instances"]
        .iter()
        .any(|k| obj.contains_key(*k))
    {
        // Check `version` before deserializing `Envelope` so files from a newer
        // Kix report a version mismatch rather than an unknown-field error.
        let version = obj.get("version").and_then(serde_json::Value::as_u64);
        match version {
            Some(1) | Some(2) => {}
            Some(v) => {
                return Err(format!(
                    "It declares version {v}, and Kix {} reads versions {VERSION_IMAGES} and {VERSION_INSTANCES}. Upgrade Kix, or check the file.",
                    crate::version::running().release()
                ));
            }
            None => return Err("It has no version. A pin file declares `\"version\"`.".to_string()),
        }
        let envelope: Envelope = serde_json::from_value(value.clone())
            .map_err(|e| format!("It is not shaped like a pin file: {e}."))?;
        if envelope.version == VERSION_IMAGES && !envelope.instances.is_empty() {
            return Err(format!(
                "It has instance pins (`instances`) but declares version {VERSION_IMAGES}. A file with instance pins declares version {VERSION_INSTANCES}."
            ));
        }
        check_pins(&envelope.images)?;
        check_instances(&envelope.instances)?;
        return Ok(PinFile {
            managed: envelope.managed_by == MANAGED_BY,
            pins: envelope.images,
            instances: envelope.instances,
            ..PinFile::default()
        });
    }

    Ok(PinFile {
        pins: parse_pins(&value)?,
        ..PinFile::default()
    })
}

/// Parse and validate a bare JSON object of image pins.
pub(crate) fn parse_pins(value: &serde_json::Value) -> Result<BTreeMap<String, Pin>, String> {
    let obj = value
        .as_object()
        .ok_or_else(|| "A pin file must be a JSON object.".to_string())?;

    let mut pins = BTreeMap::new();
    for (key, raw) in obj {
        let pin: Pin = serde_json::from_value(raw.clone()).map_err(|e| {
            format!(
                "Pin '{key}' is not shaped like a pin: {e}. Every pin needs a repository and a tag."
            )
        })?;
        pins.insert(key.clone(), pin);
    }
    check_pins(&pins)?;
    Ok(pins)
}

/// Validate every pin in an `images` map.
fn check_pins(pins: &BTreeMap<String, Pin>) -> Result<(), String> {
    for (key, pin) in pins {
        check_pin(&format!("Pin '{key}'"), pin)?;
    }
    Ok(())
}

fn check_instances(instances: &BTreeMap<String, BTreeMap<String, Pin>>) -> Result<(), String> {
    for (instance, options) in instances {
        check_instance_key(instance)?;
        if options.is_empty() {
            return Err(format!(
                "Instance pin '{instance}' has no options. Map an option path, such as `image`, to a pin."
            ));
        }
        for (option, pin) in options {
            check_option_path(instance, option)?;
            check_pin(&format!("Instance pin '{instance}' option '{option}'"), pin)?;
        }
    }
    Ok(())
}

fn check_pin(label: &str, pin: &Pin) -> Result<(), String> {
    if pin.repository.is_empty() || pin.tag.is_empty() {
        return Err(format!(
            "{label} has an empty repository or tag. Both are required."
        ));
    }
    if !is_repository(&pin.repository) {
        return Err(format!(
            "{label} has a repository that is not an image repository: '{}'. A repository is an optional registry host, then lower-case path components separated by `/`, such as docker.io/library/nginx.",
            pin.repository
        ));
    }
    if pin.tag.contains('@') {
        return Err(format!(
            "{label} has a digest in its tag: '{}'. Put the tag in `tag` and the digest in `digest`.",
            pin.tag
        ));
    }
    if !is_tag(&pin.tag) {
        return Err(format!(
            "{label} has a tag that is not an image tag: '{}'. A tag is up to 128 letters, digits, `_`, `.` and `-`, and does not start with `.` or `-`.",
            pin.tag
        ));
    }
    if let Some(d) = &pin.digest
        && !is_sha256_digest(d)
    {
        return Err(format!(
            "{label} has a digest that is not sha256: followed by 64 hexadecimal characters: '{d}'."
        ));
    }
    Ok(())
}

// Image reference grammar from the OCI distribution spec
// (`distribution/reference`), matching the Nix reader in
// `kix/lib/vocab/pins.nix`: an optional registry host and port followed by
// lowercase path components, and a tag of up to 128 word characters, dots,
// and dashes.

/// Return whether `s` matches `[a-z0-9]+(([.]|_|__|-+)[a-z0-9]+)*`.
fn is_path_component(s: &str) -> bool {
    let alnum = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit();
    let mut chars = s.chars().peekable();
    loop {
        let mut run = 0;
        while chars.peek().is_some_and(|c| alnum(*c)) {
            chars.next();
            run += 1;
        }
        if run == 0 {
            return false;
        }
        let mut sep = String::new();
        while let Some(c) = chars.peek().copied().filter(|c| !alnum(*c)) {
            sep.push(c);
            chars.next();
        }
        if sep.is_empty() {
            return chars.peek().is_none();
        }
        if !(sep == "." || sep == "_" || sep == "__" || sep.chars().all(|c| c == '-')) {
            return false;
        }
    }
}

/// Return whether `s` is a valid registry host (dot-separated labels or a
/// bracketed IPv6 address, with an optional port).
fn is_host(s: &str) -> bool {
    let (name, port) = match s.rsplit_once(':') {
        Some((name, port)) if !name.ends_with(':') && !port.contains(']') => (name, Some(port)),
        _ => (s, None),
    };
    if port.is_some_and(|p| p.is_empty() || !p.chars().all(|c| c.is_ascii_digit())) {
        return false;
    }
    if let Some(ip) = name.strip_prefix('[').and_then(|n| n.strip_suffix(']')) {
        return !ip.is_empty() && ip.chars().all(|c| c.is_ascii_hexdigit() || c == ':');
    }
    name.split('.').all(|label| {
        !label.is_empty()
            && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
            && !label.starts_with('-')
            && !label.ends_with('-')
    })
}

fn is_repository(s: &str) -> bool {
    if s.len() > 255 {
        return false;
    }
    let parts: Vec<&str> = s.split('/').collect();
    let paths_ok = |paths: &[&str]| !paths.is_empty() && paths.iter().all(|p| is_path_component(p));
    paths_ok(&parts) || (parts.len() > 1 && is_host(parts[0]) && paths_ok(&parts[1..]))
}

/// Return whether `s` matches `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}`.
fn is_tag(s: &str) -> bool {
    let word = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut chars = s.chars();
    s.len() <= 128
        && chars.next().is_some_and(word)
        && chars.all(|c| word(c) || c == '.' || c == '-')
}

/// Validate that `instance` has the `<namespace>/<instance>` form expected by
/// the Nix reader.
fn check_instance_key(instance: &str) -> Result<(), String> {
    match instance.split_once('/') {
        Some((ns, name)) if !ns.is_empty() && !name.is_empty() && !name.contains('/') => Ok(()),
        _ => Err(format!(
            "Instance pin '{instance}' is not <namespace>/<instance>."
        )),
    }
}

/// Validate that `option` consists of dot-separated option identifiers.
fn check_option_path(instance: &str, option: &str) -> Result<(), String> {
    let ok = option.split('.').all(|part| {
        !part.is_empty()
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    });
    if ok {
        Ok(())
    } else {
        Err(format!(
            "Instance pin '{instance}' names option '{option}', which is not an option path such as `image` or `server.image`."
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pin(repo: &str, tag: &str) -> Pin {
        Pin {
            repository: repo.into(),
            tag: tag.into(),
            digest: None,
            source_rev: None,
            promoted_by: None,
            resolved_at: None,
            note: None,
        }
    }

    #[test]
    fn rendering_is_deterministic_and_carries_the_managed_marker() {
        let mut f = PinFile::empty(Path::new("pins.json"));
        f.pins.insert("b".into(), pin("r/b", "v2"));
        f.pins.insert("a".into(), pin("r/a", "v1"));
        let text = f.render();
        assert!(text.contains(MANAGED_MARKER), "{text}");
        // Sorted, so a promotion diff shows one entry rather than a reshuffle.
        assert!(text.find("\"a\"").unwrap() < text.find("\"b\"").unwrap());
        assert_eq!(text, f.render());
    }

    #[test]
    fn optional_fields_are_omitted_rather_than_written_as_null() {
        let mut f = PinFile::empty(Path::new("pins.json"));
        f.pins.insert("a".into(), pin("r/a", "v1"));
        let text = f.render();
        assert!(!text.contains("digest"), "{text}");
        assert!(!text.contains("null"), "{text}");
    }

    #[test]
    fn a_rendered_file_parses_back_to_the_same_pins() {
        let mut f = PinFile::empty(Path::new("pins.json"));
        f.pins.insert(
            "web".into(),
            Pin {
                repository: "reg.example/web".into(),
                tag: "main".into(),
                digest: Some(format!("sha256:{}", "ab".repeat(32))),
                source_rev: Some("deadbeef".into()),
                promoted_by: Some("ci:deploy#7".into()),
                resolved_at: Some("2026-09-09T00:00:00Z".into()),
                note: Some("held back on purpose".into()),
            },
        );
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        let mut written = f.clone();
        written.path = path.clone();
        written.write(false).unwrap();

        let back = PinFile::read(&path).unwrap();
        assert_eq!(back.pins, f.pins);
        assert!(back.managed);
    }

    #[test]
    fn a_note_survives_a_rewrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        let mut f = PinFile::empty(&path);
        f.pins.insert(
            "web".into(),
            Pin {
                note: Some("See PLAT-412.".into()),
                ..pin("r/w", "main")
            },
        );
        f.write(false).unwrap();

        // A promotion changes the digest and leaves the note alone.
        let mut back = PinFile::read(&path).unwrap();
        back.pins.get_mut("web").unwrap().digest = Some(format!("sha256:{}", "cd".repeat(32)));
        back.write(false).unwrap();

        let again = PinFile::read(&path).unwrap();
        assert_eq!(again.pins["web"].note.as_deref(), Some("See PLAT-412."));
    }

    #[test]
    fn an_unknown_field_is_refused_rather_than_dropped() {
        // The Nix reader throws on a field it does not know. If the CLI
        // accepted one here it would delete it on the next write.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        std::fs::write(
            &path,
            r#"{"images":{"web":{"repository":"r/w","tag":"main","ticket":"PLAT-412"}},
                "version":1,"managedBy":"kix pin"}"#,
        )
        .unwrap();

        let err = PinFile::read(&path).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("ticket"), "{msg}");
    }

    #[test]
    fn a_newer_schema_version_is_refused_rather_than_misread() {
        let msg = parse_file(
            r#"{"version":3,"managedBy":"kix pin","images":{"web":{"repository":"r/w","tag":"main"}}}"#,
        )
        .unwrap_err();
        assert!(msg.contains("version 3"), "{msg}");
    }

    #[test]
    fn a_version_1_file_still_reads_and_is_written_back_as_version_1() {
        let text = r#"{
  "version": 1,
  "managedBy": "kix pin",
  "images": {
    "web": {
      "repository": "r/w",
      "tag": "main"
    }
  }
}
"#;
        let f = parse_file(text).unwrap();
        assert_eq!(f.pins["web"].tag, "main");
        assert!(f.instances.is_empty());
        // Byte for byte, so a Kix that reads only version 1 keeps reading
        // every file without instance pins.
        assert_eq!(f.render(), text);
    }

    #[test]
    fn instance_pins_are_version_2_and_render_in_sorted_order() {
        let mut f = PinFile::empty(Path::new("pins.json"));
        f.insert(
            PinKey::parse("monitoring/grafana", None).unwrap(),
            pin("docker.io/grafana/grafana", "13.1.3"),
        );
        f.insert(
            PinKey::parse("monitoring/alloy", Some("server.image")).unwrap(),
            pin("docker.io/grafana/alloy", "v1.10.0"),
        );
        f.insert(PinKey::Image("web".into()), pin("r/w", "main"));
        let text = f.render();
        assert_eq!(
            text,
            r#"{
  "version": 2,
  "managedBy": "kix pin",
  "images": {
    "web": {
      "repository": "r/w",
      "tag": "main"
    }
  },
  "instances": {
    "monitoring/alloy": {
      "server.image": {
        "repository": "docker.io/grafana/alloy",
        "tag": "v1.10.0"
      }
    },
    "monitoring/grafana": {
      "image": {
        "repository": "docker.io/grafana/grafana",
        "tag": "13.1.3"
      }
    }
  }
}
"#
        );
        let back = parse_file(&text).unwrap();
        assert_eq!(back.instances, f.instances);
        assert_eq!(back.pins, f.pins);
        assert!(back.managed);
    }

    #[test]
    fn removing_the_last_instance_pin_writes_version_1_again() {
        let mut f = PinFile::empty(Path::new("pins.json"));
        let key = PinKey::parse("monitoring/grafana", None).unwrap();
        f.insert(key.clone(), pin("r/g", "1"));
        assert!(f.render().contains("\"version\": 2"));
        assert!(f.remove(&key).is_some());
        assert!(
            f.instances.is_empty(),
            "an instance with no pins is removed"
        );
        assert!(f.render().contains("\"version\": 1"));
    }

    #[test]
    fn a_version_1_file_with_instance_pins_is_refused() {
        let msg = parse_file(
            r#"{"version":1,"managedBy":"kix pin","images":{},
                "instances":{"ns/app":{"image":{"repository":"r/a","tag":"1"}}}}"#,
        )
        .unwrap_err();
        assert!(msg.contains("declares version 1"), "{msg}");
    }

    #[test]
    fn parse_reads_text_and_names_the_path_in_errors() {
        let f = PinFile::parse(
            r#"{"version":1,"managedBy":"kix pin","images":{"web":{"repository":"r/w","tag":"1"}}}"#,
            Path::new("clusters/app/pins.json"),
        )
        .unwrap();
        assert_eq!(f.path, Path::new("clusters/app/pins.json"));
        assert!(f.managed);
        let msg = PinFile::parse("{", Path::new("clusters/app/pins.json"))
            .unwrap_err()
            .to_string();
        assert!(msg.contains("clusters/app/pins.json"), "{msg}");
    }

    #[test]
    fn a_version_2_file_without_images_reads() {
        let f = parse_file(
            r#"{"version":2,"managedBy":"kix pin",
                "instances":{"ns/app":{"image":{"repository":"r/a","tag":"1"}}}}"#,
        )
        .unwrap();
        let key = PinKey::parse("ns/app", None).unwrap();
        assert_eq!(f.get(&key).unwrap().tag, "1");
        assert!(f.pins.is_empty());
    }

    #[test]
    fn malformed_instance_pins_are_refused() {
        for (text, needle) in [
            (
                r#"{"version":2,"managedBy":"kix pin","instances":{"app":{"image":{"repository":"r","tag":"1"}}}}"#,
                "<namespace>/<instance>",
            ),
            (
                r#"{"version":2,"managedBy":"kix pin","instances":{"ns/app":{"image.":{"repository":"r","tag":"1"}}}}"#,
                "not an option path",
            ),
            (
                r#"{"version":2,"managedBy":"kix pin","instances":{"ns/app":{}}}"#,
                "has no options",
            ),
            (
                r#"{"version":2,"managedBy":"kix pin","instances":{"ns/app":{"image":{"repository":"r","tag":""}}}}"#,
                "empty repository or tag",
            ),
            (
                r#"{"version":2,"managedBy":"kix pin","images":{},"holds":{}}"#,
                "holds",
            ),
        ] {
            let msg = parse_file(text).unwrap_err();
            assert!(msg.contains(needle), "{needle}: {msg}");
        }
    }

    #[test]
    fn repositories_and_tags_follow_the_image_reference_grammar() {
        for ok in [
            "nginx",
            "docker.io/library/nginx",
            "harbor.example.com:8443/team/web-server",
            "localhost:5000/a__b/c.d/e--f",
            "[::1]:5000/app",
            "Registry.Example.com/app",
        ] {
            assert!(is_repository(ok), "{ok}");
        }
        for bad in [
            "",
            "Docker/Nginx",
            "reg.example/app/",
            "reg.example//app",
            "reg.example/-app",
            "reg.example/app.",
            "reg.example/a...b",
            "reg.example:x/app",
            "reg example/app",
        ] {
            assert!(!is_repository(bad), "{bad}");
        }
        for ok in ["1.27-alpine", "v1.154.0", "_x", "main", &"a".repeat(128)] {
            assert!(is_tag(ok), "{ok}");
        }
        for bad in ["", ".x", "-x", "a:b", "a/b", &"a".repeat(129)] {
            assert!(!is_tag(bad), "{bad}");
        }
    }

    #[test]
    fn a_pin_with_a_bad_reference_is_refused() {
        for (pin, needle) in [
            (
                r#"{"repository":"r/w","tag":"1@sha256:aa"}"#,
                "digest in its tag",
            ),
            (
                r#"{"repository":"R/W","tag":"1"}"#,
                "not an image repository",
            ),
            (r#"{"repository":"r/w","tag":"-1"}"#, "not an image tag"),
        ] {
            let text = format!(
                r#"{{"version":2,"managedBy":"kix pin","instances":{{"ns/app":{{"image":{pin}}}}}}}"#
            );
            let msg = parse_file(&text).unwrap_err();
            assert!(msg.contains(needle), "{needle}: {msg}");
        }
    }

    #[test]
    fn a_key_with_a_slash_names_an_instance() {
        assert_eq!(
            PinKey::parse("monitoring/grafana", None).unwrap(),
            PinKey::Instance {
                instance: "monitoring/grafana".into(),
                option: "image".into()
            }
        );
        assert_eq!(
            PinKey::parse("web", None).unwrap(),
            PinKey::Image("web".into())
        );
        assert!(PinKey::parse("web", Some("image")).is_err());
        assert!(PinKey::parse("a/b/c", None).is_err());
        assert_eq!(
            PinKey::parse("ns/app", Some("server.image"))
                .unwrap()
                .arguments(),
            "ns/app --option server.image"
        );
        assert_eq!(PinKey::parse("ns/app", None).unwrap().arguments(), "ns/app");
    }

    #[test]
    fn a_file_kix_did_not_write_is_not_overwritten_without_being_told() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        std::fs::write(&path, r#"{"web":{"repository":"r/w","tag":"v1"}}"#).unwrap();

        let mut f = PinFile::read(&path).unwrap();
        assert!(!f.managed, "a bare pin map is not managed");
        assert!(matches!(f.write(false), Err(PinError::NotManaged { .. })));

        // …but a reader can still read it, and --force still writes it.
        assert_eq!(f.pins["web"].tag, "v1");
        f.pins.get_mut("web").unwrap().tag = "v2".into();
        f.write(true).unwrap();
        assert_eq!(PinFile::read(&path).unwrap().pins["web"].tag, "v2");
    }
}
