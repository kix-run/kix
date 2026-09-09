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
