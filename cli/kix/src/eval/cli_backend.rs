//! Subprocess-based Nix backend using `nix` CLI commands:
//! - `list_clusters`, `list_packages`, and `list_cluster_packages` run
//!   `nix eval --json` against the flake's `kixClusters` and `kixPackages`
//!   attributes.
//! - `eval_cluster` runs `nix eval` of the cluster's `activationIndex` and
//!   extracts manifests through `StoreGraph`.
//!
//! Nix's built-in evaluation cache keeps repeated invocations fast, and
//! [`super::evaluator::KixEvaluator`] layers a SQLite cache on top.

use std::path::Path;
use std::process::Command;

use std::collections::BTreeMap;

use super::error::KixEvalError;
use super::evaluator::{ClusterOutput, ClusterPackageInfo, NixBackend, PackageInfo};
use super::nix;
use crate::runtime::Tool;

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
    pub(crate) fn new() -> Self {
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

    /// Explain a `legacyPackages.<system>.<attr>` lookup that Nix said the
    /// flake at `flake_path` does not provide: the flake has that output
    /// for other systems only, or it has no Kix outputs at all.
    fn missing_output(&self, flake_path: &Path, attr: &str) -> KixEvalError {
        nix::system_not_provided(
            ".",
            "legacyPackages",
            Some(flake_path),
            &self.input_overrides,
        )
        .unwrap_or_else(|| KixEvalError::NoKixOutputs {
            attr: format!("legacyPackages.{}.{attr}", nix::current_system()),
        })
    }
}

impl NixBackend for CliNixBackend {
    fn eval_cluster(
        &mut self,
        flake_path: &Path,
        cluster_name: &str,
    ) -> Result<ClusterOutput, KixEvalError> {
        let index = super::nix::eval_activation_index(
            flake_path,
            cluster_name,
            &self.input_overrides,
            &|_| {},
        )?;
        let files = super::build_files::BuildFiles::read(&index)?;

        // Stamped, because kix.run/depends-on edges name identity hashes.
        let graph = crate::build_source::Build::local(&index, &|_| {})?.into_graph();

        let mut raw_manifests: Vec<serde_json::Value> = graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect();
        // StoreGraph.resources is a HashMap, so its iteration order changes
        // from one run to the next. Sort so that `kix build` and `kix graph`
        // print the same order every time.
        raw_manifests.sort_by_cached_key(manifest_sort_key);

        let scorecard_path = files
            .scorecard
            .and_then(|p| super::store::disk_path(&p).ok())
            .unwrap_or_default();
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

        let extra_images_path = files
            .extra_images
            .and_then(|p| super::store::disk_path(&p).ok())
            .unwrap_or_default();
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
            "cluster evaluated"
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

        // Query `legacyPackages.<system>.kixClusters` directly via `nix eval`.
        // `mkFlake.nix` exports this attribute set for the CLI because
        // `nix flake show --json` can omit cluster attributes when
        // `--override-input` introduces a path input.
        let attr = format!(".#legacyPackages.{}.kixClusters", nix::current_system());

        let mut cmd = nix::command(Tool::Nix)?;
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
        let output = match nix::output(cmd.current_dir(flake_path)) {
            Err(e) if e.missing_attribute() => {
                return Err(self.missing_output(flake_path, "kixClusters"));
            }
            output => output?,
        };

        let mut clusters: Vec<String> =
            serde_json::from_slice(&output).map_err(|e| KixEvalError::StoreGraphError {
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

        let attr = format!(".#legacyPackages.{}.kixPackages", nix::current_system());

        let mut cmd = nix::command(Tool::Nix)?;
        cmd.args([
            "eval",
            &attr,
            "--json",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
        self.apply_overrides(&mut cmd);
        let output = match nix::output(cmd.current_dir(flake_path)) {
            Err(e) if e.missing_attribute() => {
                return Err(self.missing_output(flake_path, "kixPackages"));
            }
            output => output?,
        };

        let packages: BTreeMap<String, PackageInfo> =
            serde_json::from_slice(&output).map_err(|e| KixEvalError::StoreGraphError {
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
            nix::current_system(),
            cluster_name
        );

        let mut cmd = nix::command(Tool::Nix)?;
        cmd.args([
            "eval",
            &attr,
            "--json",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ]);
        self.apply_overrides(&mut cmd);
        let output = match nix::output(cmd.current_dir(flake_path)) {
            Err(e) if e.missing_attribute() => {
                return Err(nix::system_not_provided(
                    ".",
                    "legacyPackages",
                    Some(flake_path),
                    &self.input_overrides,
                )
                .unwrap_or_else(|| KixEvalError::not_found(cluster_name)));
            }
            output => output?,
        };

        let info: ClusterPackageInfo =
            serde_json::from_slice(&output).map_err(|e| KixEvalError::StoreGraphError {
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

/// Evaluate the `name` of the cluster defined by flake attribute `attr`, or
/// return `None` when `kixClusters` lacks `attr` or the flake has no
/// `kixClusters` output. A flake that has Kix outputs for other systems
/// only is an error, since the attribute may well be defined there.
///
/// The returned name is the value passed to `buildCluster` and written into
/// the Activation record's `kix.run/cluster` label. It differs from `attr`
/// when a flake maps an attribute like `clusters.harbor = ./test-harbor.nix`
/// to a cluster definition that sets `name = "test-harbor"`. Reading `name`
/// evaluates the `buildCluster` call without building derivations.
///
/// `flake` may be a local directory path or a flake URL such as
/// `github:org/repo`.
pub fn eval_cluster_name(
    flake: &str,
    attr: &str,
    input_overrides: &[(String, String)],
) -> Result<Option<String>, KixEvalError> {
    let Some(mut cmd) = cluster_name_command(flake, attr, input_overrides)? else {
        return Ok(None);
    };
    let output = match nix::output(&mut cmd) {
        // A flake without `legacyPackages.<sys>.kixClusters` for any system
        // is not a Kix flake and defines no clusters.
        Err(e) if e.missing_attribute() => {
            return match nix::system_not_provided(flake, "legacyPackages", None, input_overrides) {
                Some(err) => Err(err),
                None => Ok(None),
            };
        }
        output => output?,
    };
    serde_json::from_slice(&output).map_err(|e| KixEvalError::StoreGraphError {
        message: format!("failed to parse the name of cluster '{attr}': {e}"),
    })
}

/// Build the `nix eval` command that reads `kixClusters.<attr>.name` from
/// `flake`, or return `None` when `attr` is not a valid attribute name.
pub fn cluster_name_command(
    flake: &str,
    attr: &str,
    input_overrides: &[(String, String)],
) -> Result<Option<Command>, KixEvalError> {
    // `attr` is spliced into a Nix string literal below.
    if !attr
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Ok(None);
    }
    let flake_attr = format!(
        "{flake}#legacyPackages.{}.kixClusters",
        nix::current_system()
    );
    let apply = format!(
        "cs: if builtins.hasAttr \"{attr}\" cs then (builtins.getAttr \"{attr}\" cs).name else null"
    );
    let mut cmd = nix::command(Tool::Nix)?;
    cmd.args([
        "eval",
        &flake_attr,
        "--apply",
        &apply,
        "--json",
        "--extra-experimental-features",
        "nix-command flakes pipe-operators",
    ]);
    for (name, url) in input_overrides {
        cmd.arg("--override-input").arg(name).arg(url);
    }
    Ok(Some(cmd))
}

/// Return a deterministic sort key `(apiVersion, kind, namespace, name)` for `manifest`.
pub fn manifest_sort_key(manifest: &serde_json::Value) -> (String, String, String, String) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::nix::other_system;

    fn flake_with(outputs: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("flake.nix"),
            format!("{{ outputs = _: {{ {outputs} }}; }}"),
        )
        .unwrap();
        dir
    }

    /// A flake with Kix outputs for other systems only names them, in every
    /// lookup, instead of reporting the cluster or the flake as missing.
    #[test]
    fn a_flake_for_other_systems_names_them_in_every_lookup() {
        let other = other_system();
        let dir = flake_with(&format!(
            "legacyPackages.{other}.kixClusters = {{ }}; legacyPackages.{other}.kixPackages = {{ }};"
        ));
        let mut backend = CliNixBackend::new();
        let is_system_not_provided = |err: &KixEvalError| matches!(err, KixEvalError::SystemNotProvided { provided, .. } if provided == &[other.to_string()]);
        let err = backend.list_clusters(dir.path()).unwrap_err();
        assert!(is_system_not_provided(&err), "{err}");
        let err = backend.list_packages(dir.path()).unwrap_err();
        assert!(is_system_not_provided(&err), "{err}");
        let err = backend.list_cluster_packages(dir.path(), "c").unwrap_err();
        assert!(is_system_not_provided(&err), "{err}");
        let err = eval_cluster_name(&dir.path().display().to_string(), "c", &[]).unwrap_err();
        assert!(is_system_not_provided(&err), "{err}");
    }

    /// A flake with no Kix outputs for any system is not a Kix flake, and
    /// the error says so, naming the attribute `kix list` looked for.
    #[test]
    fn a_flake_with_no_kix_outputs_says_so() {
        let dir = flake_with("");
        let mut backend = CliNixBackend::new();
        let err = backend.list_clusters(dir.path()).unwrap_err();
        assert!(
            matches!(&err, KixEvalError::NoKixOutputs { attr }
                if *attr == format!("legacyPackages.{}.kixClusters", nix::current_system())),
            "{err}"
        );
        assert!(matches!(
            backend.list_cluster_packages(dir.path(), "c").unwrap_err(),
            KixEvalError::ClusterNotFound { .. }
        ));
    }

    /// A flake with Kix outputs for this system reports a cluster it does
    /// not define as missing.
    #[test]
    fn a_missing_cluster_on_a_flake_for_this_system_is_not_found() {
        let dir = flake_with(&format!(
            "legacyPackages.{}.kixClusters = {{ }};",
            nix::current_system()
        ));
        let mut backend = CliNixBackend::new();
        assert_eq!(
            backend.list_clusters(dir.path()).unwrap(),
            Vec::<String>::new()
        );
        assert!(matches!(
            backend.list_cluster_packages(dir.path(), "c").unwrap_err(),
            KixEvalError::ClusterNotFound { .. }
        ));
    }
}
