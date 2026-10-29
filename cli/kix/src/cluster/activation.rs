//! Activation CR lifecycle management.
//!
//! The Activation CR is the cluster-level record of what is deployed. This
//! module manages its state machine:
//!
//! A deploy creates a `Deploying` record before applying resources. Completion
//! moves it to `Active` or `Failed`. A later deploy supersedes the current
//! record, and garbage collection removes superseded records after their
//! resources are pruned.
//!
//! The record is created at the start of the deploy and re-asserted in the
//! final wave. Because its spec lists every `PackageInstance`, its identity
//! hash is the root of the closure's Merkle tree. Creating it early preserves
//! that property while ensuring that a deploy interrupted mid-wave leaves an
//! accurate record of what was attempted so the next deploy can fold its
//! partial state into the baseline.
//!
//! [`Records`] is the sole interface for reading and writing Activation
//! records. Opening [`Records`] runs the legacy-domain check so commands cannot
//! operate on records under a retired API group.

use std::collections::{BTreeMap, HashSet};

use crate::legacy_domain::{self, LegacyDomainError};
use crate::manifest::keys;
use crate::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_QUEUED, PHASE_SUPERSEDED,
};
use kube::{
    api::{Api, DeleteParams, DynamicObject, ListParams, Patch, PatchParams, Preconditions},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::{Value, json};
use thiserror::Error;

/// Error returned when the API server fails an operation on an Activation
/// record or on the list of records.
#[derive(Error, Debug)]
#[error("failed to {op} {}: {source}", target(.name))]
pub struct RecordsError {
    pub op: &'static str,
    pub name: Option<String>,
    #[source]
    pub source: kube::Error,
}

fn target(name: &Option<String>) -> String {
    match name {
        Some(name) => format!("activation '{name}'"),
        None => "activations".to_string(),
    }
}

impl RecordsError {
    /// Construct an error for a failed record list operation.
    fn list(source: kube::Error) -> Self {
        RecordsError {
            op: "list",
            name: None,
            source,
        }
    }

    /// Return `true` if the API server refused the request with HTTP 403.
    pub fn forbidden(&self) -> bool {
        matches!(
            crate::cluster::errors::classify(&self.source),
            crate::cluster::errors::FailureClass::Forbidden
        )
    }

    /// Construct an error constructor for a failed `op` on the record `name`.
    fn on(op: &'static str, name: &str) -> impl FnOnce(kube::Error) -> Self {
        let name = name.to_string();
        move |source| RecordsError {
            op,
            name: Some(name),
            source,
        }
    }
}

/// Errors returned by [`Records::open_installed`].
#[derive(Error, Debug)]
pub enum OpenError {
    #[error(transparent)]
    Domain(#[from] LegacyDomainError),

    #[error(
        "the Kix Activation resource type is not installed on this cluster. Check the Kubernetes context and deploy the Kix CRDs before retrying."
    )]
    NotInstalled,
}

/// Parsed fields of an Activation record.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    pub name: String,
    /// `status.phase`, or `""` when the record has no phase yet.
    pub phase: String,
    /// `kix.run/identity-hash` annotation value used to resolve the record to a
    /// closure.
    pub identity_hash: Option<String>,
    /// Store path of the activation result directory containing `kix-packages.json`.
    pub built_via: Option<String>,
    /// `kix.run/deployed-at` annotation value, written only by
    /// [`Records::finalize_deploy`] when a deploy runs to completion.
    pub deployed_at: Option<String>,
    /// `status.previousActivation`, naming the record superseded by this one so
    /// `kix rollback --list` can reconstruct the deploy chain.
    pub previous_activation: Option<String>,
    /// `status.failure.reason`, reported by the next deploy.
    pub failure_reason: Option<String>,
    /// `status.failure.at` (RFC 3339), also used as the retention sort key when
    /// a failed record has no `deployed-at` timestamp.
    pub failed_at: Option<String>,
    /// `metadata.creationTimestamp`, used as the age of a `Deploying` or
    /// `Queued` record.
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    /// `true` when `spec.source` is set, indicating an operator-driven deploy.
    pub operator_driven: bool,
    /// `status.orphansKeptFrom`, listing builds whose orphans remain on the cluster.
    pub orphans_kept_from: Vec<KeptOrphanSource>,
    /// `status.waves`, recording per-wave progress for commands waiting on the operator.
    pub waves: Vec<WaveRecord>,
    pub total_waves: usize,
    /// `true` when `metadata.deletionTimestamp` is set.
    pub deleting: bool,
    /// `metadata.uid` from the server, used as a precondition by
    /// [`Records::retire`]. Empty for records constructed in memory without
    /// server metadata.
    pub uid: String,
    pub resource_version: String,
    /// `spec.interfaces`: consumer interface pins keyed by platform name.
    pub interfaces: BTreeMap<String, PinnedInterface>,
    /// `spec.consumers.<consumer>.sha256`: published interface hashes keyed by
    /// consumer name.
    pub published_interfaces: BTreeMap<String, String>,
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
            created_at: obj.metadata.creation_timestamp.as_ref().map(|t| t.0),
            operator_driven: obj.data.pointer("/spec/source").is_some(),
            orphans_kept_from: orphans_kept_from(obj),
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
        }
    }

    /// Return `true` if this record ever completed a deploy and is therefore a
    /// valid rollback target.
    ///
    /// [`Records::finalize_deploy`] is the only caller that writes
    /// `kix.run/deployed-at`, so the annotation is present if and only if a
    /// deploy of this closure ran to completion. A record superseded directly
    /// from `Failed` lacks `kix.run/deployed-at`, whereas a previously deployed
    /// record whose later rollback was interrupted retains `kix.run/deployed-at`
    /// alongside `status.failure` and remains a valid rollback target.
    fn was_ever_current(&self) -> bool {
        self.deployed_at
            .as_deref()
            .is_some_and(|at| !at.trim().is_empty())
    }

    /// Return the timestamp used to order this record during retention checks.
    ///
    /// Uses `kix.run/deployed-at` when present, falling back to
    /// `status.failure.at` and then `metadata.creationTimestamp` for records
    /// that never completed a deploy so they are not immediately retired as
    /// [`RetireReason::UnknownAge`].
    fn retention_time(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        [&self.deployed_at, &self.failed_at]
            .into_iter()
            .find_map(|at| at.as_deref().and_then(parse_time))
            .or(self.created_at)
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
/// When orphans are kept (in warn-only mode, `--prune-mode=no`, or after a
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
    /// was current at finalize time (used when `--current-activation` bypassed
    /// reading the live record during planning).
    pub carry_current: bool,
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

/// Return the Activation `ApiResource` under the current API group if present
/// in `discovery`. Callers must still go through [`Records::open`] to enforce
/// the legacy-domain check.
fn served_resource(discovery: &[(ApiResource, Scope)]) -> Option<&ApiResource> {
    discovery
        .iter()
        .find(|(ar, _)| {
            crate::manifest::lifecycle::is_record_kind(&ar.kind) && ar.group == keys::GROUP
        })
        .map(|(ar, _)| ar)
}

/// Return `true` if any Activation record under the current API group carries
/// `cluster` in its `kix.run/cluster` label, or `false` if none exists or the
/// Activation CRD is not installed.
///
/// Used for CLI argument disambiguation before full discovery runs.
pub async fn records_exist(client: &Client, cluster: &str) -> Result<bool, RecordsError> {
    let version = keys::API_VERSION
        .rsplit_once('/')
        .map_or(keys::API_VERSION, |(_, v)| v);
    let ar = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk(
            keys::GROUP,
            version,
            crate::manifest::lifecycle::RECORD_KIND,
        ),
        "activations",
    );
    let api: Api<DynamicObject> = Api::all_with(client.clone(), &ar);
    let lp = ListParams::default()
        .labels(&cluster_selector(cluster))
        .limit(1);
    match api.list(&lp).await {
        Ok(list) => Ok(!list.items.is_empty()),
        Err(kube::Error::Api(e)) if e.code == 404 => Ok(false),
        Err(e) => Err(RecordsError::list(e)),
    }
}

/// Build the label selector matching all Activation records for `cluster`.
fn cluster_selector(cluster: &str) -> String {
    format!(
        "app.kubernetes.io/managed-by=kix,{}={cluster}",
        keys::CLUSTER_LABEL
    )
}

fn parse_time(s: &str) -> Option<chrono::DateTime<chrono::Utc>> {
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
fn pick_current<T>(
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
fn is_current_phase(phase: &str) -> bool {
    phase == PHASE_ACTIVE || phase == PHASE_DEGRADED
}

/// Read `status.phase` from an Activation object, returning `""` when absent.
fn read_phase(activation: &DynamicObject) -> &str {
    activation
        .data
        .pointer("/status/phase")
        .and_then(|v| v.as_str())
        .unwrap_or("")
}

/// Client handle for reading and writing Activation records on a Kubernetes
/// cluster.
///
/// Constructed only via [`Records::open`], which verifies that the cluster does
/// not serve records under a retired API group.
#[derive(Clone)]
pub struct Records {
    client: Client,
    resource: ApiResource,
}

/// Result of [`Records::open`] after passing the legacy-domain check: either a
/// [`Records`] handle or `None` when the Activation CRD is not installed.
#[derive(Clone)]
pub struct OpenedRecords(Option<Records>);

impl OpenedRecords {
    /// Return a reference to the [`Records`] handle, or `None` if the cluster
    /// does not serve the Activation kind.
    pub fn records(&self) -> Option<&Records> {
        self.0.as_ref()
    }

    pub fn into_records(self) -> Option<Records> {
        self.0
    }
}

impl From<Records> for OpenedRecords {
    fn from(records: Records) -> Self {
        OpenedRecords(Some(records))
    }
}

impl Records {
    /// Validate `discovery` against retired API groups and open a [`Records`]
    /// handle if the Activation CRD is served.
    ///
    /// Rejects clusters that still serve Activation records under a retired API
    /// group so that deploy, plan, rollback, gc, health, status, compliance,
    /// and the operator all enforce the domain migration check.
    pub fn open(
        client: &Client,
        discovery: &[(ApiResource, Scope)],
    ) -> Result<OpenedRecords, LegacyDomainError> {
        legacy_domain::check_discovery(discovery)?;
        Ok(OpenedRecords(served_resource(discovery).map(|resource| {
            Records {
                client: client.clone(),
                resource: resource.clone(),
            }
        })))
    }

    /// Open [`Records`] for commands that require the Activation CRD to be
    /// installed, returning [`OpenError::NotInstalled`] when it is absent.
    pub fn open_installed(
        client: &Client,
        discovery: &[(ApiResource, Scope)],
    ) -> Result<Records, OpenError> {
        Self::open(client, discovery)?
            .into_records()
            .ok_or(OpenError::NotInstalled)
    }

    /// Return the Activation `ApiResource` used by the operator's reflector and
    /// controller.
    pub fn watch_resource(&self) -> &ApiResource {
        &self.resource
    }

    /// Return a watch stream over all Activation records for the operator.
    pub fn watcher(
        &self,
        config: kube::runtime::watcher::Config,
    ) -> impl futures::Stream<
        Item = kube::runtime::watcher::Result<kube::runtime::watcher::Event<DynamicObject>>,
    > + Send
    + use<> {
        kube::runtime::watcher(self.api(), config)
    }

    fn api(&self) -> Api<DynamicObject> {
        Api::all_with(self.client.clone(), &self.resource)
    }

    /// List all Activation objects for `cluster` regardless of phase.
    async fn list_of(&self, cluster: &str) -> Result<Vec<DynamicObject>, RecordsError> {
        let lp = ListParams::default().labels(&cluster_selector(cluster));
        Ok(self
            .api()
            .list(&lp)
            .await
            .map_err(RecordsError::list)?
            .items)
    }

    /// List all [`Record`]s for `cluster` in `phase`.
    async fn in_phase(&self, cluster: &str, phase: &str) -> Result<Vec<Record>, RecordsError> {
        Ok(self
            .list_of(cluster)
            .await?
            .iter()
            .filter(|item| read_phase(item) == phase)
            .map(Record::of)
            .collect())
    }

    /// Return the current (`Active` or `Degraded`) record for `cluster`, or
    /// `None` on a first deploy.
    ///
    /// Both `Active` and `Degraded` represent the cluster's current state for
    /// diffing. A `Degraded` activation completed with some resource failures
    /// but remains the most recent description of intended state.
    ///
    /// Excludes `Failed` (which stopped mid-deploy and does not represent the
    /// full running closure) and `Deploying` (which is still in flight).
    pub async fn active(&self, cluster: &str) -> Result<Option<Record>, RecordsError> {
        let items = self.list_of(cluster).await?;
        Ok(current_of(&items, cluster).map(Record::of))
    }

    /// List all `Failed` records for `cluster`, sorted oldest first so they
    /// fold into the baseline in the order they accumulated.
    pub async fn failed(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.in_phase(cluster, PHASE_FAILED).await?;
        records.sort_by(|a, b| {
            a.failed_at
                .cmp(&b.failed_at)
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(records)
    }

    /// List all `Deploying` records for `cluster`, sorted oldest first.
    pub async fn deploying(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.in_phase(cluster, PHASE_DEPLOYING).await?;
        records.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(records)
    }

    /// List operator-driven `Queued` records for `cluster`, sorted newest first.
    ///
    /// Filters to records with `spec.source` set (`operator_driven`), which only
    /// the operator writes. CLI-created records have an empty phase between
    /// creation and `begin_deploy`, so filtering by `operator_driven` prevents
    /// the operator from mistaking an in-flight CLI record for a queued job.
    pub async fn queued(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        // Treat an empty phase on an operator-driven record as Queued because
        // newly submitted records have no status subresource yet.
        let mut queued: Vec<Record> = self
            .list_of(cluster)
            .await?
            .iter()
            .map(Record::of)
            .filter(|r| (r.phase == PHASE_QUEUED || r.phase.is_empty()) && r.operator_driven)
            .collect();
        queued.sort_by_key(|r| std::cmp::Reverse(r.created_at));
        Ok(queued)
    }

    /// List all `Superseded` records for `cluster`, sorted most recent first by
    /// [`Record::retention_time`].
    ///
    /// Includes records that were superseded out of `Failed` without ever
    /// completing a deploy so `kix gc` can retire them and prune their hashes
    /// from `kix.run/activations`. Callers selecting a rollback target should
    /// use [`Records::rollback_targets`] instead.
    pub async fn superseded(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.in_phase(cluster, PHASE_SUPERSEDED).await?;
        sort_newest_first(&mut records);
        Ok(records)
    }

    /// List `Superseded` records for `cluster` that completed a deploy
    /// ([`Record::was_ever_current`]), sorted most recent first.
    ///
    /// Excludes records that were superseded out of `Failed` without ever
    /// completing, because rolling back to them would apply a state the cluster
    /// never ran in full.
    pub async fn rollback_targets(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.superseded(cluster).await?;
        records.retain(Record::was_ever_current);
        Ok(records)
    }

    /// Return the deploy receipt from `cluster`'s current record, or `None` if
    /// no current record exists or the record has no receipt.
    pub async fn receipt(&self, cluster: &str) -> Result<Option<Value>, RecordsError> {
        let items = self.list_of(cluster).await?;
        Ok(current_of(&items, cluster).and_then(|current| {
            current
                .data
                .pointer(&format!("/status/{}", keys::RECEIPT_FIELD))
                .cloned()
        }))
    }

    /// Return the `kix.run/identity-hash` of the record named `name`,
    /// `Some("")` if the record exists without that annotation, or `None` if no
    /// such record exists.
    ///
    /// Because a record's name includes only the first 12 characters of the
    /// build's hash, two distinct builds can collide on name; checking the full
    /// identity hash prevents one build from overwriting another's record.
    pub async fn identity_hash_of(&self, name: &str) -> Result<Option<String>, RecordsError> {
        let item = self
            .api()
            .get_opt(name)
            .await
            .map_err(RecordsError::on("get", name))?;
        // Require the current annotation key directly rather than falling back
        // to legacy keys, because a record that passes this check will be
        // overwritten by the current build.
        Ok(item.map(|o| {
            o.metadata
                .annotations
                .as_ref()
                .and_then(|a| a.get(keys::IDENTITY_HASH))
                .cloned()
                .unwrap_or_default()
        }))
    }

    /// Return the identity hashes of all Activation CRs across all clusters and
    /// phases, or `None` if listing fails.
    ///
    /// Used when pruning dead hashes from `kix.run/activations` annotations.
    /// Queries across all clusters because a cluster-scoped resource can be
    /// referenced by more than one cluster. Callers must treat `None` as "skip
    /// pruning" rather than as an empty set.
    pub(crate) async fn live_hashes(&self) -> Option<HashSet<String>> {
        let all = self
            .all()
            .await
            .map_err(|e| tracing::warn!("could not list activations, skipping prune: {e}"))
            .ok()?;
        Some(
            all.iter()
                .filter_map(|item| Record::of(item).identity_hash)
                .collect(),
        )
    }

    /// List every Activation object on the cluster across all Kix clusters and
    /// phases.
    pub(crate) async fn all(&self) -> Result<Vec<DynamicObject>, RecordsError> {
        Ok(self
            .api()
            .list(&ListParams::default())
            .await
            .map_err(RecordsError::list)?
            .items)
    }

    async fn patch_status(&self, name: &str, patch: &Value) -> Result<(), RecordsError> {
        self.api()
            .patch_status(name, &PatchParams::default(), &Patch::Merge(patch))
            .await
            .map_err(RecordsError::on("patch", name))?;
        Ok(())
    }

    /// Mark a record Superseded (status.phase only).
    pub async fn supersede(&self, name: &str) -> Result<(), RecordsError> {
        self.patch_status(name, &json!({ "status": { "phase": PHASE_SUPERSEDED } }))
            .await?;
        tracing::info!(activation = %name, "marked as Superseded");
        Ok(())
    }

    /// Delete `record` only if its `uid` and `resourceVersion` still match the
    /// object that was read.
    ///
    /// Any update since the listing (such as a rollback making the record
    /// `Active` again) increments `resourceVersion` and causes the API server
    /// to reject the delete with HTTP 409. Preconditions are sent even when
    /// empty so records constructed in memory without server metadata cannot
    /// delete a live object on the cluster.
    pub async fn retire(&self, record: &Record) -> Result<(), RecordsError> {
        let dp = DeleteParams {
            preconditions: Some(Preconditions {
                uid: Some(record.uid.clone()),
                resource_version: Some(record.resource_version.clone()),
            }),
            ..Default::default()
        };
        self.api()
            .delete(&record.name, &dp)
            .await
            .map_err(RecordsError::on("delete", &record.name))?;
        Ok(())
    }

    /// Clear `status.orphansKeptFrom` on `name` after its orphans have been
    /// deleted.
    pub async fn clear_orphans_kept_from(&self, name: &str) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": { keys::ORPHANS_KEPT_FROM_FIELD: Value::Null } }),
        )
        .await
    }

    /// Verify that the client has permission to list Activation records.
    pub async fn reachable(&self) -> Result<(), RecordsError> {
        self.api()
            .list(&ListParams::default().limit(1))
            .await
            .map_err(RecordsError::list)?;
        Ok(())
    }

    /// Fetch the [`Record`] named `name`, returning `None` if it does not exist.
    pub async fn get(&self, name: &str) -> Result<Option<Record>, RecordsError> {
        let item = self
            .api()
            .get_opt(name)
            .await
            .map_err(RecordsError::on("get", name))?;
        Ok(item.as_ref().map(Record::of))
    }

    /// Create or update an Activation record for the operator to deploy from
    /// `source_path` on `cluster`.
    ///
    /// Leaves `status.phase` unset so the operator treats the record as `Queued`
    /// and advances it through `Deploying` to `Active`.
    pub async fn submit(
        &self,
        name: &str,
        cluster: &str,
        source_path: &str,
        identity_hash: Option<&str>,
    ) -> Result<(), RecordsError> {
        let mut annotations = serde_json::Map::new();
        if let Some(hash) = identity_hash {
            annotations.insert(
                keys::IDENTITY_HASH.to_string(),
                Value::String(hash.to_string()),
            );
        }
        annotations.insert(
            keys::BUILT_VIA.to_string(),
            Value::String(source_path.to_string()),
        );

        let patch = json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": {
                "name": name,
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    keys::CLUSTER_LABEL: cluster,
                },
                "annotations": annotations,
            },
            "spec": {
                "cluster": cluster,
                "source": {
                    "type": "storePath",
                    "path": source_path,
                },
            },
        });
        self.api()
            .patch(
                name,
                &PatchParams::apply("kix-cli").force(),
                &Patch::Apply(&patch),
            )
            .await
            .map_err(RecordsError::on("apply", name))?;
        Ok(())
    }

    /// Write a deploy receipt to `name`'s status subresource via merge patch.
    pub async fn write_receipt(&self, name: &str, receipt: &Value) -> Result<(), RecordsError> {
        self.patch_status(name, &json!({ "status": { keys::RECEIPT_FIELD: receipt } }))
            .await
    }

    /// Set `metadata.finalizers` on `name`.
    pub async fn set_finalizers(
        &self,
        name: &str,
        finalizers: &[String],
    ) -> Result<(), RecordsError> {
        let patch = json!({ "metadata": { "finalizers": finalizers } });
        self.api()
            .patch(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
            .map_err(RecordsError::on("patch", name))?;
        Ok(())
    }

    /// Supersede the previous activation and finalize the new one as `Active`
    /// or `Degraded`.
    ///
    /// Records the predecessor link, deployment timestamp, cluster label, and
    /// receipt on the new record, and marks any `Failed` records consumed by
    /// this plan as `Superseded`. `orphans_kept_from` replaces
    /// `status.orphansKeptFrom` (an empty slice clears the field).
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn finalize_deploy(
        &self,
        cluster_name: &str,
        new_activation_name: &str,
        old_activation: Option<&Record>,
        had_failures: bool,
        receipt: Option<&Value>,
        consumed_failed: &[String],
        orphans_kept_from: &[KeptOrphanSource],
    ) -> Result<(), RecordsError> {
        let now = chrono::Utc::now().to_rfc3339();

        if let Some(old) = old_activation {
            self.supersede(&old.name).await?;
        }

        // Supersede Failed records folded into this plan, skipping the record
        // being finalized (which shares a name when retrying the same closure).
        // Failures here are logged rather than failing the deploy after all
        // resources have been applied.
        for name in consumed_failed {
            if name == new_activation_name {
                continue;
            }
            if let Err(e) = self.supersede(name).await {
                tracing::warn!(
                    activation = %name,
                    error = %e,
                    "could not supersede a consumed Failed record",
                );
            }
        }

        // Patch lifecycle annotations with a merge patch so the identity hash
        // and other annotations written during apply are preserved.
        let mut annotations = serde_json::Map::new();
        annotations.insert(keys::DEPLOYED_AT.to_string(), Value::String(now));
        if let Some(old) = old_activation
            && let Some(ref hash) = old.identity_hash
        {
            annotations.insert(keys::PREVIOUS.to_string(), Value::String(hash.clone()));
        }

        let spec_patch = json!({
            "metadata": {
                "labels": {
                    keys::CLUSTER_LABEL: cluster_name,
                },
                "annotations": annotations,
            },
            "spec": {
                "cluster": cluster_name,
            },
        });
        self.api()
            .patch(
                new_activation_name,
                &PatchParams::default(),
                &Patch::Merge(&spec_patch),
            )
            .await
            .map_err(RecordsError::on("patch", new_activation_name))?;

        let new_phase = if had_failures {
            PHASE_DEGRADED
        } else {
            PHASE_ACTIVE
        };
        let mut status = serde_json::Map::new();
        status.insert("phase".to_string(), json!(new_phase));
        if let Some(old) = old_activation {
            status.insert("previousActivation".to_string(), json!(old.name));
        }
        if let Some(receipt) = receipt {
            status.insert(keys::RECEIPT_FIELD.to_string(), receipt.clone());
        }
        // Write null when empty so a same-name redeploy clears any previous list.
        status.insert(
            keys::ORPHANS_KEPT_FROM_FIELD.to_string(),
            if orphans_kept_from.is_empty() {
                Value::Null
            } else {
                json!(orphans_kept_from)
            },
        );
        self.patch_status(new_activation_name, &json!({ "status": status }))
            .await?;

        tracing::info!(activation = %new_activation_name, phase = new_phase, "finalized");

        Ok(())
    }

    /// Read one record's `status.phase`, or `""` when it has none yet.
    async fn phase_of(&self, name: &str) -> Result<String, RecordsError> {
        let item = self
            .api()
            .get(name)
            .await
            .map_err(RecordsError::on("get", name))?;
        Ok(read_phase(&item).to_string())
    }

    /// Set the Activation phase to `Deploying` and initialize wave counters.
    ///
    /// Called at the start of the apply loop after the record is created. Sets
    /// `status.phase = Deploying` and `status.totalWaves = total_waves`, unless
    /// the record is already current (see [`phase_on_begin`]), in which case
    /// only the wave counters and failure field are reset.
    pub(crate) async fn begin_deploy(
        &self,
        activation_name: &str,
        total_waves: usize,
    ) -> Result<(), RecordsError> {
        let current = self.phase_of(activation_name).await?;

        let mut status = serde_json::Map::new();
        if let Some(phase) = phase_on_begin(&current) {
            status.insert("phase".to_string(), json!(phase));
        }
        status.insert("totalWaves".to_string(), json!(total_waves));
        status.insert("waves".to_string(), json!([]));
        // Clear any failure status from a prior attempt on the same record.
        status.insert("failure".to_string(), Value::Null);

        self.patch_status(activation_name, &json!({ "status": status }))
            .await
    }

    /// Mark a record `Failed` when its deploy stops before finalizing.
    ///
    /// Transitions the phase only if [`phase_on_abort`] permits it, so an
    /// aborted re-deploy of the currently `Active` closure leaves the `Active`
    /// record intact.
    pub(crate) async fn fail_deploy(
        &self,
        activation_name: &str,
        reason: &str,
    ) -> Result<(), RecordsError> {
        let current = self.phase_of(activation_name).await?;
        let Some(phase) = phase_on_abort(&current) else {
            tracing::debug!(
                activation = %activation_name,
                phase = %current,
                "deploy aborted but the record is not ours to fail",
            );
            return Ok(());
        };

        let status_patch = json!({
            "status": {
                "phase": phase,
                "failure": {
                    "reason": reason,
                    "at": chrono::Utc::now().to_rfc3339(),
                },
            },
        });
        self.patch_status(activation_name, &status_patch).await?;

        tracing::info!(activation = %activation_name, reason, "marked as Failed");
        Ok(())
    }

    /// Record the completion status of waves on the Activation CR.
    ///
    /// Patches `status.waves` with the full accumulated list tracked in memory
    /// by the caller, avoiding a GET-before-PATCH round-trip.
    pub(crate) async fn record_waves(
        &self,
        activation_name: &str,
        waves: &[WaveRecord],
    ) -> Result<(), RecordsError> {
        let wave_json: Vec<Value> = waves
            .iter()
            .map(|w| {
                json!({
                    "wave": w.wave_index,
                    "status": w.status.as_str(),
                    "resources": w.resource_count,
                    "applied": w.applied,
                    "failed": w.failed,
                })
            })
            .collect();
        self.patch_status(
            activation_name,
            &json!({ "status": { "waves": wave_json } }),
        )
        .await
    }
}

/// Return the current record for `cluster` from `items`, logging a warning if
/// multiple `Active` or `Degraded` records exist.
fn current_of<'a>(items: &'a [DynamicObject], cluster: &str) -> Option<&'a DynamicObject> {
    let current: Vec<&DynamicObject> = items
        .iter()
        .filter(|item| is_current_phase(read_phase(item)))
        .collect();
    if current.len() > 1 {
        let names: Vec<&str> = current
            .iter()
            .map(|r| r.metadata.name.as_deref().unwrap_or_default())
            .collect();
        tracing::warn!(
            cluster = %cluster,
            records = ?names,
            "more than one Active or Degraded record; using the most recently deployed",
        );
    }
    current_record(current)
}

/// Sort `records` most recent first by [`Record::retention_time`], breaking
/// ties by name.
fn sort_newest_first(records: &mut [Record]) {
    records.sort_by(|a, b| {
        b.retention_time()
            .cmp(&a.retention_time())
            .then_with(|| a.name.cmp(&b.name))
    });
}

/// Default minimum and maximum number of `Superseded` records kept by
/// [`RetentionPolicy`].
///
/// Each retained record keeps one hash in the `kix.run/activations` annotation
/// on every managed resource (which is subject to Kubernetes's 256 KiB
/// annotation size limit).
pub const DEFAULT_KEEP_MIN: usize = 10;
pub const DEFAULT_KEEP_MAX: usize = 50;

/// Retention policy governing how many `Superseded` records to keep by count
/// and age.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetentionPolicy {
    /// Minimum number of newest rollback targets to keep regardless of age.
    pub keep_min: usize,
    /// Maximum total number of `Superseded` records to keep.
    pub keep_max: usize,
    /// Maximum age for records beyond `keep_min`, or `None` to disable
    /// age-based retirement.
    pub keep_for: Option<chrono::Duration>,
    /// Reference timestamp used to evaluate `keep_for`.
    pub now: chrono::DateTime<chrono::Utc>,
}

/// Reason a `Superseded` record was selected for retirement.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetireReason {
    /// Exceeded the `keep_max` cap on retained records.
    BeyondMax(usize),
    /// Older than `keep_for` and not protected by the `keep_min` floor.
    OlderThan(chrono::Duration),
    /// Missing or malformed timestamps in `deployed-at`, `status.failure.at`,
    /// and `metadata.creationTimestamp`.
    UnknownAge,
}

/// A record selected for retirement along with the reason it was retired.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retired {
    pub record: Record,
    pub reason: RetireReason,
}

/// Partition of `Superseded` records into kept and retired sets.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Retirement {
    /// Records to retain, sorted newest first.
    pub kept: Vec<Record>,
    /// Records to delete, sorted newest first, each paired with its [`RetireReason`].
    pub retire: Vec<Retired>,
}

/// Partition a cluster's `Superseded` records into kept and retired sets under
/// `policy`.
///
/// Sorts records newest first by [`Record::retention_time`] (with missing
/// timestamps sorting oldest and ties broken by name). Among records that
/// completed a deploy ([`Record::was_ever_current`]):
/// * The newest `keep_min` are always kept regardless of age.
/// * Records beyond `keep_max` are retired with [`RetireReason::BeyondMax`].
/// * Records between `keep_min` and `keep_max` are retired when `keep_for` is
///   set and the record is older than `keep_for` (or has [`RetireReason::UnknownAge`]).
///
/// Records that never completed a deploy do not count toward `keep_min` so a
/// series of failed deploys cannot displace the last valid rollback target.
/// They are subject to `keep_for`, and if the total number of kept records
/// still exceeds `keep_max`, the oldest incomplete records are retired first.
pub fn retire_plan(mut superseded: Vec<Record>, policy: &RetentionPolicy) -> Retirement {
    let keep_max = policy.keep_max.max(policy.keep_min);
    sort_newest_first(&mut superseded);
    let mut plan = Retirement::default();
    let mut targets = 0;
    for record in superseded {
        if record.was_ever_current() {
            let i = targets;
            targets += 1;
            if i < policy.keep_min {
                plan.kept.push(record);
                continue;
            }
            if i >= keep_max {
                plan.retire.push(Retired {
                    record,
                    reason: RetireReason::BeyondMax(keep_max),
                });
                continue;
            }
        }
        match (policy.keep_for, record.retention_time()) {
            (None, _) => plan.kept.push(record),
            (Some(_), None) => plan.retire.push(Retired {
                record,
                reason: RetireReason::UnknownAge,
            }),
            (Some(max_age), Some(t)) if policy.now - t > max_age => plan.retire.push(Retired {
                record,
                reason: RetireReason::OlderThan(max_age),
            }),
            (Some(_), Some(_)) => plan.kept.push(record),
        }
    }
    // Enforce keep_max across all kept records by retiring the oldest records
    // that never completed a deploy.
    while plan.kept.len() > keep_max {
        let Some(i) = plan.kept.iter().rposition(|r| !r.was_ever_current()) else {
            break;
        };
        plan.retire.push(Retired {
            record: plan.kept.remove(i),
            reason: RetireReason::BeyondMax(keep_max),
        });
    }
    plan.retire.sort_by(|a, b| {
        b.record
            .retention_time()
            .cmp(&a.record.retention_time())
            .then_with(|| a.record.name.cmp(&b.record.name))
    });
    plan
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
fn phase_on_begin(current: &str) -> Option<&'static str> {
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
/// Leaves `Active`, `Degraded`, `Queued`, `Superseded`, and `Failed` records
/// untouched.
fn phase_on_abort(current: &str) -> Option<&'static str> {
    match current {
        PHASE_DEPLOYING => Some(PHASE_FAILED),
        "" => Some(PHASE_FAILED),
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

#[cfg(test)]
mod phase_tests {
    use super::*;

    #[test]
    fn begin_marks_anything_that_is_not_already_current() {
        for phase in [
            "",
            PHASE_QUEUED,
            PHASE_SUPERSEDED,
            PHASE_FAILED,
            PHASE_DEPLOYING,
        ] {
            assert_eq!(
                phase_on_begin(phase),
                Some(PHASE_DEPLOYING),
                "phase {phase:?} should be marked Deploying",
            );
        }
    }

    #[test]
    fn begin_leaves_the_current_record_alone() {
        // Re-deploying the closure that is already running reuses its record.
        // Demoting it to Deploying and then dying would leave the cluster
        // with no current record at all, and the next deploy would plan as a
        // first deploy: no orphans, no repairs.
        assert_eq!(phase_on_begin(PHASE_ACTIVE), None);
        assert_eq!(phase_on_begin(PHASE_DEGRADED), None);
    }

    #[test]
    fn abort_only_fails_a_record_this_run_marked() {
        assert_eq!(phase_on_abort(PHASE_DEPLOYING), Some(PHASE_FAILED));
        // A record created but never marked can only be ours: `begin` creates
        // it and marks it in two round trips, and a run that dies between the
        // two would otherwise leave it invisible to every reader.
        assert_eq!(phase_on_abort(""), Some(PHASE_FAILED));
        for phase in [
            PHASE_QUEUED,
            PHASE_ACTIVE,
            PHASE_DEGRADED,
            PHASE_SUPERSEDED,
            PHASE_FAILED,
        ] {
            assert_eq!(
                phase_on_abort(phase),
                None,
                "phase {phase:?} is not ours to fail",
            );
        }
    }

    #[test]
    fn a_record_that_never_deployed_sorts_by_when_it_failed() {
        let mut record = Record {
            name: "demo-abc".into(),
            failed_at: Some("2026-09-09T10:00:00Z".into()),
            created_at: parse_time("2026-09-09T09:00:00Z"),
            ..Default::default()
        };
        assert_eq!(
            record.retention_time().map(|t| t.to_rfc3339()),
            Some("2026-09-09T10:00:00+00:00".to_string()),
        );

        // No failure timestamp either: fall back to creation, so it is still
        // not retired as UnknownAge on the first gc.
        record.failed_at = None;
        assert_eq!(
            record.retention_time().map(|t| t.to_rfc3339()),
            Some("2026-09-09T09:00:00+00:00".to_string()),
        );

        record.created_at = None;
        assert_eq!(record.retention_time(), None);
    }

    #[test]
    fn deployed_at_wins_over_the_fallbacks() {
        let record = Record {
            name: "demo-abc".into(),
            deployed_at: Some("2026-09-01T00:00:00Z".into()),
            failed_at: Some("2026-09-09T10:00:00Z".into()),
            created_at: parse_time("2026-09-09T09:00:00Z"),
            ..Default::default()
        };
        assert_eq!(
            record.retention_time().map(|t| t.to_rfc3339()),
            Some("2026-09-01T00:00:00+00:00".to_string()),
        );
    }

    #[test]
    fn the_newest_current_record_wins_and_ties_break_on_name() {
        use chrono::{TimeZone, Utc};
        let at = |h| Some(Utc.with_ymd_and_hms(2026, 9, 9, h, 0, 0).unwrap());

        assert_eq!(
            pick_current(vec![
                ("older", at(9), "b".to_string()),
                ("newer", at(11), "a".to_string()),
            ]),
            Some("newer"),
        );

        // Same timestamp: the name decides, so the plan does not depend on
        // the order the apiserver happened to list them in.
        assert_eq!(
            pick_current(vec![
                ("bee", at(9), "b".to_string()),
                ("ay", at(9), "a".to_string()),
            ]),
            Some("ay"),
        );

        // A record with no usable timestamp sorts oldest rather than winning
        // by accident.
        assert_eq!(
            pick_current(vec![
                ("unstamped", None, "a".to_string()),
                ("stamped", at(9), "z".to_string()),
            ]),
            Some("stamped"),
        );

        assert_eq!(pick_current(Vec::<(&str, _, String)>::new()), None);
    }

    /// Superseded and Failed records stay on the cluster beside the current
    /// one; the current one is chosen by phase, then by deploy time.
    #[test]
    fn current_record_skips_records_that_are_not_current() {
        let record = |name: &str, phase: &str, deployed_at: &str| DynamicObject {
            metadata: kube::api::ObjectMeta {
                name: Some(name.into()),
                annotations: Some(
                    [(keys::DEPLOYED_AT.to_string(), deployed_at.to_string())].into(),
                ),
                ..Default::default()
            },
            types: None,
            data: json!({"status": {"phase": phase}}),
        };
        let records = [
            record("c-new-failed", PHASE_FAILED, "2026-09-09T12:00:00Z"),
            record("c-old", PHASE_SUPERSEDED, "2026-09-09T08:00:00Z"),
            record("c-live", PHASE_ACTIVE, "2026-09-09T10:00:00Z"),
            record("c-older", PHASE_SUPERSEDED, "2026-09-09T09:00:00Z"),
        ];
        let current = current_record(&records).and_then(|r| r.metadata.name.as_deref());
        assert_eq!(current, Some("c-live"));
        assert!(current_record(&records[..2]).is_none());
    }
}

#[cfg(test)]
mod orphans_kept_from_tests {
    use super::*;

    /// The status list round-trips through JSON and a malformed entry is
    /// dropped without losing the others.
    #[test]
    fn reads_the_list_and_skips_malformed_entries() {
        let written = vec![KeptOrphanSource {
            activation: "c-v1".into(),
            identity_hash: "abc".into(),
            built_via: Some("/nix/store/abc-activation".into()),
        }];
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "c-v2" },
            "status": {
                "phase": PHASE_ACTIVE,
                (keys::ORPHANS_KEPT_FROM_FIELD): [written[0], { "activation": "no-hash" }],
            },
        }))
        .unwrap();
        assert_eq!(Record::of(&obj).orphans_kept_from, written);
        assert_eq!(
            json!(written[0]),
            json!({"activation": "c-v1", "identityHash": "abc", "builtVia": "/nix/store/abc-activation"})
        );
    }

    /// A consumer's pinned interfaces and a platform's published hashes are
    /// read off `spec`; a malformed entry is left out.
    #[test]
    fn reads_interfaces_and_published_hashes() {
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "c-v1" },
            "spec": {
                "interfaces": {
                    "prod": { "consumer": "acme", "path": "kix-interface/prod.json", "sha256": "aa" },
                    "broken": { "consumer": "acme" },
                },
                "consumers": {
                    "acme": { "interface": "/nix/store/x-kix-interface-acme.json", "sha256": "bb" },
                    "old": { "interface": "/nix/store/y-kix-interface-old.json" },
                },
            },
        }))
        .unwrap();
        let record = Record::of(&obj);
        assert_eq!(
            record.interfaces,
            BTreeMap::from([(
                "prod".to_string(),
                PinnedInterface {
                    consumer: "acme".into(),
                    path: "kix-interface/prod.json".into(),
                    sha256: "aa".into(),
                }
            )])
        );
        assert_eq!(
            record.published_interfaces,
            BTreeMap::from([("acme".to_string(), "bb".to_string())])
        );
    }

    fn source(name: &str) -> KeptOrphanSource {
        KeptOrphanSource {
            activation: name.into(),
            identity_hash: format!("{name}-hash"),
            built_via: None,
        }
    }

    fn names(sources: &[KeptOrphanSource]) -> Vec<&str> {
        sources.iter().map(|s| s.activation.as_str()).collect()
    }

    /// Found sources are written only while an orphan is left; unexamined
    /// ones are written either way, so a `--prune` run on a machine that
    /// cannot read a listed build does not forget it.
    #[test]
    fn unexamined_sources_survive_a_run_that_left_no_orphans() {
        let kept = KeptOrphans {
            found: vec![source("v1")],
            unexamined: vec![source("elsewhere")],
            carry_current: false,
        };
        assert_eq!(names(&kept.recorded(None, true)), vec!["v1", "elsewhere"]);
        assert_eq!(names(&kept.recorded(None, false)), vec!["elsewhere"]);
        assert!(KeptOrphans::default().recorded(None, true).is_empty());
    }

    /// The current record's list is carried only when asked for, deduplicated
    /// against what the plan found.
    #[test]
    fn the_current_list_is_carried_when_the_plan_did_not_read_it() {
        let current = [source("v1"), source("v0")];
        let mut kept = KeptOrphans {
            found: vec![source("v1")],
            unexamined: vec![],
            carry_current: false,
        };
        assert_eq!(names(&kept.recorded(Some(&current), true)), vec!["v1"]);
        kept.carry_current = true;
        assert_eq!(
            names(&kept.recorded(Some(&current), true)),
            vec!["v1", "v0"]
        );
        assert_eq!(
            names(&kept.recorded(Some(&current), false)),
            vec!["v1", "v0"]
        );
        assert!(kept.recorded(None, false).is_empty());
    }
}

#[cfg(test)]
mod retire_plan_tests {
    use super::*;
    use chrono::{Duration, TimeZone, Utc};

    fn now() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap()
    }

    fn rec(name: &str, deployed_at: &str) -> Record {
        Record {
            name: name.into(),
            deployed_at: Some(deployed_at.into()),
            ..Default::default()
        }
    }

    /// Construct a record deployed `days` days before `now()`.
    fn aged(name: &str, days: i64) -> Record {
        rec(name, &(now() - Duration::days(days)).to_rfc3339())
    }

    fn names(v: &[Record]) -> Vec<&str> {
        v.iter().map(|r| r.name.as_str()).collect()
    }

    fn retired(v: &[Retired]) -> Vec<(&str, RetireReason)> {
        v.iter()
            .map(|r| (r.record.name.as_str(), r.reason.clone()))
            .collect()
    }

    fn older_than_30d() -> RetireReason {
        RetireReason::OlderThan(Duration::days(30))
    }

    fn policy(keep_min: usize, keep_max: usize, keep_for_days: Option<i64>) -> RetentionPolicy {
        RetentionPolicy {
            keep_min,
            keep_max,
            keep_for: keep_for_days.map(Duration::days),
            now: now(),
        }
    }

    #[test]
    fn defaults_keep_ten_and_cap_fifty() {
        assert_eq!((DEFAULT_KEEP_MIN, DEFAULT_KEEP_MAX), (10, 50));
    }

    #[test]
    fn the_floor_keeps_the_newest_whatever_their_age() {
        // Twelve records, one per year: all far older than 30 days.
        let input: Vec<_> = (0..12)
            .map(|i| aged(&format!("c-{i:02}"), 365 * (i + 1)))
            .collect();
        let plan = retire_plan(input, &policy(10, 50, Some(30)));
        assert_eq!(plan.kept.len(), 10);
        assert_eq!(plan.kept[0].name, "c-00", "newest first");
        assert_eq!(
            retired(&plan.retire),
            vec![("c-10", older_than_30d()), ("c-11", older_than_30d())]
        );
    }

    #[test]
    fn the_cap_retires_even_recent_records() {
        // Sixty records deployed in the last hour.
        let input: Vec<_> = (0..60)
            .map(|i| {
                rec(
                    &format!("c-{i:02}"),
                    &(now() - Duration::minutes(i)).to_rfc3339(),
                )
            })
            .collect();
        let plan = retire_plan(input, &policy(10, 50, Some(30)));
        assert_eq!(plan.kept.len(), 50);
        assert_eq!(plan.retire.len(), 10);
        assert!(
            plan.retire
                .iter()
                .all(|r| r.reason == RetireReason::BeyondMax(50))
        );
        assert_eq!(plan.retire[0].record.name, "c-50");
    }

    #[test]
    fn the_age_rule_applies_only_between_floor_and_cap() {
        let input = vec![
            aged("new-a", 1),
            aged("new-b", 2),
            aged("old-c", 40),
            aged("old-d", 400),
        ];
        // Floor 1: new-a kept by floor; new-b kept by age; old-c and old-d
        // retired by age.
        let plan = retire_plan(input.clone(), &policy(1, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new-a", "new-b"]);
        assert_eq!(
            retired(&plan.retire),
            vec![("old-c", older_than_30d()), ("old-d", older_than_30d())]
        );
        // Floor 3: old-c now protected by the floor.
        let plan = retire_plan(input, &policy(3, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new-a", "new-b", "old-c"]);
        assert_eq!(retired(&plan.retire), vec![("old-d", older_than_30d())]);
    }

    #[test]
    fn age_rule_off_keeps_everything_up_to_the_cap() {
        let input: Vec<_> = (0..5)
            .map(|i| aged(&format!("c-{i}"), 1000 * (i + 1)))
            .collect();
        let plan = retire_plan(input, &policy(1, 3, None));
        assert_eq!(names(&plan.kept), vec!["c-0", "c-1", "c-2"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("c-3", RetireReason::BeyondMax(3)),
                ("c-4", RetireReason::BeyondMax(3))
            ]
        );
    }

    /// Construct a record superseded out of `Failed` `days` days before `now()`.
    fn failed(name: &str, days: i64) -> Record {
        Record {
            name: name.into(),
            failed_at: Some((now() - Duration::days(days)).to_rfc3339()),
            ..Default::default()
        }
    }

    /// A good deploy 40 days old, then ten failed deploys. The failed ones
    /// take no place in the floor, so the good one, the only rollback
    /// target, is kept; the failed ones are recent and kept by age.
    #[test]
    fn failed_deploys_do_not_push_the_last_rollback_target_out() {
        let mut input = vec![aged("good", 40)];
        input.extend((1..=10).map(|i| failed(&format!("f{i:02}"), i)));
        let plan = retire_plan(input, &policy(DEFAULT_KEEP_MIN, DEFAULT_KEEP_MAX, Some(30)));
        assert!(plan.retire.is_empty(), "{:?}", retired(&plan.retire));
        assert!(names(&plan.kept).contains(&"good"));

        // Past the age rule a failed record is retired, whatever the floor.
        let plan = retire_plan(
            vec![aged("good", 40), failed("old-failure", 35)],
            &policy(DEFAULT_KEEP_MIN, DEFAULT_KEEP_MAX, Some(30)),
        );
        assert_eq!(names(&plan.kept), vec!["good"]);
        assert_eq!(
            retired(&plan.retire),
            vec![("old-failure", older_than_30d())]
        );
    }

    /// With the age rule off, sixty failed deploys are still capped.
    #[test]
    fn the_cap_holds_for_records_that_never_finished() {
        let input: Vec<_> = (1..=60).map(|i| failed(&format!("f{i:02}"), i)).collect();
        let plan = retire_plan(input, &policy(10, 50, None));
        assert_eq!(plan.kept.len(), 50);
        assert_eq!(plan.retire.len(), 10);
        assert!(
            plan.retire
                .iter()
                .all(|r| r.reason == RetireReason::BeyondMax(50))
        );
        assert_eq!(plan.retire[0].record.name, "f51", "newest first");
    }

    /// Over the cap with both kinds, the failed records go, oldest first,
    /// and no rollback target within the floor is retired.
    #[test]
    fn over_the_cap_the_oldest_failed_records_go_first() {
        let mut input: Vec<_> = (1..=3).map(|i| aged(&format!("good{i}"), i * 10)).collect();
        input.extend((1..=4).map(|i| failed(&format!("f{i}"), i)));
        let plan = retire_plan(input, &policy(2, 4, None));
        assert_eq!(names(&plan.kept), vec!["f1", "good1", "good2", "good3"]);
        let gone: Vec<&str> = plan.retire.iter().map(|r| r.record.name.as_str()).collect();
        assert_eq!(gone, vec!["f2", "f3", "f4"]);
    }

    #[test]
    fn unknown_age_sorts_oldest_and_is_retired_by_the_age_rule_only() {
        let input = vec![
            rec("untimed", ""),
            aged("new", 1),
            rec("garbage-time", "yesterday"),
        ];
        let plan = retire_plan(input.clone(), &policy(1, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("garbage-time", RetireReason::UnknownAge),
                ("untimed", RetireReason::UnknownAge)
            ]
        );
        // With the age rule off they are kept like anything else.
        let plan = retire_plan(input, &policy(1, 50, None));
        assert_eq!(plan.kept.len(), 3);
    }

    #[test]
    fn exactly_the_floor_retires_nothing_and_zero_floor_with_zero_cap_retires_all() {
        let input: Vec<_> = (0..3).map(|i| aged(&format!("c-{i}"), i + 1)).collect();
        let plan = retire_plan(input.clone(), &policy(3, 50, Some(30)));
        assert!(plan.retire.is_empty());
        let plan = retire_plan(input, &policy(0, 0, None));
        assert!(plan.kept.is_empty());
        assert_eq!(plan.retire.len(), 3);
    }

    #[test]
    fn cap_below_floor_is_raised_to_the_floor() {
        let input: Vec<_> = (0..5).map(|i| aged(&format!("c-{i}"), i + 1)).collect();
        let plan = retire_plan(input, &policy(4, 2, None));
        assert_eq!(plan.kept.len(), 4);
        assert_eq!(plan.retire.len(), 1);
    }

    #[test]
    fn order_is_by_parsed_time_not_by_string_or_name() {
        // Different offsets and precision for the timestamps, and names
        // that run the other way round.
        let input = || {
            vec![
                rec("z-oldest", "2026-01-01T00:00:00+00:00"),
                rec("m-middle", "2026-05-01T02:00:00+02:00"),
                rec("a-newest", "2026-09-01T00:00:00.123456+00:00"),
            ]
        };
        // Age rule off, cap not reached: everything kept, newest first.
        let plan = retire_plan(input(), &policy(1, 50, None));
        assert_eq!(names(&plan.kept), vec!["a-newest", "m-middle", "z-oldest"]);
        assert!(plan.retire.is_empty());
        // Cap of one: the two older ones go, oldest last.
        let plan = retire_plan(input(), &policy(1, 1, None));
        assert_eq!(names(&plan.kept), vec!["a-newest"]);
        let rest: Vec<&str> = plan.retire.iter().map(|r| r.record.name.as_str()).collect();
        assert_eq!(rest, vec!["m-middle", "z-oldest"]);
    }

    #[test]
    fn ties_break_on_name() {
        let same = "2026-09-01T00:00:00Z";
        let input = vec![rec("b", same), rec("c", same), rec("a", same)];
        let plan = retire_plan(input, &policy(2, 2, None));
        assert_eq!(names(&plan.kept), vec!["a", "b"]);
        assert_eq!(plan.retire[0].record.name, "c");
    }
}

#[cfg(test)]
mod retire_plan_properties {
    use super::*;
    use chrono::{Duration, TimeZone, Utc};
    use proptest::prelude::*;

    /// Construct a test record by kind (`0` for a finished deploy, `1` for a
    /// failed deploy, and `2` for a record with only a creation timestamp) and
    /// age in hours before `now()`.
    fn record(i: usize, kind: u8, hours: i64) -> Record {
        let now = Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap();
        let at = now - Duration::hours(hours);
        let mut record = Record {
            name: format!("r{i:03}"),
            ..Default::default()
        };
        match kind {
            0 => record.deployed_at = Some(at.to_rfc3339()),
            1 => record.failed_at = Some(at.to_rfc3339()),
            _ => record.created_at = Some(at),
        }
        record
    }

    proptest! {
        /// Whatever the mix: every record is kept or retired, once; no more
        /// than the cap is kept; and the floor's newest rollback targets
        /// are kept.
        #[test]
        fn retention_keeps_the_floor_and_the_cap(
            records in prop::collection::vec((0u8..3, 0i64..3000), 0..90),
            keep_min in 0usize..15,
            keep_max in 0usize..60,
            keep_for_days in prop::option::of(0i64..60),
        ) {
            let input: Vec<Record> = records
                .iter()
                .enumerate()
                .map(|(i, (kind, hours))| record(i, *kind, *hours))
                .collect();
            let policy = RetentionPolicy {
                keep_min,
                keep_max,
                keep_for: keep_for_days.map(Duration::days),
                now: Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap(),
            };
            let plan = retire_plan(input.clone(), &policy);

            let mut seen: Vec<&str> = plan
                .kept
                .iter()
                .map(|r| r.name.as_str())
                .chain(plan.retire.iter().map(|r| r.record.name.as_str()))
                .collect();
            seen.sort();
            let mut all: Vec<&str> = input.iter().map(|r| r.name.as_str()).collect();
            all.sort();
            prop_assert_eq!(seen, all);

            prop_assert!(plan.kept.len() <= keep_min.max(keep_max));

            let mut targets: Vec<Record> =
                input.into_iter().filter(Record::was_ever_current).collect();
            sort_newest_first(&mut targets);
            for floor in targets.iter().take(keep_min) {
                prop_assert!(plan.kept.contains(floor), "{} retired", floor.name);
            }
        }
    }
}

#[cfg(test)]
mod listing_tests {
    use super::*;

    /// Records are found by their cluster label, in any phase, and a cluster
    /// label nothing carries finds none.
    #[tokio::test]
    async fn records_exist_finds_records_by_their_cluster_label() {
        let api = crate::cluster::fake_api::FakeApi::new([serde_json::json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": {
                "name": "rec-a1",
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): "test-harbor",
                },
            },
            "status": { "phase": PHASE_SUPERSEDED },
        })]);
        let client = api.client();
        assert!(records_exist(&client, "test-harbor").await.unwrap());
        assert!(!records_exist(&client, "harbor").await.unwrap());
    }

    /// A record superseded out of `Failed` still carries its failure. It is
    /// listed, so `kix gc` can retire it by when it failed, and it is not a
    /// rollback target. A record that finished a deploy and then carries a
    /// failure, as an interrupted rollback to it leaves, is listed and is a
    /// rollback target.
    #[tokio::test]
    async fn a_record_superseded_out_of_failed_is_listed_for_retention() {
        let record = |name: &str, status: serde_json::Value, deployed_at: Option<&str>| {
            let mut annotations = serde_json::Map::new();
            if let Some(at) = deployed_at {
                annotations.insert(keys::DEPLOYED_AT.into(), json!(at));
            }
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": crate::manifest::lifecycle::RECORD_KIND,
                "metadata": {
                    "name": name,
                    "labels": {
                        "app.kubernetes.io/managed-by": "kix",
                        (keys::CLUSTER_LABEL): "c",
                    },
                    "annotations": annotations,
                },
                "status": status,
            })
        };
        let api = crate::cluster::fake_api::FakeApi::new([
            record(
                "c-ran",
                json!({ "phase": PHASE_SUPERSEDED }),
                Some("2026-09-01T00:00:00Z"),
            ),
            record(
                "c-failed",
                json!({
                    "phase": PHASE_SUPERSEDED,
                    "failure": { "reason": "cancelled", "at": "2026-08-01T00:00:00Z" },
                }),
                None,
            ),
            record(
                "c-interrupted",
                json!({
                    "phase": PHASE_SUPERSEDED,
                    "failure": { "reason": "cancelled", "at": "2026-09-20T00:00:00Z" },
                }),
                Some("2026-09-15T00:00:00Z"),
            ),
        ]);
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let listed = records.superseded("c").await.unwrap();
        let names: Vec<&str> = listed.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["c-interrupted", "c-ran", "c-failed"]);

        // Past the floor and older than the age rule, it is retired by when
        // it failed, not kept forever.
        let now = chrono::DateTime::parse_from_rfc3339("2026-10-01T00:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        let policy = RetentionPolicy {
            keep_min: 1,
            keep_max: 50,
            keep_for: Some(chrono::Duration::days(30)),
            now,
        };
        let plan = retire_plan(listed, &policy);
        assert_eq!(plan.retire.len(), 1);
        assert_eq!(plan.retire[0].record.name, "c-failed");
        assert_eq!(
            plan.retire[0].reason,
            RetireReason::OlderThan(chrono::Duration::days(30))
        );
        let targets = records.rollback_targets("c").await.unwrap();
        let names: Vec<&str> = targets.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["c-interrupted", "c-ran"]);
    }

    /// A record constructed in memory without server metadata has an empty
    /// `uid` and `resourceVersion`, which `retire` still sends as
    /// preconditions so the live record of that name on the cluster is not
    /// deleted.
    #[tokio::test]
    async fn a_record_not_read_from_the_cluster_is_not_retired() {
        let api = crate::cluster::fake_api::FakeApi::new([json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": { "name": "c-made-up" },
            "status": { "phase": PHASE_SUPERSEDED },
        })]);
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let made_up = Record {
            name: "c-made-up".into(),
            ..Default::default()
        };
        let err = records.retire(&made_up).await.unwrap_err();
        assert!(
            crate::cluster::errors::classify(&err.source)
                == crate::cluster::errors::FailureClass::Conflict,
            "{err}"
        );
        assert_eq!(
            api.names(crate::manifest::lifecycle::RECORD_KIND),
            vec!["c-made-up"]
        );
    }

    /// A record that changed after it was read is not deleted, and the
    /// error says which operation on which record failed.
    #[tokio::test]
    async fn a_failed_retire_names_the_delete_and_the_record() {
        let api = crate::cluster::fake_api::FakeApi::new([json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": { "name": "c-old" },
            "status": { "phase": PHASE_SUPERSEDED },
        })]);
        let client = api.client();
        let discovery = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let read = records.get("c-old").await.unwrap().unwrap();
        api.after_get("c-old", |o| o["status"]["phase"] = json!(PHASE_ACTIVE));
        records.get("c-old").await.unwrap();
        let err = records.retire(&read).await.unwrap_err().to_string();
        assert!(
            err.starts_with("failed to delete activation 'c-old': "),
            "{err}"
        );
        assert_eq!(
            api.names(crate::manifest::lifecycle::RECORD_KIND),
            vec!["c-old"]
        );
    }

    fn discovery_with(groups: &[&str]) -> Vec<(ApiResource, Scope)> {
        groups
            .iter()
            .map(|group| {
                let gvk = kube::api::GroupVersionKind::gvk(
                    group,
                    "v1alpha1",
                    crate::manifest::lifecycle::RECORD_KIND,
                );
                (
                    ApiResource::from_gvk_with_plural(&gvk, "activations"),
                    Scope::Cluster,
                )
            })
            .collect()
    }

    /// Records open only past the gate: a cluster whose records sit under a
    /// retired group, alone or beside the current one, is refused. Without
    /// the kind there are no records, which is not an error until a command
    /// needs them.
    #[tokio::test]
    async fn records_open_only_past_the_domain_gate() {
        let client = crate::cluster::fake_api::FakeApi::new([]).client();
        let retired = crate::legacy_domain::DOMAINS[0];

        let opened = Records::open(&client, &discovery_with(&[keys::GROUP])).unwrap();
        assert_eq!(
            opened.records().unwrap().watch_resource().group,
            keys::GROUP
        );

        assert!(matches!(
            Records::open(&client, &discovery_with(&[retired])),
            Err(LegacyDomainError::NotMigrated { .. })
        ));
        assert!(matches!(
            Records::open(&client, &discovery_with(&[retired, keys::GROUP])),
            Err(LegacyDomainError::BothGroups { .. })
        ));

        assert!(Records::open(&client, &[]).unwrap().records().is_none());
        assert!(matches!(
            Records::open_installed(&client, &[]),
            Err(OpenError::NotInstalled)
        ));
        assert!(matches!(
            Records::open_installed(&client, &discovery_with(&[retired])),
            Err(OpenError::Domain(_))
        ));
    }
}
