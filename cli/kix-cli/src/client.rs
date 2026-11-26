//! Shared Kubernetes client constructor for CLI commands.
//!
//! Transport resilience settings are read from `KIX_*` environment variables
//! here so every command uses the same client policy.

use kix::cluster::binding::Connection;
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

/// Say which Kubernetes cluster `context` names, then connect to it as
/// [`make_client`] does. Commands that change a cluster call this, so the
/// reader sees where the change goes before it starts.
pub async fn connect(context: Option<&str>) -> Result<(Client, Connection), FetchError> {
    let connection = Connection::of_context(context);
    crate::say!("{}", connection.connecting());
    Ok((make_client(context).await?, connection))
}
