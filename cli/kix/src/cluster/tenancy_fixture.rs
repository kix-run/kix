//! Kix clusters on one Kubernetes cluster, written the way earlier releases
//! wrote them or the way revisions write them, for tests that check that
//! both sources of [`super::tenancy::Tenancy`] give the same answers.
//!
//! Every object is a ConfigMap in namespace `d` with identity hash
//! `h-<name>`. A Kix cluster written from records stamps each object with
//! the identity hash of each record that applied it, and lists kept orphans
//! under `status.orphansKeptFrom` as build `k-<record hash>`. A Kix cluster
//! written from revisions stamps nothing, names one instance revision on
//! every record that is not `Superseded`, and names a kept-orphans revision
//! on a record that kept orphans.

use std::collections::{BTreeMap, BTreeSet};

use kube::api::DynamicObject;
use serde_json::{Value, json};

use super::head::{self, HeadStatus};
use super::revision::{self, Revision, RevisionObject, RevisionSpec, Slot};
use super::tenancy::Tenancy;
use crate::manifest::keys;
use crate::manifest::lifecycle::{PHASE_SUPERSEDED, RECORD_KIND};

/// How a Kix cluster of a [`State`] is written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Written {
    Records,
    Revisions,
}

/// One record of a [`State`].
#[derive(Debug, Clone, Default)]
pub struct Rec<'a> {
    pub name: &'a str,
    pub cluster: &'a str,
    pub hash: &'a str,
    pub phase: &'a str,
    /// The head names it as current.
    pub current: bool,
    /// The objects of its build.
    pub objects: &'a [&'a str],
    /// The objects of its build that its deploy did not apply.
    pub unapplied: &'a [&'a str],
    /// The objects it lists as kept orphans.
    pub kept: &'a [&'a str],
}

/// The objects a [`State`] puts on a fake API server.
#[derive(Debug, Clone, Default)]
pub struct State {
    pub records: Vec<Value>,
    pub heads: Vec<Value>,
    pub revisions: Vec<Value>,
    pub objects: Vec<Value>,
}

/// Return the live object named `name`, as every [`State`] writes it.
pub fn object_of(name: &str, stamps: &[String]) -> Value {
    let mut annotations = json!({ (keys::IDENTITY_HASH): format!("h-{name}") });
    if !stamps.is_empty() {
        annotations[keys::ACTIVATIONS] = json!(stamps.join(","));
    }
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "d",
            "uid": format!("uid-{name}"),
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": annotations,
            "managedFields": [{
                "manager": super::field_manager::LEGACY,
                "operation": "Apply",
                "apiVersion": "v1",
            }],
        },
    })
}

fn revision_object(name: &str) -> RevisionObject {
    RevisionObject {
        hash: format!("h-{name}"),
        group: String::new(),
        kind: "ConfigMap".into(),
        namespace: Some("d".into()),
        name: name.into(),
        needs: Vec::new(),
    }
}

/// Return the revision of `objects` in `slot` of Kix cluster `cluster`.
pub fn revision_of(cluster: &str, slot: Slot, objects: &[&str]) -> Revision {
    Revision::new(RevisionSpec::new(
        cluster,
        slot,
        objects.iter().map(|o| revision_object(o)).collect(),
    ))
}

/// Return `revision` as the API server stores it.
pub fn revision_value(revision: &Revision) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": revision::KIND,
        "metadata": {
            "name": revision.name,
            "labels": { (keys::CLUSTER_LABEL): revision.spec.cluster },
        },
        "spec": revision.spec,
        "status": { "applied": revision.applied },
    })
}

/// Return the state of `recs`, each Kix cluster written as `written` says.
pub fn state(recs: &[Rec<'_>], written: impl Fn(&str) -> Written) -> State {
    let mut out = State::default();
    let mut stamps: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    let mut names: BTreeSet<&str> = BTreeSet::new();
    let mut revisions: BTreeMap<String, Revision> = BTreeMap::new();
    for rec in recs {
        names.extend(rec.objects.iter().chain(rec.kept));
        let mut status = json!({ "phase": rec.phase });
        match written(rec.cluster) {
            Written::Records => {
                for o in rec.objects.iter().filter(|o| !rec.unapplied.contains(o)) {
                    stamps.entry(o).or_default().push(rec.hash.to_string());
                }
                if !rec.kept.is_empty() {
                    let build = format!("k-{}", rec.hash);
                    for o in rec.kept {
                        stamps.entry(o).or_default().push(build.clone());
                    }
                    status[keys::ORPHANS_KEPT_FROM_FIELD] = json!([{ "activation": format!("old-{}", rec.name), "identityHash": build }]);
                }
            }
            Written::Revisions if rec.phase != PHASE_SUPERSEDED || rec.current => {
                let slot = Slot::Instance {
                    namespace: "d".into(),
                    name: "app".into(),
                    lifecycle: None,
                };
                let mut instance = revision_of(rec.cluster, slot, rec.objects);
                for o in rec.objects.iter().filter(|o| !rec.unapplied.contains(o)) {
                    let hash = format!("h-{o}");
                    instance
                        .applied
                        .insert(hash.clone(), format!("applied-{hash}"));
                }
                let cluster_level = revision_of(rec.cluster, Slot::ClusterLevel, &[]);
                let kept = (!rec.kept.is_empty())
                    .then(|| revision_of(rec.cluster, Slot::KeptOrphans, rec.kept));
                status["revisions"] = json!({
                    "format": 1,
                    "instances": { "d/app": instance.name },
                    "clusterLevel": cluster_level.name,
                    "keptOrphans": kept.as_ref().map(|k| k.name.clone()),
                });
                for r in std::iter::once(instance)
                    .chain(std::iter::once(cluster_level))
                    .chain(kept)
                {
                    let entry = revisions.entry(r.name.clone()).or_insert_with(|| r.clone());
                    entry.applied.extend(r.applied);
                }
            }
            Written::Revisions => {}
        }
        out.records.push(json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": {
                "name": rec.name,
                "labels": { (keys::CLUSTER_LABEL): rec.cluster },
                "annotations": { (keys::IDENTITY_HASH): rec.hash },
            },
            "status": status,
        }));
        if rec.current {
            out.heads.push(json!({
                "apiVersion": keys::API_VERSION,
                "kind": head::KIND,
                "metadata": { "name": rec.cluster },
                "status": { "current": rec.name, "generation": 1 },
            }));
        }
    }
    out.revisions = revisions.values().map(revision_value).collect();
    out.objects = names
        .iter()
        .map(|name| object_of(name, stamps.get(name).map_or(&[], Vec::as_slice)))
        .collect();
    out
}

impl State {
    /// Return the tenancy of Kix cluster `cluster` this state gives.
    pub fn tenancy(&self, cluster: &str) -> Tenancy {
        let heads: BTreeMap<String, HeadStatus> = self
            .heads
            .iter()
            .map(|h| {
                (
                    h["metadata"]["name"].as_str().unwrap().to_string(),
                    serde_json::from_value(h["status"].clone()).unwrap(),
                )
            })
            .collect();
        let records: Vec<DynamicObject> = self
            .records
            .iter()
            .map(|r| serde_json::from_value(r.clone()).unwrap())
            .collect();
        let revisions: Vec<Revision> = self
            .revisions
            .iter()
            .map(|r| Revision::from_object(&serde_json::from_value(r.clone()).unwrap()).unwrap())
            .collect();
        Tenancy::fixture_of_state(cluster, &heads, &records, &revisions)
    }

    /// Return the live object named `name`.
    pub fn object(&self, name: &str) -> DynamicObject {
        let found = self
            .objects
            .iter()
            .find(|o| o["metadata"]["name"] == name)
            .unwrap_or_else(|| panic!("no object {name}"));
        serde_json::from_value(found.clone()).unwrap()
    }

    /// Return every object of the state, for a fake API server.
    pub fn all(&self) -> Vec<Value> {
        self.records
            .iter()
            .chain(&self.heads)
            .chain(&self.revisions)
            .chain(&self.objects)
            .cloned()
            .collect()
    }

    /// Remove the revision named `name`, as when someone deleted it.
    pub fn remove_revision(&mut self, name: &str) {
        self.revisions.retain(|r| r["metadata"]["name"] != name);
    }

    /// Return the name of the revision record `record` names in `field` of
    /// its map, such as `keptOrphans`.
    pub fn revision_named(&self, record: &str, field: &str) -> String {
        let found = self
            .records
            .iter()
            .find(|r| r["metadata"]["name"] == record)
            .unwrap_or_else(|| panic!("no record {record}"));
        let map = &found["status"]["revisions"];
        let value = match field {
            "instance" => &map["instances"]["d/app"],
            other => &map[other],
        };
        value.as_str().unwrap_or_default().to_string()
    }
}
