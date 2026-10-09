//! K8s manifest types, YAML serialization and structural diff.

pub mod diff;
pub mod hash;
pub mod keys;
pub mod lifecycle;
pub mod serialize;
pub mod types;
pub mod workload;

pub use types::CLUSTER_SCOPED;
pub use types::ResourceId;
