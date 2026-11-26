//! The closures a plan compares against.
//!
//! A deploy or a rollback decides what to do by comparing compiler outputs:
//! the closure it is about to apply and the closure the cluster is already
//! running. That second closure comes from the Active Activation record.
//!
//! A deploy that stops partway applies some of its closure without becoming
//! Active, so neither side of a two-way comparison describes its leftovers.
//! Because the record is created before the first wave and marked `Failed`
//! when the run stops, those closures can be recovered by hash and folded in.
//! A deploy with `--only` leaves the same gap on purpose. It marks its record
//! `Partial`, and that record folds in the same way.
//!
//! A deploy that keeps its orphans (warn-only, the default) leaves the same
//! gap: the next plan compares against the new record only, and the build that
//! knew about those objects is no longer Active. The record therefore names
//! those objects in its kept-orphans revision, which [`kept_of`] reads from
//! the live objects. A record of a Kix cluster not read from revisions names
//! their builds under `status.orphansKeptFrom`, which [`load_kept`] resolves
//! the same way as a failed record's.
//!
//! Everything here resolves a record to a closure in the local store. Nothing
//! reads the cluster's objects except `Baseline::of_cluster` when the Active
//! record's build is not on this machine. Listing the records reads Kix's own
//! bookkeeping rather than the managed objects.
//!
//! When the Active build is read from the cluster, the failed and kept builds
//! are read from the same sweep. A machine that built none of a cluster's
//! deploys (for example, when every build came from CI) can still consume its
//! Failed records and shorten its kept list instead of carrying both forward.

use std::borrow::Cow;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

use std::collections::HashMap;

use kube::api::DynamicObject;
use kube::{client::Client, discovery::ApiResource};
use serde_json::Value;

use super::{PlanError, PlanEvent};
use crate::build_source::{Build, InstallableBuild};
use crate::cluster::activation::{self, KeptOrphanSource, OpenedRecords, Record, Records};
use crate::cluster::apply::{self, ChangeAction};
use crate::cluster::inventory::{Live, LiveObjects};
use crate::cluster::tenancy::{self, Kept, Tenancy};
use crate::cluster::{discovery, inventory, owned_view};
use crate::eval::package_index::RecordPackageIndex;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};

/// Everything a plan compares a build with: the Active record's closure,
/// and what failed and kept deploys left on the cluster. Made only by
/// [`Baseline::of_record`] and the planner, so no plan compares with a
/// baseline its caller made up.
#[derive(Debug)]
pub struct Baseline {
    /// The Active record the plan compares against. `None` on a first
    /// deploy.
    pub(crate) active: Option<Record>,
    /// Where `active_manifests` came from.
    pub(crate) source: ActiveSource,
    /// The Active record's closure.
    pub(crate) active_manifests: Vec<Value>,
    pub(crate) failed: FailedBaseline,
    pub(crate) kept: KeptBaseline,
    /// Which objects the Kix clusters on the Kubernetes cluster deploy, read
    /// when the baseline was. Empty under `--offline`.
    pub(crate) tenancy: Tenancy,
}

/// Where a [`Baseline`]'s Active closure came from.
#[derive(Debug, Default)]
pub(crate) enum ActiveSource {
    /// No Active record to compare with: a first deploy, or no cached
    /// build under `--offline`.
    #[default]
    NoRecord,
    /// The Active record's build, from this machine.
    Build(Box<StoreGraph>),
    /// The Active record's objects as the cluster holds them: its build is
    /// not on this machine.
    Live,
    /// The Active record's build is not on this machine, and nothing stands
    /// in for it.
    Unavailable,
}

impl Baseline {
    /// Return an empty baseline for a first deploy.
    pub(crate) fn empty() -> Baseline {
        Baseline {
            active: None,
            source: ActiveSource::NoRecord,
            active_manifests: Vec::new(),
            failed: FailedBaseline::default(),
            kept: KeptBaseline::default(),
            tenancy: Tenancy::empty(""),
        }
    }

    /// Return the Active record that the plan compares against, or `None` on
    /// a first deploy.
    pub fn active(&self) -> Option<&Record> {
        self.active.as_ref()
    }

    /// Return the closures of deploys that stopped partway and the records
    /// to supersede once the run finalizes.
    pub fn failed(&self) -> &FailedBaseline {
        &self.failed
    }

    /// Return the Active record's build when present on this machine.
    pub fn active_graph(&self) -> Option<&StoreGraph> {
        match &self.source {
            ActiveSource::Build(graph) => Some(graph.as_ref()),
            _ => None,
        }
    }

    /// Return the Active record's identity hash.
    pub fn active_hash(&self) -> Option<&str> {
        self.active.as_ref()?.identity_hash.as_deref()
    }

    /// Return the Active closure with the failed and kept closures merged in.
    /// Both the plan display and prune ordering need a manifest for any object
    /// that exists only in a failed or kept closure.
    pub fn manifests(&self) -> Vec<Value> {
        apply::baseline_manifests(
            &self.active_manifests,
            &[
                self.failed.closures.as_slice(),
                self.kept.closures.as_slice(),
            ]
            .concat(),
        )
    }

    /// Return an iterator over the manifests of every build the cluster ran
    /// (Active, failed, and kept) without merging. Writing one of their files
    /// is a re-apply (see [`super::objects`]).
    pub(crate) fn ran(&self) -> impl Iterator<Item = &Value> {
        self.active_manifests
            .iter()
            .chain(self.failed.closures.iter().flatten())
            .chain(self.kept.closures.iter().flatten())
    }

    /// Return the old side of the package diff for `new`. Uses the Active
    /// build when present on this machine, or synthesizes a graph from the
    /// baseline manifests so untouched packages show as unchanged. Returns an
    /// empty graph when no Active closure is available.
    pub(crate) fn diff_side(&self, new: &StoreGraph) -> Cow<'_, StoreGraph> {
        let empty = || Cow::Owned(StoreGraph::empty(&new.cluster_name));
        match &self.source {
            ActiveSource::Build(graph) => Cow::Borrowed(graph.as_ref()),
            ActiveSource::Unavailable => empty(),
            ActiveSource::NoRecord | ActiveSource::Live => {
                let manifests = self.manifests();
                if manifests.is_empty() {
                    empty()
                } else {
                    Cow::Owned(self.synthesized(&manifests, new))
                }
            }
        }
    }

    /// Synthesize the old side of the package diff from the baseline's
    /// manifests, for when the Active build is not on this machine.
    pub fn synthesized_side(&self, new: &StoreGraph) -> StoreGraph {
        self.synthesized(&self.manifests(), new)
    }

    /// Synthesize a graph of `manifests` against `new`, placing each object
    /// first by the package index of the Active record, then by those of the
    /// folded-in Failed records, newest first. A Failed record's index places
    /// what that deploy applied before it stopped. Kept builds name no
    /// record to read an index from, so their objects are placed by `new`
    /// or by their stamps.
    fn synthesized(&self, manifests: &[Value], new: &StoreGraph) -> StoreGraph {
        let active = self.active.as_ref().and_then(|a| self.tenancy.index_of(a));
        let indexes: Vec<&RecordPackageIndex> = active
            .iter()
            .chain(self.failed.indexes.iter().rev())
            .collect();
        StoreGraph::synthesize_placed(manifests, new, &indexes)
    }

    /// Compute the change action for each object of `new_manifests` and each
    /// orphan. Compares `new_manifests` against the Active closure, folds in
    /// failed and kept closures, and applies again each object the comparison
    /// leaves unchanged for which `write_again` is true.
    ///
    /// Only the Active closure is compared directly. Folding a failed closure
    /// into the old side would make an object that a failed deploy declared
    /// but never created appear already present; if the new build declared it
    /// at the same hash, the plan would skip it.
    pub(crate) fn changes(
        &self,
        new_manifests: &[Value],
        mut write_again: impl FnMut(&ResourceId) -> bool,
    ) -> Vec<ChangeAction> {
        let actions = apply::fold_kept_closures(
            apply::fold_failed_closures(
                apply::detect_changes(new_manifests, &self.active_manifests),
                new_manifests,
                &self.failed.closures,
            ),
            new_manifests,
            &self.kept.closures,
        );
        let by_id: std::collections::HashMap<ResourceId, &Value> = new_manifests
            .iter()
            .map(|m| (ResourceId::from_value(m), m))
            .collect();
        actions
            .into_iter()
            .map(|action| match &action {
                ChangeAction::Skip(rid) if write_again(rid) => by_id
                    .get(rid)
                    .map_or(action.clone(), |m| ChangeAction::Apply((*m).clone())),
                _ => action,
            })
            .collect()
    }

    /// Compute the [`activation::KeptOrphans`] for `status.orphansKeptFrom`
    /// when a plan of `new_manifests` finalizes. Includes every compared build
    /// (Active, folded-in failed, and kept) that still leaves orphans, plus
    /// every kept source this machine could not resolve.
    ///
    /// When a rollback's current build cannot be read on this machine
    /// ([`ActiveSource::Unavailable`]), the current record is listed as
    /// unexamined so a later prune can still remove its objects.
    pub(crate) fn orphans_kept_from(&self, new_manifests: &[Value]) -> activation::KeptOrphans {
        let active_source = self.active.as_ref().and_then(|a| {
            Some(KeptOrphanSource {
                activation: a.name.clone(),
                identity_hash: a.identity_hash.clone()?,
                built_via: a.built_via.clone(),
            })
        });
        let (active_source, unexamined_active) = match self.source {
            ActiveSource::Unavailable => (None, active_source),
            _ => (active_source, None),
        };
        let compared = active_source
            .map(|source| (source, self.active_manifests.as_slice()))
            .into_iter()
            .chain(
                self.failed
                    .sources
                    .iter()
                    .cloned()
                    .zip(self.failed.closures.iter().map(Vec::as_slice)),
            )
            .chain(
                self.kept
                    .sources
                    .iter()
                    .cloned()
                    .zip(self.kept.closures.iter().map(Vec::as_slice)),
            );

        let mut found: Vec<KeptOrphanSource> = Vec::new();
        for (source, closure) in compared {
            if apply::leaves_orphans(closure, new_manifests)
                && !found
                    .iter()
                    .any(|s| s.identity_hash == source.identity_hash)
            {
                found.push(source);
            }
        }
        activation::KeptOrphans {
            found,
            unexamined: self
                .kept
                .unresolved
                .iter()
                .cloned()
                .chain(unexamined_active)
                .collect(),
            carry_current: false,
        }
    }

    /// Build the baseline under `--offline` from the local
    /// activation cache for `cluster` without connecting to the cluster.
    /// Because the cache has no `orphansKeptFrom` or failed records, orphans
    /// kept by earlier deploys are omitted from the plan and carried forward
    /// from the live record on finalize.
    pub(crate) fn of_cache(cluster: &str, report: &dyn Fn(PlanEvent<'_>)) -> Baseline {
        let Some(dir) = crate::eval::store::load_activation_path(cluster) else {
            report(PlanEvent::NoCachedBuild);
            return Baseline::empty();
        };
        report(PlanEvent::LoadingCache);
        let graph = match Build::local(&dir, &|_| {}) {
            Ok(build) => build.into_graph(),
            Err(e) => {
                tracing::warn!("failed to load old activation: {e}, treating as first deploy");
                return Baseline::empty();
            }
        };
        let active_manifests = manifests_of(&graph);
        let active = lifecycle::record_of(&active_manifests).and_then(|record| {
            Some(Record {
                name: record.pointer("/metadata/name")?.as_str()?.to_string(),
                identity_hash: keys::get(record, keys::IDENTITY_HASH).map(str::to_string),
                built_via: Some(dir.to_string_lossy().into_owned()),
                ..Default::default()
            })
        });
        Baseline {
            active,
            source: ActiveSource::Build(Box::new(graph)),
            active_manifests,
            ..Baseline::empty()
        }
    }

    /// Build the baseline for `build` against the cluster reached by `client`.
    /// Resolves the Active record's build locally (or reconstructs it from
    /// live cluster objects), resolves `orphansKeptFrom`, and resolves Failed
    /// records unless another deploy is in flight.
    pub(crate) async fn of_cluster(
        client: &Client,
        build: &Build,
        report: &dyn Fn(PlanEvent<'_>),
    ) -> Result<Baseline, PlanError> {
        let cluster = build.graph().cluster_name.as_str();
        let discovery = discovery::discover_resources(client)
            .await
            .map_err(|e| PlanError::Discovery(Box::new(e)))?;
        let opened = Records::open(client, &discovery).map_err(PlanError::Domain)?;
        let active = match opened.records() {
            Some(records) => records.active(cluster).await.ok().flatten(),
            None => None,
        };

        let mut live: Option<LiveClosures> = None;
        let mut tenancy: Option<Tenancy> = None;
        let mut baseline = match active {
            Some(active) if active.identity_hash.is_some() => {
                let hash = active.identity_hash.as_deref().unwrap_or_default();
                report(PlanEvent::Active {
                    name: &active.name,
                    identity_hash: hash,
                });
                match record_graph(Some(build), cluster, hash, active.built_via.as_deref()) {
                    Ok(Some(graph)) => {
                        note_index_disagreement(&active, &graph);
                        Baseline {
                            active_manifests: manifests_of(&graph),
                            source: ActiveSource::Build(Box::new(graph)),
                            active: Some(active),
                            ..Baseline::empty()
                        }
                    }
                    // A build that will not load, or is not the record's, is
                    // not a first deploy. Fall back to the cluster rather
                    // than planning against nothing.
                    found => {
                        report(PlanEvent::ReadingLive {
                            error: found.err().as_deref(),
                        });
                        let read = of_live(
                            client,
                            build.graph(),
                            &opened,
                            &discovery,
                            cluster,
                            &active,
                            report,
                        )
                        .await?;
                        live = Some(read.closures);
                        tenancy = Some(read.tenancy);
                        Baseline {
                            active_manifests: read.manifests,
                            source: ActiveSource::Live,
                            active: Some(active),
                            ..Baseline::empty()
                        }
                    }
                }
            }
            _ => {
                report(PlanEvent::NoActiveRecord);
                Baseline::empty()
            }
        };
        baseline.tenancy = match tenancy {
            Some(tenancy) => tenancy,
            None => read_tenancy(&opened, cluster).await?,
        };

        // Objects an earlier deploy that did not prune left on the cluster.
        // The Active closure no longer declares those objects, so without
        // these the plan cannot see them.
        if let Some(active) = &baseline.active {
            let new = build.graph().manifests_by_hash();
            baseline.kept = kept_of(
                client,
                &discovery,
                &baseline.tenancy,
                active,
                Some(build),
                &new,
                report,
                live.as_ref(),
            )
            .await?;
        }

        // Closures from deploys that stopped partway. Because they applied
        // objects without becoming Active, neither side of a two-way
        // comparison knows about them. Resolve them from the local store by
        // hash, or from the live sweep when the Active build was read live.
        if let Some(records) = opened.records() {
            baseline.failed = load_failed_unless_in_flight(
                records,
                &baseline.tenancy,
                Some(build),
                cluster,
                report,
                live.as_ref(),
            )
            .await;
        }
        Ok(baseline)
    }

    /// Build the baseline for a rollback of `cluster` from `current`.
    /// Resolves `current`'s build locally, resolves the objects it lists as
    /// kept orphans, and resolves Failed records unless another deploy is in
    /// flight.
    pub async fn of_record(
        records: &Records,
        cluster: &str,
        current: &Record,
        report: &dyn Fn(PlanEvent<'_>),
    ) -> Result<Baseline, PlanError> {
        // `built_via` is written by whoever deployed, so the build there is
        // used only when it is the record's. A record without an identity
        // hash names no build to look for.
        let graph = match current.identity_hash.as_deref() {
            None => {
                report(PlanEvent::ActiveWithoutHash {
                    activation: &current.name,
                    cluster,
                });
                None
            }
            Some(hash) => match record_graph(None, cluster, hash, current.built_via.as_deref()) {
                Ok(Some(graph)) => Some(graph),
                Ok(None) => {
                    report(PlanEvent::ActiveUnresolved {
                        record: current,
                        cluster,
                    });
                    None
                }
                Err(error) => {
                    report(PlanEvent::ActiveBuildUnusable {
                        activation: &current.name,
                        error: &error,
                        cluster,
                    });
                    None
                }
            },
        };
        let (source, active_manifests) = match graph {
            Some(graph) => {
                let manifests = manifests_of(&graph);
                (ActiveSource::Build(Box::new(graph)), manifests)
            }
            None => (ActiveSource::Unavailable, Vec::new()),
        };
        let tenancy = read_tenancy(&OpenedRecords::from(records.clone()), cluster).await?;
        let failed =
            load_failed_unless_in_flight(records, &tenancy, None, cluster, report, None).await;
        let kept = match tenancy.kept(current) {
            Kept::Builds(sources) => load_kept(sources, None, cluster, report, None),
            Kept::Objects(_) => {
                let client = records.client();
                let discovery = discovery::discover_resources(client)
                    .await
                    .map_err(|e| PlanError::Discovery(Box::new(e)))?;
                kept_of(
                    client,
                    &discovery,
                    &tenancy,
                    current,
                    None,
                    &HashMap::new(),
                    report,
                    None,
                )
                .await?
            }
        };
        Ok(Baseline {
            active: Some(current.clone()),
            source,
            active_manifests,
            failed,
            kept,
            tenancy,
        })
    }
}

/// Log at debug level when `active`'s stored package index differs from the
/// index of its build. The build is the source, so a plan uses the build and
/// the note only helps explain a diff made on another machine.
fn note_index_disagreement(active: &Record, graph: &StoreGraph) {
    if let Some(stored) = &active.package_index
        && *stored != RecordPackageIndex::of(graph)
    {
        tracing::debug!(
            activation = %active.name,
            "the record's package index differs from its build; using the build",
        );
    }
}

/// Closures left behind by deploys that stopped before finalizing.
#[derive(Debug, Default)]
pub struct FailedBaseline {
    /// One stamped manifest set per record we could resolve, oldest first.
    pub closures: Vec<Vec<Value>>,
    /// Record names to supersede once this plan finalizes. Only the ones whose
    /// closure was actually folded in: a record we could not resolve has not
    /// been reconciled and must keep asking.
    pub consumed: Vec<String>,
    /// The build behind each entry of `closures`, in the same order, for
    /// `status.orphansKeptFrom` when this plan keeps the orphans it found.
    pub sources: Vec<KeptOrphanSource>,
    /// Records whose closure is not in this machine's store.
    pub unresolved: Vec<Record>,
    /// The package index of each folded-in record that has one, oldest
    /// first.
    pub indexes: Vec<RecordPackageIndex>,
    /// The folded-in records in phase `Partial`, which a deploy with
    /// `--only` left partly deployed. A subset of `consumed`.
    pub partly_deployed: Vec<String>,
}

impl FailedBaseline {
    pub fn is_empty(&self) -> bool {
        self.closures.is_empty()
    }

    /// Return, for each object of a folded build that may have been left
    /// behind, the identity hashes of the folded records that list it: the
    /// objects that neither `new_manifests` nor `active` hold.
    fn candidates(
        &self,
        new_manifests: &[Value],
        active: &[Value],
    ) -> HashMap<ResourceId, Vec<String>> {
        let held: HashSet<ResourceId> = new_manifests
            .iter()
            .chain(active)
            .map(ResourceId::from_value)
            .collect();
        let mut out: HashMap<ResourceId, Vec<String>> = HashMap::new();
        for (closure, source) in self.closures.iter().zip(&self.sources) {
            for manifest in closure {
                let rid = ResourceId::from_value(manifest);
                if keys::get(manifest, keys::IDENTITY_HASH).is_some() && !held.contains(&rid) {
                    out.entry(rid)
                        .or_default()
                        .push(source.identity_hash.clone());
                }
            }
        }
        out
    }

    /// Drop from each folded build the objects that neither `new_manifests`
    /// nor `active` hold and that its deploy did not create: `on_cluster`
    /// does not list the object with that record's identity hash. Those are
    /// objects the deploy stopped before, or that a deploy with `--only`
    /// did not select, so nothing of them is on the cluster to delete.
    fn keep_created(
        &mut self,
        new_manifests: &[Value],
        active: &[Value],
        on_cluster: &HashMap<ResourceId, HashSet<String>>,
    ) {
        let candidates = self.candidates(new_manifests, active);
        for (closure, source) in self.closures.iter_mut().zip(&self.sources) {
            closure.retain(|manifest| {
                let rid = ResourceId::from_value(manifest);
                !candidates.contains_key(&rid)
                    || on_cluster
                        .get(&rid)
                        .is_some_and(|stamps| stamps.contains(&source.identity_hash))
            });
        }
    }
}

impl Baseline {
    /// Read from the cluster behind `client` which objects of the folded
    /// builds that `new_manifests` and the Active closure lack are there,
    /// and drop the others from the folded builds
    /// ([`FailedBaseline::keep_created`]). An object is a folded deploy's
    /// leftover only when the cluster holds it and that deploy applied it
    /// ([`Tenancy::applied_by`]). An object it did not
    /// apply because it was unchanged is in the Active closure, which this
    /// leaves alone. Reads each candidate once. A failed read stops the
    /// plan, because guessing would list or delete the wrong objects.
    pub(crate) async fn read_folded_leftovers(
        &mut self,
        client: &Client,
        new_manifests: &[Value],
    ) -> Result<(), PlanError> {
        let candidates = self
            .failed
            .candidates(new_manifests, &self.active_manifests);
        if candidates.is_empty() {
            return Ok(());
        }
        let folded: Vec<&str> = self.failed.consumed.iter().map(String::as_str).collect();
        self.tenancy
            .complete_for_records(&folded)
            .map_err(|e| PlanError::Tenancy(Box::new(e)))?;
        let tenancy = &self.tenancy;
        let discovery = discovery::discover_resources(client)
            .await
            .map_err(|e| PlanError::Discovery(Box::new(e)))?;
        let reads = candidates.keys().filter_map(|rid| {
            // A kind the cluster does not serve has no object to read.
            let (ar, scope) = discovery::find(&discovery, &rid.group, &rid.kind)?;
            let api = discovery::api_for(client, ar, scope, rid);
            Some(async move {
                let obj = api.get_opt(&rid.name).await.map_err(|source| {
                    crate::cluster::errors::FetchError::GetError {
                        resource: rid.display_id(),
                        source,
                    }
                })?;
                let stamps: HashSet<String> =
                    obj.map(|o| tenancy.applied_by(&o)).unwrap_or_default();
                Ok::<_, crate::cluster::errors::FetchError>((rid.clone(), stamps))
            })
        });
        let on_cluster: HashMap<ResourceId, HashSet<String>> = futures::future::try_join_all(reads)
            .await
            .map_err(|e| PlanError::FoldedLeftovers(Box::new(e)))?
            .into_iter()
            .collect();
        let active = std::mem::take(&mut self.active_manifests);
        self.failed
            .keep_created(new_manifests, &active, &on_cluster);
        self.active_manifests = active;
        Ok(())
    }
}

/// The builds an earlier deploy kept orphans from, resolved to closures.
#[derive(Debug, Default)]
pub struct KeptBaseline {
    /// One stamped manifest set per source this machine could resolve.
    pub closures: Vec<Vec<Value>>,
    /// The source behind each entry of `closures`, in the same order.
    pub sources: Vec<KeptOrphanSource>,
    /// Sources whose build is not in this machine's store. Their orphans are
    /// not in this plan, and the next record carries them forward unchanged
    /// so a machine that has the build can still prune them.
    pub unresolved: Vec<KeptOrphanSource>,
    /// Every object the kept-orphans revision names, live or not, when the
    /// Kix cluster is read from revisions. `closures` then holds one closure
    /// of the ones still on the cluster.
    pub listed: Option<Vec<crate::cluster::revision::RevisionObject>>,
}

/// Call [`load_failed`] unless another deploy of `cluster` is still running
/// ([`deploy_in_flight`]). When another deploy is in flight, leave its
/// objects alone rather than pruning work it is still applying.
async fn load_failed_unless_in_flight(
    records: &Records,
    tenancy: &Tenancy,
    build: Option<&Build>,
    cluster: &str,
    report: &dyn Fn(PlanEvent<'_>),
    live: Option<&LiveClosures>,
) -> FailedBaseline {
    match deploy_in_flight(records, cluster).await {
        InFlight::Locked => return FailedBaseline::default(),
        InFlight::Unlocked(record) => {
            report(PlanEvent::DeployInFlight(&record));
            return FailedBaseline::default();
        }
        InFlight::No => {}
    }
    load_failed(records, tenancy, build, cluster, report, live).await
}

/// Resolve every `Failed` or `Partial` record for a cluster to its closure:
/// from the local store, or from `live` when the plan read the cluster.
///
/// A record that cannot be resolved is reported without being consumed. It
/// usually means the failed deploy ran on a different
/// machine, so this one cannot know what it applied; saying so and leaving the
/// record in place is more honest than superseding it and forgetting.
async fn load_failed(
    records: &Records,
    tenancy: &Tenancy,
    build: Option<&Build>,
    cluster: &str,
    report: &dyn Fn(PlanEvent<'_>),
    live: Option<&LiveClosures>,
) -> FailedBaseline {
    let records = match records.stopped(cluster).await {
        Ok(records) => records,
        Err(e) => {
            tracing::debug!("could not list failed activations: {e}");
            return FailedBaseline::default();
        }
    };

    let mut out = FailedBaseline::default();
    for record in records {
        let Some(hash) = record.identity_hash.clone() else {
            out.unresolved.push(record);
            continue;
        };
        let from_store = resolve_closure(build, cluster, &hash, record.built_via.as_deref());
        let closure = match (from_store, live) {
            (Ok(Some(closure)), _) => closure,
            (Ok(None) | Err(_), Some(live)) => live.closure_of(&hash),
            (Ok(None), None) => {
                out.unresolved.push(record);
                continue;
            }
            (Err(e), None) => {
                report(PlanEvent::FailedBuildUnusable {
                    activation: &record.name,
                    error: &e,
                });
                out.unresolved.push(record);
                continue;
            }
        };
        report(PlanEvent::FailedFolded(&record));
        out.closures.push(closure);
        out.indexes.extend(tenancy.index_of(&record));
        out.consumed.push(record.name.clone());
        if record.partly_deployed().is_some() {
            out.partly_deployed.push(record.name.clone());
        }
        out.sources.push(KeptOrphanSource {
            activation: record.name.clone(),
            identity_hash: hash,
            built_via: record.built_via.clone(),
        });
    }

    if !out.unresolved.is_empty() {
        report(PlanEvent::FailedUnresolved {
            records: &out.unresolved,
            cluster,
        });
    }
    out
}

/// Resolve the builds a record lists under `status.orphansKeptFrom`
/// ([`Kept::Builds`]) to closures, from the local store or from `live` when
/// the plan read the cluster, and say how many there are so the plan's extra
/// orphans have an explanation.
pub fn load_kept(
    sources: &[KeptOrphanSource],
    build: Option<&Build>,
    cluster: &str,
    report: &dyn Fn(PlanEvent<'_>),
    live: Option<&LiveClosures>,
) -> KeptBaseline {
    let mut out = KeptBaseline::default();
    for source in sources {
        let from_store = resolve_closure(
            build,
            cluster,
            &source.identity_hash,
            source.built_via.as_deref(),
        );
        let closure = match (from_store, live) {
            (Ok(Some(closure)), _) => closure,
            (Ok(None) | Err(_), Some(live)) => live.closure_of(&source.identity_hash),
            (Ok(None), None) => {
                out.unresolved.push(source.clone());
                continue;
            }
            (Err(e), None) => {
                report(PlanEvent::KeptBuildUnusable {
                    activation: &source.activation,
                    error: &e,
                });
                out.unresolved.push(source.clone());
                continue;
            }
        };
        out.closures.push(closure);
        out.sources.push(source.clone());
    }
    if !out.sources.is_empty() {
        report(PlanEvent::KeptFolded(&out.sources));
    }
    if !out.unresolved.is_empty() {
        report(PlanEvent::KeptUnresolved {
            sources: &out.unresolved,
            cluster,
        });
    }
    out
}

/// Objects from a live reconstruction that belong to builds other than the
/// Active one. Holds the swept objects that each record deploys
/// ([`Tenancy::records_naming`]) and the Active record does not, projected
/// as Kix-owned manifests.
#[derive(Debug, Default)]
pub struct LiveClosures {
    by_hash: HashMap<String, Vec<Value>>,
}

impl LiveClosures {
    fn of(
        objects: &[DynamicObject],
        manifests: &[Value],
        tenancy: &Tenancy,
        active_hash: Option<&str>,
    ) -> Self {
        let mut by_hash: HashMap<String, Vec<Value>> = HashMap::new();
        for (obj, manifest) in objects.iter().zip(manifests) {
            let named = tenancy.records_naming(obj);
            if named.iter().any(|h| Some(h.as_str()) == active_hash) {
                continue;
            }
            for hash in named {
                by_hash.entry(hash).or_default().push(manifest.clone());
            }
        }
        LiveClosures { by_hash }
    }

    /// Return the objects that only `identity_hash` keeps on the cluster.
    pub fn closure_of(&self, identity_hash: &str) -> Vec<Value> {
        self.by_hash.get(identity_hash).cloned().unwrap_or_default()
    }
}

/// Return the store path of the build matching `identity_hash` on this
/// machine, validated by [`record_graph`]. `kix history` calls this to mark
/// the deploys `kix rollback` can restore, so it must look where
/// [`target_build`] looks.
pub fn checked_dir(
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<Option<PathBuf>, String> {
    record_graph(None, cluster, identity_hash, built_via).map(|g| g.map(|g| g.built_via))
}

/// Return the store path of the build named by `active`, along with a
/// warning when the local activation cache was ignored.
///
/// Because `store::load_activation_path` is keyed by cluster name alone, it
/// can hold a build that another kube context deployed under the same cluster
/// name. The cached path is used only when its identity hash matches `active`.
/// Otherwise, the build is resolved from `active` via [`record_graph`].
pub fn active_build_dir(
    cluster: &str,
    cached: Option<PathBuf>,
    active: Option<&Record>,
) -> (Option<PathBuf>, Option<String>) {
    active_build_dir_with(cluster, cached, active, checked_dir)
}

/// Run [`active_build_dir`] using `find` in place of [`checked_dir`].
fn active_build_dir_with(
    cluster: &str,
    cached: Option<PathBuf>,
    active: Option<&Record>,
    find: impl FnOnce(&str, &str, Option<&str>) -> Result<Option<PathBuf>, String>,
) -> (Option<PathBuf>, Option<String>) {
    let cached_hash = cached
        .as_deref()
        .and_then(crate::eval::store::build_hash_of);
    let Some(hash) = active.and_then(|a| a.identity_hash.as_deref()) else {
        let warning = cached.map(|dir| {
            format!(
                "cluster '{cluster}' has no Active record in this context, so the cached build {} is not used",
                dir.display()
            )
        });
        return (None, warning);
    };
    if cached_hash.as_deref() == Some(hash) {
        return (cached, None);
    }
    let warning = cached.map(|dir| {
        format!(
            "the cached build {} ({}) is not the Active build of cluster '{cluster}' in this context ({}); using the Active record's build",
            dir.display(),
            short(cached_hash.as_deref().unwrap_or("no identity hash")),
            short(hash),
        )
    });
    let built_via = active.and_then(|a| a.built_via.as_deref());
    match find(cluster, hash, built_via) {
        Ok(dir) => (dir, warning),
        Err(refused) => {
            let warning = match warning {
                Some(warning) => format!("{warning}, but {refused}"),
                None => refused,
            };
            (None, Some(warning))
        }
    }
}

fn short(hash: &str) -> &str {
    &hash[..8.min(hash.len())]
}

/// Load the stamped build named by an Activation record from `build`,
/// `built_via`, or the local activation cache. Returns `Ok(None)` when none of
/// those sources are present on this machine.
///
/// Because `built_via` is written by whoever deployed, the loaded build is
/// verified against `identity_hash`.
pub fn record_graph(
    build: Option<&Build>,
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<Option<StoreGraph>, String> {
    if let Some(graph) = build.map_or(Ok(None), |b| b.deployed_build(identity_hash))? {
        return Ok(Some(graph));
    }
    checked_build(
        identity_hash,
        local_build_dir(built_via),
        || crate::eval::store::resolve_activation_by_hash(cluster, identity_hash),
        load_build,
        |graph| graph,
    )
}

/// Return `built_via` when it names a build directory.
fn local_build_dir(built_via: Option<&str>) -> Option<PathBuf> {
    built_via
        .map(PathBuf::from)
        .filter(|p| crate::eval::build_files::BuildFiles::is_build(p))
}

/// Load the target build for a rollback to record `name` from where
/// [`record_graph`] looks, and verify it the same way. The cluster ran this
/// build before, so it is installable even when it predates the domain move
/// ([`Build::installable_as_deployed`]).
pub fn target_build(
    cluster: &str,
    name: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<InstallableBuild, String> {
    let found = checked_build(
        identity_hash,
        local_build_dir(built_via),
        || crate::eval::store::resolve_activation_by_hash(cluster, identity_hash),
        |dir| Build::local(dir, &|_| {}),
        Build::graph,
    )
    .map_err(|error| {
        format!(
            "rollback target {name}'s build (hash: {identity_hash}) could not be loaded\n  \
             Nothing was applied to the cluster.\n\n  \
             Cause:\n    {error}\n\n  \
             Next (choose one):\n    \
             - Run `kix rollback {cluster}` on a machine with a working build for {name}.\n    \
             - Run `kix rollback {cluster}` interactively and pick another deployment record marked `[available]`.\n    \
             - Check out the git commit that deployed {name} and run `kix deploy {cluster}`."
        )
    })?;
    let found = found.ok_or_else(|| {
        format!(
            "rollback target {name}'s build is not on this machine (hash: {identity_hash})\n  \
             Nothing was applied to the cluster.\n\n  \
             Why:\n    \
             The build for {name} is not in Kix's local store on this machine (it may have been removed or built on another machine, such as CI).\n\n  \
             Next (choose one):\n    \
             - Run `kix rollback {cluster}` on a machine that has {name}'s build.\n    \
             - Run `kix rollback {cluster}` interactively on this machine and pick a deployment record marked `[available]` (or run `kix history {cluster}` to see them).\n    \
             - Check out the git commit that deployed {name} and run `kix deploy {cluster}`."
        )
    })?;
    Ok(found.installable_as_deployed())
}

/// Load the build at `dir` with stamps applied. A record's build
/// can predate a domain move, so it is not checked with [`Build::installable`].
fn load_build(dir: &Path) -> Result<StoreGraph, crate::eval::KixEvalError> {
    Build::local(dir, &|_| {}).map(Build::into_graph)
}

/// Load the first of `built_via` and `cached` that loads and matches
/// `identity_hash`. Falls back to `cached` when `built_via` is absent, fails
/// to load, or holds a different build.
/// `graph` reads the graph out of what `load` returns.
fn checked_build<T>(
    identity_hash: &str,
    built_via: Option<PathBuf>,
    cached: impl FnOnce() -> Option<PathBuf>,
    load: impl Fn(&Path) -> Result<T, crate::eval::KixEvalError>,
    graph: impl Fn(&T) -> &StoreGraph,
) -> Result<Option<T>, String> {
    let check = |dir: PathBuf| -> Result<T, String> {
        let loaded = load(&dir)
            .map_err(|e| format!("the build at {} would not load: {e}", dir.display()))?;
        let found = crate::eval::store_graph::store_hash(&graph(&loaded).activation_path);
        if found != identity_hash {
            return Err(format!(
                "the build at {} is activation {}, not {}",
                dir.display(),
                short(&found),
                short(identity_hash),
            ));
        }
        Ok(loaded)
    };
    let refused = match built_via.clone().map(check) {
        Some(Ok(graph)) => return Ok(Some(graph)),
        Some(Err(e)) => Some(e),
        None => None,
    };
    match cached().filter(|dir| Some(dir) != built_via.as_ref()) {
        Some(dir) => match check(dir) {
            Ok(graph) => Ok(Some(graph)),
            Err(e) => Err(refused.unwrap_or(e)),
        },
        None => refused.map_or(Ok(None), Err),
    }
}

/// Resolve the stamped manifests of a build from `build`, `built_via`, or the
/// local activation cache by identity hash. Returns `Ok(None)` when none of
/// those sources are present locally, or `Err` when a found build fails to load.
fn resolve_closure(
    build: Option<&Build>,
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<Option<Vec<Value>>, String> {
    Ok(record_graph(build, cluster, identity_hash, built_via)?.map(|graph| manifests_of(&graph)))
}

fn manifests_of(graph: &StoreGraph) -> Vec<Value> {
    graph
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect()
}

/// Keep a Nix GC root for every build in `recorded` that resolves locally and
/// matches its hash ([`record_graph`]), and drop roots for builds no longer
/// listed.
pub fn sync_kept_roots(cluster: &str, recorded: &[KeptOrphanSource]) {
    let listed: Vec<(String, Option<PathBuf>)> = recorded
        .iter()
        .map(|source| {
            let dir = checked_dir(cluster, &source.identity_hash, source.built_via.as_deref())
                .ok()
                .flatten();
            (source.identity_hash.clone(), dir)
        })
        .collect();
    crate::eval::store::sync_kept_roots(cluster, &listed);
}

/// Whether another deploy of a Kix cluster may be applying objects now.
enum InFlight {
    No,
    /// Another run holds the cluster's deploy lock to deploy, roll back, or
    /// delete. Commands that print the plan name it.
    Locked,
    /// A `Deploying` record that no run holds the lock for: a run of an
    /// older Kix, which takes no lock, may be deploying it, or one died
    /// before it could mark it `Failed`.
    Unlocked(Box<Record>),
}

/// Decide whether another deploy of `cluster` may be running, so the caller
/// leaves the closures of failed deploys out of its plan rather than prune
/// objects that run is still applying.
///
/// The deploy lock answers this when a run other than the operator's drift
/// repair holds it. Otherwise a `Deploying` record still means a run of a
/// Kix without the lock may be in flight. Operator-driven records are
/// ignored there because the controller resumes them itself.
async fn deploy_in_flight(records: &Records, cluster: &str) -> InFlight {
    match crate::cluster::head::read(records.client(), cluster).await {
        Ok(Some(head))
            if head
                .lock()
                .is_some_and(|l| l.purpose != crate::cluster::head::Purpose::Repair) =>
        {
            return InFlight::Locked;
        }
        Ok(_) => {}
        Err(e) => tracing::debug!("could not read the deploy lock: {e}"),
    }
    match records.deploying(cluster).await {
        Ok(found) => found
            .into_iter()
            .find(|record| !record.operator_driven)
            .map_or(InFlight::No, |r| InFlight::Unlocked(Box::new(r))),
        Err(e) => {
            tracing::debug!("could not list deploying activations: {e}");
            InFlight::No
        }
    }
}

/// What [`of_live`] read.
struct LiveRead {
    manifests: Vec<Value>,
    closures: LiveClosures,
    tenancy: Tenancy,
}

/// Reconstruct the previous deploy's manifest set from live cluster state.
///
/// Used when the old activation's store path is not present locally. Every
/// Kix-managed resource carries the `identity-hash` and `depends-on`
/// annotations that change detection and prune ordering read, so live objects
/// projected back to manifests can stand in for the old store graph.
/// Activation CRs are excluded because their lifecycle is managed by
/// superseding rather than pruning. An object whose identity hash names a
/// manifest of `new` reads as that manifest (see
/// [`owned_view::kix_owned_manifests_against`]), so the plan does not show
/// server normalisation as a change.
///
/// Includes only objects of the Active record, a Failed or Partial record
/// of this cluster, or the objects the Active record lists as kept orphans
/// ([`Tenancy::kept`]). Objects of other Kix clusters on the same Kubernetes
/// cluster belong to none of these, so they never become orphans. Objects
/// of this cluster that only older builds name are excluded and reported
/// via [`PlanEvent::OlderBuildsLeftOut`]. The [`Tenancy`] is read after the
/// objects are listed, and returned for the rest of the baseline.
///
/// Returns an error if the sweep fails so the planner never falls back to an
/// empty baseline when the apiserver is unhealthy.
async fn of_live(
    client: &Client,
    new: &StoreGraph,
    opened: &OpenedRecords,
    discovery: &[(ApiResource, kube::discovery::Scope)],
    cluster: &str,
    active: &Record,
    report: &dyn Fn(PlanEvent<'_>),
) -> Result<LiveRead, PlanError> {
    let sweep = inventory::list_managed(client, discovery)
        .await
        .map_err(|e| PlanError::Reconstruct(e.to_string()))?;
    let tenancy = read_tenancy(opened, cluster).await?;
    let stopped = match opened.records() {
        Some(records) => records
            .stopped(cluster)
            .await
            .map_err(|e| PlanError::Reconstruct(e.to_string()))?,
        None => Vec::new(),
    };
    let (hashes, names);
    let scope = match (&active.revisions, tenancy.own_source()) {
        (Some(Ok(map)), tenancy::Source::Revisions) => {
            tenancy
                .complete_for_own()
                .map_err(|e| PlanError::Tenancy(Box::new(e)))?;
            names = map
                .names()
                .chain(
                    stopped
                        .iter()
                        .filter_map(|r| r.revisions.as_ref()?.as_ref().ok())
                        .flat_map(|m| m.names()),
                )
                .map(str::to_string)
                .collect();
            inventory::SweepScope::Revisions {
                cluster,
                names: &names,
            }
        }
        _ => {
            let mut found: HashSet<String> = active.identity_hash.iter().cloned().collect();
            if let Kept::Builds(sources) = tenancy.kept(active) {
                found.extend(sources.iter().map(|s| s.identity_hash.clone()));
            }
            found.extend(stopped.iter().filter_map(|f| f.identity_hash.clone()));
            hashes = found;
            inventory::SweepScope::Records {
                cluster,
                hashes: &hashes,
            }
        }
    };
    let sweep = inventory::scope_sweep(sweep, scope, tenancy);
    if sweep.other_builds > 0 {
        report(PlanEvent::OlderBuildsLeftOut(sweep.other_builds));
    }
    let tenancy = sweep.tenancy;
    let objects: Vec<DynamicObject> = sweep
        .managed
        .into_iter()
        .filter(|obj| lifecycle::lifecycle_of_live(obj).prunable())
        .collect();
    let manifests =
        owned_view::kix_owned_manifests_against(objects.iter().cloned(), &new.manifests_by_hash());
    let closures = LiveClosures::of(
        &objects,
        &manifests,
        &tenancy,
        active.identity_hash.as_deref(),
    );
    Ok(LiveRead {
        manifests,
        closures,
        tenancy,
    })
}

/// Read the [`Tenancy`] of `cluster` for a plan.
async fn read_tenancy(opened: &OpenedRecords, cluster: &str) -> Result<Tenancy, PlanError> {
    tenancy::read(opened, cluster)
        .await
        .map_err(|e| PlanError::ReadTenancy(Box::new(e)))
}

/// Resolve the objects `active` lists as kept orphans ([`Tenancy::kept`]).
///
/// For a Kix cluster read from records, these are the builds of
/// `status.orphansKeptFrom` ([`load_kept`]). For one read from revisions,
/// they are the objects its kept-orphans revision names that the cluster
/// still holds, listed with one request for each of their kinds and read as
/// the Kix-owned part of each object, against `built` when it holds the
/// object's build hash. Refuse when that revision could not be read.
#[allow(clippy::too_many_arguments)]
pub async fn kept_of(
    client: &Client,
    discovery: &[(ApiResource, kube::discovery::Scope)],
    tenancy: &Tenancy,
    active: &Record,
    build: Option<&Build>,
    built: &HashMap<String, &Value>,
    report: &dyn Fn(PlanEvent<'_>),
    live: Option<&LiveClosures>,
) -> Result<KeptBaseline, PlanError> {
    let cluster = tenancy.cluster.as_str();
    let objects = match tenancy.kept(active) {
        Kept::Builds(sources) => return Ok(load_kept(sources, build, cluster, report, live)),
        Kept::Objects(objects) => objects,
    };
    tenancy
        .complete_for_kept()
        .map_err(|e| PlanError::Tenancy(Box::new(e)))?;
    let ids: Vec<ResourceId> = objects.iter().map(|o| o.resource_id()).collect();
    let listed = LiveObjects::list(client, discovery, &ids)
        .await
        .map_err(|e| PlanError::Reconstruct(e.to_string()))?;
    let present = ids.iter().filter_map(|rid| match listed.get(rid) {
        Live::Present(obj) => Some(obj.clone()),
        Live::Absent | Live::Unread => None,
    });
    let manifests = owned_view::kix_owned_manifests_against(present, built);
    Ok(KeptBaseline {
        closures: if manifests.is_empty() {
            Vec::new()
        } else {
            vec![manifests]
        },
        listed: Some(objects.into_iter().cloned().collect()),
        ..KeptBaseline::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::lifecycle::{
        PHASE_ACTIVE, PHASE_DEPLOYING, PHASE_FAILED, PHASE_PARTIAL, PHASE_SUPERSEDED,
    };
    use serde_json::json;

    fn m(kind: &str, name: &str, hash: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "app",
                "annotations": { keys::IDENTITY_HASH: hash },
            },
        })
    }

    fn source(activation: &str) -> KeptOrphanSource {
        KeptOrphanSource {
            activation: activation.into(),
            identity_hash: format!("{activation}-hash"),
            built_via: None,
        }
    }

    fn active(name: &str, kept: Vec<KeptOrphanSource>) -> Record {
        Record {
            name: name.into(),
            identity_hash: Some(format!("{name}-hash")),
            orphans_kept_from: kept,
            ..Default::default()
        }
    }

    /// Build a test baseline running `closure` under `active`, with `failed`
    /// and `kept` folded in.
    fn baseline(
        active: Record,
        closure: Vec<Value>,
        failed: FailedBaseline,
        kept: KeptBaseline,
    ) -> Baseline {
        Baseline {
            active: Some(active),
            source: ActiveSource::Live,
            active_manifests: closure,
            failed,
            kept,
            tenancy: Tenancy::empty(""),
        }
    }

    /// A Kix cluster read from revisions takes in what a `Partial` record's
    /// deploy applied: an object only its revision names, whose applied hash
    /// that revision holds, becomes an orphan of the finishing deploy. An
    /// object of its build it never applied does not, and neither does one
    /// the cluster no longer holds.
    #[tokio::test]
    async fn a_finishing_deploy_takes_in_what_a_partial_record_applied() {
        use crate::cluster::tenancy_fixture::{Rec, Written, state};
        let recs = [
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "cur",
                phase: PHASE_ACTIVE,
                current: true,
                objects: &["web"],
                ..Rec::default()
            },
            Rec {
                name: "a-only",
                cluster: "a",
                hash: "part",
                phase: PHASE_PARTIAL,
                objects: &["web", "added", "never", "deleted"],
                unapplied: &["never"],
                ..Rec::default()
            },
        ];
        let mut state = state(&recs, |_| Written::Revisions);
        state
            .objects
            .retain(|o| o["metadata"]["name"] != "deleted" && o["metadata"]["name"] != "never");
        let api = FakeApi::new(state.all());
        let d = |name: &str| {
            let mut obj = m("ConfigMap", name, &format!("h-{name}"));
            obj["metadata"]["namespace"] = json!("d");
            obj
        };
        let failed = FailedBaseline {
            closures: vec![["web", "added", "never", "deleted"].map(d).to_vec()],
            consumed: vec!["a-only".into()],
            sources: vec![KeptOrphanSource {
                activation: "a-only".into(),
                identity_hash: "part".into(),
                built_via: None,
            }],
            ..FailedBaseline::default()
        };
        let current: Record =
            Record::of(&serde_json::from_value(state.records[0].clone()).unwrap());
        let mut b = baseline(current, vec![d("web")], failed, KeptBaseline::default());
        b.tenancy = state.tenancy("a");
        let new = vec![d("web")];
        b.read_folded_leftovers(&api.client(), &new).await.unwrap();
        let orphans: Vec<String> = b
            .changes(&new, |_| false)
            .into_iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.name),
                _ => None,
            })
            .collect();
        assert_eq!(orphans, ["added"]);

        // Without the revision that says what it applied, the plan refuses.
        let missing = state.revision_named("a-only", "instance");
        state.remove_revision(&missing);
        let failed = FailedBaseline {
            closures: vec![["web", "added"].map(d).to_vec()],
            consumed: vec!["a-only".into()],
            sources: b.failed.sources.clone(),
            ..FailedBaseline::default()
        };
        let current: Record =
            Record::of(&serde_json::from_value(state.records[0].clone()).unwrap());
        let mut b = baseline(current, vec![d("web")], failed, KeptBaseline::default());
        b.tenancy = state.tenancy("a");
        let err = b
            .read_folded_leftovers(&api.client(), &new)
            .await
            .unwrap_err();
        assert!(matches!(err, PlanError::Tenancy(_)), "{err}");
        assert!(err.to_string().contains(&missing), "{err}");
    }

    /// A Kix cluster read from revisions reads its kept orphans from the
    /// kept-orphans revision, and the plan sees the ones still on the
    /// cluster. A Kix cluster read from records reads the builds of
    /// `status.orphansKeptFrom`.
    #[tokio::test]
    async fn kept_orphans_come_from_the_kept_orphans_revision() {
        use crate::cluster::tenancy_fixture::{Rec, Written, state};
        let recs = [Rec {
            name: "a-cur",
            cluster: "a",
            hash: "cur",
            phase: PHASE_ACTIVE,
            current: true,
            objects: &["web"],
            kept: &["left", "deleted"],
            ..Rec::default()
        }];
        for written in [Written::Revisions, Written::Records] {
            let mut state = state(&recs, |_| written);
            state.objects.retain(|o| o["metadata"]["name"] != "deleted");
            let api = FakeApi::new(state.all());
            let client = api.client();
            let discovery = discovery::discover_resources(&client).await.unwrap();
            let records = Records::open(&client, &discovery)
                .unwrap()
                .into_records()
                .unwrap();
            let current = records.get("a-cur").await.unwrap().unwrap();
            let baseline = Baseline::of_record(&records, "a", &current, &|_| {})
                .await
                .unwrap();
            match written {
                Written::Revisions => {
                    assert_eq!(baseline.kept.closures.len(), 1);
                    assert_eq!(names_of(&baseline.kept.closures[0]), ["left"]);
                    assert_eq!(baseline.kept.listed.as_ref().map(Vec::len), Some(2));
                    assert!(baseline.kept.sources.is_empty());
                }
                Written::Records => {
                    assert!(baseline.kept.listed.is_none());
                    assert_eq!(baseline.kept.unresolved.len(), 1);
                }
            }
        }
    }

    /// A folded deploy leaves behind only what it created: an object the
    /// cluster holds with that record's identity hash in
    /// `kix.run/activations`. An object it never created, or one on the
    /// cluster that only another record stamped, is neither an orphan nor a
    /// reason to record the build as one that kept orphans.
    #[tokio::test]
    async fn a_folded_deploy_leaves_behind_only_what_it_created() {
        let live = |name: &str, activations: &str| {
            let mut obj = m("ConfigMap", name, &format!("h-{name}"));
            obj["metadata"]["annotations"][keys::ACTIVATIONS] = json!(activations);
            obj
        };
        let api = FakeApi::new([
            live("made", "f1-hash"),
            live("foreign", "other-hash"),
            live("from-f2", "f2-hash,f1-hash"),
        ]);
        let failed = FailedBaseline {
            closures: vec![
                vec![
                    m("ConfigMap", "web", "h1"),
                    m("ConfigMap", "made", "h-made"),
                    m("ConfigMap", "never", "h-never"),
                    m("ConfigMap", "foreign", "h-foreign"),
                ],
                vec![m("ConfigMap", "never-2", "h-n2")],
            ],
            consumed: vec!["f1".into(), "f2".into()],
            sources: vec![source("f1"), source("f2")],
            ..FailedBaseline::default()
        };
        let mut b = baseline(
            active("cur", vec![]),
            vec![m("ConfigMap", "web", "h0")],
            failed,
            KeptBaseline::default(),
        );
        let new = vec![m("ConfigMap", "web", "h1")];
        b.read_folded_leftovers(&api.client(), &new).await.unwrap();

        let orphans: Vec<String> = b
            .changes(&new, |_| false)
            .into_iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.name),
                _ => None,
            })
            .collect();
        assert_eq!(orphans, ["made"]);
        let kept = b.orphans_kept_from(&new);
        assert_eq!(names(&kept.found), ["f1"]);
        // The object the new build holds stays in the folded build, so a
        // write over what the stopped deploy changed still happens.
        assert!(
            b.failed.closures[0]
                .iter()
                .any(|m| m["metadata"]["name"] == "web")
        );
    }

    /// A read the cluster refuses stops the plan instead of reading as
    /// "nothing left behind".
    #[tokio::test]
    async fn a_failed_read_of_leftovers_stops_the_plan() {
        let api = FakeApi::new([]);
        api.fail_next("/api/v1/namespaces/app/configmaps/made", u32::MAX, 500);
        let failed = FailedBaseline {
            closures: vec![vec![m("ConfigMap", "made", "h-made")]],
            consumed: vec!["f1".into()],
            sources: vec![source("f1")],
            ..FailedBaseline::default()
        };
        let mut b = baseline(
            active("cur", vec![]),
            vec![],
            failed,
            KeptBaseline::default(),
        );
        let err = b
            .read_folded_leftovers(&api.client(), &[])
            .await
            .unwrap_err();
        assert!(matches!(err, PlanError::FoldedLeftovers(_)), "{err}");
    }

    fn names(sources: &[KeptOrphanSource]) -> Vec<&str> {
        sources.iter().map(|s| s.activation.as_str()).collect()
    }

    /// A warn-only deploy of v2 over v1 records v1, whose ConfigMap v2 dropped.
    #[test]
    fn the_replaced_build_is_recorded_when_it_leaves_orphans() {
        let v1 = vec![m("Deployment", "web", "h1"), m("ConfigMap", "old", "h2")];
        let v2 = vec![m("Deployment", "web", "h3")];
        let got = baseline(
            active("v1", vec![]),
            v1,
            FailedBaseline::default(),
            KeptBaseline::default(),
        )
        .orphans_kept_from(&v2);
        assert_eq!(names(&got.found), vec!["v1"]);
    }

    /// v3 over v2 (which kept v1's orphans) carries v1 forward while v1 still
    /// has something v3 lacks, and records v2 only if v2 does too.
    #[test]
    fn kept_sources_carry_forward_until_the_new_build_declares_their_objects() {
        let v1 = vec![m("Deployment", "web", "h1"), m("ConfigMap", "old", "h2")];
        let v2 = vec![m("Deployment", "web", "h3")];
        let kept = KeptBaseline {
            closures: vec![v1.clone()],
            sources: vec![source("v1")],
            unresolved: vec![source("elsewhere")],
            listed: None,
        };
        let v3 = vec![m("Deployment", "web", "h4")];
        let got = baseline(
            active("v2", vec![source("v1")]),
            v2.clone(),
            FailedBaseline::default(),
            kept,
        )
        .orphans_kept_from(&v3);
        // v2 has nothing v3 lacks. The unresolved source is carried unread.
        assert_eq!(names(&got.found), vec!["v1"]);
        assert_eq!(names(&got.unexamined), vec!["elsewhere"]);

        // A build that declares the ConfigMap again ends v1's entry.
        let v4 = vec![m("Deployment", "web", "h4"), m("ConfigMap", "old", "h5")];
        let kept = KeptBaseline {
            closures: vec![v1],
            sources: vec![source("v1")],
            unresolved: vec![],
            listed: None,
        };
        let got = baseline(
            active("v2", vec![source("v1")]),
            v2,
            FailedBaseline::default(),
            kept,
        )
        .orphans_kept_from(&v4);
        assert!(got.found.is_empty(), "{got:?}");
    }

    /// A failed deploy's leftovers that this plan keeps are recorded too:
    /// the failed record is superseded on finalize and would otherwise be
    /// the only thing that knew about them.
    #[test]
    fn a_folded_failed_build_with_orphans_is_recorded() {
        let v1 = vec![m("Deployment", "web", "h1")];
        let failed = FailedBaseline {
            closures: vec![vec![
                m("Deployment", "web", "h1"),
                m("Secret", "half", "h9"),
            ]],
            consumed: vec!["f1".into()],
            sources: vec![source("f1")],
            unresolved: vec![],
            indexes: vec![],
            partly_deployed: vec![],
        };
        let got = baseline(
            active("v1", vec![]),
            v1.clone(),
            failed,
            KeptBaseline::default(),
        )
        .orphans_kept_from(&v1);
        assert_eq!(names(&got.found), vec!["f1"]);
    }

    /// Create a result directory whose `activation` symlink points to `hash`.
    fn result_dir_of(root: &std::path::Path, hash: &str) -> PathBuf {
        let dir = root.join(hash);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("kix-packages.json"), "{}").unwrap();
        let target = format!("/nix/store/{hash}-activation");
        std::os::unix::fs::symlink(target, dir.join("activation")).unwrap();
        dir
    }

    fn active_of(hash: &str, built_via: Option<&std::path::Path>) -> Record {
        Record {
            name: format!("rec-{hash}"),
            identity_hash: Some(hash.to_string()),
            built_via: built_via.map(|p| p.to_string_lossy().into_owned()),
            ..Default::default()
        }
    }

    const PROD: &str = "pppppppppppppppppppppppppppppppp";
    const STAGING: &str = "ssssssssssssssssssssssssssssssss";

    /// The cache holds prod's build of a cluster staging deploys under the
    /// same name. Against staging's Active record it is set aside with a
    /// warning, and the record's own build is used.
    #[test]
    fn a_cached_build_of_another_context_is_not_the_old_build() {
        let root = tempfile::tempdir().unwrap();
        let prod = result_dir_of(root.path(), PROD);
        let staging = result_dir_of(root.path(), STAGING);

        // The record's own build, as `checked_dir` finds it on a machine
        // that has it.
        let records_build = |_: &str, hash: &str, built_via: Option<&str>| {
            Ok(built_via
                .map(PathBuf::from)
                .filter(|dir| crate::eval::store::build_hash_of(dir).as_deref() == Some(hash)))
        };
        let (dir, warning) = active_build_dir_with(
            "web",
            Some(prod.clone()),
            Some(&active_of(STAGING, Some(&staging))),
            records_build,
        );
        assert_eq!(dir, Some(staging));
        assert!(warning.unwrap().contains("is not the Active build"));

        let (dir, warning) = active_build_dir("web", Some(prod.clone()), None);
        assert_eq!(dir, None);
        assert!(warning.unwrap().contains("no Active record"));

        let (dir, warning) =
            active_build_dir("web", Some(prod.clone()), Some(&active_of(PROD, None)));
        assert_eq!(dir, Some(prod));
        assert_eq!(warning, None);
    }

    /// A record whose `built_via` path holds another build has no build
    /// here: soft gc does not compare against it, and the kept-orphan roots
    /// do not pin it.
    #[test]
    fn a_build_path_holding_another_build_is_not_the_records() {
        let root = tempfile::tempdir().unwrap();
        let prod = result_dir_of(root.path(), PROD);
        // `e` and `u` are outside Nix's base32 alphabet, so this hash names
        // no store path on this machine.
        let hash = "eeeeuuuueeeeuuuueeeeuuuueeeeuuuu";

        let (dir, warning) = active_build_dir("gc-test", None, Some(&active_of(hash, Some(&prod))));
        assert_eq!(dir, None);
        let warning = warning.unwrap();
        assert!(warning.contains(&prod.display().to_string()), "{warning}");

        let pinned = checked_dir("gc-test", hash, Some(&prod.to_string_lossy()));
        assert!(!matches!(pinned, Ok(Some(_))), "{pinned:?}");
    }

    fn record(cluster: &str, hash: &str, phase: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): cluster,
                },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": phase },
        })
    }

    fn cm(name: &str, activations: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": name,
                "namespace": "app",
                "labels": { "app.kubernetes.io/managed-by": "kix" },
                "annotations": {
                    (keys::IDENTITY_HASH): format!("h-{name}"),
                    (keys::ACTIVATIONS): activations,
                },
                "managedFields": [{ "manager": "kix", "operation": "Apply" }],
            },
        })
    }

    /// The previous state of `a`, rebuilt from live objects, contains the
    /// closures of its Active record, its Failed and Partial records, and the
    /// build its Active record kept orphans from. Leftovers of a Superseded build and
    /// objects that only `b` deploys are excluded.
    #[tokio::test]
    async fn the_previous_state_is_the_active_failed_and_kept_closures() {
        let api = FakeApi::new([
            record("a", "a1", PHASE_SUPERSEDED),
            record("a", "a2", PHASE_ACTIVE),
            record("a", "af", PHASE_FAILED),
            record("a", "ap", PHASE_PARTIAL),
            record("b", "b1", PHASE_ACTIVE),
            cm("current", "a2"),
            cm("failed-left", "af"),
            cm("partial-left", "ap"),
            cm("kept-left", "ak"),
            cm("superseded-left", "a1"),
            cm("b-web", "b1"),
            cm("shared", "a2,b1"),
        ]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let opened = Records::open(&client, &discovery).unwrap();
        let active = Record {
            name: "rec-a2".into(),
            identity_hash: Some("a2".into()),
            orphans_kept_from: vec![KeptOrphanSource {
                activation: "rec-ak".into(),
                identity_hash: "ak".into(),
                built_via: None,
            }],
            ..Default::default()
        };
        let LiveRead {
            manifests: old,
            closures,
            ..
        } = of_live(
            &client,
            &StoreGraph::empty("c"),
            &opened,
            &discovery,
            "a",
            &active,
            &|_| {},
        )
        .await
        .unwrap();
        let mut names: Vec<&str> = old
            .iter()
            .filter_map(|m| m.pointer("/metadata/name")?.as_str())
            .collect();
        names.sort();
        assert_eq!(
            names,
            vec![
                "current",
                "failed-left",
                "kept-left",
                "partial-left",
                "shared"
            ]
        );

        // The same sweep, by the other builds it names: what the failed
        // and the kept build each left, and nothing the Active build has.
        assert_eq!(names_of(&closures.closure_of("af")), vec!["failed-left"]);
        assert_eq!(names_of(&closures.closure_of("ap")), vec!["partial-left"]);
        assert_eq!(names_of(&closures.closure_of("ak")), vec!["kept-left"]);
        assert!(closures.closure_of("a2").is_empty());
        assert!(closures.closure_of("b1").is_empty());
    }

    /// Mark `manifest` as an object of the stateful package `keeper`.
    fn of_keeper(mut manifest: Value) -> Value {
        let anns = manifest["metadata"]["annotations"].as_object_mut().unwrap();
        anns.insert(keys::PACKAGE.into(), json!("keeper"));
        anns.insert(keys::PACKAGE_NAMESPACE.into(), json!("app"));
        anns.insert(keys::LIFECYCLE.into(), json!("stateful"));
        manifest
    }

    /// An operator copies its custom resource's labels and annotations onto
    /// the data volume it makes, and leaves it unowned. Read from the cluster,
    /// the volume is not part of the previous state. So it is never an orphan
    /// to prune, and never one side of a migration.
    #[tokio::test]
    async fn an_operator_copy_is_not_part_of_the_previous_state() {
        let mut volume = of_keeper(cm("data-keeper-0", "a2"));
        volume["metadata"]["managedFields"] = json!([
            { "manager": "kube-controller-manager", "operation": "Update" },
            { "manager": "clickhouse-operator", "operation": "Update" },
        ]);
        volume["metadata"]["annotations"][keys::IDENTITY_HASH] = json!("h-keeper");
        let api = FakeApi::new([
            record("a", "a2", PHASE_ACTIVE),
            of_keeper(cm("keeper", "a2")),
            volume,
        ]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let opened = Records::open(&client, &discovery).unwrap();
        let active = Record {
            name: "rec-a2".into(),
            identity_hash: Some("a2".into()),
            ..Default::default()
        };
        let LiveRead { manifests: old, .. } = of_live(
            &client,
            &StoreGraph::empty("c"),
            &opened,
            &discovery,
            "a",
            &active,
            &|_| {},
        )
        .await
        .unwrap();
        assert_eq!(names_of(&old), vec!["keeper"]);

        // The next build adds a monitoring object to the same package.
        let new = vec![
            of_keeper(cm("keeper", "")),
            of_keeper(cm("keeper-monitor", "")),
        ];
        assert!(crate::cluster::migrate::detect_migration_pairs(&new, &old).is_empty());
        assert!(
            !apply::detect_changes(&new, &old)
                .iter()
                .any(|a| matches!(a, ChangeAction::Orphan(_)))
        );
    }

    fn names_of(manifests: &[Value]) -> Vec<&str> {
        let mut names: Vec<&str> = manifests
            .iter()
            .filter_map(|m| m.pointer("/metadata/name")?.as_str())
            .collect();
        names.sort();
        names
    }

    /// With the sweep standing in for the store, a kept build this machine
    /// has not got resolves to what it left on the cluster, and one nothing
    /// names any more resolves to nothing left. Neither is unresolved, so
    /// neither is carried forward or warned about.
    #[test]
    fn kept_builds_resolve_from_the_sweep_when_the_store_has_none() {
        let mut left = m("ConfigMap", "kept-left", "h-left");
        left["metadata"]["annotations"][keys::ACTIVATIONS] = json!("ak-hash");
        let objects: Vec<DynamicObject> = vec![serde_json::from_value(left.clone()).unwrap()];
        let live = LiveClosures::of(&objects, &[left], &Tenancy::empty("a"), Some("a2"));
        let active = Record {
            name: "rec-a2".into(),
            identity_hash: Some("a2".into()),
            orphans_kept_from: vec![source("ak"), source("gone")],
            ..Default::default()
        };
        let events = std::cell::RefCell::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.borrow_mut().push(format!("{event:?}"));
        let kept = load_kept(&active.orphans_kept_from, None, "a", &report, Some(&live));
        assert!(kept.unresolved.is_empty(), "{kept:?}");
        assert_eq!(names(&kept.sources), vec!["ak", "gone"]);
        assert_eq!(names_of(&kept.closures[0]), vec!["kept-left"]);
        assert!(kept.closures[1].is_empty());
        let events = events.into_inner();
        assert!(
            events.iter().any(|e| e.starts_with("KeptFolded"))
                && !events.iter().any(|e| e.starts_with("KeptUnresolved")),
            "{events:?}"
        );

        // Without the sweep the same sources are unresolved, reported once.
        let events = std::cell::RefCell::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.borrow_mut().push(format!("{event:?}"));
        let kept = load_kept(&active.orphans_kept_from, None, "a", &report, None);
        assert_eq!(names(&kept.unresolved), vec!["ak", "gone"]);
        let events = events.into_inner();
        assert_eq!(
            events
                .iter()
                .filter(|e| e.starts_with("KeptUnresolved"))
                .count(),
            1,
            "{events:?}"
        );
    }

    /// Build a rollback baseline whose current and failed builds both fail to
    /// load. Both records point to a result directory that is not a valid
    /// build, so neither falls back to this machine's activation cache.
    async fn rollback_baseline(extra: Value) -> (Baseline, Vec<String>) {
        rollback_baseline_with(vec![extra]).await
    }

    async fn rollback_baseline_with(extras: Vec<Value>) -> (Baseline, Vec<String>) {
        let cluster = "of-record-test";
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("kix-packages.json"), "not a build").unwrap();
        let built_via = dir.path().to_string_lossy().into_owned();
        let mut failed = record(cluster, "fl", PHASE_FAILED);
        failed["metadata"]["annotations"][keys::BUILT_VIA] = json!(built_via);
        let api = FakeApi::new(
            [record(cluster, "cur", PHASE_ACTIVE), failed]
                .into_iter()
                .chain(extras),
        );
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let current = Record {
            name: "rec-cur".into(),
            identity_hash: Some("cur".into()),
            built_via: Some(built_via),
            ..Default::default()
        };
        let events = std::cell::RefCell::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.borrow_mut().push(format!("{event:?}"));
        let baseline = Baseline::of_record(&records, cluster, &current, &report)
            .await
            .unwrap();
        (baseline, events.into_inner())
    }

    /// Nothing stands in for a current build that will not load: the
    /// rollback reports it, compares with an empty build, and its package
    /// diff starts from one, as the engine applies every object. The current
    /// record is listed as unexamined, so its objects stay reachable by a
    /// later prune. The Failed record
    /// whose build will not load is reported and not folded in.
    #[tokio::test]
    async fn a_rollback_whose_current_build_will_not_load_compares_with_nothing() {
        let (baseline, events) = rollback_baseline(json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "unrelated", "namespace": "app"},
        }))
        .await;
        assert!(matches!(baseline.source, ActiveSource::Unavailable));
        assert!(baseline.active_manifests.is_empty());
        assert_eq!(baseline.active().map(|a| a.name.as_str()), Some("rec-cur"));
        let unresolved: Vec<&str> = baseline
            .failed()
            .unresolved
            .iter()
            .map(|r| r.name.as_str())
            .collect();
        assert_eq!(unresolved, vec!["rec-fl"]);
        assert!(baseline.failed().is_empty());
        let kept = baseline.orphans_kept_from(&[]);
        let unexamined: Vec<&str> = kept
            .unexamined
            .iter()
            .map(|s| s.identity_hash.as_str())
            .collect();
        assert_eq!(unexamined, vec!["cur"], "{kept:?}");
        assert!(kept.found.is_empty(), "{kept:?}");
        assert!(
            events.iter().any(|e| e.starts_with("ActiveBuildUnusable"))
                && events.iter().any(|e| e.starts_with("FailedBuildUnusable"))
                && events.iter().any(|e| e.starts_with("FailedUnresolved")),
            "{events:?}"
        );
        let new = StoreGraph::synthesize(&[m("ConfigMap", "web", "h1")], &StoreGraph::empty("c"));
        assert!(baseline.diff_side(&new).resources.is_empty());
    }

    /// A build at the record's path that is another build does not hide
    /// the record's own build in the cache; with no cached build, the path's
    /// refusal stands.
    #[test]
    fn a_reused_build_path_falls_back_to_the_cache_by_hash() {
        let graph_of = |hash: &str| {
            let mut graph = StoreGraph::empty("c");
            graph.activation_path = PathBuf::from(format!("/nix/store/{hash}-activation"));
            graph
        };
        let load = |dir: &Path| {
            let hash = dir.file_name().unwrap().to_str().unwrap();
            Ok(graph_of(hash))
        };
        let reused = Some(PathBuf::from("/builds").join(PROD));
        let cached = PathBuf::from("/cache").join(STAGING);

        let found = checked_build(
            STAGING,
            reused.clone(),
            || Some(cached.clone()),
            load,
            |g| g,
        )
        .unwrap()
        .unwrap();
        assert_eq!(found.activation_path, graph_of(STAGING).activation_path);

        let err = checked_build(STAGING, reused, || None, load, |g| g).unwrap_err();
        assert!(
            err.contains(&format!("is activation {}", short(PROD))),
            "{err}"
        );
    }

    /// A rollback target whose build is not on this machine is refused with
    /// the record's name and hash.
    #[test]
    fn a_rollback_target_not_on_this_machine_is_refused() {
        // `e` and `u` are outside Nix's base32 alphabet, so this hash names
        // no store path on this machine.
        let hash = "eeeeuuuueeeeuuuueeeeuuuueeeeuuuu";
        let Err(err) = target_build("c", "rec-x", hash, None) else {
            panic!("the build was found");
        };
        assert!(
            err.contains(&format!(
                "rec-x's build is not on this machine (hash: {hash})"
            )),
            "{err}"
        );
    }

    /// A current build that is not on this machine is reported, and the
    /// current record is listed as unexamined.
    #[tokio::test]
    async fn a_rollback_whose_current_build_is_absent_keeps_naming_it() {
        // `e` and `u` are outside Nix's base32 alphabet, so this hash names
        // no store path on this machine.
        let hash = "eeeeuuuueeeeuuuueeeeuuuueeeeuuuu";
        let api = FakeApi::new([record("absent-test", hash, PHASE_ACTIVE)]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let current = Record {
            name: format!("rec-{hash}"),
            identity_hash: Some(hash.into()),
            ..Default::default()
        };
        let events = std::cell::RefCell::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.borrow_mut().push(format!("{event:?}"));
        let baseline = Baseline::of_record(&records, "absent-test", &current, &report)
            .await
            .unwrap();
        assert!(matches!(baseline.source, ActiveSource::Unavailable));
        let events = events.into_inner();
        assert!(
            events.iter().any(|e| e.starts_with("ActiveUnresolved")),
            "{events:?}"
        );
        let kept = baseline.orphans_kept_from(&[]);
        assert_eq!(kept.unexamined.len(), 1, "{kept:?}");
        assert_eq!(kept.unexamined[0].identity_hash, hash);
    }

    /// A current record without an identity hash names no build: nothing
    /// is looked up, and the report says why.
    #[tokio::test]
    async fn a_current_record_without_a_hash_is_not_looked_up() {
        let api = FakeApi::new([]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let current = Record {
            name: "rec-nohash".into(),
            ..Default::default()
        };
        let events = std::cell::RefCell::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.borrow_mut().push(format!("{event:?}"));
        let baseline = Baseline::of_record(&records, "c", &current, &report)
            .await
            .unwrap();
        assert!(matches!(baseline.source, ActiveSource::Unavailable));
        let events = events.into_inner();
        assert!(
            events.iter().any(|e| e.starts_with("ActiveWithoutHash")),
            "{events:?}"
        );
    }

    /// Another deploy still in flight: the rollback leaves the failed
    /// records alone and says why.
    #[tokio::test]
    async fn a_rollback_leaves_failed_records_while_a_deploy_is_in_flight() {
        let (baseline, events) =
            rollback_baseline(record("of-record-test", "dp", PHASE_DEPLOYING)).await;
        assert!(baseline.failed().unresolved.is_empty());
        assert!(baseline.failed().is_empty());
        assert!(
            events.iter().any(|e| e.starts_with("DeployInFlight")),
            "{events:?}"
        );
    }

    /// When the deploy lock names the run that is deploying, the plan still
    /// leaves the failed records alone, and prints no warning about a
    /// record left Deploying: the lock already says who is deploying.
    #[tokio::test]
    async fn a_locked_deploy_in_flight_needs_no_warning() {
        let head = json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::cluster::head::KIND,
            "metadata": { "name": "of-record-test" },
            "status": { "generation": 1, "lock": {
                "holder": "cli-1", "hint": "kix deploy by ana", "purpose": "deploy",
                "activation": "dp", "renewed": "2026-11-26T10:00:00.000Z", "durationSeconds": 30,
            } },
        });
        let (baseline, events) =
            rollback_baseline_with(vec![record("of-record-test", "dp", PHASE_DEPLOYING), head])
                .await;
        assert!(baseline.failed().is_empty());
        assert!(
            !events.iter().any(|e| e.starts_with("DeployInFlight")),
            "{events:?}"
        );
    }

    /// With no Active build, the package diff's old side is the merged
    /// closures when they were read from the cluster, and an empty build
    /// when nothing stands in for the Active build.
    #[test]
    fn the_diff_side_without_a_build_follows_where_the_closure_came_from() {
        let failed = || FailedBaseline {
            closures: vec![vec![m("ConfigMap", "half", "h9")]],
            consumed: vec!["f1".into()],
            sources: vec![source("f1")],
            unresolved: vec![],
            indexes: vec![],
            partly_deployed: vec![],
        };
        let new = StoreGraph::synthesize(&[m("ConfigMap", "web", "h1")], &StoreGraph::empty("c"));
        let live = baseline(
            active("v1", vec![]),
            Vec::new(),
            failed(),
            KeptBaseline::default(),
        );
        assert_eq!(live.diff_side(&new).resources.len(), 1);
        let unavailable = Baseline {
            source: ActiveSource::Unavailable,
            ..baseline(
                active("v1", vec![]),
                Vec::new(),
                failed(),
                KeptBaseline::default(),
            )
        };
        assert!(unavailable.diff_side(&new).resources.is_empty());
    }

    /// Read from the cluster, the old side places objects by the Active
    /// record's package index first and a folded-in Failed record's index
    /// next. An object neither lists is placed as before.
    #[test]
    fn the_diff_side_places_live_objects_by_the_records_indexes() {
        let index = |packages: serde_json::Value| -> RecordPackageIndex {
            serde_json::from_value(json!({
                "format": crate::eval::package_index::FORMAT,
                "packages": packages,
                "clusterLevel": [],
            }))
            .unwrap()
        };
        let mut deployed = active("v1", vec![]);
        deployed.package_index = Some(index(json!({
            "app/one": { "instance": "pi-one", "resources": ["ha", "hb"] },
        })));
        let failed = FailedBaseline {
            closures: vec![vec![m("ConfigMap", "b", "hb"), m("ConfigMap", "c", "hc")]],
            consumed: vec!["f1".into()],
            sources: vec![source("f1")],
            unresolved: vec![],
            indexes: vec![index(json!({
                "app/two": { "instance": "pi-two", "resources": ["hb", "hc"] },
            }))],
            partly_deployed: vec![],
        };
        let new = StoreGraph::synthesize(&[m("ConfigMap", "z", "hz")], &StoreGraph::empty("c"));
        let live = baseline(
            deployed,
            vec![m("ConfigMap", "a", "ha"), m("ConfigMap", "d", "hd")],
            failed,
            KeptBaseline::default(),
        );
        let side = live.diff_side(&new);
        let names_in = |key: &str| -> Vec<String> {
            let p = side
                .packages
                .values()
                .find(|p| format!("{}/{}", p.namespace, p.instance_name) == key)
                .unwrap_or_else(|| panic!("no package {key}"));
            let mut names: Vec<String> = p
                .resource_paths
                .iter()
                .map(|r| {
                    side.resources[r].manifest["metadata"]["name"]
                        .as_str()
                        .unwrap()
                        .into()
                })
                .collect();
            names.sort();
            names
        };
        assert_eq!(names_in("app/one"), vec!["a", "b"]);
        assert_eq!(names_in("app/two"), vec!["c"]);
        assert_eq!(side.packages.len(), 2, "d is cluster-level");
    }
}
