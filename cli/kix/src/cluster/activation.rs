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
pub const PHASE_ACTIVE: &str = "Active";
pub const PHASE_SUPERSEDED: &str = "Superseded";
pub const PHASE_DEPLOYING: &str = "Deploying";

/// Label for filtering activations by cluster.
pub const CLUSTER_LABEL: &str = "kix.dev/cluster";

/// Field manager for activation status updates.
const FIELD_MANAGER: &str = "kix";

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
}

/// Find the Activation ApiResource from discovery results.
pub fn find_activation_ar(discovery: &[(ApiResource, Scope)]) -> Option<&(ApiResource, Scope)> {
    discovery
        .iter()
        .find(|(ar, _)| ar.kind == "Activation" && ar.group == "kix.dev")
}

/// Find the current Active activation for a given cluster.
///
/// Returns None if no Active activation exists (first deploy).
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

    // Find the one with spec.active == true
    for item in &list.items {
        let active = item
            .data
            .pointer("/spec/active")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        if active {
            let name = item.metadata.name.clone().unwrap_or_default();
            let identity_hash = item
                .data
                .pointer("/metadata/annotations")
                .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            return Ok(Some(ActiveActivation {
                name,
                identity_hash,
            }));
        }
    }

    // Fallback: if no spec.active field set, find by cluster name
    // (backwards compat with activations created before state machine)
    for item in &list.items {
        let name = item.metadata.name.as_deref().unwrap_or("");
        if !name.is_empty() {
            let identity_hash = item
                .data
                .pointer("/metadata/annotations")
                .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            return Ok(Some(ActiveActivation {
                name: name.to_string(),
                identity_hash,
            }));
        }
    }

    Ok(None)
}

/// After a successful deploy, update the activation lifecycle:
/// 1. Mark the old activation as Superseded (spec.active=false, status.phase=Superseded)
/// 2. Set kix.dev/previous on the new activation pointing to the old one
/// 3. Set kix.dev/deployed-at timestamp on the new activation
/// 4. Ensure the new activation has spec.active=true and status.phase=Active
/// 5. Add kix.dev/cluster label for filtering
pub async fn finalize_deploy(
    client: &Client,
    ar: &ApiResource,
    cluster_name: &str,
    new_activation_name: &str,
    old_activation: Option<&ActiveActivation>,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let pp = PatchParams::apply(FIELD_MANAGER).force();
    let now = chrono::Utc::now().to_rfc3339();

    // 1. Supersede old activation
    if let Some(old) = old_activation {
        let patch = json!({
            "apiVersion": "kix.dev/v1alpha1",
            "kind": "Activation",
            "metadata": {
                "name": old.name,
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    CLUSTER_LABEL: cluster_name,
                },
            },
            "spec": {
                "active": false,
            },
            "status": {
                "phase": PHASE_SUPERSEDED,
            },
        });

        api.patch(&old.name, &pp, &Patch::Apply(&patch))
            .await
            .map_err(|e| ActivationError::PatchFailed {
                name: old.name.clone(),
                source: e,
            })?;

        tracing::info!(activation = %old.name, "marked as Superseded");
    }

    // 2. Update new activation with lifecycle annotations
    let mut annotations = serde_json::Map::new();
    annotations.insert(DEPLOYED_AT_ANNOTATION.to_string(), Value::String(now));
    if let Some(old) = old_activation
        && let Some(ref hash) = old.identity_hash
    {
        annotations.insert(PREVIOUS_ANNOTATION.to_string(), Value::String(hash.clone()));
    }

    let patch = json!({
        "apiVersion": "kix.dev/v1alpha1",
        "kind": "Activation",
        "metadata": {
            "name": new_activation_name,
            "labels": {
                "app.kubernetes.io/managed-by": "kix",
                CLUSTER_LABEL: cluster_name,
            },
            "annotations": annotations,
        },
        "spec": {
            "active": true,
            "cluster": cluster_name,
        },
        "status": {
            "phase": PHASE_ACTIVE,
        },
    });

    api.patch(new_activation_name, &pp, &Patch::Apply(&patch))
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: new_activation_name.to_string(),
            source: e,
        })?;

    tracing::info!(activation = %new_activation_name, "marked as Active");

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
        let active = item
            .data
            .pointer("/spec/active")
            .and_then(|v| v.as_bool())
            .unwrap_or(true); // default to active if field missing (backwards compat)

        if !active && let Some(name) = item.metadata.name.as_deref() {
            superseded.push(name.to_string());
        }
    }

    Ok(superseded)
}

/// Info about a Superseded activation, including when it was deployed.
#[derive(Debug, Clone)]
pub struct SupersededActivation {
    pub name: String,
    pub identity_hash: Option<String>,
    pub deployed_at: String,
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
        let active = item
            .data
            .pointer("/spec/active")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);

        if active {
            continue;
        }

        let name = match item.metadata.name.as_deref() {
            Some(n) => n.to_string(),
            None => continue,
        };

        let identity_hash = item
            .data
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let deployed_at = item
            .data
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(DEPLOYED_AT_ANNOTATION))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        results.push(SupersededActivation {
            name,
            identity_hash,
            deployed_at,
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

    let patch = json!({
        "metadata": { "name": activation_name },
        "status": {
            "phase": PHASE_DEPLOYING,
            "totalWaves": total_waves,
            "waves": [],
        },
    });

    api.patch(
        activation_name,
        &PatchParams::default(),
        &Patch::Merge(&patch),
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

/// Record the completion status of a wave on the Activation CR.
///
/// Appends to `status.waves` array. The operator (or a resumed CLI deploy)
/// can read this to determine where to resume after a crash.
pub async fn record_wave(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    wave: &WaveRecord,
) -> Result<(), ActivationError> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    // Read current status.waves to append
    let current = api
        .get(activation_name)
        .await
        .map_err(|e| ActivationError::PatchFailed {
            name: activation_name.to_string(),
            source: e,
        })?;

    let mut waves: Vec<Value> = current
        .data
        .pointer("/status/waves")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    // Ensure array is long enough (in case waves are recorded out of order)
    while waves.len() <= wave.wave_index {
        waves.push(json!({ "status": "Pending" }));
    }

    waves[wave.wave_index] = json!({
        "wave": wave.wave_index,
        "status": wave.status.as_str(),
        "resources": wave.resource_count,
        "applied": wave.applied,
        "failed": wave.failed,
    });

    let patch = json!({
        "metadata": { "name": activation_name },
        "status": {
            "waves": waves,
        },
    });

    api.patch(
        activation_name,
        &PatchParams::default(),
        &Patch::Merge(&patch),
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
