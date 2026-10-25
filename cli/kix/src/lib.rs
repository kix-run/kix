#![deny(clippy::print_stdout, clippy::print_stderr)]

//! Nix-based Kubernetes manifest generation and deployment.
//!
//! Three module groups:
//!
//! - [`eval`]: Nix evaluation, store graphs, caching, and error translation
//! - [`manifest`]: Kubernetes types, diffs, annotation stamping, and validation
//! - [`cluster`]: apply, fetch, DAG, readiness, activation lifecycle, and reconcile
//!
//! [`plan`] sits on top of them: what a deploy of a build would change, the
//! plan document `kix plan` and `kix diff` print, and the check that holds a
//! deploy to the objects its plan shows.
//!
//! Four smaller modules sit beside them: [`build_source`], the checked build
//! a command plans and deploys and where it came from, [`pins`], the committed record of
//! what each image reference resolved to, [`registry`], the one place Kix asks
//! a container registry a question, and [`text`], for printing text kix did
//! not write.

pub mod build_source;
pub mod cluster;
pub mod eval;
pub mod legacy_domain;
pub mod manifest;
pub mod pins;
pub mod plan;
pub mod registry;
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
