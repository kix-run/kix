pub mod build;
pub mod check;
pub mod completions;
pub mod deploy;
pub mod diff;
pub mod graph;
pub mod inspect;
pub mod list;
pub mod snapshot;
pub mod status;

use std::path::PathBuf;

use miette::IntoDiagnostic;

use crate::cli::{GlobalArgs, OutputFormat};

pub struct CommandContext {
    pub evaluator: kix_eval::eval::KixEvaluator,
    pub global: GlobalArgs,
    pub runtime: tokio::runtime::Runtime,
}

impl CommandContext {
    pub fn new(global: &GlobalArgs) -> miette::Result<Self> {
        let evaluator = create_evaluator(&global.flake)?;
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
}

/// Resolve a flake reference to a path for evaluation.
///
/// For local paths (relative or absolute), resolves to an absolute path.
/// For remote references (e.g. "github:org/repo"), passes through as-is.
fn resolve_flake_path(flake: &str) -> miette::Result<PathBuf> {
    // Remote flake references contain ":" (e.g. github:, git+https:, path:)
    // For now, treat everything without ":" as a local path
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

/// Create a KixEvaluator using the mock backend.
///
/// This will be replaced with a real FFI backend in Step 9.
/// For now, it provides demo clusters for testing the CLI flow.
fn create_evaluator(flake: &str) -> miette::Result<kix_eval::eval::KixEvaluator> {
    let mut backend = kix_eval::mock::MockNixBackend::new();

    // Register demo clusters so the CLI is exercisable
    backend.add_cluster(
        "example",
        vec![
            serde_json::json!({
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": { "name": "example" }
            }),
            serde_json::json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": { "name": "app-config", "namespace": "example" },
                "data": { "key": "value" }
            }),
        ],
    );
    backend.add_cluster(
        "nw1",
        vec![serde_json::json!({
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": { "name": "nw1" }
        })],
    );

    let flake_path = resolve_flake_path(flake)?;
    let cache_dir = kix_eval::store::default_cache_dir();
    kix_eval::eval::KixEvaluator::new(backend, &flake_path, &cache_dir).into_diagnostic()
}
