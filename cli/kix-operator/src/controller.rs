//! Activation controller — reconcile logic for the kix operator.
//!
//! # Phase-based lifecycle
//!
//! The operator manages Activation CRs through a phase-based lifecycle:
//!
//! ```text
//! (new CR, no status) → Queued → Deploying → Active → Superseded
//! ```
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
//! 2. Fetch live kix-managed resources from the cluster
//! 3. Compare identity-hashes (desired vs live) to determine Apply/Skip/Orphan
//! 4. Wave-plan and apply
//!
//! # Reconcile loop prevention
//!
//! 1. **Generation predicate** — the watcher stream filters out events where
//!    only `.status` changed (no generation bump).
//! 2. **Status subresource** — all status writes go through `patch_status`,
//!    which never bumps generation.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
    runtime::controller::Action,
};
use serde_json::Value;
use thiserror::Error;

use kix::cluster::activation::{
    self, PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_SUPERSEDED,
};
use kix::cluster::apply::{ChangeAction, IDENTITY_HASH_ANNOTATION};
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::reconcile::{OnErrorPolicy, PrunePolicy, ReconcileConfig, compute_prune_order};
use kix::cluster::waves::compute_waves;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

use crate::observer::OperatorObserver;

/// Finalizer name for operator-managed cleanup.
const FINALIZER: &str = "kix.dev/operator-gc";

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
    pub activation_ar: ApiResource,
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

/// Extract the cluster name from an Activation CR.
fn cluster_name(activation: &DynamicObject) -> Option<String> {
    activation
        .data
        .pointer("/spec/cluster")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// Extract identity hash from annotations.
fn identity_hash(activation: &DynamicObject) -> Option<String> {
    activation
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
        .cloned()
}

// ---------------------------------------------------------------------------
// Store graph loading
// ---------------------------------------------------------------------------

/// Load a StoreGraph from a result directory, stamp annotations, and collect manifests.
fn load_and_stamp(path: &Path) -> Result<(StoreGraph, Vec<Value>), OperatorError> {
    let noop = |_: &str| {};
    let mut graph = StoreGraph::from_result_dir_with_status(path, &noop).map_err(|e| {
        OperatorError::StoreGraphError {
            path: path.display().to_string(),
            reason: e.to_string(),
        }
    })?;
    stamp_annotations(&mut graph);
    let manifests = graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();
    Ok((graph, manifests))
}

/// Build wave_actions from change detection results and resource graph.
fn build_wave_actions(
    all_actions: &[ChangeAction],
    new_manifests: &[Value],
) -> Result<(Vec<Vec<ChangeAction>>, Vec<ResourceId>), OperatorError> {
    let resource_graph = ResourceGraph::from_manifests(new_manifests)
        .map_err(|e| OperatorError::GraphError(e.to_string()))?;
    let waves = compute_waves(&resource_graph);

    // Map each wave node to its change action
    let mut new_manifest_actions = std::collections::HashMap::new();
    for action in all_actions {
        let k8s_id = match action {
            ChangeAction::Apply(m) => {
                let rid = ResourceId::from_value(m);
                format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
            }
            ChangeAction::Skip(rid) => {
                format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
            }
            ChangeAction::Orphan(_) => continue,
        };
        new_manifest_actions.insert(k8s_id, action);
    }

    let wave_actions: Vec<Vec<ChangeAction>> = waves
        .iter()
        .map(|wave| {
            wave.iter()
                .map(|&idx| {
                    let node = &resource_graph.graph[idx];
                    let k8s_id = format!("{}/{}/{}", node.id.kind, node.id.namespace, node.id.name);
                    match new_manifest_actions.get(&k8s_id) {
                        Some(ChangeAction::Apply(m)) => ChangeAction::Apply(m.clone()),
                        Some(ChangeAction::Skip(rid)) => ChangeAction::Skip(rid.clone()),
                        _ => ChangeAction::Skip(node.id.clone()),
                    }
                })
                .collect()
        })
        .collect();

    let orphan_rids: Vec<ResourceId> = all_actions
        .iter()
        .filter_map(|a| {
            if let ChangeAction::Orphan(rid) = a {
                Some(rid.clone())
            } else {
                None
            }
        })
        .collect();

    Ok((wave_actions, orphan_rids))
}

// ---------------------------------------------------------------------------
// Main reconcile function
// ---------------------------------------------------------------------------

/// Main reconcile function called by the kube-rs controller runtime.
///
/// Dispatches based on phase:
/// - Queued/empty → handle activation switchover, then reconcile
/// - Active → drift detection reconcile
/// - Deploying → resume deploy
/// - Superseded → no-op
pub async fn reconcile_activation(
    activation: Arc<DynamicObject>,
    ctx: Arc<Context>,
) -> Result<Action, OperatorError> {
    let name = activation.metadata.name.as_deref().unwrap_or("<unnamed>");
    let cluster = cluster_name(&activation).unwrap_or_else(|| name.to_string());

    // Handle deletion (finalizer)
    if activation.metadata.deletion_timestamp.is_some() {
        return handle_delete(&activation, &ctx, name, &cluster).await;
    }

    let phase = activation::read_phase(&activation);

    match phase {
        // Superseded activations are done — nothing to do
        s if s == PHASE_SUPERSEDED => {
            tracing::debug!(name, "Activation is Superseded, skipping");
            Ok(Action::await_change())
        }

        // Queued or new (no phase yet) — handle activation switchover
        s if s.is_empty() || s == activation::PHASE_QUEUED => {
            tracing::info!(name, cluster = %cluster, "Processing Queued activation");

            // 1. Find all Queued activations for this cluster
            let queued = activation::find_queued(&ctx.client, &ctx.activation_ar, &cluster)
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
                activation::supersede_activation(&ctx.client, &ctx.activation_ar, name)
                    .await
                    .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                return Ok(Action::await_change());
            }

            // 3. Supersede all other Queued activations (older ones)
            for q in &queued {
                if q.name != name {
                    tracing::info!(name, superseding = %q.name, "Superseding older Queued activation");
                    activation::supersede_activation(&ctx.client, &ctx.activation_ar, &q.name)
                        .await
                        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                }
            }

            // 4. Find and supersede current Active activation
            let old_active = activation::find_active(&ctx.client, &ctx.activation_ar, &cluster)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

            if let Some(ref old) = old_active {
                tracing::info!(name, old = %old.name, "Superseding current Active activation");
                activation::supersede_activation(&ctx.client, &ctx.activation_ar, &old.name)
                    .await
                    .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
            }

            // 5. Ensure finalizer is set, then fall through to reconcile
            ensure_finalizer(&ctx.client, &ctx.activation_ar, name, &activation).await?;

            // Run reconcile with lifecycle management (will set phase to Active on success)
            return run_reconcile(&activation, &ctx, name, &cluster, true).await;
        }

        // Active or Degraded — drift detection on requeue. Degraded means the
        // last deploy completed with some failures; the CR is still the
        // current intended state and we want drift correction to keep trying.
        s if s == PHASE_ACTIVE || s == PHASE_DEGRADED => {
            // Check for Queued CRs — if any, yield to let them handle the transition
            let queued = activation::find_queued(&ctx.client, &ctx.activation_ar, &cluster)
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
            ensure_finalizer(&ctx.client, &ctx.activation_ar, name, &activation).await?;

            // Run reconcile without lifecycle management (already Active)
            return run_reconcile(&activation, &ctx, name, &cluster, false).await;
        }

        // Deploying — treat as a resume (same as Queued that's already transitioning)
        s if s == PHASE_DEPLOYING => {
            tracing::info!(name, "Resuming Deploying activation");
            ensure_finalizer(&ctx.client, &ctx.activation_ar, name, &activation).await?;
            return run_reconcile(&activation, &ctx, name, &cluster, true).await;
        }

        _ => {
            tracing::debug!(name, phase, "Unknown phase, skipping");
            Ok(Action::requeue(requeue_interval()))
        }
    }
}

/// Unified reconcile: load desired state, fetch live state, diff, wave-plan, apply.
///
/// If `manage_lifecycle` is true, passes `activation_name` to the reconcile engine
/// so it runs begin_deploy/record_waves/finalize_deploy. Used for new deployments.
/// If false, drift correction only — no lifecycle changes.
async fn run_reconcile(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    cluster: &str,
    manage_lifecycle: bool,
) -> Result<Action, OperatorError> {
    // 1. Resolve source store path
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;

    // 2. Load desired manifests
    let (_new_graph, new_manifests) = load_and_stamp(&path)?;

    if new_manifests.is_empty() {
        tracing::warn!(name, "No manifests found in store graph");
        return Ok(Action::requeue(requeue_interval()));
    }

    // 3. Filter out CRDs and Activation CRs
    //    CRDs: re-applying triggers API watch restarts.
    //    Activation CRs: the Activation is the control input — applying the
    //    Nix-generated manifest would overwrite spec.source via SSA.
    let skip_kinds: &[&str] = &["CustomResourceDefinition", "Activation"];
    let managed_manifests: Vec<Value> = new_manifests
        .iter()
        .filter(|m| !skip_kinds.contains(&ResourceId::from_value(m).kind.as_str()))
        .cloned()
        .collect();

    if managed_manifests.is_empty() {
        tracing::debug!(name, "No managed manifests to reconcile");
        return Ok(Action::requeue(requeue_interval()));
    }

    // 4. Fetch live kix-managed resources from the cluster
    let mut discovery = fetch::discover_resources(&ctx.client)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;

    let live_resources = fetch::fetch_managed_resources(&ctx.client, &discovery)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;

    // 5. Compare desired vs live by identity-hash
    let all_actions = kix::cluster::apply::detect_changes_live(&managed_manifests, &live_resources);

    let apply_count = all_actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .count();
    let orphan_count = all_actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Orphan(_)))
        .count();
    let skip_count = all_actions.len() - apply_count - orphan_count;

    tracing::info!(
        name,
        apply = apply_count,
        orphans = orphan_count,
        unchanged = skip_count,
        lifecycle = manage_lifecycle,
        "Live change detection complete"
    );

    // 6. Build wave actions
    let (wave_actions, orphan_rids) = build_wave_actions(&all_actions, &managed_manifests)?;

    // Find activation identity hash for annotation merging
    let act_identity_hash = identity_hash(activation);

    // 7. Run reconcile engine
    let config = ReconcileConfig {
        timeout: Duration::from_secs(300),
        on_error: OnErrorPolicy::Stop,
        prune: PrunePolicy::Delete,
        // The operator runs unattended; surface conflicts in Activation status
        // rather than silently clobbering fields owned by other controllers.
        force_conflicts: false,
    };

    let observer = OperatorObserver::new(name);

    // For new deployments: pass activation_name to trigger lifecycle management.
    // For drift correction: pass None to skip lifecycle changes.
    let reconcile_act_name = if manage_lifecycle { Some(name) } else { None };

    // For orphan pruning, we need manifests to compute prune order.
    // Use the live resources' data as "old manifests" for ordering.
    let old_manifest_values: Vec<Value> =
        live_resources.iter().map(|obj| obj.data.clone()).collect();

    let result = kix::cluster::reconcile::reconcile(
        &ctx.client,
        &mut discovery,
        &wave_actions,
        &orphan_rids,
        &old_manifest_values,
        cluster,
        reconcile_act_name,
        act_identity_hash.as_deref(),
        &config,
        &observer,
    )
    .await;

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

// ---------------------------------------------------------------------------
// Deletion handler
// ---------------------------------------------------------------------------

/// Handle deletion of an Activation CR (finalizer cleanup).
///
/// Only Active or Deploying activations trigger resource cleanup.
/// Superseded activations just get the finalizer removed (the Active
/// activation owns those resources now).
async fn handle_delete(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    _cluster: &str,
) -> Result<Action, OperatorError> {
    let finalizers = activation.metadata.finalizers.as_deref().unwrap_or(&[]);

    if !finalizers.contains(&FINALIZER.to_string()) {
        return Ok(Action::await_change());
    }

    let phase = activation::read_phase(activation);

    // Only clean up resources for current activations
    if phase == PHASE_ACTIVE || phase == PHASE_DEPLOYING || phase == PHASE_DEGRADED {
        tracing::info!(
            name,
            phase,
            "Handling Activation deletion — cleaning up resources"
        );

        if let Some(path) = source_path(activation)
            && let Ok((_graph, manifests)) = load_and_stamp(&path)
        {
            let all_rids: Vec<ResourceId> = manifests
                .iter()
                .map(ResourceId::from_value)
                .filter(|rid| rid.kind != "Activation")
                .collect();

            let kix_crds: &[&str] = &["activations.kix.dev", "packageinstances.kix.dev"];
            let ordered: Vec<ResourceId> = compute_prune_order(&all_rids, &manifests)
                .into_iter()
                .filter(|rid| {
                    !(rid.kind == "CustomResourceDefinition"
                        && kix_crds.contains(&rid.name.as_str()))
                })
                .collect();

            let discovery = fetch::discover_resources(&ctx.client)
                .await
                .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;

            let ar_by_kind: std::collections::HashMap<String, (&ApiResource, Scope)> = discovery
                .iter()
                .map(|(ar, scope)| (ar.kind.clone(), (ar, scope.clone())))
                .collect();

            for rid in &ordered {
                if rid.kind == "Namespace" {
                    continue;
                }
                if let Some(&(ar, ref scope)) = ar_by_kind.get(&rid.kind) {
                    let api: Api<DynamicObject> = match scope {
                        Scope::Namespaced => {
                            let ns = if rid.namespace == kix::manifest::types::CLUSTER_SCOPED {
                                "default"
                            } else {
                                &rid.namespace
                            };
                            Api::namespaced_with(ctx.client.clone(), ns, ar)
                        }
                        Scope::Cluster => Api::all_with(ctx.client.clone(), ar),
                    };
                    match api
                        .delete(&rid.name, &kube::api::DeleteParams::default())
                        .await
                    {
                        Ok(_) => tracing::info!(name, resource = %rid, "Deleted"),
                        Err(e) => {
                            tracing::warn!(name, resource = %rid, error = %e, "Failed to delete")
                        }
                    }
                }
            }
        }
    } else {
        tracing::info!(
            name,
            phase,
            "Activation is Superseded/Queued — removing finalizer without resource cleanup"
        );
    }

    // Remove finalizer
    let api: Api<DynamicObject> = Api::all_with(ctx.client.clone(), &ctx.activation_ar);
    let patch = serde_json::json!({
        "metadata": {
            "finalizers": finalizers
                .iter()
                .filter(|f| f.as_str() != FINALIZER)
                .collect::<Vec<_>>()
        }
    });
    api.patch(name, &PatchParams::default(), &Patch::Merge(&patch))
        .await?;

    tracing::info!(name, "Finalizer removed, Activation can be deleted");
    Ok(Action::await_change())
}

// ---------------------------------------------------------------------------
// Finalizer management
// ---------------------------------------------------------------------------

/// Ensure the finalizer is set on the Activation CR.
async fn ensure_finalizer(
    client: &Client,
    ar: &ApiResource,
    name: &str,
    activation: &DynamicObject,
) -> Result<(), OperatorError> {
    let finalizers = activation.metadata.finalizers.as_deref().unwrap_or(&[]);

    if finalizers.contains(&FINALIZER.to_string()) {
        return Ok(());
    }

    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let mut new_finalizers: Vec<String> = finalizers.to_vec();
    new_finalizers.push(FINALIZER.to_string());

    let patch = serde_json::json!({
        "metadata": {
            "finalizers": new_finalizers
        }
    });
    api.patch(name, &PatchParams::default(), &Patch::Merge(&patch))
        .await?;

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
