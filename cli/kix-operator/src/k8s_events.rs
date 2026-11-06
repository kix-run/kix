//! Kubernetes Event emission for graph-streaming deploys.
//!
//! Wraps a [`kube::runtime::events::Recorder`] in a [`DeployObserver`]. Every
//! terminal node verdict, prune outcome, and lifecycle transition becomes an
//! Event attached to the Activation CR, so `kubectl describe activation` and
//! downstream log aggregators surface the full deploy timeline.
//!
//! The observer is fire-and-forget:
//!   - [`DeployObserver::on_event`] is sync, so each call spawns a short
//!     async task that publishes the Event via the Recorder.
//!   - Failures are logged via `tracing` and dropped; K8s Events are best-
//!     effort telemetry, not part of deploy correctness.
//!
//! Noise budget: only *interesting* verdicts emit. Pending / Running are
//! omitted (they'd flood the cluster) except when Running carries a
//! first-class sub-event like a SOPS hydration or an in-place recreate.

use std::sync::Arc;

use k8s_openapi::api::core::v1::ObjectReference;
use kube::runtime::events::{Event as KEvent, EventType, Recorder, Reporter};

use kix::cluster::stream::{
    CancelReason, DeployEvent, DeployObserver, NodeDetail, NodeId, Verdict,
};
use kix::manifest::types::ResourceId;

/// Controller identity reported on every Event's `reportingComponent`.
const REPORTER_CONTROLLER: &str = "kix-operator";

pub struct K8sEventObserver {
    recorder: Arc<Recorder>,
    reference: ObjectReference,
}

impl K8sEventObserver {
    /// Build a Recorder for `activation` and wrap it as a DeployObserver.
    ///
    /// The ObjectReference fields (kind, apiVersion, namespace, name, uid)
    /// are filled from the Activation CR's own metadata so `kubectl describe
    /// activation <name>` shows the emitted Events inline.
    pub fn new(
        client: kube::Client,
        activation: &kube::api::DynamicObject,
        activation_api_version: &str,
        instance: Option<String>,
    ) -> Self {
        let reference = ObjectReference {
            kind: Some(kix::manifest::lifecycle::RECORD_KIND.to_string()),
            api_version: Some(activation_api_version.to_string()),
            name: activation.metadata.name.clone(),
            namespace: activation.metadata.namespace.clone(),
            uid: activation.metadata.uid.clone(),
            resource_version: activation.metadata.resource_version.clone(),
            ..Default::default()
        };
        let reporter = Reporter {
            controller: REPORTER_CONTROLLER.to_string(),
            instance,
        };
        let recorder = Recorder::new(client, reporter);
        Self {
            recorder: Arc::new(recorder),
            reference,
        }
    }

    /// Publish one Warning Event with `reason` and `note` on the record,
    /// waiting for the apiserver's answer. A failure to publish is logged,
    /// since the record's status already carries the note.
    pub async fn warn_now(&self, reason: &str, note: &str) {
        let ev = KEvent {
            type_: EventType::Warning,
            reason: reason.to_string(),
            note: Some(note.to_string()),
            action: reason.to_string(),
            secondary: None,
        };
        if let Err(e) = self.recorder.publish(&ev, &self.reference).await {
            tracing::debug!(error = %e, reason, "failed to publish K8s Event");
        }
    }

    fn spawn_publish(&self, ev: KEvent) {
        let recorder = self.recorder.clone();
        let reference = self.reference.clone();
        // Fire-and-forget: if the publish fails, log and move on. Events are
        // telemetry; a dropped Event must never fail the deploy.
        tokio::spawn(async move {
            if let Err(e) = recorder.publish(&ev, &reference).await {
                tracing::debug!(error = %e, "failed to publish K8s Event");
            }
        });
    }
}

impl DeployObserver for K8sEventObserver {
    fn on_event(&self, event: &DeployEvent) {
        let Some(ev) = to_k8s_event(event) else {
            return;
        };
        self.spawn_publish(ev);
    }
}

/// Translate a [`DeployEvent`] into a K8s Event, or `None` to suppress.
fn to_k8s_event(event: &DeployEvent) -> Option<KEvent> {
    match event {
        DeployEvent::PlanComputed { nodes, edges } => Some(KEvent {
            type_: EventType::Normal,
            reason: "PlanComputed".into(),
            note: Some(format!(
                "Scheduler plan: {} nodes, {} edges",
                nodes.len(),
                edges.len()
            )),
            action: "Scheduled".into(),
            secondary: None,
        }),
        DeployEvent::NodeStateChanged {
            node,
            kind: _,
            verdict,
            detail,
        } => node_event(node, verdict, detail.as_ref()),
        DeployEvent::CrdRediscovery => Some(KEvent {
            type_: EventType::Normal,
            reason: "CrdRediscovery".into(),
            note: Some("Re-ran API discovery after CRD applied".into()),
            action: "Rediscovered".into(),
            secondary: None,
        }),
        DeployEvent::PruneStart {
            resources,
            kept,
            delete,
            ..
        } => Some(KEvent {
            type_: EventType::Normal,
            reason: "PruneStart".into(),
            note: Some(prune_note(resources, kept, *delete)),
            action: "Pruning".into(),
            secondary: None,
        }),
        DeployEvent::PruneKept { reason, .. } => Some(KEvent {
            type_: EventType::Normal,
            reason: "PruneKept".into(),
            note: Some(reason.clone()),
            action: "Pruning".into(),
            secondary: None,
        }),
        DeployEvent::Finalized {
            activation,
            previous,
        } => Some(KEvent {
            type_: EventType::Normal,
            reason: "Finalized".into(),
            note: Some(match previous {
                Some(prev) => format!("Activation '{activation}' → Active; '{prev}' → Superseded"),
                None => format!("Activation '{activation}' → Active (first deploy)"),
            }),
            action: "Finalized".into(),
            secondary: None,
        }),
        DeployEvent::Stopped { reason } => Some(KEvent {
            type_: EventType::Warning,
            reason: "DeployStopped".into(),
            note: Some(reason.clone()),
            action: "Stopped".into(),
            secondary: None,
        }),
        DeployEvent::Stalled {
            idle,
            in_flight,
            aborting,
        } => Some(KEvent {
            type_: EventType::Warning,
            reason: if *aborting {
                "DeployStallAbort".into()
            } else {
                "DeployStalled".into()
            },
            note: Some(kix::cluster::watchdog::describe(*idle, in_flight)),
            action: "Stalled".into(),
            secondary: None,
        }),
        // A wait within the readiness budget is not an event on the record;
        // the stall and timeout events cover a wait that goes wrong.
        DeployEvent::Waiting { .. } => None,
        DeployEvent::BestEffortFailed { what, message } => Some(KEvent {
            type_: EventType::Warning,
            reason: "BestEffortFailed".into(),
            note: Some(format!("{what} failed: {message}")),
            action: "Degraded".into(),
            secondary: None,
        }),
        DeployEvent::FieldsNotKept { resource, fields } => Some(KEvent {
            type_: EventType::Warning,
            reason: "FieldsNotKept".into(),
            note: Some(kix::cluster::kept::describe(&resource.display_id(), fields)),
            action: "Applied".into(),
            secondary: None,
        }),
    }
}

/// Build a Kubernetes Event for a node's verdict transition, or return `None`
/// to suppress.
///
/// Suppresses `Pending` and most `Running` transitions, emitting one Event per
/// terminal verdict plus selected mid-flight milestones (SOPS hydration and
/// in-place recreation).
fn node_event(node: &NodeId, verdict: &Verdict, detail: Option<&NodeDetail>) -> Option<KEvent> {
    let resource = node_label(node);
    match verdict {
        Verdict::Pending => None,
        Verdict::Running => match detail? {
            NodeDetail::SecretHydrated { keys } => Some(KEvent {
                type_: EventType::Normal,
                reason: "SecretHydrated".into(),
                note: Some(format!("Hydrated {keys} keys from SOPS for {resource}")),
                action: "Hydrated".into(),
                secondary: None,
            }),
            NodeDetail::SecretHydrationFailed(msg) => Some(KEvent {
                type_: EventType::Warning,
                reason: "SecretHydrationFailed".into(),
                note: Some(format!("{resource}: {msg}")),
                action: "Failed".into(),
                secondary: None,
            }),
            _ => None,
        },
        Verdict::Ready => match detail {
            Some(NodeDetail::RecreatedInPlace { reason }) => Some(KEvent {
                type_: EventType::Warning,
                reason: "RecreatedInPlace".into(),
                note: Some(format!(
                    "{resource} recreated due to immutable-field conflict: {reason}"
                )),
                action: "Recreated".into(),
                secondary: None,
            }),
            Some(NodeDetail::Rerun { reason }) => Some(KEvent {
                type_: EventType::Normal,
                reason: "Rerun".into(),
                note: Some(format!("{resource} ran again: {reason}")),
                action: "Rerun".into(),
                secondary: None,
            }),
            _ => Some(KEvent {
                type_: EventType::Normal,
                reason: "ResourceReady".into(),
                note: Some(resource),
                action: "Ready".into(),
                secondary: None,
            }),
        },
        Verdict::Failed { message } => {
            let mut note = match detail {
                Some(NodeDetail::ReadinessFailed { missing_keys, .. })
                    if !missing_keys.is_empty() =>
                {
                    format!(
                        "{resource}: {message} (missing keys: {})",
                        missing_keys.join(", ")
                    )
                }
                _ => format!("{resource}: {message}"),
            };
            if let Some(NodeDetail::ReadinessFailed { output, .. }) = detail
                && !output.is_empty()
            {
                note.push('\n');
                note.push_str(&output.join("\n"));
            }
            // Event notes are capped at 1 KiB by the API server; a note over
            // the cap is rejected and the event is dropped. Keep the head: the
            // resource, the reason, and the first output lines.
            const NOTE_CAP: usize = 900;
            if note.len() > NOTE_CAP {
                let mut cut = NOTE_CAP;
                while !note.is_char_boundary(cut) {
                    cut -= 1;
                }
                note.truncate(cut);
                note.push_str("\n... (truncated, see kubectl logs)");
            }
            Some(KEvent {
                type_: EventType::Warning,
                reason: "NodeFailed".into(),
                note: Some(note),
                action: "Failed".into(),
                secondary: None,
            })
        }
        Verdict::Cancelled { because } => {
            let reason_text = match because {
                CancelReason::PredecessorFailed(rid) => format!("predecessor {rid} failed"),
                CancelReason::External => "external cancel".to_string(),
            };
            Some(KEvent {
                type_: EventType::Warning,
                reason: "NodeCancelled".into(),
                note: Some(format!("{resource}: {reason_text}")),
                action: "Cancelled".into(),
                secondary: None,
            })
        }
        Verdict::AwaitingInput { prompt } => Some(KEvent {
            type_: EventType::Normal,
            reason: "AwaitingInput".into(),
            note: Some(format!("{resource}: {prompt}")),
            action: "Awaiting".into(),
            secondary: None,
        }),
        Verdict::DriftDetected { message, .. } => Some(KEvent {
            type_: EventType::Warning,
            reason: "DriftDetected".into(),
            note: Some(format!("{resource}: {message}")),
            action: "Drifted".into(),
            secondary: None,
        }),
    }
}

/// Format the `PruneStart` Event note, listing at most `SHOWN` resources per
/// category so the note stays within the API server's 1 KiB Event note limit.
fn prune_note(resources: &[ResourceId], kept: &[ResourceId], delete: bool) -> String {
    const SHOWN: usize = 5;
    let names = |rids: &[ResourceId]| {
        let mut names: Vec<String> = rids.iter().take(SHOWN).map(|r| r.display_id()).collect();
        if rids.len() > SHOWN {
            names.push(format!("and {} more", rids.len() - SHOWN));
        }
        names.join(", ")
    };
    let mut parts = Vec::new();
    if !resources.is_empty() {
        let verb = if delete { "Pruning" } else { "Reporting" };
        parts.push(format!(
            "{verb} {} orphaned resources: {}",
            resources.len(),
            names(resources)
        ));
    }
    if !kept.is_empty() {
        parts.push(format!(
            "Keeping {} orphaned resources that are never deleted automatically: {}",
            kept.len(),
            names(kept)
        ));
    }
    parts.join(". ")
}

fn node_label(id: &NodeId) -> String {
    match id {
        NodeId::Resource(rid) => rid.to_string(),
        NodeId::Synthetic(s) => format!("⟦{s}⟧"),
    }
}

/// Dispatches each [`DeployEvent`] to every wrapped observer.
///
/// Used in the operator to run `OperatorObserver` (tracing) and
/// `K8sEventObserver` (K8s Events) side by side over the same stream.
pub struct CompositeObserver {
    observers: Vec<Arc<dyn DeployObserver>>,
}

impl CompositeObserver {
    pub fn new(observers: Vec<Arc<dyn DeployObserver>>) -> Self {
        Self { observers }
    }
}

impl DeployObserver for CompositeObserver {
    fn on_event(&self, event: &DeployEvent) {
        for o in &self.observers {
            o.on_event(event);
        }
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

    /// A kept orphan is named as kept, not as a resource being pruned.
    #[test]
    fn prune_start_names_kept_orphans_apart() {
        let event = to_k8s_event(&DeployEvent::PruneStart {
            count: 1,
            resources: vec![rid("ConfigMap", "old")],
            kept: vec![rid("Namespace", "gone")],
            delete: true,
        })
        .unwrap();
        assert_eq!(
            event.note.as_deref(),
            Some(
                "Pruning 1 orphaned resources: ConfigMap/old@app. Keeping 1 orphaned \
                 resources that are never deleted automatically: Namespace/gone@app"
            )
        );
    }

    /// Both lists together stay under the apiserver's 1 KiB note cap.
    #[test]
    fn prune_note_stays_under_the_event_note_cap() {
        let long = |kind: &str| -> Vec<ResourceId> {
            (0..50)
                .map(|i| rid(kind, &format!("{}-{i}", "x".repeat(60))))
                .collect()
        };
        let note = prune_note(&long("ConfigMap"), &long("Namespace"), true);
        assert!(note.len() < 1024, "{} bytes", note.len());
    }
}
