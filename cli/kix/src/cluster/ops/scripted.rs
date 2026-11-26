//! Scripted [`ResourceIo`], [`DeployRecord`], and [`SecretHydrator`] for
//! engine tests without a live cluster.
//!
//! No operation completes unless the script says so. Every call is configured
//! with a [`Behaviour`] to complete immediately, complete after a virtual
//! delay, complete when the test opens a [`Gate`], or hang forever. Running the
//! engine under `#[tokio::test(start_paused = true)]` inside
//! `tokio::time::timeout` surfaces parked futures immediately and lets
//! multi-minute watchdog tests complete in milliseconds.
//!
//! The fake also records a call log with virtual timestamps and the peak
//! number of concurrent applies so tests can assert ordering and concurrency
//! bounds.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use chrono::{DateTime, Utc};

use async_trait::async_trait;
use serde_json::Value;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use crate::manifest::types::ResourceId;

use super::super::apply::{ApplyAction, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::errors::FetchError;
use super::super::kept::NotKeptField;
use super::super::prune_guard::Pruned;
use super::super::readiness::{Deletion, ImportTarget, ReadinessError, ReadinessResult, Stuck};
use super::super::secrets::{HydrationResult, SecretError};
pub use super::Finalized;
use super::{
    DeleteError, DeployRecord, OnStatus, ReadError, RecordWriteError, RecreateError, ResourceIo,
    SecretHydrator, StampError,
};

/// The status [`ResourceIo::wait_gone`] reports for one object, if any, and
/// how its wait ends.
type GoneScript = (Option<String>, Behaviour<Result<Deletion, String>>);

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
    /// Complete on the first poll.
    Now(T),
    /// Complete after this much virtual time.
    After(Duration, T),
    /// Complete when the gate opens.
    Gate(Gate, T),
    /// Never complete.
    Hang,
    /// Panic with this message to model a bug in a node task.
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

/// Per-node script. Defaults to hydrating cleanly, creating on apply, and
/// reporting ready immediately.
#[derive(Clone, Debug)]
pub struct NodeScript {
    pub hydrate: Behaviour<Result<(), String>>,
    pub apply: Behaviour<Result<ApplyAction, ApplyFailure>>,
    pub recreate: Behaviour<Result<ApplyAction, ApplyFailure>>,
    pub ready: Behaviour<Ready>,
    /// What [`ResourceIo::get_live`] answers. Defaults to `Ok(None)`.
    pub live: Behaviour<Result<Option<Value>, String>>,
    /// The fields a successful apply reports the server did not keep.
    pub not_kept: Vec<NotKeptField>,
}

/// Apply failures the engine distinguishes.
#[derive(Clone, Debug)]
pub enum ApplyFailure {
    /// Any other error, rendered with this message.
    Other(String),
    /// Immutable-field conflict, which triggers an in-place recreate when
    /// pre-authorized.
    ImmutableConflict,
    /// The object is being deleted, and was still there when the wait ended:
    /// `ApplyError::StillBeingDeleted` from an apply,
    /// `RecreateError::StillExists` from a recreate.
    StillBeingDeleted(Stuck),
}

impl Default for NodeScript {
    fn default() -> Self {
        Self {
            hydrate: Behaviour::Now(Ok(())),
            apply: Behaviour::Now(Ok(ApplyAction::Created)),
            recreate: Behaviour::Now(Ok(ApplyAction::Configured)),
            ready: Behaviour::Now(Ready::Ready),
            live: Behaviour::Now(Ok(None)),
            not_kept: Vec::new(),
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
    pub fn recreate(mut self, b: Behaviour<Result<ApplyAction, ApplyFailure>>) -> Self {
        self.recreate = b;
        self
    }
    pub fn live(mut self, b: Behaviour<Result<Option<Value>, String>>) -> Self {
        self.live = b;
        self
    }
    pub fn not_kept(mut self, fields: Vec<NotKeptField>) -> Self {
        self.not_kept = fields;
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
    WaitGone(ResourceId),
    Finalize {
        had_failures: bool,
        orphans_left: bool,
    },
    Abort {
        reason: String,
    },
    EndPartial,
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
    begin: Mutex<Behaviour<Result<(), String>>>,
    checkpoint: Mutex<Behaviour<Result<(), String>>>,
    stamp: Mutex<Behaviour<Result<(), String>>>,
    delete: Mutex<Behaviour<Result<Pruned, String>>>,
    /// What [`ResourceIo::wait_gone`] answers for each object, after
    /// reporting the status. Unscripted objects are gone at once.
    gone: Mutex<HashMap<ResourceId, GoneScript>>,
    finalize: Mutex<Behaviour<Result<Option<Finalized>, String>>>,
    abort: Mutex<Behaviour<Result<(), String>>>,
    end_partial: Mutex<Behaviour<Result<(), String>>>,
    log: Mutex<Vec<Logged>>,
    /// The propagation policy of each [`ResourceIo::prune`] call, in order.
    propagations: Mutex<Vec<(ResourceId, kube::api::PropagationPolicy)>>,
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
            begin: Mutex::new(Behaviour::Now(Ok(()))),
            checkpoint: Mutex::new(Behaviour::Now(Ok(()))),
            stamp: Mutex::new(Behaviour::Now(Ok(()))),
            delete: Mutex::new(Behaviour::Now(Ok(Pruned::Deleted {
                uid: None,
                finalizers: Vec::new(),
            }))),
            gone: Mutex::new(HashMap::new()),
            finalize: Mutex::new(Behaviour::Now(Ok(None))),
            abort: Mutex::new(Behaviour::Now(Ok(()))),
            end_partial: Mutex::new(Behaviour::Now(Ok(()))),
            log: Mutex::new(Vec::new()),
            propagations: Mutex::new(Vec::new()),
            applies_now: AtomicUsize::new(0),
            applies_peak: AtomicUsize::new(0),
            dry_run: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Configure whether the engine runs against this fake in dry-run mode
    /// (without a deploy record; see [`super::Cluster::scripted`]).
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

    /// Set the default script for nodes without an individual script.
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

    pub fn begin_behaviour(&self, b: Behaviour<Result<(), String>>) -> &Self {
        *self.begin.lock().unwrap() = b;
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

    /// Script how the wait for the deleted object `rid` ends. `status`, when
    /// set, is reported once before it ends.
    pub fn gone_behaviour(
        &self,
        rid: ResourceId,
        status: Option<&str>,
        b: Behaviour<Result<Deletion, String>>,
    ) -> &Self {
        self.gone
            .lock()
            .unwrap()
            .insert(rid, (status.map(str::to_string), b));
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

    pub fn end_partial_behaviour(&self, b: Behaviour<Result<(), String>>) -> &Self {
        *self.end_partial.lock().unwrap() = b;
        self
    }

    /// Return all recorded calls in order with virtual timestamps.
    pub fn log(&self) -> Vec<Logged> {
        self.log.lock().unwrap().clone()
    }

    /// Return all recorded calls without timestamps.
    /// Return the propagation policy each prune used, in call order.
    pub fn propagations(&self) -> Vec<(ResourceId, kube::api::PropagationPolicy)> {
        self.propagations.lock().unwrap().clone()
    }

    pub fn calls(&self) -> Vec<Call> {
        self.log
            .lock()
            .unwrap()
            .iter()
            .map(|l| l.call.clone())
            .collect()
    }

    /// Return the virtual timestamp of the first call matching `pred`.
    pub fn time_of(&self, pred: impl Fn(&Call) -> bool) -> Option<Duration> {
        self.log
            .lock()
            .unwrap()
            .iter()
            .find(|l| pred(&l.call))
            .map(|l| l.at)
    }

    /// Return the maximum number of concurrent applies observed.
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
    async fn apply(
        &self,
        manifest: &Value,
        _timeout: Duration,
        _cancel: &CancelToken,
        _on_status: OnStatus<'_>,
    ) -> Result<ApplyResult, ApplyError> {
        let rid = ResourceId::from_value(manifest);
        let _in_flight = InFlightApply::enter(self);
        self.record(Call::ApplyStart(rid.clone()));
        let script = self.node_script(&rid);
        let out = script.apply.run().await;
        self.record(Call::ApplyEnd(rid.clone()));
        match out {
            Ok(action) => Ok(ApplyResult {
                action,
                preview: None,
                not_kept: script.not_kept.clone(),
            }),
            Err(ApplyFailure::Other(msg)) => Err(ApplyError::UnknownKind { kind: msg }),
            Err(ApplyFailure::ImmutableConflict) => Err(ApplyError::ImmutableConflict {
                resource: rid.display_id(),
                source: kube::Error::Discovery(kube::error::DiscoveryError::MissingKind(
                    "scripted immutable conflict".into(),
                )),
            }),
            Err(ApplyFailure::StillBeingDeleted(stuck)) => {
                Err(ApplyError::StillBeingDeleted { rid, stuck })
            }
        }
    }

    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError> {
        self.record(Call::GetLive(rid.clone()));
        let script = self.node_script(rid);
        script.live.run().await.map_err(ReadError::Scripted)
    }

    async fn recreate_in_place(
        &self,
        manifest: &Value,
        _timeout: Duration,
        _cancel: &CancelToken,
    ) -> Result<ApplyResult, RecreateError> {
        let rid = ResourceId::from_value(manifest);
        self.record(Call::RecreateStart(rid.clone()));
        let script = self.node_script(&rid);
        script
            .recreate
            .run()
            .await
            .map(|action| ApplyResult {
                action,
                preview: None,
                not_kept: Vec::new(),
            })
            .map_err(|failure| match failure {
                ApplyFailure::StillBeingDeleted(stuck) => RecreateError::StillExists { rid, stuck },
                ApplyFailure::Other(message) => RecreateError::Scripted(message),
                ApplyFailure::ImmutableConflict => {
                    RecreateError::Scripted("scripted immutable conflict".into())
                }
            })
    }

    async fn wait_ready(
        &self,
        rid: &ResourceId,
        _import_target: Option<&ImportTarget>,
        _applied_at: Option<DateTime<Utc>>,
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

    async fn prune(
        &self,
        rid: &ResourceId,
        propagation: kube::api::PropagationPolicy,
    ) -> Result<Pruned, DeleteError> {
        self.record(Call::Delete(rid.clone()));
        self.propagations
            .lock()
            .unwrap()
            .push((rid.clone(), propagation));
        let b = self.delete.lock().unwrap().clone();
        b.run().await.map_err(DeleteError::Scripted)
    }

    async fn wait_gone(
        &self,
        rid: &ResourceId,
        _uid: Option<&str>,
        _timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<Deletion, ReadError> {
        self.record(Call::WaitGone(rid.clone()));
        let scripted = self.gone.lock().unwrap().get(rid).cloned();
        let Some((status, b)) = scripted else {
            return Ok(Deletion::Gone);
        };
        // The real wait reads the object every few seconds and reports its
        // status after each read, and so does this. It ends when the cancel
        // token fires.
        if let Some(status) = &status {
            on_status(status);
        }
        let run = b.run();
        tokio::pin!(run);
        let every = Duration::from_secs(5);
        let mut reads = tokio::time::interval_at(tokio::time::Instant::now() + every, every);
        loop {
            tokio::select! {
                out = &mut run => return out.map_err(ReadError::Scripted),
                _ = cancel.cancelled() => return Ok(Deletion::Cancelled),
                _ = reads.tick() => {
                    if let Some(status) = &status {
                        on_status(status);
                    }
                }
            }
        }
    }
}

#[async_trait]
impl DeployRecord for ScriptedOps {
    async fn begin(&self) -> Result<(), RecordWriteError> {
        self.record(Call::Begin);
        let b = self.begin.lock().unwrap().clone();
        b.run().await.map_err(RecordWriteError::Scripted)
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
        b.run().await.map_err(RecordWriteError::Scripted)
    }

    async fn stamp_unchanged(&self, rid: &ResourceId) -> Result<(), StampError> {
        self.record(Call::Stamp(rid.clone()));
        let b = self.stamp.lock().unwrap().clone();
        b.run().await.map_err(StampError::Scripted)
    }

    async fn finalize(
        &self,
        had_failures: bool,
        left: super::Left<'_>,
    ) -> Result<Option<Finalized>, RecordWriteError> {
        self.record(Call::Finalize {
            had_failures,
            orphans_left: left.any(),
        });
        let b = self.finalize.lock().unwrap().clone();
        b.run().await.map_err(RecordWriteError::Scripted)
    }

    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError> {
        self.record(Call::Abort {
            reason: reason.to_string(),
        });
        let b = self.abort.lock().unwrap().clone();
        b.run().await.map_err(RecordWriteError::Scripted)
    }

    async fn before_prune(&self) -> Result<(), RecordWriteError> {
        Ok(())
    }

    async fn end_partial(&self) -> Result<(), RecordWriteError> {
        self.record(Call::EndPartial);
        let b = self.end_partial.lock().unwrap().clone();
        b.run().await.map_err(RecordWriteError::Scripted)
    }
}
