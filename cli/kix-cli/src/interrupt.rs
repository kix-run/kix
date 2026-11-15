//! Turn Ctrl-C and SIGTERM into a cancelled deploy run.
//!
//! Tokio never gives a registered signal back to the OS default handler, so
//! once Kix watches for one, Kix alone decides what an interrupt does. This
//! module makes that decision for the `kix` process. The library only
//! cancels a [`CancelToken`] and returns, because the operator embeds it
//! too.
//!
//! These are the only places outside `main` that end the process. They run
//! in a signal task while `main` is blocked on the run, and their purpose is
//! to stop at once without waiting for destructors.

use std::sync::Once;
use std::sync::atomic::{AtomicUsize, Ordering};

use kix::cluster::cancel::CancelToken;
use tokio::signal::unix::{SignalKind, signal};

/// Count of active watchers from [`cancel_on_interrupt`]. When non-zero, the
/// fallback handler leaves the signal to them.
static WATCHING: AtomicUsize = AtomicUsize::new(0);
static FALLBACK: Once = Once::new();

/// Exit with the shell's code for the signal when no watcher is waiting for
/// it. Without this, an interrupt after one run's watcher has ended (at
/// `kix deploy`'s confirmation, after the plan's dry run) would be
/// swallowed.
fn exit_on_unwatched_interrupt() {
    FALLBACK.call_once(|| {
        tokio::spawn(async {
            let Ok(mut terminate) = signal(SignalKind::terminate()) else {
                return;
            };
            loop {
                let code = tokio::select! {
                    _ = tokio::signal::ctrl_c() => 130,
                    _ = terminate.recv() => 143,
                };
                if WATCHING.load(Ordering::SeqCst) == 0 {
                    #[allow(clippy::disallowed_methods)]
                    std::process::exit(code);
                }
            }
        });
    });
}

/// Cancel `token` when the process is interrupted or asked to terminate.
///
/// Call this from inside a Tokio runtime. The watcher task ends when the
/// token is cancelled, so it does not outlive the run.
///
/// Turning Ctrl-C into a cancellation lets the deploy engine run its abort
/// path and mark the deploy record `Failed`, so the next deploy can
/// reconcile applied resources. If the process dies without cancelling, the
/// deploy record stays in the `Deploying` state.
///
/// A second interrupt exits the process immediately. An orderly stop
/// against an unresponsive API server can wait up to 60 seconds. Exiting
/// immediately leaves the deploy record in the `Deploying` state, which the
/// next deploy reports.
pub(crate) fn cancel_on_interrupt(token: &CancelToken) {
    exit_on_unwatched_interrupt();
    let token = token.clone();
    WATCHING.fetch_add(1, Ordering::SeqCst);
    tokio::spawn(async move {
        let mut terminate = match signal(SignalKind::terminate()) {
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

        // The run is winding down. Give the user the way out that the OS
        // default handler would have given them.
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
        // 130 is the conventional shell code for "killed by SIGINT".
        #[allow(clippy::disallowed_methods)]
        std::process::exit(130);
    });
}
