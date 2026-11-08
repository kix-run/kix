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
//! Eight smaller modules sit beside them: [`build_source`] loads and
//! validates builds from the local Nix store or a carried bundle, [`pins`]
//! manages the committed record of resolved image digests, [`project`] reads
//! a project's `kix.toml`, [`registry`] resolves image references against
//! container registries, [`runtime`] finds the external programs Kix runs,
//! [`system_nix`] checks the machine's Nix for the `nix` builder, [`text`]
//! sanitizes untrusted text for terminal output, and [`version`] parses Kix
//! versions and holds the rule for which versions work together.
//!
//! [`installs`] lists the versions of Kix installed under the data
//! directory, and [`release`] fetches, verifies, and installs new ones.

pub mod build_source;
pub mod cluster;
pub mod eval;
pub mod installs;
pub mod legacy_domain;
pub mod library;
pub mod manifest;
pub mod pins;
pub mod plan;
pub mod project;
pub mod registry;
pub mod release;
pub mod runtime;
pub mod system_nix;
pub mod text;
pub mod version;
pub mod yaml;

/// The version of the running Kix as the build recorded it. Code reads it
/// parsed, through [`version::running`]. It stays a constant because clap's
/// `version` attribute needs one.
pub const VERSION: &str = match option_env!("KIX_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};
