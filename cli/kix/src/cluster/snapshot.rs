//! The state file `kix snapshot` writes beside the objects it saves.
//!
//! The file holds what a comparison of the live cluster with a build reads:
//! the Kix state ([`SavedState`]), and each Kix object as the API server
//! served it with the applied hash computed from it ([`Observed`]). `kix
//! diff --from` reads the file back and runs that same comparison against
//! the saved state, without a connection.
//!
//! No `Secret` value is written. Each saved `Secret` is redacted
//! ([`Observed::redacted`]), and its applied hash, computed before the
//! redaction, says whether it still holds what Kix applied.

use std::path::Path;

use kube::api::DynamicObject;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::owned_view::Observed;
use super::tenancy::{SavedState, Tenancy};

/// The name of the state file in a snapshot directory.
pub const STATE_FILE: &str = "kix-snapshot.json";

/// The format this version of Kix writes and reads.
pub const FORMAT: u32 = 1;

/// Why the state file of a snapshot cannot be read.
#[derive(Debug, Error)]
pub enum SnapshotError {
    #[error(
        "cannot read snapshot state file {path}: {source}. Kix stopped without running the diff. Check that the file is readable, or save a fresh snapshot with `kix snapshot <cluster> --out <dir>`."
    )]
    Read {
        path: String,
        source: std::io::Error,
    },
    #[error(
        "{path} is not a valid Kix snapshot state file: {source}. Kix stopped without running the diff. Save a fresh snapshot with `kix snapshot <cluster> --out <dir>`."
    )]
    Invalid {
        path: String,
        source: serde_json::Error,
    },
    #[error(
        "snapshot state file {path} uses format {format}, which was written by a newer version of Kix (this version reads format {FORMAT}). Kix stopped without running the diff. Upgrade this project with `kix upgrade` (or upgrade Kix with `kix self upgrade`), or save the snapshot again with `kix snapshot <cluster> --out <dir>`."
    )]
    Newer { path: String, format: u32 },
}

/// The state file of a snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub format: u32,
    /// The name of the Kix cluster the snapshot was taken of.
    pub cluster: String,
    pub state: SavedState,
    /// Each Kix object of the cluster, as the comparison with the live
    /// cluster reads it.
    pub objects: Vec<SavedObject>,
}

/// One saved object.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedObject {
    /// The object as served, with its `Secret` values redacted.
    pub object: DynamicObject,
    /// [`Observed::applied`], computed before the redaction.
    pub applied_hash: Option<String>,
}

impl Snapshot {
    /// Return the state file for the Kix cluster `cluster`, whose state
    /// `tenancy` read, holding `objects` with their `Secret` values redacted.
    pub fn of(
        cluster: &str,
        tenancy: &Tenancy,
        objects: impl IntoIterator<Item = Observed>,
    ) -> Snapshot {
        Snapshot {
            format: FORMAT,
            cluster: cluster.to_string(),
            state: tenancy.saved(),
            objects: objects
                .into_iter()
                .map(|o| {
                    let o = o.redacted();
                    SavedObject {
                        object: o.obj,
                        applied_hash: o.applied,
                    }
                })
                .collect(),
        }
    }

    /// Write the state file into `dir`.
    pub fn write(&self, dir: &Path) -> std::io::Result<()> {
        let text = serde_json::to_string(self).map_err(std::io::Error::other)?;
        std::fs::write(dir.join(STATE_FILE), text)
    }

    /// Read the state file of the snapshot in `dir`. Return `None` when
    /// `dir` has none, as in a snapshot an older Kix wrote or an export.
    pub fn read(dir: &Path) -> Result<Option<Snapshot>, SnapshotError> {
        let path = dir.join(STATE_FILE);
        let shown = path.display().to_string();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(source) => {
                return Err(SnapshotError::Read {
                    path: shown,
                    source,
                });
            }
        };
        let value: serde_json::Value =
            serde_json::from_str(&text).map_err(|source| SnapshotError::Invalid {
                path: shown.clone(),
                source,
            })?;
        let format = value.get("format").and_then(serde_json::Value::as_u64);
        if let Some(format) = format.filter(|f| *f > u64::from(FORMAT)) {
            return Err(SnapshotError::Newer {
                path: shown,
                format: u32::try_from(format).unwrap_or(u32::MAX),
            });
        }
        let mut snapshot: Snapshot =
            serde_json::from_value(value).map_err(|source| SnapshotError::Invalid {
                path: shown,
                source,
            })?;
        for record in &mut snapshot.state.records {
            as_listed(record);
        }
        for saved in &mut snapshot.objects {
            as_listed(&mut saved.object);
        }
        Ok(Some(snapshot))
    }

    /// Return the tenancy of the snapshot's Kix cluster, read from the saved
    /// state.
    pub fn tenancy(&self) -> Tenancy {
        Tenancy::of_saved(&self.cluster, &self.state)
    }

    /// Return the saved objects.
    pub fn observed(&self) -> Vec<Observed> {
        self.objects
            .iter()
            .map(|s| Observed {
                obj: s.object.clone(),
                applied: s.applied_hash.clone(),
            })
            .collect()
    }
}

/// Put `kind` and `apiVersion` back into the data of `obj`, where a listed
/// object holds them. Reading an object back from JSON moves them into its
/// type fields.
fn as_listed(obj: &mut DynamicObject) {
    let Some(types) = obj.types.take() else {
        return;
    };
    if let Some(map) = obj.data.as_object_mut() {
        map.entry("kind")
            .or_insert_with(|| serde_json::Value::String(types.kind));
        map.entry("apiVersion")
            .or_insert_with(|| serde_json::Value::String(types.api_version));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory without a state file has no snapshot to read, and a
    /// state file a newer Kix wrote is refused rather than misread.
    #[test]
    fn a_state_file_is_read_only_in_a_format_this_kix_knows() {
        let dir = tempfile::tempdir().unwrap();
        assert!(Snapshot::read(dir.path()).unwrap().is_none());

        std::fs::write(
            dir.path().join(STATE_FILE),
            serde_json::json!({"format": FORMAT + 1}).to_string(),
        )
        .unwrap();
        assert!(matches!(
            Snapshot::read(dir.path()),
            Err(SnapshotError::Newer { .. })
        ));
    }
}
