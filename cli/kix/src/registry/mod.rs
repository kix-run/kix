//! Resolve container image references for `kix pin`.
//!
//! Resolution occurs when updating a committed pin file. Deploy reads that
//! file and does not resolve tags through the registry.

pub mod client;
pub mod credentials;
pub mod reference;

pub use client::{RegistryClient, RegistryError, Resolved};
pub use credentials::CredentialSource;
pub use reference::{Reference, is_sha256_digest};
