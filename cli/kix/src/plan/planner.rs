//! The plan of a deploy: everything it decides before it writes.
//!
//! [`Planner::run`] runs the steps `kix plan` and `kix deploy` share, so a
//! plan made with a deploy's flags is that deploy's plan:
//!
//! 1. the baseline: the closures the build is compared with (see
//!    [`super::baseline`]);
//! 2. the changes: the build against the Active closure, with what failed
//!    and kept deploys left folded in;
//! 3. the plan: the engine plan, the package diff people review, and the
//!    check that refuses a write or delete the diff does not show
//!    ([`super::objects::of`]).
//!
//! A rollback runs [`Planner::plan`], the last two steps, over the baseline
//! of the record it returns to ([`Baseline::of_record`]). The planner prints
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

use std::sync::Arc;

use kube::client::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;

use super::baseline::Baseline;
use super::document::{DriftChange, Objects, PlanFlags};
use super::objects;
use super::server::Overlay;
use super::{PackageDiff, PlanError, PlanEvent, diff_graphs};
use crate::build_source::InstallableBuild;
use crate::build_source::SopsSources;
use crate::cluster::activation::{KeptOrphanSource, KeptOrphans, Records};
use crate::cluster::apply::ChangeAction;
use crate::cluster::client::{self, ResiliencePolicy};
use crate::cluster::discovery;
use crate::cluster::errors::FetchError;
use crate::cluster::graph::ResourceGraph;
use crate::cluster::inventory;
use crate::cluster::inventory::SharedOrphan;
use crate::cluster::migrate::{MigrationPair, detect_migration_pairs};
use crate::cluster::ops::{Cluster, DryRun, KubeResources, RecordConfig};
use crate::cluster::preview::DryRunAnswer;
use crate::cluster::scheduler::{self, DeployError, DeployPlan, PrunePolicy, SchedulerConfig};
use crate::cluster::stream::{DeployObserver, DeployResult};
use crate::eval::store_graph::StoreGraph;
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};

/// What [`Planner::run`] compares the new build with.
#[derive(Debug, Clone)]
pub enum OldSide {
    /// The build the local activation cache names, without connecting
    /// (`--current-activation`). The plan then cannot see failed records or
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
    /// What the record the run finalizes lists under
    /// `status.orphansKeptFrom` if the run leaves orphans on the cluster.
    kept_orphans: KeptOrphans,
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
    /// The baseline's manifests ([`Baseline::manifests`]), which order the
    /// prune.
    old_manifests: Vec<Value>,
}

impl CheckedPlan {
    /// Return the flags that the plan was made and checked with.
    pub fn flags(&self) -> PlanFlags {
        self.flags
    }

    pub fn plan(&self) -> &DeployPlan {
        &self.plan
    }

    /// Return the orphans that this cluster's prune may delete. Orphans that
    /// another Kix cluster still deploys are in [`CheckedPlan::shared_orphans`].
    pub fn orphans(&self) -> &[ResourceId] {
        &self.orphans
    }

    pub fn shared_orphans(&self) -> &[SharedOrphan] {
        &self.shared_orphans
    }

    /// Return the package-grouped comparison of the old side with the new build.
    pub fn pkg_diff(&self) -> &PackageDiff {
        &self.pkg_diff
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

    /// Remove orphans that another Kix cluster still deploys ([`keep_shared`])
    /// from the prune set and package diff on a plan made without a client
    /// (`--current-activation`).
    pub fn keep_shared(&mut self, shared: &[SharedOrphan]) {
        self.orphans
            .retain(|rid| !shared.iter().any(|s| &s.rid == rid));
        self.pkg_diff.keep_shared(shared);
        self.shared_orphans.extend(shared.iter().cloned());
    }

    /// Run the engine over the plan with every write sent as a dry run, and
    /// return what the apiserver answered for each object. Nothing is
    /// written to the Activation record. The prune follows the plan's
    /// flags.
    pub async fn dry_run(
        &self,
        target: Target,
        config: SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> (Result<DeployResult, DeployError>, Vec<DryRunAnswer>) {
        let dry = Arc::new(DryRun::new(
            target.client,
            target.discovery,
            self.cluster.clone(),
            self.activation_identity_hash.clone(),
            self.flags.force_conflicts,
            target.sops,
        ));
        let result = scheduler::run_deploy(
            Cluster::dry_run(dry.clone()),
            self.plan.clone(),
            &self.orphans,
            &self.old_manifests,
            self.flags.prune_policy(),
            &config,
            observer,
        )
        .await;
        (result, dry.take_answers())
    }

    /// Run the engine over the checked plan, writing its Activation record
    /// with `receipt` as the provenance. The prune follows the flags the
    /// check used.
    ///
    /// Also returns the `status.orphansKeptFrom` the run's finalize wrote,
    /// or `None` when it did not finalize.
    pub async fn run(
        self,
        target: Target,
        receipt: Option<Value>,
        config: SchedulerConfig,
        observer: Arc<dyn DeployObserver>,
    ) -> (
        Result<DeployResult, DeployError>,
        Option<Vec<KeptOrphanSource>>,
    ) {
        let (cluster, record) = Cluster::new(
            KubeResources::new(
                target.client,
                target.discovery,
                self.cluster,
                self.activation_identity_hash,
                self.flags.force_conflicts,
            ),
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
                mark_failed_on_abort: true,
            },
            target.sops,
        );
        let result = scheduler::run_deploy(
            cluster,
            self.plan,
            &self.orphans,
            &self.old_manifests,
            self.flags.prune_policy(),
            &config,
            observer,
        )
        .await;
        (result, record.orphans_kept_from())
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
    pub client: Option<Client>,
    pub baseline: Baseline,
    /// Against the Active closure only.
    pub migration_pairs: Vec<MigrationPair>,
    pub checked: CheckedPlan,
}

impl Planned {
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
        if annotations.is_empty() {
            return Ok(());
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
            if let ChangeAction::Apply(manifest) = &mut node.action {
                annotate(manifest);
            }
        }
        Ok(())
    }

    /// Replace the package diff's entries with what the apiserver answered
    /// in a dry run (`Overlay`), and return the drift the deploy reverts.
    /// `None` when the deployed build's manifests are not known (the old
    /// side was rebuilt from the live objects), so a commit's change and
    /// drift look the same; a first deploy has no deployed build and every
    /// change is intended.
    pub fn overlay(&mut self, answers: &[DryRunAnswer]) -> Option<Vec<DriftChange>> {
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
        let drift = Overlay {
            new_graph: self.build.graph(),
            deployed,
        }
        .apply(&mut self.checked.pkg_diff, answers);
        known.then_some(drift)
    }
}

/// Makes the plan of a deploy with `flags`, reporting what it finds to
/// `report`.
pub struct Planner<'a> {
    flags: PlanFlags,
    report: &'a dyn Fn(PlanEvent<'_>),
}

impl<'a> Planner<'a> {
    pub fn new(flags: PlanFlags, report: &'a dyn Fn(PlanEvent<'_>)) -> Self {
        Planner { flags, report }
    }

    /// Plan a deploy of `build` against `old`: connect, unless the old side
    /// is the local cache, then the three steps.
    pub async fn run(&self, build: InstallableBuild, old: &OldSide) -> Result<Planned, PlanError> {
        let client = match old {
            OldSide::LocalCache => None,
            OldSide::Cluster { context, policy } => {
                (self.report)(PlanEvent::Connecting);
                let client = client::make_client(context.as_deref(), policy.clone())
                    .await
                    .map_err(|e| PlanError::Connect(Box::new(e)))?;
                Some(client)
            }
        };
        let new_graph = build.graph();
        let baseline = match &client {
            Some(client) => Baseline::of_cluster(client, &build, self.report).await?,
            None => Baseline::of_cache(&new_graph.cluster_name, self.report),
        };
        let new_manifests = manifests_of(new_graph);
        // A half-applied closure is not a previous intended state, so
        // pairing against it would invent migrations nobody declared.
        let migration_pairs = detect_migration_pairs(&new_manifests, &baseline.active_manifests);
        let checked = self
            .check(
                new_graph,
                &new_manifests,
                &new_graph.cluster_name,
                &baseline,
                client.as_ref(),
            )
            .await?;
        Ok(Planned {
            build,
            new_manifests,
            client,
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
    /// checks the orphans once it connects.
    pub async fn plan(
        &self,
        new_graph: &StoreGraph,
        cluster: &str,
        baseline: &Baseline,
        client: Option<&Client>,
    ) -> Result<CheckedPlan, PlanError> {
        let new_manifests = manifests_of(new_graph);
        self.check(new_graph, &new_manifests, cluster, baseline, client)
            .await
    }

    /// Compute what `new_manifests` change against `baseline`
    /// ([`Baseline::changes`]) and the kept-orphan sources for the new record.
    fn changes(&self, new_manifests: &[Value], baseline: &Baseline, read_records: bool) -> Changes {
        let actions = baseline.changes(new_manifests, self.flags.reconcile);
        let orphans = actions
            .iter()
            .filter_map(|action| match action {
                ChangeAction::Orphan(rid) => Some(rid.clone()),
                _ => None,
            })
            .collect();
        let mut kept_orphans = baseline.orphans_kept_from(new_manifests);
        // A plan that did not read the Active record carries its list
        // forward unexamined.
        kept_orphans.carry_current = !read_records;
        Changes {
            actions,
            orphans,
            kept_orphans,
        }
    }

    /// Run [`Planner::plan`] over the manifests of `new_graph`.
    async fn check(
        &self,
        new_graph: &StoreGraph,
        new_manifests: &[Value],
        cluster: &str,
        baseline: &Baseline,
        client: Option<&Client>,
    ) -> Result<CheckedPlan, PlanError> {
        let changes = self.changes(new_manifests, baseline, client.is_some());
        let (orphans, shared_orphans) = match client {
            Some(client) => keep_shared(client, cluster, changes.orphans).await?,
            None => (changes.orphans, Vec::new()),
        };
        let resource_graph =
            ResourceGraph::from_manifests(new_manifests).map_err(PlanError::Graph)?;
        let plan = DeployPlan::from_graph_and_changes(&resource_graph, &changes.actions)
            .map_err(PlanError::Marker)?;

        let record = lifecycle::record_of(new_manifests);
        let activation_name = record.and_then(|m| {
            m.pointer("/metadata/name")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
        let activation_identity_hash =
            record.and_then(|m| keys::get(m, keys::IDENTITY_HASH).map(str::to_string));

        let mut pkg_diff = diff_graphs(&baseline.diff_side(new_graph), new_graph);
        pkg_diff.keep_shared(&shared_orphans);

        let listed_deletes: &[ResourceId] = match client {
            Some(_) => &orphans,
            None => &[],
        };
        let objects = objects::of(
            &pkg_diff.shown,
            new_graph,
            &plan,
            &deletes_of(self.flags.prune_policy(), &orphans),
            listed_deletes,
            baseline.ran(),
        )
        .map_err(PlanError::Unshown)?;

        Ok(CheckedPlan {
            flags: self.flags,
            plan,
            orphans,
            shared_orphans,
            kept_orphans: changes.kept_orphans,
            pkg_diff,
            objects,
            activation_name,
            activation_identity_hash,
            record: record.cloned(),
            consumed_failed: baseline.failed().consumed.clone(),
            cluster: cluster.to_string(),
            old_manifests: baseline.manifests(),
        })
    }
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
pub(crate) fn deletes_of(prune: PrunePolicy, orphans: &[ResourceId]) -> Vec<ResourceId> {
    if prune != PrunePolicy::Delete {
        return Vec::new();
    }
    orphans
        .iter()
        .filter(|rid| !lifecycle::never_pruned(&rid.kind))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::lifecycle::PHASE_ACTIVE;
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
        ResourceId {
            kind: kind.into(),
            namespace: ns.into(),
            name: name.into(),
        }
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
        }
        let bytes: &[u8] = include_bytes!("../../tests/fixtures/kix-enterprise-test.json");
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
            prune: false,
            prune_mode: None,
            reconcile: false,
            force_conflicts: false,
            accept_migrations: false,
        };
        let new_manifests = manifests_of(build.graph());
        let checked = futures::executor::block_on(Planner::new(flags, &|_| {}).check(
            build.graph(),
            &new_manifests,
            "kix-enterprise-test",
            &baseline,
            None,
        ))
        .unwrap();
        Planned {
            build,
            new_manifests,
            client: None,
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
}
