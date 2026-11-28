//! The plan of a deploy: everything it decides before it writes.
//!
//! [`Planner::run`] runs the steps `kix plan` and `kix deploy` share, so a
//! plan made with a deploy's flags is that deploy's plan:
//!
//! 1. the baseline: the closures the build is compared with (see
//!    [`super::baseline`]);
//! 2. the changes: for a Kix cluster read from revisions, what the one
//!    planner decides from the live objects and the cluster's records
//!    ([`super::decide`]); for any other, the build against the Active
//!    closure, with what failed and kept deploys left folded in;
//! 3. the plan: the engine plan, the package diff people review, and the
//!    check that refuses a write or delete the diff does not show
//!    ([`super::objects::of`]).
//!
//! A rollback runs [`Planner::rollback`], the last two steps, over the
//! baseline of the record it returns to ([`Baseline::of_record`]), and gets
//! the same [`Planned`] a deploy does. The planner prints
//! nothing: it reports what it finds through a [`PlanEvent`] callback.
//!
//! [`Planned`] is plain data: the build, its manifests, the baseline, and the
//! [`CheckedPlan`]. A [`CheckedPlan`] comes only from the check, its fields
//! are private, and after the check it changes only by the
//! `--record-annotation` values on the record ([`Planned::annotate_record`]),
//! the apiserver's answers in the package diff ([`Planned::overlay`]), and
//! orphans dropped from the prune ([`CheckedPlan::keep_shared`]).
//! [`CheckedPlan::dry_run`] runs the engine over it with every write sent as
//! a dry run, and [`CheckedPlan::run`] runs it for real, with the prune
//! policy, conflict handling, and Activation record the check used.
//!
//! The engine, `cluster::scheduler::run_deploy`, is private to the library.
//! The only other way to reach it is the operator's [`super::live::LivePlan`],
//! which plans from a sweep of the live objects it makes itself without
//! holding the plan to a package diff.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

use kube::client::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;

use crate::manifest::kinds::{self, GroupKind};

use super::baseline::Baseline;
use super::decide::{self, Label, Ledger};
use super::document::{DriftChange, LeftAlone, Objects, PlanFlags, WriteChange, WriteReason};
use super::objects;
use super::origin::FoldedBy;
use super::server::Overlay;
use super::{PackageDiff, PlanError, PlanEvent, UnknownInstances, diff_sent};
use crate::build_source::InstallableBuild;
use crate::build_source::SopsSources;
use crate::cluster::activation::{KeptOrphans, OpenedRecords, Record, Records, features};
use crate::cluster::apply::ChangeAction;
use crate::cluster::binding;
use crate::cluster::client::{self, ResiliencePolicy};
use crate::cluster::discovery;
use crate::cluster::edges::Prior;
use crate::cluster::errors;
use crate::cluster::errors::FetchError;
use crate::cluster::graph::DeleteOrder;
use crate::cluster::graph::ResourceGraph;
use crate::cluster::head::{self, HeadRead, Lock};
use crate::cluster::inventory;
use crate::cluster::inventory::SharedOrphan;
use crate::cluster::inventory::{Live, LiveObjects};
use crate::cluster::kubernetes_version;
use crate::cluster::migrate::{MigrationPair, detect_migration_pairs};
use crate::cluster::ops::ResourceIo;
use crate::cluster::ops::{
    Cluster, DryRun, Force, KubeResources, RecordConfig, kept_orphans_revision,
};
use crate::cluster::preview::{DryRunAnswer, DryRunOutcome, PruneAnswer};
use crate::cluster::revision::RevisionSet;
use crate::cluster::scheduler::{
    self, DeployError, DeployPlan, Ending, LastRuns, PrunePolicy, SchedulerConfig,
};
use crate::cluster::stream::{DeployObserver, DeployResult, NodeId};
use crate::eval::store_graph::StoreGraph;
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};

/// What [`Planner::run`] compares the new build with.
#[derive(Debug, Clone)]
pub enum OldSide {
    /// The build the local activation cache names, without connecting
    /// (`--offline`). The plan then cannot see failed records or
    /// orphans earlier deploys kept.
    LocalCache,
    /// The cluster's records, through the kube context `context` (`None`
    /// for the current one), with the transport policy `policy`.
    Cluster {
        context: Option<String>,
        policy: ResiliencePolicy,
    },
}

/// What a build changes on a cluster, before any of it is checked.
struct Changes {
    /// One per object of the build and per orphan.
    actions: Vec<ChangeAction>,
    /// The objects the build drops.
    orphans: Vec<ResourceId>,
    /// What the run's kept-orphans revision names besides the orphans the
    /// run leaves on the cluster.
    kept_orphans: KeptOrphans,
    /// The objects the run applies with force, the ones that revert drift.
    force: HashSet<ResourceId>,
    /// Why the run writes each object whose write the new build alone does
    /// not explain.
    reasons: HashMap<ResourceId, WriteReason>,
    /// The `Failed` and `Partial` records whose leftovers the plan takes
    /// in, or `None` when the plan compared builds and folded in the ones
    /// the baseline resolved.
    consumed: Option<Vec<String>>,
    /// The live objects of the orphans, as manifests, which order the prune
    /// and describe the kept orphans when no build on this machine has them.
    orphan_manifests: Vec<Value>,
    /// The objects that need the migration write.
    migrations: Migrations,
    /// The orphans that need the migration write. The run writes it to the
    /// ones it keeps.
    orphan_migrations: Vec<ResourceId>,
}

/// Where a plan runs: a connection to the cluster, its discovery read
/// through that connection, and the SOPS sources of this machine or the
/// build. Made only by [`Target::connect`], so the run's records are opened
/// from what that cluster serves.
pub struct Target {
    client: Client,
    discovery: Vec<(ApiResource, Scope)>,
    sops: SopsSources,
}

impl Target {
    /// Discover what the cluster behind `client` serves.
    pub async fn connect(client: Client, sops: SopsSources) -> Result<Target, FetchError> {
        let discovery = discovery::discover_resources(&client).await?;
        Ok(Target {
            client,
            discovery,
            sops,
        })
    }

    pub fn client(&self) -> &Client {
        &self.client
    }

    /// Return the API resources discovered when the target connected. The run
    /// refreshes discovery after CRDs land.
    pub fn discovery(&self) -> &[(ApiResource, Scope)] {
        &self.discovery
    }
}

/// The engine plan, the package diff people review, and the objects the
/// one writes and deletes as the other shows them. Made only by
/// [`Planner::plan`] and [`Planner::run`], after the check.
/// [`CheckedPlan::keep_shared`] later narrows the prune and the package
/// diff but leaves `objects` as reviewed, so it may list deletes that
/// will not run, never fewer.
pub struct CheckedPlan {
    flags: PlanFlags,
    plan: DeployPlan,
    /// The hashes of the new build's objects, which the run's conversion of
    /// an older Kix's records reads.
    build_hashes: crate::cluster::revision::convert::BuildHashes,
    orphans: Vec<ResourceId>,
    shared_orphans: Vec<SharedOrphan>,
    kept_orphans: KeptOrphans,
    pkg_diff: PackageDiff,
    objects: Objects,
    activation_name: Option<String>,
    activation_identity_hash: Option<String>,
    /// The Activation record's manifest, which the run creates before the
    /// first node. The plan applies the same manifest as its last node.
    record: Option<Value>,
    /// Failed records whose leftovers the plan folded in. Superseded when
    /// the run finalizes.
    consumed_failed: Vec<String>,
    /// The Kix cluster the check found its records and shared orphans by.
    /// The run finalizes its record and prunes under it.
    cluster: String,
    /// The baseline's manifests ([`Baseline::manifests`]) and the edges
    /// between them, which order the prune and fill the run's kept-orphans
    /// revision. A plan that read the cluster takes the edges from this Kix
    /// cluster's revisions ([`Ledger::edges`]), because some manifests may
    /// be live objects. A plan made with `--offline` read only builds, and
    /// takes them from their annotations.
    prior: Prior,
    /// The new build's revisions, which the run's record names. A plan
    /// made with `--only` names every instance of the build too.
    revisions: RevisionSet,
    /// What the checks a run makes when it connects after the plan
    /// (`--offline`) read from the new build.
    target_checks: TargetChecks,
    /// What a plan made with `--only` leaves for a later deploy, or `None`
    /// for a plan of the whole build.
    left_alone: Option<LeftAlone>,
    /// The instances that the instances `--only` names need, which a plan
    /// made with `--only` applies in full too. Empty otherwise.
    needed: Vec<String>,
    /// The objects the plan labels as reverting drift, each with what the
    /// API server answered its forced apply would take
    /// ([`CheckedPlan::ask_takes_back`]), or `None` until it was asked or
    /// when the answer is not known. The run applies an object with force
    /// only while the server gives that same answer, and an object without
    /// one without force.
    force: HashMap<ResourceId, Option<Vec<crate::cluster::drift::TakenField>>>,
    /// The migration writes the run makes.
    migrations: Migrations,
    /// A run of the plan first gives records an older Kix wrote revisions
    /// ([`crate::cluster::revision::convert`]).
    converts: bool,
}

/// What [`CheckedPlan::run`] passes to the engine about the migration write.
pub(crate) use crate::cluster::ops::Migrations;

/// What a run of a [`CheckedPlan`] would do ([`CheckedPlan::work`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Work {
    /// It writes nothing, prunes nothing, and no Job's last run failed.
    Nothing,
    /// It writes and prunes nothing, but it reports Jobs whose last run
    /// failed, or reads Jobs the plan could not read.
    JobsOnly,
    /// It writes or prunes.
    Changes,
}

/// Whether a run of a [`CheckedPlan`] starts ([`CheckedPlan::start`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Start {
    /// No run starts. `superseded` counts the failed records the plan
    /// folded in that are now marked Superseded. `unchanged` counts the
    /// plan's nodes, which a run would have reported unchanged.
    Nothing {
        superseded: usize,
        unchanged: usize,
    },
    Run,
}

/// Mark the Activation records named in `names` Superseded, and return how
/// many were marked.
async fn supersede(client: &Client, names: &[String]) -> usize {
    if names.is_empty() {
        return 0;
    }
    let Ok(discovery) = discovery::discover_resources(client).await else {
        return 0;
    };
    let Some(records) = Records::open(client, &discovery)
        .ok()
        .and_then(OpenedRecords::into_records)
    else {
        return 0;
    };
    let mut done = 0;
    for name in names {
        match records.supersede(name).await {
            Ok(()) => done += 1,
            Err(e) => tracing::warn!(activation = %name, error = %e, "could not supersede"),
        }
    }
    done
}

/// What the checks a command makes when it connects read from the new
/// build: the binding check ([`binding::check`]), the name check
/// ([`binding::check_name`]), and the Kubernetes version check
/// ([`kubernetes_version::check`]).
#[derive(Debug, Clone)]
pub struct TargetChecks {
    cluster: String,
    name_from_flake_key: bool,
    kubernetes_uid: Option<String>,
    kubernetes_version: Option<String>,
    kubernetes_version_from: Option<String>,
}

impl TargetChecks {
    /// Return the checks for the build `graph`.
    pub fn of(graph: &StoreGraph) -> Self {
        TargetChecks {
            cluster: graph.cluster_name.clone(),
            name_from_flake_key: graph.name_from_flake_key,
            kubernetes_uid: graph.kubernetes_uid.clone(),
            kubernetes_version: graph.kubernetes_version.clone(),
            kubernetes_version_from: graph.kubernetes_version_from.clone(),
        }
    }

    /// Refuse to deploy the build to the Kubernetes cluster behind `client`
    /// when it belongs to another one, when it would deploy a cluster that
    /// Kix 0.6 named `cluster` under a new name, or when it was checked
    /// against a Kubernetes version that cluster does not run.
    pub async fn run(
        &self,
        client: &Client,
        connection: &binding::Connection,
    ) -> Result<(), PlanError> {
        binding::check(
            client,
            connection,
            binding::Action::Deploy,
            &self.cluster,
            self.kubernetes_uid.as_deref(),
        )
        .await
        .map_err(|e| PlanError::Binding(Box::new(e)))?;
        binding::check_name(client, connection, &self.cluster, self.name_from_flake_key)
            .await
            .map_err(|e| PlanError::Binding(Box::new(e)))?;
        kubernetes_version::check(
            client,
            connection,
            &self.cluster,
            self.kubernetes_version.as_deref(),
            self.kubernetes_version_from.as_deref(),
        )
        .await
        .map_err(|e| PlanError::KubernetesVersion(Box::new(e)))
    }
}

impl CheckedPlan {
    /// Return the flags that the plan was made and checked with.
    pub fn flags(&self) -> &PlanFlags {
        &self.flags
    }

    /// Return the Kix cluster the plan was checked for.
    pub fn cluster(&self) -> &str {
        &self.cluster
    }

    /// Return what a plan made with `--only` leaves for a later deploy of
    /// the whole build, or `None` for a plan of the whole build.
    pub fn left_alone(&self) -> Option<LeftAlone> {
        self.left_alone
    }

    /// Return the instances that a plan made with `--only` applies in full
    /// because the named ones need them, sorted.
    pub fn needed(&self) -> &[String] {
        &self.needed
    }

    /// Return every instance a plan made with `--only` applies in full: the
    /// named ones and the ones they need, sorted.
    pub fn applied_instances(&self) -> Vec<String> {
        let mut all: Vec<String> = self
            .flags
            .only
            .iter()
            .chain(&self.needed)
            .cloned()
            .collect();
        all.sort();
        all.dedup();
        all
    }

    /// Return how a run of the plan ends once every node has a verdict.
    fn ending(&self) -> Ending {
        if self.flags.only.is_empty() {
            Ending::Finalize(self.flags.prune)
        } else {
            Ending::Partial
        }
    }

    pub fn plan(&self) -> &DeployPlan {
        &self.plan
    }

    /// Return which applies of a run take ownership of fields another field
    /// manager owns: every apply under `--force-conflicts`, else the applies
    /// of the objects the plan labels as reverting drift for which the API
    /// server said what the forced apply takes ([`CheckedPlan::ask_takes_back`]).
    pub(crate) fn force(&self) -> Force {
        let asked: HashMap<ResourceId, Vec<crate::cluster::drift::TakenField>> = self
            .force
            .iter()
            .filter_map(|(rid, taken)| Some((rid.clone(), taken.clone()?)))
            .collect();
        if self.flags.force_conflicts {
            Force::All
        } else if asked.is_empty() {
            Force::None
        } else {
            Force::Only(asked)
        }
    }

    /// Ask the API server behind `target`, for each object the plan labels as
    /// reverting drift, what its forced apply would take from other field
    /// managers ([`crate::cluster::apply::takes_back`]), and keep the answer
    /// for the run. The run applies an object with force only while the
    /// server gives it the same answer.
    ///
    /// Each object is asked with the manifest the run sends: its SOPS values
    /// decrypted from `target`'s sources, without each ceded field another
    /// manager holds, and under the name that owns Kix's fields when the
    /// run applies it. An object whose answer is not known keeps no answer,
    /// so the run applies it without force and Kubernetes refuses a conflict.
    /// [`CheckedPlan::dry_run`] calls this. A plan that was never asked
    /// applies every object without force, as a deploy with `--offline` does.
    pub async fn ask_takes_back(&mut self, target: &Target) {
        use crate::cluster::ops::SecretHydrator as _;
        let hydrator = crate::cluster::ops::SopsHydrator::new(target.sops.clone());
        let manifests: HashMap<ResourceId, Value> = self
            .plan
            .nodes()
            .iter()
            .filter_map(|n| match &n.id {
                NodeId::Resource(rid) if self.force.contains_key(rid) => {
                    Some((rid.clone(), n.action.written()?.clone()))
                }
                _ => None,
            })
            .collect();
        for (rid, taken) in &mut self.force {
            *taken = None;
            let Some(manifest) = manifests.get(rid) else {
                continue;
            };
            let Ok((manifest, _)) = hydrator.hydrate(manifest.clone()).await else {
                continue;
            };
            let Some((ar, scope)) = discovery::find(&target.discovery, &rid.group, &rid.kind)
            else {
                continue;
            };
            let manager = if self.migrations.renamed.contains(rid) {
                crate::cluster::field_manager::FieldManager::legacy_for(&self.cluster)
            } else {
                crate::cluster::field_manager::FieldManager::of(&self.cluster)
            };
            let api = discovery::api_for(&target.client, ar, scope, rid);
            *taken = ask(&api, rid, &manager, &manifest).await;
        }
    }

    /// Return the orphans that this cluster's prune may delete. Orphans that
    /// another Kix cluster still deploys are in [`CheckedPlan::shared_orphans`].
    pub fn orphans(&self) -> &[ResourceId] {
        &self.orphans
    }

    pub fn shared_orphans(&self) -> &[SharedOrphan] {
        &self.shared_orphans
    }

    /// Return each CustomResourceDefinition that the build no longer
    /// declares, by name, with the orphan that declared it: the definition
    /// itself, or else a reference to it (`scope.mkCRDRef`). A definition
    /// that an object staying in the build, or an object the new build adds,
    /// still declares is not listed.
    pub fn kinds_leaving(&self) -> Vec<(ResourceId, String)> {
        let added = self.plan.nodes().iter().filter_map(|n| n.action.written());
        kinds_leaving(&self.prior.manifests, &self.orphans, added)
    }

    /// Return the package-grouped comparison of the old side with the new build.
    pub fn pkg_diff(&self) -> &PackageDiff {
        &self.pkg_diff
    }

    /// Mark as modified each write of an unchanged file that the package
    /// diff now lists as changed. A dry run finds such a change when the
    /// live object differs from the build, as after a stopped deploy, so the
    /// write changes the object and the objects list says what the package
    /// view says.
    fn relabel_reverted_writes(&mut self) {
        let changed: HashSet<&ResourceId> = self
            .pkg_diff
            .changed
            .iter()
            .chain(&self.pkg_diff.cluster_level)
            .flat_map(|c| c.resource_diffs.iter().map(|(id, _)| id))
            .collect();
        for write in &mut self.objects.writes {
            if write.change == WriteChange::Reapplied && changed.contains(&write.resource_id()) {
                write.change = WriteChange::Modified;
            }
        }
    }

    /// Return every object the plan writes and the prune deletes; see
    /// [`super::objects`].
    pub fn objects(&self) -> &Objects {
        &self.objects
    }

    /// Return the name of the new build's Activation record.
    pub fn activation_name(&self) -> Option<&str> {
        self.activation_name.as_deref()
    }

    /// Return the identity hash of the new build's Activation record.
    pub fn activation_identity_hash(&self) -> Option<&str> {
        self.activation_identity_hash.as_deref()
    }

    /// Return the new build's `cluster.kubernetes.uid`, or `None` when its
    /// definition is not bound to one Kubernetes cluster.
    pub fn kubernetes_uid(&self) -> Option<&str> {
        self.target_checks.kubernetes_uid.as_deref()
    }

    /// Return the checks a command makes when it connects to the cluster
    /// after the plan was made without connecting.
    pub fn target_checks(&self) -> &TargetChecks {
        &self.target_checks
    }

    /// Return what a run of the plan would do, given what reading its Jobs'
    /// last runs found. Only [`CheckedPlan::read_last_runs`] gives a
    /// [`LastRuns`], so this cannot be asked before the plan has read the
    /// cluster.
    pub fn work(&self, last_runs: &LastRuns) -> Work {
        let writes = self
            .plan
            .nodes()
            .iter()
            .any(|n| n.action.written().is_some());
        if writes
            || !self.orphans.is_empty()
            || self.migrations.count() > 0
            || !self.migrations.releases.is_empty()
            || self.converts
        {
            return Work::Changes;
        }
        match last_runs {
            LastRuns::Read { failed } if failed.is_empty() => Work::Nothing,
            _ => Work::JobsOnly,
        }
    }

    /// Decide whether a run of the plan starts, given what reading its Jobs'
    /// last runs found. A run that finalizes supersedes the failed records
    /// the plan folded in. When there is nothing to do, no run starts, so
    /// this supersedes them through `client` itself. A record it cannot
    /// supersede is logged and folded in again by the next deploy.
    pub async fn start(&self, client: &Client, last_runs: &LastRuns) -> Start {
        match self.work(last_runs) {
            Work::Nothing => Start::Nothing {
                superseded: supersede(client, &self.consumed_failed).await,
                unchanged: self.plan.nodes().len(),
            },
            Work::JobsOnly | Work::Changes => Start::Run,
        }
    }

    /// Read the last runs of the plan's Jobs on the cluster behind `client`.
    /// A Job under `kix.run/rerun` whose last run failed runs again, and an
    /// unchanged Job without it is listed in [`LastRuns::Read`]. Every
    /// command that runs a plan calls this once it has a client, before it
    /// prints the plan's reruns or decides whether to start.
    pub async fn read_last_runs(&mut self, client: &Client) -> Result<LastRuns, PlanError> {
        let last_runs = if self.plan.reads_last_runs() {
            let discovery = discovery::discover_resources(client)
                .await
                .map_err(|e| PlanError::Discovery(Box::new(e)))?;
            self.plan.read_last_runs(client, &discovery).await
        } else {
            LastRuns::Read { failed: Vec::new() }
        };
        self.count_reruns();
        Ok(last_runs)
    }

    /// Read the last runs of the plan's Jobs in `live`, the objects a plan
    /// made while connected listed.
    fn last_runs_from(&mut self, live: &LiveObjects) -> LastRuns {
        let last_runs = self.plan.last_runs_from(live);
        self.count_reruns();
        last_runs
    }

    /// Count as a certain write each Job that its failed last run makes run
    /// again. The digest leaves out how a write is shown, so it stays the
    /// same.
    fn count_reruns(&mut self) {
        let recreated: HashSet<&ResourceId> = self
            .plan
            .nodes()
            .iter()
            .filter(|n| matches!(n.action, ChangeAction::Recreate(..)))
            .filter_map(|n| match &n.id {
                NodeId::Resource(rid) => Some(rid),
                _ => None,
            })
            .collect();
        for w in &mut self.objects.writes {
            if w.change == WriteChange::IfLastRunFailed && recreated.contains(&w.resource_id()) {
                w.change = WriteChange::Reapplied;
            }
        }
    }

    /// Return how many objects the run moves to this Kix's bookkeeping with
    /// the migration write ([`crate::cluster::migration_write`]).
    pub fn metadata_rewrites(&self) -> usize {
        self.migrations.count()
    }

    /// Return the failed Activation records whose leftovers the plan folded
    /// in. A run that finalizes supersedes them.
    pub fn consumed_failed(&self) -> &[String] {
        &self.consumed_failed
    }

    /// Remove orphans that another Kix cluster still deploys ([`keep_shared`])
    /// from the prune set and package diff on a plan made without a client
    /// (`--offline`).
    pub fn keep_shared(&mut self, shared: &[SharedOrphan]) {
        self.orphans
            .retain(|rid| !shared.iter().any(|s| &s.rid == rid));
        self.pkg_diff.keep_shared(shared);
        self.shared_orphans.extend(shared.iter().cloned());
        // The run releases each one, or its record keeps naming it.
        self.migrations
            .releases
            .extend(shared.iter().map(|s| s.rid.clone()));
    }

    /// Return the order in which the prune deletes the plan's orphans.
    pub(crate) fn prune_order(&self) -> DeleteOrder {
        scheduler::prune_order(&self.orphans, &self.prior)
    }

    /// Run the engine over the plan with every write sent as a dry run, and
    /// return what the apiserver answered for each object. First ask what
    /// each forced apply takes ([`CheckedPlan::ask_takes_back`]), which the
    /// dry run and a later run check against. Nothing is written to the
    /// Activation record. The prune follows the plan's flags.
    pub async fn dry_run(
        &mut self,
        target: Target,
        config: SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> (Result<DeployResult, DeployError>, Vec<DryRunAnswer>) {
        self.ask_takes_back(&target).await;
        let dry = Arc::new(DryRun::new(
            target.client,
            target.discovery,
            self.cluster.clone(),
            self.force(),
            target.sops,
            self.migrations.clone(),
        ));
        let result = scheduler::run_deploy(
            Cluster::dry_run(dry.clone()),
            self.plan.clone(),
            &self.orphans,
            &self.prior,
            self.ending(),
            &config,
            observer,
        )
        .await;
        let mut answers = dry.take_answers();
        read_prune_controllers(&mut answers, &self.prune_order(), &*dry).await;
        (result, answers)
    }

    /// Run the engine over the checked plan, writing its Activation record
    /// with `receipt` as the provenance. Every write goes through `lock`'s
    /// guarded client, and the finalize commits the deploy on `lock`. The
    /// caller releases it. The prune follows the flags the check used.
    pub async fn run(
        self,
        target: Target,
        lock: Arc<Lock>,
        receipt: Option<Value>,
        config: SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> Result<DeployResult, DeployError> {
        let ending = self.ending();
        let only = self.applied_instances();
        let force = self.force();
        lock.stop_with(&config.cancel);
        let (cluster, _) = Cluster::new(
            KubeResources::new(
                lock.guarded(&target.client),
                target.discovery,
                self.cluster,
                force,
            )
            .with_migrations(self.migrations)
            .with_recording(crate::cluster::ops::Recording::of_revisions(
                &self.revisions,
            )),
            RecordConfig {
                name: self.activation_name,
                // Created before the first node so a run that stops partway
                // leaves a record of what it was attempting. The plan applies
                // this same manifest again as its last node, which is then an
                // unchanged no-op.
                manifest: self.record,
                receipt,
                consumed_failed: self.consumed_failed,
                kept_orphans: self.kept_orphans,
                revisions: Some(self.revisions),
                build_hashes: self.build_hashes,
                only,
                mark_failed_on_abort: true,
                lock: Some(lock),
            },
            target.sops,
        );
        scheduler::run_deploy(
            cluster,
            self.plan,
            &self.orphans,
            &self.prior,
            ending,
            &config,
            observer,
        )
        .await
    }
}

/// Return the name of the Activation record of the build `graph`.
fn record_name(graph: &StoreGraph) -> Option<String> {
    graph
        .resources
        .values()
        .map(|r| &r.manifest)
        .find(|m| lifecycle::is_record(m))
        .and_then(|m| m.pointer("/metadata/name"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// Return what a forced apply of `manifest` under `manager` would take from
/// other field managers on the object `rid`, read now, or `None` when Kix
/// cannot tell: the object is gone, the API server refused the question, the
/// answer names a field the object does not hold, or the object kept moving.
/// Return `None` too when the answer names a field another Kix cluster
/// holds, so the run applies the object without force and Kubernetes
/// refuses the conflict. Kix never forces a field away from another Kix
/// cluster.
async fn ask(
    api: &kube::Api<kube::api::DynamicObject>,
    rid: &ResourceId,
    manager: &crate::cluster::field_manager::FieldManager,
    manifest: &Value,
) -> Option<Vec<crate::cluster::drift::TakenField>> {
    use crate::cluster::apply::{self, Takes};
    use crate::cluster::field_manager::Manager;
    for _ in 0..apply::TAKEOVER_ATTEMPTS {
        let live = api.get_opt(&rid.name).await.ok()??;
        let sent = apply::bound_to(apply::forced_manifest(manifest, &live, manager), &live);
        match apply::takes_back(api, &rid.name, manager, &sent, &live).await {
            Ok(Takes::Fields(taken)) => {
                let other_cluster = |name: &str| {
                    Manager::parse(name).is_kix() && !manager.counts_as_own(Some(name))
                };
                return (!taken.iter().any(|t| other_cluster(&t.manager))).then_some(taken);
            }
            Ok(Takes::Moved) => continue,
            Ok(Takes::Unknown) | Err(_) => return None,
        }
    }
    None
}

/// Read the deploy lock of Kix cluster `cluster`, which a plan binds to, or
/// `None` when the account may not read it.
async fn read_head(client: &Client, cluster: &str) -> Result<Option<HeadRead>, PlanError> {
    match head::read(client, cluster).await {
        Ok(found) => Ok(Some(HeadRead::of(found.as_ref()))),
        Err(e) if errors::classify(&e) == errors::FailureClass::Forbidden => {
            tracing::warn!(
                cluster,
                "this account cannot read ActivationHead; skipping deploy lock check for this plan"
            );
            Ok(None)
        }
        Err(e) => Err(PlanError::ReadHead(Box::new(e))),
    }
}

/// Read the controllers of each object whose prune delete will wait for a
/// finalizer, so the plan can say whether something runs that removes it.
/// `order` names the controllers of each orphan.
async fn read_prune_controllers(
    answers: &mut [DryRunAnswer],
    order: &DeleteOrder,
    resources: &dyn ResourceIo,
) {
    for answer in answers {
        let DryRunOutcome::Pruned(PruneAnswer::Deleted(wait)) = &mut answer.outcome else {
            continue;
        };
        if wait.finalizers.is_empty() {
            continue;
        }
        for id in order.controllers().get(&answer.rid).into_iter().flatten() {
            wait.controllers
                .push(scheduler::read_controller(resources, id).await);
        }
    }
}

/// Everything a deploy decides before it writes. Made only by
/// [`Planner::run`].
pub struct Planned {
    /// The new build, stamped, and refused if it would install Kix's own
    /// CRDs under a retired group.
    pub build: InstallableBuild,
    /// The build's manifests, with the `--record-annotation` values on the
    /// record once [`Planned::annotate_record`] has run.
    // Private so that annotate_record, which refuses Kix's own keys, is the
    // only way to change it.
    new_manifests: Vec<Value>,
    /// `None` under [`OldSide::LocalCache`], which plans without connecting.
    pub connected: Option<Connected>,
    pub baseline: Baseline,
    /// Against the Active closure only.
    pub migration_pairs: Vec<MigrationPair>,
    pub checked: CheckedPlan,
}

/// What a plan made while connected to the cluster read there.
pub struct Connected {
    pub client: Client,
    /// Which Kubernetes cluster `client` talks to, as the kubeconfig names it.
    pub connection: binding::Connection,
    pub last_runs: LastRuns,
    /// The Kix cluster's deploy lock as the plan read it, which the run
    /// binds to. `None` when the account may not read it; the run then
    /// fails when it takes the lock.
    pub head: Option<HeadRead>,
}

impl Planned {
    /// Return the client of a plan made while connected, or `None` for one
    /// made from the local cache.
    pub fn client(&self) -> Option<&Client> {
        self.connected.as_ref().map(|c| &c.client)
    }

    /// Return [`crate::build_source::Build::sops_sources`] for the new build.
    pub fn sops_sources(&mut self, placeholders: bool) -> Result<SopsSources, String> {
        self.build.sops_sources(placeholders)
    }

    pub fn new_manifests(&self) -> &[Value] {
        &self.new_manifests
    }

    /// Write `--record-annotation` pairs onto the Activation record, both
    /// where the engine creates it before the first node and where the plan
    /// applies it last, so the two stay the same manifest. The record's
    /// lifecycle writes are outside the objects check.
    ///
    /// Refuses a key under Kix's own domain ([`keys::is_kix_domain_key`]):
    /// Kix reads those off the record, the identity hash among them, and the
    /// check was made with the record's own values.
    pub fn annotate_record(&mut self, annotations: &[(String, String)]) -> Result<(), String> {
        if let Some((key, _)) = annotations
            .iter()
            .find(|(key, _)| keys::is_kix_domain_key(key))
        {
            return Err(format!(
                "the record annotation '{key}' is not allowed: Kix writes the keys under {} on the record",
                keys::DOMAIN
            ));
        }
        self.set_record_annotations(annotations);
        Ok(())
    }

    /// Write [`keys::WITHDRAWN_KIX`] onto the Activation record, so the
    /// record shows that a withdrawn Kix wrote it on purpose.
    pub fn note_withdrawn_kix(&mut self, version: &crate::version::Version) {
        self.set_record_annotations(&[(keys::WITHDRAWN_KIX.to_string(), version.release())]);
    }

    /// Write [`keys::DOWNGRADED_FROM`] onto the Activation record, so the
    /// record shows that an older minor of Kix wrote it on purpose over a
    /// cluster that Kix `from` deployed last.
    pub fn note_downgrade(&mut self, from: &crate::version::Version) {
        self.set_record_annotations(&[(keys::DOWNGRADED_FROM.to_string(), from.release())]);
    }

    fn set_record_annotations(&mut self, annotations: &[(String, String)]) {
        if annotations.is_empty() {
            return;
        }
        let annotate = |manifest: &mut Value| {
            if !lifecycle::is_record(manifest) {
                return;
            }
            let meta = manifest
                .as_object_mut()
                .and_then(|m| m.get_mut("metadata"))
                .and_then(Value::as_object_mut);
            if let Some(meta) = meta {
                let map = meta
                    .entry("annotations")
                    .or_insert_with(|| Value::Object(Default::default()));
                if let Some(map) = map.as_object_mut() {
                    for (k, v) in annotations {
                        map.insert(k.clone(), Value::String(v.clone()));
                    }
                }
            }
        };
        self.new_manifests.iter_mut().for_each(annotate);
        self.checked.record.iter_mut().for_each(annotate);
        for node in self.checked.plan.nodes.iter_mut() {
            if let ChangeAction::Apply(manifest) | ChangeAction::Recreate(manifest, _) =
                &mut node.action
            {
                annotate(manifest);
            }
        }
    }

    /// Replace the package diff's entries with what the apiserver answered
    /// in a dry run (`Overlay`), and return the drift the deploy reverts and
    /// the values deploys that did not finish wrote, which the plan folded
    /// in. `None` when the deployed build's manifests are not known (the old
    /// side was rebuilt from the live objects), so a commit's change and
    /// drift look the same; a first deploy has no deployed build and every
    /// change is intended.
    pub fn overlay(&mut self, answers: &[DryRunAnswer]) -> Option<Differences> {
        let baseline = &self.baseline;
        let first_deploy = baseline.active_hash().is_none() && baseline.active_manifests.is_empty();
        let deployed = (baseline.active_graph().is_some() || first_deploy).then(|| {
            baseline
                .active_manifests
                .iter()
                .map(|m| (ResourceId::from_value(m), m))
                .collect()
        });
        let known = deployed.is_some();
        let failed = baseline.failed();
        let mut folded: HashMap<ResourceId, Vec<(FoldedBy, &Value)>> = HashMap::new();
        for (closure, source) in failed.closures.iter().zip(&failed.sources) {
            let by = FoldedBy {
                record: source.activation.clone(),
                partly_deployed: failed.partly_deployed.contains(&source.activation),
            };
            for manifest in closure {
                folded
                    .entry(ResourceId::from_value(manifest))
                    .or_default()
                    .push((by.clone(), manifest));
            }
        }
        let found = Overlay {
            new_graph: self.build.graph(),
            deployed,
            folded,
            manager: baseline
                .tenancy
                .manager_of(&self.build.graph().cluster_name),
        }
        .apply(&mut self.checked.pkg_diff, answers);
        self.checked.relabel_reverted_writes();
        known.then_some(Differences {
            drift: found.drift,
            earlier: found.earlier,
        })
    }
}

/// The fields where the live cluster differs from the deployed build, from
/// [`Planned::overlay`].
#[derive(Debug, Default)]
pub struct Differences {
    /// Drift the deploy reverts.
    pub drift: Vec<DriftChange>,
    /// Values that deploys the plan folded in wrote.
    pub earlier: Vec<super::document::EarlierDeployChange>,
}

/// A plan made again from the live cluster after a plan made offline was
/// confirmed ([`Planner::recheck`]).
pub struct Replanned {
    pub checked: CheckedPlan,
    pub connected: Connected,
}

/// Makes the plan of a deploy with `flags`, reporting what it finds to
/// `report`.
pub struct Planner<'a> {
    flags: PlanFlags,
    report: &'a dyn Fn(PlanEvent<'_>),
    settle: Option<Settle>,
}

/// The command a [`Planner`] plans for when it settles a held deploy lock
/// before it reads the cluster ([`Planner::settling`]).
#[derive(Debug, Clone)]
pub struct Settle {
    /// What a user typed, such as `kix deploy`, for the lock's hint.
    pub command: &'static str,
    pub purpose: head::Purpose,
}

impl<'a> Planner<'a> {
    /// Make a planner for `flags`. [`PlanFlags::only`] is sorted and holds
    /// each name once, whatever the caller passed.
    pub fn new(mut flags: PlanFlags, report: &'a dyn Fn(PlanEvent<'_>)) -> Self {
        flags.only = PlanFlags::only_of(&flags.only);
        Planner {
            flags,
            report,
            settle: None,
        }
    }

    /// Settle a deploy lock another run holds before reading the cluster,
    /// for a command that will take the lock ([`head::settle`]): refuse when
    /// the holder is alive, and take a dead holder's lock over and release
    /// it, so the plan reads the state the takeover left. `kix plan` does
    /// not settle: a read never waits for the lock.
    pub fn settling(mut self, settle: Settle) -> Self {
        self.settle = Some(settle);
        self
    }

    /// Plan a deploy of `build` against `old`: connect, unless the old side
    /// is the local cache, run [`TargetChecks::run`] against the Kubernetes
    /// cluster it connected to, then the three steps.
    pub async fn run(&self, build: InstallableBuild, old: &OldSide) -> Result<Planned, PlanError> {
        let new_graph = build.graph();
        let client = match old {
            OldSide::LocalCache => None,
            OldSide::Cluster { context, policy } => {
                let connection = binding::Connection::of_context(context.as_deref());
                (self.report)(PlanEvent::Connecting(&connection));
                let client = client::make_client(context.as_deref(), policy.clone())
                    .await
                    .map_err(|e| PlanError::Connect(Box::new(e)))?;
                TargetChecks::of(new_graph)
                    .run(&client, &connection)
                    .await?;
                if let Some(settle) = &self.settle {
                    self.take_back(&client, new_graph, settle).await?;
                    refuse_older_operator(&client, &new_graph.cluster_name).await?;
                    self.settle_lock(&client, new_graph, settle).await?;
                }
                Some((client, connection))
            }
        };
        let baseline = match &client {
            Some((client, connection)) => {
                let baseline = Baseline::of_cluster(client, &build, self.report).await?;
                self.note_unbound(client, connection, new_graph, &baseline)
                    .await;
                baseline
            }
            None => Baseline::of_cache(&new_graph.cluster_name, self.report),
        };
        self.planned(build, baseline, client).await
    }

    /// Plan `build` again from the live cluster behind `client`, after
    /// `confirmed`, the plan of `build` made offline (`--offline`), was
    /// confirmed. `new_manifests` are the manifests that plan was made from,
    /// with the values `--record-annotation` put on the record.
    ///
    /// Return the plan made from the live cluster, which the run uses, or
    /// refuse when it writes or deletes other objects than `confirmed`
    /// ([`super::offline::compare`]). The caller has already run the target
    /// checks, and takes the deploy lock only after this returns.
    pub async fn recheck(
        &self,
        confirmed: &CheckedPlan,
        build: &InstallableBuild,
        new_manifests: &[Value],
        client: Client,
        connection: binding::Connection,
    ) -> Result<Replanned, PlanError> {
        let graph = build.graph();
        let cluster = &graph.cluster_name;
        if let Some(settle) = &self.settle {
            self.take_back(&client, graph, settle).await?;
            refuse_older_operator(&client, cluster).await?;
            self.settle_lock(&client, graph, settle).await?;
        }
        let baseline = Baseline::of_cluster(&client, build, self.report).await?;
        let ledger = ledger_for(&client, &baseline, new_manifests).await?;
        let head = read_head(&client, cluster).await?;
        let live = read_live(&client, &listed_ids(new_manifests, Some(&ledger))).await?;
        let mut checked = self
            .check(
                graph,
                new_manifests,
                cluster,
                &baseline,
                Some((&client, &live)),
                Some(&ledger),
            )
            .await?;
        super::offline::compare(
            cluster,
            &connection,
            confirmed.objects(),
            checked.objects(),
            checked.shared_orphans(),
        )
        .map_err(PlanError::OfflinePlanDiffers)?;
        let last_runs = checked.last_runs_from(&live);
        Ok(Replanned {
            checked,
            connected: Connected {
                client,
                connection,
                last_runs,
                head,
            },
        })
    }

    /// Settle a lock another run holds on the Kix cluster of `graph`, saying
    /// first who holds it ([`PlanEvent::LockHeld`]). A dead run's record is
    /// continued rather than marked `Failed` when it is this build's record.
    /// With [`PlanFlags::operator_removed`], take Kix cluster `cluster` back
    /// from the Kix operator ([`features::take_back`]) under its deploy lock,
    /// before the plan reads the records. Take the lock only when a record
    /// needs it, and read the records again under it. The writes raise the
    /// lock's generation when it is released, so a plan made before them is
    /// refused at its take.
    pub(crate) async fn take_back(
        &self,
        client: &Client,
        graph: &StoreGraph,
        settle: &Settle,
    ) -> Result<(), PlanError> {
        if !self.flags.operator_removed {
            return Ok(());
        }
        let cluster = graph.cluster_name.as_str();
        let failed = |e: features::TakeBackError| PlanError::TakeBack {
            cluster: cluster.to_string(),
            source: Box::new(e),
        };
        let discovery = discovery::discover_resources(client)
            .await
            .map_err(|e| PlanError::Discovery(Box::new(e)))?;
        let opened = Records::open(client, &discovery).map_err(PlanError::Domain)?;
        let Some(records) = opened.records() else {
            return Ok(());
        };
        let driven = features::driven_by_older_operator(client, records, cluster)
            .await
            .map_err(|e| failed(e.into()))?;
        if driven.is_empty() {
            (self.report)(PlanEvent::NothingToTakeBack { cluster });
            return Ok(());
        }
        // The same request as the lock the deploy settles next, so a dead run
        // of this build is continued here too rather than marked `Failed`.
        let request = head::Request {
            cluster: cluster.to_string(),
            holder: head::Holder::cli(settle.command),
            purpose: settle.purpose,
            activation: record_name(graph),
            expect: None,
        };
        let held = head::read(client, cluster)
            .await
            .map_err(|e| PlanError::ReadHead(Box::new(e)))?
            .and_then(|h| h.lock().cloned());
        if let Some(held) = &held {
            (self.report)(PlanEvent::LockHeld(held));
        }
        let lock = head::take(client, request, head::system_clock(), &|_| {})
            .await
            .map_err(|e| PlanError::Lock(Box::new(e)))?;
        let guarded = lock.guarded(client);
        let taken = features::take_back(&guarded, &records.through(&guarded), cluster).await;
        let released = lock.release().await;
        let taken = taken.map_err(failed)?;
        released.map_err(|e| PlanError::Lock(Box::new(e.into())))?;
        if taken.is_empty() {
            (self.report)(PlanEvent::NothingToTakeBack { cluster });
        } else {
            (self.report)(PlanEvent::TookBack {
                cluster,
                taken: &taken,
            });
        }
        Ok(())
    }

    async fn settle_lock(
        &self,
        client: &Client,
        graph: &StoreGraph,
        settle: &Settle,
    ) -> Result<(), PlanError> {
        let cluster = &graph.cluster_name;
        let held = head::read(client, cluster)
            .await
            .map_err(|e| PlanError::ReadHead(Box::new(e)))?
            .and_then(|h| h.lock().cloned());
        let Some(held) = held else {
            return Ok(());
        };
        (self.report)(PlanEvent::LockHeld(&held));
        let request = head::Request {
            cluster: cluster.clone(),
            holder: head::Holder::cli(settle.command),
            purpose: settle.purpose,
            activation: record_name(graph),
            expect: None,
        };
        head::settle(client, request, head::system_clock(), &|_| {})
            .await
            .map_err(|e| PlanError::Lock(Box::new(e)))
    }

    /// Report [`PlanEvent::Unbound`] on the first deploy of a build whose
    /// definition names no Kubernetes cluster. A cluster with an Active
    /// record was deployed here before, so the note would only repeat.
    async fn note_unbound(
        &self,
        client: &Client,
        connection: &binding::Connection,
        graph: &StoreGraph,
        baseline: &Baseline,
    ) {
        if graph.kubernetes_uid.is_some() || baseline.active().is_some() {
            return;
        }
        let uid = binding::live_uid(client).await.ok();
        (self.report)(PlanEvent::Unbound {
            cluster: &graph.cluster_name,
            connection,
            uid: uid.as_deref(),
        });
    }

    /// Plan a rollback of Kix cluster `cluster` from its current record
    /// `current` to `build`, the build of an earlier record, through `client`,
    /// which talks to the Kubernetes cluster of `connection`.
    /// The baseline is [`Baseline::of_record`]. The rollback command makes
    /// its own target checks before this, because a rollback must not be
    /// refused for a Kubernetes upgrade during an incident.
    pub async fn rollback(
        &self,
        build: InstallableBuild,
        records: &Records,
        current: &Record,
        client: Client,
        connection: binding::Connection,
    ) -> Result<Planned, PlanError> {
        let cluster = build.graph().cluster_name.clone();
        refuse_older_operator(&client, &cluster).await?;
        let baseline = Baseline::of_record(records, &cluster, current, self.report).await?;
        self.planned(build, baseline, Some((client, connection)))
            .await
    }

    /// Plan `build` against `baseline`. With a client, first list the
    /// build's objects on the cluster ([`read_live`]), so the plan writes
    /// again each unchanged object the cluster no longer holds and reads
    /// the last runs of its Jobs.
    async fn planned(
        &self,
        build: InstallableBuild,
        baseline: Baseline,
        client: Option<(Client, binding::Connection)>,
    ) -> Result<Planned, PlanError> {
        let new_graph = build.graph();
        let new_manifests = manifests_of(new_graph);
        let ledger = match &client {
            Some((client, _)) => Some(ledger_for(client, &baseline, &new_manifests).await?),
            None => None,
        };
        // A half-applied closure is not a previous intended state, so
        // pairing against it would invent migrations nobody declared.
        let mut migration_pairs = detect_migration_pairs(
            &new_manifests,
            &baseline.active_manifests,
            &baseline.instances(),
        );
        let read = match client {
            Some((client, connection)) => {
                let head = read_head(&client, &new_graph.cluster_name).await?;
                let live = read_live(&client, &listed_ids(&new_manifests, ledger.as_ref())).await?;
                Some((client, connection, live, head))
            }
            None => None,
        };
        let mut checked = self
            .check(
                new_graph,
                &new_manifests,
                &new_graph.cluster_name,
                &baseline,
                read.as_ref().map(|(client, _, live, _)| (client, live)),
                ledger.as_ref(),
            )
            .await?;
        // A deploy with `--only` makes only the migrations whose new object
        // it writes. It deletes no old object.
        if checked.left_alone.is_some() {
            let written: HashSet<&ResourceId> = checked
                .plan
                .nodes()
                .iter()
                .filter_map(|n| match &n.id {
                    NodeId::Resource(rid) if n.action.written().is_some() => Some(rid),
                    _ => None,
                })
                .collect();
            migration_pairs.retain(|pair| written.contains(&pair.target));
        }
        let connected = read.map(|(client, connection, live, head)| Connected {
            last_runs: checked.last_runs_from(&live),
            client,
            connection,
            head,
        });
        Ok(Planned {
            build,
            new_manifests,
            connected,
            baseline,
            migration_pairs,
            checked,
        })
    }

    /// Compute the changes of `new_graph` against `baseline` and build the
    /// checked deploy plan and package diff. Fails unless every write and
    /// delete of the engine plan is shown in the package diff. `cluster` is
    /// the Kix cluster whose records the baseline came from. With a `client`,
    /// orphans that another Kix cluster still deploys are kept and the plan's
    /// prune section lists every other orphan; without one, `kix deploy`
    /// checks the orphans once it connects. With a `client`, the plan also
    /// writes again each unchanged object the cluster no longer holds. The
    /// caller reads the last runs of the plan's Jobs
    /// ([`CheckedPlan::read_last_runs`]).
    pub async fn plan(
        &self,
        new_graph: &StoreGraph,
        cluster: &str,
        baseline: &Baseline,
        client: Option<&Client>,
    ) -> Result<CheckedPlan, PlanError> {
        let new_manifests = manifests_of(new_graph);
        let ledger = match client {
            Some(client) => Some(ledger_for(client, baseline, &new_manifests).await?),
            None => None,
        };
        let live = match client {
            Some(client) => {
                Some(read_live(client, &listed_ids(&new_manifests, ledger.as_ref())).await?)
            }
            None => None,
        };
        self.check(
            new_graph,
            &new_manifests,
            cluster,
            baseline,
            client.zip(live.as_ref()),
            ledger.as_ref(),
        )
        .await
    }

    /// Compute what `new_manifests` change against the build of `baseline`
    /// ([`Baseline::changes`]), for a plan that did not read the cluster
    /// (`--offline`). An object the build leaves unchanged is written again
    /// under `--reconcile`. The run's kept-orphans revision carries the
    /// current record's forward unexamined.
    fn changes(&self, new_manifests: &[Value], baseline: &Baseline) -> Changes {
        let actions = baseline.changes(new_manifests, |_| self.flags.reconcile);
        let orphans = actions
            .iter()
            .filter_map(|action| match action {
                ChangeAction::Orphan(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect();
        Changes {
            actions,
            orphans,
            kept_orphans: KeptOrphans {
                carry_current: true,
                ..KeptOrphans::default()
            },
            force: HashSet::new(),
            reasons: HashMap::new(),
            consumed: None,
            orphan_manifests: Vec::new(),
            migrations: Migrations::default(),
            orphan_migrations: Vec::new(),
        }
    }

    /// Decide what `new_manifests` change with the one planner
    /// ([`decide::decide`]), from `live`, the objects of the build and the
    /// ones `ledger` names as the cluster holds them.
    fn decided(
        &self,
        new_manifests: &[Value],
        ledger: &Ledger,
        live: &LiveObjects,
    ) -> Result<Changes, PlanError> {
        let made: HashSet<ResourceId> = lifecycle::made_by(new_manifests).collect();
        let decided = decide::decide(
            new_manifests,
            &made,
            live,
            ledger,
            self.flags.reconcile,
            true,
        )
        .map_err(|e| PlanError::ReadForbidden(Box::new(e)))?;
        if !decided.lost.is_empty() {
            (self.report)(PlanEvent::NotHeld(&decided.lost));
        }
        let mut force = HashSet::new();
        let mut reasons = HashMap::new();
        let mut actions = Vec::with_capacity(decided.decisions.len() + decided.orphans.len());
        for decision in decided.decisions {
            if decision.label.reverts_drift() {
                force.insert(decision.id.clone());
            }
            if let Some(reason) = write_reason(&decision.label) {
                reasons.insert(decision.id, reason);
            }
            actions.push(decision.action);
        }
        let orphan_manifests = decided
            .orphans
            .iter()
            .filter_map(|rid| match live.get(rid) {
                Live::Present(obj) => Some(crate::manifest::types::to_manifest_value(obj)),
                Live::Absent | Live::Unserved | Live::Unread => None,
            })
            .collect();
        actions.extend(decided.orphans.iter().cloned().map(ChangeAction::Orphan));
        // The plan read every kept orphan it could from the cluster. The
        // run's kept-orphans revision names again the ones whose kind the
        // cluster does not serve, and carries nothing else forward.
        let kept_orphans = KeptOrphans {
            unknown: decided.unknown,
            ..KeptOrphans::default()
        };
        Ok(Changes {
            actions,
            orphans: decided.orphans,
            kept_orphans,
            force,
            reasons,
            consumed: Some(ledger.taken_in().to_vec()),
            orphan_manifests,
            orphan_migrations: decided.orphan_migrations,
            migrations: Migrations {
                objects: decided.migrations.into_iter().collect(),
                renamed: decided.renamed.into_iter().collect(),
                releases: Vec::new(),
                record: ledger.record().map(str::to_string),
            },
        })
    }

    /// Run [`Planner::plan`] over the manifests of `new_graph`. `read` is
    /// the client of a plan made while connected and the build's objects it
    /// listed.
    async fn check(
        &self,
        new_graph: &StoreGraph,
        new_manifests: &[Value],
        cluster: &str,
        baseline: &Baseline,
        read: Option<(&Client, &LiveObjects)>,
        ledger: Option<&Ledger>,
    ) -> Result<CheckedPlan, PlanError> {
        let partial = !self.flags.only.is_empty();
        if partial {
            match baseline.active() {
                None => return Err(PlanError::OnlyFirstDeploy(cluster.to_string())),
                // The operator repairs the build of a record it deployed on
                // every requeue, so it would put back what this deploy
                // applies and delete the objects it adds.
                Some(active) if active.operator_driven => {
                    return Err(PlanError::OnlyUnderOperator {
                        cluster: cluster.to_string(),
                        record: active.name.clone(),
                    });
                }
                Some(_) => {}
            }
        }
        let client = read.map(|(client, _)| client);
        let Changes {
            actions,
            orphans,
            kept_orphans,
            force,
            reasons,
            consumed,
            orphan_manifests,
            mut migrations,
            orphan_migrations,
        } = match (ledger, read) {
            (Some(ledger), Some((_, live))) => self.decided(new_manifests, ledger, live)?,
            _ => self.changes(new_manifests, baseline),
        };
        // A deploy with `--only` leaves every orphan alone, so it does not
        // ask which ones another Kix cluster deploys. The one planner read
        // every orphan and the tenancy already.
        let (orphans, shared_orphans) = match (read, ledger) {
            _ if partial => (orphans, Vec::new()),
            (Some((_, live)), Some(_)) => {
                baseline
                    .tenancy
                    .complete_for_others()
                    .map_err(|e| PlanError::Tenancy(Box::new(e)))?;
                inventory::split_shared_orphans_listed(orphans, live, &baseline.tenancy)
            }
            (Some((client, _)), None) => keep_shared(client, cluster, orphans).await?,
            (None, _) => (orphans, Vec::new()),
        };
        migrations.releases = match read {
            Some((_, live)) => inventory::releases_of(
                &shared_orphans,
                live,
                &crate::cluster::field_manager::FieldManager::of(cluster),
            ),
            None => shared_orphans.iter().map(|s| s.rid.clone()).collect(),
        };
        let resource_graph =
            ResourceGraph::from_manifests(new_manifests).map_err(PlanError::Graph)?;
        let mut plan = DeployPlan::from_graph_and_changes(&resource_graph, &actions)
            .map_err(PlanError::Marker)?;

        let record = lifecycle::record_of(new_manifests);
        let activation_name = record.and_then(|m| {
            m.pointer("/metadata/name")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
        let activation_identity_hash =
            record.and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(str::to_string));

        let mut pkg_diff = diff_sent(&baseline.diff_side(new_graph), new_graph);
        pkg_diff.keep_shared(&shared_orphans);
        let aliased = pkg_diff.aliased_moves();
        if !aliased.is_empty() {
            return Err(PlanError::AliasedMove(aliased));
        }

        // `--only` narrows the plan to the instances it names and what they
        // depend on. What the plan shows and what the run writes are both
        // that part, so the objects check below holds them to each other.
        let (orphans, shared_orphans, kept_orphans, consumed_failed, selection) = if partial {
            let selection = select_only(
                &self.flags.only,
                new_graph,
                cluster,
                &mut plan,
                &mut pkg_diff,
                orphans.len(),
            )?;
            migrations.releases.clear();
            migrations.objects.retain(|rid| {
                plan.nodes()
                    .iter()
                    .any(|n| matches!(&n.id, NodeId::Resource(r) if r == rid))
            });
            (
                Vec::new(),
                Vec::new(),
                Default::default(),
                Vec::new(),
                Some(selection),
            )
        } else {
            (
                orphans,
                shared_orphans,
                kept_orphans,
                consumed.unwrap_or_else(|| baseline.failed().consumed.clone()),
                None,
            )
        };

        let listed_deletes: &[ResourceId] = match client {
            Some(_) => &orphans,
            None => &[],
        };
        let mut objects = objects::of(
            &pkg_diff.shown,
            new_graph,
            &plan,
            &deletes_of(self.flags.prune, &orphans),
            listed_deletes,
            baseline.ran(),
        )
        .map_err(PlanError::Unshown)?;
        for write in &mut objects.writes {
            write.reason = reasons.get(&write.resource_id()).cloned();
        }
        // Before the lock is taken, so a build no deploy can record stops
        // here with a message that names the instance.
        let revisions = RevisionSet::of(cluster, new_graph);
        revisions
            .check_size()
            .map_err(|e| PlanError::RevisionTooLarge(Box::new(e)))?;
        // An orphan the prune deletes needs no migration write, and a deploy
        // with `--only` keeps none.
        let deleted: HashSet<ResourceId> =
            deletes_of(self.flags.prune, &orphans).into_iter().collect();
        migrations.objects.extend(
            orphan_migrations
                .into_iter()
                .filter(|rid| orphans.contains(rid) && !deleted.contains(rid)),
        );
        let prior = {
            let manifests = crate::cluster::apply::baseline_manifests(
                &baseline.manifests(),
                &[orphan_manifests],
            );
            match ledger {
                Some(ledger) => ledger.prior(manifests),
                None => Prior::of_build(manifests),
            }
        };
        check_kept_orphans_size(
            cluster,
            self.flags.prune,
            &orphans,
            &deleted,
            &shared_orphans,
            &prior,
            &kept_orphans,
        )?;

        Ok(CheckedPlan {
            flags: self.flags.clone(),
            build_hashes: crate::cluster::revision::convert::BuildHashes::of(new_manifests),
            plan,
            orphans,
            shared_orphans,
            kept_orphans,
            pkg_diff,
            objects,
            activation_name,
            activation_identity_hash,
            record: record.cloned(),
            consumed_failed,
            cluster: cluster.to_string(),
            prior,
            revisions,
            target_checks: TargetChecks::of(new_graph),
            left_alone: selection.as_ref().map(|s| s.left_alone),
            needed: selection.map(|s| s.needed).unwrap_or_default(),
            force: force.into_iter().map(|rid| (rid, None)).collect(),
            migrations,
            converts: ledger.is_some_and(Ledger::converts),
        })
    }
}

/// Return the ledger of the one planner for the Kix cluster `baseline` was
/// read for, through `client`, for a deploy of `new_manifests`. When a
/// record a run needs has no revision map, the run gives it revisions first
/// ([`crate::cluster::revision::convert`]). The plan lists every object that
/// carries Kix's label, computes the same conversion, and reads the records
/// as the run will find them. Refuse when the tenancy could not read what
/// this Kix cluster's records name, because the plan could not tell which
/// objects are orphans.
async fn ledger_for(
    client: &Client,
    baseline: &Baseline,
    new_manifests: &[Value],
) -> Result<Ledger, PlanError> {
    use crate::cluster::revision::convert;
    let take_in_stopped = !baseline.failed().left_out;
    let tenancy = &baseline.tenancy;
    let own = tenancy.own_records();
    let current = convert::current_of(tenancy.own_current(), own);
    let listed = tenancy.own_listed_revisions();
    let conversion = if convert::targets(current, own, &listed).is_empty() {
        crate::cluster::revision::Conversion::default()
    } else {
        let discovery = discovery::discover_resources(client)
            .await
            .map_err(|e| PlanError::Discovery(Box::new(e)))?;
        let sweep = inventory::list_managed(client, &discovery)
            .await
            .map_err(|e| PlanError::Reconstruct(e.to_string()))?;
        convert::plan(
            &tenancy.cluster,
            current,
            own,
            &listed,
            &sweep.managed,
            &sweep.forbidden,
            &convert::BuildHashes::of(new_manifests),
        )
        .map_err(|e| PlanError::Conversion(Box::new(e)))?
    };
    let converted = tenancy.with_conversion(&conversion);
    let mut ledger =
        Ledger::of(&converted, take_in_stopped).map_err(|e| PlanError::Tenancy(Box::new(e)))?;
    ledger.set_converts(!conversion.is_empty());
    let record =
        lifecycle::record_of(new_manifests).and_then(|m| keys::get(m, keys::IDENTITY_HASH));
    ledger.deploying(record);
    Ok(ledger)
}

/// Refuse when a record of Kix cluster `cluster` is driven by a Kix operator
/// older than this Kix ([`crate::cluster::activation::features::operator_without_revisions`]),
/// before a command that will take the lock plans anything.
pub(crate) async fn refuse_older_operator(client: &Client, cluster: &str) -> Result<(), PlanError> {
    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| PlanError::Discovery(Box::new(e)))?;
    let opened = Records::open(client, &discovery).map_err(PlanError::Domain)?;
    let Some(records) = opened.records() else {
        return Ok(());
    };
    match crate::cluster::activation::features::operator_without_revisions(client, records, cluster)
        .await
    {
        Ok(None) => Ok(()),
        Ok(Some(refusal)) => Err(PlanError::OperatorWithoutRevisions(Box::new(refusal))),
        Err(e) => Err(PlanError::OperatorFeatures(Box::new(e))),
    }
}

/// Return the objects a plan lists on the cluster: those `new_manifests`
/// make, and those `ledger` names that the build does not make.
fn listed_ids(new_manifests: &[Value], ledger: Option<&Ledger>) -> Vec<ResourceId> {
    let made: HashSet<ResourceId> = lifecycle::made_by(new_manifests).collect();
    let candidates: Vec<ResourceId> = ledger
        .map(|l| l.candidates(&made).cloned().collect())
        .unwrap_or_default();
    made.into_iter().chain(candidates).collect()
}

/// Return what the plan document says about a write labelled `label`, or
/// `None` for a change the new build makes.
fn write_reason(label: &Label) -> Option<WriteReason> {
    match label {
        Label::AppliedByRecord(record) => Some(WriteReason::AppliedByRecord {
            record: record.clone(),
        }),
        Label::LeftByDegraded(record) => Some(WriteReason::LeftByDegraded {
            record: record.clone(),
        }),
        Label::AppliedHashMissing => Some(WriteReason::AppliedHashMissing),
        Label::RevertsDrift(report)
        | Label::Unfinished {
            drift: Some(report),
            ..
        } => Some(WriteReason::RevertsDrift {
            changed_by: super::document::DriftOwner::of_report(report),
        }),
        Label::HeldByOtherCluster(report) => Some(WriteReason::HeldByOtherCluster {
            changed_by: super::document::DriftOwner::of_report(report),
        }),
        Label::Unfinished {
            record,
            drift: None,
        } => Some(WriteReason::UnfinishedDeploy {
            record: record.clone(),
        }),
        Label::Intended | Label::Reconciled | Label::Unchanged | Label::DriftReported(_) => None,
    }
}

/// What [`select_only`] chose and left out.
struct Selection {
    /// The instances the named ones need, which the deploy applies in full
    /// too, sorted.
    needed: Vec<String>,
    left_alone: LeftAlone,
}

/// Narrow `plan` and `pkg_diff` to the instances `only` names in the build
/// `graph` of Kix cluster `cluster`, and return what the narrowed plan
/// applies besides them and what it leaves out of the whole build's plan,
/// which deletes `orphans` objects.
///
/// An instance is its PackageInstance and every object the build's package
/// index lists under it. The PackageInstance depends only on its namespace
/// and its kind's CRD, so the package index names the instance's objects.
/// The selection starts from the named instances' objects and adds what
/// they depend on. Whenever it holds an object of an instance, it takes
/// every object of that instance, so no instance is left half at the new
/// build. An object outside every instance, such as a Namespace or a CRD,
/// is taken alone.
fn select_only(
    only: &[String],
    graph: &StoreGraph,
    cluster: &str,
    plan: &mut DeployPlan,
    pkg_diff: &mut PackageDiff,
    orphans: usize,
) -> Result<Selection, PlanError> {
    let mut members: BTreeMap<String, Vec<NodeId>> = BTreeMap::new();
    for p in graph.packages.values() {
        let ids = p
            .resource_paths
            .iter()
            .chain([&p.store_path])
            .filter_map(|path| graph.resources.get(path))
            .map(|node| NodeId::Resource(ResourceId::from_value(&node.manifest)));
        members
            .entry(format!("{}/{}", p.namespace, p.instance_name))
            .or_default()
            .extend(ids);
    }
    let mut instances_of: HashMap<&NodeId, Vec<&str>> = HashMap::new();
    for (key, ids) in &members {
        for id in ids {
            instances_of.entry(id).or_default().push(key);
        }
    }
    // The objects that go with each object: those of every instance that
    // lists it.
    let together: HashMap<NodeId, Vec<NodeId>> = instances_of
        .iter()
        .map(|(id, keys)| {
            let ids = keys
                .iter()
                .flat_map(|k| members[*k].iter().cloned())
                .collect();
            ((*id).clone(), ids)
        })
        .collect();

    let unknown: Vec<String> = only
        .iter()
        .filter(|name| members.get(name.as_str()).is_none_or(Vec::is_empty))
        .cloned()
        .collect();
    if !unknown.is_empty() {
        return Err(PlanError::UnknownInstances(UnknownInstances {
            cluster: cluster.to_string(),
            unknown,
            valid: members.keys().cloned().collect(),
        }));
    }
    let roots: HashSet<NodeId> = only
        .iter()
        .flat_map(|name| members[name.as_str()].iter().cloned())
        .collect();
    let left = plan.retain_closure(&roots, |id| together.get(id).map_or(&[][..], Vec::as_slice));
    let writes = left
        .iter()
        .filter_map(|n| n.action.written())
        .filter(|m| !lifecycle::is_record(m))
        .count();
    let kept: HashSet<ResourceId> = plan
        .nodes()
        .iter()
        .filter_map(|n| match &n.id {
            NodeId::Resource(rid) => Some(rid.clone()),
            NodeId::Synthetic(_) => None,
        })
        .collect();
    let needed = members
        .iter()
        .filter(|(key, ids)| {
            !only.contains(key)
                && ids
                    .iter()
                    .any(|id| matches!(id, NodeId::Resource(rid) if kept.contains(rid)))
        })
        .map(|(key, _)| key.clone())
        .collect();
    pkg_diff.retain_objects(&kept);
    Ok(Selection {
        needed,
        left_alone: LeftAlone { writes, orphans },
    })
}

/// List each kind of `ids` on the cluster behind `client`, once.
async fn read_live(client: &Client, ids: &[ResourceId]) -> Result<LiveObjects, PlanError> {
    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| PlanError::Discovery(Box::new(e)))?;
    LiveObjects::list(client, &discovery, ids)
        .await
        .map_err(|e| PlanError::ReadLive(Box::new(e)))
}

fn manifests_of(graph: &StoreGraph) -> Vec<Value> {
    graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect()
}

/// Return the orphans that a run's prune deletes under `PrunePolicy::Delete`,
/// excluding kinds protected by `lifecycle::never_pruned`.
/// Refuse a plan whose run would write a kept-orphans revision too large
/// to store, as the run finalizes after every apply and every delete. The
/// revision names what the run keeps when it goes as planned: each orphan
/// the prune does not delete, and with `--skip-orphan-check` the orphans
/// another Kix cluster shares, which the run does not release. It is built
/// as the run builds it ([`kept_orphans_revision`]), without the current
/// record's kept orphans that an offline plan carries forward unread.
fn check_kept_orphans_size(
    cluster: &str,
    prune: PrunePolicy,
    orphans: &[ResourceId],
    deleted: &HashSet<ResourceId>,
    shared: &[SharedOrphan],
    prior: &Prior,
    kept: &KeptOrphans,
) -> Result<(), PlanError> {
    let unshared = if prune == PrunePolicy::Skip {
        shared
    } else {
        &[]
    };
    let wanted = orphans
        .iter()
        .filter(|rid| !deleted.contains(*rid))
        .chain(unshared.iter().map(|s| &s.rid));
    let Some(revision) = kept_orphans_revision(cluster, wanted, prior, &kept.unknown, None) else {
        return Ok(());
    };
    if revision.stored_bytes() <= crate::cluster::revision::MAX_BYTES {
        return Ok(());
    }
    Err(PlanError::RevisionTooLarge(Box::new(
        crate::cluster::revision::TooLarge {
            what: "the list of orphaned objects this deploy keeps".to_string(),
            objects: revision.spec.objects.len(),
            bytes: revision.stored_bytes(),
            next: "Pass `--prune` to delete orphaned objects during this deploy, or run `kix gc` first to delete orphaned objects kept from earlier deploys.",
        },
    )))
}

pub(crate) fn deletes_of(prune: PrunePolicy, orphans: &[ResourceId]) -> Vec<ResourceId> {
    if prune != PrunePolicy::Delete {
        return Vec::new();
    }
    orphans
        .iter()
        .filter(|rid| !lifecycle::never_pruned(rid.group_kind()))
        .cloned()
        .collect()
}

/// Split `orphans` into the ones to prune and the ones another Kix cluster's
/// current Activation record still names. Reads each candidate, then the
/// records.
///
/// Two Kix clusters on one Kubernetes cluster can both contain an object,
/// such as an identical ClusterRole. When one of them drops it from its
/// build, the comparison of builds plans it as an orphan, but the other
/// cluster's current build still contains it. Every command that prunes
/// from a plan passes its orphans through here so the plan lists such an
/// object as kept, and deletes through `cluster::prune_guard::PruneGuard`,
/// which checks again at the delete.
pub async fn keep_shared(
    client: &Client,
    cluster: &str,
    orphans: Vec<ResourceId>,
) -> Result<(Vec<ResourceId>, Vec<SharedOrphan>), PlanError> {
    if orphans.is_empty() {
        return Ok((orphans, Vec::new()));
    }
    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| PlanError::Discovery(Box::new(e)))?;
    let records = Records::open(client, &discovery).map_err(PlanError::Domain)?;
    inventory::split_shared_orphans_live(client, &discovery, &records, orphans, cluster)
        .await
        .map_err(|e| PlanError::SharedOrphans(Box::new(e)))
}

/// Split `candidates` into the ones `kix gc` may delete and the ones a
/// pending record of Kix cluster `cluster` names: a deploy that is queued,
/// deploying, failed, or partly deployed
/// ([`crate::cluster::tenancy::Tenancy::pending_records_of`]). Reads each
/// candidate, then the records.
pub async fn keep_held(
    client: &Client,
    cluster: &str,
    candidates: Vec<ResourceId>,
) -> Result<(Vec<ResourceId>, Vec<inventory::HeldObject>), PlanError> {
    if candidates.is_empty() {
        return Ok((candidates, Vec::new()));
    }
    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| PlanError::Discovery(Box::new(e)))?;
    let records = Records::open(client, &discovery).map_err(PlanError::Domain)?;
    inventory::split_held_live(client, &discovery, &records, candidates, cluster)
        .await
        .map_err(|e| PlanError::HeldObjects(Box::new(e)))
}

/// Return each CustomResourceDefinition that an orphan of `old_manifests`
/// declares and that no other object of `old_manifests` and none of `added`
/// declares, with the orphan: the definition itself when it is an orphan,
/// else the first reference to it.
pub fn kinds_leaving<'a>(
    old_manifests: &[Value],
    orphans: &[ResourceId],
    added: impl Iterator<Item = &'a Value>,
) -> Vec<(ResourceId, String)> {
    let orphans: HashSet<&ResourceId> = orphans.iter().collect();
    let mut kept: HashSet<String> = added.filter_map(declared_crd).collect();
    let mut leaving: BTreeMap<String, ResourceId> = BTreeMap::new();
    for m in old_manifests {
        let Some(crd) = declared_crd(m) else {
            continue;
        };
        let rid = ResourceId::from_value(m);
        if !orphans.contains(&rid) {
            kept.insert(crd);
            continue;
        }
        let is_definition = rid.group_kind() == kinds::CUSTOM_RESOURCE_DEFINITION;
        let replace = match leaving.get(&crd) {
            None => true,
            Some(by) => is_definition && by.group_kind() != kinds::CUSTOM_RESOURCE_DEFINITION,
        };
        if replace {
            leaving.insert(crd, rid);
        }
    }
    leaving
        .into_iter()
        .filter(|(crd, _)| !kept.contains(crd))
        .map(|(crd, rid)| (rid, crd))
        .collect()
}

/// Return the name of the CustomResourceDefinition that `manifest` declares:
/// its own name when it is one, or its target when it is an import marker
/// for one.
fn declared_crd(manifest: &Value) -> Option<String> {
    if GroupKind::of_manifest(manifest) == kinds::CUSTOM_RESOURCE_DEFINITION {
        return manifest
            .pointer("/metadata/name")
            .and_then(Value::as_str)
            .map(str::to_string);
    }
    match crate::cluster::readiness::import_target_from_manifest(manifest) {
        Ok(Some(target)) if target.kind == "CustomResourceDefinition" => Some(target.name),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_SUPERSEDED};
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    fn record(cluster: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        })
    }

    fn rid(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId::new("", kind, ns, name)
    }

    /// The plan reads the controller of each prune delete that waits for a
    /// finalizer, and reads nothing for a delete with no finalizer or an
    /// object whose kind names no controller.
    #[tokio::test]
    async fn the_plan_reads_the_controller_of_a_delete_that_waits() {
        use crate::cluster::ops::scripted::{Behaviour, NodeScript, ScriptedOps};
        use crate::cluster::preview::DeleteWait;
        use crate::cluster::readiness::ControllerState;
        let manifest = |kind: &str, name: &str, hash: &str, deps: &str| {
            json!({
                "apiVersion": if kind == "Deployment" { "apps/v1" } else { "v1" },
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "annotations": {
                        (keys::IDENTITY_HASH): hash,
                        (keys::DEPENDS_ON): deps,
                    },
                },
            })
        };
        let order = DeleteOrder::of_build(&[
            manifest("ConfigMap", "held", "h1", "controller:op"),
            manifest("ConfigMap", "free", "h2", "controller:op"),
            manifest("ConfigMap", "plain", "h3", ""),
            manifest("Deployment", "operator", "op", ""),
        ]);
        let operator = ResourceId::new("apps", "Deployment", "app", "operator");
        let ops = ScriptedOps::new();
        ops.script(
            operator.clone(),
            NodeScript {
                live: Behaviour::Now(Ok(None)),
                ..NodeScript::default()
            },
        );
        let deleted = |rid: ResourceId, finalizers: &[&str]| DryRunAnswer {
            rid,
            outcome: DryRunOutcome::Pruned(PruneAnswer::Deleted(DeleteWait {
                finalizers: finalizers.iter().map(|f| f.to_string()).collect(),
                ..DeleteWait::default()
            })),
        };
        let mut answers = vec![
            deleted(rid("ConfigMap", "app", "held"), &["example.com/hold"]),
            deleted(rid("ConfigMap", "app", "free"), &[]),
            deleted(rid("ConfigMap", "app", "plain"), &["example.com/hold"]),
        ];
        read_prune_controllers(&mut answers, &order, &ops).await;
        let controllers = |i: usize| match &answers[i].outcome {
            DryRunOutcome::Pruned(PruneAnswer::Deleted(w)) => w.controllers.clone(),
            other => panic!("{other:?}"),
        };
        let held = controllers(0);
        assert_eq!(held.len(), 1);
        assert_eq!(held[0].id, operator);
        assert_eq!(held[0].state, ControllerState::Missing);
        assert!(controllers(1).is_empty());
        assert!(controllers(2).is_empty());
    }

    /// Kix cluster `a` drops a ClusterRole and a ConfigMap that `b` still
    /// deploys, and a ConfigMap only `a` had: the plan keeps the first two.
    /// The unnamespaced ConfigMap is read in `default`, where it was applied.
    #[tokio::test]
    async fn orphans_another_cluster_still_deploys_are_kept() {
        let api = FakeApi::new([
            record("a", "a1"),
            record("b", "b1"),
            json!({
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "ClusterRole",
                "metadata": { "name": "shared", "annotations": { (keys::ACTIVATIONS): "a1,b1" } },
            }),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "shared-cm",
                    "namespace": "default",
                    "annotations": { (keys::ACTIVATIONS): "a1,b1" },
                },
            }),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "mine",
                    "namespace": "app",
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            }),
        ]);
        let orphans = vec![
            rid("ClusterRole", CLUSTER_SCOPED, "shared"),
            rid("ConfigMap", CLUSTER_SCOPED, "shared-cm"),
            rid("ConfigMap", "app", "mine"),
        ];
        let (prune, kept) = keep_shared(&api.client(), "a", orphans).await.unwrap();
        assert_eq!(prune, vec![rid("ConfigMap", "app", "mine")]);
        let kept: Vec<&str> = kept.iter().map(|s| s.rid.name.as_str()).collect();
        assert_eq!(kept, vec!["shared", "shared-cm"]);
    }

    fn failed_record(name: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": name,
                "labels": { (keys::CLUSTER_LABEL): "kix-enterprise-test" },
                "annotations": { (keys::IDENTITY_HASH): "f1" },
            },
            "status": { "phase": crate::manifest::lifecycle::PHASE_FAILED },
        })
    }

    async fn phase(client: &Client, name: &str) -> String {
        let discovery = discovery::discover_resources(client).await.unwrap();
        let records = Records::open(client, &discovery)
            .unwrap()
            .into_records()
            .unwrap();
        let api = kube::Api::<kube::api::DynamicObject>::all_with(
            client.clone(),
            records.watch_resource(),
        );
        let record = api.get(name).await.unwrap();
        record.data["status"]["phase"]
            .as_str()
            .unwrap_or_default()
            .to_string()
    }

    /// Plan a redeploy of the `kix-enterprise-test` build over itself, with
    /// the failed record `rec-failed` folded in.
    fn unchanged_plan() -> CheckedPlan {
        let build = crate::plan::fixtures::kix_enterprise_test();
        let mut baseline = crate::plan::fixtures::deployed(Some(&build));
        baseline.failed.consumed = vec!["rec-failed".to_string()];
        crate::plan::fixtures::plan(&baseline, &build, crate::plan::fixtures::flags(&[])).unwrap()
    }

    /// After a stopped deploy, the dry run finds that the live object differs
    /// from the build, and the package view lists it as changed. The write
    /// of that object is then a modification, not a re-apply of an
    /// unchanged object, while a re-apply the view does not list stays one.
    #[test]
    fn a_write_the_dry_run_finds_changed_is_not_a_reapply() {
        let mut checked = unchanged_plan();
        let write = |name: &str| crate::plan::document::ObjectWrite {
            kind: "ConfigMap".into(),
            namespace: "web".into(),
            name: name.into(),
            store_hash: "h".into(),
            package: "web/web".into(),
            change: WriteChange::Reapplied,
            group: String::new(),
            reason: None,
        };
        checked.objects.writes = vec![write("reverted"), write("same")];
        checked
            .pkg_diff
            .changed
            .push(super::super::PackageChangeDiff {
                key: "web/web".into(),
                old_version: None,
                new_version: None,
                resource_diffs: vec![(write("reverted").resource_id(), Vec::new())],
                dep_affected_resources: Vec::new(),
                added_resources: Vec::new(),
                removed_resources: Vec::new(),
                shared_kept: Vec::new(),
            });
        checked.relabel_reverted_writes();
        let changes: Vec<(&str, WriteChange)> = checked
            .objects
            .writes
            .iter()
            .map(|w| (w.name.as_str(), w.change))
            .collect();
        assert_eq!(
            changes,
            [
                ("reverted", WriteChange::Modified),
                ("same", WriteChange::Reapplied)
            ]
        );
    }

    /// The `unchanged` count of a plan with nothing to do is what a run of
    /// the same plan reports.
    #[tokio::test(start_paused = true)]
    async fn nothing_to_do_counts_what_a_run_reports_unchanged() {
        use crate::cluster::scheduler::{self, OnErrorPolicy, PrunePolicy, SchedulerConfig};
        let checked = unchanged_plan();
        let read = LastRuns::Read { failed: vec![] };
        let api = FakeApi::new([failed_record("rec-failed")]);
        let Start::Nothing { unchanged, .. } = checked.start(&api.client(), &read).await else {
            panic!("the plan has nothing to do");
        };
        let config = SchedulerConfig {
            timeout: std::time::Duration::from_secs(300),
            on_error: OnErrorPolicy::Continue,
            cancel: crate::cluster::cancel::CancelToken::new(),
            concurrency: scheduler::CONCURRENCY,
            stall: crate::cluster::watchdog::StallPolicy::off(),
            check_unchanged: true,
            names_flags: true,
        };
        let ran = scheduler::run_scripted(
            std::sync::Arc::new(crate::cluster::ops::scripted::ScriptedOps::new()),
            checked.plan().clone(),
            &[],
            &[],
            scheduler::Ending::Finalize(PrunePolicy::WarnOnly),
            &config,
            std::sync::Arc::new(crate::cluster::stream::NullObserver),
        )
        .await
        .unwrap();
        assert!(unchanged > 0);
        assert_eq!(ran.unchanged, unchanged);
        assert_eq!(ran.created + ran.configured + ran.failed, 0);
    }

    /// A first deploy to a cluster that serves none of Kix's kinds passes
    /// the dry run. The build carries no CRD for the deployment record or the
    /// package instances, and Kix installs those CRDs when the deploy takes
    /// its lock, so their objects are not checked rather than refused.
    #[tokio::test]
    async fn a_first_deploy_to_a_cluster_without_kix_kinds_passes_the_dry_run() {
        use crate::cluster::classify::{DeployScope, Verdict, classify};
        use crate::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
        use crate::plan::document::UncheckedReason;

        let build = crate::plan::fixtures::kix_enterprise_test();
        let mut checked = crate::plan::fixtures::plan(
            &Baseline::empty(),
            &build,
            crate::plan::fixtures::flags(&[]),
        )
        .unwrap();
        let (_, manifests) = crate::plan::fixtures::stamp(&build);
        let api = FakeApi::new([]);
        api.serve_no_kix_kinds();
        let target = Target::connect(api.client(), crate::build_source::SopsSources::Local)
            .await
            .unwrap();
        let served = target.discovery().to_vec();
        let config = SchedulerConfig {
            timeout: std::time::Duration::from_secs(5),
            on_error: OnErrorPolicy::Continue,
            cancel: crate::cluster::cancel::CancelToken::new(),
            concurrency: scheduler::CONCURRENCY,
            stall: crate::cluster::watchdog::StallPolicy::off(),
            check_unchanged: true,
            names_flags: true,
        };
        let (_, answers) = checked
            .dry_run(
                target,
                config,
                std::sync::Arc::new(crate::cluster::stream::NullObserver),
            )
            .await;
        let scope = DeployScope {
            cluster: &checked.cluster,
            build: &manifests,
            plan: checked.plan(),
            served: &served,
        };
        let verdicts = classify(&answers, &scope);
        let refused: Vec<String> = verdicts
            .iter()
            .filter(|(_, v)| matches!(v, Verdict::Refused(_)))
            .map(|(rid, v)| format!("{} {v:?}", rid.display_id()))
            .collect();
        assert!(refused.is_empty(), "{refused:#?}");
        let mut by_kix: Vec<&str> = verdicts
            .iter()
            .filter(|(_, v)| {
                matches!(
                    v,
                    Verdict::NotChecked {
                        reason: UncheckedReason::CrdInstalledByKix,
                        ..
                    }
                )
            })
            .map(|(rid, _)| rid.kind.as_str())
            .collect();
        by_kix.sort();
        by_kix.dedup();
        assert_eq!(by_kix, ["Activation", "PackageInstance"]);
    }

    /// A plan with nothing to do starts no run, so no finalize supersedes
    /// the failed records it folded in. `start` supersedes them, as it does
    /// for `kix deploy` and `kix rollback` alike.
    #[tokio::test]
    async fn nothing_to_do_supersedes_the_failed_records_the_plan_folded_in() {
        let checked = unchanged_plan();
        let read = LastRuns::Read { failed: vec![] };
        assert_eq!(checked.work(&read), Work::Nothing);

        let api = FakeApi::new([failed_record("rec-failed")]);
        let client = api.client();
        assert_eq!(
            checked.start(&client, &read).await,
            Start::Nothing {
                superseded: 1,
                unchanged: checked.plan().nodes().len(),
            }
        );
        assert_eq!(phase(&client, "rec-failed").await, PHASE_SUPERSEDED);
    }

    /// A Job whose last run failed, or a Job Kix could not read, gives the
    /// run work to do. The run starts and its finalize supersedes the failed
    /// records, so `start` leaves them alone.
    #[tokio::test]
    async fn jobs_to_report_or_read_start_the_run() {
        let checked = unchanged_plan();
        let failed = LastRuns::Read {
            failed: vec![rid("Job", "app", "migrate")],
        };
        for last_runs in [failed, LastRuns::Unreadable] {
            assert_eq!(checked.work(&last_runs), Work::JobsOnly);
            let api = FakeApi::new([failed_record("rec-failed")]);
            let client = api.client();
            assert_eq!(checked.start(&client, &last_runs).await, Start::Run);
            assert_eq!(
                phase(&client, "rec-failed").await,
                crate::manifest::lifecycle::PHASE_FAILED
            );
        }
    }

    /// Run [`Planner::note_unbound`] for the `kix-enterprise-test` build,
    /// with `uid` as its `cluster.kubernetes.uid` and `active` as the
    /// cluster's Active record, against a cluster whose `kube-system` UID is
    /// `live-uid`. Return the events it reported.
    async fn unbound_events(uid: Option<&str>, active: Option<Value>) -> Vec<String> {
        let api = FakeApi::new([crate::cluster::fake_api::kube_system("live-uid")]);
        let mut graph = crate::plan::fixtures::kix_enterprise_test();
        graph.kubernetes_uid = uid.map(str::to_string);
        let mut baseline = Baseline::empty();
        baseline.active = active.map(|r| Record::of(&serde_json::from_value(r).unwrap()));
        let connection = binding::Connection::Context {
            name: Some("prod".into()),
            server: Some("https://prod.example:6443".into()),
        };
        let events = std::sync::Mutex::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.lock().unwrap().push(format!("{event:?}"));
        let flags = super::super::document::PlanFlags {
            prune: PrunePolicy::WarnOnly,
            reconcile: false,
            force_conflicts: false,
            accept_migrations: false,
            operator_removed: false,
            only: Vec::new(),
        };
        Planner::new(flags, &report)
            .note_unbound(&api.client(), &connection, &graph, &baseline)
            .await;
        events.into_inner().unwrap()
    }

    /// The first deploy of a definition that names no Kubernetes cluster
    /// says so, with the UID that would bind it to this one. A bound
    /// definition, and a cluster deployed here before, say nothing.
    #[tokio::test]
    async fn a_first_deploy_of_an_unbound_definition_says_how_to_bind_it() {
        let events = unbound_events(None, None).await;
        assert_eq!(events.len(), 1, "{events:?}");
        assert!(events[0].starts_with("Unbound"), "{events:?}");
        assert!(events[0].contains("live-uid"), "{events:?}");
        assert!(events[0].contains("prod.example"), "{events:?}");

        assert!(unbound_events(Some("live-uid"), None).await.is_empty());
        let active = record("kix-enterprise-test", "abc");
        assert!(unbound_events(None, Some(active)).await.is_empty());
    }

    /// Build a [`Planned`] for the `kix-enterprise-test` fixture as a first
    /// deploy without connecting.
    fn planned() -> Planned {
        struct Carried;
        impl crate::build_source::CarriedBuild for Carried {
            fn sops_files(&mut self) -> Result<std::collections::HashMap<String, Vec<u8>>, String> {
                Ok(Default::default())
            }
            fn provenance(&self) -> crate::build_source::Provenance {
                Default::default()
            }
            fn deployed_build(&self, _identity_hash: &str) -> Result<Option<StoreGraph>, String> {
                Ok(None)
            }
            fn warnings(&self) -> Vec<crate::eval::library_record::LibraryRecord> {
                Vec::new()
            }
        }
        let bytes: &[u8] = crate::eval::fixtures::KIX_ENTERPRISE_TEST_JSON;
        let graph = crate::plan::fixtures::kix_enterprise_test();
        let build =
            crate::build_source::Build::carried(bytes.to_vec(), "kix-enterprise-test", |_| {
                Ok((Carried, graph))
            })
            .unwrap()
            .installable()
            .unwrap();
        let baseline = Baseline::empty();
        let flags = super::super::document::PlanFlags {
            prune: PrunePolicy::WarnOnly,
            reconcile: false,
            force_conflicts: false,
            accept_migrations: false,
            operator_removed: false,
            only: Vec::new(),
        };
        let new_manifests = manifests_of(build.graph());
        let checked = futures::executor::block_on(Planner::new(flags, &|_| {}).check(
            build.graph(),
            &new_manifests,
            "kix-enterprise-test",
            &baseline,
            None,
            None,
        ))
        .unwrap();
        Planned {
            build,
            new_manifests,
            connected: None,
            baseline,
            migration_pairs: Vec::new(),
            checked,
        }
    }

    /// Return the value of annotation `key` on the build's manifests, the
    /// initial record, and the plan's record node.
    fn record_annotation(p: &Planned, key: &str) -> Vec<Option<String>> {
        let applied = p.checked.plan.nodes.iter().filter_map(|n| match &n.action {
            ChangeAction::Apply(m) if lifecycle::is_record(m) => Some(m),
            _ => None,
        });
        lifecycle::record_of(&p.new_manifests)
            .into_iter()
            .chain(&p.checked.record)
            .chain(applied)
            .map(|m| {
                m.pointer("/metadata/annotations")
                    .and_then(|a| a.get(key))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .collect()
    }

    /// `--record-annotation` cannot set a key Kix reads off the record,
    /// under its domain, a subdomain of it, or a retired domain; the plan
    /// keeps the record it was checked with. Another key lands on every
    /// copy of the record.
    #[test]
    fn a_record_annotation_under_kix_domain_is_refused() {
        let mut p = planned();
        let hash = keys::IDENTITY_HASH.to_string();
        let before = record_annotation(&p, &hash);
        for key in [
            hash.clone(),
            format!("operator.{}/x", keys::DOMAIN),
            format!("{}/x", crate::legacy_domain::DOMAINS[0]),
        ] {
            let err = p
                .annotate_record(&[("team".into(), "a".into()), (key.clone(), "forged".into())])
                .unwrap_err();
            assert!(err.contains(&format!("'{key}'")), "{err}");
        }
        assert_eq!(record_annotation(&p, &hash), before);
        assert!(record_annotation(&p, "team").iter().all(Option::is_none));

        p.annotate_record(&[("example.com/ticket".into(), "T-1".into())])
            .unwrap();
        let ticket = record_annotation(&p, "example.com/ticket");
        assert_eq!(ticket, vec![Some("T-1".to_string()); 3]);
    }

    #[test]
    fn a_downgrade_is_noted_on_the_record() {
        let mut p = planned();
        p.note_downgrade(&"0.11.0".parse().unwrap());
        let noted = record_annotation(&p, keys::DOWNGRADED_FROM);
        assert_eq!(noted, vec![Some("0.11.0".to_string()); 3]);
    }

    #[test]
    fn a_withdrawn_kix_is_noted_on_the_record() {
        let mut p = planned();
        p.note_withdrawn_kix(&"0.10.0+abc".parse().unwrap());
        let noted = record_annotation(&p, keys::WITHDRAWN_KIX);
        assert_eq!(noted, vec![Some("0.10.0".to_string()); 3]);
    }

    /// A definition leaves when every object declaring it is an orphan and
    /// the new build adds none. The definition names the kind over a
    /// reference to it. A definition a remaining object still declares, or a
    /// new object declares, does not leave.
    #[test]
    fn kinds_leave_with_the_last_object_declaring_them() {
        let crd = |name: &str| {
            json!({
                "apiVersion": "apiextensions.k8s.io/v1",
                "kind": "CustomResourceDefinition",
                "metadata": { "name": name },
            })
        };
        let marker = |name: &str, crd: &str| {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "PackageInstance",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "annotations": {
                        (keys::MODE): "import",
                        (keys::IMPORT_KIND): "CustomResourceDefinition",
                        (keys::IMPORT_API_VERSION): "apiextensions.k8s.io/v1",
                        (keys::IMPORT_NAME): crd,
                        (keys::CRD_KIND): "Widget",
                        (keys::CRD_SERVED_VERSIONS): "v1",
                    },
                },
            })
        };
        let old = vec![
            marker("ref-a", "a.example.com"),
            crd("a.example.com"),
            marker("ref-b", "b.example.com"),
            crd("c.example.com"),
            marker("ref-c", "c.example.com"),
            crd("d.example.com"),
        ];
        let orphans: Vec<ResourceId> = ["ref-a", "ref-b", "ref-c"]
            .iter()
            .map(|n| ResourceId::from_value(&marker(n, "")))
            .chain(
                ["a.example.com", "c.example.com", "d.example.com"]
                    .map(|n| ResourceId::from_value(&crd(n))),
            )
            .collect();
        let added = [marker("ref-d", "d.example.com")];
        let leaving = kinds_leaving(&old, &orphans, added.iter());
        let names: Vec<(&str, &str)> = leaving
            .iter()
            .map(|(rid, crd)| (rid.name.as_str(), crd.as_str()))
            .collect();
        assert_eq!(
            names,
            vec![
                ("a.example.com", "a.example.com"),
                ("ref-b", "b.example.com"),
                ("c.example.com", "c.example.com"),
            ]
        );
        let kept_c: Vec<ResourceId> = orphans
            .iter()
            .filter(|r| r.name != "c.example.com")
            .cloned()
            .collect();
        let leaving = kinds_leaving(&old, &kept_c, std::iter::empty());
        assert!(
            leaving.iter().all(|(_, crd)| crd != "c.example.com"),
            "{leaving:?}"
        );
    }
}
