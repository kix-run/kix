//! Kubernetes fetching, deployment, status, and graph operations.

pub mod activation;
pub mod apply;
pub mod binding;
pub mod cancel;
pub mod classify;
pub mod client;
pub mod deploy_log;
pub mod discovery;
pub mod drift;
pub mod edges;
pub mod errors;
#[cfg(any(test, feature = "test-util"))]
pub mod fake_api;
pub mod field_manager;
pub mod fieldsv1;
pub mod graph;
pub mod head;
pub mod inventory;
pub mod kept;
pub mod kubernetes_version;
pub mod left_behind;
pub mod migrate;
pub mod migration_write;
pub mod observe;
pub(crate) mod ops;
pub mod own_crds;
pub mod owned_view;
pub mod preview;
pub mod prune_guard;
pub mod readiness;
pub mod revision;
pub mod scheduler;
pub mod snapshot;
/// Scripted test fakes for the deploy engine's external interfaces.
#[cfg(any(test, feature = "test-util"))]
pub use ops::scripted;
pub(crate) mod secrets;
#[cfg(test)]
mod state_fixtures;
pub mod stops;
pub mod stream;
pub mod tenancy;
#[cfg(any(test, feature = "test-util"))]
pub mod tenancy_fixture;
#[cfg(test)]
mod test_fixtures;
pub mod topology;
pub mod watchdog;

/// Convert a Kubernetes timestamp to the `chrono` type the rest of Kix uses.
///
/// Return `None` for a time that `chrono` cannot hold.
pub fn chrono_time(
    time: &k8s_openapi::apimachinery::pkg::apis::meta::v1::Time,
) -> Option<chrono::DateTime<chrono::Utc>> {
    let nanos = time.0.as_nanosecond();
    let seconds = i64::try_from(nanos.div_euclid(1_000_000_000)).ok()?;
    let subsec = u32::try_from(nanos.rem_euclid(1_000_000_000)).ok()?;
    chrono::DateTime::from_timestamp(seconds, subsec)
}
