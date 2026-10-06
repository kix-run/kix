pub mod baseline;
pub mod build;
pub mod bundle;
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
pub mod plan;
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
    /// (see [`kix::eval::eval_cluster_name`]). Reading that name evaluates
    /// most of the cluster, needs the flake's inputs, and fails when the
    /// flake does not evaluate, so it is the last resort:
    ///
    /// 1. With no flake (no `flake.nix` in a local `--flake` directory),
    ///    `arg` is the name.
    /// 2. When records in the current context carry `arg` as their cluster
    ///    label, `arg` is the name.
    /// 3. Otherwise the name is evaluated. A flake that does not define
    ///    `arg`, or has no `kixClusters`, leaves `arg` as the name.
    ///
    /// When the evaluation fails, [`Lookup::Mutating`] is an error naming the
    /// attribute and the failure, and [`Lookup::ReadOnly`] warns and uses
    /// `arg`. A command that builds the cluster reads the name from the
    /// build, `StoreGraph::cluster_name`, instead.
    pub fn cluster_identity(&self, arg: &str, lookup: Lookup) -> miette::Result<String> {
        let flake_path = match resolve_flake_path(&self.global.flake) {
            Ok(p) => p,
            Err(_) => return Ok(arg.to_string()),
        };
        // A local directory without a flake has nothing to evaluate, and
        // `nix eval` there would only print an error.
        if !self.global.flake.contains(':') && !flake_path.join("flake.nix").exists() {
            return Ok(arg.to_string());
        }
        let context = self.global.context.clone();
        let has_records = self.runtime.block_on(async {
            let client = kix::cluster::fetch::make_client(context.as_deref())
                .await
                .ok()?;
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

/// Whether a command that looks up a cluster's records changes the cluster.
/// See [`CommandContext::cluster_identity`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lookup {
    /// Reads state only (health, status, attest): a wrong name finds nothing.
    ReadOnly,
    /// Deletes or reverts (rollback, gc): a wrong name must not be guessed.
    Mutating,
}

/// Steps 2 and 3 of [`CommandContext::cluster_identity`]: `arg` when records
/// carry it, else the evaluated name.
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

    fn eval_error() -> kix::eval::error::KixEvalError {
        kix::eval::error::KixEvalError::StoreGraphError {
            message: "error: cannot fetch input 'nixpkgs'".into(),
        }
    }

    /// Records that carry the argument settle the name without evaluating.
    #[test]
    fn records_under_the_argument_skip_the_evaluation() {
        let name = resolve_identity("harbor", true, Lookup::Mutating, || {
            panic!("evaluated although records carry the argument")
        });
        assert_eq!(name.unwrap(), "harbor");
    }

    /// Without records the evaluated name is used, and a flake that does not
    /// define the attribute leaves the argument.
    #[test]
    fn without_records_the_name_is_evaluated() {
        let name = resolve_identity("harbor", false, Lookup::Mutating, || {
            Ok(Some("test-harbor".into()))
        });
        assert_eq!(name.unwrap(), "test-harbor");
        let name = resolve_identity("harbor", false, Lookup::Mutating, || Ok(None));
        assert_eq!(name.unwrap(), "harbor");
    }

    /// A failed evaluation is an error naming the attribute and the failure
    /// for a command that changes the cluster, and the argument otherwise.
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

    /// Without a flake there is nothing to resolve, and no `nix` runs.
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
