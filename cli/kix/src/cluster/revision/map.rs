//! `status.revisions` of an Activation record: which revisions the record's
//! deploy is made of.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::spec::{Revision, RevisionSet, Slot};
use crate::eval::package_index::{self, IndexedPackage, ObjectName, RecordPackageIndex};
use crate::manifest::keys;
use crate::manifest::lifecycle::PACKAGE_INSTANCE_KIND;

/// The format of `status.revisions` this release reads and writes.
pub const FORMAT: u64 = 1;

/// A `status.revisions` this release cannot read: it does not parse, or it
/// is in a format a later release wrote. The record may name revisions this
/// release cannot see, so nothing may delete revisions on its account.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("its `status.revisions` {reason}")]
pub struct UnreadableMap {
    pub reason: String,
}

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

    /// Read `status.revisions`. Refuse a value that does not parse or is in
    /// a format this release does not read.
    pub fn read(value: &Value) -> Result<RevisionMap, UnreadableMap> {
        let format = value.get("format").and_then(Value::as_u64);
        if format.is_some_and(|f| f != FORMAT) {
            return Err(UnreadableMap {
                reason: format!(
                    "uses format {} (this version of Kix supports format {FORMAT})",
                    format.unwrap_or_default()
                ),
            });
        }
        let stored: Stored = serde_json::from_value(value.clone()).map_err(|e| UnreadableMap {
            reason: format!("is invalid: {e}"),
        })?;
        Ok(RevisionMap {
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

    /// Return the package index of the build the map names, read from the
    /// revisions `find` returns: which instance holds each object, and each
    /// object's group, kind, namespace, and name. A revision `find` does not
    /// return is left out. The kept orphans are not part of the build.
    pub fn package_index<'a>(
        &self,
        find: impl Fn(&str) -> Option<&'a Revision>,
    ) -> RecordPackageIndex {
        let mut names = BTreeMap::new();
        let mut groups = BTreeMap::new();
        let mut add_names = |revision: &Revision| {
            for object in &revision.spec.objects {
                let rid = object.resource_id();
                if !rid.group.is_empty() {
                    groups.insert(object.hash.clone(), rid.group.clone());
                }
                names.insert(object.hash.clone(), ObjectName::of(&rid));
            }
        };
        let mut packages = BTreeMap::new();
        for (key, revision) in &self.instances {
            let Some(revision) = find(revision) else {
                continue;
            };
            add_names(revision);
            let is_instance = |o: &&super::RevisionObject| match &revision.spec.slot {
                Slot::Instance {
                    namespace, name, ..
                } => {
                    o.kind == PACKAGE_INSTANCE_KIND
                        && o.group == keys::GROUP
                        && o.namespace.as_deref() == Some(namespace.as_str())
                        && &o.name == name
                }
                Slot::ClusterLevel | Slot::KeptOrphans => false,
            };
            let instance = revision.spec.objects.iter().find(is_instance);
            let resources = revision
                .spec
                .objects
                .iter()
                .filter(|o| Some(*o) != instance)
                .map(|o| o.hash.clone())
                .collect();
            packages.insert(
                key.clone(),
                IndexedPackage {
                    instance: instance.map(|o| o.hash.clone()).unwrap_or_default(),
                    resources,
                },
            );
        }
        let mut cluster_level = Vec::new();
        if let Some(revision) = find(&self.cluster_level) {
            add_names(revision);
            cluster_level = revision
                .spec
                .objects
                .iter()
                .map(|o| o.hash.clone())
                .collect();
            cluster_level.sort();
        }
        RecordPackageIndex {
            format: package_index::FORMAT,
            packages,
            cluster_level,
            names,
            groups: Some(groups),
        }
    }
}
