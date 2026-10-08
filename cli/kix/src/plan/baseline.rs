//! The closures a plan compares against.
//!
//! A deploy or a rollback decides what to do by comparing compiler outputs:
//! the closure it is about to apply, and the closure the cluster is already
//! running. That second one comes from the Active Activation record.
//!
//! It is not the whole story. A deploy that stops part way applies some of its
//! closure and never becomes Active, so its leftovers are described by neither
//! side and the next plan cannot see them (kixpkgs#82). Since the record is
//! now created before the first wave and marked `Failed` when the run stops,
//! those closures can be recovered by hash and folded in.
//!
//! A deploy that keeps its orphans (warn-only, the default) leaves the same
//! kind of hole: the next plan compares against the new record only, and the
//! build that still knew about those objects is gone from the comparison. The
//! record therefore names those builds under `status.orphansKeptFrom`, and
//! [`load_kept`] resolves them the same way.
//!
//! Everything here resolves a record to a closure in the local store. Nothing
//! reads the cluster's objects, except [`Baseline::of_cluster`] when the
//! Active record's build is not on this machine: the kix invariant is that
//! live state is consulted to execute and to observe, never to decide
//! (`v2_discussions/81_deploy_as_lifecycle_engine.md`, "Closure A to closure
//! B"). Listing the records is a read of our own bookkeeping, not of the
//! objects being reasoned about.

use std::borrow::Cow;
use std::collections::HashSet;
use std::path::PathBuf;

use kube::{client::Client, discovery::ApiResource};
use serde_json::Value;

use super::{PlanError, PlanEvent};
use crate::build_source::Build;
use crate::cluster::activation::{
    self, ActiveActivation, DeployingActivation, FailedActivation, KeptOrphanSource,
};
use crate::cluster::apply::{self, ChangeAction};
use crate::cluster::fetch;
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
    pub(crate) active: Option<ActiveActivation>,
    /// Where `active_manifests` came from.
    pub(crate) source: ActiveSource,
    /// The Active record's closure.
    pub(crate) active_manifests: Vec<Value>,
    pub(crate) failed: FailedBaseline,
    pub(crate) kept: KeptBaseline,
}

/// Where a [`Baseline`]'s Active closure came from.
#[derive(Debug, Default)]
pub(crate) enum ActiveSource {
    /// No Active record to compare with: a first deploy, or no cached
    /// build under `--current-activation`.
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
    /// No previous build: a first deploy.
    pub(crate) fn empty() -> Baseline {
        Baseline {
            active: None,
            source: ActiveSource::NoRecord,
            active_manifests: Vec::new(),
            failed: FailedBaseline::default(),
            kept: KeptBaseline::default(),
        }
    }

    /// The Active record the plan compares against. `None` on a first
    /// deploy.
    pub fn active(&self) -> Option<&ActiveActivation> {
        self.active.as_ref()
    }

    /// The closures of the deploys that stopped part way, and the records
    /// to supersede once the run finalizes.
    pub fn failed(&self) -> &FailedBaseline {
        &self.failed
    }

    /// The Active record's build, when this machine has it.
    pub fn active_graph(&self) -> Option<&StoreGraph> {
        match &self.source {
            ActiveSource::Build(graph) => Some(graph.as_ref()),
            _ => None,
        }
    }

    /// The Active record's identity hash.
    pub fn active_hash(&self) -> Option<&str> {
        self.active.as_ref()?.identity_hash.as_deref()
    }

    /// The Active closure with the failed and kept ones merged in. The plan
    /// display and the prune ordering both need a manifest for an object
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

    /// The manifests of every build the cluster ran: the Active closure and
    /// the failed and kept ones, unmerged. A write of one of their files is a
    /// re-apply (see [`super::objects`]).
    pub(crate) fn ran(&self) -> impl Iterator<Item = &Value> {
        self.active_manifests
            .iter()
            .chain(self.failed.closures.iter().flatten())
            .chain(self.kept.closures.iter().flatten())
    }

    /// The old side of the package diff for `new`: the Active build when
    /// this machine has it. Without it, the manifests the plan compares
    /// against, grouped by their package stamps, so untouched packages show
    /// as unchanged instead of everything added. With nothing standing in
    /// for the Active build, an empty build: the engine applies every object.
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
                    Cow::Owned(StoreGraph::synthesize(&manifests, new))
                }
            }
        }
    }

    /// The change for each object of `new_manifests` and each orphan:
    /// `new_manifests` against the Active closure, then what the failed
    /// deploys may have left and the orphans kept deploys left, then
    /// `reconcile`. The folds can turn a Skip into an Apply (repair) and can
    /// add orphans (prune); they never invent a change the closures do not
    /// justify.
    ///
    /// Only the Active closure is compared. Folding a failed closure into the
    /// old side would make an object that a failed deploy declared but never
    /// created read as already present; if the new build declares it at the
    /// same hash, the plan would skip it and the run would finalize claiming
    /// an object that is not there.
    pub(crate) fn changes(&self, new_manifests: &[Value], reconcile: bool) -> Vec<ChangeAction> {
        let actions = apply::fold_kept_closures(
            apply::fold_failed_closures(
                apply::detect_changes(new_manifests, &self.active_manifests),
                new_manifests,
                &self.failed.closures,
            ),
            new_manifests,
            &self.kept.closures,
        );
        if !reconcile {
            return actions;
        }
        // --reconcile applies every object again, changed or not.
        let by_id: std::collections::HashMap<ResourceId, &Value> = new_manifests
            .iter()
            .map(|m| (ResourceId::from_value(m), m))
            .collect();
        actions
            .into_iter()
            .map(|action| match &action {
                ChangeAction::Skip(rid) => by_id
                    .get(rid)
                    .map_or(action.clone(), |m| ChangeAction::Apply((*m).clone())),
                _ => action,
            })
            .collect()
    }

    /// What the record a plan of `new_manifests` finalizes lists under
    /// `status.orphansKeptFrom`: every build the plan compared against (the
    /// Active one, folded-in failed ones, kept ones) that still has something
    /// prune would delete, and every kept source this machine could not
    /// resolve. See [`activation::KeptOrphans`] for which of them finalize
    /// writes.
    pub(crate) fn orphans_kept_from(&self, new_manifests: &[Value]) -> activation::KeptOrphans {
        let active_source = self.active.as_ref().and_then(|a| {
            Some(KeptOrphanSource {
                activation: a.name.clone(),
                identity_hash: a.identity_hash.clone()?,
                built_via: a.built_via.clone(),
            })
        });
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
            unexamined: self.kept.unresolved.clone(),
            carry_current: false,
        }
    }

    /// The baseline under `--current-activation`, which does not connect:
    /// the build the local activation cache names for `cluster`, as the
    /// Active record. It has no `orphansKeptFrom` and no failed records, so
    /// orphans kept by earlier deploys are not in its plan; finalize carries
    /// the real record's list forward instead.
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
            Some(ActiveActivation {
                name: record.pointer("/metadata/name")?.as_str()?.to_string(),
                identity_hash: keys::get(record, keys::IDENTITY_HASH).map(str::to_string),
                built_via: Some(dir.to_string_lossy().into_owned()),
                orphans_kept_from: Vec::new(),
            })
        });
        Baseline {
            active,
            source: ActiveSource::Build(Box::new(graph)),
            active_manifests,
            ..Baseline::empty()
        }
    }

    /// The baseline of a plan of `build` against the cluster `client` reaches:
    /// the Active record's build (`build`'s copy, then `built_via`, then the
    /// local cache), or when this machine has none of them, the record's
    /// objects as the cluster holds them; the builds its `orphansKeptFrom`
    /// names; and every Failed record's build, unless another deploy of the
    /// cluster is in flight.
    pub(crate) async fn of_cluster(
        client: &Client,
        build: &Build,
        report: &dyn Fn(PlanEvent<'_>),
    ) -> Result<Baseline, PlanError> {
        let cluster = build.graph().cluster_name.as_str();
        let discovery = fetch::discover_resources(client)
            .await
            .map_err(|e| PlanError::Discovery(Box::new(e)))?;
        let ar = activation::find_activation_ar(&discovery)
            .map_err(PlanError::Domain)?
            .map(|(ar, _)| ar.clone());
        let active = match &ar {
            Some(ar) => activation::find_active(client, ar, cluster)
                .await
                .ok()
                .flatten(),
            None => None,
        };

        let mut baseline = match active {
            Some(active) if active.identity_hash.is_some() => {
                let hash = active.identity_hash.as_deref().unwrap_or_default();
                report(PlanEvent::Active {
                    name: &active.name,
                    identity_hash: hash,
                });
                match record_graph(Some(build), cluster, hash, active.built_via.as_deref()) {
                    Ok(Some(graph)) => Baseline {
                        active_manifests: manifests_of(&graph),
                        source: ActiveSource::Build(Box::new(graph)),
                        active: Some(active),
                        ..Baseline::empty()
                    },
                    // A build that will not load, or is not the record's, is
                    // not a first deploy. Fall back to the cluster rather
                    // than planning against nothing.
                    found => {
                        report(PlanEvent::ReadingLive {
                            error: found.err().as_deref(),
                        });
                        let active_manifests =
                            of_live(client, &discovery, cluster, &active, report).await?;
                        Baseline {
                            active_manifests,
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

        // Builds whose orphans an earlier warn-only deploy kept. The Active
        // closure no longer declares those objects, so without these the
        // plan cannot see them.
        if let Some(active) = &baseline.active {
            baseline.kept = load_kept(active, Some(build), cluster, report);
        }

        // Closures from deploys that stopped part way. They applied objects
        // and never became Active, so neither side of the comparison knows
        // about them (kixpkgs#82). Resolved from the local store by hash, so
        // every input to the plan is still a compiler output.
        if let Some(ar) = &ar {
            baseline.failed =
                load_failed_unless_in_flight(client, ar, Some(build), cluster, report).await;
        }
        Ok(baseline)
    }

    /// The baseline of a rollback of `cluster`, which runs `current`: the
    /// current record's build from this machine (`built_via`, else the local
    /// cache), or nothing when it will not load; the builds its
    /// `orphansKeptFrom` names; and every Failed record's build, unless
    /// another deploy is in flight. A rollback is the most likely thing to
    /// run straight after a deploy that stopped part way, and its baseline
    /// has exactly the same hole as a deploy's.
    pub async fn of_record(
        client: &Client,
        ar: &ApiResource,
        cluster: &str,
        current: &ActiveActivation,
        report: &dyn Fn(PlanEvent<'_>),
    ) -> Baseline {
        let hash = current.identity_hash.as_deref().unwrap_or("");
        let graph = result_dir(cluster, hash, current.built_via.as_deref())
            .and_then(|dir| Build::local(&dir, &|_| {}).ok())
            .map(Build::into_graph);
        let (source, active_manifests) = match graph {
            Some(graph) => {
                let manifests = manifests_of(&graph);
                (ActiveSource::Build(Box::new(graph)), manifests)
            }
            None => (ActiveSource::Unavailable, Vec::new()),
        };
        let failed = load_failed_unless_in_flight(client, ar, None, cluster, report).await;
        let kept = load_kept(current, None, cluster, report);
        Baseline {
            active: Some(current.clone()),
            source,
            active_manifests,
            failed,
            kept,
        }
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
    pub unresolved: Vec<FailedActivation>,
}

impl FailedBaseline {
    pub fn is_empty(&self) -> bool {
        self.closures.is_empty()
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
}

/// [`load_failed`], unless another deploy of `cluster` looks like it is
/// still running ([`deploy_in_flight`]): that deploy would be applying the
/// very objects this plan might prune, so its work is left alone rather than
/// guessing which of the two is real.
async fn load_failed_unless_in_flight(
    client: &Client,
    ar: &ApiResource,
    build: Option<&Build>,
    cluster: &str,
    report: &dyn Fn(PlanEvent<'_>),
) -> FailedBaseline {
    if let Some(record) = deploy_in_flight(client, ar, cluster).await {
        report(PlanEvent::DeployInFlight(&record));
        return FailedBaseline::default();
    }
    load_failed(client, ar, build, cluster, report).await
}

/// Resolve every `Failed` record for a cluster to its closure.
///
/// A record that cannot be resolved is reported without being consumed. It
/// usually means the failed deploy ran on a different
/// machine, so this one cannot know what it applied; saying so and leaving the
/// record in place is more honest than superseding it and forgetting.
async fn load_failed(
    client: &Client,
    ar: &ApiResource,
    build: Option<&Build>,
    cluster: &str,
    report: &dyn Fn(PlanEvent<'_>),
) -> FailedBaseline {
    let records = match activation::find_failed(client, ar, cluster).await {
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
        let closure = match resolve_closure(build, cluster, &hash, record.built_via.as_deref()) {
            Ok(Some(closure)) => closure,
            Ok(None) => {
                out.unresolved.push(record);
                continue;
            }
            Err(e) => {
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
        out.consumed.push(record.name.clone());
        out.sources.push(KeptOrphanSource {
            activation: record.name.clone(),
            identity_hash: hash,
            built_via: record.built_via.clone(),
        });
    }

    for record in &out.unresolved {
        report(PlanEvent::FailedUnresolved { record, cluster });
    }
    out
}

/// Resolve the Active record's `status.orphansKeptFrom` to closures, and say
/// how many there are so the plan's extra orphans have an explanation.
pub fn load_kept(
    active: &ActiveActivation,
    build: Option<&Build>,
    cluster: &str,
    report: &dyn Fn(PlanEvent<'_>),
) -> KeptBaseline {
    let mut out = KeptBaseline::default();
    for source in &active.orphans_kept_from {
        match resolve_closure(
            build,
            cluster,
            &source.identity_hash,
            source.built_via.as_deref(),
        ) {
            Ok(Some(closure)) => {
                out.closures.push(closure);
                out.sources.push(source.clone());
            }
            Ok(None) => out.unresolved.push(source.clone()),
            Err(e) => {
                report(PlanEvent::KeptBuildUnusable {
                    activation: &source.activation,
                    error: &e,
                });
                out.unresolved.push(source.clone());
            }
        }
    }
    if !out.sources.is_empty() {
        report(PlanEvent::KeptFolded(&out.sources));
    }
    for source in &out.unresolved {
        report(PlanEvent::KeptUnresolved { source, cluster });
    }
    out
}

/// A build's result dir: `built_via` when that store path is on this
/// machine, else the local activation cache by identity hash.
fn result_dir(cluster: &str, identity_hash: &str, built_via: Option<&str>) -> Option<PathBuf> {
    built_via
        .map(PathBuf::from)
        .filter(|p| p.join("kix-packages.json").exists())
        .or_else(|| crate::eval::store::resolve_activation_by_hash(cluster, identity_hash))
}

/// The result dir of the build the Active record `active` names, for a plan
/// that uses it as the old state, with a warning to print when the local
/// activation cache was set aside.
///
/// The cache (`store::load_activation_path`) is keyed by cluster name alone,
/// so it can hold the build another kube context deployed under the same
/// name. It is used only when its identity hash is the Active record's.
/// Otherwise the build comes from the record (`built_via`, else the store by
/// hash). With no Active record there is no old build.
pub fn active_build_dir(
    cluster: &str,
    cached: Option<PathBuf>,
    active: Option<&ActiveActivation>,
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
    (result_dir(cluster, hash, built_via), warning)
}

fn short(hash: &str) -> &str {
    &hash[..8.min(hash.len())]
}

/// The build an Activation record names, stamped: from the new `build`
/// ([`Build::deployed_build`]) by its identity hash, else from `built_via`
/// or the local activation cache. `Ok(None)` when this machine has none of
/// them.
///
/// A build from `built_via` must be the build the record names: it is
/// written by whoever deployed, so a record could point at any store path
/// on this machine.
pub fn record_graph(
    build: Option<&Build>,
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<Option<StoreGraph>, String> {
    if let Some(graph) = build.map_or(Ok(None), |b| b.deployed_build(identity_hash))? {
        return Ok(Some(graph));
    }
    let Some(dir) = result_dir(cluster, identity_hash, built_via) else {
        return Ok(None);
    };
    // A record's build can predate the domain move, so it is not refused
    // for one ([`Build::installable`]).
    let graph = Build::local(&dir, &|_| {})
        .map_err(|e| format!("the build at {} would not load: {e}", dir.display()))?
        .into_graph();
    let found = crate::eval::store_graph::store_hash(&graph.activation_path);
    if found != identity_hash {
        return Err(format!(
            "the build at {} is activation {}, not {}",
            dir.display(),
            short(&found),
            short(identity_hash),
        ));
    }
    Ok(Some(graph))
}

/// The stamped manifests of a build, from `build`, from `built_via` when
/// that store path is on this machine, else through the local activation
/// cache by identity hash. `Ok(None)` when none is available, and an error
/// when one is but will not load.
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

/// Keep a Nix GC root for every build `recorded` lists that this machine
/// can resolve, and drop the roots of builds it no longer lists. A listed
/// build that loses its store path cannot be read by the next plan, so its
/// orphans would be carried unexamined until `kix gc --hard`.
pub fn sync_kept_roots(cluster: &str, recorded: &[KeptOrphanSource]) {
    let listed: Vec<(String, Option<PathBuf>)> = recorded
        .iter()
        .map(|source| {
            let dir = result_dir(cluster, &source.identity_hash, source.built_via.as_deref());
            (source.identity_hash.clone(), dir)
        })
        .collect();
    crate::eval::store::sync_kept_roots(cluster, &listed);
}

/// Whether another deploy of this cluster looks like it is still running, in
/// which case the failed closures must not be folded in.
///
/// A `Deploying` record is either a live deploy or one whose process died
/// before it could mark itself `Failed`, and nothing here can tell those
/// apart. The difference matters in one direction only: folding in a closure
/// that another machine is still applying could prune objects out from under
/// it. So this does not refuse, it drops the fold, which leaves the plan
/// exactly as it was before any of this existed. A wrong guess costs the user
/// one deploy that does not reconcile the leftovers, not a command they
/// cannot run.
///
/// Refusing outright was the first shape of this and it was worse: a deploy
/// killed with SIGKILL leaves a `Deploying` record forever, and every deploy
/// and rollback of that cluster would have been blocked behind a manual
/// `kubectl patch`.
///
/// Operator-driven records are ignored. Those belong to the controller, which
/// resumes them itself.
async fn deploy_in_flight(
    client: &Client,
    ar: &ApiResource,
    cluster: &str,
) -> Option<DeployingActivation> {
    match activation::find_deploying(client, ar, cluster).await {
        Ok(found) => found.into_iter().find(|record| !record.operator_driven),
        Err(e) => {
            tracing::debug!("could not list deploying activations: {e}");
            None
        }
    }
}

/// Reconstruct the previous deploy's manifest set from live cluster state.
///
/// Fallback for when the old activation's store path is gone (garbage-
/// collected, or the deploy came from another machine). Every kix-managed
/// resource carries the identity-hash and depends-on annotations that
/// change detection and prune ordering read, so live objects projected
/// back to manifests substitute for the old store graph. Activation CRs
/// are excluded: their lifecycle is supersede-managed, never prune (same
/// policy as the operator's reconcile).
///
/// Only objects naming the Active record, a Failed record of this cluster,
/// or a build the Active record lists under `status.orphansKeptFrom`: the
/// closures the store-graph path would read. Objects of other Kix clusters
/// on the same Kubernetes cluster name none of these, so they never become
/// orphans. This cluster's objects that name only older builds are left out
/// too, and [`PlanEvent::OlderBuildsLeftOut`] says how many.
///
/// A failed sweep is an error, not an empty previous state. Planning
/// against an empty old set would show every resource as "added" and,
/// with `--prune`, would compute no orphans at all: a plan that looks
/// plausible and is wrong.
async fn of_live(
    client: &Client,
    discovery: &[(ApiResource, kube::discovery::Scope)],
    cluster: &str,
    active: &ActiveActivation,
    report: &dyn Fn(PlanEvent<'_>),
) -> Result<Vec<Value>, PlanError> {
    let mut hashes: HashSet<String> = active.identity_hash.iter().cloned().collect();
    hashes.extend(
        active
            .orphans_kept_from
            .iter()
            .map(|s| s.identity_hash.clone()),
    );
    if let Some((ar, _)) = activation::find_activation_ar(discovery).map_err(PlanError::Domain)? {
        let failed = activation::find_failed(client, ar, cluster)
            .await
            .map_err(|e| PlanError::Reconstruct(e.to_string()))?;
        hashes.extend(failed.into_iter().filter_map(|f| f.identity_hash));
    }
    let scope = fetch::SweepScope::Records {
        cluster,
        hashes: &hashes,
    };
    let sweep = fetch::sweep_managed(client, discovery, scope)
        .await
        .map_err(|e| PlanError::Reconstruct(e.to_string()))?;
    if sweep.other_builds > 0 {
        report(PlanEvent::OlderBuildsLeftOut(sweep.other_builds));
    }
    Ok(fetch::kix_owned_manifests(
        sweep
            .managed
            .into_iter()
            .filter(|obj| lifecycle::lifecycle_of_live(obj).prunable()),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::activation::{
        PHASE_ACTIVE, PHASE_DEPLOYING, PHASE_FAILED, PHASE_SUPERSEDED,
    };
    use crate::cluster::fake_api::FakeApi;
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

    fn active(name: &str, kept: Vec<KeptOrphanSource>) -> ActiveActivation {
        ActiveActivation {
            name: name.into(),
            identity_hash: Some(format!("{name}-hash")),
            built_via: None,
            orphans_kept_from: kept,
        }
    }

    /// The baseline of a cluster that runs `closure` under the record
    /// `active`, with `failed` and `kept` folded in.
    fn baseline(
        active: ActiveActivation,
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
        }
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

    /// A result dir whose `activation` link names build `hash`.
    fn result_dir_of(root: &std::path::Path, hash: &str) -> PathBuf {
        let dir = root.join(hash);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("kix-packages.json"), "{}").unwrap();
        let target = format!("/nix/store/{hash}-activation");
        std::os::unix::fs::symlink(target, dir.join("activation")).unwrap();
        dir
    }

    fn active_of(hash: &str, built_via: Option<&std::path::Path>) -> ActiveActivation {
        ActiveActivation {
            name: format!("rec-{hash}"),
            identity_hash: Some(hash.to_string()),
            built_via: built_via.map(|p| p.to_string_lossy().into_owned()),
            orphans_kept_from: Vec::new(),
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

        let (dir, warning) = active_build_dir(
            "web",
            Some(prod.clone()),
            Some(&active_of(STAGING, Some(&staging))),
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
            },
        })
    }

    /// The previous state of `a`, rebuilt from live objects, is the closures
    /// of its Active record, its Failed record and the build its Active
    /// record kept orphans from. Leftovers of a Superseded build, and every
    /// object only `b` deploys, are not in it.
    #[tokio::test]
    async fn the_previous_state_is_the_active_failed_and_kept_closures() {
        let api = FakeApi::new([
            record("a", "a1", PHASE_SUPERSEDED),
            record("a", "a2", PHASE_ACTIVE),
            record("a", "af", PHASE_FAILED),
            record("b", "b1", PHASE_ACTIVE),
            cm("current", "a2"),
            cm("failed-left", "af"),
            cm("kept-left", "ak"),
            cm("superseded-left", "a1"),
            cm("b-web", "b1"),
            cm("shared", "a2,b1"),
        ]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let active = ActiveActivation {
            name: "rec-a2".into(),
            identity_hash: Some("a2".into()),
            built_via: None,
            orphans_kept_from: vec![KeptOrphanSource {
                activation: "rec-ak".into(),
                identity_hash: "ak".into(),
                built_via: None,
            }],
        };
        let old = of_live(&client, &discovery, "a", &active, &|_| {})
            .await
            .unwrap();
        let mut names: Vec<&str> = old
            .iter()
            .filter_map(|m| m.pointer("/metadata/name")?.as_str())
            .collect();
        names.sort();
        assert_eq!(names, vec!["current", "failed-left", "kept-left", "shared"]);
    }

    /// A rollback whose current build will not load, with a Failed record
    /// whose build will not load either. Both records name a result
    /// directory that is not a build, so neither is looked up in this
    /// machine's activation cache.
    async fn rollback_baseline(extra: Value) -> (Baseline, Vec<String>) {
        let cluster = "of-record-test";
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("kix-packages.json"), "not a build").unwrap();
        let built_via = dir.path().to_string_lossy().into_owned();
        let mut failed = record(cluster, "fl", PHASE_FAILED);
        failed["metadata"]["annotations"][keys::BUILT_VIA] = json!(built_via);
        let api = FakeApi::new([record(cluster, "cur", PHASE_ACTIVE), failed, extra]);
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let (ar, _) = activation::find_activation_ar(&discovery).unwrap().unwrap();
        let current = ActiveActivation {
            name: "rec-cur".into(),
            identity_hash: Some("cur".into()),
            built_via: Some(built_via),
            orphans_kept_from: Vec::new(),
        };
        let events = std::cell::RefCell::new(Vec::new());
        let report = |event: PlanEvent<'_>| events.borrow_mut().push(format!("{event:?}"));
        let baseline = Baseline::of_record(&client, ar, cluster, &current, &report).await;
        (baseline, events.into_inner())
    }

    /// Nothing stands in for a current build that will not load: the
    /// rollback compares with an empty build, and its package diff starts
    /// from one, as the engine applies every object. The Failed record
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
        assert!(
            events.iter().any(|e| e.starts_with("FailedBuildUnusable"))
                && events.iter().any(|e| e.starts_with("FailedUnresolved")),
            "{events:?}"
        );
        let new = StoreGraph::synthesize(&[m("ConfigMap", "web", "h1")], &StoreGraph::empty("c"));
        assert!(baseline.diff_side(&new).resources.is_empty());
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
}
