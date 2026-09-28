//! [`ClusterOps`] against a real cluster.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use tokio::sync::RwLock;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

use super::super::activation::{self, WaveRecord, WaveStatus};
use super::super::apply::{self, ApplyAction, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::errors::{FailureClass, classify, describe};
use super::super::fetch::{self, FetchError};
use super::super::prune_guard::{PruneGuard, Pruned};
use super::super::readiness::{self, ImportTarget, ReadinessError, ReadinessResult};
use super::super::secrets::{self, HydrationResult, SecretError};
use super::{ClusterOps, Finalized, OnStatus};

/// Shared discovery cache: every kind the cluster serves, refreshed after
/// CRDs land. Refreshes MERGE (see `fetch::merge_discovery`): the aggregated
/// discovery document churns after CRD writes and can transiently omit
/// unrelated groups, so a refresh must never forget a kind already seen.
pub type DiscoveryCache = Arc<RwLock<Vec<(ApiResource, Scope)>>>;

/// Wall-clock bound for waiting on the live resource to disappear during an
/// immutable-conflict recreate. Independent of the readiness timeout:
/// deletion should be near-instant; anything longer usually means stuck
/// finalizers, which we surface rather than mask.
const RECREATE_DELETE_TIMEOUT: Duration = Duration::from_secs(30);

/// Best-effort writes (checkpoint, finalize) get this long. They run on
/// their own tasks so a slow one parks nothing, but the end of the run
/// awaits the last checkpoint and finalize inline; this keeps that bounded.
const BEST_EFFORT_TIMEOUT: Duration = Duration::from_secs(30);

/// Kind-aware propagation policy for in-place recreate. Jobs foreground-delete
/// so the old pods are gone before we re-apply. StatefulSets orphan-delete so
/// PVCs are retained. Everything else uses Background (kubectl default).
pub fn delete_propagation_for(kind: &str) -> kube::api::PropagationPolicy {
    match kind {
        "Job" => kube::api::PropagationPolicy::Foreground,
        "StatefulSet" => kube::api::PropagationPolicy::Orphan,
        _ => kube::api::PropagationPolicy::Background,
    }
}

/// What a run needs to know about its Activation and its flags.
/// How long apply waits for an object a manifest expects something else to
/// have created (`kix.run/expects`). The creator is ready by the time this
/// runs, so the wait covers what it does after becoming ready: a Job's
/// last step, an operator's first reconcile. Matches the default per-node
/// readiness timeout.
const EXPECTS_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Debug, Clone, Default)]
pub struct KubeOpsConfig {
    pub cluster_name: String,
    /// Name of the Activation CR for this run. `None` for runs that do not
    /// manage the lifecycle (some operator paths).
    pub activation_name: Option<String>,
    /// Identity hash of the Activation, stamped into `kix.run/activations`.
    pub activation_identity_hash: Option<String>,
    /// Take ownership of fields another manager owns.
    /// Provenance to record on the Activation when the deploy finishes. The
    /// CLI computes it; the operator does not, because it never had a source
    /// tree to compute it from.
    pub receipt: Option<serde_json::Value>,
    pub force_conflicts: bool,
    /// Apiserver dry run: SSA and DELETE go with `dryRun=All`; nothing is
    /// written to the Activation.
    pub dry_run: bool,
    /// The Activation record's own stamped manifest, so [`ClusterOps::begin`]
    /// can create it before the first wave instead of waiting for it to come
    /// round as the last node of the plan.
    ///
    /// The same manifest either way, applied by the same field manager with
    /// the same identity hash, so the last-wave apply of it is a no-op that
    /// re-asserts spec once everything it depends on is Ready. `None` leaves
    /// the old behaviour, which is what the operator wants: it created the
    /// record itself and owns `spec.source`.
    pub activation_manifest: Option<serde_json::Value>,
    /// Failed records whose leftovers this run's plan folded in. Superseded
    /// on finalize, because by then they describe nothing outstanding.
    pub consumed_failed: Vec<String>,
    /// What finalize writes to the record's `status.orphansKeptFrom`.
    pub kept_orphans: activation::KeptOrphans,
    /// Whether [`ClusterOps::abort`] should mark the record Failed.
    ///
    /// True for the CLI, which owns the run end to end. False for the
    /// operator, whose model is resume-on-requeue: a reconcile that returns
    /// early will be retried, so failing the record would fight it.
    pub mark_failed_on_abort: bool,
}

pub struct KubeOps {
    client: Client,
    discovery: DiscoveryCache,
    cfg: KubeOpsConfig,
    /// Identity hashes of every Activation CR on the cluster, read once in
    /// [`ClusterOps::begin`]. `None` = do not prune the annotation.
    live_activations: std::sync::RwLock<Option<HashSet<String>>>,
    /// Set when [`ClusterOps::begin`] wanted to create the Activation record
    /// but its CRD was not served yet, which is every cluster's first deploy.
    /// [`ClusterOps::rediscover`] does it at the CRD barrier, the earliest
    /// point at which it can succeed.
    record_pending: std::sync::atomic::AtomicBool,
    /// The `status.orphansKeptFrom` that [`ClusterOps::finalize`] wrote, for
    /// the caller's GC roots. `None` until a finalize succeeds.
    recorded_kept: std::sync::Mutex<Option<Vec<activation::KeptOrphanSource>>>,
    /// Made at the first prune delete, when discovery has settled.
    prune_guard: tokio::sync::OnceCell<PruneGuard>,
}

impl KubeOps {
    pub fn new(client: Client, discovery: DiscoveryCache, cfg: KubeOpsConfig) -> Self {
        Self {
            client,
            discovery,
            cfg,
            live_activations: std::sync::RwLock::new(None),
            record_pending: std::sync::atomic::AtomicBool::new(false),
            recorded_kept: std::sync::Mutex::new(None),
            prune_guard: tokio::sync::OnceCell::new(),
        }
    }

    /// The `status.orphansKeptFrom` the run's finalize wrote, or `None` when
    /// it did not finalize (no-op run, dry run, failure).
    pub fn recorded_orphans_kept_from(&self) -> Option<Vec<activation::KeptOrphanSource>> {
        self.recorded_kept.lock().ok().and_then(|g| g.clone())
    }

    fn live_activations(&self) -> Option<HashSet<String>> {
        self.live_activations.read().ok().and_then(|g| g.clone())
    }

    /// The Activation `ApiResource`, or `None` when there is no record CRD.
    ///
    /// A cluster still on a retired API group returns `None` here and is
    /// reported by the caller that has somewhere to put the message; the
    /// engine treats a missing CRD as "no record to write", which is the
    /// safe direction: the operator reconciles nothing until the migration
    /// has run.
    async fn activation_ar(&self) -> Option<ApiResource> {
        let d = self.discovery.read().await;
        match activation::find_activation_ar(&d) {
            Ok(found) => found.map(|(ar, _)| ar.clone()),
            Err(e) => {
                tracing::error!("{e}");
                None
            }
        }
    }

    /// Create the Activation record and mark it Deploying.
    ///
    /// Returns false when the record CRD is not served yet, which is a
    /// cluster's first deploy: the caller sets `record_pending` and
    /// [`ClusterOps::rediscover`] retries at the CRD barrier.
    ///
    /// The apply goes through the same path the plan's own node will take, so
    /// field manager, identity hash and annotation stamping all match and the
    /// later apply is an unchanged no-op.
    async fn create_record(&self) -> bool {
        let Some(name) = self.cfg.activation_name.as_ref() else {
            return true;
        };
        let Some(ar) = self.activation_ar().await else {
            return false;
        };

        // Only the CLI brings a manifest. The operator's record already
        // exists on the cluster, because the operator is reconciling it, so
        // there is nothing to create and it goes straight to marking the
        // phase, which is what `begin` has always done for it.
        if let Some(manifest) = self.cfg.activation_manifest.as_ref() {
            let rid = ResourceId::from_value(manifest);
            let Some((manifest_ar, scope)) = self.cached_kind(&rid.kind).await else {
                return false;
            };

            let live = self.live_activations();
            if let Err(e) = apply::apply_resource(
                &self.client,
                &manifest_ar,
                scope,
                manifest,
                self.cfg.dry_run,
                self.cfg.activation_identity_hash.as_deref(),
                live.as_ref(),
                self.cfg.force_conflicts,
            )
            .await
            {
                // Not fatal. Without the record the run behaves exactly as it
                // did before this existed, and the deploy itself is what
                // matters. Marking the phase below will 404 and be swallowed.
                tracing::warn!(
                    activation = %name,
                    error = %e,
                    "could not create the Activation record up front; a failure part way \
                     through this run will leave nothing to say what it applied",
                );
            }
        }

        if let Err(e) = activation::begin_deploy(&self.client, &ar, name, 1).await {
            // 404 on a cluster whose record CRD is served but whose record
            // does not exist yet: the create above failed, or this is the
            // operator on a record that has since gone.
            tracing::debug!(activation = %name, error = %e, "could not mark the record Deploying");
        }
        true
    }

    /// Kind lookup from the cache, no refresh.
    async fn cached_kind(&self, kind: &str) -> Option<(ApiResource, Scope)> {
        let d = self.discovery.read().await;
        d.iter()
            .find(|(ar, _)| ar.kind == kind)
            .map(|(ar, s)| (ar.clone(), s.clone()))
    }

    /// Kind lookup with refresh-on-miss.
    ///
    /// Dependents of a CRD do not run until the CRD is Ready and discovery
    /// has been refreshed, so the kind is normally in the cache. HA
    /// apiservers can serve discovery from different replicas with a few
    /// hundred ms of skew, so retry with a targeted group fetch, then a full
    /// one, before failing the node.
    async fn resolve_kind(&self, manifest: &Value) -> Result<(ApiResource, Scope), ApplyError> {
        const RETRIES: u32 = 4;
        const INTERVAL: Duration = Duration::from_millis(500);
        let kind = manifest.get("kind").and_then(Value::as_str).unwrap_or("");
        for attempt in 0..=RETRIES {
            if let Some(found) = self.cached_kind(kind).await {
                return Ok(found);
            }
            if attempt == RETRIES {
                break;
            }
            tracing::debug!(
                kind,
                attempt = attempt + 1,
                "kind missing from discovery cache, refreshing"
            );
            let group = manifest
                .get("apiVersion")
                .and_then(Value::as_str)
                .map(|av| {
                    av.split('/')
                        .next()
                        .filter(|_| av.contains('/'))
                        .unwrap_or("")
                })
                .unwrap_or("");
            // Targeted single-group fetch first: the bulk sweep can drop whole
            // groups under load (see fetch::discover_group).
            if let Ok(new) = fetch::discover_group(&self.client, group).await {
                let mut d = self.discovery.write().await;
                *d = fetch::merge_discovery(&d, new);
                continue;
            }
            if let Ok(new) = fetch::discover_resources(&self.client).await {
                let mut d = self.discovery.write().await;
                *d = fetch::merge_discovery(&d, new);
            }
            tokio::time::sleep(INTERVAL).await;
        }
        Err(ApplyError::UnknownKind {
            kind: kind.to_string(),
        })
    }

    fn api_for(&self, ar: &ApiResource, scope: &Scope, rid: &ResourceId) -> Api<DynamicObject> {
        fetch::api_for(&self.client, ar, scope, rid)
    }
}

#[async_trait]
impl ClusterOps for KubeOps {
    fn dry_run(&self) -> bool {
        self.cfg.dry_run
    }

    async fn begin(&self) -> Result<(), String> {
        if self.cfg.dry_run {
            return Ok(());
        }
        let Some(ar) = self.activation_ar().await else {
            // No record CRD served yet. On a cluster's first deploy the CRD is
            // in this very plan, so the record is created at the CRD barrier
            // instead; see `rediscover`.
            self.record_pending
                .store(true, std::sync::atomic::Ordering::SeqCst);
            return Ok(());
        };

        // Read the live set BEFORE creating the record, so the annotation
        // stamped on the record itself is computed the same way as every
        // other resource's.
        let live = activation::live_activation_hashes(&self.client, &ar).await;
        if let Ok(mut slot) = self.live_activations.write() {
            *slot = live;
        }

        if !self.create_record().await {
            self.record_pending
                .store(true, std::sync::atomic::Ordering::SeqCst);
        }
        Ok(())
    }

    async fn abort(&self, reason: &str) -> Result<(), String> {
        if self.cfg.dry_run || !self.cfg.mark_failed_on_abort {
            return Ok(());
        }
        let (Some(ar), Some(name)) = (self.activation_ar().await, &self.cfg.activation_name) else {
            return Ok(());
        };
        match tokio::time::timeout(
            BEST_EFFORT_TIMEOUT,
            activation::fail_deploy(&self.client, &ar, name, reason),
        )
        .await
        {
            Ok(Ok(())) => Ok(()),
            // Nothing to fail. The record never got created, which is the
            // pre-CRD window on a first deploy.
            Ok(Err(activation::ActivationError::PatchFailed { source, .. }))
                if classify(&source) == FailureClass::NotFound =>
            {
                Ok(())
            }
            Ok(Err(e)) => Err(describe(&e)),
            Err(_) => Err(format!(
                "no answer within {}s",
                BEST_EFFORT_TIMEOUT.as_secs()
            )),
        }
    }

    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError> {
        // `sops` is a synchronous subprocess. On a blocking thread it cannot
        // stall the runtime; the engine's own thread never runs it.
        tokio::task::spawn_blocking(move || {
            let mut single = [manifest];
            let results = secrets::hydrate_secrets(&mut single)?;
            let [manifest] = single;
            Ok((manifest, results))
        })
        .await
        .unwrap_or_else(|join| {
            Err(SecretError::DecryptionFailed {
                path: String::new(),
                message: format!("hydration task failed: {join}"),
            })
        })
    }

    async fn apply(&self, manifest: &Value) -> Result<ApplyResult, ApplyError> {
        let (ar, scope) = self.resolve_kind(manifest).await?;
        // What the manifest expects something else to have created
        // (kix.untrackedRef with a kind and a creator). The creator is a
        // dependency, so it is ready by now; what is checked is that it
        // did what the package said it does. Experimental: see
        // core/markers.nix in the lib.
        if !self.cfg.dry_run {
            let cancel = CancelToken::new();
            if let Err((expected, detail)) =
                readiness::wait_for_expectations(&self.client, manifest, EXPECTS_TIMEOUT, &cancel)
                    .await
            {
                return Err(ApplyError::ExpectationUnmet {
                    resource: ResourceId::from_value(manifest).display_id(),
                    expected: expected.display(),
                    detail,
                });
            }
        }
        let live = self.live_activations();
        apply::apply_resource(
            &self.client,
            &ar,
            scope,
            manifest,
            self.cfg.dry_run,
            self.cfg.activation_identity_hash.as_deref(),
            live.as_ref(),
            self.cfg.force_conflicts,
        )
        .await
    }

    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, String> {
        // Refresh on a miss, as apply does: discovery can lag a CRD apply.
        let found = match self.cached_kind(&rid.kind).await {
            Some(found) => Some(found),
            None => {
                if let Ok(new) = fetch::discover_resources(&self.client).await {
                    let mut d = self.discovery.write().await;
                    *d = fetch::merge_discovery(&d, new);
                }
                self.cached_kind(&rid.kind).await
            }
        };
        let (ar, scope) =
            found.ok_or_else(|| format!("kind {} not in discovery cache", rid.kind))?;
        let api = self.api_for(&ar, &scope, rid);
        api.get_opt(&rid.name)
            .await
            .map(|o| o.map(|obj| obj.data))
            .map_err(|e| format!("get failed: {}", describe(&e)))
    }

    async fn recreate_in_place(&self, manifest: &Value) -> Result<ApplyResult, String> {
        let rid = ResourceId::from_value(manifest);
        let (ar, scope) = self
            .cached_kind(&rid.kind)
            .await
            .ok_or_else(|| format!("kind {} not in discovery cache", rid.kind))?;
        let api = self.api_for(&ar, &scope, &rid);
        let dp = kube::api::DeleteParams {
            propagation_policy: Some(delete_propagation_for(&rid.kind)),
            dry_run: self.cfg.dry_run,
            ..Default::default()
        };
        // An object that is already gone (TTL-reaped, deleted externally,
        // or deleted by a concurrent run) is what we wanted anyway.
        let deleted = match api.delete(&rid.name, &dp).await {
            Ok(_) => true,
            Err(kube::Error::Api(ae)) if ae.code == 404 => false,
            Err(e) => return Err(format!("delete failed: {}", describe(&e))),
        };

        // Under dry run the delete was checked but nothing went away, so
        // the dry-run apply of the changed manifest hits the immutable-field
        // 422 the real path avoids by deleting first. Every other answer
        // (schema, admission, RBAC, field conflicts) is the validation a dry
        // run promises, so the apply still runs; only that one error is the
        // expected "would be created after the delete".
        if self.cfg.dry_run {
            let live = self.live_activations();
            return match apply::apply_resource(
                &self.client,
                &ar,
                scope,
                manifest,
                true,
                self.cfg.activation_identity_hash.as_deref(),
                live.as_ref(),
                self.cfg.force_conflicts,
            )
            .await
            {
                Ok(result) => Ok(result),
                Err(ApplyError::ImmutableConflict { .. }) => Ok(ApplyResult {
                    action: ApplyAction::Created,
                    resource_id: rid,
                }),
                Err(e) => Err(format!("dry-run re-apply failed: {e}")),
            };
        }

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
                return Err(format!(
                    "{rid} still exists {}s after delete (stuck finalizer?); not re-applied",
                    RECREATE_DELETE_TIMEOUT.as_secs()
                ));
            }
        }

        let live = self.live_activations();
        apply::apply_resource(
            &self.client,
            &ar,
            scope,
            manifest,
            self.cfg.dry_run,
            self.cfg.activation_identity_hash.as_deref(),
            live.as_ref(),
            self.cfg.force_conflicts,
        )
        .await
        .map_err(|e| format!("re-apply failed: {e}"))
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
                    message: format!("kind {} not in discovery cache", rid.kind),
                    output: Vec::new(),
                });
            }
        };
        let ns = (rid.namespace != CLUSTER_SCOPED).then_some(rid.namespace.as_str());
        readiness::wait_for_ready(
            &self.client,
            &ar,
            &scope,
            &rid.name,
            ns,
            &rid.kind,
            timeout,
            cancel,
            on_status,
        )
        .await
    }

    async fn rediscover(&self) -> Result<(), FetchError> {
        let new = fetch::discover_resources(&self.client).await?;
        {
            let mut d = self.discovery.write().await;
            *d = fetch::merge_discovery(&d, new);
        }

        // A cluster's first deploy carries the record's own CRD, so `begin`
        // could not create the record. This is the first moment it can: the
        // engine only calls this once a CRD it applied is Established.
        if self
            .record_pending
            .load(std::sync::atomic::Ordering::SeqCst)
            && let Some(ar) = self.activation_ar().await
        {
            let live = activation::live_activation_hashes(&self.client, &ar).await;
            if let Ok(mut slot) = self.live_activations.write() {
                *slot = live;
            }
            if self.create_record().await {
                self.record_pending
                    .store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        Ok(())
    }

    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), String> {
        if self.cfg.dry_run {
            return Ok(());
        }
        let (Some(ar), Some(name)) = (self.activation_ar().await, &self.cfg.activation_name) else {
            return Ok(());
        };
        // One synthetic "wave" until the Activation schema moves to per-node
        // progress; it still gives the operator a liveness pulse.
        let record = WaveRecord {
            wave_index: 0,
            status: if finalizing {
                WaveStatus::Complete
            } else {
                WaveStatus::Pending
            },
            resource_count: applied + failed,
            applied,
            failed,
        };
        match tokio::time::timeout(
            BEST_EFFORT_TIMEOUT,
            activation::record_waves(&self.client, &ar, name, &[record]),
        )
        .await
        {
            Ok(Ok(())) => Ok(()),
            // The Activation CR is itself a node of the plan and lands in the
            // last wave, so on a cluster's first deploy every checkpoint
            // before it is a 404. That is expected, not a failure.
            Ok(Err(activation::ActivationError::PatchFailed { source, .. }))
                if classify(&source) == FailureClass::NotFound =>
            {
                tracing::debug!("activation not yet on cluster; checkpoint skipped");
                Ok(())
            }
            Ok(Err(e)) => Err(describe(&e)),
            Err(_) => Err(format!(
                "no answer within {}s",
                BEST_EFFORT_TIMEOUT.as_secs()
            )),
        }
    }

    async fn record_activation_on_skipped(&self, rid: &ResourceId) -> Result<(), String> {
        let Some(hash) = self.cfg.activation_identity_hash.as_deref() else {
            return Ok(());
        };
        if self.cfg.dry_run {
            return Ok(());
        }
        // A skipped resource is by definition live, so its kind should be in
        // discovery. If it is not, say so rather than dropping it from the
        // count.
        let (ar, scope) = self
            .cached_kind(&rid.kind)
            .await
            .ok_or_else(|| "kind not in discovery cache".to_string())?;
        let live = self.live_activations();
        apply::record_activation_on_skipped(&self.client, &ar, scope, rid, hash, live.as_ref())
            .await
            .map_err(|e| e.to_string())
    }

    async fn delete(&self, rid: &ResourceId) -> Result<Pruned, String> {
        let (ar, scope) = self
            .cached_kind(&rid.kind)
            .await
            .ok_or_else(|| format!("kind {} not in discovery cache", rid.kind))?;
        let guard = self
            .prune_guard
            .get_or_init(|| async {
                let discovery = self.discovery.read().await;
                PruneGuard::new(self.client.clone(), &discovery, &self.cfg.cluster_name)
            })
            .await;
        let dp = kube::api::DeleteParams {
            propagation_policy: Some(kube::api::PropagationPolicy::Background),
            dry_run: self.cfg.dry_run,
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
            .map_err(|e| e.to_string())
    }

    async fn finalize(
        &self,
        had_failures: bool,
        orphans_left: bool,
    ) -> Result<Option<Finalized>, String> {
        if self.cfg.dry_run {
            return Ok(None);
        }
        let (Some(ar), Some(name)) = (self.activation_ar().await, &self.cfg.activation_name) else {
            return Ok(None);
        };
        let work = async {
            let current = activation::find_active(&self.client, &ar, &self.cfg.cluster_name)
                .await
                .ok()
                .flatten();
            let kept = self.cfg.kept_orphans.recorded(
                current.as_ref().map(|c| c.orphans_kept_from.as_slice()),
                orphans_left,
            );
            let old = current.filter(|old| &old.name != name);
            activation::finalize_deploy(
                &self.client,
                &ar,
                &self.cfg.cluster_name,
                name,
                old.as_ref(),
                had_failures,
                self.cfg.receipt.as_ref(),
                &self.cfg.consumed_failed,
                &kept,
            )
            .await?;
            if let Ok(mut recorded) = self.recorded_kept.lock() {
                *recorded = Some(kept);
            }
            Ok::<_, activation::ActivationError>(Finalized {
                activation: name.clone(),
                previous: old.map(|a| a.name),
            })
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, work).await {
            Ok(Ok(f)) => Ok(Some(f)),
            Ok(Err(e)) => Err(describe(&e)),
            Err(_) => Err(format!(
                "no answer within {}s",
                BEST_EFFORT_TIMEOUT.as_secs()
            )),
        }
    }
}

#[cfg(test)]
mod prune_tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::keys;
    use crate::manifest::lifecycle::RECORD_KIND;
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
                "status": { "phase": activation::PHASE_ACTIVE },
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
        let ops = KubeOps::new(
            client,
            Arc::new(RwLock::new(discovery)),
            KubeOpsConfig {
                cluster_name: "a".into(),
                ..Default::default()
            },
        );
        let rid = |name: &str| ResourceId {
            kind: "ClusterRole".into(),
            namespace: CLUSTER_SCOPED.into(),
            name: name.into(),
        };
        assert_eq!(ops.delete(&rid("mine")).await, Ok(Pruned::Deleted));
        assert!(matches!(
            ops.delete(&rid("shared")).await,
            Ok(Pruned::Kept(_))
        ));
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }
}
