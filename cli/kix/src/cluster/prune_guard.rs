//! The last check before a prune deletes an object.
//!
//! Two Kix clusters on one Kubernetes cluster can both contain an object,
//! such as an identical ClusterRole. When one drops it from its build, its
//! prune plans the object as an orphan while the other's current build still
//! contains it. Every prune path (deploy and rollback through
//! `super::ops::KubeResources`, soft and hard gc, and the operator's reconcile
//! and finalizer) deletes through [`PruneGuard::delete`], which reads the
//! object, then the Activation records, and deletes only an object no other Kix
//! cluster's current record names. The delete carries the read's uid and
//! resourceVersion as preconditions, so an object that changed after the read
//! is left in place.
//!
//! `kix gc` and the operator's finalizer delete a whole ordered list, and both
//! go through [`delete_in_order`]. It owns which objects are never deleted,
//! what happens to a kind the cluster does not serve, and the wait for each
//! deleted object to be gone, and returns one [`Removal`] per object for the
//! caller to print or log.

use std::time::Duration;

use kube::{
    Client,
    api::{DeleteParams, DynamicObject, Preconditions, PropagationPolicy},
    discovery::{ApiResource, Scope},
};
use thiserror::Error;
use tokio::sync::Mutex;

use super::activation::{OpenedRecords, Records, RecordsError};
use super::cancel::CancelToken;
use super::discovery;
use super::errors::FetchError;
use super::graph::{DeleteOrder, Walked};
use super::inventory::SharedOrphan;
use super::readiness::{Deletion, Stuck, wait_gone};
use super::tenancy::{self, Tenancy};
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::lifecycle;
use crate::manifest::types::ResourceId;

/// What [`PruneGuard::delete`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pruned {
    /// The API server accepted the delete. The object stays on the cluster
    /// until its finalizers are removed. `uid` is the uid of the object
    /// deleted, for [`super::readiness::wait_gone`].
    Deleted { uid: Option<String> },
    /// The object was already being deleted, so no request was sent.
    AlreadyDeleting { uid: Option<String> },
    /// Not on the cluster.
    Gone,
    /// Another Kix cluster's current build contains it, so it stays.
    Kept(SharedOrphan),
    /// It changed between the read and the delete, so it stays. The next
    /// prune judges it again.
    Changed(ResourceId),
}

impl Pruned {
    /// Format the line a command prints when the guard leaves an object in place.
    pub fn kept_reason(&self) -> Option<String> {
        match self {
            Pruned::Kept(shared) => Some(shared.describe()),
            Pruned::Changed(rid) => Some(format!(
                "kept {rid}, changed since it was read; the next prune checks it again"
            )),
            Pruned::Deleted { .. } | Pruned::AlreadyDeleting { .. } | Pruned::Gone => None,
        }
    }

    /// Return the uid of the object to wait for when the delete was sent or
    /// was already under way, or `None` when nothing is being deleted.
    pub fn deleting(&self) -> Option<Option<&str>> {
        match self {
            Pruned::Deleted { uid } | Pruned::AlreadyDeleting { uid } => Some(uid.as_deref()),
            Pruned::Gone | Pruned::Kept(_) | Pruned::Changed(_) => None,
        }
    }
}

#[derive(Debug, Error)]
pub enum PruneError {
    #[error("{}", super::errors::describe(.0))]
    Kube(#[from] kube::Error),
    #[error("cannot tell whether another Kix cluster still deploys it: {0}")]
    Records(#[from] RecordsError),
}

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
    tenancy: Mutex<Option<Tenancy>>,
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
    /// it is already being deleted. The caller waits for a deleted object to
    /// be gone.
    pub async fn delete(
        &self,
        ar: &ApiResource,
        scope: &Scope,
        rid: &ResourceId,
        params: &DeleteParams,
    ) -> Result<Pruned, PruneError> {
        let api = discovery::api_for(&self.client, ar, scope, rid);
        let Some(obj) = api.get_opt(&rid.name).await? else {
            return Ok(Pruned::Gone);
        };
        let clusters = self
            .tenancy_naming(&obj)
            .await?
            .still_deployed_by_others(&obj);
        if !clusters.is_empty() {
            return Ok(Pruned::Kept(SharedOrphan {
                rid: rid.clone(),
                clusters,
            }));
        }
        let uid = obj.metadata.uid.clone();
        if obj.metadata.deletion_timestamp.is_some() {
            return Ok(Pruned::AlreadyDeleting { uid });
        }
        let params = DeleteParams {
            preconditions: Some(Preconditions {
                uid: uid.clone(),
                resource_version: obj.metadata.resource_version.clone(),
            }),
            ..params.clone()
        };
        match api.delete(&rid.name, &params).await {
            Ok(_) => Ok(Pruned::Deleted { uid }),
            Err(kube::Error::Api(ae)) if ae.code == 404 => Ok(Pruned::Gone),
            Err(kube::Error::Api(ae)) if ae.code == 409 => Ok(Pruned::Changed(rid.clone())),
            Err(e) => Err(e.into()),
        }
    }

    /// Return a [`Tenancy`] read after `obj` whenever `obj` names a record hash
    /// absent from the cached tenancy. Because a record's cluster never changes
    /// and a `Superseded` record stays `Superseded`, a cached tenancy that
    /// recognizes every hash can only overstate what other clusters still
    /// deploy.
    async fn tenancy_naming(&self, obj: &DynamicObject) -> Result<Tenancy, PruneError> {
        let mut slot = self.tenancy.lock().await;
        if let Some(t) = &*slot
            && tenancy::named_hashes(obj).all(|h| t.knows(h))
        {
            return Ok(t.clone());
        }
        let read = tenancy::read(&self.records, &self.cluster).await?;
        *slot = Some(read.clone());
        Ok(read)
    }
}

/// What [`delete_in_order`] did with one object.
#[derive(Debug)]
pub enum Removal {
    /// `lifecycle::never_pruned` protects its kind, so no request was sent.
    NeverPruned,
    /// The cluster serves no API for its group and kind, so it was not deleted.
    UnknownKind,
    /// [`PruneGuard::delete`] returned this outcome. A `Deleted` or
    /// `AlreadyDeleting` object is gone by the time this is reported.
    Pruned(Pruned),
    /// The object was still being deleted when the wait ended.
    Stuck(Stuck),
    /// Not deleted, because this object's delete did not finish and it
    /// depends on the object ([`DeleteOrder::hold_back`]).
    HeldBack(ResourceId),
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
    /// Return whether the object may still be on the cluster because a
    /// delete failed, did not finish, or was not attempted.
    pub fn unfinished(&self) -> bool {
        matches!(
            self,
            Removal::Stuck(_)
                | Removal::HeldBack(_)
                | Removal::Cycle
                | Removal::Cancelled
                | Removal::Failed(_)
        )
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

/// How many deletes [`delete_in_order`] runs at a time.
const DELETE_CONCURRENCY: usize = 64;

/// Delete the objects of `order` of `cluster` through a [`PruneGuard`] with
/// `Background` propagation, as deploy's prune does, walking the order with
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
    let params = DeleteParams {
        propagation_policy: Some(PropagationPolicy::Background),
        ..DeleteParams::default()
    };
    // Deletes run concurrently and report while they wait, so the reporter
    // is shared behind a lock that no one holds across an await.
    let report = std::sync::Mutex::new(report);
    let say = |rid: &ResourceId, step: Step<'_>| {
        if let Ok(mut report) = report.lock() {
            report(rid, step);
        }
    };
    let start = |rid: &ResourceId| {
        let rid = rid.clone();
        let (guard, params, discovery, say) = (&guard, &params, &discovery, &say);
        async move {
            if protected(&rid) {
                return Removal::NeverPruned;
            }
            let Some((ar, scope)) = discovery::find(discovery, &rid.group, &rid.kind) else {
                return Removal::UnknownKind;
            };
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
                Ok(Deletion::Stuck(stuck)) => Removal::Stuck(stuck),
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
            Removal::unfinished,
            |rid, walked| {
                let removal = match walked {
                    Walked::Done(removal) => removal,
                    Walked::HeldBack(stuck) => Removal::HeldBack(stuck.clone()),
                    Walked::Cycle => Removal::Cycle,
                    Walked::NotStarted => Removal::Cancelled,
                };
                say(rid, Step::Done(&removal));
                removals.push((rid.clone(), removal));
            },
        )
        .await;
    removals.sort_by_key(|(rid, _)| ids.iter().position(|r| r == rid));
    Ok(removals)
}

type Report<'a> = dyn FnMut(&ResourceId, Step<'_>) + Send + 'a;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::keys;
    use crate::manifest::lifecycle;
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
            Pruned::Deleted { uid: Some(_) }
        ));
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
        assert_eq!(delete(&g, &d, &once).await, Pruned::Gone);
    }

    /// Another cluster's deploy stamps the object between the guard's read
    /// and its delete: the precondition refuses the delete.
    #[tokio::test]
    async fn an_object_changed_after_the_read_is_left_in_place() {
        let api = FakeApi::new([
            record("a", "a1", lifecycle::PHASE_ACTIVE),
            role("mine", "a1"),
        ]);
        api.after_get("mine", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("a1,b1");
        });
        let (g, d) = guard(&api, "a").await;
        let mine = ResourceId::new(
            "rbac.authorization.k8s.io",
            "ClusterRole",
            CLUSTER_SCOPED,
            "mine",
        );
        assert_eq!(delete(&g, &d, &mine).await, Pruned::Changed(mine.clone()));
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
    /// kind, reports a kind the cluster does not serve, and deletes through
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
        assert!(matches!(removals[2].1, Removal::UnknownKind));
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
                    "finalizers": ["test.kix.run/hold"],
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            }),
        ]);
        let (g, d) = guard(&api, "a").await;
        let cm = ResourceId::new("", "ConfigMap", "app", "cm");
        assert!(matches!(
            delete(&g, &d, &cm).await,
            Pruned::AlreadyDeleting { uid: Some(_) }
        ));
        assert!(
            !api.requests().iter().any(|r| r.starts_with("DELETE")),
            "{:?}",
            api.requests()
        );
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
            &["test.kix.run/hold"],
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
        assert_eq!(stuck.finalizers, vec!["test.kix.run/hold".to_string()]);
        assert!(matches!(by_name("needed"), Removal::HeldBack(r) if r.name == "cm"));
        assert!(matches!(
            by_name("other"),
            Removal::Pruned(Pruned::Deleted { .. })
        ));
        assert_eq!(api.names("ConfigMap"), vec!["cm"]);
        assert_eq!(api.names("Secret"), vec!["needed"]);
        assert!(
            steps.contains(&"cm waiting: being deleted, waiting for test.kix.run/hold".to_string()),
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
}
