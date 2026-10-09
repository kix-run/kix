//! The operator's plan: a build against the live objects of its Kix cluster.
//!
//! The CLI plans against the builds the cluster's records name
//! ([`super::Planner`]). The operator plans against every live object of
//! its Kix cluster instead: those already include what failed and kept
//! deploys left, and the same loop corrects drift. [`LiveChanges::sweep`]
//! takes the Activation record being reconciled, opens the records and reads
//! the live objects itself, and [`LivePlan`] is made only from its result.
//! So the plan the operator runs is always one made from the live objects,
//! and the run writes the record it was made for. No check holds the plan to
//! a package diff.

use std::collections::BTreeMap;
use std::sync::Arc;

use kube::api::DynamicObject;
use kube::client::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;
use thiserror::Error;

use crate::cluster::activation::{Record, Records};
use crate::cluster::apply::{ChangeAction, detect_changes_live};
use crate::cluster::fetch::{self, FetchError, SharedOrphan};
use crate::cluster::graph::{GraphError, ResourceGraph};
use crate::cluster::ops::{ActivationRecord, Cluster, KubeResources, RecordConfig, SopsHydrator};
use crate::cluster::readiness::MalformedMarker;
use crate::cluster::scheduler::{self, DeployError, DeployPlan, SchedulerConfig};
use crate::cluster::stream::{DeployObserver, DeployResult};
use crate::cluster::tenancy::Tenancy;
use crate::legacy_domain::LegacyDomainError;
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

/// The Kix cluster an Activation record belongs to: its `kix.run/cluster`
/// label, which the compiler stamps on every record, else `spec.cluster`,
/// which a record built by Nix lacks until the CLI finalizes it.
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

/// Why [`LiveChanges::sweep`] or [`LiveChanges::plan`] made no plan.
#[derive(Debug, Error)]
pub enum LivePlanError {
    #[error(transparent)]
    Discovery(Box<FetchError>),
    /// The records sit under a retired group.
    #[error(transparent)]
    Domain(LegacyDomainError),
    #[error(transparent)]
    Sweep(Box<FetchError>),
    #[error(transparent)]
    Graph(GraphError),
    #[error(transparent)]
    Marker(MalformedMarker),
}

/// What a build changes against the live objects of one Kix cluster. Made
/// only by [`LiveChanges::sweep`].
pub struct LiveChanges {
    client: Client,
    discovery: Vec<(ApiResource, Scope)>,
    cluster: String,
    record: Record,
    desired: Vec<Value>,
    actions: Vec<ChangeAction>,
    orphans: Vec<ResourceId>,
    shared_orphans: Vec<SharedOrphan>,
    /// The live objects, which order the prune.
    live: Vec<Value>,
    applies: usize,
    foreign: BTreeMap<String, usize>,
    unattributed: usize,
}

impl LiveChanges {
    /// Read the live objects of the Kix cluster `activation` belongs to
    /// ([`cluster_of`]) and compare `desired` with them. A record that names
    /// no cluster sweeps under the empty name, under which no record counts
    /// as this cluster's own.
    pub async fn sweep(
        client: &Client,
        activation: &DynamicObject,
        desired: Vec<Value>,
    ) -> Result<LiveChanges, LivePlanError> {
        let cluster = cluster_of(activation).unwrap_or_default();
        let discovery = fetch::discover_resources(client)
            .await
            .map_err(|e| LivePlanError::Discovery(Box::new(e)))?;
        let records = Records::open(client, &discovery).map_err(LivePlanError::Domain)?;
        // Only this Kix cluster's objects: every other Kix cluster's objects
        // are absent from this build and would otherwise be pruned as
        // orphans.
        let sweep = fetch::sweep_managed(
            client,
            &discovery,
            &records,
            fetch::SweepScope::Cluster(&cluster),
        )
        .await
        .map_err(|e| LivePlanError::Sweep(Box::new(e)))?;

        let (actions, shared_orphans) = live_changes(&desired, &sweep.managed, &sweep.tenancy);
        let applies = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .count();
        let orphans: Vec<ResourceId> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect();

        Ok(LiveChanges {
            client: client.clone(),
            discovery,
            cluster,
            record: Record::of(activation),
            desired,
            actions,
            orphans,
            shared_orphans,
            live: sweep.managed.into_iter().map(|obj| obj.data).collect(),
            applies,
            foreign: sweep.foreign,
            unattributed: sweep.unattributed.len(),
        })
    }

    /// Objects the build applies.
    pub fn applies(&self) -> usize {
        self.applies
    }

    /// Objects the build leaves as they are.
    pub fn unchanged(&self) -> usize {
        self.actions.len() - self.applies - self.orphans.len()
    }

    /// Orphans the prune may delete.
    pub fn orphans(&self) -> &[ResourceId] {
        &self.orphans
    }

    /// Orphans another Kix cluster's current build still contains, which
    /// the prune keeps.
    pub fn shared_orphans(&self) -> &[SharedOrphan] {
        &self.shared_orphans
    }

    /// Live objects the sweep left out because they belong only to other
    /// Kix clusters, counted per owner.
    pub fn foreign(&self) -> &BTreeMap<String, usize> {
        &self.foreign
    }

    /// Live objects that name no record of any Kix cluster, which the sweep
    /// left out when another Kix cluster has records here.
    pub fn unattributed(&self) -> usize {
        self.unattributed
    }

    /// The engine plan for the changes.
    pub fn plan(self) -> Result<LivePlan, LivePlanError> {
        let graph = ResourceGraph::from_manifests(&self.desired).map_err(LivePlanError::Graph)?;
        let plan = DeployPlan::from_graph_and_changes(&graph, &self.actions)
            .map_err(LivePlanError::Marker)?;
        Ok(LivePlan {
            client: self.client,
            discovery: self.discovery,
            cluster: self.cluster,
            record: self.record,
            plan,
            orphans: self.orphans,
            live: self.live,
        })
    }
}

/// A build planned against the live objects of one Kix cluster. Made only
/// by [`LiveChanges::plan`]; run with [`LivePlan::run`].
pub struct LivePlan {
    client: Client,
    discovery: Vec<(ApiResource, Scope)>,
    cluster: String,
    record: Record,
    plan: DeployPlan,
    orphans: Vec<ResourceId>,
    live: Vec<Value>,
}

impl LivePlan {
    /// Run the engine over the plan, stamping the record's identity hash
    /// into `kix.run/activations` on every object it writes.
    ///
    /// With `manage_lifecycle` the run writes the record's lifecycle (begin,
    /// checkpoints, finalize); without, it corrects drift and leaves the
    /// record alone. The run never marks the record Failed: a reconcile that
    /// returns early is retried on requeue, and failing the record would
    /// fight that.
    pub async fn run(
        self,
        manage_lifecycle: bool,
        config: SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        let resources = Arc::new(KubeResources::new(
            self.client,
            self.discovery,
            self.cluster,
            self.record.identity_hash,
            // The operator runs unattended; surface conflicts in Activation
            // status rather than silently clobbering fields owned by other
            // controllers.
            false,
        ));
        let record = Arc::new(ActivationRecord::new(
            resources.clone(),
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
                mark_failed_on_abort: false,
            },
        ));
        let cluster = Cluster::new(resources, record, SopsHydrator::new(Default::default()));
        scheduler::run_deploy(
            cluster,
            self.plan,
            &self.orphans,
            &self.live,
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
    let (_, shared) = fetch::split_shared_orphans(orphans, live, tenancy);
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
    use crate::cluster::activation::PHASE_ACTIVE;
    use serde_json::json;

    fn annotated(kind: &str, name: &str, hash: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "d",
                "annotations": {
                    (keys::IDENTITY_HASH): hash,
                    (keys::ACTIVATIONS): activations,
                },
            },
        })
    }

    fn live(kind: &str, name: &str, hash: &str, activations: &str) -> DynamicObject {
        serde_json::from_value(annotated(kind, name, hash, activations)).unwrap()
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
        let sweep = fetch::scope_sweep(
            fetch::partition_sweep(objects.clone()),
            fetch::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        let (actions, shared) = live_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["a-stale"]);
        assert_eq!(shared.len(), 1);
        assert_eq!(shared[0].rid.name, "shared");

        // `b`'s reconcile, with `b`'s build unchanged, prunes nothing of `a`.
        let tenancy = Tenancy::fixture(&records, "b");
        let sweep = fetch::scope_sweep(
            fetch::partition_sweep(objects),
            fetch::SweepScope::Cluster("b"),
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

    /// One Kix cluster: every stale object is an orphan, as before scoping.
    #[test]
    fn reconcile_on_a_single_cluster_is_unchanged() {
        let tenancy = Tenancy::fixture(&[record("a", "a2")], "a");
        let objects = vec![
            live("ConfigMap", "a-web", "h-web", "a2"),
            live("ConfigMap", "leftover", "h-left", "retired"),
        ];
        let sweep = fetch::scope_sweep(
            fetch::partition_sweep(objects),
            fetch::SweepScope::Cluster("a"),
            tenancy.clone(),
        );
        let desired = [annotated("ConfigMap", "a-web", "h-web", "")];
        let (actions, _) = live_changes(&desired, &sweep.managed, &tenancy);
        assert_eq!(orphans(&actions), vec!["leftover"]);
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
