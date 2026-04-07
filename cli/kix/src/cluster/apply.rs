//! Apply engine — SSA-based resource application with local DAG diff change detection.
//!
//! Uses server-side apply (`Patch::Apply`) with `kix` as the field manager.
//! Change detection diffs two sets of stamped manifests locally by comparing
//! identity-hashes, without querying the live cluster.

use std::collections::HashMap;
use std::time::Duration;

use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;
use tokio::task::JoinSet;

/// Number of attempts for transient-failure retries on patch operations
/// (SSA itself and the activations annotation update).
///
/// Sized to comfortably outlast a webhook controller pod restart cycle:
/// 7 attempts with capped exponential backoff = roughly 30 seconds total
/// (0.5, 1, 2, 4, 8, 8, 8). The cap prevents pathological waits while still
/// covering JVM-cold-start webhooks like the stackgres operator.
const PATCH_RETRY_ATTEMPTS: usize = 7;

/// Initial backoff between patch retries; doubles each attempt up to the cap.
const PATCH_RETRY_INITIAL_BACKOFF: Duration = Duration::from_millis(500);

/// Maximum backoff between patch retries.
const PATCH_RETRY_MAX_BACKOFF: Duration = Duration::from_secs(8);

/// Annotation key for identity hash (derived from Nix store path).
pub const IDENTITY_HASH_ANNOTATION: &str = "kix.dev/identity-hash";

/// Annotation key for activations (comma-separated activation identity-hashes).
pub const ACTIVATIONS_ANNOTATION: &str = "kix.dev/activations";

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
        "field-ownership conflict on {resource}: another field manager owns one or more fields kix is trying to set. \
         Re-run with --force-conflicts to take ownership. Underlying error: {source}"
    )]
    Conflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "failed to update kix.dev/activations annotation on {resource} after {attempts} attempts: {source}"
    )]
    ActivationsAnnotationFailed {
        resource: String,
        attempts: usize,
        #[source]
        source: kube::Error,
    },

    #[error("no API resource found for kind '{kind}'")]
    UnknownKind { kind: String },
}

/// Result of applying a single resource.
#[derive(Debug, Clone)]
pub struct ApplyResult {
    /// What action was taken.
    pub action: ApplyAction,
    /// The resource that was acted upon.
    pub resource_id: ResourceId,
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
    /// Resource exists in old activation but not new — candidate for pruning.
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
pub fn detect_changes(new_manifests: &[Value], old_manifests: &[Value]) -> Vec<ChangeAction> {
    // Index old manifests by K8s identity (kind/ns/name) → identity-hash
    let old_by_k8s_id: HashMap<String, &str> = old_manifests
        .iter()
        .filter_map(|m| {
            let rid = ResourceId::from_value(m);
            let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
            let hash = m
                .pointer("/metadata/annotations")
                .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
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
            .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
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

    // Find orphans: old resources not matched by any new resource
    for old_manifest in old_manifests {
        let rid = ResourceId::from_value(old_manifest);
        let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
        if !matched_old_ids.contains(&k8s_id) {
            actions.push(ChangeAction::Orphan(rid));
        }
    }

    actions
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
    // Index live resources by K8s identity → identity-hash
    let mut live_by_k8s_id: HashMap<String, Option<&str>> = HashMap::new();
    let mut live_rids: HashMap<String, ResourceId> = HashMap::new();

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
            .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
            .map(|s| s.as_str());

        live_by_k8s_id.insert(k8s_id.clone(), hash);
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
            .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
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

    // Find orphans: live resources not matched by any desired manifest
    for (k8s_id, rid) in &live_rids {
        if !matched_live_ids.contains(k8s_id) {
            actions.push(ChangeAction::Orphan(rid.clone()));
        }
    }

    actions
}

/// Apply a single resource via server-side apply.
///
/// If `activation_hash` is provided, the resource's `kix.dev/activations`
/// annotation is updated to include this activation (read-modify-write).
pub async fn apply_resource(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    manifest: &Value,
    dry_run: bool,
    activation_hash: Option<&str>,
    force_conflicts: bool,
) -> Result<ApplyResult, ApplyError> {
    let rid = ResourceId::from_value(manifest);
    let name = rid.name.clone();

    tracing::info!(resource = %rid.display_id(), "applying resource");

    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            let ns = if rid.namespace == CLUSTER_SCOPED {
                "default"
            } else {
                &rid.namespace
            };
            Api::namespaced_with(client.clone(), ns, ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), ar),
    };

    // Build patch params. We default to NON-force SSA: conflicts surface as 409
    // with the conflicting field paths and current owner, instead of silently
    // clobbering. The user opts in to clobber via --force-conflicts (typically
    // for first-time migration of a resource away from kubectl/helm).
    let mut pp = PatchParams::apply(FIELD_MANAGER);
    if force_conflicts {
        pp = pp.force();
    }
    if dry_run {
        pp = pp.dry_run();
    }

    // Check if resource exists to determine Created vs Configured
    let existed = api.get_opt(&name).await.is_ok_and(|o| o.is_some());

    // Apply with retry on transient errors (5xx, network). 409 conflicts are
    // permanent and surface immediately as ApplyError::Conflict so the user
    // sees an actionable error pointing at --force-conflicts.
    apply_patch_with_retry(&api, &name, &pp, manifest, &rid).await?;

    // Update kix.dev/activations annotation (merge current activation into set).
    //
    // This is a SEPARATE patch from the SSA above because we need read-modify-write
    // semantics to merge into the existing comma-separated set without clobbering
    // entries written by other activations. It traverses validating webhooks just
    // like the SSA, so a transient webhook outage (e.g. ingress-nginx admission pod
    // rolling) can fail it. We retry transient errors with backoff and surface a
    // hard failure if it still doesn't succeed — silently dropping this update
    // would corrupt reference counting and cause GC to delete the resource on the
    // next deploy.
    if let Some(act_hash) = activation_hash
        && !dry_run
    {
        update_activations_annotation_with_retry(&api, &name, act_hash, &rid).await?;
    }

    let action = if existed {
        ApplyAction::Configured
    } else {
        ApplyAction::Created
    };

    tracing::debug!(resource = %rid.display_id(), ?action, "server-side apply complete");

    Ok(ApplyResult {
        action,
        resource_id: rid,
    })
}

/// Retry an SSA patch on transient errors (5xx, network), surface 409 conflicts
/// as [`ApplyError::Conflict`] so the user gets an actionable message instead
/// of silently clobbering field ownership.
async fn apply_patch_with_retry(
    api: &Api<DynamicObject>,
    name: &str,
    pp: &PatchParams,
    manifest: &Value,
    rid: &ResourceId,
) -> Result<(), ApplyError> {
    let attempt_label = "applying resource";
    retry_kube_op(rid, attempt_label, |attempt| async move {
        let _ = attempt;
        api.patch(name, pp, &Patch::Apply(manifest))
            .await
            .map(|_| ())
    })
    .await
    .map_err(|e| classify_apply_error(rid, e))
}

/// Wrapper around [`update_activations_annotation`] that retries transient
/// failures (e.g. validating-webhook pod rolling) with capped exponential
/// backoff. Permanent errors (4xx, parse, auth) bail immediately.
/// After exhausting attempts the failure is surfaced as a hard
/// [`ApplyError::ActivationsAnnotationFailed`] so the deploy halts under
/// `on_error=stop` instead of silently corrupting `kix.dev/activations`
/// reference counting.
async fn update_activations_annotation_with_retry(
    api: &Api<DynamicObject>,
    name: &str,
    activation_hash: &str,
    rid: &ResourceId,
) -> Result<(), ApplyError> {
    let attempt_label = "updating activations annotation";
    retry_kube_op(rid, attempt_label, |attempt| async move {
        let _ = attempt;
        update_activations_annotation(api, name, activation_hash).await
    })
    .await
    .map_err(|e| ApplyError::ActivationsAnnotationFailed {
        resource: rid.display_id(),
        attempts: PATCH_RETRY_ATTEMPTS,
        source: e,
    })
}

/// Generic retry loop with capped exponential backoff. Calls `op` up to
/// `PATCH_RETRY_ATTEMPTS` times; retries iff [`is_transient_kube_error`]
/// returns true. Returns the final `kube::Error` (transient-exhausted or
/// permanent on first hit) so the caller can wrap it in an `ApplyError`
/// variant of its choice.
async fn retry_kube_op<F, Fut>(
    rid: &ResourceId,
    label: &'static str,
    mut op: F,
) -> Result<(), kube::Error>
where
    F: FnMut(usize) -> Fut,
    Fut: std::future::Future<Output = Result<(), kube::Error>>,
{
    let mut backoff = PATCH_RETRY_INITIAL_BACKOFF;
    let mut last_err: Option<kube::Error> = None;

    for attempt in 1..=PATCH_RETRY_ATTEMPTS {
        match op(attempt).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                if !is_transient_kube_error(&e) {
                    return Err(e);
                }
                tracing::warn!(
                    resource = %rid.display_id(),
                    op = label,
                    attempt,
                    max_attempts = PATCH_RETRY_ATTEMPTS,
                    error = %e,
                    "transient error, retrying"
                );
                last_err = Some(e);
                if attempt < PATCH_RETRY_ATTEMPTS {
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff.saturating_mul(2)).min(PATCH_RETRY_MAX_BACKOFF);
                }
            }
        }
    }

    Err(last_err.expect("at least one attempt was made"))
}

/// Classify a permanent (post-retry) `kube::Error` from an SSA patch into the
/// right `ApplyError` variant. 409 Conflict gets the dedicated `Conflict`
/// variant; everything else falls through to `PatchFailed`.
fn classify_apply_error(rid: &ResourceId, err: kube::Error) -> ApplyError {
    if let kube::Error::Api(ref resp) = err
        && resp.code == 409
    {
        return ApplyError::Conflict {
            resource: rid.display_id(),
            source: err,
        };
    }
    ApplyError::PatchFailed {
        resource: rid.display_id(),
        source: err,
    }
}

/// Classify a kube::Error as transient (worth retrying) vs permanent.
///
/// Transient: 5xx API responses (often surfaced when validating webhooks are
/// unreachable) and any non-API error (network/hyper/timeout). Everything
/// else (4xx including 409 Conflict, parse errors, auth failures) is treated
/// as permanent.
fn is_transient_kube_error(err: &kube::Error) -> bool {
    match err {
        kube::Error::Api(resp) => resp.code >= 500,
        // Network-ish errors — connection refused, EOF, TLS, timeout, etc.
        kube::Error::HyperError(_) | kube::Error::Service(_) => true,
        _ => false,
    }
}

/// Read-modify-write the `kix.dev/activations` annotation on a resource.
/// Merges `activation_hash` into the comma-separated set of activation hashes.
async fn update_activations_annotation(
    api: &Api<DynamicObject>,
    name: &str,
    activation_hash: &str,
) -> Result<(), kube::Error> {
    // Read current annotation
    let current = api.get(name).await?;
    let existing = current
        .data
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(ACTIVATIONS_ANNOTATION))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // Build the merged set
    let mut hashes: std::collections::BTreeSet<&str> = existing
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    hashes.insert(activation_hash);
    let merged = hashes.into_iter().collect::<Vec<_>>().join(",");

    // Patch with strategic merge (not SSA — we only want to touch this one annotation)
    let patch = serde_json::json!({
        "metadata": {
            "annotations": {
                ACTIVATIONS_ANNOTATION: merged,
            }
        }
    });
    api.patch(name, &PatchParams::default(), &Patch::Merge(&patch))
        .await?;

    Ok(())
}

/// Apply all resources in a wave in parallel.
///
/// If `activation_hash` is provided, each applied resource gets the activation
/// merged into its `kix.dev/activations` annotation.
///
/// Returns a vec of (ResourceId, Result) pairs for each action in the wave.
pub async fn apply_wave(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    wave: &[ChangeAction],
    dry_run: bool,
    activation_hash: Option<&str>,
    force_conflicts: bool,
) -> Vec<(ResourceId, Result<ApplyResult, ApplyError>)> {
    // Build kind -> (ApiResource, Scope) lookup
    let ar_by_kind: HashMap<String, (ApiResource, Scope)> = discovery
        .iter()
        .map(|pair| (pair.0.kind.clone(), (pair.0.clone(), pair.1.clone())))
        .collect();

    let mut set = JoinSet::new();

    for action in wave {
        match action {
            ChangeAction::Apply(manifest) => {
                let rid = ResourceId::from_value(manifest);
                let kind = rid.kind.clone();

                let Some((ar, scope)) = ar_by_kind.get(&kind) else {
                    let rid_clone = rid.clone();
                    set.spawn(async move {
                        (
                            rid_clone.clone(),
                            Err(ApplyError::UnknownKind {
                                kind: rid_clone.kind.clone(),
                            }),
                        )
                    });
                    continue;
                };

                let client = client.clone();
                let ar = ar.clone();
                let scope = scope.clone();
                let manifest = manifest.clone();
                let act_hash = activation_hash.map(|s| s.to_string());
                set.spawn(async move {
                    let result = apply_resource(
                        &client,
                        &ar,
                        scope,
                        &manifest,
                        dry_run,
                        act_hash.as_deref(),
                        force_conflicts,
                    )
                    .await;
                    (rid, result)
                });
            }
            ChangeAction::Skip(rid) => {
                let rid = rid.clone();
                set.spawn(async move {
                    (
                        rid.clone(),
                        Ok(ApplyResult {
                            action: ApplyAction::Unchanged,
                            resource_id: rid,
                        }),
                    )
                });
            }
            ChangeAction::Orphan(rid) => {
                // Orphans are handled separately (prune phase),
                // but we report them here for tracking
                let rid = rid.clone();
                set.spawn(async move {
                    (
                        rid.clone(),
                        Ok(ApplyResult {
                            action: ApplyAction::Skipped,
                            resource_id: rid,
                        }),
                    )
                });
            }
        }
    }

    let mut results = Vec::new();
    while let Some(join_result) = set.join_next().await {
        match join_result {
            Ok(pair) => results.push(pair),
            Err(e) => {
                tracing::warn!(error = %e, "task join error during apply wave");
            }
        }
    }
    results
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::json;

    fn manifest(kind: &str, name: &str, ns: &str, identity_hash: &str) -> Value {
        json!({
            "apiVersion": "apps/v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {
                    IDENTITY_HASH_ANNOTATION: identity_hash,
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
    fn apply_action_eq() {
        assert_eq!(ApplyAction::Created, ApplyAction::Created);
        assert_eq!(ApplyAction::Configured, ApplyAction::Configured);
        assert_eq!(ApplyAction::Unchanged, ApplyAction::Unchanged);
        assert_ne!(ApplyAction::Created, ApplyAction::Configured);
    }

    // -- detect_changes_live tests --

    fn live_object(kind: &str, name: &str, ns: &str, identity_hash: &str) -> DynamicObject {
        let mut annotations = std::collections::BTreeMap::new();
        annotations.insert(
            IDENTITY_HASH_ANNOTATION.to_string(),
            identity_hash.to_string(),
        );
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
                        IDENTITY_HASH_ANNOTATION: identity_hash,
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
}
