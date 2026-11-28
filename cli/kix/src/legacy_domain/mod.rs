//! The retired API domain layer of `kix-core`, plus the parts that talk to
//! the API server: the discovery check and the `kix migrate domain` migration.

use kube::discovery::{ApiResource, Scope};

pub use kix_core::legacy_domain::*;

pub(crate) mod kube_ops;
pub mod migrate;

pub use kube_ops::KubeMigrationOps;

/// Check whether API discovery shows Kix records under a retired group.
///
/// [`crate::cluster::activation::Records::open`] runs this check before
/// reading or writing records, and read-only commands such as `kix diff` and
/// `kix plan` call it directly.
pub fn check_discovery(discovery: &[(ApiResource, Scope)]) -> Result<(), LegacyDomainError> {
    let groups: Vec<&str> = discovery
        .iter()
        // Records under any group, so that one under a retired group is found.
        .filter(|(ar, _)| ar.kind == crate::manifest::lifecycle::RECORD_KIND)
        .map(|(ar, _)| ar.group.as_str())
        .collect();
    check_cluster(&groups)
}
