//! Per-node execution, recreation refusal, and orphan pruning order.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use crate::manifest::kinds;
use crate::manifest::lifecycle::never_pruned;
use crate::manifest::types::ResourceId;

use chrono::Utc;

use super::super::apply::{ApplyAction, ApplyError, ApplyResult, ChangeAction};
use super::super::cancel::CancelToken;
use super::super::graph::DeleteOrder;
use super::super::ops::{RecreateError, ResourceIo, SecretHydrator};
use super::super::readiness::{self, DeletePath, ReadinessResult, Runner};
use super::super::secrets;
use super::super::stream::{DeployEvent, DeployObserver, NodeDetail, NodeId, Phase, Verdict};
use super::super::watchdog::Progress;
use super::PlanNodeEntry;

pub(super) struct NodeCtx {
    pub(super) resources: Arc<dyn ResourceIo>,
    pub(super) secrets: Arc<dyn SecretHydrator>,
    pub(super) cancel: CancelToken,
    pub(super) timeout: Duration,
    pub(super) orphan_set: HashSet<ResourceId>,
    /// The controllers that the kind of each object names, read when a
    /// delete before a recreate or an apply does not finish.
    pub(super) controllers: HashMap<ResourceId, Vec<ResourceId>>,
    pub(super) dry_run: bool,
    pub(super) progress: Arc<Progress>,
    pub(super) observer: Arc<dyn DeployObserver>,
    /// Who runs the deploy, for the next step a message gives.
    pub(super) runner: Runner,
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
    /// Ready, with the running workload still on the previous spec (see
    /// `ReadinessResult::ReadyPendingRestart`).
    PendingRestart {
        apply_action: ApplyAction,
        stale: Option<i64>,
        message: String,
    },
    Failed {
        detail: NodeDetail,
        message: String,
    },
    Cancelled,
}

/// A step of a node that failed: what it reports, and the detail the
/// stream carries.
struct StepFailed {
    message: String,
    detail: NodeDetail,
}

impl StepFailed {
    fn apply(message: String) -> Self {
        StepFailed {
            detail: NodeDetail::ApplyFailed(message.clone()),
            message,
        }
    }

    /// Put `prefix` before the message, in the detail too.
    fn prefixed(self, prefix: &str) -> Self {
        let message = format!("{prefix}{}", self.message);
        let detail = match self.detail {
            NodeDetail::DeletionUnfinished {
                elapsed,
                finalizers,
                controllers,
                ..
            } => NodeDetail::DeletionUnfinished {
                elapsed,
                finalizers,
                controllers,
                message: message.clone(),
            },
            _ => NodeDetail::ApplyFailed(message.clone()),
        };
        StepFailed { message, detail }
    }

    fn outcome(self) -> NodeOutcome {
        NodeOutcome::Failed {
            detail: self.detail,
            message: self.message,
        }
    }
}

/// Return the failure of a delete on `path` that did not finish: read each
/// controller that the kind of `rid` names, so the message says whether it
/// runs, and explain what Kix did.
async fn deletion_unfinished(
    ctx: &NodeCtx,
    rid: &ResourceId,
    mut stuck: readiness::Stuck,
    path: DeletePath,
) -> StepFailed {
    for id in ctx.controllers.get(rid).into_iter().flatten() {
        stuck
            .controllers
            .push(super::read_controller(&*ctx.resources, id).await);
    }
    let message = format!(
        "{}\n\n{}",
        readiness::stuck_message(rid, &stuck),
        readiness::stuck_explanation(path)
    );
    StepFailed {
        detail: NodeDetail::deletion_unfinished(&stuck, message.clone()),
        message,
    }
}

/// Delete and recreate a resource through `ResourceIo::recreate_in_place`
/// unless `recreate_refusal` rejects its kind.
async fn recreate(
    ctx: &NodeCtx,
    manifest: &Value,
    rid: &ResourceId,
) -> Result<ApplyResult, StepFailed> {
    if let Some(refusal) = recreate_refusal(rid) {
        return Err(StepFailed::apply(refusal));
    }
    match ctx
        .resources
        .recreate_in_place(manifest, ctx.timeout, &ctx.cancel)
        .await
    {
        Ok(result) => Ok(result),
        Err(RecreateError::StillExists { rid, stuck }) => {
            Err(deletion_unfinished(ctx, &rid, stuck, DeletePath::Recreate(ctx.runner)).await)
        }
        Err(e) => Err(StepFailed::apply(e.to_string())),
    }
}

/// Return an error message if `rid` is a protected kind that Kix must not
/// delete and recreate automatically, or `None` if recreation is allowed.
pub(super) fn recreate_refusal(rid: &ResourceId) -> Option<String> {
    if !never_pruned(rid.group_kind()) {
        return None;
    }
    let consequence = match rid.group_kind() {
        kinds::NAMESPACE => "deleting a Namespace deletes everything in it",
        kinds::CUSTOM_RESOURCE_DEFINITION => {
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
    match &entry.action {
        ChangeAction::Apply(m) | ChangeAction::Recreate(m, _) => {
            match apply_node(ctx, entry, m.clone()).await {
                Ok(outcome) | Err(outcome) => outcome,
            }
        }
        ChangeAction::Skip(rid) if super::plan::skip_reads_live(entry) => {
            check_unchanged_job(ctx, entry, rid, checked).await
        }
        // The scheduler runs a task for any other Skip node only when
        // something in this deploy depends on it, so the live object is
        // checked.
        ChangeAction::Skip(rid) => check_unchanged(ctx, entry, rid).await,
        ChangeAction::Orphan(_) => NodeOutcome::Ready {
            apply_action: ApplyAction::Skipped,
        },
    }
}

/// Report the last run of an unchanged Job. An unchanged Job is never
/// applied again, so its last run is read back, and a failed run is
/// reported. The plan decides whether a Job runs again, so nothing is
/// deleted here.
async fn check_unchanged_job(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    rid: &ResourceId,
    checked: bool,
) -> NodeOutcome {
    let rerun = entry.rerun.is_some();
    let live = ctx.resources.get_live(rid).await;
    let terminal = match &live {
        Ok(Some(obj)) => readiness::classify_workload_terminal(obj, rid.group_kind()),
        _ => None,
    };
    match (live, terminal) {
        (Ok(Some(_)), Some((reason, detail))) => {
            let message = format!(
                "{}: {detail}; unchanged since its last run, which failed. {}",
                reason.as_str(),
                job_next_step(rerun),
            );
            NodeOutcome::Failed {
                detail: NodeDetail::ReadinessFailed {
                    message: message.clone(),
                    missing_keys: Vec::new(),
                    output: Vec::new(),
                },
                message,
            }
        }
        // A run that is still going holds back what depends on it, as a Job
        // this deploy applied would.
        (Ok(Some(obj)), None) if checked && !readiness::check_job_ready(&obj) => {
            match check_unchanged(ctx, entry, rid).await {
                NodeOutcome::Failed { detail, message } => NodeOutcome::Failed {
                    message: with_sentence(&message, &format!("{}.", job_next_step(rerun))),
                    detail,
                },
                other => other,
            }
        }
        (Ok(_), _) => NodeOutcome::Ready {
            apply_action: ApplyAction::Unchanged,
        },
        (Err(e), _) => apply_failed(format!("could not read the live object: {e}")),
    }
}

/// Hydrate, apply or recreate, and wait for `manifest`. Every step that
/// fails returns the node's outcome as the error.
async fn apply_node(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    manifest: Value,
) -> Result<NodeOutcome, NodeOutcome> {
    let rid = ResourceId::from_value(&manifest);
    let node = NodeId::Resource(rid.clone());
    let manifest = hydrate(ctx, entry, &node, manifest).await?;
    let rerun_reason = rerun_reason(ctx, entry, &rid).await?;

    ctx.progress.set_phase(&node, Phase::Apply);
    // Taken before the apply so a controller's verdict written while the
    // apply is in flight still counts as later than it.
    let apply_started = Utc::now();
    let (applied, recreated_reason) = apply_or_recreate(ctx, &manifest, &rid, rerun_reason).await?;
    let applied_action = applied.action;

    ctx.emit(DeployEvent::NodeStateChanged {
        node: node.clone(),
        kind: entry.kind,
        verdict: Verdict::Running,
        detail: Some(NodeDetail::Applied(applied_action.clone())),
    });
    // A dry run reports these in the plan document instead.
    if !ctx.dry_run && !applied.not_kept.is_empty() {
        ctx.emit(DeployEvent::FieldsNotKept {
            resource: rid.clone(),
            fields: applied.not_kept,
        });
    }

    let applied_at = matches!(
        applied_action,
        ApplyAction::Created | ApplyAction::Configured
    )
    .then_some(apply_started);
    let done = match (rerun_reason, recreated_reason) {
        (Some(reason), _) => NodeOutcome::Rerun {
            apply_action: applied_action,
            reason: reason.to_string(),
        },
        (None, Some(reason)) => NodeOutcome::Recreated {
            apply_action: applied_action,
            reason,
        },
        (None, None) => NodeOutcome::Ready {
            apply_action: applied_action,
        },
    };

    // Dry-run applies are not persisted, so skip readiness polling.
    if ctx.dry_run {
        return Ok(done);
    }
    let import_target = entry.meta.import_target.as_ref();
    if import_target.is_none() && readiness::is_immediate(rid.group_kind(), &manifest) {
        return Ok(done);
    }
    Ok(wait_applied(ctx, entry, &node, &rid, applied_at, done).await)
}

/// Fill in the secret values `manifest` refers to, when it has any.
async fn hydrate(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    node: &NodeId,
    manifest: Value,
) -> Result<Value, NodeOutcome> {
    if !secrets::needs_hydration(&manifest) {
        return Ok(manifest);
    }
    ctx.progress.set_phase(node, Phase::Hydrate);
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
            Ok(manifest)
        }
        Err(e) => Err(NodeOutcome::Failed {
            detail: NodeDetail::SecretHydrationFailed(e.to_string()),
            message: format!("could not prepare secret values for deployment: {e}"),
        }),
    }
}

/// Return why the plan runs a Job again, when it does and the Job exists.
/// A Job the plan runs again is never patched in place. Its live object is
/// deleted in the foreground first so its pods are removed before it is
/// recreated. A Job with no live object is applied directly.
async fn rerun_reason(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    rid: &ResourceId,
) -> Result<Option<&'static str>, NodeOutcome> {
    let ChangeAction::Recreate(_, reason) = &entry.action else {
        return Ok(None);
    };
    match ctx.resources.get_live(rid).await {
        Ok(Some(_)) => Ok(Some(reason.as_str())),
        Ok(None) => Ok(None),
        Err(e) => Err(apply_failed(format!("could not read the live object: {e}"))),
    }
}

/// Apply `manifest`, or recreate it when the plan runs it again. An orphan
/// that the API server refuses to change in place is recreated too, and the
/// refusal is returned as the reason.
async fn apply_or_recreate(
    ctx: &NodeCtx,
    manifest: &Value,
    rid: &ResourceId,
    rerun_reason: Option<&'static str>,
) -> Result<(ApplyResult, Option<String>), NodeOutcome> {
    if let Some(reason) = rerun_reason {
        return match recreate(ctx, manifest, rid).await {
            Ok(result) => Ok((result, None)),
            Err(e) => Err(e.prefixed(&format!("rerun ({reason}) failed: ")).outcome()),
        };
    }
    let node = NodeId::Resource(rid.clone());
    let on_status = |msg: &str| ctx.progress.set_status(&node, msg);
    match ctx
        .resources
        .apply(manifest, ctx.timeout, &ctx.cancel, &on_status)
        .await
    {
        Ok(result) => Ok((result, None)),
        Err(ApplyError::ImmutableConflict { source, .. }) if ctx.orphan_set.contains(rid) => {
            let reason = source.to_string();
            match recreate(ctx, manifest, rid).await {
                Ok(result) => Ok((result, Some(reason))),
                Err(e) => Err(e.outcome()),
            }
        }
        Err(ApplyError::StillBeingDeleted { rid, stuck }) => {
            Err(
                deletion_unfinished(ctx, &rid, stuck, DeletePath::Apply(ctx.runner))
                    .await
                    .outcome(),
            )
        }
        Err(e) => Err(apply_failed(e.to_string())),
    }
}

/// Wait for the object this node applied to become ready, and return `done`
/// when it does. Each status callback updates the watchdog so an active
/// rollout does not trigger a stall warning.
async fn wait_applied(
    ctx: &NodeCtx,
    entry: &PlanNodeEntry,
    node: &NodeId,
    rid: &ResourceId,
    applied_at: Option<chrono::DateTime<Utc>>,
    done: NodeOutcome,
) -> NodeOutcome {
    ctx.progress.set_phase(node, Phase::Readiness);
    let on_status = |msg: &str| {
        ctx.progress.set_status(node, msg);
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
        ReadinessResult::Ready => done,
        ReadinessResult::ReadyPendingRestart { stale, message } => match done {
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

/// Return the outcome of a node whose apply failed with `message`.
fn apply_failed(message: String) -> NodeOutcome {
    NodeOutcome::Failed {
        detail: NodeDetail::ApplyFailed(message.clone()),
        message,
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
    if entry.meta.import_target.is_none() && readiness::is_immediate_kind(rid.group_kind()) {
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
        "Deploy from the command line to run it again, or change an input"
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

/// Return the orphans in an order that deletes each before the orphans it
/// depends on, with the dependencies of the whole previous build
/// (`old_manifests`), so a dependency through an object that stays still
/// counts. Orphans without a matching manifest have no known dependencies
/// and come last.
pub(crate) fn prune_order(orphan_rids: &[ResourceId], old_manifests: &[Value]) -> DeleteOrder {
    let orphan_set: HashSet<&ResourceId> = orphan_rids.iter().collect();
    let mut order = DeleteOrder::of_manifests(old_manifests);
    order.retain(|rid| orphan_set.contains(rid));
    for rid in orphan_rids {
        order.push(rid.clone());
    }
    order
}
