#![deny(clippy::print_stdout, clippy::print_stderr)]

//! The parts of Kix that need no Kubernetes client: evaluating a project with
//! Nix, reading its configuration, and handling the manifests it renders.
//!
//! - [`eval`]: Nix evaluation, store graphs, caching, and error translation
//! - [`manifest`]: Kubernetes manifest types, keys, lifecycles, and diffs
//! - [`build_source`]: loads and validates builds from the local Nix store or
//!   a carried bundle
//!
//! [`project`] reads a project's `kix.toml`, [`flake_lock`] reads which Kix
//! a project uses, [`pin_library`] pins its Kix library to a release,
//! [`runtime`] finds the external programs Kix runs,
//! [`system_nix`] checks the machine's Nix for the `nix` builder,
//! [`legacy_domain`] reads objects stamped under Kix's retired API domains,
//! [`text`] sanitizes untrusted text for terminal output, [`yaml`] reads and
//! writes YAML, [`version`] parses Kix versions and holds the rule for
//! which versions work together, and [`changes`] reads the change records a
//! release publishes.
//!
//! `kix-lib` builds the cluster, plan, and release code on top of this crate
//! and re-exports every module here under the same path.

pub mod build_source;
pub mod changes;
pub mod eval;
pub mod flake_lock;
pub mod legacy_domain;
pub mod manifest;
pub mod pin_library;
pub mod project;
pub mod runtime;
pub mod system_nix;
pub mod text;
pub mod version;
pub mod versions;
pub mod yaml;

/// The version of the running Kix as the build recorded it. Code reads it
/// parsed, through [`version::running`]. It stays a constant because clap's
/// `version` attribute needs one.
pub const VERSION: &str = match option_env!("KIX_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};
