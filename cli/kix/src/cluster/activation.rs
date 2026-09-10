//! Activation CR lifecycle management.
//!
//! The Activation CR is the cluster-level record of "what is deployed."
//! This module manages the state machine:
//!
//! ```text
//! deploy starts   → Deploying (the record is created before the first wave)
//! deploy succeeds → Active
//! deploy stops    → Failed (nothing else moves it; the next deploy folds it in)
//! new deploy      → old becomes Superseded, new becomes Active
//! kix gc          → Superseded gets deleted (after its orphaned resources are cleaned up)
//! kix rollback    → current becomes Superseded, target becomes Active
//! ```
//!
//! The record is created at the start of the deploy, not at the end. It is
//! also a node of the plan, and by construction the last one: its spec lists
//! every PackageInstance, so its identity hash is the root of the closure's
//! Merkle tree. Creating it early and re-asserting it in the last wave keeps
//! that property while making a deploy that dies mid-wave leave a truthful
//! record of what it was attempting. Without it the next deploy has no way to
//! know that anything was applied at all (kixpkgs#82).

use crate::manifest::keys;
use kube::{
    api::{Api, DynamicObject, ListParams, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::{Value, json};
use thiserror::Error;

/// Activation phase values (stored in status.phase).
pub const PHASE_QUEUED: &str = "Queued";
pub const PHASE_ACTIVE: &str = "Active";
pub const PHASE_SUPERSEDED: &str = "Superseded";
pub const PHASE_DEPLOYING: &str = "Deploying";
/// Deploy completed but some resources failed to apply or become ready.
/// Treated as the "current state" for diffing/drift purposes: the next deploy
/// must be able to find this CR to compute a meaningful plan.
pub const PHASE_DEGRADED: &str = "Degraded";
/// The deploy stopped before it could finalize: cancelled, a node failed under
/// a Stop policy, discovery broke, or the process died and something later
/// marked the record.
///
/// Terminal, and deliberately NOT a current state. [`find_active`] must never
/// return one: a half-applied closure is not what the cluster is running, and
/// diffing against it would compute every object only the still-Active closure
/// has as an orphan. The next deploy reads it only as an extra baseline, to
/// re-apply what it may have changed and prune what it left behind, and
/// supersedes it once that plan finalizes.
pub const PHASE_FAILED: &str = "Failed";

#[derive(Error, Debug)]
pub enum ActivationError {
    #[error("Activation CRD not registered on cluster")]
    CrdNotRegistered,

    #[error("failed to list activations: {0}")]
    ListFailed(#[source] kube::Error),

    #[error("failed to patch activation '{name}': {source}")]
    PatchFailed {
        name: String,
        #[source]
        source: kube::Error,
    },
}

/// Info about the currently Active activation on the cluster.
#[derive(Debug, Clone)]
pub struct ActiveActivation {
    /// The resource name of the active Activation CR.
    pub name: String,
    /// The identity-hash annotation value.
    pub identity_hash: Option<String>,
    /// Store path of the activation result dir (contains kix-packages.json).
    pub built_via: Option<String>,
}

/// Find the Activation ApiResource from discovery results.
pub fn find_activation_ar(
    discovery: &[(ApiResource, Scope)],
) -> Result<Option<&(ApiResource, Scope)>, crate::legacy_domain::LegacyDomainError> {
    // The gate. A cluster whose records still sit under a retired group is
    // refused here, so every command that reads a record is covered: deploy,
    // rollback, gc, health, status and the operator.
    let groups: Vec<&str> = discovery
        .iter()
        .filter(|(ar, _)| crate::manifest::lifecycle::is_record_kind(&ar.kind))
        .map(|(ar, _)| ar.group.as_str())
        .collect();
    crate::legacy_domain::check_cluster(&groups)?;
    Ok(find_current_activation_ar(discovery))
}

/// The Activation `ApiResource` under the current group, if discovery has it.
fn find_current_activation_ar(discovery: &[(ApiResource, Scope)]) -> Option<&(ApiResource, Scope)> {
    discovery.iter().find(|(ar, _)| {
        crate::manifest::lifecycle::is_record_kind(&ar.kind) && ar.group == keys::GROUP
    })
}

/// Every record this cluster owns, whatever its phase.
///
/// One place that knows the label selector, so a new phase reader does not
/// copy it a fifth time.
async fn list_cluster_records(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<DynamicObject>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{}={cluster_name}",
        keys::CLUSTER_LABEL
    ));
    Ok(api
        .list(&lp)
        .await
        .map_err(ActivationError::ListFailed)?
        .items)
}

/// A record's `kix.run/deployed-at`, parsed, or None when it is absent or
/// malformed. A record that never finished a deploy has none.
fn parsed_deployed_at(item: &DynamicObject) -> Option<chrono::DateTime<chrono::Utc>> {
    item.metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::DEPLOYED_AT))
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|t| t.with_timezone(&chrono::Utc))
}

/// Which of several current records is *the* current one.
///
/// A cluster should only ever hold one Active or Degraded record, but nothing
/// enforces that: a partial supersede, two deploys racing, or a hand-edited
/// status can all leave two. Picking whichever the apiserver listed first
/// makes the plan depend on list order, so the newest `deployed-at` wins and
/// the name breaks ties. Split out from [`find_active`] so it can be tested
/// without a cluster.
fn pick_current<T>(
    mut candidates: Vec<(T, Option<chrono::DateTime<chrono::Utc>>, String)>,
) -> Option<T> {
    // Newest first; a record with no usable timestamp sorts oldest.
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
    candidates.into_iter().next().map(|(value, _, _)| value)
}

/// Find the current Active activation for a given cluster.
///
/// Returns None if no current activation exists (first deploy).
/// Matches `status.phase` against `Active` or `Degraded`, both of which
/// represent "the cluster's current state" for diffing purposes. A Degraded
/// activation is one whose deploy completed with some resource failures; it is
/// still the most recent description of intended state and the next deploy
/// should diff against it instead of treating the cluster as empty.
///
/// `Failed` is deliberately not matched. That record describes a deploy that
/// stopped part way, so it is not what the cluster is running, and diffing
/// against it would read every object only the Active closure has as an
/// orphan. `Deploying` is not matched either: it is in flight.
pub async fn find_active(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Option<ActiveActivation>, ActivationError> {
    let items = list_cluster_records(client, ar, cluster_name).await?;

    let mut candidates = Vec::new();
    for item in &items {
        let phase = read_phase(item);
        if phase != PHASE_ACTIVE && phase != PHASE_DEGRADED {
            continue;
        }
        let name = item.metadata.name.clone().unwrap_or_default();
        let annotations = item.metadata.annotations.as_ref();
        let identity_hash = annotations
            .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
            .map(str::to_string);
        let built_via = annotations
            .and_then(|a| keys::get_meta(a, keys::BUILT_VIA))
            .map(str::to_string);
        candidates.push((
            ActiveActivation {
                name: name.clone(),
                identity_hash,
                built_via,
            },
            parsed_deployed_at(item),
            name,
        ));
    }

    if candidates.len() > 1 {
        let names: Vec<&str> = candidates.iter().map(|c| c.2.as_str()).collect();
        tracing::warn!(
            cluster = %cluster_name,
            records = ?names,
            "more than one Active or Degraded record; using the most recently deployed",
        );
    }

    Ok(pick_current(candidates))
}

/// A record left behind by a deploy that stopped before it finalized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FailedActivation {
    pub name: String,
    /// The identity-hash annotation value. Without it the record cannot be
    /// resolved to a closure and the caller can only warn.
    pub identity_hash: Option<String>,
    /// Store path of the activation result dir (contains kix-packages.json).
    pub built_via: Option<String>,
    /// `status.failure.reason`, for the message the next deploy prints.
    pub reason: Option<String>,
    /// `status.failure.at`, RFC 3339. Also the retention sort key once the
    /// record is superseded, since it has no `deployed-at`.
    pub failed_at: Option<String>,
}

/// Every Failed record for a cluster, oldest first.
///
/// Oldest first because that is the order a deploy consumed them in, so a
/// stack of them folds into the baseline the same way it accumulated.
pub async fn find_failed(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<FailedActivation>, ActivationError> {
    let items = list_cluster_records(client, ar, cluster_name).await?;

    let mut results: Vec<FailedActivation> = items
        .iter()
        .filter(|item| read_phase(item) == PHASE_FAILED)
        .filter_map(|item| {
            let name = item.metadata.name.clone()?;
            let annotations = item.metadata.annotations.as_ref();
            Some(FailedActivation {
                name,
                identity_hash: annotations
                    .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
                    .map(str::to_string),
                built_via: annotations
                    .and_then(|a| keys::get_meta(a, keys::BUILT_VIA))
                    .map(str::to_string),
                reason: item
                    .data
                    .pointer("/status/failure/reason")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
                failed_at: item
                    .data
                    .pointer("/status/failure/at")
                    .and_then(|v| v.as_str())
                    .map(str::to_string),
            })
        })
        .collect();

    results.sort_by(|a, b| {
        a.failed_at
            .cmp(&b.failed_at)
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(results)
}

/// A record whose deploy is still in flight, or was when it last wrote.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeployingActivation {
    pub name: String,
    pub identity_hash: Option<String>,
    /// `metadata.creationTimestamp`, the only age a Deploying record has.
    pub created_at: Option<String>,
    /// True when `spec.source` is set, which the operator writes and the CLI
    /// does not. The discriminator for "who is driving this deploy".
    pub operator_driven: bool,
}

/// Every Deploying record for a cluster, oldest first.
pub async fn find_deploying(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<DeployingActivation>, ActivationError> {
    let items = list_cluster_records(client, ar, cluster_name).await?;

    let mut results: Vec<DeployingActivation> = items
        .iter()
        .filter(|item| read_phase(item) == PHASE_DEPLOYING)
        .filter_map(|item| {
            let name = item.metadata.name.clone()?;
            Some(DeployingActivation {
                name,
                identity_hash: item
                    .metadata
                    .annotations
                    .as_ref()
                    .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
                    .map(str::to_string),
                created_at: item
                    .metadata
                    .creation_timestamp
                    .as_ref()
                    .map(|t| t.0.to_rfc3339()),
                operator_driven: item.data.pointer("/spec/source").is_some(),
            })
        })
        .collect();

    results.sort_by(|a, b| {
        a.created_at
            .cmp(&b.created_at)
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(results)
}

/// After a deploy, update the activation lifecycle:
/// 1. Mark the old activation as Superseded (status.phase=Superseded)
/// 2. Set kix.run/previous on the new activation pointing to the old one
/// 3. Set kix.run/deployed-at timestamp on the new activation
/// 4. Set the new activation phase: `Active` on a clean deploy, `Degraded` if
///    `had_failures` is true. Either way, it becomes the cluster's current
///    state — the next deploy must be able to find it via `find_active` to
///    compute a meaningful diff. Marking it Active despite failures would
///    misrepresent the state; refusing to finalize at all (the previous
///    behavior) leaves an orphaned Activation that nothing can find.
/// 5. Add kix.run/cluster label for filtering (also stamped at build time
///    via `mkActivation`, but re-asserted here for older CRs).
/// 6. Mark every Failed record this deploy folded into its plan as
///    Superseded, since its leftovers have now been reconciled.
/// 7. Write the deploy receipt into status, when the caller computed one.
///    Status rather than spec on purpose: the status subresource is untouched
///    by an apply of the main resource, so a later rollback that re-applies
///    this Activation cannot erase the record of what happened.
// Eight, and every one is a distinct type, so there is nothing here a caller
// can transpose. Following the house precedent rather than wrapping a single
// call site in a params struct.
#[allow(clippy::too_many_arguments)]
pub async fn finalize_deploy(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
    new_activation_name: &str,
    old_activation: Option<&ActiveActivation>,
    had_failures: bool,
    receipt: Option<&Value>,
    consumed_failed: &[String],
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let now = chrono::Utc::now().to_rfc3339();

    // 1. Supersede old activation
    if let Some(old) = old_activation {
        supersede_activation(client, ar, &old.name).await?;
    }

    // 1b. Supersede the Failed records this deploy folded into its plan. Their
    //     leftovers have now been re-applied or pruned, so they describe
    //     nothing outstanding and belong in history with everything else.
    //
    //     Skipping the record being finalized matters: retrying the same
    //     closure that failed reuses its name, and superseding it here would
    //     immediately undo the Active phase set below.
    //
    //     Best-effort. A record that will not supersede is cosmetic, and
    //     failing the deploy over it after every resource has landed would
    //     be a worse trade.
    for name in consumed_failed {
        if name == new_activation_name {
            continue;
        }
        if let Err(e) = supersede_activation(client, ar, name).await {
            tracing::warn!(
                activation = %name,
                error = %e,
                "could not supersede a consumed Failed record",
            );
        }
    }

    // 2. Update new activation with lifecycle annotations (merge patch to preserve
    //    kix.run/identity-hash and other annotations set during wave apply)
    let mut annotations = serde_json::Map::new();
    annotations.insert(keys::DEPLOYED_AT.to_string(), Value::String(now));
    if let Some(old) = old_activation
        && let Some(ref hash) = old.identity_hash
    {
        annotations.insert(keys::PREVIOUS.to_string(), Value::String(hash.clone()));
    }

    let spec_patch = json!({
        "metadata": {
            "labels": {
                keys::CLUSTER_LABEL: cluster_name,
            },
            "annotations": annotations,
        },
        "spec": {
            "cluster": cluster_name,
        },
    });
    api.patch(
        new_activation_name,
        &PatchParams::default(),
        &Patch::Merge(&spec_patch),
    )
    .await
    .map_err(|e| ActivationError::PatchFailed {
        name: new_activation_name.to_string(),
        source: e,
    })?;

    // 3. Set status phase with previousActivation link
    let new_phase = if had_failures {
        PHASE_DEGRADED
    } else {
        PHASE_ACTIVE
    };
    let mut status = serde_json::Map::new();
    status.insert("phase".to_string(), json!(new_phase));
    if let Some(old) = old_activation {
        status.insert("previousActivation".to_string(), json!(old.name));
    }
    if let Some(receipt) = receipt {
        status.insert(keys::RECEIPT_FIELD.to_string(), receipt.clone());
    }

    let status_patch = json!({ "status": status });
    api.patch_status(
        new_activation_name,
        &PatchParams::default(),
        &Patch::Merge(&status_patch),
    )
    .await
    .map_err(|e| ActivationError::PatchFailed {
        name: new_activation_name.to_string(),
        source: e,
    })?;

    tracing::info!(activation = %new_activation_name, phase = new_phase, "finalized");

    Ok(())
}

/// Read the deploy receipt off a cluster's active Activation.
///
/// This is the read half of the record. A deploy writes provenance into the
/// Activation's status subresource; this reads it back, so a question like
/// "what is running here and where did it come from" can be answered by
/// anyone who can reach the cluster, without the machine that built it and
/// without a rebuild.
///
/// `Ok(None)` means the cluster has an active Activation that predates
/// receipts, which is a different answer from "no such cluster" and is
/// reported as such.
pub async fn read_receipt(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Option<Value>, ActivationError> {
    let Some(active) = find_active(client, ar, cluster_name).await? else {
        return Ok(None);
    };
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let full = api
        .get(&active.name)
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: active.name.clone(),
            source: e,
        })?;
    Ok(full
        .data
        .pointer(&format!("/status/{}", keys::RECEIPT_FIELD))
        .cloned())
}

/// List all Superseded activations for a cluster.
pub async fn list_superseded(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<String>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{}={cluster_name}",
        keys::CLUSTER_LABEL
    ));

    let list = api.list(&lp).await.map_err(ActivationError::ListFailed)?;

    let mut superseded = Vec::new();
    for item in &list.items {
        let phase = item
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if phase == PHASE_SUPERSEDED
            && let Some(name) = item.metadata.name.as_deref()
        {
            superseded.push(name.to_string());
        }
    }

    Ok(superseded)
}

/// Identity hashes of every Activation CR on the cluster, across all clusters
/// and all phases.
///
/// This is the authority for pruning `kix.run/activations`: a hash in that set
/// that names no Activation here is a reference to something that no longer
/// exists. Deliberately NOT filtered by cluster label — one resource can be
/// referenced by activations of more than one cluster, and pruning another
/// cluster's live reference would be worse than keeping a dead one.
///
/// Returns `None` when the set cannot be established (CRD not yet registered,
/// list failed). Callers must treat `None` as "do not prune" rather than as an
/// empty set.
pub async fn live_activation_hashes(
    client: &Client,
    ar: &ApiResource,
) -> Option<std::collections::HashSet<String>> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let list = api
        .list(&ListParams::default())
        .await
        .map_err(|e| tracing::warn!("could not list activations, skipping prune: {e}"))
        .ok()?;

    Some(
        list.items
            .iter()
            .filter_map(|item| {
                item.metadata
                    .annotations
                    .as_ref()
                    .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
                    .map(str::to_string)
            })
            .collect(),
    )
}

/// Info about a Superseded activation, including when it was deployed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SupersededActivation {
    pub name: String,
    pub identity_hash: Option<String>,
    pub deployed_at: String,
    /// Store path of the activation result dir (contains kix-packages.json).
    pub built_via: Option<String>,
    /// Name of the activation that this one superseded, taken from
    /// `status.previousActivation`. Lets the history walk reconstruct the
    /// deploy chain for `kix rollback --list`.
    pub previous_activation: Option<String>,
    /// Server-assigned identity, so a delete can be conditional on the
    /// record being the one that was listed.
    pub uid: Option<String>,
    pub resource_version: Option<String>,
    /// `status.failure.at`, present when this record was superseded out of
    /// `Failed` rather than out of `Active`. Such a record never deployed, so
    /// it has no `deployed-at`, and this is the honest age to sort it by.
    pub failed_at: Option<String>,
    /// `metadata.creationTimestamp`, the last resort when neither timestamp
    /// above is present.
    pub created_at: Option<String>,
}

/// List all Superseded activations for a cluster, sorted by deployed-at (most
/// recent first).
///
/// Every Superseded record, including ones that never finished a deploy, so
/// that `kix gc` can retire them: a listing that hid them would leave a
/// permanent record for every failed deploy, each keeping a hash alive in the
/// `kix.run/activations` annotation of everything it stamped.
///
/// A caller choosing a rollback target must filter with
/// [`SupersededActivation::was_ever_current`] first.
pub async fn list_superseded_activations(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<SupersededActivation>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{}={cluster_name}",
        keys::CLUSTER_LABEL
    ));

    let list = api.list(&lp).await.map_err(ActivationError::ListFailed)?;

    let mut results = Vec::new();

    for item in &list.items {
        let phase = item
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if phase != PHASE_SUPERSEDED {
            continue;
        }

        // A record that carries a failure never finished a deploy. It is
        // Superseded because a later deploy folded its leftovers in, not
        // because it was ever the cluster's state, so it is not a rollback
        // target and must not count toward the retention floor of "newest
        // targets to keep". `begin_deploy` clears the field on a retry, so a
        // record that failed and then succeeded is not caught here.
        if item
            .data
            .pointer("/status/failure")
            .is_some_and(|v| !v.is_null())
        {
            continue;
        }

        let name = match item.metadata.name.as_deref() {
            Some(n) => n.to_string(),
            None => continue,
        };

        let annotations = item.metadata.annotations.as_ref();
        let identity_hash = annotations
            .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
            .map(str::to_string);

        let deployed_at = annotations
            .and_then(|a| keys::get_meta(a, keys::DEPLOYED_AT))
            .map(str::to_string)
            .unwrap_or_default();

        let built_via = annotations
            .and_then(|a| keys::get_meta(a, keys::BUILT_VIA))
            .map(str::to_string);

        let previous_activation = item
            .data
            .pointer("/status/previousActivation")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        results.push(SupersededActivation {
            name,
            identity_hash,
            deployed_at,
            built_via,
            previous_activation,
            uid: item.metadata.uid.clone(),
            resource_version: item.metadata.resource_version.clone(),
            failed_at: item
                .data
                .pointer("/status/failure/at")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            created_at: item
                .metadata
                .creation_timestamp
                .as_ref()
                .map(|ts| ts.0.to_rfc3339()),
        });
    }

    // Most recent first, by whichever timestamp the record actually has.
    results.sort_by(|a, b| {
        deployed_at(b)
            .cmp(&deployed_at(a))
            .then_with(|| a.name.cmp(&b.name))
    });

    Ok(results)
}

/// Defaults for [`RetentionPolicy`]: always keep the 10 newest records,
/// never more than 50, and retire anything older than 30 days beyond the
/// floor. Helm 3 and Argo CD keep 10 by default; the cap and the age rule
/// exist because each record still on the cluster keeps one hash alive in
/// `kix.run/activations` on every managed resource, and that annotation is
/// capped at 256 KiB.
pub const DEFAULT_KEEP_MIN: usize = 10;
pub const DEFAULT_KEEP_MAX: usize = 50;
pub const DEFAULT_KEEP_FOR_DAYS: i64 = 30;

/// How many Superseded records to keep, by count and by age.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetentionPolicy {
    /// Always keep this many of the newest, whatever their age.
    pub keep_min: usize,
    /// Never keep more than this many.
    pub keep_max: usize,
    /// Beyond `keep_min`, retire records older than this. `None` disables
    /// the age rule.
    pub keep_for: Option<chrono::Duration>,
    /// The clock the age rule uses. Injected so plans are testable.
    pub now: chrono::DateTime<chrono::Utc>,
}

impl SupersededActivation {
    /// Whether this record was ever the cluster's state, and so whether it is
    /// a legitimate rollback target.
    ///
    /// `kix.run/deployed-at` is written by [`finalize_deploy`] and nothing
    /// else, so it is present exactly when a deploy of this closure ran to
    /// completion. A record superseded out of `Failed` has none, and applying
    /// it would put the cluster into a state it has never been in.
    ///
    /// Deliberately not "does it carry a `status.failure`". A rollback
    /// re-asserts its target's record and marks it Deploying, so a rollback
    /// that is then interrupted leaves a failure on a record that really was
    /// current once, and that record is still a valid target.
    pub fn was_ever_current(&self) -> bool {
        !self.deployed_at.trim().is_empty()
    }
}

impl RetentionPolicy {
    pub fn defaults(now: chrono::DateTime<chrono::Utc>) -> Self {
        Self {
            keep_min: DEFAULT_KEEP_MIN,
            keep_max: DEFAULT_KEEP_MAX,
            keep_for: Some(chrono::Duration::days(DEFAULT_KEEP_FOR_DAYS)),
            now,
        }
    }
}

/// Why a record is retired.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetireReason {
    /// Past the `keep_max` newest.
    BeyondMax(usize),
    /// Older than `keep_for` and past the `keep_min` newest.
    OlderThan(chrono::Duration),
    /// No usable timestamp at all, so its age is unknown and it sorts oldest.
    /// A record that never finished a deploy still has `status.failure.at` or
    /// a creation timestamp to go on (see [`deployed_at`]), so reaching this
    /// means every one of those was missing or malformed.
    UnknownAge,
}

impl std::fmt::Display for RetireReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RetireReason::BeyondMax(n) => write!(f, "beyond the {n} newest"),
            RetireReason::OlderThan(d) => write!(f, "older than {}", humanize(*d)),
            RetireReason::UnknownAge => write!(f, "no deployed-at"),
        }
    }
}

/// `30d`, `12h`, `45m`, `30s`: the largest unit that divides evenly.
pub fn humanize(d: chrono::Duration) -> String {
    let secs = d.num_seconds();
    if secs > 0 && secs % 86_400 == 0 {
        format!("{}d", secs / 86_400)
    } else if secs > 0 && secs % 3_600 == 0 {
        format!("{}h", secs / 3_600)
    } else if secs > 0 && secs % 60 == 0 {
        format!("{}m", secs / 60)
    } else {
        format!("{secs}s")
    }
}

/// A record the plan retires, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Retired {
    pub record: SupersededActivation,
    pub reason: RetireReason,
}

/// Which Superseded records to keep and which to retire.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Retirement {
    /// Records that stay, newest first. Rollback targets.
    pub kept: Vec<SupersededActivation>,
    /// Records to delete, newest first, each with its reason.
    pub retire: Vec<Retired>,
}

/// When a record last mattered, for retention ordering.
///
/// `kix.run/deployed-at` when the record finished a deploy. A record that was
/// superseded out of `Failed` never did, so it falls back to when it failed,
/// then to when it was created. Without the fallback every such record sorts
/// oldest and is retired as `UnknownAge` on the first `kix gc`, which loses
/// the history of what went wrong just when it is most wanted.
pub fn deployed_at(record: &SupersededActivation) -> Option<chrono::DateTime<chrono::Utc>> {
    let parse = |s: &str| {
        chrono::DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|t| t.with_timezone(&chrono::Utc))
    };
    parse(&record.deployed_at)
        .or_else(|| record.failed_at.as_deref().and_then(parse))
        .or_else(|| record.created_at.as_deref().and_then(parse))
}

/// Split a cluster's Superseded records into kept and retired under a
/// [`RetentionPolicy`] (`kix gc --keep`, kixpkgs#59 follow-up).
///
/// Newest first by `kix.run/deployed-at` (parsed, so offsets and precision
/// do not matter); a record whose annotation is missing or unparseable is
/// treated as the oldest. Ties break on name so the plan is deterministic.
/// Then, in order: the first `keep_min` are kept whatever their age; past
/// `keep_max` everything is retired; in between, a record is retired when
/// the age rule is on and it is older than `keep_for` (or its age is
/// unknown). The Active record is never in the input.
pub fn retire_plan(
    mut superseded: Vec<SupersededActivation>,
    policy: &RetentionPolicy,
) -> Retirement {
    let keep_max = policy.keep_max.max(policy.keep_min);
    superseded.sort_by(|a, b| {
        deployed_at(b)
            .cmp(&deployed_at(a))
            .then_with(|| a.name.cmp(&b.name))
    });
    let mut plan = Retirement::default();
    for (i, record) in superseded.into_iter().enumerate() {
        if i < policy.keep_min {
            plan.kept.push(record);
            continue;
        }
        if i >= keep_max {
            plan.retire.push(Retired {
                record,
                reason: RetireReason::BeyondMax(keep_max),
            });
            continue;
        }
        match (policy.keep_for, deployed_at(&record)) {
            (None, _) => plan.kept.push(record),
            (Some(_), None) => plan.retire.push(Retired {
                record,
                reason: RetireReason::UnknownAge,
            }),
            (Some(max_age), Some(t)) if policy.now - t > max_age => plan.retire.push(Retired {
                record,
                reason: RetireReason::OlderThan(max_age),
            }),
            (Some(_), Some(_)) => plan.kept.push(record),
        }
    }
    plan
}

/// Delete a listed record only if it is still the object that was listed
/// (same uid and resourceVersion). A status change since the listing, such
/// as a rollback making it Active again, bumps resourceVersion and the
/// apiserver refuses with 409, so nothing that changed underneath the plan
/// is deleted.
pub async fn delete_activation_if_unchanged(
    client: &Client,
    ar: &ApiResource,
    record: &SupersededActivation,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let dp = kube::api::DeleteParams {
        preconditions: Some(kube::api::Preconditions {
            uid: record.uid.clone(),
            resource_version: record.resource_version.clone(),
        }),
        ..Default::default()
    };
    api.delete(&record.name, &dp)
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: record.name.clone(),
            source: e,
        })?;
    Ok(())
}

/// Delete a Superseded activation CR (after its orphaned resources are cleaned up).
pub async fn delete_activation(
    client: &Client,
    ar: &ApiResource,
    name: &str,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    api.delete(name, &kube::api::DeleteParams::default())
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: name.to_string(),
            source: e,
        })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Phase transition helpers
// ---------------------------------------------------------------------------

/// Info about a Queued activation.
#[derive(Debug, Clone)]
pub struct QueuedActivation {
    pub name: String,
    pub identity_hash: Option<String>,
    pub created_at: Option<String>,
}

/// Queued records for a cluster, newest first.
///
/// The operator's queue, so only records it owns: `spec.source` is what it
/// writes when it adopts a deploy, and the CLI never does. Without that
/// filter a CLI record, which is phase-less for the round trip between being
/// created and being marked Deploying, reads as a queued deploy and the
/// operator supersedes either it or itself over the difference.
pub async fn find_queued(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<QueuedActivation>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{}={cluster_name}",
        keys::CLUSTER_LABEL
    ));

    let list = api.list(&lp).await.map_err(ActivationError::ListFailed)?;

    let mut queued = Vec::new();
    for item in &list.items {
        let phase = item
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        // Treat empty/missing phase as Queued (new CR without status yet).
        //
        // Only the operator's own records though. A CLI deploy creates its
        // record and marks it Deploying a round trip later, so for that
        // moment, and permanently if the process is killed in between, it
        // looks exactly like a queued deploy. Adopting one makes the operator
        // supersede either that record or itself over a deploy it is not
        // running. `spec.source` is the discriminator: the operator writes it
        // when it adopts a deploy, and the CLI never does.
        if (phase == PHASE_QUEUED || phase.is_empty())
            && item.data.pointer("/spec/source").is_some()
        {
            let name = item.metadata.name.clone().unwrap_or_default();
            let annotations = item.metadata.annotations.as_ref();
            let identity_hash = annotations
                .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
                .map(str::to_string);
            let created_at = item
                .metadata
                .creation_timestamp
                .as_ref()
                .map(|t| t.0.to_rfc3339());
            queued.push(QueuedActivation {
                name,
                identity_hash,
                created_at,
            });
        }
    }

    // Newest first (reverse chronological)
    queued.sort_by(|a, b| b.created_at.cmp(&a.created_at));

    Ok(queued)
}

/// Mark an activation as Superseded (status.phase only).
pub async fn supersede_activation(
    client: &Client,
    ar: &ApiResource,
    name: &str,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    let status_patch = json!({
        "status": {
            "phase": PHASE_SUPERSEDED,
        },
    });
    api.patch_status(name, &PatchParams::default(), &Patch::Merge(&status_patch))
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: name.to_string(),
            source: e,
        })?;

    tracing::info!(activation = %name, "marked as Superseded");
    Ok(())
}

/// Read `status.phase` from an activation.
pub fn read_phase(activation: &DynamicObject) -> &str {
    activation
        .data
        .pointer("/status/phase")
        .and_then(|v| v.as_str())
        .unwrap_or("")
}

// ---------------------------------------------------------------------------
// Wave progress persistence
// ---------------------------------------------------------------------------

/// Status of a single wave in the deploy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WaveStatus {
    Pending,
    Complete,
    Failed,
}

impl WaveStatus {
    fn as_str(&self) -> &'static str {
        match self {
            WaveStatus::Pending => "Pending",
            WaveStatus::Complete => "Complete",
            WaveStatus::Failed => "Failed",
        }
    }

    fn from_str(s: &str) -> Self {
        match s {
            "Complete" => WaveStatus::Complete,
            "Failed" => WaveStatus::Failed,
            _ => WaveStatus::Pending,
        }
    }
}

/// The phase a record should move to when a deploy begins, or None to leave
/// it where it is.
///
/// Re-deploying the closure that is already current hits this with an `Active`
/// record, and that record must keep its phase. Demoting it to `Deploying`
/// means a run that then dies leaves the cluster with no current record at
/// all, and the next deploy plans as a first deploy: no orphans, no repairs.
/// Everything else is either not current or already in flight, so it is safe
/// to mark.
fn phase_on_begin(current: &str) -> Option<&'static str> {
    match current {
        PHASE_ACTIVE | PHASE_DEGRADED => None,
        _ => Some(PHASE_DEPLOYING),
    }
}

/// The phase a record should move to when a deploy stops without finalizing,
/// or None to leave it alone.
///
/// Only a record this run put into `Deploying` is ours to fail. One left
/// `Active` by [`phase_on_begin`] is still the truthful current state and must
/// stay that way.
fn phase_on_abort(current: &str) -> Option<&'static str> {
    match current {
        PHASE_DEPLOYING => Some(PHASE_FAILED),
        // No phase at all means the record was created and the run died
        // before it could be marked, which only this run can have done: the
        // create and the mark are two round trips inside `begin`. Leaving it
        // blank would make it invisible to every reader, which is the hole
        // this whole change exists to close.
        //
        // `Queued` is excluded on purpose. That is somebody's stated intent,
        // usually the operator's, and not ours to overwrite.
        "" => Some(PHASE_FAILED),
        _ => None,
    }
}

/// Read one record's `status.phase`, or "" when it has none yet.
async fn read_record_phase(
    client: &Client,
    ar: &ApiResource,
    name: &str,
) -> Result<String, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let item = api
        .get(name)
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: name.to_string(),
            source: e,
        })?;
    Ok(read_phase(&item).to_string())
}

/// Set the Activation phase to Deploying and initialize wave status.
///
/// Called at the start of the apply loop, after the record itself has been
/// created. Sets `status.phase = Deploying` and `status.totalWaves = n`,
/// unless the record is the current one being re-deployed (see
/// [`phase_on_begin`]), in which case only the wave counters are reset.
pub async fn begin_deploy(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    total_waves: usize,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    let current = read_record_phase(client, ar, activation_name).await?;

    let mut status = serde_json::Map::new();
    if let Some(phase) = phase_on_begin(&current) {
        status.insert("phase".to_string(), json!(phase));
    }
    status.insert("totalWaves".to_string(), json!(total_waves));
    status.insert("waves".to_string(), json!([]));
    // A retry clears the previous attempt's verdict, so a record that goes on
    // to succeed does not keep a stale failure hanging off its status.
    status.insert("failure".to_string(), Value::Null);

    api.patch_status(
        activation_name,
        &PatchParams::default(),
        &Patch::Merge(&json!({ "status": status })),
    )
    .await
    .map_err(|e| ActivationError::PatchFailed {
        name: activation_name.to_string(),
        source: e,
    })?;

    Ok(())
}

/// Mark a record Failed because its deploy stopped before finalizing.
///
/// Best-effort by nature: the run is already ending, and a cluster that will
/// not take this patch is one the next deploy has to cope with anyway. It is
/// conditional on the record still being `Deploying`, so a re-deploy of the
/// current closure that aborts leaves the Active record alone.
pub async fn fail_deploy(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    reason: &str,
) -> Result<(), ActivationError> {
    let current = read_record_phase(client, ar, activation_name).await?;
    let Some(phase) = phase_on_abort(&current) else {
        tracing::debug!(
            activation = %activation_name,
            phase = %current,
            "deploy aborted but the record is not ours to fail",
        );
        return Ok(());
    };

    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let status_patch = json!({
        "status": {
            "phase": phase,
            "failure": {
                "reason": reason,
                "at": chrono::Utc::now().to_rfc3339(),
            },
        },
    });
    api.patch_status(
        activation_name,
        &PatchParams::default(),
        &Patch::Merge(&status_patch),
    )
    .await
    .map_err(|e| ActivationError::PatchFailed {
        name: activation_name.to_string(),
        source: e,
    })?;

    tracing::info!(activation = %activation_name, reason, "marked as Failed");
    Ok(())
}

/// Data for recording a single wave's result.
#[derive(Debug, Clone)]
pub struct WaveRecord {
    pub wave_index: usize,
    pub status: WaveStatus,
    pub resource_count: usize,
    pub applied: usize,
    pub failed: usize,
}

/// Record the completion status of waves on the Activation CR.
///
/// Patches `status.waves` with the full accumulated list. The caller
/// tracks wave records in memory and passes the complete list each time,
/// eliminating the need for a GET-before-PATCH round-trip.
pub async fn record_waves(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    waves: &[WaveRecord],
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    let wave_json: Vec<Value> = waves
        .iter()
        .map(|w| {
            json!({
                "wave": w.wave_index,
                "status": w.status.as_str(),
                "resources": w.resource_count,
                "applied": w.applied,
                "failed": w.failed,
            })
        })
        .collect();

    let status_patch = json!({
        "status": {
            "waves": wave_json,
        },
    });

    api.patch_status(
        activation_name,
        &PatchParams::default(),
        &Patch::Merge(&status_patch),
    )
    .await
    .map_err(|e| ActivationError::PatchFailed {
        name: activation_name.to_string(),
        source: e,
    })?;

    Ok(())
}

/// Read wave progress from the Activation CR to determine resume point.
///
/// Returns the index of the first non-Complete wave, or None if all complete.
pub async fn resume_point(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
) -> Result<Option<usize>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    let current = api
        .get(activation_name)
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: activation_name.to_string(),
            source: e,
        })?;

    let phase = current
        .data
        .pointer("/status/phase")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // Only resume if we're in Deploying state
    if phase != PHASE_DEPLOYING {
        return Ok(None);
    }

    let waves = current
        .data
        .pointer("/status/waves")
        .and_then(|v| v.as_array());

    let Some(waves) = waves else {
        return Ok(Some(0)); // Deploying but no wave progress — start from 0
    };

    for (i, wave) in waves.iter().enumerate() {
        let status = wave
            .get("status")
            .and_then(|v| v.as_str())
            .map(WaveStatus::from_str)
            .unwrap_or(WaveStatus::Pending);

        if status != WaveStatus::Complete {
            return Ok(Some(i));
        }
    }

    // All recorded waves complete — but there might be more waves beyond what's recorded
    let total_waves = current
        .data
        .pointer("/status/totalWaves")
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as usize;

    if waves.len() < total_waves {
        return Ok(Some(waves.len()));
    }

    Ok(None) // All waves complete
}

#[cfg(test)]
mod phase_tests {
    use super::*;

    #[test]
    fn begin_marks_anything_that_is_not_already_current() {
        for phase in [
            "",
            PHASE_QUEUED,
            PHASE_SUPERSEDED,
            PHASE_FAILED,
            PHASE_DEPLOYING,
        ] {
            assert_eq!(
                phase_on_begin(phase),
                Some(PHASE_DEPLOYING),
                "phase {phase:?} should be marked Deploying",
            );
        }
    }

    #[test]
    fn begin_leaves_the_current_record_alone() {
        // Re-deploying the closure that is already running reuses its record.
        // Demoting it to Deploying and then dying would leave the cluster
        // with no current record at all, and the next deploy would plan as a
        // first deploy: no orphans, no repairs.
        assert_eq!(phase_on_begin(PHASE_ACTIVE), None);
        assert_eq!(phase_on_begin(PHASE_DEGRADED), None);
    }

    #[test]
    fn abort_only_fails_a_record_this_run_marked() {
        assert_eq!(phase_on_abort(PHASE_DEPLOYING), Some(PHASE_FAILED));
        // A record created but never marked can only be ours: `begin` creates
        // it and marks it in two round trips, and a run that dies between the
        // two would otherwise leave it invisible to every reader.
        assert_eq!(phase_on_abort(""), Some(PHASE_FAILED));
        for phase in [
            PHASE_QUEUED,
            PHASE_ACTIVE,
            PHASE_DEGRADED,
            PHASE_SUPERSEDED,
            PHASE_FAILED,
        ] {
            assert_eq!(
                phase_on_abort(phase),
                None,
                "phase {phase:?} is not ours to fail",
            );
        }
    }

    /// A record superseded out of `Failed` is not a rollback target. It was
    /// never the cluster's state, so applying it would put the cluster into
    /// one it has never been in.
    #[test]
    fn a_record_that_never_finished_is_filtered_out_of_the_superseded_list() {
        use kube::api::DynamicObject;

        let item: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "demo-failed" },
            "status": {
                "phase": PHASE_SUPERSEDED,
                "failure": { "reason": "cancelled", "at": "2026-09-10T10:00:00Z" },
            },
        }))
        .unwrap();
        assert!(
            item.data
                .pointer("/status/failure")
                .is_some_and(|v| !v.is_null()),
            "the filter list_superseded_activations applies must see this record",
        );

        // A record that failed and was then retried successfully has the
        // field cleared by begin_deploy, so it stays a valid target.
        let retried: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "demo-ok" },
            "status": { "phase": PHASE_SUPERSEDED, "failure": Value::Null },
        }))
        .unwrap();
        assert!(
            retried
                .data
                .pointer("/status/failure")
                .is_none_or(Value::is_null),
        );
    }

    #[test]
    fn a_record_that_never_deployed_sorts_by_when_it_failed() {
        let mut record = SupersededActivation {
            name: "demo-abc".into(),
            identity_hash: None,
            deployed_at: String::new(),
            built_via: None,
            previous_activation: None,
            uid: None,
            resource_version: None,
            failed_at: Some("2026-09-09T10:00:00Z".into()),
            created_at: Some("2026-09-09T09:00:00Z".into()),
        };
        assert_eq!(
            deployed_at(&record).map(|t| t.to_rfc3339()),
            Some("2026-09-09T10:00:00+00:00".to_string()),
        );

        // No failure timestamp either: fall back to creation, so it is still
        // not retired as UnknownAge on the first gc.
        record.failed_at = None;
        assert_eq!(
            deployed_at(&record).map(|t| t.to_rfc3339()),
            Some("2026-09-09T09:00:00+00:00".to_string()),
        );

        record.created_at = None;
        assert_eq!(deployed_at(&record), None);
    }

    #[test]
    fn deployed_at_wins_over_the_fallbacks() {
        let record = SupersededActivation {
            name: "demo-abc".into(),
            identity_hash: None,
            deployed_at: "2026-09-01T00:00:00Z".into(),
            built_via: None,
            previous_activation: None,
            uid: None,
            resource_version: None,
            failed_at: Some("2026-09-09T10:00:00Z".into()),
            created_at: Some("2026-09-09T09:00:00Z".into()),
        };
        assert_eq!(
            deployed_at(&record).map(|t| t.to_rfc3339()),
            Some("2026-09-01T00:00:00+00:00".to_string()),
        );
    }

    #[test]
    fn the_newest_current_record_wins_and_ties_break_on_name() {
        use chrono::{TimeZone, Utc};
        let at = |h| Some(Utc.with_ymd_and_hms(2026, 9, 9, h, 0, 0).unwrap());

        assert_eq!(
            pick_current(vec![
                ("older", at(9), "b".to_string()),
                ("newer", at(11), "a".to_string()),
            ]),
            Some("newer"),
        );

        // Same timestamp: the name decides, so the plan does not depend on
        // the order the apiserver happened to list them in.
        assert_eq!(
            pick_current(vec![
                ("bee", at(9), "b".to_string()),
                ("ay", at(9), "a".to_string()),
            ]),
            Some("ay"),
        );

        // A record with no usable timestamp sorts oldest rather than winning
        // by accident.
        assert_eq!(
            pick_current(vec![
                ("unstamped", None, "a".to_string()),
                ("stamped", at(9), "z".to_string()),
            ]),
            Some("stamped"),
        );

        assert_eq!(pick_current(Vec::<(&str, _, String)>::new()), None);
    }
}

#[cfg(test)]
mod retire_plan_tests {
    use super::*;
    use chrono::{Duration, TimeZone, Utc};

    fn now() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 7, 12, 0, 0).unwrap()
    }

    fn rec(name: &str, deployed_at: &str) -> SupersededActivation {
        SupersededActivation {
            name: name.into(),
            identity_hash: None,
            deployed_at: deployed_at.into(),
            built_via: None,
            previous_activation: None,
            uid: None,
            resource_version: None,
            failed_at: None,
            created_at: None,
        }
    }

    /// A record deployed `days` days before `now()`.
    fn aged(name: &str, days: i64) -> SupersededActivation {
        rec(name, &(now() - Duration::days(days)).to_rfc3339())
    }

    fn names(v: &[SupersededActivation]) -> Vec<&str> {
        v.iter().map(|r| r.name.as_str()).collect()
    }

    fn retired(v: &[Retired]) -> Vec<(&str, String)> {
        v.iter()
            .map(|r| (r.record.name.as_str(), r.reason.to_string()))
            .collect()
    }

    fn policy(keep_min: usize, keep_max: usize, keep_for_days: Option<i64>) -> RetentionPolicy {
        RetentionPolicy {
            keep_min,
            keep_max,
            keep_for: keep_for_days.map(Duration::days),
            now: now(),
        }
    }

    #[test]
    fn defaults_keep_ten_cap_fifty_and_thirty_days() {
        let p = RetentionPolicy::defaults(now());
        assert_eq!((p.keep_min, p.keep_max), (10, 50));
        assert_eq!(p.keep_for, Some(Duration::days(30)));
    }

    #[test]
    fn the_floor_keeps_the_newest_whatever_their_age() {
        // Twelve records, one per year: all far older than 30 days.
        let input: Vec<_> = (0..12)
            .map(|i| aged(&format!("c-{i:02}"), 365 * (i + 1)))
            .collect();
        let plan = retire_plan(input, &policy(10, 50, Some(30)));
        assert_eq!(plan.kept.len(), 10);
        assert_eq!(plan.kept[0].name, "c-00", "newest first");
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("c-10", "older than 30d".to_string()),
                ("c-11", "older than 30d".to_string())
            ]
        );
    }

    #[test]
    fn the_cap_retires_even_recent_records() {
        // Sixty records deployed in the last hour.
        let input: Vec<_> = (0..60)
            .map(|i| {
                rec(
                    &format!("c-{i:02}"),
                    &(now() - Duration::minutes(i)).to_rfc3339(),
                )
            })
            .collect();
        let plan = retire_plan(input, &policy(10, 50, Some(30)));
        assert_eq!(plan.kept.len(), 50);
        assert_eq!(plan.retire.len(), 10);
        assert!(
            plan.retire
                .iter()
                .all(|r| r.reason == RetireReason::BeyondMax(50))
        );
        assert_eq!(plan.retire[0].record.name, "c-50");
    }

    #[test]
    fn the_age_rule_applies_only_between_floor_and_cap() {
        let input = vec![
            aged("new-a", 1),
            aged("new-b", 2),
            aged("old-c", 40),
            aged("old-d", 400),
        ];
        // Floor 1: new-a kept by floor; new-b kept by age; old-c and old-d
        // retired by age.
        let plan = retire_plan(input.clone(), &policy(1, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new-a", "new-b"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("old-c", "older than 30d".to_string()),
                ("old-d", "older than 30d".to_string())
            ]
        );
        // Floor 3: old-c now protected by the floor.
        let plan = retire_plan(input, &policy(3, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new-a", "new-b", "old-c"]);
        assert_eq!(
            retired(&plan.retire),
            vec![("old-d", "older than 30d".to_string())]
        );
    }

    #[test]
    fn age_rule_off_keeps_everything_up_to_the_cap() {
        let input: Vec<_> = (0..5)
            .map(|i| aged(&format!("c-{i}"), 1000 * (i + 1)))
            .collect();
        let plan = retire_plan(input, &policy(1, 3, None));
        assert_eq!(names(&plan.kept), vec!["c-0", "c-1", "c-2"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("c-3", "beyond the 3 newest".to_string()),
                ("c-4", "beyond the 3 newest".to_string())
            ]
        );
    }

    #[test]
    fn unknown_age_sorts_oldest_and_is_retired_by_the_age_rule_only() {
        let input = vec![
            rec("untimed", ""),
            aged("new", 1),
            rec("garbage-time", "yesterday"),
        ];
        let plan = retire_plan(input.clone(), &policy(1, 50, Some(30)));
        assert_eq!(names(&plan.kept), vec!["new"]);
        assert_eq!(
            retired(&plan.retire),
            vec![
                ("garbage-time", "no deployed-at".to_string()),
                ("untimed", "no deployed-at".to_string())
            ]
        );
        // With the age rule off they are kept like anything else.
        let plan = retire_plan(input, &policy(1, 50, None));
        assert_eq!(plan.kept.len(), 3);
    }

    #[test]
    fn exactly_the_floor_retires_nothing_and_zero_floor_with_zero_cap_retires_all() {
        let input: Vec<_> = (0..3).map(|i| aged(&format!("c-{i}"), i + 1)).collect();
        let plan = retire_plan(input.clone(), &policy(3, 50, Some(30)));
        assert!(plan.retire.is_empty());
        let plan = retire_plan(input, &policy(0, 0, None));
        assert!(plan.kept.is_empty());
        assert_eq!(plan.retire.len(), 3);
    }

    #[test]
    fn cap_below_floor_is_raised_to_the_floor() {
        let input: Vec<_> = (0..5).map(|i| aged(&format!("c-{i}"), i + 1)).collect();
        let plan = retire_plan(input, &policy(4, 2, None));
        assert_eq!(plan.kept.len(), 4);
        assert_eq!(plan.retire.len(), 1);
    }

    #[test]
    fn order_is_by_parsed_time_not_by_string_or_name() {
        // Different offsets and precision for the timestamps, and names
        // that run the other way round.
        let input = || {
            vec![
                rec("z-oldest", "2026-01-01T00:00:00+00:00"),
                rec("m-middle", "2026-05-01T02:00:00+02:00"),
                rec("a-newest", "2026-09-01T00:00:00.123456+00:00"),
            ]
        };
        // Age rule off, cap not reached: everything kept, newest first.
        let plan = retire_plan(input(), &policy(1, 50, None));
        assert_eq!(names(&plan.kept), vec!["a-newest", "m-middle", "z-oldest"]);
        assert!(plan.retire.is_empty());
        // Cap of one: the two older ones go, oldest last.
        let plan = retire_plan(input(), &policy(1, 1, None));
        assert_eq!(names(&plan.kept), vec!["a-newest"]);
        let rest: Vec<&str> = plan.retire.iter().map(|r| r.record.name.as_str()).collect();
        assert_eq!(rest, vec!["m-middle", "z-oldest"]);
    }

    #[test]
    fn ties_break_on_name() {
        let same = "2026-09-01T00:00:00Z";
        let input = vec![rec("b", same), rec("c", same), rec("a", same)];
        let plan = retire_plan(input, &policy(2, 2, None));
        assert_eq!(names(&plan.kept), vec!["a", "b"]);
        assert_eq!(plan.retire[0].record.name, "c");
    }

    #[test]
    fn humanize_picks_the_largest_even_unit() {
        assert_eq!(humanize(Duration::days(30)), "30d");
        assert_eq!(humanize(Duration::hours(36)), "36h");
        assert_eq!(humanize(Duration::minutes(90)), "90m");
        assert_eq!(humanize(Duration::seconds(45)), "45s");
    }
}
