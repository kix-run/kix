//! The last check before a prune deletes an object.
//!
//! Two Kix clusters on one Kubernetes cluster can both contain an object,
//! such as an identical ClusterRole. When one drops it from its build, its
//! prune plans the object as an orphan while the other's current build still
//! contains it. Every prune path (deploy and rollback through
//! `super::ops::KubeResources`, soft and hard gc, and the operator's reconcile
//! and finalizer) deletes through [`PruneGuard::delete`]. It reads the object,
//! decides whether another Kix cluster deploys it
//! ([`Tenancy::still_deployed_by_others`]), and deletes only an object no other
//! Kix cluster deploys. The delete carries the read's uid and
//! `resourceVersion` as preconditions, so Kubernetes refuses it when the
//! object changed after the read. The guard then reads and judges the object
//! again, because the write may have been one the judgment does not depend
//! on, such as a controller updating its status.
//!
//! The guard keeps an object when another Kix cluster
//!
//! - has an `Apply` entry under its own field manager on the object
//!   ([`super::field_manager`]), whatever its records say,
//! - has a record that is not `Superseded`, or the record its lock names,
//!   whose revisions, other than its kept orphans, name the object, or
//! - is read from records and has such a record whose identity hash the
//!   object's `kix.run/activations` names.
//!
//! The records and revisions are read once per guard, which lives for one
//! run, and read again only when the object names a record hash the last
//! read does not settle ([`tenancy::settles`]).
//!
//! # Why a delete cannot remove what another Kix cluster is deploying
//!
//! Say this guard read the object at version `v`, decided from records read
//! at any time before or after, and deleted at `v`. Take another Kix cluster
//! B that deploys the object in a run whose record the guard did not see.
//!
//! B applies under its own field manager and plans from revisions: before a
//! run writes any object, it gives the records an older Kix wrote revisions
//! ([`super::revision::convert`]), and its plan reads them the same way.
//! B's planner leaves an object unchanged only when the object has B's
//! `Apply` entry, or when its entry under the legacy manager `kix` holds
//! B's fields, which B's planner counts only on an object a record of B
//! already named ([`super::migration_write::takes_legacy`]). On any other
//! object it finds no fields of B's to compare, and applies it. So either
//! B wrote the object, which changes `resourceVersion`, or a record of B
//! named it before B's run.
//!
//! - If B wrote the object before the guard's read, B's entry was there at
//!   `v`, and the guard kept it.
//! - If B writes the object after the guard's read and before its delete,
//!   the delete is refused, the guard reads the object again, finds B's
//!   entry, and keeps it. Kubernetes changes `resourceVersion` when an
//!   apply under a new manager adds an entry, even when the values are the
//!   same, and the migration write changes it too.
//! - If B applies the object after the delete, B's apply creates it again,
//!   or finds it still being deleted and fails with a message that says so.
//! - If a record of B named the object before B's run, the guard finds it,
//!   whenever it read the records: a record with a map is read from its
//!   revisions whatever B's head names, and a record an older Kix wrote is
//!   read from the object's `kix.run/activations`, which B removes only
//!   with the migration write, after its run created its own record and
//!   revisions. That write changes `resourceVersion`.
//!
//! So a failed migration write, which is best-effort for an unchanged
//! object, leaves the object safe. No step depends on when the records were
//! read, so reading them once is enough. The records cover a run that named
//! the object but has not applied it yet, for example one that is under way
//! or stopped before it got there.
//!
//! A Kix cluster that an older Kix still deploys applies under `kix` and
//! writes the deploying record's hash into `kix.run/activations` after each
//! apply. That write changes `resourceVersion`, and the record exists before
//! it, so the guard either finds the hash at `v`, and reads the records
//! again when it is new, or has its delete refused. While an object's note
//! names a record of such a Kix cluster, B's migration write keeps the note
//! with B's deploying record's hash in it, so a guard of an earlier release,
//! which reads only the note, judges the object as before.
//!
//! `kix gc` and the operator's finalizer delete a whole ordered list, and both
//! go through [`delete_in_order`]. It owns which objects are never deleted
//! and the wait for each deleted object to be gone, and returns one
//! [`Removal`] per object for the caller to print or log. Every prune path
//! asks [`discovery::lookup_kind`] whether the cluster serves an object's
//! kind, and reports an object of a kind it does not serve as
//! [`Pruned::NotServed`].

use std::collections::HashMap;
use std::time::Duration;

use kube::{
    Client,
    api::{DeleteParams, DynamicObject, Preconditions},
    discovery::{ApiResource, Scope},
};
use thiserror::Error;
use tokio::sync::Mutex;

use super::activation::{OpenedRecords, Records, RecordsError};
use super::cancel::CancelToken;
use super::discovery::{self, KindLookup};
use super::errors::FetchError;
use super::graph::{DeleteOrder, Walked};
use super::inventory::SharedOrphan;
use super::readiness::{Controller, Deletion, Stuck, controller_state, finalizers_of, wait_gone};
use super::tenancy::{self, Tenancy};
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::lifecycle;
use crate::manifest::types::ResourceId;

/// What [`PruneGuard::delete`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pruned {
    /// The API server accepted the delete. The object stays on the cluster
    /// until its finalizers are removed. `uid` is the uid of the object
    /// deleted, for [`super::readiness::wait_gone`]. `finalizers` are the
    /// finalizers the object held when it was read, which the delete waits
    /// for.
    Deleted {
        uid: Option<String>,
        finalizers: Vec<String>,
    },
    /// The object was already being deleted, so no request was sent. `since`
    /// is its `metadata.deletionTimestamp`.
    AlreadyDeleting {
        uid: Option<String>,
        finalizers: Vec<String>,
        since: Option<String>,
    },
    /// Not on the cluster.
    Gone,
    /// The cluster does not serve the object's kind, so the object cannot
    /// exist ([`discovery::KindLookup::NotServed`]). This happens when a
    /// deploy recorded an object it never created, or when its
    /// CustomResourceDefinition was removed.
    NotServed,
    /// Another Kix cluster deploys it, so it stays.
    Kept(SharedOrphan),
    /// It changed between the read and the delete on each of
    /// [`DELETE_ATTEMPTS`] attempts, so it stays. The next prune judges it
    /// again.
    Changed(ResourceId),
}

impl Pruned {
    /// Format the line a command prints when the guard leaves an object in place.
    pub fn kept_reason(&self) -> Option<String> {
        match self {
            Pruned::Kept(shared) => Some(shared.describe()),
            Pruned::Changed(rid) => Some(format!(
                "[K6315] could not delete {rid}: something modified it during all {DELETE_ATTEMPTS} delete attempts, so Kix left it on the cluster; stop what keeps updating {rid} (or wait for updates to settle), then run `kix gc` or `--prune` again"
            )),
            Pruned::Deleted { .. }
            | Pruned::AlreadyDeleting { .. }
            | Pruned::Gone
            | Pruned::NotServed => None,
        }
    }

    /// Return what a command says about an object it did not delete because
    /// it was not there, or `None` for any other outcome. `kix deploy`,
    /// `kix rollback`, and `kix gc` all print this text.
    pub fn already_gone(&self) -> Option<&'static str> {
        match self {
            Pruned::Gone => Some("already gone"),
            Pruned::NotServed => Some("already gone (Kubernetes does not recognize its kind)"),
            Pruned::Deleted { .. }
            | Pruned::AlreadyDeleting { .. }
            | Pruned::Kept(_)
            | Pruned::Changed(_) => None,
        }
    }

    /// Return the uid of the object to wait for when the delete was sent or
    /// was already under way, or `None` when nothing is being deleted.
    pub fn deleting(&self) -> Option<Option<&str>> {
        match self {
            Pruned::Deleted { uid, .. } | Pruned::AlreadyDeleting { uid, .. } => {
                Some(uid.as_deref())
            }
            Pruned::Gone | Pruned::NotServed | Pruned::Kept(_) | Pruned::Changed(_) => None,
        }
    }
}

#[derive(Debug, Error)]
pub enum PruneError {
    #[error("{}", super::errors::describe(.0))]
    Kube(#[from] kube::Error),
    #[error("cannot tell whether another Kix cluster still deploys it: {0}")]
    Records(#[from] RecordsError),
    /// Kix could not read part of what says which objects other Kix
    /// clusters deploy.
    #[error(
        "not deleted because Kix cannot determine whether another Kix cluster still deploys it: {0}"
    )]
    Tenancy(#[from] super::tenancy::Problem),
    /// Kix could not tell whether the cluster serves the object's kind.
    #[error("not deleted because Kix could not check whether Kubernetes recognizes its kind: {0}")]
    Discovery(#[from] FetchError),
}

/// How many times [`PruneGuard::delete`] reads, judges, and deletes an object
/// that changes between its read and its delete before it leaves the object
/// in place. Each refused delete means the object was written in the moment
/// between the two requests, so a controller that writes the object now and
/// then does not use them up.
pub const DELETE_ATTEMPTS: usize = 5;

/// Deletes orphans of one Kix cluster. See the module docs.
pub struct PruneGuard {
    client: Client,
    /// What [`Records::open`](super::activation::Records::open) returned.
    /// When the cluster serves no Activation kind, no other cluster has
    /// records.
    records: OpenedRecords,
    cluster: String,
    /// The last records read. Reread when an object names a hash it lacks,
    /// which is how a record created after the last read shows up.
    tenancy: Mutex<Option<std::sync::Arc<Tenancy>>>,
}

impl PruneGuard {
    /// Create a prune guard for `cluster`. When `records` holds no `Activation`
    /// API, no other cluster can have records, and the guard only attaches
    /// delete preconditions.
    pub fn new(client: Client, records: OpenedRecords, cluster: &str) -> Self {
        PruneGuard {
            client,
            records,
            cluster: cluster.to_string(),
            tenancy: Mutex::new(None),
        }
    }

    /// Read `rid`, and delete it with `params` plus preconditions on the
    /// object read, unless another Kix cluster's current record names it or
    /// it is already being deleted. When the object changed after the read,
    /// Kubernetes refuses the delete, and the guard reads and judges it
    /// again, up to [`DELETE_ATTEMPTS`] times. The caller waits for a
    /// deleted object to be gone.
    pub async fn delete(
        &self,
        ar: &ApiResource,
        scope: &Scope,
        rid: &ResourceId,
        params: &DeleteParams,
    ) -> Result<Pruned, PruneError> {
        let api = discovery::api_for(&self.client, ar, scope, rid);
        for _ in 0..DELETE_ATTEMPTS {
            if let Some(pruned) = self.delete_once(&api, rid, params).await? {
                return Ok(pruned);
            }
        }
        Ok(Pruned::Changed(rid.clone()))
    }

    /// Read `rid` and judge it, then delete it with the read's uid and
    /// resourceVersion as preconditions. Return `None` when Kubernetes
    /// refused the delete because the object changed after the read.
    async fn delete_once(
        &self,
        api: &kube::Api<DynamicObject>,
        rid: &ResourceId,
        params: &DeleteParams,
    ) -> Result<Option<Pruned>, PruneError> {
        let Some(obj) = api.get_opt(&rid.name).await? else {
            return Ok(Some(Pruned::Gone));
        };
        let clusters = self
            .tenancy_naming(&obj)
            .await?
            .still_deployed_by_others(&obj);
        if !clusters.is_empty() {
            return Ok(Some(Pruned::Kept(SharedOrphan {
                rid: rid.clone(),
                clusters,
            })));
        }
        let uid = obj.metadata.uid.clone();
        let finalizers = finalizers_of(&obj);
        if let Some(since) = &obj.metadata.deletion_timestamp {
            return Ok(Some(Pruned::AlreadyDeleting {
                uid,
                finalizers,
                since: serde_json::to_value(since)
                    .ok()
                    .and_then(|t| t.as_str().map(str::to_string)),
            }));
        }
        let params = DeleteParams {
            preconditions: Some(Preconditions {
                uid: uid.clone(),
                resource_version: obj.metadata.resource_version.clone(),
            }),
            ..params.clone()
        };
        match api.delete(&rid.name, &params).await {
            Ok(_) => Ok(Some(Pruned::Deleted { uid, finalizers })),
            Err(kube::Error::Api(ae)) if ae.code == 404 => Ok(Some(Pruned::Gone)),
            Err(kube::Error::Api(ae)) if ae.code == 409 => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Return a [`Tenancy`] read after `obj` whenever `obj` names a record hash
    /// the cached tenancy does not settle ([`Tenancy::knows`]). Because a
    /// record's cluster never changes, a `Superseded` record stays
    /// `Superseded`, and a record's map names the same revisions once
    /// written, a cached tenancy that settles every hash can only overstate
    /// what other clusters still deploy. Refuse when the read could not tell
    /// what another Kix cluster deploys ([`Tenancy::complete_for_others`]).
    pub(crate) async fn tenancy_naming(
        &self,
        obj: &DynamicObject,
    ) -> Result<std::sync::Arc<Tenancy>, PruneError> {
        let mut slot = self.tenancy.lock().await;
        if let Some(t) = &*slot
            && tenancy::settles(t, obj)
        {
            return Ok(t.clone());
        }
        let read = tenancy::read(&self.records, &self.cluster).await?;
        read.complete_for_others()?;
        let read = std::sync::Arc::new(read);
        *slot = Some(read.clone());
        Ok(read)
    }
}

/// What [`delete_in_order`] did with one object.
#[derive(Debug)]
pub enum Removal {
    /// `lifecycle::never_pruned` protects its kind, so no request was sent.
    NeverPruned,
    /// [`PruneGuard::delete`] returned this outcome. A `Deleted` or
    /// `AlreadyDeleting` object is gone by the time this is reported.
    Pruned(Pruned),
    /// The object was still being deleted when the wait ended.
    Stuck(Stuck),
    /// Not deleted, because `by`, which depends on it, is still on the
    /// cluster ([`DeleteOrder::hold_back`]). `shared` says that `by` stays
    /// because another Kix cluster still deploys it.
    HeldBack { by: ResourceId, shared: bool },
    /// Not deleted, because it is part of a dependency cycle or something in
    /// one depends on it ([`Walked::Cycle`]).
    Cycle,
    /// Not deleted, or not waited for to the end, because the cancel token
    /// fired.
    Cancelled,
    /// [`PruneGuard::delete`] or the wait for the object failed.
    Failed(PruneError),
}

impl Removal {
    /// Return whether the object is still on the cluster after this attempt,
    /// so what it depends on must stay too.
    pub fn still_live(&self) -> bool {
        match self {
            Removal::NeverPruned => false,
            Removal::Pruned(pruned) => matches!(pruned, Pruned::Kept(_) | Pruned::Changed(_)),
            Removal::Stuck(_)
            | Removal::HeldBack { .. }
            | Removal::Cycle
            | Removal::Cancelled
            | Removal::Failed(_) => true,
        }
    }

    /// Return whether the object is still on the cluster and still this Kix
    /// cluster's to delete, so a teardown is not done. An object another Kix
    /// cluster still deploys, and what it holds back, belongs to that
    /// cluster.
    pub fn unfinished(&self) -> bool {
        match self {
            Removal::Pruned(Pruned::Kept(_)) | Removal::HeldBack { shared: true, .. } => false,
            other => other.still_live(),
        }
    }
}

/// A step of [`delete_in_order`], reported as it happens.
pub enum Step<'a> {
    /// The object is still being deleted, for this reason.
    Waiting(&'a str),
    /// What happened to the object.
    Done(&'a Removal),
}

/// Why [`delete_in_order`] deleted nothing.
#[derive(Debug, Error)]
pub enum DeleteInOrderError {
    #[error("{0}")]
    Discovery(#[from] FetchError),
    #[error("{0}")]
    Domain(#[from] LegacyDomainError),
}

/// Read the live object `id`, or `None` when it is not on the cluster or
/// Kubernetes does not serve its kind.
async fn read_live(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    id: &ResourceId,
) -> Result<Option<DynamicObject>, String> {
    let Some((ar, scope)) = discovery::find(discovery, &id.group, &id.kind) else {
        return Ok(None);
    };
    discovery::api_for(client, ar, scope, id)
        .get_opt(&id.name)
        .await
        .map_err(|e| e.to_string())
}

/// How many deletes [`delete_in_order`] runs at a time.
const DELETE_CONCURRENCY: usize = 64;

/// Delete the objects of `order` of `cluster` through a [`PruneGuard`] with
/// the propagation [`DeleteOrder::propagation`] gives, as deploy's prune
/// does, walking the order with
/// [`DeleteOrder::walk`]. After each delete, wait up to `budget` without
/// progress for the object to be gone ([`wait_gone`]). An object still there
/// after the wait holds back what it depends on. Report each step to `report`
/// as it happens, and return what happened to each object in the order's
/// order. Once `cancel` fires, nothing new starts.
///
/// Kinds `lifecycle::never_pruned` protects are never sent to the API server.
/// When every object is protected, nothing is read from the cluster. An error
/// for one object does not stop the others, so the only errors returned are
/// those that come before the first delete: API discovery, and the retired
/// domain check that opening the records runs.
pub async fn delete_in_order(
    client: &Client,
    cluster: &str,
    mut order: DeleteOrder,
    budget: Duration,
    cancel: &CancelToken,
    report: &mut Report<'_>,
) -> Result<Vec<(ResourceId, Removal)>, DeleteInOrderError> {
    let protected = |rid: &ResourceId| lifecycle::never_pruned(rid.group_kind());
    let ids = order.ids().to_vec();
    let mut removals: Vec<(ResourceId, Removal)> = Vec::with_capacity(ids.len());
    if ids.iter().all(protected) {
        for rid in &ids {
            report(rid, Step::Done(&Removal::NeverPruned));
            removals.push((rid.clone(), Removal::NeverPruned));
        }
        return Ok(removals);
    }
    let discovery = discovery::discover_resources(client).await?;
    let guard = PruneGuard::new(client.clone(), Records::open(client, &discovery)?, cluster);
    let mut shared: std::collections::HashSet<ResourceId> = std::collections::HashSet::new();
    // Deletes run concurrently and report while they wait, so the reporter
    // is shared behind a lock that no one holds across an await.
    let report = std::sync::Mutex::new(report);
    let say = |rid: &ResourceId, step: Step<'_>| {
        if let Ok(mut report) = report.lock() {
            report(rid, step);
        }
    };
    let controllers = order.controllers().clone();
    let params: HashMap<ResourceId, DeleteParams> = ids
        .iter()
        .map(|rid| {
            let params = DeleteParams {
                propagation_policy: Some(order.propagation(rid)),
                ..DeleteParams::default()
            };
            (rid.clone(), params)
        })
        .collect();
    let start = |rid: &ResourceId| {
        let rid = rid.clone();
        let (guard, params, discovery, say, controllers) =
            (&guard, &params[&rid], &discovery, &say, &controllers);
        async move {
            if protected(&rid) {
                return Removal::NeverPruned;
            }
            let (ar, scope) =
                match discovery::lookup_kind(client, discovery, &rid.group, &rid.kind).await {
                    Ok(KindLookup::Served(ar, scope)) => (ar, scope),
                    Ok(KindLookup::NotServed) => return Removal::Pruned(Pruned::NotServed),
                    Err(e) => return Removal::Failed(e.into()),
                };
            let (ar, scope) = (&ar, &scope);
            let pruned = match guard.delete(ar, scope, &rid, params).await {
                Ok(pruned) => pruned,
                Err(e) => return Removal::Failed(e),
            };
            let Some(uid) = pruned.deleting() else {
                return Removal::Pruned(pruned);
            };
            let api = discovery::api_for(client, ar, scope, &rid);
            let waited = wait_gone(&api, &rid.name, uid, budget, cancel, |status| {
                say(&rid, Step::Waiting(status))
            })
            .await;
            match waited {
                Ok(Deletion::Gone) => Removal::Pruned(pruned),
                Ok(Deletion::Stuck(mut stuck)) => {
                    for id in controllers.get(&rid).into_iter().flatten() {
                        stuck.controllers.push(Controller {
                            id: id.clone(),
                            state: controller_state(id, read_live(client, discovery, id).await),
                        });
                    }
                    Removal::Stuck(stuck)
                }
                Ok(Deletion::Cancelled) => Removal::Cancelled,
                Err(e) => Removal::Failed(e.into()),
            }
        }
    };
    order
        .walk(
            DELETE_CONCURRENCY,
            cancel,
            start,
            Removal::still_live,
            |rid, walked| {
                let removal = match walked {
                    Walked::Done(removal) => {
                        if matches!(removal, Removal::Pruned(Pruned::Kept(_))) {
                            shared.insert(rid.clone());
                        }
                        removal
                    }
                    Walked::HeldBack(by) => Removal::HeldBack {
                        by: by.clone(),
                        shared: shared.contains(by),
                    },
                    Walked::Cycle => Removal::Cycle,
                    Walked::NotStarted => Removal::Cancelled,
                };
                say(rid, Step::Done(&removal));
                removals.push((rid.clone(), removal));
            },
        )
        .await;
    let position: std::collections::HashMap<&ResourceId, usize> =
        ids.iter().enumerate().map(|(i, rid)| (rid, i)).collect();
    removals.sort_by_key(|(rid, _)| position.get(rid).copied());
    Ok(removals)
}

type Report<'a> = dyn FnMut(&ResourceId, Step<'_>) + Send + 'a;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::cluster::readiness;
    use crate::manifest::keys;
    use crate::manifest::lifecycle;
    use crate::manifest::lifecycle::RECORD_KIND;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::{Value, json};

    fn record(cluster: &str, hash: &str, phase: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": phase },
        })
    }

    fn role(name: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": {
                "name": name,
                "annotations": { (keys::ACTIVATIONS): activations },
            },
        })
    }

    async fn guard(api: &FakeApi, cluster: &str) -> (PruneGuard, Vec<(ApiResource, Scope)>) {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = crate::cluster::activation::Records::open(&client, &discovery).unwrap();
        (PruneGuard::new(client, records, cluster), discovery)
    }

    /// Run [`delete_in_order`] as cluster `a` over `resources` in the order
    /// given, with a 10-second budget.
    async fn delete_all(api: &FakeApi, resources: &[ResourceId]) -> Vec<(ResourceId, Removal)> {
        delete_in_order(
            &api.client(),
            "a",
            DeleteOrder::unordered(resources.to_vec()),
            Duration::from_secs(10),
            &CancelToken::new(),
            &mut |_, _| {},
        )
        .await
        .unwrap()
    }

    async fn delete(g: &PruneGuard, d: &[(ApiResource, Scope)], rid: &ResourceId) -> Pruned {
        let (ar, scope) = discovery::find(d, &rid.group, &rid.kind).unwrap();
        g.delete(ar, scope, rid, &DeleteParams::default())
            .await
            .unwrap()
    }

    /// `a` drops a ClusterRole that `b`'s Active record still names: kept.
    /// One only `a` and a Superseded record of `b` name: deleted.
    #[tokio::test]
    async fn an_object_another_cluster_still_deploys_is_kept() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            record("b", "b0", lifecycle::PHASE_SUPERSEDED),
            record("b", "b1", lifecycle::PHASE_ACTIVE),
            role("shared", "a1,b1"),
            role("once-shared", "a1,b0"),
        ]);
        let (g, d) = guard(&api, "a").await;
        let shared = ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            "shared",
        );
        assert_eq!(
            delete(&g, &d, &shared).await,
            Pruned::Kept(SharedOrphan {
                rid: shared,
                clusters: vec!["b".into()],
            })
        );
        let once = ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            "once-shared",
        );
        assert!(matches!(
            delete(&g, &d, &once).await,
            Pruned::Deleted { uid: Some(_), .. }
        ));
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
        assert_eq!(delete(&g, &d, &once).await, Pruned::Gone);
    }

    fn mine() -> ResourceId {
        ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            "mine",
        )
    }

    /// A controller writes the object's status between the guard's read and
    /// its delete. The judgment does not depend on status, so the guard reads
    /// it again and deletes it.
    #[tokio::test]
    async fn an_object_whose_status_changes_after_the_read_is_deleted() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            role("mine", "a1"),
        ]);
        api.after_get("mine", |o| {
            o["status"] = json!({ "observedGeneration": 2 });
        });
        let (g, d) = guard(&api, "a").await;
        assert!(matches!(
            delete(&g, &d, &mine()).await,
            Pruned::Deleted { .. }
        ));
        assert!(api.names("ClusterRole").is_empty());
    }

    /// Another cluster's deploy stamps the object between the guard's read
    /// and its delete. The precondition refuses the delete, and the guard's
    /// second read finds that the other cluster deploys it, so it stays.
    #[tokio::test]
    async fn an_object_another_cluster_stamps_after_the_read_is_kept() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            record("b", "b1", lifecycle::PHASE_ACTIVE),
            role("mine", "a1"),
        ]);
        api.after_get("mine", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("a1,b1");
        });
        let (g, d) = guard(&api, "a").await;
        assert_eq!(
            delete(&g, &d, &mine()).await,
            Pruned::Kept(SharedOrphan {
                rid: mine(),
                clusters: vec!["b".into()],
            })
        );
        assert_eq!(api.names("ClusterRole"), vec!["mine"]);
    }

    /// An object written between every read and delete stays after
    /// `DELETE_ATTEMPTS` attempts, for the next prune to judge.
    #[tokio::test]
    async fn an_object_written_on_every_attempt_is_left_in_place() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            role("mine", "a1"),
        ]);
        for n in 0..DELETE_ATTEMPTS {
            api.after_get("mine", move |o| {
                o["status"] = json!({ "observedGeneration": n });
            });
        }
        let (g, d) = guard(&api, "a").await;
        assert_eq!(delete(&g, &d, &mine()).await, Pruned::Changed(mine()));
        assert_eq!(api.names("ClusterRole"), vec!["mine"]);
    }

    /// A record created after the guard's first read is found: the object
    /// naming it makes the guard read the records again.
    #[tokio::test]
    async fn a_record_created_after_the_first_read_is_seen() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            role("first", "a1"),
        ]);
        let (g, d) = guard(&api, "a").await;
        let first = ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            "first",
        );
        assert!(matches!(
            delete(&g, &d, &first).await,
            Pruned::Deleted { .. }
        ));

        // `b`'s first deploy: its record, then an object naming it.
        api.insert(record("b", "b1", lifecycle::PHASE_DEPLOYING));
        api.insert(role("later", "a1,b1"));
        let later = ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            "later",
        );
        assert!(matches!(delete(&g, &d, &later).await, Pruned::Kept(_)));
    }

    /// Two Kix clusters, `a` read from records and `b` read from
    /// revisions: each one's prune keeps what the other deploys, read from
    /// the other's own source, and deletes what the other only kept.
    #[tokio::test]
    async fn each_cluster_keeps_what_the_other_deploys_from_its_own_source() {
        use crate::cluster::tenancy_fixture::{Rec, Written, state};
        let recs = [
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "acur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["ours", "shared"],
                ..Rec::default()
            },
            Rec {
                name: "b-cur",
                cluster: "b",
                hash: "bcur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["theirs", "shared"],
                kept: &["their-left"],
                ..Rec::default()
            },
        ];
        let state = state(&recs, |c| {
            if c == "a" {
                Written::Records
            } else {
                Written::Revisions
            }
        });
        let cm = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
        let api = FakeApi::new(state.all());
        let (g, d) = guard(&api, "a").await;
        assert_eq!(
            delete(&g, &d, &cm("shared")).await,
            Pruned::Kept(SharedOrphan {
                rid: cm("shared"),
                clusters: vec!["b".into()],
            })
        );
        assert!(matches!(
            delete(&g, &d, &cm("their-left")).await,
            Pruned::Deleted { .. }
        ));
        let (g, d) = guard(&api, "b").await;
        assert_eq!(
            delete(&g, &d, &cm("ours")).await,
            Pruned::Kept(SharedOrphan {
                rid: cm("ours"),
                clusters: vec!["a".into()],
            })
        );
    }

    /// A revision another Kix cluster's record names is missing, so the
    /// guard cannot tell what that cluster deploys and deletes nothing.
    #[tokio::test]
    async fn a_missing_revision_of_another_cluster_stops_the_prune() {
        use crate::cluster::tenancy_fixture::{Rec, Written, state};
        let recs = [
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "acur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["ours"],
                ..Rec::default()
            },
            Rec {
                name: "b-cur",
                cluster: "b",
                hash: "bcur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["theirs"],
                ..Rec::default()
            },
        ];
        let mut state = state(&recs, |_| Written::Revisions);
        let missing = state.revision_named("b-cur", "instance");
        state.remove_revision(&missing);
        let api = FakeApi::new(state.all());
        let (g, d) = guard(&api, "a").await;
        let rid = ResourceId::new("", "ConfigMap", "d", "ours");
        let (ar, scope) = discovery::find(&d, &rid.group, &rid.kind).unwrap();
        let err = g
            .delete(ar, scope, &rid, &DeleteParams::default())
            .await
            .unwrap_err();
        assert!(matches!(err, PruneError::Tenancy(_)), "{err}");
        assert!(err.to_string().contains(&missing), "{err}");
        assert_eq!(api.names("ConfigMap"), ["ours", "theirs"]);
    }

    /// A queued record of a Kix cluster read from revisions has no map at
    /// the guard's first read. Once its deploy names its revisions and
    /// stamps an object, the guard reads again and keeps the object.
    #[tokio::test]
    async fn a_record_that_gains_its_map_after_the_first_read_is_seen() {
        use crate::cluster::tenancy_fixture::{Rec, Written, state};
        let recs = [
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "acur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["first", "later"],
                ..Rec::default()
            },
            Rec {
                name: "b-cur",
                cluster: "b",
                hash: "bcur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["theirs"],
                ..Rec::default()
            },
            Rec {
                name: "b-next",
                cluster: "b",
                hash: "bnext",
                phase: lifecycle::PHASE_DEPLOYING,
                objects: &["theirs", "later"],
                ..Rec::default()
            },
        ];
        let full = state(&recs, |_| Written::Revisions);
        let mut first = full.clone();
        let queued = first
            .records
            .iter_mut()
            .find(|r| r["metadata"]["name"] == "b-next")
            .unwrap();
        queued["status"] = json!({});
        let api = FakeApi::new(first.all());
        let (g, d) = guard(&api, "a").await;
        let cm = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
        assert!(matches!(
            delete(&g, &d, &cm("first")).await,
            Pruned::Deleted { .. }
        ));
        // `b-next` begins: its map, then an object stamped with its hash.
        let named = full
            .records
            .iter()
            .find(|r| r["metadata"]["name"] == "b-next")
            .unwrap()
            .clone();
        api.patch_object(RECORD_KIND, "b-next", |r| {
            r["status"] = named["status"].clone()
        });
        api.patch_object("ConfigMap", "later", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("acur,bnext");
        });
        assert_eq!(
            delete(&g, &d, &cm("later")).await,
            Pruned::Kept(SharedOrphan {
                rid: cm("later"),
                clusters: vec!["b".into()],
            })
        );
    }

    /// Add an `Apply` entry under `manager` to `o`.
    fn applied_by(o: &mut Value, manager: &str) {
        let entry = json!({ "manager": manager, "operation": "Apply", "apiVersion": "v1" });
        match o["metadata"]["managedFields"].as_array_mut() {
            Some(entries) => entries.push(entry),
            None => o["metadata"]["managedFields"] = json!([entry]),
        }
    }

    fn role_applied_by(name: &str, activations: &str, managers: &[&str]) -> Value {
        let mut o = role(name, activations);
        for m in managers {
            applied_by(&mut o, m);
        }
        o
    }

    fn cluster_role(name: &str) -> ResourceId {
        ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            name,
        )
    }

    /// An object with an `Apply` entry of another Kix cluster's manager is
    /// kept although no record of that cluster names it, and although that
    /// cluster has no records at all. The legacy entry and this cluster's
    /// own entry keep nothing.
    #[tokio::test]
    async fn an_object_another_cluster_applies_is_kept_without_a_record() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            record("b", "b1", lifecycle::PHASE_ACTIVE),
            role_applied_by("by-b", "a1", &["kix/a", "kix/b"]),
            role_applied_by("by-c", "a1", &["kix/c"]),
            role_applied_by(
                "own",
                "a1",
                &[crate::cluster::field_manager::LEGACY, "kix/a"],
            ),
        ]);
        let (g, d) = guard(&api, "a").await;
        for (name, other) in [("by-b", "b"), ("by-c", "c")] {
            assert_eq!(
                delete(&g, &d, &cluster_role(name)).await,
                Pruned::Kept(SharedOrphan {
                    rid: cluster_role(name),
                    clusters: vec![other.into()],
                })
            );
        }
        assert!(matches!(
            delete(&g, &d, &cluster_role("own")).await,
            Pruned::Deleted { .. }
        ));
        assert_eq!(api.names("ClusterRole"), ["by-b", "by-c"]);
    }

    /// Another Kix cluster applies the object under its own manager between
    /// the guard's read and its delete, with the same content, and writes
    /// nothing else. The new entry changes `resourceVersion`, so the delete
    /// is refused, and the guard's second read finds the entry and keeps the
    /// object. The records are read once.
    #[tokio::test]
    async fn another_clusters_first_apply_after_the_read_keeps_the_object() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            record("b", "b1", lifecycle::PHASE_ACTIVE),
            role_applied_by("first", "a1", &["kix/a"]),
            role_applied_by("mine", "a1", &["kix/a"]),
        ]);
        api.after_get("mine", |o| applied_by(o, "kix/b"));
        let (g, d) = guard(&api, "a").await;
        assert!(matches!(
            delete(&g, &d, &cluster_role("first")).await,
            Pruned::Deleted { .. }
        ));
        assert_eq!(
            delete(&g, &d, &cluster_role("mine")).await,
            Pruned::Kept(SharedOrphan {
                rid: cluster_role("mine"),
                clusters: vec!["b".into()],
            })
        );
        assert_eq!(api.names("ClusterRole"), ["mine"]);
        let requests = api.requests();
        let deletes = requests.iter().filter(|r| r.starts_with("DELETE")).count();
        assert_eq!(deletes, 2, "{requests:?}");
        let record_lists = requests
            .iter()
            .filter(|r| {
                r.starts_with("GET") && r.contains("/activations") && !r.contains("/activations/")
            })
            .count();
        assert_eq!(record_lists, 1, "{requests:?}");
    }

    /// The pair of a Kix cluster `a` read from revisions that applies under
    /// its own manager, and a Kix cluster `b` of an earlier release read from
    /// records that applies under the legacy manager and stamps
    /// `kix.run/activations`, both ways round.
    fn mixed() -> FakeApi {
        use crate::cluster::tenancy_fixture::{Rec, Written, state};
        let recs = [
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "acur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["a-only", "shared"],
                ..Rec::default()
            },
            Rec {
                name: "b-cur",
                cluster: "b",
                hash: "bcur",
                phase: lifecycle::PHASE_ACTIVE,
                current: true,
                objects: &["b-only", "shared"],
                ..Rec::default()
            },
        ];
        let mut state = state(&recs, |c| {
            if c == "a" {
                Written::Revisions
            } else {
                Written::Records
            }
        });
        for o in &mut state.objects {
            let name = o["metadata"]["name"].as_str().unwrap_or_default();
            if name != "b-only" {
                applied_by(o, "kix/a");
            }
        }
        state.objects.push(object_of("a-dropped", &[]));
        state.objects.push(object_of("b-dropped", &[]));
        let api = FakeApi::new(state.all());
        api.patch_object("ConfigMap", "a-dropped", |o| applied_by(o, "kix/a"));
        api
    }

    use crate::cluster::tenancy_fixture::object_of;

    /// `a`, migrated, prunes beside `b`, not migrated. It keeps what `b`'s
    /// stamp names, deletes what only the legacy entry and its own entry
    /// mark, and keeps an object `b` stamps between its read and its delete.
    #[tokio::test]
    async fn a_migrated_cluster_keeps_what_an_unmigrated_one_deploys() {
        let api = mixed();
        let cm = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
        api.after_get("b-dropped", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("bcur");
        });
        let (g, d) = guard(&api, "a").await;
        for name in ["shared", "b-dropped"] {
            assert_eq!(
                delete(&g, &d, &cm(name)).await,
                Pruned::Kept(SharedOrphan {
                    rid: cm(name),
                    clusters: vec!["b".into()],
                }),
                "{name}"
            );
        }
        for name in ["a-only", "a-dropped"] {
            assert!(
                matches!(delete(&g, &d, &cm(name)).await, Pruned::Deleted { .. }),
                "{name}"
            );
        }
    }

    /// `b`, not migrated, prunes beside `a`, migrated. It keeps what `a`'s
    /// revisions name, what carries `a`'s entry though no revision of `a`
    /// names it, and an object `a` first applies between its read and its
    /// delete. It deletes what only the legacy entry marks.
    #[tokio::test]
    async fn an_unmigrated_cluster_keeps_what_a_migrated_one_deploys() {
        let api = mixed();
        let cm = |name: &str| ResourceId::new("", "ConfigMap", "d", name);
        api.patch_object("ConfigMap", "b-only", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("bcur");
        });
        api.after_get("b-only", |o| applied_by(o, "kix/a"));
        let (g, d) = guard(&api, "b").await;
        for name in ["shared", "a-dropped", "b-only"] {
            assert_eq!(
                delete(&g, &d, &cm(name)).await,
                Pruned::Kept(SharedOrphan {
                    rid: cm(name),
                    clusters: vec!["a".into()],
                }),
                "{name}"
            );
        }
        assert!(matches!(
            delete(&g, &d, &cm("b-dropped")).await,
            Pruned::Deleted { .. }
        ));
    }

    /// A namespaced object whose manifest names no namespace is read and
    /// deleted in `default`, where it was applied.
    #[tokio::test]
    async fn a_namespaced_object_without_a_namespace_is_read_in_default() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            record("b", "b1", lifecycle::PHASE_ACTIVE),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "cm",
                    "namespace": "default",
                    "annotations": { (keys::ACTIVATIONS): "a1,b1" },
                },
            }),
        ]);
        let (g, d) = guard(&api, "a").await;
        let cm = ResourceId::new("", "ConfigMap", CLUSTER_SCOPED, "cm");
        assert!(matches!(delete(&g, &d, &cm).await, Pruned::Kept(_)));
        assert_eq!(api.names("ConfigMap"), vec!["cm"]);
    }

    /// `delete_in_order` keeps the given order, sends nothing for a protected
    /// kind, counts an object of a kind the cluster does not serve as gone
    /// so it holds nothing back, and deletes through
    /// the API of the object's own group, though `/apis` lists another group
    /// that serves a `Job` kind first.
    #[tokio::test]
    async fn delete_in_order_reports_each_object() {
        use crate::cluster::fake_api::OTHER_JOB_GROUP;
        let other_version = format!("{OTHER_JOB_GROUP}/v1alpha1");
        let job = |api_version: &str| {
            json!({
                "apiVersion": api_version,
                "kind": "Job",
                "metadata": {
                    "name": "x",
                    "namespace": "app",
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            })
        };
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            job("batch/v1"),
            job(&other_version),
        ]);
        let resources = [
            ResourceId::from_value(&job("batch/v1")),
            ResourceId::new("", "Namespace", CLUSTER_SCOPED, "app"),
            ResourceId::new("example.com", "Widget", "app", "w"),
            ResourceId::new("", "ConfigMap", "app", "gone"),
        ];
        let removals = delete_all(&api, &resources).await;
        let ids: Vec<_> = removals.iter().map(|(rid, _)| rid.clone()).collect();
        assert_eq!(ids, resources);
        assert!(matches!(
            removals[0].1,
            Removal::Pruned(Pruned::Deleted { .. })
        ));
        assert!(matches!(removals[1].1, Removal::NeverPruned));
        assert!(matches!(removals[2].1, Removal::Pruned(Pruned::NotServed)));
        assert!(!removals[2].1.still_live());
        assert!(matches!(removals[3].1, Removal::Pruned(Pruned::Gone)));
        assert!(api.names_of("batch/v1", "Job").is_empty());
        assert_eq!(api.names_of(&other_version, "Job"), vec!["x"]);
    }

    /// When every object is protected, `delete_in_order` sends no request.
    #[tokio::test]
    async fn delete_in_order_reads_nothing_when_all_are_protected() {
        let api = FakeApi::new(Vec::<Value>::new());
        let resources = [ResourceId::new("", "Namespace", CLUSTER_SCOPED, "app")];
        let removals = delete_all(&api, &resources).await;
        assert!(matches!(removals[0].1, Removal::NeverPruned));
        assert!(api.requests().is_empty(), "{:?}", api.requests());
    }

    /// An object that already has a deletion timestamp gets no second
    /// delete request.
    #[tokio::test]
    async fn an_object_already_being_deleted_is_not_deleted_again() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "cm",
                    "namespace": "app",
                    "deletionTimestamp": "2026-11-24T15:54:00Z",
                    "finalizers": ["example.com/hold"],
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            }),
        ]);
        let (g, d) = guard(&api, "a").await;
        let cm = ResourceId::new("", "ConfigMap", "app", "cm");
        assert_eq!(
            delete(&g, &d, &cm).await,
            Pruned::AlreadyDeleting {
                uid: api.object("ConfigMap", "cm").unwrap()["metadata"]["uid"]
                    .as_str()
                    .map(str::to_string),
                finalizers: vec!["example.com/hold".to_string()],
                since: Some("2026-11-24T15:54:00Z".to_string()),
            }
        );
        assert!(
            !api.requests().iter().any(|r| r.starts_with("DELETE")),
            "{:?}",
            api.requests()
        );
    }

    /// A delete returns the finalizers the object held when it was read,
    /// which the delete waits for. An object without any returns none.
    #[tokio::test]
    async fn a_delete_says_which_finalizers_it_waits_for() {
        let cm = |name: &str, finalizers: &[&str]| {
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "finalizers": finalizers,
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            })
        };
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            cm("held", &["example.com/hold"]),
            cm("free", &[]),
        ]);
        let (g, d) = guard(&api, "a").await;
        let finalizers = |pruned: Pruned| match pruned {
            Pruned::Deleted { finalizers, .. } => finalizers,
            other => panic!("{other:?}"),
        };
        let held = ResourceId::new("", "ConfigMap", "app", "held");
        assert_eq!(
            finalizers(delete(&g, &d, &held).await),
            vec!["example.com/hold".to_string()]
        );
        let free = ResourceId::new("", "ConfigMap", "app", "free");
        assert!(finalizers(delete(&g, &d, &free).await).is_empty());
    }

    /// `delete_in_order` waits for each deleted object. One that keeps its
    /// finalizer past the budget is stuck, and what it depends on is held
    /// back and stays on the cluster. An object that does not depend on it is
    /// still deleted.
    #[tokio::test(start_paused = true)]
    async fn a_stuck_delete_holds_back_what_it_needs() {
        let object = |kind: &str, name: &str, hash: &str, deps: &str, finalizers: &[&str]| {
            json!({
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "finalizers": finalizers,
                    "annotations": {
                        (keys::ACTIVATIONS): "a1",
                        (keys::IDENTITY_HASH): hash,
                        (keys::DEPENDS_ON): deps,
                    },
                },
            })
        };
        let cm = object(
            "ConfigMap",
            "cm",
            "hash_cm",
            "hash_secret",
            &["example.com/hold"],
        );
        let secret = object("Secret", "needed", "hash_secret", "", &[]);
        let other = object("Secret", "other", "hash_other", "", &[]);
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            cm.clone(),
            secret.clone(),
            other.clone(),
        ]);
        let mut steps = Vec::new();
        let removals = delete_in_order(
            &api.client(),
            "a",
            DeleteOrder::of_manifests(&[cm, secret, other]),
            Duration::from_secs(10),
            &CancelToken::new(),
            &mut |rid: &ResourceId, step: Step<'_>| {
                steps.push(match step {
                    Step::Waiting(s) => format!("{} waiting: {s}", rid.name),
                    Step::Done(r) => format!("{} done: {}", rid.name, r.unfinished()),
                })
            },
        )
        .await
        .unwrap();
        let by_name = |name: &str| &removals.iter().find(|(r, _)| r.name == name).unwrap().1;
        let Removal::Stuck(stuck) = by_name("cm") else {
            panic!("{removals:?}");
        };
        assert_eq!(stuck.finalizers, vec!["example.com/hold".to_string()]);
        assert!(
            matches!(by_name("needed"), Removal::HeldBack { by, shared: false } if by.name == "cm")
        );
        assert!(matches!(
            by_name("other"),
            Removal::Pruned(Pruned::Deleted { .. })
        ));
        assert_eq!(api.names("ConfigMap"), vec!["cm"]);
        assert_eq!(api.names("Secret"), vec!["needed"]);
        assert!(
            steps.contains(&"cm waiting: being deleted, waiting for example.com/hold".to_string()),
            "{steps:?}"
        );
        // Two deletes went out: `cm` and `other`. `needed` got none.
        let deletes: Vec<_> = api
            .requests()
            .into_iter()
            .filter(|r| r.starts_with("DELETE"))
            .collect();
        assert_eq!(deletes.len(), 2, "{deletes:?}");
    }

    /// A ConfigMap `cm` held by a finalizer that depends on the Deployment
    /// `operator` through the `relation` entry of its depends-on, both named
    /// by cluster `a`'s record. `operator` is on the cluster with
    /// `ready_replicas` of 1 replica when it is `Some`.
    fn custom_resource_and_operator(
        relation: &str,
        ready_replicas: Option<u32>,
    ) -> (FakeApi, DeleteOrder) {
        let annotations = |hash: &str, deps: &str| {
            json!({
                (keys::ACTIVATIONS): "a1",
                (keys::IDENTITY_HASH): hash,
                (keys::DEPENDS_ON): deps,
            })
        };
        let cm = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "cm",
                "namespace": "app",
                "finalizers": ["example.com/hold"],
                "annotations": annotations("hash_cm", &format!("{relation}hash_op")),
            },
        });
        let operator = json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "operator",
                "namespace": "app",
                "generation": 1,
                "annotations": annotations("hash_op", ""),
            },
            "spec": { "replicas": 1 },
            "status": {
                "observedGeneration": 1,
                "replicas": 1,
                "updatedReplicas": ready_replicas,
                "readyReplicas": ready_replicas,
                "availableReplicas": ready_replicas,
            },
        });
        let order = DeleteOrder::of_manifests(&[cm.clone(), operator.clone()]);
        let mut objects = vec![record("a", "a1", lifecycle::PHASE_ACTIVE), cm];
        if ready_replicas.is_some() {
            objects.push(operator);
        }
        (FakeApi::new(objects), order)
    }

    /// Return the message for the stuck `cm` after deleting the objects of
    /// `custom_resource_and_operator`.
    async fn stuck_cm_message(relation: &str, ready_replicas: Option<u32>) -> String {
        let (api, order) = custom_resource_and_operator(relation, ready_replicas);
        let removals = walk(&api, order, &CancelToken::new()).await;
        let Removal::Stuck(stuck) = removal(&removals, "cm") else {
            panic!("{removals:?}");
        };
        if ready_replicas.is_some() {
            assert!(
                matches!(removal(&removals, "operator"), Removal::HeldBack { by, .. } if by.name == "cm"),
                "{removals:?}"
            );
        }
        let cm = ResourceId::new("", "ConfigMap", "app", "cm");
        readiness::stuck_message(&cm, stuck)
    }

    /// A stuck object whose kind names a controller says whether the
    /// controller runs: not ready, ready, or not on the cluster.
    #[tokio::test(start_paused = true)]
    async fn a_stuck_delete_names_the_controller_and_its_state() {
        let not_ready = stuck_cm_message("controller:", Some(0)).await;
        assert!(
            not_ready.contains("ConfigMap controller Deployment.apps/operator@app is not ready ("),
            "{not_ready}"
        );
        let ready = stuck_cm_message("controller:", Some(1)).await;
        assert!(
            ready.contains("ConfigMap controller Deployment.apps/operator@app has ready pods but"),
            "{ready}"
        );
        let missing = stuck_cm_message("controller:", None).await;
        assert!(
            missing.contains(
                "ConfigMap controller Deployment.apps/operator@app is not on the cluster"
            ),
            "{missing}"
        );
    }

    /// The same dependency without the `controller:` relation still holds
    /// the operator back, and the message names no controller.
    #[tokio::test(start_paused = true)]
    async fn a_stuck_delete_without_a_controller_names_none() {
        for relation in ["requires:", ""] {
            let message = stuck_cm_message(relation, Some(0)).await;
            assert!(
                message.contains("waiting for example.com/hold."),
                "{message}"
            );
            assert!(!message.contains("ConfigMap controller"), "{message}");
        }
    }

    /// A ConfigMap `cm` that depends on Secret `needed`, both named by
    /// cluster `a`'s record, plus the record.
    fn pair(cm_finalizers: &[&str]) -> (FakeApi, DeleteOrder) {
        let object = |kind: &str, name: &str, hash: &str, deps: &str, finalizers: &[&str]| {
            json!({
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "finalizers": finalizers,
                    "annotations": {
                        (keys::ACTIVATIONS): "a1",
                        (keys::IDENTITY_HASH): hash,
                        (keys::DEPENDS_ON): deps,
                    },
                },
            })
        };
        let cm = object("ConfigMap", "cm", "hash_cm", "hash_s", cm_finalizers);
        let secret = object("Secret", "needed", "hash_s", "", &[]);
        let order = DeleteOrder::of_manifests(&[cm.clone(), secret.clone()]);
        let api = FakeApi::new([record("a", "a1", lifecycle::PHASE_ACTIVE), cm, secret]);
        (api, order)
    }

    async fn walk(
        api: &FakeApi,
        order: DeleteOrder,
        cancel: &CancelToken,
    ) -> Vec<(ResourceId, Removal)> {
        delete_in_order(
            &api.client(),
            "a",
            order,
            Duration::from_secs(10),
            cancel,
            &mut |_, _| {},
        )
        .await
        .unwrap()
    }

    fn removal<'a>(removals: &'a [(ResourceId, Removal)], name: &str) -> &'a Removal {
        &removals.iter().find(|(r, _)| r.name == name).unwrap().1
    }

    /// Return the objects of a custom resource `cr` whose kind names the
    /// controller `operator`, and that owns `child`, an object the controller
    /// made for it that carries the controller's finalizer. `relation`
    /// prefixes the custom resource's dependency on the controller.
    fn custom_resource_with_a_child(relation: &str, blocks: bool) -> (FakeApi, DeleteOrder) {
        let annotations = |hash: &str, deps: &str| {
            json!({
                (keys::ACTIVATIONS): "a1",
                (keys::IDENTITY_HASH): hash,
                (keys::DEPENDS_ON): deps,
            })
        };
        let cr = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "cr",
                "namespace": "app",
                "uid": "uid-cr",
                "annotations": annotations("hash_cr", &format!("{relation}hash_op")),
            },
        });
        let operator = json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "name": "operator",
                "namespace": "app",
                "generation": 1,
                "annotations": annotations("hash_op", ""),
            },
            "spec": { "replicas": 1 },
            "status": { "observedGeneration": 1, "replicas": 1, "readyReplicas": 1 },
        });
        let child = json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "child",
                "namespace": "app",
                "finalizers": ["example.com/cleanup"],
                "ownerReferences": [{
                    "apiVersion": "v1",
                    "kind": "ConfigMap",
                    "name": "cr",
                    "uid": "uid-cr",
                    "controller": true,
                    "blockOwnerDeletion": blocks,
                }],
            },
        });
        let order = DeleteOrder::of_manifests(&[cr.clone(), operator.clone()]);
        let objects = [
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            cr,
            operator,
            child,
        ];
        (FakeApi::new(objects), order)
    }

    /// A custom resource whose kind names a controller is deleted in the
    /// foreground. It stays until the object its controller made for it is
    /// gone, so the controller stays to remove that object's finalizer.
    #[tokio::test(start_paused = true)]
    async fn a_controllers_object_waits_for_what_the_controller_made_for_it() {
        let (api, order) = custom_resource_with_a_child("controller:", true);
        let removals = walk(&api, order, &CancelToken::new()).await;
        let Removal::Stuck(stuck) = removal(&removals, "cr") else {
            panic!("{removals:?}");
        };
        assert_eq!(stuck.finalizers, vec!["foregroundDeletion"]);
        assert!(
            matches!(removal(&removals, "operator"), Removal::HeldBack { by, .. } if by.name == "cr"),
            "{removals:?}"
        );
        assert_eq!(api.names("Deployment"), vec!["operator"]);

        // Once the controller has cleaned up, the custom resource goes and the
        // next walk deletes the controller.
        api.remove_finalizers("Secret", "child");
        assert!(api.names("ConfigMap").is_empty());
        assert!(api.names("Secret").is_empty());
    }

    /// An object the controller made with `blockOwnerDeletion: false` does
    /// not hold its owner, as in Kubernetes, so the custom resource goes at
    /// once and the controller is deleted while that object still waits.
    #[tokio::test(start_paused = true)]
    async fn a_child_that_does_not_block_its_owner_is_not_waited_for() {
        let (api, order) = custom_resource_with_a_child("controller:", false);
        let removals = walk(&api, order, &CancelToken::new()).await;
        assert!(
            matches!(removal(&removals, "cr"), Removal::Pruned(_)),
            "{removals:?}"
        );
        assert!(api.names("Deployment").is_empty());
        assert_eq!(api.names("Secret"), vec!["child"]);
    }

    /// An object whose kind names no controller is deleted in the background
    /// and does not wait for what it owns, so the operator it only requires
    /// is deleted while the owned object still waits for its finalizer.
    #[tokio::test(start_paused = true)]
    async fn an_object_without_a_controller_does_not_wait_for_what_it_owns() {
        let (api, order) = custom_resource_with_a_child("requires:", true);
        let removals = walk(&api, order, &CancelToken::new()).await;
        assert!(
            matches!(removal(&removals, "cr"), Removal::Pruned(_)),
            "{removals:?}"
        );
        assert!(api.names("Deployment").is_empty());
        assert_eq!(api.names("Secret"), vec!["child"]);
    }

    /// A dependent whose delete request fails holds back what it depends on.
    #[tokio::test(start_paused = true)]
    async fn a_failed_delete_holds_back_what_it_needs() {
        let (api, order) = pair(&[]);
        api.fail_next("/api/v1/namespaces/app/configmaps/cm", 1, 500);
        let removals = walk(&api, order, &CancelToken::new()).await;
        assert!(
            matches!(removal(&removals, "cm"), Removal::Failed(_)),
            "{removals:?}"
        );
        assert!(matches!(
            removal(&removals, "needed"),
            Removal::HeldBack { shared: false, .. }
        ));
        assert_eq!(api.names("Secret"), vec!["needed"]);
    }

    /// A dependent written between every read and delete is still on the
    /// cluster: it holds back what it depends on, and the teardown is not
    /// done.
    #[tokio::test(start_paused = true)]
    async fn a_changed_dependent_holds_back_what_it_needs() {
        let (api, order) = pair(&[]);
        for n in 0..DELETE_ATTEMPTS {
            api.after_get("cm", move |o| {
                o["data"] = json!({ "touched": n.to_string() });
            });
        }
        let removals = walk(&api, order, &CancelToken::new()).await;
        let cm = removal(&removals, "cm");
        assert!(
            matches!(cm, Removal::Pruned(Pruned::Changed(_))),
            "{removals:?}"
        );
        assert!(cm.unfinished());
        assert!(removal(&removals, "needed").unfinished());
        assert_eq!(api.names("Secret"), vec!["needed"]);
    }

    /// A dependent another Kix cluster still deploys holds back what it
    /// depends on, and neither blocks the teardown.
    #[tokio::test(start_paused = true)]
    async fn a_shared_dependent_holds_back_without_blocking() {
        let (api, order) = pair(&[]);
        api.insert(record("b", "b1", lifecycle::PHASE_ACTIVE));
        api.patch_object("ConfigMap", "cm", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("a1,b1");
        });
        let removals = walk(&api, order, &CancelToken::new()).await;
        let cm = removal(&removals, "cm");
        assert!(
            matches!(cm, Removal::Pruned(Pruned::Kept(_))),
            "{removals:?}"
        );
        assert!(!cm.unfinished());
        let needed = removal(&removals, "needed");
        assert!(
            matches!(needed, Removal::HeldBack { shared: true, .. }),
            "{removals:?}"
        );
        assert!(!needed.unfinished());
    }

    /// A cancel while a delete waits stops the walk: the object waited for
    /// and the one behind it are reported cancelled, and both stay.
    #[tokio::test(start_paused = true)]
    async fn a_cancel_mid_walk_stops_it() {
        let (api, order) = pair(&["example.com/hold"]);
        let cancel = CancelToken::new();
        let stopper = {
            let cancel = cancel.clone();
            async move {
                tokio::time::sleep(Duration::from_secs(2)).await;
                cancel.cancel();
            }
        };
        let (removals, ()) = tokio::join!(walk(&api, order, &cancel), stopper);
        assert!(
            matches!(removal(&removals, "cm"), Removal::Cancelled),
            "{removals:?}"
        );
        assert!(
            matches!(removal(&removals, "needed"), Removal::Cancelled),
            "{removals:?}"
        );
        assert_eq!(api.names("Secret"), vec!["needed"]);
    }

    /// More deletes than run at once still all happen, and stuck ones wait
    /// side by side: 70 objects that keep their finalizer for the whole
    /// budget take two budgets, not seventy.
    #[tokio::test(start_paused = true)]
    async fn more_deletes_than_the_limit_all_run() {
        let mut objects = vec![record("a", "a1", lifecycle::PHASE_ACTIVE)];
        let mut ids = Vec::new();
        for i in 0..70 {
            let name = format!("cm{i}");
            objects.push(json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "finalizers": ["example.com/hold"],
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            }));
            ids.push(ResourceId::new("", "ConfigMap", "app", &name));
        }
        let api = FakeApi::new(objects);
        let start = tokio::time::Instant::now();
        let removals = walk(&api, DeleteOrder::unordered(ids), &CancelToken::new()).await;
        assert_eq!(removals.len(), 70);
        assert!(removals.iter().all(|(_, r)| matches!(r, Removal::Stuck(_))));
        let waited = start.elapsed();
        assert!(waited < Duration::from_secs(30), "waited {waited:?}");
    }
}
