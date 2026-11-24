//! The builder that runs `nix` commands on this machine:
//! - `list_clusters`, `list_packages`, and `list_cluster_packages` run
//!   `nix eval --json` against the flake's `kixClusters` (`kixClustersNix`
//!   under the `nix` builder) and `kixPackages` attributes.
//! - `eval_cluster` runs `nix eval` of the cluster's `activationIndex` and
//!   extracts manifests through `StoreGraph`.
//!
//! Nix's built-in evaluation cache keeps repeated invocations fast, and
//! [`super::evaluator::KixEvaluator`] layers a file cache on top.

use std::path::Path;
use std::process::Command;

use std::collections::BTreeMap;

use super::error::KixEvalError;
use super::evaluator::{Builder, ClusterOutput, ClusterPackageInfo, PackageInfo};
use super::nix;
use crate::runtime::Tool;

/// The builder that runs `nix` on this machine. The Nix runner decides which
/// `nix` and which store.
pub struct LocalBuilder {
    /// Flake input overrides forwarded to every `nix` subprocess as
    /// `--override-input <name> <url>`. Populated from the CLI's
    /// repeated `--override-input` global flag.
    input_overrides: Vec<(String, String)>,
}

impl Default for LocalBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl LocalBuilder {
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

impl Builder for LocalBuilder {
    fn source_fingerprint(&mut self, flake_path: &Path) -> Option<String> {
        // The fingerprint describes the inputs `flake.lock` names, and an
        // override replaces one of them.
        if !self.input_overrides.is_empty() || !flake_path.is_dir() {
            return None;
        }
        match nix::flake_fingerprint(flake_path) {
            Ok(fingerprint) => fingerprint,
            Err(e) => {
                tracing::debug!(flake = %flake_path.display(), error = %e, "could not read the flake's fingerprint; evaluating from source");
                None
            }
        }
    }

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
        let build = crate::build_source::Build::local(&index, &|_| {})?;
        let warnings = build.warnings().to_vec();
        let graph = build.into_graph();

        let mut raw_manifests: Vec<serde_json::Value> = graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect();
        // StoreGraph.resources is a HashMap, so its iteration order changes
        // from one run to the next. Sort so that `kix build` and `kix graph`
        // print the same order every time.
        raw_manifests.sort_by_cached_key(manifest_sort_key);

        let scorecard_report = read_build_file(files.scorecard, cluster_name, "scorecard report");
        let extra_images = read_build_file(files.extra_images, cluster_name, "extra images");

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
            warnings,
        })
    }

    fn list_clusters(&mut self, flake_path: &Path) -> Result<Vec<String>, KixEvalError> {
        tracing::debug!("listing clusters via nix eval");

        // Query `legacyPackages.<system>.kixClusters` directly via `nix eval`.
        // `mkFlake.nix` exports this attribute set for the CLI because
        // `nix flake show --json` can omit cluster attributes when
        // `--override-input` introduces a path input.
        let attr = format!(
            ".#legacyPackages.{}.{}",
            nix::current_system(),
            nix::clusters_attr()
        );

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
                return Err(self.missing_output(flake_path, nix::clusters_attr()));
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
        if !nix::is_valid_cluster_name(cluster_name) {
            return Err(KixEvalError::not_found(cluster_name));
        }

        tracing::debug!(
            cluster = cluster_name,
            "listing cluster packages via nix eval"
        );

        let attr = format!(
            ".#legacyPackages.{}.{}.{}.info",
            nix::current_system(),
            nix::clusters_attr(),
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
    if !nix::is_valid_cluster_name(attr) {
        return Ok(None);
    }
    let flake_attr = format!(
        "{flake}#legacyPackages.{}.{}",
        nix::current_system(),
        nix::clusters_attr()
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

/// Read the JSON file a build lists at `path`. A file the build does not list
/// is `None`, and so is one Kix cannot read, after a warning in the log.
fn read_build_file<T: serde::de::DeserializeOwned>(
    path: Option<std::path::PathBuf>,
    cluster: &str,
    what: &str,
) -> Option<T> {
    let path = super::store::disk_path(&path?).ok()?;
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) => {
            tracing::warn!(cluster, error = %e, "failed to read {what}");
            return None;
        }
    };
    match serde_json::from_str(&text) {
        Ok(value) => {
            tracing::debug!(cluster, "{what} loaded");
            Some(value)
        }
        Err(e) => {
            tracing::warn!(cluster, error = %e, "failed to parse {what}");
            None
        }
    }
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
        let mut backend = LocalBuilder::new();
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
        let mut backend = LocalBuilder::new();
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
        let mut backend = LocalBuilder::new();
        assert_eq!(
            backend.list_clusters(dir.path()).unwrap(),
            Vec::<String>::new()
        );
        assert!(matches!(
            backend.list_cluster_packages(dir.path(), "c").unwrap_err(),
            KixEvalError::ClusterNotFound { .. }
        ));
    }

    fn git(dir: &Path, args: &[&str]) {
        let status = Command::new("git")
            .args(["-c", "user.name=test", "-c", "user.email=test@example.com"])
            .args(args)
            .current_dir(dir)
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// Make a flake whose one cluster is named by the text of `name.txt`,
    /// and return the folder to evaluate. With `git`, the flake is `proj/`
    /// in a Git repository and reads the file from the input `path:../lib`.
    /// Without, the flake is a plain folder that holds the file.
    fn flake_reading_a_file(root: &Path, in_git: bool) -> std::path::PathBuf {
        let system = nix::current_system();
        let clusters = "kixClusters = { ${builtins.readFile ./name.txt} = { }; }";
        if !in_git {
            std::fs::write(
                root.join("flake.nix"),
                format!("{{ outputs = _: {{ legacyPackages.{system}.{clusters}; }}; }}"),
            )
            .unwrap();
            std::fs::write(root.join("name.txt"), "one").unwrap();
            return root.to_path_buf();
        }
        let (proj, lib) = (root.join("proj"), root.join("lib"));
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::create_dir_all(&lib).unwrap();
        std::fs::write(
            lib.join("flake.nix"),
            format!("{{ outputs = _: {{ {clusters}; }}; }}"),
        )
        .unwrap();
        std::fs::write(lib.join("name.txt"), "one").unwrap();
        std::fs::write(
            proj.join("flake.nix"),
            format!(
                "{{ inputs.lib.url = \"path:../lib\"; outputs = inputs: {{ legacyPackages.{system}.kixClusters = inputs.lib.kixClusters; }}; }}"
            ),
        )
        .unwrap();
        // The lock Nix writes for a relative path input.
        std::fs::write(
            proj.join("flake.lock"),
            r#"{"nodes":{"lib":{"locked":{"path":"../lib","type":"path"},"original":{"path":"../lib","type":"path"},"parent":[]},"root":{"inputs":{"lib":"lib"}}},"root":"root","version":7}"#,
        )
        .unwrap();
        git(root, &["init", "-q", "."]);
        git(root, &["add", "-A"]);
        git(root, &["commit", "-q", "-m", "init"]);
        proj
    }

    /// List the clusters as a new run of Kix would, with the cache in
    /// `cache_dir`.
    fn list_cached(flake: &Path, cache_dir: &Path) -> Vec<String> {
        crate::eval::KixEvaluator::new(LocalBuilder::new(), flake, cache_dir)
            .unwrap()
            .list_clusters()
            .unwrap()
    }

    /// A changed file that an input outside the flake folder reads with
    /// `builtins.readFile` gives a new result, with no `--no-cache`.
    #[test]
    fn a_changed_file_in_a_relative_path_input_is_evaluated_again() {
        let (root, cache_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let proj = flake_reading_a_file(root.path(), true);
        let mut backend = LocalBuilder::new();
        let before = backend.source_fingerprint(&proj).expect("a fingerprint");
        assert_eq!(list_cached(&proj, cache_dir.path()), ["one"]);

        std::fs::write(root.path().join("lib/name.txt"), "two").unwrap();
        assert_ne!(backend.source_fingerprint(&proj), Some(before));
        assert_eq!(list_cached(&proj, cache_dir.path()), ["two"]);
        assert_eq!(list_cached(&proj, cache_dir.path()), ["two"]);
    }

    /// Nix leaves a file Git does not track out of the flake, so it cannot
    /// change a result, and it does not change the fingerprint.
    #[test]
    fn an_untracked_file_keeps_the_fingerprint() {
        let root = tempfile::tempdir().unwrap();
        let proj = flake_reading_a_file(root.path(), true);
        let mut backend = LocalBuilder::new();
        let before = backend.source_fingerprint(&proj).expect("a fingerprint");
        std::fs::write(root.path().join("lib/untracked.txt"), "x").unwrap();
        std::fs::write(proj.join("untracked.nix"), "{ }").unwrap();
        assert_eq!(backend.source_fingerprint(&proj), Some(before));
    }

    /// A flake in a plain folder reads every file in it, whatever its name.
    #[test]
    fn a_changed_file_in_a_plain_folder_is_evaluated_again() {
        let (root, cache_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let flake = flake_reading_a_file(root.path(), false);
        assert_eq!(list_cached(&flake, cache_dir.path()), ["one"]);
        std::fs::write(flake.join("name.txt"), "two").unwrap();
        assert_eq!(list_cached(&flake, cache_dir.path()), ["two"]);
        std::fs::write(flake.join("run.sh"), "true").unwrap();
        let mut backend = LocalBuilder::new();
        let before = backend.source_fingerprint(&flake).expect("a fingerprint");
        std::fs::write(flake.join("run.sh"), "false").unwrap();
        assert_ne!(backend.source_fingerprint(&flake), Some(before));
    }

    /// An evaluation with an overridden input reads the override, and
    /// neither returns a cached result nor leaves one.
    #[test]
    fn an_overridden_input_never_uses_the_cache() {
        let (root, cache_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let proj = flake_reading_a_file(root.path(), true);
        let other = tempfile::tempdir().unwrap();
        std::fs::copy(
            root.path().join("lib/flake.nix"),
            other.path().join("flake.nix"),
        )
        .unwrap();
        std::fs::write(other.path().join("name.txt"), "two").unwrap();
        let overridden = || {
            let overrides = vec![("lib".into(), format!("path:{}", other.path().display()))];
            crate::eval::KixEvaluator::new(
                LocalBuilder::with_overrides(overrides),
                &proj,
                cache_dir.path(),
            )
            .unwrap()
            .list_clusters()
            .unwrap()
        };

        assert_eq!(list_cached(&proj, cache_dir.path()), ["one"]);
        assert_eq!(overridden(), ["two"]);
        std::fs::write(other.path().join("name.txt"), "three").unwrap();
        assert_eq!(overridden(), ["three"]);
        assert_eq!(list_cached(&proj, cache_dir.path()), ["one"]);
    }
}
