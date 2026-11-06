//! Nix evaluation layer for Kix.
//!
//! Provides store management, expression evaluation, flake attribute
//! navigation, eval caching, and error translation. All Nix complexity
//! is contained here; consumers get `serde_json::Value` results.
//!
//! # Backend selection
//!
//! The `NixBackend` trait in `evaluator` abstracts over Nix evaluation.
//! Two implementations exist:
//!
//! - [`cli_backend::CliNixBackend`] shells out to `nix` CLI commands.
//!   Default backend for production use. Benefits from Nix's built-in
//!   eval cache for fast repeated invocations.
//!
//! - `mock::MockNixBackend` returns canned data, for this crate's tests
//!   without a Nix installation.

pub mod build_files;
pub(crate) mod cache;
pub mod cli_backend;
pub mod derivation;
pub mod error;
pub(crate) mod evaluator;
pub mod helm;
pub mod helm_yaml;
pub mod manifest_json;
#[cfg(test)]
mod mock;
pub mod nix;
pub mod package_index;
pub mod stamp;
pub mod store;
pub mod store_graph;
pub mod store_path;

pub use cli_backend::{CliNixBackend, cluster_name_command, eval_cluster_name};
pub(crate) use error::KixEvalError;
pub use evaluator::{
    ClusterOutput, ClusterPackageInfo, InstanceInfo, KixEvaluator, NixBackend, PackageInfo,
};
pub(crate) use store_graph::PackageNode;
