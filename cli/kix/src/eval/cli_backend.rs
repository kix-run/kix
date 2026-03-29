//! Subprocess-based Nix backend using `nix` CLI commands.
//!
//! Replaces the FFI backend with standard `nix` subprocess calls:
//! - `list_clusters` → `nix flake show --json` filtered for `cluster-*-activation`
//! - `eval_cluster` → `nix build .#cluster-<name>-activation` + StoreGraph manifest extraction
//!
//! This is slower than FFI for raw evaluation but benefits from Nix's built-in
//! eval cache, making repeated invocations fast. Combined with the SQLite cache
//! in KixEvaluator, this provides good performance for all commands.

use std::path::Path;
use std::process::Command;

use super::error::KixEvalError;
use super::evaluator::{ClusterOutput, NixBackend};

/// Nix CLI subprocess backend.
pub struct CliNixBackend;

impl Default for CliNixBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl CliNixBackend {
    pub fn new() -> Self {
        Self
    }
}

impl NixBackend for CliNixBackend {
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
        if !cluster_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return Err(KixEvalError::not_found(cluster_name));
        }

        tracing::info!(cluster = cluster_name, "building cluster activation");

        // Build the activation via nix build (same path as deploy/diff/gc)
        let result_dir = super::build::build_cluster_activation(flake_path, cluster_name)?;

        // Load the StoreGraph, stamp identity-hash + package annotations,
        // then extract manifests. Without stamping, kix.dev/depends-on edges
        // can't be resolved (they reference identity hashes).
        let mut graph = super::store_graph::StoreGraph::from_result_dir(&result_dir)?;
        crate::manifest::stamp::stamp_annotations(&mut graph);

        let raw_manifests: Vec<serde_json::Value> = graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect();

        tracing::info!(
            cluster = cluster_name,
            manifests = raw_manifests.len(),
            "cluster evaluated via nix build"
        );

        Ok(ClusterOutput {
            name: cluster_name.to_string(),
            raw_manifests,
        })
    }

    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
        tracing::debug!("listing clusters via nix flake show");

        let output = Command::new("nix")
            .args([
                "flake",
                "show",
                "--json",
                "--extra-experimental-features",
                "nix-command flakes pipe-operators",
            ])
            .current_dir(flake_path)
            .output()
            .map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to run nix flake show: {e}"),
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KixEvalError::StoreGraphError {
                message: format!("nix flake show failed: {stderr}"),
            });
        }

        let flake_output: serde_json::Value =
            serde_json::from_slice(&output.stdout).map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to parse nix flake show output: {e}"),
            })?;

        // Extract cluster names from packages.<system>.cluster-*-activation
        // The system doesn't matter — cluster names are the same across systems.
        let mut clusters = Vec::new();

        if let Some(packages) = flake_output.get("packages") {
            // Pick the first system we find
            if let Some(per_system) = packages.as_object().and_then(|o| o.values().next())
                && let Some(attrs) = per_system.as_object()
            {
                for key in attrs.keys() {
                    if let Some(name) = key
                        .strip_prefix("cluster-")
                        .and_then(|s| s.strip_suffix("-activation"))
                    {
                        clusters.push(name.to_string());
                    }
                }
            }
        }

        clusters.sort();
        tracing::debug!(count = clusters.len(), "clusters found");

        Ok(clusters)
    }
}
