//! K8s Event emission for the DAG-streaming deploy (doc 99 Stage H).
//!
//! Wraps a [`kube::runtime::events::Recorder`] in a [`DeployObserver`]. Every
//! terminal node verdict, prune outcome, and lifecycle transition becomes an
//! Event attached to the Activation CR, so `kubectl describe activation` and
//! downstream log aggregators surface the full deploy timeline.
//!
//! The observer is deliberately fire-and-forget:
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
            kind: Some("Activation".to_string()),
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
        DeployEvent::PruneStart { count } => Some(KEvent {
            type_: EventType::Normal,
            reason: "PruneStart".into(),
            note: Some(format!("Pruning {count} orphaned resources")),
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
        DeployEvent::BestEffortFailed { what, message } => Some(KEvent {
            type_: EventType::Warning,
            reason: "BestEffortFailed".into(),
            note: Some(format!("{what} failed: {message}")),
            action: "Degraded".into(),
            secondary: None,
        }),
    }
}

/// Events for a node's verdict transition. Suppresses Pending and most
/// Running events; emits one Event per terminal verdict plus a few
/// mid-flight milestones (SOPS hydration, in-place recreate).
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
            _ => Some(KEvent {
                type_: EventType::Normal,
                reason: "ResourceReady".into(),
                note: Some(resource),
                action: "Ready".into(),
                secondary: None,
            }),
        },
        Verdict::Failed { message } => {
            let note = match detail {
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

fn node_label(id: &NodeId) -> String {
    match id {
        NodeId::Resource(rid) => rid.to_string(),
        NodeId::Synthetic(s) => format!("⟦{s}⟧"),
    }
}

// ── Composite observer ──────────────────────────────────────────────────────

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
