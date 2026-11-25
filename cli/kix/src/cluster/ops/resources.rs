//! [`ResourceIo`] against a real cluster.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};

use async_trait::async_trait;
use kube::{
    api::{Api, DeleteParams, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use tokio::sync::RwLock;

use crate::legacy_domain::LegacyDomainError;
use crate::manifest::kinds::{self, GroupKind};
use crate::manifest::types::ResourceId;

use super::super::activation::{OpenedRecords, Records};
use super::super::apply::{self, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::discovery;
use super::super::errors::FetchError;
use super::super::prune_guard::{PruneGuard, Pruned};
use super::super::readiness::{self, Deletion, ImportTarget, ReadinessError, ReadinessResult};
use super::{DeleteError, NotDiscovered, OnStatus, ReadError, RecreateError, ResourceIo};

/// Shared discovery cache of every kind the cluster serves, refreshed after
/// CRDs land. Refreshes merge into the existing cache (see
/// `discovery::merge_discovery`). Because the aggregated discovery document
/// churns after CRD writes and can transiently omit unrelated groups, a refresh
/// never forgets a kind already seen or replaces a cached kind when a group
/// version fails to respond.
type DiscoveryCache = Arc<RwLock<Vec<(ApiResource, Scope)>>>;

/// How long apply waits for an object a manifest expects something else to
/// have created (`kix.run/expects`). The creator is ready by the time this
/// runs, so the wait covers work done after becoming ready (such as a Job's
/// last step or an operator's first reconcile). Matches the default per-node
/// readiness timeout.
const EXPECTS_TIMEOUT: Duration = Duration::from_secs(180);

/// Return the kind-aware propagation policy for in-place recreate. Jobs use
/// `Foreground` so old pods are gone before re-applying, StatefulSets use
/// `Orphan` so PVCs are retained, and all other kinds use `Background`.
fn delete_propagation_for(kind: GroupKind<'_>) -> kube::api::PropagationPolicy {
    match kind {
        kinds::JOB => kube::api::PropagationPolicy::Foreground,
        kinds::STATEFUL_SET => kube::api::PropagationPolicy::Orphan,
        _ => kube::api::PropagationPolicy::Background,
    }
}

/// How a [`KubeResources`] sends its writes. Fixed when it is made.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Writes {
    Persist,
    /// Send every SSA and DELETE with `dryRun=All`. Only [`super::DryRun`]
    /// constructs this mode, so dry-run writes never persist.
    DryRun,
}

/// Live cluster resource I/O for a single deploy run. Constructed with
/// [`KubeResources::new`] for persistent writes, or [`KubeResources::dry_run`]
/// inside [`super::DryRun`].
pub(crate) struct KubeResources {
    client: Client,
    writes: Writes,
    discovery: DiscoveryCache,
    /// The Kix cluster whose orphans a prune deletes.
    cluster: String,
    /// Identity hash of the run's Activation, stamped into
    /// `kix.run/activations` on every object written.
    identity_hash: Option<String>,
    /// Take ownership of fields another manager owns.
    force_conflicts: bool,
    /// Identity hashes of every Activation CR on the cluster, used to prune
    /// `kix.run/activations`. Set by the record when the run begins, or `None`
    /// to leave the annotation unpruned.
    live_activations: std::sync::RwLock<Option<HashSet<String>>>,
    /// Initialized on the first prune delete, after discovery has settled.
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
        Self::with_writes(
            Writes::Persist,
            client,
            discovery,
            cluster,
            identity_hash,
            force_conflicts,
        )
    }

    /// Create a [`KubeResources`] instance that sends every write with
    /// `dryRun=All`, for [`super::DryRun`].
    pub(super) fn dry_run(
        client: Client,
        discovery: Vec<(ApiResource, Scope)>,
        cluster: String,
        identity_hash: Option<String>,
        force_conflicts: bool,
    ) -> Self {
        Self::with_writes(
            Writes::DryRun,
            client,
            discovery,
            cluster,
            identity_hash,
            force_conflicts,
        )
    }

    fn with_writes(
        writes: Writes,
        client: Client,
        discovery: Vec<(ApiResource, Scope)>,
        cluster: String,
        identity_hash: Option<String>,
        force_conflicts: bool,
    ) -> Self {
        Self {
            client,
            writes,
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

    /// Return whether writes use `dryRun=All`.
    fn dry(&self) -> bool {
        self.writes == Writes::DryRun
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

    /// Open `Activation` records past the domain gate using the current
    /// discovery cache, since the record CRD can arrive mid-run.
    async fn opened(&self) -> Result<OpenedRecords, LegacyDomainError> {
        let d = self.discovery.read().await;
        Records::open(&self.client, &d)
    }

    /// Return the `Records` handle for lifecycle writes, `None` when the record
    /// CRD is not yet served, or an error when the domain gate rejects retired
    /// records.
    pub(super) async fn records(&self) -> Result<Option<Records>, LegacyDomainError> {
        self.opened().await.map(OpenedRecords::into_records)
    }

    /// Look up `rid`'s group and kind in the discovery cache without
    /// refreshing.
    pub(super) async fn cached(&self, rid: &ResourceId) -> Option<(ApiResource, Scope)> {
        let d = self.discovery.read().await;
        discovery::find(&d, &rid.group, &rid.kind).cloned()
    }

    /// Look up `manifest`'s group and kind in discovery, refreshing on a
    /// cache miss.
    ///
    /// Dependents of a CRD do not run until the CRD is Ready and discovery
    /// has been refreshed, so the kind is normally in the cache. HA
    /// apiservers can serve discovery from different replicas with a few
    /// hundred ms of skew, so [`Self::refresh_until_found`] retries before
    /// failing the node.
    async fn resolve_kind(&self, manifest: &Value) -> Result<(ApiResource, Scope), ApplyError> {
        let rid = ResourceId::from_value(manifest);
        self.refresh_until_found(&rid)
            .await
            .ok_or(ApplyError::UnknownKind { kind: rid.kind })
    }

    /// Look up `rid`'s group and kind in the cache, refreshing discovery on a
    /// miss up to `REFRESH_ATTEMPTS` times with backoff (under 4 s of waiting
    /// between requests). Each refresh fetches the group alone, so an
    /// unrelated group version answering 404 does not add
    /// [`discovery::DISCOVERY_SETTLE`] to each attempt. It falls back to a
    /// single-pass full walk ([`discovery::discover_resources_once`]) only
    /// when the group fetch fails. Refreshes merge into the cache.
    async fn refresh_until_found(&self, rid: &ResourceId) -> Option<(ApiResource, Scope)> {
        const REFRESH_ATTEMPTS: u32 = 5;
        const BACKOFF_START: Duration = Duration::from_millis(250);
        const BACKOFF_MAX: Duration = Duration::from_secs(2);
        if let Some(found) = self.cached(rid).await {
            return Some(found);
        }
        let mut delay = BACKOFF_START;
        for attempt in 1..=REFRESH_ATTEMPTS {
            tracing::debug!(
                group = %rid.group,
                kind = %rid.kind,
                attempt,
                "kind missing from discovery cache, refreshing"
            );
            let fresh = match discovery::discover_group(&self.client, &rid.group).await {
                Ok(new) => Some(new),
                Err(_) => discovery::discover_resources_once(&self.client).await.ok(),
            };
            if let Some(new) = fresh {
                let mut d = self.discovery.write().await;
                *d = discovery::merge_discovery(&d, new);
            }
            if let Some(found) = self.cached(rid).await {
                return Some(found);
            }
            if attempt < REFRESH_ATTEMPTS {
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(BACKOFF_MAX);
            }
        }
        None
    }

    pub(super) fn api_for(
        &self,
        ar: &ApiResource,
        scope: &Scope,
        rid: &ResourceId,
    ) -> Api<DynamicObject> {
        discovery::api_for(&self.client, ar, scope, rid)
    }

    /// Server-side apply `manifest` as the kind `ar`, stamped with the run's
    /// Activation.
    pub(super) async fn apply_as(
        &self,
        ar: &ApiResource,
        scope: Scope,
        manifest: &Value,
    ) -> Result<ApplyResult, ApplyError> {
        let live = self.live_activations();
        apply::apply_resource(
            &self.client,
            ar,
            scope,
            manifest,
            self.dry(),
            self.identity_hash.as_deref(),
            live.as_ref(),
            self.force_conflicts,
        )
        .await
    }

    /// Delete the live object as the first step of an in-place recreate.
    /// Returns the resolved kind, the API handle, and, when an object existed
    /// to delete, its uid. A 404 is treated as success because the object is
    /// already absent.
    pub(super) async fn delete_for_recreate(
        &self,
        rid: &ResourceId,
    ) -> Result<
        (
            ApiResource,
            Scope,
            Api<DynamicObject>,
            Option<Option<String>>,
        ),
        RecreateError,
    > {
        let (ar, scope) = self.cached(rid).await.ok_or_else(|| not_discovered(rid))?;
        let api = self.api_for(&ar, &scope, rid);
        let dp = DeleteParams {
            propagation_policy: Some(delete_propagation_for(rid.group_kind())),
            dry_run: self.dry(),
            ..Default::default()
        };
        let deleted = match api.delete(&rid.name, &dp).await {
            // The object while it waits for its finalizers, or the status of a
            // delete already done.
            Ok(answer) => Some(answer.either(
                |obj| obj.metadata.uid,
                |status| status.details.map(|d| d.uid).filter(|uid| !uid.is_empty()),
            )),
            Err(kube::Error::Api(ae)) if ae.code == 404 => None,
            Err(e) => return Err(RecreateError::Delete(e)),
        };
        Ok((ar, scope, api, deleted))
    }
}

#[async_trait]
impl ResourceIo for KubeResources {
    async fn prune(&self, rid: &ResourceId) -> Result<Pruned, DeleteError> {
        let (ar, scope) = self.cached(rid).await.ok_or_else(|| not_discovered(rid))?;
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
            dry_run: self.dry(),
            ..Default::default()
        };
        // An object that is already absent (`Pruned::Gone`) is a successful
        // prune. Baseline closures from failed runs can include resources that
        // were never created or were already removed, so a 404 must not mark
        // the new Activation Degraded.
        guard
            .delete(&ar, &scope, rid, &dp)
            .await
            .map_err(DeleteError::Prune)
    }

    async fn wait_gone(
        &self,
        rid: &ResourceId,
        uid: Option<&str>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<Deletion, ReadError> {
        let (ar, scope) = self.cached(rid).await.ok_or_else(|| not_discovered(rid))?;
        let api = self.api_for(&ar, &scope, rid);
        readiness::wait_gone(&api, &rid.name, uid, timeout, cancel, on_status)
            .await
            .map_err(ReadError::Get)
    }

    async fn apply(
        &self,
        manifest: &Value,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ApplyResult, ApplyError> {
        let (ar, scope) = self.resolve_kind(manifest).await?;
        // Wait for any untracked resources expected by the manifest
        // (`kix.run/expects`, see `core/markers.nix`). The creator dependency
        // is already Ready, and this verifies that the expected object exists.
        if let Err((expected, detail)) =
            readiness::wait_for_expectations(&self.client, manifest, EXPECTS_TIMEOUT, cancel).await
        {
            return Err(ApplyError::ExpectationUnmet {
                resource: ResourceId::from_value(manifest).display_id(),
                expected: expected.display(),
                detail,
            });
        }
        let uid = match self.apply_as(&ar, scope.clone(), manifest).await {
            Err(ApplyError::BeingDeleted { uid, .. }) => uid,
            other => return other,
        };
        let rid = ResourceId::from_value(manifest);
        let api = self.api_for(&ar, &scope, &rid);
        match readiness::wait_gone(&api, &rid.name, uid.as_deref(), timeout, cancel, on_status)
            .await
        {
            Ok(Deletion::Gone) => self.apply_as(&ar, scope, manifest).await,
            Ok(Deletion::Stuck(stuck)) => Err(ApplyError::StillBeingDeleted { rid, stuck }),
            Ok(Deletion::Cancelled) => Err(ApplyError::Interrupted {
                resource: rid.display_id(),
            }),
            Err(source) => Err(ApplyError::PatchFailed {
                resource: rid.display_id(),
                source,
            }),
        }
    }

    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError> {
        // Refresh on a cache miss in case discovery lags behind a CRD apply.
        let (ar, scope) = self
            .refresh_until_found(rid)
            .await
            .ok_or_else(|| not_discovered(rid))?;
        let api = self.api_for(&ar, &scope, rid);
        api.get_opt(&rid.name)
            .await
            .map(|o| o.map(|obj| obj.data))
            .map_err(ReadError::Get)
    }

    async fn recreate_in_place(
        &self,
        manifest: &Value,
        timeout: Duration,
        cancel: &CancelToken,
    ) -> Result<ApplyResult, RecreateError> {
        let rid = ResourceId::from_value(manifest);
        let (ar, scope, api, deleted) = self.delete_for_recreate(&rid).await?;

        // An object still there after the wait is not applied again, because
        // the apply would fail with the same immutable-field error.
        if let Some(uid) = deleted {
            let waited =
                readiness::wait_gone(&api, &rid.name, uid.as_deref(), timeout, cancel, |_| {})
                    .await;
            match waited {
                Ok(Deletion::Gone) => {}
                Ok(Deletion::Stuck(stuck)) => {
                    return Err(RecreateError::StillExists { rid, stuck });
                }
                Ok(Deletion::Cancelled) => return Err(RecreateError::Cancelled(rid)),
                Err(source) => return Err(RecreateError::WaitGone { rid, source }),
            }
        }

        self.apply_as(&ar, scope, manifest)
            .await
            .map_err(RecreateError::Reapply)
    }

    async fn wait_ready(
        &self,
        rid: &ResourceId,
        import_target: Option<&ImportTarget>,
        applied_at: Option<DateTime<Utc>>,
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
        let (ar, scope) = match self.cached(rid).await {
            Some(found) => found,
            // The object was just applied, so its kind should be in the cache.
            // If it is missing, report it as a readiness failure.
            None => {
                return Ok(ReadinessResult::Failed {
                    message: not_discovered(rid).to_string(),
                    output: Vec::new(),
                });
            }
        };
        readiness::wait_for_ready(
            &self.client,
            &ar,
            &scope,
            rid,
            applied_at,
            timeout,
            cancel,
            on_status,
        )
        .await
    }

    async fn rediscover(&self) -> Result<(), FetchError> {
        let new = discovery::DiscoveryPass {
            resources: discovery::discover_resources(&self.client).await?,
            missing: Vec::new(),
        };
        let mut d = self.discovery.write().await;
        *d = discovery::merge_discovery(&d, new);
        Ok(())
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
                "status": { "phase": crate::manifest::lifecycle::PHASE_ACTIVE },
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
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let ops = KubeResources::new(client, discovery, "a".into(), None, false);
        let rid = |name: &str| ResourceId {
            group: "rbac.authorization.k8s.io".into(),
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: name.into(),
        };
        assert!(matches!(
            ops.prune(&rid("mine")).await.unwrap(),
            Pruned::Deleted { .. }
        ));
        assert!(matches!(
            ops.prune(&rid("shared")).await,
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
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let ops = KubeResources::new(client, discovery, "a".into(), None, false);
        let rid = ResourceId {
            group: "rbac.authorization.k8s.io".into(),
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "mine".into(),
        };
        let err = ops.prune(&rid).await.unwrap_err().to_string();
        assert!(err.contains("kix migrate domain"), "{err}");
        assert_eq!(api.names("ClusterRole"), vec!["mine"]);
    }
}

#[cfg(test)]
mod apply_tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use serde_json::json;

    fn held_config_map() -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "cm",
                "namespace": "app",
                "deletionTimestamp": "2026-11-24T15:54:00Z",
                "finalizers": ["example.com/hold"],
            },
            "data": { "old": "yes" },
        })
    }

    fn desired() -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "cm", "namespace": "app" },
            "data": { "new": "yes" },
        })
    }

    async fn ops(api: &FakeApi) -> KubeResources {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        KubeResources::new(client, discovery, "a".into(), None, false)
    }

    /// An apply onto an object being deleted waits for it to be gone, then
    /// creates the new object.
    #[tokio::test(start_paused = true)]
    async fn an_apply_waits_for_the_object_being_deleted_then_creates_it() {
        let api = FakeApi::new([held_config_map()]);
        let ops = ops(&api).await;
        let remover = {
            let api = api.clone();
            async move {
                tokio::time::sleep(Duration::from_secs(5)).await;
                api.remove_finalizers("ConfigMap", "cm");
            }
        };
        let (manifest, cancel) = (desired(), CancelToken::new());
        let applied = ops.apply(&manifest, Duration::from_secs(60), &cancel, &|_| {});
        let (applied, ()) = tokio::join!(applied, remover);
        assert_eq!(applied.unwrap().action, apply::ApplyAction::Created);
        let cm = api.object("ConfigMap", "cm").unwrap();
        assert_eq!(cm["data"], json!({ "new": "yes" }));
        assert!(cm["metadata"]["deletionTimestamp"].is_null());
    }

    /// An object that stays past the wait is not applied, and the error is
    /// the stuck message, naming the finalizer.
    #[tokio::test(start_paused = true)]
    async fn an_apply_onto_an_object_that_stays_reports_it_stuck() {
        let api = FakeApi::new([held_config_map()]);
        let ops = ops(&api).await;
        let err = ops
            .apply(
                &desired(),
                Duration::from_secs(10),
                &CancelToken::new(),
                &|_| {},
            )
            .await
            .unwrap_err()
            .to_string();
        assert!(err.starts_with("[K2794] "), "{err}");
        assert!(err.contains("waiting for example.com/hold"), "{err}");
        assert_eq!(
            api.object("ConfigMap", "cm").unwrap()["data"],
            json!({ "old": "yes" })
        );
    }
}

#[cfg(test)]
mod group_tests {
    use super::*;
    use crate::cluster::fake_api::{FakeApi, OTHER_JOB_GROUP};
    use crate::manifest::keys;
    use serde_json::json;

    fn job(api_version: &str, note: &str) -> Value {
        json!({
            "apiVersion": api_version,
            "kind": "Job",
            "metadata": {
                "name": "x",
                "namespace": "app",
                "annotations": { (keys::ACTIVATIONS): "a1" },
            },
            "spec": { "note": note },
        })
    }

    /// Two kinds named `Job` in two groups are read and pruned through each
    /// one's own API, though `/apis` lists the other group before `batch`.
    #[tokio::test]
    async fn reads_and_prunes_go_through_the_api_of_the_ids_group() {
        let other_version = format!("{OTHER_JOB_GROUP}/v1alpha1");
        let api = FakeApi::new([job("batch/v1", "batch"), job(&other_version, "other")]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let ops = KubeResources::new(client, discovery, "a".into(), None, false);
        let rid = |group: &str| ResourceId::from_value(&job(group, ""));

        let note = |live: Option<Value>| live.unwrap()["spec"]["note"].clone();
        let batch = ops.get_live(&rid("batch/v1")).await.unwrap();
        assert_eq!(note(batch), json!("batch"));
        let other = ops.get_live(&rid(&other_version)).await.unwrap();
        assert_eq!(note(other), json!("other"));

        assert!(matches!(
            ops.prune(&rid("batch/v1")).await.unwrap(),
            Pruned::Deleted { .. }
        ));
        assert!(api.names_of("batch/v1", "Job").is_empty());
        assert_eq!(api.names_of(&other_version, "Job"), vec!["x"]);
    }
}

#[cfg(test)]
mod discovery_tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    const RBAC_V1: &str = "/apis/rbac.authorization.k8s.io/v1";

    /// Create a [`KubeResources`] instance over `api` with an empty discovery
    /// cache, modeling a cache before the group is served.
    fn ops(api: &FakeApi) -> KubeResources {
        KubeResources::new(api.client(), Vec::new(), String::new(), None, false)
    }

    async fn cached(ops: &KubeResources, group: &str, kind: &str) -> bool {
        let rid = ResourceId {
            group: group.into(),
            kind: kind.into(),
            namespace: CLUSTER_SCOPED.into(),
            name: String::new(),
        };
        ops.cached(&rid).await.is_some()
    }

    /// The CRD barrier's refresh succeeds when a listed group version
    /// answers 404 a few times before it is served.
    #[tokio::test(start_paused = true)]
    async fn rediscover_waits_out_a_group_version_that_404s() {
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, 3, 404);
        let ops = ops(&api);
        ops.rediscover().await.unwrap();
        assert!(cached(&ops, "rbac.authorization.k8s.io", "ClusterRole").await);
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
            group: "rbac.authorization.k8s.io".into(),
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
            group: "rbac.authorization.k8s.io".into(),
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "absent".into(),
        };
        let start = tokio::time::Instant::now();
        assert_eq!(ops(&api).get_live(&rid).await.unwrap(), None);
        assert_eq!(start.elapsed(), Duration::ZERO);
    }
}
