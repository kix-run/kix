//! Activation CR lifecycle management.
//!
//! The Activation CR is the cluster-level record of "what is deployed."
//! This module manages the state machine:
//!
//! A deploy creates a Deploying record before applying resources. Completion
//! moves it to Active or Failed. A later deploy supersedes the current record;
//! garbage collection removes superseded records after their resources.
//!
//! The record is created at the start of the deploy, not at the end. It is
//! also a node of the plan, and by construction the last one: its spec lists
//! every PackageInstance, so its identity hash is the root of the closure's
//! Merkle tree. Creating it early and re-asserting it in the last wave keeps
//! that property while making a deploy that dies mid-wave leave a truthful
//! record of what it was attempting. Without it the next deploy has no way to
//! know that anything was applied at all (kixpkgs#82).
//!
//! [`Records`] is the one way to read or write the records. Opening it runs
//! the legacy-domain gate, so no command can reach a record on a cluster
//! whose records still sit under a retired API group. A record comes back
//! as a [`Record`], the fields Kix reads off it.

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

/// The apiserver failed `op` on the record `name`, or on the list of
/// records when `name` is `None`.
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
    /// A failed list of the records.
    fn list(source: kube::Error) -> Self {
        RecordsError {
            op: "list",
            name: None,
            source,
        }
    }

    /// Whether the apiserver refused the request with HTTP 403.
    pub fn forbidden(&self) -> bool {
        matches!(
            crate::cluster::errors::classify(&self.source),
            crate::cluster::errors::FailureClass::Forbidden
        )
    }

    /// A failed `op` on the record `name`.
    fn on(op: &'static str, name: &str) -> impl FnOnce(kube::Error) -> Self {
        let name = name.to_string();
        move |source| RecordsError {
            op,
            name: Some(name),
            source,
        }
    }
}

/// Why [`Records::open_installed`] has no records to open.
#[derive(Error, Debug)]
pub enum OpenError {
    #[error(transparent)]
    Domain(#[from] LegacyDomainError),

    #[error(
        "the Kix Activation resource type is not installed on this cluster. Check the Kubernetes context and deploy the Kix CRDs before retrying."
    )]
    NotInstalled,
}

/// One Activation record, read: the fields Kix reads off it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Record {
    pub name: String,
    /// `status.phase`, or "" when the record has none yet.
    pub phase: String,
    /// The identity-hash annotation value. Without it the record cannot be
    /// resolved to a closure.
    pub identity_hash: Option<String>,
    /// Store path of the activation result dir (contains kix-packages.json).
    pub built_via: Option<String>,
    /// `kix.run/deployed-at`. Only a finalize writes it, so a record has it
    /// exactly when a deploy of its closure ran to completion.
    pub deployed_at: Option<String>,
    /// `status.previousActivation`, the record this one superseded. Lets the
    /// history walk reconstruct the deploy chain for `kix rollback --list`.
    pub previous_activation: Option<String>,
    /// `status.failure.reason`, for the message the next deploy prints.
    pub failure_reason: Option<String>,
    /// `status.failure.at`, RFC 3339. Also the retention sort key once the
    /// record is superseded, since it has no `deployed-at`.
    pub failed_at: Option<String>,
    /// `metadata.creationTimestamp`. The only age a Deploying or Queued
    /// record has.
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
    /// True when `spec.source` is set, which the operator writes and the CLI
    /// does not. The discriminator for "who is driving this deploy".
    pub operator_driven: bool,
    /// `status.orphansKeptFrom`: builds whose orphans are still on the cluster.
    pub orphans_kept_from: Vec<KeptOrphanSource>,
    /// `status.waves` and `status.totalWaves`: deploy progress, for a
    /// command that waits on the operator.
    pub waves: Vec<WaveRecord>,
    pub total_waves: usize,
    /// Whether the record is being deleted (`metadata.deletionTimestamp`).
    pub deleting: bool,
    /// `metadata.uid` and `metadata.resourceVersion` as the cluster served
    /// the record, which [`Records::retire`] makes its delete conditional
    /// on. Empty for a record built by hand.
    pub uid: String,
    pub resource_version: String,
    /// `spec.interfaces`: the interface each platform gave this cluster as
    /// its consumer, as the build pinned it, by platform name.
    pub interfaces: BTreeMap<String, PinnedInterface>,
    /// `spec.consumers.<consumer>.sha256`: the hash of the interface this
    /// cluster publishes to each of its consumers, by consumer name.
    pub published_interfaces: BTreeMap<String, String>,
}

/// A platform's interface file as a consumer's build loaded it.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct PinnedInterface {
    /// The consumer name the platform gave this cluster.
    pub consumer: String,
    /// The file, relative to the flake root.
    pub path: String,
    /// The hash of the file as the platform's build writes it.
    pub sha256: String,
}

impl Record {
    /// Read the fields of an Activation object.
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

    /// Whether this record was ever the cluster's state, and so whether it is
    /// a legitimate rollback target.
    ///
    /// `kix.run/deployed-at` is written by [`Records::finalize_deploy`] and
    /// nothing else, so it is present exactly when a deploy of this closure
    /// ran to completion. A record superseded out of `Failed` has none, and
    /// applying it would put the cluster into a state it has never been in.
    ///
    /// Deliberately not "does it carry a `status.failure`". A rollback
    /// re-asserts its target's record and marks it Deploying, so a rollback
    /// that is then interrupted leaves a failure on a record that really was
    /// current once, and that record is still a valid target.
    fn was_ever_current(&self) -> bool {
        self.deployed_at
            .as_deref()
            .is_some_and(|at| !at.trim().is_empty())
    }

    /// When the record last mattered, for retention ordering.
    ///
    /// `kix.run/deployed-at` when the record finished a deploy. A record that
    /// was superseded out of `Failed` never did, so it falls back to when it
    /// failed, then to when it was created. Without the fallback every such
    /// record sorts oldest and is retired as `UnknownAge` on the first
    /// `kix gc`, which loses the history of what went wrong just when it is
    /// most wanted.
    fn retention_time(&self) -> Option<chrono::DateTime<chrono::Utc>> {
        [&self.deployed_at, &self.failed_at]
            .into_iter()
            .find_map(|at| at.as_deref().and_then(parse_time))
            .or(self.created_at)
    }
}

/// The object at `pointer`, each entry read by `read`. An entry `read`
/// cannot read is left out.
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

/// A build whose orphans a deploy reported and did not delete.
///
/// A deploy finds orphans by comparing its build with the builds it replaces.
/// When it keeps them (warn-only, `--prune-mode=no`, or a failed delete), the
/// record it finalizes lists those builds under `status.orphansKeptFrom`, so
/// the next `kix deploy --prune`, `kix rollback --prune` or soft `kix gc` can
/// compare against them again. Without the list, the new record becomes the
/// only baseline and the orphans are invisible to everything but
/// `kix gc --hard`.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeptOrphanSource {
    /// The Activation record the build belonged to, for people reading the
    /// status. The record may since have been retired.
    pub activation: String,
    /// The build's `kix.run/identity-hash`, resolved through the local
    /// activation cache when `built_via` is not in this machine's store.
    pub identity_hash: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub built_via: Option<String>,
}

/// What a finalizing run writes to `status.orphansKeptFrom`.
#[derive(Debug, Clone, Default)]
pub(crate) struct KeptOrphans {
    /// Builds this run's plan found orphans in. Recorded only when the run
    /// leaves an orphan on the cluster: a run that deleted them all has
    /// nothing left to describe.
    pub found: Vec<KeptOrphanSource>,
    /// Listed sources the plan could not examine because their build is not
    /// in this machine's store. Recorded whatever the run did, since it could
    /// not have deleted their orphans.
    pub unexamined: Vec<KeptOrphanSource>,
    /// Also carry forward the list on the record current at finalize, as
    /// unexamined sources. For a plan that never read that record
    /// (`kix deploy --current-activation`).
    pub carry_current: bool,
}

impl KeptOrphans {
    /// The list to write, given the current record's list (read at finalize)
    /// and whether the run left a prunable orphan in place. Deduplicated by
    /// identity hash, first entry wins.
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

/// Read `status.orphansKeptFrom`. A malformed entry is skipped with a debug
/// log: the list only widens a prune, so losing an entry keeps an orphan, it
/// never deletes anything extra.
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

/// The Activation `ApiResource` under the current group, if discovery has
/// it. Not the gate: [`Records::open`] is.
fn served_resource(discovery: &[(ApiResource, Scope)]) -> Option<&ApiResource> {
    discovery
        .iter()
        .find(|(ar, _)| {
            crate::manifest::lifecycle::is_record_kind(&ar.kind) && ar.group == keys::GROUP
        })
        .map(|(ar, _)| ar)
}

/// Whether any Activation record carries `cluster` in its `kix.run/cluster`
/// label, in any phase. Needs no discovery: the record kind is Kix's own. A
/// cluster without Kix's CRD has no records, so a 404 is `false`.
///
/// Outside [`Records`] and its gate: it only decides how a command-line
/// argument is read, and a cluster that has not migrated has no records
/// under the current group to find.
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

/// The label selector of every record a Kix cluster owns.
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

/// A record's `kix.run/deployed-at`, parsed, or None when it is absent or
/// malformed. A record that never finished a deploy has none.
fn parsed_deployed_at(item: &DynamicObject) -> Option<chrono::DateTime<chrono::Utc>> {
    item.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::DEPLOYED_AT))
        .and_then(parse_time)
}

/// Which of several current records is *the* current one.
///
/// A cluster should only ever hold one Active or Degraded record, but nothing
/// enforces that: a partial supersede, two deploys racing, or an externally edited
/// status can all leave two. Picking whichever the apiserver listed first
/// makes the plan depend on list order, so the newest `deployed-at` wins and
/// the name breaks ties. Split out from [`current_record`] so it can be
/// tested without objects.
fn pick_current<T>(
    mut candidates: Vec<(T, Option<chrono::DateTime<chrono::Utc>>, String)>,
) -> Option<T> {
    // Newest first; a record with no usable timestamp sorts oldest.
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
    candidates.into_iter().next().map(|(value, _, _)| value)
}

/// The current record among `records`, chosen as [`Records::active`]
/// chooses: phase Active or Degraded, the most recently deployed first.
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

/// Whether a record in this phase describes what the cluster runs.
fn is_current_phase(phase: &str) -> bool {
    phase == PHASE_ACTIVE || phase == PHASE_DEGRADED
}

/// Read `status.phase` from an activation, or "" when it has none yet.
fn read_phase(activation: &DynamicObject) -> &str {
    activation
        .data
        .pointer("/status/phase")
        .and_then(|v| v.as_str())
        .unwrap_or("")
}

/// The Activation records of one Kubernetes cluster: Kix's deploy records.
///
/// Made only by [`Records::open`], which refuses a cluster whose records
/// still sit under a retired API group, so holding one means the
/// legacy-domain gate has run. Reads take the Kix cluster whose records
/// they want, by its `kix.run/cluster` label.
#[derive(Clone)]
pub struct Records {
    client: Client,
    resource: ApiResource,
}

/// What [`Records::open`] found past the domain gate: the records, or that
/// the cluster does not serve the Activation kind, which also means it has
/// no records. Only `open` makes one from discovery, so a caller holding
/// one knows the gate ran, and "no records" cannot be mistaken for a gate
/// that refused.
#[derive(Clone)]
pub struct OpenedRecords(Option<Records>);

impl OpenedRecords {
    /// The records, or `None` when the cluster serves no Activation kind.
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
    /// The records `discovery` shows, past the domain gate.
    ///
    /// The gate. A cluster whose records still sit under a retired group is
    /// refused here, so every command that reads or writes a record is
    /// covered: deploy, plan, rollback, gc, health, status, compliance and
    /// the operator.
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

    /// [`Records::open`] for a command that needs the records: a cluster
    /// without the Activation kind is an error.
    pub fn open_installed(
        client: &Client,
        discovery: &[(ApiResource, Scope)],
    ) -> Result<Records, OpenError> {
        Self::open(client, discovery)?
            .into_records()
            .ok_or(OpenError::NotInstalled)
    }

    /// The Activation kind as the cluster serves it, which the operator's
    /// reflector and controller are keyed by.
    pub fn watch_resource(&self) -> &ApiResource {
        &self.resource
    }

    /// A watch of every record, for the operator.
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

    /// Every record `cluster` owns, whatever its phase.
    async fn list_of(&self, cluster: &str) -> Result<Vec<DynamicObject>, RecordsError> {
        let lp = ListParams::default().labels(&cluster_selector(cluster));
        Ok(self
            .api()
            .list(&lp)
            .await
            .map_err(RecordsError::list)?
            .items)
    }

    /// `cluster`'s records in `phase`.
    async fn in_phase(&self, cluster: &str, phase: &str) -> Result<Vec<Record>, RecordsError> {
        Ok(self
            .list_of(cluster)
            .await?
            .iter()
            .filter(|item| read_phase(item) == phase)
            .map(Record::of)
            .collect())
    }

    /// The current record of a given cluster.
    ///
    /// Returns None if no current activation exists (first deploy).
    /// Matches `status.phase` against `Active` or `Degraded`, both of which
    /// represent "the cluster's current state" for diffing purposes. A Degraded
    /// activation is one whose deploy completed with some resource failures; it is
    /// still the most recent description of intended state and the next deploy
    /// should diff against it instead of treating the cluster as empty.
    ///
    /// `Failed` is excluded because it describes a deploy that
    /// stopped part way, so it is not what the cluster is running, and diffing
    /// against it would read every object only the Active closure has as an
    /// orphan. `Deploying` is not matched either: it is in flight.
    pub async fn active(&self, cluster: &str) -> Result<Option<Record>, RecordsError> {
        let items = self.list_of(cluster).await?;
        Ok(current_of(&items, cluster).map(Record::of))
    }

    /// Every Failed record for a cluster, oldest first.
    ///
    /// Oldest first because that is the order a deploy consumed them in, so a
    /// stack of them folds into the baseline the same way it accumulated.
    pub async fn failed(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.in_phase(cluster, PHASE_FAILED).await?;
        records.sort_by(|a, b| {
            a.failed_at
                .cmp(&b.failed_at)
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(records)
    }

    /// Every Deploying record for a cluster, oldest first: deploys still in
    /// flight, or that were when they last wrote.
    pub async fn deploying(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.in_phase(cluster, PHASE_DEPLOYING).await?;
        records.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(records)
    }

    /// Queued records for a cluster, newest first.
    ///
    /// The operator's queue, so only records it owns: `spec.source` is what it
    /// writes when it adopts a deploy, and the CLI never does. Without that
    /// filter a CLI record, which is phase-less for the round trip between being
    /// created and being marked Deploying, reads as a queued deploy and the
    /// operator supersedes either it or itself over the difference.
    pub async fn queued(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        // An empty phase is a new record without status yet, which reads as
        // Queued. Only the operator's own, as above: a CLI record looks
        // exactly like this for a round trip, and permanently if the process
        // is killed in between.
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

    /// Every Superseded record for a cluster, most recent first by
    /// `Record::retention_time`.
    ///
    /// Every Superseded record, including ones that never finished a deploy,
    /// so that `kix gc` can retire them: a listing that hid them would leave a
    /// permanent record for every failed deploy, each keeping a hash alive in
    /// the `kix.run/activations` annotation of everything it stamped. A caller
    /// choosing a rollback target wants [`Records::rollback_targets`].
    pub async fn superseded(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.in_phase(cluster, PHASE_SUPERSEDED).await?;
        sort_newest_first(&mut records);
        Ok(records)
    }

    /// The Superseded records that really were the cluster's state
    /// (`Record::was_ever_current`), most recent first. A deploy that
    /// stopped part way is Superseded once a later plan folded its leftovers
    /// in, but it was never running, so rolling back to it would apply a state
    /// the cluster has never been in.
    pub async fn rollback_targets(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records = self.superseded(cluster).await?;
        records.retain(Record::was_ever_current);
        Ok(records)
    }

    /// The deploy receipt on a cluster's current record.
    ///
    /// This is the read half of the record. A deploy writes provenance into the
    /// Activation's status subresource; this reads it back, so a question like
    /// "what is running here and where did it come from" can be answered by
    /// anyone who can reach the cluster, without the machine that built it and
    /// without a rebuild.
    ///
    /// `Ok(None)` when there is no current record, or it predates receipts.
    pub async fn receipt(&self, cluster: &str) -> Result<Option<Value>, RecordsError> {
        let items = self.list_of(cluster).await?;
        Ok(current_of(&items, cluster).and_then(|current| {
            current
                .data
                .pointer(&format!("/status/{}", keys::RECEIPT_FIELD))
                .cloned()
        }))
    }

    /// The identity hash of the record named `name`, or `None` when no such
    /// record exists. `Some("")` for a record without the annotation.
    ///
    /// A record's name carries only the first 12 characters of the build's
    /// hash, so two builds can share a name. Applying one over the other would
    /// rewrite the history of what was deployed.
    pub async fn identity_hash_of(&self, name: &str) -> Result<Option<String>, RecordsError> {
        let item = self
            .api()
            .get_opt(name)
            .await
            .map_err(RecordsError::on("get", name))?;
        // The exact key, without the retired spelling `Record::of` falls
        // back to: a record this check passes is one this build will
        // overwrite, so it must carry the current identity stamp.
        Ok(item.map(|o| {
            o.metadata
                .annotations
                .as_ref()
                .and_then(|a| a.get(keys::IDENTITY_HASH))
                .cloned()
                .unwrap_or_default()
        }))
    }

    /// Identity hashes of every Activation CR on the cluster, across all clusters
    /// and all phases.
    ///
    /// This is the authority for pruning `kix.run/activations`: a hash in that set
    /// that names no Activation here is a reference to something that no longer
    /// exists. Do not filter by cluster label because one resource can be
    /// referenced by activations of more than one cluster, and pruning another
    /// cluster's live reference would be worse than keeping a dead one.
    ///
    /// Returns `None` when the set cannot be established (list failed).
    /// Callers must treat `None` as "do not prune" rather than as an empty
    /// set.
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

    /// Every record on the cluster, of every Kix cluster and phase, as
    /// objects, for [`super::tenancy::read`].
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

    /// Delete a record only if it is still the object that was read (same
    /// uid and resourceVersion). A status change since the listing, such as
    /// a rollback making it Active again, bumps resourceVersion and the
    /// apiserver refuses with 409, so nothing that changed underneath the
    /// plan is deleted.
    ///
    /// The preconditions are sent even when empty, as for a record built by
    /// hand: the apiserver compares an empty uid like any other, and refuses.
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

    /// Remove `status.orphansKeptFrom` from a record, once something has
    /// deleted the orphans it describes.
    pub async fn clear_orphans_kept_from(&self, name: &str) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": { keys::ORPHANS_KEPT_FROM_FIELD: Value::Null } }),
        )
        .await
    }

    /// List one record, to check that this client may read them.
    pub async fn reachable(&self) -> Result<(), RecordsError> {
        self.api()
            .list(&ListParams::default().limit(1))
            .await
            .map_err(RecordsError::list)?;
        Ok(())
    }

    /// The record named `name`, or `None` when there is no such record.
    pub async fn get(&self, name: &str) -> Result<Option<Record>, RecordsError> {
        let item = self
            .api()
            .get_opt(name)
            .await
            .map_err(RecordsError::on("get", name))?;
        Ok(item.as_ref().map(Record::of))
    }

    /// Create or update a record for the operator to deploy: the build at
    /// `source_path`, of Kix cluster `cluster`.
    ///
    /// The record carries no phase. The operator treats it as Queued and
    /// advances it through Deploying to Active.
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

    /// Write a deploy receipt to a record's status. A merge patch on the
    /// status subresource leaves everything else alone, so it does not
    /// matter whether the operator has already started on the record.
    pub async fn write_receipt(&self, name: &str, receipt: &Value) -> Result<(), RecordsError> {
        self.patch_status(name, &json!({ "status": { keys::RECEIPT_FIELD: receipt } }))
            .await
    }

    /// Set a record's `metadata.finalizers`, for the operator's own.
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

    /// Supersede the old activation and finalize the new one as Active or
    /// Degraded. The new record stores its predecessor, deployment timestamp,
    /// cluster label, and receipt. Consumed Failed records are also superseded.
    /// Degraded remains current so the next deploy can compute its diff.
    ///
    /// `orphans_kept_from` replaces the record's `status.orphansKeptFrom`; an
    /// empty slice removes the field.
    // The parameters have distinct types and this function has one call site.
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

        // Supersede the old activation.
        if let Some(old) = old_activation {
            self.supersede(&old.name).await?;
        }

        // Supersede Failed records folded into this plan. Their leftovers have
        // now been re-applied or pruned, so they describe nothing outstanding
        // and belong in history with everything else.
        //
        // Skipping the record being finalized matters: retrying the same
        // closure that failed reuses its name, and superseding it here would
        // immediately undo the Active phase set below.
        //
        // Best-effort. A record that will not supersede is cosmetic, and
        // failing the deploy over it after every resource has landed would be
        // a worse trade.
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

        // Lifecycle annotations on the new record, by merge patch, so the
        // identity hash and the other annotations the apply set stay.
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

        // Set the final phase and predecessor link.
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
        // A same-name redeploy finalizes a record that may already carry a list,
        // so an empty one is written as null to remove it.
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

    /// Read one record's `status.phase`, or "" when it has none yet.
    async fn phase_of(&self, name: &str) -> Result<String, RecordsError> {
        let item = self
            .api()
            .get(name)
            .await
            .map_err(RecordsError::on("get", name))?;
        Ok(read_phase(&item).to_string())
    }

    /// Set the Activation phase to Deploying and initialize wave status.
    ///
    /// Called at the start of the apply loop, after the record itself has been
    /// created. Sets `status.phase = Deploying` and `status.totalWaves = n`,
    /// unless the record is the current one being re-deployed (see
    /// [`phase_on_begin`]), in which case only the wave counters are reset.
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
        // A retry clears the previous attempt's verdict, so a record that goes on
        // to succeed does not keep a stale failure hanging off its status.
        status.insert("failure".to_string(), Value::Null);

        self.patch_status(activation_name, &json!({ "status": status }))
            .await
    }

    /// Mark a record Failed because its deploy stopped before finalizing.
    ///
    /// Best-effort by nature: the run is already ending, and a cluster that will
    /// not take this patch is one the next deploy has to cope with anyway. It is
    /// conditional on the record still being `Deploying`, so a re-deploy of the
    /// current closure that aborts leaves the Active record alone.
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
    /// Patches `status.waves` with the full accumulated list. The caller
    /// tracks wave records in memory and passes the complete list each time,
    /// eliminating the need for a GET-before-PATCH round-trip.
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

/// The current record among `cluster`'s `items`, with a warning when there
/// is more than one to choose from.
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

/// Most recent first by `Record::retention_time`, ties broken on name.
fn sort_newest_first(records: &mut [Record]) {
    records.sort_by(|a, b| {
        b.retention_time()
            .cmp(&a.retention_time())
            .then_with(|| a.name.cmp(&b.name))
    });
}

/// Defaults for [`RetentionPolicy`]: always keep the 10 newest records and
/// never more than 50. `kix gc --keep-for` adds the age rule, 30 days by
/// default. Helm 3 and Argo CD keep 10 by default; the cap and the age rule
/// exist because each record still on the cluster keeps one hash alive in
/// `kix.run/activations` on every managed resource, and that annotation is
/// capped at 256 KiB.
pub const DEFAULT_KEEP_MIN: usize = 10;
pub const DEFAULT_KEEP_MAX: usize = 50;

/// How many Superseded records to keep, by count and by age.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetentionPolicy {
    /// Always keep this many of the newest, whatever their age.
    pub keep_min: usize,
    /// Never keep more than this many.
    pub keep_max: usize,
    /// Beyond `keep_min`, retire records older than this. `None` disables
    /// the age rule.
    pub keep_for: Option<chrono::Duration>,
    /// The clock the age rule uses. Injected so plans are testable.
    pub now: chrono::DateTime<chrono::Utc>,
}

/// Why a record is retired.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetireReason {
    /// Past the cap of `keep_max` records kept: a rollback target past the
    /// `keep_max` newest, or a record of a deploy that never finished,
    /// oldest first, once everything kept would exceed the cap.
    BeyondMax(usize),
    /// Older than `keep_for`: a rollback target past the `keep_min` newest,
    /// or any record of a deploy that never finished, which the floor does
    /// not cover.
    OlderThan(chrono::Duration),
    /// No usable timestamp at all, so its age is unknown and it sorts oldest.
    /// A record that never finished a deploy still has `status.failure.at` or
    /// a creation timestamp to go on (see `Record::retention_time`), so
    /// reaching this means every one of those was missing or malformed.
    UnknownAge,
}

/// A record the plan retires, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retired {
    pub record: Record,
    pub reason: RetireReason,
}

/// Which Superseded records to keep and which to retire.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Retirement {
    /// Records that stay, newest first. Those that were ever current are
    /// the rollback targets.
    pub kept: Vec<Record>,
    /// Records to delete, newest first, each with its reason.
    pub retire: Vec<Retired>,
}

/// Split a cluster's Superseded records into kept and retired under a
/// [`RetentionPolicy`] (`kix gc --keep`, kixpkgs#59 follow-up).
///
/// Newest first by `Record::retention_time` (parsed, so offsets and
/// precision do not matter); a record with no usable timestamp is treated as
/// the oldest. Ties break on name so the plan is deterministic.
/// Then, among the records that were ever current (rollback targets): the
/// first `keep_min` are kept whatever their age; past `keep_max` everything
/// is retired; in between, a record is retired when the age rule is on and
/// it is older than `keep_for` (or its age is unknown). A record that never
/// finished a deploy is judged by the age rule, and takes no place in the
/// floor, so a run of failed deploys cannot push the last rollback target
/// out. The cap still holds for everything kept: past `keep_max`, the
/// oldest records that never finished a deploy are retired. The Active
/// record is never in the input.
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
    // The cap holds for the whole list: each record kept keeps a hash on
    // every managed object. The records that were ever current are within
    // it already, so the excess is records that never finished a deploy,
    // and the oldest of them go first.
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

// ---------------------------------------------------------------------------
// Wave progress persistence
// ---------------------------------------------------------------------------

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

/// The phase a record should move to when a deploy begins, or None to leave
/// it where it is.
///
/// Re-deploying the closure that is already current hits this with an `Active`
/// record, and that record must keep its phase. Demoting it to `Deploying`
/// means a run that then dies leaves the cluster with no current record at
/// all, and the next deploy plans as a first deploy: no orphans, no repairs.
/// Everything else is either not current or already in flight, so it is safe
/// to mark.
fn phase_on_begin(current: &str) -> Option<&'static str> {
    match current {
        PHASE_ACTIVE | PHASE_DEGRADED => None,
        _ => Some(PHASE_DEPLOYING),
    }
}

/// The phase a record should move to when a deploy stops without finalizing,
/// or None to leave it alone.
///
/// Only a record this run put into `Deploying` is ours to fail. One left
/// `Active` by [`phase_on_begin`] is still the truthful current state and must
/// stay that way.
fn phase_on_abort(current: &str) -> Option<&'static str> {
    match current {
        PHASE_DEPLOYING => Some(PHASE_FAILED),
        // No phase at all means the record was created and the run died
        // before it could be marked, which only this run can have done: the
        // create and the mark are two round trips inside `begin`. Leaving it
        // blank would make it invisible to every reader, which is the hole
        // this whole change exists to close.
        //
        // `Queued` is excluded on purpose. That is somebody's stated intent,
        // usually the operator's, and not ours to overwrite.
        "" => Some(PHASE_FAILED),
        _ => None,
    }
}

/// Data for recording a single wave's result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaveRecord {
    pub wave_index: usize,
    pub status: WaveStatus,
    pub resource_count: usize,
    pub applied: usize,
    pub failed: usize,
}

impl WaveRecord {
    /// One entry of `status.waves`, as [`Records::record_waves`] writes it.
    /// A missing number reads as 0 and a missing status as Pending.
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

    /// A record deployed `days` days before `now()`.
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

    /// A record superseded out of `Failed`, `days` days before `now()`.
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

    /// A record by kind (0: a finished deploy, 1: a failed one, 2: one with
    /// only a creation time) and age in hours before `now()`.
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

    /// A record built by hand carries an empty uid and resourceVersion,
    /// which the delete still sends as preconditions, so the record of that
    /// name on the cluster is not deleted.
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
