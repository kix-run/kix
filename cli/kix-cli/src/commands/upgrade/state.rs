//! `kix-upgrade.json`: what the last `kix upgrade` did, kept in the project
//! so a later run can resume and `kix deploy` can ask about data changes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The file name, in the project directory.
pub const FILE: &str = "kix-upgrade.json";

/// The `schema` of [`FILE`].
pub const SCHEMA: &str = "kix.run/upgrade/v1";

/// How the last upgrade ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Status {
    /// The project builds on the target, and nothing needs a person.
    Done,
    /// A build failed. The project is pinned at the failing step.
    FixNeeded,
    /// The project builds on the target, and a person should read what
    /// changed.
    NeedsPerson,
    /// The upgrade stopped at a release clusters must deploy first.
    RequiredStop,
    /// Kix built the project as it was, and a person must edit `flake.nix`
    /// before the upgrade can go on.
    EditNeeded,
}

/// One version the upgrade built the project with.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub version: String,
    /// `ok`, `failed`, or `started` while the step runs or when it stopped
    /// before it built anything.
    pub result: String,
    /// The clusters that failed to build.
    #[serde(default)]
    pub failed: Vec<String>,
}

/// A change that moves or reinterprets stored data, which `kix deploy`
/// asks a person to acknowledge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DataChange {
    /// The record's id, or its name when it has none.
    pub reference: String,
    pub release: String,
    pub body: String,
}

/// A line in a project file that names a command or flag a record changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CliHit {
    pub text: String,
    pub file: String,
    pub line: usize,
}

/// The contents of [`FILE`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpgradeState {
    pub schema: String,
    pub from: String,
    pub to: String,
    /// The `--to` value the upgrade started with, or `latest`. A resumed run
    /// without `--to` asks for it again. Kix 0.10.0-rc.4 and older did not
    /// write it, and a resume of their state needs `--to`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub requested: Option<String>,
    pub status: Status,
    pub steps: Vec<Step>,
    /// The applying records by kind, each named by its id or its name.
    pub records: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub data_changes: Vec<DataChange>,
    #[serde(default)]
    pub acknowledged: Vec<String>,
    pub sensitive_changes: usize,
    #[serde(default)]
    pub cli_hits: Vec<CliHit>,
    /// The builds made with the version the upgrade started from.
    pub before: PathBuf,
    /// The ids of Kix's own packages that the project's clusters install,
    /// such as `harbor` or `experimental/coredns`, as the version the upgrade
    /// started from listed them. Absent when that Kix could not list them,
    /// and then no record is marked.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package_ids_in_use: Option<Vec<String>>,
}

impl UpgradeState {
    /// Read [`FILE`] in `project`. A missing file is `Ok(None)`.
    pub fn read(project: &Path) -> Result<Option<Self>, String> {
        let path = project.join(FILE);
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("could not read {}: {e}", path.display())),
        };
        let state: UpgradeState = serde_json::from_str(&text)
            .map_err(|e| format!("{} cannot be read: {e}", path.display()))?;
        if state.schema != SCHEMA {
            return Err(format!(
                "{} uses schema `{}`, and this Kix reads only `{SCHEMA}`",
                path.display(),
                state.schema
            ));
        }
        Ok(Some(state))
    }

    /// Write [`FILE`] in `project`.
    pub fn write(&self, project: &Path) -> Result<(), String> {
        let path = project.join(FILE);
        let mut text = serde_json::to_string_pretty(self).expect("the state serializes");
        text.push('\n');
        std::fs::write(&path, text).map_err(|e| format!("could not write {}: {e}", path.display()))
    }

    /// Return the data changes no one has acknowledged.
    pub fn unacknowledged(&self) -> Vec<&DataChange> {
        self.data_changes
            .iter()
            .filter(|d| !self.acknowledged.contains(&d.reference))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_state_round_trips_and_lists_unacknowledged_changes() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(UpgradeState::read(dir.path()).unwrap(), None);
        let state = UpgradeState {
            schema: SCHEMA.into(),
            from: "0.9.0".into(),
            to: "0.10.0".into(),
            requested: Some("0.10".into()),
            status: Status::NeedsPerson,
            steps: vec![Step {
                version: "0.10.0".into(),
                result: "ok".into(),
                failed: vec![],
            }],
            records: BTreeMap::from([("silent".to_string(), vec!["K0002".to_string()])]),
            data_changes: vec![
                DataChange {
                    reference: "K0002".into(),
                    release: "0.10.0".into(),
                    body: "Moved.".into(),
                },
                DataChange {
                    reference: "move-files".into(),
                    release: "0.10.0".into(),
                    body: "Moved too.".into(),
                },
            ],
            acknowledged: vec!["K0002".into()],
            sensitive_changes: 1,
            cli_hits: vec![],
            before: "/cache/before".into(),
            package_ids_in_use: Some(vec!["harbor".into(), "experimental/coredns".into()]),
        };
        state.write(dir.path()).unwrap();
        let text = std::fs::read_to_string(dir.path().join(FILE)).unwrap();
        assert!(text.contains("\"status\": \"needs-person\""), "{text}");
        assert!(text.contains("\"dataChanges\""), "{text}");
        let read = UpgradeState::read(dir.path()).unwrap().unwrap();
        assert_eq!(read, state);
        let open: Vec<&str> = read
            .unacknowledged()
            .iter()
            .map(|d| d.reference.as_str())
            .collect();
        assert_eq!(open, ["move-files"]);

        std::fs::write(
            dir.path().join(FILE),
            text.replace("upgrade/v1", "upgrade/v9"),
        )
        .unwrap();
        assert!(UpgradeState::read(dir.path()).is_err());
    }
}
