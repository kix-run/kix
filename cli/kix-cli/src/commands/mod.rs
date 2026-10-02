pub mod baseline;
pub mod build;
pub mod check;
pub mod completions;
pub mod compliance;
pub mod deploy;
pub mod deploy_log;
pub mod diff;
pub mod drift;
pub mod export;
pub mod gc;
pub mod graph;
pub mod graph_stream;
pub mod health;
pub mod images;
pub mod inspect;
pub mod list;
pub mod logs;
pub mod migrate;
pub mod operator;
pub mod pf;
pub mod pin;
pub mod rollback;
pub mod shared_orphans;
pub mod snapshot;
pub mod status;
pub mod workload;

use std::path::PathBuf;

use miette::IntoDiagnostic;

use crate::cli::{GlobalArgs, OutputFormat};

pub struct CommandContext {
    pub evaluator: kix::eval::KixEvaluator,
    pub global: GlobalArgs,
    pub runtime: tokio::runtime::Runtime,
}

impl CommandContext {
    pub fn new(global: &GlobalArgs) -> miette::Result<Self> {
        let evaluator = create_evaluator(&global.flake, global.no_cache, global.input_overrides())?;
        let runtime = tokio::runtime::Runtime::new().into_diagnostic()?;
        Ok(Self {
            evaluator,
            global: global.clone(),
            runtime,
        })
    }

    pub fn output_format(&self, default: OutputFormat) -> OutputFormat {
        self.global.output.unwrap_or(default)
    }

    /// The name that identifies the cluster `arg` names, for every lookup a
    /// command makes on the Kubernetes cluster or in the local activation
    /// cache.
    ///
    /// `arg` is the flake attribute the user typed. Activation records and
    /// the cache are keyed by the cluster definition's own `name` instead
    /// (see [`kix::eval::eval_cluster_name`]), so this evaluates that name.
    /// When the flake does not define `arg`, or there is no flake, `arg` is
    /// taken to be the cluster's name already, which keeps the commands that
    /// need no flake working. A command that builds the cluster reads the
    /// name from the build, `StoreGraph::cluster_name`, instead.
    pub fn cluster_identity(&self, arg: &str) -> String {
        let flake_path = match resolve_flake_path(&self.global.flake) {
            Ok(p) => p,
            Err(_) => return arg.to_string(),
        };
        // A local directory without a flake has nothing to evaluate, and
        // `nix eval` there would only print an error.
        if !self.global.flake.contains(':') && !flake_path.join("flake.nix").exists() {
            return arg.to_string();
        }
        match kix::eval::eval_cluster_name(&flake_path, arg, &self.global.input_overrides()) {
            Ok(Some(name)) => name,
            Ok(None) => arg.to_string(),
            Err(e) => {
                tracing::warn!(
                    "could not evaluate the name of cluster '{arg}', so looking it up as '{arg}': {e}"
                );
                arg.to_string()
            }
        }
    }

    /// Evaluate a cluster, returning a helpful error with available cluster names if not found.
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

/// Resolve a flake reference to a path for evaluation.
///
/// For local paths (relative or absolute), resolves to an absolute path.
/// For remote references (e.g. "github:org/repo"), passes through as-is.
fn resolve_flake_path(flake: &str) -> miette::Result<PathBuf> {
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

/// Create a KixEvaluator with the CLI subprocess backend.
fn create_evaluator(
    flake: &str,
    no_cache: bool,
    input_overrides: Vec<(String, String)>,
) -> miette::Result<kix::eval::KixEvaluator> {
    let backend = kix::eval::CliNixBackend::with_overrides(input_overrides);
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
        CommandContext::new(&cli.global).expect("context")
    }

    fn repo_root() -> String {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|p| p.parent())
            .expect("repo root");
        root.display().to_string()
    }

    /// The repository flake maps attribute `minimal` to
    /// `clusters/test-minimal.nix`, whose `name` is `test-minimal`. Records
    /// carry that name, so it is what the lookups get. Runs `nix eval`.
    #[test]
    fn a_flake_attribute_resolves_to_the_cluster_name() {
        assert_eq!(
            context(&repo_root()).cluster_identity("minimal"),
            "test-minimal"
        );
    }

    /// An argument the flake does not define is already a cluster name, as
    /// it is for a cluster deployed from another flake. Runs `nix eval`.
    #[test]
    fn a_name_the_flake_does_not_define_is_kept() {
        assert_eq!(
            context(&repo_root()).cluster_identity("test-minimal"),
            "test-minimal"
        );
    }

    /// Without a flake there is nothing to resolve, and no `nix` runs.
    #[test]
    fn without_a_flake_the_argument_is_the_name() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            context(&dir.path().display().to_string()).cluster_identity("harbor"),
            "harbor"
        );
    }
}
