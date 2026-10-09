//! Which Kix cluster each Activation record, and so each object, belongs to.
//!
//! Every object a deploy touches names the deploying record's identity hash
//! in `kix.run/activations`. Read with the records' `kix.run/cluster`
//! labels, those hashes attribute a live object to the Kix clusters whose
//! builds contain it ([`super::fetch::attribute`]), and tell a prune which
//! objects another Kix cluster still deploys ([`super::prune_guard`]).
//!
//! It reads the records through [`Records`](super::activation::Records), so the domain gate has run: on
//! a cluster whose records sit under a retired group every record would be
//! missing, every object would look unattributed, and a view of one Kix
//! cluster would hold all of them.

use std::collections::{HashMap, HashSet};

use kube::api::DynamicObject;

use super::activation::{OpenedRecords, PHASE_SUPERSEDED, Record, RecordsError};
use crate::manifest::keys;

/// Which Activation records on this Kubernetes cluster belong to which Kix
/// cluster, keyed by identity hash.
///
/// Every object a deploy touches names the deploying record's identity hash
/// in `kix.run/activations`, so these sets attribute a live object to the Kix
/// clusters whose builds contain it. See [`super::fetch::attribute`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tenancy {
    /// The Kix cluster this tenancy is read for.
    pub(crate) cluster: String,
    /// Identity hashes of this cluster's records, every phase.
    pub(crate) own: HashSet<String>,
    /// Identity hash to owning cluster, for every other record. A record
    /// without a `kix.run/cluster` label is listed under `?`.
    pub(crate) others: HashMap<String, String>,
    /// The hashes in `others` whose record is not Superseded: builds another
    /// cluster runs, is deploying, or left part-applied.
    pub(crate) others_current: HashSet<String>,
}

impl Tenancy {
    /// The tenancy of a cluster with no records.
    pub(crate) fn empty(cluster: &str) -> Self {
        Tenancy {
            cluster: cluster.to_string(),
            own: HashSet::new(),
            others: HashMap::new(),
            others_current: HashSet::new(),
        }
    }

    /// A tenancy of `records` as given, for tests of other crates. Outside
    /// tests a tenancy is only read through [`read`], past the domain gate.
    #[cfg(any(test, feature = "test-util"))]
    pub fn fixture(records: &[DynamicObject], cluster: &str) -> Self {
        Self::from_records(records, cluster)
    }

    /// Partition the records by their `kix.run/cluster` label. An empty
    /// `cluster` owns no record: every record is another cluster's.
    pub(crate) fn from_records(records: &[DynamicObject], cluster: &str) -> Self {
        let mut tenancy = Tenancy::empty(cluster);
        for record in records {
            let Some(hash) = record
                .metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
            else {
                continue;
            };
            let owner = record
                .metadata
                .labels
                .as_ref()
                .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL));
            if !cluster.is_empty() && owner == Some(cluster) {
                tenancy.own.insert(hash.to_string());
                continue;
            }
            if Record::of(record).phase != PHASE_SUPERSEDED {
                tenancy.others_current.insert(hash.to_string());
            }
            tenancy
                .others
                .insert(hash.to_string(), owner.unwrap_or("?").to_string());
        }
        tenancy
    }

    /// Refuse a tenancy whose cluster has no records while other clusters
    /// do: the name is most likely a typo, and a view of it would be empty.
    pub fn require_records(&self) -> Result<(), String> {
        if !self.own.is_empty() || self.others.is_empty() {
            return Ok(());
        }
        let mut known: Vec<&str> = self.others.values().map(String::as_str).collect();
        known.sort();
        known.dedup();
        Err(format!(
            "no Activation records of Kix cluster '{}' on this cluster. Kix clusters with records here: {}",
            self.cluster,
            known.join(", ")
        ))
    }

    /// Whether `hash` is the identity hash of a record this tenancy read.
    pub fn knows(&self, hash: &str) -> bool {
        self.own.contains(hash) || self.others.contains_key(hash)
    }

    /// The Kix clusters an object belongs to, by the record hashes it names.
    /// A record names itself through its own identity hash.
    pub fn owners_of(&self, obj: &DynamicObject) -> Vec<String> {
        let mut owners: Vec<String> = named_hashes(obj)
            .filter_map(|h| {
                if self.own.contains(h) {
                    Some(self.cluster.clone())
                } else {
                    self.others.get(h).cloned()
                }
            })
            .collect();
        owners.sort();
        owners.dedup();
        owners
    }

    /// Other Kix clusters whose current build contains this object. A prune
    /// must leave such an object in place.
    pub fn still_deployed_by_others(&self, obj: &DynamicObject) -> Vec<String> {
        let mut clusters: Vec<String> = named_hashes(obj)
            .filter(|h| self.others_current.contains(*h))
            .filter_map(|h| self.others.get(h).cloned())
            .collect();
        clusters.sort();
        clusters.dedup();
        clusters
    }
}

/// The record identity hashes an object names: every entry of
/// `kix.run/activations`, plus its own `kix.run/identity-hash`, which for an
/// Activation record is the key [`Tenancy`] is indexed by. A record in its
/// first wave is not yet stamped with its own hash in `kix.run/activations`.
pub fn named_hashes(obj: &DynamicObject) -> impl Iterator<Item = &str> {
    let annotations = obj.metadata.annotations.as_ref();
    let activations = annotations
        .and_then(|a| keys::get_meta(a, keys::ACTIVATIONS))
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let own = annotations.and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH));
    activations.chain(own)
}

/// Read the [`Tenancy`] for `cluster` from one list of every Activation
/// record, read through what [`super::activation::Records::open`]
/// returned. A cluster that does not serve the Activation kind has no
/// records, and the tenancy is empty.
///
/// Read it after the objects it will attribute, as
/// [`super::fetch::sweep_managed`] and [`super::prune_guard::PruneGuard`] do.
/// A deploy creates its record before any object names the record's hash, so
/// every hash on an object read earlier belongs to a record this list
/// returns, or to one deleted since. Read before the objects, a Kix cluster
/// whose first deploy lands in between leaves objects that name no known
/// record, and those count as this cluster's own.
pub async fn read(records: &OpenedRecords, cluster: &str) -> Result<Tenancy, RecordsError> {
    let Some(records) = records.records() else {
        return Ok(Tenancy::empty(cluster));
    };
    Ok(Tenancy::from_records(&records.all().await?, cluster))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::activation::{PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING};
    use serde_json::json;

    fn record(cluster: Option<&str>, hash: Option<&str>, phase: &str) -> DynamicObject {
        let mut labels = serde_json::Map::new();
        if let Some(c) = cluster {
            labels.insert(keys::CLUSTER_LABEL.into(), json!(c));
        }
        let mut annotations = serde_json::Map::new();
        if let Some(h) = hash {
            annotations.insert(keys::IDENTITY_HASH.into(), json!(h));
        }
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "r", "labels": labels, "annotations": annotations },
            "status": { "phase": phase },
        }))
        .unwrap()
    }

    #[test]
    fn records_are_partitioned_by_their_cluster_label() {
        let records = [
            record(Some("a"), Some("a1"), PHASE_SUPERSEDED),
            record(Some("a"), Some("a2"), PHASE_ACTIVE),
            record(Some("b"), Some("b0"), PHASE_SUPERSEDED),
            record(Some("b"), Some("b1"), PHASE_DEGRADED),
            record(None, Some("x1"), PHASE_ACTIVE),
            record(Some("a"), None, PHASE_DEPLOYING),
        ];
        let t = Tenancy::from_records(&records, "a");
        assert_eq!(t.own, HashSet::from(["a1".into(), "a2".into()]));
        assert_eq!(
            t.others,
            HashMap::from([
                ("b0".into(), "b".into()),
                ("b1".into(), "b".into()),
                // A record without the label is another cluster's, so it can
                // only narrow what this cluster sees and deletes.
                ("x1".into(), "?".into()),
            ])
        );
        assert_eq!(t.others_current, HashSet::from(["b1".into(), "x1".into()]));
    }

    #[test]
    fn a_cluster_with_no_records_among_others_is_refused() {
        let records = [record(Some("b"), Some("b1"), PHASE_ACTIVE)];
        let err = Tenancy::from_records(&records, "typo")
            .require_records()
            .unwrap_err();
        assert!(
            err.contains("'typo'") && err.ends_with("records here: b"),
            "{err}"
        );
        assert!(
            Tenancy::from_records(&records, "b")
                .require_records()
                .is_ok()
        );
        assert!(Tenancy::from_records(&[], "new").require_records().is_ok());
    }

    /// An empty cluster name, as the operator uses for a record that names
    /// no cluster, owns no record, even one whose label is empty.
    #[test]
    fn an_empty_cluster_name_owns_nothing() {
        let records = [record(Some(""), Some("e1"), PHASE_ACTIVE)];
        let t = Tenancy::from_records(&records, "");
        assert!(t.own.is_empty());
        assert!(t.others_current.contains("e1"));
    }
}
