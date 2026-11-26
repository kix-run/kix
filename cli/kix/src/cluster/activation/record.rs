//! Activation record types, phase transitions, and selection helpers.

use std::collections::BTreeMap;

use crate::cluster::revision::{RevisionMap, UnreadableMap};
use crate::eval::package_index::RecordPackageIndex;
use crate::manifest::keys;
use crate::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_PARTIAL,
};
use kube::api::DynamicObject;
use serde_json::Value;

/// Parsed fields of an Activation record.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    pub name: String,
    /// `status.phase`, or `""` when the record has no phase yet.
    pub phase: String,
    /// `kix.run/identity-hash` annotation value used to resolve the record to a
    /// closure.
    pub identity_hash: Option<String>,
    /// `kix.run/built-via`: the store path of the build, an index file or a
    /// result directory ([`crate::eval::build_files::BuildFiles`]).
    pub built_via: Option<String>,
    /// `kix.run/deployed-at` annotation value, written only by
    /// [`super::Records::finalize_deploy`] when a deploy runs to completion.
    pub deployed_at: Option<String>,
    /// `status.previousActivation`, naming the record superseded by this one so
    /// `kix history` can reconstruct the deploy chain.
    pub previous_activation: Option<String>,
    /// `status.failure.reason`, reported by the next deploy.
    pub failure_reason: Option<String>,
    /// `status.failure.at` (RFC 3339), also used as the retention sort key when
    /// a failed record has no `deployed-at` timestamp.
    pub failed_at: Option<String>,
    /// `status.partial`: which instances `kix deploy --only` applied of this
    /// record's build. Set exactly when the phase is `Partial`.
    pub partial: Option<PartialDeploy>,
    /// `metadata.creationTimestamp`, used as the age of a `Deploying` or
    /// `Queued` record.
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    /// `true` when `spec.source` is set, indicating an operator-driven deploy.
    pub operator_driven: bool,
    /// `spec.request`: the request a person last made, through `kix deploy
    /// --operator` or `kix rollback --operator`, for the operator to deploy
    /// this record. Only those commands write it, so a record a direct
    /// deploy wrote, or one written before Kix had requests, has none.
    pub request: Option<String>,
    /// `status.startedRequest`: the last request the operator started.
    pub started_request: Option<String>,
    /// `status.finishedRequest`: the last request whose run the operator
    /// finished.
    pub finished_request: Option<String>,
    /// `status.failedRequest`: the last request whose run on this record,
    /// while it stayed current, the operator could not finish. An operator
    /// writes it in place of `status.finishedRequest`, so a Kix that does not
    /// read it never takes the failure for success.
    pub failed_request: Option<FailedRequest>,
    /// `status.failedAttempts`: how many runs of the operator's current
    /// deploy of this record stopped at a failure. Zero when the record has
    /// none, as a record the CLI wrote or an older operator wrote does.
    pub failed_attempts: u32,
    /// `status.orphansKeptFrom`, listing builds whose orphans remain on the cluster.
    pub orphans_kept_from: Vec<KeptOrphanSource>,
    /// `status.packageIndex`, which package each resource of the record's
    /// build belongs to. `None` when the record has none, as records written
    /// before Kix wrote it do, or when it is in a format this release does
    /// not read.
    pub package_index: Option<RecordPackageIndex>,
    /// `status.revisions`, the revisions the record's deploy is made of.
    /// `None` when the record has none, as records an earlier Kix wrote and
    /// `Superseded` records do. An error when it is there and this release
    /// cannot read it, so the record may name revisions Kix cannot see.
    pub revisions: Option<Result<RevisionMap, UnreadableMap>>,
    /// `status.waves`, recording per-wave progress for commands waiting on the operator.
    pub waves: Vec<WaveRecord>,
    pub total_waves: usize,
    /// `true` when `metadata.deletionTimestamp` is set.
    pub deleting: bool,
    /// `metadata.uid` from the server, used as a precondition by
    /// [`super::Records::retire`]. Empty for records constructed in memory without
    /// server metadata.
    pub uid: String,
    pub resource_version: String,
    /// `spec.interfaces`: consumer interface pins keyed by platform name.
    pub interfaces: BTreeMap<String, PinnedInterface>,
    /// `spec.consumers.<consumer>.sha256`: published interface hashes keyed by
    /// consumer name.
    pub published_interfaces: BTreeMap<String, String>,
    /// The version of Kix that made this deploy, from the receipt in
    /// `status.receipt`: `deployer.kixVersion` for a deploy from a bundle,
    /// else `builder.kixVersion`. `None` when the record has no receipt, as
    /// an operator deploy's record does.
    pub deployed_with: Option<String>,
    /// The commit the deploy was built from, from the receipt's
    /// `source.gitCommit`. `None` when the record has no receipt, or the
    /// build did not come from a Git checkout.
    pub deployed_from: Option<String>,
}

/// What `kix deploy --only` applied of a record's build, read from
/// `status.partial`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PartialDeploy {
    /// The instances (`namespace/instance`) that deploys with `--only`
    /// applied, sorted.
    pub only: Vec<String>,
    /// When the last of those deploys ended (RFC 3339).
    pub at: Option<String>,
}

impl PartialDeploy {
    fn of(obj: &DynamicObject) -> Option<Self> {
        let partial = obj.data.pointer(&format!("/status/{PARTIAL_FIELD}"))?;
        if !partial.is_object() {
            return None;
        }
        let mut only: Vec<String> = partial
            .get("only")
            .and_then(Value::as_array)
            .map(|names| {
                names
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        only.sort();
        only.dedup();
        Some(PartialDeploy {
            only,
            at: partial
                .get("at")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
    }
}

/// A request the operator could not finish on a current record, read from
/// `status.failedRequest`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailedRequest {
    /// The request, as in `spec.request`.
    pub request: String,
    /// Why the run stopped.
    pub reason: String,
}

/// Platform interface file metadata pinned by a consumer build.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct PinnedInterface {
    /// Consumer name assigned to this cluster by the platform.
    pub consumer: String,
    /// Interface file path relative to the flake root.
    pub path: String,
    /// SHA-256 hash of the interface file produced by the platform build.
    pub sha256: String,
}

/// The `spec` field that holds a person's request to deploy the record.
pub(crate) const REQUEST_FIELD: &str = "request";
/// The `status` field that holds the last request the operator started.
pub(crate) const STARTED_REQUEST_FIELD: &str = "startedRequest";
/// The `status` field that holds the last request the operator finished.
pub(crate) const FINISHED_REQUEST_FIELD: &str = "finishedRequest";
/// The `status` field that holds the last request the operator could not
/// finish on a current record, with the reason.
pub(crate) const FAILED_REQUEST_FIELD: &str = "failedRequest";
/// The `status` field that names the instances a deploy with `--only`
/// applied of the record's build.
pub(crate) const PARTIAL_FIELD: &str = "partial";
/// The `status` field that names the revisions the record's deploy is made
/// of.
pub(crate) const REVISIONS_FIELD: &str = "revisions";
/// The `status` field that counts the failed runs of the operator's current
/// deploy.
pub(crate) const FAILED_ATTEMPTS_FIELD: &str = "failedAttempts";

/// Return a new request token: 32 random hexadecimal digits.
pub fn new_request() -> String {
    format!("{:032x}", fastrand::u128(..))
}

impl Record {
    /// Parse a [`Record`] from a live Activation `DynamicObject`.
    pub fn of(obj: &DynamicObject) -> Record {
        let annotations = obj.metadata.annotations.as_ref();
        let annotation = |key: &str| {
            annotations
                .and_then(|a| keys::get_meta(a, key))
                .map(str::to_string)
        };
        let status = |pointer: &str| {
            obj.data
                .pointer(pointer)
                .and_then(Value::as_str)
                .map(str::to_string)
        };
        Record {
            name: obj.metadata.name.clone().unwrap_or_default(),
            phase: read_phase(obj).to_string(),
            identity_hash: annotation(keys::IDENTITY_HASH),
            built_via: annotation(keys::BUILT_VIA),
            deployed_at: annotation(keys::DEPLOYED_AT),
            previous_activation: status("/status/previousActivation"),
            failure_reason: status("/status/failure/reason"),
            failed_at: status("/status/failure/at"),
            partial: PartialDeploy::of(obj),
            created_at: obj
                .metadata
                .creation_timestamp
                .as_ref()
                .and_then(crate::cluster::chrono_time),
            operator_driven: obj.data.pointer("/spec/source").is_some(),
            request: status(&format!("/spec/{REQUEST_FIELD}")),
            started_request: status(&format!("/status/{STARTED_REQUEST_FIELD}")),
            finished_request: status(&format!("/status/{FINISHED_REQUEST_FIELD}")),
            failed_request: status(&format!("/status/{FAILED_REQUEST_FIELD}/request")).map(
                |request| FailedRequest {
                    request,
                    reason: status(&format!("/status/{FAILED_REQUEST_FIELD}/reason"))
                        .unwrap_or_default(),
                },
            ),
            failed_attempts: obj
                .data
                .pointer(&format!("/status/{FAILED_ATTEMPTS_FIELD}"))
                .and_then(Value::as_u64)
                .map_or(0, |n| u32::try_from(n).unwrap_or(u32::MAX)),
            orphans_kept_from: orphans_kept_from(obj),
            package_index: obj
                .data
                .pointer(&format!("/status/{}", keys::PACKAGE_INDEX_FIELD))
                .and_then(RecordPackageIndex::from_value),
            revisions: obj
                .data
                .pointer(&format!("/status/{REVISIONS_FIELD}"))
                .filter(|v| !v.is_null())
                .map(RevisionMap::read),
            waves: obj
                .data
                .pointer("/status/waves")
                .and_then(Value::as_array)
                .map(|waves| waves.iter().map(WaveRecord::of).collect())
                .unwrap_or_default(),
            total_waves: obj
                .data
                .pointer("/status/totalWaves")
                .and_then(Value::as_u64)
                .unwrap_or(0) as usize,
            deleting: obj.metadata.deletion_timestamp.is_some(),
            uid: obj.metadata.uid.clone().unwrap_or_default(),
            resource_version: obj.metadata.resource_version.clone().unwrap_or_default(),
            interfaces: spec_map(obj, "/spec/interfaces", |v| {
                serde_json::from_value(v.clone()).ok()
            }),
            published_interfaces: spec_map(obj, "/spec/consumers", |v| {
                v.get("sha256").and_then(Value::as_str).map(str::to_string)
            }),
            deployed_with: ["deployer", "builder"].into_iter().find_map(|who| {
                status(&format!("/status/{}/{who}/kixVersion", keys::RECEIPT_FIELD))
            }),
            deployed_from: status(&format!("/status/{}/source/gitCommit", keys::RECEIPT_FIELD)),
        }
    }

    /// Return the request the operator has not started yet, or `None` when
    /// there is none. A request is a token compared only for equality, so
    /// the clocks of the machines that wrote it do not matter.
    pub fn pending_request(&self) -> Option<&str> {
        self.request
            .as_deref()
            .filter(|request| self.started_request.as_deref() != Some(*request))
    }

    /// Return `true` if this record ever completed a deploy and is therefore a
    /// valid rollback target.
    ///
    /// [`super::Records::finalize_deploy`] is the only caller that writes
    /// `kix.run/deployed-at`, so the annotation is present if and only if a
    /// deploy of this closure ran to completion. A record superseded directly
    /// from `Failed` lacks `kix.run/deployed-at`, whereas a previously deployed
    /// record whose later rollback was interrupted retains `kix.run/deployed-at`
    /// alongside `status.failure` and remains a valid rollback target.
    pub(super) fn was_ever_current(&self) -> bool {
        self.deployed_at
            .as_deref()
            .is_some_and(|at| !at.trim().is_empty())
    }

    /// Return the timestamp used to order this record during retention checks.
    ///
    /// Uses `kix.run/deployed-at` when present, falling back to
    /// [`Record::stopped_at`] and then `metadata.creationTimestamp` for records
    /// that never completed a deploy so they are not immediately retired as
    /// [`super::RetireReason::UnknownAge`].
    pub(super) fn retention_time(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        [self.deployed_at.as_deref(), self.stopped_at()]
            .into_iter()
            .find_map(|at| at.and_then(parse_time))
            .or(self.created_at)
    }

    /// Return what `kix deploy --only` applied of the record's build when
    /// the record is `Partial`, and `None` in any other phase.
    pub fn partly_deployed(&self) -> Option<&PartialDeploy> {
        if self.phase == PHASE_PARTIAL {
            self.partial.as_ref()
        } else {
            None
        }
    }

    /// Return when the record's deploy stopped without making it current:
    /// `status.failure.at`, or `status.partial.at` for a deploy with
    /// `--only`.
    pub(super) fn stopped_at(&self) -> Option<&str> {
        self.failed_at
            .as_deref()
            .or_else(|| self.partial.as_ref().and_then(|p| p.at.as_deref()))
    }
}

/// Parse the JSON object at `pointer` into a map, skipping entries for which
/// `read` returns `None`.
fn spec_map<T>(
    obj: &DynamicObject,
    pointer: &str,
    read: impl Fn(&Value) -> Option<T>,
) -> BTreeMap<String, T> {
    obj.data
        .pointer(pointer)
        .and_then(Value::as_object)
        .map(|entries| {
            entries
                .iter()
                .filter_map(|(name, v)| Some((name.clone(), read(v)?)))
                .collect()
        })
        .unwrap_or_default()
}

/// A build whose orphans a deploy reported and kept on the cluster.
///
/// A deploy detects orphans by comparing its build with the builds it replaces.
/// When orphans are kept (in warn-only mode, `--skip-orphan-check`, or after a
/// failed delete), the finalized record records those builds under
/// `status.orphansKeptFrom` so a subsequent `kix deploy --prune`,
/// `kix rollback --prune`, or soft `kix gc` can still compare against them.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeptOrphanSource {
    /// Name of the Activation record that owned the build (which may since have
    /// been retired).
    pub activation: String,
    /// The build's `kix.run/identity-hash`, resolved through the local
    /// activation cache when `built_via` is not in the local Nix store.
    pub identity_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub built_via: Option<String>,
}

/// Orphan sources accumulated during a deploy to write to `status.orphansKeptFrom`.
#[derive(Debug, Clone, Default)]
pub(crate) struct KeptOrphans {
    /// Builds in which this run's plan found orphans. Written only when at
    /// least one orphan remains on the cluster after pruning.
    pub found: Vec<KeptOrphanSource>,
    /// Sources the plan could not inspect because their builds are absent from
    /// the local Nix store. Always preserved because their orphans could not be
    /// pruned.
    pub unexamined: Vec<KeptOrphanSource>,
    /// Whether to carry forward `status.orphansKeptFrom` from the record that
    /// was current at finalize time (used when `--offline` bypassed
    /// reading the live record during planning).
    pub carry_current: bool,
    /// Objects the records name that the plan could not find out about,
    /// because the cluster does not serve their kind. The run's
    /// kept-orphans revision names them again.
    pub unknown: Vec<crate::cluster::revision::RevisionObject>,
}

impl KeptOrphans {
    /// Return the deduplicated list of orphan sources to write to
    /// `status.orphansKeptFrom`.
    pub fn recorded(
        &self,
        current: Option<&[KeptOrphanSource]>,
        orphans_left: bool,
    ) -> Vec<KeptOrphanSource> {
        let found = if orphans_left { &self.found[..] } else { &[] };
        let carried = if self.carry_current {
            current.unwrap_or_default()
        } else {
            &[]
        };
        let mut out: Vec<KeptOrphanSource> = Vec::new();
        for source in found.iter().chain(&self.unexamined).chain(carried) {
            if !out.iter().any(|s| s.identity_hash == source.identity_hash) {
                out.push(source.clone());
            }
        }
        out
    }
}

/// Read `status.orphansKeptFrom` from an Activation object, skipping malformed
/// entries with a debug log.
fn orphans_kept_from(activation: &DynamicObject) -> Vec<KeptOrphanSource> {
    let Some(entries) = activation
        .data
        .pointer(&format!("/status/{}", keys::ORPHANS_KEPT_FROM_FIELD))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| match serde_json::from_value(entry.clone()) {
            Ok(source) => Some(source),
            Err(e) => {
                tracing::debug!(error = %e, "ignoring a malformed orphansKeptFrom entry");
                None
            }
        })
        .collect()
}

pub(super) fn parse_time(s: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|t| t.with_timezone(&chrono::Utc))
}

/// Parse a record's `kix.run/deployed-at` annotation, returning `None` when
/// absent or malformed.
fn parsed_deployed_at(item: &DynamicObject) -> Option<chrono::DateTime<chrono::Utc>> {
    item.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::DEPLOYED_AT))
        .and_then(parse_time)
}

/// Select the current record from a list of candidates by choosing the most
/// recent `deployed-at` timestamp and breaking ties by name.
///
/// Although a cluster normally has at most one `Active` or `Degraded` record,
/// a partial supersede, concurrent deploys, or manual status edits can leave
/// multiple candidates. Sorting by timestamp and name keeps selection
/// independent of API server list order.
pub(super) fn pick_current<T>(
    mut candidates: Vec<(T, Option<chrono::DateTime<chrono::Utc>>, String)>,
) -> Option<T> {
    // Sort newest first; records without a valid timestamp sort last.
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
    candidates.into_iter().next().map(|(value, _, _)| value)
}

/// Return the current (`Active` or `Degraded`) record from `records`, choosing
/// the most recently deployed when multiple exist.
pub fn current_record<'a>(
    records: impl IntoIterator<Item = &'a DynamicObject>,
) -> Option<&'a DynamicObject> {
    pick_current(
        records
            .into_iter()
            .filter(|r| is_current_phase(read_phase(r)))
            .map(|r| {
                (
                    r,
                    parsed_deployed_at(r),
                    r.metadata.name.clone().unwrap_or_default(),
                )
            })
            .collect(),
    )
}

/// Return `true` if `phase` represents the cluster's current state (`Active` or
/// `Degraded`).
pub(super) fn is_current_phase(phase: &str) -> bool {
    phase == PHASE_ACTIVE || phase == PHASE_DEGRADED
}

/// Read `status.phase` from an Activation object, returning `""` when absent.
pub(super) fn read_phase(activation: &DynamicObject) -> &str {
    activation
        .data
        .pointer("/status/phase")
        .and_then(|v| v.as_str())
        .unwrap_or("")
}

/// Sort `records` most recent first by [`Record::retention_time`], breaking
/// ties by name.
pub(super) fn sort_newest_first(records: &mut [Record]) {
    records.sort_by(|a, b| {
        b.retention_time()
            .cmp(&a.retention_time())
            .then_with(|| a.name.cmp(&b.name))
    });
}

/// Status of a single wave in the deploy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaveStatus {
    Pending,
    Complete,
    Failed,
}

impl WaveStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            WaveStatus::Pending => "Pending",
            WaveStatus::Complete => "Complete",
            WaveStatus::Failed => "Failed",
        }
    }

    fn from_str(s: &str) -> Self {
        match s {
            "Complete" => WaveStatus::Complete,
            "Failed" => WaveStatus::Failed,
            _ => WaveStatus::Pending,
        }
    }
}

/// Return the phase a record should transition to when a deploy begins, or
/// `None` to leave its current phase unchanged.
///
/// When re-deploying the closure that is already `Active` or `Degraded`, its
/// phase is preserved so an interrupted re-deploy does not leave the cluster
/// without a current record.
pub(super) fn phase_on_begin(current: &str) -> Option<&'static str> {
    match current {
        PHASE_ACTIVE | PHASE_DEGRADED => None,
        _ => Some(PHASE_DEPLOYING),
    }
}

/// Return the phase a record should transition to when a deploy aborts before
/// finalizing, or `None` to leave its phase unchanged.
///
/// Transitions only records in `Deploying` or with an empty phase (when the
/// deploy aborted between creating the record and marking it `Deploying`).
/// Leaves `Active`, `Degraded`, `Queued`, `Superseded`, `Failed`, and
/// `Partial` records untouched.
pub(super) fn phase_on_abort(current: &str) -> Option<&'static str> {
    match current {
        PHASE_DEPLOYING | "" => Some(PHASE_FAILED),
        _ => None,
    }
}

/// Return the phase a record should transition to when a deploy with
/// `--only` applies everything it selected, or `None` to leave its phase
/// unchanged.
///
/// Transitions the same records as [`phase_on_abort`]. A record that is
/// current keeps its phase, because the build is the one the cluster runs.
pub(super) fn phase_on_end_partial(current: &str) -> Option<&'static str> {
    match current {
        PHASE_DEPLOYING | "" => Some(PHASE_PARTIAL),
        _ => None,
    }
}

/// Result summary for a single wave in `status.waves`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaveRecord {
    pub wave_index: usize,
    pub status: WaveStatus,
    pub resource_count: usize,
    pub applied: usize,
    pub failed: usize,
}

impl WaveRecord {
    /// Parse a [`WaveRecord`] from an entry in `status.waves`, defaulting
    /// missing counts to `0` and missing status to [`WaveStatus::Pending`].
    fn of(wave: &Value) -> WaveRecord {
        let number = |key: &str| wave.get(key).and_then(Value::as_u64).unwrap_or(0) as usize;
        WaveRecord {
            wave_index: number("wave"),
            status: wave
                .get("status")
                .and_then(Value::as_str)
                .map_or(WaveStatus::Pending, WaveStatus::from_str),
            resource_count: number("resources"),
            applied: number("applied"),
            failed: number("failed"),
        }
    }
}
