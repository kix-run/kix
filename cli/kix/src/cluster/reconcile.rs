//! Reconciliation engine — wave-based deploy loop extracted from the CLI.
//!
//! This module is the core deploy orchestration, usable by both `kix deploy`
//! (CLI, one-shot) and `kix-operator` (in-cluster, continuous). All output
//! is routed through a [`ReconcileObserver`] trait so consumers can handle
//! progress however they want (CLI prints, operator writes status, etc.).

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use futures::stream::{self, StreamExt};

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
use super::cancel::CancelToken;
use super::graph::ResourceGraph;
use super::readiness::{self, ImportTarget, ReadinessResult};
use super::secrets;
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
    ///
    /// When `import_target` is `Some`, the resource is an import marker
    /// (`kix.dev/mode: import`). Observers should render imports with a
    /// discrete visual cue referencing the target the marker describes
    /// rather than the marker's own ResourceId.
    ResourceApplied {
        rid: ResourceId,
        action: ApplyAction,
        import_target: Option<ImportTarget>,
    },
    /// A single resource failed to apply.
    ResourceFailed { rid: ResourceId, error: String },
    /// Waiting for a resource to become ready.
    ReadinessWaiting {
        rid: ResourceId,
        import_target: Option<ImportTarget>,
    },
    /// Periodic status update while polling a resource for readiness.
    ///
    /// Carries a human-readable snapshot of the resource's current state
    /// (e.g. "3/5 ready, 5/5 updated") so consumers can show live progress
    /// without duplicating the readiness-check logic.
    ReadinessProgress {
        rid: ResourceId,
        import_target: Option<ImportTarget>,
        message: String,
    },
    /// A resource became ready.
    ReadinessReady {
        rid: ResourceId,
        import_target: Option<ImportTarget>,
    },
    /// A resource timed out waiting for readiness.
    ReadinessTimeout {
        rid: ResourceId,
        elapsed: Duration,
        message: String,
        import_target: Option<ImportTarget>,
    },
    /// A resource readiness check failed.
    ///
    /// `missing_keys` is populated when the failure is an import mismatch
    /// (`ReadinessResult::ImportMismatch`) — observers can render the exact
    /// missing Secret keys as a structured line under the marker instead of
    /// parsing the message string.
    ReadinessFailed {
        rid: ResourceId,
        message: String,
        import_target: Option<ImportTarget>,
        missing_keys: Vec<String>,
    },
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
    /// A secret was hydrated (SOPS decrypted + injected).
    SecretHydrated { rid: ResourceId, keys: usize },
    /// Secret hydration failed.
    SecretHydrationFailed { rid: ResourceId, error: String },
    /// An apply hit an immutable-field conflict but the resource was in the
    /// pre-authorized orphan set, so reconcile deleted the live copy and
    /// re-applied it in place. Rendered as a distinct, destructive-but-ok
    /// line in the CLI.
    ResourceRecreated {
        rid: ResourceId,
        /// The immutable-field conflict message from the API server.
        reason: String,
    },
    /// Deploy stopped due to errors.
    Stopped { reason: String },
    /// Deploy was cancelled externally (e.g. operator saw a newer Activation).
    Cancelled { at: &'static str },
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
    /// Take ownership of fields owned by other field managers (SSA force).
    /// Default false — conflicts surface as actionable errors instead of silent clobber.
    pub force_conflicts: bool,
    /// Cancellation flag. The CLI passes a never-cancelled token; the
    /// operator passes one that flips when a newer Activation supersedes
    /// the in-flight deploy. Checked at wave boundaries and between
    /// readiness polls.
    pub cancel: CancelToken,
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

    #[error("deploy cancelled")]
    Cancelled { partial_result: ReconcileResult },
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

    // Pre-authorized delete set: the planner populates this with orphans that
    // the deploy is allowed to remove. 422-immutable-conflict recovery during
    // apply is gated on membership in this set — apply is NEVER allowed to
    // delete a resource the caller didn't explicitly authorize. Recovered
    // rids are removed from the prune set so prune doesn't delete them a
    // second time after we re-created them in-place.
    let orphan_set: HashSet<ResourceId> = orphan_rids.iter().cloned().collect();
    let mut consumed_orphans: HashSet<ResourceId> = HashSet::new();

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
        // Cancellation point at each wave boundary. Between waves is the
        // cheapest, cleanest place to bail — no half-applied wave state.
        if config.cancel.is_cancelled() {
            observer.on_event(&ReconcileEvent::Cancelled {
                at: "wave-boundary",
            });
            return Err(ReconcileError::Cancelled {
                partial_result: result,
            });
        }

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

        // Hydrate SOPS-encrypted secrets before applying the wave.
        // Failed hydration drops the action from the wave entirely — applying
        // a Secret with empty data would silently corrupt cluster state and
        // SSA would happily succeed. Tracked failures are surfaced as
        // ResourceFailed below so they count against wave_failed.
        let mut hydration_failures: Vec<(ResourceId, String)> = Vec::new();
        let mut hydrated_actions: Vec<ChangeAction> = Vec::with_capacity(actions.len());
        for action in actions {
            match action {
                ChangeAction::Apply(manifest) if secrets::needs_hydration(manifest) => {
                    let mut single = [manifest.clone()];
                    match secrets::hydrate_secrets(&mut single) {
                        Ok(results) => {
                            for hr in &results {
                                observer.on_event(&ReconcileEvent::SecretHydrated {
                                    rid: hr.rid.clone(),
                                    keys: hr.keys_injected,
                                });
                            }
                            hydrated_actions
                                .push(ChangeAction::Apply(single.into_iter().next().unwrap()));
                        }
                        Err(e) => {
                            let rid = ResourceId::from_value(manifest);
                            observer.on_event(&ReconcileEvent::SecretHydrationFailed {
                                rid: rid.clone(),
                                error: e.to_string(),
                            });
                            hydration_failures.push((rid, e.to_string()));
                        }
                    }
                }
                other => hydrated_actions.push(other.clone()),
            }
        }

        let mut results = apply::apply_wave(
            client,
            discovery,
            &hydrated_actions,
            false,
            activation_identity_hash,
            config.force_conflicts,
        )
        .await;

        // Immutable-conflict recovery.
        //
        // When SSA returns 422 "field is immutable" on a resource (Job spec
        // change, StatefulSet selector change, Service clusterIP, etc.), we
        // need to delete the live copy and re-create it. Apply is NOT
        // generally allowed to delete — that's prune's job. We permit it
        // here ONLY when the rid is in `orphan_set`, i.e. the caller has
        // pre-authorized destruction of this resource as part of this
        // deploy. Recovered rids are tracked in `consumed_orphans` so the
        // prune phase doesn't delete them a second time.
        //
        // Collect candidate indices first so we don't borrow `results`
        // immutably and mutably at once during the recovery loop.
        let immutable_conflict_indices: Vec<usize> = results
            .iter()
            .enumerate()
            .filter_map(|(i, (_, res))| {
                matches!(res, Err(apply::ApplyError::ImmutableConflict { .. })).then_some(i)
            })
            .collect();
        for i in immutable_conflict_indices {
            let rid = results[i].0.clone();
            if !orphan_set.contains(&rid) {
                // Not pre-authorized. The actionable error message from
                // ApplyError::ImmutableConflict will surface downstream,
                // telling the user to add this rid to the prune set.
                tracing::warn!(
                    resource = %rid,
                    "immutable-field conflict on resource NOT in orphan set; leaving as failed"
                );
                continue;
            }
            let reason = match &results[i].1 {
                Err(apply::ApplyError::ImmutableConflict { source, .. }) => source.to_string(),
                _ => String::new(),
            };
            let Some(manifest) = hydrated_actions.iter().find_map(|a| match a {
                ChangeAction::Apply(m) if ResourceId::from_value(m) == rid => Some(m),
                _ => None,
            }) else {
                continue;
            };
            match recreate_in_place(
                client,
                discovery,
                &rid,
                manifest,
                config.force_conflicts,
                activation_identity_hash,
            )
            .await
            {
                Ok(apply_result) => {
                    consumed_orphans.insert(rid.clone());
                    observer.on_event(&ReconcileEvent::ResourceRecreated {
                        rid: rid.clone(),
                        reason,
                    });
                    results[i] = (rid, Ok(apply_result));
                }
                Err(e) => {
                    tracing::warn!(
                        resource = %rid,
                        error = %e,
                        "recreate-in-place failed; resource remains in ImmutableConflict state"
                    );
                    // Leave original error in results; downstream reports failed.
                }
            }
        }

        // Index hydrated action manifests by ResourceId for import-target
        // lookup during event emission. We clone Values because the closure
        // borrow would otherwise conflict with the later readiness loop.
        let manifest_by_rid: HashMap<ResourceId, &Value> = hydrated_actions
            .iter()
            .filter_map(|action| match action {
                ChangeAction::Apply(m) => Some((ResourceId::from_value(m), m)),
                _ => None,
            })
            .collect();

        // Surface hydration failures as wave failures before processing apply
        // results, so they're indistinguishable downstream from a 422 apply error.
        let mut wave_failed = !hydration_failures.is_empty();
        let mut wave_apply_count = 0usize;
        let mut wave_fail_count = hydration_failures.len();
        for (rid, err) in &hydration_failures {
            result.failed += 1;
            observer.on_event(&ReconcileEvent::ResourceFailed {
                rid: rid.clone(),
                error: format!("secret hydration failed: {err}"),
            });
        }

        // Index successful apply outcomes for O(1) readiness gating and for
        // bucket-demotion when readiness later fails on an applied resource.
        let mut apply_outcomes: HashMap<ResourceId, ApplyAction> = HashMap::new();
        for (rid, res) in &results {
            match res {
                Ok(apply_result) => {
                    match apply_result.action {
                        ApplyAction::Created => {
                            result.created += 1;
                            wave_apply_count += 1;
                        }
                        ApplyAction::Configured => {
                            result.configured += 1;
                            wave_apply_count += 1;
                        }
                        ApplyAction::Unchanged | ApplyAction::Skipped => result.unchanged += 1,
                    }
                    apply_outcomes.insert(rid.clone(), apply_result.action.clone());
                    let import_target = manifest_by_rid
                        .get(rid)
                        .and_then(|m| readiness::import_target_from_manifest(m));
                    observer.on_event(&ReconcileEvent::ResourceApplied {
                        rid: rid.clone(),
                        action: apply_result.action.clone(),
                        import_target,
                    });
                }
                Err(e) => {
                    result.failed += 1;
                    wave_fail_count += 1;
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

        // Readiness polling for this wave.
        //
        // Every applied resource in the wave is polled concurrently (bounded
        // by READINESS_CONCURRENCY). This is safe because `compute_waves`
        // already serialized every cross-resource dependency into the wave
        // structure — resources inside a single wave are, by construction,
        // independent of one another, so their readiness checks can run in
        // parallel without ordering hazards.
        //
        // Iterate hydrated_actions (not the pre-hydration `actions`) so we
        // never poll a resource that was dropped due to hydration failure.
        let mut wave_had_crd_import = false;
        if !wave_failed || config.on_error == OnErrorPolicy::Continue {
            // Early cancellation check — cheaper to bail here than to spin
            // up the futures machinery.
            if config.cancel.is_cancelled() {
                observer.on_event(&ReconcileEvent::Cancelled {
                    at: "readiness-loop",
                });
                return Err(ReconcileError::Cancelled {
                    partial_result: result,
                });
            }

            // Build the list of resources to poll. Filter out:
            //   - non-Apply actions
            //   - resources whose apply failed (no entry in apply_outcomes)
            //   - immediate kinds with no import target (existence == ready)
            //   - non-import resources whose kind isn't in discovery (a
            //     later wave will install the CRD; we can't poll until then)
            struct Pending {
                rid: ResourceId,
                import_target: Option<ImportTarget>,
            }
            let mut to_poll: Vec<Pending> = Vec::new();
            for action in &hydrated_actions {
                let ChangeAction::Apply(manifest) = action else {
                    continue;
                };
                let rid = ResourceId::from_value(manifest);
                if !apply_outcomes.contains_key(&rid) {
                    continue;
                }
                let import_target = readiness::import_target_from_manifest(manifest);
                if import_target
                    .as_ref()
                    .is_some_and(|t| t.kind == "CustomResourceDefinition")
                {
                    wave_had_crd_import = true;
                }
                if import_target.is_none() && readiness::is_immediate_kind(&rid.kind) {
                    continue;
                }
                if import_target.is_none() && !discovery.iter().any(|(ar, _)| ar.kind == rid.kind) {
                    tracing::warn!(
                        resource = %rid,
                        "skipping readiness: kind not in discovery cache \
                         (CRD likely installed in a later wave)"
                    );
                    continue;
                }
                to_poll.push(Pending { rid, import_target });
            }

            // Eagerly emit ReadinessWaiting for every resource. This is what
            // lets the TUI surface the full in-flight list at once instead
            // of one row lighting up at a time — and for non-TUI output it
            // matches the line-oriented CliObserver's behavior.
            for p in &to_poll {
                observer.on_event(&ReconcileEvent::ReadinessWaiting {
                    rid: p.rid.clone(),
                    import_target: p.import_target.clone(),
                });
            }

            /// Max concurrent readiness polls per wave. Each poll is a
            /// single GET roughly every second, so the network pressure is
            /// modest — this cap exists mostly to keep kube's client
            /// connection pool and the API server's rate limiter happy on
            /// enormous waves.
            const READINESS_CONCURRENCY: usize = 64;

            // Snapshot the bits the futures need so nothing ends up holding
            // a &mut borrow of the outer scope.
            let discovery_ref: &[(ApiResource, Scope)] = &*discovery;
            let timeout = config.timeout;
            let cancel = config.cancel.clone();

            let futures_iter = to_poll.into_iter().map(|p| {
                let client = client.clone();
                let cancel = cancel.clone();
                async move {
                    let Pending { rid, import_target } = p;
                    let on_status = |msg: &str| {
                        observer.on_event(&ReconcileEvent::ReadinessProgress {
                            rid: rid.clone(),
                            import_target: import_target.clone(),
                            message: msg.to_string(),
                        });
                    };
                    let outcome = if let Some(target) = &import_target {
                        readiness::wait_for_import_target(
                            &client, target, timeout, &cancel, on_status,
                        )
                        .await
                    } else {
                        // Safe: filtered above to ensure kind is present.
                        let (ar, scope) = discovery_ref
                            .iter()
                            .find(|(ar, _)| ar.kind == rid.kind)
                            .expect("kind was filtered to exist in discovery cache");
                        let ns = if rid.namespace == CLUSTER_SCOPED {
                            None
                        } else {
                            Some(rid.namespace.as_str())
                        };
                        readiness::wait_for_ready(
                            &client, ar, scope, &rid.name, ns, &rid.kind, timeout, &cancel,
                            on_status,
                        )
                        .await
                    };
                    (rid, import_target, outcome)
                }
            });

            let mut poll_stream =
                stream::iter(futures_iter).buffer_unordered(READINESS_CONCURRENCY);

            // First Stop-worthy error — we remember it, break out of the
            // consume loop, and return it. Dropping `poll_stream` aborts
            // the pending futures mid-poll; that's well-defined for
            // `wait_for_ready` (it awaits only tokio sleeps and kube GETs,
            // both cancel-safe on drop). We intentionally do NOT flip
            // `config.cancel` here — that token belongs to the caller
            // (operator supersession, etc.) and we shouldn't overload its
            // meaning with "local drain".
            let mut stop_error: Option<ReconcileError> = None;

            while let Some((rid, import_target, outcome)) = poll_stream.next().await {
                // External cancellation surfaces here too: if the token
                // flipped while we were in recv, bail out the whole deploy.
                if config.cancel.is_cancelled() {
                    observer.on_event(&ReconcileEvent::Cancelled {
                        at: "readiness-loop",
                    });
                    return Err(ReconcileError::Cancelled {
                        partial_result: result,
                    });
                }

                match outcome {
                    Ok(ReadinessResult::Ready) => {
                        observer.on_event(&ReconcileEvent::ReadinessReady { rid, import_target });
                    }
                    Ok(ReadinessResult::Cancelled) => {
                        observer.on_event(&ReconcileEvent::Cancelled {
                            at: "readiness-poll",
                        });
                        return Err(ReconcileError::Cancelled {
                            partial_result: result,
                        });
                    }
                    Ok(ReadinessResult::TimedOut { elapsed, message }) => {
                        observer.on_event(&ReconcileEvent::ReadinessTimeout {
                            rid: rid.clone(),
                            elapsed,
                            message: message.clone(),
                            import_target,
                        });
                        if config.on_error == OnErrorPolicy::Stop && stop_error.is_none() {
                            stop_error = Some(ReconcileError::ReadinessTimeout {
                                rid,
                                partial_result: result.clone(),
                            });
                            break;
                        }
                    }
                    Ok(ReadinessResult::Failed(msg)) => {
                        demote_apply_to_failed(&apply_outcomes, &mut result, &rid);
                        observer.on_event(&ReconcileEvent::ReadinessFailed {
                            rid: rid.clone(),
                            message: msg.clone(),
                            import_target,
                            missing_keys: Vec::new(),
                        });
                        if config.on_error == OnErrorPolicy::Stop && stop_error.is_none() {
                            stop_error = Some(ReconcileError::ReadinessFailed {
                                rid,
                                message: msg,
                                partial_result: result.clone(),
                            });
                            break;
                        }
                    }
                    Ok(ReadinessResult::ImportMismatch {
                        missing_keys,
                        message,
                    }) => {
                        // Import marker's target exists but doesn't match
                        // the shape declared by the marker. Terminal —
                        // never polled again. Today this only fires for
                        // Secret imports with missing keys.
                        demote_apply_to_failed(&apply_outcomes, &mut result, &rid);
                        observer.on_event(&ReconcileEvent::ReadinessFailed {
                            rid: rid.clone(),
                            message: message.clone(),
                            import_target,
                            missing_keys,
                        });
                        if config.on_error == OnErrorPolicy::Stop && stop_error.is_none() {
                            stop_error = Some(ReconcileError::ReadinessFailed {
                                rid,
                                message,
                                partial_result: result.clone(),
                            });
                            break;
                        }
                    }
                    Err(e) => {
                        tracing::warn!("readiness check error for {rid}: {e}");
                    }
                }
            }
            drop(poll_stream);

            if let Some(err) = stop_error {
                return Err(err);
            }
        }

        // Re-discover API resources if this wave created CRDs directly OR
        // resolved CRD import markers (operator installed CRDs out-of-band).
        // Either way, later waves may reference new kinds that aren't yet in
        // our discovery cache.
        let wave_had_crds = wave_had_crd_import
            || hydrated_actions.iter().any(|a| {
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

        // Record wave progress on the Activation CR.
        // `applied`/`failed` here count *apply* (and hydration) outcomes only —
        // readiness failures bump `result.failed` but don't retroactively flip
        // a wave to Failed, since the resource did make it onto the cluster.
        let status = if wave_failed {
            WaveStatus::Failed
        } else {
            WaveStatus::Complete
        };
        let record = WaveRecord {
            wave_index: wave_idx,
            status: status.clone(),
            resource_count: actions.len(),
            applied: wave_apply_count,
            failed: wave_fail_count,
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

    // Prune orphans (after all apply waves). Skip any rids that were already
    // consumed by in-place recreate during apply — those live resources have
    // been re-created and must not be deleted again.
    let effective_orphans: Vec<ResourceId> = orphan_rids
        .iter()
        .filter(|rid| !consumed_orphans.contains(rid))
        .cloned()
        .collect();
    if !effective_orphans.is_empty() && config.prune != PrunePolicy::Skip {
        let ordered_orphans = compute_prune_order(&effective_orphans, old_manifests);

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

                let dp = kube::api::DeleteParams {
                    propagation_policy: Some(kube::api::PropagationPolicy::Background),
                    ..Default::default()
                };
                match api.delete(&rid.name, &dp).await {
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

    // Finalize activation lifecycle (mark old as Superseded, new as Active or
    // Degraded). finalize_deploy unconditionally bumps kix.dev/deployed-at,
    // which bumps metadata.generation, so we gate to avoid an infinite
    // reconcile loop on no-op deploys.
    //
    // We DO finalize when failures occurred: an unfinalized Activation has no
    // kix.dev/cluster label or terminal phase, so the next deploy can't find
    // it and treats the cluster as empty. finalize_deploy maps had_failures
    // to phase=Degraded, which `find_active` accepts for diffing.
    //
    // Pure no-op (everything Unchanged, zero failures) is the only path that
    // skips finalize.
    let actually_changed =
        result.created > 0 || result.configured > 0 || result.pruned > 0 || result.failed > 0;
    if actually_changed
        && let Some(act_name) = activation_name
        && let Some((ar, _)) = activation::find_activation_ar(discovery)
    {
        let old_activation = activation::find_active(client, ar, cluster_name)
            .await
            .ok()
            .flatten()
            .filter(|old| old.name != act_name);

        let had_failures = result.failed > 0;
        if let Err(e) = activation::finalize_deploy(
            client,
            ar,
            cluster_name,
            act_name,
            old_activation.as_ref(),
            had_failures,
        )
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
// Helpers
// ---------------------------------------------------------------------------

/// Wall-clock bound for waiting on the live resource to disappear during
/// an immutable-conflict recreate. Independent of the readiness timeout —
/// deletion should be near-instant; anything longer usually means stuck
/// finalizers, which we surface rather than mask.
const RECREATE_DELETE_TIMEOUT: Duration = Duration::from_secs(30);

/// Kind-aware propagation policy for in-place recreate. Jobs foreground-delete
/// so the old pods are gone before we re-apply (otherwise the new Job's
/// controller collides with stale pods). StatefulSets orphan-delete so
/// PVCs are retained across the recreate. Everything else uses Background,
/// which is the kubectl default.
fn delete_propagation_for(kind: &str) -> kube::api::PropagationPolicy {
    match kind {
        "Job" => kube::api::PropagationPolicy::Foreground,
        "StatefulSet" => kube::api::PropagationPolicy::Orphan,
        _ => kube::api::PropagationPolicy::Background,
    }
}

/// Delete the live resource identified by `rid`, wait for it to disappear,
/// then re-apply `manifest`. The caller must have already verified the rid
/// is authorized for deletion (i.e. present in the orphan set).
async fn recreate_in_place(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    rid: &ResourceId,
    manifest: &Value,
    force_conflicts: bool,
    activation_hash: Option<&str>,
) -> Result<apply::ApplyResult, String> {
    let Some((ar, scope)) = discovery.iter().find(|(ar, _)| ar.kind == rid.kind) else {
        return Err(format!("kind {} not in discovery cache", rid.kind));
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

    let dp = kube::api::DeleteParams {
        propagation_policy: Some(delete_propagation_for(&rid.kind)),
        ..Default::default()
    };
    api.delete(&rid.name, &dp)
        .await
        .map_err(|e| format!("delete failed: {e}"))?;

    // Poll for deletion. Transient API errors treated as "probably gone"
    // since the delete itself succeeded; any real problem will re-surface
    // on the re-apply below.
    let deadline = std::time::Instant::now() + RECREATE_DELETE_TIMEOUT;
    while std::time::Instant::now() < deadline {
        match api.get_opt(&rid.name).await {
            Ok(None) => break,
            Ok(Some(_)) => tokio::time::sleep(Duration::from_millis(500)).await,
            Err(e) => {
                tracing::debug!(resource = %rid, error = %e, "transient error polling deletion; assuming gone");
                break;
            }
        }
    }

    apply::apply_resource(
        client,
        ar,
        scope.clone(),
        manifest,
        false,
        activation_hash,
        force_conflicts,
    )
    .await
    .map_err(|e| format!("re-apply failed: {e}"))
}

/// Move a resource that had a successful apply into the `failed` bucket after
/// a readiness failure, so a single bad resource isn't counted as both
/// "configured" and "failed". `saturating_sub` guards against any future
/// caller invoking this twice on the same rid.
fn demote_apply_to_failed(
    outcomes: &HashMap<ResourceId, ApplyAction>,
    result: &mut ReconcileResult,
    rid: &ResourceId,
) {
    match outcomes.get(rid) {
        Some(ApplyAction::Created) => {
            result.created = result.created.saturating_sub(1);
        }
        Some(ApplyAction::Configured) => {
            result.configured = result.configured.saturating_sub(1);
        }
        Some(ApplyAction::Unchanged) | Some(ApplyAction::Skipped) => {
            result.unchanged = result.unchanged.saturating_sub(1);
        }
        None => {}
    }
    result.failed += 1;
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
