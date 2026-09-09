#![deny(clippy::print_stdout, clippy::print_stderr)]

//! kix — Nix-based Kubernetes manifest generator library.
//!
//! Three module groups:
//!
//! - [`eval`] — Nix FFI, store graph, eval caching, error translation
//! - [`manifest`] — K8s types, structural diff, annotation stamping, validation
//! - [`cluster`] — apply, fetch, DAG, waves, readiness, activation lifecycle, reconcile

pub mod cluster;
pub mod eval;
pub mod legacy_domain;
pub mod manifest;
