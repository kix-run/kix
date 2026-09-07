//! Apply engine — SSA-based resource application with local DAG diff change detection.
//!
//! Uses server-side apply (`Patch::Apply`) with `kix` as the field manager.
//! Change detection diffs two sets of stamped manifests locally by comparing
//! identity-hashes, without querying the live cluster.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use super::fieldsv1;
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
        "immutable-field conflict on {resource}: the live resource has one or more fields that cannot be updated in place. \
         To recover, include this resource in the prune set so reconcile is authorized to delete + recreate it. \
         Underlying error: {source}"
    )]
    ImmutableConflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "failed to update kix bookkeeping annotations (activations, applied-hash) on {resource} after {attempts} attempts: {source}"
    )]
    BookkeepingAnnotationsFailed {
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
/// The `kix.dev/identity-hash` a rendered or live-reconstructed manifest
/// carries, if kix ever applied it.
fn manifest_identity_hash(manifest: &Value) -> Option<&str> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
        .and_then(Value::as_str)
}

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

    // Find orphans: old resources not matched by any new resource. Only
    // stamped resources qualify: an old manifest without an identity hash
    // came from live reconstruction of something kix never applied (a
    // controller child that inherited the label, a kubectl-applied render),
    // and kix only ever deletes what it stamped.
    for old_manifest in old_manifests {
        if manifest_identity_hash(old_manifest).is_none() {
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

    // Find orphans: live resources not matched by any desired manifest.
    // Unstamped live objects are never orphans: kix did not apply them, so
    // kix does not delete them (see detect_changes).
    for (k8s_id, rid) in &live_rids {
        let stamped = live_by_k8s_id.get(k8s_id).copied().flatten().is_some();
        if stamped && !matched_live_ids.contains(k8s_id) {
            actions.push(ChangeAction::Orphan(rid.clone()));
        }
    }

    actions
}

/// Build the typed API handle for a resource, honoring cluster scope.
fn api_for(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    rid: &ResourceId,
) -> Api<DynamicObject> {
    match scope {
        Scope::Namespaced => {
            let ns = if rid.namespace == CLUSTER_SCOPED {
                "default"
            } else {
                &rid.namespace
            };
            Api::namespaced_with(client.clone(), ns, ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), ar),
    }
}

/// Record this activation on a resource the deploy did NOT apply.
///
/// An unchanged resource is skipped — its identity hash already matches, so
/// there is nothing to send. But it is still part of THIS activation, and
/// `kix.dev/activations` is the record of that. Without this, any resource
/// whose identity hash does not churn between deploys (ServiceAccounts,
/// ConfigMaps, import markers, leaf Services) freezes its activation set at
/// the last deploy that happened to change it, and the annotation silently
/// under-counts — it cannot be used for reference-counted GC.
///
/// Deliberately does not touch `kix.dev/applied-hash`: nothing was applied, so
/// the existing stamp is still the truth about the content on the cluster.
/// Writes nothing when the annotation already says the right thing.
pub async fn record_activation_on_skipped(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    rid: &ResourceId,
    activation_hash: &str,
    live_activations: Option<&HashSet<String>>,
) -> Result<(), ApplyError> {
    let api = api_for(client, ar, scope, rid);
    update_bookkeeping_annotations_with_retry(
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
/// If `activation_hash` is provided, the resource's `kix.dev/activations`
/// annotation is updated to include this activation (read-modify-write).
#[allow(clippy::too_many_arguments)]
pub async fn apply_resource(
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

    let api: Api<DynamicObject> = api_for(client, ar, scope, &rid);

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
    let echo = apply_patch_with_retry(&api, &name, &pp, manifest, &rid).await?;

    // Compute the applied-content hash from the SSA response echo (doc 122):
    // the echo IS the committed, canonicalized server representation, so a
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
    // `kix.dev/activations` and stamp `kix.dev/applied-hash`.
    //
    // This is a SEPARATE patch from the SSA above because we need read-modify-write
    // semantics to merge into the existing comma-separated set without clobbering
    // entries written by other activations. It traverses validating webhooks just
    // like the SSA, so a transient webhook outage (e.g. ingress-nginx admission pod
    // rolling) can fail it. We retry transient errors with backoff and surface a
    // hard failure if it still doesn't succeed — silently dropping this update
    // would corrupt reference counting and cause GC to delete the resource on the
    // next deploy.
    if !dry_run && (activation_hash.is_some() || applied_hash.is_some()) {
        update_bookkeeping_annotations_with_retry(
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

    Ok(ApplyResult {
        action,
        resource_id: rid,
    })
}

/// Retry an SSA patch on transient errors (5xx, network), surface 409 conflicts
/// as [`ApplyError::Conflict`] so the user gets an actionable message instead
/// of silently clobbering field ownership.
///
/// Returns the SSA response echo — the committed, server-canonicalized object,
/// used to compute the applied-content hash (doc 122).
async fn apply_patch_with_retry(
    api: &Api<DynamicObject>,
    name: &str,
    pp: &PatchParams,
    manifest: &Value,
    rid: &ResourceId,
) -> Result<DynamicObject, ApplyError> {
    let attempt_label = "applying resource";
    retry_kube_op(rid, attempt_label, |attempt| async move {
        let _ = attempt;
        api.patch(name, pp, &Patch::Apply(manifest)).await
    })
    .await
    .map_err(|e| classify_apply_error(rid, e))
}

/// Wrapper around [`update_bookkeeping_annotations`] that retries transient
/// failures (e.g. validating-webhook pod rolling) with capped exponential
/// backoff. Permanent errors (4xx, parse, auth) bail immediately.
/// After exhausting attempts the failure is surfaced as a hard
/// [`ApplyError::BookkeepingAnnotationsFailed`] so the deploy halts under
/// `on_error=stop` instead of silently corrupting `kix.dev/activations`
/// reference counting.
async fn update_bookkeeping_annotations_with_retry(
    api: &Api<DynamicObject>,
    name: &str,
    activation_hash: Option<&str>,
    applied_hash: Option<&str>,
    live_activations: Option<&HashSet<String>>,
    rid: &ResourceId,
) -> Result<(), ApplyError> {
    let attempt_label = "updating bookkeeping annotations";
    retry_kube_op(rid, attempt_label, |attempt| async move {
        let _ = attempt;
        update_bookkeeping_annotations(api, name, activation_hash, applied_hash, live_activations)
            .await
    })
    .await
    .map_err(|e| ApplyError::BookkeepingAnnotationsFailed {
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
async fn retry_kube_op<T, F, Fut>(
    rid: &ResourceId,
    label: &'static str,
    mut op: F,
) -> Result<T, kube::Error>
where
    F: FnMut(usize) -> Fut,
    Fut: std::future::Future<Output = Result<T, kube::Error>>,
{
    let mut backoff = PATCH_RETRY_INITIAL_BACKOFF;
    let mut last_err: Option<kube::Error> = None;

    for attempt in 1..=PATCH_RETRY_ATTEMPTS {
        match op(attempt).await {
            Ok(v) => return Ok(v),
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
/// right `ApplyError` variant. 409 Conflict → `Conflict`. 422 Invalid with an
/// immutable-field message → `ImmutableConflict`. Everything else falls
/// through to `PatchFailed`.
fn classify_apply_error(rid: &ResourceId, err: kube::Error) -> ApplyError {
    if let kube::Error::Api(ref resp) = err {
        if resp.code == 409 {
            return ApplyError::Conflict {
                resource: rid.display_id(),
                source: err,
            };
        }
        if resp.code == 422 && is_immutable_field_message(&resp.message) {
            return ApplyError::ImmutableConflict {
                resource: rid.display_id(),
                source: err,
            };
        }
    }
    ApplyError::PatchFailed {
        resource: rid.display_id(),
        source: err,
    }
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

/// Fold `activation_hash` into the comma-separated `kix.dev/activations` set,
/// dropping entries that name an activation no longer on the cluster.
///
/// The activation being deployed is always kept, even when `live` does not
/// list it: its CR is applied in the last wave, so it is legitimately absent
/// while its own resources are being stamped.
///
/// `live == None` means "could not establish the set" and disables pruning
/// entirely — keeping a dead reference is recoverable, dropping a live one is
/// not. Output is sorted and deduplicated so a re-run is byte-identical and
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
/// trips): read-modify-write `kix.dev/activations` (merge `activation_hash`
/// into the comma-separated set, drop entries naming activations that no
/// longer exist) and overwrite `kix.dev/applied-hash` with the hash computed
/// from the SSA response echo.
///
/// `live_activations`, when `Some`, is the set of identity hashes of every
/// Activation CR currently on the cluster. `None` means the set could not be
/// established, in which case nothing is pruned — a dead reference is a lesser
/// evil than dropping a live one.
async fn update_bookkeeping_annotations(
    api: &Api<DynamicObject>,
    name: &str,
    activation_hash: Option<&str>,
    applied_hash: Option<&str>,
    live_activations: Option<&HashSet<String>>,
) -> Result<(), kube::Error> {
    let mut annotations = serde_json::Map::new();

    if let Some(activation_hash) = activation_hash {
        // Read current annotation so we merge instead of clobbering entries
        // written by other activations.
        let current = api.get(name).await?;
        let existing = current
            .metadata
            .annotations
            .as_ref()
            .and_then(|a| a.get(ACTIVATIONS_ANNOTATION))
            .map(String::as_str)
            .unwrap_or("");

        let merged = merge_activation_set(existing, activation_hash, live_activations);

        // Nothing to say: skip the write rather than bump resourceVersion on
        // every unchanged resource, every deploy.
        if merged != existing || applied_hash.is_some() {
            annotations.insert(ACTIVATIONS_ANNOTATION.to_string(), Value::String(merged));
        }
    }

    if let Some(applied_hash) = applied_hash {
        annotations.insert(
            fieldsv1::APPLIED_HASH_ANNOTATION.to_string(),
            Value::String(applied_hash.to_string()),
        );
    }

    if annotations.is_empty() {
        return Ok(());
    }

    // Patch with strategic merge (not SSA — we only want to touch these
    // annotations, without disturbing kix's Apply fieldset).
    // Name the field manager explicitly: kube's default would record this write
    // under manager "unknown" in managedFields, which pollutes ownership-based
    // drift attribution (doc 122).
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
                        None,
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
