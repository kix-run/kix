//! Nix FFI wrapper for kix.
//!
//! Provides store management, expression evaluation, flake attribute
//! navigation, eval caching, and error translation. All Nix complexity
//! is contained here — consumers get `serde_json::Value` results.
//!
//! # Backend selection
//!
//! The `NixBackend` trait in [`eval`] abstracts over Nix evaluation.
//! Two implementations exist:
//!
//! - [`mock::MockNixBackend`] — returns canned data, always available,
//!   used for testing and development without a Nix installation.
//!
//! - `NixFfiBackend` (gated behind `#[cfg(feature = "nix-ffi")]`) —
//!   real FFI evaluation via `nix-bindings-*` crates.

pub mod build;
pub mod cache;
pub mod error;
pub mod evaluator;
pub mod mock;
pub mod store;
pub mod store_graph;
pub mod value;

pub use build::{build_cluster_activation, build_cluster_activation_with_status};
pub use error::KixEvalError;
pub use evaluator::{ClusterOutput, KixEvaluator, NixBackend};
pub use store_graph::{CrossDep, KixPackageIndex, PackageNode, ResourceNode, StoreGraph};

/// Real Nix FFI backend — available only when built with Nix C libraries.
#[cfg(feature = "nix-ffi")]
pub mod ffi;
