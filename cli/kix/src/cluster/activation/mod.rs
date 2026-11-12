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

mod record;
mod retention;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashSet};

use crate::eval::package_index::{self, RecordPackageIndex};
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

pub use record::{
    KeptOrphanSource, PinnedInterface, Record, WaveRecord, WaveStatus, current_record,
};
pub use retention::{
    DEFAULT_KEEP_MAX, DEFAULT_KEEP_MIN, RetentionPolicy, RetireReason, Retired, Retirement,
    retire_plan,
};

pub(crate) use record::KeptOrphans;

use record::{is_current_phase, phase_on_abort, phase_on_begin, read_phase, sort_newest_first};

#[cfg(test)]
use record::{parse_time, pick_current};

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
    discovery
        .iter()
        .find(|(ar, _)| {
            crate::manifest::lifecycle::is_record_kind(&ar.kind) && ar.group == keys::GROUP
        })
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

    /// Set the Activation phase to `Deploying`, initialize wave counters, and
    /// write the build's package index.
    ///
    /// Called at the start of the apply loop after the record is created. Sets
    /// `status.phase = Deploying` and `status.totalWaves = total_waves`, unless
    /// the record is already current (see [`phase_on_begin`]), in which case
    /// only the wave counters and failure field are reset.
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
            .await?;

        if let Some(index) = package_index {
            self.write_package_index(activation_name, index).await;
        }
        Ok(())
    }

    /// Write `index` to the record's `status.packageIndex`, warning instead
    /// of failing. The index only helps a later diff group objects, so a
    /// failure must not stop a deploy. See [`Records::begin_deploy`].
    pub async fn write_package_index(&self, activation_name: &str, index: &RecordPackageIndex) {
        let value = index.to_value();
        let bytes = value.to_string().len();
        if bytes > package_index::MAX_BYTES {
            tracing::warn!(
                activation = %activation_name,
                bytes,
                limit = package_index::MAX_BYTES,
                "the build's package index is too large to store on its record; \
                 a diff on a machine without this build will show an object that \
                 moved between packages only under its new package",
            );
            return;
        }
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
