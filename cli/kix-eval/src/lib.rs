#![deny(clippy::print_stdout, clippy::print_stderr)]

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
//!   real FFI evaluation via `nix-bindings-*` crates. This requires
//!   linking against Nix C libraries (nix-expr-c, nix-store-c,
//!   nix-util-c, nix-flake-c) which are provided by the Nix flake
//!   packaging (see `cli/flake-integration.nix`).
//!
//! The `ffi` module is only compiled when the `nix-ffi` feature flag is
//! enabled; the `mock` module is always available and provides
//! `MockNixBackend` for unit and integration tests. The binary crate
//! (`kix-cli`) always enables `nix-ffi`, so production builds use the
//! real FFI backend.
//!
//! To switch from mock to real FFI in production:
//!
//! ```rust,ignore
//! #[cfg(feature = "nix-ffi")]
//! let backend = kix_eval::ffi::NixFfiBackend::new(store_uri)?;
//!
//! #[cfg(not(feature = "nix-ffi"))]
//! let backend = kix_eval::mock::MockNixBackend::new();
//!
//! let evaluator = KixEvaluator::new(backend, flake_path, cache_dir)?;
//! ```

pub mod cache;
pub mod error;
pub mod eval;
// TODO: Gate behind `#[cfg(any(test, feature = "test-util"))]` once the real
// NixFfiBackend exists and non-test code no longer needs the mock fallback.
pub mod mock;
pub mod store;
pub mod value;

pub use error::KixEvalError;
pub use eval::KixEvaluator;

/// Real Nix FFI backend — available only when built with Nix C libraries.
///
/// This module will contain `NixFfiBackend` implementing `NixBackend` via:
///
/// 1. Initialize Nix: `settings::set("experimental-features", "flakes")`
/// 2. GC registration: `eval_state::init()` + `gc_register_my_thread()`
/// 3. Open store: `Store::open(store_uri, [])`
/// 4. Build EvalState: `EvalStateBuilder::new(store).flakes(&flake_settings).build()`
/// 5. Parse flake ref: `FlakeReference::parse_with_fragment(..., "path:.#cluster-{name}")`
/// 6. Lock + eval: `LockedFlake::lock(...)` → `.outputs(...)` → navigate attrs
/// 7. Convert Nix Values to `serde_json::Value` via `builtins.toJSON` or manual walk
///
/// The store path defaults to `~/.cache/kix/store` (not `/nix/store`),
/// allowing operation without root privileges or the Nix daemon.
///
/// Threading: EvalState is NOT thread-safe. All evaluation runs on a single
/// dedicated thread with Boehm GC registration via RAII guard.
#[cfg(feature = "nix-ffi")]
pub mod ffi;
// When nix-ffi feature is enabled, add to Cargo.toml:
//
// [features]
// nix-ffi = [
//   "dep:nix-bindings-expr",
//   "dep:nix-bindings-store",
//   "dep:nix-bindings-flake",
//   "dep:nix-bindings-util",
//   "dep:nix-bindings-fetchers",
// ]
//
// [dependencies]
// nix-bindings-expr = { git = "https://github.com/cachix/nix-bindings-rust", branch = "for-upstream", optional = true }
// nix-bindings-store = { git = "https://github.com/cachix/nix-bindings-rust", branch = "for-upstream", optional = true }
// nix-bindings-flake = { git = "https://github.com/cachix/nix-bindings-rust", branch = "for-upstream", optional = true }
// nix-bindings-util = { git = "https://github.com/cachix/nix-bindings-rust", branch = "for-upstream", optional = true }
// nix-bindings-fetchers = { git = "https://github.com/cachix/nix-bindings-rust", branch = "for-upstream", optional = true }
