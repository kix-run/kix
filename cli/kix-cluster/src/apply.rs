//! Apply engine — SSA-based resource application with content-hash change detection.
//!
//! Uses server-side apply (`Patch::Apply`) with `kix` as the field manager.
//! Change detection compares `kix.dev/content-hash` annotations to skip
//! unchanged resources.

use std::collections::{HashMap, HashSet};

use kix_manifest::types::ResourceId;
use kube::{
    api::{Api, DynamicObject, Patch, PatchParams},
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;
use thiserror::Error;
use tokio::task::JoinSet;

/// Annotation key for content hash (changes when resource spec changes).
pub const CONTENT_HASH_ANNOTATION: &str = "kix.dev/content-hash";

/// Annotation key for identity hash (stable across content changes).
pub const IDENTITY_HASH_ANNOTATION: &str = "kix.dev/identity-hash";

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
    /// Resource was updated (content-hash changed).
    Configured,
    /// Resource was skipped (content-hash matched).
    Unchanged,
    /// Resource was skipped for another reason.
    Skipped,
}

/// A change action determined by comparing manifests against live state.
#[derive(Debug, Clone)]
pub enum ChangeAction {
    /// Resource needs to be applied (new or changed).
    Apply(Value),
    /// Resource is unchanged, skip it.
    Skip(ResourceId),
    /// Resource exists on cluster but not in manifests, candidate for pruning.
    Prune(ResourceId),
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

    let api: Api<DynamicObject> = match scope {
        Scope::Namespaced => {
            let ns = if rid.namespace == "_cluster" {
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

    Ok(ApplyResult {
        action,
        resource_id: rid,
    })
}

/// Detect changes by comparing content-hash annotations between
/// generated manifests and live resources.
///
/// Returns a list of `ChangeAction` values indicating what needs
/// to be applied, skipped, or pruned.
pub fn detect_changes(manifests: &[Value], live: &[DynamicObject]) -> Vec<ChangeAction> {
    // Index live resources by identity-hash
    let live_by_identity: HashMap<&str, &DynamicObject> = live
        .iter()
        .filter_map(|obj| {
            let hash = obj
                .data
                .pointer("/metadata/annotations")
                .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
                .and_then(Value::as_str)?;
            Some((hash, obj))
        })
        .collect();

    // Track which identity hashes are in the manifest set
    let mut manifest_identity_hashes: HashSet<String> = HashSet::new();
    let mut actions: Vec<ChangeAction> = Vec::new();

    for manifest in manifests {
        let content_hash = manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(CONTENT_HASH_ANNOTATION))
            .and_then(Value::as_str);

        let identity_hash = manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(IDENTITY_HASH_ANNOTATION))
            .and_then(Value::as_str);

        if let Some(id_hash) = identity_hash {
            manifest_identity_hashes.insert(id_hash.to_string());
        }

        // Find matching live resource by identity hash
        let live_obj = identity_hash.and_then(|h| live_by_identity.get(h).copied());

        match (live_obj, content_hash) {
            (Some(live_resource), Some(manifest_hash)) => {
                // Compare content hashes
                let live_hash = live_resource
                    .data
                    .pointer("/metadata/annotations")
                    .and_then(|a| a.get(CONTENT_HASH_ANNOTATION))
                    .and_then(Value::as_str);

                if live_hash == Some(manifest_hash) {
                    actions.push(ChangeAction::Skip(ResourceId::from_value(manifest)));
                } else {
                    actions.push(ChangeAction::Apply(manifest.clone()));
                }
            }
            (None, _) => {
                // Resource doesn't exist on cluster — needs creation
                actions.push(ChangeAction::Apply(manifest.clone()));
            }
            (Some(_), None) => {
                // No content hash on manifest — always apply
                actions.push(ChangeAction::Apply(manifest.clone()));
            }
        }
    }

    // Find live resources with kix identity hashes not in manifest set (prune candidates)
    for (identity_hash, live_obj) in &live_by_identity {
        if !manifest_identity_hashes.contains(*identity_hash) {
            actions.push(ChangeAction::Prune(ResourceId::from_value(&live_obj.data)));
        }
    }

    actions
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
            ChangeAction::Prune(rid) => {
                // Pruning is handled separately by the deploy command,
                // but we report it here for tracking
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

    fn manifest(
        kind: &str,
        name: &str,
        ns: &str,
        content_hash: &str,
        identity_hash: &str,
    ) -> Value {
        json!({
            "apiVersion": "apps/v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": {
                    CONTENT_HASH_ANNOTATION: content_hash,
                    IDENTITY_HASH_ANNOTATION: identity_hash,
                }
            }
        })
    }

    fn live_obj(
        kind: &str,
        name: &str,
        ns: &str,
        content_hash: &str,
        identity_hash: &str,
    ) -> DynamicObject {
        DynamicObject {
            metadata: kube::api::ObjectMeta {
                name: Some(name.into()),
                namespace: Some(ns.into()),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "apps/v1",
                "kind": kind,
                "metadata": {
                    "name": name,
                    "namespace": ns,
                    "annotations": {
                        CONTENT_HASH_ANNOTATION: content_hash,
                        IDENTITY_HASH_ANNOTATION: identity_hash,
                    }
                }
            }),
        }
    }

    #[test]
    fn detect_new_resource() {
        let manifests = vec![manifest("Deployment", "app", "default", "abc123", "id1")];
        let live: Vec<DynamicObject> = vec![];

        let actions = detect_changes(&manifests, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn detect_unchanged_resource() {
        let manifests = vec![manifest("Deployment", "app", "default", "abc123", "id1")];
        let live = vec![live_obj("Deployment", "app", "default", "abc123", "id1")];

        let actions = detect_changes(&manifests, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Skip(_)));
    }

    #[test]
    fn detect_changed_resource() {
        let manifests = vec![manifest("Deployment", "app", "default", "new-hash", "id1")];
        let live = vec![live_obj("Deployment", "app", "default", "old-hash", "id1")];

        let actions = detect_changes(&manifests, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn detect_prune_candidate() {
        let manifests: Vec<Value> = vec![];
        let live = vec![live_obj(
            "Deployment",
            "old-app",
            "default",
            "hash",
            "id-orphan",
        )];

        let actions = detect_changes(&manifests, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Prune(_)));
        if let ChangeAction::Prune(rid) = &actions[0] {
            assert_eq!(rid.name, "old-app");
        }
    }

    #[test]
    fn detect_mixed_actions() {
        let manifests = vec![
            manifest("Deployment", "unchanged", "default", "hash1", "id1"),
            manifest("Deployment", "changed", "default", "new-hash", "id2"),
            manifest("Deployment", "new-app", "default", "hash3", "id3"),
        ];
        let live = vec![
            live_obj("Deployment", "unchanged", "default", "hash1", "id1"),
            live_obj("Deployment", "changed", "default", "old-hash", "id2"),
            live_obj("Deployment", "orphan", "default", "hash-x", "id-orphan"),
        ];

        let actions = detect_changes(&manifests, &live);
        // 3 manifest actions + 1 prune = 4
        assert_eq!(actions.len(), 4);

        let skips: Vec<_> = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Skip(_)))
            .collect();
        let applies: Vec<_> = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Apply(_)))
            .collect();
        let prunes: Vec<_> = actions
            .iter()
            .filter(|a| matches!(a, ChangeAction::Prune(_)))
            .collect();

        assert_eq!(skips.len(), 1); // unchanged
        assert_eq!(applies.len(), 2); // changed + new
        assert_eq!(prunes.len(), 1); // orphan
    }

    #[test]
    fn detect_no_content_hash_always_applies() {
        let manifests = vec![json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "test",
                "namespace": "default",
                "annotations": {
                    IDENTITY_HASH_ANNOTATION: "id1",
                }
            }
        })];
        let live = vec![live_obj("ConfigMap", "test", "default", "any-hash", "id1")];

        let actions = detect_changes(&manifests, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn detect_no_identity_hash_on_live_treats_as_new() {
        let manifests = vec![manifest("Deployment", "app", "default", "hash", "id1")];
        // Live object has no identity hash annotation
        let live = vec![DynamicObject {
            metadata: kube::api::ObjectMeta {
                name: Some("app".into()),
                namespace: Some("default".into()),
                ..Default::default()
            },
            types: None,
            data: json!({
                "kind": "Deployment",
                "metadata": {"name": "app", "namespace": "default"}
            }),
        }];

        let actions = detect_changes(&manifests, &live);
        assert_eq!(actions.len(), 1);
        assert!(matches!(&actions[0], ChangeAction::Apply(_)));
    }

    #[test]
    fn apply_action_eq() {
        assert_eq!(ApplyAction::Created, ApplyAction::Created);
        assert_eq!(ApplyAction::Configured, ApplyAction::Configured);
        assert_eq!(ApplyAction::Unchanged, ApplyAction::Unchanged);
        assert_ne!(ApplyAction::Created, ApplyAction::Configured);
    }
}
