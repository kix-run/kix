//! A scripted [`ResourceIo`], [`DeployRecord`] and [`SecretHydrator`] for
//! engine tests. No cluster.
//!
//! The rule that makes this useful: **nothing completes unless the script
//! says so.** A fake that answers on the first poll cannot show a parked
//! future, which is exactly how the 2026-09-07 deadlock got past the tests.
//! Here every call is one of [`Behaviour`]: complete now, complete after a
//! virtual delay, complete when the test opens a [`Gate`], or hang forever.
//! Run the engine under `#[tokio::test(start_paused = true)]` and wrap it in
//! `tokio::time::timeout`: a parked run fails at once instead of hanging,
//! and a "ten minute" watchdog test takes milliseconds.
//!
//! The fake also records a call log with virtual timestamps and the peak
//! number of concurrent applies, so tests can assert ordering and bounds.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::manifest::types::ResourceId;

use super::super::activation::RecordsError;
use super::super::apply::{ApplyAction, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::fetch::FetchError;
use super::super::prune_guard::{PruneError, Pruned};
use super::super::readiness::{ImportTarget, ReadinessError, ReadinessResult};
use super::super::secrets::{HydrationResult, SecretError};
use super::{
    DeleteError, DeployRecord, Finalized, OnStatus, ReadError, RecordWriteError, RecreateError,
    ResourceIo, SecretHydrator, StampError,
};

/// A latch many calls can wait on. Opened once by the test.
#[derive(Clone, Default, Debug)]
pub struct Gate(CancellationToken);

impl Gate {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn open(&self) {
        self.0.cancel();
    }
    pub fn is_open(&self) -> bool {
        self.0.is_cancelled()
    }
    async fn wait(&self) {
        self.0.cancelled().await
    }
}

/// How a scripted call completes.
#[derive(Clone, Debug)]
pub enum Behaviour<T: Clone> {
    /// On the first poll.
    Now(T),
    /// After this much virtual time.
    After(Duration, T),
    /// When the gate opens.
    Gate(Gate, T),
    /// Never.
    Hang,
    /// Panic with this message. Models a bug in a node task.
    Panic(String),
}

impl<T: Clone> Behaviour<T> {
    async fn run(&self) -> T {
        match self {
            Behaviour::Now(v) => v.clone(),
            Behaviour::After(d, v) => {
                tokio::time::sleep(*d).await;
                v.clone()
            }
            Behaviour::Gate(g, v) => {
                g.wait().await;
                v.clone()
            }
            Behaviour::Hang => std::future::pending().await,
            Behaviour::Panic(msg) => panic!("{msg}"),
        }
    }
}

/// What readiness reports for a node.
#[derive(Clone, Debug)]
pub enum Ready {
    Ready,
    Failed(String),
    TimedOut,
    Cancelled,
    /// Call `on_status` every `every` for `count` times, then `then`.
    /// Models a slow but healthy rollout.
    Heartbeat {
        every: Duration,
        count: usize,
        then: Box<Ready>,
    },
}

/// Per-node script. Defaults: hydrate succeeds, apply creates, ready now.
#[derive(Clone, Debug)]
pub struct NodeScript {
    pub hydrate: Behaviour<Result<(), String>>,
    pub apply: Behaviour<Result<ApplyAction, ApplyFailure>>,
    pub recreate: Behaviour<Result<ApplyAction, String>>,
    pub ready: Behaviour<Ready>,
    /// What [`ResourceIo::get_live`] answers. Default: nothing is live.
    pub live: Behaviour<Result<Option<Value>, String>>,
}

/// Apply failures the engine distinguishes.
#[derive(Clone, Debug)]
pub enum ApplyFailure {
    /// Any other error, rendered with this message.
    Other(String),
    /// Immutable-field conflict; the engine recreates if pre-authorized.
    ImmutableConflict,
}

impl Default for NodeScript {
    fn default() -> Self {
        Self {
            hydrate: Behaviour::Now(Ok(())),
            apply: Behaviour::Now(Ok(ApplyAction::Created)),
            recreate: Behaviour::Now(Ok(ApplyAction::Configured)),
            ready: Behaviour::Now(Ready::Ready),
            live: Behaviour::Now(Ok(None)),
        }
    }
}

impl NodeScript {
    pub fn apply(mut self, b: Behaviour<Result<ApplyAction, ApplyFailure>>) -> Self {
        self.apply = b;
        self
    }
    pub fn ready(mut self, b: Behaviour<Ready>) -> Self {
        self.ready = b;
        self
    }
    pub fn hydrate(mut self, b: Behaviour<Result<(), String>>) -> Self {
        self.hydrate = b;
        self
    }
    pub fn recreate(mut self, b: Behaviour<Result<ApplyAction, String>>) -> Self {
        self.recreate = b;
        self
    }
    pub fn live(mut self, b: Behaviour<Result<Option<Value>, String>>) -> Self {
        self.live = b;
        self
    }
}

/// One recorded call, with the virtual time it happened.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Call {
    Begin,
    HydrateStart(ResourceId),
    ApplyStart(ResourceId),
    ApplyEnd(ResourceId),
    GetLive(ResourceId),
    RecreateStart(ResourceId),
    ReadyStart(ResourceId),
    ReadyEnd(ResourceId),
    RediscoverStart,
    RediscoverEnd,
    Checkpoint {
        applied: usize,
        failed: usize,
        finalizing: bool,
    },
    Stamp(ResourceId),
    Delete(ResourceId),
    Finalize {
        had_failures: bool,
        orphans_left: bool,
    },
    Abort {
        reason: String,
    },
}

#[derive(Clone, Debug)]
pub struct Logged {
    pub at: Duration,
    pub call: Call,
}

pub struct ScriptedOps {
    started: Instant,
    nodes: Mutex<HashMap<ResourceId, NodeScript>>,
    default_node: Mutex<NodeScript>,
    rediscover: Mutex<VecDeque<Behaviour<Result<(), String>>>>,
    default_rediscover: Mutex<Behaviour<Result<(), String>>>,
    checkpoint: Mutex<Behaviour<Result<(), String>>>,
    stamp: Mutex<Behaviour<Result<(), String>>>,
    delete: Mutex<Behaviour<Result<Pruned, String>>>,
    finalize: Mutex<Behaviour<Result<Option<Finalized>, String>>>,
    abort: Mutex<Behaviour<Result<(), String>>>,
    log: Mutex<Vec<Logged>>,
    applies_now: AtomicUsize,
    applies_peak: AtomicUsize,
    dry_run: std::sync::atomic::AtomicBool,
}

impl Default for ScriptedOps {
    fn default() -> Self {
        Self::new()
    }
}

impl ScriptedOps {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            nodes: Mutex::new(HashMap::new()),
            default_node: Mutex::new(NodeScript::default()),
            rediscover: Mutex::new(VecDeque::new()),
            default_rediscover: Mutex::new(Behaviour::Now(Ok(()))),
            checkpoint: Mutex::new(Behaviour::Now(Ok(()))),
            stamp: Mutex::new(Behaviour::Now(Ok(()))),
            delete: Mutex::new(Behaviour::Now(Ok(Pruned::Deleted))),
            finalize: Mutex::new(Behaviour::Now(Ok(None))),
            abort: Mutex::new(Behaviour::Now(Ok(()))),
            log: Mutex::new(Vec::new()),
            applies_now: AtomicUsize::new(0),
            applies_peak: AtomicUsize::new(0),
            dry_run: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Whether the engine runs against the fake as a dry run, which has no
    /// record (see [`super::Cluster::scripted`]).
    pub fn set_dry_run(&self, dry_run: bool) -> &Self {
        self.dry_run.store(dry_run, Ordering::SeqCst);
        self
    }

    pub(crate) fn is_dry_run(&self) -> bool {
        self.dry_run.load(Ordering::SeqCst)
    }

    /// Script one node. Unscripted nodes use [`Self::default_node`].
    pub fn script(&self, rid: ResourceId, script: NodeScript) -> &Self {
        self.nodes.lock().unwrap().insert(rid, script);
        self
    }

    /// Script for every node not scripted individually.
    pub fn default_node(&self, script: NodeScript) -> &Self {
        *self.default_node.lock().unwrap() = script;
        self
    }

    /// Queue a behaviour for the next rediscovery call. When the queue is
    /// empty, [`Self::default_rediscover`] applies.
    pub fn rediscover_next(&self, b: Behaviour<Result<(), String>>) -> &Self {
        self.rediscover.lock().unwrap().push_back(b);
        self
    }

    pub fn default_rediscover(&self, b: Behaviour<Result<(), String>>) -> &Self {
        *self.default_rediscover.lock().unwrap() = b;
        self
    }

    pub fn checkpoint_behaviour(&self, b: Behaviour<Result<(), String>>) -> &Self {
        *self.checkpoint.lock().unwrap() = b;
        self
    }

    pub fn stamp_behaviour(&self, b: Behaviour<Result<(), String>>) -> &Self {
        *self.stamp.lock().unwrap() = b;
        self
    }

    pub fn delete_behaviour(&self, b: Behaviour<Result<Pruned, String>>) -> &Self {
        *self.delete.lock().unwrap() = b;
        self
    }

    pub fn finalize_behaviour(&self, b: Behaviour<Result<Option<Finalized>, String>>) -> &Self {
        *self.finalize.lock().unwrap() = b;
        self
    }

    pub fn abort_behaviour(&self, b: Behaviour<Result<(), String>>) -> &Self {
        *self.abort.lock().unwrap() = b;
        self
    }

    /// Every call so far, in order, with virtual timestamps.
    pub fn log(&self) -> Vec<Logged> {
        self.log.lock().unwrap().clone()
    }

    /// Just the calls, without timestamps.
    pub fn calls(&self) -> Vec<Call> {
        self.log
            .lock()
            .unwrap()
            .iter()
            .map(|l| l.call.clone())
            .collect()
    }

    /// Virtual time of the first matching call.
    pub fn time_of(&self, pred: impl Fn(&Call) -> bool) -> Option<Duration> {
        self.log
            .lock()
            .unwrap()
            .iter()
            .find(|l| pred(&l.call))
            .map(|l| l.at)
    }

    /// Highest number of applies in flight at once.
    pub fn peak_concurrent_applies(&self) -> usize {
        self.applies_peak.load(Ordering::Relaxed)
    }

    fn record(&self, call: Call) {
        let at = self.started.elapsed();
        self.log.lock().unwrap().push(Logged { at, call });
    }

    fn node_script(&self, rid: &ResourceId) -> NodeScript {
        self.nodes
            .lock()
            .unwrap()
            .get(rid)
            .cloned()
            .unwrap_or_else(|| self.default_node.lock().unwrap().clone())
    }

    fn next_rediscover(&self) -> Behaviour<Result<(), String>> {
        self.rediscover
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| self.default_rediscover.lock().unwrap().clone())
    }
}

/// A kube error carrying a scripted message, for the typed errors whose
/// message a test scripts.
fn scripted_error(message: String) -> kube::Error {
    kube::Error::Discovery(kube::error::DiscoveryError::MissingKind(message))
}

/// A failed write to the Activation record, with a scripted message.
fn record_error(message: String) -> RecordWriteError {
    RecordWriteError::Records(RecordsError {
        op: "patch",
        name: None,
        source: scripted_error(message),
    })
}

/// Counts applies in flight for the duration of a borrow.
struct InFlightApply<'a>(&'a ScriptedOps);

impl<'a> InFlightApply<'a> {
    fn enter(ops: &'a ScriptedOps) -> Self {
        let now = ops.applies_now.fetch_add(1, Ordering::SeqCst) + 1;
        ops.applies_peak.fetch_max(now, Ordering::SeqCst);
        Self(ops)
    }
}

impl Drop for InFlightApply<'_> {
    fn drop(&mut self) {
        self.0.applies_now.fetch_sub(1, Ordering::SeqCst);
    }
}

#[async_trait]
impl SecretHydrator for ScriptedOps {
    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError> {
        let rid = ResourceId::from_value(&manifest);
        self.record(Call::HydrateStart(rid.clone()));
        let script = self.node_script(&rid);
        match script.hydrate.run().await {
            Ok(()) => Ok((
                manifest,
                vec![HydrationResult {
                    rid,
                    keys_injected: 1,
                }],
            )),
            Err(message) => Err(SecretError::DecryptionFailed {
                path: "scripted".into(),
                message,
            }),
        }
    }
}

#[async_trait]
impl ResourceIo for ScriptedOps {
    async fn apply(&self, manifest: &Value) -> Result<ApplyResult, ApplyError> {
        let rid = ResourceId::from_value(manifest);
        let _in_flight = InFlightApply::enter(self);
        self.record(Call::ApplyStart(rid.clone()));
        let script = self.node_script(&rid);
        let out = script.apply.run().await;
        self.record(Call::ApplyEnd(rid.clone()));
        match out {
            Ok(action) => Ok(ApplyResult {
                action,
                resource_id: rid,
                preview: None,
            }),
            Err(ApplyFailure::Other(msg)) => Err(ApplyError::UnknownKind { kind: msg }),
            Err(ApplyFailure::ImmutableConflict) => Err(ApplyError::ImmutableConflict {
                resource: rid.display_id(),
                source: kube::Error::Discovery(kube::error::DiscoveryError::MissingKind(
                    "scripted immutable conflict".into(),
                )),
            }),
        }
    }

    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError> {
        self.record(Call::GetLive(rid.clone()));
        let script = self.node_script(rid);
        script
            .live
            .run()
            .await
            .map_err(|m| ReadError::Get(scripted_error(m)))
    }

    async fn recreate_in_place(&self, manifest: &Value) -> Result<ApplyResult, RecreateError> {
        let rid = ResourceId::from_value(manifest);
        self.record(Call::RecreateStart(rid.clone()));
        let script = self.node_script(&rid);
        script
            .recreate
            .run()
            .await
            .map(|action| ApplyResult {
                action,
                resource_id: rid,
                preview: None,
            })
            .map_err(|m| RecreateError::Delete(scripted_error(m)))
    }

    async fn wait_ready(
        &self,
        rid: &ResourceId,
        _import_target: Option<&ImportTarget>,
        _timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ReadinessResult, ReadinessError> {
        self.record(Call::ReadyStart(rid.clone()));
        let script = self.node_script(rid);
        let mut outcome = script.ready.run().await;
        loop {
            match outcome {
                Ready::Heartbeat { every, count, then } => {
                    for i in 0..count {
                        if cancel.is_cancelled() {
                            self.record(Call::ReadyEnd(rid.clone()));
                            return Ok(ReadinessResult::Cancelled);
                        }
                        tokio::time::sleep(every).await;
                        on_status(&format!("scripted progress {}/{count}", i + 1));
                    }
                    outcome = *then;
                }
                other => {
                    self.record(Call::ReadyEnd(rid.clone()));
                    return Ok(match other {
                        Ready::Ready => ReadinessResult::Ready,
                        Ready::Failed(m) => ReadinessResult::Failed {
                            message: m,
                            output: Vec::new(),
                        },
                        Ready::Cancelled => ReadinessResult::Cancelled,
                        Ready::TimedOut => ReadinessResult::TimedOut {
                            elapsed: Duration::ZERO,
                            message: "scripted timeout".into(),
                        },
                        Ready::Heartbeat { .. } => unreachable!(),
                    });
                }
            }
        }
    }

    async fn rediscover(&self) -> Result<(), FetchError> {
        self.record(Call::RediscoverStart);
        let b = self.next_rediscover();
        let out = b.run().await;
        self.record(Call::RediscoverEnd);
        out.map_err(|msg| {
            FetchError::DiscoveryError(kube::Error::Discovery(
                kube::error::DiscoveryError::MissingApiGroup(msg),
            ))
        })
    }

    async fn delete(&self, rid: &ResourceId) -> Result<Pruned, DeleteError> {
        self.record(Call::Delete(rid.clone()));
        let b = self.delete.lock().unwrap().clone();
        b.run()
            .await
            .map_err(|m| DeleteError::Guard(PruneError::Kube(scripted_error(m))))
    }
}

#[async_trait]
impl DeployRecord for ScriptedOps {
    async fn begin(&self) {
        self.record(Call::Begin);
    }

    async fn discovery_refreshed(&self) {}

    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), RecordWriteError> {
        self.record(Call::Checkpoint {
            applied,
            failed,
            finalizing,
        });
        let b = self.checkpoint.lock().unwrap().clone();
        b.run().await.map_err(record_error)
    }

    async fn stamp_unchanged(&self, rid: &ResourceId) -> Result<(), StampError> {
        self.record(Call::Stamp(rid.clone()));
        let b = self.stamp.lock().unwrap().clone();
        b.run()
            .await
            .map_err(|kind| StampError::Apply(ApplyError::UnknownKind { kind }))
    }

    async fn finalize(
        &self,
        had_failures: bool,
        orphans_left: bool,
    ) -> Result<Option<Finalized>, RecordWriteError> {
        self.record(Call::Finalize {
            had_failures,
            orphans_left,
        });
        let b = self.finalize.lock().unwrap().clone();
        b.run().await.map_err(record_error)
    }

    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError> {
        self.record(Call::Abort {
            reason: reason.to_string(),
        });
        let b = self.abort.lock().unwrap().clone();
        b.run().await.map_err(record_error)
    }
}
