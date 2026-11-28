//! Which revisions Kix still needs, and the cleanup of the rest.
//!
//! Only a run that holds the deploy lock creates revisions, writes the map
//! that names them, or cleans up. A run creates its revisions before it
//! writes the map, so a revision no record names is either left over from a
//! run that stopped in between, which nothing needs, or belongs to the lock
//! holder that runs the cleanup, which writes its map before it cleans.
//! Records and revisions are both selected by their `kix.run/cluster` label.
//!
//! The cleanup fails closed. It refuses when the record list cannot be read,
//! when a record's map cannot be read, or when the record the head calls
//! current, or the record the lock holder deploys, is missing from the list.

use std::collections::BTreeSet;

use kube::Client;
use thiserror::Error;

use super::map::UnreadableMap;
use super::store::{Listed, RevisionError, Revisions};
use crate::cluster::activation::{Record, Records, RecordsError};
use crate::cluster::errors::describe;
use crate::cluster::head::{self, HeadStatus};
use crate::manifest::keys;
use crate::manifest::lifecycle::PHASE_SUPERSEDED;

/// Return the names of the revisions that must stay: every revision named by
/// the record `head` names as current, by the record the lock holder is
/// deploying, and by each record that is not `Superseded`. That covers the
/// queued records, the record being deployed, and each `Failed` or `Partial`
/// record, whose objects a later deploy has not taken in yet.
///
/// A `Superseded` record keeps none, unless a needed record lists its build
/// under `status.orphansKeptFrom`: a rollback to it writes its revisions
/// again from its build. A record with no `status.revisions` names none.
/// Refuse when a record's map cannot be read, because it may name
/// revisions this release cannot see.
pub fn needed(
    head: Option<&HeadStatus>,
    records: &[Record],
) -> Result<BTreeSet<String>, CleanError> {
    if let Some((record, Err(source))) = records
        .iter()
        .find_map(|r| Some((r, r.revisions.as_ref()?)).filter(|(_, m)| m.is_err()))
    {
        return Err(CleanError::UnreadableMap {
            record: record.name.clone(),
            source: source.clone(),
        });
    }
    Ok(needed_readable(head, records))
}

/// Return what [`needed`] returns, leaving out the records whose map this
/// Kix cannot read rather than refusing.
pub(crate) fn needed_readable(head: Option<&HeadStatus>, records: &[Record]) -> BTreeSet<String> {
    let current = head.and_then(|h| h.current.as_deref());
    let deploying = head
        .and_then(|h| h.lock.as_ref())
        .and_then(|l| l.activation.as_deref());
    let is_needed = |record: &Record| {
        record.phase != PHASE_SUPERSEDED
            || Some(record.name.as_str()) == current
            || Some(record.name.as_str()) == deploying
    };
    // A record an older Kix wrote lists the builds whose orphans its deploy
    // kept under `status.orphansKeptFrom`. When such a build is a record
    // with revisions, they are what names those orphans.
    let kept_from: std::collections::HashSet<&str> = records
        .iter()
        .filter(|r| is_needed(r))
        .flat_map(|r| r.orphans_kept_from.iter())
        .map(|s| s.identity_hash.as_str())
        .collect();
    let mut names = BTreeSet::new();
    for record in records {
        let Some(Ok(map)) = &record.revisions else {
            continue;
        };
        let kept = record
            .identity_hash
            .as_deref()
            .is_some_and(|h| kept_from.contains(h));
        if is_needed(record) || kept {
            names.extend(map.names().map(str::to_string));
        }
    }
    names
}

/// Return the names of the revisions that a readable map of a record in
/// `records` names, `Superseded` or not.
pub(crate) fn named_by(records: &[Record]) -> BTreeSet<String> {
    records
        .iter()
        .filter_map(|r| r.revisions.as_ref()?.as_ref().ok())
        .flat_map(|map| map.names().map(str::to_string))
        .collect()
}

/// Why [`clean`] stopped.
#[derive(Debug, Error)]
pub enum CleanError {
    #[error(transparent)]
    Revisions(#[from] RevisionError),
    #[error(transparent)]
    Records(#[from] RecordsError),
    #[error(
        "cannot read ActivationHead for Kix cluster '{cluster}': {}. Kix will keep all PackageInstanceRevision objects until it can verify which deployment record is current",
        describe(.source)
    )]
    Head {
        cluster: String,
        #[source]
        source: kube::Error,
    },
    #[error(
        "deployment record `{record}` cannot be read by this version of Kix ({source}), likely because a newer version of Kix wrote it. Kix left all PackageInstanceRevision objects in place"
    )]
    UnreadableMap {
        record: String,
        #[source]
        source: UnreadableMap,
    },
    #[error(
        "ActivationHead for Kix cluster '{cluster}' names deployment record `{record}`, but no deployment record with that name has label `{}={cluster}`. Kix left all PackageInstanceRevision objects in place",
        keys::CLUSTER_LABEL
    )]
    MissingRecord { cluster: String, record: String },
}

/// What Kix reads about a Kix cluster to decide which revisions it keeps.
pub(crate) struct State {
    pub(crate) revisions: Listed,
    pub(crate) records: Vec<Record>,
    pub(crate) head: Option<HeadStatus>,
}

impl State {
    /// Read the revisions of Kix cluster `cluster`, then its records, then
    /// its head. A revision created after the list is the lock holder's,
    /// whose record the later reads see.
    pub(crate) async fn read(
        client: &Client,
        records: &Records,
        cluster: &str,
    ) -> Result<State, CleanError> {
        let revisions = Revisions::new(client).list(cluster).await?;
        let records = records.of_cluster(cluster).await?;
        let head = head::read(client, cluster)
            .await
            .map_err(|source| CleanError::Head {
                cluster: cluster.to_string(),
                source,
            })?
            .and_then(|h| h.status);
        Ok(State {
            revisions,
            records,
            head,
        })
    }

    /// Return the names of the revisions that must stay ([`needed`]).
    pub(crate) fn needed(&self) -> Result<BTreeSet<String>, CleanError> {
        needed(self.head.as_ref(), &self.records)
    }

    /// Return [`needed_readable`] of what was read.
    pub(crate) fn needed_readable(&self) -> BTreeSet<String> {
        needed_readable(self.head.as_ref(), &self.records)
    }
}

/// Return the revisions of Kix cluster `cluster` that [`needed`] does not
/// name, readable or not. List the revisions first, then the records, then
/// the head.
pub async fn unneeded(
    client: &Client,
    records: &Records,
    cluster: &str,
) -> Result<Vec<String>, CleanError> {
    let state = State::read(client, records, cluster).await?;
    let status = state.head.as_ref();
    let current = status.and_then(|h| h.current.as_deref());
    let deploying = status
        .and_then(|h| h.lock.as_ref())
        .and_then(|l| l.activation.as_deref());
    for record in current.into_iter().chain(deploying) {
        if !state.records.iter().any(|r| r.name == record) {
            return Err(CleanError::MissingRecord {
                cluster: cluster.to_string(),
                record: record.to_string(),
            });
        }
    }
    let keep = state.needed()?;
    Ok(state
        .revisions
        .names()
        .filter(|name| !keep.contains(*name))
        .map(str::to_string)
        .collect())
}

/// Delete the revisions of Kix cluster `cluster` that no record needs, and
/// return their names. Call it only while holding the cluster's deploy lock,
/// with `client` the lock's guarded client.
pub async fn clean(
    client: &Client,
    records: &Records,
    cluster: &str,
) -> Result<Vec<String>, CleanError> {
    let store = Revisions::new(client);
    let names = unneeded(client, records, cluster).await?;
    for name in &names {
        store.delete(name).await?;
    }
    if !names.is_empty() {
        tracing::debug!(
            cluster,
            count = names.len(),
            "deleted revisions no record needs"
        );
    }
    Ok(names)
}

/// Name a new kept-orphans revision of `objects` on record `record` of Kix
/// cluster `cluster`, for `kix gc --full-scan` to rebuild a list that is
/// missing or cannot be read. Create the revision before the write that
/// names it, so the map names only revisions that exist. Hold the deploy
/// lock while calling this.
pub async fn rebuild_kept(
    client: &Client,
    records: &Records,
    cluster: &str,
    record: &str,
    objects: Vec<super::RevisionObject>,
) -> Result<String, String> {
    let revision = super::Revision::new(super::RevisionSpec::new(
        cluster,
        super::Slot::KeptOrphans,
        objects,
    ));
    Revisions::new(client)
        .create(&revision)
        .await
        .map_err(|e| e.to_string())?;
    records
        .name_kept_orphans(record, &revision.name)
        .await
        .map_err(|e| e.to_string())?;
    Ok(revision.name)
}

/// Return what a rebuilt kept-orphans list names: each labelled, prunable
/// live object of `sweep` that the Kix cluster applied, that no other
/// revision of it names, and that the build compared with, whose objects
/// are `in_build`, lacks. Nothing says which build wanted each object, so
/// each gets the hash [`super::REBUILT`], which no object hash equals, and
/// no edges.
pub fn kept_to_rebuild(
    sweep: &crate::cluster::inventory::ManagedSweep,
    in_build: &std::collections::HashSet<crate::manifest::types::ResourceId>,
) -> Vec<super::RevisionObject> {
    let tenancy = &sweep.tenancy;
    let mut objects: Vec<super::RevisionObject> = sweep
        .managed
        .iter()
        .chain(&sweep.unattributed)
        .filter(|obj| crate::manifest::lifecycle::lifecycle_of_live(obj).prunable())
        .filter(|obj| tenancy.unlisted_own(obj))
        .map(crate::cluster::drift::resource_id)
        .filter(|rid| !in_build.contains(rid))
        .map(|rid| super::RevisionObject::of_id(super::REBUILT, &rid))
        .collect();
    objects.sort();
    objects.dedup();
    objects
}
