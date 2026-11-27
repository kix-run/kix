//! Taking, renewing, committing, and releasing the deploy lock.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use kube::Client;
use kube::api::{DynamicObject, PostParams};
use serde_json::{Value, json};
use thiserror::Error;

use super::guard::WritesStopped;
use super::{
    Clock, Head, HeadStatus, Holder, LEASE, LockState, Purpose, RENEW_EVERY, STOP_AFTER, Writer,
    api,
};
use crate::cluster::activation::{self, Record, Records, RecordsError};
use crate::cluster::cancel::CancelToken;
use crate::cluster::errors::describe;
use crate::manifest::keys;
use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_SUPERSEDED};

/// How often a run that waits for the lock reads the head.
const POLL: Duration = Duration::from_secs(1);

/// How often the holder's background task wakes to check its lease.
const TICK: Duration = Duration::from_secs(1);

/// How long a run waits for a repair that keeps renewing to give way.
const REPAIR_WAIT: Duration = Duration::from_secs(60);

/// What a run asks of [`take`].
#[derive(Debug, Clone)]
pub struct Request {
    /// The Kix cluster, which names its head.
    pub cluster: String,
    pub holder: Holder,
    pub purpose: Purpose,
    /// The record the run deploys, if any.
    pub activation: Option<String>,
    /// The generation the run's plan read, or `None` when nothing binds the
    /// run (a plan made without connecting, gc, migrate, the operator).
    pub expect: Option<u64>,
}

/// A live run holds the lock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Held {
    pub cluster: String,
    pub lock: LockState,
    /// The holder is the operator's repair, which did not give way in time.
    pub repair: bool,
}

impl std::fmt::Display for Held {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let lock = &self.lock;
        let who = if lock.hint.is_empty() {
            lock.holder.as_str()
        } else {
            lock.hint.as_str()
        };
        let what = match &lock.activation {
            Some(record) => format!("{} of record {record}", lock.purpose.as_str()),
            None => lock.purpose.as_str().to_string(),
        };
        let why = if self.repair {
            format!(
                "The Kix operator is repairing drift on this cluster and did not release the lock within {} seconds after this run asked for it.",
                REPAIR_WAIT.as_secs()
            )
        } else {
            "Only one run can change a Kix cluster at a time. That run renewed its lock while Kix was watching, so it is still active.".to_string()
        };
        write!(
            f,
            "Kix cluster {cluster} is locked by another run: {who} ({what}).\n  \
             Nothing was changed on the cluster.\n\n  \
             Why:\n    \
             {why}\n\n  \
             Next:\n    \
             Wait for that run to finish, then run this command again. If that run stops unexpectedly, its lock expires {lease} seconds after its last renewal and the next run will take it over.",
            cluster = self.cluster,
            lease = LEASE.as_secs(),
        )
    }
}

/// Why [`take`] did not give the run the lock.
#[derive(Debug, Error)]
pub enum TakeError {
    #[error("{0}")]
    Held(Box<Held>),
    #[error(
        "Kix cluster {cluster} changed after this plan was made (deploy lock generation {planned}, now {now}).\n  \
         Nothing was changed on the cluster.\n\n  \
         Why:\n    \
         Another run changed the cluster, or Kix repaired its deployment records, before this run took the deploy lock. The plan may be out of date.\n\n  \
         Next:\n    \
         Run the command again to build a fresh plan."
    )]
    GenerationMoved {
        cluster: String,
        planned: u64,
        now: u64,
    },
    #[error(transparent)]
    Crd(#[from] crate::cluster::own_crds::CrdError),
    #[error(
        "cannot read or update deploy lock `ActivationHead` `{cluster}`: {}. Nothing was changed on the cluster. Check the cluster connection and ensure this account has `get`, `list`, `create`, and `update` permissions on `{}`, then try again",
        describe(.source),
        super::crd_name()
    )]
    Api {
        cluster: String,
        #[source]
        source: kube::Error,
    },
    #[error(transparent)]
    Records(#[from] RecordsError),
    #[error(transparent)]
    Release(#[from] CommitError),
}

/// What [`decide`] makes of the head and the records when a run takes the
/// lock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Decision {
    /// The status to write, holding the new lock.
    pub status: HeadStatus,
    /// A record a dead run left `Deploying`, to mark `Failed`.
    pub mark_failed: Option<String>,
    /// Phases to correct because a deploy stopped after its commit.
    pub repair: Option<PhaseRepair>,
}

/// Phases that disagree with the head's `current`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PhaseRepair {
    pub current: String,
    /// The phase `current` gets, or `None` when it already has a current
    /// phase.
    pub phase: Option<&'static str>,
    /// Other records with a current phase.
    pub supersede: Vec<String>,
}

/// Decide what a run that takes the lock writes, from `existing` (`None`
/// when the cluster has no head, `Some(None)` when the head has no status),
/// `dead` (the lock of a run that stopped renewing, being taken over), the
/// cluster's `records`, and the new `lock`.
///
/// - A dead run's record that is current needs nothing. One the new run
///   deploys too is continued. Any other one still `Deploying` is marked
///   `Failed`. Taking over a dead run raises the generation, unless the new
///   run continues it or the dead run was a repair.
/// - The head is rebuilt from the phases when it has no status, or when an
///   older Kix deployed after it: the record it names is gone or
///   `Superseded`, or another record is current by phase and has no
///   revision map while the named one still has a current phase
///   ([`crate::cluster::tenancy::older_kix_deployed_after`]). Rebuilding a head that had a status raises the generation and
///   forgets the writer, so the checks of the writer read the current
///   record as before.
/// - Otherwise the phases are repaired from the head when the record it
///   names lacks a current phase, or another record has one. That raises
///   the generation too, because a plan read the old phases.
pub(super) fn decide(
    existing: Option<Option<&HeadStatus>>,
    dead: Option<&LockState>,
    records: &[Record],
    lock: LockState,
) -> Decision {
    let had_status = matches!(existing, Some(Some(_)));
    let mut status = existing.flatten().cloned().unwrap_or_default();
    let mut bump = false;
    let mut mark_failed = None;

    if let Some(dead) = dead {
        let continued = dead.activation.is_some() && dead.activation == lock.activation;
        let current = dead.activation.is_some() && dead.activation == status.current;
        if dead.purpose != Purpose::Repair && !continued {
            bump = true;
        }
        if let Some(name) = &dead.activation
            && !continued
            && !current
            && records
                .iter()
                .any(|r| &r.name == name && (r.phase == PHASE_DEPLOYING || r.phase.is_empty()))
        {
            mark_failed = Some(name.clone());
        }
    }

    let by_phase = activation::current_among(records).map(|r| r.name.clone());
    let named = status
        .current
        .as_ref()
        .and_then(|c| records.iter().find(|r| &r.name == c))
        .filter(|r| {
            r.phase != PHASE_SUPERSEDED
                && !crate::cluster::tenancy::older_kix_deployed_after(r, records)
        });
    let mut repair = None;
    match named {
        Some(record) if had_status => {
            let others: Vec<String> = records
                .iter()
                .filter(|r| r.name != record.name && activation::phase_is_current(&r.phase))
                .map(|r| r.name.clone())
                .collect();
            let phase = (!activation::phase_is_current(&record.phase)).then(|| {
                let failed = record
                    .waves
                    .iter()
                    .any(|w| w.failed > 0 || w.status == activation::WaveStatus::Failed);
                if failed { PHASE_DEGRADED } else { PHASE_ACTIVE }
            });
            if phase.is_some() || !others.is_empty() {
                repair = Some(PhaseRepair {
                    current: record.name.clone(),
                    phase,
                    supersede: others,
                });
                bump = true;
            }
        }
        _ => {
            if had_status && by_phase != status.current {
                bump = true;
                status.writer = None;
            }
            if !had_status {
                status.writer = None;
            }
            status.current = by_phase;
        }
    }

    if bump {
        status.generation += 1;
    }
    status.lock = Some(lock);
    Decision {
        status,
        mark_failed,
        repair,
    }
}

/// The renewals a watching run has seen of another run's lock.
struct Watch {
    holder: String,
    renewed: String,
    /// When this run last saw the lock change, by its monotonic clock.
    since: tokio::time::Instant,
    /// When this run started waiting for a repair to give way.
    waiting_since: Option<tokio::time::Instant>,
}

/// Take the deploy lock of `request.cluster` through `client`, creating the
/// head when absent, after installing or updating Kix's own CRDs.
///
/// When another run holds the lock, watch it for up to [`LEASE`]: refuse
/// with [`TakeError::Held`] once it renews, take it over if it never does. A
/// lock the operator's repair holds is asked to give way. A lock held by
/// `request.holder` itself was left by an earlier run of the same holder,
/// which no longer runs, and is taken over at once.
///
/// Once the lock is taken, correct the records ([`decide`]), then refuse
/// with [`TakeError::GenerationMoved`] when `request.expect` is not the
/// head's generation.
///
/// `on_watch` is called once, with the other run's lock, when this run
/// starts to watch it, so a command can say why it waits.
pub async fn take(
    client: &Client,
    request: Request,
    clock: Arc<dyn Clock>,
    on_watch: &(dyn Fn(&LockState) + Send + Sync),
) -> Result<Lock, TakeError> {
    crate::cluster::own_crds::ensure_all(client).await?;
    let cluster = request.cluster.clone();
    let api_error = |source| TakeError::Api {
        cluster: cluster.clone(),
        source,
    };
    let heads = api(client);
    let records = Records::undiscovered(client);
    let mut watch: Option<Watch> = None;
    loop {
        let found = heads.get_opt(&cluster).await.map_err(api_error)?;
        let head = found.as_ref().map(Head::of);
        let held = head.as_ref().and_then(|h| h.lock().cloned());
        let dead = match held {
            None => None,
            Some(other) if other.holder == request.holder.id => Some(other),
            Some(other) => {
                if watch.is_none() {
                    on_watch(&other);
                }
                match watch_step(&mut watch, &other, &request, clock.as_ref()) {
                    Step::Wait => {}
                    Step::AskToGiveWay => {
                        ask_to_give_way(client, found.as_ref(), &request.holder.id)
                            .await
                            .map_err(api_error)?;
                    }
                    Step::Refuse { repair } => {
                        return Err(TakeError::Held(Box::new(Held {
                            cluster: cluster.clone(),
                            lock: other,
                            repair,
                        })));
                    }
                    Step::TakeOver => {
                        tracing::warn!(cluster = %cluster, holder = %other.holder, hint = %other.hint, "taking over a deploy lock that was not renewed for {}s", LEASE.as_secs());
                        watch = None;
                        let all = records.of_cluster(&cluster).await?;
                        match write_taken(
                            client,
                            found.as_ref(),
                            head.as_ref(),
                            Some(&other),
                            &all,
                            &request,
                            clock.as_ref(),
                        )
                        .await
                        .map_err(api_error)?
                        {
                            Some((obj, decision)) => {
                                return finish_take(client, obj, decision, request, clock).await;
                            }
                            None => continue,
                        }
                    }
                }
                tokio::time::sleep(POLL).await;
                continue;
            }
        };
        let all = records.of_cluster(&cluster).await?;
        match write_taken(
            client,
            found.as_ref(),
            head.as_ref(),
            dead.as_ref(),
            &all,
            &request,
            clock.as_ref(),
        )
        .await
        .map_err(api_error)?
        {
            Some((obj, decision)) => {
                return finish_take(client, obj, decision, request, clock).await;
            }
            // Another run wrote the head between the read and the write.
            None => continue,
        }
    }
}

/// Settle a lock that another run holds before a command reads the state
/// it plans from. When no run holds the lock, do nothing. Otherwise take the
/// lock as [`take`] does, so a live holder is refused with
/// [`TakeError::Held`] and a dead one is taken over with its cleanup
/// ([`decide`]), then release it at once. The plan that follows then reads
/// the state the takeover left, and the take after confirmation finds the
/// lock free and the generation unchanged.
pub async fn settle(
    client: &Client,
    request: Request,
    clock: Arc<dyn Clock>,
    on_watch: &(dyn Fn(&LockState) + Send + Sync),
) -> Result<(), TakeError> {
    let held = super::read(client, &request.cluster)
        .await
        .map_err(|source| TakeError::Api {
            cluster: request.cluster.clone(),
            source,
        })?
        .is_some_and(|h| h.lock().is_some());
    if !held {
        return Ok(());
    }
    let lock = take(
        client,
        Request {
            expect: None,
            ..request
        },
        clock,
        on_watch,
    )
    .await?;
    lock.release().await?;
    Ok(())
}

/// What a watching run does next.
enum Step {
    Wait,
    AskToGiveWay,
    Refuse { repair: bool },
    TakeOver,
}

/// Note what this read shows of `other`'s lock and decide the next step.
fn watch_step(
    watch: &mut Option<Watch>,
    other: &LockState,
    request: &Request,
    clock: &dyn Clock,
) -> Step {
    let now = clock.mono();
    let repair = other.purpose == Purpose::Repair && request.purpose != Purpose::Repair;
    match watch {
        None => {
            *watch = Some(Watch {
                holder: other.holder.clone(),
                renewed: other.renewed.clone(),
                since: now,
                waiting_since: repair.then_some(now),
            });
            if repair && other.waiting.as_deref() != Some(request.holder.id.as_str()) {
                Step::AskToGiveWay
            } else {
                Step::Wait
            }
        }
        Some(w) if w.holder != other.holder => Step::Refuse { repair: false },
        Some(w) if w.renewed != other.renewed => match w.waiting_since {
            Some(started) if now.duration_since(started) < REPAIR_WAIT => {
                w.renewed = other.renewed.clone();
                w.since = now;
                if other.waiting.as_deref() != Some(request.holder.id.as_str()) {
                    Step::AskToGiveWay
                } else {
                    Step::Wait
                }
            }
            Some(_) => Step::Refuse { repair: true },
            None => Step::Refuse { repair: false },
        },
        Some(w) if now.duration_since(w.since) >= LEASE => Step::TakeOver,
        Some(w) => match w.waiting_since {
            Some(started) if now.duration_since(started) >= REPAIR_WAIT => {
                Step::Refuse { repair: true }
            }
            _ => Step::Wait,
        },
    }
}

/// Write this run's id to `status.lock.waiting` of the head `found`, which a
/// repair holds. A conflict means the head changed, which the next read
/// shows.
async fn ask_to_give_way(
    client: &Client,
    found: Option<&DynamicObject>,
    id: &str,
) -> Result<(), kube::Error> {
    let Some(found) = found else {
        return Ok(());
    };
    let mut obj = found.clone();
    if let Some(lock) = obj
        .data
        .get_mut("status")
        .and_then(|s| s.get_mut("lock"))
        .and_then(Value::as_object_mut)
    {
        lock.insert("waiting".into(), json!(id));
    }
    let name = obj.metadata.name.clone().unwrap_or_default();
    match api(client)
        .replace(&name, &PostParams::default(), &obj)
        .await
    {
        Ok(_) => Ok(()),
        Err(kube::Error::Api(e)) if e.code == 409 => Ok(()),
        Err(e) => Err(e),
    }
}

/// Write the head that gives this run the lock, creating it when `found` is
/// `None`. Return `None` when another writer got there first.
async fn write_taken(
    client: &Client,
    found: Option<&DynamicObject>,
    head: Option<&Head>,
    dead: Option<&LockState>,
    records: &[Record],
    request: &Request,
    clock: &dyn Clock,
) -> Result<Option<(DynamicObject, Decision)>, kube::Error> {
    let lock = LockState {
        holder: request.holder.id.clone(),
        hint: request.holder.hint.clone(),
        activation: request.activation.clone(),
        purpose: request.purpose,
        renewed: super::rfc3339(clock.wall()),
        duration_seconds: LEASE.as_secs(),
        waiting: None,
    };
    let decision = decide(head.map(|h| h.status.as_ref()), dead, records, lock);
    let status = serde_json::to_value(&decision.status).expect("the head's status serializes");
    let heads = api(client);
    let written = match found {
        None => {
            let obj: DynamicObject = serde_json::from_value(json!({
                "apiVersion": keys::API_VERSION,
                "kind": super::KIND,
                "metadata": {
                    "name": request.cluster,
                    "labels": { (keys::CLUSTER_LABEL): request.cluster },
                },
                "status": status,
            }))
            .expect("the head is an object");
            heads.create(&PostParams::default(), &obj).await
        }
        Some(found) => {
            let mut obj = found.clone();
            obj.data["status"] = status;
            heads
                .replace(&request.cluster, &PostParams::default(), &obj)
                .await
        }
    };
    match written {
        Ok(obj) => Ok(Some((obj, decision))),
        Err(kube::Error::Api(e)) if e.code == 409 => Ok(None),
        Err(e) => Err(e),
    }
}

/// Hold the lock just written in `obj`: start renewing it, correct the
/// records `decision` names, and check the generation the run's plan read.
async fn finish_take(
    client: &Client,
    obj: DynamicObject,
    decision: Decision,
    request: Request,
    clock: Arc<dyn Clock>,
) -> Result<Lock, TakeError> {
    let lock = Lock::hold(client, &obj, &decision.status, request.clone(), clock);
    let records = Records::undiscovered(&lock.guarded(client));
    let corrected = async {
        if let Some(name) = &decision.mark_failed {
            records
                .fail_deploy(
                    name,
                    &format!(
                        "the previous deploy stopped renewing the deploy lock on cluster {}, and {} took over the lock",
                        request.cluster, request.holder.hint
                    ),
                )
                .await?;
        }
        if let Some(repair) = &decision.repair {
            records
                .repair_phases(&repair.current, repair.phase, &repair.supersede)
                .await?;
        }
        Ok::<_, RecordsError>(())
    }
    .await;
    if let Err(e) = corrected {
        let _ = lock.release().await;
        return Err(e.into());
    }
    // `decide` already raised the generation for these corrections, so they
    // do not count as the run's own writes.
    lock.inner.wrote.store(false, Ordering::SeqCst);
    if let Some(planned) = request.expect
        && planned != decision.status.generation
    {
        let _ = lock.release().await;
        return Err(TakeError::GenerationMoved {
            cluster: request.cluster,
            planned,
            now: decision.status.generation,
        });
    }
    Ok(lock)
}

/// Why the holder lost its lease.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Loss {
    /// Another run wrote the head with another holder.
    TakenOver,
    /// The run is a repair, and another run asked for the lock.
    Yielded,
}

/// What the holder knows of its lease.
pub(super) struct Lease {
    pub resource_version: String,
    pub status: HeadStatus,
    pub renewed_mono: tokio::time::Instant,
    pub renewed_wall: DateTime<Utc>,
    pub lost: Option<Loss>,
}

/// The holder's side of the lock, shared with its renewal task and the
/// guarded clients.
pub(super) struct Inner {
    pub client: Client,
    pub cluster: String,
    pub holder: Holder,
    pub purpose: Purpose,
    pub clock: Arc<dyn Clock>,
    pub lease: Mutex<Lease>,
    /// Set by a guarded client once a write other than to the head
    /// succeeded.
    pub wrote: AtomicBool,
    committed: AtomicBool,
    released: AtomicBool,
    /// Cancelled when the run must stop: the lease was lost, or its deadline
    /// passed.
    stop: Mutex<Vec<CancelToken>>,
}

impl Inner {
    /// Return the time since the last renewal: the longer of the monotonic
    /// and the wall-clock time.
    pub fn since_renewal(&self) -> Duration {
        let lease = self.lease.lock().expect("lease lock");
        let mono = self.clock.mono().duration_since(lease.renewed_mono);
        let wall = (self.clock.wall() - lease.renewed_wall)
            .to_std()
            .unwrap_or_default();
        mono.max(wall)
    }

    /// Return why writes must stop now, or `None` while the lease holds.
    pub fn stopped(&self) -> Option<WritesStopped> {
        if self.released.load(Ordering::SeqCst) {
            return Some(WritesStopped::Released);
        }
        let lost = self.lease.lock().expect("lease lock").lost;
        match lost {
            Some(Loss::TakenOver) => {
                return Some(WritesStopped::TakenOver {
                    cluster: self.cluster.clone(),
                });
            }
            Some(Loss::Yielded) => return Some(WritesStopped::Yielded),
            None => {}
        }
        let since = self.since_renewal();
        (since >= STOP_AFTER).then_some(WritesStopped::Deadline {
            seconds: since.as_secs(),
        })
    }

    fn trip(&self, reason: &str) {
        for token in self.stop.lock().expect("stop lock").iter() {
            token.cancel_with_reason(reason.to_string());
        }
    }

    /// Read the head, and when a waiting run asks a repair to give way, mark
    /// the lease yielded. Used by a repair before each write.
    pub async fn check_waiting(&self) {
        if self.purpose != Purpose::Repair {
            return;
        }
        if let Ok(Some(head)) = super::read(&self.client, &self.cluster).await
            && head
                .lock()
                .is_some_and(|l| l.holder == self.holder.id && l.waiting.is_some())
        {
            self.lose(Loss::Yielded);
        }
    }

    fn lose(&self, loss: Loss) {
        let mut lease = self.lease.lock().expect("lease lock");
        if lease.lost.is_none() {
            lease.lost = Some(loss);
            drop(lease);
            let reason = match loss {
                Loss::TakenOver => "another run took over the deploy lock",
                Loss::Yielded => "drift repair gave the deploy lock to a waiting run",
            };
            tracing::warn!(cluster = %self.cluster, "{reason}");
            self.trip(reason);
        }
    }

    /// Write the head with `change` applied to the status this holder last
    /// wrote, as the holder. A conflict re-reads the head: when the lock is
    /// still this holder's (a waiting run wrote to it), the change is
    /// applied to what was read and written again. Return `false` when the
    /// lock belongs to someone else now.
    async fn write(&self, change: impl Fn(&mut HeadStatus)) -> Result<bool, kube::Error> {
        let heads = api(&self.client);
        for _ in 0..3 {
            let (rv, mut status) = {
                let lease = self.lease.lock().expect("lease lock");
                if lease.lost == Some(Loss::TakenOver) {
                    return Ok(false);
                }
                (lease.resource_version.clone(), lease.status.clone())
            };
            let now = self.clock.wall();
            if let Some(lock) = status.lock.as_mut() {
                lock.renewed = super::rfc3339(now);
            }
            change(&mut status);
            let obj: DynamicObject = serde_json::from_value(json!({
                "apiVersion": keys::API_VERSION,
                "kind": super::KIND,
                "metadata": {
                    "name": self.cluster,
                    "resourceVersion": rv,
                    "labels": { (keys::CLUSTER_LABEL): self.cluster },
                },
                "status": status,
            }))
            .expect("the head is an object");
            let mono = self.clock.mono();
            match heads
                .replace(&self.cluster, &PostParams::default(), &obj)
                .await
            {
                Ok(written) => {
                    let mut lease = self.lease.lock().expect("lease lock");
                    lease.resource_version = written
                        .metadata
                        .resource_version
                        .clone()
                        .unwrap_or_default();
                    lease.renewed_mono = mono;
                    lease.renewed_wall = now;
                    lease.status = status;
                    return Ok(true);
                }
                Err(kube::Error::Api(e)) if e.code == 409 => {
                    let Some(head) = super::read(&self.client, &self.cluster).await? else {
                        self.lose(Loss::TakenOver);
                        return Ok(false);
                    };
                    let Some(read) = head
                        .status
                        .filter(|s| s.lock.as_ref().is_some_and(|l| l.holder == self.holder.id))
                    else {
                        self.lose(Loss::TakenOver);
                        return Ok(false);
                    };
                    let mut lease = self.lease.lock().expect("lease lock");
                    lease.resource_version = head.resource_version;
                    lease.status = read;
                }
                Err(e) => return Err(e),
            }
        }
        Ok(false)
    }

    /// Renew the lease. A repair asked to give way yields instead.
    async fn renew(&self) -> Result<bool, kube::Error> {
        let renewed = self.write(|_| {}).await?;
        let waiting = self
            .lease
            .lock()
            .expect("lease lock")
            .status
            .lock
            .as_ref()
            .is_some_and(|l| l.waiting.is_some());
        if renewed && waiting && self.purpose == Purpose::Repair {
            self.lose(Loss::Yielded);
        }
        Ok(renewed)
    }
}

/// A held deploy lock. The holder ends it with [`Lock::release`]. Dropping it
/// without releasing stops the renewals, and the lock expires after
/// [`LEASE`].
pub struct Lock {
    inner: Arc<Inner>,
    renewer: tokio::task::JoinHandle<()>,
}

impl std::fmt::Debug for Lock {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Lock")
            .field("cluster", &self.inner.cluster)
            .field("holder", &self.inner.holder.id)
            .field("purpose", &self.inner.purpose)
            .finish()
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        self.renewer.abort();
    }
}

impl Lock {
    fn hold(
        client: &Client,
        obj: &DynamicObject,
        status: &HeadStatus,
        request: Request,
        clock: Arc<dyn Clock>,
    ) -> Lock {
        let inner = Arc::new(Inner {
            client: client.clone(),
            cluster: request.cluster,
            holder: request.holder,
            purpose: request.purpose,
            lease: Mutex::new(Lease {
                resource_version: obj.metadata.resource_version.clone().unwrap_or_default(),
                status: status.clone(),
                renewed_mono: clock.mono(),
                renewed_wall: status
                    .lock
                    .as_ref()
                    .and_then(LockState::renewed_at)
                    .unwrap_or_else(|| clock.wall()),
                lost: None,
            }),
            clock,
            wrote: AtomicBool::new(false),
            committed: AtomicBool::new(false),
            released: AtomicBool::new(false),
            stop: Mutex::new(Vec::new()),
        });
        let renewer = tokio::spawn(renew_loop(Arc::downgrade(&inner)));
        Lock { inner, renewer }
    }

    /// Return a client that sends this run's writes. It refuses every write
    /// except to the head once the lease is lost or [`STOP_AFTER`] has passed
    /// since the last renewal. For a repair it reads the head before each
    /// write and yields when a run waits.
    pub fn guarded(&self, client: &Client) -> Client {
        super::guard::guarded(self.inner.clone(), client.clone())
    }

    /// Cancel `token` when the run must stop: the lease was lost or its
    /// deadline passed.
    pub fn stop_with(&self, token: &CancelToken) {
        self.inner
            .stop
            .lock()
            .expect("stop lock")
            .push(token.clone());
        if let Some(why) = self.inner.stopped() {
            token.cancel_with_reason(why.to_string());
        }
    }

    /// Return the generation the head had when this run took the lock, or
    /// since its last write.
    pub fn generation(&self) -> u64 {
        self.inner
            .lease
            .lock()
            .expect("lease lock")
            .status
            .generation
    }

    /// Return the head's status as this holder last wrote it.
    pub fn status(&self) -> HeadStatus {
        self.inner.lease.lock().expect("lease lock").status.clone()
    }

    /// Return why writes are refused now, or `None` while the lease holds.
    pub fn stopped(&self) -> Option<WritesStopped> {
        self.inner.stopped()
    }

    /// Return whether a write through a guarded client succeeded.
    pub fn wrote(&self) -> bool {
        self.inner.wrote.load(Ordering::SeqCst)
    }

    /// Renew the lease now, as a run does right before it prunes.
    pub async fn renew(&self) -> Result<(), WritesStopped> {
        match self.inner.renew().await {
            Ok(true) => Ok(()),
            Ok(false) => Err(self.inner.stopped().unwrap_or(WritesStopped::TakenOver {
                cluster: self.inner.cluster.clone(),
            })),
            Err(e) => {
                tracing::warn!(cluster = %self.inner.cluster, error = %describe(&e), "could not renew the deploy lock");
                match self.inner.stopped() {
                    Some(why) => Err(why),
                    None => Ok(()),
                }
            }
        }
    }

    /// Make record `current` the one the cluster runs: the commit point of a
    /// deploy. Raise the generation and name this Kix as the writer, and keep
    /// the lock, which [`Lock::release`] gives up after the phases are
    /// written. A repair never commits.
    pub async fn commit(&self, current: &str) -> Result<(), CommitError> {
        let program = self.inner.holder.program;
        let written = self
            .inner
            .write(|status| {
                status.current = Some(current.to_string());
                status.generation += 1;
                status.writer = Some(Writer::running(program));
            })
            .await
            .map_err(|source| CommitError::Api {
                cluster: self.inner.cluster.clone(),
                source,
            })?;
        if !written {
            return Err(CommitError::Lost {
                cluster: self.inner.cluster.clone(),
            });
        }
        self.inner.committed.store(true, Ordering::SeqCst);
        tracing::info!(cluster = %self.inner.cluster, activation = %current, "committed the deploy on the deploy lock");
        Ok(())
    }

    /// Give up the lock. When the run wrote and did not commit, raise the
    /// generation and name this Kix as the writer in the same write. A
    /// repair changes neither. Releasing twice does nothing.
    pub async fn release(&self) -> Result<(), CommitError> {
        if self.inner.released.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.renewer.abort();
        let counts = self.inner.purpose != Purpose::Repair
            && self.wrote()
            && !self.inner.committed.load(Ordering::SeqCst);
        let program = self.inner.holder.program;
        let written = self
            .inner
            .write(|status| {
                status.lock = None;
                if counts {
                    status.generation += 1;
                    status.writer = Some(Writer::running(program));
                }
            })
            .await
            .map_err(|source| CommitError::Api {
                cluster: self.inner.cluster.clone(),
                source,
            })?;
        if !written {
            return Err(CommitError::Lost {
                cluster: self.inner.cluster.clone(),
            });
        }
        Ok(())
    }
}

/// Why [`Lock::commit`] or [`Lock::release`] did not write the head.
#[derive(Debug, Error)]
pub enum CommitError {
    #[error(
        "another run took over the deploy lock on cluster {cluster} before this run finished, so Kix could not record this run on `ActivationHead` `{cluster}`. Run `kix status {cluster}` to check the cluster"
    )]
    Lost { cluster: String },
    #[error(
        "could not update deploy lock `ActivationHead` `{cluster}`: {}",
        describe(.source)
    )]
    Api {
        cluster: String,
        #[source]
        source: kube::Error,
    },
}

/// Renew the lease every [`RENEW_EVERY`] while the lock is held, and stop the
/// run once the lease is lost or its deadline passed.
async fn renew_loop(inner: std::sync::Weak<Inner>) {
    let mut tripped = false;
    loop {
        tokio::time::sleep(TICK).await;
        let Some(inner) = inner.upgrade() else {
            return;
        };
        if inner.released.load(Ordering::SeqCst) {
            return;
        }
        if inner.lease.lock().expect("lease lock").lost.is_some() {
            return;
        }
        if inner.since_renewal() >= RENEW_EVERY
            && let Err(e) = inner.renew().await
        {
            tracing::warn!(cluster = %inner.cluster, error = %describe(&e), "could not renew the deploy lock; retrying");
        }
        if !tripped && let Some(why) = inner.stopped() {
            tripped = true;
            inner.trip(&why.to_string());
        }
    }
}
