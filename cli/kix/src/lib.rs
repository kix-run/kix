#![deny(clippy::print_stdout, clippy::print_stderr)]

//! Nix-based Kubernetes manifest generation and deployment.
//!
//! Three module groups:
//!
//! - [`eval`]: Nix evaluation, store graphs, caching, and error translation
//! - [`manifest`]: Kubernetes types, diffs, annotation stamping, and validation
//! - [`cluster`]: apply, fetch, DAG, readiness, activation lifecycle, and reconcile
//!
//! Three smaller modules sit beside them: [`pins`], the committed record of
//! what each image reference resolved to, [`registry`], the one place Kix asks
//! a container registry a question, and [`text`], for printing text kix did
//! not write.

pub mod cluster;
pub mod eval;
pub mod legacy_domain;
pub mod manifest;
pub mod pins;
pub mod registry;
pub mod text;
