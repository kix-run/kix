//! Annotation stamping: add `kix.dev/*` annotations to resource manifests.
//!
//! After building a `StoreGraph`, this module stamps each resource with:
//! - `kix.dev/content-hash` — the 32-char Nix store hash of the resource
//! - `kix.dev/package` — owning package instance name
//! - `kix.dev/package-namespace` — namespace of the owning package
//! - `kix.dev/depends-on` — comma-separated store hashes of cross-package deps

use std::path::PathBuf;

use kix_eval::store_graph::{StoreGraph, store_hash};

/// Stamp kix.dev annotations onto every resource manifest in the graph.
/// Modifies manifests in place.
///
/// Uses the bulk-loaded ref_cache from StoreGraph — no subprocess calls.
pub fn stamp_annotations(graph: &mut StoreGraph) {
    // First pass: collect stamping info using explicit loops to avoid borrow issues.
    let mut stamp_info: Vec<(PathBuf, String, String, String, Vec<String>)> = Vec::new();

    for pkg in graph.packages.values() {
        for res_path in &pkg.resource_paths {
            let cross_refs = graph.cross_pkg_refs(res_path);
            let dep_hashes: Vec<String> = cross_refs.iter().map(|r| store_hash(r)).collect();
            let content_hash = store_hash(res_path);

            stamp_info.push((
                res_path.clone(),
                content_hash,
                pkg.instance_name.clone(),
                pkg.namespace.clone(),
                dep_hashes,
            ));
        }
    }

    // Second pass: stamp annotations.
    for (res_path, content_hash, instance_name, namespace, dep_hashes) in stamp_info {
        let Some(res) = graph.resources.get_mut(&res_path) else {
            continue;
        };

        let mut new_anns = serde_json::Map::new();
        new_anns.insert(
            "kix.dev/content-hash".to_string(),
            serde_json::Value::String(content_hash),
        );
        new_anns.insert(
            "kix.dev/package".to_string(),
            serde_json::Value::String(instance_name),
        );
        new_anns.insert(
            "kix.dev/package-namespace".to_string(),
            serde_json::Value::String(namespace),
        );
        if !dep_hashes.is_empty() {
            new_anns.insert(
                "kix.dev/depends-on".to_string(),
                serde_json::Value::String(dep_hashes.join(",")),
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
