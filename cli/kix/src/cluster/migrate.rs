//! Stateful migration pair detection.
//!
//! When a deploy removes an object that holds data and adds another in the
//! same logical slot, the pair represents a data migration the user needs to
//! acknowledge. This module detects and reports pairs without executing the
//! migration.
//!
//! # Logical slot identity
//!
//! A resource's logical slot is the pair of `kix.run/package-namespace` and
//! `kix.run/package` annotations.
//!
//! # Which objects pair
//!
//! Both sides must be marked `kix.run/lifecycle = "stateful"`. L7 swaps, cache
//! rebinds, and monitoring storage flips are suppressed because their packages
//! declare `lifecycle = "ephemeral"` (or leave it unset).
//!
//! The mark is stamped on every object of a stateful package, so it does not
//! say which objects hold data. Import markers and the deploy record never
//! pair, since they have no content of their own. Two objects of the same kind
//! pair, as a renamed object usually takes its data with it. Two objects of
//! different kinds pair only when both may hold data (see [`may_hold_data`]).
//! That covers moving a database from a StatefulSet to an operator's custom
//! resource, or from one operator to another.
//!
//! # Which objects hold data
//!
//! The library marks objects `kix.run/holds-data`. A custom resource carries
//! its kind's `holdsData` declaration, which a stateful package's custom
//! resources must have. A PersistentVolumeClaim, a PersistentVolume, and a
//! StatefulSet with claim templates are marked `"true"`. Other built-in
//! objects carry no mark. An object without one, such as chart output or an
//! object built by an older Kix, falls back to its storage shape and API
//! group, and a custom resource without a mark is assumed to hold data. A
//! pair Kix cannot judge is reported, because a false alarm costs a flag and
//! a missed migration costs the data.
//!
//! Detection does not select a migration strategy, schedule migration steps,
//! or remove resources from the Apply and Orphan action sets.

use std::collections::HashMap;

use serde_json::Value;

use crate::manifest::keys;
use crate::manifest::lifecycle::{Lifecycle, lifecycle_of};
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
    /// Format a one-line summary for CLI output.
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

/// Return whether the resource can be one side of a migration pair: its
/// package is classified `lifecycle = "stateful"` and it is desired state,
/// not an import marker or the deploy record.
fn is_stateful(manifest: &Value) -> bool {
    lifecycle_of(manifest) == Lifecycle::Desired
        && manifest
            .pointer("/metadata/annotations")
            .and_then(|a| a.get(keys::LIFECYCLE))
            .and_then(Value::as_str)
            == Some(LIFECYCLE_STATEFUL)
}

/// Return whether the manifest declares storage of its own. That is a
/// non-empty `spec.volumeClaimTemplates` (StatefulSet), a
/// `spec.resources.requests.storage` (PersistentVolumeClaim), a
/// `spec.capacity.storage` (PersistentVolume), or a
/// `spec.storage` (the shape many database operators use for their cluster
/// resource).
fn holds_data(manifest: &Value) -> bool {
    let declared = |v: Option<&Value>| match v {
        None | Some(Value::Null) => false,
        Some(Value::Array(a)) => !a.is_empty(),
        Some(Value::Object(o)) => !o.is_empty(),
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
    };
    let Some(spec) = manifest.get("spec") else {
        return false;
    };
    declared(spec.get("volumeClaimTemplates"))
        || declared(spec.pointer("/resources/requests/storage"))
        || declared(spec.pointer("/capacity/storage"))
        || declared(spec.get("storage"))
}

/// API groups whose kinds Kix treats as built-in, besides the core group and
/// Kix's own. The library reads the same lists from
/// `kix/lib/core/api-groups.json` (`facts.isForeignGroup`), and a test below
/// checks that the two agree.
const BUILTIN_GROUPS: &[&str] = &["apps", "batch", "policy", "autoscaling"];

/// Suffixes of API groups whose kinds Kix treats as built-in.
const BUILTIN_GROUP_SUFFIXES: &[&str] = &[".k8s.io"];

/// Return whether the manifest's API group is one whose kinds Kix knows: the
/// core group, a [`BUILTIN_GROUPS`] entry, a group ending in one of
/// [`BUILTIN_GROUP_SUFFIXES`], and Kix's own group.
fn is_known_api(manifest: &Value) -> bool {
    let api_version = manifest
        .get("apiVersion")
        .and_then(Value::as_str)
        .unwrap_or("");
    let Some((group, _)) = api_version.split_once('/') else {
        return true;
    };
    BUILTIN_GROUPS.contains(&group)
        || BUILTIN_GROUP_SUFFIXES.iter().any(|s| group.ends_with(s))
        || group == keys::GROUP
}

/// Return the object's `kix.run/holds-data` mark, or `None` when it has none
/// or the value is neither `"true"` nor `"false"`.
fn marked_holds_data(manifest: &Value) -> Option<bool> {
    match keys::get(manifest, keys::HOLDS_DATA)? {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}

/// Return whether the manifest may hold data. The `kix.run/holds-data` mark
/// answers when present. Without it, a known kind holds data only when it
/// declares storage. Kix cannot see where an unmarked custom resource keeps
/// its data, so it assumes that one may.
fn may_hold_data(manifest: &Value) -> bool {
    marked_holds_data(manifest).unwrap_or_else(|| holds_data(manifest) || !is_known_api(manifest))
}

/// Derive a short "why did this change" reason by comparing source and target
/// manifests. PVC storage class and size changes receive specific messages,
/// while other differences use a generic message.
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
        return format!("{src_kind} removed, {tgt_kind} added");
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
///   1. are lifecycle=stateful desired state (see [`is_stateful`]),
///   2. have a `(namespace, instance)` slot,
///   3. are absent from `new_manifests` under the same Kubernetes identity.
///
/// For each removed stateful resource, looks in `new_manifests` for an
/// added stateful resource in the same slot that is also absent from
/// `old_manifests` under the same K8s identity. A candidate of the same kind
/// wins. A candidate of another kind qualifies only when both it and the
/// removed resource may hold data (see [`may_hold_data`]). When one is found, emits
/// a `MigrationPair`.
///
/// This detector runs independently of `detect_changes`, and callers combine
/// their outputs.
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
            // An unchanged Kubernetes identity means the resource is patched in
            // place rather than replaced.
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
            continue;
        }
        let Some(slot) = slot_of(manifest) else {
            continue;
        };
        let Some(candidates) = added_by_slot.get(&slot) else {
            // Removed stateful resource with no replacement in the slot.
            continue;
        };

        let source_may_hold_data = may_hold_data(manifest);
        let unclaimed = |(target_rid, m): &&(ResourceId, &Value)| {
            !consumed.contains(&candidate_key(target_rid, m))
        };
        let chosen = candidates
            .iter()
            .filter(unclaimed)
            // Same kind always pairs, since a renamed Secret may hold the only copy of a key.
            .find(|(target_rid, _)| target_rid.kind == rid.kind)
            .or_else(|| {
                candidates
                    .iter()
                    .filter(unclaimed)
                    .find(|(_, m)| source_may_hold_data && may_hold_data(m))
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

    /// Return `manifest` with its `apiVersion` set.
    fn with_api(mut manifest: Value, api_version: &str) -> Value {
        manifest["apiVersion"] = json!(api_version);
        manifest
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

    /// Return `manifest` with `spec.<key>` set to `value`.
    fn with_spec(mut manifest: Value, key: &str, value: Value) -> Value {
        manifest["spec"][key] = value;
        manifest
    }

    /// Return `manifest` marked as an import marker.
    fn as_import_marker(mut manifest: Value) -> Value {
        manifest["metadata"]["annotations"][keys::MODE] = json!("import");
        manifest["apiVersion"] = json!(keys::API_VERSION);
        manifest
    }

    /// Return a manifest of `kind` and `name` in the stateful package `data/postgres`.
    fn in_postgres(kind: &str, name: &str, identity_hash: &str) -> Value {
        stamped(
            kind,
            "data",
            name,
            "data",
            "postgres",
            Some("stateful"),
            None,
            None,
            identity_hash,
        )
    }

    #[test]
    fn detects_statefulset_to_operator_resource() {
        // Moving a database from a StatefulSet to an operator's custom
        // resource pairs across kinds, because both declare storage.
        let old = vec![with_spec(
            with_api(in_postgres("StatefulSet", "postgres", "aaaa"), "apps/v1"),
            "volumeClaimTemplates",
            json!([{ "metadata": { "name": "data" } }]),
        )];
        let new = vec![with_spec(
            with_api(
                in_postgres("Cluster", "postgres", "bbbb"),
                "postgresql.cnpg.io/v1",
            ),
            "storage",
            json!({ "size": "10Gi" }),
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].reason, "StatefulSet removed, Cluster added");
    }

    #[test]
    fn detects_operator_swap_cross_kind() {
        // Kix cannot see where a custom resource keeps its data, so a swap
        // between two operators' resources pairs.
        let old = vec![with_api(
            in_postgres("SGCluster", "postgres", "aaaa"),
            "stackgres.io/v1",
        )];
        let new = vec![with_api(
            in_postgres("Cluster", "postgres", "bbbb"),
            "postgresql.cnpg.io/v1",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].reason, "SGCluster removed, Cluster added");
    }

    #[test]
    fn ignores_builtin_without_storage_to_custom_resource() {
        // A ConfigMap holds no data, so replacing it with a custom resource
        // moves none.
        let old = vec![in_postgres("ConfigMap", "postgres", "aaaa")];
        let new = vec![with_api(
            in_postgres("Cluster", "postgres", "bbbb"),
            "postgresql.cnpg.io/v1",
        )];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    #[test]
    fn detects_persistent_volume_to_custom_resource() {
        // A PersistentVolume declares its size in `spec.capacity.storage`.
        let old = vec![with_spec(
            in_postgres("PersistentVolume", "postgres-data", "aaaa"),
            "capacity",
            json!({ "storage": "10Gi" }),
        )];
        let new = vec![with_api(
            in_postgres("Cluster", "postgres", "bbbb"),
            "postgresql.cnpg.io/v1",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].reason, "PersistentVolume removed, Cluster added");
    }

    #[test]
    fn detects_same_kind_rename() {
        // A renamed object of the same kind pairs whether or not its manifest
        // declares storage.
        let old = vec![in_postgres("StatefulSet", "postgres", "aaaa")];
        let new = vec![in_postgres("StatefulSet", "postgres-v2", "bbbb")];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].target.name, "postgres-v2");
    }

    #[test]
    fn ignores_removed_import_marker() {
        // A stateful package stops importing a Secret and adds a
        // PodDisruptionBudget. Neither holds data.
        let old = vec![as_import_marker(in_postgres(
            "PackageInstance",
            "secret-ref-password",
            "aaaa",
        ))];
        let new = vec![with_api(
            in_postgres("PodDisruptionBudget", "postgres", "bbbb"),
            "policy/v1",
        )];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    #[test]
    fn ignores_added_import_marker() {
        // An import marker never pairs, even with a removed object of its kind.
        let old = vec![in_postgres("PackageInstance", "postgres", "aaaa")];
        let new = vec![as_import_marker(in_postgres(
            "PackageInstance",
            "secret-ref-password",
            "bbbb",
        ))];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    #[test]
    fn ignores_cross_kind_without_storage() {
        // A Deployment replaced by a ConfigMap in a stateful package moves no data.
        let old = vec![with_api(
            in_postgres("Deployment", "postgres", "aaaa"),
            "apps/v1",
        )];
        let new = vec![in_postgres("ConfigMap", "postgres", "bbbb")];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    #[test]
    fn ignores_cross_kind_when_only_the_source_holds_data() {
        // A removed claim does not pair with an added object that declares no storage.
        let old = vec![stamped(
            "PersistentVolumeClaim",
            "data",
            "postgres",
            "data",
            "postgres",
            Some("stateful"),
            None,
            Some("10Gi"),
            "aaaa",
        )];
        let new = vec![in_postgres("Service", "postgres", "bbbb")];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    #[test]
    fn ignores_same_k8s_identity_patch() {
        // An unchanged identity (`kind/ns/name`) with modified content is an
        // in-place patch, so data stays in place.
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

    /// Return `manifest` with `kix.run/holds-data` set to `value`.
    fn marked(mut manifest: Value, value: &str) -> Value {
        manifest["metadata"]["annotations"][keys::HOLDS_DATA] = json!(value);
        manifest
    }

    #[test]
    fn ignores_custom_resources_marked_as_holding_no_data() {
        // A PodMonitor swapped for a PrometheusRule in a stateful package
        // moves no data. Unmarked, both are custom resources and pair.
        let monitor = || {
            with_api(
                in_postgres("PodMonitor", "postgres", "aaaa"),
                "monitoring.coreos.com/v1",
            )
        };
        let rule = || {
            with_api(
                in_postgres("PrometheusRule", "postgres-alerts", "bbbb"),
                "monitoring.coreos.com/v1",
            )
        };
        assert!(
            detect_migration_pairs(&[marked(rule(), "false")], &[marked(monitor(), "false")])
                .is_empty()
        );
        assert_eq!(detect_migration_pairs(&[rule()], &[monitor()]).len(), 1);
    }

    #[test]
    fn detects_cross_kind_marked_as_holding_data() {
        let old = vec![marked(
            with_api(
                in_postgres("SGCluster", "postgres", "aaaa"),
                "stackgres.io/v1",
            ),
            "true",
        )];
        let new = vec![marked(
            with_api(
                in_postgres("Cluster", "postgres", "bbbb"),
                "postgresql.cnpg.io/v1",
            ),
            "true",
        )];
        let pairs = detect_migration_pairs(&new, &old);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].reason, "SGCluster removed, Cluster added");
    }

    #[test]
    fn the_mark_overrides_the_storage_shape() {
        // A custom resource marked "false" does not pair even when its spec
        // has the `storage` shape the fallback reads.
        let old = vec![marked(
            with_spec(
                with_api(
                    in_postgres("Cluster", "postgres", "aaaa"),
                    "postgresql.cnpg.io/v1",
                ),
                "storage",
                json!({ "size": "10Gi" }),
            ),
            "false",
        )];
        let new = vec![marked(
            with_api(
                in_postgres("SGCluster", "postgres", "bbbb"),
                "stackgres.io/v1",
            ),
            "true",
        )];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    #[test]
    fn an_unmarked_side_uses_the_fallback() {
        // The removed object was built by a Kix that wrote no mark, so its
        // custom resource kind is assumed to hold data, and it pairs with a
        // replacement marked "true".
        let old = vec![with_api(
            in_postgres("SGCluster", "postgres", "aaaa"),
            "stackgres.io/v1",
        )];
        let new = vec![marked(
            with_api(
                in_postgres("Cluster", "postgres", "bbbb"),
                "postgresql.cnpg.io/v1",
            ),
            "true",
        )];
        assert_eq!(detect_migration_pairs(&new, &old).len(), 1);
        // An unmarked ConfigMap holds no data by its shape.
        let old = vec![in_postgres("ConfigMap", "postgres", "aaaa")];
        assert!(detect_migration_pairs(&new, &old).is_empty());
    }

    /// The CLI and the library draw the built-in boundary from the same
    /// lists. Skipped when the repository tree is not there, so a packaged
    /// crate still tests clean.
    #[test]
    fn built_in_groups_match_the_library() {
        let Some(path) = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors()
            .map(|p| p.join("kix/lib/core/api-groups.json"))
            .find(|p| p.is_file())
        else {
            return;
        };
        let lists: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let strings = |key: &str| -> Vec<String> {
            lists[key]
                .as_array()
                .unwrap_or_else(|| panic!("{} has no {key} list", path.display()))
                .iter()
                .map(|v| v.as_str().unwrap().to_string())
                .collect()
        };
        assert_eq!(strings("builtinGroups"), BUILTIN_GROUPS);
        assert_eq!(strings("builtinGroupSuffixes"), BUILTIN_GROUP_SUFFIXES);
    }
}
