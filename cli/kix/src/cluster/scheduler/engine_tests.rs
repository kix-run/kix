//! Engine tests: `run_deploy` against the scripted fake without a cluster,
//! using a paused clock. Every run is wrapped in a one-hour virtual timeout so
//! a parked engine fails immediately instead of hanging the suite.

use super::*;
use crate::cluster::ops::scripted::{
    ApplyFailure, Behaviour, Call, Gate, NodeScript, Ready, ScriptedOps,
};
use crate::cluster::stream::{InFlight, NullObserver};
use serde_json::json;
use std::sync::Mutex;
use tokio::time::Instant;

fn secs(n: u64) -> Duration {
    Duration::from_secs(n)
}

fn rid(kind: &str, name: &str) -> ResourceId {
    ResourceId {
        kind: kind.into(),
        namespace: if kind == "CustomResourceDefinition" {
            CLUSTER_SCOPED.into()
        } else {
            "default".into()
        },
        name: name.into(),
    }
}

/// Build a manifest with identity hash `h_<name>` and dependencies `deps`.
fn m(kind: &str, name: &str, deps: &[&str]) -> Value {
    let mut annotations = serde_json::Map::new();
    annotations.insert(keys::IDENTITY_HASH.into(), json!(format!("h_{name}")));
    if !deps.is_empty() {
        let deps: Vec<String> = deps.iter().map(|d| format!("h_{d}")).collect();
        annotations.insert(keys::DEPENDS_ON.into(), json!(deps.join(",")));
    }
    let mut metadata = json!({ "name": name, "annotations": annotations });
    if kind != "CustomResourceDefinition" {
        metadata["namespace"] = json!("default");
    }
    json!({ "apiVersion": "v1", "kind": kind, "metadata": metadata })
}

/// Build a manifest carrying the `kix.run/rerun` annotation.
fn rerun_m(kind: &str, name: &str, deps: &[&str]) -> Value {
    let mut v = m(kind, name, deps);
    v["metadata"]["annotations"][keys::RERUN] = json!("on-change");
    v
}

/// Build a live Job object in a failed or succeeded state.
fn live_job(failed: bool) -> Value {
    live_job_named("probe", failed)
}

fn live_job_named(name: &str, failed: bool) -> Value {
    json!({
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": { "name": name, "namespace": "default" },
        "spec": { "backoffLimit": 0 },
        "status": if failed { json!({ "failed": 1 }) } else { json!({ "succeeded": 1 }) },
    })
}

fn plan_of(manifests: &[Value]) -> DeployPlan {
    plan_with_skips(manifests, &[])
}

/// Build a plan from `manifests`, marking the named resources as `Skip`.
fn plan_with_skips(manifests: &[Value], skip: &[&str]) -> DeployPlan {
    let graph = ResourceGraph::from_manifests(manifests).unwrap();
    let changes: Vec<ChangeAction> = manifests
        .iter()
        .map(|m| {
            let rid = ResourceId::from_value(m);
            if skip.contains(&rid.name.as_str()) {
                ChangeAction::Skip(rid)
            } else {
                ChangeAction::Apply(m.clone())
            }
        })
        .collect();
    DeployPlan::from_graph_and_changes(&graph, &changes).unwrap()
}

fn config(stall: StallPolicy) -> SchedulerConfig {
    SchedulerConfig {
        timeout: secs(300),
        on_error: OnErrorPolicy::Continue,
        cancel: CancelToken::new(),
        concurrency: CONCURRENCY,
        stall,
        rerun_failed: true,
    }
}

fn quiet_watchdog() -> StallPolicy {
    StallPolicy::off()
}

#[derive(Default)]
struct Recorder(Mutex<Vec<DeployEvent>>);

impl DeployObserver for Recorder {
    fn on_event(&self, event: &DeployEvent) {
        self.0.lock().unwrap().push(event.clone());
    }
}

impl Recorder {
    fn stalls(&self) -> Vec<(Duration, Vec<InFlight>, bool)> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::Stalled {
                    idle,
                    in_flight,
                    aborting,
                } => Some((*idle, in_flight.clone(), *aborting)),
                _ => None,
            })
            .collect()
    }

    fn prune_starts(&self) -> Vec<(usize, Vec<ResourceId>, Vec<ResourceId>, bool)> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::PruneStart {
                    count,
                    resources,
                    kept,
                    delete,
                } => Some((*count, resources.clone(), kept.clone(), *delete)),
                _ => None,
            })
            .collect()
    }

    fn best_effort_failures(&self) -> Vec<String> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::BestEffortFailed { what, message } => {
                    Some(format!("{what}: {message}"))
                }
                _ => None,
            })
            .collect()
    }

    fn stopped(&self) -> Option<String> {
        self.0.lock().unwrap().iter().find_map(|e| match e {
            DeployEvent::Stopped { reason } => Some(reason.clone()),
            _ => None,
        })
    }

    /// Return every `Waiting` event as `(node, holds, holds_total)`.
    fn waits(&self) -> Vec<(NodeId, Vec<NodeId>, usize)> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::Waiting {
                    node,
                    holds,
                    holds_total,
                    ..
                } => Some((node.clone(), holds.clone(), *holds_total)),
                _ => None,
            })
            .collect()
    }

    /// Return terminal verdicts per node in emission order.
    fn terminals(&self) -> Vec<(NodeId, Verdict)> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter_map(|e| match e {
                DeployEvent::NodeStateChanged { node, verdict, .. } if verdict.is_terminal() => {
                    Some((node.clone(), verdict.clone()))
                }
                _ => None,
            })
            .collect()
    }

    fn terminal_count(&self, node: &NodeId) -> usize {
        self.terminals().iter().filter(|(n, _)| n == node).count()
    }
}

/// Run the engine with a virtual timeout so any deadlock fails immediately.
async fn run(
    ops: &Arc<ScriptedOps>,
    plan: DeployPlan,
    config: &SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
) -> Result<DeployResult, DeployError> {
    tokio::time::timeout(
        secs(3600),
        run_scripted(
            ops.clone(),
            plan,
            &[],
            &[],
            PrunePolicy::WarnOnly,
            config,
            observer,
        ),
    )
    .await
    .expect("engine parked: nothing runnable for an hour of virtual time")
}

/// Run the engine with orphans to prune.
async fn run_with_orphans(
    ops: &Arc<ScriptedOps>,
    plan: DeployPlan,
    orphans: &[ResourceId],
    old_manifests: &[Value],
    prune: PrunePolicy,
    config: &SchedulerConfig,
    observer: Arc<dyn DeployObserver>,
) -> Result<DeployResult, DeployError> {
    tokio::time::timeout(
        secs(3600),
        run_scripted(
            ops.clone(),
            plan,
            orphans,
            old_manifests,
            prune,
            config,
            observer,
        ),
    )
    .await
    .expect("engine parked: nothing runnable for an hour of virtual time")
}

fn total(r: &DeployResult) -> usize {
    r.created + r.configured + r.unchanged + r.failed + r.cancelled
}

/// Slow applies can fill the concurrency cap without blocking a completed
/// CRD's discovery refresh or its dependent.
#[tokio::test(start_paused = true)]
async fn crd_barrier_does_not_park_running_nodes() {
    let mut manifests: Vec<Value> = (0..64)
        .map(|i| m("Deployment", &format!("d{i}"), &[]))
        .collect();
    manifests.push(m("CustomResourceDefinition", "widgets", &[]));
    manifests.push(m("Widget", "w", &["widgets"]));
    let ops = Arc::new(ScriptedOps::new());
    ops.default_node(
        NodeScript::default().apply(Behaviour::After(secs(5), Ok(ApplyAction::Created))),
    );
    ops.script(
        rid("CustomResourceDefinition", "widgets"),
        NodeScript::default(),
    );
    ops.script(rid("Widget", "w"), NodeScript::default());
    ops.default_rediscover(Behaviour::After(secs(1), Ok(())));
    let mut cfg = config(quiet_watchdog());
    cfg.concurrency = 100;

    let start = Instant::now();
    let result = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
        .await
        .unwrap();

    assert_eq!(result.created, 66);
    assert_eq!(start.elapsed(), secs(5), "slow applies bound the run");
    let w = rid("Widget", "w");
    let rediscover_end = ops.time_of(|c| *c == Call::RediscoverEnd).unwrap();
    let w_start = ops.time_of(|c| *c == Call::ApplyStart(w.clone())).unwrap();
    assert_eq!(rediscover_end, secs(1));
    assert!(w_start >= rediscover_end, "dependent waits for the refresh");
    assert!(
        w_start < secs(5),
        "dependent does not wait for unrelated slow nodes"
    );
    assert_eq!(
        ops.calls()
            .iter()
            .filter(|c| **c == Call::RediscoverStart)
            .count(),
        1
    );
}

/// A failed discovery refresh stops the run before its dependent is
/// applied; nodes already in flight finish.
#[tokio::test(start_paused = true)]
async fn rediscovery_failure_stops_the_run() {
    let manifests = vec![
        m("CustomResourceDefinition", "widgets", &[]),
        m("Widget", "w", &["widgets"]),
        m("Deployment", "slow", &[]),
    ];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "slow"),
        NodeScript::default().apply(Behaviour::After(secs(3), Ok(ApplyAction::Created))),
    );
    ops.rediscover_next(Behaviour::Now(Err("aggregated discovery 503".into())));
    let rec = Arc::new(Recorder::default());
    let cfg = config(quiet_watchdog());

    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    match err {
        DeployError::DiscoveryFailed { message, partial } => {
            assert!(message.contains("503"), "{message}");
            assert_eq!(partial.created, 2, "crd and the slow node finished");
        }
        other => panic!("expected DiscoveryFailed, got {other}"),
    }
    let w = rid("Widget", "w");
    assert!(ops.time_of(|c| *c == Call::ApplyStart(w.clone())).is_none());
    assert!(rec.stopped().unwrap().contains("rediscovery failed"));
}

/// A hung apply is named within the warning bound and the
/// run is cancelled at the abort bound.
#[tokio::test(start_paused = true)]
async fn hung_apply_is_reported_then_aborted() {
    let manifests = vec![m("Deployment", "stuck", &[]), m("ConfigMap", "cm", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "stuck"),
        NodeScript::default().apply(Behaviour::Hang),
    );
    let rec = Arc::new(Recorder::default());
    let cfg = config(StallPolicy {
        warn_after: secs(30),
        abort_after: Some(secs(120)),
    });

    let start = Instant::now();
    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    let DeployError::Cancelled { reason, partial } = err else {
        panic!("expected Cancelled, got {err}");
    };
    assert!(reason.starts_with("no progress for 120s"), "{reason}");
    assert!(
        reason.contains("Deployment/stuck@default (apply, 12"),
        "{reason}"
    );
    assert_eq!(
        partial.created, 1,
        "the ConfigMap finished before the stall"
    );
    assert!(start.elapsed() >= secs(120) && start.elapsed() < secs(126));

    let stalls = rec.stalls();
    assert_eq!(
        stalls.len(),
        4,
        "warn at 30, 60, 90, abort at 120: {stalls:?}"
    );
    for (i, (idle, in_flight, aborting)) in stalls.iter().enumerate() {
        let expected = secs(30 * (i as u64 + 1));
        assert!(
            *idle >= expected && *idle < expected + secs(6),
            "stall {i} idle {idle:?}, expected about {expected:?}"
        );
        assert_eq!(*aborting, i == 3);
        assert_eq!(in_flight.len(), 1);
        assert_eq!(
            in_flight[0].node,
            NodeId::Resource(rid("Deployment", "stuck"))
        );
        assert_eq!(in_flight[0].phase, Phase::Apply);
    }
    assert_eq!(rec.stopped().as_deref(), Some(reason.as_str()));
    // The hung node gets a verdict: Cancelled, exactly once.
    let stuck = NodeId::Resource(rid("Deployment", "stuck"));
    assert_eq!(rec.terminal_count(&stuck), 1);
    assert_eq!(partial.cancelled, 1);
}

/// A hung node's `Waiting` events name the direct dependents that have work
/// to do and count every such node behind it. An unchanged dependent is
/// neither named nor counted, but the nodes behind it are.
#[tokio::test(start_paused = true)]
async fn a_hung_node_reports_what_it_holds_up() {
    let manifests = vec![
        m("CustomResourceDefinition", "foos", &[]),
        m("Deployment", "operator", &["foos"]),
        m("Service", "operator-api", &["operator"]),
        m("ConfigMap", "unchanged", &["foos"]),
        m("Secret", "behind", &["unchanged"]),
        m("ConfigMap", "cm", &[]),
    ];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("CustomResourceDefinition", "foos"),
        NodeScript::default().apply(Behaviour::Hang),
    );
    let rec = Arc::new(Recorder::default());
    let cfg = config(StallPolicy {
        warn_after: secs(30),
        abort_after: Some(secs(60)),
    });

    let plan = plan_with_skips(&manifests, &["unchanged"]);
    let err = run(&ops, plan, &cfg, rec.clone()).await.unwrap_err();
    assert!(matches!(err, DeployError::Cancelled { .. }), "{err}");

    let waits = rec.waits();
    let crd = NodeId::Resource(rid("CustomResourceDefinition", "foos"));
    assert!(
        waits.iter().all(|(node, _, _)| *node == crd),
        "only the hung node waits: {waits:?}"
    );
    assert_eq!(
        waits.first(),
        Some(&(
            crd,
            vec![NodeId::Resource(rid("Deployment", "operator"))],
            3
        )),
        "{waits:?}"
    );
}

/// A slow but healthy rollout reports progress often enough to keep the
/// watchdog quiet.
#[tokio::test(start_paused = true)]
async fn readiness_progress_keeps_the_watchdog_quiet() {
    let manifests = vec![m("StatefulSet", "db", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("StatefulSet", "db"),
        NodeScript::default().ready(Behaviour::Now(Ready::Heartbeat {
            every: secs(2),
            count: 150,
            then: Box::new(Ready::Ready),
        })),
    );
    let rec = Arc::new(Recorder::default());
    let cfg = config(StallPolicy {
        warn_after: secs(30),
        abort_after: Some(secs(120)),
    });

    let start = Instant::now();
    let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap();

    assert_eq!(result.created, 1);
    assert_eq!(start.elapsed(), secs(300));
    assert!(rec.stalls().is_empty(), "{:?}", rec.stalls());
}

/// Cancellation with every node hung returns promptly and aborts
/// the in-flight tasks (they never complete once released), and gives
/// every node a verdict: the in-flight ones Cancelled, the pending
/// dependent Cancelled.
#[tokio::test(start_paused = true)]
async fn cancel_terminates_promptly_and_accounts_for_everything() {
    let manifests = vec![
        m("Deployment", "a", &[]),
        m("Deployment", "b", &[]),
        m("Deployment", "c", &["a"]),
    ];
    let ops = Arc::new(ScriptedOps::new());
    let gate = Gate::new();
    ops.default_node(
        NodeScript::default().apply(Behaviour::Gate(gate.clone(), Ok(ApplyAction::Created))),
    );
    let cfg = config(quiet_watchdog());
    let token = cfg.cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(secs(1)).await;
        token.cancel_with_reason("interrupted");
    });
    let rec = Arc::new(Recorder::default());

    let start = Instant::now();
    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    let DeployError::Cancelled { reason, partial } = err else {
        panic!("expected Cancelled, got {err}");
    };
    assert_eq!(reason, "interrupted");
    assert_eq!(start.elapsed(), secs(1));
    assert_eq!(rec.stopped().as_deref(), Some("interrupted"));
    assert_eq!(
        partial.cancelled, 3,
        "a and b in flight, c pending: {partial:?}"
    );
    for name in ["a", "b", "c"] {
        assert_eq!(
            rec.terminal_count(&NodeId::Resource(rid("Deployment", name))),
            1
        );
    }
    // Opening the gate now must not complete anything: the tasks were
    // aborted, not left running.
    gate.open();
    tokio::time::sleep(secs(1)).await;
    assert!(
        !ops.calls().iter().any(|c| matches!(c, Call::ApplyEnd(_))),
        "an aborted apply completed after the run returned"
    );
    // A run that stopped writes nothing more.
    assert!(
        !ops.calls()
            .iter()
            .any(|c| matches!(c, Call::Finalize { .. } | Call::Delete(_)))
    );
}

/// Cancel while a node is in readiness: the node reports Cancelled, its
/// dependent is Cancelled, and nothing after the loop runs (no prune, no
/// finalize), even though the loop may exit on its own.
#[tokio::test(start_paused = true)]
async fn cancel_during_readiness_never_reaches_prune_or_finalize() {
    let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "a"),
        NodeScript::default().ready(Behaviour::Now(Ready::Heartbeat {
            every: secs(2),
            count: 100,
            then: Box::new(Ready::Ready),
        })),
    );
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::Delete;
    let token = cfg.cancel.clone();
    tokio::spawn(async move {
        tokio::time::sleep(secs(5)).await;
        token.cancel();
    });
    let rec = Arc::new(Recorder::default());
    let orphans = [rid("ConfigMap", "old")];
    let old = [m("ConfigMap", "old", &[])];

    let err = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &old,
        prune,
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap_err();

    assert!(matches!(err, DeployError::Cancelled { .. }), "{err}");
    let calls = ops.calls();
    assert!(
        !calls
            .iter()
            .any(|c| matches!(c, Call::Delete(_) | Call::Finalize { .. }))
    );
    // But it does mark the record Failed, which is the whole point: this
    // run applied part of its closure and nothing else will say so.
    assert!(
        calls.iter().any(|c| matches!(c, Call::Abort { .. })),
        "a cancelled run must abort the activation: {calls:?}",
    );
    assert_eq!(
        rec.terminal_count(&NodeId::Resource(rid("Deployment", "a"))),
        1
    );
    assert_eq!(
        rec.terminal_count(&NodeId::Resource(rid("Deployment", "b"))),
        1
    );
}

/// A run that stops because a node failed under `OnErrorPolicy::Stop`
/// marks the activation record as `Failed` so the next deploy can
/// reconcile what was applied.
#[tokio::test(start_paused = true)]
async fn a_failed_node_under_stop_aborts_the_activation() {
    let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "a"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
    );
    let mut cfg = config(quiet_watchdog());
    cfg.on_error = OnErrorPolicy::Stop;
    let rec = Arc::new(Recorder::default());

    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    assert!(matches!(err, DeployError::NodesFailed { .. }), "{err}");
    let calls = ops.calls();
    assert!(
        calls.iter().any(|c| matches!(c, Call::Abort { .. })),
        "a halted run must abort the activation: {calls:?}",
    );
    assert!(
        !calls.iter().any(|c| matches!(c, Call::Finalize { .. })),
        "and must not also finalize: {calls:?}",
    );
}

/// A run under `--on-error=continue` that leaves nodes never attempted
/// must not finalize. The record would land Degraded, and Degraded is a
/// current state: the next deploy of the same closure would then skip
/// every node this one never ran.
#[tokio::test(start_paused = true)]
async fn a_run_with_cancelled_nodes_aborts_instead_of_finalizing() {
    let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "a"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
    );
    let mut cfg = config(quiet_watchdog());
    cfg.on_error = OnErrorPolicy::Continue;
    let prune = PrunePolicy::Delete;
    let rec = Arc::new(Recorder::default());

    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &[rid("ConfigMap", "old")],
        &[m("ConfigMap", "old", &[])],
        prune,
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap();
    assert!(result.cancelled > 0, "b should have been cancelled");

    let calls = ops.calls();
    assert!(
        calls.iter().any(|c| matches!(c, Call::Abort { .. })),
        "an incomplete run must abort: {calls:?}",
    );
    assert!(
        !calls.iter().any(|c| matches!(c, Call::Finalize { .. })),
        "and must not finalize, which would supersede a still-running activation: {calls:?}",
    );
    // And it must not prune. The previous activation stays Active, so its
    // orphans are objects the cluster still depends on.
    assert!(
        !calls.iter().any(|c| matches!(c, Call::Delete(_))),
        "an incomplete run must not prune the still-current closure: {calls:?}",
    );
}

/// A dry run tries the dependents of a refused node, since nothing a dry
/// run writes persists: every refusal shows, not only the first.
#[tokio::test(start_paused = true)]
async fn a_dry_run_tries_the_dependents_of_a_refused_node() {
    let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
    let ops = Arc::new(ScriptedOps::new());
    ops.set_dry_run(true);
    ops.script(
        rid("Deployment", "a"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
    );
    let mut cfg = config(quiet_watchdog());
    cfg.on_error = OnErrorPolicy::Continue;
    let rec = Arc::new(Recorder::default());

    let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap();
    assert_eq!((result.failed, result.cancelled), (1, 0));
    assert!(
        ops.calls()
            .contains(&Call::ApplyEnd(rid("Deployment", "b"))),
        "b was not tried: {:?}",
        ops.calls()
    );
}

/// A run where everything was attempted and some failed IS a current
/// state, so it finalizes (Degraded) rather than aborting.
#[tokio::test(start_paused = true)]
async fn a_run_that_attempted_everything_still_finalizes() {
    // Two independent nodes: one fails, the other applies. Nothing is
    // cancelled, so the closure is as applied as it can be.
    let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "a"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
    );
    let mut cfg = config(quiet_watchdog());
    cfg.on_error = OnErrorPolicy::Continue;
    let rec = Arc::new(Recorder::default());

    let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap();
    assert_eq!(result.cancelled, 0);
    assert_eq!(result.failed, 1);

    let calls = ops.calls();
    assert!(
        calls.iter().any(|c| matches!(
            c,
            Call::Finalize {
                had_failures: true,
                ..
            }
        )),
        "expected a Degraded finalize: {calls:?}",
    );
    assert!(!calls.iter().any(|c| matches!(c, Call::Abort { .. })));
}

/// A run that finishes never aborts. Finalize and abort are the two ends
/// of the same lifecycle and exactly one of them happens.
#[tokio::test(start_paused = true)]
async fn a_clean_run_finalizes_and_never_aborts() {
    let manifests = vec![m("Deployment", "a", &[]), m("Deployment", "b", &["a"])];
    let ops = Arc::new(ScriptedOps::new());
    let cfg = config(quiet_watchdog());
    let rec = Arc::new(Recorder::default());

    run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap();

    let calls = ops.calls();
    assert!(calls.iter().any(|c| matches!(c, Call::Finalize { .. })));
    assert!(
        !calls.iter().any(|c| matches!(c, Call::Abort { .. })),
        "a clean run must not abort: {calls:?}",
    );
}

/// A record that cannot be begun stops the run before any node is
/// applied, and the run does not abort a record it never began.
#[tokio::test(start_paused = true)]
async fn a_failed_begin_stops_the_run_before_any_node() {
    let manifests = vec![m("Deployment", "a", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.begin_behaviour(Behaviour::Now(Err("records under a retired group".into())));
    let rec = Arc::new(Recorder::default());

    let err = run(
        &ops,
        plan_of(&manifests),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap_err();

    assert!(matches!(err, DeployError::BeginFailed { .. }), "{err}");
    assert!(
        err.to_string().contains("records under a retired group"),
        "{err}"
    );
    assert_eq!(ops.calls(), vec![Call::Begin]);
    assert!(rec.stopped().is_some());
}

/// An abort that will not go through is reported, not fatal. The run has
/// already ended; the error it ends with must still be the real one.
#[tokio::test(start_paused = true)]
async fn a_failing_abort_is_reported_and_does_not_change_the_error() {
    let manifests = vec![m("Deployment", "a", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "a"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("boom".into())))),
    );
    ops.abort_behaviour(Behaviour::Now(Err("no answer from the apiserver".into())));
    let mut cfg = config(quiet_watchdog());
    cfg.on_error = OnErrorPolicy::Stop;
    let rec = Arc::new(Recorder::default());

    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    assert!(matches!(err, DeployError::NodesFailed { .. }), "{err}");
    assert!(
        rec.best_effort_failures()
            .iter()
            .any(|line| line.starts_with("activation abort:")),
        "the failed abort should be reported as best-effort",
    );
}

/// A checkpoint write that never answers does not park nodes or hold the
/// run open.
#[tokio::test(start_paused = true)]
async fn hung_checkpoint_does_not_hold_the_run() {
    let manifests: Vec<Value> = (0..40)
        .map(|i| m("ConfigMap", &format!("cm{i}"), &[]))
        .collect();
    let ops = Arc::new(ScriptedOps::new());
    // 16 nodes finish at 1s (that spawns the first checkpoint, which
    // hangs), 16 more at 2s, the last 8 at 3s.
    for i in 0..40 {
        ops.script(
            rid("ConfigMap", &format!("cm{i}")),
            NodeScript::default()
                .apply(Behaviour::After(secs(1 + i / 16), Ok(ApplyAction::Created))),
        );
    }
    ops.checkpoint_behaviour(Behaviour::Hang);
    let rec = Arc::new(Recorder::default());
    let cfg = config(quiet_watchdog());

    let start = Instant::now();
    let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap();

    assert_eq!(result.created, 40);
    let mid_run = ops
        .calls()
        .iter()
        .filter(|c| {
            matches!(
                c,
                Call::Checkpoint {
                    finalizing: false,
                    ..
                }
            )
        })
        .count();
    assert_eq!(mid_run, 1, "one checkpoint in flight at most, and it hung");
    // Nodes kept finishing (t=2s, t=3s) while the checkpoint hung; only
    // the final inline checkpoint costs its bounded timeout.
    let last_apply = ops
        .log()
        .iter()
        .filter(|l| matches!(l.call, Call::ApplyEnd(_)))
        .map(|l| l.at)
        .max()
        .unwrap();
    assert_eq!(last_apply, secs(3));
    assert_eq!(start.elapsed(), secs(3) + INLINE_BEST_EFFORT_TIMEOUT);
    let failures = rec.best_effort_failures();
    assert_eq!(failures.len(), 1, "{failures:?}");
    assert!(failures[0].starts_with("activation checkpoint: no answer within"));
}

/// Admission streams: a slot freed by one fast node is refilled at once,
/// not when the whole batch drains.
#[tokio::test(start_paused = true)]
async fn admission_refills_a_slot_as_soon_as_it_frees() {
    let manifests: Vec<Value> = (0..65)
        .map(|i| m("ConfigMap", &format!("cm{i:02}"), &[]))
        .collect();
    let ops = Arc::new(ScriptedOps::new());
    ops.default_node(
        NodeScript::default().apply(Behaviour::After(secs(10), Ok(ApplyAction::Created))),
    );
    // Admission is in sorted order, so cm00 is in the first batch.
    ops.script(
        rid("ConfigMap", "cm00"),
        NodeScript::default().apply(Behaviour::After(secs(1), Ok(ApplyAction::Created))),
    );
    let cfg = config(quiet_watchdog());

    let start = Instant::now();
    let result = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
        .await
        .unwrap();

    assert_eq!(result.created, 65);
    let last = rid("ConfigMap", "cm64");
    assert_eq!(
        ops.time_of(|c| *c == Call::ApplyStart(last.clone())),
        Some(secs(1)),
        "the 65th node starts when the fast node frees its slot"
    );
    assert_eq!(start.elapsed(), secs(11));
}

/// Peak concurrency reaches the configured cap without exceeding it.
#[tokio::test(start_paused = true)]
async fn concurrency_never_exceeds_the_cap() {
    let manifests: Vec<Value> = (0..200)
        .map(|i| m("ConfigMap", &format!("cm{i}"), &[]))
        .collect();
    let ops = Arc::new(ScriptedOps::new());
    ops.default_node(
        NodeScript::default().apply(Behaviour::After(secs(1), Ok(ApplyAction::Created))),
    );
    let cfg = config(quiet_watchdog());

    let start = Instant::now();
    let result = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
        .await
        .unwrap();

    assert_eq!(result.created, 200);
    assert_eq!(ops.peak_concurrent_applies(), CONCURRENCY);
    assert_eq!(start.elapsed(), secs(4), "200 nodes in batches of 64");
}

/// A node task panic is a fatal engine error rather than
/// a lost node.
#[tokio::test(start_paused = true)]
async fn panicking_node_is_fatal() {
    let manifests = vec![m("ConfigMap", "boom", &[]), m("ConfigMap", "ok", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("ConfigMap", "boom"),
        NodeScript::default().apply(Behaviour::Panic("scripted panic".into())),
    );
    let cfg = config(quiet_watchdog());

    let err = run(&ops, plan_of(&manifests), &cfg, Arc::new(NullObserver))
        .await
        .unwrap_err();

    let DeployError::Internal { message, .. } = err else {
        panic!("expected Internal, got {err}");
    };
    assert!(message.contains("panicked"), "{message}");
}

/// Gated applies: the run does not finish until the test opens the gate,
/// and does finish then. Pins the fake's central property.
#[tokio::test(start_paused = true)]
async fn gated_apply_completes_only_when_released() {
    let manifests = vec![m("ConfigMap", "g", &[])];
    let ops = Arc::new(ScriptedOps::new());
    let gate = Gate::new();
    ops.script(
        rid("ConfigMap", "g"),
        NodeScript::default().apply(Behaviour::Gate(gate.clone(), Ok(ApplyAction::Created))),
    );
    let cfg = config(quiet_watchdog());
    let ops2 = ops.clone();
    let handle =
        tokio::spawn(
            async move { run(&ops2, plan_of(&manifests), &cfg, Arc::new(NullObserver)).await },
        );
    tokio::time::sleep(secs(10)).await;
    assert!(!handle.is_finished());
    gate.open();
    let result = handle.await.unwrap().unwrap();
    assert_eq!(result.created, 1);
}

/// An immutable conflict on a pre-authorized orphan recreates in place.
#[tokio::test(start_paused = true)]
async fn immutable_conflict_recreates_when_preauthorized() {
    let manifests = vec![m("Deployment", "sts", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Deployment", "sts"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::ImmutableConflict))),
    );
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::Delete;
    let orphans = [rid("Deployment", "sts")];
    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &manifests,
        prune,
        &cfg,
        Arc::new(NullObserver),
    )
    .await
    .unwrap();
    assert_eq!(result.configured, 1);
    assert!(
        ops.calls()
            .contains(&Call::RecreateStart(rid("Deployment", "sts")))
    );
    assert_eq!(result.pruned, 0, "the consumed orphan is not pruned again");
    assert!(!ops.calls().iter().any(|c| matches!(c, Call::Delete(_))));
}

/// An immutable conflict on a CRD fails the node even when the CRD is a
/// pre-authorized orphan: re-creating it would delete every custom
/// resource of its kind.
#[tokio::test(start_paused = true)]
async fn immutable_conflict_on_crd_is_not_recreated() {
    let manifests = vec![m("CustomResourceDefinition", "widgets.example.com", &[])];
    let crd = rid("CustomResourceDefinition", "widgets.example.com");
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        crd.clone(),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::ImmutableConflict))),
    );
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::Delete;
    let orphans = [crd.clone()];
    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &manifests,
        prune,
        &cfg,
        Arc::new(NullObserver),
    )
    .await
    .unwrap();
    assert_eq!(result.failed, 1);
    assert!(
        !ops.calls()
            .iter()
            .any(|c| matches!(c, Call::RecreateStart(_) | Call::Delete(_)))
    );
}

/// The refusal names the kind and what deleting it would take with it;
/// ordinary kinds are not refused.
#[test]
fn recreate_refusal_names_the_consequence() {
    let crd = recreate_refusal(&rid("CustomResourceDefinition", "widgets.example.com"))
        .expect("a CRD is refused");
    assert!(crd.contains("every custom resource of that kind"), "{crd}");
    assert!(crd.contains("kubectl"), "{crd}");
    let ns = recreate_refusal(&ResourceId {
        kind: "Namespace".into(),
        namespace: CLUSTER_SCOPED.into(),
        name: "apps".into(),
    })
    .expect("a Namespace is refused");
    assert!(ns.contains("deletes everything in it"), "{ns}");
    assert!(recreate_refusal(&rid("Job", "probe")).is_none());
}

fn rerun_details(rec: &Recorder) -> Vec<String> {
    rec.0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            DeployEvent::NodeStateChanged {
                detail: Some(NodeDetail::Rerun { reason }),
                ..
            } => Some(reason.clone()),
            _ => None,
        })
        .collect()
}

/// A changed Job carrying `kix.run/rerun`
/// with a live object is deleted and created again, not applied. The
/// delete goes through `recreate_in_place`, never through the prune
/// path, and the node reports `Rerun`.
#[tokio::test(start_paused = true)]
async fn rerun_job_with_live_object_is_recreated() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Job", "probe"),
        NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(false))))),
    );
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_of(&manifests),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.configured, 1);
    assert_eq!(result.failed, 0);
    let calls = ops.calls();
    assert!(calls.contains(&Call::RecreateStart(rid("Job", "probe"))));
    assert!(!calls.iter().any(|c| matches!(c, Call::ApplyStart(_))));
    assert!(!calls.iter().any(|c| matches!(c, Call::Delete(_))));
    assert_eq!(rerun_details(&rec), vec!["changed since the last run"]);
}

/// Nothing live (first deploy, or deleted by hand): a plain apply, no
/// delete.
#[tokio::test(start_paused = true)]
async fn rerun_job_without_live_object_is_applied() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_of(&manifests),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.created, 1);
    let calls = ops.calls();
    assert!(calls.contains(&Call::GetLive(rid("Job", "probe"))));
    assert!(calls.contains(&Call::ApplyStart(rid("Job", "probe"))));
    assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
    assert!(rerun_details(&rec).is_empty());
}

/// An unchanged probe whose live Job failed runs again on the next
/// deploy without a manual delete.
#[tokio::test(start_paused = true)]
async fn skipped_rerun_job_that_failed_is_recreated() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Job", "probe"),
        NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(true))))),
    );
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_with_skips(&manifests, &["probe"]),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.configured, 1);
    assert_eq!(result.unchanged, 0);
    assert!(
        ops.calls()
            .contains(&Call::RecreateStart(rid("Job", "probe")))
    );
    assert_eq!(rerun_details(&rec), vec!["the last run failed"]);
}

/// An unchanged probe whose live Job succeeded is left alone: counted
/// unchanged and stamped with the activation like any Skip node.
#[tokio::test(start_paused = true)]
async fn skipped_rerun_job_that_succeeded_is_left_alone() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Job", "probe"),
        NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(false))))),
    );
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_with_skips(&manifests, &["probe"]),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.unchanged, 1);
    assert_eq!(result.configured, 0);
    let calls = ops.calls();
    assert!(calls.contains(&Call::GetLive(rid("Job", "probe"))));
    assert!(calls.contains(&Call::Stamp(rid("Job", "probe"))));
    assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
    assert!(!calls.iter().any(|c| matches!(c, Call::ApplyStart(_))));
    assert!(rerun_details(&rec).is_empty());
}

/// Without `rerun_failed` (the operator) an unchanged probe whose live
/// Job failed is reported as failed, never deleted: the gate stays red
/// instead of reading as healthy, and nothing loops.
#[tokio::test(start_paused = true)]
async fn skipped_rerun_job_is_reported_not_retried_without_rerun_failed() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Job", "probe"),
        NodeScript::default().live(Behaviour::Now(Ok(Some(live_job(true))))),
    );
    let mut cfg = config(quiet_watchdog());
    cfg.rerun_failed = false;
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_with_skips(&manifests, &["probe"]),
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.failed, 1);
    assert_eq!(result.unchanged, 0);
    let calls = ops.calls();
    assert!(calls.contains(&Call::GetLive(rid("Job", "probe"))));
    assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
    assert!(!calls.iter().any(|c| matches!(c, Call::Delete(_))));
    assert!(rerun_details(&rec).is_empty());
    let failed: Vec<String> = rec
        .0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            DeployEvent::NodeStateChanged {
                verdict: Verdict::Failed { message },
                ..
            } => Some(message.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(failed.len(), 1);
    assert!(failed[0].contains("which failed"), "{}", failed[0]);
}

fn failed_messages(rec: &Recorder) -> Vec<String> {
    rec.0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            DeployEvent::NodeStateChanged {
                verdict: Verdict::Failed { message },
                ..
            } => Some(message.clone()),
            _ => None,
        })
        .collect()
}

/// An unchanged Job without `kix.run/rerun` whose live object failed is
/// reported as failed and never deleted or recreated, with or without
/// `rerun_failed`: a bootstrap Job that exhausted its backoff must not read
/// as healthy on the next deploy or reconcile.
#[tokio::test(start_paused = true)]
async fn skipped_plain_job_that_failed_is_reported_never_deleted() {
    for rerun_failed in [true, false] {
        let manifests = vec![m("Job", "bootstrap", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.script(
            rid("Job", "bootstrap"),
            NodeScript::default().live(Behaviour::Now(Ok(Some(live_job_named("bootstrap", true))))),
        );
        let mut cfg = config(quiet_watchdog());
        cfg.rerun_failed = rerun_failed;
        let rec = Arc::new(Recorder::default());
        let result = run(
            &ops,
            plan_with_skips(&manifests, &["bootstrap"]),
            &cfg,
            rec.clone(),
        )
        .await
        .unwrap();
        assert_eq!(result.failed, 1, "rerun_failed={rerun_failed}");
        assert_eq!(result.unchanged, 0);
        let calls = ops.calls();
        assert!(calls.contains(&Call::GetLive(rid("Job", "bootstrap"))));
        assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
        assert!(!calls.iter().any(|c| matches!(c, Call::Delete(_))));
        assert!(!calls.iter().any(|c| matches!(c, Call::ApplyStart(_))));
        let failed = failed_messages(&rec);
        assert_eq!(failed.len(), 1);
        assert!(
            failed[0].contains("which failed. Change an input, or delete the Job with kubectl"),
            "{}",
            failed[0]
        );
    }
}

/// An unchanged Job without `kix.run/rerun` whose live object succeeded, or
/// is gone, counts as unchanged. A skipped non-Job is never read.
#[tokio::test(start_paused = true)]
async fn skipped_plain_job_that_succeeded_is_unchanged() {
    let manifests = vec![
        m("Job", "bootstrap", &[]),
        m("Job", "gone", &[]),
        m("ConfigMap", "cm", &[]),
    ];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Job", "bootstrap"),
        NodeScript::default().live(Behaviour::Now(Ok(Some(live_job_named("bootstrap", false))))),
    );
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_with_skips(&manifests, &["bootstrap", "gone", "cm"]),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.failed, 0);
    assert_eq!(result.unchanged, 3);
    let calls = ops.calls();
    assert!(calls.contains(&Call::GetLive(rid("Job", "bootstrap"))));
    assert!(calls.contains(&Call::GetLive(rid("Job", "gone"))));
    assert!(!calls.contains(&Call::GetLive(rid("ConfigMap", "cm"))));
    assert!(!calls.iter().any(|c| matches!(c, Call::RecreateStart(_))));
}

/// The pre-check `kix deploy` runs before taking the "nothing to apply" exit
/// names every unchanged Job whose live object failed, with or without
/// `kix.run/rerun`, and not one that succeeded.
#[tokio::test]
async fn failed_skipped_jobs_names_any_failed_unchanged_job() {
    let api = crate::cluster::fake_api::FakeApi::new([
        live_job_named("bootstrap", true),
        live_job_named("probe", true),
        live_job_named("done", false),
    ]);
    let client = api.client();
    let discovery = crate::cluster::discovery::discover_resources(&client)
        .await
        .unwrap();
    let manifests = vec![
        m("Job", "bootstrap", &[]),
        rerun_m("Job", "probe", &[]),
        m("Job", "done", &[]),
        m("ConfigMap", "cm", &[]),
    ];
    let plan = plan_with_skips(&manifests, &["bootstrap", "probe", "done", "cm"]);
    let mut failed = failed_skipped_jobs(&client, &discovery, &plan).await;
    failed.sort();
    assert_eq!(failed, vec![rid("Job", "bootstrap"), rid("Job", "probe")]);
}

/// Under dry run a changed rerun Job with a live object still takes the
/// recreate path (the ops layer answers without writing) and reports
/// `Rerun`, so a preview shows what the real deploy will do.
#[tokio::test(start_paused = true)]
async fn rerun_job_under_dry_run_reports_rerun() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.set_dry_run(true);
    ops.script(
        rid("Job", "probe"),
        NodeScript::default()
            .live(Behaviour::Now(Ok(Some(live_job(false)))))
            .recreate(Behaviour::Now(Ok(ApplyAction::Created))),
    );
    let cfg = config(quiet_watchdog());
    let rec = Arc::new(Recorder::default());
    let result = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap();
    assert_eq!(result.failed, 0);
    assert_eq!(result.created, 1);
    assert!(
        ops.calls()
            .contains(&Call::RecreateStart(rid("Job", "probe")))
    );
    assert_eq!(rerun_details(&rec), vec!["changed since the last run"]);
}

/// A delete that never completes (stuck finalizer) fails the node with
/// the ops layer's message instead of a blind re-apply.
#[tokio::test(start_paused = true)]
async fn rerun_job_still_present_after_delete_fails_the_node() {
    let manifests = vec![rerun_m("Job", "probe", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Job", "probe"),
        NodeScript::default()
            .live(Behaviour::Now(Ok(Some(live_job(false)))))
            .recreate(Behaviour::Now(Err(
                "Job/default/probe still exists 30s after delete (stuck finalizer?); not re-applied".into(),
            ))),
    );
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_of(&manifests),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!(result.failed, 1);
    let failed: Vec<String> = rec
        .0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            DeployEvent::NodeStateChanged {
                verdict: Verdict::Failed { message },
                ..
            } => Some(message.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(failed.len(), 1);
    assert!(
        failed[0].contains("still exists 30s after delete"),
        "{}",
        failed[0]
    );
    assert!(
        failed[0].contains("changed since the last run"),
        "{}",
        failed[0]
    );
}

/// A hung discovery refresh is bounded and named in the error.
#[tokio::test(start_paused = true)]
async fn hung_rediscovery_is_reported_and_aborted() {
    let manifests = vec![
        m("CustomResourceDefinition", "widgets", &[]),
        m("Widget", "w", &["widgets"]),
    ];
    let ops = Arc::new(ScriptedOps::new());
    ops.default_rediscover(Behaviour::Hang);
    let rec = Arc::new(Recorder::default());
    let cfg = config(StallPolicy {
        warn_after: secs(10),
        abort_after: Some(secs(30)),
    });

    let start = Instant::now();
    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    let DeployError::Cancelled { reason, partial } = err else {
        panic!("expected Cancelled, got {err}");
    };
    assert!(reason.contains("api-discovery (discovery, 3"), "{reason}");
    assert!(start.elapsed() >= secs(30) && start.elapsed() < secs(36));
    assert_eq!(partial.created, 1);
    assert_eq!(
        partial.cancelled, 1,
        "the dependent never ran and is Cancelled"
    );
    assert!(
        ops.time_of(|c| *c == Call::ApplyStart(rid("Widget", "w")))
            .is_none()
    );
    assert_eq!(rec.terminal_count(&NodeId::Resource(rid("Widget", "w"))), 1);
}

/// Build one of Kix's own CRDs serving `v1alpha1`.
fn kix_crd(name: &str) -> Value {
    let mut v = m("CustomResourceDefinition", name, &[]);
    v["apiVersion"] = json!("apiextensions.k8s.io/v1");
    v["spec"] = json!({"versions": [{"name": "v1alpha1", "served": true}]});
    v
}

/// Build a deploy record depending on `deps` with `interfaces`.
fn record_m(interfaces: Value, deps: &[&str]) -> Value {
    let mut v = m(lifecycle::RECORD_KIND, "rec", deps);
    v["apiVersion"] = json!(keys::API_VERSION);
    v["metadata"].as_object_mut().unwrap().remove("namespace");
    v["spec"] = json!({ "interfaces": interfaces });
    v
}

/// Build a manifest set with Kix's two CRDs, a `PackageInstance`, and an
/// `Activation` record. Non-empty `interfaces` marks the build as a
/// consumer cluster.
fn kix_build(interfaces: Value) -> Vec<Value> {
    vec![
        kix_crd(keys::ACTIVATIONS_CRD),
        kix_crd(keys::PACKAGE_INSTANCES_CRD),
        m("PackageInstance", "web", &[keys::PACKAGE_INSTANCES_CRD]),
        record_m(interfaces, &[keys::ACTIVATIONS_CRD, "web"]),
    ]
}

/// A consumer waits for Kix's CRDs, which its platform writes. It never
/// applies them, nor stamps them, and its other objects wait for them.
#[tokio::test(start_paused = true)]
async fn a_consumer_waits_for_kix_crds_and_never_writes_them() {
    let manifests = kix_build(json!({"core": {"consumer": "acme"}}));
    let plan = plan_of(&manifests);
    let crds = [
        rid("CustomResourceDefinition", keys::ACTIVATIONS_CRD),
        rid("CustomResourceDefinition", keys::PACKAGE_INSTANCES_CRD),
    ];
    for crd in &crds {
        let node = plan
            .nodes()
            .iter()
            .find(|n| n.id == NodeId::Resource(crd.clone()))
            .unwrap();
        assert_eq!(node.kind, TransitionKind::Wait);
        assert!(matches!(node.action, ChangeAction::Skip(_)));
        let target = node.meta.import_target.as_ref().unwrap();
        assert_eq!(target.platform.as_deref(), Some("core"));
        assert_eq!(target.served_versions, ["v1alpha1"]);
    }

    let ops = Arc::new(ScriptedOps::new());
    let result = run(
        &ops,
        plan,
        &config(quiet_watchdog()),
        Arc::new(NullObserver),
    )
    .await
    .unwrap();

    let calls = ops.calls();
    for crd in &crds {
        assert!(!calls.contains(&Call::ApplyStart(crd.clone())));
        assert!(!calls.contains(&Call::Stamp(crd.clone())));
        assert!(calls.contains(&Call::ReadyEnd(crd.clone())));
    }
    let crd_ready = ops
        .time_of(|c| *c == Call::ReadyEnd(crds[1].clone()))
        .unwrap();
    let web_applied = ops
        .time_of(|c| *c == Call::ApplyStart(rid("PackageInstance", "web")))
        .unwrap();
    assert!(crd_ready <= web_applied);
    assert_eq!(result.unchanged, 2);
    assert_eq!(result.created, 2);
}

/// A Kix CRD the platform never installs fails its node, and nothing
/// that needs it is applied.
#[tokio::test(start_paused = true)]
async fn a_consumer_stops_when_kix_crds_never_appear() {
    let manifests = kix_build(json!({"core": {"consumer": "acme"}}));
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("CustomResourceDefinition", keys::PACKAGE_INSTANCES_CRD),
        NodeScript::default().ready(Behaviour::Now(Ready::TimedOut)),
    );
    let result = run(
        &ops,
        plan_of(&manifests),
        &config(quiet_watchdog()),
        Arc::new(NullObserver),
    )
    .await
    .unwrap();

    assert_eq!(result.failed, 1);
    assert!(
        !ops.calls()
            .contains(&Call::ApplyStart(rid("PackageInstance", "web")))
    );
}

/// A cluster that is no one's consumer applies Kix's CRDs itself.
#[tokio::test(start_paused = true)]
async fn a_cluster_without_a_platform_applies_kix_crds() {
    let manifests = kix_build(json!({}));
    let plan = plan_of(&manifests);
    assert!(!plan.nodes().iter().any(|n| n.kind == TransitionKind::Wait));

    let ops = Arc::new(ScriptedOps::new());
    run(
        &ops,
        plan,
        &config(quiet_watchdog()),
        Arc::new(NullObserver),
    )
    .await
    .unwrap();
    let calls = ops.calls();
    assert!(calls.contains(&Call::ApplyStart(rid(
        "CustomResourceDefinition",
        keys::PACKAGE_INSTANCES_CRD
    ))));
}

/// Stamping an unchanged resource is bounded by the watchdog.
#[tokio::test(start_paused = true)]
async fn hung_stamp_of_unchanged_resource_is_bounded() {
    let manifests = vec![m("ConfigMap", "same", &[]), m("ConfigMap", "new", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.stamp_behaviour(Behaviour::Hang);
    let rec = Arc::new(Recorder::default());
    let cfg = config(quiet_watchdog());

    let start = Instant::now();
    let result = run(
        &ops,
        plan_with_skips(&manifests, &["same"]),
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap();

    assert_eq!(result.unchanged, 1);
    assert_eq!(result.created, 1);
    assert!(ops.calls().contains(&Call::Stamp(rid("ConfigMap", "same"))));
    assert_eq!(start.elapsed(), INLINE_BEST_EFFORT_TIMEOUT);
    let failures = rec.best_effort_failures();
    assert_eq!(failures.len(), 1, "{failures:?}");
    assert!(failures[0].starts_with("activation stamp on unchanged resources: 1 of 1"));
}

/// A hung prune delete is reported as failed. Namespaces are never pruned.
#[tokio::test(start_paused = true)]
async fn hung_prune_delete_is_bounded() {
    let manifests = vec![m("ConfigMap", "keep", &[])];
    let ops = Arc::new(ScriptedOps::new());
    ops.delete_behaviour(Behaviour::Hang);
    let rec = Arc::new(Recorder::default());
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::Delete;
    let orphans = [rid("ConfigMap", "old"), rid("Namespace", "ns")];
    let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];

    let start = Instant::now();
    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &old,
        prune,
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap();

    assert_eq!(result.pruned, 0);
    assert_eq!(
        result.failed, 1,
        "the hung delete counts as failed: {result:?}"
    );
    assert_eq!(start.elapsed(), INLINE_BEST_EFFORT_TIMEOUT);
    let delete_calls: Vec<Call> = ops
        .calls()
        .into_iter()
        .filter(|c| matches!(c, Call::Delete(_)))
        .collect();
    assert_eq!(delete_calls, vec![Call::Delete(rid("ConfigMap", "old"))]);
    // The announced prune list matches what is acted on: the Namespace
    // is never deleted, so it is announced as kept.
    assert_eq!(
        rec.prune_starts(),
        vec![(
            1,
            vec![rid("ConfigMap", "old")],
            vec![rid("Namespace", "ns")],
            true
        )]
    );
    let failed: Vec<(NodeId, Verdict)> = rec
        .terminals()
        .into_iter()
        .filter(|(_, v)| matches!(v, Verdict::Failed { .. }))
        .collect();
    assert_eq!(failed.len(), 1);
    assert_eq!(failed[0].0, NodeId::Resource(rid("ConfigMap", "old")));
}

/// Under warn-only, a Namespace orphan is announced as kept, apart from
/// the orphans the policy reports, and nothing is deleted.
#[tokio::test(start_paused = true)]
async fn warn_only_announces_a_namespace_orphan_as_kept() {
    let manifests = vec![m("ConfigMap", "keep", &[])];
    let ops = Arc::new(ScriptedOps::new());
    let rec = Arc::new(Recorder::default());
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::WarnOnly;
    let orphans = [rid("ConfigMap", "old"), rid("Namespace", "ns")];
    let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];

    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &old,
        prune,
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap();

    assert_eq!(result.pruned, 0);
    assert!(!ops.calls().iter().any(|c| matches!(c, Call::Delete(_))));
    assert_eq!(
        rec.prune_starts(),
        vec![(
            1,
            vec![rid("ConfigMap", "old")],
            vec![rid("Namespace", "ns")],
            false
        )]
    );
}

/// Finalize is told whether a prunable orphan is still on the cluster:
/// true when the policy keeps one or a delete fails, false when every
/// delete succeeds or the only orphans are kinds prune never deletes.
#[tokio::test(start_paused = true)]
async fn finalize_learns_whether_orphans_were_left() {
    async fn orphans_left(
        policy: PrunePolicy,
        orphans: &[ResourceId],
        delete: Behaviour<Result<Pruned, String>>,
    ) -> bool {
        let manifests = vec![m("ConfigMap", "keep", &[])];
        let old = [m("ConfigMap", "old", &[]), m("Namespace", "ns", &[])];
        let ops = Arc::new(ScriptedOps::new());
        ops.delete_behaviour(delete);
        let cfg = config(quiet_watchdog());
        let prune = policy;
        let _ = run_with_orphans(
            &ops,
            plan_of(&manifests),
            orphans,
            &old,
            prune,
            &cfg,
            Arc::new(Recorder::default()),
        )
        .await;
        let finalized: Vec<bool> = ops
            .calls()
            .into_iter()
            .filter_map(|c| match c {
                Call::Finalize { orphans_left, .. } => Some(orphans_left),
                _ => None,
            })
            .collect();
        assert_eq!(finalized.len(), 1, "finalize runs once");
        finalized[0]
    }
    let cm = [rid("ConfigMap", "old")];
    let ns = [rid("Namespace", "ns")];
    let ok = || Behaviour::Now(Ok(Pruned::Deleted));

    assert!(orphans_left(PrunePolicy::WarnOnly, &cm, ok()).await);
    assert!(orphans_left(PrunePolicy::Skip, &cm, ok()).await);
    assert!(!orphans_left(PrunePolicy::Delete, &cm, ok()).await);
    assert!(
        orphans_left(
            PrunePolicy::Delete,
            &cm,
            Behaviour::Now(Err("denied".into()))
        )
        .await
    );
    assert!(!orphans_left(PrunePolicy::WarnOnly, &ns, ok()).await);
    // A delete the guard refused because the object changed leaves it
    // for the next prune; one another Kix cluster still deploys does not.
    let changed = Pruned::Changed(rid("ConfigMap", "old"));
    assert!(orphans_left(PrunePolicy::Delete, &cm, Behaviour::Now(Ok(changed))).await);
    let shared = Pruned::Kept(crate::cluster::inventory::SharedOrphan {
        rid: rid("ConfigMap", "old"),
        clusters: vec!["b".into()],
    });
    assert!(!orphans_left(PrunePolicy::Delete, &cm, Behaviour::Now(Ok(shared))).await);
}

/// An orphan with no manifest among the old manifests is still pruned,
/// after the ones the graph orders.
#[tokio::test(start_paused = true)]
async fn an_orphan_the_old_manifests_lack_is_still_pruned() {
    let manifests = vec![m("ConfigMap", "keep", &[])];
    let ops = Arc::new(ScriptedOps::new());
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::Delete;
    let orphans = [rid("ConfigMap", "listed"), rid("ConfigMap", "unlisted")];
    let old = [m("ConfigMap", "listed", &[])];

    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &old,
        prune,
        &cfg,
        Arc::new(Recorder::default()),
    )
    .await
    .unwrap();

    assert_eq!(result.pruned, 2);
    let deleted: Vec<ResourceId> = ops
        .calls()
        .into_iter()
        .filter_map(|c| match c {
            Call::Delete(rid) => Some(rid),
            _ => None,
        })
        .collect();
    assert_eq!(deleted, orphans.to_vec());
}

/// An orphan the prune guard keeps is reported as kept, not as pruned or
/// failed.
#[tokio::test(start_paused = true)]
async fn a_kept_prune_delete_is_reported_as_kept() {
    let manifests = vec![m("ConfigMap", "keep", &[])];
    let ops = Arc::new(ScriptedOps::new());
    let shared = Pruned::Kept(crate::cluster::inventory::SharedOrphan {
        rid: rid("ConfigMap", "old"),
        clusters: vec!["b".into()],
    });
    ops.delete_behaviour(Behaviour::Now(Ok(shared)));
    let rec = Arc::new(Recorder::default());
    let cfg = config(quiet_watchdog());
    let prune = PrunePolicy::Delete;
    let orphans = [rid("ConfigMap", "old")];
    let old = [m("ConfigMap", "old", &[])];

    let result = run_with_orphans(
        &ops,
        plan_of(&manifests),
        &orphans,
        &old,
        prune,
        &cfg,
        rec.clone(),
    )
    .await
    .unwrap();

    assert_eq!((result.pruned, result.failed), (0, 0));
    let kept: Vec<(ResourceId, String)> = rec
        .0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            DeployEvent::PruneKept { resource, reason } => Some((resource.clone(), reason.clone())),
            _ => None,
        })
        .collect();
    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].0, rid("ConfigMap", "old"));
    assert!(
        kept[0].1.contains("still deployed by Kix cluster b"),
        "{kept:?}"
    );
}

/// Under `OnErrorPolicy::Stop`, nodes still in flight finish and are
/// counted; nodes never admitted get a Cancelled verdict.
#[tokio::test(start_paused = true)]
async fn halt_on_first_failure_finishes_in_flight_and_cancels_the_rest() {
    let manifests = vec![
        m("ConfigMap", "bad", &[]),
        m("ConfigMap", "slow", &[]),
        m("ConfigMap", "later", &["slow"]),
    ];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("ConfigMap", "bad"),
        NodeScript::default().apply(Behaviour::Now(Err(ApplyFailure::Other("nope".into())))),
    );
    ops.script(
        rid("ConfigMap", "slow"),
        NodeScript::default().apply(Behaviour::After(secs(2), Ok(ApplyAction::Created))),
    );
    let rec = Arc::new(Recorder::default());
    let mut cfg = config(quiet_watchdog());
    cfg.on_error = OnErrorPolicy::Stop;

    let err = run(&ops, plan_of(&manifests), &cfg, rec.clone())
        .await
        .unwrap_err();

    let DeployError::NodesFailed { count, partial } = err else {
        panic!("expected NodesFailed, got {err}");
    };
    assert_eq!(count, 1);
    assert_eq!(partial.created, 1, "the in-flight node finished");
    assert_eq!(partial.cancelled, 1, "the never-admitted node is Cancelled");
    for name in ["bad", "slow", "later"] {
        assert_eq!(
            rec.terminal_count(&NodeId::Resource(rid("ConfigMap", name))),
            1,
            "{name}"
        );
    }
    assert!(rec.stopped().unwrap().starts_with("halt-on-first-failure"));
}

// Property tests over generated DAGs and outcomes.

#[derive(Debug, Clone, Copy)]
enum Outcome {
    Ok,
    /// Applies after 1 to 3 virtual seconds. Far below the 30s abort
    /// bound the case runs with, so a Slow node never looks like a hang.
    Slow,
    Fail,
    Hang,
    /// Applies, then readiness fails.
    ReadyFail,
    /// Applies, then readiness never answers.
    ReadyHang,
}

#[derive(Debug, Clone)]
struct Case {
    n: usize,
    /// `edges[j]` holds the predecessors of node `j` (all `< j`).
    preds: Vec<Vec<usize>>,
    outcomes: Vec<Outcome>,
    /// Whether the node has a readiness wait (Deployment) or not
    /// (ConfigMap).
    polled: Vec<bool>,
}

fn case_strategy() -> impl proptest::strategy::Strategy<Value = Case> {
    use proptest::prelude::*;
    (1usize..=24).prop_flat_map(|n| {
        let preds = (0..n)
            .map(|j| proptest::collection::vec(any::<bool>(), j))
            .collect::<Vec<_>>();
        let outcome = prop_oneof![
            6 => Just(Outcome::Ok),
            3 => Just(Outcome::Slow),
            2 => Just(Outcome::Fail),
            1 => Just(Outcome::Hang),
            1 => Just(Outcome::ReadyFail),
            1 => Just(Outcome::ReadyHang),
        ];
        (
            preds,
            proptest::collection::vec(outcome, n),
            proptest::collection::vec(any::<bool>(), n),
        )
            .prop_map(move |(mask, outcomes, polled)| Case {
                n,
                preds: mask
                    .into_iter()
                    .map(|row| {
                        row.into_iter()
                            .enumerate()
                            .filter(|(_, b)| *b)
                            .map(|(i, _)| i)
                            .collect()
                    })
                    .collect(),
                outcomes,
                polled,
            })
    })
}

/// Return true if node `j` requires readiness polling (`Deployment`).
fn polled(case: &Case, j: usize) -> bool {
    case.polled[j] || matches!(case.outcomes[j], Outcome::ReadyFail | Outcome::ReadyHang)
}

fn case_manifests(case: &Case) -> Vec<Value> {
    (0..case.n)
        .map(|j| {
            let kind = if polled(case, j) {
                "Deployment"
            } else {
                "ConfigMap"
            };
            let deps: Vec<String> = case.preds[j].iter().map(|i| format!("n{i}")).collect();
            let deps: Vec<&str> = deps.iter().map(String::as_str).collect();
            m(kind, &format!("n{j}"), &deps)
        })
        .collect()
}

fn node_rid(case: &Case, j: usize) -> ResourceId {
    let kind = if polled(case, j) {
        "Deployment"
    } else {
        "ConfigMap"
    };
    rid(kind, &format!("n{j}"))
}

/// What the engine must do with each node, derived from the case alone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fate {
    Ready,
    Failed,
    /// A predecessor failed or was cancelled: cascade-cancelled, terminal.
    Cancelled,
    /// Ran and never finished. Cancelled by the watchdog's abort.
    Hung,
    /// Waits on a hung ancestor with no failed one: never admitted.
    /// Cancelled when the run stops.
    Pending,
}

fn fates(case: &Case) -> Vec<Fate> {
    let mut out = Vec::with_capacity(case.n);
    for j in 0..case.n {
        let preds: Vec<Fate> = case.preds[j].iter().map(|&i| out[i]).collect();
        let fate = if preds
            .iter()
            .any(|f| matches!(f, Fate::Failed | Fate::Cancelled))
        {
            Fate::Cancelled
        } else if preds
            .iter()
            .any(|f| matches!(f, Fate::Hung | Fate::Pending))
        {
            Fate::Pending
        } else {
            match case.outcomes[j] {
                Outcome::Ok | Outcome::Slow => Fate::Ready,
                Outcome::Fail | Outcome::ReadyFail => Fate::Failed,
                Outcome::Hang | Outcome::ReadyHang => Fate::Hung,
            }
        };
        out.push(fate);
    }
    out
}

fn check_case(case: Case) -> Result<(), proptest::test_runner::TestCaseError> {
    use proptest::prop_assert;
    use proptest::prop_assert_eq;

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    // The fake stamps its log with tokio's (paused) clock.
    let _enter = rt.enter();
    let ops = Arc::new(ScriptedOps::new());
    for j in 0..case.n {
        let apply = match case.outcomes[j] {
            Outcome::Ok | Outcome::ReadyFail | Outcome::ReadyHang => {
                Behaviour::Now(Ok(ApplyAction::Created))
            }
            Outcome::Slow => Behaviour::After(secs(1 + (j as u64 % 3)), Ok(ApplyAction::Created)),
            Outcome::Fail => Behaviour::Now(Err(ApplyFailure::Other(format!("n{j} failed")))),
            Outcome::Hang => Behaviour::Hang,
        };
        let ready = match case.outcomes[j] {
            Outcome::ReadyFail => Behaviour::Now(Ready::Failed(format!("n{j} not ready"))),
            Outcome::ReadyHang => Behaviour::Hang,
            _ => Behaviour::Now(Ready::Ready),
        };
        ops.script(
            node_rid(&case, j),
            NodeScript::default().apply(apply).ready(ready),
        );
    }
    let cfg = config(StallPolicy {
        warn_after: secs(10),
        abort_after: Some(secs(30)),
    });
    let manifests = case_manifests(&case);
    let plan = plan_of(&manifests);
    let rec = Arc::new(Recorder::default());
    let outcome = rt.block_on(tokio::time::timeout(
        secs(3600),
        run_scripted(
            ops.clone(),
            plan,
            &[],
            &[],
            PrunePolicy::WarnOnly,
            &cfg,
            rec.clone(),
        ),
    ));
    let outcome = match outcome {
        Ok(o) => o,
        Err(_) => return Err(proptest::test_runner::TestCaseError::fail("engine parked")),
    };

    // A node scripted to hang only hangs if it runs; one behind a failed
    // predecessor is cancelled instead.
    let fates = fates(&case);
    let any_hang = fates.iter().any(|f| matches!(f, Fate::Hung));
    let result = match (&outcome, any_hang) {
        (Ok(r), false) => r.clone(),
        (Err(DeployError::Cancelled { partial, reason }), true) => {
            prop_assert!(reason.starts_with("no progress"), "{reason}");
            partial.clone()
        }
        (other, _) => {
            return Err(proptest::test_runner::TestCaseError::fail(format!(
                "unexpected outcome {other:?} (any_hang={any_hang})"
            )));
        }
    };

    let calls = ops.log();
    let started: HashSet<ResourceId> = calls
        .iter()
        .filter_map(|l| match &l.call {
            Call::ApplyStart(r) => Some(r.clone()),
            _ => None,
        })
        .collect();
    let mut expected = DeployResult::default();
    for (j, fate) in fates.iter().enumerate() {
        let r = node_rid(&case, j);
        match fate {
            Fate::Ready => {
                expected.created += 1;
                prop_assert!(started.contains(&r), "n{j} never ran");
            }
            Fate::Failed => {
                expected.failed += 1;
                prop_assert!(started.contains(&r), "n{j} never ran");
            }
            Fate::Hung => {
                expected.cancelled += 1;
                prop_assert!(started.contains(&r), "n{j} never ran");
            }
            Fate::Cancelled => {
                expected.cancelled += 1;
                prop_assert!(
                    !started.contains(&r),
                    "n{j} ran despite a failed predecessor"
                );
            }
            Fate::Pending => {
                expected.cancelled += 1;
                prop_assert!(!started.contains(&r), "n{j} ran despite a hung predecessor");
            }
        }
        // Exactly one terminal verdict per node, whatever stopped the run.
        let node = NodeId::Resource(r);
        prop_assert_eq!(
            rec.terminal_count(&node),
            1,
            "n{} ({:?}) terminal verdicts: {:?}",
            j,
            fates[j],
            rec.terminals()
                .into_iter()
                .filter(|(n, _)| *n == node)
                .collect::<Vec<_>>()
        );
    }
    // The counts are a pure function of the case and add up to the plan.
    prop_assert_eq!(
        result.created,
        expected.created,
        "created: {:?} vs fates {:?}",
        result,
        fates
    );
    prop_assert_eq!(
        result.failed,
        expected.failed,
        "failed: {:?} vs fates {:?}",
        result,
        fates
    );
    prop_assert_eq!(
        result.cancelled,
        expected.cancelled,
        "cancelled: {:?} vs fates {:?}",
        result,
        fates
    );
    prop_assert_eq!(result.configured + result.unchanged + result.pruned, 0);
    prop_assert_eq!(total(&result), case.n);

    // Ordering: a node starts only after every predecessor is done. Log
    // position, not virtual time: most nodes finish at t=0, where a time
    // comparison proves nothing.
    let index_of = |call: &Call| calls.iter().position(|l| l.call == *call);
    for j in 0..case.n {
        let r = node_rid(&case, j);
        let Some(start) = index_of(&Call::ApplyStart(r)) else {
            continue;
        };
        for &i in &case.preds[j] {
            let p = node_rid(&case, i);
            let done = index_of(&Call::ReadyEnd(p.clone()))
                .or_else(|| index_of(&Call::ApplyEnd(p.clone())))
                .expect("predecessor of a started node finished");
            prop_assert!(
                start > done,
                "n{j} started (log #{start}) before n{i} finished (log #{done})"
            );
        }
    }
    Ok(())
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config { cases: 96, .. Default::default() })]
    #[test]
    fn random_dags_reach_terminal_verdicts_in_order(case in case_strategy()) {
        check_case(case)?;
    }
}

/// A field the server did not keep is a warning event. The node is still
/// ready and the run succeeds.
#[tokio::test(start_paused = true)]
async fn fields_the_server_did_not_keep_warn_and_the_run_goes_on() {
    use crate::cluster::kept::{NotKept, NotKeptField};
    let manifests = vec![m("Widget", "w", &[]), m("ConfigMap", "cm", &[])];
    let pruned = vec![NotKeptField {
        path: "$.spec.colour".into(),
        change: NotKept::Dropped,
        sent: json!("red"),
        stored: None,
    }];
    let ops = Arc::new(ScriptedOps::new());
    ops.script(
        rid("Widget", "w"),
        NodeScript::default().not_kept(pruned.clone()),
    );
    let rec = Arc::new(Recorder::default());
    let result = run(
        &ops,
        plan_of(&manifests),
        &config(quiet_watchdog()),
        rec.clone(),
    )
    .await
    .unwrap();
    assert_eq!((result.created, result.failed), (2, 0));
    let warned: Vec<(ResourceId, Vec<NotKeptField>)> = rec
        .0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match e {
            DeployEvent::FieldsNotKept { resource, fields } => {
                Some((resource.clone(), fields.clone()))
            }
            _ => None,
        })
        .collect();
    assert_eq!(warned, vec![(rid("Widget", "w"), pruned)]);
}
