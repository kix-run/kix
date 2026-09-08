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
#[derive(Debug, Clone, Default)]
pub struct KubeOpsConfig {
    pub cluster_name: String,
    /// Name of the Activation CR for this run. `None` for runs that do not
    /// manage the lifecycle (some operator paths).
    pub activation_name: Option<String>,
    /// Identity hash of the Activation, stamped into `kix.dev/activations`.
    pub activation_identity_hash: Option<String>,
    /// Take ownership of fields another manager owns.
    pub force_conflicts: bool,
    /// Apiserver dry run: SSA and DELETE go with `dryRun=All`; nothing is
    /// written to the Activation.
    pub dry_run: bool,
}

pub struct KubeOps {
    client: Client,
    discovery: DiscoveryCache,
    cfg: KubeOpsConfig,
    /// Identity hashes of every Activation CR on the cluster, read once in
    /// [`ClusterOps::begin`]. `None` = do not prune the annotation.
    live_activations: std::sync::RwLock<Option<HashSet<String>>>,
}

impl KubeOps {
    pub fn new(client: Client, discovery: DiscoveryCache, cfg: KubeOpsConfig) -> Self {
        Self {
            client,
            discovery,
            cfg,
            live_activations: std::sync::RwLock::new(None),
        }
    }

    fn live_activations(&self) -> Option<HashSet<String>> {
        self.live_activations.read().ok().and_then(|g| g.clone())
    }

    async fn activation_ar(&self) -> Option<ApiResource> {
        let d = self.discovery.read().await;
        activation::find_activation_ar(&d).map(|(ar, _)| ar.clone())
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
        match scope {
            Scope::Namespaced => {
                let ns = if rid.namespace == CLUSTER_SCOPED {
                    "default"
                } else {
                    rid.namespace.as_str()
                };
                Api::namespaced_with(self.client.clone(), ns, ar)
            }
            Scope::Cluster => Api::all_with(self.client.clone(), ar),
        }
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
            return Ok(());
        };
        if let Some(name) = &self.cfg.activation_name
            && let Err(e) = activation::begin_deploy(&self.client, &ar, name, 1).await
        {
            // 404 on the first deploy: the CR lands in the last wave.
            tracing::debug!("activation not yet on cluster (first deploy): {e}");
        }
        let live = activation::live_activation_hashes(&self.client, &ar).await;
        if let Ok(mut slot) = self.live_activations.write() {
            *slot = live;
        }
        Ok(())
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
        // An object that is already gone (TTL-reaped, deleted by hand,
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
        let mut d = self.discovery.write().await;
        *d = fetch::merge_discovery(&d, new);
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

    async fn delete(&self, rid: &ResourceId) -> Result<(), String> {
        let (ar, scope) = self
            .cached_kind(&rid.kind)
            .await
            .ok_or_else(|| format!("kind {} not in discovery cache", rid.kind))?;
        let api = self.api_for(&ar, &scope, rid);
        let dp = kube::api::DeleteParams {
            propagation_policy: Some(kube::api::PropagationPolicy::Background),
            dry_run: self.cfg.dry_run,
            ..Default::default()
        };
        api.delete(&rid.name, &dp)
            .await
            .map(|_| ())
            .map_err(|e| describe(&e))
    }

    async fn finalize(&self, had_failures: bool) -> Result<Option<Finalized>, String> {
        if self.cfg.dry_run {
            return Ok(None);
        }
        let (Some(ar), Some(name)) = (self.activation_ar().await, &self.cfg.activation_name) else {
            return Ok(None);
        };
        let work = async {
            let old = activation::find_active(&self.client, &ar, &self.cfg.cluster_name)
                .await
                .ok()
                .flatten()
                .filter(|old| &old.name != name);
            activation::finalize_deploy(
                &self.client,
                &ar,
                &self.cfg.cluster_name,
                name,
                old.as_ref(),
                had_failures,
            )
            .await
            .map(|()| Finalized {
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
