//! Annotation stamping: add `kix.dev/*` annotations to resource manifests.
//!
//! After building a `StoreGraph`, this module stamps each resource with:
//! - `kix.dev/identity-hash` — the 32-char Nix store hash of the resource
//! - `kix.dev/package` — owning package instance name
//! - `kix.dev/package-namespace` — namespace of the owning package
//! - `kix.dev/depends-on` — comma-separated store hashes of cross-package deps
//! - `kix.dev/activations` — comma-separated activation identity-hashes (set during apply)

use std::path::PathBuf;

use kix_eval::store_graph::{StoreGraph, store_hash};

/// Collected stamping info for a single resource.
struct StampEntry {
    res_path: PathBuf,
    identity_hash: String,
    package: String,
    package_namespace: String,
    dep_hashes: Vec<String>,
}

/// Stamp kix.dev annotations onto every resource manifest in the graph.
/// Modifies manifests in place.
///
/// Uses the bulk-loaded ref_cache from StoreGraph — no subprocess calls.
pub fn stamp_annotations(graph: &mut StoreGraph) {
    // First pass: collect stamping info using explicit loops to avoid borrow issues.
    let mut stamp_info: Vec<StampEntry> = Vec::new();

    for pkg in graph.packages.values() {
        for res_path in &pkg.resource_paths {
            let cross_refs = graph.cross_pkg_refs(res_path);
            let dep_hashes: Vec<String> = cross_refs.iter().map(|r| store_hash(r)).collect();

            stamp_info.push(StampEntry {
                res_path: res_path.clone(),
                identity_hash: store_hash(res_path),
                package: pkg.instance_name.clone(),
                package_namespace: pkg.namespace.clone(),
                dep_hashes,
            });
        }
    }

    // Stamp cluster-level resources (not owned by any package).
    {
        let owned_paths: std::collections::HashSet<PathBuf> =
            stamp_info.iter().map(|e| e.res_path.clone()).collect();
        let cluster_paths: Vec<PathBuf> = graph
            .resources
            .keys()
            .filter(|p| !owned_paths.contains(*p))
            .cloned()
            .collect();
        for res_path in cluster_paths {
            // Find k8s deps in the ref_cache
            let empty = vec![];
            let refs = graph.ref_cache.get(&res_path).unwrap_or(&empty);
            let dep_hashes: Vec<String> = refs
                .iter()
                .filter(|r| graph.resources.contains_key(r.as_path()) && **r != res_path)
                .map(|r| store_hash(r))
                .collect();

            stamp_info.push(StampEntry {
                identity_hash: store_hash(&res_path),
                package: "_cluster".to_string(),
                package_namespace: "_cluster".to_string(),
                dep_hashes,
                res_path,
            });
        }
    }

    // Second pass: stamp annotations.
    for entry in stamp_info {
        let Some(res) = graph.resources.get_mut(&entry.res_path) else {
            continue;
        };

        let mut new_anns = serde_json::Map::new();
        new_anns.insert(
            "kix.dev/identity-hash".to_string(),
            serde_json::Value::String(entry.identity_hash),
        );
        new_anns.insert(
            "kix.dev/package".to_string(),
            serde_json::Value::String(entry.package),
        );
        new_anns.insert(
            "kix.dev/package-namespace".to_string(),
            serde_json::Value::String(entry.package_namespace),
        );
        if !entry.dep_hashes.is_empty() {
            new_anns.insert(
                "kix.dev/depends-on".to_string(),
                serde_json::Value::String(entry.dep_hashes.join(",")),
            );
        }

        if let Some(anns) = res
            .manifest
            .pointer_mut("/metadata/annotations")
            .and_then(|v| v.as_object_mut())
        {
            anns.extend(new_anns);
        } else if let Some(metadata) = res
            .manifest
            .pointer_mut("/metadata")
            .and_then(|v| v.as_object_mut())
        {
            metadata.insert(
                "annotations".to_string(),
                serde_json::Value::Object(new_anns),
            );
        }
    }
}
