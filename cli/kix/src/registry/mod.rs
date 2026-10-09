//! Resolve container image references for `kix pin`.
//!
//! Resolution occurs when updating a committed pin file. Deploy reads that
//! file and does not resolve tags through the registry.

pub(crate) mod client;
pub(crate) mod credentials;
pub(crate) mod reference;

pub use client::{RegistryClient, RegistryError, Resolved};
pub use reference::{Reference, is_sha256_digest};
