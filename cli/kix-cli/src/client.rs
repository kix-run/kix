//! Shared Kubernetes client constructor for CLI commands.
//!
//! Transport resilience settings are read from `KIX_*` environment variables
//! here so every command uses the same client policy.

use kix::cluster::client::ResiliencePolicy;
use kix::cluster::errors::FetchError;
use kube::Client;

/// Return the transport resilience policy configured via environment variables.
pub fn policy() -> ResiliencePolicy {
    ResiliencePolicy::from_env()
}

/// Connect to the cluster using `context` (or the current kubeconfig context
/// if `None`) and [`policy`].
pub async fn make_client(context: Option<&str>) -> Result<Client, FetchError> {
    kix::cluster::client::make_client(context, policy()).await
}
