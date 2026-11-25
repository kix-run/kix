//! Read what each Kix cluster's current deploy left on a Kubernetes cluster.
//!
//! [`observe`] reads the deploy records and lists Kix's objects once, then
//! gives three facts for every object the current deploy should have:
//!
//! - presence: is the object on the cluster ([`Presence`]),
//! - content: does it still hold what Kix applied ([`DriftVerdict`]),
//! - readiness: is it ready by the rules a deploy waits on ([`Readiness`]).
//!
//! The objects a deploy should have come from its record's package index,
//! which every machine can read. A record written before Kix stored the index
//! falls back to following `kix.run/depends-on` from the record's own object.
//! The index also names each object. For a record without names, Kix names a
//! missing object from the local Nix store when the build is there.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use kube::api::DynamicObject;
use kube::client::Client;
use kube::discovery::{ApiResource, Scope};

use super::activation::{OpenedRecords, Record};
use super::drift::{self, DriftVerdict};
use super::errors::FetchError;
use super::inventory;
use super::readiness;
use crate::eval::package_index::{IndexedName, ObjectName};
use crate::eval::store_graph::{self, StoreEntry};
use crate::manifest::keys;
use crate::manifest::lifecycle::{Lifecycle, lifecycle_of_live};
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

/// Which Kix clusters [`observe`] reads.
#[derive(Debug, Clone, Copy)]
pub enum ObserveScope<'a> {
    /// One Kix cluster, by the name its records carry.
    Cluster(&'a str),
    /// Every Kix cluster that has a current deploy record.
    All,
}

/// What [`observe`] read.
#[derive(Debug, Clone)]
pub struct Observation {
    /// One view for each Kix cluster in scope that has a current record,
    /// sorted by cluster name.
    pub clusters: Vec<ClusterView>,
    /// Resource types this account may not list, such as `secrets`. Objects
    /// of these kinds are [`Presence::Unknown`] when Kix cannot see them.
    pub unreadable: Vec<String>,
}

/// One Kix cluster's current deploy and its objects.
#[derive(Debug, Clone)]
pub struct ClusterView {
    pub cluster: String,
    /// The current (`Active` or `Degraded`) deploy record.
    pub record: Record,
    /// Where the list of expected objects came from.
    pub expected_from: ExpectedFrom,
    /// Every object the current deploy should have, once, in the order of the
    /// record's index.
    pub objects: Vec<ObjectView>,
    /// Objects of this Kix cluster that are not in the current deploy and are
    /// being deleted, sorted by id. A prune deleted them, or someone did, and
    /// a finalizer or a slow shutdown still holds them.
    pub leaving: Vec<Leaving>,
}

/// An object of a Kix cluster that left its build and is still being
/// deleted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Leaving {
    pub rid: ResourceId,
    /// The package the object belonged to, keyed `namespace/instance`, or
    /// `None` for a cluster-level object.
    pub package: Option<String>,
    pub deleting: Deleting,
}

/// An object's deletion that has not finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deleting {
    /// The object's `metadata.deletionTimestamp` (RFC 3339).
    pub since: String,
    /// The finalizers that still hold it.
    pub finalizers: Vec<String>,
}

impl Deleting {
    /// Return the deletion of `obj`, or `None` when it is not being deleted.
    pub fn of(obj: &DynamicObject) -> Option<Deleting> {
        let since = obj.metadata.deletion_timestamp.as_ref()?;
        Some(Deleting {
            since: serde_json::to_value(since)
                .ok()
                .and_then(|t| t.as_str().map(str::to_string))
                .unwrap_or_default(),
            finalizers: readiness::finalizers_of(obj),
        })
    }
}

/// Where [`ClusterView::objects`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExpectedFrom {
    /// The record's package index.
    Index,
    /// The `kix.run/depends-on` annotations of live objects, starting at the
    /// record's own object. Used for a record without an index.
    DependsOn,
    /// Neither. The record has no index and its object is not on the
    /// cluster, so Kix cannot tell which objects the deploy made.
    Nothing,
}

/// One object of a deploy.
#[derive(Debug, Clone)]
pub struct ObjectView {
    /// `kix.run/identity-hash` of the object in the deploy's build.
    pub identity_hash: String,
    /// The object's kind, namespace, and name. When Kix cannot name a missing
    /// object, the kind is `Unknown` and `named` is false.
    pub rid: ResourceId,
    pub named: bool,
    /// The package the object belongs to, keyed `namespace/instance`, or
    /// `None` for a cluster-level object.
    pub package: Option<String>,
    pub presence: Presence,
    /// The drift check of the live object. `None` when it is not on the
    /// cluster.
    pub content: Option<DriftVerdict>,
    pub readiness: Readiness,
    /// The object's deletion when it is being deleted. Its readiness is then
    /// [`Readiness::NotReady`].
    pub deleting: Option<Deleting>,
    /// Identity hashes of the deploy's objects that this object depends on,
    /// from its live `kix.run/depends-on`.
    pub depends_on: Vec<String>,
}

/// Whether an object is on the cluster.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Presence {
    Present,
    /// An import marker: a `PackageInstance` that stands for an object Kix
    /// does not manage. The marker is on the cluster.
    External,
    /// Kix can read the object's kind, and the cluster has no object with its
    /// identity hash or its name.
    Missing,
    /// The object is not on the cluster under its identity hash, and Kix
    /// cannot look it up by name. Its record was written before records
    /// stored each object's API group, and more than one group the cluster
    /// serves has a kind of that name.
    Ambiguous,
    /// The account may not list the object's kind, so Kix cannot tell.
    Unknown,
}

/// Whether an object is ready.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    /// Not ready, with the reason in a few words, such as `0/1 ready`.
    NotReady(String),
    /// The kind has no readiness, as a ConfigMap, or the object is not on the
    /// cluster.
    NotApplicable,
}

impl ClusterView {
    /// Return the objects that depend directly on the object with identity
    /// hash `hash`.
    pub fn needed_by(&self, hash: &str) -> Vec<&ObjectView> {
        self.objects
            .iter()
            .filter(|o| o.depends_on.iter().any(|d| d == hash))
            .collect()
    }
}

/// Return the identity hashes of the objects on the cluster that depend,
/// directly or through other objects, on a [`Presence::Missing`] object.
pub fn at_risk(view: &ClusterView) -> BTreeSet<String> {
    let mut broken: HashSet<&str> = view
        .objects
        .iter()
        .filter(|o| o.presence == Presence::Missing)
        .map(|o| o.identity_hash.as_str())
        .collect();
    let mut out = BTreeSet::new();
    loop {
        let found: Vec<&str> = view
            .objects
            .iter()
            .filter(|o| {
                o.presence != Presence::Missing && !broken.contains(o.identity_hash.as_str())
            })
            .filter(|o| o.depends_on.iter().any(|d| broken.contains(d.as_str())))
            .map(|o| o.identity_hash.as_str())
            .collect();
        if found.is_empty() {
            return out;
        }
        for hash in found {
            broken.insert(hash);
            out.insert(hash.to_string());
        }
    }
}

/// Read the current deploy records in `scope` and list Kix's objects once,
/// and return what each deploy should have and what the cluster holds.
///
/// The records are read before the objects. A deploy applies its objects
/// before its record becomes current, so every object a record read here
/// lists is on the cluster when the objects are listed, unless it is gone.
pub async fn observe(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    records: &OpenedRecords,
    scope: ObserveScope<'_>,
) -> Result<Observation, FetchError> {
    let mut current = match records.records() {
        Some(records) => records
            .all_current()
            .await
            .map_err(FetchError::RecordsError)?,
        None => BTreeMap::new(),
    };
    if let ObserveScope::Cluster(cluster) = scope {
        current.retain(|name, _| name == cluster);
    }
    let sweep =
        inventory::sweep_managed(client, discovery, records, inventory::SweepScope::All).await?;
    let apis = Apis::of(discovery, &sweep.forbidden);
    let live = Live::of(&sweep.managed);
    let clusters = current
        .into_iter()
        .map(|(cluster, record)| {
            let mut view = view(cluster, record, &live, &apis, |hashes| {
                store_graph::lookup_hashes(hashes.iter().copied())
            });
            view.leaving = leaving(&view, &sweep.managed, |obj| sweep.tenancy.owners_of(obj));
            view
        })
        .collect();
    Ok(Observation {
        clusters,
        unreadable: sweep.forbidden,
    })
}

/// The APIs the cluster serves, as [`view`] needs them.
#[derive(Debug, Default)]
struct Apis {
    /// `(group, kind)` of each API this account may not list.
    unreadable: HashSet<(String, String)>,
    /// The API groups that serve each kind.
    groups_by_kind: HashMap<String, BTreeSet<String>>,
}

impl Apis {
    /// Index `discovery`, where `forbidden` names the resources (as
    /// [`inventory::resource_fqn`] writes them) this account may not list.
    fn of(discovery: &[(ApiResource, Scope)], forbidden: &[String]) -> Apis {
        let mut apis = Apis::default();
        for (ar, _) in discovery {
            apis.groups_by_kind
                .entry(ar.kind.clone())
                .or_default()
                .insert(ar.group.clone());
            if forbidden.contains(&inventory::resource_fqn(ar)) {
                apis.unreadable.insert((ar.group.clone(), ar.kind.clone()));
            }
        }
        apis
    }

    /// Return the id of an object that an index written before indexes
    /// stored groups names. Its group is the one group that serves its kind.
    /// Return `None` when several groups serve the kind. When none does, the
    /// object cannot be on the cluster, and the id takes the core group.
    fn resolve(&self, name: &ObjectName) -> Option<ResourceId> {
        let groups = self.groups_by_kind.get(&name.0);
        match groups.map_or(0, BTreeSet::len) {
            0 => Some(name.resource_id("")),
            1 => groups
                .and_then(|g| g.first())
                .map(|group| name.resource_id(group)),
            _ => None,
        }
    }
}

/// The objects a sweep found, indexed for [`view`].
struct Live<'a> {
    by_hash: HashMap<&'a str, &'a DynamicObject>,
    by_rid: HashMap<ResourceId, &'a DynamicObject>,
}

impl<'a> Live<'a> {
    fn of(objects: &'a [DynamicObject]) -> Live<'a> {
        Live {
            by_hash: objects
                .iter()
                .filter_map(|o| Some((annotation(o, keys::IDENTITY_HASH)?, o)))
                .collect(),
            by_rid: objects.iter().map(|o| (drift::resource_id(o), o)).collect(),
        }
    }
}

/// One expected object before it is checked.
struct Expected {
    hash: String,
    package: Option<String>,
}

/// Build the view of one cluster's current deploy from the live objects.
///
/// `lookup` names identity hashes from the local store (see
/// [`store_graph::lookup_hashes`]). It runs at most once, and only for a
/// record without names.
fn view(
    cluster: String,
    record: Record,
    live: &Live<'_>,
    apis: &Apis,
    lookup: impl FnOnce(&[&str]) -> HashMap<String, StoreEntry>,
) -> ClusterView {
    let root = record.identity_hash.clone().unwrap_or_default();
    let (expected_from, mut expected) = match &record.package_index {
        Some(index) => {
            let mut out = Vec::new();
            for (key, package) in &index.packages {
                for hash in std::iter::once(&package.instance).chain(&package.resources) {
                    out.push(Expected {
                        hash: hash.clone(),
                        package: Some(key.clone()),
                    });
                }
            }
            out.extend(index.cluster_level.iter().map(|hash| Expected {
                hash: hash.clone(),
                package: None,
            }));
            (ExpectedFrom::Index, out)
        }
        None if live.by_hash.contains_key(root.as_str()) => (ExpectedFrom::DependsOn, Vec::new()),
        None => (ExpectedFrom::Nothing, Vec::new()),
    };

    // Without an index, follow `kix.run/depends-on` from the record. A
    // dependency with no live object may be a file such as a Secret's SOPS
    // source, which the annotation also lists. The local store tells files
    // from objects when it has the build.
    let mut store: Option<HashMap<String, StoreEntry>> = None;
    let mut lookup = Some(lookup);
    if expected_from == ExpectedFrom::DependsOn {
        let (found, unresolved) = walk_depends_on(&root, live);
        let wanted: Vec<&str> = unresolved.keys().map(String::as_str).collect();
        let entries = lookup.take().map(|f| f(&wanted)).unwrap_or_default();
        for obj in found {
            expected.push(Expected {
                hash: annotation(obj, keys::IDENTITY_HASH)
                    .unwrap_or_default()
                    .to_string(),
                package: package_of(obj),
            });
        }
        for (dep, sops_sources) in &unresolved {
            let not_object =
                matches!(entries.get(dep), Some(StoreEntry::Other)) || sops_sources.contains(dep);
            if !not_object {
                expected.push(Expected {
                    hash: dep.clone(),
                    package: None,
                });
            }
        }
        store = Some(entries);
    }

    let mut seen = HashSet::new();
    expected.retain(|e| e.hash != root && seen.insert(e.hash.clone()));

    // Name each object: from the index, else from its live object, else from
    // the local store.
    let index_name = |hash: &str| record.package_index.as_ref()?.name_of(hash);
    let unnamed: Vec<&str> = expected
        .iter()
        .filter(|e| index_name(&e.hash).is_none() && !live.by_hash.contains_key(e.hash.as_str()))
        .map(|e| e.hash.as_str())
        .collect();
    let store = match (store, lookup) {
        (Some(store), _) => store,
        (None, Some(lookup)) if !unnamed.is_empty() => lookup(&unnamed),
        _ => HashMap::new(),
    };

    let expected_hashes: HashSet<&str> = expected.iter().map(|e| e.hash.as_str()).collect();
    let objects = expected
        .iter()
        .map(|e| {
            let by_hash = live.by_hash.get(e.hash.as_str()).copied();
            // An index written before indexes stored groups names an object
            // without its group. The live object says it, and otherwise the
            // one group that serves the kind does.
            let mut ambiguous = None;
            let name = match index_name(&e.hash) {
                Some(IndexedName::Named(rid)) => Some(rid),
                Some(IndexedName::GroupUnknown(name)) => match (by_hash, apis.resolve(&name)) {
                    (Some(o), _) => Some(drift::resource_id(o)),
                    (None, Some(rid)) => Some(rid),
                    (None, None) => {
                        ambiguous = Some(name.resource_id(""));
                        None
                    }
                },
                None => by_hash
                    .map(drift::resource_id)
                    .or_else(|| match store.get(&e.hash) {
                        Some(StoreEntry::Resource(rid)) => Some(rid.clone()),
                        _ => None,
                    }),
            };
            // An older version of the object is live under another identity
            // hash, which a deploy that failed partway can leave. It is not
            // missing.
            let obj =
                by_hash.or_else(|| name.as_ref().and_then(|rid| live.by_rid.get(rid)).copied());
            let unreadable = match &name {
                Some(rid) => apis
                    .unreadable
                    .contains(&(rid.group.clone(), rid.kind.clone())),
                None => !apis.unreadable.is_empty(),
            };
            let deleting = obj.and_then(Deleting::of);
            let (presence, content, readiness, depends_on) = match obj {
                Some(obj) => {
                    let marker = lifecycle_of_live(obj) == Lifecycle::Marker;
                    let depends_on = depends_on(obj)
                        .filter(|d| expected_hashes.contains(d))
                        .map(str::to_string)
                        .collect();
                    (
                        if marker {
                            Presence::External
                        } else {
                            Presence::Present
                        },
                        Some(drift::check_object(obj).verdict),
                        if marker {
                            Readiness::NotApplicable
                        } else {
                            readiness_of(obj)
                        },
                        depends_on,
                    )
                }
                None if ambiguous.is_some() => {
                    (Presence::Ambiguous, None, Readiness::NotApplicable, vec![])
                }
                None if unreadable => (Presence::Unknown, None, Readiness::NotApplicable, vec![]),
                None => (Presence::Missing, None, Readiness::NotApplicable, vec![]),
            };
            let name = name.or(ambiguous);
            ObjectView {
                named: name.is_some(),
                rid: name.unwrap_or_else(|| unnamed_rid(&e.hash)),
                identity_hash: e.hash.clone(),
                package: e.package.clone(),
                presence,
                content,
                readiness,
                deleting,
                depends_on,
            }
        })
        .collect();

    ClusterView {
        cluster,
        record,
        expected_from,
        objects,
        leaving: Vec::new(),
    }
}

/// Return the objects of `live` that belong to `view`'s Kix cluster, are not
/// among the objects of its current deploy, and are being deleted. `owners`
/// names the Kix clusters an object belongs to.
fn leaving(
    view: &ClusterView,
    live: &[DynamicObject],
    owners: impl Fn(&DynamicObject) -> Vec<String>,
) -> Vec<Leaving> {
    let hashes: HashSet<&str> = view
        .objects
        .iter()
        .map(|o| o.identity_hash.as_str())
        .collect();
    let rids: HashSet<&ResourceId> = view.objects.iter().map(|o| &o.rid).collect();
    let mut out: Vec<Leaving> = live
        .iter()
        .filter(|obj| !annotation(obj, keys::IDENTITY_HASH).is_some_and(|h| hashes.contains(h)))
        .filter(|obj| !rids.contains(&drift::resource_id(obj)))
        .filter_map(|obj| Some((obj, Deleting::of(obj)?)))
        .filter(|(obj, _)| owners(obj).contains(&view.cluster))
        .map(|(obj, deleting)| Leaving {
            rid: drift::resource_id(obj),
            package: package_of(obj),
            deleting,
        })
        .collect();
    out.sort_by(|a, b| a.rid.cmp(&b.rid));
    out
}

/// Follow `kix.run/depends-on` from the live object with identity hash
/// `root`. Return the live objects reached, and each dependency hash with no
/// live object together with the SOPS source hashes of the objects that
/// named it.
fn walk_depends_on<'a>(
    root: &str,
    live: &Live<'a>,
) -> (Vec<&'a DynamicObject>, BTreeMap<String, HashSet<String>>) {
    let mut found = Vec::new();
    let mut unresolved: BTreeMap<String, HashSet<String>> = BTreeMap::new();
    let mut visited: HashSet<&str> = HashSet::from([root]);
    let mut queue = vec![root.to_string()];
    while let Some(hash) = queue.pop() {
        let Some(obj) = live.by_hash.get(hash.as_str()).copied() else {
            continue;
        };
        if hash != root {
            found.push(obj);
        }
        let sops = annotation(obj, keys::SOPS_SOURCE)
            .map(|p| store_graph::store_hash(std::path::Path::new(p)))
            .filter(|h| !h.is_empty());
        for dep in depends_on(obj) {
            match live.by_hash.get_key_value(dep) {
                Some((&key, _)) => {
                    if visited.insert(key) {
                        queue.push(key.to_string());
                    }
                }
                None => {
                    let entry = unresolved.entry(dep.to_string()).or_default();
                    entry.extend(sops.clone());
                }
            }
        }
    }
    (found, unresolved)
}

/// Return the readiness of a live object by the rules a deploy waits on. An
/// object being deleted is not ready, even of a kind that has no readiness.
fn readiness_of(obj: &DynamicObject) -> Readiness {
    let rid = drift::resource_id(obj);
    let kind = rid.group_kind();
    if let Some(reason) = readiness::deletion_reason(obj) {
        Readiness::NotReady(reason)
    } else if readiness::is_immediate(kind, &obj.data) {
        Readiness::NotApplicable
    } else if readiness::check_readiness(obj, kind) {
        Readiness::Ready
    } else {
        Readiness::NotReady(readiness::not_ready_reason(obj, kind))
    }
}

fn depends_on(obj: &DynamicObject) -> impl Iterator<Item = &str> {
    keys::depends_on_hashes(annotation(obj, keys::DEPENDS_ON).unwrap_or(""))
}

fn package_of(obj: &DynamicObject) -> Option<String> {
    keys::package_of_meta(obj.metadata.annotations.as_ref()?)
}

fn annotation<'a>(obj: &'a DynamicObject, key: &str) -> Option<&'a str> {
    keys::get_meta(obj.metadata.annotations.as_ref()?, key)
}

/// Return the placeholder for an object Kix cannot name, which shows the
/// start of its identity hash.
fn unnamed_rid(hash: &str) -> ResourceId {
    ResourceId {
        group: String::new(),
        kind: "Unknown".to_string(),
        namespace: CLUSTER_SCOPED.to_string(),
        name: format!("(hash: {}...)", &hash[..12.min(hash.len())]),
    }
}

#[cfg(test)]
#[path = "observe_tests.rs"]
mod tests;
