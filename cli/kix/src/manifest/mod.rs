//! K8s manifest types, YAML serialization and structural diff.

pub mod diff;
pub mod keys;
pub mod lifecycle;
pub mod serialize;
pub mod stamp;
pub mod types;
pub mod workload;

pub use types::CLUSTER_SCOPED;
pub use types::ResourceId;
