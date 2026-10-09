//! [`ResourceIo`] against a real cluster.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use kube::{
    api::{Api, DeleteParams, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use tokio::sync::RwLock;

use crate::legacy_domain::LegacyDomainError;
use crate::manifest::types::ResourceId;

use super::super::activation::{OpenedRecords, Records};
use super::super::apply::{self, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::fetch::{self, FetchError};
use super::super::prune_guard::{PruneGuard, Pruned};
use super::super::readiness::{self, ImportTarget, ReadinessError, ReadinessResult};
use super::{DeleteError, NotDiscovered, OnStatus, ReadError, RecreateError, ResourceIo};

/// Shared discovery cache: every kind the cluster serves, refreshed after
/// CRDs land. Refreshes MERGE (see `fetch::merge_discovery`): the aggregated
/// discovery document churns after CRD writes and can transiently omit
/// unrelated groups, so a refresh must never forget a kind already seen, and
/// one that skipped a group version never replaces a cached kind.
type DiscoveryCache = Arc<RwLock<Vec<(ApiResource, Scope)>>>;

/// Wall-clock bound for waiting on the live resource to disappear during an
/// immutable-conflict recreate. Independent of the readiness timeout:
/// deletion should be near-instant; anything longer usually means stuck
/// finalizers, which we surface rather than mask.
const RECREATE_DELETE_TIMEOUT: Duration = Duration::from_secs(30);

/// How long apply waits for an object a manifest expects something else to
/// have created (`kix.run/expects`). The creator is ready by the time this
/// runs, so the wait covers what it does after becoming ready: a Job's
/// last step, an operator's first reconcile. Matches the default per-node
/// readiness timeout.
const EXPECTS_TIMEOUT: Duration = Duration::from_secs(180);

/// Kind-aware propagation policy for in-place recreate. Jobs foreground-delete
/// so the old pods are gone before we re-apply. StatefulSets orphan-delete so
/// PVCs are retained. Everything else uses Background (kubectl default).
fn delete_propagation_for(kind: &str) -> kube::api::PropagationPolicy {
    match kind {
        "Job" => kube::api::PropagationPolicy::Foreground,
        "StatefulSet" => kube::api::PropagationPolicy::Orphan,
        _ => kube::api::PropagationPolicy::Background,
    }
}

/// The objects of one run on a real cluster. Every write persists;
/// [`super::DryRun`] wraps this to send them as dry runs instead.
pub(crate) struct KubeResources {
    client: Client,
    discovery: DiscoveryCache,
    /// The Kix cluster whose orphans a prune deletes.
    cluster: String,
    /// Identity hash of the run's Activation, stamped into
    /// `kix.run/activations` on every object written.
    identity_hash: Option<String>,
    /// Take ownership of fields another manager owns.
    force_conflicts: bool,
    /// Identity hashes of every Activation CR on the cluster, which prune
    /// `kix.run/activations`. Set by the record when the run begins. `None`
    /// = do not prune the annotation.
    live_activations: std::sync::RwLock<Option<HashSet<String>>>,
    /// Made at the first prune delete, when discovery has settled.
    prune_guard: tokio::sync::OnceCell<PruneGuard>,
}

impl KubeResources {
    pub(crate) fn new(
        client: Client,
        discovery: Vec<(ApiResource, Scope)>,
        cluster: String,
        identity_hash: Option<String>,
        force_conflicts: bool,
    ) -> Self {
        Self {
            client,
            discovery: Arc::new(RwLock::new(discovery)),
            cluster,
            identity_hash,
            force_conflicts,
            live_activations: std::sync::RwLock::new(None),
            prune_guard: tokio::sync::OnceCell::new(),
        }
    }

    pub(super) fn client(&self) -> &Client {
        &self.client
    }

    pub(super) fn cluster(&self) -> &str {
        &self.cluster
    }

    pub(super) fn identity_hash(&self) -> Option<&str> {
        self.identity_hash.as_deref()
    }

    pub(super) fn live_activations(&self) -> Option<HashSet<String>> {
        self.live_activations.read().ok().and_then(|g| g.clone())
    }

    pub(super) fn set_live_activations(&self, live: Option<HashSet<String>>) {
        if let Ok(mut slot) = self.live_activations.write() {
            *slot = live;
        }
    }

    /// The Activation records past the domain gate, opened from the
    /// discovery cache each time, since the record CRD can arrive mid-run.
    async fn opened(&self) -> Result<OpenedRecords, LegacyDomainError> {
        let d = self.discovery.read().await;
        Records::open(&self.client, &d)
    }

    /// The records for a lifecycle write, or `None` when there are none to
    /// write to: no record CRD yet, or a cluster whose records sit under a
    /// retired group, which is logged. Skipping a lifecycle write deletes
    /// nothing. A prune does not come through here: it refuses on the
    /// gate's error (see [`KubeResources::prune`]).
    pub(super) async fn records(&self) -> Option<Records> {
        match self.opened().await {
            Ok(opened) => opened.into_records(),
            Err(e) => {
                tracing::error!("{e}");
                None
            }
        }
    }

    /// Kind lookup from the cache, no refresh.
    pub(super) async fn cached_kind(&self, kind: &str) -> Option<(ApiResource, Scope)> {
        let d = self.discovery.read().await;
        d.iter()
            .find(|(ar, _)| ar.kind == kind)
            .map(|(ar, s)| (ar.clone(), s.clone()))
    }

    /// Kind lookup with refresh-on-miss, for applies.
    ///
    /// Dependents of a CRD do not run until the CRD is Ready and discovery
    /// has been refreshed, so the kind is normally in the cache. HA
    /// apiservers can serve discovery from different replicas with a few
    /// hundred ms of skew, so [`Self::refresh_until_found`] asks again
    /// before the node fails.
    async fn resolve_kind(&self, manifest: &Value) -> Result<(ApiResource, Scope), ApplyError> {
        let kind = manifest.get("kind").and_then(Value::as_str).unwrap_or("");
        let group = manifest
            .get("apiVersion")
            .and_then(Value::as_str)
            .map(|av| av.split_once('/').map_or("", |(g, _)| g));
        self.refresh_until_found(kind, group)
            .await
            .ok_or_else(|| ApplyError::UnknownKind {
                kind: kind.to_string(),
            })
    }

    /// The cached entry for `kind`, refreshing discovery on a miss up to
    /// `REFRESH_ATTEMPTS` times with backoff (under 4 s of waiting between
    /// requests). With a `group`, each refresh fetches that group alone and
    /// falls back to a full walk only when the group fetch fails; without
    /// one, each refresh is a full walk. A full walk here is a single pass
    /// ([`fetch::discover_resources_once`]), so an unrelated group version
    /// that answers 404 does not add [`fetch::DISCOVERY_SETTLE`] to each
    /// attempt. Refreshes merge into the cache.
    async fn refresh_until_found(
        &self,
        kind: &str,
        group: Option<&str>,
    ) -> Option<(ApiResource, Scope)> {
        const REFRESH_ATTEMPTS: u32 = 5;
        const BACKOFF_START: Duration = Duration::from_millis(250);
        const BACKOFF_MAX: Duration = Duration::from_secs(2);
        if let Some(found) = self.cached_kind(kind).await {
            return Some(found);
        }
        let mut delay = BACKOFF_START;
        for attempt in 1..=REFRESH_ATTEMPTS {
            tracing::debug!(
                kind,
                attempt,
                "kind missing from discovery cache, refreshing"
            );
            let targeted = match group {
                Some(g) => fetch::discover_group(&self.client, g).await.ok(),
                None => None,
            };
            let fresh = match targeted {
                Some(new) => Some(new),
                None => fetch::discover_resources_once(&self.client).await.ok(),
            };
            if let Some(new) = fresh {
                let mut d = self.discovery.write().await;
                *d = fetch::merge_discovery(&d, new);
            }
            if let Some(found) = self.cached_kind(kind).await {
                return Some(found);
            }
            if attempt < REFRESH_ATTEMPTS {
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(BACKOFF_MAX);
            }
        }
        None
    }

    fn api_for(&self, ar: &ApiResource, scope: &Scope, rid: &ResourceId) -> Api<DynamicObject> {
        fetch::api_for(&self.client, ar, scope, rid)
    }

    /// Server-side apply `manifest` as the kind `ar`, stamped with the run's
    /// Activation, as a dry run when `dry_run`.
    pub(super) async fn apply_as(
        &self,
        ar: &ApiResource,
        scope: Scope,
        manifest: &Value,
        dry_run: bool,
    ) -> Result<ApplyResult, ApplyError> {
        let live = self.live_activations();
        apply::apply_resource(
            &self.client,
            ar,
            scope,
            manifest,
            dry_run,
            self.identity_hash.as_deref(),
            live.as_ref(),
            self.force_conflicts,
        )
        .await
    }

    /// The first step of a recreate: delete the live object, as a dry run
    /// when `dry_run`. Returns the kind, the API, and whether there was an
    /// object to delete. An object that is already gone (TTL-reaped,
    /// deleted externally, or deleted by a concurrent run) is what the
    /// recreate wanted anyway.
    pub(super) async fn delete_for_recreate(
        &self,
        rid: &ResourceId,
        dry_run: bool,
    ) -> Result<(ApiResource, Scope, Api<DynamicObject>, bool), RecreateError> {
        let (ar, scope) = self
            .cached_kind(&rid.kind)
            .await
            .ok_or_else(|| not_discovered(rid))?;
        let api = self.api_for(&ar, &scope, rid);
        let dp = DeleteParams {
            propagation_policy: Some(delete_propagation_for(&rid.kind)),
            dry_run,
            ..Default::default()
        };
        let deleted = match api.delete(&rid.name, &dp).await {
            Ok(_) => true,
            Err(kube::Error::Api(ae)) if ae.code == 404 => false,
            Err(e) => return Err(RecreateError::Delete(e)),
        };
        Ok((ar, scope, api, deleted))
    }

    /// Delete an orphan through the prune guard, as a dry run when
    /// `dry_run`.
    pub(super) async fn prune(
        &self,
        rid: &ResourceId,
        dry_run: bool,
    ) -> Result<Pruned, DeleteError> {
        let (ar, scope) = self
            .cached_kind(&rid.kind)
            .await
            .ok_or_else(|| not_discovered(rid))?;
        // The guard reads the other clusters' records, so a cluster the
        // domain gate refuses has no guard and nothing is deleted.
        let guard = self
            .prune_guard
            .get_or_try_init(|| async {
                let opened = self.opened().await.map_err(DeleteError::Domain)?;
                Ok::<_, DeleteError>(PruneGuard::new(self.client.clone(), opened, &self.cluster))
            })
            .await?;
        let dp = DeleteParams {
            propagation_policy: Some(kube::api::PropagationPolicy::Background),
            dry_run,
            ..Default::default()
        };
        // An object that is already gone (`Pruned::Gone`) is what the prune
        // wanted. This is routine now that a failed run's whole closure is
        // folded into the baseline: much of it was never created, and a
        // later run pruning what an earlier one already removed must not
        // read as a failure, which would land the new record Degraded for no
        // reason.
        guard
            .delete(&ar, &scope, rid, &dp)
            .await
            .map_err(DeleteError::Guard)
    }
}

#[async_trait]
impl ResourceIo for KubeResources {
    async fn apply(&self, manifest: &Value) -> Result<ApplyResult, ApplyError> {
        let (ar, scope) = self.resolve_kind(manifest).await?;
        // What the manifest expects something else to have created
        // (kix.untrackedRef with a kind and a creator). The creator is a
        // dependency, so it is ready by now; what is checked is that it
        // did what the package said it does. Experimental: see
        // core/markers.nix in the lib.
        let cancel = CancelToken::new();
        if let Err((expected, detail)) =
            readiness::wait_for_expectations(&self.client, manifest, EXPECTS_TIMEOUT, &cancel).await
        {
            return Err(ApplyError::ExpectationUnmet {
                resource: ResourceId::from_value(manifest).display_id(),
                expected: expected.display(),
                detail,
            });
        }
        self.apply_as(&ar, scope, manifest, false).await
    }

    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError> {
        // Refresh on a miss, as apply does: discovery can lag a CRD apply.
        // A ResourceId carries no group, so each refresh is a full walk.
        let (ar, scope) = self
            .refresh_until_found(&rid.kind, None)
            .await
            .ok_or_else(|| not_discovered(rid))?;
        let api = self.api_for(&ar, &scope, rid);
        api.get_opt(&rid.name)
            .await
            .map(|o| o.map(|obj| obj.data))
            .map_err(ReadError::Get)
    }

    async fn recreate_in_place(&self, manifest: &Value) -> Result<ApplyResult, RecreateError> {
        let rid = ResourceId::from_value(manifest);
        let (ar, scope, api, deleted) = self.delete_for_recreate(&rid, false).await?;

        // Poll for deletion. Transient API errors are treated as "probably
        // gone" since the delete itself succeeded; any real problem
        // re-surfaces on the re-apply. An object still there at the end of
        // the wait is reported as such rather than re-applied: the apply
        // would fail with the same immutable-field 422 and say nothing about
        // why.
        if deleted {
            let deadline = tokio::time::Instant::now() + RECREATE_DELETE_TIMEOUT;
            let mut gone = false;
            while tokio::time::Instant::now() < deadline {
                match api.get_opt(&rid.name).await {
                    Ok(None) => {
                        gone = true;
                        break;
                    }
                    Ok(Some(_)) => tokio::time::sleep(Duration::from_millis(500)).await,
                    Err(e) => {
                        tracing::debug!(resource = %rid, error = %e, "transient error polling deletion; assuming gone");
                        gone = true;
                        break;
                    }
                }
            }
            if !gone && matches!(api.get_opt(&rid.name).await, Ok(Some(_))) {
                return Err(RecreateError::StillExists {
                    rid,
                    waited: RECREATE_DELETE_TIMEOUT,
                });
            }
        }

        self.apply_as(&ar, scope, manifest, false)
            .await
            .map_err(RecreateError::Reapply)
    }

    async fn wait_ready(
        &self,
        rid: &ResourceId,
        import_target: Option<&ImportTarget>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ReadinessResult, ReadinessError> {
        if let Some(target) = import_target {
            return readiness::wait_for_import_target(
                &self.client,
                target,
                timeout,
                cancel,
                on_status,
            )
            .await;
        }
        let (ar, scope) = match self.cached_kind(&rid.kind).await {
            Some(found) => found,
            // The object was just applied, so its kind is known. If the
            // cache lost it there is nothing to poll; treat as not found.
            None => {
                return Ok(ReadinessResult::Failed {
                    message: not_discovered(rid).to_string(),
                    output: Vec::new(),
                });
            }
        };
        readiness::wait_for_ready(&self.client, &ar, &scope, rid, timeout, cancel, on_status).await
    }

    async fn rediscover(&self) -> Result<(), FetchError> {
        // A settled walk: every listed group version answered.
        let new = fetch::DiscoveryPass {
            resources: fetch::discover_resources(&self.client).await?,
            missing: Vec::new(),
        };
        let mut d = self.discovery.write().await;
        *d = fetch::merge_discovery(&d, new);
        Ok(())
    }

    async fn delete(&self, rid: &ResourceId) -> Result<Pruned, DeleteError> {
        self.prune(rid, false).await
    }
}

pub(super) fn not_discovered(rid: &ResourceId) -> NotDiscovered {
    NotDiscovered {
        kind: rid.kind.clone(),
    }
}

#[cfg(test)]
mod prune_tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::keys;
    use crate::manifest::lifecycle::RECORD_KIND;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    /// Deploy's prune deletes through the prune guard: a ClusterRole another
    /// Kix cluster's Active record names stays, one only this cluster's does
    /// not.
    #[tokio::test]
    async fn a_prune_delete_keeps_what_another_cluster_deploys() {
        let rec = |cluster: &str, hash: &str| {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": RECORD_KIND,
                "metadata": {
                    "name": cluster,
                    "labels": { (keys::CLUSTER_LABEL): cluster },
                    "annotations": { (keys::IDENTITY_HASH): hash },
                },
                "status": { "phase": crate::cluster::activation::PHASE_ACTIVE },
            })
        };
        let role = |name: &str, activations: &str| {
            json!({
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "ClusterRole",
                "metadata": { "name": name, "annotations": { (keys::ACTIVATIONS): activations } },
            })
        };
        let api = FakeApi::new([
            rec("a", "a1"),
            rec("b", "b1"),
            role("mine", "a1"),
            role("shared", "a1,b1"),
        ]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let ops = KubeResources::new(client, discovery, "a".into(), None, false);
        let rid = |name: &str| ResourceId {
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: name.into(),
        };
        assert_eq!(ops.delete(&rid("mine")).await.unwrap(), Pruned::Deleted);
        assert!(matches!(
            ops.delete(&rid("shared")).await,
            Ok(Pruned::Kept(_))
        ));
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }

    /// On a cluster whose records sit under a retired group the guard
    /// cannot tell what other clusters deploy, so the prune refuses rather
    /// than deleting as if there were no records.
    #[tokio::test]
    async fn a_prune_on_an_unmigrated_cluster_deletes_nothing() {
        let api = FakeApi::new([json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": { "name": "mine", "annotations": { (keys::ACTIVATIONS): "a1" } },
        })]);
        api.serve_retired_records();
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let ops = KubeResources::new(client, discovery, "a".into(), None, false);
        let rid = ResourceId {
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "mine".into(),
        };
        let err = ops.delete(&rid).await.unwrap_err().to_string();
        assert!(err.contains("kix migrate domain"), "{err}");
        assert_eq!(api.names("ClusterRole"), vec!["mine"]);
    }
}

#[cfg(test)]
mod discovery_tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    const RBAC_V1: &str = "/apis/rbac.authorization.k8s.io/v1";

    /// `ops` over `api` with an empty discovery cache, the state of a cache
    /// that predates the group being served.
    fn ops(api: &FakeApi) -> KubeResources {
        KubeResources::new(api.client(), Vec::new(), String::new(), None, false)
    }

    async fn cached(ops: &KubeResources, kind: &str) -> bool {
        ops.cached_kind(kind).await.is_some()
    }

    /// The CRD barrier's refresh succeeds when a listed group version
    /// answers 404 a few times before it is served.
    #[tokio::test(start_paused = true)]
    async fn rediscover_waits_out_a_group_version_that_404s() {
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, 3, 404);
        let ops = ops(&api);
        ops.rediscover().await.unwrap();
        assert!(cached(&ops, "ClusterRole").await);
    }

    /// A group version that keeps answering 404 fails the refresh, and the
    /// error names it.
    #[tokio::test(start_paused = true)]
    async fn rediscover_that_never_settles_names_the_group_version() {
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, u32::MAX, 404);
        let err = ops(&api).rediscover().await.unwrap_err();
        assert!(err.to_string().contains(RBAC_V1), "{err}");
    }

    /// Kind resolution for an apply asks again while the kind's group
    /// version answers 404.
    #[tokio::test(start_paused = true)]
    async fn apply_resolution_waits_out_a_group_version_that_404s() {
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, 2, 404);
        let manifest = json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": { "name": "r" },
        });
        let (ar, _) = ops(&api).resolve_kind(&manifest).await.unwrap();
        assert_eq!(ar.kind, "ClusterRole");
    }

    /// `get_live` refreshes on a miss, and the refresh waits out a 404.
    #[tokio::test(start_paused = true)]
    async fn get_live_waits_out_a_group_version_that_404s() {
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, 2, 404);
        let rid = ResourceId {
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "absent".into(),
        };
        assert_eq!(ops(&api).get_live(&rid).await.unwrap(), None);
    }

    /// A miss for a kind whose group answers is resolved at once when an
    /// unrelated listed group version keeps answering 404.
    #[tokio::test(start_paused = true)]
    async fn get_live_does_not_wait_on_an_unrelated_group_version_that_404s() {
        let api = FakeApi::new([]);
        api.fail_next(
            &format!("/apis/{}/v1alpha1", crate::manifest::keys::DOMAIN),
            u32::MAX,
            404,
        );
        let rid = ResourceId {
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "absent".into(),
        };
        let start = tokio::time::Instant::now();
        assert_eq!(ops(&api).get_live(&rid).await.unwrap(), None);
        assert_eq!(start.elapsed(), Duration::ZERO);
    }
}
