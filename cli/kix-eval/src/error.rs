//! Error types for kix-eval.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum KixEvalError {
    #[error("failed to initialize evaluator")]
    InitFailed {
        #[source]
        source: anyhow::Error,
    },

    #[error("failed to open store at '{path}'")]
    StoreOpenFailed {
        path: String,
        #[source]
        source: anyhow::Error,
    },

    #[error("failed to evaluate cluster attribute '{attr}' in '{flake}'")]
    EvalFailed {
        flake: String,
        attr: String,
        #[source]
        source: anyhow::Error,
    },

    #[error("cluster '{name}' not found")]
    ClusterNotFound { name: String },

    #[error("evaluation error in {file}:{line}")]
    NixError {
        file: String,
        line: u32,
        message: String,
        suggestion: Option<String>,
    },

    #[error("eval cache error")]
    CacheError {
        #[source]
        source: anyhow::Error,
    },

    #[error("store graph error: {message}")]
    StoreGraphError { message: String },
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

    pub fn not_found(name: impl Into<String>) -> Self {
        Self::ClusterNotFound { name: name.into() }
    }
}
