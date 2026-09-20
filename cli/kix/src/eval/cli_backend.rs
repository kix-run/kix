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

use std::collections::BTreeMap;

use super::error::KixEvalError;
use super::evaluator::{ClusterOutput, ClusterPackageInfo, NixBackend, PackageInfo};

/// Nix CLI subprocess backend.
pub struct CliNixBackend {
    /// Flake input overrides forwarded to every `nix` subprocess as
    /// `--override-input <name> <url>`. Populated from the CLI's
    /// repeated `--override-input` global flag.
    input_overrides: Vec<(String, String)>,
}

impl Default for CliNixBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl CliNixBackend {
    pub fn new() -> Self {
        Self {
            input_overrides: Vec::new(),
        }
    }

    pub fn with_overrides(input_overrides: Vec<(String, String)>) -> Self {
        Self { input_overrides }
    }

    /// Append `--override-input <name> <url>` flags to a `nix` command.
    fn apply_overrides(&self, cmd: &mut Command) {
        for (name, url) in &self.input_overrides {
            cmd.arg("--override-input").arg(name).arg(url);
        }
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
        let result_dir = super::build::build_cluster_activation(
            flake_path,
            cluster_name,
            &self.input_overrides,
        )?;

        // Load the StoreGraph, stamp identity-hash + package annotations,
        // then extract manifests. Without stamping, kix.run/depends-on edges
        // can't be resolved (they reference identity hashes).
        let mut graph = super::store_graph::StoreGraph::from_result_dir(&result_dir)?;
        crate::manifest::stamp::stamp_annotations(&mut graph);

        let mut raw_manifests: Vec<serde_json::Value> = graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect();
        // StoreGraph.resources is a HashMap, so its iteration order changes
        // from one run to the next. Sort so that `kix build` and `kix graph`
        // print the same order every time.
        raw_manifests.sort_by_cached_key(manifest_sort_key);

        // Read scorecard report if present
        let scorecard_path = result_dir.join("kix-scorecard.json");
        let scorecard_report = if scorecard_path.exists() {
            match std::fs::read_to_string(&scorecard_path) {
                Ok(json_str) => match serde_json::from_str::<serde_json::Value>(&json_str) {
                    Ok(val) => {
                        tracing::debug!(cluster = cluster_name, "scorecard report loaded");
                        Some(val)
                    }
                    Err(e) => {
                        tracing::warn!(cluster = cluster_name, error = %e, "failed to parse scorecard report");
                        None
                    }
                },
                Err(e) => {
                    tracing::warn!(cluster = cluster_name, error = %e, "failed to read scorecard report");
                    None
                }
            }
        } else {
            None
        };

        // Read extra images if present (operator-spawned images declared by packages)
        let extra_images_path = result_dir.join("kix-extra-images.json");
        let extra_images = if extra_images_path.exists() {
            match std::fs::read_to_string(&extra_images_path) {
                Ok(json_str) => {
                    match serde_json::from_str::<Vec<super::evaluator::ExtraImage>>(&json_str) {
                        Ok(imgs) => {
                            tracing::debug!(
                                cluster = cluster_name,
                                count = imgs.len(),
                                "extra images loaded"
                            );
                            Some(imgs)
                        }
                        Err(e) => {
                            tracing::warn!(cluster = cluster_name, error = %e, "failed to parse extra images");
                            None
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!(cluster = cluster_name, error = %e, "failed to read extra images");
                    None
                }
            }
        } else {
            None
        };

        tracing::info!(
            cluster = cluster_name,
            manifests = raw_manifests.len(),
            "cluster evaluated via nix build"
        );

        Ok(ClusterOutput {
            name: cluster_name.to_string(),
            raw_manifests,
            scorecard_report,
            extra_images,
        })
    }

    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
        tracing::debug!("listing clusters via nix eval");

        // Query `legacyPackages.<system>.kixClusters` and take its attr
        // names. mkFlake.nix exports that attrset specifically for this
        // CLI path. Previously we shelled out to `nix flake show
        // --json` and walked the packages tree, but Determinate Nix
        // sometimes omits cluster attrs from that output when
        // `--override-input` introduces a path input. `nix eval` is a
        // direct attribute query and stays stable.
        let attr = format!(".#legacyPackages.{}.kixClusters", current_nix_system());

        let mut cmd = Command::new("nix");
        cmd.args([
            "eval",
            &attr,
            "--apply",
            "builtins.attrNames",
            "--json",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
        self.apply_overrides(&mut cmd);
        let output =
            cmd.current_dir(flake_path)
                .output()
                .map_err(|e| KixEvalError::StoreGraphError {
                    message: format!("failed to run nix eval: {e}"),
                })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KixEvalError::StoreGraphError {
                message: format!("nix eval kixClusters failed: {stderr}"),
            });
        }

        let mut clusters: Vec<String> =
            serde_json::from_slice(&output.stdout).map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to parse cluster names: {e}"),
            })?;

        clusters.sort();
        tracing::debug!(count = clusters.len(), "clusters found");

        Ok(clusters)
    }

    fn list_packages(
        &mut self,
        flake_path: &Path,
    ) -> Result<BTreeMap<String, PackageInfo>, KixEvalError> {
        tracing::debug!("listing packages via nix eval");

        let attr = format!(".#legacyPackages.{}.kixPackages", current_nix_system());

        let mut cmd = Command::new("nix");
        cmd.args([
            "eval",
            &attr,
            "--json",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
        self.apply_overrides(&mut cmd);
        let output =
            cmd.current_dir(flake_path)
                .output()
                .map_err(|e| KixEvalError::StoreGraphError {
                    message: format!("failed to run nix eval: {e}"),
                })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(KixEvalError::StoreGraphError {
                message: format!("nix eval kixPackages failed: {stderr}"),
            });
        }

        let packages: BTreeMap<String, PackageInfo> = serde_json::from_slice(&output.stdout)
            .map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to parse kixPackages output: {e}"),
            })?;

        tracing::debug!(count = packages.len(), "packages found");
        Ok(packages)
    }

    fn list_cluster_packages(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterPackageInfo, KixEvalError> {
        if !cluster_name
            .chars()
            .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
        {
            return Err(KixEvalError::not_found(cluster_name));
        }

        tracing::debug!(
            cluster = cluster_name,
            "listing cluster packages via nix eval"
        );

        let attr = format!(
            ".#legacyPackages.{}.kixClusters.{}.info",
            current_nix_system(),
            cluster_name
        );

        let mut cmd = Command::new("nix");
        cmd.args([
            "eval",
            &attr,
            "--json",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
        self.apply_overrides(&mut cmd);
        let output =
            cmd.current_dir(flake_path)
                .output()
                .map_err(|e| KixEvalError::StoreGraphError {
                    message: format!("failed to run nix eval: {e}"),
                })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            // Check if this looks like a cluster-not-found error
            if stderr.contains("does not provide attribute") {
                return Err(KixEvalError::ClusterNotFound {
                    name: cluster_name.to_string(),
                });
            }
            return Err(KixEvalError::StoreGraphError {
                message: format!("nix eval cluster info failed: {stderr}"),
            });
        }

        let info: ClusterPackageInfo =
            serde_json::from_slice(&output.stdout).map_err(|e| KixEvalError::StoreGraphError {
                message: format!("failed to parse cluster info output: {e}"),
            })?;

        tracing::debug!(
            cluster = cluster_name,
            instances = info.instances.values().map(|ns| ns.len()).sum::<usize>(),
            available = info.available_packages.len(),
            "cluster packages found"
        );
        Ok(info)
    }
}

/// Determine the current Nix system string at compile time.
fn current_nix_system() -> &'static str {
    if cfg!(all(target_arch = "x86_64", target_os = "linux")) {
        "x86_64-linux"
    } else if cfg!(all(target_arch = "aarch64", target_os = "linux")) {
        "aarch64-linux"
    } else if cfg!(all(target_arch = "x86_64", target_os = "macos")) {
        "x86_64-darwin"
    } else if cfg!(all(target_arch = "aarch64", target_os = "macos")) {
        "aarch64-darwin"
    } else {
        "x86_64-linux"
    }
}

/// Stable ordering for manifests: apiVersion, kind, namespace, name.
fn manifest_sort_key(manifest: &serde_json::Value) -> (String, String, String, String) {
    let field = |pointer: &str| {
        manifest
            .pointer(pointer)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    (
        field("/apiVersion"),
        field("/kind"),
        field("/metadata/namespace"),
        field("/metadata/name"),
    )
}
