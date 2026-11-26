//! Sweep Kix-labeled objects on a cluster using parallel LIST requests, then
//! attribute each object to the Kix clusters whose records it names.

use std::collections::{BTreeSet, HashMap, HashSet};

use super::activation::OpenedRecords;
use super::discovery::api_for;
use super::errors::{FailureClass, FetchError, classify};
use super::tenancy::{self, Tenancy};
use crate::manifest::keys;
use crate::manifest::lifecycle::{Lifecycle, lifecycle_of_live, never_pruned};
use crate::manifest::types::{ResourceId, to_manifest_value};
use kube::{
    api::{Api, DynamicObject, ListParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use tokio::task::JoinSet;

/// The managed-by label value that Kix sets on all resources.
pub(crate) const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by=kix";

/// Return the fully qualified resource name for logging (e.g. "pods" or "deployments.apps").
pub(crate) fn resource_fqn(ar: &ApiResource) -> String {
    if ar.group.is_empty() {
        ar.plural.clone()
    } else {
        format!("{}.{}", ar.plural, ar.group)
    }
}

/// Results of a cluster sweep of Kix-labeled objects.
pub struct ManagedSweep {
    /// Objects Kix applied, each carrying `kix.run/identity-hash`.
    pub managed: Vec<DynamicObject>,
    /// Objects Kix wrote that carry the Kix label without an identity hash or
    /// owner, so no build of Kix's lists them. `kix gc --full-scan` reports
    /// them, and nothing deletes them unless requested.
    pub unstamped: Vec<DynamicObject>,
    /// Objects that Kix never wrote: no `managedFields` entry names the `kix`
    /// field manager. Another program copied Kix's labels, and sometimes its
    /// annotations, onto them. They are excluded from every [`SweepScope`].
    /// `kix gc --full-scan` reports them, and nothing deletes them unless
    /// requested.
    pub copies: Vec<DynamicObject>,
    /// Resource types this account cannot list (403). Callers report these so a
    /// partial view of the cluster is not mistaken for a complete one.
    pub forbidden: Vec<String>,
    /// Under [`SweepScope::Cluster`], objects omitted because they belong only
    /// to other Kix clusters.
    pub foreign: Foreign,
    /// Under [`SweepScope::Cluster`], objects that name no record of any Kix
    /// cluster, so Kix cannot tell which cluster they belong to. Omitted from
    /// `managed` and `unstamped`.
    pub unattributed: Vec<DynamicObject>,
    /// Under [`SweepScope::Records`], objects of the named cluster that name
    /// none of the given records (such as leftovers from superseded builds).
    pub other_builds: usize,
    /// Activation records read after the object lists. Its `cluster` matches
    /// the scope, or is empty under [`SweepScope::All`].
    pub tenancy: Tenancy,
}

/// Objects a [`SweepScope::Cluster`] sweep omitted because only other Kix
/// clusters' records name them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Foreign {
    /// How many objects were omitted. An object several clusters deploy
    /// counts once.
    pub objects: usize,
    /// Every Kix cluster whose records name one of those objects.
    pub clusters: BTreeSet<String>,
}

impl Foreign {
    fn add(&mut self, owners: Vec<String>) {
        self.objects += 1;
        self.clusters.extend(owners);
    }
}

impl ManagedSweep {
    /// Return one line that says how many objects other Kix clusters own,
    /// or `None` when there are none. A line for each cluster would grow with
    /// every cluster that shares the Kubernetes cluster.
    pub fn foreign_note(&self) -> Option<String> {
        let total = self.foreign.objects;
        let (objects, belong) = if total == 1 {
            ("object", "belongs")
        } else {
            ("objects", "belong")
        };
        let owners: Vec<&str> = self.foreign.clusters.iter().map(String::as_str).collect();
        match owners.as_slice() {
            [] => None,
            [owner] => Some(format!(
                "Skipped {total} {objects} that {belong} to Kix cluster '{owner}'."
            )),
            _ => Some(format!(
                "Skipped {total} {objects} that {belong} to {} other Kix clusters: {}.",
                owners.len(),
                owners.join(", ")
            )),
        }
    }

    /// Format summary lines describing objects omitted by `scope` for CLI
    /// output.
    pub fn scope_notes(&self) -> Vec<String> {
        let mut notes: Vec<String> = self.foreign_note().into_iter().collect();
        if !self.unattributed.is_empty() {
            let n = self.unattributed.len();
            notes.push(format!(
                "Skipped {n} Kix-labeled object(s) that name no deployment record on this \
                 cluster, so Kix cannot tell which Kix cluster they belong to."
            ));
        }
        notes
    }
}

/// Which Kix-labeled objects a sweep returns.
#[derive(Debug, Clone, Copy)]
pub enum SweepScope<'a> {
    /// The named Kix cluster's own and shared objects, as classified by
    /// [`attribute`]. Unattributed objects go to
    /// [`ManagedSweep::unattributed`], because an object that names no record
    /// may belong to a Kix cluster whose records were deleted.
    Cluster(&'a str),
    /// Objects naming one of `hashes` in `kix.run/activations` (the built
    /// resources of those records of `cluster`, whether or not the records
    /// still exist).
    Records {
        cluster: &'a str,
        hashes: &'a HashSet<String>,
    },
    /// Every Kix-labeled object, regardless of which cluster deployed it.
    All,
}

/// Ownership classification of an object by the record hashes it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attribution {
    /// Names a record of this cluster and none of another's.
    Ours,
    /// Names a record of this cluster and records of these other clusters.
    Shared(Vec<String>),
    /// Names records of these other clusters only.
    Foreign(Vec<String>),
    /// Names no record on the cluster because its hashes are retired, it has no
    /// `kix.run/activations` annotation, or it was never stamped.
    Unattributed,
}

/// Attribute a swept object to Kix clusters through the record hashes it
/// names (see `tenancy::named_hashes`).
pub fn attribute(obj: &DynamicObject, tenancy: &Tenancy) -> Attribution {
    let mut ours = false;
    let mut others: Vec<String> = Vec::new();
    for hash in tenancy::named_hashes(obj) {
        if tenancy.own.contains(hash) {
            ours = true;
        } else if let Some(owner) = tenancy.others.get(hash) {
            others.push(owner.clone());
        }
    }
    others.sort();
    others.dedup();
    match (ours, others.is_empty()) {
        (true, true) => Attribution::Ours,
        (true, false) => Attribution::Shared(others),
        (false, false) => Attribution::Foreign(others),
        (false, true) => Attribution::Unattributed,
    }
}

/// Narrow a whole-cluster sweep to `scope`, attributing objects through
/// `tenancy`, which must be read for the cluster `scope` names.
pub fn scope_sweep(sweep: ManagedSweep, scope: SweepScope<'_>, tenancy: Tenancy) -> ManagedSweep {
    match scope {
        SweepScope::All => ManagedSweep { tenancy, ..sweep },
        SweepScope::Records { hashes, .. } => {
            let (managed, rest) = split_by_records(sweep.managed, hashes);
            let (unstamped, _) = split_by_records(sweep.unstamped, hashes);
            let other_builds = rest
                .iter()
                .filter(|o| {
                    matches!(
                        attribute(o, &tenancy),
                        Attribution::Ours | Attribution::Shared(_)
                    )
                })
                .count();
            ManagedSweep {
                managed,
                unstamped,
                other_builds,
                tenancy,
                ..sweep
            }
        }
        SweepScope::Cluster(_) => {
            let mut foreign = Foreign::default();
            let mut unattributed = Vec::new();
            let mut keep = |objects: Vec<DynamicObject>| -> Vec<DynamicObject> {
                let mut kept = Vec::new();
                for obj in objects {
                    match attribute(&obj, &tenancy) {
                        Attribution::Ours | Attribution::Shared(_) => kept.push(obj),
                        Attribution::Foreign(owners) => foreign.add(owners),
                        Attribution::Unattributed => unattributed.push(obj),
                    }
                }
                kept
            };
            let managed = keep(sweep.managed);
            let unstamped = keep(sweep.unstamped);
            ManagedSweep {
                managed,
                unstamped,
                copies: sweep.copies,
                forbidden: sweep.forbidden,
                foreign,
                unattributed,
                other_builds: 0,
                tenancy,
            }
        }
    }
}

/// Split objects into the ones naming one of `hashes` in
/// `kix.run/activations` (the closures of exactly those records) and the
/// rest.
pub(crate) fn split_by_records(
    objects: Vec<DynamicObject>,
    hashes: &HashSet<String>,
) -> (Vec<DynamicObject>, Vec<DynamicObject>) {
    objects
        .into_iter()
        .partition(|o| tenancy::named_hashes(o).any(|h| hashes.contains(h)))
}

/// Fetch every resource Kix applied by running parallel LIST calls with the
/// `managed-by=kix` label selector and partitioning the results with
/// [`partition_sweep`].
///
/// A 403 on a resource type is recorded rather than failing the sweep (use
/// [`sweep_managed`] to inspect `forbidden`). Any other list failure that
/// exhausts transport retries returns an error so callers never plan against
/// an incomplete view.
pub async fn fetch_managed_resources(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    records: &OpenedRecords,
    scope: SweepScope<'_>,
) -> Result<Vec<DynamicObject>, FetchError> {
    Ok(sweep_managed(client, discovery, records, scope)
        .await?
        .managed)
}

/// Sweep Kix-labeled objects and narrow the result to `scope`.
///
/// LIST selects by the `managed-by=kix` label and [`scope_sweep`] filters
/// client-side because ordinary objects carry no per-cluster label. Activation
/// records are listed after the objects (see [`tenancy::read`]). The
/// Activation and PackageInstance definitions are left out
/// ([`crate::manifest::lifecycle::is_kix_crd`]).
pub async fn sweep_managed(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    records: &OpenedRecords,
    scope: SweepScope<'_>,
) -> Result<ManagedSweep, FetchError> {
    let lp = ListParams::default().labels(MANAGED_BY_LABEL);
    let listed = fetch_parallel(client, discovery, &lp).await?;
    // Earlier releases applied the Activation and PackageInstance
    // definitions from builds, so the live ones may still carry the label.
    let objects = listed
        .objects
        .into_iter()
        .filter(|o| {
            let id = super::drift::resource_id(o);
            !crate::manifest::lifecycle::is_kix_crd_named(id.group_kind(), Some(&id.name))
        })
        .collect();
    let mut sweep = partition_sweep(objects);
    sweep.forbidden = listed.forbidden;
    let cluster = match scope {
        SweepScope::Cluster(cluster) | SweepScope::Records { cluster, .. } => cluster,
        SweepScope::All => "",
    };
    let tenancy = tenancy::read(records, cluster)
        .await
        .map_err(FetchError::RecordsError)?;
    Ok(scope_sweep(sweep, scope, tenancy))
}

/// Partition `managed-by=kix` objects into Kix-managed resources, controller
/// copies, and unstamped objects.
///
/// Controllers often copy labels and annotations onto derived objects (such as
/// EndpointSlices, ReplicaSets, Pods, and Events), so the label alone does not
/// prove Kix applied an object. Whether Kix wrote it decides that, whether or
/// not it carries Kix's stamp:
///
/// - Stamped and written by Kix (a `managedFields` entry for the `kix` field
///   manager): placed in `managed`, even if a controller later adopted it.
/// - Activation records: never copies. Kix writes some of them under other
///   field managers, and records are never pruned.
/// - Unstamped and owned by a controller: dropped as a controller child.
/// - Unstamped `Endpoints` with the same namespace and name as a stamped
///   `Service`: dropped as the endpoints controller's mirror.
/// - Any other object Kix never wrote: placed in `copies`. Operators copy a
///   custom resource's labels onto the objects they make, and some leave those
///   objects unowned, such as data volumes and the Events they post.
/// - Unstamped objects Kix wrote: placed in `unstamped`.
pub fn partition_sweep(objects: Vec<DynamicObject>) -> ManagedSweep {
    let (stamped, rest): (Vec<DynamicObject>, Vec<DynamicObject>) =
        objects.into_iter().partition(is_stamped);
    let (mut copies, managed): (Vec<DynamicObject>, Vec<DynamicObject>) =
        stamped.into_iter().partition(is_controller_copy);
    let stamped_services: HashSet<(String, String)> = managed
        .iter()
        .chain(&copies)
        .filter(|o| super::drift::resource_id(o).group_kind() == crate::manifest::kinds::SERVICE)
        .map(|o| (namespace_of(o), o.metadata.name.clone().unwrap_or_default()))
        .collect();
    let (unstamped_copies, unstamped): (Vec<DynamicObject>, Vec<DynamicObject>) = rest
        .into_iter()
        .filter(|o| !is_owned(o))
        .filter(|o| {
            !(object_kind(o) == "Endpoints"
                && stamped_services
                    .contains(&(namespace_of(o), o.metadata.name.clone().unwrap_or_default())))
        })
        .partition(is_controller_copy);
    copies.extend(unstamped_copies);
    ManagedSweep {
        managed,
        unstamped,
        copies,
        forbidden: Vec::new(),
        foreign: Foreign::default(),
        unattributed: Vec::new(),
        other_builds: 0,
        tenancy: Tenancy::empty(""),
    }
}

/// Return whether Kix's apply step stamped `obj` with `kix.run/identity-hash`.
pub(crate) fn is_stamped(obj: &DynamicObject) -> bool {
    obj.metadata
        .annotations
        .as_ref()
        .is_some_and(|a| keys::contains_meta(a, keys::IDENTITY_HASH))
}

/// Return whether `obj` is a controller-created copy rather than an object Kix
/// applied (see [`partition_sweep`]).
fn is_controller_copy(obj: &DynamicObject) -> bool {
    lifecycle_of_live(obj) != Lifecycle::Record
        && !super::fieldsv1::written_by_kix(obj.metadata.managed_fields.as_deref().unwrap_or(&[]))
}

/// Return whether `obj` has at least one `ownerReference`.
pub(crate) fn is_owned(obj: &DynamicObject) -> bool {
    obj.metadata
        .owner_references
        .as_ref()
        .is_some_and(|owners| !owners.is_empty())
}

fn object_kind(obj: &DynamicObject) -> &str {
    obj.data
        .get("kind")
        .and_then(serde_json::Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("")
}

fn namespace_of(obj: &DynamicObject) -> String {
    obj.metadata.namespace.clone().unwrap_or_default()
}

/// An orphan candidate that another Kix cluster's current build still
/// contains, so a prune keeps it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedOrphan {
    pub rid: ResourceId,
    /// The other Kix clusters, sorted.
    pub clusters: Vec<String>,
}

impl SharedOrphan {
    /// Format the line a plan prints for this shared orphan.
    pub fn describe(&self) -> String {
        let clusters = if self.clusters.len() == 1 {
            "Kix cluster"
        } else {
            "Kix clusters"
        };
        format!(
            "kept {}, still deployed by {clusters} {}",
            self.rid,
            self.clusters.join(", ")
        )
    }
}

/// An object that a pending record of its own Kix cluster names
/// ([`Tenancy::pending_records_of`]), so `kix gc` leaves it alone until a
/// deploy finishes or replaces that record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeldObject {
    pub rid: ResourceId,
    /// The names of those records, sorted.
    pub records: Vec<String>,
}

/// Split orphan candidates into those to prune and those still deployed by
/// another Kix cluster, using `live` objects already in memory. Kinds
/// protected by [`never_pruned`] stay in the prune list so the prune step can
/// report them as kept.
pub(crate) fn split_shared_orphans(
    orphans: Vec<ResourceId>,
    live: &[DynamicObject],
    tenancy: &Tenancy,
) -> (Vec<ResourceId>, Vec<SharedOrphan>) {
    let by_id: std::collections::HashMap<ResourceId, &DynamicObject> = live
        .iter()
        .map(|o| (ResourceId::from_value(&to_manifest_value(o)), o))
        .collect();
    split_by_lookup(orphans, |rid| by_id.get(rid).copied(), tenancy)
}

fn split_by_lookup<'a>(
    orphans: Vec<ResourceId>,
    live: impl Fn(&ResourceId) -> Option<&'a DynamicObject>,
    tenancy: &Tenancy,
) -> (Vec<ResourceId>, Vec<SharedOrphan>) {
    if tenancy.others_current.is_empty() {
        return (orphans, Vec::new());
    }
    let mut prune = Vec::new();
    let mut shared = Vec::new();
    for rid in orphans {
        if never_pruned(rid.group_kind()) {
            prune.push(rid);
            continue;
        }
        let clusters = live(&rid)
            .map(|o| tenancy.still_deployed_by_others(o))
            .unwrap_or_default();
        if clusters.is_empty() {
            prune.push(rid);
        } else {
            shared.push(SharedOrphan { rid, clusters });
        }
    }
    (prune, shared)
}

/// Fetch each orphan candidate from the cluster and split out resources still
/// deployed by another Kix cluster.
///
/// Used when planning from builds without a full cluster sweep. Candidates that
/// are already gone or whose kind is not served are treated as prunable. Any
/// other GET failure returns an error so pruning never deletes an unreadable
/// shared object.
pub(crate) async fn split_shared_orphans_live(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    records: &OpenedRecords,
    orphans: Vec<ResourceId>,
    cluster: &str,
) -> Result<(Vec<ResourceId>, Vec<SharedOrphan>), FetchError> {
    if orphans.is_empty() {
        return Ok((orphans, Vec::new()));
    }
    let live = read_candidates(client, discovery, &orphans).await?;
    let tenancy = tenancy::read(records, cluster)
        .await
        .map_err(FetchError::RecordsError)?;
    Ok(split_by_lookup(orphans, |rid| live.get(rid), &tenancy))
}

/// Fetch each candidate from the cluster and split out the ones a pending
/// record of Kix cluster `cluster` names ([`Tenancy::pending_records_of`]). A candidate that is gone or whose
/// kind is not served stays in the first list. Any other GET failure is an
/// error.
pub(crate) async fn split_held_live(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    records: &OpenedRecords,
    candidates: Vec<ResourceId>,
    cluster: &str,
) -> Result<(Vec<ResourceId>, Vec<HeldObject>), FetchError> {
    if candidates.is_empty() {
        return Ok((candidates, Vec::new()));
    }
    let live = read_candidates(client, discovery, &candidates).await?;
    let tenancy = tenancy::read(records, cluster)
        .await
        .map_err(FetchError::RecordsError)?;
    let mut rest = Vec::new();
    let mut held = Vec::new();
    for rid in candidates {
        let records = live
            .get(&rid)
            .map(|o| tenancy.pending_records_of(o))
            .unwrap_or_default();
        if records.is_empty() {
            rest.push(rid);
        } else {
            held.push(HeldObject { rid, records });
        }
    }
    Ok((rest, held))
}

/// Read each of `candidates` the cluster serves, except kinds that are never
/// pruned, keyed by the candidate's `ResourceId` so an object read from
/// `default` for a cluster-scoped candidate still matches. A candidate that
/// is gone is left out. Any other GET failure is an error.
async fn read_candidates(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    candidates: &[ResourceId],
) -> Result<HashMap<ResourceId, DynamicObject>, FetchError> {
    let ar_by_kind: HashMap<&str, &(ApiResource, Scope)> = discovery
        .iter()
        .map(|pair| (pair.0.kind.as_str(), pair))
        .collect();
    let gets = candidates
        .iter()
        .filter(|rid| !never_pruned(rid.group_kind()))
        .filter_map(|rid| {
            let (ar, scope) = ar_by_kind.get(rid.kind.as_str())?;
            let api = api_for(client, ar, scope, rid);
            Some(async move {
                let obj = api
                    .get_opt(&rid.name)
                    .await
                    .map_err(|source| FetchError::GetError {
                        resource: rid.display_id(),
                        source,
                    })?;
                Ok::<_, FetchError>(obj.map(|o| (rid.clone(), o)))
            })
        });
    Ok(futures::future::try_join_all(gets)
        .await?
        .into_iter()
        .flatten()
        .collect())
}

/// What [`LiveObjects::get`] knows about one object.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Live<'a> {
    Present(&'a DynamicObject),
    /// The listing of its kind does not hold it, or the cluster does not
    /// serve its kind.
    Absent,
    /// This account may not list its kind.
    Unread,
}

/// The objects of some kinds that carry the `managed-by=kix` label, read with
/// one cluster-wide LIST per kind.
#[derive(Debug, Default)]
pub(crate) struct LiveObjects {
    objects: HashMap<ResourceId, DynamicObject>,
    /// `(group, kind)` of each kind this account may not list.
    unread: HashSet<(String, String)>,
}

impl LiveObjects {
    /// List the objects of each kind of `ids` that the cluster serves. A
    /// kind the account may not list (403) is recorded as unread. Any other
    /// failure returns an error, so no caller reads a missing listing as an
    /// empty one.
    pub(crate) async fn list<'a>(
        client: &Client,
        discovery: &[(ApiResource, Scope)],
        ids: impl IntoIterator<Item = &'a ResourceId>,
    ) -> Result<LiveObjects, FetchError> {
        let mut kinds: Vec<(ApiResource, Scope)> = Vec::new();
        for rid in ids {
            let listed = kinds
                .iter()
                .any(|(ar, _)| ar.group == rid.group && ar.kind == rid.kind);
            if !listed
                && let Some(served) = super::discovery::find(discovery, &rid.group, &rid.kind)
            {
                kinds.push(served.clone());
            }
        }
        let lp = ListParams::default().labels(MANAGED_BY_LABEL);
        let listed = fetch_parallel(client, &kinds, &lp).await?;
        let unread = kinds
            .iter()
            .filter(|(ar, _)| listed.forbidden.contains(&resource_fqn(ar)))
            .map(|(ar, _)| (ar.group.clone(), ar.kind.clone()))
            .collect();
        let objects = listed
            .objects
            .into_iter()
            .map(|obj| (super::drift::resource_id(&obj), obj))
            .collect();
        Ok(LiveObjects { objects, unread })
    }

    pub(crate) fn get(&self, rid: &ResourceId) -> Live<'_> {
        if self.unread.contains(&(rid.group.clone(), rid.kind.clone())) {
            return Live::Unread;
        }
        self.objects.get(rid).map_or(Live::Absent, Live::Present)
    }
}

impl Live<'_> {
    /// Return whether the cluster no longer holds the object: it is absent,
    /// or it is being deleted. An object of a kind Kix may not list is not
    /// known to be lost.
    pub(crate) fn lost(self) -> bool {
        match self {
            Live::Absent => true,
            Live::Present(obj) => obj.metadata.deletion_timestamp.is_some(),
            Live::Unread => false,
        }
    }
}

/// Results of a single parallel LIST pass.
pub(crate) struct Listed {
    pub objects: Vec<DynamicObject>,
    /// Resource types that answered 403.
    pub forbidden: Vec<String>,
}

/// One task's result inside [`fetch_parallel`].
enum ListOutcome {
    /// The objects listed through the resource at this index of the
    /// discovery list.
    Items(usize, Vec<DynamicObject>),
    Forbidden(String),
}

/// Maximum concurrent LIST requests during a sweep. Keeping this bounded on
/// spawned tasks avoids triggering API server priority-and-fairness 429s
/// without holding permits across parked futures. Override with
/// `KIX_SWEEP_CONCURRENCY`.
pub(crate) const DEFAULT_SWEEP_CONCURRENCY: usize = 8;
/// Env var for [`DEFAULT_SWEEP_CONCURRENCY`].
pub(crate) const SWEEP_CONCURRENCY_ENV: &str = "KIX_SWEEP_CONCURRENCY";

fn sweep_concurrency() -> usize {
    super::client::env_number(SWEEP_CONCURRENCY_ENV)
        .map(|n| n.max(1) as usize)
        .unwrap_or(DEFAULT_SWEEP_CONCURRENCY)
}

/// Run parallel LIST calls across all discovered resource types, up to
/// [`DEFAULT_SWEEP_CONCURRENCY`] at a time, and return each object once
/// (see [`one_per_object`]).
///
/// Returns any non-403 error that exhausts transport retries and cancels
/// remaining in-flight LISTs so callers never see a partial result as empty.
async fn fetch_parallel(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    lp: &ListParams,
) -> Result<Listed, FetchError> {
    let mut set = JoinSet::new();
    let mut batches: Vec<(usize, Vec<DynamicObject>)> = Vec::new();
    let mut forbidden: Vec<String> = Vec::new();
    let limit = sweep_concurrency();

    for (index, (ar, scope)) in discovery.iter().enumerate() {
        while set.len() >= limit {
            match set.join_next().await {
                Some(outcome) => absorb(&mut batches, &mut forbidden, outcome)?,
                None => break,
            }
        }
        let api: Api<DynamicObject> = match scope {
            Scope::Namespaced => Api::all_with(client.clone(), ar),
            Scope::Cluster => Api::all_with(client.clone(), ar),
        };

        let lp = lp.clone();
        let fqn = resource_fqn(ar);
        let kind = ar.kind.clone();
        let api_version = ar.api_version.clone();
        set.spawn(async move {
            match api.list(&lp).await {
                Ok(list) => {
                    if !list.items.is_empty() {
                        tracing::debug!(resource = %fqn, count = list.items.len(), "fetched");
                    }
                    // LIST responses omit per-item `kind` and `apiVersion`.
                    let items: Vec<DynamicObject> = list
                        .items
                        .into_iter()
                        .map(|mut obj| {
                            if let Some(map) = obj.data.as_object_mut() {
                                map.entry("kind")
                                    .or_insert_with(|| serde_json::Value::String(kind.clone()));
                                map.entry("apiVersion").or_insert_with(|| {
                                    serde_json::Value::String(api_version.clone())
                                });
                            }
                            obj
                        })
                        .collect();
                    Ok(ListOutcome::Items(index, items))
                }
                Err(e) if classify(&e) == FailureClass::Forbidden => {
                    tracing::debug!(resource = %fqn, "forbidden, recorded");
                    Ok(ListOutcome::Forbidden(fqn))
                }
                Err(e) => Err(FetchError::ListError {
                    resource: fqn,
                    source: e,
                }),
            }
        });
    }

    while let Some(join_result) = set.join_next().await {
        absorb(&mut batches, &mut forbidden, join_result)?;
    }
    batches.sort_by_key(|(index, _)| *index);
    forbidden.sort();
    Ok(Listed {
        objects: one_per_object(batches.into_iter().flat_map(|(_, items)| items)),
        forbidden,
    })
}

/// Fold one finished LIST task into `batches` or `forbidden`, or return its
/// error.
#[allow(clippy::result_large_err)]
fn absorb(
    batches: &mut Vec<(usize, Vec<DynamicObject>)>,
    forbidden: &mut Vec<String>,
    join_result: Result<Result<ListOutcome, FetchError>, tokio::task::JoinError>,
) -> Result<(), FetchError> {
    match join_result {
        Ok(Ok(ListOutcome::Items(index, items))) => batches.push((index, items)),
        Ok(Ok(ListOutcome::Forbidden(fqn))) => forbidden.push(fqn),
        Ok(Err(e)) => return Err(e),
        Err(e) => return Err(FetchError::ClientError(Box::new(e))),
    }
    Ok(())
}

/// Keep one copy of each object, identified by its UID, from objects listed
/// in discovery order.
///
/// Kubernetes serves some kinds under more than one API group, such as
/// `Event` under both the core group and `events.k8s.io`, so listing every
/// served kind reads such an object once per group. The copy read through the
/// API group Kix applied it with wins, so its resource id matches the
/// build's. Otherwise the first copy in discovery order wins.
fn one_per_object(objects: impl IntoIterator<Item = DynamicObject>) -> Vec<DynamicObject> {
    let mut kept: Vec<DynamicObject> = Vec::new();
    let mut by_uid: HashMap<String, usize> = HashMap::new();
    for obj in objects {
        let Some(uid) = obj.metadata.uid.clone() else {
            kept.push(obj);
            continue;
        };
        match by_uid.get(&uid) {
            None => {
                by_uid.insert(uid, kept.len());
                kept.push(obj);
            }
            Some(&i) => {
                if read_as_kix_applied(&obj) && !read_as_kix_applied(&kept[i]) {
                    kept[i] = obj;
                }
            }
        }
    }
    kept
}

/// Return whether `obj` was read through the API group of a `kix`
/// `managedFields` entry.
fn read_as_kix_applied(obj: &DynamicObject) -> bool {
    let group = |api_version: &str| {
        api_version
            .split_once('/')
            .map_or("", |(g, _)| g)
            .to_owned()
    };
    let Some(read) = obj
        .data
        .get("apiVersion")
        .and_then(serde_json::Value::as_str)
    else {
        return false;
    };
    obj.metadata.managed_fields.iter().flatten().any(|e| {
        e.manager.as_deref() == Some(super::fieldsv1::KIX_FIELD_MANAGER)
            && e.api_version.as_deref().map(group) == Some(group(read))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::activation;
    use crate::cluster::discovery::discover_resources;
    use crate::manifest::lifecycle;
    use crate::manifest::types::CLUSTER_SCOPED;
    use k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry;
    use kube::api::ObjectMeta;
    use serde_json::json;

    fn swept(kind: &str, ns: &str, name: &str, stamped: bool, owned: bool) -> DynamicObject {
        use k8s_openapi::apimachinery::pkg::apis::meta::v1::OwnerReference;
        let mut obj = DynamicObject {
            types: None,
            metadata: ObjectMeta {
                name: Some(name.into()),
                namespace: Some(ns.into()),
                ..Default::default()
            },
            data: json!({ "kind": kind }),
        };
        if stamped {
            obj.metadata.annotations = Some(
                [(keys::IDENTITY_HASH.to_string(), "h".to_string())]
                    .into_iter()
                    .collect(),
            );
        }
        obj = kix_applied(obj);
        if owned {
            obj.metadata.owner_references = Some(vec![OwnerReference {
                api_version: "v1".into(),
                kind: "Service".into(),
                name: name.into(),
                uid: "abc".into(),
                controller: Some(true),
                block_owner_deletion: None,
            }]);
        }
        obj
    }

    fn names(objs: &[DynamicObject]) -> Vec<String> {
        let mut v: Vec<String> = objs
            .iter()
            .map(|o| {
                format!(
                    "{}/{}/{}",
                    o.metadata.namespace.as_deref().unwrap_or(""),
                    o.data["kind"].as_str().unwrap(),
                    o.metadata.name.as_deref().unwrap()
                )
            })
            .collect();
        v.sort();
        v
    }

    /// Build a `managedFields` entry for `manager` and `operation`.
    fn entry(manager: &str, operation: &str) -> ManagedFieldsEntry {
        ManagedFieldsEntry {
            manager: Some(manager.into()),
            operation: Some(operation.into()),
            ..Default::default()
        }
    }

    /// Replace `obj`'s `managedFields` with one entry by `manager`, as on an
    /// object a controller made from a Kix object's labels and annotations.
    fn written_by(manager: &str, mut obj: DynamicObject) -> DynamicObject {
        obj.metadata.managed_fields = Some(vec![entry(manager, "Update")]);
        obj
    }

    /// Attach Kix's `Apply` `managedFields` entry to `obj`.
    fn kix_applied(mut obj: DynamicObject) -> DynamicObject {
        obj.metadata.managed_fields = Some(vec![entry(
            crate::cluster::fieldsv1::KIX_FIELD_MANAGER,
            "Apply",
        )]);
        obj
    }

    #[test]
    fn sweep_keeps_stamped_objects_whoever_owns_them() {
        let sweep = partition_sweep(vec![
            swept("Deployment", "ns", "web", true, false),
            swept("Job", "ns", "adopted", true, true),
        ]);
        assert_eq!(
            names(&sweep.managed),
            ["ns/Deployment/web", "ns/Job/adopted"]
        );
        assert!(sweep.unstamped.is_empty());
        assert!(sweep.copies.is_empty());
    }

    #[test]
    fn sweep_sets_apart_owned_stamped_objects_kix_never_applied() {
        let sweep = partition_sweep(vec![
            written_by("syncer", swept("Service", "ns", "web-x-guest", true, true)),
            written_by(
                "syncer",
                swept("Secret", "ns", "synced-by-other", true, true),
            ),
        ]);
        assert!(sweep.managed.is_empty());
        assert!(sweep.unstamped.is_empty());
        assert_eq!(
            names(&sweep.copies),
            ["ns/Secret/synced-by-other", "ns/Service/web-x-guest"]
        );
    }

    /// An operator copies a custom resource's labels and annotations onto
    /// the data volumes it makes and leaves them unowned, so deleting the
    /// resource keeps the data. Kix never wrote them, so they are copies.
    #[test]
    fn sweep_sets_apart_unowned_objects_kix_never_wrote() {
        let mut volume = swept("PersistentVolumeClaim", "ns", "data-keeper-0", true, false);
        volume.metadata.managed_fields = Some(vec![
            entry("kube-controller-manager", "Update"),
            entry("clickhouse-operator", "Update"),
        ]);
        let sweep = partition_sweep(vec![
            swept("ClickHouseKeeperInstallation", "ns", "keeper", true, false),
            volume,
        ]);
        assert_eq!(
            names(&sweep.managed),
            ["ns/ClickHouseKeeperInstallation/keeper"]
        );
        assert_eq!(
            names(&sweep.copies),
            ["ns/PersistentVolumeClaim/data-keeper-0"]
        );
    }

    /// Kix's bookkeeping update also writes under the `kix` field manager, so
    /// an object whose `Apply` entry another manager took over is still Kix's.
    #[test]
    fn sweep_keeps_an_object_with_only_kix_bookkeeping_entry() {
        let mut taken = swept("ConfigMap", "ns", "taken-over", true, false);
        taken.metadata.managed_fields = Some(vec![
            entry("kubectl", "Apply"),
            entry(crate::cluster::fieldsv1::KIX_FIELD_MANAGER, "Update"),
        ]);
        let sweep = partition_sweep(vec![taken]);
        assert_eq!(names(&sweep.managed), ["ns/ConfigMap/taken-over"]);
        assert!(sweep.copies.is_empty());
    }

    /// Kix writes some Activation records under other field managers: the
    /// records it hands to the operator, and the ones a domain move copied.
    #[test]
    fn sweep_keeps_records_written_under_other_managers() {
        let sweep = partition_sweep(vec![
            written_by("kix-cli", record(Some("a"), "a1", lifecycle::PHASE_QUEUED)),
            written_by(
                "kix-migrate-domain",
                record(Some("a"), "a2", lifecycle::PHASE_SUPERSEDED),
            ),
        ]);
        assert_eq!(sorted_names(&sweep.managed), ["rec-a1", "rec-a2"]);
        assert!(sweep.copies.is_empty());
    }

    #[test]
    fn sweep_treats_endpoints_named_after_a_copied_service_as_its_mirror() {
        let sweep = partition_sweep(vec![
            written_by("syncer", swept("Service", "ns", "web-x-guest", true, true)),
            swept("Endpoints", "ns", "web-x-guest", false, false),
        ]);
        assert_eq!(names(&sweep.copies), ["ns/Service/web-x-guest"]);
        assert!(sweep.unstamped.is_empty());
    }

    #[test]
    fn sweep_drops_owned_unstamped_children() {
        let sweep = partition_sweep(vec![
            swept("Service", "ns", "web", true, false),
            swept("EndpointSlice", "ns", "web-abc12", false, true),
            swept("ReplicaSet", "ns", "web-7d9f", false, true),
        ]);
        assert_eq!(names(&sweep.managed), ["ns/Service/web"]);
        assert!(sweep.unstamped.is_empty());
    }

    #[test]
    fn sweep_reports_unowned_unstamped_objects_kix_wrote() {
        let sweep = partition_sweep(vec![swept("ConfigMap", "ns", "unannotated", false, false)]);
        assert!(sweep.managed.is_empty() && sweep.copies.is_empty());
        assert_eq!(names(&sweep.unstamped), ["ns/ConfigMap/unannotated"]);
    }

    /// An operator copies a custom resource's labels, without Kix's
    /// annotations, onto the Events it posts about it. Kix never wrote them,
    /// so they are copies, not unstamped objects of Kix's.
    #[test]
    fn sweep_sets_apart_unstamped_objects_kix_never_wrote() {
        let sweep = partition_sweep(vec![
            written_by(
                "stackgres-operator",
                swept("Event", "ns", "db.1a2b", false, false),
            ),
            swept("ConfigMap", "ns", "unannotated", false, false),
        ]);
        assert_eq!(names(&sweep.copies), ["ns/Event/db.1a2b"]);
        assert_eq!(names(&sweep.unstamped), ["ns/ConfigMap/unannotated"]);
        assert!(sweep.managed.is_empty());
    }

    #[test]
    fn sweep_treats_endpoints_named_after_a_managed_service_as_its_mirror() {
        let sweep = partition_sweep(vec![
            swept("Service", "ns", "web", true, false),
            swept("Endpoints", "ns", "web", false, false),
            swept("Endpoints", "ns", "stray", false, false),
            swept("Endpoints", "other", "web", false, false),
        ]);
        assert_eq!(names(&sweep.managed), ["ns/Service/web"]);
        assert_eq!(
            names(&sweep.unstamped),
            ["ns/Endpoints/stray", "other/Endpoints/web"],
            "only the same-namespace mirror is dropped"
        );
    }

    fn record(cluster: Option<&str>, hash: &str, phase: &str) -> DynamicObject {
        let mut labels = serde_json::Map::new();
        if let Some(c) = cluster {
            labels.insert(keys::CLUSTER_LABEL.into(), json!(c));
        }
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": labels,
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": phase },
        }))
        .unwrap()
    }

    /// Build a [`Tenancy`] where cluster `a` has `a1` (Superseded) and `a2`
    /// (Active), and cluster `b` has `b0` (Superseded) and `b1` (Active).
    fn two_clusters(cluster: &str) -> Tenancy {
        Tenancy::from_records(
            &[
                record(Some("a"), "a1", lifecycle::PHASE_SUPERSEDED),
                record(Some("a"), "a2", lifecycle::PHASE_ACTIVE),
                record(Some("b"), "b0", lifecycle::PHASE_SUPERSEDED),
                record(Some("b"), "b1", lifecycle::PHASE_ACTIVE),
            ],
            cluster,
        )
    }

    fn one_cluster() -> Tenancy {
        Tenancy::from_records(&[record(Some("a"), "a2", lifecycle::PHASE_ACTIVE)], "a")
    }

    /// Build a stamped object naming comma-separated `activations` under `key`.
    fn named(kind: &str, ns: &str, name: &str, key: &str, activations: &str) -> DynamicObject {
        let mut obj = swept(kind, ns, name, true, false);
        if !activations.is_empty() {
            obj.metadata
                .annotations
                .get_or_insert_default()
                .insert(key.to_string(), activations.to_string());
        }
        obj
    }

    fn obj(kind: &str, name: &str, activations: &str) -> DynamicObject {
        named(kind, "ns", name, keys::ACTIVATIONS, activations)
    }

    #[test]
    fn attribution_follows_the_record_hashes_an_object_names() {
        let t = two_clusters("a");
        let cases = [
            ("a2", Attribution::Ours),
            ("a1", Attribution::Ours),
            ("a2,b1", Attribution::Shared(vec!["b".into()])),
            ("b1", Attribution::Foreign(vec!["b".into()])),
            ("b0,b1", Attribution::Foreign(vec!["b".into()])),
            ("dead1,dead2", Attribution::Unattributed),
            ("", Attribution::Unattributed),
        ];
        for (acts, want) in cases {
            assert_eq!(
                attribute(&obj("ConfigMap", "c", acts), &t),
                want,
                "{acts:?}"
            );
        }
        // An unstamped label carrier names nothing.
        assert_eq!(
            attribute(&swept("ConfigMap", "ns", "c", false, false), &t),
            Attribution::Unattributed
        );
    }

    #[test]
    fn attribution_reads_the_retired_activations_key() {
        let Some(domain) = crate::legacy_domain::DOMAINS.first() else {
            return;
        };
        let t = two_clusters("a");
        let legacy = named(
            "ConfigMap",
            "ns",
            "c",
            &format!("{domain}/activations"),
            "b1",
        );
        assert_eq!(
            attribute(&legacy, &t),
            Attribution::Foreign(vec!["b".into()])
        );
    }

    /// An Activation record names itself by its identity hash, before any
    /// deploy has stamped `kix.run/activations` on it.
    #[test]
    fn a_record_is_attributed_by_its_own_hash() {
        let t = two_clusters("a");
        assert_eq!(
            attribute(&record(Some("b"), "b1", lifecycle::PHASE_ACTIVE), &t),
            Attribution::Foreign(vec!["b".into()])
        );
        assert_eq!(
            attribute(&record(Some("a"), "a2", lifecycle::PHASE_ACTIVE), &t),
            Attribution::Ours
        );
    }

    fn mixed_sweep() -> ManagedSweep {
        partition_sweep(vec![
            obj("Deployment", "a-web", "a2"),
            obj("Deployment", "b-web", "b1"),
            obj("ClusterRole", "shared", "a2,b1"),
            obj("ConfigMap", "leftover", "dead"),
            swept("ConfigMap", "ns", "unannotated", false, false),
        ])
    }

    fn sorted_names(objs: &[DynamicObject]) -> Vec<&str> {
        let mut v: Vec<&str> = objs
            .iter()
            .map(|o| o.metadata.name.as_deref().unwrap())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn copies_stay_in_a_single_cluster_scope() {
        let sweep = partition_sweep(vec![
            obj("Deployment", "a-web", "a2"),
            written_by("syncer", swept("Service", "ns", "copied", true, true)),
        ]);
        let scoped = scope_sweep(sweep, SweepScope::Cluster("a"), two_clusters("a"));
        assert_eq!(sorted_names(&scoped.managed), vec!["a-web"]);
        assert_eq!(sorted_names(&scoped.copies), vec!["copied"]);
        assert!(scoped.unattributed.is_empty());
    }

    /// Two Kix clusters' objects in one apiserver: each cluster's scope sees
    /// its own objects and the shared one, never the other's.
    #[test]
    fn each_cluster_sees_only_its_own_objects() {
        let swept_a = scope_sweep(mixed_sweep(), SweepScope::Cluster("a"), two_clusters("a"));
        assert_eq!(sorted_names(&swept_a.managed), vec!["a-web", "shared"]);
        assert_eq!(swept_a.foreign, foreign(1, &["b"]));
        assert_eq!(
            sorted_names(&swept_a.unattributed),
            vec!["leftover", "unannotated"]
        );
        assert!(swept_a.unstamped.is_empty());

        let swept_b = scope_sweep(mixed_sweep(), SweepScope::Cluster("b"), two_clusters("b"));
        assert_eq!(sorted_names(&swept_b.managed), vec!["b-web", "shared"]);
        assert_eq!(swept_b.foreign, foreign(1, &["a"]));
    }

    /// When only one Kix cluster has records on the Kubernetes cluster, the
    /// scoped sweep keeps that cluster's objects and sets aside every object
    /// that names no record.
    #[test]
    fn a_single_cluster_sets_aside_objects_that_name_no_record() {
        let t = one_cluster();
        let sweep = partition_sweep(vec![
            obj("Deployment", "web", "a2"),
            obj("ConfigMap", "leftover", "dead"),
            obj("ConfigMap", "never-annotated", ""),
            swept("ConfigMap", "ns", "unannotated", false, false),
        ]);
        let scoped = scope_sweep(sweep, SweepScope::Cluster("a"), t);
        assert_eq!(sorted_names(&scoped.managed), vec!["web"]);
        assert_eq!(
            sorted_names(&scoped.unattributed),
            vec!["leftover", "never-annotated", "unannotated"]
        );
        assert!(scoped.foreign.objects == 0 && scoped.unstamped.is_empty());

        // A Kubernetes cluster with no Activation records attributes nothing.
        let none = Tenancy::from_records(&[], "a");
        let scoped = scope_sweep(mixed_sweep(), SweepScope::Cluster("a"), none);
        assert!(scoped.managed.is_empty());
        assert_eq!(scoped.unattributed.len(), 5);
    }

    /// Deleting another Kix cluster's records does not make its objects this
    /// cluster's: they name records that are gone, so they are unattributed.
    #[test]
    fn objects_of_a_cluster_whose_records_are_gone_are_not_ours() {
        let sweep = || {
            partition_sweep(vec![
                obj("Deployment", "a-web", "a2"),
                obj("Deployment", "b-web", "b1"),
                obj("ClusterRole", "shared", "a2,b1"),
            ])
        };
        let both = scope_sweep(sweep(), SweepScope::Cluster("a"), two_clusters("a"));
        assert_eq!(sorted_names(&both.managed), vec!["a-web", "shared"]);
        assert_eq!(both.foreign, foreign(1, &["b"]));

        let a_only = scope_sweep(sweep(), SweepScope::Cluster("a"), one_cluster());
        assert_eq!(sorted_names(&a_only.managed), vec!["a-web", "shared"]);
        assert_eq!(sorted_names(&a_only.unattributed), vec!["b-web"]);
        assert!(a_only.foreign.objects == 0);
    }

    #[test]
    fn a_records_scope_keeps_exactly_those_closures() {
        let hashes: HashSet<String> = ["a2".to_string()].into();
        let mut objects = mixed_sweep();
        objects.managed.push(obj("ConfigMap", "a-older", "a1"));
        let scope = SweepScope::Records {
            cluster: "a",
            hashes: &hashes,
        };
        let scoped = scope_sweep(objects, scope, two_clusters("a"));
        assert_eq!(sorted_names(&scoped.managed), vec!["a-web", "shared"]);
        assert!(scoped.unstamped.is_empty());
        // `a-older` names only a Superseded record of `a`.
        assert_eq!(scoped.other_builds, 1);
    }

    fn foreign(objects: usize, clusters: &[&str]) -> Foreign {
        Foreign {
            objects,
            clusters: clusters.iter().map(|c| c.to_string()).collect(),
        }
    }

    /// Objects that several other clusters deploy count once, and each
    /// cluster is named once, so the count of clusters matches the names.
    #[test]
    fn the_foreign_note_names_each_other_cluster_once() {
        let records = [
            record(Some("a"), "a1", lifecycle::PHASE_ACTIVE),
            record(Some("b"), "b1", lifecycle::PHASE_ACTIVE),
            record(Some("c"), "c1", lifecycle::PHASE_ACTIVE),
            record(Some("d"), "d1", lifecycle::PHASE_ACTIVE),
        ];
        let sweep = partition_sweep(vec![
            obj("Deployment", "b-web", "b1"),
            obj("ClusterRole", "b-and-c", "b1,c1"),
            obj("ClusterRole", "c-and-d", "c1,d1"),
            obj("Deployment", "d-web", "d1"),
        ]);
        let scoped = scope_sweep(
            sweep,
            SweepScope::Cluster("a"),
            Tenancy::from_records(&records, "a"),
        );
        assert_eq!(scoped.foreign, foreign(4, &["b", "c", "d"]));
        assert_eq!(
            scoped.foreign_note().unwrap(),
            "Skipped 4 objects that belong to 3 other Kix clusters: b, c, d."
        );

        let one = ManagedSweep {
            foreign: foreign(1, &["b", "c"]),
            ..partition_sweep(vec![])
        };
        assert_eq!(
            one.foreign_note().unwrap(),
            "Skipped 1 object that belongs to 2 other Kix clusters: b, c."
        );
        let none = partition_sweep(vec![]);
        assert_eq!(none.foreign_note(), None);
    }

    #[test]
    fn scope_notes_name_the_other_cluster() {
        let notes =
            scope_sweep(mixed_sweep(), SweepScope::Cluster("a"), two_clusters("a")).scope_notes();
        assert_eq!(
            notes[0],
            "Skipped 1 object that belongs to Kix cluster 'b'."
        );
        assert!(
            notes[1].starts_with("Skipped 2 Kix-labeled object(s) that name no deployment record")
        );
    }

    /// The sweep lists the Activation records after every object LIST, so
    /// every hash a listed object names belongs to a record it read.
    #[tokio::test]
    async fn the_sweep_reads_the_records_after_the_objects() {
        use crate::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        let client = api.client();
        let discovery = discover_resources(&client).await.unwrap();
        let records = activation::Records::open(&client, &discovery).unwrap();
        let before = api.requests().len();
        sweep_managed(&client, &discovery, &records, SweepScope::Cluster("a"))
            .await
            .unwrap();
        let requests = api.requests().split_off(before);
        let records = format!("GET /apis/{}/activations", keys::API_VERSION);
        let last_object_list = requests
            .iter()
            .rposition(|r| r.contains("labelSelector="))
            .unwrap();
        let record_list = requests.iter().position(|r| *r == records).unwrap();
        assert!(last_object_list < record_list, "{requests:#?}");
    }

    /// Soft gc reads each candidate and keeps the ones a failed or partly
    /// deployed record of its cluster names. A candidate only the current
    /// or a Superseded record names, and one that is gone, may be deleted.
    #[tokio::test]
    async fn candidates_a_pending_record_names_are_held() {
        use crate::cluster::fake_api::FakeApi;
        use crate::manifest::lifecycle::{PHASE_FAILED, PHASE_PARTIAL};
        let record = |name: &str, hash: &str, phase: &str| {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": name,
                    "labels": {
                        "app.kubernetes.io/managed-by": "kix",
                        (keys::CLUSTER_LABEL): "a",
                    },
                    "annotations": { (keys::IDENTITY_HASH): hash },
                },
                "status": { "phase": phase },
            })
        };
        let cm = |name: &str, activations: &str| {
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "labels": { "app.kubernetes.io/managed-by": "kix" },
                    "annotations": { (keys::ACTIVATIONS): activations },
                },
            })
        };
        let api = FakeApi::new([
            record("a-cur", "cur", lifecycle::PHASE_ACTIVE),
            record("a-old", "old", lifecycle::PHASE_SUPERSEDED),
            record("a-failed", "fail", PHASE_FAILED),
            record("a-only", "part", PHASE_PARTIAL),
            cm("stale", "old,cur"),
            cm("from-failed", "old,fail"),
            cm("from-only", "part"),
        ]);
        let client = api.client();
        let discovery = discover_resources(&client).await.unwrap();
        let records = activation::Records::open(&client, &discovery).unwrap();
        let rid = |name: &str| ResourceId::new("", "ConfigMap", "app", name);
        let (rest, held) = split_held_live(
            &client,
            &discovery,
            &records,
            vec![
                rid("stale"),
                rid("from-failed"),
                rid("from-only"),
                rid("gone"),
            ],
            "a",
        )
        .await
        .unwrap();
        assert_eq!(rest, vec![rid("stale"), rid("gone")]);
        assert_eq!(
            held,
            vec![
                HeldObject {
                    rid: rid("from-failed"),
                    records: vec!["a-failed".into()],
                },
                HeldObject {
                    rid: rid("from-only"),
                    records: vec!["a-only".into()],
                },
            ]
        );
    }

    /// Build an object read through `api_version` with uid `uid`.
    fn read_as(api_version: &str, uid: &str, name: &str) -> DynamicObject {
        let mut o = swept("Event", "ns", name, false, false);
        o.data["apiVersion"] = json!(api_version);
        o.metadata.uid = Some(uid.into());
        o
    }

    /// Kubernetes serves an Event under two API groups. The sweep keeps one
    /// copy of each object, and keeps objects with different uids apart.
    #[test]
    fn one_per_object_keeps_each_uid_once() {
        let written_through = |api_version: &str, o: DynamicObject| {
            let mut o = o;
            o.metadata.managed_fields = Some(vec![ManagedFieldsEntry {
                api_version: Some(api_version.into()),
                ..entry(crate::cluster::fieldsv1::KIX_FIELD_MANAGER, "Apply")
            }]);
            o
        };
        let group = |o: &DynamicObject| o.data["apiVersion"].as_str().unwrap().to_string();

        // Nobody's write names a group: the first copy in discovery order.
        let kept = one_per_object([
            read_as("v1", "u1", "e"),
            read_as("events.k8s.io/v1", "u1", "e"),
        ]);
        assert_eq!(kept.iter().map(group).collect::<Vec<_>>(), ["v1"]);

        // Kix applied it through `events.k8s.io`, listed second: that copy.
        let kept = one_per_object([
            written_through("events.k8s.io/v1beta1", read_as("v1", "u1", "e")),
            written_through(
                "events.k8s.io/v1beta1",
                read_as("events.k8s.io/v1", "u1", "e"),
            ),
        ]);
        assert_eq!(
            kept.iter().map(group).collect::<Vec<_>>(),
            ["events.k8s.io/v1"]
        );

        // Two objects with one name but different uids are both kept.
        let kept = one_per_object([
            read_as("v1", "u1", "e"),
            read_as("events.k8s.io/v1", "u2", "e"),
        ]);
        assert_eq!(kept.len(), 2);
    }

    /// A full sweep of a shared cluster reads an operator's Event once,
    /// although both the core group and `events.k8s.io` serve it, and sets it
    /// apart as a copy because only the operator wrote it.
    #[tokio::test]
    async fn the_sweep_lists_an_event_served_by_two_groups_once_as_a_copy() {
        use crate::cluster::fake_api::FakeApi;
        let event = |api_version: &str| {
            json!({
                "apiVersion": api_version,
                "kind": "Event",
                "metadata": {
                    "name": "orders.1a2b",
                    "namespace": "orders",
                    "uid": "event-uid",
                    "labels": {
                        "app.kubernetes.io/managed-by": "kix",
                        "app.kubernetes.io/instance": "orders",
                    },
                    "managedFields": [
                        { "manager": "stackgres-operator", "operation": "Update",
                          "apiVersion": api_version },
                    ],
                },
            })
        };
        let api = FakeApi::new([event("v1"), event("events.k8s.io/v1")]);
        let client = api.client();
        let discovery = discover_resources(&client).await.unwrap();
        let records = activation::Records::open(&client, &discovery).unwrap();
        let sweep = sweep_managed(&client, &discovery, &records, SweepScope::Cluster("a"))
            .await
            .unwrap();
        assert_eq!(names(&sweep.copies), ["orders/Event/orders.1a2b"]);
        assert!(sweep.unattributed.is_empty() && sweep.unstamped.is_empty());
        assert!(sweep.managed.is_empty());
    }

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId::new("", kind, "ns", name)
    }

    /// An object deployed by two clusters is kept when one cluster drops it
    /// while the other's current record still names it.
    #[test]
    fn an_orphan_another_cluster_still_deploys_is_kept() {
        let live = vec![
            obj("ClusterRole", "shared", "a2,b1"),
            obj("ClusterRole", "once-shared", "a2,b0"),
            obj("ConfigMap", "mine", "a2"),
        ];
        let orphans = vec![rid("ClusterRole", "shared"), rid("ConfigMap", "mine")];
        let (prune, kept) = split_shared_orphans(orphans, &live, &two_clusters("a"));
        assert_eq!(prune, vec![rid("ConfigMap", "mine")]);
        assert_eq!(
            kept,
            vec![SharedOrphan {
                rid: rid("ClusterRole", "shared"),
                clusters: vec!["b".into()],
            }]
        );
        assert_eq!(
            kept[0].describe(),
            "kept ClusterRole/shared@ns, still deployed by Kix cluster b"
        );

        // A Namespace is never pruned anyway; the prune lists it as kept.
        let ns = named(
            "Namespace",
            CLUSTER_SCOPED,
            "shared-ns",
            keys::ACTIVATIONS,
            "a2,b1",
        );
        let ns_rid = ResourceId::from_value(&to_manifest_value(&ns));
        let split = split_shared_orphans(vec![ns_rid.clone()], &[ns], &two_clusters("a"));
        assert_eq!(split, (vec![ns_rid], vec![]));

        let (prune, kept) = split_shared_orphans(
            vec![rid("ClusterRole", "shared")],
            &live,
            &two_clusters("b"),
        );
        assert!(prune.is_empty());
        assert_eq!(kept[0].clusters, vec!["a".to_string()]);

        // A Superseded record of `b` no longer deploys anything.
        let (prune, kept) = split_shared_orphans(
            vec![rid("ClusterRole", "once-shared")],
            &live,
            &two_clusters("a"),
        );
        assert_eq!(prune, vec![rid("ClusterRole", "once-shared")]);
        assert!(kept.is_empty());
    }
}
