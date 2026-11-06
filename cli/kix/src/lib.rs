#![deny(clippy::print_stdout, clippy::print_stderr)]

//! Nix-based Kubernetes manifest generation and deployment.
//!
//! Three module groups:
//!
//! - [`eval`]: Nix evaluation, store graphs, caching, and error translation
//! - [`manifest`]: Kubernetes types, diffs, annotation stamping, and validation
//! - [`cluster`]: apply, fetch, DAG, readiness, activation lifecycle, and reconcile
//!
//! [`plan`] sits on top of them. It computes what deploying a build would
//! change, renders the plan document printed by `kix plan` and `kix diff`, and
//! verifies that a deploy applies only the objects shown in its plan.
//!
//! Five smaller modules sit beside them: [`build_source`] loads and validates
//! builds from the local Nix store or a carried bundle, [`pins`] manages the
//! committed record of resolved image digests, [`registry`] resolves image
//! references against container registries, [`runtime`] finds the external
//! programs Kix runs, and [`text`] sanitizes untrusted text for terminal
//! output.

pub mod build_source;
pub mod cluster;
pub mod eval;
pub mod legacy_domain;
pub mod library;
pub mod manifest;
pub mod pins;
pub mod plan;
pub mod registry;
pub mod runtime;
pub mod text;

/// The Kix version. A release build sets `KIX_VERSION` at compile time to
/// the crate version with the CI run number as semver build metadata
/// (`0.1.0+250`), so two released binaries with the same crate version
/// still report different versions. Any other build reports the crate
/// version.
pub const VERSION: &str = match option_env!("KIX_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};
