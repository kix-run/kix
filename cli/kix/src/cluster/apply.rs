//! Apply resources with server-side apply and local DAG change detection.
//!
//! Uses server-side apply (`Patch::Apply`) with `kix` as the field manager.
//! Change detection diffs two sets of stamped manifests locally by comparing
//! identity-hashes, without querying the live cluster.

use std::collections::{HashMap, HashSet};

use super::errors::FailureClass;
use super::fieldsv1;
use crate::manifest::keys;
use crate::manifest::lifecycle::{lifecycle_of, lifecycle_of_live};
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

/// Does this manifest opt into the rerun rule? Jobs only: the rule deletes
/// the live object, and for anything with a rollout (a Deployment stuck on
/// its progress deadline is "failed" too) that would be an outage, not a
/// retry. The Nix side refuses the annotation on other kinds as well
/// (cross-resource check 16).
pub fn wants_rerun(manifest: &Value) -> bool {
    manifest.get("kind").and_then(Value::as_str) == Some("Job")
        && manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(keys::RERUN))
            .and_then(Value::as_str)
            == Some("on-change")
}

/// Field manager name for server-side apply.
const FIELD_MANAGER: &str = "kix";

/// Errors from apply operations.
#[derive(Error, Debug)]
pub enum ApplyError {
    #[error("failed to apply {resource}: {source}")]
    PatchFailed {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "cannot update {resource}: another tool owns fields that Kix is trying to change. \
         Review the fields listed below. If Kix should manage them, rerun with --force-conflicts to take ownership; \
         if the other tool is meant to own them, declare them on the resource with `ownership.cede`. Kubernetes reported: {source}"
    )]
    Conflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "cannot update {resource}: the change includes a field that Kubernetes does not allow to be modified. \
         To apply this change, the resource must be deleted and recreated; \
         review the impact before deleting it, then deploy again. \
         Kubernetes reported: {source}"
    )]
    ImmutableConflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "cannot update {resource}: it drops an API version that the cluster still has objects stored at. \
         Kubernetes keeps the versions it has written in the CRD's status.storedVersions, and refuses to \
         remove one until nothing is stored at it. Migrate the existing objects to a version this CRD still \
         serves (read and re-apply each one, or run a storage-version migrator), then deploy again. \
         Keeping the old version in spec.versions also unblocks the deploy. Kubernetes reported: {source}"
    )]
    CrdStoredVersion {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "could not record Kix deployment tracking annotations (activations, applied-hash) on {resource}: {source}"
    )]
    BookkeepingAnnotationsFailed {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "the Kubernetes API does not recognize resource kind '{kind}'. Check the kind and API version, and install its CRD if it is a custom resource"
    )]
    UnknownKind { kind: String },

    #[error(
        "cannot apply {resource}: it expects {expected} to exist, declared with kix.untrackedRef as created by something else, \
         and it has not appeared: {detail}. Check that the declared creator really creates it."
    )]
    ExpectationUnmet {
        resource: String,
        expected: String,
        detail: String,
    },

    #[error(
        "cannot apply {resource}: Kubernetes serves this kind as namespaced, but the manifest has no metadata.namespace. \
         Kix does not pick a namespace for it. Create it with a namespaced scope (scope.mkResource) or set metadata.namespace"
    )]
    NoNamespace { resource: String },
}

/// Is `rid` of a namespaced kind but keyed [`CLUSTER_SCOPED`], because its
/// manifest names no namespace? The apiserver would store such an object in
/// the requester's namespace, where no later comparison with the build finds
/// it, so `apply_resource` refuses it.
pub fn is_namespaceless(scope: &Scope, rid: &ResourceId) -> bool {
    matches!(scope, Scope::Namespaced) && rid.namespace == CLUSTER_SCOPED
}

/// The resources among `rids` that `apply_resource` would refuse as
/// [`ApplyError::NoNamespace`], judged by `discovery`. A kind discovery does
/// not know yet (a CRD the same deploy creates) is not reported.
pub fn namespaceless<'a>(
    discovery: &[(ApiResource, Scope)],
    rids: impl IntoIterator<Item = &'a ResourceId>,
) -> Vec<ResourceId> {
    rids.into_iter()
        .filter(|rid| {
            discovery
                .iter()
                .find(|(ar, _)| ar.kind == rid.kind)
                .is_some_and(|(_, scope)| is_namespaceless(scope, rid))
        })
        .cloned()
        .collect()
}

/// Result of applying a single resource.
#[derive(Debug, Clone)]
pub struct ApplyResult {
    /// What action was taken.
    pub action: ApplyAction,
    /// The resource that was acted upon.
    pub resource_id: ResourceId,
    /// What the apiserver answered to a dry-run apply. `None` for a real
    /// apply, and for a dry run that never reached the apiserver.
    pub preview: Option<Box<ApplyPreview>>,
}

/// The two objects a dry-run apply compares: the live object before the
/// apply and the object the apiserver says the apply would produce. Both are
/// whole objects as the apiserver serves them, `managedFields` and Secret
/// values included, so a caller that shows them must hide what is secret.
#[derive(Debug, Clone)]
pub struct ApplyPreview {
    /// `None` when the object does not exist, so the apply would create it.
    pub live: Option<Value>,
    pub result: Value,
}

/// The action taken during apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApplyAction {
    /// Resource was created (didn't exist before).
    Created,
    /// Resource was updated (identity-hash changed).
    Configured,
    /// Resource was skipped (identity-hash matched).
    Unchanged,
    /// Resource was skipped for another reason.
    Skipped,
}

/// A change action determined by local DAG diff (old vs new activation).
#[derive(Debug, Clone)]
pub enum ChangeAction {
    /// Resource needs to be applied (new or changed).
    Apply(Value),
    /// Resource is unchanged (same identity-hash), skip it.
    Skip(ResourceId),
    /// Resource exists in the old activation but not the new one; candidate for pruning.
    Orphan(ResourceId),
}

/// Detect changes by diffing two sets of stamped manifests locally.
///
/// Matches resources by Kubernetes identity (kind + namespace + name),
/// then compares identity-hashes to determine if content changed.
///
/// `new_manifests`: manifests from the new activation (what we want to deploy)
/// `old_manifests`: manifests from the old/current activation (what's deployed)
///
/// Returns actions for the new manifests (Apply or Skip) plus Orphan actions
/// for resources in old but not in new.
/// The `kix.run/identity-hash` a rendered or live-reconstructed manifest
/// carries, if kix ever applied it.
fn manifest_identity_hash(manifest: &Value) -> Option<&str> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::IDENTITY_HASH))
        .and_then(Value::as_str)
}

pub fn detect_changes(new_manifests: &[Value], old_manifests: &[Value]) -> Vec<ChangeAction> {
    // Index old manifests by K8s identity (kind/ns/name) → identity-hash.
    // The previous deploy's record stays in this index so an unchanged
    // build (same record name, same hash) still comes out as Skip and the
    // deploy can short-circuit; it is only kept out of the orphan set below.
    let old_by_k8s_id: HashMap<String, &str> = old_manifests
        .iter()
        .filter_map(|m| {
            let rid = ResourceId::from_value(m);
            let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
            let hash = m
                .pointer("/metadata/annotations")
                .and_then(|a| a.get(keys::IDENTITY_HASH))
                .and_then(Value::as_str)?;
            Some((k8s_id, hash))
        })
        .collect();

    // Track which old K8s identities are matched by new manifests
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
            (Some(&old_hash), Some(new_h)) if old_hash == new_h => {
                // Same identity-hash → identical content+deps, skip
                matched_old_ids.insert(k8s_id);
                actions.push(ChangeAction::Skip(rid));
            }
            (Some(_), _) => {
                // Different identity-hash or missing → content changed, apply
                matched_old_ids.insert(k8s_id);
                actions.push(ChangeAction::Apply(manifest.clone()));
            }
            (None, _) => {
                // Not in old graph → new resource, apply
                actions.push(ChangeAction::Apply(manifest.clone()));
            }
        }
    }

    // Only stamped resources can become orphans. An unstamped manifest may be
    // a controller child or an object applied outside Kix and must not be deleted.
    //
    // Finalization supersedes the previous deploy record. Exclude it from
    // orphan detection because each changed activation has a different name.
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

/// Fold the closures of deploys that stopped part way into a plan.
///
/// A run that dies mid-wave applied some of its closure and recorded nothing,
/// so [`detect_changes`] against the still-Active closure cannot see any of
/// it: the objects it created are not orphans, and the objects it changed do
/// not read as changed.
///
/// For a resource that differs between the active and failed closures, the
/// cluster may hold either compiler output. Apply these rules:
///
/// - A `Skip` whose identity appears in a failed closure under a DIFFERENT
///   hash becomes an `Apply`. The cluster holds either the new hash or that
///   one, and applying is idempotent, so the cost of guessing wrong is a
///   single unchanged apply. Leaving it a `Skip` when the cluster holds the
///   other one is the bug.
/// - An identity that only a failed closure has becomes an `Orphan`, under
///   the same rules [`detect_changes`] uses: stamped, prunable, and not a
///   record.
///
/// Every input is a compiler output. This function does not read live cluster
/// state when deciding how to combine closures.
pub fn fold_failed_closures(
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

    // Identity -> every hash a failed closure claims for it.
    let mut uncertain: HashMap<String, HashSet<String>> = HashMap::new();
    // Identity -> a manifest for it, for the orphan rids.
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
                    // Every hash a failed closure has for this resource is the
                    // one we are about to apply, so nothing can have changed.
                    (Some(hashes), Some(h)) => hashes.iter().all(|candidate| candidate == h),
                    // No hash on the new side means detect_changes already
                    // treated it as opaque; leave its verdict alone.
                    (Some(_), None) => true,
                };
                if all_agree {
                    out.push(ChangeAction::Skip(rid));
                } else {
                    match new_by_id.get(&id) {
                        Some(manifest) => out.push(ChangeAction::Apply((*manifest).clone())),
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

    // Anything only a failed closure knows about. Sorted so a plan is
    // byte-identical across runs.
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

/// Add the orphans of builds an earlier deploy kept orphans from
/// (`status.orphansKeptFrom`).
///
/// Every one of those builds was applied in full and then replaced, so unlike
/// [`fold_failed_closures`] nothing here can turn a `Skip` into an `Apply`:
/// the Active closure already describes every object the new build shares
/// with them. What they add is the objects the new build no longer declares,
/// under the same rules [`detect_changes`] uses: stamped, prunable, and not
/// a record.
pub fn fold_kept_closures(
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
    // Sorted so a plan is byte-identical across runs.
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

/// Whether `closure` has an object that prune would delete if `new_manifests`
/// replaced it: stamped, prunable, of a kind `never_pruned` does not protect,
/// and absent from `new_manifests` by Kubernetes identity.
///
/// A deploy that keeps its orphans records each build this is true for, so
/// the list on the record names only builds that still have something to
/// delete.
pub fn leaves_orphans(closure: &[Value], new_manifests: &[Value]) -> bool {
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

/// The manifest set a plan should show and prune against: the Active closure,
/// plus anything only a failed closure has.
///
/// `run_deploy` needs this so `prune_order` can topologically sort orphans
/// that exist in no current closure, and the plan display needs it so those
/// orphans have a manifest to describe.
pub fn baseline_manifests(active: &[Value], failed: &[Vec<Value>]) -> Vec<Value> {
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

/// Detect changes by comparing desired manifests against live cluster resources.
///
/// For each desired manifest:
///   - Look up live resource by K8s identity (kind/namespace/name)
///   - If not found → Apply (resource missing from cluster)
///   - If identity-hash differs → Apply (drifted or changed)
///   - If identity-hash matches → Skip
///
/// For each live resource not in desired set → Orphan
///
/// This replaces `detect_changes` for the operator, where the cluster
/// is the source of truth for "old state" rather than a local manifest set.
pub fn detect_changes_live(
    desired_manifests: &[Value],
    live_resources: &[DynamicObject],
) -> Vec<ChangeAction> {
    // Index live resources by K8s identity → identity-hash. Live records
    // stay in the index so an unchanged record comes out as Skip; they are
    // kept out of the orphan set below.
    let mut live_by_k8s_id: HashMap<String, Option<&str>> = HashMap::new();
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
            (Some(Some(live_hash)), Some(desired_h)) if *live_hash == desired_h => {
                // Live hash matches desired → no drift, skip
                matched_live_ids.insert(k8s_id);
                actions.push(ChangeAction::Skip(rid));
            }
            (Some(_), _) => {
                // Live exists but hash differs or missing → apply
                matched_live_ids.insert(k8s_id);
                actions.push(ChangeAction::Apply(manifest.clone()));
            }
            (None, _) => {
                // Not on cluster → apply
                actions.push(ChangeAction::Apply(manifest.clone()));
            }
        }
    }

    // An orphan is a stamped live resource absent from desired manifests.
    // Exclude unstamped objects and activation records from deletion.
    for (k8s_id, rid) in &live_rids {
        let stamped = live_by_k8s_id.get(k8s_id).copied().flatten().is_some();
        if stamped && live_prunable.contains(k8s_id) && !matched_live_ids.contains(k8s_id) {
            actions.push(ChangeAction::Orphan(rid.clone()));
        }
    }

    actions
}

/// Record this activation on a resource the deploy did NOT apply.
///
/// An unchanged resource is still part of the current activation. Add the
/// activation to `kix.run/activations` even though no content patch is needed,
/// keeping the reference set complete for garbage collection.
///
/// Leave `kix.run/applied-hash` unchanged because no content was applied.
/// Writes nothing when the annotation already says the right thing.
pub(crate) async fn record_activation_on_skipped(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    rid: &ResourceId,
    activation_hash: &str,
    live_activations: Option<&HashSet<String>>,
) -> Result<(), ApplyError> {
    let api = super::fetch::api_for(client, ar, &scope, rid);
    update_bookkeeping_annotations_checked(
        &api,
        &rid.name,
        Some(activation_hash),
        None,
        live_activations,
        rid,
    )
    .await
}

/// Apply a single resource via server-side apply.
///
/// If `activation_hash` is provided, the resource's `kix.run/activations`
/// annotation is updated to include this activation (read-modify-write).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn apply_resource(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    manifest: &Value,
    dry_run: bool,
    activation_hash: Option<&str>,
    live_activations: Option<&HashSet<String>>,
    force_conflicts: bool,
) -> Result<ApplyResult, ApplyError> {
    let rid = ResourceId::from_value(manifest);
    let name = rid.name.clone();

    tracing::info!(resource = %rid.display_id(), "applying resource");

    if is_namespaceless(&scope, &rid) {
        return Err(ApplyError::NoNamespace {
            resource: rid.display_id(),
        });
    }
    let api: Api<DynamicObject> = super::fetch::api_for(client, ar, &scope, &rid);

    // Default to non-force SSA so ownership conflicts return their field paths
    // and current manager. --force-conflicts opts into taking ownership.
    let mut pp = PatchParams::apply(FIELD_MANAGER);
    if force_conflicts {
        pp = pp.force();
    }
    if dry_run {
        pp = pp.dry_run();
    }

    // Check if resource exists to determine Created vs Configured. A dry run
    // keeps the live object for its preview.
    let live = api.get_opt(&name).await.ok().flatten();
    let existed = live.is_some();

    // Transient errors (429, 5xx, connection loss) are retried by the
    // client transport (cluster::client), not here. 409 conflicts are
    // permanent and surface immediately as ApplyError::Conflict so the user
    // sees an actionable error pointing at --force-conflicts.
    let echo = match apply_patch(&api, &name, &pp, manifest, &rid).await {
        Ok(echo) => echo,
        Err(ApplyError::Conflict { resource, source }) => {
            // A conflict confined to fields the resource ceded is not a
            // failure: the other manager has taken what it was meant to
            // take. Apply again without those fields and it keeps them.
            let message = match &source {
                kube::Error::Api(resp) => resp.message.clone(),
                _ => String::new(),
            };
            match without_ceded_conflicts(manifest, &message) {
                Some(stripped) => {
                    tracing::info!(
                        resource = %rid.display_id(),
                        fields = %conflict_paths(&message).join(", "),
                        "another manager owns ceded fields; applying without them"
                    );
                    apply_patch(&api, &name, &pp, &stripped, &rid).await?
                }
                None => return Err(ApplyError::Conflict { resource, source }),
            }
        }
        Err(e) => return Err(e),
    };

    // Compute the applied-content hash from the SSA response. It is the
    // committed, canonicalized server representation, so a
    // hash of its kix-owned projection is directly comparable to a hash of
    // the live object at any later check.
    let applied_hash = if dry_run {
        None
    } else {
        let h = fieldsv1::applied_content_hash(&echo);
        if h.is_none() {
            tracing::warn!(
                resource = %rid.display_id(),
                "SSA response has no kix managedFields entry; skipping applied-hash stamp"
            );
        }
        h
    };

    // Update kix bookkeeping annotations: merge the current activation into
    // `kix.run/activations` and stamp `kix.run/applied-hash`.
    //
    // This is a SEPARATE patch from the SSA above because we need read-modify-write
    // semantics to merge into the existing comma-separated set without clobbering
    // entries written by other activations. It traverses validating webhooks just
    // like the SSA, so a transient webhook outage (e.g. ingress-nginx admission pod
    // rolling) can fail it. The transport retries those; if the failure
    // outlasts the retry budget it is surfaced as a hard error, because
    // Dropping this update would corrupt reference counting and
    // cause GC to delete the resource on the next deploy.
    if !dry_run && (activation_hash.is_some() || applied_hash.is_some()) {
        update_bookkeeping_annotations_checked(
            &api,
            &name,
            activation_hash,
            applied_hash.as_deref(),
            live_activations,
            &rid,
        )
        .await?;
    }

    let action = if existed {
        ApplyAction::Configured
    } else {
        ApplyAction::Created
    };

    tracing::debug!(resource = %rid.display_id(), ?action, "server-side apply complete");

    let preview = dry_run.then(|| {
        Box::new(ApplyPreview {
            live: live.and_then(|o| serde_json::to_value(o).ok()),
            result: serde_json::to_value(&echo).unwrap_or(Value::Null),
        })
    });
    Ok(ApplyResult {
        action,
        resource_id: rid,
        preview,
    })
}

/// Send the SSA patch and classify a failure: 409 conflicts become
/// [`ApplyError::Conflict`] with the conflicting field ownership.
///
/// Return the server-canonicalized SSA response used to compute the
/// applied-content hash.
async fn apply_patch(
    api: &Api<DynamicObject>,
    name: &str,
    pp: &PatchParams,
    manifest: &Value,
    rid: &ResourceId,
) -> Result<DynamicObject, ApplyError> {
    api.patch(name, pp, &Patch::Apply(manifest))
        .await
        .map_err(|e| classify_apply_error(rid, e))
}

/// Wrapper around [`update_bookkeeping_annotations`] that turns a failure
/// into [`ApplyError::BookkeepingAnnotationsFailed`]. Under `on_error=stop`,
/// the deploy halts before it can continue with incomplete activation data.
async fn update_bookkeeping_annotations_checked(
    api: &Api<DynamicObject>,
    name: &str,
    activation_hash: Option<&str>,
    applied_hash: Option<&str>,
    live_activations: Option<&HashSet<String>>,
    rid: &ResourceId,
) -> Result<(), ApplyError> {
    update_bookkeeping_annotations(api, name, activation_hash, applied_hash, live_activations)
        .await
        .map_err(|e| ApplyError::BookkeepingAnnotationsFailed {
            resource: rid.display_id(),
            source: e,
        })
}

// ---------------------------------------------------------------------------
// Ceded fields (`kix.run/cede-fields`)
// ---------------------------------------------------------------------------

/// One step of an apiserver field path: `.spec`, `[name="x"]`, `[0]`, or
/// `[*]` in a ceded declaration for any list element.
#[derive(Debug, Clone, PartialEq)]
enum Seg {
    Field(String),
    Key(String, String),
    Index(usize),
    Any,
}

/// Parse `.webhooks[name="x"].rules` (leading dot optional) into segments.
/// `None` on anything malformed.
fn parse_path(path: &str) -> Option<Vec<Seg>> {
    let mut segs = Vec::new();
    let mut rest = path.strip_prefix('.').unwrap_or(path);
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('[') {
            let end = after.find(']')?;
            let inner = &after[..end];
            let seg = if inner == "*" {
                Seg::Any
            } else if let Ok(i) = inner.parse::<usize>() {
                Seg::Index(i)
            } else {
                let (k, v) = inner.split_once('=')?;
                Seg::Key(k.to_string(), v.trim_matches('"').to_string())
            };
            segs.push(seg);
            rest = &after[end + 1..];
            rest = rest.strip_prefix('.').unwrap_or(rest);
        } else {
            let end = rest.find(['.', '[']).unwrap_or(rest.len());
            if end == 0 {
                return None;
            }
            segs.push(Seg::Field(rest[..end].to_string()));
            rest = &rest[end..];
            rest = rest.strip_prefix('.').unwrap_or(rest);
        }
    }
    if segs.is_empty() { None } else { Some(segs) }
}

/// The paths the resource declared ceded, parsed.
fn ceded_fields(manifest: &Value) -> Vec<Vec<Seg>> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::CEDE_FIELDS))
        .and_then(Value::as_str)
        .map(|s| s.split(',').filter_map(|p| parse_path(p.trim())).collect())
        .unwrap_or_default()
}

/// The field paths a 409 message names. The apiserver writes them as
/// dot-led tokens (`conflict with "cdi-operator" using v1: .spec.versions`,
/// one per line or comma separated when there are several).
fn conflict_paths(message: &str) -> Vec<String> {
    message
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|t| t.len() > 1 && t.starts_with('.'))
        .map(str::to_string)
        .collect()
}

/// Whether a ceded declaration covers a conflicting path: the declaration
/// is a prefix, with `[*]` standing for any list element.
fn covers(ceded: &[Seg], path: &[Seg]) -> bool {
    ceded.len() <= path.len()
        && ceded.iter().zip(path).all(|(c, p)| match (c, p) {
            (Seg::Any, Seg::Key(..)) | (Seg::Any, Seg::Index(_)) => true,
            _ => c == p,
        })
}

fn step_mut<'a>(v: &'a mut Value, seg: &Seg) -> Option<&'a mut Value> {
    match seg {
        Seg::Field(f) => v.get_mut(f),
        Seg::Index(i) => v.get_mut(*i),
        Seg::Key(k, val) => v
            .as_array_mut()?
            .iter_mut()
            .find(|e| e.get(k).and_then(Value::as_str) == Some(val)),
        Seg::Any => None,
    }
}

fn remove_path(v: &mut Value, path: &[Seg]) -> bool {
    match path {
        [] => false,
        [last] => match last {
            Seg::Field(f) => v.as_object_mut().is_some_and(|o| o.remove(f).is_some()),
            Seg::Index(i) => v.as_array_mut().is_some_and(|a| {
                if *i < a.len() {
                    a.remove(*i);
                    true
                } else {
                    false
                }
            }),
            Seg::Key(k, val) => v.as_array_mut().is_some_and(|a| {
                let before = a.len();
                a.retain(|e| e.get(k).and_then(Value::as_str) != Some(val));
                a.len() != before
            }),
            Seg::Any => false,
        },
        [head, rest @ ..] => match step_mut(v, head) {
            Some(child) => remove_path(child, rest),
            None => false,
        },
    }
}

/// The manifest without the fields a 409 names, when every one of them is
/// ceded; `None` when nothing is ceded, the message names no field, or
/// any conflicting field is outside the declaration.
fn without_ceded_conflicts(manifest: &Value, message: &str) -> Option<Value> {
    let ceded = ceded_fields(manifest);
    if ceded.is_empty() {
        return None;
    }
    let paths: Vec<Vec<Seg>> = conflict_paths(message)
        .iter()
        .map(|p| parse_path(p))
        .collect::<Option<_>>()?;
    if paths.is_empty() || !paths.iter().all(|p| ceded.iter().any(|c| covers(c, p))) {
        return None;
    }
    let mut stripped = manifest.clone();
    for p in &paths {
        remove_path(&mut stripped, p);
    }
    Some(stripped)
}

/// Classify a `kube::Error` from an SSA patch into the
/// right `ApplyError` variant. 409 Conflict → `Conflict`. 422 Invalid with an
/// immutable-field message → `ImmutableConflict`. Everything else falls
/// through to `PatchFailed`.
fn classify_apply_error(rid: &ResourceId, err: kube::Error) -> ApplyError {
    match super::errors::classify(&err) {
        FailureClass::Conflict => {
            return ApplyError::Conflict {
                resource: rid.display_id(),
                source: err,
            };
        }
        FailureClass::Invalid => {
            if let kube::Error::Api(ref resp) = err {
                if is_stored_version_message(&resp.message) {
                    return ApplyError::CrdStoredVersion {
                        resource: rid.display_id(),
                        source: err,
                    };
                }
                if is_immutable_field_message(&resp.message) {
                    return ApplyError::ImmutableConflict {
                        resource: rid.display_id(),
                        source: err,
                    };
                }
            }
        }
        _ => {}
    }
    ApplyError::PatchFailed {
        resource: rid.display_id(),
        source: err,
    }
}

/// Detect the apiserver rejecting a CRD that drops a version the cluster
/// still has objects stored at.
///
/// The API server reports this as a validation error on status.storedVersions.
/// Match that field path to identify the case without classifying unrelated
/// validation failures.
fn is_stored_version_message(msg: &str) -> bool {
    msg.contains("status.storedVersions")
}

/// Detect the wire-format signatures the API server uses to reject updates to
/// immutable spec fields. Kept as a substring match because the error bodies
/// are free-form and vary per kind (Job uses "field is immutable", StatefulSet
/// "updates to statefulset spec for fields other than", Service "field is
/// immutable", etc).
fn is_immutable_field_message(msg: &str) -> bool {
    msg.contains("field is immutable")
        || msg.contains("may not be changed")
        || msg.contains("cannot be changed")
        || msg.contains("updates to statefulset spec for fields other than")
        || msg.contains("updates to daemonset spec for fields other than")
}

/// Fold `activation_hash` into the comma-separated `kix.run/activations` set,
/// dropping entries that name an activation no longer on the cluster.
///
/// The activation being deployed is always kept, even when `live` does not
/// list it: its CR is applied in the last wave, so it is legitimately absent
/// while its own resources are being stamped.
///
/// `live == None` means the set could not be established and disables pruning.
/// Output is sorted and deduplicated so a re-run is byte-identical and
/// the caller can compare against `existing` to decide whether to write.
fn merge_activation_set(
    existing: &str,
    activation_hash: &str,
    live: Option<&HashSet<String>>,
) -> String {
    let mut hashes: std::collections::BTreeSet<&str> = existing
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter(|s| live.is_none_or(|live| live.contains(*s)))
        .collect();
    hashes.insert(activation_hash);
    hashes.into_iter().collect::<Vec<_>>().join(",")
}

/// Write kix's bookkeeping annotations in ONE merge patch (no extra round
/// trips): read-modify-write `kix.run/activations` (merge `activation_hash`
/// into the comma-separated set, drop entries naming activations that no
/// longer exist) and overwrite `kix.run/applied-hash` with the hash computed
/// from the SSA response echo.
///
/// `live_activations`, when `Some`, is the set of identity hashes of every
/// Activation CR currently on the cluster. `None` means the set could not be
/// established, in which case existing activation references are retained.
async fn update_bookkeeping_annotations(
    api: &Api<DynamicObject>,
    name: &str,
    activation_hash: Option<&str>,
    applied_hash: Option<&str>,
    live_activations: Option<&HashSet<String>>,
) -> Result<(), kube::Error> {
    let mut annotations = serde_json::Map::new();
    let mut live: Option<DynamicObject> = None;

    if let Some(activation_hash) = activation_hash {
        // Read current annotation so we merge instead of clobbering entries
        // written by other activations.
        let current = api.get(name).await?;
        let existing = current
            .metadata
            .annotations
            .as_ref()
            .and_then(|a| keys::get_meta(a, keys::ACTIVATIONS))
            .unwrap_or("");

        let merged = merge_activation_set(existing, activation_hash, live_activations);

        // Nothing to say: skip the write rather than bump resourceVersion on
        // every unchanged resource, every deploy.
        if merged != existing || applied_hash.is_some() {
            annotations.insert(keys::ACTIVATIONS.to_string(), Value::String(merged));
        }
        live = Some(current);
    }

    if let Some(applied_hash) = applied_hash {
        annotations.insert(
            keys::APPLIED_HASH.to_string(),
            Value::String(applied_hash.to_string()),
        );
    }

    if annotations.is_empty() {
        return Ok(());
    }

    // These are written by merge patch, not by server-side apply, so the
    // `kix` field manager does not own them and an apply will not drop their
    // retired spellings. Clear those by name, in the write that is happening
    // anyway, and only for the keys this patch actually replaces. Inert when
    // no domain has been retired.
    let writing: Vec<&str> = annotations.keys().map(String::as_str).collect();
    for old in crate::legacy_domain::bookkeeping_null_outs(&writing) {
        annotations.insert(old, Value::Null);
    }

    // Retired build-time keys the apply could not drop.
    //
    // Server-side apply removes those on its own, but only where the `kix`
    // field manager owns them. On an object whose `managedFields` are empty,
    // which client-side `kubectl apply` leaves behind, it owns nothing: the
    // apply adds the current spelling and the retired one stays beside it,
    // so the domain move never finishes on that object.
    //
    // Only on a real apply. `applied_hash` is None on the skipped path,
    // where the resource was not re-applied and its retired keys are the
    // only ones it has: clearing them there would blind drift for good.
    if applied_hash.is_some()
        && let Some(present) = live.as_ref().and_then(|o| o.metadata.annotations.as_ref())
    {
        for old in crate::legacy_domain::retired_keys(present) {
            annotations.insert(old, Value::Null);
        }
    }

    // Use strategic merge to update these annotations without changing Kix's
    // server-side apply field set.
    // Name the field manager explicitly: kube's default would record this write
    // under manager "unknown" in managedFields, which pollutes ownership-based
    // drift attribution.
    let patch = serde_json::json!({
        "metadata": {
            "annotations": annotations,
        }
    });
    let pp = PatchParams {
        field_manager: Some(FIELD_MANAGER.to_string()),
        ..PatchParams::default()
    };
    api.patch(name, &pp, &Patch::Merge(&patch)).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn ceded_conflict_is_stripped_and_others_are_not() {
        let manifest = serde_json::json!({
            "apiVersion": "admissionregistration.k8s.io/v1",
            "kind": "ValidatingWebhookConfiguration",
            "metadata": { "name": "op", "annotations": { super::keys::CEDE_FIELDS: "webhooks[*].rules,spec.versions" } },
            "webhooks": [
                { "name": "a.example.io", "rules": [ { "apiGroups": ["x"] } ], "clientConfig": { "service": { "name": "op" } } },
                { "name": "b.example.io", "rules": [ { "apiGroups": ["y"] } ] }
            ]
        });
        let msg = "Apply failed with 1 conflict: conflict with \"fabric8-kubernetes-client\" using \
                   admissionregistration.k8s.io/v1: .webhooks[name=\"a.example.io\"].rules";
        let stripped = super::without_ceded_conflicts(&manifest, msg).expect("ceded");
        assert!(stripped["webhooks"][0].get("rules").is_none());
        assert!(stripped["webhooks"][0].get("clientConfig").is_some());
        assert!(stripped["webhooks"][1].get("rules").is_some());

        // A conflict outside the declaration is still a conflict.
        let other = "conflict with \"x\" using v1: .webhooks[name=\"a.example.io\"].clientConfig";
        assert!(super::without_ceded_conflicts(&manifest, other).is_none());
        // Two paths, one outside: still a conflict.
        let mixed = "conflicts with \"x\" using v1:\n- .spec.versions\n- .metadata.labels";
        assert!(super::without_ceded_conflicts(&manifest, mixed).is_none());
        // Nothing ceded: never stripped.
        let plain = serde_json::json!({ "metadata": { "name": "n" }, "spec": { "versions": [] } });
        assert!(super::without_ceded_conflicts(&plain, ".spec.versions").is_none());
    }

    #[test]
    fn conflict_paths_are_read_from_the_message() {
        let msg = "Apply failed with 2 conflicts: conflicts with \"cdi-operator\" using apiextensions.k8s.io/v1:\n- .spec.versions\n- .spec.conversion";
        assert_eq!(
            super::conflict_paths(msg),
            vec![".spec.versions", ".spec.conversion"]
        );
        assert_eq!(
            super::parse_path(".a[name=\"x y\"].b[0]").unwrap(),
            vec![
                super::Seg::Field("a".into()),
                super::Seg::Key("name".into(), "x y".into()),
                super::Seg::Field("b".into()),
                super::Seg::Index(0)
            ]
        );
        assert!(super::parse_path("").is_none());
    }

    #[test]
    fn stored_version_rejection_is_recognised() {
        // What the apiserver actually says when a CRD drops a version that
        // still has objects stored at it.
        let msg = "CustomResourceDefinition.apiextensions.k8s.io \"cdis.cdi.kubevirt.io\" \
                   is invalid: status.storedVersions[0]: Invalid value: \"v1alpha1\": \
                   must appear in spec.versions";
        assert!(super::is_stored_version_message(msg));
        assert!(!super::is_immutable_field_message(msg));
    }

    #[test]
    fn immutable_rejection_is_not_a_stored_version_one() {
        let msg =
            "Job.batch \"probe\" is invalid: spec.template: Invalid value: ...: field is immutable";
        assert!(super::is_immutable_field_message(msg));
        assert!(!super::is_stored_version_message(msg));
    }

    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::json;

    fn live(hashes: &[&str]) -> HashSet<String> {
        hashes.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn merges_into_an_existing_set() {
        assert_eq!(
            merge_activation_set("bbb,ccc", "aaa", Some(&live(&["bbb", "ccc"]))),
            "aaa,bbb,ccc"
        );
    }

    #[test]
    fn first_activation_on_a_bare_resource() {
        assert_eq!(merge_activation_set("", "aaa", Some(&live(&[]))), "aaa");
    }

    #[test]
    fn drops_activations_that_no_longer_exist() {
        // `dead` names an Activation CR that has been garbage-collected.
        assert_eq!(
            merge_activation_set("bbb,dead", "aaa", Some(&live(&["bbb"]))),
            "aaa,bbb"
        );
    }

    #[test]
    fn keeps_the_current_activation_even_when_not_yet_on_cluster() {
        // The Activation CR is applied in the last wave, so it is absent from
        // the live set while its own resources are being stamped.
        assert_eq!(
            merge_activation_set("bbb", "aaa", Some(&live(&["bbb"]))),
            "aaa,bbb"
        );
    }

    #[test]
    fn unknown_live_set_never_prunes() {
        assert_eq!(
            merge_activation_set("bbb,dead", "aaa", None),
            "aaa,bbb,dead"
        );
    }

    #[test]
    fn is_idempotent_and_order_insensitive() {
        let l = live(&["aaa", "bbb"]);
        let once = merge_activation_set("bbb,aaa", "aaa", Some(&l));
        assert_eq!(once, merge_activation_set(&once, "aaa", Some(&l)));
        assert_eq!(once, merge_activation_set("aaa,bbb", "aaa", Some(&l)));
        // Unchanged output is how the caller decides to skip the write.
        assert_eq!(once, "aaa,bbb");
    }

    #[test]
    fn tolerates_whitespace_and_empty_entries() {
        assert_eq!(
            merge_activation_set(" bbb , , ccc ", "aaa", Some(&live(&["bbb", "ccc"]))),
            "aaa,bbb,ccc"
        );
    }

    #[test]
    fn unstamped_old_manifest_is_never_an_orphan() {
        let mut inherited = manifest("EndpointSlice", "web-abc", "default", "unused");
        inherited["metadata"]
            .as_object_mut()
            .unwrap()
            .remove("annotations");
        let old = vec![
            inherited,
            manifest("Deployment", "gone", "default", "id-gone"),
        ];
        let actions = detect_changes(&[], &old);
        let orphans: Vec<_> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.name.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(orphans, vec!["gone"]);
    }

    #[test]
    fn unstamped_live_object_is_never_an_orphan() {
        let mut inherited = live_object("EndpointSlice", "web-abc", "default", "unused");
        inherited.metadata.annotations = None;
        let live = vec![
            inherited,
            live_object("Deployment", "gone", "default", "id-gone"),
        ];
        let actions = detect_changes_live(&[], &live);
        let orphans: Vec<_> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.name.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(orphans, vec!["gone"]);
    }

    fn manifest(kind: &str, name: &str, ns: &str, identity_hash: &str) -> Value {
        json!({
            "apiVersion": "apps/v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {
                    keys::IDENTITY_HASH: identity_hash,
                }
            }
        })
    }

    #[test]
    fn detect_new_resource() {
        let new = vec![manifest("Deployment", "app", "default", "id1")];
        let old: Vec<Value> = vec![];

        let actions = detect_changes(&new, &old);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn detect_unchanged_resource() {
        let new = vec![manifest("Deployment", "app", "default", "id1")];
        let old = vec![manifest("Deployment", "app", "default", "id1")];

        let actions = detect_changes(&new, &old);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Skip(_)));
    }

    #[test]
    fn detect_changed_resource() {
        let new = vec![manifest("Deployment", "app", "default", "new-hash")];
        let old = vec![manifest("Deployment", "app", "default", "old-hash")];

        let actions = detect_changes(&new, &old);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn detect_orphan() {
        let new: Vec<Value> = vec![];
        let old = vec![manifest("Deployment", "old-app", "default", "id-orphan")];

        let actions = detect_changes(&new, &old);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Orphan(_)));
        if let ChangeAction::Orphan(rid) = &actions[0] {
            assert_eq!(rid.name, "old-app");
        }
    }

    #[test]
    fn detect_mixed_actions() {
        let new = vec![
            manifest("Deployment", "unchanged", "default", "id1"),
            manifest("Deployment", "changed", "default", "new-hash"),
            manifest("Deployment", "new-app", "default", "id3"),
        ];
        let old = vec![
            manifest("Deployment", "unchanged", "default", "id1"),
            manifest("Deployment", "changed", "default", "old-hash"),
            manifest("Deployment", "orphan", "default", "id-orphan"),
        ];

        let actions = detect_changes(&new, &old);
        // 3 new manifest actions + 1 orphan = 4
        assert_eq!(actions.len(), 4);

        let skips: Vec<_> = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Skip(_)))
            .collect();
        let applies: Vec<_> = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .collect();
        let orphans: Vec<_> = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Orphan(_)))
            .collect();

        assert_eq!(skips.len(), 1); // unchanged
        assert_eq!(applies.len(), 2); // changed + new
        assert_eq!(orphans.len(), 1); // orphan
    }

    #[test]
    fn first_deploy_all_applies() {
        let new = vec![
            manifest("Namespace", "default", CLUSTER_SCOPED, "id1"),
            manifest("Deployment", "app", "default", "id2"),
        ];
        let old: Vec<Value> = vec![];

        let actions = detect_changes(&new, &old);
        assert_eq!(actions.len(), 2);
        assert!(actions.iter().all(|a| matches!(a, ChangeAction::Apply(_))));
    }

    #[test]
    fn immutable_field_messages_detected() {
        assert!(is_immutable_field_message(
            "Job.batch \"x\" is invalid: spec.template: Invalid value: ...: field is immutable"
        ));
        assert!(is_immutable_field_message(
            "Service \"x\" is invalid: spec.clusterIP: Invalid value: \"10.0.0.1\": field is immutable"
        ));
        assert!(is_immutable_field_message(
            "StatefulSet.apps \"x\" is invalid: spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals'"
        ));
        assert!(!is_immutable_field_message(
            "Deployment.apps \"x\" is invalid: spec.replicas: must be non-negative"
        ));
        assert!(!is_immutable_field_message("unrelated error"));
    }

    #[test]
    fn apply_action_eq() {
        assert_eq!(ApplyAction::Created, ApplyAction::Created);
        assert_eq!(ApplyAction::Configured, ApplyAction::Configured);
        assert_eq!(ApplyAction::Unchanged, ApplyAction::Unchanged);
        assert_ne!(ApplyAction::Created, ApplyAction::Configured);
    }

    // -- detect_changes_live tests --

    fn live_object(kind: &str, name: &str, ns: &str, identity_hash: &str) -> DynamicObject {
        let mut annotations = std::collections::BTreeMap::new();
        annotations.insert(keys::IDENTITY_HASH.to_string(), identity_hash.to_string());
        DynamicObject {
            metadata: ObjectMeta {
                name: Some(name.to_string()),
                namespace: if ns == crate::manifest::types::CLUSTER_SCOPED {
                    None
                } else {
                    Some(ns.to_string())
                },
                annotations: Some(annotations),
                ..Default::default()
            },
            types: Some(kube::api::TypeMeta {
                kind: kind.to_string(),
                api_version: "apps/v1".to_string(),
            }),
            data: json!({
                "kind": kind,
                "apiVersion": "apps/v1",
                "metadata": {
                    "name": name,
                    "namespace": ns,
                    "annotations": {
                        keys::IDENTITY_HASH: identity_hash,
                    }
                }
            }),
        }
    }

    #[test]
    fn live_detect_new_resource() {
        let desired = vec![manifest("Deployment", "app", "default", "id1")];
        let live: Vec<DynamicObject> = vec![];

        let actions = detect_changes_live(&desired, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn live_detect_unchanged_resource() {
        let desired = vec![manifest("Deployment", "app", "default", "id1")];
        let live = vec![live_object("Deployment", "app", "default", "id1")];

        let actions = detect_changes_live(&desired, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Skip(_)));
    }

    #[test]
    fn live_detect_drifted_resource() {
        let desired = vec![manifest("Deployment", "app", "default", "desired-hash")];
        let live = vec![live_object("Deployment", "app", "default", "live-hash")];

        let actions = detect_changes_live(&desired, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn live_detect_orphan() {
        let desired: Vec<Value> = vec![];
        let live = vec![live_object("Deployment", "orphan", "default", "id1")];

        let actions = detect_changes_live(&desired, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Orphan(_)));
        if let ChangeAction::Orphan(rid) = &actions[0] {
            assert_eq!(rid.name, "orphan");
        }
    }

    #[test]
    fn live_detect_mixed() {
        let desired = vec![
            manifest("Deployment", "unchanged", "default", "id1"),
            manifest("Deployment", "drifted", "default", "new-hash"),
            manifest("Deployment", "new-app", "default", "id3"),
        ];
        let live = vec![
            live_object("Deployment", "unchanged", "default", "id1"),
            live_object("Deployment", "drifted", "default", "old-hash"),
            live_object("Deployment", "orphan", "default", "id-orphan"),
        ];

        let actions = detect_changes_live(&desired, &live);
        // 3 desired actions + 1 orphan = 4
        assert_eq!(actions.len(), 4);

        let skips = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Skip(_)))
            .count();
        let applies = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .count();
        let orphans = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Orphan(_)))
            .count();

        assert_eq!(skips, 1);
        assert_eq!(applies, 2);
        assert_eq!(orphans, 1);
    }

    // Deploy records do not participate in change detection.

    fn record(name: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": name,
                "annotations": { keys::IDENTITY_HASH: hash, keys::PACKAGE: "_cluster" }
            }
        })
    }

    fn live_record(name: &str, hash: &str) -> DynamicObject {
        serde_json::from_value(record(name, hash)).unwrap()
    }

    fn orphan_ids(actions: &[ChangeAction]) -> Vec<String> {
        let mut v: Vec<String> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Orphan(rid) => Some(rid.display_id()),
                _ => None,
            })
            .collect();
        v.sort();
        v
    }

    fn apply_ids(actions: &[ChangeAction]) -> Vec<String> {
        let mut v: Vec<String> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Apply(m) => Some(ResourceId::from_value(m).display_id()),
                _ => None,
            })
            .collect();
        v.sort();
        v
    }

    fn skip_ids(actions: &[ChangeAction]) -> Vec<String> {
        let mut v: Vec<String> = actions
            .iter()
            .filter_map(|a| match a {
                ChangeAction::Skip(rid) => Some(rid.display_id()),
                _ => None,
            })
            .collect();
        v.sort();
        v
    }

    // -- fold_kept_closures / leaves_orphans ------------------------------
    //
    // The situation: a warn-only deploy of A replaced K and kept K's orphans.
    // A is Active and lists K under `status.orphansKeptFrom`; we are about to
    // deploy N.

    #[test]
    fn an_object_only_a_kept_closure_has_is_an_orphan_again() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = active.clone();
        let kept = vec![
            manifest("Deployment", "web", "app", "h0"),
            manifest("ConfigMap", "removed", "app", "h9"),
            record("demo-old", "h8"),
        ];

        let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[kept]);
        assert_eq!(orphan_ids(&folded), vec!["ConfigMap/removed@app"]);
        // A kept closure never turns a Skip into an Apply: A replaced it in full.
        assert_eq!(skip_ids(&folded), vec!["Deployment/web@app"]);
        assert!(apply_ids(&folded).is_empty());
    }

    #[test]
    fn an_object_the_new_build_declares_again_is_not_an_orphan() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![
            manifest("Deployment", "web", "app", "h1"),
            manifest("ConfigMap", "removed", "app", "h10"),
        ];
        let kept = vec![manifest("ConfigMap", "removed", "app", "h9")];

        let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[kept]);
        assert!(orphan_ids(&folded).is_empty());
    }

    #[test]
    fn kept_closures_and_the_active_diff_do_not_duplicate_orphans() {
        let active = vec![
            manifest("Deployment", "web", "app", "h1"),
            manifest("ConfigMap", "gone", "app", "h5"),
        ];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let first = vec![
            manifest("ConfigMap", "gone", "app", "h4"),
            manifest("Secret", "older", "app", "h3"),
        ];
        let second = vec![manifest("Secret", "older", "app", "h3")];

        let folded = fold_kept_closures(detect_changes(&new, &active), &new, &[first, second]);
        assert_eq!(
            orphan_ids(&folded),
            vec!["ConfigMap/gone@app", "Secret/older@app"]
        );
    }

    #[test]
    fn a_closure_leaves_orphans_only_for_deletable_objects_the_new_build_lacks() {
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        assert!(leaves_orphans(
            &[manifest("ConfigMap", "removed", "app", "h9")],
            &new
        ));
        // Same identity under a different hash is an update, not an orphan.
        assert!(!leaves_orphans(
            &[manifest("Deployment", "web", "app", "h0")],
            &new
        ));
        // Records are superseded and Namespaces are never pruned.
        assert!(!leaves_orphans(&[record("demo-old", "h8")], &new));
        let mut ns = manifest("Namespace", "app", "app", "h7");
        ns["metadata"].as_object_mut().unwrap().remove("namespace");
        assert!(!leaves_orphans(&[ns], &new));
    }

    // -- fold_failed_closures --------------------------------------------
    //
    // The situation throughout: a deploy of closure F started, applied some of
    // it, and died. Its record is Failed and resolvable, so F is known. The
    // cluster is running A, and we are about to deploy N.

    #[test]
    fn an_object_only_the_failed_closure_has_is_an_orphan() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![
            manifest("Deployment", "web", "app", "h2"),
            manifest("ConfigMap", "leftover", "app", "h9"),
        ];

        let actions = detect_changes(&new, &active);
        assert_eq!(orphan_ids(&actions), Vec::<String>::new());

        let folded = fold_failed_closures(actions, &new, &[failed]);
        assert_eq!(orphan_ids(&folded), vec!["ConfigMap/leftover@app"]);
    }

    #[test]
    fn an_object_the_failed_deploy_may_have_changed_is_reapplied() {
        // The repair half of #82. Reverting the config makes N identical to A,
        // so detect_changes skips everything, but the cluster may hold F's
        // version of `web`.
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![manifest("Deployment", "web", "app", "h2")];

        let actions = detect_changes(&new, &active);
        assert_eq!(skip_ids(&actions), vec!["Deployment/web@app"]);

        let folded = fold_failed_closures(actions, &new, &[failed]);
        assert_eq!(apply_ids(&folded), vec!["Deployment/web@app"]);
        assert!(skip_ids(&folded).is_empty());
    }

    #[test]
    fn a_hash_the_failed_closure_agrees_on_stays_skipped() {
        // F never disagreed about this one, so nothing it did could have
        // changed it and re-applying would be noise.
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![manifest("Deployment", "web", "app", "h1")];

        let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
        assert_eq!(skip_ids(&folded), vec!["Deployment/web@app"]);
        assert!(apply_ids(&folded).is_empty());
    }

    #[test]
    fn retrying_the_closure_that_failed_applies_it_and_orphans_nothing() {
        // N == F: every node is already an Apply, and nothing F touched is
        // outside the set we are about to write.
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![
            manifest("Deployment", "web", "app", "h2"),
            manifest("ConfigMap", "extra", "app", "h9"),
        ];
        let failed = new.clone();

        let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
        assert_eq!(
            apply_ids(&folded),
            vec!["ConfigMap/extra@app", "Deployment/web@app"]
        );
        assert!(orphan_ids(&folded).is_empty());
    }

    #[test]
    fn stacked_failed_closures_union_their_leftovers() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let first = vec![manifest("ConfigMap", "one", "app", "h7")];
        let second = vec![manifest("ConfigMap", "two", "app", "h8")];

        let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[first, second]);
        assert_eq!(
            orphan_ids(&folded),
            vec!["ConfigMap/one@app", "ConfigMap/two@app"]
        );
    }

    #[test]
    fn a_record_in_a_failed_closure_is_never_an_orphan() {
        // Records are superseded, not pruned. A failed closure always carries
        // its own, and its name differs from the new one on every changed
        // deploy, so without the lifecycle check every run would invent one.
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![
            manifest("Deployment", "web", "app", "h1"),
            record("demo-abc123", "h2"),
        ];

        let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
        assert!(orphan_ids(&folded).is_empty());
    }

    #[test]
    fn an_unstamped_manifest_in_a_failed_closure_is_never_an_orphan() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "unstamped", "namespace": "app" }
        })];

        let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
        assert!(orphan_ids(&folded).is_empty());
    }

    #[test]
    fn an_orphan_detect_changes_already_found_is_not_duplicated() {
        let active = vec![
            manifest("Deployment", "web", "app", "h1"),
            manifest("ConfigMap", "gone", "app", "h5"),
        ];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![manifest("ConfigMap", "gone", "app", "h6")];

        let folded = fold_failed_closures(detect_changes(&new, &active), &new, &[failed]);
        assert_eq!(orphan_ids(&folded), vec!["ConfigMap/gone@app"]);
    }

    #[test]
    fn no_failed_closures_changes_nothing() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let new = vec![manifest("Deployment", "web", "app", "h1")];
        let before = detect_changes(&new, &active);
        let after = fold_failed_closures(before.clone(), &new, &[]);
        assert_eq!(skip_ids(&before), skip_ids(&after));
        assert_eq!(apply_ids(&before), apply_ids(&after));
        assert_eq!(orphan_ids(&before), orphan_ids(&after));
    }

    // -- baseline_manifests ----------------------------------------------

    #[test]
    fn baseline_keeps_active_and_adds_only_what_is_missing() {
        let active = vec![manifest("Deployment", "web", "app", "h1")];
        let failed = vec![
            // Same identity as active: the active version wins, so the plan
            // describes the object the way the current closure does.
            manifest("Deployment", "web", "app", "h2"),
            manifest("ConfigMap", "leftover", "app", "h9"),
        ];

        let merged = baseline_manifests(&active, &[failed]);
        assert_eq!(merged.len(), 2);
        assert_eq!(manifest_identity_hash(&merged[0]), Some("h1"));
        assert_eq!(
            ResourceId::from_value(&merged[1]).display_id(),
            "ConfigMap/leftover@app"
        );
    }

    /// Invariant 1: two builds that differ only in the record produce no
    /// orphan. The only apply is the new record itself, which is how it
    /// reaches the cluster.
    #[test]
    fn record_rename_is_not_an_orphan() {
        let shared = manifest(
            "ConfigMap",
            "grafana-datasources",
            "monitoring-system",
            "same",
        );
        let old = vec![
            record("stage1-0f3g4dhhzqfd", "0f3g4dhhzqfd0xvgwfw987lf0s8xhmkb"),
            shared.clone(),
        ];
        let new = vec![
            record("stage1-680afyh7g9kd", "680afyh7g9kd5vdqk3p5kzgs5ymyyyzi"),
            shared,
        ];
        let actions = detect_changes(&new, &old);
        assert!(
            orphan_ids(&actions).is_empty(),
            "{:?}",
            orphan_ids(&actions)
        );
        assert_eq!(apply_ids(&actions), vec!["Activation/stage1-680afyh7g9kd"]);
    }

    /// An unchanged build keeps the same record name and hash. It must come
    /// out as Skip on both paths, so `total_apply == 0` and the deploy can
    /// short-circuit on "activation identical". Removing records from the
    /// old side before matching (the first cut of this fix) broke that: the
    /// record was Apply on every deploy and the short-circuit was dead code.
    #[test]
    fn unchanged_record_is_skip_not_apply() {
        let dep = manifest("Deployment", "web", "default", "d1");
        let same = record("stage1-0f3g4dhhzqfd", "0f3g4dhhzqfd0xvgwfw987lf0s8xhmkb");
        let actions = detect_changes(&[same.clone(), dep.clone()], &[same.clone(), dep.clone()]);
        assert!(apply_ids(&actions).is_empty(), "{:?}", apply_ids(&actions));
        assert!(orphan_ids(&actions).is_empty());
        assert_eq!(
            actions
                .iter()
                .filter(|a| matches!(a, ChangeAction::Skip(_)))
                .count(),
            2
        );

        let live = vec![
            live_object(
                "Activation",
                "stage1-0f3g4dhhzqfd",
                CLUSTER_SCOPED,
                "0f3g4dhhzqfd0xvgwfw987lf0s8xhmkb",
            ),
            live_object("Deployment", "web", "default", "d1"),
        ];
        let actions = detect_changes_live(&[same, dep], &live);
        assert!(apply_ids(&actions).is_empty(), "{:?}", apply_ids(&actions));
        assert!(orphan_ids(&actions).is_empty());
    }

    /// Markers and plain PackageInstances are ordinary desired state for
    /// orphan detection: one that left the build is an orphan. Pins
    /// `Lifecycle::prunable()` against a mutant that only prunes `Desired`.
    #[test]
    fn markers_and_plain_package_instances_can_be_orphans() {
        let mut marker = manifest("PackageInstance", "pi-import", "ns", "m1");
        marker["metadata"]["annotations"][keys::MODE] = serde_json::json!("import");
        let plain = manifest("PackageInstance", "pi-plain", "ns", "p1");
        let keep = manifest("Deployment", "web", "default", "d1");
        let old = vec![marker, plain, keep.clone()];
        let actions = detect_changes(std::slice::from_ref(&keep), &old);
        let mut orphans = orphan_ids(&actions);
        orphans.sort();
        assert_eq!(
            orphans,
            vec![
                "PackageInstance/pi-import@ns",
                "PackageInstance/pi-plain@ns"
            ]
        );
    }

    /// Invariant 2: no orphan action ever names a record, whatever the
    /// shapes of the two sets.
    #[test]
    fn records_are_never_orphans() {
        let dep = manifest("Deployment", "web", "default", "d1");
        let cases: Vec<(Vec<Value>, Vec<Value>)> = vec![
            // old has a record, new has none
            (vec![dep.clone()], vec![record("c-a", "a"), dep.clone()]),
            // old has two records (a stale one and the active one)
            (
                vec![record("c-c", "c"), dep.clone()],
                vec![record("c-a", "a"), record("c-b", "b"), dep.clone()],
            ),
            // old is only a record
            (vec![dep.clone()], vec![record("c-a", "a")]),
            // a real orphan alongside a record: the real one is still found
            (
                vec![record("c-b", "b")],
                vec![record("c-a", "a"), dep.clone()],
            ),
        ];
        for (new, old) in cases {
            let actions = detect_changes(&new, &old);
            for id in orphan_ids(&actions) {
                assert!(
                    !id.starts_with("Activation/"),
                    "record reported as orphan: {id}"
                );
            }
        }
        // The last case must still report the Deployment.
        let actions = detect_changes(&[record("c-b", "b")], &[record("c-a", "a"), dep]);
        assert_eq!(orphan_ids(&actions), vec!["Deployment/web@default"]);
    }

    /// Invariant 3: the store path and the live path agree on the orphan
    /// set for the same previous state, records included.
    #[test]
    fn store_and_live_paths_agree_on_orphans() {
        let desired = vec![
            record("c-new", "new"),
            manifest("Deployment", "keep", "default", "k1"),
        ];
        let old = vec![
            record("c-old", "old"),
            manifest("Deployment", "keep", "default", "k1"),
            manifest("Deployment", "gone", "default", "g1"),
        ];
        let live = vec![
            live_record("c-old", "old"),
            live_object("Deployment", "keep", "default", "k1"),
            live_object("Deployment", "gone", "default", "g1"),
        ];
        let via_store = orphan_ids(&detect_changes(&desired, &old));
        let via_live = orphan_ids(&detect_changes_live(&desired, &live));
        assert_eq!(via_store, vec!["Deployment/gone@default"]);
        assert_eq!(via_store, via_live);
        // Both paths still apply the new record.
        assert!(
            apply_ids(&detect_changes(&desired, &old))
                .iter()
                .any(|id| id.starts_with("Activation/")),
            "store path drops the new record"
        );
        assert!(
            apply_ids(&detect_changes_live(&desired, &live))
                .iter()
                .any(|id| id.starts_with("Activation/")),
            "live path drops the new record"
        );
    }

    /// The operator strips the record from the desired side and prunes with
    /// delete. Before #59 that made every live record an orphan.
    #[test]
    fn operator_shape_live_record_is_not_an_orphan() {
        let desired = vec![manifest("Deployment", "web", "default", "d1")];
        let live = vec![
            live_record("c-active", "act"),
            live_object("Deployment", "web", "default", "d1"),
        ];
        let actions = detect_changes_live(&desired, &live);
        assert!(
            orphan_ids(&actions).is_empty(),
            "{:?}",
            orphan_ids(&actions)
        );
    }

    /// A ConfigMap manifest without metadata.namespace is refused before any
    /// request, so the apiserver never stores it in `default` under an id
    /// the build does not have. `namespaceless` reports only that case: not a
    /// ClusterRole, a ConfigMap with a namespace, or a kind discovery lacks.
    #[tokio::test]
    async fn a_namespaced_kind_without_a_namespace_is_refused() {
        use crate::cluster::{fake_api::FakeApi, fetch};
        use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};

        let api = FakeApi::default();
        let client = api.client();
        let discovery = fetch::discover_resources(&client).await.unwrap();
        let before = api.requests().len();
        let cm = serde_json::json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "shared" },
        });
        let (ar, scope) = discovery
            .iter()
            .find(|(ar, _)| ar.kind == "ConfigMap")
            .unwrap();
        let err = super::apply_resource(&client, ar, scope.clone(), &cm, false, None, None, false)
            .await
            .unwrap_err();
        assert!(
            matches!(&err, super::ApplyError::NoNamespace { resource } if resource == "ConfigMap/shared"),
            "{err}"
        );
        assert_eq!(api.requests().len(), before, "{:?}", api.requests());

        let rid = |kind: &str, ns: &str| ResourceId {
            kind: kind.into(),
            namespace: ns.into(),
            name: "shared".into(),
        };
        let candidates = [
            rid("ConfigMap", CLUSTER_SCOPED),
            rid("ConfigMap", "default"),
            rid("ClusterRole", CLUSTER_SCOPED),
            rid("Widget", CLUSTER_SCOPED),
        ];
        assert_eq!(
            super::namespaceless(&discovery, &candidates),
            vec![rid("ConfigMap", CLUSTER_SCOPED)]
        );
    }
}
