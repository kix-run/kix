//! Per-node execution, recreation refusal, and orphan pruning order.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use crate::manifest::lifecycle::never_pruned;
use crate::manifest::types::ResourceId;

use chrono::Utc;

use super::super::apply::{ApplyAction, ApplyError, ApplyResult, ChangeAction};
use super::super::cancel::CancelToken;
use super::super::graph::ResourceGraph;
use super::super::kept::NotKeptField;
use super::super::ops::{ResourceIo, SecretHydrator};
use super::super::readiness::{self, ImportTarget, ReadinessResult};
use super::super::secrets;
use super::super::stream::{
    DeployEvent, DeployObserver, NodeDetail, NodeId, Phase, TransitionKind, Verdict,
};
use super::super::watchdog::Progress;
use super::PlanNodeEntry;

pub(super) struct NodeCtx {
    pub(super) resources: Arc<dyn ResourceIo>,
    pub(super) secrets: Arc<dyn SecretHydrator>,
    pub(super) cancel: CancelToken,
    pub(super) timeout: Duration,
    pub(super) orphan_set: HashSet<ResourceId>,
    pub(super) dry_run: bool,
    pub(super) rerun_failed: bool,
    pub(super) progress: Arc<Progress>,
    pub(super) observer: Arc<dyn DeployObserver>,
}

impl NodeCtx {
    fn emit(&self, event: DeployEvent) {
        self.progress.touch();
        self.observer.on_event(&event);
    }
}

pub(super) enum NodeOutcome {
    Ready {
        apply_action: ApplyAction,
    },
    Recreated {
        apply_action: ApplyAction,
        reason: String,
    },
    /// Deleted and recreated under the rerun rule.
    Rerun {
        apply_action: ApplyAction,
        reason: String,
    },
    /// Ready, with `stale` pods of an `OnDelete` DaemonSet still running the
    /// previous pod template.
    PendingRestart {
        apply_action: ApplyAction,
        stale: i64,
        message: String,
    },
    Failed {
        detail: NodeDetail,
        message: String,
    },
    Cancelled,
}

/// Delete and recreate a resource through `ResourceIo::recreate_in_place`
/// unless `recreate_refusal` rejects its kind.
async fn recreate(
    ctx: &NodeCtx,
    manifest: &Value,
    rid: &ResourceId,
) -> Result<ApplyResult, String> {
    if let Some(refusal) = recreate_refusal(rid) {
        return Err(refusal);
    }
    ctx.resources
        .recreate_in_place(manifest)
        .await
        .map_err(|e| e.to_string())
}

/// Return an error message if `rid` is a protected kind that Kix must not
/// delete and recreate automatically, or `None` if recreation is allowed.
pub(super) fn recreate_refusal(rid: &ResourceId) -> Option<String> {
    if !never_pruned(&rid.kind) {
        return None;
    }
    let consequence = match rid.kind.as_str() {
        "Namespace" => "deleting a Namespace deletes everything in it",
        "CustomResourceDefinition" => {
            "deleting a CustomResourceDefinition deletes every custom resource of that kind"
        }
        _ => "deleting it also deletes objects outside the build",
    };
    Some(format!(
        "{rid} can only be changed by deleting and re-creating it, and Kix never \
         deletes a {kind} automatically: {consequence}. Delete it with kubectl \
         if that is intended, then deploy again.",
        kind = rid.kind,
    ))
}

/// Hydrate secrets, apply or recreate the resource, wait for readiness, and
/// return the node's outcome.
///
/// `checked` says that something in this deploy depends on `entry` although
/// the plan leaves it unchanged (`SchedulerState::is_checked`).
pub(super) async fn execute_node(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    checked: bool,
) -> NodeOutcome {
    if entry.kind == TransitionKind::Wait {
        return wait_for_platform(ctx, entry).await;
    }
    // Reason a rerun node is deleted before apply. `None` means a standard apply.
    let mut rerun_reason: Option<&'static str> = None;
    let manifest = match (&entry.action, &entry.rerun) {
        (ChangeAction::Apply(m), _) => m.clone(),
        (ChangeAction::Skip(rid), rerun) if super::plan::skip_reads_live(entry) => {
            // An unchanged Job is never applied again, so its last run is
            // read back. A failed run is recreated under `kix.run/rerun` when
            // `rerun_failed` is enabled, and reported otherwise. A Job
            // without the annotation is never deleted here.
            let live = ctx.resources.get_live(rid).await;
            let terminal = match &live {
                Ok(Some(obj)) => readiness::classify_workload_terminal(obj, &rid.kind),
                _ => None,
            };
            match (live, terminal) {
                (Ok(Some(_)), Some((reason, detail))) => {
                    let manifest = match rerun {
                        Some(manifest) if ctx.rerun_failed => Some(manifest),
                        _ => None,
                    };
                    let Some(manifest) = manifest else {
                        let message = format!(
                            "{}: {detail}; unchanged since its last run, which failed. {}",
                            reason.as_str(),
                            job_next_step(rerun.is_some()),
                        );
                        return NodeOutcome::Failed {
                            detail: NodeDetail::ReadinessFailed {
                                message: message.clone(),
                                missing_keys: Vec::new(),
                                output: Vec::new(),
                            },
                            message,
                        };
                    };
                    rerun_reason = Some("the last run failed");
                    manifest.clone()
                }
                // A run that is still going holds back what depends on it,
                // as a Job this deploy applied would.
                (Ok(Some(obj)), None) if checked && !readiness::check_job_ready(&obj) => {
                    return match check_unchanged(ctx, entry, rid).await {
                        NodeOutcome::Failed { detail, message } => NodeOutcome::Failed {
                            message: with_sentence(
                                &message,
                                &format!("{}.", job_next_step(rerun.is_some())),
                            ),
                            detail,
                        },
                        other => other,
                    };
                }
                (Ok(_), _) => {
                    return NodeOutcome::Ready {
                        apply_action: ApplyAction::Unchanged,
                    };
                }
                (Err(e), _) => {
                    let message = format!("could not read the live object: {e}");
                    return NodeOutcome::Failed {
                        detail: NodeDetail::ApplyFailed(message.clone()),
                        message,
                    };
                }
            }
        }
        // The scheduler runs a task for any other Skip node only when
        // something in this deploy depends on it, so the live object is
        // checked.
        (ChangeAction::Skip(rid), _) => return check_unchanged(ctx, entry, rid).await,
        (ChangeAction::Orphan(_), _) => {
            return NodeOutcome::Ready {
                apply_action: ApplyAction::Skipped,
            };
        }
    };
    let rid = ResourceId::from_value(&manifest);
    let node = NodeId::Resource(rid.clone());

    let manifest = if secrets::needs_hydration(&manifest) {
        ctx.progress.set_phase(&node, Phase::Hydrate);
        match ctx.secrets.hydrate(manifest).await {
            Ok((manifest, results)) => {
                for hr in &results {
                    ctx.emit(DeployEvent::NodeStateChanged {
                        node: NodeId::Resource(hr.rid.clone()),
                        kind: entry.kind,
                        verdict: Verdict::Running,
                        detail: Some(NodeDetail::SecretHydrated {
                            keys: hr.keys_injected,
                        }),
                    });
                }
                manifest
            }
            Err(e) => {
                return NodeOutcome::Failed {
                    detail: NodeDetail::SecretHydrationFailed(e.to_string()),
                    message: format!("could not prepare secret values for deployment: {e}"),
                };
            }
        }
    } else {
        manifest
    };

    // Changed resources carrying `kix.run/rerun` are never patched in place.
    // Delete the live object in the foreground first so its pods are removed
    // before recreating it, or apply directly if no live object exists.
    if matches!(entry.kind, TransitionKind::Recreate) && rerun_reason.is_none() {
        match ctx.resources.get_live(&rid).await {
            Ok(Some(_)) => rerun_reason = Some("changed since the last run"),
            Ok(None) => {}
            Err(e) => {
                let message = format!("could not read the live object: {e}");
                return NodeOutcome::Failed {
                    detail: NodeDetail::ApplyFailed(message.clone()),
                    message,
                };
            }
        }
    }

    ctx.progress.set_phase(&node, Phase::Apply);
    // Taken before the apply so a controller's verdict written while the
    // apply is in flight still counts as later than it.
    let apply_started = Utc::now();
    let applied_action: ApplyAction;
    let not_kept: Vec<NotKeptField>;
    let mut recreated_reason: Option<String> = None;
    if let Some(reason) = rerun_reason {
        match recreate(ctx, &manifest, &rid).await {
            Ok(apply_result) => {
                applied_action = apply_result.action;
                not_kept = apply_result.not_kept;
            }
            Err(e) => {
                let message = format!("rerun ({reason}) failed: {e}");
                return NodeOutcome::Failed {
                    detail: NodeDetail::ApplyFailed(message.clone()),
                    message,
                };
            }
        }
    } else {
        match ctx.resources.apply(&manifest).await {
            Ok(result) => {
                applied_action = result.action;
                not_kept = result.not_kept;
            }
            Err(ApplyError::ImmutableConflict { source, .. }) if ctx.orphan_set.contains(&rid) => {
                let reason = source.to_string();
                match recreate(ctx, &manifest, &rid).await {
                    Ok(apply_result) => {
                        applied_action = apply_result.action;
                        not_kept = apply_result.not_kept;
                        recreated_reason = Some(reason);
                    }
                    Err(e) => {
                        return NodeOutcome::Failed {
                            detail: NodeDetail::ApplyFailed(e.clone()),
                            message: e,
                        };
                    }
                }
            }
            Err(e) => {
                return NodeOutcome::Failed {
                    detail: NodeDetail::ApplyFailed(e.to_string()),
                    message: e.to_string(),
                };
            }
        }
    }

    ctx.emit(DeployEvent::NodeStateChanged {
        node: node.clone(),
        kind: entry.kind,
        verdict: Verdict::Running,
        detail: Some(NodeDetail::Applied(applied_action.clone())),
    });
    // A dry run reports these in the plan document instead.
    if !ctx.dry_run && !not_kept.is_empty() {
        ctx.emit(DeployEvent::FieldsNotKept {
            resource: rid.clone(),
            fields: not_kept,
        });
    }

    let done = |recreated_reason: Option<String>| match (rerun_reason, recreated_reason) {
        (Some(reason), _) => NodeOutcome::Rerun {
            apply_action: applied_action.clone(),
            reason: reason.to_string(),
        },
        (None, Some(reason)) => NodeOutcome::Recreated {
            apply_action: applied_action.clone(),
            reason,
        },
        (None, None) => NodeOutcome::Ready {
            apply_action: applied_action.clone(),
        },
    };

    // Dry-run applies are not persisted, so skip readiness polling.
    if ctx.dry_run {
        return done(recreated_reason);
    }

    let import_target: Option<ImportTarget> = entry.meta.import_target.clone();
    if import_target.is_none() && readiness::is_immediate_kind(&rid.kind) {
        return done(recreated_reason);
    }

    // Poll for readiness. Each status callback updates the watchdog so an
    // active rollout does not trigger a stall warning.
    ctx.progress.set_phase(&node, Phase::Readiness);
    let on_status = |msg: &str| {
        ctx.progress.set_status(&node, msg);
        ctx.emit(DeployEvent::NodeStateChanged {
            node: node.clone(),
            kind: entry.kind,
            verdict: Verdict::Running,
            detail: Some(NodeDetail::ReadinessProgress(msg.to_string())),
        });
    };
    let applied_at = matches!(
        applied_action,
        ApplyAction::Created | ApplyAction::Configured
    )
    .then_some(apply_started);
    let outcome = ctx
        .resources
        .wait_ready(
            &rid,
            import_target.as_ref(),
            applied_at,
            ctx.timeout,
            &ctx.cancel,
            &on_status,
        )
        .await;

    let outcome = match outcome {
        Ok(o) => o,
        Err(e) => {
            tracing::warn!("readiness error for {rid}: {e}");
            return NodeOutcome::Failed {
                detail: NodeDetail::ReadinessFailed {
                    message: e.to_string(),
                    missing_keys: Vec::new(),
                    output: Vec::new(),
                },
                message: e.to_string(),
            };
        }
    };

    match outcome {
        ReadinessResult::Ready => done(recreated_reason),
        ReadinessResult::ReadyPendingRestart { stale, message } => match done(recreated_reason) {
            NodeOutcome::Ready { apply_action } => NodeOutcome::PendingRestart {
                apply_action,
                stale,
                message,
            },
            other => other,
        },
        ReadinessResult::Cancelled => NodeOutcome::Cancelled,
        ReadinessResult::TimedOut { elapsed, message } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessTimeout {
                elapsed,
                message: message.clone(),
            },
            message,
        },
        ReadinessResult::Failed { message, output } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys: Vec::new(),
                output,
            },
            message,
        },
        ReadinessResult::ImportMismatch {
            missing_keys,
            message,
        } => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys,
                output: Vec::new(),
            },
            message,
        },
    }
}

/// Wait for a resource managed by a platform Kix cluster
/// ([`TransitionKind::Wait`]) to become ready without applying it.
async fn wait_for_platform(ctx: &NodeCtx, entry: &PlanNodeEntry) -> NodeOutcome {
    match &entry.id {
        NodeId::Resource(rid) if !ctx.dry_run => wait_live(ctx, entry, rid).await,
        _ => NodeOutcome::Ready {
            apply_action: ApplyAction::Unchanged,
        },
    }
}

/// Check that an unchanged resource something in this deploy depends on is
/// ready, without applying it. A dry run and a kind whose readiness is
/// immediate read nothing. A failure says that this deploy did not change
/// the object, because the readiness text alone reads as if the deploy had
/// just applied it. The scheduler adds the consequence and the next step.
async fn check_unchanged(ctx: &NodeCtx, entry: &PlanNodeEntry, rid: &ResourceId) -> NodeOutcome {
    let unchanged = NodeOutcome::Ready {
        apply_action: ApplyAction::Unchanged,
    };
    if ctx.dry_run {
        return unchanged;
    }
    if entry.meta.import_target.is_none() && readiness::is_immediate_kind(&rid.kind) {
        return unchanged;
    }
    match wait_live(ctx, entry, rid).await {
        NodeOutcome::Failed { detail, message } => {
            let message = with_sentence(
                &message,
                "This deploy did not change it. An earlier deploy or a change on the \
                 cluster left it like this.",
            );
            NodeOutcome::Failed { detail, message }
        }
        other => other,
    }
}

/// Return the next step after an unchanged Job failed. A Job cannot be
/// changed in place, so it runs again only when it is recreated.
fn job_next_step(rerun: bool) -> &'static str {
    if rerun {
        "Deploy with the CLI to run it again, or change an input"
    } else {
        "Change an input, or delete the Job with kubectl and deploy again"
    }
}

/// Append `sentence` to `message`, closing the message with a full stop when
/// it does not end in one.
pub(super) fn with_sentence(message: &str, sentence: &str) -> String {
    let message = message.trim_end();
    let stop = if message.ends_with(['.', '!', '?']) {
        ""
    } else {
        "."
    };
    format!("{message}{stop} {sentence}")
}

/// Wait through `ResourceIo::wait_ready` for a node's live object (or the
/// import target it describes) without applying it. The node left the object
/// as it was, so `applied_at` is `None` and a declared failure is final at
/// once.
async fn wait_live(ctx: &NodeCtx, entry: &PlanNodeEntry, rid: &ResourceId) -> NodeOutcome {
    let unchanged = NodeOutcome::Ready {
        apply_action: ApplyAction::Unchanged,
    };
    let node = entry.id.clone();
    ctx.progress.set_phase(&node, Phase::Readiness);
    let on_status = |msg: &str| {
        ctx.progress.set_status(&node, msg);
        ctx.emit(DeployEvent::NodeStateChanged {
            node: node.clone(),
            kind: entry.kind,
            verdict: Verdict::Running,
            detail: Some(NodeDetail::ReadinessProgress(msg.to_string())),
        });
    };
    let outcome = ctx
        .resources
        .wait_ready(
            rid,
            entry.meta.import_target.as_ref(),
            None,
            ctx.timeout,
            &ctx.cancel,
            &on_status,
        )
        .await;
    match outcome {
        Ok(ReadinessResult::Ready | ReadinessResult::ReadyPendingRestart { .. }) => unchanged,
        Ok(ReadinessResult::Cancelled) => NodeOutcome::Cancelled,
        Ok(ReadinessResult::TimedOut { elapsed, message }) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessTimeout {
                elapsed,
                message: message.clone(),
            },
            message,
        },
        Ok(
            ReadinessResult::Failed { message, .. }
            | ReadinessResult::ImportMismatch { message, .. },
        ) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: message.clone(),
                missing_keys: Vec::new(),
                output: Vec::new(),
            },
            message,
        },
        Err(e) => NodeOutcome::Failed {
            detail: NodeDetail::ReadinessFailed {
                message: e.to_string(),
                missing_keys: Vec::new(),
                output: Vec::new(),
            },
            message: e.to_string(),
        },
    }
}

/// Return orphaned resources in reverse-topological order according to
/// `old_manifests`. Orphans without a matching manifest in `old_manifests`
/// have no known dependencies and are appended at the end.
pub(super) fn prune_order(orphan_rids: &[ResourceId], old_manifests: &[Value]) -> Vec<ResourceId> {
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
    let mut ordered = match ResourceGraph::from_manifests(&orphan_manifests) {
        Ok(graph) => graph.reverse_topo_ids(),
        Err(_) => return orphan_rids.to_vec(),
    };
    let listed: HashSet<ResourceId> = ordered.iter().cloned().collect();
    ordered.extend(
        orphan_rids
            .iter()
            .filter(|rid| !listed.contains(*rid))
            .cloned(),
    );
    ordered
}
