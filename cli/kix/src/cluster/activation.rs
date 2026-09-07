//! Activation CR lifecycle management.
//!
//! The Activation CR is the cluster-level record of "what is deployed."
//! This module manages the state machine:
//!
//! ```text
//! deploy succeeds → Active
//! new deploy      → old becomes Superseded, new becomes Active
//! kix gc          → Superseded gets deleted (after its orphaned resources are cleaned up)
//! kix rollback    → current becomes Superseded, target becomes Active
//! ```

use kube::{
    api::{Api, DynamicObject, ListParams, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::{Value, json};
use thiserror::Error;

use super::apply::IDENTITY_HASH_ANNOTATION;

/// Annotation keys used on Activation CRs.
pub const PREVIOUS_ANNOTATION: &str = "kix.dev/previous";
pub const DEPLOYED_AT_ANNOTATION: &str = "kix.dev/deployed-at";

/// Activation phase values (stored in status.phase).
pub const PHASE_QUEUED: &str = "Queued";
pub const PHASE_ACTIVE: &str = "Active";
pub const PHASE_SUPERSEDED: &str = "Superseded";
pub const PHASE_DEPLOYING: &str = "Deploying";
/// Deploy completed but some resources failed to apply or become ready.
/// Treated as the "current state" for diffing/drift purposes — the next deploy
/// must be able to find this CR to compute a meaningful plan.
pub const PHASE_DEGRADED: &str = "Degraded";

/// Label for filtering activations by cluster.
pub const CLUSTER_LABEL: &str = "kix.dev/cluster";

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
pub fn find_activation_ar(discovery: &[(ApiResource, Scope)]) -> Option<&(ApiResource, Scope)> {
    discovery.iter().find(|(ar, _)| {
        crate::manifest::lifecycle::is_record_kind(&ar.kind) && ar.group == "kix.dev"
    })
}

/// Find the current Active activation for a given cluster.
///
/// Returns None if no current activation exists (first deploy).
/// Matches `status.phase` against `Active` or `Degraded` — both represent
/// "the cluster's current state" for diffing purposes. A Degraded activation
/// is one whose deploy completed with some resource failures; it is still the
/// most recent description of intended state and the next deploy should diff
/// against it instead of treating the cluster as empty.
pub async fn find_active(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Option<ActiveActivation>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{CLUSTER_LABEL}={cluster_name}"
    ));

    let list = api.list(&lp).await.map_err(ActivationError::ListFailed)?;

    for item in &list.items {
        let phase = item
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if phase == PHASE_ACTIVE || phase == PHASE_DEGRADED {
            let name = item.metadata.name.clone().unwrap_or_default();
            let annotations = item.metadata.annotations.as_ref();
            let identity_hash = annotations
                .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
                .cloned();
            let built_via = annotations
                .and_then(|a| a.get(BUILT_VIA_ANNOTATION))
                .cloned();
            return Ok(Some(ActiveActivation {
                name,
                identity_hash,
                built_via,
            }));
        }
    }

    Ok(None)
}

/// After a deploy, update the activation lifecycle:
/// 1. Mark the old activation as Superseded (status.phase=Superseded)
/// 2. Set kix.dev/previous on the new activation pointing to the old one
/// 3. Set kix.dev/deployed-at timestamp on the new activation
/// 4. Set the new activation phase: `Active` on a clean deploy, `Degraded` if
///    `had_failures` is true. Either way, it becomes the cluster's current
///    state — the next deploy must be able to find it via `find_active` to
///    compute a meaningful diff. Marking it Active despite failures would
///    misrepresent the state; refusing to finalize at all (the previous
///    behavior) leaves an orphaned Activation that nothing can find.
/// 5. Add kix.dev/cluster label for filtering (also stamped at build time
///    via `mkActivation`, but re-asserted here for older CRs).
pub async fn finalize_deploy(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
    new_activation_name: &str,
    old_activation: Option<&ActiveActivation>,
    had_failures: bool,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let now = chrono::Utc::now().to_rfc3339();

    // 1. Supersede old activation
    if let Some(old) = old_activation {
        supersede_activation(client, ar, &old.name).await?;
    }

    // 2. Update new activation with lifecycle annotations (merge patch to preserve
    //    kix.dev/identity-hash and other annotations set during wave apply)
    let mut annotations = serde_json::Map::new();
    annotations.insert(DEPLOYED_AT_ANNOTATION.to_string(), Value::String(now));
    if let Some(old) = old_activation
        && let Some(ref hash) = old.identity_hash
    {
        annotations.insert(PREVIOUS_ANNOTATION.to_string(), Value::String(hash.clone()));
    }

    let spec_patch = json!({
        "metadata": {
            "labels": {
                CLUSTER_LABEL: cluster_name,
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

/// List all Superseded activations for a cluster.
pub async fn list_superseded(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<String>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{CLUSTER_LABEL}={cluster_name}"
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
/// This is the authority for pruning `kix.dev/activations`: a hash in that set
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
                    .as_ref()?
                    .get(IDENTITY_HASH_ANNOTATION)
                    .cloned()
            })
            .collect(),
    )
}

/// Annotation key for the activation result dir store path.
pub const BUILT_VIA_ANNOTATION: &str = "kix.dev/built-via";

/// Info about a Superseded activation, including when it was deployed.
#[derive(Debug, Clone)]
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
}

/// List all Superseded activations for a cluster, sorted by deployed-at (most recent first).
pub async fn list_superseded_activations(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<SupersededActivation>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{CLUSTER_LABEL}={cluster_name}"
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

        let name = match item.metadata.name.as_deref() {
            Some(n) => n.to_string(),
            None => continue,
        };

        let annotations = item.metadata.annotations.as_ref();
        let identity_hash = annotations
            .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
            .cloned();

        let deployed_at = annotations
            .and_then(|a| a.get(DEPLOYED_AT_ANNOTATION))
            .cloned()
            .unwrap_or_default();

        let built_via = annotations
            .and_then(|a| a.get(BUILT_VIA_ANNOTATION))
            .cloned();

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
        });
    }

    // Most recent first
    results.sort_by(|a, b| b.deployed_at.cmp(&a.deployed_at));

    Ok(results)
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

/// Find all Queued activations for a cluster, sorted by creation time (newest first).
pub async fn find_queued(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
) -> Result<Vec<QueuedActivation>, ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let lp = ListParams::default().labels(&format!(
        "app.kubernetes.io/managed-by=kix,{CLUSTER_LABEL}={cluster_name}"
    ));

    let list = api.list(&lp).await.map_err(ActivationError::ListFailed)?;

    let mut queued = Vec::new();
    for item in &list.items {
        let phase = item
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        // Treat empty/missing phase as Queued (new CR without status yet)
        if phase == PHASE_QUEUED || phase.is_empty() {
            let name = item.metadata.name.clone().unwrap_or_default();
            let annotations = item.metadata.annotations.as_ref();
            let identity_hash = annotations
                .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
                .cloned();
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

/// Set the Activation phase to Deploying and initialize wave status.
///
/// Called at the start of the apply loop. Sets `status.phase = Deploying`
/// and `status.totalWaves = n`.
pub async fn begin_deploy(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    total_waves: usize,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    let status_patch = json!({
        "status": {
            "phase": PHASE_DEPLOYING,
            "totalWaves": total_waves,
            "waves": [],
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
