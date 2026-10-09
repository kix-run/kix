//! Error types for kix-eval.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum KixEvalError {
    #[error("could not initialize the Nix evaluator: {source}")]
    InitFailed {
        #[source]
        source: anyhow::Error,
    },

    #[error("could not open the Nix store at '{path}': {source}")]
    StoreOpenFailed {
        path: String,
        #[source]
        source: anyhow::Error,
    },

    #[error("could not evaluate cluster attribute '{attr}' in '{flake}': {source}")]
    EvalFailed {
        flake: String,
        attr: String,
        #[source]
        source: anyhow::Error,
    },

    #[error(
        "cluster '{name}' was not found. Run `kix list clusters` with the same flake to see available clusters"
    )]
    ClusterNotFound { name: String },

    #[error("Nix evaluation failed at {file}:{line}: {message}")]
    NixError {
        file: String,
        line: u32,
        message: String,
        suggestion: Option<String>,
    },

    #[error("could not access the Nix evaluation cache: {source}")]
    CacheError {
        #[source]
        source: anyhow::Error,
    },

    #[error("could not read the built resources and their dependencies: {message}")]
    StoreGraphError { message: String },

    /// A manifest of the build that the one parser refused.
    #[error("could not read the built resources and their dependencies: {0}")]
    NotJson(#[from] super::manifest_json::NotJson),
}

impl KixEvalError {
    pub fn init(source: impl Into<anyhow::Error>) -> Self {
        Self::InitFailed {
            source: source.into(),
        }
    }

    pub fn store(path: impl Into<String>, source: impl Into<anyhow::Error>) -> Self {
        Self::StoreOpenFailed {
            path: path.into(),
            source: source.into(),
        }
    }

    pub fn eval(
        flake: impl Into<String>,
        attr: impl Into<String>,
        source: impl Into<anyhow::Error>,
    ) -> Self {
        Self::EvalFailed {
            flake: flake.into(),
            attr: attr.into(),
            source: source.into(),
        }
    }

    pub(crate) fn not_found(name: impl Into<String>) -> Self {
        Self::ClusterNotFound { name: name.into() }
    }
}
