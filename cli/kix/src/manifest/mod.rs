//! The manifest modules of `kix-core`, plus the functions that read live
//! objects as the Kubernetes client returns them.

pub use kix_core::manifest::*;

pub mod lifecycle;
pub mod types;
