//! Cancellation primitive for the deploy engine.
//!
//! A thin wrapper over `tokio_util::sync::CancellationToken`. The engine's
//! supervisor loop selects on [`CancelToken::cancelled`] so a cancel from the
//! caller (Ctrl-C, operator supersession) or from the progress watchdog is
//! observed even while every node is in flight. Readiness polls keep checking
//! the flag between polls as before.
//!
//! The token also carries the *reason* for the cancel, when the canceller
//! has one. The watchdog uses this to say "no progress for 10m" instead of
//! the bare "cancelled".

use std::sync::{Arc, Mutex};

use tokio_util::sync::CancellationToken;

/// Clone-safe cancellation flag.
#[derive(Clone, Default, Debug)]
pub struct CancelToken {
    inner: CancellationToken,
    reason: Arc<Mutex<Option<String>>>,
}

impl CancelToken {
    /// A fresh, un-cancelled token.
    pub fn new() -> Self {
        Self::default()
    }

    /// Signal cancellation. Idempotent.
    pub fn cancel(&self) {
        self.inner.cancel();
    }

    /// Cancel when the process is interrupted or asked to terminate.
    ///
    /// Must be called from inside a tokio runtime; the watcher task ends when
    /// the token is cancelled by anything, so it does not outlive the run.
    ///
    /// This is what turns Ctrl-C into an orderly stop rather than a killed
    /// process. It matters more than it used to: the deploy record is now
    /// created before the first wave, so a run that dies without cancelling
    /// leaves the record `Deploying` and nothing to say the run is over. A
    /// cancel takes the engine through its abort path, which marks the record
    /// `Failed` and lets the next deploy reconcile what this one applied.
    ///
    /// A second interrupt exits the process immediately. That has to be done
    /// explicitly: registering a signal with tokio replaces the OS default for
    /// the life of the process, so after the first Ctrl-C nothing but SIGKILL
    /// would end it, and an orderly stop against an unresponsive apiserver
    /// can sit through a 60 second bound. Exiting this way leaves the record
    /// `Deploying`, which the next deploy reports rather than guesses at.
    pub fn cancel_on_interrupt(&self) {
        let token = self.clone();
        tokio::spawn(async move {
            let mut terminate =
                match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::debug!("cannot watch SIGTERM: {e}");
                        return;
                    }
                };
            let reason = tokio::select! {
                _ = tokio::signal::ctrl_c() => "interrupted",
                _ = terminate.recv() => "terminated",
                _ = token.cancelled() => return,
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

    /// Signal cancellation and record why. The first reason wins.
    pub fn cancel_with_reason(&self, reason: impl Into<String>) {
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

    /// The reason given to [`cancel_with_reason`](Self::cancel_with_reason),
    /// if any.
    pub fn reason(&self) -> Option<String> {
        self.reason.lock().ok().and_then(|r| r.clone())
    }

    /// Resolves when the token is cancelled. Resolves at once if it already
    /// is.
    pub async fn cancelled(&self) {
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
