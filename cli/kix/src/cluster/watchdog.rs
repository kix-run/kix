//! Detect deploy runs that stop reporting progress.
//!
//! Node tasks record phases in `Progress`, and every deploy event or
//! readiness heartbeat resets its idle timer. `assess` decides whether a
//! timer tick should warn or abort. `run` emits stall events and cancels the
//! run through [`CancelToken`] without accessing the cluster.
//!
//! Readiness polling counts as activity on the idle timer, so a long wait on a
//! single object is not treated as a stall. Instead, `run` emits a `Waiting`
//! event per node once it has remained in its phase for [`WAIT_REPORT_AFTER`],
//! and repeats the event on [`wait_due`]'s schedule while the wait continues.
//! The event also names the objects the wait holds up, read from the plan's
//! edges that the engine hands `Progress` once at the start of the run.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::time::{Instant, MissedTickBehavior};

use super::cancel::CancelToken;
use super::stream::{DeployEvent, DeployObserver, InFlight, NodeId, Phase};

/// Environment variable for the abort bound, in seconds. `0` disables the
/// abort (the warnings still print).
pub(crate) const STALL_TIMEOUT_ENV: &str = "KIX_STALL_TIMEOUT";

/// Idle thresholds for warnings and cancellation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StallPolicy {
    /// Idle time after which the first `Stalled` event fires, and the interval
    /// at which it repeats while the stall lasts.
    pub warn_after: Duration,
    /// Idle time after which the run is cancelled. `None` never aborts.
    pub abort_after: Option<Duration>,
}

impl Default for StallPolicy {
    fn default() -> Self {
        Self {
            warn_after: Duration::from_secs(30),
            abort_after: Some(Duration::from_secs(600)),
        }
    }
}

impl StallPolicy {
    /// Return the default policy with `KIX_STALL_TIMEOUT` applied.
    pub fn from_env() -> Self {
        let mut policy = Self::default();
        if let Some(secs) = super::client::env_number(STALL_TIMEOUT_ENV) {
            policy.abort_after = (secs > 0).then(|| Duration::from_secs(secs));
        }
        policy
    }

    /// Return a policy with warnings and cancellation disabled.
    pub fn off() -> Self {
        Self {
            warn_after: Duration::MAX,
            abort_after: None,
        }
    }
}

/// Duration a node must remain in one phase before `run` reports the wait.
pub(crate) const WAIT_REPORT_AFTER: Duration = Duration::from_secs(10);

/// Ages at which a wait is reported after the first report, before repeating
/// every [`WAIT_REPORT_EVERY`].
const WAIT_REPORT_AT: [Duration; 3] = [
    Duration::from_secs(30),
    Duration::from_secs(60),
    Duration::from_secs(120),
];
const WAIT_REPORT_EVERY: Duration = Duration::from_secs(60);

/// Return whether a node that has waited `since` is due for a report, given
/// the `reported` age of its last report.
pub(crate) fn wait_due(since: Duration, reported: Option<Duration>) -> bool {
    let next = match reported {
        None => WAIT_REPORT_AFTER,
        Some(last) => WAIT_REPORT_AT
            .iter()
            .copied()
            .find(|at| *at > last)
            .unwrap_or_else(|| last.saturating_add(WAIT_REPORT_EVERY)),
    };
    since >= next
}

/// One node in flight.
#[derive(Debug)]
struct Flight {
    phase: Phase,
    since: Instant,
    /// The last readiness message the node reported.
    status: Option<String>,
    /// The node's age when its wait was last reported.
    reported: Option<Duration>,
}

/// Shared progress record between the engine, its node tasks, and the
/// watchdog.
#[derive(Debug)]
pub(crate) struct Progress {
    started: Instant,
    /// Millis since `started` of the last activity of any kind.
    last_activity_ms: AtomicU64,
    in_flight: Mutex<HashMap<NodeId, Flight>>,
    /// The readiness timeout in millis, for `Waiting` events to name the
    /// budget a wait runs against. Zero until the engine sets it.
    readiness_budget_ms: AtomicU64,
    /// What the plan says each node holds up, for `Waiting` events.
    held: Mutex<Held>,
}

/// The plan as `holds` reads it.
#[derive(Debug, Default)]
struct Held {
    /// The direct dependents of each node, from the plan's edges.
    dependents: HashMap<NodeId, Vec<NodeId>>,
    /// The nodes that run a task. An unchanged node finishes the moment its
    /// predecessors do, so it is never held up, but the nodes behind it are.
    working: HashSet<NodeId>,
    /// The nodes with a terminal verdict, which nothing holds up any more.
    finished: HashSet<NodeId>,
    /// Nodes that hold up what other nodes hold up: the API discovery
    /// refresh stands for the CRDs it covers.
    stands_for: HashMap<NodeId, Vec<NodeId>>,
}

impl Held {
    /// Return whether `node` is an object a wait holds up: a resource that
    /// still has work to do.
    fn counts(&self, node: &NodeId) -> bool {
        node.is_resource() && self.working.contains(node) && !self.finished.contains(node)
    }
}

/// The objects a node holds up: its direct dependents that count, sorted by
/// kind, namespace, and name, and the number of objects that wait on it
/// directly or through other nodes.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Holds {
    pub(crate) direct: Vec<NodeId>,
    pub(crate) total: usize,
}

impl Default for Progress {
    fn default() -> Self {
        Self::new()
    }
}

impl Progress {
    pub(crate) fn new() -> Self {
        Self {
            started: Instant::now(),
            last_activity_ms: AtomicU64::new(0),
            in_flight: Mutex::new(HashMap::new()),
            readiness_budget_ms: AtomicU64::new(0),
            held: Mutex::new(Held::default()),
        }
    }

    /// Set the readiness timeout reported in `Waiting` events.
    pub(crate) fn set_readiness_budget(&self, budget: Duration) {
        self.readiness_budget_ms
            .store(budget.as_millis() as u64, Ordering::Relaxed);
    }

    /// Record the plan's `(dependent, predecessor)` edges and the nodes that
    /// run a task, so `Waiting` events can name what each node holds up.
    pub(crate) fn set_plan(
        &self,
        edges: &[(NodeId, NodeId)],
        working: impl IntoIterator<Item = NodeId>,
    ) {
        if let Ok(mut held) = self.held.lock() {
            *held = Held {
                working: working.into_iter().collect(),
                ..Held::default()
            };
            for (dependent, predecessor) in edges {
                held.dependents
                    .entry(predecessor.clone())
                    .or_default()
                    .push(dependent.clone());
            }
        }
    }

    /// Record that `node` holds up whatever `nodes` hold up, as the API
    /// discovery refresh does for the CRDs it covers.
    pub(crate) fn set_stands_for(&self, node: &NodeId, nodes: &[NodeId]) {
        if let Ok(mut held) = self.held.lock() {
            held.stands_for.insert(node.clone(), nodes.to_vec());
        }
    }

    /// Record that `node` has a terminal verdict, so no wait holds it up.
    pub(crate) fn finished(&self, node: &NodeId) {
        if let Ok(mut held) = self.held.lock() {
            held.finished.insert(node.clone());
        }
    }

    /// Return what `node` holds up. The walk goes through every dependent,
    /// unchanged and synthetic ones included, and counts the resources that
    /// still have work to do.
    pub(crate) fn holds(&self, node: &NodeId) -> Holds {
        let Ok(held) = self.held.lock() else {
            return Holds::default();
        };
        let roots: Vec<&NodeId> = match held.stands_for.get(node) {
            Some(nodes) => nodes.iter().collect(),
            None => vec![node],
        };
        let mut seen: HashSet<&NodeId> = HashSet::new();
        let mut queue: VecDeque<&NodeId> = VecDeque::new();
        let mut direct: Vec<&NodeId> = Vec::new();
        for root in roots {
            for dependent in held.dependents.get(root).into_iter().flatten() {
                if seen.insert(dependent) {
                    queue.push_back(dependent);
                    if held.counts(dependent) {
                        direct.push(dependent);
                    }
                }
            }
        }
        while let Some(next) = queue.pop_front() {
            for dependent in held.dependents.get(next).into_iter().flatten() {
                if seen.insert(dependent) {
                    queue.push_back(dependent);
                }
            }
        }
        direct.sort_by_key(|n| n.sort_key());
        Holds {
            direct: direct.into_iter().cloned().collect(),
            total: seen.iter().filter(|n| held.counts(n)).count(),
        }
    }

    fn readiness_budget(&self) -> Option<Duration> {
        match self.readiness_budget_ms.load(Ordering::Relaxed) {
            0 => None,
            ms => Some(Duration::from_millis(ms)),
        }
    }

    /// Reset the idle clock after any deploy or readiness activity.
    pub(crate) fn touch(&self) {
        let ms = self.started.elapsed().as_millis() as u64;
        self.last_activity_ms.fetch_max(ms, Ordering::Relaxed);
    }

    /// Record that `node` entered `phase`.
    pub(crate) fn set_phase(&self, node: &NodeId, phase: Phase) {
        if let Ok(mut m) = self.in_flight.lock() {
            m.insert(
                node.clone(),
                Flight {
                    phase,
                    since: Instant::now(),
                    status: None,
                    reported: None,
                },
            );
        }
        self.touch();
    }

    /// Record the latest readiness message for `node` without resetting the
    /// idle timer (the scheduler's event for the same message already resets it).
    pub(crate) fn set_status(&self, node: &NodeId, status: &str) {
        if let Ok(mut m) = self.in_flight.lock()
            && let Some(flight) = m.get_mut(node)
        {
            flight.status = Some(status.to_string());
        }
    }

    /// Collect `Waiting` events for in-flight nodes due for a report
    /// ([`wait_due`]) and mark each as reported at its current age.
    pub(crate) fn due_waits(&self) -> Vec<DeployEvent> {
        let now = Instant::now();
        let budget = self.readiness_budget();
        let mut due: Vec<(NodeId, Phase, Duration, Option<String>)> = Vec::new();
        if let Ok(mut m) = self.in_flight.lock() {
            for (node, flight) in m.iter_mut() {
                let since = now.saturating_duration_since(flight.since);
                if !wait_due(since, flight.reported) {
                    continue;
                }
                flight.reported = Some(since);
                due.push((node.clone(), flight.phase, since, flight.status.clone()));
            }
        }
        // Longest wait first, so the output order is stable.
        due.sort_by_key(|(_, _, since, _)| std::cmp::Reverse(*since));
        due.into_iter()
            .map(|(node, phase, since, status)| {
                let holds = self.holds(&node);
                DeployEvent::Waiting {
                    node,
                    phase,
                    since,
                    status,
                    budget: (phase == Phase::Readiness).then_some(budget).flatten(),
                    holds: holds.direct,
                    holds_total: holds.total,
                }
            })
            .collect()
    }

    /// Remove `node` from the in-flight set when it reaches a terminal verdict.
    pub(crate) fn clear(&self, node: &NodeId) {
        if let Ok(mut m) = self.in_flight.lock() {
            m.remove(node);
        }
        self.touch();
    }

    /// Return the duration elapsed since the last activity.
    pub(crate) fn idle(&self) -> Duration {
        let last = Duration::from_millis(self.last_activity_ms.load(Ordering::Relaxed));
        self.started.elapsed().saturating_sub(last)
    }

    /// Return a snapshot of in-flight nodes, sorted longest-waiting first.
    pub(crate) fn in_flight(&self) -> Vec<InFlight> {
        let now = Instant::now();
        let mut out: Vec<InFlight> = self
            .in_flight
            .lock()
            .map(|m| {
                m.iter()
                    .map(|(node, flight)| InFlight {
                        node: node.clone(),
                        phase: flight.phase,
                        since: now.saturating_duration_since(flight.since),
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by_key(|b| std::cmp::Reverse(b.since));
        out
    }

    #[cfg(test)]
    pub(crate) fn in_flight_count(&self) -> usize {
        self.in_flight.lock().map(|m| m.len()).unwrap_or(0)
    }
}

/// Action selected for one watchdog tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Assessment {
    /// Activity is within the warning threshold, or no nodes are in flight.
    Quiet,
    /// Emit a stall warning.
    Warn,
    /// Emit a stall event and cancel the run.
    Abort,
}

/// Select an action from idle time and in-flight work. `last_warned` records
/// the idle duration of the previous warning so warnings repeat no more often
/// than `warn_after`.
pub(crate) fn assess(
    policy: &StallPolicy,
    idle: Duration,
    in_flight: usize,
    last_warned: Option<Duration>,
) -> Assessment {
    if in_flight == 0 {
        return Assessment::Quiet;
    }
    if let Some(abort) = policy.abort_after
        && idle >= abort
    {
        return Assessment::Abort;
    }
    if idle < policy.warn_after {
        return Assessment::Quiet;
    }
    match last_warned {
        Some(prev) if idle < prev.saturating_add(policy.warn_after) => Assessment::Quiet,
        _ => Assessment::Warn,
    }
}

/// Describe the current stall and up to five in-flight nodes.
pub fn describe(idle: Duration, in_flight: &[InFlight]) -> String {
    const SHOWN: usize = 5;
    let mut parts: Vec<String> = in_flight
        .iter()
        .take(SHOWN)
        .map(|f| {
            format!(
                "{} ({}, {}s)",
                node_label(&f.node),
                f.phase.as_str(),
                f.since.as_secs()
            )
        })
        .collect();
    if in_flight.len() > SHOWN {
        parts.push(format!("and {} more", in_flight.len() - SHOWN));
    }
    format!(
        "no progress for {}s: waiting on {}",
        idle.as_secs(),
        parts.join(", ")
    )
}

/// Format a one-line summary for a `Waiting` event naming the node, its wait
/// duration and readiness budget, the latest readiness message or phase,
/// and the objects the wait holds up. `holds` is the direct dependents and
/// `holds_total` every object that waits on the node directly or through
/// others; the line names up to three and counts the rest.
pub fn describe_wait(
    node: &NodeId,
    phase: Phase,
    since: Duration,
    status: Option<&str>,
    budget: Option<Duration>,
    holds: &[NodeId],
    holds_total: usize,
) -> String {
    let doing = match (status, phase) {
        (Some(status), _) => status.to_string(),
        (None, Phase::Readiness) => "waiting for readiness".to_string(),
        (None, Phase::Apply) => "apply request outstanding".to_string(),
        (None, Phase::Hydrate) => "decrypting secrets".to_string(),
        (None, Phase::Discovery) => "refreshing API discovery".to_string(),
    };
    let age = match budget {
        Some(budget) if phase == Phase::Readiness => {
            format!("{}s of {}s", since.as_secs(), budget.as_secs())
        }
        _ => format!("{}s", since.as_secs()),
    };
    format!(
        "{} waiting: {doing} ({age}){}",
        node_label(node),
        describe_holds(holds, holds_total)
    )
}

/// Format the `; N objects wait for it: ...` suffix of a `Waiting` line, or
/// nothing when `holds_total` is zero.
fn describe_holds(holds: &[NodeId], holds_total: usize) -> String {
    const NAMED: usize = 3;
    if holds_total == 0 {
        return String::new();
    }
    let what = if holds_total == 1 {
        "1 object waits for it".to_string()
    } else {
        format!("{holds_total} objects wait for it")
    };
    let names: Vec<String> = holds.iter().take(NAMED).map(node_label).collect();
    let more = holds_total.saturating_sub(names.len());
    let list = match (names.len(), more) {
        (0, _) => String::new(),
        (_, 0) => names.join(", "),
        (1, _) => format!("{} and {more} more", names[0]),
        _ => format!("{}, and {more} more", names.join(", ")),
    };
    if list.is_empty() {
        format!("; {what}")
    } else {
        format!("; {what}: {list}")
    }
}

fn node_label(id: &NodeId) -> String {
    match id {
        NodeId::Resource(rid) => rid.display_id(),
        NodeId::Synthetic(s) => s.clone(),
    }
}

/// Check progress every `min(warn_after, abort_after, 5s)`, with a 100ms
/// minimum interval. Emit `Stalled` events and cancel after the abort threshold.
/// Returns when cancellation fires, or when the engine aborts this task at the
/// end of the run.
pub(crate) async fn run(
    policy: StallPolicy,
    progress: Arc<Progress>,
    cancel: CancelToken,
    observer: Arc<dyn DeployObserver>,
) {
    if policy.warn_after == Duration::MAX && policy.abort_after.is_none() {
        return;
    }
    let period = policy
        .warn_after
        .min(policy.abort_after.unwrap_or(Duration::MAX))
        .min(Duration::from_secs(5))
        .max(Duration::from_millis(100));
    let mut ticker = tokio::time::interval(period);
    // Delay missed ticks so a stalled executor does not produce several
    // catch-up warnings at once.
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut last_warned: Option<Duration> = None;
    loop {
        tokio::select! {
            _ = cancel.cancelled() => return,
            _ = ticker.tick() => {}
        }
        for event in progress.due_waits() {
            observer.on_event(&event);
        }
        let idle = progress.idle();
        let in_flight = progress.in_flight();
        match assess(&policy, idle, in_flight.len(), last_warned) {
            Assessment::Quiet => {
                if in_flight.is_empty() || idle < policy.warn_after {
                    last_warned = None;
                }
            }
            Assessment::Warn => {
                last_warned = Some(idle);
                observer.on_event(&DeployEvent::Stalled {
                    idle,
                    in_flight,
                    aborting: false,
                });
            }
            Assessment::Abort => {
                let reason = format!(
                    "{}; giving up (set {STALL_TIMEOUT_ENV} to change the bound)",
                    describe(idle, &in_flight)
                );
                observer.on_event(&DeployEvent::Stalled {
                    idle,
                    in_flight,
                    aborting: true,
                });
                cancel.cancel_with_reason(reason);
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::types::ResourceId;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    fn policy() -> StallPolicy {
        StallPolicy {
            warn_after: secs(30),
            abort_after: Some(secs(600)),
        }
    }

    /// A wait is reported at 10s, then at 30, 60, and 120, then every 60s.
    #[test]
    fn waits_are_reported_on_a_widening_schedule() {
        assert!(!wait_due(secs(9), None));
        assert!(wait_due(secs(10), None));
        assert!(!wait_due(secs(29), Some(secs(10))));
        assert!(wait_due(secs(30), Some(secs(10))));
        assert!(wait_due(secs(61), Some(secs(31))));
        assert!(!wait_due(secs(119), Some(secs(61))));
        assert!(wait_due(secs(120), Some(secs(61))));
        assert!(!wait_due(secs(179), Some(secs(120))));
        assert!(wait_due(secs(180), Some(secs(120))));
        assert!(wait_due(secs(241), Some(secs(181))));
    }

    /// `due_waits` reports a node once per due age, carries its last
    /// readiness message, and names the budget only for a readiness wait.
    #[tokio::test(start_paused = true)]
    async fn due_waits_report_each_node_once_per_step() {
        let progress = Progress::new();
        progress.set_readiness_budget(secs(180));
        let node = NodeId::Resource(ResourceId {
            kind: "Service".into(),
            namespace: "app".into(),
            name: "web".into(),
        });
        progress.set_phase(&node, Phase::Readiness);
        progress.set_status(&node, "not found yet");
        assert!(progress.due_waits().is_empty());
        tokio::time::advance(secs(10)).await;
        let events = progress.due_waits();
        assert_eq!(events.len(), 1);
        match &events[0] {
            DeployEvent::Waiting {
                phase,
                since,
                status,
                budget,
                holds,
                holds_total,
                ..
            } => {
                assert_eq!(*phase, Phase::Readiness);
                assert_eq!(since.as_secs(), 10);
                assert_eq!(status.as_deref(), Some("not found yet"));
                assert_eq!(*budget, Some(secs(180)));
                assert!(holds.is_empty());
                assert_eq!(*holds_total, 0);
            }
            other => panic!("{other:?}"),
        }
        assert!(progress.due_waits().is_empty(), "reported once per step");
        tokio::time::advance(secs(20)).await;
        assert_eq!(progress.due_waits().len(), 1);
        progress.clear(&node);
        tokio::time::advance(secs(60)).await;
        assert!(progress.due_waits().is_empty());
    }

    fn res(kind: &str, namespace: &str, name: &str) -> NodeId {
        NodeId::Resource(ResourceId {
            kind: kind.into(),
            namespace: namespace.into(),
            name: name.into(),
        })
    }

    /// `holds` names the direct dependents that are resources, sorted by
    /// kind, namespace, and name, and counts every resource downstream.
    #[test]
    fn holds_sorts_direct_dependents_and_counts_through_two_levels() {
        let crd = res("CustomResourceDefinition", "_cluster", "foos.example.com");
        let operator = res("Deployment", "foo", "foo-operator");
        let b = res("Foo", "apps", "b");
        let a = res("Foo", "apps", "a");
        let svc = res("Service", "foo", "foo-operator");
        let gate = NodeId::Synthetic("pause-1".into());
        let after = res("Deployment", "apps", "after");
        let progress = Progress::new();
        let edges = [
            (b.clone(), crd.clone()),
            (operator.clone(), crd.clone()),
            (a.clone(), crd.clone()),
            (gate.clone(), crd.clone()),
            (svc.clone(), operator.clone()),
            (after.clone(), gate.clone()),
            (after.clone(), svc.clone()),
        ];
        progress.set_plan(&edges, edges.iter().map(|(d, _)| d.clone()));
        assert_eq!(
            progress.holds(&crd),
            Holds {
                direct: vec![operator.clone(), a.clone(), b.clone()],
                total: 5,
            }
        );
        assert_eq!(
            progress.holds(&operator),
            Holds {
                direct: vec![svc.clone()],
                total: 2,
            }
        );
        assert_eq!(progress.holds(&after), Holds::default());
        assert_eq!(
            progress.holds(&NodeId::Synthetic("api-discovery".into())),
            Holds::default()
        );
    }

    /// An unchanged node is neither named nor counted, but the working nodes
    /// behind it are. A node with a terminal verdict drops out of the count.
    #[test]
    fn holds_skips_unchanged_and_finished_nodes_but_walks_through_them() {
        let crd = res("CustomResourceDefinition", "_cluster", "foos.example.com");
        let unchanged = res("ConfigMap", "apps", "unchanged");
        let behind = res("Deployment", "apps", "behind");
        let changed = res("Deployment", "apps", "changed");
        let sibling = res("Service", "apps", "sibling");
        let progress = Progress::new();
        progress.set_plan(
            &[
                (unchanged.clone(), crd.clone()),
                (behind.clone(), unchanged.clone()),
                (changed.clone(), crd.clone()),
                (sibling.clone(), changed.clone()),
            ],
            [behind.clone(), changed.clone(), sibling.clone()],
        );
        assert_eq!(
            progress.holds(&crd),
            Holds {
                direct: vec![changed.clone()],
                total: 3,
            }
        );
        progress.finished(&changed);
        progress.finished(&sibling);
        assert_eq!(
            progress.holds(&crd),
            Holds {
                direct: vec![],
                total: 1,
            }
        );
    }

    /// A node that stands for others, as the discovery refresh does for the
    /// CRDs it covers, holds up their dependents.
    #[test]
    fn holds_of_a_node_standing_for_others_are_their_dependents() {
        let foos = res("CustomResourceDefinition", "_cluster", "foos.example.com");
        let bars = res("CustomResourceDefinition", "_cluster", "bars.example.com");
        let foo = res("Foo", "apps", "x");
        let bar = res("Bar", "apps", "y");
        let after = res("Deployment", "apps", "after");
        let discovery = NodeId::Synthetic("api-discovery".into());
        let progress = Progress::new();
        progress.set_plan(
            &[
                (foo.clone(), foos.clone()),
                (bar.clone(), bars.clone()),
                (after.clone(), foo.clone()),
                (after.clone(), bar.clone()),
            ],
            [foo.clone(), bar.clone(), after.clone()],
        );
        assert_eq!(progress.holds(&discovery), Holds::default());
        progress.set_stands_for(&discovery, &[foos.clone(), bars.clone()]);
        assert_eq!(
            progress.holds(&discovery),
            Holds {
                direct: vec![bar.clone(), foo.clone()],
                total: 3,
            }
        );
    }

    /// `due_waits` carries what the slow node holds up.
    #[tokio::test(start_paused = true)]
    async fn due_waits_carry_the_held_objects() {
        let crd = res("CustomResourceDefinition", "_cluster", "foos.example.com");
        let a = res("Foo", "apps", "a");
        let b = res("Deployment", "apps", "b");
        let progress = Progress::new();
        progress.set_plan(
            &[(a.clone(), crd.clone()), (b.clone(), a.clone())],
            [a.clone(), b.clone()],
        );
        progress.set_phase(&crd, Phase::Readiness);
        tokio::time::advance(secs(10)).await;
        let events = progress.due_waits();
        match &events[..] {
            [
                DeployEvent::Waiting {
                    holds, holds_total, ..
                },
            ] => {
                assert_eq!(holds, std::slice::from_ref(&a));
                assert_eq!(*holds_total, 2);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn describe_wait_names_the_status_and_the_budget() {
        let node = res("Service", "app", "web");
        assert_eq!(
            describe_wait(
                &node,
                Phase::Readiness,
                secs(30),
                Some("import target Service/web not found yet"),
                Some(secs(180)),
                &[],
                0,
            ),
            "Service/web@app waiting: import target Service/web not found yet (30s of 180s)"
        );
        assert_eq!(
            describe_wait(&node, Phase::Apply, secs(12), None, Some(secs(180)), &[], 0),
            "Service/web@app waiting: apply request outstanding (12s)"
        );
    }

    /// The suffix names up to three direct dependents, counts the rest, uses
    /// the singular for one, and is absent when nothing waits.
    #[test]
    fn describe_wait_names_what_the_wait_holds_up() {
        let crd = res("CustomResourceDefinition", "_cluster", "foos.example.com");
        let wait = |holds: &[NodeId], total: usize| {
            describe_wait(
                &crd,
                Phase::Readiness,
                secs(30),
                Some("CRD present, waiting for Established=True"),
                Some(secs(180)),
                holds,
                total,
            )
        };
        let head = "CustomResourceDefinition/foos.example.com waiting: \
                    CRD present, waiting for Established=True (30s of 180s)";
        let operator = res("Deployment", "foo", "foo-operator");
        let a = res("Foo", "apps", "a");
        let b = res("Foo", "apps", "b");
        let c = res("Foo", "apps", "c");
        assert_eq!(
            wait(&[operator.clone(), a.clone(), b.clone(), c.clone()], 6),
            format!(
                "{head}; 6 objects wait for it: Deployment/foo-operator@foo, Foo/a@apps, \
                 Foo/b@apps, and 3 more"
            )
        );
        assert_eq!(
            wait(&[operator.clone(), a.clone()], 2),
            format!("{head}; 2 objects wait for it: Deployment/foo-operator@foo, Foo/a@apps")
        );
        // Three or fewer direct dependents, but more behind them.
        assert_eq!(
            wait(std::slice::from_ref(&operator), 4),
            format!("{head}; 4 objects wait for it: Deployment/foo-operator@foo and 3 more")
        );
        assert_eq!(
            wait(&[operator.clone(), a.clone()], 3),
            format!(
                "{head}; 3 objects wait for it: Deployment/foo-operator@foo, Foo/a@apps, \
                 and 1 more"
            )
        );
        assert_eq!(
            wait(std::slice::from_ref(&operator), 1),
            format!("{head}; 1 object waits for it: Deployment/foo-operator@foo")
        );
        // Only a synthetic node waits directly, with resources behind it.
        assert_eq!(wait(&[], 2), format!("{head}; 2 objects wait for it"));
        assert_eq!(wait(&[], 0), head);
    }

    #[test]
    fn quiet_while_progressing_or_idle_with_nothing_in_flight() {
        assert_eq!(assess(&policy(), secs(5), 3, None), Assessment::Quiet);
        assert_eq!(assess(&policy(), secs(29), 3, None), Assessment::Quiet);
        assert_eq!(assess(&policy(), secs(1000), 0, None), Assessment::Quiet);
    }

    #[test]
    fn warns_at_the_bound_and_repeats_every_bound() {
        assert_eq!(assess(&policy(), secs(30), 1, None), Assessment::Warn);
        assert_eq!(
            assess(&policy(), secs(45), 1, Some(secs(30))),
            Assessment::Quiet
        );
        assert_eq!(
            assess(&policy(), secs(60), 1, Some(secs(30))),
            Assessment::Warn
        );
    }

    #[test]
    fn aborts_at_the_abort_bound_and_never_when_disabled() {
        assert_eq!(
            assess(&policy(), secs(600), 1, Some(secs(570))),
            Assessment::Abort
        );
        let never = StallPolicy {
            abort_after: None,
            ..policy()
        };
        assert_eq!(assess(&never, secs(100_000), 1, None), Assessment::Warn);
    }

    #[test]
    fn env_zero_disables_abort() {
        // SAFETY: tests in this module are the only readers of this variable
        // and run in one process. The value is restored below.
        unsafe { std::env::set_var(STALL_TIMEOUT_ENV, "0") };
        assert_eq!(StallPolicy::from_env().abort_after, None);
        unsafe { std::env::set_var(STALL_TIMEOUT_ENV, "90") };
        assert_eq!(StallPolicy::from_env().abort_after, Some(secs(90)));
        unsafe { std::env::remove_var(STALL_TIMEOUT_ENV) };
        assert_eq!(StallPolicy::from_env(), StallPolicy::default());
    }

    #[test]
    fn describe_names_the_longest_waiting_first_and_caps_the_list() {
        let f = |name: &str, phase: Phase, s: u64| InFlight {
            node: NodeId::Resource(ResourceId {
                kind: "Deployment".into(),
                namespace: "default".into(),
                name: name.into(),
            }),
            phase,
            since: secs(s),
        };
        let line = describe(
            secs(31),
            &[f("a", Phase::Apply, 31), f("b", Phase::Readiness, 29)],
        );
        assert_eq!(
            line,
            "no progress for 31s: waiting on Deployment/a@default (apply, 31s), Deployment/b@default (readiness, 29s)"
        );
        let many: Vec<InFlight> = (0..7)
            .map(|i| f(&format!("n{i}"), Phase::Apply, 10))
            .collect();
        assert!(describe(secs(10), &many).ends_with("and 2 more"));
    }

    #[tokio::test(start_paused = true)]
    async fn progress_idle_and_snapshot() {
        let p = Progress::new();
        let node = NodeId::Synthetic("x".into());
        p.set_phase(&node, Phase::Apply);
        tokio::time::advance(secs(40)).await;
        assert_eq!(p.idle(), secs(40));
        let snap = p.in_flight();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].phase, Phase::Apply);
        assert_eq!(snap[0].since, secs(40));
        p.touch();
        assert_eq!(p.idle(), Duration::ZERO);
        p.clear(&node);
        assert_eq!(p.in_flight_count(), 0);
    }
}
