#![deny(clippy::print_stdout, clippy::print_stderr)]

//! kix — Nix-based Kubernetes manifest generator library.
//!
//! Three module groups:
//!
//! - [`eval`] — Nix FFI, store graph, eval caching, error translation
//! - [`manifest`] — K8s types, structural diff, annotation stamping, validation
//! - [`cluster`] — apply, fetch, DAG, waves, readiness, activation lifecycle, reconcile
//!
//! Two smaller modules sit beside them: [`pins`], the committed record of what
//! each image reference resolved to, and [`registry`], the one place Kix asks
//! a container registry a question.

pub mod cluster;
pub mod eval;
pub mod legacy_domain;
pub mod manifest;
pub mod pins;
pub mod registry;
