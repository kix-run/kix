//! Talking to a container registry.
//!
//! This exists for one command, `kix pin`, and one question: what digest does
//! this image reference resolve to? Kix asks that at promotion time, writes
//! the answer into a committed pin file, and never asks again. Resolving a
//! tag during a deploy is a non-goal (`v2_discussions/120` §3.9): a value
//! obtained by a network call at apply time cannot be reviewed before it is
//! applied, and a `digest: null` that tells the truth is worth more.

pub mod client;
pub mod credentials;
pub mod reference;

pub use client::{RegistryClient, RegistryError, Resolved};
pub use credentials::CredentialSource;
pub use reference::{Reference, is_sha256_digest};
