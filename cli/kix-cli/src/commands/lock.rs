//! Take and release a Kix cluster's deploy lock for a command that changes
//! the cluster ([`kix::cluster::head`]).

use std::sync::Arc;

use kix::cluster::head::{self, Holder, Lock, LockView, Purpose, Request};
use miette::{Result, miette};

use crate::output;

/// Take the deploy lock of Kix cluster `cluster` for `command` (such as `kix
/// deploy`) through `client`. `expect` is the generation the command's plan
/// read, or `None` when nothing binds the command to one. Say once when
/// another run holds the lock and this one waits for it.
pub(crate) async fn take(
    client: &kube::Client,
    cluster: &str,
    command: &str,
    purpose: Purpose,
    activation: Option<String>,
    expect: Option<u64>,
) -> Result<Arc<Lock>> {
    let request = Request {
        cluster: cluster.to_string(),
        holder: Holder::cli(command),
        purpose,
        activation,
        expect,
    };
    let on_watch = |other: &head::LockState| say_watching(other);
    head::take(client, request, head::system_clock(), &on_watch)
        .await
        .map(Arc::new)
        .map_err(|e| miette!("{e}"))
}

/// Say that another run holds the deploy lock and that this one watches it.
pub(crate) fn say_watching(other: &head::LockState) {
    let view = LockView::of(other, chrono::Utc::now());
    eprintln!(
        "{} {}. Waiting up to {}s to see whether it is still running...",
        output::yellow("Locked:"),
        view.describe(),
        head::LEASE.as_secs()
    );
}

/// Settle a deploy lock another run holds on Kix cluster `cluster` before
/// `command` reads the state it plans from ([`head::settle`]): refuse when
/// that run is alive, and take a dead run's lock over and release it.
pub(crate) async fn settle(
    client: &kube::Client,
    cluster: &str,
    command: &str,
    purpose: Purpose,
) -> Result<()> {
    let request = Request {
        cluster: cluster.to_string(),
        holder: Holder::cli(command),
        purpose,
        activation: None,
        expect: None,
    };
    head::settle(client, request, head::system_clock(), &say_watching)
        .await
        .map_err(|e| miette!("{e}"))
}

/// Release `lock`, warning, with what happens next, when the lock could not
/// be written.
pub(crate) async fn release(lock: &Lock) {
    match lock.release().await {
        Ok(()) => {}
        Err(head::CommitError::Lost { cluster }) => eprintln!(
            "{} another run took over the deploy lock of Kix cluster {cluster} before this run released it, so this run has no lock to release. That run holds the lock now, or has released it.",
            output::yellow("warning:"),
        ),
        Err(e @ head::CommitError::Api { .. }) => eprintln!(
            "{} {e}. The lock expires {} seconds after this run's last renewal, and the next run takes it over.",
            output::yellow("warning:"),
            head::LEASE.as_secs()
        ),
    }
}
