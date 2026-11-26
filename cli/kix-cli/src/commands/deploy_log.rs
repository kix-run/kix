//! Provide non-interactive deploy observers.
//!
//! Two output modes exist alongside the colored [`StreamCliObserver`](super::deploy::StreamCliObserver):
//!
//! - [`LineObserver`] prints one line per terminal verdict, phase boundary,
//!   prune event, or finalization without ANSI codes or cursor motion. Kix uses
//!   it automatically when `--log-format=pretty` is requested on a non-TTY stdout.
//! - [`JsonObserver`] flushes one NDJSON [`kix::cluster::deploy_log::Line`] per
//!   [`DeployEvent`] (excluding readiness progress events), followed by a
//!   `summary` object with the counts and outcome. Every object carries `type`,
//!   `elapsed_ms`, and `schema_version`.
//!
//! Both observers are allocation-light and track only a `started_at` timestamp
//! for elapsed fields.

use std::time::Instant;

use kix::cluster::apply::ApplyAction;
use kix::cluster::binding::Connection;
use kix::cluster::deploy_log::Line;
use kix::cluster::stream::{
    DeployEvent, DeployObserver, DeployResult, HALTED_ON_FAILURE, NodeDetail, TransitionKind,
    Verdict,
};
use kix::manifest::types::ResourceId;

pub struct LineObserver {
    pub verbose: bool,
    /// The Kix cluster being deployed, named in the command that deletes
    /// kept orphans.
    pub cluster: String,
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
                let label = node.to_string();
                let tag = kind.tag().map(|t| format!("{t} ")).unwrap_or_default();
                if *kind == TransitionKind::Delete
                    && let Some(line) = delete_line(verdict, detail.as_ref())
                {
                    println!("{label}> {line}");
                    return;
                }
                match verdict {
                    Verdict::Pending => {}
                    Verdict::Running => match detail {
                        Some(NodeDetail::Applied(action)) => {
                            println!("{label}> {tag}{action}");
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
                        Some(NodeDetail::PendingRestart { message, .. }) => {
                            println!("{label}> ready, restart pending: {message}");
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
                        println!("{label}> {}", super::deploy::held_back(because));
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
                for line in prune_lines(resources, kept, *delete, &self.cluster) {
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
            // The failed node's line already carries a halting failure.
            DeployEvent::Stopped { reason } if !reason.starts_with(HALTED_ON_FAILURE) => {
                eprintln!("stopped> {reason}");
            }
            DeployEvent::Stopped { .. } => {}
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
            DeployEvent::Waiting {
                node,
                phase,
                since,
                status,
                budget,
                holds,
                holds_total,
            } => {
                let line = kix::cluster::watchdog::describe_wait(
                    node,
                    *phase,
                    *since,
                    status.as_deref(),
                    *budget,
                    holds,
                    *holds_total,
                );
                println!("waiting> {line}");
            }
            DeployEvent::BestEffortFailed { what, message } => {
                eprintln!("warn> {what} failed: {message}");
            }
            DeployEvent::FieldsNotKept { resource, fields } => {
                eprintln!(
                    "warn> {}",
                    kix::cluster::kept::describe(&resource.display_id(), fields)
                );
            }
        }
    }
}

pub struct JsonObserver {
    started_at: Instant,
}

impl JsonObserver {
    /// Create an observer that measures elapsed time from now.
    pub fn new() -> Self {
        Self {
            started_at: Instant::now(),
        }
    }

    /// Print the line that names the Kubernetes cluster of `connection`.
    pub fn kubernetes(&self, connection: &Connection) {
        let elapsed_ms = self.started_at.elapsed().as_millis() as u64;
        println!("{}", json_line(&Line::kubernetes(connection, elapsed_ms)));
    }

    /// Print the summary line of a deploy that has nothing to apply.
    pub fn nothing_to_apply(&self, unchanged: usize) {
        let elapsed_ms = self.started_at.elapsed().as_millis() as u64;
        println!(
            "{}",
            json_line(&Line::nothing_to_apply(unchanged, elapsed_ms))
        );
    }

    /// Print the final summary line for the deploy run.
    pub fn summary(&self, counts: &DeployResult, dry_run: bool, succeeded: bool) {
        let elapsed_ms = self.started_at.elapsed().as_millis() as u64;
        println!(
            "{}",
            json_line(&Line::summary(counts, dry_run, succeeded, elapsed_ms))
        );
    }
}

impl DeployObserver for JsonObserver {
    fn on_event(&self, event: &DeployEvent) {
        let elapsed_ms = self.started_at.elapsed().as_millis() as u64;
        if let Some(line) = Line::of(event, elapsed_ms) {
            println!("{}", json_line(&line));
        }
    }
}

/// Serialize `line` as a single JSON line with sorted keys.
fn json_line(line: &Line) -> String {
    serde_json::to_value(line)
        .expect("a log line serializes")
        .to_string()
}

/// Return the text after `<object>> ` for a prune delete that is waiting
/// for its object to be gone or is done, or `None` for a verdict the other
/// node lines cover.
pub(crate) fn delete_line(verdict: &Verdict, detail: Option<&NodeDetail>) -> Option<String> {
    match (verdict, detail) {
        (Verdict::Running, Some(NodeDetail::ReadinessProgress(status))) => Some(deleting(status)),
        (Verdict::Ready, Some(NodeDetail::AlreadyGone(why))) => Some(why.clone()),
        (Verdict::Ready, _) => Some("deleted".to_string()),
        _ => None,
    }
}

/// Describe a delete that waits for its object to be gone, given what the
/// object waits for, such as `being deleted, waiting for finalizer.keda.sh`.
pub(crate) fn deleting(status: &str) -> String {
    match status.strip_prefix("being deleted") {
        Some(rest) => format!("deleting{rest}"),
        None => format!("deleting, {status}"),
    }
}

/// Format `PruneStart` lines for `LineObserver`, listing deleted or reported
/// orphans followed by protected orphans.
fn prune_lines(
    resources: &[ResourceId],
    kept: &[ResourceId],
    delete: bool,
    cluster: &str,
) -> Vec<String> {
    let mut lines = Vec::new();
    if !resources.is_empty() {
        let count = resources.len();
        lines.push(if delete {
            format!("prune> deleting {count} object(s) that left the build")
        } else {
            format!(
                "prune> {count} object(s) left the build, {}",
                crate::plan::kept_orphans_fate(cluster)
            )
        });
        let each = if delete {
            "left the build, will be deleted"
        } else {
            "left the build, still on the cluster"
        };
        lines.extend(
            resources
                .iter()
                .map(|rid| format!("{}> {each}", rid.display_id())),
        );
    }
    if !kept.is_empty() {
        lines.push(format!(
            "prune> {} object(s) left the build and are never deleted automatically",
            kept.len()
        ));
        lines.extend(kept.iter().map(|rid| {
            format!(
                "{}> left the build, kept (never deleted automatically)",
                rid.display_id()
            )
        }));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::kept::{NotKept, NotKeptField};
    use kix::cluster::stream::{CancelReason, NodeId, TransitionKind};

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            group: String::new(),
            kind: kind.into(),
            name: name.into(),
            namespace: "app".into(),
        }
    }

    fn node(kind: &str, name: &str) -> NodeId {
        NodeId::Resource(rid(kind, name))
    }

    fn state(
        id: NodeId,
        kind: TransitionKind,
        verdict: Verdict,
        detail: Option<NodeDetail>,
    ) -> DeployEvent {
        DeployEvent::NodeStateChanged {
            node: id,
            kind,
            verdict,
            detail,
        }
    }

    /// Build a synthetic stream covering every `DeployEvent`, `Verdict`, and
    /// `NodeDetail` variant.
    fn every_event() -> Vec<DeployEvent> {
        use kix::cluster::readiness::ImportTarget;
        use kix::cluster::stream::{InFlight, NodeMeta, Phase, PlanNode};
        use std::time::Duration;
        let crd = NodeId::Resource(ResourceId {
            group: "apiextensions.k8s.io".into(),
            kind: "CustomResourceDefinition".into(),
            name: "things.example.com".into(),
            namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
        });
        let gate = NodeId::Synthetic("pause-1".into());
        let web = || node("Deployment", "web");
        vec![
            DeployEvent::PlanComputed {
                nodes: vec![
                    PlanNode {
                        id: web(),
                        kind: TransitionKind::Apply,
                        meta: NodeMeta {
                            package: Some("web".into()),
                            namespace: Some("app".into()),
                            import_target: None,
                        },
                    },
                    PlanNode {
                        id: crd.clone(),
                        kind: TransitionKind::Skip,
                        meta: NodeMeta {
                            package: Some("crds".into()),
                            namespace: None,
                            import_target: Some(ImportTarget {
                                kind: "CustomResourceDefinition".into(),
                                api_version: "apiextensions.k8s.io/v1".into(),
                                name: "things.example.com".into(),
                                namespace: None,
                                expected_keys: vec!["unused".into()],
                                served_versions: vec!["v1".into()],
                                platform: None,
                            }),
                        },
                    },
                    PlanNode {
                        id: gate.clone(),
                        kind: TransitionKind::Pause,
                        meta: NodeMeta {
                            package: None,
                            namespace: None,
                            import_target: None,
                        },
                    },
                    PlanNode {
                        id: node("ImportMarker", "db-creds"),
                        kind: TransitionKind::Apply,
                        meta: NodeMeta {
                            package: Some("web".into()),
                            namespace: Some("app".into()),
                            import_target: Some(ImportTarget {
                                kind: "Secret".into(),
                                api_version: "v1".into(),
                                name: "db-creds".into(),
                                namespace: Some("app".into()),
                                expected_keys: vec!["password".into()],
                                served_versions: vec![],
                                platform: None,
                            }),
                        },
                    },
                ],
                edges: vec![(web(), crd.clone()), (gate.clone(), web())],
            },
            state(web(), TransitionKind::Apply, Verdict::Pending, None),
            state(
                web(),
                TransitionKind::Apply,
                Verdict::Running,
                Some(NodeDetail::Applied(ApplyAction::Created)),
            ),
            state(
                web(),
                TransitionKind::Apply,
                Verdict::Running,
                Some(NodeDetail::ReadinessProgress("1/2 ready".into())),
            ),
            state(
                web(),
                TransitionKind::Apply,
                Verdict::Ready,
                Some(NodeDetail::Applied(ApplyAction::Configured)),
            ),
            state(
                crd.clone(),
                TransitionKind::Skip,
                Verdict::Ready,
                Some(NodeDetail::Applied(ApplyAction::Unchanged)),
            ),
            state(
                node("Job", "probe"),
                TransitionKind::Recreate,
                Verdict::Ready,
                Some(NodeDetail::Rerun {
                    reason: "its last run failed".into(),
                }),
            ),
            state(
                node("StatefulSet", "db"),
                TransitionKind::Migrate,
                Verdict::Ready,
                Some(NodeDetail::RecreatedInPlace {
                    reason: "spec.selector is immutable".into(),
                }),
            ),
            state(
                node("DaemonSet", "agent"),
                TransitionKind::Apply,
                Verdict::Ready,
                Some(NodeDetail::PendingRestart {
                    stale: Some(2),
                    message: "OnDelete".into(),
                }),
            ),
            state(
                node("VirtualMachine", "demo"),
                TransitionKind::Apply,
                Verdict::Ready,
                Some(NodeDetail::PendingRestart {
                    stale: None,
                    message: "its controller set RestartRequired=True".into(),
                }),
            ),
            state(
                node("Secret", "creds"),
                TransitionKind::Apply,
                Verdict::Running,
                Some(NodeDetail::SecretHydrated { keys: 3 }),
            ),
            state(
                node("Secret", "creds"),
                TransitionKind::Apply,
                Verdict::Failed {
                    message: "cannot decrypt".into(),
                },
                Some(NodeDetail::SecretHydrationFailed("no key".into())),
            ),
            state(
                node("Service", "web"),
                TransitionKind::Apply,
                Verdict::Failed {
                    message: "refused".into(),
                },
                Some(NodeDetail::ApplyFailed("field is immutable".into())),
            ),
            state(
                node("Deployment", "slow"),
                TransitionKind::Apply,
                Verdict::Failed {
                    message: "timed out".into(),
                },
                Some(NodeDetail::ReadinessTimeout {
                    elapsed: Duration::from_secs(300),
                    message: "0/1 ready".into(),
                }),
            ),
            state(
                node("Job", "check"),
                TransitionKind::Apply,
                Verdict::Failed {
                    message: "probe failed".into(),
                },
                Some(NodeDetail::ReadinessFailed {
                    message: "probe failed".into(),
                    missing_keys: vec!["password".into()],
                    output: vec!["FAIL: \"quoted\" \u{1b}[31m".into()],
                }),
            ),
            state(
                node("ScaledObject", "worker"),
                TransitionKind::Delete,
                Verdict::Failed {
                    message: "[K2794] still being deleted".into(),
                },
                Some(NodeDetail::DeletionUnfinished {
                    elapsed: Duration::from_secs(180),
                    finalizers: vec!["finalizer.keda.sh".into()],
                    controllers: vec![
                        kix::cluster::readiness::Controller {
                            id: rid("Deployment", "keda-operator"),
                            state: kix::cluster::readiness::ControllerState::NotReady(
                                "0/1 ready".into(),
                            ),
                        },
                        kix::cluster::readiness::Controller {
                            id: rid("Deployment", "keda-admission"),
                            state: kix::cluster::readiness::ControllerState::Missing,
                        },
                    ],
                    message: "[K2794] still being deleted".into(),
                }),
            ),
            state(
                node("Widget", "w"),
                TransitionKind::Delete,
                Verdict::Ready,
                Some(NodeDetail::AlreadyGone(
                    "already gone (Kubernetes does not recognize its kind)".into(),
                )),
            ),
            state(
                node("Pod", "after"),
                TransitionKind::Drain,
                Verdict::Cancelled {
                    because: CancelReason::PredecessorFailed(rid("Job", "check")),
                },
                None,
            ),
            state(
                node("ConfigMap", "old"),
                TransitionKind::Delete,
                Verdict::Cancelled {
                    because: CancelReason::External,
                },
                Some(NodeDetail::Applied(ApplyAction::Skipped)),
            ),
            state(
                gate.clone(),
                TransitionKind::Pause,
                Verdict::AwaitingInput {
                    prompt: "approve?".into(),
                },
                None,
            ),
            state(
                web(),
                TransitionKind::Apply,
                Verdict::DriftDetected {
                    since: Duration::from_millis(1500),
                    message: "replicas changed".into(),
                },
                None,
            ),
            DeployEvent::CrdRediscovery,
            DeployEvent::PruneStart {
                count: 1,
                resources: vec![rid("ConfigMap", "old")],
                kept: vec![rid("Namespace", "gone")],
                delete: true,
            },
            DeployEvent::PruneKept {
                resource: rid("ConfigMap", "shared"),
                reason: "Kix cluster other still deploys it".into(),
            },
            DeployEvent::Finalized {
                activation: "act-2".into(),
                previous: Some("act-1".into()),
            },
            DeployEvent::Finalized {
                activation: "act-1".into(),
                previous: None,
            },
            DeployEvent::Stopped {
                reason: "halted on first failure".into(),
            },
            DeployEvent::Stalled {
                idle: Duration::from_secs(90),
                in_flight: vec![
                    InFlight {
                        node: web(),
                        phase: Phase::Readiness,
                        since: Duration::from_secs(30),
                    },
                    InFlight {
                        node: gate,
                        phase: Phase::Discovery,
                        since: Duration::from_millis(250),
                    },
                    InFlight {
                        node: node("Secret", "creds"),
                        phase: Phase::Hydrate,
                        since: Duration::from_millis(40),
                    },
                    InFlight {
                        node: node("Service", "web"),
                        phase: Phase::Apply,
                        since: Duration::from_secs(2),
                    },
                ],
                aborting: true,
            },
            DeployEvent::Waiting {
                node: web(),
                phase: Phase::Readiness,
                since: Duration::from_secs(30),
                status: Some("import target Service/web not found yet".into()),
                budget: Some(Duration::from_secs(180)),
                holds: vec![node("Deployment", "api"), node("Job", "migrate")],
                holds_total: 3,
            },
            DeployEvent::Waiting {
                node: node("ScaledObject", "worker"),
                phase: Phase::Deletion,
                since: Duration::from_secs(60),
                status: Some("being deleted, waiting for finalizer.keda.sh".into()),
                budget: Some(Duration::from_secs(180)),
                holds: vec![],
                holds_total: 0,
            },
            DeployEvent::BestEffortFailed {
                what: "checkpoint".into(),
                message: "conflict".into(),
            },
            DeployEvent::FieldsNotKept {
                resource: rid("Widget", "w"),
                fields: vec![
                    NotKeptField {
                        path: "$.spec.colour".into(),
                        change: NotKept::Dropped,
                        sent: serde_json::json!("red"),
                        stored: None,
                    },
                    NotKeptField {
                        path: "$.spec.size".into(),
                        change: NotKept::Changed,
                        sent: serde_json::json!(2),
                        stored: Some(serde_json::json!(5)),
                    },
                ],
            },
        ]
    }

    /// Verify that serialized deploy log lines match the golden fixture.
    #[test]
    fn the_log_lines_are_unchanged() {
        let counts = DeployResult {
            created: 1,
            configured: 2,
            unchanged: 3,
            failed: 4,
            failed_after_apply: 2,
            cancelled: 5,
            pruned: 6,
            ..DeployResult::default()
        };
        let lines: Vec<String> = every_event()
            .iter()
            .filter_map(|e| Line::of(e, 7))
            .chain([Line::summary(&counts, true, false, 7)])
            .map(|line| json_line(&line))
            .collect();
        // Regenerate the fixture alongside the schemas with
        // `KIX_WRITE_SCHEMAS=1 cargo test -p kix-cli`.
        if std::env::var_os("KIX_WRITE_SCHEMAS").is_some() {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/deploy-log.ndjson");
            std::fs::write(path, lines.join("\n") + "\n").unwrap();
        }
        assert_eq!(lines, GOLDEN.lines().collect::<Vec<_>>());
    }

    /// Verify that every golden log line round-trips through `Line`.
    #[test]
    fn every_log_line_reads_back_as_written() {
        for text in GOLDEN.lines() {
            let line: Line = serde_json::from_str(text).unwrap();
            assert_eq!(json_line(&line), text);
        }
    }

    const GOLDEN: &str = include_str!("../../tests/fixtures/deploy-log.ndjson");

    /// The log opens with a line that names the context and API server the
    /// deploy writes to, and the line reads back as written.
    #[test]
    fn the_log_names_the_kubernetes_cluster() {
        let connection = Connection::Context {
            name: Some("prod".into()),
            server: Some("https://prod.example:6443".into()),
        };
        let text = json_line(&Line::kubernetes(&connection, 0));
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["type"], "kubernetes");
        assert_eq!(value["context"], "prod");
        assert_eq!(value["server"], "https://prod.example:6443");
        let line: Line = serde_json::from_str(&text).unwrap();
        assert_eq!(json_line(&line), text);
    }

    /// A deploy with nothing to apply still ends its log with a summary line
    /// that says so, while a run that applied something says it did not.
    #[test]
    fn a_deploy_with_nothing_to_apply_ends_with_a_summary() {
        let text = json_line(&Line::nothing_to_apply(9, 3));
        let value: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["type"], "summary");
        assert_eq!(value["succeeded"], true);
        assert_eq!(value["nothing_to_apply"], true);
        assert_eq!(value["created"], 0);
        assert_eq!(value["unchanged"], 9);
        let ran = json_line(&Line::summary(&DeployResult::default(), false, true, 3));
        let ran: serde_json::Value = serde_json::from_str(&ran).unwrap();
        assert_eq!(ran["nothing_to_apply"], false);
    }

    /// A summary line written before `nothing_to_apply` existed still reads.
    #[test]
    fn a_summary_without_nothing_to_apply_reads() {
        let text = r#"{"schema_version":"2026-11-25","elapsed_ms":1,"type":"summary","dry_run":false,"succeeded":true,"created":0,"configured":0,"unchanged":1,"failed":0,"cancelled":0,"pruned":0}"#;
        let line: Line = serde_json::from_str(text).unwrap();
        assert!(matches!(
            line.event,
            kix::cluster::deploy_log::Event::Summary {
                nothing_to_apply: false,
                ..
            }
        ));
    }

    /// Under `--prune`, each object is listed as one Kix will delete.
    #[test]
    fn prune_lines_say_what_will_be_deleted() {
        let lines = prune_lines(&[rid("ConfigMap", "old")], &[], true, "app");
        assert_eq!(
            lines,
            vec![
                "prune> deleting 1 object(s) that left the build",
                "ConfigMap/old@app> left the build, will be deleted",
            ]
        );
    }

    /// A delete that waits says what for, a finished delete says "deleted",
    /// and a prune that found nothing to delete says why.
    #[test]
    fn a_delete_reads_as_deleted() {
        assert_eq!(
            deleting("being deleted, waiting for finalizer.keda.sh"),
            "deleting, waiting for finalizer.keda.sh"
        );
        assert_eq!(deleting("being deleted"), "deleting");
        assert_eq!(
            delete_line(&Verdict::Ready, None).as_deref(),
            Some("deleted")
        );
        let why = kix::cluster::prune_guard::Pruned::NotServed
            .already_gone()
            .unwrap();
        assert_eq!(
            delete_line(&Verdict::Ready, Some(&NodeDetail::AlreadyGone(why.into()))).as_deref(),
            Some("already gone (Kubernetes does not recognize its kind)")
        );
        assert_eq!(
            delete_line(
                &Verdict::Running,
                Some(&NodeDetail::ReadinessProgress(
                    "being deleted, waiting for example.com/hold".into()
                ))
            )
            .as_deref(),
            Some("deleting, waiting for example.com/hold")
        );
        let failed = Verdict::Failed {
            message: "stuck".into(),
        };
        assert_eq!(delete_line(&failed, None), None);
    }

    /// Verify that warn-only mode lists protected orphans separately from
    /// reported orphans.
    #[test]
    fn prune_lines_list_kept_orphans_apart() {
        let lines = prune_lines(
            &[rid("ConfigMap", "old")],
            &[rid("Namespace", "gone")],
            false,
            "app",
        );
        assert_eq!(
            lines,
            vec![
                "prune> 1 object(s) left the build, still on the cluster (run `kix gc app` to delete them)",
                "ConfigMap/old@app> left the build, still on the cluster",
                "prune> 1 object(s) left the build and are never deleted automatically",
                "Namespace/gone@app> left the build, kept (never deleted automatically)",
            ]
        );
    }
}
