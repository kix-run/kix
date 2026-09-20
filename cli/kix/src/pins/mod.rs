//! The committed record of what each image reference resolved to.
//!
//! A pin file is JSON living next to the cluster definition that reads it.
//! JSON rather than Nix for a reason that has nothing to do with taste:
//! reading a Nix file means evaluating it, so reading a pin file would
//! execute whatever the file contains, and writing one means escaping
//! registry-supplied strings into a programming language by hand. Neither is
//! a thing to do to a file a bot rewrites on every build. JSON parses inert
//! and serialises with serde.
//!
//! It is also what the rest of Kix already does. `kix-packages.json`,
//! `kix-scorecard.json`, `kix-extra-images.json`, the SBOM, the provenance
//! and the OSCAL assessment are all JSON; YAML appears only where Kubernetes
//! imposes it. The evaluation cache fingerprints `.nix`, `.yaml`, `.yml` and
//! `.json` (`crate::eval::cache`), so a JSON pin file lands in the
//! fingerprint like any other input.
//!
//! ```json
//! {
//!   "version": 1,
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
//!   }
//! }
//! ```
//!
//! The tag names a stream and does not move per build: `main`, not
//! `sha-5d5dda2`. The digest is the part that changes, which is what makes
//! the file regenerable and keeps CI out of the cluster definition.
//!
//! `note` is there so a person can say why an entry is what it is without
//! the next promotion deleting it. JSON has no comments, and a field
//! survives a rewrite where a comment would not.
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

/// The schema version of the envelope. Bumped only for a breaking change.
const VERSION: u32 = 1;

/// One image reference, as resolved at promotion time.
///
/// `deny_unknown_fields` on purpose: the Nix reader refuses a field it does
/// not know, so the CLI has to refuse it too. Accepting it here and dropping
/// it on the next write would delete whatever somebody added, without saying
/// so.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pin {
    /// Repository including the registry host. What to pull from.
    pub repository: String,
    /// The tag that was asked for. Names a stream, not a build.
    pub tag: String,
    /// The manifest digest the tag resolved to. What will actually run.
    /// `None` means the pin has never been resolved against a registry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest: Option<String>,
    /// Revision of the source this image was built from, when Kix knows it.
    /// `None` for an upstream image, which has no revision in our history.
    #[serde(rename = "sourceRev", default, skip_serializing_if = "Option::is_none")]
    pub source_rev: Option<String>,
    /// Who promoted it, for the record.
    #[serde(
        rename = "promotedBy",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub promoted_by: Option<String>,
    /// When it was resolved, RFC 3339.
    #[serde(
        rename = "resolvedAt",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub resolved_at: Option<String>,
    /// A human note about this entry. Kix never reads it, and never
    /// discards it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

impl Pin {
    /// `repository:tag`, the reference to hand a registry.
    pub fn reference(&self) -> String {
        format!("{}:{}", self.repository, self.tag)
    }

    /// `repository@digest` when resolved. This, not the tag, is what a
    /// freshness check should ask the registry about.
    pub fn digest_reference(&self) -> Option<String> {
        self.digest
            .as_ref()
            .map(|d| format!("{}@{}", self.repository, d))
    }
}

/// The on-disk envelope. Separate from `PinFile` because the envelope is a
/// serialisation detail and `PinFile` carries the path and the managed flag.
#[derive(Debug, Serialize, Deserialize)]
struct Envelope {
    version: u32,
    #[serde(rename = "managedBy")]
    managed_by: String,
    images: BTreeMap<String, Pin>,
}

/// A whole pin file. Ordered, so writing it back is deterministic and a diff
/// shows only what changed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PinFile {
    pub path: PathBuf,
    pub pins: BTreeMap<String, Pin>,
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

    #[error("{path} has no pin named '{key}'. Pins in that file: {known}. Add it with --init.")]
    UnknownKey {
        path: String,
        key: String,
        known: String,
    },
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
        let (pins, managed) = parse_file(&text).map_err(|detail| PinError::Invalid {
            path: path.display().to_string(),
            detail,
        })?;
        Ok(Self {
            path: path.to_path_buf(),
            pins,
            managed,
        })
    }

    /// A pin file that does not exist yet.
    pub fn empty(path: &Path) -> Self {
        Self {
            path: path.to_path_buf(),
            pins: BTreeMap::new(),
            managed: true,
        }
    }

    /// Read the file if it is there, otherwise start an empty one.
    pub fn read_or_empty(path: &Path) -> Result<Self, PinError> {
        match Self::read(path) {
            Ok(f) => Ok(f),
            Err(PinError::NoFile { .. }) => Ok(Self::empty(path)),
            Err(e) => Err(e),
        }
    }

    pub fn get(&self, key: &str) -> Result<&Pin, PinError> {
        self.pins.get(key).ok_or_else(|| PinError::UnknownKey {
            path: self.path.display().to_string(),
            key: key.to_string(),
            known: if self.pins.is_empty() {
                "none".to_string()
            } else {
                self.pins.keys().cloned().collect::<Vec<_>>().join(", ")
            },
        })
    }

    /// Render the canonical form. Deterministic: same pins, same bytes.
    pub fn render(&self) -> String {
        let envelope = Envelope {
            version: VERSION,
            managed_by: MANAGED_BY.to_string(),
            images: self.pins.clone(),
        };
        let mut out = serde_json::to_string_pretty(&envelope)
            .expect("a pin file is plain data and always serialises");
        out.push('\n');
        out
    }

    /// Write the canonical form, refusing to clobber a file Kix did not write
    /// unless the caller has said to.
    pub fn write(&self, force: bool) -> Result<(), PinError> {
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

/// Parse a pin file's text into its pins and whether it declared itself
/// managed.
///
/// Two shapes are accepted. The canonical envelope, and a bare map of pins,
/// which is what a hand-written file tends to look like. A bare map is never
/// managed, so `kix pin set` will not rewrite one without `--force`.
fn parse_file(text: &str) -> Result<(BTreeMap<String, Pin>, bool), String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|e| {
        format!("It is not JSON: {e}. A pin file is JSON written by `kix pin set`.")
    })?;

    let obj = value
        .as_object()
        .ok_or_else(|| "A pin file must be a JSON object.".to_string())?;

    if obj.contains_key("images") {
        let envelope: Envelope = serde_json::from_value(value.clone())
            .map_err(|e| format!("It is not shaped like a pin file: {e}."))?;
        // Checked rather than ignored. A file from a newer Kix read as
        // though it were this one is the failure a version field exists to
        // prevent, and the Nix reader refuses it too.
        if envelope.version != VERSION {
            return Err(format!(
                "It declares version {}, and this kix reads version {VERSION}. Upgrade kix, or check the file.",
                envelope.version
            ));
        }
        check_pins(&envelope.images)?;
        let managed = envelope.managed_by == MANAGED_BY;
        return Ok((envelope.images, managed));
    }

    let pins = parse_pins(&value)?;
    Ok((pins, false))
}

/// Turn a bare map of pins into pins, refusing anything that would render a
/// reference Kix cannot pull.
pub fn parse_pins(value: &serde_json::Value) -> Result<BTreeMap<String, Pin>, String> {
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

/// The checks that apply however the file was shaped.
fn check_pins(pins: &BTreeMap<String, Pin>) -> Result<(), String> {
    for (key, pin) in pins {
        if pin.repository.is_empty() || pin.tag.is_empty() {
            return Err(format!(
                "Pin '{key}' has an empty repository or tag. Both are required."
            ));
        }
        if let Some(d) = &pin.digest
            && !is_sha256_digest(d)
        {
            return Err(format!(
                "Pin '{key}' has a digest that is not sha256: followed by 64 hexadecimal characters: '{d}'."
            ));
        }
    }
    Ok(())
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
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        std::fs::write(
            &path,
            r#"{"version":2,"managedBy":"kix pin","images":{"web":{"repository":"r/w","tag":"main"}}}"#,
        )
        .unwrap();

        let msg = PinFile::read(&path).unwrap_err().to_string();
        assert!(msg.contains("version 2"), "{msg}");
    }

    #[test]
    fn a_file_kix_did_not_write_is_not_overwritten_without_being_told() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pins.json");
        std::fs::write(&path, r#"{"web":{"repository":"r/w","tag":"v1"}}"#).unwrap();

        let mut f = PinFile::read(&path).unwrap();
        assert!(!f.managed, "a hand-written file is not managed");
        assert!(matches!(f.write(false), Err(PinError::NotManaged { .. })));

        // …but a reader can still read it, and --force still writes it.
        assert_eq!(f.pins["web"].tag, "v1");
        f.pins.get_mut("web").unwrap().tag = "v2".into();
        f.write(true).unwrap();
        assert_eq!(PinFile::read(&path).unwrap().pins["web"].tag, "v2");
    }
}
