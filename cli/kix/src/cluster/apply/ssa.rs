//! Server-side apply execution and conflict classification.

use std::borrow::Cow;

use super::super::drift::{self, TakenField};
use super::super::errors::FailureClass;
use super::super::field_manager::{FieldManager, Whose};
use super::super::fieldsv1;
use super::super::kept::{self, NotKeptField};
use super::super::preview::ConflictOwner;
use crate::manifest::keys;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;

/// Errors from apply operations.
#[derive(Error, Debug)]
pub enum ApplyError {
    #[error("failed to apply {resource}: {}", reported(.source))]
    PatchFailed {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "field ownership conflict on {resource} (not updated). Another field manager owns fields that Kix sets; run the command again with `--force-conflicts` to take ownership, or declare those fields on {resource} with `ownership.cede` if the other manager should keep owning them. Kubernetes reported: {}", reported(.source)
    )]
    Conflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    /// Another Kix cluster applies the object and sets fields this apply
    /// sets to other values.
    #[error("{}", kix_cluster_conflict(.resource, .clusters, .source))]
    KixClusterConflict {
        resource: String,
        /// Each other Kix cluster named in the conflict, as its cluster
        /// name, with the fields it owns.
        clusters: Vec<ConflictOwner>,
        #[source]
        source: kube::Error,
    },

    #[error(
        "[K9044] field ownership conflict on {resource} (not updated). Another field manager owns keys in `data` with different values, so Kix did not overwrite them. Run the command again with `--force-conflicts` to write the build's values, or copy the cluster's values into `stringData` or the SOPS file and deploy again. Kubernetes reported: {}", reported(.source)
    )]
    SecretDataConflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    /// What a forced apply would take back is not what the plan showed.
    #[error(
        "{resource} was not updated because the fields Kix would take back from other field managers changed after the plan was made. Kix overwrites only the fields and live values shown in the plan. Run the command again to build a fresh plan from the live cluster."
    )]
    ChangedSincePlan { resource: String },

    /// A forced apply found the object changed between its read and its
    /// write each time it tried.
    #[error(
        "{resource} was not updated because another writer modified it on each of the {TAKEOVER_ATTEMPTS} times Kix read it to take fields back. Stop what keeps updating {resource} (or cede those fields with `ownership.cede`), then run the deploy again."
    )]
    KeepsChanging { resource: String },

    #[error(
        "immutable field changed on {resource} (not updated). Kubernetes does not allow changing this field in place, and Kix did not recreate {resource} automatically; review the impact of deleting {resource}, delete it, and run the deploy again. Kubernetes reported: {}", reported(.source)
    )]
    ImmutableConflict {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error(
        "cannot drop a stored API version from {resource} (not updated). The cluster still has objects stored at an API version removed from `spec.versions`; keep that version in `spec.versions`, or migrate the stored objects to a version {resource} still serves (by reading and re-applying each object or running a storage-version migrator) and run the deploy again. Kubernetes reported: {}", reported(.source)
    )]
    CrdStoredVersion {
        resource: String,
        #[source]
        source: kube::Error,
    },

    /// The migration write that runs before the object's first apply under
    /// this Kix cluster's manager failed ([`super::super::migration_write`]).
    #[error(transparent)]
    Migration(Box<super::super::migration_write::WriteError>),

    #[error(
        "{resource} is {reason} (not applied). Applying changes now would let Kubernetes finish deleting it after the deploy. Wait for {resource} to be removed, then run the deploy again."
    )]
    BeingDeleted {
        resource: String,
        reason: String,
        /// The uid of the object being deleted, to wait for.
        uid: Option<String>,
    },

    /// The object was being deleted and was still there after the wait.
    #[error(
        "{}",
        super::super::readiness::stuck_message(.rid, .stuck)
    )]
    StillBeingDeleted {
        rid: ResourceId,
        stuck: super::super::readiness::Stuck,
    },

    /// The cancel token fired while Kix waited for the object to be deleted.
    #[error(
        "interrupted while waiting for {resource} to finish deleting (not applied). Wait for deletion to finish, then run the deploy again."
    )]
    Interrupted { resource: String },

    #[error(
        "the API server does not serve kind `{kind}` (not applied). Check the kind and `apiVersion`, and make sure the CustomResourceDefinition for `{kind}` is installed if it is a custom resource."
    )]
    UnknownKind { kind: String },

    #[error(
        "{resource} was not applied because {expected} (declared with `kix.untrackedRef` as created outside this build) has not appeared: {detail}. Check that the controller or process expected to create {expected} is running and creates it, then run the deploy again."
    )]
    ExpectationUnmet {
        resource: String,
        expected: String,
        detail: String,
    },

    #[error(
        "{resource} is a namespaced resource on the cluster, but its manifest has no `metadata.namespace` (not applied). Create {resource} with a namespaced scope (`scope.mkResource`) or set `metadata.namespace`, then run the deploy again."
    )]
    NoNamespace { resource: String },
}

/// Return what the API server said in `e`: the message of an API error
/// without its debug form, or the whole error otherwise.
fn reported(e: &kube::Error) -> String {
    match e {
        kube::Error::Api(status) if !status.message.is_empty() => status.message.clone(),
        other => other.to_string(),
    }
}

/// Return the message of [`ApplyError::KixClusterConflict`].
fn kix_cluster_conflict(
    resource: &str,
    clusters: &[ConflictOwner],
    source: &kube::Error,
) -> String {
    let names: Vec<String> = clusters
        .iter()
        .map(|c| format!("`{}`", c.manager))
        .collect();
    let (who, next) = match names.as_slice() {
        [one] => (
            format!("Kix cluster {one} also deploys it and sets"),
            format!("the next deploy of {one}"),
        ),
        _ => (
            format!("Kix clusters {} also deploy it and set", names.join(", ")),
            "the next deploy of each of them".to_string(),
        ),
    };
    let fields: Vec<String> = clusters
        .iter()
        .filter(|c| !c.fields.is_empty())
        .map(|c| format!("Kix cluster `{}` owns {}.", c.manager, c.fields.join(", ")))
        .collect();
    let mut message =
        format!("[K5636] {resource} was not updated. {who} some of its fields to other values.");
    for line in fields {
        message.push(' ');
        message.push_str(&line);
    }
    message.push_str(&format!(
        " Each Kix cluster renders {resource} with different values, and Kubernetes rejects overwriting fields owned by another Kix cluster's field manager unless forced. Make the definitions agree, or deploy {resource} from only one Kix cluster. Running with `--force-conflicts` takes ownership for this Kix cluster, but {next} will be refused in the same way. Kubernetes reported: {}",
        reported(source)
    ));
    message
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
            super::super::discovery::find(discovery, &rid.group, &rid.kind)
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
    /// The hash of the Kix-owned fields of the object the server stored
    /// ([`fieldsv1::applied_content_hash`]). `None` for a dry run, and when
    /// the server's answer has no Kix entry in `managedFields`.
    pub applied_hash: Option<String>,
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

impl ApplyAction {
    /// Return the action's name, spelled as the deploy log serializes it.
    pub fn as_str(&self) -> &'static str {
        match self {
            ApplyAction::Created => "created",
            ApplyAction::Configured => "configured",
            ApplyAction::Unchanged => "unchanged",
            ApplyAction::Skipped => "skipped",
        }
    }
}

impl std::fmt::Display for ApplyAction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Whether an apply takes ownership of fields another field manager owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Takeover {
    /// No: an apply that would change another manager's field is refused
    /// with a conflict.
    No,
    /// Yes, whatever the object holds (`--force-conflicts`).
    Always,
    /// Yes, while the forced apply takes back exactly these fields, at these
    /// live values: what the plan showed ([`drift::taken_back`]). The apply
    /// reads the object, judges it, and sends the write with the
    /// `resourceVersion` it read, so the judgement and the write are one
    /// step. Otherwise it fails with [`ApplyError::ChangedSincePlan`].
    IfTakesBack(Vec<TakenField>),
}

/// How many times a forced apply under [`Takeover::IfTakesBack`] reads,
/// judges, and writes an object that changes between its read and its
/// write before it gives up with [`ApplyError::KeepsChanging`].
pub(crate) const TAKEOVER_ATTEMPTS: usize = 5;

/// Apply a single resource via server-side apply under `manager`.
pub(crate) async fn apply_resource(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    manager: &FieldManager,
    manifest: &Value,
    dry_run: bool,
    takeover: Takeover,
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
    let original = manifest;
    let mut manifest = string_data_as_data(manifest);

    // Default to non-force SSA so ownership conflicts return their field paths
    // and current manager. --force-conflicts opts into taking ownership.
    let mut pp = PatchParams::apply(manager.name());
    if takeover != Takeover::No {
        pp = pp.force();
    }
    if dry_run {
        pp = pp.dry_run();
    }

    let mut attempts = 0;
    let (live, echo, stripped) = loop {
        // Check if resource exists to determine Created vs Configured. A dry
        // run keeps the live object for its preview.
        let live = api.get_opt(&name).await.ok().flatten();
        if let Some(reason) = live
            .as_ref()
            .and_then(super::super::readiness::deletion_reason)
        {
            return Err(ApplyError::BeingDeleted {
                resource: rid.display_id(),
                reason,
                uid: live.as_ref().and_then(|o| o.metadata.uid.clone()),
            });
        }
        // A `resourceVersion` in the applied object makes the API server
        // refuse the apply with 409 when the object changed since that
        // version. A forced apply never conflicts on fields, so a 409 then
        // means only that, and the apply reads and judges the object again.
        if let Takeover::IfTakesBack(shown) = &takeover {
            let unchanged = live
                .as_ref()
                .is_some_and(|obj| drift::taken_back(obj, original, manager) == *shown);
            if !unchanged {
                return Err(ApplyError::ChangedSincePlan {
                    resource: rid.display_id(),
                });
            }
            let version = live
                .as_ref()
                .and_then(|o| o.metadata.resource_version.clone())
                .unwrap_or_default();
            if let Some(meta) = manifest
                .to_mut()
                .get_mut("metadata")
                .and_then(Value::as_object_mut)
            {
                meta.insert("resourceVersion".into(), Value::String(version));
            }
        }
        let sent = &*manifest;

        // Transient errors (429, 5xx, connection loss) are retried by the
        // client transport (cluster::client), not here. 409 conflicts are
        // permanent and surface immediately as ApplyError::Conflict so the
        // user sees an actionable error pointing at --force-conflicts.
        match apply_patch(&api, &name, &pp, sent, &rid).await {
            Ok(echo) => break (live, echo, None),
            Err(ApplyError::Conflict { resource, .. })
                if matches!(takeover, Takeover::IfTakesBack(_)) =>
            {
                attempts += 1;
                if attempts == TAKEOVER_ATTEMPTS {
                    return Err(ApplyError::KeepsChanging { resource });
                }
            }
            Err(ApplyError::Conflict { resource, source }) => {
                // A conflict confined to fields the resource ceded is not a
                // failure: the other manager has taken what it was meant to
                // take. Apply again without those fields and it keeps them.
                let message = match &source {
                    kube::Error::Api(resp) => resp.message.clone(),
                    _ => String::new(),
                };
                match without_ceded_conflicts(sent, &message) {
                    Some(stripped) => {
                        tracing::info!(
                            resource = %rid.display_id(),
                            fields = %conflict_paths(&message).join(", "),
                            "another manager owns ceded fields; applying without them"
                        );
                        let echo = apply_patch(&api, &name, &pp, &stripped, &rid).await?;
                        break (live, echo, Some(stripped));
                    }
                    None => return Err(conflict_error(&rid, manager, resource, source)),
                }
            }
            Err(e) => return Err(e),
        }
    };
    let existed = live.is_some();
    let manifest = &*manifest;

    let result = serde_json::to_value(&echo).unwrap_or(Value::Null);
    let not_kept = kept::not_kept(stripped.as_ref().unwrap_or(manifest), &result);

    // Compute the applied-content hash from the SSA response. Because the
    // response is the canonicalized server representation, the hash of its
    // Kix-owned projection can be compared directly against the live object on
    // later drift checks.
    let applied_hash = if dry_run {
        None
    } else {
        let h = fieldsv1::applied_content_hash(&echo, manager);
        if h.is_none() {
            tracing::warn!(
                resource = %rid.display_id(),
                manager = %manager,
                "server-side apply response has no managedFields entry for this field manager; skipping applied-hash recording"
            );
        }
        h
    };

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
        applied_hash,
    })
}

/// Return `manifest` with a Secret's `stringData` written into `data` as
/// base64, the form the API server stores. A key in both takes its
/// `stringData` value, as it does on the server.
///
/// Every apply and dry run sends this form. The server never stores
/// `stringData`, so a field manager that applies it owns no stored field.
/// Sent as `data`, each key belongs to Kix: a key removed from the build is
/// removed from the cluster, and a key another manager changed is a conflict.
/// Any other manifest is returned unchanged, and so is a Secret whose
/// `stringData` or `data` is not a map of strings, which the server refuses
/// with its own message.
pub(crate) fn string_data_as_data(manifest: &Value) -> Cow<'_, Value> {
    use base64::Engine as _;

    if !crate::manifest::types::is_secret(manifest) {
        return Cow::Borrowed(manifest);
    }
    let Some(Value::Object(strings)) = manifest.get("stringData") else {
        return Cow::Borrowed(manifest);
    };
    let data_is_map = matches!(
        manifest.get("data"),
        None | Some(Value::Null | Value::Object(_))
    );
    if !data_is_map || !strings.values().all(Value::is_string) {
        return Cow::Borrowed(manifest);
    }
    let mut data = match manifest.get("data") {
        Some(Value::Object(data)) => data.clone(),
        _ => serde_json::Map::new(),
    };
    for (key, value) in strings {
        let text = value.as_str().unwrap_or_default();
        let encoded = base64::engine::general_purpose::STANDARD.encode(text);
        data.insert(key.clone(), Value::String(encoded));
    }
    let mut out = manifest.clone();
    if let Some(obj) = out.as_object_mut() {
        obj.remove("stringData");
        if !strings.is_empty() {
            obj.insert("data".into(), Value::Object(data));
        }
    }
    Cow::Owned(out)
}

/// Return the error for a conflict that no ceded field explains, met by an
/// apply under `manager`. A conflict with another Kix cluster's manager gets
/// [`ApplyError::KixClusterConflict`], which names that cluster. A conflict
/// on a Secret's `data` gets [`ApplyError::SecretDataConflict`], which says
/// what overwriting the other manager's values means.
pub(super) fn conflict_error(
    rid: &ResourceId,
    manager: &FieldManager,
    resource: String,
    source: kube::Error,
) -> ApplyError {
    let message = match &source {
        kube::Error::Api(resp) => resp.message.as_str(),
        _ => "",
    };
    let clusters: Vec<ConflictOwner> = crate::cluster::preview::conflict_owners(message)
        .into_iter()
        .filter_map(|owner| match manager.whose(&owner.manager) {
            Whose::OtherCluster(cluster) => Some(ConflictOwner {
                manager: cluster.to_string(),
                fields: owner.fields,
            }),
            Whose::This | Whose::Legacy | Whose::NotKix => None,
        })
        .collect();
    if !clusters.is_empty() {
        return ApplyError::KixClusterConflict {
            resource,
            clusters,
            source,
        };
    }
    let on_data = conflict_paths(message)
        .iter()
        .any(|p| p == ".data" || p.starts_with(".data."));
    if on_data && rid.group_kind() == crate::manifest::kinds::SECRET {
        ApplyError::SecretDataConflict { resource, source }
    } else {
        ApplyError::Conflict { resource, source }
    }
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

/// One segment of an API server field path: `.spec`, `[name="x"]`,
/// `[containerPort=53,protocol="UDP"]`, `[0]`, or `[*]` (matching any list
/// element in a `kix.run/cede-fields` declaration).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Seg {
    Field(String),
    /// A list element picked by the values of its key fields, in the order
    /// the path names them.
    Key(Vec<(String, Value)>),
    Index(usize),
    Any,
}

/// Return whether the list element `item` has every key value in `keys`.
fn picks(keys: &[(String, Value)], item: &Value) -> bool {
    keys.iter().all(|(k, v)| item.get(k) == Some(v))
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
                Seg::Key(key_values(inner)?)
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

/// Parse the key fields of a list element, `containerPort=53,protocol="UDP"`.
/// The API server writes each value as JSON. A value that is not JSON, such
/// as `name=x` in a `kix.run/cede-fields` declaration, is read as a string.
fn key_values(inner: &str) -> Option<Vec<(String, Value)>> {
    split_outside(inner, |c| c == ',')
        .into_iter()
        .map(|pair| {
            let (k, v) = pair.split_once('=')?;
            let v = serde_json::from_str(v).unwrap_or_else(|_| Value::String(v.to_string()));
            Some((k.to_string(), v))
        })
        .collect()
}

/// Split `text` at each character `at` accepts, except inside brackets or a
/// double-quoted string, so a list key such as
/// `[containerPort=53,protocol="UDP"]` stays in one piece.
fn split_outside(text: &str, at: impl Fn(char) -> bool) -> Vec<&str> {
    let mut pieces = Vec::new();
    let (mut depth, mut quoted, mut escaped) = (0usize, false, false);
    let mut start = 0;
    for (i, c) in text.char_indices() {
        if quoted {
            match c {
                _ if escaped => escaped = false,
                '\\' => escaped = true,
                '"' => quoted = false,
                _ => {}
            }
            continue;
        }
        match c {
            '"' => quoted = true,
            '[' => depth += 1,
            ']' => depth = depth.saturating_sub(1),
            _ if depth == 0 && at(c) => {
                pieces.push(&text[start..i]);
                start = i + c.len_utf8();
            }
            _ => {}
        }
    }
    pieces.push(&text[start..]);
    pieces
}

/// Parse the field paths declared in `manifest`'s `kix.run/cede-fields`
/// annotation.
pub(crate) fn ceded_fields(manifest: &Value) -> Vec<Vec<Seg>> {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::CEDE_FIELDS))
        .and_then(Value::as_str)
        .map(|s| {
            split_outside(s, |c| c == ',')
                .into_iter()
                .filter_map(|p| parse_path(p.trim()))
                .collect()
        })
        .unwrap_or_default()
}

/// Extract the dot-prefixed field paths named in `text`, part or all of an
/// HTTP 409 conflict message (for example,
/// `conflict with "cdi-operator" using v1: .spec.versions`).
pub(crate) fn conflict_paths(text: &str) -> Vec<String> {
    split_outside(text, |c| c.is_whitespace() || c == ',')
        .into_iter()
        .filter(|t| t.len() > 1 && t.starts_with('.'))
        .map(str::to_string)
        .collect()
}

/// Return `true` if `ceded` is a prefix of `path`, where [`Seg::Any`] (`[*]`)
/// matches any list key or index segment.
pub(crate) fn covers(ceded: &[Seg], path: &[Seg]) -> bool {
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
        Seg::Key(keys) => v.as_array_mut()?.iter_mut().find(|e| picks(keys, e)),
        Seg::Any => None,
    }
}

/// Remove the field at `path` from `v`, and return whether it was there.
pub(crate) fn remove_path(v: &mut Value, path: &[Seg]) -> bool {
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
            Seg::Key(keys) => v.as_array_mut().is_some_and(|a| {
                let before = a.len();
                a.retain(|e| !picks(keys, e));
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

/// Remove from `v` every field `ceded` covers. A [`Seg::Any`] segment covers
/// each element of a list.
pub(crate) fn remove_covered(v: &mut Value, ceded: &[Seg]) {
    match ceded {
        [] => {}
        [Seg::Any] => {
            if let Some(items) = v.as_array_mut() {
                items.clear();
            }
        }
        [last] => {
            remove_path(v, std::slice::from_ref(last));
        }
        [Seg::Any, rest @ ..] => {
            for item in v.as_array_mut().into_iter().flatten() {
                remove_covered(item, rest);
            }
        }
        [Seg::Key(keys), rest @ ..] => {
            for item in v.as_array_mut().into_iter().flatten() {
                if picks(keys, item) {
                    remove_covered(item, rest);
                }
            }
        }
        [head, rest @ ..] => {
            if let Some(child) = step_mut(v, head) {
                remove_covered(child, rest);
            }
        }
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
