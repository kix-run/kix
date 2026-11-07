pub mod build;
pub mod bundle;
pub mod check;
pub mod completions;
pub mod compliance;
pub mod deploy;
pub mod deploy_log;
pub mod diff;
pub mod doctor;
pub mod drift;
pub mod export;
pub mod gc;
pub mod graph;
pub mod graph_stream;
pub mod health;
pub mod images;
pub mod inspect;
pub mod library;
pub mod list;
pub mod logs;
pub mod migrate;
pub mod operator;
pub mod pf;
pub mod pin;
pub mod plan;
pub mod rollback;
pub mod snapshot;
pub mod status;
pub mod workload;

use std::path::PathBuf;

use kix::build_source::{Build, FlakeBuildError};
use miette::IntoDiagnostic;

use crate::cli::GlobalArgs;

/// Build the receipt that a deploy records on its Activation, and extract
/// pre-deploy warnings from it.
///
/// `kix bundle` also populates the bundle's `Provenance` from the receipt's
/// `source`, `inputs`, and `builder` fields.
pub trait ReceiptMaker {
    /// Build the receipt for a deploy of `build`, reading local source metadata
    /// from the flake at `flake_ref`.
    fn of_build(&self, build: &Build, flake_ref: &str) -> serde_json::Value;

    /// Return styled warning lines to print before confirming the deploy.
    fn warnings(&self, receipt: &serde_json::Value) -> Vec<String>;
}

pub struct CommandContext {
    pub evaluator: kix::eval::KixEvaluator,
    pub global: GlobalArgs,
    pub runtime: tokio::runtime::Runtime,
    pub receipts: &'static dyn ReceiptMaker,
}

impl CommandContext {
    pub fn new(global: &GlobalArgs, receipts: &'static dyn ReceiptMaker) -> miette::Result<Self> {
        let evaluator = create_evaluator(&global.flake, global.no_cache, global.input_overrides())?;
        let runtime = tokio::runtime::Runtime::new().into_diagnostic()?;
        Ok(Self {
            evaluator,
            global: global.clone(),
            runtime,
            receipts,
        })
    }

    /// Resolve the cluster name used to look up records on the Kubernetes
    /// cluster or in the local activation cache.
    ///
    /// `arg` is the flake attribute from the command line, whereas activation
    /// records and the cache are keyed by the cluster definition's own `name`
    /// (see [`kix::eval::eval_cluster_name`]). Evaluating that name requires
    /// fetching flake inputs and evaluating most of the cluster, so Kix avoids
    /// it when possible:
    ///
    /// 1. When `--flake` points to a local directory without `flake.nix`,
    ///    return `arg`.
    /// 2. When records in the current Kubernetes context already carry `arg` as
    ///    their cluster label, return `arg`.
    /// 3. Otherwise, evaluate the cluster name from the flake. If the flake
    ///    does not define `arg` or `kixClusters`, return `arg`.
    ///
    /// If evaluation fails, [`Lookup::Mutating`] returns an error and
    /// [`Lookup::ReadOnly`] prints a warning and falls back to `arg`. Commands
    /// that build the cluster read `StoreGraph::cluster_name` from the build
    /// instead.
    pub fn cluster_identity(&self, arg: &str, lookup: Lookup) -> miette::Result<String> {
        let flake_path = match resolve_flake_path(&self.global.flake) {
            Ok(p) => p,
            Err(_) => return Ok(arg.to_string()),
        };
        // A local directory without `flake.nix` has nothing to evaluate.
        if !self.global.flake.contains(':') && !flake_path.join("flake.nix").exists() {
            return Ok(arg.to_string());
        }
        let context = self.global.context.clone();
        let has_records = self.runtime.block_on(async {
            let client = crate::client::make_client(context.as_deref()).await.ok()?;
            kix::cluster::activation::records_exist(&client, arg)
                .await
                .ok()
        });
        resolve_identity(arg, has_records == Some(true), lookup, || {
            kix::eval::eval_cluster_name(
                &flake_path.to_string_lossy(),
                arg,
                &self.global.input_overrides(),
            )
        })
    }

    /// Evaluate a cluster, or return an error listing available clusters when `name` is not found.
    pub fn eval_cluster_or_suggest(
        &mut self,
        name: &str,
    ) -> miette::Result<kix::eval::ClusterOutput> {
        use miette::IntoDiagnostic;
        match self.evaluator.eval_cluster(name) {
            Ok(o) => Ok(o),
            Err(kix::eval::error::KixEvalError::ClusterNotFound { name }) => {
                let clusters = self.evaluator.list_clusters().unwrap_or_default();
                let mut msg = format!("cluster '{}' not found", name);
                if !clusters.is_empty() {
                    msg.push_str(&format!(". Available clusters: {}", clusters.join(", ")));
                }
                Err(miette::miette!("{}", msg))
            }
            Err(e) => Err(e).into_diagnostic(),
        }
    }
}

/// Whether a cluster-record lookup is read-only or mutates cluster state.
///
/// See [`CommandContext::cluster_identity`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lookup {
    /// The command only reads state (`health`, `status`, `attest`), so a
    /// fallback name is safe.
    ReadOnly,
    /// The command deletes or reverts cluster state (`rollback`, `gc`), so
    /// Kix must not guess the cluster name when evaluation fails.
    Mutating,
}

/// Apply steps 2 and 3 of [`CommandContext::cluster_identity`], returning `arg`
/// when existing records match it or evaluating the cluster name otherwise.
fn resolve_identity(
    arg: &str,
    has_records: bool,
    lookup: Lookup,
    eval: impl FnOnce() -> Result<Option<String>, kix::eval::error::KixEvalError>,
) -> miette::Result<String> {
    if has_records {
        return Ok(arg.to_string());
    }
    match eval() {
        Ok(Some(name)) => Ok(name),
        Ok(None) => Ok(arg.to_string()),
        Err(e) => match lookup {
            Lookup::Mutating => Err(miette::miette!(
                "no Activation record in this context carries cluster name '{arg}', and evaluating the name that flake attribute '{arg}' gives its cluster failed: {e}"
            )),
            Lookup::ReadOnly => {
                eprintln!(
                    "warning: could not evaluate the name of cluster '{arg}', so looking it up as '{arg}': {e}"
                );
                Ok(arg.to_string())
            }
        },
    }
}

/// Build `cluster` from `global.flake` into the local Nix store, reporting
/// progress lines to `status` and prefixing evaluation errors with `build_failed`.
pub(crate) fn build_flake(
    global: &GlobalArgs,
    cluster: &str,
    status: &dyn Fn(&str),
    build_failed: &str,
) -> miette::Result<Build> {
    let flake_path = resolve_flake_path(&global.flake)?;
    Build::of_flake(&flake_path, cluster, &global.input_overrides(), status).map_err(|e| match e {
        FlakeBuildError::Build(e) => miette::miette!("{build_failed}: {e}"),
        FlakeBuildError::Load(e) => miette::miette!("{e}"),
    })
}

/// Error prefix for commands whose evaluation step fails.
pub(crate) const BUILD_FAILED: &str = "failed to build cluster";
/// Error prefix for activation-oriented commands whose evaluation step fails.
pub(crate) const ACTIVATION_BUILD_FAILED: &str = "failed to build cluster activation";

/// Resolve a local flake path to an absolute path, or pass a remote flake URI through unchanged.
pub(crate) fn resolve_flake_path(flake: &str) -> miette::Result<PathBuf> {
    if flake.contains(':') {
        Ok(PathBuf::from(flake))
    } else {
        let path = PathBuf::from(flake);
        if path.is_absolute() {
            Ok(path)
        } else {
            let cwd = std::env::current_dir().into_diagnostic()?;
            Ok(cwd.join(path))
        }
    }
}

/// Return the local project directory `flake` names, or `None` for a remote
/// flake reference.
pub(crate) fn project_dir(flake: &str) -> Option<PathBuf> {
    if flake.contains(':') {
        return None;
    }
    resolve_flake_path(flake).ok()
}

/// Read the project's `kix.toml` and choose the Nix runner its builder
/// needs. Call it before Kix runs any Nix program.
pub(crate) fn select_builder(global: &GlobalArgs) -> miette::Result<()> {
    let config = kix::project::ProjectConfig::load(project_dir(&global.flake).as_deref())
        .map_err(|e| miette::miette!("{e}"))?;
    kix::runtime::select_builder(config.builder).map_err(|e| miette::miette!("{e}"))?;
    Ok(())
}

fn create_evaluator(
    flake: &str,
    no_cache: bool,
    input_overrides: Vec<(String, String)>,
) -> miette::Result<kix::eval::KixEvaluator> {
    let backend = kix::eval::LocalBuilder::with_overrides(input_overrides);
    let flake_path = resolve_flake_path(flake)?;

    if no_cache {
        kix::eval::KixEvaluator::new_uncached(backend, &flake_path).into_diagnostic()
    } else {
        let cache_dir = kix::eval::store::default_cache_dir();
        kix::eval::KixEvaluator::new(backend, &flake_path, &cache_dir).into_diagnostic()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    fn context(flake: &str) -> CommandContext {
        let cli = crate::cli::Cli::try_parse_from(["kix", "--flake", flake, "health", "x"])
            .expect("arguments parse");
        CommandContext::new(&cli.global, &compliance::receipt::ComplianceReceipts).expect("context")
    }

    fn eval_error() -> kix::eval::error::KixEvalError {
        kix::eval::error::KixEvalError::StoreGraphError {
            message: "error: cannot fetch input 'nixpkgs'".into(),
        }
    }

    /// Verify that existing records matching the argument skip flake evaluation.
    #[test]
    fn records_under_the_argument_skip_the_evaluation() {
        let name = resolve_identity("harbor", true, Lookup::Mutating, || {
            panic!("evaluated although records carry the argument")
        });
        assert_eq!(name.unwrap(), "harbor");
    }

    /// Verify that without matching records, Kix evaluates the cluster name or
    /// falls back to the argument when the flake does not define the attribute.
    #[test]
    fn without_records_the_name_is_evaluated() {
        let name = resolve_identity("harbor", false, Lookup::Mutating, || {
            Ok(Some("test-harbor".into()))
        });
        assert_eq!(name.unwrap(), "test-harbor");
        let name = resolve_identity("harbor", false, Lookup::Mutating, || Ok(None));
        assert_eq!(name.unwrap(), "harbor");
    }

    /// Verify that a failed evaluation errors on a mutating lookup and falls
    /// back to the argument on a read-only lookup.
    #[test]
    fn a_failed_evaluation_refuses_a_mutating_lookup() {
        let err = resolve_identity("harbor", false, Lookup::Mutating, || Err(eval_error()))
            .unwrap_err()
            .to_string();
        assert!(err.contains("'harbor'"), "{err}");
        assert!(err.contains("cannot fetch input"), "{err}");
        let name = resolve_identity("harbor", false, Lookup::ReadOnly, || Err(eval_error()));
        assert_eq!(name.unwrap(), "harbor");
    }

    /// Verify that a local directory without `flake.nix` returns the argument
    /// without invoking `nix`.
    #[test]
    fn without_a_flake_the_argument_is_the_name() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            context(&dir.path().display().to_string())
                .cluster_identity("harbor", Lookup::Mutating)
                .unwrap(),
            "harbor"
        );
    }
}
