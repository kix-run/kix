//! The records the Kix library gives a person to fix: errors and warnings.
//!
//! `kix/lib/core/error.nix` builds both from the same fields. An error stops
//! evaluation and reaches Kix through Nix's stderr
//! ([`super::library_error::parse`]). A warning lets the build go on, and the
//! build lists the cluster's warnings in `kix-warnings.json`, which
//! [`read_warnings`] reads. Change this file with `error.nix`.

use std::path::PathBuf;

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// One error or warning of the Kix library. Fields this Kix does not know
/// are skipped, so a newer library can add them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub struct LibraryRecord {
    /// The change record id, such as `K0001`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// The instance it is about, as `<namespace>/<name>`. Absent for the
    /// whole cluster.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instance: Option<String>,
    /// The package of that instance.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package: Option<String>,
    /// The Kubernetes object it is about.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub object: Option<LibraryObject>,
    /// The option to change, as a path in the instance's `config`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub option: Option<String>,
    /// The dependency to change, as its name in the instance's `deps`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dependency: Option<String>,
    /// The cluster option to change, as a path in the cluster definition.
    #[serde(
        default,
        rename = "clusterOption",
        skip_serializing_if = "Option::is_none"
    )]
    pub cluster_option: Option<String>,
    /// What is wrong, which may span lines.
    pub message: String,
    /// What to change, which may span lines.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

/// A Kubernetes object a record is about.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize, JsonSchema)]
pub struct LibraryObject {
    pub kind: String,
    /// Absent for an object at cluster scope, or when the library does not
    /// know it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub namespace: Option<String>,
    pub name: String,
}

impl std::fmt::Display for LibraryObject {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.namespace {
            Some(ns) => write!(f, "{} {ns}/{}", self.kind, self.name),
            None => write!(f, "{} {}", self.kind, self.name),
        }
    }
}

impl LibraryRecord {
    /// Return the first line: the id, the instance and package, and the
    /// first line of the message.
    fn headline(&self) -> String {
        let mut out = String::new();
        if let Some(id) = &self.id {
            out.push_str(&format!("[{id}] "));
        }
        match (&self.instance, &self.package) {
            (Some(i), Some(p)) => out.push_str(&format!("{i} ({p}): ")),
            (Some(i), None) => out.push_str(&format!("{i}: ")),
            (None, Some(p)) => out.push_str(&format!("{p}: ")),
            (None, None) => {}
        }
        out.push_str(&self.message);
        out
    }

    /// Return the record as text, with every line after the first indented
    /// by `indent`.
    pub fn describe(&self, indent: &str) -> String {
        let mut text = self.headline();
        if let Some(object) = &self.object {
            text.push_str(&format!("\nObject: {object}"));
        }
        if let Some(option) = &self.option {
            text.push_str(&format!("\nOption: {option}"));
        }
        if let Some(dependency) = &self.dependency {
            text.push_str(&format!("\nDependency: {dependency}"));
        }
        if let Some(cluster_option) = &self.cluster_option {
            text.push_str(&format!("\nCluster option: {cluster_option}"));
        }
        if let Some(fix) = &self.fix {
            text.push_str(&format!("\nFix: {fix}"));
        }
        text.replace('\n', &format!("\n{indent}"))
    }
}

/// Return `warnings` as text for a person: a heading, then each warning
/// under it. Return an empty string when there are none.
pub fn describe_warnings(warnings: &[LibraryRecord]) -> String {
    if warnings.is_empty() {
        return String::new();
    }
    let mut out = format!("Warnings from the Kix library, {}:", warnings.len());
    for w in warnings {
        out.push_str("\n  ");
        out.push_str(w.describe("    ").trim_end());
    }
    out
}

/// Read the warnings file at `path`, a logical store path from
/// [`super::build_files::BuildFiles::warnings`]. A build that lists no file
/// has no warnings. A file Kix cannot read gives none, after a warning in
/// the log, because the build itself is still good.
pub fn read_warnings(path: Option<&PathBuf>) -> Vec<LibraryRecord> {
    let Some(path) = path else {
        return Vec::new();
    };
    let read = || -> Result<Vec<LibraryRecord>, String> {
        let on_disk = super::store::disk_path(path).map_err(|e| e.to_string())?;
        let text = std::fs::read_to_string(on_disk).map_err(|e| e.to_string())?;
        serde_json::from_str(&text).map_err(|e| e.to_string())
    };
    read().unwrap_or_else(|error| {
        tracing::warn!(path = %path.display(), %error, "failed to read the library's warnings");
        Vec::new()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn warning(json: serde_json::Value) -> LibraryRecord {
        serde_json::from_value(json).unwrap()
    }

    /// A warning reads its fields from the file, skips fields it does not
    /// know, and shows each field on a line of its own.
    #[test]
    fn a_warning_shows_its_fields() {
        let w = warning(serde_json::json!({
            "instance": "shop/db",
            "object": {"kind": "Job", "namespace": "shop", "name": "migrate"},
            "option": "replicas",
            "message": "first\nsecond",
            "fix": "Leave it out.",
            "severity": "a field a newer library adds",
        }));
        assert_eq!(
            describe_warnings(&[w, warning(serde_json::json!({"message": "cluster"}))]),
            "Warnings from the Kix library, 2:\n  \
             shop/db: first\n    second\n    Object: Job shop/migrate\n    \
             Option: replicas\n    Fix: Leave it out.\n  cluster"
        );
        assert_eq!(describe_warnings(&[]), "");
    }

    /// A build that lists no warnings file, or one Kix cannot read, has no
    /// warnings.
    #[test]
    fn a_missing_or_unreadable_file_has_no_warnings() {
        assert!(read_warnings(None).is_empty());
        let dir = tempfile::tempdir().unwrap();
        let bad = dir.path().join("kix-warnings.json");
        std::fs::write(&bad, "not json").unwrap();
        assert!(read_warnings(Some(&bad)).is_empty());
        std::fs::write(&bad, r#"[{"instance":"a/b","message":"m"}]"#).unwrap();
        assert_eq!(
            read_warnings(Some(&bad)),
            vec![LibraryRecord {
                instance: Some("a/b".into()),
                message: "m".into(),
                ..Default::default()
            }]
        );
    }
}
