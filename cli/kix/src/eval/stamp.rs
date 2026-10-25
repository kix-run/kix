//! Annotation stamping: add `kix.run/*` annotations to resource manifests.
//!
//! A loaded `StoreGraph` is stamped once, as [`crate::build_source::Build`]
//! makes it (or the evaluator's [`super::cli_backend`] loads it), so
//! commands see only stamped graphs. Each resource gets:
//! - `kix.run/identity-hash`: the 32-character Nix store hash
//! - `kix.run/package`: owning package instance name
//! - `kix.run/package-namespace`: namespace of the owning package
//! - `kix.run/lifecycle`: package lifecycle used by migration detection
//! - `kix.run/activations`: activation identity hashes, set during apply
//!
//! Note: `kix.run/depends-on` is stamped at resource creation time in Nix (lib/k8s.nix).

use std::path::PathBuf;

use super::store_graph::{StoreGraph, store_hash};
use crate::manifest::keys;

/// Collected stamping info for a single resource.
struct StampEntry {
    res_path: PathBuf,
    identity_hash: String,
    package: String,
    package_namespace: String,
    lifecycle: Option<String>,
}

/// Stamp kix.run annotations onto every resource manifest in the graph.
/// Modifies manifests in place.
///
/// Commands get a graph stamped by [`crate::build_source::Build`]. This is
/// public for `kix-bundle`, which stamps the bundle it reads back to compare
/// it with the build, and for tests that change a graph before stamping.
pub fn stamp_annotations(graph: &mut StoreGraph) {
    // A build loaded from an activation that predates a domain move carries
    // the retired keys in its store paths. Bring them to the current domain
    // before anything reads them, so the planner, the differ and the stamps
    // below all see one domain. Inert when no domain has been retired.
    for res in graph.resources.values_mut() {
        crate::legacy_domain::upgrade_manifest(&mut res.manifest);
    }

    // First pass: collect stamping info using explicit loops to avoid borrow issues.
    let mut stamp_info: Vec<StampEntry> = Vec::new();

    for pkg in graph.packages.values() {
        for res_path in &pkg.resource_paths {
            stamp_info.push(StampEntry {
                res_path: res_path.clone(),
                identity_hash: store_hash(res_path),
                package: pkg.instance_name.clone(),
                package_namespace: pkg.namespace.clone(),
                lifecycle: pkg.lifecycle.clone(),
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
            stamp_info.push(StampEntry {
                identity_hash: store_hash(&res_path),
                package: "_cluster".to_string(),
                package_namespace: "_cluster".to_string(),
                lifecycle: None,
                res_path,
            });
        }
    }

    // Second pass: stamp annotations.
    for entry in stamp_info {
        let Some(res) = graph.resources.get_mut(&entry.res_path) else {
            continue;
        };

        // For Activation CRs:
        // - Rename to include identity hash so each deploy creates a distinct CR
        //   (enabling supersede/rollback lifecycle).
        // - Add kix.run/built-via annotation with the activation result dir path
        //   so rollback can find manifests without a nix build.
        let is_record = crate::manifest::lifecycle::is_record(&res.manifest);
        if is_record {
            let hash_prefix = &entry.identity_hash[..12.min(entry.identity_hash.len())];
            if let Some(meta) = res
                .manifest
                .pointer_mut("/metadata")
                .and_then(|v| v.as_object_mut())
            {
                let base_name = meta
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or("activation")
                    .to_string();
                meta.insert(
                    "name".to_string(),
                    serde_json::Value::String(format!("{}-{}", base_name, hash_prefix)),
                );
            }
        }

        let mut new_anns = serde_json::Map::new();

        if is_record {
            // Store the activation result dir path so rollback/deploy can
            // load manifests directly from the nix store without rebuilding.
            new_anns.insert(
                keys::BUILT_VIA.to_string(),
                serde_json::Value::String(graph.result_dir.to_string_lossy().to_string()),
            );
        }
        new_anns.insert(
            keys::IDENTITY_HASH.to_string(),
            serde_json::Value::String(entry.identity_hash),
        );
        new_anns.insert(
            keys::PACKAGE.to_string(),
            serde_json::Value::String(entry.package),
        );
        new_anns.insert(
            keys::PACKAGE_NAMESPACE.to_string(),
            serde_json::Value::String(entry.package_namespace),
        );
        if let Some(lc) = entry.lifecycle {
            new_anns.insert(keys::LIFECYCLE.to_string(), serde_json::Value::String(lc));
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
