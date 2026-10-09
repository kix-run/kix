//! The cluster connection every command makes. The transport policy comes
//! from the `KIX_*` environment variables, read here and nowhere else in
//! the CLI.

use kix::cluster::client::ResiliencePolicy;
use kix::cluster::errors::FetchError;
use kube::Client;

/// The transport policy the environment sets.
pub fn policy() -> ResiliencePolicy {
    ResiliencePolicy::from_env()
}

/// Connect through the kube context `context` (`None` for the current one)
/// with [`policy`].
pub async fn make_client(context: Option<&str>) -> Result<Client, FetchError> {
    kix::cluster::client::make_client(context, policy()).await
}
