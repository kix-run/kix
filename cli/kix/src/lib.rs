#![deny(clippy::print_stdout, clippy::print_stderr)]

//! Kubernetes operations for Kix: deploying, planning, and installing
//! releases. Everything that needs no Kubernetes client lives in `kix-core`,
//! and this crate re-exports each of its modules under the same path, so
//! `kix::eval` and `kix_core::eval` name the same module.
//!
//! - [`cluster`]: apply, fetch, DAG, readiness, activation lifecycle, and reconcile
//! - [`plan`]: computes what deploying a build would change, renders the plan
//!   document printed by `kix plan` and `kix diff`, and verifies that a
//!   deploy applies only the objects shown in its plan
//!
//! [`pins`] manages the committed record of resolved image digests,
//! [`registry`] resolves image references against container registries,
//! [`installs`] lists the versions of Kix installed under the data
//! directory, and [`release`] fetches, verifies, and installs new ones.
//!
//! [`manifest`] and [`legacy_domain`] add the functions that take Kubernetes
//! client types to the `kix-core` modules of the same name.

pub use kix_core::{
    VERSION, build_source, changes, eval, flake_lock, library, pin_library, project, runtime,
    system_nix, text, version, yaml,
};

pub mod cluster;
pub mod installs;
pub mod legacy_domain;
pub mod manifest;
pub mod pins;
pub mod plan;
pub mod registry;
pub mod release;
