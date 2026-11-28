//! Apply resources with server-side apply and local DAG change detection.
//!
//! Uses server-side apply (`Patch::Apply`) under the Kix cluster's own field
//! manager ([`super::field_manager`]).
//! Change detection diffs two sets of stamped manifests locally by comparing
//! object hashes, without querying the live cluster. A Job under the rerun
//! rule is recreated only when its content hash changed or its last run
//! failed (see [`changed`]).

mod ssa;
#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet};

use crate::manifest::hash::object_hash;
use crate::manifest::keys;
use crate::manifest::kinds::{self, GroupKind};
use crate::manifest::lifecycle::{self, lifecycle_of};
#[cfg(test)]
use crate::manifest::types::CLUSTER_SCOPED;
use crate::manifest::types::ResourceId;
use serde_json::Value;

pub use ssa::{ApplyAction, ApplyError, ApplyPreview, namespaceless};
pub(crate) use ssa::{
    ApplyResult, Seg, TAKEOVER_ATTEMPTS, Takeover, Takes, apply_resource, bound_to, ceded_fields,
    conflict_paths, covers, forced_manifest, remove_covered, remove_path, takes_back,
};
#[cfg(test)]
use ssa::{
    conflict_error, is_immutable_field_message, is_stored_version_message, parse_path,
    string_data_as_data, without_ceded_conflicts,
};

/// Return `true` if `manifest` is a `Job` with `kix.run/rerun: on-change`.
///
/// Only `Job` resources support the rerun rule because rerunning deletes the
/// live object before re-creating it; deleting a rollout-based workload such as
/// a `Deployment` would cause an outage rather than a retry.
pub(crate) fn wants_rerun(manifest: &Value) -> bool {
    GroupKind::of_manifest(manifest) == kinds::JOB
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
    /// Resource is unchanged and can be skipped.
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

/// Detect changes by diffing two sets of stamped manifests locally.
///
/// Matches resources by Kubernetes identity ([`ResourceId`]) and compares
/// their object hashes ([`crate::manifest::hash::object_hash`]), which a
/// deploy compares too: an object whose dependencies changed and whose own
/// manifest did not is skipped. An import marker is always skipped, because
/// Kix writes nothing for it. Returns [`ChangeAction::Apply`] or
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
    let old_by_k8s_id: HashMap<ResourceId, &Value> = old_manifests
        .iter()
        .filter_map(|m| {
            manifest_identity_hash(m)?;
            Some((ResourceId::from_value(m), m))
        })
        .collect();

    let mut matched_old_ids: HashSet<ResourceId> = HashSet::new();
    let mut actions: Vec<ChangeAction> = Vec::new();

    for manifest in new_manifests {
        let rid = ResourceId::from_value(manifest);
        // Kix writes nothing for an import marker.
        if lifecycle::is_marker(manifest) {
            actions.push(ChangeAction::Skip(rid));
            continue;
        }

        match old_by_k8s_id.get(&rid) {
            Some(old)
                if manifest_identity_hash(manifest).is_some()
                    && object_hash(old) == object_hash(manifest) =>
            {
                matched_old_ids.insert(rid.clone());
                actions.push(ChangeAction::Skip(rid));
            }
            Some(old) => {
                matched_old_ids.insert(rid);
                actions.push(changed(
                    manifest,
                    Deployed::RerunHash(manifest_rerun_hash(old)),
                    false,
                ));
            }
            None => {
                actions.push(changed(manifest, Deployed::Nothing, false));
            }
        }
    }

    // Only stamped, prunable resources can become orphans. Unstamped manifests
    // may belong to controller children or external tools, and Activation
    // records are superseded during finalization rather than pruned here. A
    // build does not make its import markers, so a marker of the old build
    // is no orphan of it.
    for old_manifest in old_manifests {
        if manifest_identity_hash(old_manifest).is_none()
            || !lifecycle_of(old_manifest).prunable()
            || lifecycle::is_marker(old_manifest)
        {
            continue;
        }
        let rid = ResourceId::from_value(old_manifest);
        if !matched_old_ids.contains(&rid) {
            actions.push(ChangeAction::Orphan(rid));
        }
    }

    actions
}

/// Return the baseline manifest set combining `active` with any manifests that
/// appear only in `failed`.
///
/// Provides manifests for orphans originating from failed deploys so they can
/// be topologically sorted for pruning and rendered in plan output.
pub(crate) fn baseline_manifests(active: &[Value], failed: &[Vec<Value>]) -> Vec<Value> {
    let mut seen: HashSet<ResourceId> = active.iter().map(ResourceId::from_value).collect();
    let mut out = active.to_vec();
    for closure in failed {
        for manifest in closure {
            if seen.insert(ResourceId::from_value(manifest)) {
                out.push(manifest.clone());
            }
        }
    }
    out
}
