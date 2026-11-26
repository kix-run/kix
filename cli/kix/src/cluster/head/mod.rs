//! The `ActivationHead`: one object per Kix cluster that says which record
//! the cluster runs, which Kix wrote to it last, and who holds its deploy
//! lock.
//!
//! This module is the only code that writes the head. Commands and the
//! operator call [`take`] before they change a Kix cluster, write through
//! the client [`Lock::guarded`] hands out, and end with [`Lock::commit`]
//! (the one point a deploy becomes current) and [`Lock::release`].
//!
//! - Every write carries the head's `resourceVersion`, so Kubernetes refuses
//!   the second of two writers.
//! - A second run watches the lock for up to one lease ([`LEASE`]). It
//!   refuses when the holder renews, and takes over when nothing renews.
//! - The holder renews every [`RENEW_EVERY`] in a background task, and sends
//!   no write except to the head once [`STOP_AFTER`] has passed since its
//!   last renewal. It measures that time with the monotonic clock and with
//!   the wall clock and uses the longer, because the monotonic clock stops
//!   on some systems while the machine sleeps.
//! - The head's CRD is part of the Kix program. [`ensure_crd`] creates it
//!   when it is absent, before any lock is taken.
//!
//! The phases on Activation records are still written and read as before.
//! [`take`] rebuilds the head from them when an older Kix wrote after it,
//! and repairs them from the head when a deploy stopped between its commit
//! and its phase writes.

mod crd;
mod guard;
mod lock;
#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use kube::Client;
use kube::api::{Api, DynamicObject};
use kube::discovery::ApiResource;
use serde::{Deserialize, Serialize};

use crate::manifest::keys;

pub use crd::{CrdError, ensure_crd};
pub use guard::WritesStopped;
pub use lock::{CommitError, Held, Lock, Request, TakeError, settle, take};

/// The kind of the head.
pub const KIND: &str = "ActivationHead";

/// The plural the API serves the head under.
pub const PLURAL: &str = "activationheads";

/// How long a lock stays valid after its holder last renewed it.
pub const LEASE: Duration = Duration::from_secs(30);

/// How often the holder renews its lock.
pub const RENEW_EVERY: Duration = Duration::from_secs(10);

/// How long after its last renewal the holder stops writing. It is shorter
/// than [`LEASE`], so a holder whose renewals fail has stopped before another
/// run may take over.
pub const STOP_AFTER: Duration = Duration::from_secs(20);

/// Return the name of the head's CustomResourceDefinition.
pub fn crd_name() -> String {
    format!("{PLURAL}.{}", keys::GROUP)
}

fn resource() -> ApiResource {
    let version = keys::API_VERSION
        .rsplit_once('/')
        .map_or(keys::API_VERSION, |(_, v)| v);
    ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk(keys::GROUP, version, KIND),
        PLURAL,
    )
}

fn api(client: &Client) -> Api<DynamicObject> {
    Api::all_with(client.clone(), &resource())
}

/// Why a run holds the lock.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    Deploy,
    Rollback,
    Gc,
    Migrate,
    /// The operator corrects drift from the current record. It gives the
    /// lock to a run that waits for it, and does not count as a write.
    Repair,
    /// The operator deletes the objects of a deleted record.
    Teardown,
    /// A purpose a newer Kix wrote.
    #[serde(other)]
    Other,
}

impl Purpose {
    /// Return the purpose as the head stores it.
    pub fn as_str(self) -> &'static str {
        match self {
            Purpose::Deploy => "deploy",
            Purpose::Rollback => "rollback",
            Purpose::Gc => "gc",
            Purpose::Migrate => "migrate",
            Purpose::Repair => "repair",
            Purpose::Teardown => "teardown",
            Purpose::Other => "other",
        }
    }
}

/// Which Kix program wrote to the cluster.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Program {
    Cli,
    Operator,
    /// A program a newer Kix wrote.
    #[serde(other)]
    Other,
}

/// The Kix that last finished a write to the cluster.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct Writer {
    /// The Kix version, as `kix --version` prints it.
    pub version: String,
    pub program: Program,
}

impl Writer {
    /// Return this Kix, run as `program`.
    pub fn running(program: Program) -> Writer {
        Writer {
            version: crate::version::running().to_string(),
            program,
        }
    }
}

/// `status.lock`: who holds the deploy lock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct LockState {
    /// The id of the run that holds the lock.
    pub holder: String,
    /// A description of the run a person can read, such as `kix deploy by
    /// ana@laptop, process 4242`.
    #[serde(default)]
    pub hint: String,
    /// The record the holder is deploying, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activation: Option<String>,
    pub purpose: Purpose,
    /// When the holder last renewed the lock, by its own clock, in RFC 3339.
    pub renewed: String,
    pub duration_seconds: u64,
    /// The id of a run that waits for a repair to give up the lock.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting: Option<String>,
}

impl LockState {
    /// Return `renewed` as a time, or `None` when it does not parse.
    pub fn renewed_at(&self) -> Option<DateTime<Utc>> {
        DateTime::parse_from_rfc3339(&self.renewed)
            .ok()
            .map(|t| t.with_timezone(&Utc))
    }
}

/// Return `time` as the head stores it.
pub(crate) fn rfc3339(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// `status` of the head.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HeadStatus {
    /// The name of the record the cluster runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<String>,
    /// Rises each time a run that wrote to the cluster releases the lock.
    /// A plan binds to it.
    #[serde(default)]
    pub generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lock: Option<LockState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub writer: Option<Writer>,
}

/// The head of a Kix cluster as one read found it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Head {
    pub resource_version: String,
    /// `None` when the object has no `status`, as after a restore from a
    /// backup that drops it.
    pub status: Option<HeadStatus>,
}

impl Head {
    fn of(obj: &DynamicObject) -> Head {
        Head {
            resource_version: obj.metadata.resource_version.clone().unwrap_or_default(),
            status: obj
                .data
                .get("status")
                .filter(|s| s.is_object())
                .and_then(|s| serde_json::from_value(s.clone()).ok()),
        }
    }

    /// Return the generation a plan binds to: the head's, or 0 when it has
    /// no status.
    pub fn generation(&self) -> u64 {
        self.status.as_ref().map_or(0, |s| s.generation)
    }

    pub fn lock(&self) -> Option<&LockState> {
        self.status.as_ref().and_then(|s| s.lock.as_ref())
    }

    pub fn writer(&self) -> Option<&Writer> {
        self.status.as_ref().and_then(|s| s.writer.as_ref())
    }
}

/// Return the generation a plan of Kix cluster `head` binds to: 0 when the
/// cluster has no head yet.
pub fn generation_of(head: Option<&Head>) -> u64 {
    head.map_or(0, Head::generation)
}

/// Read the head of Kix cluster `cluster`, or `None` when it has none or the
/// head's kind is not served. A read never waits and never takes the lock.
pub async fn read(client: &Client, cluster: &str) -> Result<Option<Head>, kube::Error> {
    match api(client).get_opt(cluster).await {
        Ok(found) => Ok(found.as_ref().map(Head::of)),
        Err(kube::Error::Api(e)) if e.code == 404 => Ok(None),
        Err(e) => Err(e),
    }
}

/// What a command that only reads says about a lock: who holds it and how
/// long ago it was renewed by this machine's clock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LockView {
    pub holder: String,
    pub hint: String,
    pub purpose: Purpose,
    /// The record the holder is deploying, if any.
    pub activation: Option<String>,
    /// When the holder last renewed the lock, by its clock, in RFC 3339.
    pub renewed: String,
    /// Seconds from `renewed` to now by this machine's clock. Negative when
    /// the two clocks disagree, and `null` when `renewed` does not parse.
    pub seconds_since_renewal: Option<i64>,
    /// Whether that is longer than the lease, so the run has probably died
    /// and the next run that changes the cluster takes over. Clocks of two
    /// machines can disagree, so this is a guess, not a decision.
    pub probably_dead: bool,
}

impl LockView {
    /// Describe `lock` as of `now`.
    pub fn of(lock: &LockState, now: DateTime<Utc>) -> LockView {
        let since = lock.renewed_at().map(|t| (now - t).num_seconds());
        let lease = i64::try_from(lock.duration_seconds).unwrap_or(i64::MAX);
        LockView {
            holder: lock.holder.clone(),
            hint: lock.hint.clone(),
            purpose: lock.purpose,
            activation: lock.activation.clone(),
            renewed: lock.renewed.clone(),
            seconds_since_renewal: since,
            probably_dead: since.is_none_or(|s| s > lease),
        }
    }

    /// Return one line that says who holds the lock, for `kix status` and
    /// `kix plan`.
    pub fn describe(&self) -> String {
        let what = match &self.activation {
            Some(record) => format!("{} of {record}", self.purpose.as_str()),
            None => self.purpose.as_str().to_string(),
        };
        let who = if self.hint.is_empty() {
            self.holder.as_str()
        } else {
            self.hint.as_str()
        };
        let base = match self.seconds_since_renewal {
            Some(since) => format!("{who} holds the deploy lock ({what}), renewed {since}s ago"),
            None => format!(
                "{who} holds the deploy lock ({what}), renewed at {}",
                self.renewed
            ),
        };
        if self.probably_dead {
            format!(
                "{base}. That is longer than the {}s lease, so the run has probably stopped; the next deploy takes over the lock",
                LEASE.as_secs()
            )
        } else {
            base
        }
    }
}

/// What a plan read of the head: the generation it binds to, the record the
/// head names as current, and the lock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct HeadRead {
    /// The head's generation, or 0 when the cluster has no head yet.
    pub generation: u64,
    /// The record the head names as current.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<String>,
    /// The lock as it was read, or `None` when no run held it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lock: Option<LockState>,
    /// The Kix that last finished a write, or `None` when the head names
    /// none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub writer: Option<Writer>,
}

impl HeadRead {
    /// Summarise `head`, which may be absent.
    pub fn of(head: Option<&Head>) -> HeadRead {
        let status = head.and_then(|h| h.status.as_ref());
        HeadRead {
            generation: generation_of(head),
            current: status.and_then(|s| s.current.clone()),
            lock: status.and_then(|s| s.lock.clone()),
            writer: status.and_then(|s| s.writer.clone()),
        }
    }

    /// Describe what the plan read for the plan document, as of `now`.
    pub fn document(&self, now: DateTime<Utc>) -> crate::plan::document::PlanHead {
        crate::plan::document::PlanHead {
            generation: self.generation,
            current: self.current.clone(),
            lock: self.lock.as_ref().map(|l| LockView::of(l, now)),
        }
    }
}

/// Where the holder reads the time. Monotonic time comes from
/// `tokio::time::Instant`, so tests run on paused time.
pub trait Clock: Send + Sync + 'static {
    fn wall(&self) -> DateTime<Utc>;
    fn mono(&self) -> tokio::time::Instant {
        tokio::time::Instant::now()
    }
}

/// The system's clocks.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn wall(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

/// Return the system's clocks, shared.
pub fn system_clock() -> Arc<dyn Clock> {
    Arc::new(SystemClock)
}

/// The run that takes a lock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Holder {
    pub id: String,
    pub hint: String,
    pub program: Program,
}

impl Holder {
    /// Return a holder for one run of `command` (such as `kix deploy`) from
    /// this machine. The id differs for every run.
    pub fn cli(command: &str) -> Holder {
        let user = std::env::var("USER")
            .or_else(|_| std::env::var("USERNAME"))
            .unwrap_or_else(|_| "unknown".into());
        let host = std::env::var("HOSTNAME")
            .ok()
            .or_else(|| std::fs::read_to_string("/etc/hostname").ok())
            .map(|h| h.trim().to_string())
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| "unknown-host".into());
        Holder {
            id: format!("cli-{:016x}", fastrand::u64(..)),
            hint: format!("{command} by {user}@{host}, process {}", std::process::id()),
            program: Program::Cli,
        }
    }

    /// Return the holder of the Kix operator running in `namespace`. The id
    /// is the same after the operator's pod restarts, so the new pod takes
    /// over the lock its last pod left at once. The operator runs one deploy
    /// of a Kix cluster at a time, so no live run of it holds that id.
    pub fn operator(namespace: &str, pod: Option<&str>) -> Holder {
        let hint = match pod {
            Some(pod) => format!("Kix operator pod {namespace}/{pod}"),
            None => format!("Kix operator in namespace {namespace}"),
        };
        Holder {
            id: format!("kix-operator/{namespace}"),
            hint,
            program: Program::Operator,
        }
    }
}
