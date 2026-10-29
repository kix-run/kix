//! Cancellation primitive for the deploy engine.
//!
//! A thin wrapper over `tokio_util::sync::CancellationToken`. The engine's
//! supervisor loop selects on `CancelToken::cancelled` so a cancel from the
//! caller (Ctrl-C or operator supersession) or from the progress watchdog is
//! observed even while every node is in flight. Readiness loops also check
//! the flag between polls.
//!
//! The token also carries the *reason* for the cancel, when the canceller
//! has one. The watchdog uses this to say "no progress for 10m" instead of
//! the bare "cancelled".

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once};

use tokio_util::sync::CancellationToken;

/// Count of active interrupt watchers from [`CancelToken::cancel_on_interrupt`].
/// When non-zero, the fallback handler leaves the signal to them.
static WATCHING: AtomicUsize = AtomicUsize::new(0);
static FALLBACK: Once = Once::new();

/// Exit with the shell's code for the signal when no watcher is waiting
/// for it. Tokio never gives a registered signal back to the OS default, so
/// without this an interrupt after one run's watcher has ended (at `kix
/// deploy`'s confirmation, after the plan's dry run) would be swallowed.
fn exit_on_unwatched_interrupt() {
    FALLBACK.call_once(|| {
        tokio::spawn(async {
            let Ok(mut terminate) =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            else {
                return;
            };
            loop {
                let code = tokio::select! {
                    _ = tokio::signal::ctrl_c() => 130,
                    _ = terminate.recv() => 143,
                };
                if WATCHING.load(Ordering::SeqCst) == 0 {
                    std::process::exit(code);
                }
            }
        });
    });
}

/// Clone-safe cancellation flag.
#[derive(Clone, Default, Debug)]
pub struct CancelToken {
    inner: CancellationToken,
    reason: Arc<Mutex<Option<String>>>,
}

impl CancelToken {
    /// Return a fresh, uncancelled token.
    pub fn new() -> Self {
        Self::default()
    }

    /// Signal cancellation. Subsequent calls are no-ops.
    pub fn cancel(&self) {
        self.inner.cancel();
    }

    /// Cancel when the process is interrupted or asked to terminate.
    ///
    /// Call this from inside a Tokio runtime. The watcher task exits when the
    /// token is cancelled, so it does not outlive the run.
    ///
    /// Turning Ctrl-C into a cancellation lets the deploy engine run its abort
    /// path and mark the deploy record `Failed` so the next deploy can
    /// reconcile applied resources. If the process dies without cancelling,
    /// the deploy record remains in the `Deploying` state.
    ///
    /// A second interrupt exits the process immediately. Registering a signal
    /// with Tokio replaces the OS default handler for the life of the process,
    /// and an orderly stop against an unresponsive API server can wait up to
    /// 60 seconds. Exiting immediately leaves the deploy record in the
    /// `Deploying` state, which the next deploy reports.
    pub fn cancel_on_interrupt(&self) {
        exit_on_unwatched_interrupt();
        let token = self.clone();
        WATCHING.fetch_add(1, Ordering::SeqCst);
        tokio::spawn(async move {
            let mut terminate =
                match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::debug!("cannot watch SIGTERM: {e}");
                        WATCHING.fetch_sub(1, Ordering::SeqCst);
                        return;
                    }
                };
            let reason = tokio::select! {
                _ = tokio::signal::ctrl_c() => "interrupted",
                _ = terminate.recv() => "terminated",
                _ = token.cancelled() => {
                    WATCHING.fetch_sub(1, Ordering::SeqCst);
                    return;
                }
            };
            tracing::info!(%reason, "cancelling the run");
            token.cancel_with_reason(reason);

            // From here the run is winding down. Give the user the escape
            // hatch the OS default would have given them.
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = terminate.recv() => {}
            }
            // 130 is the conventional shell code for "killed by SIGINT".
            std::process::exit(130);
        });
    }

    /// Signal cancellation and record the reason if none is set.
    pub(crate) fn cancel_with_reason(&self, reason: impl Into<String>) {
        if let Ok(mut slot) = self.reason.lock()
            && slot.is_none()
        {
            *slot = Some(reason.into());
        }
        self.inner.cancel();
    }

    /// Check whether cancellation has been requested.
    pub fn is_cancelled(&self) -> bool {
        self.inner.is_cancelled()
    }

    /// Return the reason passed to [`cancel_with_reason`](Self::cancel_with_reason),
    /// if any.
    pub(crate) fn reason(&self) -> Option<String> {
        self.reason.lock().ok().and_then(|r| r.clone())
    }

    /// Wait until the token is cancelled, or return immediately if it is
    /// already cancelled.
    pub(crate) async fn cancelled(&self) {
        self.inner.cancelled().await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test(start_paused = true)]
    async fn cancelled_wakes_a_waiter() {
        let token = CancelToken::new();
        let waiter = token.clone();
        let handle = tokio::spawn(async move {
            waiter.cancelled().await;
            waiter.reason()
        });
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(!handle.is_finished());
        token.cancel_with_reason("test");
        let reason = tokio::time::timeout(Duration::from_secs(1), handle)
            .await
            .expect("waiter must wake")
            .unwrap();
        assert_eq!(reason.as_deref(), Some("test"));
        assert!(token.is_cancelled());
    }

    #[test]
    fn first_reason_wins() {
        let token = CancelToken::new();
        token.cancel_with_reason("first");
        token.cancel_with_reason("second");
        assert_eq!(token.reason().as_deref(), Some("first"));
        let plain = CancelToken::new();
        plain.cancel();
        assert!(plain.reason().is_none());
    }
}
