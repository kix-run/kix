//! Reconciliation engine — wave-based deploy loop extracted from the CLI.
//!
//! This module is the core deploy orchestration, usable by both `kix deploy`
//! (CLI, one-shot) and `kix-operator` (in-cluster, continuous). All output
//! is routed through a [`ReconcileObserver`] trait so consumers can handle
//! progress however they want (CLI prints, operator writes status, etc.).

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

use super::activation::{self, WaveRecord, WaveStatus};
use super::apply::{ApplyAction, ChangeAction};
use super::graph::ResourceGraph;
use super::readiness::{self, ReadinessResult};
use super::waves::compute_waves;
use super::{apply, fetch};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Events emitted during reconciliation.
///
/// Consumers implement [`ReconcileObserver`] to react to these — the CLI
/// prints colored output, the operator writes to Activation status, etc.
#[derive(Debug, Clone)]
pub enum ReconcileEvent {
    /// A wave was skipped entirely (already complete from a resumed deploy).
    WaveSkipped {
        wave_index: usize,
        count: usize,
        reason: &'static str,
    },
    /// A wave is about to be applied.
    WaveStart {
        wave_index: usize,
        apply_count: usize,
        total: usize,
    },
    /// A wave had no resources to apply (all unchanged).
    WaveUnchanged { wave_index: usize, count: usize },
    /// A single resource was applied successfully.
    ResourceApplied {
        rid: ResourceId,
        action: ApplyAction,
    },
    /// A single resource failed to apply.
    ResourceFailed { rid: ResourceId, error: String },
    /// Waiting for a resource to become ready.
    ReadinessWaiting { rid: ResourceId },
    /// A resource became ready.
    ReadinessReady { rid: ResourceId },
    /// A resource timed out waiting for readiness.
    ReadinessTimeout {
        rid: ResourceId,
        elapsed: Duration,
        message: String,
    },
    /// A resource readiness check failed.
    ReadinessFailed { rid: ResourceId, message: String },
    /// A wave completed (recorded on Activation CR).
    WaveComplete {
        wave_index: usize,
        record: WaveRecord,
    },
    /// CRDs were applied, re-running API discovery.
    CrdRediscovery,
    /// Starting to prune orphaned resources.
    PruneStart { count: usize },
    /// An orphan was not pruned (e.g., Namespace).
    PruneSkipped { rid: ResourceId, reason: String },
    /// An orphan was successfully pruned.
    PruneOk { rid: ResourceId },
    /// An orphan failed to prune.
    PruneFailed { rid: ResourceId, error: String },
    /// Activation lifecycle finalized.
    Finalized {
        activation: String,
        old: Option<String>,
    },
    /// Deploy stopped due to errors.
    Stopped { reason: String },
}

/// Observer for reconciliation progress.
///
/// The CLI implements this with colored output; the operator uses tracing.
pub trait ReconcileObserver: Send + Sync {
    fn on_event(&self, event: &ReconcileEvent);
}

/// A no-op observer that discards all events.
pub struct NullObserver;

impl ReconcileObserver for NullObserver {
    fn on_event(&self, _event: &ReconcileEvent) {}
}

/// What to do when a wave fails.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnErrorPolicy {
    /// Halt the deploy immediately.
    Stop,
    /// Log the error and continue with the next wave.
    Continue,
}

/// How to handle orphaned resources.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrunePolicy {
    /// Do not prune — skip entirely.
    Skip,
    /// Report orphans but do not delete them.
    WarnOnly,
    /// Delete orphaned resources.
    Delete,
}

/// Configuration for a reconcile run.
pub struct ReconcileConfig {
    /// Readiness timeout per resource.
    pub timeout: Duration,
    /// What to do on wave failure.
    pub on_error: OnErrorPolicy,
    /// How to handle orphans.
    pub prune: PrunePolicy,
}

/// Summary of a reconcile run.
#[derive(Debug, Clone, Default)]
pub struct ReconcileResult {
    pub created: usize,
    pub configured: usize,
    pub unchanged: usize,
    pub failed: usize,
    pub pruned: usize,
}

/// Errors from the reconcile engine.
#[derive(Error, Debug)]
pub enum ReconcileError {
    #[error("deploy stopped: wave {wave} had errors")]
    WaveFailed {
        wave: usize,
        partial_result: ReconcileResult,
    },

    #[error("deploy stopped: readiness timeout for {rid}")]
    ReadinessTimeout {
        rid: ResourceId,
        partial_result: ReconcileResult,
    },

    #[error("deploy stopped: readiness failed for {rid}: {message}")]
    ReadinessFailed {
        rid: ResourceId,
        message: String,
        partial_result: ReconcileResult,
    },

    #[error("API discovery failed: {0}")]
    DiscoveryFailed(String),

    #[error("activation lifecycle error: {0}")]
    ActivationError(String),
}

// ---------------------------------------------------------------------------
// Main reconcile function
// ---------------------------------------------------------------------------

/// Execute the wave-based reconciliation loop.
///
/// This is the core deploy engine. Both `kix deploy` (CLI) and `kix-operator`
/// call this function. All progress is routed through the `observer`.
///
/// # Arguments
///
/// * `client` — Kubernetes client
/// * `discovery` — API resource discovery (mutated if CRD waves trigger re-discovery)
/// * `wave_actions` — Pre-computed waves with change actions per resource
/// * `orphan_rids` — Resources to prune (from old activation, not in new)
/// * `old_manifests` — Old manifests for computing prune order
/// * `cluster_name` — Name of the cluster being deployed
/// * `activation_name` — Name of the Activation CR (if any)
/// * `activation_identity_hash` — Identity hash of the new Activation (for annotation merging)
/// * `config` — Reconcile behavior configuration
/// * `observer` — Progress event receiver
#[allow(clippy::too_many_arguments)]
pub async fn reconcile(
    client: &Client,
    discovery: &mut Vec<(ApiResource, Scope)>,
    wave_actions: &[Vec<ChangeAction>],
    orphan_rids: &[ResourceId],
    old_manifests: &[Value],
    cluster_name: &str,
    activation_name: Option<&str>,
    activation_identity_hash: Option<&str>,
    config: &ReconcileConfig,
    observer: &dyn ReconcileObserver,
) -> Result<ReconcileResult, ReconcileError> {
    let mut result = ReconcileResult::default();

    // Find Activation ApiResource for status updates
    let activation_ar = activation::find_activation_ar(discovery).map(|(ar, _)| ar.clone());

    // Determine resume point (if a previous deploy crashed mid-wave)
    let resume_from = if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
        match activation::resume_point(client, ar, act_name).await {
            Ok(Some(idx)) if idx > 0 => idx,
            _ => 0,
        }
    } else {
        0
    };

    // Record deploy start on the Activation CR (may 404 if first deploy — harmless)
    if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name)
        && let Err(e) = activation::begin_deploy(client, ar, act_name, wave_actions.len()).await
    {
        tracing::debug!("activation not yet on cluster (first deploy): {e}");
    }

    // Accumulated wave records — passed to record_waves each time to avoid
    // the GET-before-PATCH round-trip that the old record_wave did.
    let mut accumulated_waves: Vec<WaveRecord> = Vec::new();

    // Apply waves
    for (wave_idx, actions) in wave_actions.iter().enumerate() {
        // Skip waves completed in a previous (crashed) deploy
        if wave_idx < resume_from {
            let count = actions.len();
            observer.on_event(&ReconcileEvent::WaveSkipped {
                wave_index: wave_idx,
                count,
                reason: "already complete",
            });
            result.unchanged += count;
            accumulated_waves.push(WaveRecord {
                wave_index: wave_idx,
                status: WaveStatus::Complete,
                resource_count: count,
                applied: 0,
                failed: 0,
            });
            continue;
        }

        let apply_count = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .count();

        if apply_count == 0 {
            observer.on_event(&ReconcileEvent::WaveUnchanged {
                wave_index: wave_idx,
                count: actions.len(),
            });
            result.unchanged += actions.len();

            let record = WaveRecord {
                wave_index: wave_idx,
                status: WaveStatus::Complete,
                resource_count: actions.len(),
                applied: 0,
                failed: 0,
            };
            accumulated_waves.push(record);
            if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
                let _ = activation::record_waves(client, ar, act_name, &accumulated_waves).await;
            }
            continue;
        }

        observer.on_event(&ReconcileEvent::WaveStart {
            wave_index: wave_idx,
            apply_count,
            total: actions.len(),
        });

        let results =
            apply::apply_wave(client, discovery, actions, false, activation_identity_hash).await;

        let mut wave_failed = false;
        for (rid, res) in &results {
            match res {
                Ok(apply_result) => {
                    match apply_result.action {
                        ApplyAction::Created => result.created += 1,
                        ApplyAction::Configured => result.configured += 1,
                        ApplyAction::Unchanged | ApplyAction::Skipped => result.unchanged += 1,
                    }
                    observer.on_event(&ReconcileEvent::ResourceApplied {
                        rid: rid.clone(),
                        action: apply_result.action.clone(),
                    });
                }
                Err(e) => {
                    result.failed += 1;
                    wave_failed = true;
                    observer.on_event(&ReconcileEvent::ResourceFailed {
                        rid: rid.clone(),
                        error: e.to_string(),
                    });
                }
            }
        }

        // Check failure mode
        if wave_failed && config.on_error == OnErrorPolicy::Stop {
            observer.on_event(&ReconcileEvent::Stopped {
                reason: "wave had errors (on_error=stop)".into(),
            });
            return Err(ReconcileError::WaveFailed {
                wave: wave_idx,
                partial_result: result,
            });
        }

        // Readiness polling for this wave
        if !wave_failed || config.on_error == OnErrorPolicy::Continue {
            for action in actions {
                if let ChangeAction::Apply(manifest) = action {
                    let rid = ResourceId::from_value(manifest);

                    // Only check readiness for resources that were actually applied
                    if !results.iter().any(|(r, res)| *r == rid && res.is_ok()) {
                        continue;
                    }

                    if readiness::is_immediate_kind(&rid.kind) {
                        continue;
                    }

                    let ar_scope = discovery.iter().find(|(ar, _)| ar.kind == rid.kind);

                    if let Some((ar, scope)) = ar_scope {
                        let ns = if rid.namespace == CLUSTER_SCOPED {
                            None
                        } else {
                            Some(rid.namespace.as_str())
                        };

                        observer.on_event(&ReconcileEvent::ReadinessWaiting { rid: rid.clone() });

                        match readiness::wait_for_ready(
                            client,
                            ar,
                            scope,
                            &rid.name,
                            ns,
                            &rid.kind,
                            config.timeout,
                        )
                        .await
                        {
                            Ok(ReadinessResult::Ready) => {
                                observer
                                    .on_event(&ReconcileEvent::ReadinessReady { rid: rid.clone() });
                            }
                            Ok(ReadinessResult::TimedOut { elapsed, message }) => {
                                observer.on_event(&ReconcileEvent::ReadinessTimeout {
                                    rid: rid.clone(),
                                    elapsed,
                                    message: message.clone(),
                                });
                                if config.on_error == OnErrorPolicy::Stop {
                                    return Err(ReconcileError::ReadinessTimeout {
                                        rid,
                                        partial_result: result,
                                    });
                                }
                            }
                            Ok(ReadinessResult::Failed(msg)) => {
                                result.failed += 1;
                                observer.on_event(&ReconcileEvent::ReadinessFailed {
                                    rid: rid.clone(),
                                    message: msg.clone(),
                                });
                                if config.on_error == OnErrorPolicy::Stop {
                                    return Err(ReconcileError::ReadinessFailed {
                                        rid,
                                        message: msg,
                                        partial_result: result,
                                    });
                                }
                            }
                            Err(e) => {
                                tracing::warn!("readiness check error for {rid}: {e}");
                            }
                        }
                    }
                }
            }
        }

        // Re-discover API resources if this wave created CRDs
        let wave_had_crds = actions.iter().any(|a| {
            if let ChangeAction::Apply(m) = a {
                ResourceId::from_value(m).kind == "CustomResourceDefinition"
            } else {
                false
            }
        });
        if wave_had_crds {
            observer.on_event(&ReconcileEvent::CrdRediscovery);
            if let Ok(new_disc) = fetch::discover_resources(client).await {
                *discovery = new_disc;
            }
        }

        // Record wave progress on the Activation CR
        let wave_applied = results
            .iter()
            .filter(|(_, r)| {
                r.as_ref().is_ok_and(|r| {
                    matches!(r.action, ApplyAction::Created | ApplyAction::Configured)
                })
            })
            .count();
        let wave_failed_count = results.iter().filter(|(_, r)| r.is_err()).count();
        let status = if wave_failed {
            WaveStatus::Failed
        } else {
            WaveStatus::Complete
        };
        let record = WaveRecord {
            wave_index: wave_idx,
            status: status.clone(),
            resource_count: actions.len(),
            applied: wave_applied,
            failed: wave_failed_count,
        };
        observer.on_event(&ReconcileEvent::WaveComplete {
            wave_index: wave_idx,
            record: record.clone(),
        });
        accumulated_waves.push(record);
        if let (Some(ar), Some(act_name)) = (&activation_ar, activation_name) {
            let _ = activation::record_waves(client, ar, act_name, &accumulated_waves).await;
        }
    }

    // Prune orphans (after all apply waves)
    if !orphan_rids.is_empty() && config.prune != PrunePolicy::Skip {
        let ordered_orphans = compute_prune_order(orphan_rids, old_manifests);

        observer.on_event(&ReconcileEvent::PruneStart {
            count: ordered_orphans.len(),
        });

        if config.prune == PrunePolicy::WarnOnly {
            for rid in &ordered_orphans {
                observer.on_event(&ReconcileEvent::PruneSkipped {
                    rid: rid.clone(),
                    reason: "prune policy is warn-only".into(),
                });
            }
        } else {
            let ar_by_kind: HashMap<String, (&ApiResource, Scope)> = discovery
                .iter()
                .map(|(ar, scope)| (ar.kind.clone(), (ar, scope.clone())))
                .collect();

            for rid in &ordered_orphans {
                if rid.kind == "Namespace" {
                    observer.on_event(&ReconcileEvent::PruneSkipped {
                        rid: rid.clone(),
                        reason: "Namespace pruning skipped — delete manually".into(),
                    });
                    continue;
                }

                let Some(&(ar, ref scope)) = ar_by_kind.get(&rid.kind) else {
                    observer.on_event(&ReconcileEvent::PruneFailed {
                        rid: rid.clone(),
                        error: "unknown kind, cannot prune".into(),
                    });
                    result.failed += 1;
                    continue;
                };

                let api: Api<DynamicObject> = match scope {
                    Scope::Namespaced => {
                        let ns = if rid.namespace == CLUSTER_SCOPED {
                            "default"
                        } else {
                            &rid.namespace
                        };
                        Api::namespaced_with(client.clone(), ns, ar)
                    }
                    Scope::Cluster => Api::all_with(client.clone(), ar),
                };

                match api
                    .delete(&rid.name, &kube::api::DeleteParams::default())
                    .await
                {
                    Ok(_) => {
                        result.pruned += 1;
                        observer.on_event(&ReconcileEvent::PruneOk { rid: rid.clone() });
                    }
                    Err(e) => {
                        result.failed += 1;
                        observer.on_event(&ReconcileEvent::PruneFailed {
                            rid: rid.clone(),
                            error: e.to_string(),
                        });
                    }
                }
            }
        }
    }

    // Finalize activation lifecycle (mark old as Superseded, new as Active).
    // Only finalize when resources were actually changed — calling finalize_deploy
    // unconditionally creates an infinite reconcile loop because it always sets a new
    // kix.dev/deployed-at timestamp, which bumps metadata.generation.
    let actually_changed = result.created > 0 || result.configured > 0 || result.pruned > 0;
    if actually_changed
        && result.failed == 0
        && let Some(act_name) = activation_name
        && let Some((ar, _)) = activation::find_activation_ar(discovery)
    {
        let old_activation = activation::find_active(client, ar, cluster_name)
            .await
            .ok()
            .flatten()
            .filter(|old| old.name != act_name);

        if let Err(e) =
            activation::finalize_deploy(client, ar, cluster_name, act_name, old_activation.as_ref())
                .await
        {
            tracing::warn!("failed to finalize activation lifecycle: {e}");
        } else {
            observer.on_event(&ReconcileEvent::Finalized {
                activation: act_name.to_string(),
                old: old_activation.map(|a| a.name),
            });
        }
    }

    Ok(result)
}

// ---------------------------------------------------------------------------
// Prune ordering
// ---------------------------------------------------------------------------

/// Compute prune order: reverse topological order from old graph (dependents first).
pub fn compute_prune_order(orphan_rids: &[ResourceId], old_manifests: &[Value]) -> Vec<ResourceId> {
    let orphan_set: HashSet<String> = orphan_rids
        .iter()
        .map(|rid| format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
        .collect();

    let orphan_manifests: Vec<Value> = old_manifests
        .iter()
        .filter(|m| {
            let rid = ResourceId::from_value(m);
            orphan_set.contains(&format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
        })
        .cloned()
        .collect();

    match ResourceGraph::from_manifests(&orphan_manifests) {
        Ok(graph) => {
            let waves = compute_waves(&graph);
            // Reverse: delete dependents (later waves) first
            let mut ordered: Vec<ResourceId> = Vec::new();
            for wave in waves.into_iter().rev() {
                for idx in wave {
                    ordered.push(graph.graph[idx].id.clone());
                }
            }
            ordered
        }
        Err(_) => {
            // If graph construction fails, fall back to unordered
            orphan_rids.to_vec()
        }
    }
}
