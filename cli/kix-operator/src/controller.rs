//! Reconcile Activation resources for the Kix operator.
//!
//! # Phase-based lifecycle
//!
//! The operator manages Activation CRs through a phase-based lifecycle:
//!
//! New resources progress through Queued, Deploying, Active, and Superseded.
//!
//! - **Queued**: A new activation waiting to be deployed. The operator
//!   supersedes the current Active activation and begins deploying this one.
//! - **Deploying**: Deploy in progress (wave-by-wave apply).
//! - **Active**: Successfully deployed. Drift detection runs on requeue.
//! - **Superseded**: Replaced by a newer activation.
//!
//! # Unified reconcile loop
//!
//! Both new deployments and drift correction use the same path:
//! 1. Load desired manifests from `spec.source.path`
//! 2. Fetch the live Kix-managed resources of the record's Kix cluster
//! 3. Compare identity-hashes (desired vs live) to determine Apply/Skip/Orphan
//! 4. Wave-plan and apply
//!
//! # Reconcile loop prevention
//!
//! 1. The generation predicate filters events where
//!    only `.status` changed (no generation bump).
//! 2. Status writes use the status subresource through `patch_status`,
//!    which never bumps generation.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use kube::{api::DynamicObject, client::Client, runtime::controller::Action};
use serde_json::Value;
use thiserror::Error;

use kix::build_source::Build;
use kix::cluster::activation::{Record, Records};
use kix::cluster::binding::{self, BindingError, Connection};
use kix::cluster::discovery;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::prune_guard::{PruneGuard, Pruned};
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::DeployObserver;
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::read_index;
use kix::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_QUEUED, PHASE_SUPERSEDED,
};
use kix::manifest::types::ResourceId;
use kix::plan::live::{LivePlan, LivePlanError, cluster_of};

use crate::k8s_events::{CompositeObserver, K8sEventObserver};
use crate::observer::OperatorObserver;
use kix::manifest::keys;

/// Finalizer name for operator-managed cleanup.
const FINALIZER: &str = keys::OPERATOR_GC_FINALIZER;

/// Short requeue when yielding to a Queued activation.
const QUEUED_REQUEUE_INTERVAL: Duration = Duration::from_secs(5);

/// Default requeue interval after successful reconciliation.
/// Override with KIX_REQUEUE_INTERVAL_SECS env var.
fn requeue_interval() -> Duration {
    std::env::var("KIX_REQUEUE_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(300))
}

/// Default requeue interval after errors.
const ERROR_REQUEUE_INTERVAL: Duration = Duration::from_secs(30);

/// Shared context for the controller.
pub struct Context {
    pub client: Client,
    pub records: Records,
}

/// Errors from the operator reconcile loop.
#[derive(Error, Debug)]
pub enum OperatorError {
    #[error("missing spec.source.path on Activation")]
    MissingSourcePath,

    #[error("failed to load store graph from {path}: {reason}")]
    StoreGraphError { path: String, reason: String },

    #[error("failed to run API discovery: {0}")]
    DiscoveryError(String),

    #[error("reconcile failed: {0}")]
    ReconcileError(String),

    #[error("kube error: {0}")]
    KubeError(#[from] kube::Error),

    #[error("graph error: {0}")]
    GraphError(String),

    #[error("activation lifecycle error: {0}")]
    LifecycleError(String),
}

/// Extract the source store path from an Activation CR.
fn source_path(activation: &DynamicObject) -> Option<std::path::PathBuf> {
    activation
        .data
        .pointer("/spec/source/path")
        .and_then(|v| v.as_str())
        .map(std::path::PathBuf::from)
}

/// Load the stamped manifests of the build in `path`.
///
/// Does not reject retired domains ([`Build::installable`]): the record may
/// reference a build created before a domain migration (such as during
/// `kix rollback --operator`), and `kix deploy` validates new builds before
/// writing the record.
fn load_manifests(path: &Path) -> Result<Vec<Value>, OperatorError> {
    let build = Build::local(path, &|_| {}).map_err(|e| OperatorError::StoreGraphError {
        path: path.display().to_string(),
        reason: e.to_string(),
    })?;
    Ok(build
        .graph()
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect())
}

/// What the binding check decided for a Queued record.
enum Binding {
    /// The build may be applied here.
    Accepted,
    /// The build belongs to another Kubernetes cluster, or names none where
    /// a bound one deployed: the record fails with this message.
    Refused(String),
    /// The operator may not read the `kube-system` Namespace: a grant of
    /// permission resolves it, so the record waits with this message.
    Forbidden(String),
}

/// Check that the build the Queued `activation` names belongs to the
/// Kubernetes cluster the operator runs on ([`binding::check`]). An error
/// means the check could not run, so the reconcile is retried.
///
/// Reads only `kix-packages.json` of the build: the whole graph is loaded
/// once the record is past this check.
async fn check_binding(
    client: &Client,
    activation: &DynamicObject,
) -> Result<Binding, OperatorError> {
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;
    let index = read_index(&path).map_err(|e| OperatorError::StoreGraphError {
        path: path.display().to_string(),
        reason: e.to_string(),
    })?;
    match binding::check(
        client,
        &Connection::InCluster,
        &index.cluster,
        index.kubernetes.uid.as_deref(),
    )
    .await
    {
        Ok(()) => Ok(Binding::Accepted),
        Err(e) if e.is_forbidden() => Ok(Binding::Forbidden(e.to_string())),
        Err(
            e @ (BindingError::Mismatch { .. }
            | BindingError::Unbound { .. }
            | BindingError::UnboundRestored { .. }),
        ) => Ok(Binding::Refused(e.to_string())),
        Err(e) => Err(OperatorError::DiscoveryError(e.to_string())),
    }
}

/// Map a [`LivePlanError`] to the corresponding [`OperatorError`] variant.
fn operator_error(e: LivePlanError) -> OperatorError {
    match e {
        LivePlanError::Fetch(_) | LivePlanError::Domain(_) => {
            OperatorError::DiscoveryError(e.to_string())
        }
        LivePlanError::Graph(_) | LivePlanError::Marker(_) => {
            OperatorError::GraphError(e.to_string())
        }
    }
}

/// Reconcile an Activation resource according to its current phase.
pub async fn reconcile_activation(
    activation: Arc<DynamicObject>,
    ctx: Arc<Context>,
) -> Result<Action, OperatorError> {
    let name = activation.metadata.name.as_deref().unwrap_or("<unnamed>");
    // Records are looked up by the cluster label, so a record that names no
    // cluster finds only itself. The sweep and the prune get an empty name
    // instead, under which no record counts as this cluster's own.
    let own_cluster = cluster_of(&activation).unwrap_or_default();
    let cluster = if own_cluster.is_empty() {
        name.to_string()
    } else {
        own_cluster.clone()
    };

    if activation.metadata.deletion_timestamp.is_some() {
        return handle_delete(&activation, &ctx, name, &own_cluster).await;
    }

    let record = Record::of(&activation);
    let phase = record.phase.as_str();

    match phase {
        s if s == PHASE_SUPERSEDED => {
            tracing::debug!(name, "Activation is Superseded, skipping");
            Ok(Action::await_change())
        }

        // Ignore records without `spec.source`. The CLI creates an Activation
        // record before marking it `Deploying`, so a newly created CLI record
        // briefly has an empty phase. Adopting it here would supersede the
        // Active record before the CLI applies anything, attach the operator
        // finalizer to a CLI-owned record, and run two writers concurrently.
        s if s.is_empty() || s == PHASE_QUEUED => {
            if source_path(&activation).is_none() {
                tracing::debug!(name, "record has no spec.source; not ours to drive");
                return Ok(Action::await_change());
            }
            tracing::info!(name, cluster = %cluster, "Processing Queued activation");

            // A build bound to another Kubernetes cluster, or an unbound one
            // where a bound build has deployed, fails here, before any other
            // record is superseded and before anything is applied. A 403 on
            // the Namespace leaves the record Queued and retries, since a
            // grant of permission resolves it.
            let events = || {
                K8sEventObserver::new(
                    ctx.client.clone(),
                    &activation,
                    keys::API_VERSION,
                    Some(name.to_string()),
                )
            };
            match check_binding(&ctx.client, &activation).await? {
                Binding::Accepted => {}
                Binding::Refused(reason) => {
                    tracing::warn!(name, %reason, "Refusing the Queued activation");
                    ctx.records
                        .fail_queued(name, &reason)
                        .await
                        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                    events().warn_now("BindingRefused", &reason).await;
                    return Ok(Action::await_change());
                }
                Binding::Forbidden(reason) => {
                    tracing::warn!(name, %reason, "Cannot check the Queued activation's binding yet");
                    events().warn_now("BindingUnchecked", &reason).await;
                    return Err(OperatorError::DiscoveryError(reason));
                }
            }

            let queued = ctx
                .records
                .queued(&cluster)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

            // If a newer Queued activation exists, supersede this one.
            if let Some(newest) = queued.first()
                && newest.name != name
            {
                tracing::info!(
                    name,
                    newest = %newest.name,
                    "Newer Queued activation exists, superseding self"
                );
                ctx.records
                    .supersede(name)
                    .await
                    .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                return Ok(Action::await_change());
            }

            // Supersede any older Queued activations.
            for q in &queued {
                if q.name != name {
                    tracing::info!(name, superseding = %q.name, "Superseding older Queued activation");
                    ctx.records
                        .supersede(&q.name)
                        .await
                        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                }
            }

            let old_active = ctx
                .records
                .active(&cluster)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

            if let Some(ref old) = old_active {
                tracing::info!(name, old = %old.name, "Superseding current Active activation");
                ctx.records
                    .supersede(&old.name)
                    .await
                    .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
            }

            ensure_finalizer(&ctx.records, name, &activation).await?;

            return run_reconcile(&activation, &ctx, name, true).await;
        }

        // Active and Degraded records run drift detection on requeue. Degraded
        // means the last deploy completed with some failures, but the CR is
        // still the current intended state.
        s if s == PHASE_ACTIVE || s == PHASE_DEGRADED => {
            // Yield to any queued Activation so it can perform the transition.
            let queued = ctx
                .records
                .queued(&cluster)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

            if !queued.is_empty() {
                tracing::info!(
                    name,
                    queued_count = queued.len(),
                    "Queued activations exist, yielding"
                );
                return Ok(Action::requeue(QUEUED_REQUEUE_INTERVAL));
            }

            ensure_finalizer(&ctx.records, name, &activation).await?;

            return run_reconcile(&activation, &ctx, name, false).await;
        }

        // Resume an interrupted operator deployment. Records without
        // `spec.source` belong to an in-flight CLI `kix deploy` and must not
        // be adopted by the operator.
        s if s == PHASE_DEPLOYING => {
            if source_path(&activation).is_none() {
                tracing::debug!(
                    name,
                    "Deploying record has no spec.source; not ours to drive"
                );
                return Ok(Action::await_change());
            }
            tracing::info!(name, "Resuming Deploying activation");
            ensure_finalizer(&ctx.records, name, &activation).await?;
            return run_reconcile(&activation, &ctx, name, true).await;
        }

        // Failed is terminal. The deploy that owned it has stopped, and the
        // next one folds its closure into the plan and supersedes it. There
        // is nothing here to reconcile toward.
        s if s == PHASE_FAILED => {
            tracing::debug!(name, "Failed activation, nothing to reconcile");
            Ok(Action::await_change())
        }

        _ => {
            tracing::debug!(name, phase, "Unknown phase, skipping");
            Ok(Action::requeue(requeue_interval()))
        }
    }
}

/// Load desired state, fetch live state, diff, wave-plan, and apply.
///
/// When `manage_lifecycle` is true, records deployment lifecycle transitions
/// on the Activation CR (`begin_deploy`, `record_waves`, and `finalize_deploy`).
/// When false, runs drift correction without modifying the Activation phase.
async fn run_reconcile(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    manage_lifecycle: bool,
) -> Result<Action, OperatorError> {
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;
    let new_manifests = load_manifests(&path)?;

    if new_manifests.is_empty() {
        tracing::warn!(name, "No manifests found in store graph");
        return Ok(Action::requeue(requeue_interval()));
    }

    // Exclude CRDs (re-applying them triggers API watch restarts) and
    // Activation CRs (applying the Nix-generated manifest would overwrite
    // `spec.source` via server-side apply).
    let managed_manifests: Vec<Value> = new_manifests
        .iter()
        .filter(|m| {
            ResourceId::from_value(m).kind != "CustomResourceDefinition"
                && !kix::manifest::lifecycle::is_record(m)
        })
        .cloned()
        .collect();

    if managed_manifests.is_empty() {
        tracing::debug!(name, "No managed manifests to reconcile");
        return Ok(Action::requeue(requeue_interval()));
    }

    let plan = LivePlan::sweep(&ctx.client, activation, &managed_manifests)
        .await
        .map_err(operator_error)?;
    for (owner, count) in plan.foreign() {
        tracing::debug!(name, owner = %owner, count, "left out objects of another Kix cluster");
    }
    if plan.unattributed() > 0 {
        tracing::info!(
            name,
            count = plan.unattributed(),
            "left out Kix objects that name no Activation record; another Kix cluster deploys here",
        );
    }
    for s in plan.shared_orphans() {
        tracing::info!(name, resource = %s.rid, clusters = ?s.clusters, "prune: {}", s.describe());
    }

    tracing::info!(
        name,
        apply = plan.applies(),
        orphans = plan.orphans().len(),
        unchanged = plan.unchanged(),
        lifecycle = manage_lifecycle,
        "Live change detection complete"
    );

    // TODO(operator-cancel): wire this token to a per-Activation supervisor
    // so a newer Activation can cancel the in-flight loop.
    let config = SchedulerConfig {
        timeout: Duration::from_secs(300),
        on_error: OnErrorPolicy::Stop,
        cancel: kix::cluster::cancel::CancelToken::new(),
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        // Never retry a failed probe from the reconcile loop: it would
        // delete and recreate the Job every 30 s on a degraded cluster.
        rerun_failed: false,
    };

    // Compose two observers: tracing (structured logs) + K8s Events
    // (cluster-observable audit trail on the Activation CR).
    let observer: Arc<dyn DeployObserver> = Arc::new(CompositeObserver::new(vec![
        Arc::new(OperatorObserver::new(name)) as Arc<dyn DeployObserver>,
        Arc::new(K8sEventObserver::new(
            ctx.client.clone(),
            activation,
            keys::API_VERSION,
            Some(name.to_string()),
        )) as Arc<dyn DeployObserver>,
    ]));
    let result = plan.run(manage_lifecycle, config, observer).await;

    match result {
        Ok(r) => {
            tracing::info!(
                name,
                created = r.created,
                configured = r.configured,
                unchanged = r.unchanged,
                pruned = r.pruned,
                failed = r.failed,
                lifecycle = manage_lifecycle,
                "Reconciliation complete"
            );
            Ok(Action::requeue(requeue_interval()))
        }
        Err(e) => {
            tracing::error!(name, error = %e, "Reconciliation failed");
            Err(OperatorError::ReconcileError(e.to_string()))
        }
    }
}

/// Handle deletion of an Activation CR (finalizer cleanup).
///
/// Only Active, Deploying, or Degraded activations trigger resource cleanup,
/// keeping kinds protected by `never_pruned` and objects still referenced by
/// another Kix cluster's active build (see [`delete_closure`]). Superseded
/// activations simply have their finalizer removed because the Active
/// activation now owns their resources.
async fn handle_delete(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    cluster: &str,
) -> Result<Action, OperatorError> {
    let finalizers = activation.metadata.finalizers.as_deref().unwrap_or(&[]);

    if !finalizers.contains(&FINALIZER.to_string()) {
        return Ok(Action::await_change());
    }

    let record = Record::of(activation);
    let phase = record.phase.as_str();

    if phase == PHASE_ACTIVE || phase == PHASE_DEPLOYING || phase == PHASE_DEGRADED {
        tracing::info!(
            name,
            phase,
            "Handling Activation deletion — cleaning up resources"
        );

        if let Some(path) = source_path(activation)
            && let Ok(manifests) = load_manifests(&path)
        {
            let all_rids: Vec<ResourceId> = manifests
                .iter()
                .map(ResourceId::from_value)
                .filter(|rid| !kix::manifest::lifecycle::is_record_kind(&rid.kind))
                .collect();

            let orphan_set: std::collections::HashSet<String> = all_rids
                .iter()
                .map(|rid| format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
                .collect();
            let orphan_manifests: Vec<Value> = manifests
                .iter()
                .filter(|m| {
                    let rid = ResourceId::from_value(m);
                    orphan_set.contains(&format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
                })
                .cloned()
                .collect();
            let ordered: Vec<ResourceId> = match ResourceGraph::from_manifests(&orphan_manifests) {
                Ok(g) => g.reverse_topo_ids(),
                Err(_) => all_rids.clone(),
            }
            .into_iter()
            // Namespaces and CRDs stay, which also keeps the CRD this
            // operator's own Activation records live in. See `never_pruned`.
            .filter(|rid| !kix::manifest::lifecycle::never_pruned(&rid.kind))
            .collect();

            delete_closure(&ctx.client, &ctx.records, cluster, name, &ordered).await?;
        }
    } else {
        tracing::info!(
            name,
            phase,
            "Activation is Superseded/Queued — removing finalizer without resource cleanup"
        );
    }

    let rest: Vec<String> = finalizers
        .iter()
        .filter(|f| f.as_str() != FINALIZER)
        .cloned()
        .collect();
    ctx.records
        .set_finalizers(name, &rest)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

    tracing::info!(name, "Finalizer removed, Activation can be deleted");
    Ok(Action::await_change())
}

/// Delete a deleted record's resources in `ordered` order through
/// [`PruneGuard`], preserving any object still referenced by another Kix
/// cluster's current build (such as a shared ClusterRole). `cluster` is the
/// record's Kix cluster; because the record remains listed while its finalizer
/// is present, its own hash still counts as belonging to `cluster`.
async fn delete_closure(
    client: &Client,
    records: &Records,
    cluster: &str,
    name: &str,
    ordered: &[ResourceId],
) -> Result<(), OperatorError> {
    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;
    let guard = PruneGuard::new(client.clone(), records.clone().into(), cluster);
    for rid in ordered {
        let Some((ar, scope)) = discovery.iter().find(|(ar, _)| ar.kind == rid.kind) else {
            continue;
        };
        match guard
            .delete(ar, scope, rid, &kube::api::DeleteParams::default())
            .await
        {
            Ok(Pruned::Deleted) => tracing::info!(name, resource = %rid, "Deleted"),
            Ok(Pruned::Gone) => {}
            Ok(kept) => {
                let reason = kept.kept_reason().unwrap_or_default();
                tracing::info!(name, resource = %rid, "prune: {reason}");
            }
            Err(e) => tracing::warn!(name, resource = %rid, error = %e, "Failed to delete"),
        }
    }
    Ok(())
}

/// Ensure the finalizer is set on the Activation CR.
async fn ensure_finalizer(
    records: &Records,
    name: &str,
    activation: &DynamicObject,
) -> Result<(), OperatorError> {
    let finalizers = activation.metadata.finalizers.as_deref().unwrap_or(&[]);

    if finalizers.contains(&FINALIZER.to_string()) {
        return Ok(());
    }

    let mut new_finalizers: Vec<String> = finalizers.to_vec();
    new_finalizers.push(FINALIZER.to_string());
    records
        .set_finalizers(name, &new_finalizers)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

    tracing::info!(name, "Added finalizer {FINALIZER}");
    Ok(())
}

/// Requeue failed reconciliations after [`ERROR_REQUEUE_INTERVAL`].
pub fn error_policy(
    _activation: Arc<DynamicObject>,
    error: &OperatorError,
    _ctx: Arc<Context>,
) -> Action {
    tracing::warn!(error = %error, "Error during reconciliation, requeueing");
    Action::requeue(ERROR_REQUEUE_INTERVAL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::fake_api::{FakeApi, kube_system};
    use serde_json::json;

    const HERE: &str = "9f8e7d6c-5b4a-4321-8765-0fedcba98765";
    const ELSEWHERE: &str = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";

    /// A Queued record of cluster `a` whose build, in a temporary result
    /// directory, names the Kubernetes cluster `kubernetes_uid`.
    fn queued(dir: &Path, kubernetes_uid: Option<&str>) -> Value {
        let index = json!({
            "cluster": "a",
            "kubernetes": { "uid": kubernetes_uid },
            "packages": {},
        });
        std::fs::write(dir.join("kix-packages.json"), index.to_string()).unwrap();
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-new",
                "labels": { (keys::CLUSTER_LABEL): "a" },
            },
            "spec": {
                "cluster": "a",
                "source": { "type": "storePath", "path": dir.display().to_string() },
            },
        })
    }

    /// Reconcile `queued` on a fake holding `objects`, and return the record
    /// afterwards.
    async fn reconcile_queued(objects: Vec<Value>, queued: Value) -> (FakeApi, DynamicObject) {
        let api = FakeApi::new(objects);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let resource = records.watch_resource().clone();
        let ctx = Arc::new(Context { client, records });
        let activation: DynamicObject = serde_json::from_value(queued).unwrap();
        reconcile_activation(Arc::new(activation), ctx.clone())
            .await
            .unwrap();
        let after = kube::Api::<DynamicObject>::all_with(ctx.client.clone(), &resource)
            .get("a-new")
            .await
            .unwrap();
        (api, after)
    }

    /// A Queued build bound to another Kubernetes cluster is marked Failed
    /// with the reason, and the Active record is left alone.
    #[tokio::test]
    async fn a_queued_build_bound_elsewhere_fails_before_anything_is_superseded() {
        let dir = tempfile::tempdir().unwrap();
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "a-old", "labels": { (keys::CLUSTER_LABEL): "a" } },
            "status": { "phase": PHASE_ACTIVE },
        });
        let record = queued(dir.path(), Some(ELSEWHERE));
        let (api, after) =
            reconcile_queued(vec![kube_system(HERE), active, record.clone()], record).await;
        assert_eq!(after.data["status"]["phase"], PHASE_FAILED);
        let reason = after.data["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains(&format!(
                "a's definition sets cluster.kubernetes.uid = \"{ELSEWHERE}\""
            )) && reason.contains("Nothing was applied"),
            "{reason}"
        );
        let supersedes: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| r.contains("a-old"))
            .collect();
        assert!(supersedes.is_empty(), "{supersedes:?}");
    }

    /// An unbound Queued build on a Kubernetes cluster where a bound build
    /// deployed fails the same way, naming that build's cluster.
    #[tokio::test]
    async fn an_unbound_queued_build_fails_where_a_bound_build_deployed() {
        let dir = tempfile::tempdir().unwrap();
        let bound = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "lab1-1",
                "labels": { (keys::CLUSTER_LABEL): "lab1", (keys::KUBERNETES_UID): HERE },
            },
            "status": { "phase": PHASE_ACTIVE },
        });
        let record = queued(dir.path(), None);
        let (_, after) =
            reconcile_queued(vec![kube_system(HERE), bound, record.clone()], record).await;
        assert_eq!(after.data["status"]["phase"], PHASE_FAILED);
        let reason = after.data["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains(&format!(
                "lab1 was deployed here with cluster.kubernetes.uid = \"{HERE}\""
            )),
            "{reason}"
        );
    }

    /// A 403 on the Namespace leaves the Queued record as it is and retries,
    /// since a grant to the operator's service account resolves it.
    #[tokio::test]
    async fn a_forbidden_namespace_read_leaves_the_record_queued() {
        let dir = tempfile::tempdir().unwrap();
        let record = queued(dir.path(), Some(HERE));
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 403);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let resource = records.watch_resource().clone();
        let ctx = Arc::new(Context { client, records });
        let activation: DynamicObject = serde_json::from_value(record).unwrap();
        let err = reconcile_activation(Arc::new(activation), ctx.clone())
            .await
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("Grant the operator's service account get permission on namespaces"),
            "{err}"
        );
        let after = kube::Api::<DynamicObject>::all_with(ctx.client.clone(), &resource)
            .get("a-new")
            .await
            .unwrap();
        assert!(after.data.get("status").is_none(), "{:?}", after.data);
    }

    /// Deleting `b`'s Active record tears down `b`'s closure but leaves the
    /// ClusterRole `a`'s current build also contains.
    #[tokio::test]
    async fn finalizer_keeps_what_another_cluster_still_deploys() {
        use kix::cluster::fake_api::FakeApi;
        let rec = |cluster: &str, hash: &str| {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": cluster,
                    "labels": { (keys::CLUSTER_LABEL): cluster },
                    "annotations": { (keys::IDENTITY_HASH): hash },
                },
                "status": { "phase": PHASE_ACTIVE },
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
            role("b-only", "b1"),
            role("shared", "a1,b1"),
        ]);
        let rid = |name: &str| ResourceId {
            kind: "ClusterRole".into(),
            namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
            name: name.into(),
        };
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        delete_closure(&client, &records, "b", "b", &[rid("b-only"), rid("shared")])
            .await
            .unwrap();
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }
}
