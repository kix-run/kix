//! The change record format: one Markdown file per change, with a TOML
//! header between `+++` lines, and the JSON document a release ships.
//!
//! `build.rs` compiles this file too, to check every record and embed it in
//! Kix, so it uses only `serde`, `serde_json`, and `toml`, and nothing else
//! from this crate.

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
    /// Every kind, in the order `CHANGELOG.md` lists their headings.
    pub const ALL: [Kind; 7] = [
        Kind::Error,
        Kind::Silent,
        Kind::Note,
        Kind::Security,
        Kind::Added,
        Kind::Changed,
        Kind::Fixed,
    ];

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

    /// Return the `CHANGELOG.md` heading for this kind, without the `###`.
    pub fn heading(self) -> &'static str {
        match self {
            Kind::Error => "Breaking (shows an error)",
            Kind::Silent => "Breaking (no error)",
            Kind::Note => "Upgrade notes",
            Kind::Security => "Security",
            Kind::Added => "Added",
            Kind::Changed => "Changed",
            Kind::Fixed => "Fixed",
        }
    }

    /// Return whether a user who upgrades past this change must act on it.
    pub fn is_breaking(self) -> bool {
        matches!(self, Kind::Error | Kind::Silent)
    }

    /// Return the kind a record's `kind` field names, or `None`.
    pub fn from_name(name: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.name() == name)
    }
}

/// One change record.
///
/// The JSON form uses camelCase keys and the file header kebab-case ones.
/// Reading JSON skips fields this version does not know.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    /// The file name without `.md`, usually the branch name.
    pub name: String,
    pub kind: Kind,
    /// Package names under `kix/packages/` the change touches.
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
    #[serde(default)]
    pub touches_data: bool,
    /// Whether clusters must be deployed with this release before upgrading
    /// further.
    #[serde(default)]
    pub required_stop: bool,
    /// `K` and four digits, printed in the error the change causes.
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub cve: Vec<String>,
    /// How to get a security fix without upgrading.
    #[serde(default)]
    pub workaround: Option<String>,
    /// The Markdown text below the header.
    #[serde(default)]
    pub body: String,
}

/// A record file that breaks the format. Holds every problem found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordError(pub Vec<String>);

impl fmt::Display for RecordError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0.join("; "))
    }
}

impl std::error::Error for RecordError {}

const FENCE: &str = "+++";
const LIST_FIELDS: [&str; 4] = ["packages", "library", "cli", "cve"];
const BOOL_FIELDS: [&str; 3] = ["state", "touches-data", "required-stop"];
const STRING_FIELDS: [&str; 3] = ["kind", "id", "workaround"];

/// Return whether `id` is `K` followed by four digits.
pub fn is_id(id: &str) -> bool {
    id.len() == 5 && id.starts_with('K') && id[1..].bytes().all(|b| b.is_ascii_digit())
}

/// Split a record file into its TOML header and its body.
fn split_header(text: &str) -> Result<(String, String), RecordError> {
    let mut lines = text.split_inclusive('\n');
    if lines.next().map(str::trim) != Some(FENCE) {
        return Err(RecordError(vec![
            "the file must start with a `+++` line".into(),
        ]));
    }
    let mut header = String::new();
    for line in lines.by_ref() {
        if line.trim() == FENCE {
            return Ok((header, lines.collect()));
        }
        header.push_str(line);
    }
    Err(RecordError(vec![
        "the header has no closing `+++` line".into(),
    ]))
}

impl Record {
    /// Parse the record file `name.md` from its `text`, and check its fields.
    pub fn parse(name: &str, text: &str) -> Result<Record, RecordError> {
        let (header_text, body) = split_header(text)?;
        let header: toml::Table = toml::from_str(&header_text)
            .map_err(|e| RecordError(vec![format!("the header is not valid TOML: {e}")]))?;

        let mut problems = Vec::new();
        let known: Vec<&str> = LIST_FIELDS
            .iter()
            .chain(&BOOL_FIELDS)
            .chain(&STRING_FIELDS)
            .copied()
            .collect();
        let mut sorted_known = known.clone();
        sorted_known.sort_unstable();
        for key in header.keys() {
            if !known.contains(&key.as_str()) {
                problems.push(format!(
                    "unknown field `{key}`. The fields are: {}",
                    sorted_known.join(", ")
                ));
            }
        }

        let strings = |key: &str, problems: &mut Vec<String>| -> Vec<String> {
            match header.get(key) {
                None => Vec::new(),
                Some(toml::Value::Array(items)) => {
                    let out: Option<Vec<String>> = items
                        .iter()
                        .map(|v| v.as_str().map(str::to_owned))
                        .collect();
                    out.unwrap_or_else(|| {
                        problems.push(format!("`{key}` must be a list of strings"));
                        Vec::new()
                    })
                }
                Some(_) => {
                    problems.push(format!("`{key}` must be a list of strings"));
                    Vec::new()
                }
            }
        };
        let boolean = |key: &str, problems: &mut Vec<String>| -> bool {
            match header.get(key) {
                None => false,
                Some(toml::Value::Boolean(b)) => *b,
                Some(_) => {
                    problems.push(format!("`{key}` must be true or false"));
                    false
                }
            }
        };
        let string = |key: &str, problems: &mut Vec<String>| -> Option<String> {
            match header.get(key) {
                None => None,
                Some(toml::Value::String(s)) => Some(s.clone()),
                Some(_) => {
                    problems.push(format!("`{key}` must be a string"));
                    None
                }
            }
        };

        let packages = strings("packages", &mut problems);
        let library = strings("library", &mut problems);
        let cli = strings("cli", &mut problems);
        let cve = strings("cve", &mut problems);
        let state = boolean("state", &mut problems);
        let touches_data = boolean("touches-data", &mut problems);
        let required_stop = boolean("required-stop", &mut problems);
        let kind_name = string("kind", &mut problems);
        let id = string("id", &mut problems);
        let workaround = string("workaround", &mut problems);

        let kind_names: Vec<&str> = Kind::ALL.iter().map(|k| k.name()).collect();
        let kind = match kind_name.as_deref() {
            None if !header.contains_key("kind") => {
                problems.push(format!(
                    "`kind` is required. Use one of: {}",
                    kind_names.join(", ")
                ));
                None
            }
            None => None,
            Some(name) => {
                let kind = Kind::from_name(name);
                if kind.is_none() {
                    problems.push(format!(
                        "`kind = \"{name}\"` is unknown. Use one of: {}",
                        kind_names.join(", ")
                    ));
                }
                kind
            }
        };

        if let Some(id) = &id
            && !is_id(id)
        {
            problems.push(format!(
                "`id = \"{id}\"` must be K and four digits, such as K0001"
            ));
        }
        if kind == Some(Kind::Error) && !header.contains_key("id") {
            problems.push(
                "`kind = \"error\"` needs an `id`. Run `scripts/change-records.py next-id` to get one"
                    .into(),
            );
        }
        if touches_data && kind != Some(Kind::Silent) {
            problems.push("`touches-data` is only for `kind = \"silent\"`".into());
        }
        if required_stop && !state {
            problems.push("`required-stop` needs `state = true`".into());
        }
        if !cve.is_empty() && kind != Some(Kind::Security) {
            problems.push("`cve` is only for `kind = \"security\"`".into());
        }
        if kind == Some(Kind::Security) {
            if workaround.as_deref().is_none_or(|w| w.trim().is_empty()) {
                problems.push(
                    "`kind = \"security\"` needs a `workaround` that says how to get the fix without upgrading"
                        .into(),
                );
            }
        } else if header.contains_key("workaround") {
            problems.push("`workaround` is only for `kind = \"security\"`".into());
        }
        if body.trim().is_empty() {
            problems
                .push("the text below the header is empty. Describe the change for users".into());
        }

        match kind {
            Some(kind) if problems.is_empty() => Ok(Record {
                name: name.to_owned(),
                kind,
                packages,
                library,
                cli,
                state,
                touches_data,
                required_stop,
                id,
                cve,
                workaround,
                body,
            }),
            _ => Err(RecordError(problems)),
        }
    }

    /// Return whether a user who upgrades past this change must act on it.
    pub fn is_breaking(&self) -> bool {
        self.kind.is_breaking()
    }
}

/// The change records of one release, as `kix-<version>-changes.json` holds
/// them.
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
                "the change records use schema `{s}`, and this Kix reads only `{SCHEMA}`"
            ),
        }
    }
}

impl std::error::Error for DocumentError {}

impl Document {
    /// Read a change record document. Fields this version does not know are
    /// skipped.
    pub fn parse(json: &str) -> Result<Document, DocumentError> {
        let doc: Document = serde_json::from_str(json).map_err(DocumentError::Json)?;
        if doc.schema != SCHEMA {
            return Err(DocumentError::Schema(doc.schema));
        }
        Ok(doc)
    }
}

/// A record built into Kix, with the release it shipped in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Compiled {
    /// The Kix version the record shipped in, or `None` when it is not
    /// released yet.
    pub release: Option<String>,
    #[serde(flatten)]
    pub record: Record,
}
