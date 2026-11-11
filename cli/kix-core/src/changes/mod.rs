//! The change records a release publishes as `kix-<version>-changes.json`,
//! which `kix upgrade` reads. `scripts/change-records.py json` writes the
//! file from the records under the repository's `changes/` folder, described
//! in `changes/README.md`.

use std::fmt;

use serde::{Deserialize, Serialize};

/// The `schema` of a change record document.
pub const SCHEMA: &str = "kix.run/changes/v1";

/// What kind of change a record describes. Each kind is one `CHANGELOG.md`
/// heading.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Error,
    Silent,
    Note,
    Security,
    Added,
    Changed,
    Fixed,
}

impl Kind {
    /// Return the name a record's `kind` field uses.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Error => "error",
            Kind::Silent => "silent",
            Kind::Note => "note",
            Kind::Security => "security",
            Kind::Added => "added",
            Kind::Changed => "changed",
            Kind::Fixed => "fixed",
        }
    }
}

/// One change record.
///
/// Reading skips fields this version does not know. The fields `kix
/// upgrade` decides on (`kind`, `touchesData`, `requiredStop`) have no
/// default, so a renamed key fails to read instead of reading as false.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    /// The file name without `.md`, usually the branch name.
    pub name: String,
    pub kind: Kind,
    /// The packages the change touches: a folder name under
    /// `kix/packages/stable/`, or `experimental/<name>` for one under
    /// `kix/packages/experimental/`.
    #[serde(default)]
    pub packages: Vec<String>,
    /// Library symbols, such as `kix.contracts.redis`.
    #[serde(default)]
    pub library: Vec<String>,
    /// CLI commands or flags removed or changed, as a user types them.
    #[serde(default)]
    pub cli: Vec<String>,
    /// Whether the change touches the state Kix writes into a cluster.
    #[serde(default)]
    pub state: bool,
    /// Whether the change moves or reinterprets stored data.
    pub touches_data: bool,
    /// Whether clusters must be deployed with this release before upgrading
    /// further.
    pub required_stop: bool,
    /// `K` and four digits, printed in brackets at the start of the error
    /// the change causes.
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub cve: Vec<String>,
    /// How to get a security fix without upgrading.
    #[serde(default)]
    pub workaround: Option<String>,
    /// The Markdown text of the record.
    #[serde(default)]
    pub body: String,
}

/// The change records of one release.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    pub schema: String,
    pub version: String,
    pub records: Vec<Record>,
}

/// A change record document that cannot be read.
#[derive(Debug)]
pub enum DocumentError {
    Json(serde_json::Error),
    /// The document names a `schema` other than [`SCHEMA`].
    Schema(String),
}

impl fmt::Display for DocumentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DocumentError::Json(e) => write!(f, "the change records are not valid JSON: {e}"),
            DocumentError::Schema(s) => write!(
                f,
                "the change records use schema `{s}`, and Kix reads only `{SCHEMA}`"
            ),
        }
    }
}

impl std::error::Error for DocumentError {}

impl Document {
    /// Read a change record document.
    pub fn parse(json: &str) -> Result<Document, DocumentError> {
        let doc: Document = serde_json::from_str(json).map_err(DocumentError::Json)?;
        if doc.schema != SCHEMA {
            return Err(DocumentError::Schema(doc.schema));
        }
        Ok(doc)
    }
}

/// Return whether `id` is `K` followed by four digits.
pub fn is_id(id: &str) -> bool {
    id.len() == 5 && id.starts_with('K') && id[1..].bytes().all(|b| b.is_ascii_digit())
}

/// Return `input` as a record id (`K0001`), accepting brackets and any case,
/// or `None` when it does not have the shape of one.
pub fn normalize_id(input: &str) -> Option<String> {
    let trimmed = input.trim();
    let bare = trimmed
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(trimmed);
    let id = bare.to_ascii_uppercase();
    is_id(&id).then_some(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_document_skips_unknown_fields() {
        let doc = Document::parse(
            r#"{
              "schema": "kix.run/changes/v1",
              "version": "0.10.0",
              "future": {"x": 1},
              "records": [{
                "name": "a", "kind": "error", "touchesData": false,
                "requiredStop": true, "id": "K0001", "addedLater": "skipped"
              }]
            }"#,
        )
        .unwrap();
        assert_eq!(doc.records[0].kind, Kind::Error);
        assert!(doc.records[0].required_stop);
        assert_eq!(doc.records[0].body, "");
    }

    #[test]
    fn a_missing_verdict_field_is_an_error() {
        for record in [
            r#"{"name": "a", "touchesData": false, "requiredStop": false}"#,
            r#"{"name": "a", "kind": "silent", "requiredStop": false}"#,
            r#"{"name": "a", "kind": "note", "touchesData": false}"#,
            r#"{"name": "a", "kind": "silent", "touches_data": true, "requiredStop": false}"#,
        ] {
            let json = format!(
                r#"{{"schema": "kix.run/changes/v1", "version": "1.0.0", "records": [{record}]}}"#
            );
            assert!(Document::parse(&json).is_err(), "{record}");
        }
    }

    #[test]
    fn another_schema_is_refused() {
        let err = Document::parse(
            r#"{"schema": "kix.run/changes/v2", "version": "1.0.0", "records": []}"#,
        )
        .unwrap_err();
        assert!(matches!(err, DocumentError::Schema(_)), "{err}");
    }

    #[test]
    fn ids_are_read_in_any_form() {
        for form in ["K0001", "k0001", "[K0001]", " [k0001] "] {
            assert_eq!(normalize_id(form).as_deref(), Some("K0001"), "{form}");
        }
        assert_eq!(normalize_id("K01"), None);
        assert_eq!(normalize_id("move-data"), None);
    }
}
