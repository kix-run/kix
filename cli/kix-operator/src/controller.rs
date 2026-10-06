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

use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::ApiResource,
    runtime::controller::Action,
};
use serde_json::Value;
use thiserror::Error;

use kix::cluster::activation::{
    self, PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_SUPERSEDED,
};
use kix::cluster::apply::ChangeAction;
use kix::cluster::fetch;
use kix::cluster::graph::ResourceGraph;
use kix::cluster::ops::{ClusterOps, KubeOps, KubeOpsConfig};
use kix::cluster::prune_guard::{PruneGuard, Pruned};
use kix::cluster::scheduler::{self, DeployPlan, OnErrorPolicy, PrunePolicy, SchedulerConfig};
use kix::cluster::stream::DeployObserver;
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::ResourceId;

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

/// The Kix cluster an Activation CR belongs to: its `kix.run/cluster`
/// label, which the compiler stamps on every record, else `spec.cluster`,
/// which a record built by Nix lacks until the CLI finalizes it.
fn cluster_name(activation: &DynamicObject) -> Option<String> {
    activation
        .metadata
        .labels
        .as_ref()
        .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
        .or_else(|| {
            activation
                .data
                .pointer("/spec/cluster")
                .and_then(|v| v.as_str())
        })
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Extract identity hash from annotations.
fn identity_hash(activation: &DynamicObject) -> Option<String> {
    activation
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
        .map(str::to_string)
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

/// Compare desired manifests with this cluster's live objects by identity
/// hash, keeping out of the orphans every object another Kix cluster's
/// current build still contains.
fn live_changes(
    desired: &[Value],
    live: &[DynamicObject],
    tenancy: &activation::Tenancy,
) -> (Vec<ChangeAction>, Vec<fetch::SharedOrphan>) {
    let actions = kix::cluster::apply::detect_changes_live(desired, live);
    let orphans: Vec<ResourceId> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Orphan(rid) => Some(rid.clone()),
            _ => None,
        })
        .collect();
    let (_, shared) = fetch::split_shared_orphans(orphans, live, tenancy);
    let actions = actions
        .into_iter()
        .filter(|a| match a {
            ChangeAction::Orphan(rid) => !shared.iter().any(|s| &s.rid == rid),
            _ => true,
        })
        .collect();
    (actions, shared)
}

/// Build a streaming [`DeployPlan`] + orphan list from change detection.
fn build_deploy_plan(
    all_actions: &[ChangeAction],
    new_manifests: &[Value],
) -> Result<(DeployPlan, Vec<ResourceId>), OperatorError> {
    let resource_graph = ResourceGraph::from_manifests(new_manifests)
        .map_err(|e| OperatorError::GraphError(e.to_string()))?;
    let plan = DeployPlan::from_graph_and_changes(&resource_graph, all_actions)
        .map_err(|e| OperatorError::GraphError(e.to_string()))?;
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
    Ok((plan, orphan_rids))
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
    let own_cluster = cluster_name(&activation).unwrap_or_default();
    let cluster = if own_cluster.is_empty() {
        name.to_string()
    } else {
        own_cluster.clone()
    };

    // Handle deletion (finalizer)
    if activation.metadata.deletion_timestamp.is_some() {
        return handle_delete(&activation, &ctx, name, &own_cluster).await;
    }

    let phase = activation::read_phase(&activation);

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
        s if s.is_empty() || s == activation::PHASE_QUEUED => {
            if source_path(&activation).is_none() {
                tracing::debug!(name, "record has no spec.source; not ours to drive");
                return Ok(Action::await_change());
            }
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
            return run_reconcile(&activation, &ctx, name, &own_cluster, true).await;
        }

        // Active and Degraded records run drift detection on requeue. Degraded means the
        // last deploy completed with some failures; the CR is still the
        // current intended state and we want drift correction to keep trying.
        s if s == PHASE_ACTIVE || s == PHASE_DEGRADED => {
            // Yield to a queued Activation so it can perform the transition.
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
            return run_reconcile(&activation, &ctx, name, &own_cluster, false).await;
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
            ensure_finalizer(&ctx.client, &ctx.activation_ar, name, &activation).await?;
            return run_reconcile(&activation, &ctx, name, &own_cluster, true).await;
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
/// If `manage_lifecycle` is true, passes `activation_name` to the reconcile engine
/// so it runs begin_deploy/record_waves/finalize_deploy. Used for new deployments.
/// If false, run drift correction without lifecycle changes.
///
/// `cluster` is the record's Kix cluster, empty when it names none.
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

    // 4. Fetch live kix-managed resources from the cluster
    let discovery = fetch::discover_resources(&ctx.client)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;

    // Only this Kix cluster's objects: every other Kix cluster's objects are
    // absent from this build and would otherwise be pruned as orphans.
    let sweep = fetch::sweep_managed(&ctx.client, &discovery, fetch::SweepScope::Cluster(cluster))
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;
    let tenancy = sweep.tenancy.clone();
    for (owner, count) in &sweep.foreign {
        tracing::debug!(name, owner = %owner, count, "left out objects of another Kix cluster");
    }
    if !sweep.unattributed.is_empty() {
        tracing::info!(
            name,
            count = sweep.unattributed.len(),
            "left out Kix objects that name no Activation record; another Kix cluster deploys here",
        );
    }
    let live_resources = sweep.managed;

    // 5. Compare desired vs live by identity-hash
    let (all_actions, shared) = live_changes(&managed_manifests, &live_resources, &tenancy);
    for s in &shared {
        tracing::info!(name, resource = %s.rid, clusters = ?s.clusters, "prune: {}", s.describe());
    }

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

    // 6. Build the streaming plan.
    let (plan, orphan_rids) = build_deploy_plan(&all_actions, &managed_manifests)?;

    let act_identity_hash = identity_hash(activation);

    // 7. Run the DAG-streaming scheduler.
    //
    // TODO(operator-cancel): wire this token to a per-Activation supervisor
    // so a newer Activation can cancel the in-flight loop. This caller does
    // not currently trigger cancellation.
    let config = SchedulerConfig {
        timeout: Duration::from_secs(300),
        on_error: OnErrorPolicy::Stop,
        prune: PrunePolicy::Delete,
        cancel: kix::cluster::cancel::CancelToken::new(),
        dry_run: false,
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
    let reconcile_act_name = if manage_lifecycle { Some(name) } else { None };
    let old_manifest_values: Vec<Value> =
        live_resources.iter().map(|obj| obj.data.clone()).collect();
    let discovery_shared = Arc::new(tokio::sync::RwLock::new(discovery));
    let ops: Arc<dyn ClusterOps> = Arc::new(KubeOps::new(
        ctx.client.clone(),
        discovery_shared,
        KubeOpsConfig {
            cluster_name: cluster.to_string(),
            activation_name: reconcile_act_name.map(str::to_string),
            activation_identity_hash: act_identity_hash.clone(),
            // The operator reconciles a build somebody else made, from inside
            // the cluster, with no source tree to read provenance from. The
            // receipt the deploy wrote stays as it is.
            receipt: None,
            // The operator runs unattended; surface conflicts in Activation
            // status rather than silently clobbering fields owned by other
            // controllers.
            force_conflicts: false,
            dry_run: false,
            // The operator created the record itself and owns `spec.source`;
            // it has no stamped manifest to re-apply and needs none.
            activation_manifest: None,
            // The operator plans against live objects by design, so a failed
            // deploy's leftovers are already visible to its next reconcile.
            // Nothing to fold, nothing to supersede.
            consumed_failed: Vec::new(),
            // Its orphans are live objects the next reconcile finds again,
            // so there are no builds to record.
            kept_orphans: Default::default(),
            // Its model is resume-on-requeue: a reconcile that returns early
            // is retried, so marking the record Failed would fight it.
            mark_failed_on_abort: false,
            sops: Default::default(),
        },
    ));

    let result = scheduler::run_deploy(
        ops,
        plan,
        &orphan_rids,
        &old_manifest_values,
        &config,
        observer,
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

            delete_closure(&ctx.client, cluster, name, &ordered).await?;
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

/// Delete a deleted record's closure in `ordered` order through
/// [`PruneGuard`]: an object another Kix cluster's current build contains,
/// such as a shared ClusterRole, stays. `cluster` is the record's Kix
/// cluster; the record is still listed while its finalizer holds it, so its
/// own hash counts as this cluster's.
async fn delete_closure(
    client: &Client,
    cluster: &str,
    name: &str,
    ordered: &[ResourceId],
) -> Result<(), OperatorError> {
    let discovery = fetch::discover_resources(client)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;
    let guard = PruneGuard::new(client.clone(), &discovery, cluster);
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

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::activation::Tenancy;
    use serde_json::json;

    fn annotated(kind: &str, name: &str, hash: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "d",
                "annotations": {
                    (keys::IDENTITY_HASH): hash,
                    (keys::ACTIVATIONS): activations,
                },
            },
        })
    }

    fn live(kind: &str, name: &str, hash: &str, activations: &str) -> DynamicObject {
        serde_json::from_value(annotated(kind, name, hash, activations)).unwrap()
    }

    fn record(cluster: &str, hash: &str) -> DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": cluster,
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        }))
        .unwrap()
    }

    fn orphans(actions: &[ChangeAction]) -> Vec<String> {
        let mut v: Vec<String> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.name.clone()),
                _ => None,
            })
            .collect();
        v.sort();
        v
    }

    /// The reconcile of Kix cluster `a` in a Kubernetes cluster that also
    /// runs `b`: it prunes its own stale object, never `b`'s, and keeps the
    /// ClusterRole both deployed after `a` dropped it.
    #[test]
    fn reconcile_prunes_only_this_clusters_orphans() {
        let records = [record("a", "a2"), record("b", "b1")];
        let objects = vec![
            live("ConfigMap", "a-web", "h-web", "a2"),
            live("ConfigMap", "a-stale", "h-stale", "a2"),
            live("ConfigMap", "b-web", "h-b", "b1"),
            live("ClusterRole", "shared", "h-shared", "a2,b1"),
        ];
        let desired = [annotated("ConfigMap", "a-web", "h-web", "")];

        let tenancy = Tenancy::from_records(&records, "a");
        let sweep = fetch::scope_sweep(
            fetch::partition_sweep(objects.clone()),
            fetch::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        let (actions, shared) = live_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["a-stale"]);
        assert_eq!(shared.len(), 1);
        assert_eq!(shared[0].rid.name, "shared");

        // `b`'s reconcile, with `b`'s build unchanged, prunes nothing of `a`.
        let tenancy = Tenancy::from_records(&records, "b");
        let sweep = fetch::scope_sweep(
            fetch::partition_sweep(objects),
            fetch::SweepScope::Cluster("b"),
            tenancy.clone(),
        );
        let desired = [
            annotated("ConfigMap", "b-web", "h-b", ""),
            annotated("ClusterRole", "shared", "h-shared", ""),
        ];
        let (actions, shared) = live_changes(&desired, &sweep.managed, &tenancy);
        assert!(orphans(&actions).is_empty());
        assert!(shared.is_empty());
    }

    /// One Kix cluster: every stale object is an orphan, as before scoping.
    #[test]
    fn reconcile_on_a_single_cluster_is_unchanged() {
        let tenancy = Tenancy::from_records(&[record("a", "a2")], "a");
        let objects = vec![
            live("ConfigMap", "a-web", "h-web", "a2"),
            live("ConfigMap", "leftover", "h-left", "retired"),
        ];
        let sweep = fetch::scope_sweep(
            fetch::partition_sweep(objects),
            fetch::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        let desired = [annotated("ConfigMap", "a-web", "h-web", "")];
        let (actions, _) = live_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["leftover"]);
    }

    /// The operator reads a record's cluster from its label before
    /// `spec.cluster`, and a record naming neither has no cluster.
    #[test]
    fn a_records_cluster_comes_from_its_label() {
        let mut rec = record("a", "a1");
        rec.data = json!({ "spec": { "cluster": "stale" } });
        assert_eq!(cluster_name(&rec).as_deref(), Some("a"));
        rec.metadata.labels = None;
        assert_eq!(cluster_name(&rec).as_deref(), Some("stale"));
        rec.data = json!({});
        assert_eq!(cluster_name(&rec), None);
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
        delete_closure(&api.client(), "b", "b", &[rid("b-only"), rid("shared")])
            .await
            .unwrap();
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }
}
