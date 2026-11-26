//! The operator's plan: a build against the live objects of its Kix cluster.
//!
//! The CLI plans against the builds the cluster's records name
//! ([`super::Planner`]). The operator plans against every live object of
//! its Kix cluster instead: those already include what failed and kept
//! deploys left, and the same loop corrects drift. [`LivePlan::sweep`]
//! takes the Activation record being reconciled, opens the records, reads
//! the live objects itself, and plans from them. Because [`LivePlan::sweep`]
//! is the only way to construct a [`LivePlan`], the operator always runs a
//! plan made from live objects and writes the record it was made for. No
//! check holds the plan to a package diff.

use std::sync::Arc;

use kube::api::DynamicObject;
use kube::client::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;
use thiserror::Error;

use crate::cluster::activation::{Record, Records};
use crate::cluster::apply::{ChangeAction, detect_changes_live};
use crate::cluster::discovery;
use crate::cluster::errors::FetchError;
use crate::cluster::graph::{GraphError, ResourceGraph};
use crate::cluster::inventory;
use crate::cluster::inventory::SharedOrphan;
use crate::cluster::ops::{Cluster, KubeResources, RecordConfig};
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
}

impl LivePlan {
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
    pub async fn sweep(
        client: &Client,
        activation: &DynamicObject,
        desired: &[Value],
        revisions: Option<RevisionSet>,
    ) -> Result<LivePlan, LivePlanError> {
        let cluster = cluster_of(activation).unwrap_or_default();
        let discovery = discovery::discover_resources(client)
            .await
            .map_err(|e| LivePlanError::Fetch(Box::new(e)))?;
        let records = Records::open(client, &discovery).map_err(LivePlanError::Domain)?;
        // Only this Kix cluster's objects: every other Kix cluster's objects
        // are absent from this build and would otherwise be pruned as
        // orphans.
        let sweep = inventory::sweep_managed(
            client,
            &discovery,
            &records,
            inventory::SweepScope::Cluster(&cluster),
        )
        .await
        .map_err(|e| LivePlanError::Fetch(Box::new(e)))?;

        let (actions, shared_orphans) = live_changes(desired, &sweep.managed, &sweep.tenancy);
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
            record: Record::of(activation),
            plan,
            orphans,
            shared_orphans,
            live: sweep.managed.iter().map(to_manifest_value).collect(),
            compared: actions.len(),
            foreign: sweep.foreign,
            unattributed: sweep.unattributed.len(),
            revisions,
        })
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

    /// Run the engine over the plan, stamping the record's identity hash
    /// into `kix.run/activations` on every object it writes. Every write
    /// goes through `lock`'s guarded client, and a run that manages the
    /// lifecycle commits the deploy on `lock`. The caller releases it.
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
                self.record.identity_hash,
                // The operator runs unattended; surface conflicts in
                // Activation status rather than silently clobbering fields
                // owned by other controllers.
                false,
            ),
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
                // Its orphans are live objects the next reconcile finds
                // again, so there are no builds to record.
                kept_orphans: Default::default(),
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

/// Compare desired manifests with this cluster's live objects by identity
/// hash, keeping out of the orphans every object another Kix cluster's
/// current build still contains.
fn live_changes(
    desired: &[Value],
    live: &[DynamicObject],
    tenancy: &Tenancy,
) -> (Vec<ChangeAction>, Vec<SharedOrphan>) {
    let actions = detect_changes_live(desired, live);
    let orphans: Vec<ResourceId> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Orphan(rid) => Some(rid.clone()),
            _ => None,
        })
        .collect();
    let (_, shared) = inventory::split_shared_orphans(orphans, live, tenancy);
    let actions = actions
        .into_iter()
        .filter(|a| match a {
            ChangeAction::Orphan(rid) => !shared.iter().any(|s| &s.rid == rid),
            _ => true,
        })
        .collect();
    (actions, shared)
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
        let (actions, shared) = live_changes(&desired, &sweep.managed, &tenancy);
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
        let (actions, shared) = live_changes(&desired, &sweep.managed, &tenancy);
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
        let (actions, _) = live_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["a-stale"]);
    }

    fn rerun_job(hash: &str) -> Value {
        let mut job = annotated("Job", "migrate", hash, "a2");
        job["apiVersion"] = json!("batch/v1");
        job["metadata"]["annotations"][keys::RERUN] = json!("on-change");
        job
    }

    fn failed(mut job: Value) -> Value {
        job["metadata"]["managedFields"] = json!([{ "manager": "kix", "operation": "Apply" }]);
        job["spec"] = json!({ "backoffLimit": 0 });
        job["status"] = json!({ "failed": 1 });
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
        let (actions, _) = live_changes(&desired, std::slice::from_ref(&live_job), &tenancy);
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
        let plan = LivePlan::sweep(&api.client(), &activation, &[], None)
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
}
