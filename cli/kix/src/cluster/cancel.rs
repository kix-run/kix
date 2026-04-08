//! Cancellation primitive for the reconcile engine.
//!
//! A tiny local type rather than `tokio_util::sync::CancellationToken` —
//! we only need a cloneable boolean flag checked at poll boundaries, not
//! the full watcher/futures integration that tokio-util provides.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Clone-safe cancellation flag. Checked at wave boundaries and inside the
/// readiness poll loop so a long-running reconcile can be interrupted
/// cleanly — the operator needs this to abort a superseded deploy without
/// waiting out the current readiness timeout.
#[derive(Clone, Default, Debug)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    /// A fresh, un-cancelled token.
    pub fn new() -> Self {
        Self::default()
    }

    /// Signal cancellation. Idempotent.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    /// Check whether cancellation has been requested.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}
