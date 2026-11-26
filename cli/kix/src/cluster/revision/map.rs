//! `status.revisions` of an Activation record: which revisions the record's
//! deploy is made of.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::spec::RevisionSet;

/// The format of `status.revisions` this release reads and writes. A record
/// in another format reads as having no map.
pub const FORMAT: u64 = 1;

/// The revisions one Activation record names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevisionMap {
    /// The revision of each package instance, keyed `namespace/instance`.
    pub instances: BTreeMap<String, String>,
    /// The revision of the objects that belong to no instance.
    pub cluster_level: String,
    /// The revision of the objects the deploy left on the cluster when it
    /// did not prune, or `None` when it left none.
    pub kept_orphans: Option<String>,
}

/// `status.revisions` as the record stores it.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stored {
    format: u64,
    instances: BTreeMap<String, String>,
    cluster_level: String,
    #[serde(default)]
    kept_orphans: Option<String>,
}

impl RevisionMap {
    /// Return the map of a build's revisions, naming no kept orphans.
    pub fn of(set: &RevisionSet) -> RevisionMap {
        RevisionMap {
            instances: set
                .instances
                .iter()
                .map(|(key, revision)| (key.clone(), revision.name.clone()))
                .collect(),
            cluster_level: set.cluster_level.name.clone(),
            kept_orphans: None,
        }
    }

    /// Read `status.revisions`. Return `None` when it does not parse or is
    /// in a format this release does not read.
    pub fn from_value(value: &Value) -> Option<RevisionMap> {
        let stored: Stored = serde_json::from_value(value.clone()).ok()?;
        (stored.format == FORMAT).then_some(RevisionMap {
            instances: stored.instances,
            cluster_level: stored.cluster_level,
            kept_orphans: stored.kept_orphans,
        })
    }

    /// Return the map as the record stores it. `keptOrphans` is written as
    /// `null` when the map names none, so a merge patch clears an earlier
    /// value.
    pub fn to_value(&self) -> Value {
        serde_json::to_value(Stored {
            format: FORMAT,
            instances: self.instances.clone(),
            cluster_level: self.cluster_level.clone(),
            kept_orphans: self.kept_orphans.clone(),
        })
        .expect("a revision map serializes")
    }

    /// Return the name of every revision the map names.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.instances
            .values()
            .chain(std::iter::once(&self.cluster_level))
            .chain(self.kept_orphans.iter())
            .map(String::as_str)
    }
}
