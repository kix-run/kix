//! Nix evaluation layer for Kix.
//!
//! Provides store management, expression evaluation, flake attribute
//! navigation, eval caching, and error translation. All Nix complexity
//! is contained here; consumers get `serde_json::Value` results.
//!
//! # Builders
//!
//! The `Builder` trait in `evaluator` abstracts over Nix evaluation.
//! Two implementations exist:
//!
//! - [`cli_backend::LocalBuilder`] shells out to `nix` CLI commands on this
//!   machine. The production builder. Benefits from Nix's built-in
//!   eval cache for fast repeated invocations.
//!
//! - `mock::MockBuilder` returns canned data, for this crate's tests
//!   without a Nix installation.

pub mod build_files;
pub(crate) mod cache;
pub mod cli_backend;
pub mod derivation;
pub mod error;
pub(crate) mod evaluator;
#[cfg(any(test, feature = "test-util"))]
pub mod fixtures;
pub mod helm;
pub mod helm_yaml;
pub mod library_error;
pub mod manifest_json;
#[cfg(test)]
mod mock;
pub mod nix;
pub mod package_index;
pub mod stamp;
pub mod store;
pub mod store_graph;
pub mod store_path;

pub use cli_backend::{LocalBuilder, cluster_name_command, eval_cluster_name};
pub use error::KixEvalError;
pub use evaluator::{
    Builder, ClusterOutput, ClusterPackageInfo, InstanceInfo, KixEvaluator, PackageInfo,
};
pub use store_graph::PackageNode;
