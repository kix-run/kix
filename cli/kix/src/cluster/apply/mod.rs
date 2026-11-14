//! Apply resources with server-side apply and local DAG change detection.
//!
//! Uses server-side apply (`Patch::Apply`) with `kix` as the field manager.
//! Change detection diffs two sets of stamped manifests locally by comparing
//! identity-hashes, without querying the live cluster. A Job under the rerun
//! rule is recreated only when its content hash changed or its last run
//! failed (see [`changed`]).

mod ssa;
#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet};

use crate::manifest::keys;
use crate::manifest::lifecycle::{is_record, lifecycle_of, lifecycle_of_live};
#[cfg(test)]
use crate::manifest::types::CLUSTER_SCOPED;
use crate::manifest::types::ResourceId;
use kube::api::DynamicObject;
use serde_json::Value;

pub use ssa::{ApplyAction, ApplyError, ApplyPreview, namespaceless};
pub(crate) use ssa::{
    ApplyResult, Seg, apply_resource, ceded_fields, record_activation_on_skipped,
};
#[cfg(test)]
use ssa::{
    conflict_paths, is_immutable_field_message, is_stored_version_message, merge_activation_set,
    parse_path, without_ceded_conflicts,
};

/// Return `true` if `manifest` is a `Job` with `kix.run/rerun: on-change`.
///
/// Only `Job` resources support the rerun rule because rerunning deletes the
/// live object before re-creating it; deleting a rollout-based workload such as
/// a `Deployment` would cause an outage rather than a retry.
pub(crate) fn wants_rerun(manifest: &Value) -> bool {
    manifest.get("kind").and_then(Value::as_str) == Some("Job")
        && manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(keys::RERUN))
            .and_then(Value::as_str)
            == Some(keys::RERUN_ON_CHANGE)
}

/// Why a Job under the rerun rule runs again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RerunReason {
    /// No build this cluster ran has it, so there is normally nothing to
    /// delete first.
    New,
    /// Its `kix.run/rerun-hash` differs from the one it was last deployed
    /// with, or Kix has no record of that value.
    Changed,
    /// Its live object shows that its last run failed.
    LastRunFailed,
}

impl RerunReason {
    /// Return the reason as the deploy log and the plan state it.
    pub fn as_str(self) -> &'static str {
        match self {
            RerunReason::New => "new to this cluster",
            RerunReason::Changed => "changed since the last run",
            RerunReason::LastRunFailed => "the last run failed",
        }
    }
}

/// Change action determined by diffing the old and new activations.
#[derive(Debug, Clone)]
pub enum ChangeAction {
    /// Resource is new or changed and needs to be applied.
    Apply(Value),
    /// Job under the rerun rule that is new, whose own content changed, or
    /// whose last run failed. It is deleted and created again so that it
    /// runs again.
    Recreate(Value, RerunReason),
    /// Resource has the same identity-hash and can be skipped.
    Skip(ResourceId),
    /// Resource exists in the old activation but not the new one and is a
    /// candidate for pruning.
    Orphan(ResourceId),
}

impl ChangeAction {
    /// Return the manifest this action writes, if it writes one.
    pub fn written(&self) -> Option<&Value> {
        match self {
            ChangeAction::Apply(m) | ChangeAction::Recreate(m, _) => Some(m),
            ChangeAction::Skip(_) | ChangeAction::Orphan(_) => None,
        }
    }
}

/// Return the `kix.run/identity-hash` annotation from a manifest, if present.
fn manifest_identity_hash(manifest: &Value) -> Option<&str> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::IDENTITY_HASH))
        .and_then(Value::as_str)
}

/// Return the `kix.run/rerun-hash` annotation from a manifest, if present.
fn manifest_rerun_hash(manifest: &Value) -> Option<&str> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::RERUN_HASH))
        .and_then(Value::as_str)
}

/// What the cluster's deployed state holds for an object.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Deployed<'a> {
    /// Nothing: the object is new to the cluster.
    Nothing,
    /// The object, with the `kix.run/rerun-hash` it was deployed with, or
    /// `None` when that value is not known.
    RerunHash(Option<&'a str>),
}

/// Return the action for `manifest`, which is new, differs from what was
/// last deployed, or is a Job whose last run failed. This is the one place
/// that decides whether a Job under the rerun rule runs again.
///
/// Such a Job is recreated when `last_run_failed` says its live object
/// failed, which the plan reads from the cluster (see
/// `DeployPlan::rerun_failed`). A new Job takes the same path, so the
/// engine replaces a Job of that name that no build recorded. Otherwise the
/// Job is recreated when its `kix.run/rerun-hash` differs from the value
/// `deployed` holds. A change that leaves its own content alone, such as a
/// new label on its namespace, applies it in place. A Job that a release
/// before 0.10 deployed has no old value and is recreated.
pub(crate) fn changed(
    manifest: &Value,
    deployed: Deployed<'_>,
    last_run_failed: bool,
) -> ChangeAction {
    if !wants_rerun(manifest) {
        return ChangeAction::Apply(manifest.clone());
    }
    let content = manifest_rerun_hash(manifest);
    let reason = match deployed {
        _ if last_run_failed => RerunReason::LastRunFailed,
        Deployed::Nothing => RerunReason::New,
        Deployed::RerunHash(old) if old.is_none() || content != old => RerunReason::Changed,
        Deployed::RerunHash(_) => return ChangeAction::Apply(manifest.clone()),
    };
    ChangeAction::Recreate(manifest.clone(), reason)
}

/// Annotations the CLI stamps from the build's package index. They are not
/// part of the identity hash, so an object whose content is unchanged is
/// still applied when one of them differs, and the live object keeps the
/// owner the current build names. Activation records are exempt: the deploy
/// writes them itself, and an unchanged build must skip everything.
const OWNER_STAMPS: [&str; 3] = [keys::PACKAGE, keys::PACKAGE_NAMESPACE, keys::LIFECYCLE];

/// Return the owner stamps of a manifest, in `OWNER_STAMPS` order.
fn owner_stamps(manifest: &Value) -> [Option<&str>; 3] {
    let annotations = manifest.pointer("/metadata/annotations");
    OWNER_STAMPS.map(|key| annotations.and_then(|a| a.get(key)).and_then(Value::as_str))
}

/// Return the owner stamps of a live object, in `OWNER_STAMPS` order.
fn live_owner_stamps(obj: &DynamicObject) -> [Option<&str>; 3] {
    let annotations = obj.metadata.annotations.as_ref();
    OWNER_STAMPS.map(|key| annotations.and_then(|a| keys::get_meta(a, key)))
}

/// Detect changes by diffing two sets of stamped manifests locally.
///
/// Matches resources by Kubernetes identity (`kind/namespace/name`) and
/// compares `kix.run/identity-hash` annotations to determine whether content
/// changed, and the owner stamps (`OWNER_STAMPS`) to determine whether the
/// annotations need rewriting. Returns [`ChangeAction::Apply`] or
/// [`ChangeAction::Skip`] for each manifest in `new_manifests`, followed by
/// [`ChangeAction::Orphan`] for prunable stamped resources present in
/// `old_manifests` but absent from `new_manifests`.
pub(crate) fn detect_changes(
    new_manifests: &[Value],
    old_manifests: &[Value],
) -> Vec<ChangeAction> {
    // Keep the previous deploy's Activation record in this index so an
    // unchanged build (same record name and hash) produces Skip and can
    // short-circuit; records are excluded from the orphan set below.
    let old_by_k8s_id: HashMap<String, &Value> = old_manifests
        .iter()
        .filter_map(|m| {
            let rid = ResourceId::from_value(m);
            let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
            manifest_identity_hash(m)?;
            Some((k8s_id, m))
        })
        .collect();

    let mut matched_old_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut actions: Vec<ChangeAction> = Vec::new();

    for manifest in new_manifests {
        let rid = ResourceId::from_value(manifest);
        let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);

        let new_hash = manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(keys::IDENTITY_HASH))
            .and_then(Value::as_str);

        match (old_by_k8s_id.get(&k8s_id), new_hash) {
            (Some(old), Some(new_h))
                if manifest_identity_hash(old) == Some(new_h)
                    && (is_record(manifest) || owner_stamps(old) == owner_stamps(manifest)) =>
            {
                matched_old_ids.insert(k8s_id);
                actions.push(ChangeAction::Skip(rid));
            }
            (Some(old), _) => {
                matched_old_ids.insert(k8s_id);
                actions.push(changed(
                    manifest,
                    Deployed::RerunHash(manifest_rerun_hash(old)),
                    false,
                ));
            }
            (None, _) => {
                actions.push(changed(manifest, Deployed::Nothing, false));
            }
        }
    }

    // Only stamped, prunable resources can become orphans. Unstamped manifests
    // may belong to controller children or external tools, and Activation
    // records are superseded during finalization rather than pruned here.
    for old_manifest in old_manifests {
        if manifest_identity_hash(old_manifest).is_none() || !lifecycle_of(old_manifest).prunable()
        {
            continue;
        }
        let rid = ResourceId::from_value(old_manifest);
        let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
        if !matched_old_ids.contains(&k8s_id) {
            actions.push(ChangeAction::Orphan(rid));
        }
    }

    actions
}

/// Fold the closures of partially applied `Failed` deploys into a change plan.
///
/// When a prior deploy stopped mid-wave, it may have created or modified some
/// resources before aborting without updating the `Active` record. Diffing
/// only against the `Active` closure would miss those partial changes.
///
/// For each resource in `failed_closures`:
/// * A [`ChangeAction::Skip`] whose resource appears in a failed closure with a
///   different identity hash is promoted to [`changed`] so the desired
///   manifest is re-asserted if the failed deploy overwrote it. A Job under
///   the rerun rule keeps its last run only when every failed closure holds
///   it with the content hash the new build gives it.
/// * A stamped, prunable resource that appears only in `failed_closures` and
///   not in `new_manifests` is added as [`ChangeAction::Orphan`].
pub(crate) fn fold_failed_closures(
    actions: Vec<ChangeAction>,
    new_manifests: &[Value],
    failed_closures: &[Vec<Value>],
) -> Vec<ChangeAction> {
    if failed_closures.is_empty() {
        return actions;
    }

    let id_of = |m: &Value| {
        let rid = ResourceId::from_value(m);
        format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
    };

    let mut uncertain: HashMap<String, HashSet<String>> = HashMap::new();
    let mut failed_content: HashMap<String, HashSet<Option<&str>>> = HashMap::new();
    let mut failed_manifest: HashMap<String, &Value> = HashMap::new();
    for closure in failed_closures {
        for manifest in closure {
            let Some(hash) = manifest_identity_hash(manifest) else {
                continue;
            };
            let id = id_of(manifest);
            uncertain
                .entry(id.clone())
                .or_default()
                .insert(hash.to_string());
            failed_content
                .entry(id.clone())
                .or_default()
                .insert(manifest_rerun_hash(manifest));
            failed_manifest.entry(id).or_insert(manifest);
        }
    }

    let new_by_id: HashMap<String, &Value> = new_manifests.iter().map(|m| (id_of(m), m)).collect();

    let mut out: Vec<ChangeAction> = Vec::with_capacity(actions.len());
    let mut seen_orphans: HashSet<String> = HashSet::new();

    for action in actions {
        match action {
            ChangeAction::Skip(rid) => {
                let id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
                let new_hash = new_by_id.get(&id).and_then(|m| manifest_identity_hash(m));
                let all_agree = match (uncertain.get(&id), new_hash) {
                    (None, _) => true,
                    (Some(hashes), Some(h)) => hashes.iter().all(|candidate| candidate == h),
                    (Some(_), None) => true,
                };
                if all_agree {
                    out.push(ChangeAction::Skip(rid));
                } else {
                    match new_by_id.get(&id) {
                        Some(manifest) => {
                            // The live Job holds the content of one of the
                            // failed closures, so it is known only when they
                            // all agree with the new build.
                            let content = manifest_rerun_hash(manifest);
                            let old_content = failed_content
                                .get(&id)
                                .is_some_and(|c| c.iter().all(|h| *h == content))
                                .then_some(content)
                                .flatten();
                            out.push(changed(manifest, Deployed::RerunHash(old_content), false));
                        }
                        None => out.push(ChangeAction::Skip(rid)),
                    }
                }
            }
            ChangeAction::Orphan(rid) => {
                seen_orphans.insert(format!("{}/{}/{}", rid.kind, rid.namespace, rid.name));
                out.push(ChangeAction::Orphan(rid));
            }
            other => out.push(other),
        }
    }

    // Sort leftover orphans for deterministic plan output.
    let mut leftovers: Vec<&String> = uncertain
        .keys()
        .filter(|id| !new_by_id.contains_key(*id) && !seen_orphans.contains(*id))
        .collect();
    leftovers.sort();
    for id in leftovers {
        let manifest = failed_manifest[id];
        if !lifecycle_of(manifest).prunable() {
            continue;
        }
        out.push(ChangeAction::Orphan(ResourceId::from_value(manifest)));
    }

    out
}

/// Add orphans from builds listed in `status.orphansKeptFrom` to `actions`.
///
/// Because each closure in `kept_closures` was previously superseded by a
/// completed deploy, shared resources are already represented in the `Active`
/// closure and do not need to be promoted from `Skip` to `Apply`. Only stamped,
/// prunable resources absent from `new_manifests` are added as
/// [`ChangeAction::Orphan`].
pub(crate) fn fold_kept_closures(
    mut actions: Vec<ChangeAction>,
    new_manifests: &[Value],
    kept_closures: &[Vec<Value>],
) -> Vec<ChangeAction> {
    let id_of = |rid: &ResourceId| format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
    let new_ids: HashSet<String> = new_manifests
        .iter()
        .map(|m| id_of(&ResourceId::from_value(m)))
        .collect();
    let mut seen: HashSet<String> = actions
        .iter()
        .filter_map(|a| match a {
            ChangeAction::Orphan(rid) => Some(id_of(rid)),
            _ => None,
        })
        .collect();
    let mut added: Vec<ResourceId> = Vec::new();
    for manifest in kept_closures.iter().flatten() {
        if manifest_identity_hash(manifest).is_none() || !lifecycle_of(manifest).prunable() {
            continue;
        }
        let rid = ResourceId::from_value(manifest);
        let id = id_of(&rid);
        if !new_ids.contains(&id) && seen.insert(id) {
            added.push(rid);
        }
    }
    added.sort();
    actions.extend(added.into_iter().map(ChangeAction::Orphan));
    actions
}

/// Return `true` if `closure` contains any stamped, prunable resource (excluding
/// `never_pruned` kinds) that is absent from `new_manifests`.
///
/// Used when a deploy keeps orphans so `status.orphansKeptFrom` records only
/// builds that still have unpruned resources on the cluster.
pub(crate) fn leaves_orphans(closure: &[Value], new_manifests: &[Value]) -> bool {
    let id_of = |m: &Value| {
        let rid = ResourceId::from_value(m);
        format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
    };
    let new_ids: HashSet<String> = new_manifests.iter().map(id_of).collect();
    closure.iter().any(|m| {
        manifest_identity_hash(m).is_some()
            && lifecycle_of(m).prunable()
            && !crate::manifest::lifecycle::never_pruned(&ResourceId::from_value(m).kind)
            && !new_ids.contains(&id_of(m))
    })
}

/// Return the baseline manifest set combining `active` with any manifests that
/// appear only in `failed`.
///
/// Provides manifests for orphans originating from failed deploys so they can
/// be topologically sorted for pruning and rendered in plan output.
pub(crate) fn baseline_manifests(active: &[Value], failed: &[Vec<Value>]) -> Vec<Value> {
    let id_of = |m: &Value| {
        let rid = ResourceId::from_value(m);
        format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
    };
    let mut seen: HashSet<String> = active.iter().map(id_of).collect();
    let mut out = active.to_vec();
    for closure in failed {
        for manifest in closure {
            let id = id_of(manifest);
            if seen.insert(id) {
                out.push(manifest.clone());
            }
        }
    }
    out
}

/// Detect changes by comparing desired manifests against live cluster objects.
///
/// Used by the operator, where live cluster state is the baseline:
/// * Desired resources absent from `live_resources` or with a differing
///   `kix.run/identity-hash` produce [`ChangeAction::Apply`].
/// * Desired resources whose `kix.run/identity-hash` matches the live object
///   produce [`ChangeAction::Skip`].
/// * Stamped, prunable live resources absent from `desired_manifests` produce
///   [`ChangeAction::Orphan`].
pub(crate) fn detect_changes_live(
    desired_manifests: &[Value],
    live_resources: &[DynamicObject],
) -> Vec<ChangeAction> {
    // Keep live Activation records in the index so an unchanged record produces
    // Skip; records are excluded from the orphan set via `live_prunable` below.
    let mut live_by_k8s_id: HashMap<String, Option<&str>> = HashMap::new();
    let mut live_content: HashMap<String, Option<&str>> = HashMap::new();
    let mut live_stamps: HashMap<String, [Option<&str>; 3]> = HashMap::new();
    let mut live_rids: HashMap<String, ResourceId> = HashMap::new();
    let mut live_prunable: std::collections::HashSet<String> = std::collections::HashSet::new();

    for obj in live_resources {
        let kind = obj
            .data
            .get("kind")
            .and_then(|v| v.as_str())
            .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
            .unwrap_or("");
        let name = obj.metadata.name.as_deref().unwrap_or("");
        let ns = obj
            .metadata
            .namespace
            .as_deref()
            .unwrap_or(crate::manifest::types::CLUSTER_SCOPED);
        let k8s_id = format!("{kind}/{ns}/{name}");

        let hash = obj
            .metadata
            .annotations
            .as_ref()
            .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH));

        live_by_k8s_id.insert(k8s_id.clone(), hash);
        live_content.insert(
            k8s_id.clone(),
            obj.metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, keys::RERUN_HASH)),
        );
        live_stamps.insert(k8s_id.clone(), live_owner_stamps(obj));
        if lifecycle_of_live(obj).prunable() {
            live_prunable.insert(k8s_id.clone());
        }
        live_rids.insert(
            k8s_id,
            ResourceId {
                kind: kind.to_string(),
                name: name.to_string(),
                namespace: ns.to_string(),
            },
        );
    }

    let mut matched_live_ids: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut actions: Vec<ChangeAction> = Vec::new();

    for manifest in desired_manifests {
        let rid = ResourceId::from_value(manifest);
        let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);

        let desired_hash = manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(keys::IDENTITY_HASH))
            .and_then(Value::as_str);

        match (live_by_k8s_id.get(&k8s_id), desired_hash) {
            (Some(Some(live_hash)), Some(desired_h))
                if *live_hash == desired_h
                    && (is_record(manifest)
                        || live_stamps.get(&k8s_id) == Some(&owner_stamps(manifest))) =>
            {
                matched_live_ids.insert(k8s_id);
                actions.push(ChangeAction::Skip(rid));
            }
            (Some(_), _) => {
                let old_content = live_content.get(&k8s_id).copied().flatten();
                matched_live_ids.insert(k8s_id);
                actions.push(changed(manifest, Deployed::RerunHash(old_content), false));
            }
            (None, _) => {
                actions.push(changed(manifest, Deployed::Nothing, false));
            }
        }
    }

    // Only stamped, prunable live resources absent from desired manifests are orphans.
    for (k8s_id, rid) in &live_rids {
        let stamped = live_by_k8s_id.get(k8s_id).copied().flatten().is_some();
        if stamped && live_prunable.contains(k8s_id) && !matched_live_ids.contains(k8s_id) {
            actions.push(ChangeAction::Orphan(rid.clone()));
        }
    }

    actions
}
