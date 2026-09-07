//! K8s manifest types, YAML serialization, structural diff, and validation.

pub mod diff;
pub mod lifecycle;
pub mod serialize;
pub mod stamp;
pub mod types;
pub mod validate;

pub use types::CLUSTER_SCOPED;
pub use types::ResourceId;
