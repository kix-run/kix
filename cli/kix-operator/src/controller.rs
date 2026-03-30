//! Activation controller — reconcile logic for the kix operator.
//!
//! On create/update: load store graph from spec.source.path, diff against
//! previous activation, apply wave-by-wave via the shared reconcile engine.
//!
//! On delete: clean up resources unique to this activation (finalizer).

use std::path::{Path, PathBuf};
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

/// Annotation storing the source path that was last successfully applied.
const LAST_APPLIED_SOURCE: &str = "kix.dev/last-applied-source";

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
}

/// Extract the source store path from an Activation CR.
fn source_path(activation: &DynamicObject) -> Option<PathBuf> {
    activation
        .data
        .pointer("/spec/source/path")
        .and_then(|v| v.as_str())
        .map(PathBuf::from)
}

/// Extract the cluster name from an Activation CR.
fn cluster_name(activation: &DynamicObject) -> Option<String> {
    activation
        .data
        .pointer("/spec/cluster")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

/// Check if the Activation has spec.active == true.
fn is_active(activation: &DynamicObject) -> bool {
    activation
        .data
        .pointer("/spec/active")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
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

/// Main reconcile function called by the kube-rs controller runtime.
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

    // Only reconcile active activations
    if !is_active(&activation) {
        tracing::debug!(name, "Activation is not active, skipping");
        return Ok(Action::requeue(requeue_interval()));
    }

    // Ensure finalizer is set
    ensure_finalizer(&ctx.client, &ctx.activation_ar, name, &activation).await?;

    tracing::info!(name, cluster = %cluster, "Reconciling activation");

    // 1. Resolve source store path
    let path = source_path(&activation).ok_or(OperatorError::MissingSourcePath)?;
    tracing::info!(name, path = %path.display(), "Loading store graph");

    // 2. Load new store graph
    let (_new_graph, new_manifests) = load_and_stamp(&path)?;

    if new_manifests.is_empty() {
        tracing::warn!(name, "No manifests found in store graph");
        return Ok(Action::requeue(requeue_interval()));
    }

    tracing::info!(name, count = new_manifests.len(), "Loaded manifests");

    // 3. Determine if source changed since last successful apply
    let last_applied = activation
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(LAST_APPLIED_SOURCE))
        .map(|s| s.as_str());
    let source_changed = last_applied != Some(path.to_str().unwrap_or(""));

    // 4. Resolve previous state and detect changes
    let old_manifests = resolve_old_manifests(&activation).unwrap_or_default();
    let all_actions = kix::cluster::apply::detect_changes(&new_manifests, &old_manifests);

    let apply_count = all_actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Apply(_)))
        .count();
    let orphan_count = all_actions
        .iter()
        .filter(|a| matches!(a, ChangeAction::Orphan(_)))
        .count();

    // 5. Choose reconcile strategy based on whether source changed
    let (wave_actions, orphan_rids) = if source_changed {
        // Source changed: full reconcile with change detection + orphan pruning
        tracing::info!(
            name,
            apply = apply_count,
            orphans = orphan_count,
            unchanged = all_actions.len() - apply_count - orphan_count,
            "Source changed — full reconcile"
        );
        build_wave_actions(&all_actions, &new_manifests)?
    } else {
        // Source unchanged (requeue): drift-correction — apply manifests that
        // could have drifted. Skip CRDs (re-applying triggers API watch restarts)
        // and the Activation CR itself (re-applying triggers the controller watch).
        let skip_kinds: &[&str] = &["CustomResourceDefinition", "Activation"];
        let drift_actions: Vec<ChangeAction> = new_manifests
            .iter()
            .filter(|m| !skip_kinds.contains(&ResourceId::from_value(m).kind.as_str()))
            .map(|m| ChangeAction::Apply(m.clone()))
            .collect();

        if drift_actions.is_empty() {
            tracing::info!(name, "No driftable manifests to reconcile");
            return Ok(Action::requeue(requeue_interval()));
        }

        tracing::debug!(
            name,
            count = drift_actions.len(),
            "Source unchanged — drift-correction reconcile"
        );

        // Build waves from drift actions (no orphans in drift mode)
        let drift_manifests: Vec<Value> = new_manifests
            .iter()
            .filter(|m| !skip_kinds.contains(&ResourceId::from_value(m).kind.as_str()))
            .cloned()
            .collect();
        (
            build_wave_actions(&drift_actions, &drift_manifests)?.0,
            vec![],
        )
    };

    // Find activation identity hash for annotation merging
    let act_identity_hash = identity_hash(&activation);

    // 6. Run reconcile engine
    let mut discovery = fetch::discover_resources(&ctx.client)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;

    let config = ReconcileConfig {
        timeout: Duration::from_secs(300),
        on_error: OnErrorPolicy::Stop,
        prune: PrunePolicy::Delete,
    };

    let observer = OperatorObserver::new(name);

    // During drift-correction (source unchanged), don't pass activation_name
    // to the reconcile engine — otherwise it patches the Activation CR status
    // (begin_deploy, record_wave, finalize_deploy), which triggers the controller
    // watch and causes an infinite loop.
    let reconcile_act_name = if source_changed { Some(name) } else { None };

    let result = kix::cluster::reconcile::reconcile(
        &ctx.client,
        &mut discovery,
        &wave_actions,
        &orphan_rids,
        &old_manifests,
        &cluster,
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
                "Reconciliation complete"
            );

            // Only stamp annotation when source actually changed, to avoid
            // triggering the Activation watch on steady-state reconciles.
            if source_changed {
                let api: Api<DynamicObject> = Api::all_with(ctx.client.clone(), &ctx.activation_ar);
                let patch = serde_json::json!({
                    "metadata": {
                        "annotations": {
                            LAST_APPLIED_SOURCE: path.display().to_string()
                        }
                    }
                });
                if let Err(e) = api
                    .patch(name, &PatchParams::default(), &Patch::Merge(&patch))
                    .await
                {
                    tracing::warn!(name, error = %e, "Failed to stamp last-applied-source");
                }
            }

            Ok(Action::requeue(requeue_interval()))
        }
        Err(e) => {
            tracing::error!(name, error = %e, "Reconciliation failed");
            Err(OperatorError::ReconcileError(e.to_string()))
        }
    }
}

/// Resolve old manifests from the last successfully applied source path.
///
/// Reads the `kix.dev/last-applied-source` annotation from the Activation CR.
/// If present, loads manifests from that path so `detect_changes` can compare
/// identity hashes and skip unchanged resources.
fn resolve_old_manifests(activation: &DynamicObject) -> Option<Vec<Value>> {
    let last_path = activation
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(LAST_APPLIED_SOURCE))?;

    let path = Path::new(last_path);
    if !path.exists() {
        tracing::warn!(path = %last_path, "Last-applied source path no longer exists");
        return None;
    }

    let (_graph, manifests) = load_and_stamp(path).ok()?;
    Some(manifests)
}

/// Handle deletion of an Activation CR (finalizer cleanup).
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

    tracing::info!(name, "Handling Activation deletion — cleaning up resources");

    // Load the activation's store graph to know what to delete
    if let Some(path) = source_path(activation)
        && let Ok((_graph, manifests)) = load_and_stamp(&path)
    {
        // Delete all resources owned by this activation in reverse topo order
        let all_rids: Vec<ResourceId> = manifests
            .iter()
            .map(ResourceId::from_value)
            .filter(|rid| rid.kind != "Activation") // Don't delete the Activation itself
            .collect();

        // Skip kix's own CRDs — deleting them would break the operator
        let kix_crds: &[&str] = &["activations.kix.dev", "packageinstances.kix.dev"];
        let ordered: Vec<ResourceId> = compute_prune_order(&all_rids, &manifests)
            .into_iter()
            .filter(|rid| {
                !(rid.kind == "CustomResourceDefinition" && kix_crds.contains(&rid.name.as_str()))
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

/// Error policy: requeue with backoff on errors.
pub fn error_policy(
    _activation: Arc<DynamicObject>,
    error: &OperatorError,
    _ctx: Arc<Context>,
) -> Action {
    tracing::warn!(error = %error, "Error during reconciliation, requeueing");
    Action::requeue(ERROR_REQUEUE_INTERVAL)
}
