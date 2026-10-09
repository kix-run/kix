//! Reconcile Activation resources for the kix operator.
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
//! 2. Fetch the live kix-managed resources of the record's Kix cluster
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
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::prune_guard::{PruneGuard, Pruned};
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stream::DeployObserver;
use kix::cluster::watchdog::StallPolicy;
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

// ---------------------------------------------------------------------------
// Helpers for reading Activation CR fields
// ---------------------------------------------------------------------------

/// Extract the source store path from an Activation CR.
fn source_path(activation: &DynamicObject) -> Option<std::path::PathBuf> {
    activation
        .data
        .pointer("/spec/source/path")
        .and_then(|v| v.as_str())
        .map(std::path::PathBuf::from)
}

// ---------------------------------------------------------------------------
// Store graph loading
// ---------------------------------------------------------------------------

/// The stamped manifests of the build in the result directory `path`.
///
/// Not refused for a retired domain ([`Build::installable`]): the record
/// may name a build from before the domain move, as `kix rollback
/// --operator` does, and `kix deploy` has already checked a new build
/// before it writes the record.
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

/// The operator's error for a live plan that could not be made, worded as
/// the step that failed.
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

// ---------------------------------------------------------------------------
// Main reconcile function
// ---------------------------------------------------------------------------

/// Main reconcile function called by the kube-rs controller runtime.
///
/// Dispatch reconciliation according to the Activation phase.
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

    // Handle deletion (finalizer)
    if activation.metadata.deletion_timestamp.is_some() {
        return handle_delete(&activation, &ctx, name, &own_cluster).await;
    }

    let record = Record::of(&activation);
    let phase = record.phase.as_str();

    match phase {
        // Superseded activations require no further work.
        s if s == PHASE_SUPERSEDED => {
            tracing::debug!(name, "Activation is Superseded, skipping");
            Ok(Action::await_change())
        }

        // Queued or new (no phase yet): handle activation switchover.
        //
        // A record with no phase is not necessarily a queued deploy waiting
        // for us. The CLI creates its record at the start of a run and marks
        // it Deploying a round trip later (kixpkgs#82), so for a moment it
        // looks exactly like this. Adopting one would supersede the Active
        // record before the CLI had applied anything, stamp our finalizer on
        // a record we do not own, and put two writers on one closure.
        // `spec.source` is the discriminator: we write it when we adopt a
        // deploy, and the CLI never does. Same rule as the Deploying arm.
        s if s.is_empty() || s == PHASE_QUEUED => {
            if source_path(&activation).is_none() {
                tracing::debug!(name, "record has no spec.source; not ours to drive");
                return Ok(Action::await_change());
            }
            tracing::info!(name, cluster = %cluster, "Processing Queued activation");

            // 1. Find all Queued activations for this cluster
            let queued = ctx
                .records
                .queued(&cluster)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

            // 2. If there are newer Queued CRs, supersede this one
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

            // 3. Supersede all other Queued activations (older ones)
            for q in &queued {
                if q.name != name {
                    tracing::info!(name, superseding = %q.name, "Superseding older Queued activation");
                    ctx.records
                        .supersede(&q.name)
                        .await
                        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                }
            }

            // 4. Find and supersede current Active activation
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

            // 5. Ensure finalizer is set, then fall through to reconcile
            ensure_finalizer(&ctx.records, name, &activation).await?;

            // Run reconcile with lifecycle management (will set phase to Active on success)
            return run_reconcile(&activation, &ctx, name, true).await;
        }

        // Active and Degraded records run drift detection on requeue. Degraded means the
        // last deploy completed with some failures; the CR is still the
        // current intended state and we want drift correction to keep trying.
        s if s == PHASE_ACTIVE || s == PHASE_DEGRADED => {
            // Yield to a queued Activation so it can perform the transition.
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

            // Ensure finalizer
            ensure_finalizer(&ctx.records, name, &activation).await?;

            // Run reconcile without lifecycle management (already Active)
            return run_reconcile(&activation, &ctx, name, false).await;
        }

        // Deploying: a resume, the same as a Queued one already transitioning.
        //
        // Unless nobody asked us. The CLI now creates its record at the start
        // of a deploy rather than the end (kixpkgs#82), so a `Deploying`
        // record is just as likely to be a `kix deploy` in flight on
        // somebody's laptop. `spec.source` is what tells the two apart: the
        // operator writes it when it adopts a deploy, and the CLI never does.
        // Reconciling one of those would mean two writers on the same
        // closure, and stamping our finalizer on it would leave the CLI's
        // record undeletable by anything but us.
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

/// Unified reconcile: load desired state, fetch live state, diff, wave-plan, apply.
///
/// If `manage_lifecycle` is true, the run writes the record's lifecycle
/// (begin_deploy/record_waves/finalize_deploy). Used for new deployments.
/// If false, run drift correction without lifecycle changes.
async fn run_reconcile(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    manage_lifecycle: bool,
) -> Result<Action, OperatorError> {
    // 1. Resolve source store path
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;

    // 2. Load desired manifests
    let new_manifests = load_manifests(&path)?;

    if new_manifests.is_empty() {
        tracing::warn!(name, "No manifests found in store graph");
        return Ok(Action::requeue(requeue_interval()));
    }

    // 3. Filter out CRDs and Activation CRs
    //    CRDs: re-applying triggers API watch restarts.
    //    Activation CRs: the Activation is the control input. Applying the
    //    Nix-generated manifest would overwrite spec.source via SSA.
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

    // 4. Compare desired vs live by identity-hash, over this Kix cluster's
    //    live objects only, and plan the changes.
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

    // 5. Run the DAG-streaming scheduler.
    //
    // TODO(operator-cancel): wire this token to a per-Activation supervisor
    // so a newer Activation can cancel the in-flight loop. This caller does
    // not currently trigger cancellation.
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
/// Only Active, Deploying or Degraded activations trigger resource cleanup,
/// and it keeps the kinds `never_pruned` protects and the objects another
/// Kix cluster's current build still contains (see [`delete_closure`]).
/// Superseded activations just get the finalizer removed (the Active
/// activation owns those resources now).
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

    // Only clean up resources for current activations
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

    // Remove finalizer
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

/// Delete a deleted record's closure in `ordered` order through
/// [`PruneGuard`]: an object another Kix cluster's current build contains,
/// such as a shared ClusterRole, stays. `cluster` is the record's Kix
/// cluster; the record is still listed while its finalizer holds it, so its
/// own hash counts as this cluster's.
async fn delete_closure(
    client: &Client,
    records: &Records,
    cluster: &str,
    name: &str,
    ordered: &[ResourceId],
) -> Result<(), OperatorError> {
    let discovery = fetch::discover_resources(client)
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

// ---------------------------------------------------------------------------
// Finalizer management
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Error policy
// ---------------------------------------------------------------------------

/// Error policy: requeue with backoff on errors.
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
    use serde_json::json;

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
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        delete_closure(&client, &records, "b", "b", &[rid("b-only"), rid("shared")])
            .await
            .unwrap();
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }
}
