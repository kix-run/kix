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
//! go through [`delete_in_order`]. It owns which objects are never deleted and
//! what happens to a kind the cluster does not serve, and returns one
//! [`Removal`] per object for the caller to print or log.

use kube::{
    Client,
    api::{DeleteParams, DynamicObject, Preconditions},
    discovery::{ApiResource, Scope},
};
use thiserror::Error;
use tokio::sync::Mutex;

use super::activation::{OpenedRecords, Records, RecordsError};
use super::discovery;
use super::errors::FetchError;
use super::inventory::SharedOrphan;
use super::tenancy::{self, Tenancy};
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::lifecycle;
use crate::manifest::types::ResourceId;

/// What [`PruneGuard::delete`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pruned {
    Deleted,
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
            Pruned::Deleted | Pruned::Gone => None,
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
    /// object read, unless another Kix cluster's current record names it.
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
        let params = DeleteParams {
            preconditions: Some(Preconditions {
                uid: obj.metadata.uid.clone(),
                resource_version: obj.metadata.resource_version.clone(),
            }),
            ..params.clone()
        };
        match api.delete(&rid.name, &params).await {
            Ok(_) => Ok(Pruned::Deleted),
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
    /// [`PruneGuard::delete`] returned this outcome.
    Pruned(Pruned),
    /// [`PruneGuard::delete`] failed.
    Failed(PruneError),
}

/// Why [`delete_in_order`] deleted nothing.
#[derive(Debug, Error)]
pub enum DeleteInOrderError {
    #[error("{0}")]
    Discovery(#[from] FetchError),
    #[error("{0}")]
    Domain(#[from] LegacyDomainError),
}

/// Delete `resources` of `cluster` one at a time in the order given, through
/// a [`PruneGuard`], and return what happened to each in the same order.
///
/// Kinds `lifecycle::never_pruned` protects are never sent to the API server.
/// When every object is protected, nothing is read from the cluster. An error
/// for one object does not stop the others, so the only errors returned are
/// those that come before the first delete: API discovery, and the retired
/// domain check that opening the records runs.
pub async fn delete_in_order(
    client: &Client,
    cluster: &str,
    resources: &[ResourceId],
) -> Result<Vec<(ResourceId, Removal)>, DeleteInOrderError> {
    let protected = |rid: &ResourceId| lifecycle::never_pruned(rid.group_kind());
    if resources.iter().all(protected) {
        return Ok(resources
            .iter()
            .map(|rid| (rid.clone(), Removal::NeverPruned))
            .collect());
    }
    let discovery = discovery::discover_resources(client).await?;
    let guard = PruneGuard::new(client.clone(), Records::open(client, &discovery)?, cluster);
    let mut removals = Vec::with_capacity(resources.len());
    for rid in resources {
        let removal = if protected(rid) {
            Removal::NeverPruned
        } else if let Some((ar, scope)) = discovery::find(&discovery, &rid.group, &rid.kind) {
            match guard.delete(ar, scope, rid, &DeleteParams::default()).await {
                Ok(pruned) => Removal::Pruned(pruned),
                Err(e) => Removal::Failed(e),
            }
        } else {
            Removal::UnknownKind
        };
        removals.push((rid.clone(), removal));
    }
    Ok(removals)
}

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
        assert_eq!(delete(&g, &d, &once).await, Pruned::Deleted);
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
        assert_eq!(delete(&g, &d, &first).await, Pruned::Deleted);

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
        let removals = delete_in_order(&api.client(), "a", &resources)
            .await
            .unwrap();
        let ids: Vec<_> = removals.iter().map(|(rid, _)| rid.clone()).collect();
        assert_eq!(ids, resources);
        assert!(matches!(removals[0].1, Removal::Pruned(Pruned::Deleted)));
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
        let removals = delete_in_order(&api.client(), "a", &resources)
            .await
            .unwrap();
        assert!(matches!(removals[0].1, Removal::NeverPruned));
        assert!(api.requests().is_empty(), "{:?}", api.requests());
    }
}
