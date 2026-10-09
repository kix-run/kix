//! The last check before a prune deletes an object.
//!
//! Two Kix clusters on one Kubernetes cluster can both contain an object,
//! such as an identical ClusterRole. When one drops it from its build, its
//! prune plans the object as an orphan while the other's current build still
//! contains it. Every prune path (deploy and rollback through
//! [`super::ops::KubeOps`], soft and hard gc, the operator's reconcile and
//! finalizer) deletes through [`PruneGuard::delete`], which reads the object,
//! then the Activation records, and deletes only an object no other Kix
//! cluster's current record names. The delete carries the read's uid and
//! resourceVersion as preconditions, so an object that changed after the
//! read (another cluster's deploy stamping it, say) is left in place.

use kube::{
    Client,
    api::{DeleteParams, DynamicObject, Preconditions},
    discovery::{ApiResource, Scope},
};
use thiserror::Error;
use tokio::sync::Mutex;

use super::activation::{self, ActivationError};
use super::fetch::{self, SharedOrphan};
use super::tenancy::{self, Tenancy};
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
    /// The line a command prints for an object the guard left in place.
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
    Records(#[from] ActivationError),
}

/// Deletes orphans of one Kix cluster. See the module docs.
pub struct PruneGuard {
    client: Client,
    /// The Activation kind, if served.
    record_resource: Option<ApiResource>,
    cluster: String,
    /// The last records read. Reread when an object names a hash it lacks,
    /// which is how a record created after the last read shows up.
    tenancy: Mutex<Option<Tenancy>>,
}

impl PruneGuard {
    /// A guard for `cluster`'s prune. `discovery` locates the Activation
    /// kind; without it no other cluster can have records, and the guard
    /// only adds the preconditions.
    pub fn new(client: Client, discovery: &[(ApiResource, Scope)], cluster: &str) -> Self {
        PruneGuard {
            client,
            record_resource: activation::served_resource(discovery).cloned(),
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
        let api = fetch::api_for(&self.client, ar, scope, rid);
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

    /// A tenancy read after `obj` whenever `obj` names a record the cached
    /// one lacks. A record's cluster never changes and a Superseded record
    /// stays Superseded, so a cached tenancy that knows every hash can only
    /// overstate what other clusters still deploy.
    async fn tenancy_naming(&self, obj: &DynamicObject) -> Result<Tenancy, PruneError> {
        let mut slot = self.tenancy.lock().await;
        let fresh = match &*slot {
            Some(t) => tenancy::named_hashes(obj).all(|h| t.knows(h)),
            None => false,
        };
        if !fresh {
            let read =
                tenancy::read_from(&self.client, self.record_resource.as_ref(), &self.cluster)
                    .await?;
            *slot = Some(read);
        }
        Ok(slot.clone().unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::keys;
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

    fn rid(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            namespace: ns.into(),
            name: name.into(),
        }
    }

    async fn guard(api: &FakeApi, cluster: &str) -> (PruneGuard, Vec<(ApiResource, Scope)>) {
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        (PruneGuard::new(client, &discovery, cluster), discovery)
    }

    async fn delete(g: &PruneGuard, d: &[(ApiResource, Scope)], rid: &ResourceId) -> Pruned {
        let (ar, scope) = d.iter().find(|(ar, _)| ar.kind == rid.kind).unwrap();
        g.delete(ar, scope, rid, &DeleteParams::default())
            .await
            .unwrap()
    }

    /// `a` drops a ClusterRole that `b`'s Active record still names: kept.
    /// One only `a` and a Superseded record of `b` name: deleted.
    #[tokio::test]
    async fn an_object_another_cluster_still_deploys_is_kept() {
        let api = FakeApi::new([
            record("a", "a1", activation::PHASE_ACTIVE),
            record("b", "b0", activation::PHASE_SUPERSEDED),
            record("b", "b1", activation::PHASE_ACTIVE),
            role("shared", "a1,b1"),
            role("once-shared", "a1,b0"),
        ]);
        let (g, d) = guard(&api, "a").await;
        let shared = rid("ClusterRole", CLUSTER_SCOPED, "shared");
        assert_eq!(
            delete(&g, &d, &shared).await,
            Pruned::Kept(SharedOrphan {
                rid: shared,
                clusters: vec!["b".into()],
            })
        );
        let once = rid("ClusterRole", CLUSTER_SCOPED, "once-shared");
        assert_eq!(delete(&g, &d, &once).await, Pruned::Deleted);
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
        assert_eq!(delete(&g, &d, &once).await, Pruned::Gone);
    }

    /// Another cluster's deploy stamps the object between the guard's read
    /// and its delete: the precondition refuses the delete.
    #[tokio::test]
    async fn an_object_changed_after_the_read_is_left_in_place() {
        let api = FakeApi::new([
            record("a", "a1", activation::PHASE_ACTIVE),
            role("mine", "a1"),
        ]);
        api.after_get("mine", |o| {
            o["metadata"]["annotations"][keys::ACTIVATIONS] = json!("a1,b1");
        });
        let (g, d) = guard(&api, "a").await;
        let mine = rid("ClusterRole", CLUSTER_SCOPED, "mine");
        assert_eq!(delete(&g, &d, &mine).await, Pruned::Changed(mine.clone()));
        assert_eq!(api.names("ClusterRole"), vec!["mine"]);
    }

    /// A record created after the guard's first read is found: the object
    /// naming it makes the guard read the records again.
    #[tokio::test]
    async fn a_record_created_after_the_first_read_is_seen() {
        let api = FakeApi::new([
            record("a", "a1", activation::PHASE_ACTIVE),
            role("first", "a1"),
        ]);
        let (g, d) = guard(&api, "a").await;
        let first = rid("ClusterRole", CLUSTER_SCOPED, "first");
        assert_eq!(delete(&g, &d, &first).await, Pruned::Deleted);

        // `b`'s first deploy: its record, then an object naming it.
        api.insert(record("b", "b1", activation::PHASE_DEPLOYING));
        api.insert(role("later", "a1,b1"));
        let later = rid("ClusterRole", CLUSTER_SCOPED, "later");
        assert!(matches!(delete(&g, &d, &later).await, Pruned::Kept(_)));
    }

    /// A namespaced object whose manifest names no namespace is read and
    /// deleted in `default`, where it was applied.
    #[tokio::test]
    async fn a_namespaced_object_without_a_namespace_is_read_in_default() {
        let api = FakeApi::new([
            record("a", "a1", activation::PHASE_ACTIVE),
            record("b", "b1", activation::PHASE_ACTIVE),
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
        let cm = rid("ConfigMap", CLUSTER_SCOPED, "cm");
        assert!(matches!(delete(&g, &d, &cm).await, Pruned::Kept(_)));
        assert_eq!(api.names("ConfigMap"), vec!["cm"]);
    }
}
