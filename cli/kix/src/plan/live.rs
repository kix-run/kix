//! The operator's plan: a build against the live objects of its Kix cluster.
//!
//! For a Kix cluster read from revisions, the operator decides through the
//! one planner the CLI uses ([`super::decide`]), from the build it applies,
//! the live objects, and the cluster's records and revisions. It never
//! applies with force, so it does not write a drifted object whose changed
//! fields another manager owns. The plan lists such objects
//! ([`LivePlan::drift_not_reverted`]) for the operator to report.
//!
//! The records an older Kix wrote get revisions before any run writes an
//! object ([`crate::cluster::revision::convert`]), in a deploy and in a
//! repair alike, and the plan reads them as the run will find them.
//! [`LivePlan::sweep`]
//! takes the Activation record being reconciled, opens the records, reads
//! the live objects itself, and plans from them. Because [`LivePlan::sweep`]
//! is the only way to construct a [`LivePlan`], the operator always runs a
//! plan made from live objects and writes the record it was made for. No
//! check holds the plan to a package diff.

use std::collections::HashSet;
use std::sync::Arc;

use kube::api::DynamicObject;
use kube::client::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;
use thiserror::Error;

use crate::cluster::activation::{Record, Records};
use crate::cluster::apply::ChangeAction;
use crate::cluster::discovery;
use crate::cluster::errors::FetchError;
use crate::cluster::graph::{GraphError, ResourceGraph};
use crate::cluster::inventory;
use crate::cluster::inventory::{Live, LiveObjects, SharedOrphan};
use crate::cluster::ops::{Cluster, Force, KubeResources, RecordConfig};
use crate::cluster::readiness::MalformedMarker;
use crate::cluster::revision::RevisionSet;
use crate::cluster::scheduler::{
    self, DeployError, DeployPlan, LastRuns, PrunePolicy, SchedulerConfig,
};
use crate::cluster::stream::{DeployObserver, DeployResult};
use crate::cluster::tenancy::Tenancy;
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::keys;
use crate::manifest::types::{ResourceId, to_manifest_value};
use crate::plan::decide::{self, Ledger};

/// Return the Kix cluster that `activation` belongs to, reading its
/// `kix.run/cluster` label before `spec.cluster`.
pub fn cluster_of(activation: &DynamicObject) -> Option<String> {
    activation
        .metadata
        .labels
        .as_ref()
        .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
        .or_else(|| {
            activation
                .data
                .pointer("/spec/cluster")
                .and_then(|v| v.as_str())
        })
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Why [`LivePlan::sweep`] made no plan.
#[derive(Debug, Error)]
pub enum LivePlanError {
    /// Discovery, or the sweep of the live objects, failed.
    #[error(transparent)]
    Fetch(Box<FetchError>),
    /// The records sit under a retired group.
    #[error(transparent)]
    Domain(LegacyDomainError),
    #[error(transparent)]
    Graph(GraphError),
    #[error(transparent)]
    Marker(MalformedMarker),
    /// The records or revisions of this Kix cluster could not be read, so
    /// the plan cannot tell which objects they name.
    #[error("{0}. Nothing was applied or deleted")]
    Tenancy(Box<crate::cluster::tenancy::Problem>),
    /// This account may neither list nor get objects the plan must read.
    #[error("{0}. Nothing was applied or deleted")]
    ReadForbidden(Box<crate::cluster::inventory::ReadForbidden>),
    /// The records an older Kix wrote cannot be given revisions.
    #[error("{0}. Nothing was applied or deleted")]
    Conversion(Box<crate::cluster::revision::convert::Refusal>),
}

/// A drifted object the operator leaves as it is, because another field
/// manager owns fields the build sets and the operator never forces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriftNotReverted {
    pub rid: ResourceId,
    /// The managers that own fields Kix applied, with those fields.
    pub owners: Vec<crate::plan::document::DriftOwner>,
}

/// A build planned against the live objects of one Kix cluster, with the
/// counts the operator logs. Made only by [`LivePlan::sweep`]; run with
/// [`LivePlan::run`].
pub struct LivePlan {
    client: Client,
    discovery: Vec<(ApiResource, Scope)>,
    cluster: String,
    record: Record,
    plan: DeployPlan,
    orphans: Vec<ResourceId>,
    shared_orphans: Vec<SharedOrphan>,
    /// The live objects, which order the prune.
    live: Vec<Value>,
    /// The number of desired and live objects the plan compared.
    compared: usize,
    foreign: inventory::Foreign,
    unattributed: usize,
    /// The revisions of the objects the plan applies, which a run that
    /// writes the record names in it. `None` when the record names no Kix
    /// cluster to label them with.
    revisions: Option<RevisionSet>,
    drift_not_reverted: Vec<DriftNotReverted>,
    /// The objects the records name whose kind the cluster does not serve,
    /// which the run's kept-orphans revision names again.
    unknown: Vec<crate::cluster::revision::RevisionObject>,
    /// The migration writes the run makes.
    migrations: crate::cluster::ops::Migrations,
}

impl LivePlan {
    /// Return how many objects the run moves to this Kix's bookkeeping with
    /// the migration write.
    pub fn metadata_rewrites(&self) -> usize {
        self.migrations.count()
    }

    /// Read the live objects of the Kix cluster `activation` belongs to
    /// ([`cluster_of`]), compare `desired` with them, and plan the changes.
    /// A record that names no cluster sweeps under the empty name, under
    /// which no record counts as this cluster's own.
    ///
    /// `revisions` are the revisions of `desired`, built from the same
    /// objects, so no revision names an object the run does not apply.
    ///
    /// The plan has not read the last runs of its Jobs. Until
    /// [`LivePlan::read_last_runs`] does, a Job under `kix.run/rerun` whose
    /// last run failed does not run again, and the run reports it as failed.
    ///
    /// `deploys` says that the run deploys the record, rather than repairing
    /// drift without writing it. A repair refuses on a Kix cluster an older
    /// Kix deployed last.
    pub async fn sweep(
        client: &Client,
        activation: &DynamicObject,
        desired: &[Value],
        revisions: Option<RevisionSet>,
        deploys: bool,
    ) -> Result<LivePlan, LivePlanError> {
        let cluster = cluster_of(activation).unwrap_or_default();
        let discovery = discovery::discover_resources(client)
            .await
            .map_err(|e| LivePlanError::Fetch(Box::new(e)))?;
        let records = Records::open(client, &discovery).map_err(LivePlanError::Domain)?;
        let fetch = |e: FetchError| LivePlanError::Fetch(Box::new(e));
        // The objects first, then the records ([`crate::cluster::tenancy::read`]).
        let listed = inventory::list_labelled(client, &discovery)
            .await
            .map_err(fetch)?;
        let tenancy = crate::cluster::tenancy::read(&records, &cluster)
            .await
            .map_err(|e| fetch(FetchError::RecordsError(e)))?;
        // The run gives the records an older Kix wrote revisions before it
        // writes anything. The plan reads the records as the run will find
        // them.
        let tenancy = {
            use crate::cluster::revision::convert;
            let own = tenancy.own_records();
            let current = convert::current_of(tenancy.own_current(), own);
            let conversion = convert::plan(
                &cluster,
                current,
                own,
                &tenancy.own_listed_revisions(),
                &inventory::managed_of(listed.clone()).managed,
                &listed.forbidden,
            )
            .map_err(|e| LivePlanError::Conversion(Box::new(e)))?;
            tenancy.with_conversion(&conversion)
        };
        // Only this Kix cluster's objects: every other Kix cluster's objects
        // are absent from this build and would otherwise be pruned as
        // orphans.
        let sweep = inventory::scope_sweep(
            inventory::managed_of(listed.clone()),
            inventory::SweepScope::Cluster(&cluster),
            tenancy,
        );
        // Which orphans another Kix cluster still deploys is decided below,
        // so a run that cannot tell stops before it plans a prune.
        sweep
            .tenancy
            .complete_for_others()
            .map_err(|e| LivePlanError::Fetch(Box::new(FetchError::Tenancy(e))))?;

        let mut live: Vec<Value> = sweep.managed.iter().map(to_manifest_value).collect();
        // The operator holds the deploy lock, so no other deploy is applying
        // what a `Failed` or `Partial` record names.
        let mut ledger =
            Ledger::of(&sweep.tenancy, true).map_err(|e| LivePlanError::Tenancy(Box::new(e)))?;
        let record = Record::of(activation);
        ledger.deploying(record.identity_hash.as_deref().filter(|_| deploys));
        let made = made_by(desired, revisions.as_ref());
        let ids: Vec<ResourceId> = desired
            .iter()
            .map(ResourceId::from_value)
            .chain(ledger.candidates(&made).cloned())
            .collect();
        // The sweep's listing holds every labelled object of every kind, so
        // the plan reads the build's objects from it.
        let objects = LiveObjects::of_listing(client, &discovery, listed, ids.iter().collect())
            .await
            .map_err(fetch)?;
        let decided = decided_changes(desired, &made, &objects, &ledger, &sweep.tenancy)?;
        live = crate::cluster::apply::baseline_manifests(&live, &[decided.orphan_manifests]);
        let drift_not_reverted = decided.drift_not_reverted;
        let unknown = decided.unknown;
        let (actions, shared_orphans) = (decided.actions, decided.shared);
        let orphans: Vec<ResourceId> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect();
        let graph = ResourceGraph::from_manifests(desired).map_err(LivePlanError::Graph)?;
        let plan =
            DeployPlan::from_graph_and_changes(&graph, &actions).map_err(LivePlanError::Marker)?;

        Ok(LivePlan {
            client: client.clone(),
            discovery,
            cluster,
            record,
            migrations: decided.migrations,
            plan,
            orphans,
            shared_orphans,
            live,
            compared: actions.len(),
            foreign: sweep.foreign,
            unattributed: sweep.unattributed.len(),
            revisions,
            drift_not_reverted,
            unknown,
        })
    }

    /// Return the drifted objects the plan leaves as they are, because
    /// another field manager owns fields the build sets.
    pub fn drift_not_reverted(&self) -> &[DriftNotReverted] {
        &self.drift_not_reverted
    }

    /// Read the last runs of the plan's Jobs, as a deploy from the CLI does
    /// ([`crate::plan::CheckedPlan::read_last_runs`]). A Job under
    /// `kix.run/rerun` whose last run failed then runs again.
    ///
    /// The operator calls this only when it starts a deploy of a Queued
    /// record, so a failed Job runs again once for each deploy someone
    /// submits, as it does for each `kix deploy`. A repair of a running build
    /// or a resumed deploy must not call it: the operator retries those, and
    /// would delete and recreate a failing Job on every retry.
    pub async fn read_last_runs(&mut self) -> LastRuns {
        self.plan
            .read_last_runs(&self.client, &self.discovery)
            .await
    }

    /// Return the number of objects the build applies. It is counted on the
    /// plan, which applies none of the objects a consumer leaves to its
    /// platform.
    pub fn applies(&self) -> usize {
        self.plan
            .nodes()
            .iter()
            .filter(|n| n.action.written().is_some())
            .count()
    }

    /// Return the number of objects the build leaves unchanged.
    pub fn unchanged(&self) -> usize {
        self.compared - self.applies() - self.orphans.len()
    }

    /// Return the orphans that pruning may delete.
    pub fn orphans(&self) -> &[ResourceId] {
        &self.orphans
    }

    /// Return the orphans that another Kix cluster's current build still
    /// contains, which pruning preserves.
    pub fn shared_orphans(&self) -> &[SharedOrphan] {
        &self.shared_orphans
    }

    /// Return the live objects the sweep left out because only other Kix
    /// clusters' records name them.
    pub fn foreign(&self) -> &inventory::Foreign {
        &self.foreign
    }

    /// Return the number of live objects naming no record of any Kix cluster
    /// that the sweep excluded.
    pub fn unattributed(&self) -> usize {
        self.unattributed
    }

    /// Run the engine over the plan. Every write goes through `lock`'s
    /// guarded client, and a run that manages the lifecycle commits the
    /// deploy on `lock`. The caller releases it.
    ///
    /// With `manage_lifecycle` the run writes the record's lifecycle (begin,
    /// checkpoints, finalize); without, it corrects drift and leaves the
    /// record alone. The run never marks the record Failed. The operator
    /// counts the runs that stop and decides when to stop retrying.
    pub async fn run(
        self,
        lock: Arc<crate::cluster::head::Lock>,
        manage_lifecycle: bool,
        config: SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        lock.stop_with(&config.cancel);
        let (cluster, _) = Cluster::new(
            KubeResources::new(
                lock.guarded(&self.client),
                self.discovery,
                self.cluster,
                // The operator runs unattended; surface conflicts in
                // Activation status rather than silently clobbering fields
                // owned by other controllers.
                Force::None,
            )
            .with_migrations(self.migrations),
            RecordConfig {
                name: manage_lifecycle.then_some(self.record.name),
                // The operator created the record itself and owns
                // `spec.source`; it has no stamped manifest to re-apply and
                // needs none.
                manifest: None,
                // The operator reconciles a build somebody else made, from
                // inside the cluster, with no source tree to read provenance
                // from. The receipt the deploy wrote stays as it is.
                receipt: None,
                // The live objects already show a failed deploy's leftovers,
                // so there is nothing to fold and nothing to supersede.
                consumed_failed: Vec::new(),
                // The objects whose kind the cluster does not serve keep
                // their place.
                kept_orphans: crate::cluster::activation::KeptOrphans {
                    unknown: self.unknown,
                    ..Default::default()
                },
                // Only a run that writes the record names revisions in it.
                revisions: self.revisions.filter(|_| manage_lifecycle),
                // The operator deploys whole builds.
                only: Vec::new(),
                mark_failed_on_abort: false,
                lock: Some(lock),
            },
            Default::default(),
        );
        scheduler::run_deploy(
            cluster,
            self.plan,
            &self.orphans,
            &self.live,
            // The operator always prunes: its orphans are live objects of
            // its own Kix cluster that the build no longer contains.
            scheduler::Ending::Finalize(PrunePolicy::Delete),
            &config,
            observer,
        )
        .await
    }
}

/// What [`decided_changes`] found.
struct DecidedChanges {
    actions: Vec<ChangeAction>,
    shared: Vec<SharedOrphan>,
    migrations: crate::cluster::ops::Migrations,
    /// The live objects of the orphans the prune may delete, as manifests.
    orphan_manifests: Vec<Value>,
    drift_not_reverted: Vec<DriftNotReverted>,
    unknown: Vec<crate::cluster::revision::RevisionObject>,
}

/// Return every object of the build `desired` is part of: the objects of
/// `desired`, and those `revisions` name, which include the objects the
/// operator leaves out of `desired`.
fn made_by(desired: &[Value], revisions: Option<&RevisionSet>) -> HashSet<ResourceId> {
    let named = revisions
        .into_iter()
        .flat_map(|set| set.all())
        .flat_map(|r| r.spec.objects.iter().map(|o| o.resource_id()));
    desired
        .iter()
        .map(ResourceId::from_value)
        .chain(named)
        .collect()
}

/// Decide the changes of `desired` with the one planner, as the CLI does
/// ([`decide::decide`]), keeping out of the orphans every object another Kix
/// cluster still deploys.
fn decided_changes(
    desired: &[Value],
    made: &HashSet<ResourceId>,
    live: &LiveObjects,
    ledger: &Ledger,
    tenancy: &Tenancy,
) -> Result<DecidedChanges, LivePlanError> {
    let decided = decide::decide(desired, made, live, ledger, false, false)
        .map_err(|e| LivePlanError::ReadForbidden(Box::new(e)))?;
    if !decided.unknown.is_empty() {
        tracing::info!(
            count = decided.unknown.len(),
            "objects earlier deploys left are of kinds the cluster does not serve now; they are not pruned, and the record keeps them listed"
        );
    }
    let (orphans, shared) = inventory::split_shared_orphans_listed(decided.orphans, live, tenancy);
    let orphan_manifests = orphans
        .iter()
        .filter_map(|rid| match live.get(rid) {
            Live::Present(obj) => Some(to_manifest_value(obj)),
            Live::Absent | Live::Unserved | Live::Unread => None,
        })
        .collect();
    let drift_not_reverted = decided
        .decisions
        .iter()
        .filter_map(|d| match &d.label {
            decide::Label::DriftReported(report) => Some(DriftNotReverted {
                rid: d.id.clone(),
                owners: crate::plan::document::DriftOwner::of_report(report),
            }),
            _ => None,
        })
        .collect();
    // The operator always prunes, so an orphan it keeps is one it could
    // not delete, which the next reconcile tries again.
    let migrations = crate::cluster::ops::Migrations {
        objects: decided.migrations.iter().cloned().collect(),
        renamed: decided.renamed.iter().cloned().collect(),
        releases: shared.iter().map(|s| s.rid.clone()).collect(),
        record: ledger.record().map(str::to_string),
    };
    let actions = decided
        .decisions
        .into_iter()
        .map(|d| d.action)
        .chain(orphans.into_iter().map(ChangeAction::Orphan))
        .collect();
    Ok(DecidedChanges {
        actions,
        shared,
        migrations,
        orphan_manifests,
        drift_not_reverted,
        unknown: decided.unknown,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::apply::RerunReason;
    use crate::manifest::lifecycle::PHASE_ACTIVE;
    use serde_json::json;

    fn annotated(kind: &str, name: &str, hash: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "d",
                "labels": { "app.kubernetes.io/managed-by": "kix" },
                "annotations": {
                    (keys::IDENTITY_HASH): hash,
                    (keys::ACTIVATIONS): activations,
                },
            },
        })
    }

    fn live(kind: &str, name: &str, hash: &str, activations: &str) -> DynamicObject {
        let mut obj = annotated(kind, name, hash, activations);
        obj["metadata"]["managedFields"] = json!([{ "manager": "kix", "operation": "Apply" }]);
        serde_json::from_value(obj).unwrap()
    }

    fn record(cluster: &str, hash: &str) -> DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": cluster,
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        }))
        .unwrap()
    }

    fn orphans(actions: &[ChangeAction]) -> Vec<String> {
        let mut v: Vec<String> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.name.clone()),
                _ => None,
            })
            .collect();
        v.sort();
        v
    }

    /// Decide `desired` against `objects` for a Kix cluster that an older
    /// Kix deployed last, after the conversion a run writes first, as the
    /// operator's deploy does.
    fn notes_changes(
        desired: &[Value],
        objects: &[DynamicObject],
        tenancy: &Tenancy,
    ) -> (Vec<ChangeAction>, Vec<SharedOrphan>) {
        use crate::cluster::revision::convert;
        let own = tenancy.own_records();
        let conversion = convert::plan(
            &tenancy.cluster,
            convert::current_of(tenancy.own_current(), own),
            own,
            &[],
            objects,
            &[],
        )
        .unwrap();
        let tenancy = &tenancy.with_conversion(&conversion);
        let ledger = Ledger::of(tenancy, true).unwrap();
        let made = made_by(desired, None);
        let live = LiveObjects::of(objects.iter().cloned(), []);
        let decided = decided_changes(desired, &made, &live, &ledger, tenancy).unwrap();
        (decided.actions, decided.shared)
    }

    /// The reconcile of Kix cluster `a` in a Kubernetes cluster that also
    /// runs `b`: it prunes its own stale object, never `b`'s, and keeps the
    /// ClusterRole both deployed after `a` dropped it.
    #[test]
    fn reconcile_prunes_only_this_clusters_orphans() {
        let records = [record("a", "a2"), record("b", "b1")];
        let objects = vec![
            live("ConfigMap", "a-web", "h-web", "a2"),
            live("ConfigMap", "a-stale", "h-stale", "a2"),
            live("ConfigMap", "b-web", "h-b", "b1"),
            live("ClusterRole", "shared", "h-shared", "a2,b1"),
        ];
        let desired = [annotated("ConfigMap", "a-web", "h-web", "")];

        let tenancy = Tenancy::fixture(&records, "a");
        let sweep = inventory::scope_sweep(
            inventory::partition_sweep(objects.clone()),
            inventory::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        let (actions, shared) = notes_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["a-stale"]);
        assert_eq!(shared.len(), 1);
        assert_eq!(shared[0].rid.name, "shared");

        // `b`'s reconcile, with `b`'s build unchanged, prunes nothing of `a`.
        let tenancy = Tenancy::fixture(&records, "b");
        let sweep = inventory::scope_sweep(
            inventory::partition_sweep(objects),
            inventory::SweepScope::Cluster("b"),
            tenancy.clone(),
        );
        let desired = [
            annotated("ConfigMap", "b-web", "h-b", ""),
            annotated("ClusterRole", "shared", "h-shared", ""),
        ];
        let (actions, shared) = notes_changes(&desired, &sweep.managed, &tenancy);
        assert!(orphans(&actions).is_empty());
        assert!(shared.is_empty());
    }

    /// The operator prunes a stale object of its own cluster, and never an
    /// object that names no record, even when no other Kix cluster has records
    /// left: that object may belong to a cluster whose records were deleted.
    #[test]
    fn reconcile_prunes_only_objects_that_name_its_records() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let objects = vec![
            live("ConfigMap", "a-web", "h-web", "a2"),
            live("ConfigMap", "a-stale", "h-stale", "a2"),
            live("ConfigMap", "b-web", "h-b", "b1"),
            live("ConfigMap", "leftover", "h-left", "retired"),
        ];
        let sweep = inventory::scope_sweep(
            inventory::partition_sweep(objects),
            inventory::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        let desired = [annotated("ConfigMap", "a-web", "h-web", "")];
        assert_eq!(sweep.unattributed.len(), 2);
        let (actions, _) = notes_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["a-stale"]);
    }

    fn rerun_job(hash: &str) -> Value {
        let mut job = annotated("Job", "migrate", hash, "a2");
        job["apiVersion"] = json!("batch/v1");
        job["metadata"]["annotations"][keys::RERUN] = json!("on-change");
        job
    }

    /// Return `job` as an older Kix left it after its last run failed,
    /// with the applied hash it recorded in its note.
    fn failed(mut job: Value) -> Value {
        job["metadata"]["managedFields"] = json!([{
            "manager": crate::cluster::field_manager::LEGACY,
            "operation": "Apply",
            "fieldsType": "FieldsV1",
            "fieldsV1": { "f:spec": { "f:backoffLimit": {} } },
        }]);
        job["spec"] = json!({ "backoffLimit": 0 });
        job["status"] = json!({ "failed": 1 });
        let obj: DynamicObject = serde_json::from_value(job.clone()).unwrap();
        let applied = crate::cluster::fieldsv1::applied_content_hash(
            &obj,
            &crate::cluster::field_manager::FieldManager::unmigrated("a"),
        )
        .unwrap();
        job["metadata"]["annotations"][keys::APPLIED_HASH] = json!(applied);
        job
    }

    fn rerun_reasons(plan: &DeployPlan) -> Vec<RerunReason> {
        plan.nodes()
            .iter()
            .filter_map(|n| match &n.action {
                ChangeAction::Recreate(_, reason) => Some(*reason),
                _ => None,
            })
            .collect()
    }

    /// An unchanged Job under `kix.run/rerun` whose last run failed runs
    /// again when a deploy starts, whether the CLI or the operator runs it.
    /// Both read the Job through the same decision, and give the same
    /// reason.
    #[tokio::test]
    async fn the_cli_and_the_operator_both_rerun_a_failed_job() {
        let api = crate::cluster::fake_api::FakeApi::new([failed(rerun_job("h-job"))]);
        let client = api.client();

        // The operator: the live Job carries the build's hash, so the sweep
        // leaves it unchanged until the plan reads its last run.
        let live_job: DynamicObject = serde_json::from_value(failed(rerun_job("h-job"))).unwrap();
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let desired = [rerun_job("h-job")];
        let (actions, _) = notes_changes(&desired, std::slice::from_ref(&live_job), &tenancy);
        let graph = ResourceGraph::from_manifests(&desired).unwrap();
        let mut operator = LivePlan {
            client: client.clone(),
            discovery: discovery::discover_resources(&client).await.unwrap(),
            cluster: "a".into(),
            record: Record::default(),
            plan: DeployPlan::from_graph_and_changes(&graph, &actions).unwrap(),
            orphans: Vec::new(),
            shared_orphans: Vec::new(),
            live: Vec::new(),
            compared: actions.len(),
            foreign: inventory::Foreign::default(),
            unattributed: 0,
            revisions: None,
            drift_not_reverted: Vec::new(),
            unknown: Vec::new(),
            migrations: Default::default(),
        };
        assert_eq!(operator.applies(), 0);
        assert_eq!(
            operator.read_last_runs().await,
            LastRuns::Read { failed: vec![] }
        );
        assert_eq!(rerun_reasons(&operator.plan), [RerunReason::LastRunFailed]);
        assert_eq!((operator.applies(), operator.unchanged()), (1, 0));

        // The CLI: a redeploy of the same build.
        let built = crate::eval::store_graph::StoreGraph::synthesize(
            &desired,
            &crate::eval::store_graph::StoreGraph::empty("a"),
        );
        let mut checked = crate::plan::fixtures::plan(
            &crate::plan::fixtures::deployed(Some(&built)),
            &built,
            crate::plan::fixtures::flags(&[]),
        )
        .unwrap();
        assert!(rerun_reasons(checked.plan()).is_empty());
        let last_runs = checked.read_last_runs(&client).await.unwrap();
        assert_eq!(last_runs, LastRuns::Read { failed: vec![] });
        assert_eq!(rerun_reasons(checked.plan()), [RerunReason::LastRunFailed]);
    }

    /// The live objects a sweep keeps are whole manifests, with the
    /// `metadata` kube holds apart from the rest. The prune orders the
    /// orphans by them, and the kept-orphans revision reads each one's
    /// identity hash from them.
    #[tokio::test]
    async fn the_sweep_keeps_the_live_objects_metadata() {
        let mut rec = serde_json::to_value(record("a", "a1")).unwrap();
        rec["metadata"]["labels"]["app.kubernetes.io/managed-by"] = json!("kix");
        let api = crate::cluster::fake_api::FakeApi::new([
            rec.clone(),
            serde_json::to_value(live("ConfigMap", "stale", "h-stale", "a1")).unwrap(),
        ]);
        let activation: DynamicObject = serde_json::from_value(rec).unwrap();
        let plan = LivePlan::sweep(&api.client(), &activation, &[], None, true)
            .await
            .unwrap();
        assert_eq!(
            plan.orphans()
                .iter()
                .map(|r| r.name.as_str())
                .collect::<Vec<_>>(),
            ["stale"]
        );
        let kept: Vec<ResourceId> = plan.live.iter().map(ResourceId::from_value).collect();
        assert!(kept.contains(&plan.orphans()[0]), "{:?}", plan.live);
        let manifest = plan
            .live
            .iter()
            .find(|m| ResourceId::from_value(m) == plan.orphans()[0])
            .unwrap();
        assert_eq!(keys::get(manifest, keys::IDENTITY_HASH), Some("h-stale"));
    }

    /// A record's cluster comes from its label before `spec.cluster`, and
    /// a record naming neither has no cluster.
    #[test]
    fn a_records_cluster_comes_from_its_label() {
        let mut rec = record("a", "a1");
        rec.data = json!({ "spec": { "cluster": "stale" } });
        assert_eq!(cluster_of(&rec).as_deref(), Some("a"));
        rec.metadata.labels = None;
        assert_eq!(cluster_of(&rec).as_deref(), Some("stale"));
        rec.data = json!({});
        assert_eq!(cluster_of(&rec), None);
    }

    mod one_planner {
        use super::*;
        use crate::cluster::fake_api::FakeApi;
        use crate::cluster::revision::{RevisionMap, Revisions};
        use crate::eval::store_graph::StoreGraph;

        fn config_map(name: &str, value: &str) -> Value {
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "labels": { "app.kubernetes.io/managed-by": "kix" },
                },
                "data": { "k": value },
            })
        }

        /// Return the stamped build of `manifests` for Kix cluster `a`.
        fn build(manifests: &[Value]) -> StoreGraph {
            let graph = StoreGraph::synthesize(manifests, &StoreGraph::empty("a"));
            crate::plan::fixtures::stamp(&graph).0
        }

        fn manifests(graph: &StoreGraph) -> Vec<Value> {
            graph
                .resources
                .values()
                .map(|r| r.manifest.clone())
                .collect()
        }

        /// Put on a fake API server Kix cluster `a` read from revisions:
        /// its head, its current record `a-cur` with the revisions of
        /// `deployed`, and the live objects `live`.
        async fn cluster(deployed: &StoreGraph, live: &[Value]) -> (FakeApi, DynamicObject) {
            let set = RevisionSet::of("a", deployed);
            let record = json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": "a-cur",
                    "labels": { (keys::CLUSTER_LABEL): "a" },
                    "annotations": { (keys::IDENTITY_HASH): "rec-cur" },
                },
                "status": {
                    "phase": PHASE_ACTIVE,
                    "revisions": RevisionMap::of(&set).to_value(),
                },
            });
            let head = json!({
                "apiVersion": keys::API_VERSION,
                "kind": crate::cluster::head::KIND,
                "metadata": { "name": "a" },
                "status": { "current": "a-cur", "generation": 1 },
            });
            let api = FakeApi::new(
                [record.clone(), head]
                    .into_iter()
                    .chain(live.iter().cloned()),
            );
            let store = Revisions::new(&api.client());
            for revision in set.all() {
                store.create(revision).await.unwrap();
            }
            (api, serde_json::from_value(record).unwrap())
        }

        fn written(plan: &DeployPlan) -> Vec<String> {
            let mut names: Vec<String> = plan
                .nodes()
                .iter()
                .filter_map(|n| n.action.written())
                .map(|m| ResourceId::from_value(m).name)
                .collect();
            names.sort();
            names
        }

        fn names(ids: &[ResourceId]) -> Vec<String> {
            ids.iter().map(|r| r.name.clone()).collect()
        }

        /// The CLI and the operator decide the same writes and orphans
        /// from the same build, live objects, and records: `kept` is
        /// unchanged but has no applied hash, `changed` carries the
        /// deployed build's hash, and `dropped` left the build.
        #[tokio::test]
        async fn the_cli_and_the_operator_decide_the_same() {
            let deployed = build(&[
                config_map("kept", "1"),
                config_map("changed", "1"),
                config_map("dropped", "1"),
            ]);
            let new = build(&[config_map("kept", "1"), config_map("changed", "2")]);
            let (api, record) = cluster(&deployed, &manifests(&deployed)).await;
            let client = api.client();

            let opened = Records::open(
                &client,
                &discovery::discover_resources(&client).await.unwrap(),
            )
            .unwrap();
            let baseline = crate::plan::baseline::Baseline {
                active: Some(Record::of(&record)),
                tenancy: crate::cluster::tenancy::read(&opened, "a").await.unwrap(),
                ..crate::plan::baseline::Baseline::empty()
            };
            let planner = crate::plan::Planner::new(crate::plan::fixtures::flags(&[]), &|_| {});
            let cli = planner
                .plan(&new, "a", &baseline, Some(&client))
                .await
                .unwrap();

            let operator = LivePlan::sweep(
                &client,
                &record,
                &manifests(&new),
                Some(RevisionSet::of("a", &new)),
                true,
            )
            .await
            .unwrap();

            assert_eq!(written(cli.plan()), ["changed", "kept"]);
            assert_eq!(written(&operator.plan), written(cli.plan()));
            assert_eq!(names(cli.orphans()), ["dropped"]);
            assert_eq!(names(operator.orphans()), names(cli.orphans()));
            let reasons: Vec<_> = cli
                .objects()
                .writes
                .iter()
                .map(|w| (w.name.as_str(), w.reason.clone()))
                .collect();
            assert_eq!(
                reasons,
                [
                    ("changed", None),
                    (
                        "kept",
                        Some(crate::plan::document::WriteReason::AppliedHashMissing)
                    ),
                ]
            );
        }

        /// A drifted object is labelled as reverting drift. The CLI applies
        /// it with force, and the operator applies it without.
        #[tokio::test]
        async fn the_cli_forces_a_revert_of_drift_and_the_operator_does_not() {
            let graph = build(&[config_map("web", "1"), config_map("calm", "1")]);
            let owned = |mut m: Value| {
                m["metadata"]["managedFields"] = json!([{
                    "manager": "kix/a",
                    "operation": "Apply",
                    "apiVersion": "v1",
                    "fieldsV1": { "f:data": { "f:k": {} } },
                }]);
                m
            };
            let live: Vec<Value> = manifests(&graph).into_iter().map(owned).collect();
            let (api, record) = cluster(&graph, &live).await;
            let client = api.client();
            let set = RevisionSet::of("a", &graph);
            let store = Revisions::new(&client);
            for revision in set.all() {
                let entries: std::collections::BTreeMap<String, String> = revision
                    .spec
                    .objects
                    .iter()
                    .map(|o| {
                        let obj: DynamicObject = serde_json::from_value(
                            live.iter()
                                .find(|m| ResourceId::from_value(m) == o.resource_id())
                                .unwrap()
                                .clone(),
                        )
                        .unwrap();
                        let applied = match o.name.as_str() {
                            "web" => "stale".to_string(),
                            _ => crate::cluster::fieldsv1::applied_content_hash(
                                &obj,
                                &crate::cluster::field_manager::FieldManager::of("a"),
                            )
                            .unwrap(),
                        };
                        (o.hash.clone(), applied)
                    })
                    .collect();
                if !entries.is_empty() {
                    store.write_applied(&revision.name, &entries).await.unwrap();
                }
            }

            let opened = Records::open(
                &client,
                &discovery::discover_resources(&client).await.unwrap(),
            )
            .unwrap();
            let baseline = crate::plan::baseline::Baseline {
                active: Some(Record::of(&record)),
                tenancy: crate::cluster::tenancy::read(&opened, "a").await.unwrap(),
                ..crate::plan::baseline::Baseline::empty()
            };
            let planner = crate::plan::Planner::new(crate::plan::fixtures::flags(&[]), &|_| {});
            let cli = planner
                .plan(&graph, "a", &baseline, Some(&client))
                .await
                .unwrap();
            assert_eq!(written(cli.plan()), ["web"]);
            let web = ResourceId::from_value(&config_map("web", "1"));
            let crate::cluster::ops::Force::Only(forced) = cli.force() else {
                panic!("forces only the drifted object");
            };
            assert_eq!(forced.keys().collect::<Vec<_>>(), [&web]);
            assert!(matches!(
                cli.objects().writes[0].reason,
                Some(crate::plan::document::WriteReason::RevertsDrift { .. })
            ));

            let operator = LivePlan::sweep(&client, &record, &manifests(&graph), Some(set), false)
                .await
                .unwrap();
            assert_eq!(written(&operator.plan), ["web"]);
            let lock = crate::cluster::head::take(
                &client,
                crate::cluster::head::Request {
                    cluster: "a".into(),
                    holder: crate::cluster::head::Holder::cli("kix deploy"),
                    purpose: crate::cluster::head::Purpose::Repair,
                    activation: Some("a-cur".into()),
                    expect: None,
                },
                crate::cluster::head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap();
            let lock = Arc::new(lock);
            operator
                .run(
                    lock.clone(),
                    false,
                    test_config(),
                    Arc::new(crate::cluster::stream::NullObserver),
                )
                .await
                .unwrap();
            lock.release().await.unwrap();
            let applies: Vec<String> = api
                .requests()
                .into_iter()
                .filter(|r| r.starts_with("PATCH") && r.contains("/configmaps/web?"))
                .collect();
            assert!(!applies.is_empty());
            assert!(
                applies.iter().all(|r| !r.contains("force=true")),
                "{applies:?}"
            );
        }

        /// A repair that goes on past a failed object, as the operator's
        /// does, repairs the other drifted object and reports the one whose
        /// apply Kubernetes refused with a conflict.
        #[tokio::test]
        async fn a_repair_that_continues_repairs_past_a_conflict() {
            let graph = build(&[config_map("web", "1"), config_map("calm", "1")]);
            let owned = |mut m: Value| {
                m["metadata"]["managedFields"] = json!([{
                    "manager": "kix/a",
                    "operation": "Apply",
                    "apiVersion": "v1",
                    "fieldsV1": { "f:data": { "f:k": {} } },
                }]);
                m
            };
            let live: Vec<Value> = manifests(&graph).into_iter().map(owned).collect();
            let (api, record) = cluster(&graph, &live).await;
            let client = api.client();
            let set = RevisionSet::of("a", &graph);
            let store = Revisions::new(&client);
            for revision in set.all() {
                let entries: std::collections::BTreeMap<String, String> = revision
                    .spec
                    .objects
                    .iter()
                    .map(|o| (o.hash.clone(), "stale".to_string()))
                    .collect();
                if !entries.is_empty() {
                    store.write_applied(&revision.name, &entries).await.unwrap();
                }
            }
            let plan = LivePlan::sweep(&client, &record, &manifests(&graph), Some(set), false)
                .await
                .unwrap();
            assert_eq!(written(&plan.plan), ["calm", "web"]);
            api.fail_next("/api/v1/namespaces/app/configmaps/web", u32::MAX, 409);
            let lock = crate::cluster::head::take(
                &client,
                crate::cluster::head::Request {
                    cluster: "a".into(),
                    holder: crate::cluster::head::Holder::operator("kix", None),
                    purpose: crate::cluster::head::Purpose::Repair,
                    activation: Some("a-cur".into()),
                    expect: None,
                },
                crate::cluster::head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap();
            let lock = Arc::new(lock);
            let config = SchedulerConfig {
                on_error: crate::cluster::scheduler::OnErrorPolicy::Continue,
                ..test_config()
            };
            let result = plan
                .run(
                    lock.clone(),
                    false,
                    config,
                    Arc::new(crate::cluster::stream::NullObserver),
                )
                .await
                .unwrap();
            lock.release().await.unwrap();
            assert_eq!((result.configured, result.failed), (1, 1));
            assert_eq!(
                result.failures[0].node,
                crate::cluster::stream::NodeId::Resource(ResourceId::from_value(&config_map(
                    "web", "1"
                )))
            );
            assert!(
                api.requests()
                    .iter()
                    .any(|r| r.starts_with("PATCH") && r.contains("/configmaps/calm?")),
                "{:?}",
                api.requests()
            );
        }

        /// Return the build of `manifests` with its Activation record
        /// `record`, for Kix cluster `a`.
        fn release(record: &str, manifests: &[Value]) -> StoreGraph {
            let mut all = manifests.to_vec();
            all.push(json!({
                "apiVersion": keys::API_VERSION,
                "kind": crate::manifest::lifecycle::RECORD_KIND,
                "metadata": {
                    "name": record,
                    "labels": { (keys::CLUSTER_LABEL): "a" },
                },
                "spec": { "cluster": "a" },
            }));
            build(&all)
        }

        fn deployment(name: &str, cede: bool) -> Value {
            let mut d = json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "labels": { "app.kubernetes.io/managed-by": "kix" },
                },
                "spec": { "replicas": 1, "template": { "spec": { "image": "web:1" } } },
                // The fake stores what a create sends, so the Deployment is
                // ready at once. No apply owns `status`.
                "status": {
                    "observedGeneration": 1,
                    "replicas": 1,
                    "updatedReplicas": 1,
                    "readyReplicas": 1,
                    "availableReplicas": 1,
                    "conditions": [{ "type": "Available", "status": "True" }],
                },
            });
            if cede {
                d["metadata"]["annotations"] = json!({ (keys::CEDE_FIELDS): ".spec.replicas" });
            }
            d
        }

        /// Return the current record of Kix cluster `a` and the baseline the
        /// CLI plans against.
        async fn current_baseline(client: &Client) -> crate::plan::baseline::Baseline {
            let opened = Records::open(
                client,
                &discovery::discover_resources(client).await.unwrap(),
            )
            .unwrap();
            let tenancy = crate::cluster::tenancy::read(&opened, "a").await.unwrap();
            let active = opened.into_records().unwrap().active("a").await.unwrap();
            crate::plan::baseline::Baseline {
                active,
                tenancy,
                ..crate::plan::baseline::Baseline::empty()
            }
        }

        /// Plan `graph` as `kix plan` does.
        async fn cli_plan(api: &FakeApi, graph: &StoreGraph) -> crate::plan::CheckedPlan {
            let client = api.client();
            let baseline = current_baseline(&client).await;
            crate::plan::Planner::new(crate::plan::fixtures::flags(&[]), &|_| {})
                .plan(graph, "a", &baseline, Some(&client))
                .await
                .unwrap()
        }

        /// Plan `graph` and run the plan as `kix deploy` does, and return
        /// what the run reports.
        async fn cli_deploy(
            api: &FakeApi,
            graph: &StoreGraph,
        ) -> Result<crate::cluster::stream::DeployResult, DeployError> {
            let checked = cli_plan(api, graph).await;
            cli_run(api, checked).await
        }

        /// Run `checked` as `kix deploy` does, and return what the run
        /// reports.
        async fn cli_run(
            api: &FakeApi,
            checked: crate::plan::CheckedPlan,
        ) -> Result<crate::cluster::stream::DeployResult, DeployError> {
            let client = api.client();
            let lock = crate::cluster::head::take(
                &client,
                crate::cluster::head::Request {
                    cluster: "a".into(),
                    holder: crate::cluster::head::Holder::cli("kix deploy"),
                    purpose: crate::cluster::head::Purpose::Deploy,
                    activation: checked.activation_name().map(str::to_string),
                    expect: None,
                },
                crate::cluster::head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap();
            let lock = Arc::new(lock);
            let target =
                crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
                    .await
                    .unwrap();
            let result = checked
                .run(
                    target,
                    lock.clone(),
                    None,
                    test_config(),
                    Arc::new(crate::cluster::stream::NullObserver),
                )
                .await;
            lock.release().await.unwrap();
            result
        }

        /// Plan the repair of the current record's build `graph` as the
        /// operator does.
        async fn operator_plan(api: &FakeApi, graph: &StoreGraph) -> LivePlan {
            let client = api.client();
            let name = current_baseline(&client).await.active.unwrap().name;
            let record: DynamicObject = serde_json::from_value(
                api.object(crate::manifest::lifecycle::RECORD_KIND, &name)
                    .unwrap(),
            )
            .unwrap();
            let desired: Vec<Value> = manifests(graph)
                .into_iter()
                .filter(|m| !crate::manifest::lifecycle::is_record(m))
                .collect();
            LivePlan::sweep(
                &client,
                &record,
                &desired,
                Some(RevisionSet::of("a", graph)),
                false,
            )
            .await
            .unwrap()
        }

        /// Run the operator's repair `plan`, going on past a failed object.
        async fn operator_repair(
            api: &FakeApi,
            plan: LivePlan,
        ) -> crate::cluster::stream::DeployResult {
            operator_run(
                api,
                plan,
                crate::cluster::scheduler::OnErrorPolicy::Continue,
            )
            .await
        }

        /// Run the operator's repair `plan` with `on_error`.
        async fn operator_run(
            api: &FakeApi,
            plan: LivePlan,
            on_error: crate::cluster::scheduler::OnErrorPolicy,
        ) -> crate::cluster::stream::DeployResult {
            let client = api.client();
            let lock = crate::cluster::head::take(
                &client,
                crate::cluster::head::Request {
                    cluster: "a".into(),
                    holder: crate::cluster::head::Holder::operator("kix", None),
                    purpose: crate::cluster::head::Purpose::Repair,
                    activation: None,
                    expect: None,
                },
                crate::cluster::head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap();
            let lock = Arc::new(lock);
            let config = SchedulerConfig {
                on_error,
                ..test_config()
            };
            let result = plan
                .run(
                    lock.clone(),
                    false,
                    config,
                    Arc::new(crate::cluster::stream::NullObserver),
                )
                .await
                .unwrap();
            lock.release().await.unwrap();
            result
        }

        fn writes(plan: &crate::plan::CheckedPlan) -> Vec<String> {
            written(plan.plan())
                .into_iter()
                .filter(|n| !n.starts_with("a-v"))
                .collect()
        }

        /// Plan, run, and plan again: the second plan writes nothing, from
        /// the CLI and from the operator. An autoscaler that changes a ceded
        /// field leaves both plans with nothing to write. A field another
        /// manager took that the object does not cede is taken back by the
        /// CLI, with force, and the plan after that writes nothing again.
        #[tokio::test]
        async fn plan_run_plan_again_writes_nothing() {
            let api = FakeApi::new([]);
            api.track_owners();
            let v1 = release(
                "a-v1",
                &[
                    config_map("conf", "1"),
                    deployment("scaled", true),
                    deployment("fixed", false),
                ],
            );
            let first = cli_deploy(&api, &v1).await.unwrap();
            assert_eq!(first.failed, 0, "{first:?}");
            assert_eq!(writes(&cli_plan(&api, &v1).await), Vec::<String>::new());
            let operator = operator_plan(&api, &v1).await;
            assert_eq!(
                (operator.applies(), operator.drift_not_reverted().len()),
                (0, 0)
            );

            // An autoscaler scales both Deployments through `/scale`.
            for name in ["scaled", "fixed"] {
                api.update_as("hpa", Some("scale"), "Deployment", name, |o| {
                    o["spec"]["replicas"] = json!(5);
                });
            }
            let plan = cli_plan(&api, &v1).await;
            assert_eq!(writes(&plan), ["fixed"]);
            let operator = operator_plan(&api, &v1).await;
            assert_eq!(operator.applies(), 0);
            assert_eq!(
                operator
                    .drift_not_reverted()
                    .iter()
                    .map(|d| d.rid.name.as_str())
                    .collect::<Vec<_>>(),
                ["fixed"]
            );

            // The operator sends nothing for it, so even a run that stops at
            // the first failure has none, and the rest of the build goes on.
            let before = api.requests().len();
            let result = operator_run(
                &api,
                operator_plan(&api, &v1).await,
                crate::cluster::scheduler::OnErrorPolicy::Stop,
            )
            .await;
            assert_eq!(result.failed, 0, "{result:?}");
            assert!(
                !api.requests()[before..]
                    .iter()
                    .any(|r| r.starts_with("PATCH") && r.contains("/deployments/fixed")),
                "{:?}",
                api.requests()
            );

            let second = cli_deploy(&api, &v1).await.unwrap();
            assert_eq!(second.failed, 0, "{second:?}");
            let scaled = api.object("Deployment", "scaled").unwrap();
            let fixed = api.object("Deployment", "fixed").unwrap();
            assert_eq!(
                scaled["spec"]["replicas"],
                json!(5),
                "the autoscaler keeps a ceded field"
            );
            assert_eq!(
                fixed["spec"]["replicas"],
                json!(1),
                "the deploy takes the field back"
            );
            assert_eq!(writes(&cli_plan(&api, &v1).await), Vec::<String>::new());
            let operator = operator_plan(&api, &v1).await;
            assert_eq!(
                (operator.applies(), operator.drift_not_reverted().len()),
                (0, 0)
            );
        }

        /// An earlier Kix stored applied hashes that covered ceded fields.
        /// On the first plan after the change, such an object reads as
        /// drifted once. The forced apply leaves out the ceded field the
        /// autoscaler owns, so it writes nothing the autoscaler set, and it
        /// records the new hash. The plan after that writes nothing.
        #[tokio::test]
        async fn a_hash_stored_with_ceded_fields_reads_as_drift_once_and_is_harmless() {
            let api = FakeApi::new([]);
            api.track_owners();
            let v1 = release(
                "a-v1",
                &[deployment("scaled", true), deployment("held", true)],
            );
            cli_deploy(&api, &v1).await.unwrap();
            // Store each hash as an earlier Kix computed it, ceded field and
            // all.
            let store = Revisions::new(&api.client());
            let listed = store.list("a").await.unwrap().readable;
            for name in ["scaled", "held"] {
                let obj: DynamicObject =
                    serde_json::from_value(api.object("Deployment", name).unwrap()).unwrap();
                let old = crate::cluster::fieldsv1::projection_hash(
                    crate::cluster::fieldsv1::kix_owned_projection(
                        &obj,
                        &crate::cluster::field_manager::FieldManager::of("a"),
                    )
                    .unwrap(),
                );
                assert_ne!(
                    Some(&old),
                    crate::cluster::fieldsv1::applied_content_hash(
                        &obj,
                        &crate::cluster::field_manager::FieldManager::of("a")
                    )
                    .as_ref()
                );
                for revision in &listed {
                    if let Some(o) = revision.spec.objects.iter().find(|o| o.name == name) {
                        store
                            .write_applied(&revision.name, &[(o.hash.clone(), old.clone())].into())
                            .await
                            .unwrap();
                    }
                }
            }
            api.update_as("hpa", Some("scale"), "Deployment", "scaled", |o| {
                o["spec"]["replicas"] = json!(5);
                for count in [
                    "replicas",
                    "updatedReplicas",
                    "readyReplicas",
                    "availableReplicas",
                ] {
                    o["status"][count] = json!(5);
                }
            });
            let plan = cli_plan(&api, &v1).await;
            assert_eq!(writes(&plan), ["held", "scaled"]);
            let result = cli_deploy(&api, &v1).await.unwrap();
            assert_eq!(result.failed, 0, "{result:?}");
            assert_eq!(
                api.object("Deployment", "scaled").unwrap()["spec"]["replicas"],
                json!(5)
            );
            assert_eq!(
                api.object("Deployment", "held").unwrap()["spec"]["replicas"],
                json!(1)
            );
            assert_eq!(writes(&cli_plan(&api, &v1).await), Vec::<String>::new());
        }

        /// The operator repairs drift that no other manager owns, without
        /// force, and its next plan writes nothing.
        #[tokio::test]
        async fn an_operator_repair_then_its_next_plan_writes_nothing() {
            let api = FakeApi::new([]);
            api.track_owners();
            let v1 = release(
                "a-v1",
                &[config_map("conf", "1"), deployment("scaled", true)],
            );
            cli_deploy(&api, &v1).await.unwrap();
            api.update_as("hpa", Some("scale"), "Deployment", "scaled", |o| {
                o["spec"]["replicas"] = json!(3);
            });
            // A field removed by hand has no owner left.
            api.patch_object("ConfigMap", "conf", |o| {
                o["data"] = json!({});
            });
            let plan = operator_plan(&api, &v1).await;
            assert_eq!(written(&plan.plan), ["conf"]);
            let result = operator_repair(&api, plan).await;
            assert_eq!((result.configured, result.failed), (1, 0), "{result:?}");
            let again = operator_plan(&api, &v1).await;
            assert_eq!((again.applies(), again.drift_not_reverted().len()), (0, 0));
            assert_eq!(
                api.object("Deployment", "scaled").unwrap()["spec"]["replicas"],
                json!(3)
            );
        }

        /// A forced revert of drift takes back only what the plan showed, so
        /// an edit made after the plan to a field it takes back stops the
        /// deploy rather than being overwritten.
        #[tokio::test]
        async fn a_forced_revert_stops_on_an_object_changed_after_the_plan() {
            let api = FakeApi::new([]);
            api.track_owners();
            let v1 = release("a-v1", &[deployment("web", false)]);
            cli_deploy(&api, &v1).await.unwrap();
            api.update_as("kubectl-edit", None, "Deployment", "web", |o| {
                o["spec"]["template"]["spec"]["image"] = json!("web:edited");
            });
            let checked = cli_plan(&api, &v1).await;
            assert_eq!(writes(&checked), ["web"]);
            // A second edit after the plan was made.
            api.update_as("kubectl-edit", None, "Deployment", "web", |o| {
                o["spec"]["template"]["spec"]["image"] = json!("web:later");
            });
            let client = api.client();
            let lock = crate::cluster::head::take(
                &client,
                crate::cluster::head::Request {
                    cluster: "a".into(),
                    holder: crate::cluster::head::Holder::cli("kix deploy"),
                    purpose: crate::cluster::head::Purpose::Deploy,
                    activation: checked.activation_name().map(str::to_string),
                    expect: None,
                },
                crate::cluster::head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap();
            let lock = Arc::new(lock);
            let target =
                crate::plan::Target::connect(client, crate::build_source::SopsSources::Local)
                    .await
                    .unwrap();
            let result = checked
                .run(
                    target,
                    lock.clone(),
                    None,
                    test_config(),
                    Arc::new(crate::cluster::stream::NullObserver),
                )
                .await;
            lock.release().await.unwrap();
            let failure = format!(
                "{:?}",
                result
                    .map(|r| r.failures)
                    .unwrap_or_else(|e| e.partial().failures.clone())
            );
            assert!(
                failure.contains("changed after the plan was made"),
                "{failure}"
            );
            assert_eq!(
                api.object("Deployment", "web").unwrap()["spec"]["template"]["spec"]["image"],
                json!("web:later")
            );
        }

        /// Return the failures a run reported, as text.
        fn failures_of(
            result: &Result<crate::cluster::stream::DeployResult, DeployError>,
        ) -> String {
            format!(
                "{:?}",
                match result {
                    Ok(r) => &r.failures,
                    Err(e) => &e.partial().failures,
                }
            )
        }

        /// A Deployment that `kubectl-edit` changed, planned as reverting
        /// drift.
        async fn drifted(api: &FakeApi) -> (StoreGraph, crate::plan::CheckedPlan) {
            api.track_owners();
            let v1 = release("a-v1", &[deployment("web", false)]);
            cli_deploy(api, &v1).await.unwrap();
            api.update_as("kubectl-edit", None, "Deployment", "web", |o| {
                o["spec"]["template"]["spec"]["image"] = json!("web:edited");
            });
            let checked = cli_plan(api, &v1).await;
            assert_eq!(writes(&checked), ["web"]);
            (v1, checked)
        }

        /// A controller writes the object's `status` after the plan, which
        /// moves its `resourceVersion` but not what the forced apply takes
        /// back, so the revert goes on.
        #[tokio::test]
        async fn a_forced_revert_goes_on_when_only_status_changed() {
            let api = FakeApi::new([]);
            let (_, checked) = drifted(&api).await;
            api.update_as(
                "deployment-controller",
                Some("status"),
                "Deployment",
                "web",
                |o| {
                    o["status"]["observedGeneration"] = json!(2);
                },
            );
            let result = cli_run(&api, checked).await;
            assert_eq!(failures_of(&result), "[]");
            assert_eq!(
                api.object("Deployment", "web").unwrap()["spec"]["template"]["spec"]["image"],
                json!("web:1")
            );
        }

        /// Another manager takes one more field the build sets after the
        /// plan, so the forced apply would take back more than the plan
        /// showed. Nothing is forced.
        #[tokio::test]
        async fn a_forced_revert_stops_when_another_field_is_taken() {
            let api = FakeApi::new([]);
            let (_, checked) = drifted(&api).await;
            api.update_as("kubectl-scale", None, "Deployment", "web", |o| {
                o["spec"]["replicas"] = json!(4);
            });
            let result = cli_run(&api, checked).await;
            assert!(
                failures_of(&result).contains("changed after the plan was made"),
                "{}",
                failures_of(&result)
            );
            let web = api.object("Deployment", "web").unwrap();
            assert_eq!(web["spec"]["replicas"], json!(4));
            assert_eq!(
                web["spec"]["template"]["spec"]["image"],
                json!("web:edited")
            );
        }

        /// The object changes once between the forced apply's read and its
        /// write: the apply reads it again, judges it again, and goes on.
        /// An object that changes every time fails with a bounded error.
        #[tokio::test]
        async fn a_forced_revert_reads_again_when_the_object_moves_under_it() {
            let api = FakeApi::new([]);
            let (_, checked) = drifted(&api).await;
            api.after_get("web", |o| {
                o["status"]["observedGeneration"] = json!(3);
            });
            let before = api.requests().len();
            let result = cli_run(&api, checked).await;
            assert_eq!(failures_of(&result), "[]");
            let forced = api.requests()[before..]
                .iter()
                .filter(|r| {
                    r.starts_with("PATCH")
                        && r.contains("/deployments/web?")
                        && r.contains("force=true")
                })
                .count();
            assert_eq!(forced, 2, "{:?}", &api.requests()[before..]);
            assert_eq!(
                api.object("Deployment", "web").unwrap()["spec"]["template"]["spec"]["image"],
                json!("web:1")
            );

            let api = FakeApi::new([]);
            let (_, checked) = drifted(&api).await;
            for _ in 0..20 {
                api.after_get("web", |o| {
                    o["status"]["observedGeneration"] = json!(4);
                });
            }
            let result = cli_run(&api, checked).await;
            assert!(
                failures_of(&result).contains("each of the 5 times"),
                "{}",
                failures_of(&result)
            );
            assert_eq!(
                api.object("Deployment", "web").unwrap()["spec"]["template"]["spec"]["image"],
                json!("web:edited")
            );
        }

        fn test_config() -> SchedulerConfig {
            SchedulerConfig {
                timeout: std::time::Duration::from_secs(5),
                on_error: crate::cluster::scheduler::OnErrorPolicy::Stop,
                cancel: crate::cluster::cancel::CancelToken::new(),
                concurrency: scheduler::CONCURRENCY,
                stall: crate::cluster::watchdog::StallPolicy::off(),
                check_unchanged: false,
                names_flags: false,
            }
        }

        /// An object whose build hash matches but whose applied hash Kix
        /// does not know is applied, and the run records the hash, so the
        /// next plan leaves the object alone.
        #[tokio::test]
        async fn an_object_without_an_applied_hash_is_applied_once() {
            let graph = build(&[config_map("web", "1")]);
            let (api, record) = cluster(&graph, &manifests(&graph)).await;
            // Kubernetes answers an apply with the fields the manager owns.
            api.on_apply("web", |obj| {
                obj["metadata"]["managedFields"] = json!([{
                    "manager": "kix/a",
                    "operation": "Apply",
                    "apiVersion": "v1",
                    "fieldsV1": { "f:data": { "f:k": {} } },
                }]);
            });
            let client = api.client();
            let desired = manifests(&graph);
            let set = RevisionSet::of("a", &graph);

            let plan = LivePlan::sweep(&client, &record, &desired, Some(set.clone()), false)
                .await
                .unwrap();
            assert_eq!((plan.applies(), plan.unchanged()), (1, 0));
            let lock = crate::cluster::head::take(
                &client,
                crate::cluster::head::Request {
                    cluster: "a".into(),
                    holder: crate::cluster::head::Holder::cli("kix deploy"),
                    purpose: crate::cluster::head::Purpose::Repair,
                    activation: Some("a-cur".into()),
                    expect: None,
                },
                crate::cluster::head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap();
            let lock = Arc::new(lock);
            plan.run(
                lock.clone(),
                false,
                test_config(),
                Arc::new(crate::cluster::stream::NullObserver),
            )
            .await
            .unwrap();
            lock.release().await.unwrap();

            let again = LivePlan::sweep(&client, &record, &desired, Some(set), false)
                .await
                .unwrap();
            assert_eq!((again.applies(), again.unchanged()), (0, 1));
        }
    }
}
