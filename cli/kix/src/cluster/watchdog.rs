//! Detect deploy runs that stop reporting progress.
//!
//! Node tasks record phases in `Progress`, and every deploy event or
//! readiness heartbeat resets its idle timer. `assess` decides whether a
//! timer tick should warn or abort. `run` emits stall events and cancels the
//! run through [`CancelToken`]; it does not access the cluster.

use std::collections::HashMap;
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
    /// Idle time after which the first `Stalled` event fires; repeated at
    /// this interval while the stall lasts.
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
    /// Defaults with `KIX_STALL_TIMEOUT` applied.
    pub fn from_env() -> Self {
        let mut policy = Self::default();
        if let Some(secs) = super::client::env_number(STALL_TIMEOUT_ENV) {
            policy.abort_after = (secs > 0).then(|| Duration::from_secs(secs));
        }
        policy
    }

    /// Disable warnings and cancellation.
    pub fn off() -> Self {
        Self {
            warn_after: Duration::MAX,
            abort_after: None,
        }
    }
}

/// Shared progress record between the engine, its node tasks and the
/// watchdog.
#[derive(Debug)]
pub(crate) struct Progress {
    started: Instant,
    /// Millis since `started` of the last activity of any kind.
    last_activity_ms: AtomicU64,
    in_flight: Mutex<HashMap<NodeId, (Phase, Instant)>>,
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
        }
    }

    /// Reset the idle clock after any deploy or readiness activity.
    pub(crate) fn touch(&self) {
        let ms = self.started.elapsed().as_millis() as u64;
        self.last_activity_ms.fetch_max(ms, Ordering::Relaxed);
    }

    /// A node entered a phase.
    pub(crate) fn set_phase(&self, node: &NodeId, phase: Phase) {
        if let Ok(mut m) = self.in_flight.lock() {
            m.insert(node.clone(), (phase, Instant::now()));
        }
        self.touch();
    }

    /// A node reached a terminal verdict.
    pub(crate) fn clear(&self, node: &NodeId) {
        if let Ok(mut m) = self.in_flight.lock() {
            m.remove(node);
        }
        self.touch();
    }

    /// How long since the last activity.
    pub(crate) fn idle(&self) -> Duration {
        let last = Duration::from_millis(self.last_activity_ms.load(Ordering::Relaxed));
        self.started.elapsed().saturating_sub(last)
    }

    /// Snapshot of the nodes in flight, longest-waiting first.
    pub(crate) fn in_flight(&self) -> Vec<InFlight> {
        let now = Instant::now();
        let mut out: Vec<InFlight> = self
            .in_flight
            .lock()
            .map(|m| {
                m.iter()
                    .map(|(node, (phase, since))| InFlight {
                        node: node.clone(),
                        phase: *phase,
                        since: now.saturating_duration_since(*since),
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

fn node_label(id: &NodeId) -> String {
    match id {
        NodeId::Resource(rid) => rid.display_id(),
        NodeId::Synthetic(s) => s.clone(),
    }
}

/// Check progress every `min(warn_after, abort_after, 5s)`, with a 100ms
/// minimum interval. Emit `Stalled` events and cancel after the abort threshold.
/// Return when cancellation fires; the engine aborts this task when the run ends.
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
        // and run in one process; the value is restored below.
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
