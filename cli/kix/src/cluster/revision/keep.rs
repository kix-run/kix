//! Which revisions Kix still needs, and the cleanup of the rest.
//!
//! Only a run that holds the deploy lock cleans up. Lock holders write a
//! record before they create the revisions it names, and [`clean`] lists the
//! revisions before it lists the records. So a revision that [`clean`] lists
//! was either named by a record it then lists, or by none that a lock holder
//! can still write, and no age rule is needed.

use std::collections::BTreeSet;

use kube::Client;
use thiserror::Error;

use super::store::{RevisionError, Revisions};
use crate::cluster::activation::{Record, Records, RecordsError};
use crate::cluster::errors::describe;
use crate::cluster::head::{self, HeadStatus};
use crate::manifest::lifecycle::PHASE_SUPERSEDED;

/// Return the names of the revisions that must stay: every revision named by
/// the record `head` names as current, by the record the lock holder is
/// deploying, and by each record that is not `Superseded`. That covers the
/// queued records, the record being deployed, and each `Failed` or `Partial`
/// record, whose objects a later deploy has not taken in yet.
///
/// A `Superseded` record keeps none: a rollback to it writes its revisions
/// again from its build. A record with no `status.revisions` names none.
pub fn needed(head: Option<&HeadStatus>, records: &[Record]) -> BTreeSet<String> {
    let current = head.and_then(|h| h.current.as_deref());
    let deploying = head
        .and_then(|h| h.lock.as_ref())
        .and_then(|l| l.activation.as_deref());
    records
        .iter()
        .filter(|r| {
            r.phase != PHASE_SUPERSEDED
                || Some(r.name.as_str()) == current
                || Some(r.name.as_str()) == deploying
        })
        .filter_map(|r| r.revisions.as_ref())
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
        "cannot read the ActivationHead of Kix cluster {cluster}: {}. Kix keeps every revision until it can read which record is current",
        describe(.source)
    )]
    Head {
        cluster: String,
        #[source]
        source: kube::Error,
    },
}

/// Return the revisions of Kix cluster `cluster` that [`needed`] does not
/// name. List the revisions first, then the records, then the head.
pub async fn unneeded(
    client: &Client,
    records: &Records,
    cluster: &str,
) -> Result<Vec<String>, CleanError> {
    let revisions = Revisions::new(client).list(cluster).await?;
    let listed = records.of_cluster(cluster).await?;
    let head = head::read(client, cluster)
        .await
        .map_err(|source| CleanError::Head {
            cluster: cluster.to_string(),
            source,
        })?;
    let keep = needed(head.as_ref().and_then(|h| h.status.as_ref()), &listed);
    Ok(revisions
        .into_iter()
        .map(|r| r.name)
        .filter(|name| !keep.contains(name))
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
