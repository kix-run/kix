//! Non-interactive deploy observers.
//!
//! Two output modes beyond the colored [`StreamCliObserver`]:
//!
//! - [`LineObserver`]: one line per terminal verdict,
//!   phase boundary, prune event, or finalization. No ANSI codes, no cursor
//!   motion. Safe to pipe into `less`, CI logs, `tee`. Used automatically
//!   when `--log-format=pretty` is requested against a non-TTY stdout.
//! - [`JsonObserver`]: one NDJSON object per [`DeployEvent`],
//!   flushed immediately. Shape is stable across events (every object
//!   carries `type` and timestamp); consumers can `jq -c` or pipe to log
//!   aggregators. Readiness progress events are suppressed unless `-v` is
//!   on to match the `line` format's suppression rule.
//!
//! Both observers are allocation-light and do not
//! track state beyond a `started_at` timestamp for elapsed fields.

use std::io::{self, Write};
use std::time::Instant;

use serde_json::json;

use kix::cluster::apply::ApplyAction;
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, NodeDetail, NodeId, TransitionKind, Verdict,
};
use kix::manifest::types::ResourceId;

pub struct LineObserver {
    pub verbose: bool,
}

impl DeployObserver for LineObserver {
    fn on_event(&self, event: &DeployEvent) {
        match event {
            DeployEvent::PlanComputed { nodes, .. } => {
                println!("plan: {} nodes", nodes.len());
            }
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => {
                let label = node_label(node);
                let tag = kind.tag().map(|t| format!("{t} ")).unwrap_or_default();
                match verdict {
                    Verdict::Pending => {}
                    Verdict::Running => match detail {
                        Some(NodeDetail::Applied(action)) => {
                            println!("{label}> {tag}{}", apply_label(action));
                        }
                        Some(NodeDetail::SecretHydrated { keys }) => {
                            println!("{label}> hydrated {keys} keys from SOPS");
                        }
                        Some(NodeDetail::ReadinessProgress(_)) => {}
                        _ => {}
                    },
                    Verdict::Ready => match detail {
                        Some(NodeDetail::Applied(ApplyAction::Unchanged)) => {
                            if self.verbose {
                                println!("{label}> {tag}unchanged");
                            }
                        }
                        Some(NodeDetail::RecreatedInPlace { reason }) => {
                            println!("{label}> recreate (immutable): {reason}");
                        }
                        Some(NodeDetail::Rerun { reason }) => {
                            println!("{label}> rerun: {reason}");
                        }
                        Some(NodeDetail::PendingRestart { stale, message }) => {
                            println!(
                                "{label}> ready, {stale} pods pending manual restart (OnDelete): {message}"
                            );
                        }
                        _ => {
                            println!("{label}> ready");
                        }
                    },
                    Verdict::Failed { message } => {
                        eprintln!("{label}> FAILED: {message}");
                        if let Some(NodeDetail::ReadinessFailed {
                            missing_keys,
                            output,
                            ..
                        }) = detail
                        {
                            if !missing_keys.is_empty() {
                                eprintln!("{label}>   missing key(s): {}", missing_keys.join(", "),);
                            }
                            for line in output {
                                eprintln!("{label}>   | {line}");
                            }
                        }
                    }
                    Verdict::Cancelled { because } => {
                        let because = match because {
                            CancelReason::PredecessorFailed(rid) => {
                                format!("predecessor {rid} failed")
                            }
                            CancelReason::External => "external cancel".to_string(),
                        };
                        println!("{label}> cancelled ({because})");
                    }
                    Verdict::AwaitingInput { prompt } => {
                        println!("{label}> awaiting input: {prompt}");
                    }
                    Verdict::DriftDetected { message, .. } => {
                        println!("{label}> drift: {message}");
                    }
                }
            }
            DeployEvent::CrdRediscovery => {
                if self.verbose {
                    println!("crd> re-running API discovery");
                }
            }
            DeployEvent::PruneStart {
                resources,
                kept,
                delete,
                ..
            } => {
                for line in prune_lines(resources, kept, *delete) {
                    println!("{line}");
                }
            }
            DeployEvent::PruneKept { reason, .. } => {
                println!("prune> {reason}");
            }
            DeployEvent::Finalized {
                activation,
                previous,
            } => {
                if let Some(prev) = previous {
                    println!("activation> '{prev}' → Superseded");
                }
                println!("activation> '{activation}' → Active");
            }
            DeployEvent::Stopped { reason } => {
                eprintln!("stopped> {reason}");
            }
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => {
                let line = kix::cluster::watchdog::describe(*idle, in_flight);
                if *aborting {
                    eprintln!("stalled> {line}; giving up");
                } else {
                    eprintln!("stalled> {line}");
                }
            }
            DeployEvent::BestEffortFailed { what, message } => {
                eprintln!("warn> {what} failed: {message}");
            }
        }
        // Line format is unbuffered so CI logs land promptly.
        let _ = io::stdout().flush();
    }
}

pub struct JsonObserver {
    pub started_at: Instant,
}

impl JsonObserver {
    pub fn new(_verbose: bool) -> Self {
        Self {
            started_at: Instant::now(),
        }
    }
}

impl DeployObserver for JsonObserver {
    fn on_event(&self, event: &DeployEvent) {
        let elapsed_ms = self.started_at.elapsed().as_millis() as u64;
        let obj = match event {
            DeployEvent::PlanComputed { nodes, edges } => json!({
                "type": "plan",
                "elapsed_ms": elapsed_ms,
                "nodes": nodes
                    .iter()
                    .map(|n| json!({
                        "id": json_node_id(&n.id),
                        "kind": transition_kind_str(n.kind),
                        "package": n.meta.package,
                        "namespace": n.meta.namespace,
                        "import": n.meta.import_target.as_ref().map(|t| json!({
                            "kind": t.kind,
                            "name": t.name,
                            "apiVersion": t.api_version,
                            "namespace": t.namespace,
                        })),
                    }))
                    .collect::<Vec<_>>(),
                "edges": edges
                    .iter()
                    .map(|(dep, pred)| json!({
                        "dependent": json_node_id(dep),
                        "predecessor": json_node_id(pred),
                    }))
                    .collect::<Vec<_>>(),
            }),
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => {
                // Suppress mid-flight readiness-progress entirely: the log
                // emits one `created` + one `ready` event per resource and
                // nothing in between. Structured progress belongs in the TUI.
                if matches!(detail, Some(NodeDetail::ReadinessProgress(_))) {
                    return;
                }
                json!({
                    "type": "node",
                    "elapsed_ms": elapsed_ms,
                    "id": json_node_id(node),
                    "kind": transition_kind_str(*kind),
                    "verdict": json_verdict(verdict),
                    "detail": detail.as_ref().map(json_detail),
                })
            }
            DeployEvent::CrdRediscovery => json!({
                "type": "crd_rediscovery",
                "elapsed_ms": elapsed_ms,
            }),
            DeployEvent::PruneStart {
                count,
                resources,
                kept,
                delete,
            } => json!({
                "type": "prune_start",
                "elapsed_ms": elapsed_ms,
                "count": count,
                "delete": delete,
                "resources": resources.iter().map(|r| r.display_id()).collect::<Vec<_>>(),
                "kept": kept.iter().map(|r| r.display_id()).collect::<Vec<_>>(),
            }),
            DeployEvent::PruneKept { resource, reason } => json!({
                "type": "prune_kept",
                "elapsed_ms": elapsed_ms,
                "resource": resource.display_id(),
                "reason": reason,
            }),
            DeployEvent::Finalized {
                activation,
                previous,
            } => json!({
                "type": "finalized",
                "elapsed_ms": elapsed_ms,
                "activation": activation,
                "previous": previous,
            }),
            DeployEvent::Stopped { reason } => json!({
                "type": "stopped",
                "elapsed_ms": elapsed_ms,
                "reason": reason,
            }),
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => json!({
                "type": "stalled",
                "elapsed_ms": elapsed_ms,
                "idle_ms": idle.as_millis() as u64,
                "aborting": aborting,
                "in_flight": in_flight
                    .iter()
                    .map(|f| json!({
                        "node": node_label(&f.node),
                        "phase": f.phase.as_str(),
                        "since_ms": f.since.as_millis() as u64,
                    }))
                    .collect::<Vec<_>>(),
            }),
            DeployEvent::BestEffortFailed { what, message } => json!({
                "type": "best_effort_failed",
                "elapsed_ms": elapsed_ms,
                "what": what,
                "message": message,
            }),
        };
        println!("{obj}");
        let _ = io::stdout().flush();
    }
}

/// `LineObserver`'s lines for a `PruneStart`: the orphans prune deletes or
/// reports, then the ones no prune policy deletes.
fn prune_lines(resources: &[ResourceId], kept: &[ResourceId], delete: bool) -> Vec<String> {
    let mut lines = Vec::new();
    if !resources.is_empty() {
        let count = resources.len();
        lines.push(if delete {
            format!("prune> deleting {count} orphaned resources")
        } else {
            format!(
                "prune> {count} orphaned resources kept (warn-only; {})",
                super::deploy::KEPT_ORPHANS_HINT
            )
        });
        lines.extend(
            resources
                .iter()
                .map(|rid| format!("{}> orphan", rid.display_id())),
        );
    }
    if !kept.is_empty() {
        lines.push(format!(
            "prune> {} orphaned resources are never deleted automatically",
            kept.len()
        ));
        lines.extend(
            kept.iter()
                .map(|rid| format!("{}> orphan, kept", rid.display_id())),
        );
    }
    lines
}

fn node_label(id: &NodeId) -> String {
    match id {
        NodeId::Resource(rid) => rid.to_string(),
        NodeId::Synthetic(s) => format!("⟦{s}⟧"),
    }
}

fn json_node_id(id: &NodeId) -> serde_json::Value {
    match id {
        NodeId::Resource(rid) => json!({
            "kind": rid.kind,
            "namespace": rid.namespace,
            "name": rid.name,
        }),
        NodeId::Synthetic(s) => json!({ "synthetic": s }),
    }
}

fn transition_kind_str(k: TransitionKind) -> &'static str {
    match k {
        TransitionKind::Apply => "apply",
        TransitionKind::Skip => "skip",
        TransitionKind::Recreate => "recreate",
        TransitionKind::Migrate => "migrate",
        TransitionKind::Drain => "drain",
        TransitionKind::Delete => "delete",
        TransitionKind::Pause => "pause",
    }
}

fn json_verdict(v: &Verdict) -> serde_json::Value {
    match v {
        Verdict::Pending => json!({ "state": "pending" }),
        Verdict::Running => json!({ "state": "running" }),
        Verdict::Ready => json!({ "state": "ready" }),
        Verdict::Failed { message } => json!({ "state": "failed", "message": message }),
        Verdict::Cancelled { because } => {
            let reason = match because {
                CancelReason::PredecessorFailed(rid) => json!({
                    "predecessor_failed": json!({
                        "kind": rid.kind,
                        "namespace": rid.namespace,
                        "name": rid.name,
                    }),
                }),
                CancelReason::External => json!({ "external": true }),
            };
            json!({ "state": "cancelled", "because": reason })
        }
        Verdict::AwaitingInput { prompt } => {
            json!({ "state": "awaiting_input", "prompt": prompt })
        }
        Verdict::DriftDetected { since, message } => json!({
            "state": "drift",
            "since_ms": since.as_millis() as u64,
            "message": message,
        }),
    }
}

fn json_detail(detail: &NodeDetail) -> serde_json::Value {
    match detail {
        NodeDetail::Applied(action) => json!({
            "applied": apply_label(action),
        }),
        NodeDetail::ReadinessProgress(msg) => json!({ "readiness": msg }),
        NodeDetail::ApplyFailed(msg) => json!({ "apply_failed": msg }),
        NodeDetail::ReadinessTimeout { elapsed, message } => json!({
            "readiness_timeout": {
                "elapsed_ms": elapsed.as_millis() as u64,
                "message": message,
            },
        }),
        NodeDetail::ReadinessFailed {
            message,
            missing_keys,
            output,
        } => json!({
            "readiness_failed": {
                "message": message,
                "missing_keys": missing_keys,
                "output": output,
            },
        }),
        NodeDetail::SecretHydrated { keys } => json!({ "secret_hydrated": keys }),
        NodeDetail::SecretHydrationFailed(msg) => json!({ "secret_hydration_failed": msg }),
        NodeDetail::RecreatedInPlace { reason } => json!({ "recreated_in_place": reason }),
        NodeDetail::Rerun { reason } => json!({ "rerun": reason }),
        NodeDetail::PendingRestart { stale, message } => json!({
            "pending_restart": {
                "stale": stale,
                "message": message,
            },
        }),
    }
}

fn apply_label(action: &ApplyAction) -> &'static str {
    match action {
        ApplyAction::Created => "created",
        ApplyAction::Configured => "configured",
        ApplyAction::Unchanged => "unchanged",
        ApplyAction::Skipped => "skipped",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            name: name.into(),
            namespace: "app".into(),
        }
    }

    #[test]
    fn pending_restart_detail_json() {
        let detail = NodeDetail::PendingRestart {
            stale: 2,
            message: "2 pods run the previous template".into(),
        };
        assert_eq!(
            json_detail(&detail),
            json!({
                "pending_restart": {
                    "stale": 2,
                    "message": "2 pods run the previous template",
                },
            })
        );
    }

    /// Under warn-only, a kept orphan is not counted or listed with the
    /// orphans the policy reports.
    #[test]
    fn prune_lines_list_kept_orphans_apart() {
        let lines = prune_lines(
            &[rid("ConfigMap", "old")],
            &[rid("Namespace", "gone")],
            false,
        );
        assert_eq!(
            lines,
            vec![
                "prune> 1 orphaned resources kept (warn-only; `kix deploy --prune` or `kix gc` deletes them)",
                "ConfigMap/old@app> orphan",
                "prune> 1 orphaned resources are never deleted automatically",
                "Namespace/gone@app> orphan, kept",
            ]
        );
    }
}
