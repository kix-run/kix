//! Server-side apply execution, conflict classification, and bookkeeping annotations.

use std::collections::HashSet;

use super::super::errors::FailureClass;
use super::super::fieldsv1;
use super::super::kept::{self, NotKeptField};
use crate::manifest::keys;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

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

/// Return `true` if `rid` has a namespaced kind (`scope == Scope::Namespaced`)
/// but is keyed as [`CLUSTER_SCOPED`] because its manifest omits
/// `metadata.namespace`.
///
/// [`apply_resource`] rejects such manifests so the API server does not store
/// them in the client's default namespace where later diffs against the build
/// would not find them.
pub(crate) fn is_namespaceless(scope: &Scope, rid: &ResourceId) -> bool {
    matches!(scope, Scope::Namespaced) && rid.namespace == CLUSTER_SCOPED
}

/// Return the resources in `rids` that [`apply_resource`] would reject with
/// [`ApplyError::NoNamespace`] according to `discovery`.
///
/// Kinds not yet present in `discovery` (such as CRDs created by the same
/// deploy) are skipped.
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
pub(crate) struct ApplyResult {
    /// Action taken during apply.
    pub action: ApplyAction,
    /// Server-side dry-run preview, or `None` for a live apply or a dry run
    /// that did not reach the API server.
    pub preview: Option<Box<ApplyPreview>>,
    /// Fields of the applied manifest the server did not store as sent
    /// ([`kept::not_kept`]).
    pub not_kept: Vec<NotKeptField>,
}

/// Live and dry-run result objects compared by a dry-run apply.
///
/// Both fields hold full objects as returned by the API server (including
/// `managedFields` and `Secret` values), so callers displaying them must redact
/// secret data.
#[derive(Debug, Clone)]
pub struct ApplyPreview {
    /// Live object before the apply, or `None` if the apply would create it.
    pub live: Option<Value>,
    pub result: Value,
    /// Fields of the manifest sent that `result` does not keep as sent.
    pub not_kept: Vec<NotKeptField>,
}

/// Action taken during apply, serialized in `snake_case` in the deploy log.
#[derive(
    Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum ApplyAction {
    /// Resource was created.
    Created,
    /// Resource was updated because its identity-hash changed.
    Configured,
    /// Resource was skipped because its identity-hash matched.
    Unchanged,
    /// Resource was skipped for another reason.
    Skipped,
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
    let api = super::super::discovery::api_for(client, ar, &scope, rid);
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
    let api: Api<DynamicObject> = super::super::discovery::api_for(client, ar, &scope, &rid);

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
    let (echo, stripped) = match apply_patch(&api, &name, &pp, manifest, &rid).await {
        Ok(echo) => (echo, None),
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
                    let echo = apply_patch(&api, &name, &pp, &stripped, &rid).await?;
                    (echo, Some(stripped))
                }
                None => return Err(ApplyError::Conflict { resource, source }),
            }
        }
        Err(e) => return Err(e),
    };

    let result = serde_json::to_value(&echo).unwrap_or(Value::Null);
    let not_kept = kept::not_kept(stripped.as_ref().unwrap_or(manifest), &result);

    // Compute the applied-content hash from the SSA response. Because the
    // response is the canonicalized server representation, the hash of its
    // Kix-owned projection can be compared directly against the live object on
    // later drift checks.
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

    // Update Kix bookkeeping annotations by merging the current activation into
    // `kix.run/activations` and stamping `kix.run/applied-hash`.
    //
    // Uses a separate read-modify-write merge patch so existing entries in the
    // comma-separated `kix.run/activations` set written by other activations
    // are preserved. If the patch fails after transport retries, surface a hard
    // error because dropping this update would leave reference counts incomplete
    // for garbage collection.
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
            result,
            not_kept: not_kept.clone(),
        })
    });
    Ok(ApplyResult {
        action,
        preview,
        not_kept,
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

/// Call [`update_bookkeeping_annotations`] and map errors to
/// [`ApplyError::BookkeepingAnnotationsFailed`].
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

/// One segment of an API server field path: `.spec`, `[name="x"]`, `[0]`, or
/// `[*]` (matching any list element in a `kix.run/cede-fields` declaration).
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Seg {
    Field(String),
    Key(String, String),
    Index(usize),
    Any,
}

/// Parse a field path such as `.webhooks[name="x"].rules` (with an optional
/// leading dot) into segments, returning `None` if malformed.
pub(super) fn parse_path(path: &str) -> Option<Vec<Seg>> {
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

/// Parse the field paths declared in `manifest`'s `kix.run/cede-fields`
/// annotation.
fn ceded_fields(manifest: &Value) -> Vec<Vec<Seg>> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::CEDE_FIELDS))
        .and_then(Value::as_str)
        .map(|s| s.split(',').filter_map(|p| parse_path(p.trim())).collect())
        .unwrap_or_default()
}

/// Extract the dot-prefixed field paths named in an HTTP 409 conflict message
/// (for example, `conflict with "cdi-operator" using v1: .spec.versions`).
pub(super) fn conflict_paths(message: &str) -> Vec<String> {
    message
        .split(|c: char| c.is_whitespace() || c == ',')
        .filter(|t| t.len() > 1 && t.starts_with('.'))
        .map(str::to_string)
        .collect()
}

/// Return `true` if `ceded` is a prefix of `path`, where [`Seg::Any`] (`[*]`)
/// matches any list key or index segment.
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

/// Strip the conflicting fields named in `message` from `manifest` if every
/// conflicting path is covered by `kix.run/cede-fields`. Return `None` if no
/// fields are ceded, `message` names no field paths, or any conflicting path
/// falls outside the ceded declaration.
pub(super) fn without_ceded_conflicts(manifest: &Value, message: &str) -> Option<Value> {
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

/// Classify a `kube::Error` from a server-side apply patch into the
/// corresponding [`ApplyError`] variant.
///
/// Maps HTTP 409 conflicts to [`ApplyError::Conflict`], HTTP 422 stored-version
/// errors to [`ApplyError::CrdStoredVersion`], HTTP 422 immutable-field errors
/// to [`ApplyError::ImmutableConflict`], and all other errors to
/// [`ApplyError::PatchFailed`].
fn classify_apply_error(rid: &ResourceId, err: kube::Error) -> ApplyError {
    match super::super::errors::classify(&err) {
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
pub(super) fn is_stored_version_message(msg: &str) -> bool {
    msg.contains("status.storedVersions")
}

/// Detect the wire-format signatures the API server uses to reject updates to
/// immutable spec fields. Kept as a substring match because the error bodies
/// are free-form and vary per kind (Job uses "field is immutable", StatefulSet
/// "updates to statefulset spec for fields other than", Service "field is
/// immutable", etc).
pub(super) fn is_immutable_field_message(msg: &str) -> bool {
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
pub(super) fn merge_activation_set(
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

/// Update Kix's bookkeeping annotations in a single merge patch: merge
/// `activation_hash` into `kix.run/activations` (dropping entries that are not
/// in `live_activations`) and set `kix.run/applied-hash` when provided.
///
/// When `live_activations` is `None`, existing activation references are
/// retained without pruning.
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
        let current = api.get(name).await?;
        let existing = current
            .metadata
            .annotations
            .as_ref()
            .and_then(|a| keys::get_meta(a, keys::ACTIVATIONS))
            .unwrap_or("");

        let merged = merge_activation_set(existing, activation_hash, live_activations);

        // Skip writing when the merged set is unchanged and no new applied-hash
        // is being recorded, avoiding unnecessary resourceVersion bumps.
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

    // Because bookkeeping annotations are written via merge patch rather than
    // server-side apply, explicitly null out any retired domain keys for the
    // annotations replaced by this patch.
    let writing: Vec<&str> = annotations.keys().map(String::as_str).collect();
    for old in crate::legacy_domain::bookkeeping_null_outs(&writing) {
        annotations.insert(old, Value::Null);
    }

    // On a full apply (`applied_hash.is_some()`), also null out any retired
    // build-time annotation keys remaining on the live object (for example,
    // from an earlier client-side `kubectl apply` where `kix` did not own the
    // field in `managedFields`). Skip this when `applied_hash` is `None` so an
    // unapplied resource does not lose its only identity annotations.
    if applied_hash.is_some()
        && let Some(present) = live.as_ref().and_then(|o| o.metadata.annotations.as_ref())
    {
        for old in crate::legacy_domain::retired_keys(present) {
            annotations.insert(old, Value::Null);
        }
    }

    // Use a merge patch with `FIELD_MANAGER` so the update does not alter Kix's
    // server-side apply field set or record an "unknown" manager in `managedFields`.
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
