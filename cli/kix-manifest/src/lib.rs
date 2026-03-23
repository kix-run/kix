#![deny(clippy::print_stdout, clippy::print_stderr)]

//! K8s manifest types, YAML serialization, structural diff, and validation.

pub mod diff;
pub mod normalize;
pub mod serialize;
pub mod types;
pub mod validate;
