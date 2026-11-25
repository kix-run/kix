//! Cancellation primitive for the deploy engine.
//!
//! A thin wrapper over `tokio_util::sync::CancellationToken`. The engine's
//! supervisor loop selects on `CancelToken::cancelled` so a cancel from the
//! caller (the CLI cancels it on Ctrl-C) or from the progress watchdog is
//! observed even while every node is in flight. Readiness loops also check
//! the flag between polls.
//!
//! The library never ends the process. A binary that wants Ctrl-C to stop a
//! run watches for the signal itself and cancels the token.
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
    /// Return a fresh, uncancelled token.
    pub fn new() -> Self {
        Self::default()
    }

    /// Return a token that is cancelled when this one is, and that can be
    /// cancelled on its own without cancelling this one. It starts with no
    /// reason.
    pub fn child(&self) -> Self {
        Self {
            inner: self.inner.child_token(),
            reason: Arc::default(),
        }
    }

    /// Signal cancellation. Subsequent calls are no-ops.
    pub fn cancel(&self) {
        self.inner.cancel();
    }

    /// Signal cancellation and record the reason if none is set.
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

    /// Return the reason passed to [`cancel_with_reason`](Self::cancel_with_reason),
    /// if any.
    pub(crate) fn reason(&self) -> Option<String> {
        self.reason.lock().ok().and_then(|r| r.clone())
    }

    /// Wait until the token is cancelled, or return immediately if it is
    /// already cancelled.
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

    /// Cancelling a child leaves its parent running, and cancelling the
    /// parent cancels every child.
    #[test]
    fn a_child_is_cancelled_with_its_parent_only() {
        let parent = CancelToken::new();
        let first = parent.child();
        first.cancel_with_reason("stalled");
        assert!(!parent.is_cancelled());
        assert!(parent.reason().is_none());
        let second = parent.child();
        parent.cancel();
        assert!(second.is_cancelled());
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
