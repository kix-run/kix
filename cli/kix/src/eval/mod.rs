//! Nix evaluation layer for kix.
//!
//! Provides store management, expression evaluation, flake attribute
//! navigation, eval caching, and error translation. All Nix complexity
//! is contained here; consumers get `serde_json::Value` results.
//!
//! # Backend selection
//!
//! The `NixBackend` trait in [`evaluator`] abstracts over Nix evaluation.
//! Three implementations exist:
//!
//! - [`cli_backend::CliNixBackend`] shells out to `nix` CLI commands.
//!   Default backend for production use. Benefits from Nix's built-in
//!   eval cache for fast repeated invocations.
//!
//! - `mock::MockNixBackend` returns canned data, for this crate's tests
//!   without a Nix installation.
//!
//! - `FfiNixBackend`, gated behind `#[cfg(feature = "nix-ffi")]`, provides
//!   direct FFI evaluation via `nix-bindings-*` crates. It is experimental and
//!   not currently used by the CLI.

pub(crate) mod build;
pub mod bundle;
pub mod cache;
pub mod cli_backend;
pub mod error;
pub mod evaluator;
pub mod manifest_json;
#[cfg(test)]
mod mock;
pub mod stamp;
pub mod store;
pub mod store_graph;
pub mod store_path;
pub mod value;

pub use cli_backend::{CliNixBackend, cluster_name_command, eval_cluster_name};
pub use error::KixEvalError;
pub use evaluator::{
    ClusterOutput, ClusterPackageInfo, InstanceInfo, KixEvaluator, NixBackend, PackageInfo,
};
pub use store_graph::{CrossDep, KixPackageIndex, PackageNode, ResourceNode, StoreGraph};

/// Nix FFI backend available only when built with Nix C libraries.
/// Experimental: not currently used by the CLI.
#[cfg(feature = "nix-ffi")]
pub mod ffi;
