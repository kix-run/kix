//! Stateful migration pair detection.
//!
//! When a deploy removes a stateful resource and adds a different stateful
//! resource in the same logical slot, the pair represents a data migration
//! the user needs to acknowledge. This module only detects and reports pairs;
//! it does not execute the migration.
//!
//! # Logical slot identity
//!
//! A resource's logical slot is the pair of `kix.run/package-namespace` and
//! `kix.run/package` annotations.
//!
//! A pair is flagged only when **both** sides are marked
//! `kix.run/lifecycle = "stateful"`. L7 swaps, cache rebinds, and monitoring
//! storage flips are suppressed because their packages declare
//! `lifecycle = "ephemeral"` (or leave it unset).
//!
//! Detection does not select a migration strategy, schedule migration steps,
//! or remove resources from the Apply and Orphan action sets.

use std::collections::HashMap;

use serde_json::Value;

use crate::manifest::keys;
use crate::manifest::types::ResourceId;

/// The lifecycle value for resources whose data requires migration.
const LIFECYCLE_STATEFUL: &str = "stateful";

/// A pairing of an about-to-be-removed stateful resource with an
/// about-to-be-added replacement in the same logical slot.
#[derive(Debug, Clone)]
pub struct MigrationPair {
    /// The logical slot (`namespace/instance`), stable across closures.
    pub slot: String,
    /// Resource being removed from the cluster (source of data).
    pub source: ResourceId,
    /// Resource being added to the cluster (target of data).
    pub target: ResourceId,
    /// Human-readable reason derived from what changed between source and target.
    pub reason: String,
}

impl MigrationPair {
    /// Formatted one-line summary for CLI output.
    pub fn summary(&self) -> String {
        format!(
            "{slot}: {src_kind}/{src_name} -> {tgt_kind}/{tgt_name} ({reason})",
            slot = self.slot,
            src_kind = self.source.kind,
            src_name = self.source.name,
            tgt_kind = self.target.kind,
            tgt_name = self.target.name,
            reason = self.reason,
        )
    }
}

/// Pull `(ns, instance)` from stamped annotations. Returns `None` when the
/// resource is not owned by a package.
fn slot_of(manifest: &Value) -> Option<String> {
    let anns = manifest.pointer("/metadata/annotations")?;
    let ns = anns.get(keys::PACKAGE_NAMESPACE).and_then(Value::as_str)?;
    let inst = anns.get(keys::PACKAGE).and_then(Value::as_str)?;
    if ns == "_cluster" || inst == "_cluster" {
        return None;
    }
    Some(format!("{ns}/{inst}"))
}

/// True when the resource's package is classified `lifecycle = "stateful"`.
fn is_stateful(manifest: &Value) -> bool {
    manifest
        .pointer("/metadata/annotations")
        .and_then(|a| a.get(keys::LIFECYCLE))
        .and_then(Value::as_str)
        == Some(LIFECYCLE_STATEFUL)
}

/// Derive a short "why did this change" reason by comparing source and target
/// manifests. PVC storage class and size changes receive specific messages;
/// other differences use a generic message.
fn derive_reason(source: &Value, target: &Value) -> String {
    let src_kind = source
        .pointer("/kind")
        .and_then(Value::as_str)
        .unwrap_or("?");
    let tgt_kind = target
        .pointer("/kind")
        .and_then(Value::as_str)
        .unwrap_or("?");

    if src_kind != tgt_kind {
        return format!("kind changed: {src_kind} -> {tgt_kind}");
    }

    // PVC-shaped diff hints (works for PersistentVolumeClaim and for CRs
    // that mirror the PVC shape on spec).
    let src_sc = source
        .pointer("/spec/storageClassName")
        .and_then(Value::as_str);
    let tgt_sc = target
        .pointer("/spec/storageClassName")
        .and_then(Value::as_str);
    if src_sc != tgt_sc {
        return format!(
            "storageClass changed: {} -> {}",
            src_sc.unwrap_or("<none>"),
            tgt_sc.unwrap_or("<none>"),
        );
    }

    let src_size = source
        .pointer("/spec/resources/requests/storage")
        .and_then(Value::as_str);
    let tgt_size = target
        .pointer("/spec/resources/requests/storage")
        .and_then(Value::as_str);
    if src_size != tgt_size {
        return format!(
            "size changed: {} -> {}",
            src_size.unwrap_or("?"),
            tgt_size.unwrap_or("?"),
        );
    }

    "content changed".to_string()
}

/// Detect migration pairs from raw stamped manifests.
///
/// Scans `old_manifests` for resources that:
///   1. are lifecycle=stateful,
///   2. have a `(namespace, instance)` slot,
///   3. are absent from `new_manifests` under the same Kubernetes identity.
///
/// For each removed stateful resource, looks in `new_manifests` for an
/// added stateful resource in the same slot that is also absent from
/// `old_manifests` under the same K8s identity. When found, emits a
/// `MigrationPair`.
///
/// This detector is independent of `detect_changes`; callers combine their
/// outputs.
pub fn detect_migration_pairs(
    new_manifests: &[Value],
    old_manifests: &[Value],
) -> Vec<MigrationPair> {
    // Index new manifests by K8s identity for "is this removed?" lookups.
    let new_by_k8s_id: HashMap<String, &Value> = new_manifests
        .iter()
        .map(|m| {
            let rid = ResourceId::from_value(m);
            (format!("{}/{}/{}", rid.kind, rid.namespace, rid.name), m)
        })
        .collect();

    // Index old manifests by K8s identity for "is this new?" lookups.
    let old_by_k8s_id: HashMap<String, &Value> = old_manifests
        .iter()
        .map(|m| {
            let rid = ResourceId::from_value(m);
            (format!("{}/{}/{}", rid.kind, rid.namespace, rid.name), m)
        })
        .collect();

    // Bucket added stateful manifests by slot.
    let mut added_by_slot: HashMap<String, Vec<(ResourceId, &Value)>> = HashMap::new();
    for manifest in new_manifests {
        if !is_stateful(manifest) {
            continue;
        }
        let rid = ResourceId::from_value(manifest);
        let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
        if old_by_k8s_id.contains_key(&k8s_id) {
            // The same identity in the old set is a content change,
            // just a content change. Not a migration pair: the PVC is
            // being patched in place (e.g. a label edit) and data stays.
            continue;
        }
        let Some(slot) = slot_of(manifest) else {
            continue;
        };
        added_by_slot.entry(slot).or_default().push((rid, manifest));
    }

    // Walk removed stateful manifests, match by slot.
    let mut pairs: Vec<MigrationPair> = Vec::new();
    // Track which added entries we've consumed so we don't double-pair.
    let mut consumed: std::collections::HashSet<String> = std::collections::HashSet::new();

    for manifest in old_manifests {
        if !is_stateful(manifest) {
            continue;
        }
        let rid = ResourceId::from_value(manifest);
        let k8s_id = format!("{}/{}/{}", rid.kind, rid.namespace, rid.name);
        if new_by_k8s_id.contains_key(&k8s_id) {
            continue; // Still present under the same identity.
        }
        let Some(slot) = slot_of(manifest) else {
            continue;
        };
        let Some(candidates) = added_by_slot.get(&slot) else {
            // Removed stateful resource with no replacement in the slot.
            // An orphan without a replacement is not a migration pair.
            continue;
        };

        // Prefer a same-kind candidate; fall back to any candidate in the slot.
        // Same-kind replacements are less ambiguous than cross-kind candidates.
        let chosen = candidates
            .iter()
            .find(|(target_rid, m)| {
                target_rid.kind == rid.kind && !consumed.contains(&candidate_key(target_rid, m))
            })
            .or_else(|| {
                candidates
                    .iter()
                    .find(|(target_rid, m)| !consumed.contains(&candidate_key(target_rid, m)))
            });

        let Some((target_rid, target_manifest)) = chosen else {
            continue;
        };

        consumed.insert(candidate_key(target_rid, target_manifest));

        let reason = derive_reason(manifest, target_manifest);
        pairs.push(MigrationPair {
            slot,
            source: rid,
            target: target_rid.clone(),
            reason,
        });
    }

    pairs
}

fn candidate_key(rid: &ResourceId, _m: &Value) -> String {
    format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[allow(clippy::too_many_arguments)]
    fn stamped(
        kind: &str,
        ns: &str,
        name: &str,
        pkg_ns: &str,
        pkg: &str,
        lifecycle: Option<&str>,
        storage_class: Option<&str>,
        size: Option<&str>,
        identity_hash: &str,
    ) -> Value {
        let mut anns = serde_json::Map::new();
        anns.insert(keys::PACKAGE.into(), json!(pkg));
        anns.insert(keys::PACKAGE_NAMESPACE.into(), json!(pkg_ns));
        anns.insert(keys::IDENTITY_HASH.into(), json!(identity_hash));
        if let Some(lc) = lifecycle {
            anns.insert(keys::LIFECYCLE.into(), json!(lc));
        }

        let mut spec = serde_json::Map::new();
        if let Some(sc) = storage_class {
            spec.insert("storageClassName".into(), json!(sc));
        }
        if let Some(s) = size {
            spec.insert("resources".into(), json!({ "requests": { "storage": s } }));
        }

        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": ns,
                "annotations": anns,
            },
            "spec": spec,
        })
    }

    #[test]
    fn detects_storage_class_swap() {
        // Same slot (immich/storage), same kind, different PVC name and
        // storageClass, representing a storage backend migration.
        let old = vec![stamped(
            "PersistentVolumeClaim",
            "immich",
            "storage-old",
            "immich",
            "storage",
            Some("stateful"),
            Some("local-path"),
            Some("100Gi"),
            "aaaa",
        )];
        let new = vec![stamped(
            "PersistentVolumeClaim",
            "immich",
            "storage-new",
            "immich",
            "storage",
            Some("stateful"),
            Some("zfs-tank"),
            Some("200Gi"),
            "bbbb",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].slot, "immich/storage");
        assert!(pairs[0].reason.contains("storageClass"));
    }

    #[test]
    fn detects_operator_swap_cross_kind() {
        // A replacement in the same slot may use a different kind.
        let old = vec![stamped(
            "SGCluster",
            "data",
            "postgres",
            "data",
            "postgres",
            Some("stateful"),
            None,
            None,
            "aaaa",
        )];
        let new = vec![stamped(
            "Cluster",
            "data",
            "postgres",
            "data",
            "postgres",
            Some("stateful"),
            None,
            None,
            "bbbb",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert!(pairs[0].reason.contains("kind changed"));
    }

    #[test]
    fn ignores_same_k8s_identity_patch() {
        // Identity (kind/ns/name) unchanged, content changed. That is a
        // regular SSA patch; the data stays in place.
        let old = vec![stamped(
            "PersistentVolumeClaim",
            "immich",
            "storage",
            "immich",
            "storage",
            Some("stateful"),
            Some("local-path"),
            Some("100Gi"),
            "aaaa",
        )];
        let new = vec![stamped(
            "PersistentVolumeClaim",
            "immich",
            "storage",
            "immich",
            "storage",
            Some("stateful"),
            Some("local-path"),
            Some("200Gi"),
            "bbbb",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert!(pairs.is_empty());
    }

    #[test]
    fn ignores_ephemeral_lifecycle() {
        // Ephemeral resources do not form migration pairs.
        let old = vec![stamped(
            "PersistentVolumeClaim",
            "monitoring",
            "loki-old",
            "monitoring",
            "loki",
            Some("ephemeral"),
            Some("local-path"),
            Some("5Gi"),
            "aaaa",
        )];
        let new = vec![stamped(
            "PersistentVolumeClaim",
            "monitoring",
            "loki-new",
            "monitoring",
            "loki",
            Some("ephemeral"),
            Some("zfs-tank"),
            Some("5Gi"),
            "bbbb",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert!(pairs.is_empty());
    }

    #[test]
    fn ignores_l7_swap_ingress_to_httproute() {
        // Two non-stateful resources in the same slot do not form a pair.
        let old = vec![stamped(
            "Ingress", "immich", "immich", "immich", "immich", None, None, None, "aaaa",
        )];
        let new = vec![stamped(
            "HTTPRoute",
            "immich",
            "immich",
            "immich",
            "immich",
            None,
            None,
            None,
            "bbbb",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert!(pairs.is_empty());
    }

    #[test]
    fn orphan_stateful_without_replacement_is_not_a_pair() {
        // A removed PVC without a replacement is an orphan.
        let old = vec![stamped(
            "PersistentVolumeClaim",
            "immich",
            "storage",
            "immich",
            "storage",
            Some("stateful"),
            Some("local-path"),
            Some("100Gi"),
            "aaaa",
        )];
        let new: Vec<Value> = vec![];
        let pairs = detect_migration_pairs(&new, &old);
        assert!(pairs.is_empty());
    }

    #[test]
    fn matches_multiple_pairs_in_one_diff() {
        // Multiple storage slots can migrate in one plan.
        let old = vec![
            stamped(
                "PersistentVolumeClaim",
                "immich",
                "storage-old",
                "immich",
                "storage",
                Some("stateful"),
                Some("local-path"),
                Some("100Gi"),
                "aaaa",
            ),
            stamped(
                "PersistentVolumeClaim",
                "vaultwarden",
                "storage-old",
                "vaultwarden",
                "storage",
                Some("stateful"),
                Some("local-path"),
                Some("1Gi"),
                "cccc",
            ),
        ];
        let new = vec![
            stamped(
                "PersistentVolumeClaim",
                "immich",
                "storage-new",
                "immich",
                "storage",
                Some("stateful"),
                Some("zfs-tank"),
                Some("100Gi"),
                "bbbb",
            ),
            stamped(
                "PersistentVolumeClaim",
                "vaultwarden",
                "storage-new",
                "vaultwarden",
                "storage",
                Some("stateful"),
                Some("zfs-tank"),
                Some("1Gi"),
                "dddd",
            ),
        ];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 2);
        let slots: std::collections::HashSet<_> = pairs.iter().map(|p| p.slot.clone()).collect();
        assert!(slots.contains("immich/storage"));
        assert!(slots.contains("vaultwarden/storage"));
    }
}
