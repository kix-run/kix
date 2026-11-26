//! The one place a lock holder's writes pass through.
//!
//! [`guarded`] wraps a `kube::Client` in a service that refuses every write
//! once the holder's lease is lost or its deadline passed. Every component
//! of a run (the engine's objects and record, the prune guard, gc, and the
//! domain migration) writes through the client it was given, so a run that
//! takes the lock hands them this client and needs no check of its own.
//! Writes to the head itself pass, because each carries the head's
//! `resourceVersion` and Kubernetes refuses a stale one.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use kube::Client;
use thiserror::Error;

use super::lock::Inner;
use super::{PLURAL, STOP_AFTER};

/// Why a holder's guarded client refused a write.
#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum WritesStopped {
    #[error(
        "Kix stopped writing to the cluster: this run last renewed its deploy lock {seconds} seconds ago, and it sends no write once {} seconds have passed, so that a run taking the lock over cannot write at the same time",
        STOP_AFTER.as_secs()
    )]
    Deadline { seconds: u64 },
    #[error(
        "Kix stopped writing to the cluster: another run took over the deploy lock of Kix cluster {cluster}"
    )]
    TakenOver { cluster: String },
    #[error(
        "the Kix operator stopped its repair and gave the deploy lock to a run that is waiting for it"
    )]
    Yielded,
    #[error("Kix stopped writing to the cluster: this run already released its deploy lock")]
    Released,
}

/// Return whether a request changes something on the cluster. A dry run
/// writes nothing.
fn is_write(request: &http::Request<kube::client::Body>) -> bool {
    let method = request.method();
    if method == http::Method::GET
        || method == http::Method::HEAD
        || method == http::Method::OPTIONS
    {
        return false;
    }
    !request
        .uri()
        .query()
        .is_some_and(|q| q.split('&').any(|p| p == "dryRun=All"))
}

fn is_head(request: &http::Request<kube::client::Body>) -> bool {
    request
        .uri()
        .path()
        .split('/')
        .any(|segment| segment == PLURAL)
}

/// Wrap `client` so its writes stop with the lease `inner` describes.
pub(super) fn guarded(inner: Arc<Inner>, client: Client) -> Client {
    let namespace = client.default_namespace().to_string();
    let service = tower::service_fn(move |request: http::Request<kube::client::Body>| {
        let inner = inner.clone();
        let client = client.clone();
        async move {
            let write = is_write(&request) && !is_head(&request);
            if write {
                inner.check_waiting().await;
                if let Some(why) = inner.stopped() {
                    return Err(Box::new(why) as tower::BoxError);
                }
            }
            let response = client.send(request).await.map_err(tower::BoxError::from)?;
            if write && response.status().is_success() {
                inner.wrote.store(true, Ordering::SeqCst);
            }
            Ok::<_, tower::BoxError>(response)
        }
    });
    Client::new(service, namespace)
}
