//! Operator observer — maps reconcile events to structured tracing output.

use kix::cluster::apply::ApplyAction;
use kix::cluster::reconcile::{ReconcileEvent, ReconcileObserver};

/// Observer that logs reconcile events via `tracing`.
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

impl ReconcileObserver for OperatorObserver {
    fn on_event(&self, event: &ReconcileEvent) {
        let name = &self.activation_name;
        match event {
            ReconcileEvent::WaveSkipped {
                wave_index,
                count,
                reason,
            } => {
                tracing::info!(
                    activation = name,
                    wave = wave_index + 1,
                    count,
                    reason,
                    "Wave skipped"
                );
            }
            ReconcileEvent::WaveUnchanged {
                wave_index, count, ..
            } => {
                tracing::debug!(
                    activation = name,
                    wave = wave_index + 1,
                    count,
                    "Wave unchanged"
                );
            }
            ReconcileEvent::WaveStart {
                wave_index,
                apply_count,
                total,
            } => {
                tracing::info!(
                    activation = name,
                    wave = wave_index + 1,
                    applying = apply_count,
                    total,
                    "Applying wave"
                );
            }
            ReconcileEvent::ResourceApplied {
                rid,
                action,
                import_target,
            } => {
                let action_str = match action {
                    ApplyAction::Created => "created",
                    ApplyAction::Configured => "configured",
                    ApplyAction::Unchanged => "unchanged",
                    ApplyAction::Skipped => "skipped",
                };
                tracing::info!(
                    activation = name,
                    resource = %rid,
                    action = action_str,
                    import_target = import_target.as_ref().map(|t| format!("{}/{}", t.kind, t.name)),
                    "Resource applied"
                );
            }
            ReconcileEvent::ResourceFailed { rid, error } => {
                tracing::error!(
                    activation = name,
                    resource = %rid,
                    error,
                    "Resource apply failed"
                );
            }
            ReconcileEvent::ReadinessWaiting { rid, import_target } => {
                tracing::debug!(
                    activation = name,
                    resource = %rid,
                    import_target = import_target.as_ref().map(|t| format!("{}/{}", t.kind, t.name)),
                    "Waiting for readiness"
                );
            }
            ReconcileEvent::ReadinessProgress {
                rid,
                import_target,
                message,
            } => {
                tracing::debug!(
                    activation = name,
                    resource = %rid,
                    import_target = import_target.as_ref().map(|t| format!("{}/{}", t.kind, t.name)),
                    status = message,
                    "Readiness progress"
                );
            }
            ReconcileEvent::ReadinessReady { rid, import_target } => {
                tracing::info!(
                    activation = name,
                    resource = %rid,
                    import_target = import_target.as_ref().map(|t| format!("{}/{}", t.kind, t.name)),
                    "Resource ready"
                );
            }
            ReconcileEvent::ReadinessTimeout {
                rid,
                elapsed,
                message,
                import_target,
            } => {
                tracing::warn!(
                    activation = name,
                    resource = %rid,
                    elapsed_secs = elapsed.as_secs(),
                    message,
                    import_target = import_target.as_ref().map(|t| format!("{}/{}", t.kind, t.name)),
                    "Readiness timeout"
                );
            }
            ReconcileEvent::ReadinessFailed {
                rid,
                message,
                import_target,
                missing_keys,
            } => {
                tracing::error!(
                    activation = name,
                    resource = %rid,
                    message,
                    import_target = import_target.as_ref().map(|t| format!("{}/{}", t.kind, t.name)),
                    missing_keys = ?missing_keys,
                    "Readiness failed"
                );
            }
            ReconcileEvent::WaveComplete { wave_index, record } => {
                tracing::info!(
                    activation = name,
                    wave = wave_index + 1,
                    applied = record.applied,
                    failed = record.failed,
                    total = record.resource_count,
                    "Wave complete"
                );
            }
            ReconcileEvent::CrdRediscovery => {
                tracing::info!(activation = name, "Re-running API discovery after CRD wave");
            }
            ReconcileEvent::PruneStart { count } => {
                tracing::info!(
                    activation = name,
                    count,
                    "Starting prune of orphaned resources"
                );
            }
            ReconcileEvent::PruneSkipped { rid, reason } => {
                tracing::info!(
                    activation = name,
                    resource = %rid,
                    reason,
                    "Prune skipped"
                );
            }
            ReconcileEvent::PruneOk { rid } => {
                tracing::info!(
                    activation = name,
                    resource = %rid,
                    "Pruned"
                );
            }
            ReconcileEvent::PruneFailed { rid, error } => {
                tracing::error!(
                    activation = name,
                    resource = %rid,
                    error,
                    "Prune failed"
                );
            }
            ReconcileEvent::Finalized { activation, old } => {
                if let Some(old) = old {
                    tracing::info!(
                        activation = name,
                        new = activation.as_str(),
                        old = old.as_str(),
                        "Activation finalized"
                    );
                } else {
                    tracing::info!(
                        activation = name,
                        new = activation.as_str(),
                        "Activation finalized (first deploy)"
                    );
                }
            }
            ReconcileEvent::SecretHydrated { rid, keys } => {
                tracing::info!(
                    activation = name,
                    resource = %rid,
                    keys,
                    "Secret hydrated from SOPS"
                );
            }
            ReconcileEvent::SecretHydrationFailed { rid, error } => {
                tracing::error!(
                    activation = name,
                    resource = %rid,
                    error,
                    "Secret hydration failed"
                );
            }
            ReconcileEvent::Stopped { reason } => {
                tracing::error!(activation = name, reason, "Deploy stopped");
            }
        }
    }
}
