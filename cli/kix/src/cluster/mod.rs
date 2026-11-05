//! Kubernetes fetching, deployment, status, and graph operations.

pub mod activation;
pub mod apply;
pub mod cancel;
pub mod client;
pub mod deploy_log;
pub mod discovery;
pub mod drift;
pub mod errors;
#[cfg(any(test, feature = "test-util"))]
pub mod fake_api;
pub mod fieldsv1;
pub mod graph;
pub mod inventory;
pub mod kept;
pub mod migrate;
pub(crate) mod ops;
pub mod owned_view;
pub mod preview;
pub mod prune_guard;
pub mod readiness;
pub mod scheduler;
/// Scripted test fakes for the deploy engine's external interfaces.
#[cfg(any(test, feature = "test-util"))]
pub use ops::scripted;
pub(crate) mod secrets;
pub mod stream;
pub mod tenancy;
pub mod topology;
pub mod watchdog;
