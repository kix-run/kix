//! Map graph-streaming [`DeployEvent`]s to structured
//! tracing output.
//!
//! Every terminal verdict, prune outcome, and lifecycle transition becomes a
//! span-tagged tracing event carrying the Activation name. The shape mirrors
//! the JSON log format used by the CLI so consumers downstream can correlate
//! CLI and operator logs on the same deploy.

use kix::cluster::apply::ApplyAction;
use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, NodeDetail, NodeId, Verdict,
};

pub struct OperatorObserver {
    activation_name: String,
}

impl OperatorObserver {
    pub fn new(activation_name: &str) -> Self {
        Self {
            activation_name: activation_name.to_string(),
        }
    }
}

impl DeployObserver for OperatorObserver {
    fn on_event(&self, event: &DeployEvent) {
        let activation = self.activation_name.as_str();
        match event {
            DeployEvent::PlanComputed { nodes, edges } => {
                tracing::info!(
                    activation,
                    nodes = nodes.len(),
                    edges = edges.len(),
                    "Plan computed"
                );
            }
            DeployEvent::NodeStateChanged {
                node,
                kind,
                verdict,
                detail,
            } => {
                let resource = node_label(node);
                let kind_str = match kind {
                    kix::cluster::stream::TransitionKind::Apply => "apply",
                    kix::cluster::stream::TransitionKind::Skip => "skip",
                    kix::cluster::stream::TransitionKind::Recreate => "recreate",
                    kix::cluster::stream::TransitionKind::Migrate => "migrate",
                    kix::cluster::stream::TransitionKind::Drain => "drain",
                    kix::cluster::stream::TransitionKind::Delete => "delete",
                    kix::cluster::stream::TransitionKind::Pause => "pause",
                    kix::cluster::stream::TransitionKind::Wait => "wait",
                };
                match verdict {
                    Verdict::Pending => {}
                    Verdict::Running => match detail {
                        Some(NodeDetail::Applied(action)) => {
                            tracing::info!(
                                activation,
                                resource = %resource,
                                kind = kind_str,
                                action = apply_label(action),
                                "Resource applied"
                            );
                        }
                        Some(NodeDetail::SecretHydrated { keys }) => {
                            tracing::info!(
                                activation,
                                resource = %resource,
                                keys = *keys,
                                "Secret hydrated from SOPS"
                            );
                        }
                        Some(NodeDetail::ReadinessProgress(msg)) => {
                            tracing::debug!(
                                activation,
                                resource = %resource,
                                status = msg.as_str(),
                                "Readiness progress"
                            );
                        }
                        _ => {}
                    },
                    Verdict::Ready => match detail {
                        Some(NodeDetail::RecreatedInPlace { reason }) => {
                            tracing::warn!(
                                activation,
                                resource = %resource,
                                reason = reason.as_str(),
                                "Resource recreated in place due to immutable-field conflict"
                            );
                        }
                        _ => {
                            tracing::info!(
                                activation,
                                resource = %resource,
                                kind = kind_str,
                                "Resource ready"
                            );
                        }
                    },
                    Verdict::Failed { message } => {
                        let (missing_keys, output) = if let Some(NodeDetail::ReadinessFailed {
                            missing_keys,
                            output,
                            ..
                        }) = detail
                        {
                            (Some(missing_keys.clone()), Some(output.join("\n")))
                        } else {
                            (None, None)
                        };
                        tracing::error!(
                            activation,
                            resource = %resource,
                            kind = kind_str,
                            message = message.as_str(),
                            missing_keys = ?missing_keys,
                            output = ?output,
                            "Node failed"
                        );
                    }
                    Verdict::Cancelled { because } => {
                        let reason = match because {
                            CancelReason::PredecessorFailed(rid) => {
                                format!("predecessor {rid} failed")
                            }
                            CancelReason::External => "external cancel".to_string(),
                        };
                        tracing::warn!(
                            activation,
                            resource = %resource,
                            reason = %reason,
                            "Node cancelled"
                        );
                    }
                    Verdict::AwaitingInput { prompt } => {
                        tracing::info!(
                            activation,
                            resource = %resource,
                            prompt = prompt.as_str(),
                            "Node awaiting input"
                        );
                    }
                    Verdict::DriftDetected { message, .. } => {
                        tracing::warn!(
                            activation,
                            resource = %resource,
                            message = message.as_str(),
                            "Drift detected"
                        );
                    }
                }
            }
            DeployEvent::CrdRediscovery => {
                tracing::info!(activation, "Re-running API discovery after CRD");
            }
            DeployEvent::PruneStart {
                count,
                resources,
                kept,
                delete,
            } => {
                let names: Vec<String> = resources.iter().map(|r| r.display_id()).collect();
                let kept: Vec<String> = kept.iter().map(|r| r.display_id()).collect();
                tracing::info!(activation, count = *count, delete = *delete, resources = ?names, kept = ?kept, "Starting prune");
            }
            DeployEvent::PruneKept { resource, reason } => {
                tracing::info!(activation, resource = %resource, "prune: {reason}");
            }
            DeployEvent::Finalized {
                activation: new,
                previous,
            } => {
                if let Some(prev) = previous {
                    tracing::info!(
                        activation,
                        new = new.as_str(),
                        old = prev.as_str(),
                        "Activation finalized"
                    );
                } else {
                    tracing::info!(
                        activation,
                        new = new.as_str(),
                        "Activation finalized (first deploy)"
                    );
                }
            }
            DeployEvent::Stopped { reason } => {
                tracing::error!(activation, reason = reason.as_str(), "Deploy stopped");
            }
            DeployEvent::Stalled {
                idle,
                in_flight,
                aborting,
            } => {
                let waiting_on = kix::cluster::watchdog::describe(*idle, in_flight);
                if *aborting {
                    tracing::error!(activation, idle_s = idle.as_secs(), %waiting_on, "Deploy stalled; giving up");
                } else {
                    tracing::warn!(activation, idle_s = idle.as_secs(), %waiting_on, "Deploy stalled");
                }
            }
            DeployEvent::Waiting {
                node,
                phase,
                since,
                status,
                budget,
            } => {
                let waiting = kix::cluster::watchdog::describe_wait(
                    node,
                    *phase,
                    *since,
                    status.as_deref(),
                    *budget,
                );
                tracing::info!(activation, %waiting, "Deploy waiting");
            }
            DeployEvent::BestEffortFailed { what, message } => {
                tracing::warn!(
                    activation,
                    what = what.as_str(),
                    message = message.as_str(),
                    "Best-effort write failed"
                );
            }
        }
    }
}

fn node_label(id: &NodeId) -> String {
    match id {
        NodeId::Resource(rid) => rid.to_string(),
        NodeId::Synthetic(s) => format!("⟦{s}⟧"),
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
