//! Activation CR lifecycle management.
//!
//! The Activation CR is the cluster-level record of what is deployed. This
//! module manages its state machine:
//!
//! A deploy creates a `Deploying` record before applying resources. Completion
//! moves it to `Active` or `Degraded`, a deploy that stops moves it to
//! `Failed`, and a deploy with `--only` that applies everything it selected
//! moves it to `Partial`. A later deploy supersedes the current record, and
//! garbage collection removes superseded records after their resources are
//! pruned.
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

pub mod features;
mod record;
mod retention;

#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashSet};

use crate::eval::package_index::{self, RecordPackageIndex};
use crate::legacy_domain::{self, LegacyDomainError};
use crate::manifest::keys;
use crate::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_PARTIAL, PHASE_QUEUED,
    PHASE_SUPERSEDED,
};
use kube::{
    api::{Api, DeleteParams, DynamicObject, ListParams, Patch, PatchParams, Preconditions},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::{Value, json};
use thiserror::Error;

pub use record::{
    FailedRequest, KeptOrphanSource, PartialDeploy, PinnedInterface, Record, WaveRecord,
    WaveStatus, current_record, new_request,
};
pub use retention::{
    DEFAULT_KEEP_MAX, DEFAULT_KEEP_MIN, RetentionPolicy, RetireReason, Retired, Retirement,
    retire_plan,
};

pub(crate) use record::KeptOrphans;

use record::{
    FAILED_ATTEMPTS_FIELD, FAILED_REQUEST_FIELD, FINISHED_REQUEST_FIELD, PARTIAL_FIELD,
    REQUEST_FIELD, STARTED_REQUEST_FIELD, is_current_phase, parse_time, phase_on_abort,
    phase_on_begin, phase_on_end_partial, pick_current, read_phase, sort_newest_first,
};

/// Return whether `phase` makes a record current (`Active` or `Degraded`).
pub(crate) fn phase_is_current(phase: &str) -> bool {
    is_current_phase(phase)
}

/// Return the current record among `records`, chosen as [`Records::active`]
/// chooses it: the most recently deployed `Active` or `Degraded` one.
pub(crate) fn current_among(records: &[Record]) -> Option<&Record> {
    pick_current(
        records
            .iter()
            .filter(|r| is_current_phase(&r.phase))
            .map(|r| {
                (
                    r,
                    r.deployed_at.as_deref().and_then(parse_time),
                    r.name.clone(),
                )
            })
            .collect(),
    )
}

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
        "no Kix deployment records exist on this Kubernetes cluster (the deployment record resource type is not installed)\n  \
         Nothing was changed on the cluster.\n\n  \
         Why:\n    \
         Either Kix has never deployed to this Kubernetes cluster, or your kubeconfig points at a different cluster than you intended.\n\n  \
         Next (choose one):\n    \
         - Check which cluster your kubeconfig points at (`kubectl config current-context`), or pass `--context <name>` and run the command again.\n    \
         - If this is the right Kubernetes cluster and it has never been deployed with Kix, run its first deploy (which installs the deployment record resource type):\n        \
         kix deploy <cluster>"
    )]
    NotInstalled,
}

/// Return the Activation `ApiResource` under the current API group if present
/// in `discovery`. Callers must still go through [`Records::open`] to enforce
/// the legacy-domain check.
fn served_resource(discovery: &[(ApiResource, Scope)]) -> Option<&ApiResource> {
    super::discovery::find(
        discovery,
        keys::GROUP,
        crate::manifest::lifecycle::RECORD_KIND,
    )
    .map(|(ar, _)| ar)
}

/// Return the Activation `ApiResource` under the current API group, spelled
/// from Kix's own constants rather than discovery, for the listings that run
/// before discovery.
fn record_resource() -> ApiResource {
    let version = keys::API_VERSION
        .rsplit_once('/')
        .map_or(keys::API_VERSION, |(_, v)| v);
    ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk(
            keys::GROUP,
            version,
            crate::manifest::lifecycle::RECORD_KIND,
        ),
        "activations",
    )
}

/// List the Activation records under the current API group that match
/// `selector`, up to `limit` when given, or none when the Activation CRD is
/// not installed.
async fn list_undiscovered(
    client: &Client,
    selector: &str,
    limit: Option<u32>,
) -> Result<Vec<DynamicObject>, RecordsError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), &record_resource());
    let mut lp = ListParams::default().labels(selector);
    if let Some(limit) = limit {
        lp = lp.limit(limit);
    }
    match api.list(&lp).await {
        Ok(list) => Ok(list.items),
        Err(kube::Error::Api(e)) if e.code == 404 => Ok(Vec::new()),
        Err(e) => Err(RecordsError::list(e)),
    }
}

/// Return `true` if any Activation record under the current API group carries
/// `cluster` in its `kix.run/cluster` label, or `false` if none exists or the
/// Activation CRD is not installed.
///
/// Used for CLI argument disambiguation before full discovery runs.
pub async fn records_exist(client: &Client, cluster: &str) -> Result<bool, RecordsError> {
    Ok(
        !list_undiscovered(client, &cluster_selector(cluster), Some(1))
            .await?
            .is_empty(),
    )
}

/// An Activation record that carries the `kix.run/kubernetes-uid` label: the
/// Kix cluster that deployed it, and the UID its build named.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoundRecord {
    pub cluster: String,
    pub uid: String,
}

/// Return one Activation record on the Kubernetes cluster, of any Kix
/// cluster, whose build named a `cluster.kubernetes.uid` and finished a
/// deploy ([`has_deployed`]), or `None` when no such record exists or the
/// Activation CRD is not installed. A record that never finished a deploy,
/// such as one the operator failed because its build named another
/// Kubernetes cluster, does not lock the cluster. Runs before discovery.
pub async fn bound_record(client: &Client) -> Result<Option<BoundRecord>, RecordsError> {
    let found = list_undiscovered(client, keys::KUBERNETES_UID, None).await?;
    Ok(found.iter().find(|item| has_deployed(item)).map(|item| {
        let label = |key: &str| {
            item.metadata
                .labels
                .as_ref()
                .and_then(|l| l.get(key))
                .cloned()
                .unwrap_or_default()
        };
        BoundRecord {
            cluster: label(keys::CLUSTER_LABEL),
            uid: label(keys::KUBERNETES_UID),
        }
    }))
}

/// Return whether the deploy of `item` finished: it is current (`Active` or
/// `Degraded`), or it carries `kix.run/deployed-at`, which finalizing a
/// deploy writes and later phases keep.
fn has_deployed(item: &DynamicObject) -> bool {
    is_current_phase(read_phase(item)) || Record::of(item).was_ever_current()
}

/// Build the label selector matching all Activation records for `cluster`.
fn cluster_selector(cluster: &str) -> String {
    format!(
        "app.kubernetes.io/managed-by=kix,{}={cluster}",
        keys::CLUSTER_LABEL
    )
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

/// A Kix cluster's current deploy record, and the newest deploy that failed
/// after it ([`Records::all_current_deploys`]).
#[derive(Debug, Clone)]
pub struct CurrentDeploy {
    /// The `Active` or `Degraded` record.
    pub current: Record,
    /// The newest `Failed` record whose failure came after `current` was
    /// deployed, or `None`.
    pub failed_since: Option<Record>,
}

impl Records {
    /// Open records spelled from Kix's own constants, without discovery, for
    /// the deploy lock, which runs after the command opened its records
    /// through [`Records::open`].
    pub(crate) fn undiscovered(client: &Client) -> Records {
        Records {
            client: client.clone(),
            resource: record_resource(),
        }
    }

    /// Return the client the records are read and written through.
    pub fn client(&self) -> &Client {
        &self.client
    }

    /// Return the same records, read and written through `client`.
    pub fn through(&self, client: &Client) -> Records {
        Records {
            client: client.clone(),
            resource: self.resource.clone(),
        }
    }

    /// List every record of `cluster`, or none when the Activation CRD is
    /// not installed.
    pub(crate) async fn of_cluster(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let lp = ListParams::default().labels(&cluster_selector(cluster));
        match self.api().list(&lp).await {
            Ok(list) => Ok(list.items.iter().map(Record::of).collect()),
            Err(kube::Error::Api(e)) if e.code == 404 => Ok(Vec::new()),
            Err(e) => Err(RecordsError::list(e)),
        }
    }

    /// Make the phases agree with the head after a deploy stopped between
    /// its commit and its phase writes: give record `current` the phase
    /// `phase`, when one is given, and mark each record in `supersede`
    /// Superseded.
    pub(crate) async fn repair_phases(
        &self,
        current: &str,
        phase: Option<&str>,
        supersede: &[String],
    ) -> Result<(), RecordsError> {
        if let Some(phase) = phase {
            self.patch_status(current, &json!({ "status": { "phase": phase } }))
                .await?;
            tracing::info!(activation = %current, phase, "repaired deployment record phase from ActivationHead");
        }
        for name in supersede {
            self.supersede(name).await?;
        }
        Ok(())
    }

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
    /// Excludes `Failed` and `Partial` (which stopped part way and do not
    /// represent the full running closure) and `Deploying` (which is still in
    /// flight).
    pub async fn active(&self, cluster: &str) -> Result<Option<Record>, RecordsError> {
        let items = self.list_of(cluster).await?;
        Ok(current_of(&items, cluster).map(Record::of))
    }

    /// List the records of `cluster` whose deploy stopped without making
    /// them current, `Failed` and `Partial` ones, sorted oldest first so they
    /// fold into the baseline in the order they accumulated.
    pub async fn stopped(&self, cluster: &str) -> Result<Vec<Record>, RecordsError> {
        let mut records: Vec<Record> = self
            .list_of(cluster)
            .await?
            .iter()
            .filter(|item| matches!(read_phase(item), PHASE_FAILED | PHASE_PARTIAL))
            .map(Record::of)
            .collect();
        records.sort_by(|a, b| {
            a.stopped_at()
                .cmp(&b.stopped_at())
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

    /// Return the current record of every Kix cluster with records on the
    /// cluster, keyed by cluster name, as [`Records::active`] picks it. A
    /// record without a `kix.run/cluster` label is left out.
    pub async fn all_current(&self) -> Result<BTreeMap<String, Record>, RecordsError> {
        let mut by_cluster: BTreeMap<String, Vec<DynamicObject>> = BTreeMap::new();
        for item in self.all().await? {
            let cluster = item
                .metadata
                .labels
                .as_ref()
                .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
                .map(str::to_string);
            if let Some(cluster) = cluster {
                by_cluster.entry(cluster).or_default().push(item);
            }
        }
        Ok(by_cluster
            .iter()
            .filter_map(|(cluster, items)| {
                current_of(items, cluster).map(|r| (cluster.clone(), Record::of(r)))
            })
            .collect())
    }

    /// Return the current record of every Kix cluster with one, as
    /// [`Records::all_current`] does, with the newest `Failed` record that
    /// failed after the current record was deployed. Such a record means the
    /// last deploy failed and left the current record in place. It reads
    /// the same one list of records.
    pub async fn all_current_deploys(
        &self,
    ) -> Result<BTreeMap<String, CurrentDeploy>, RecordsError> {
        let mut by_cluster: BTreeMap<String, Vec<DynamicObject>> = BTreeMap::new();
        for item in self.all().await? {
            let cluster = item
                .metadata
                .labels
                .as_ref()
                .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
                .map(str::to_string);
            if let Some(cluster) = cluster {
                by_cluster.entry(cluster).or_default().push(item);
            }
        }
        Ok(by_cluster
            .iter()
            .filter_map(|(cluster, items)| {
                let current = Record::of(current_of(items, cluster)?);
                let since = current.retention_time();
                let failed_since = items
                    .iter()
                    .filter(|item| read_phase(item) == PHASE_FAILED)
                    .map(Record::of)
                    .filter(|r| r.retention_time() > since)
                    .max_by(|a, b| {
                        a.retention_time()
                            .cmp(&b.retention_time())
                            .then_with(|| a.name.cmp(&b.name))
                    });
                Some((
                    cluster.clone(),
                    CurrentDeploy {
                        current,
                        failed_since,
                    },
                ))
            })
            .collect())
    }

    async fn patch_status(&self, name: &str, patch: &Value) -> Result<(), RecordsError> {
        self.api()
            .patch_status(name, &PatchParams::default(), &Patch::Merge(patch))
            .await
            .map_err(RecordsError::on("patch", name))?;
        Ok(())
    }

    /// Mark a record Superseded, and clear the `status.partial` that a
    /// `Partial` record has.
    pub async fn supersede(&self, name: &str) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": { "phase": PHASE_SUPERSEDED, PARTIAL_FIELD: null } }),
        )
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
    /// and advances it through `Deploying` to `Active`. `kubernetes_uid` is
    /// the build's `cluster.kubernetes.uid`, written as the
    /// `kix.run/kubernetes-uid` label when the build names one.
    pub async fn submit(
        &self,
        name: &str,
        cluster: &str,
        source_path: &str,
        identity_hash: Option<&str>,
        kubernetes_uid: Option<&str>,
        request: &str,
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
        let mut labels = serde_json::Map::new();
        labels.insert(
            "app.kubernetes.io/managed-by".to_string(),
            Value::String("kix".to_string()),
        );
        labels.insert(
            keys::CLUSTER_LABEL.to_string(),
            Value::String(cluster.to_string()),
        );
        if let Some(uid) = kubernetes_uid {
            labels.insert(
                keys::KUBERNETES_UID.to_string(),
                Value::String(uid.to_string()),
            );
        }

        let patch = json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": {
                "name": name,
                "labels": labels,
                "annotations": annotations,
            },
            "spec": {
                "cluster": cluster,
                "source": {
                    "type": "storePath",
                    "path": source_path,
                },
                REQUEST_FIELD: request,
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

    /// Record that the operator started `request` on record `name`, and
    /// clear the count of failed attempts, so each request starts from zero.
    pub async fn start_request(&self, name: &str, request: &str) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": { STARTED_REQUEST_FIELD: request, FAILED_ATTEMPTS_FIELD: null } }),
        )
        .await
    }

    /// Queue record `name` again for the operator's `request`, record that
    /// the operator started it, and clear the count of failed attempts and
    /// the `status.partial` of a `Partial` record. The operator then deploys
    /// the record as it deploys a new one.
    pub async fn requeue(&self, name: &str, request: &str) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": {
                "phase": PHASE_QUEUED,
                STARTED_REQUEST_FIELD: request,
                FAILED_ATTEMPTS_FIELD: null,
                PARTIAL_FIELD: null,
            } }),
        )
        .await
    }

    /// Record that the operator finished the run of `request` on record
    /// `name`.
    pub async fn finish_request(&self, name: &str, request: &str) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": { FINISHED_REQUEST_FIELD: request } }),
        )
        .await
    }

    /// Record that the operator could not finish the run of `request` on
    /// record `name`, which stays current, because of `reason`. A command
    /// waiting on the request reads this as its answer. A Kix that does not
    /// know the field keeps waiting, because `status.finishedRequest` does
    /// not change.
    pub async fn fail_request(
        &self,
        name: &str,
        request: &str,
        reason: &str,
    ) -> Result<(), RecordsError> {
        self.patch_status(
            name,
            &json!({ "status": { FAILED_REQUEST_FIELD: {
                "request": request,
                "reason": reason,
                "at": chrono::Utc::now().to_rfc3339(),
            } } }),
        )
        .await
    }

    /// Write a deploy receipt to `name`'s status subresource via merge patch.
    pub async fn write_receipt(&self, name: &str, receipt: &Value) -> Result<(), RecordsError> {
        self.patch_status(name, &json!({ "status": { keys::RECEIPT_FIELD: receipt } }))
            .await
    }

    /// Write [`keys::WITHDRAWN_KIX`] onto `name`, so the record shows that a
    /// withdrawn Kix submitted it on purpose.
    pub async fn note_withdrawn_kix(
        &self,
        name: &str,
        version: &crate::version::Version,
    ) -> Result<(), RecordsError> {
        let patch = json!({
            "metadata": { "annotations": { keys::WITHDRAWN_KIX: version.release() } }
        });
        self.api()
            .patch(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
            .map_err(RecordsError::on("patch", name))?;
        Ok(())
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
    /// or `Degraded`: [`Records::record_finish`], then
    /// [`Records::settle_phases`]. A run that holds the deploy lock commits
    /// the deploy on the lock between the two.
    #[allow(clippy::too_many_arguments)]
    #[cfg(test)]
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
        self.record_finish(
            cluster_name,
            new_activation_name,
            old_activation,
            receipt,
            orphans_kept_from,
        )
        .await?;
        self.settle_phases(
            new_activation_name,
            old_activation,
            had_failures,
            consumed_failed,
        )
        .await
    }

    /// Write what a finished deploy did onto its record, before the deploy
    /// becomes current: the predecessor link, deployment timestamp, cluster
    /// label, and receipt. `orphans_kept_from` replaces
    /// `status.orphansKeptFrom` (an empty slice clears the field).
    pub(crate) async fn record_finish(
        &self,
        cluster_name: &str,
        new_activation_name: &str,
        old_activation: Option<&Record>,
        receipt: Option<&Value>,
        orphans_kept_from: &[KeptOrphanSource],
    ) -> Result<(), RecordsError> {
        let now = chrono::Utc::now().to_rfc3339();

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

        let mut status = serde_json::Map::new();
        if let Some(old) = old_activation {
            status.insert("previousActivation".to_string(), json!(old.name));
        }
        if let Some(receipt) = receipt {
            status.insert(keys::RECEIPT_FIELD.to_string(), receipt.clone());
        }
        // The whole build is deployed now.
        status.insert(PARTIAL_FIELD.to_string(), Value::Null);
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
            .await
    }

    /// Set the phases of a finished deploy: mark the previous record and the
    /// `Failed` records consumed by this plan `Superseded`, and the new one
    /// `Active` or `Degraded`.
    pub(crate) async fn settle_phases(
        &self,
        new_activation_name: &str,
        old_activation: Option<&Record>,
        had_failures: bool,
        consumed_failed: &[String],
    ) -> Result<(), RecordsError> {
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

        let new_phase = if had_failures {
            PHASE_DEGRADED
        } else {
            PHASE_ACTIVE
        };
        self.patch_status(
            new_activation_name,
            &json!({ "status": { "phase": new_phase } }),
        )
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

    /// Set the Activation phase to `Deploying`, initialize wave counters, and
    /// write the build's package index.
    ///
    /// Called at the start of the apply loop after the record is created. Sets
    /// `status.phase = Deploying` and `status.totalWaves = total_waves`, unless
    /// the record is already current (see [`phase_on_begin`]), in which case
    /// only the wave counters and failure field are reset.
    ///
    /// Also clears `status.partial`, since the record now describes this
    /// run, and returns the instances it named. A run with `--only` passes
    /// them to [`Records::end_partial`], so a second such deploy of the same
    /// build adds to the list. A run that stops ends `Failed` with no
    /// `status.partial`.
    ///
    /// Then writes `package_index` to `status.packageIndex` with a patch of
    /// its own. The index only helps a later diff group objects, so a failure
    /// to write it, or an index over [`package_index::MAX_BYTES`], logs a
    /// warning and the deploy goes on. Writing it separately keeps such a
    /// failure from losing the phase.
    pub(crate) async fn begin_deploy(
        &self,
        activation_name: &str,
        total_waves: usize,
        package_index: Option<&RecordPackageIndex>,
    ) -> Result<Vec<String>, RecordsError> {
        let item = self
            .api()
            .get(activation_name)
            .await
            .map_err(RecordsError::on("get", activation_name))?;
        let current = read_phase(&item);
        let earlier_only = Record::of(&item)
            .partial
            .map(|p| p.only)
            .unwrap_or_default();

        let mut status = serde_json::Map::new();
        if let Some(phase) = phase_on_begin(current) {
            status.insert("phase".to_string(), json!(phase));
        }
        status.insert("totalWaves".to_string(), json!(total_waves));
        status.insert("waves".to_string(), json!([]));
        // Clear any failure status from a prior attempt on the same record.
        status.insert("failure".to_string(), Value::Null);
        status.insert(PARTIAL_FIELD.to_string(), Value::Null);

        self.patch_status(activation_name, &json!({ "status": status }))
            .await?;

        if let Some(index) = package_index {
            self.write_package_index(activation_name, index).await;
        }
        Ok(earlier_only)
    }

    /// Write `index` to the record's `status.packageIndex`, warning instead
    /// of failing. The index only helps later commands group and name
    /// objects, so a failure must not stop a deploy. See
    /// [`Records::begin_deploy`].
    ///
    /// An index over [`package_index::MAX_BYTES`] is written without its
    /// names, and one still over the limit is not written.
    pub async fn write_package_index(&self, activation_name: &str, index: &RecordPackageIndex) {
        let Some(value) = sized_index(index) else {
            tracing::warn!(
                activation = %activation_name,
                limit = package_index::MAX_BYTES,
                "the build's package index is too large to store on its record; \
                 a diff on a machine without this build will show an object that \
                 moved between packages only under its new package",
            );
            return;
        };
        let patch = json!({ "status": { (keys::PACKAGE_INDEX_FIELD): value } });
        if let Err(e) = self.patch_status(activation_name, &patch).await {
            tracing::warn!(
                activation = %activation_name,
                error = %e,
                "could not store the build's package index on its record; \
                 a diff on a machine without this build will show an object that \
                 moved between packages only under its new package",
            );
        }
    }

    /// Mark a `Queued` record `Failed` with `reason` before the operator
    /// applies anything from it, such as when its build is bound to another
    /// Kubernetes cluster. Leaves a record that has already left `Queued`
    /// alone.
    pub async fn fail_queued(&self, name: &str, reason: &str) -> Result<(), RecordsError> {
        let current = self.phase_of(name).await?;
        if !(current.is_empty() || current == PHASE_QUEUED) {
            tracing::debug!(activation = %name, phase = %current, "not Queued; left as is");
            return Ok(());
        }
        self.patch_status(
            name,
            &json!({
                "status": {
                    "phase": PHASE_FAILED,
                    "failure": {
                        "reason": reason,
                        "at": chrono::Utc::now().to_rfc3339(),
                    },
                },
            }),
        )
        .await?;
        tracing::info!(activation = %name, reason, "marked as Failed before applying");
        Ok(())
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

    /// End a deploy with `--only` that applied every object it selected of
    /// record `name`'s build. `only` names the instances it applied, joined
    /// with those that [`Records::begin_deploy`] returned.
    ///
    /// When the run moved the record to `Deploying`, mark it `Partial` with
    /// `status.partial` naming the instances. The next plan folds what the
    /// record applied into its baseline, so the next deploy applies the rest
    /// of the build. A record that is current, because the build is the one
    /// the cluster runs, keeps its phase, as [`phase_on_end_partial`]
    /// decides.
    pub(crate) async fn end_partial(
        &self,
        name: &str,
        only: &[String],
    ) -> Result<(), RecordsError> {
        let current = self.phase_of(name).await?;
        let Some(phase) = phase_on_end_partial(&current) else {
            tracing::debug!(activation = %name, phase = %current, "partial deploy of a record that is not Deploying; phase left as is");
            return Ok(());
        };
        let mut names = only.to_vec();
        names.sort();
        names.dedup();
        self.patch_status(
            name,
            &json!({
                "status": {
                    "phase": phase,
                    PARTIAL_FIELD: {
                        "only": names,
                        "at": chrono::Utc::now().to_rfc3339(),
                    },
                },
            }),
        )
        .await?;
        tracing::info!(activation = %name, "marked as Partial");
        Ok(())
    }

    /// Record that the operator's attempt number `attempts` to deploy record
    /// `name` failed with `reason`. With `give_up`, also mark the record
    /// `Failed` when it is `Queued`, or when [`phase_on_abort`] permits it, as
    /// [`Records::fail_deploy`] does. A record is still `Queued` when the
    /// attempt failed before the deploy began, such as when the operator
    /// could not read its build. Return whether the record is now `Failed`.
    pub async fn fail_attempt(
        &self,
        name: &str,
        attempts: u32,
        reason: &str,
        give_up: bool,
    ) -> Result<bool, RecordsError> {
        let mut status = serde_json::Map::new();
        status.insert(FAILED_ATTEMPTS_FIELD.to_string(), json!(attempts));
        status.insert(
            "failure".to_string(),
            json!({ "reason": reason, "at": chrono::Utc::now().to_rfc3339() }),
        );
        let failed = if give_up {
            let current = self.phase_of(name).await?;
            let phase = if current == PHASE_QUEUED {
                Some(PHASE_FAILED)
            } else {
                phase_on_abort(&current)
            };
            if let Some(phase) = phase {
                status.insert("phase".to_string(), json!(phase));
            }
            phase.is_some()
        } else {
            false
        };
        self.patch_status(name, &json!({ "status": status }))
            .await?;
        Ok(failed)
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

/// Return `index` as the JSON a record stores: with its names when it fits
/// in [`package_index::MAX_BYTES`], else without them, else `None`.
fn sized_index(index: &RecordPackageIndex) -> Option<Value> {
    let fits = |v: &Value| v.to_string().len() <= package_index::MAX_BYTES;
    let full = index.to_value();
    if fits(&full) {
        return Some(full);
    }
    let bare = index.without_names().to_value();
    if fits(&bare) {
        tracing::debug!(
            "writing the package index without object names to stay under its size limit"
        );
        return Some(bare);
    }
    None
}
