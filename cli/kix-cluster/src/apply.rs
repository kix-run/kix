//! Apply engine — SSA-based resource application with local DAG diff change detection.
//!
//! Uses server-side apply (`Patch::Apply`) with `kix` as the field manager.
//! Change detection diffs two sets of stamped manifests locally by comparing
//! identity-hashes, without querying the live cluster.

use std::collections::HashMap;

use kix_manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;
use tokio::task::JoinSet;

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

/// Apply a single resource via server-side apply.
pub async fn apply_resource(
    client: &Client,
    ar: &ApiResource,
    scope: Scope,
    manifest: &Value,
    dry_run: bool,
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

    let mut pp = PatchParams::apply(FIELD_MANAGER).force();
    if dry_run {
        pp = pp.dry_run();
    }

    // Check if resource exists to determine Created vs Configured
    let existed = api.get_opt(&name).await.is_ok_and(|o| o.is_some());

    api.patch(&name, &pp, &Patch::Apply(manifest))
        .await
        .map_err(|e| ApplyError::PatchFailed {
            resource: rid.display_id(),
            source: e,
        })?;

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

/// Apply all resources in a wave in parallel.
///
/// Returns a vec of (ResourceId, Result) pairs for each action in the wave.
pub async fn apply_wave(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    wave: &[ChangeAction],
    dry_run: bool,
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
                set.spawn(async move {
                    let result = apply_resource(&client, &ar, scope, &manifest, dry_run).await;
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
}
