//! One classification of apiserver failures, decided once.
//!
//! Every place that talks to the apiserver used to pattern-match on the
//! HTTP status code by hand (`resp.code == 403`, `resp.code >= 500`, ...).
//! Each site drew its own line between "transient" and "permanent", and
//! the lines did not agree. This module is the single table. The transport
//! layer in [`super::client`] uses it to decide what to retry; the sweep in
//! [`super::fetch`] uses it to tell "forbidden" from "failed"; apply and
//! readiness use it for conflicts and not-found.

use std::error::Error as StdError;

/// What kind of failure an apiserver call produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// HTTP 429. The server refused the request before doing any work. Safe to
    /// retry for every method, after the interval it asked for.
    RateLimited,
    /// HTTP 502, 503 or 504. The request may or may not have reached the server.
    /// Safe to retry for idempotent methods.
    Unavailable,
    /// Any other 5xx. Usually a webhook or storage backend having a bad
    /// moment. Safe to retry for idempotent methods.
    ServerError,
    /// The connection failed or dropped: refused, reset, TLS, EOF.
    Transport,
    /// A deadline set by kix expired before the server answered.
    Timeout,
    /// HTTP 401.
    Unauthorized,
    /// HTTP 403. A stable fact about the credentials, not a fault.
    Forbidden,
    /// HTTP 404.
    NotFound,
    /// HTTP 409.
    Conflict,
    /// HTTP 422.
    Invalid,
    /// Any other 4xx.
    ClientError,
    /// Everything else: serialisation, auth plugin, kubeconfig.
    Other,
}

impl FailureClass {
    /// Would the same request plausibly succeed if sent again?
    pub fn is_transient(self) -> bool {
        matches!(
            self,
            FailureClass::RateLimited
                | FailureClass::Unavailable
                | FailureClass::ServerError
                | FailureClass::Transport
                | FailureClass::Timeout
        )
    }
}

/// Classify an HTTP status code from the apiserver.
pub fn classify_status(code: u16) -> FailureClass {
    match code {
        429 => FailureClass::RateLimited,
        502..=504 => FailureClass::Unavailable,
        500..=599 => FailureClass::ServerError,
        401 => FailureClass::Unauthorized,
        403 => FailureClass::Forbidden,
        404 => FailureClass::NotFound,
        409 => FailureClass::Conflict,
        422 => FailureClass::Invalid,
        400..=499 => FailureClass::ClientError,
        _ => FailureClass::Other,
    }
}

/// Classify a `kube::Error`.
pub fn classify(err: &kube::Error) -> FailureClass {
    match err {
        kube::Error::Api(resp) => classify_status(resp.code),
        kube::Error::HyperError(_) => FailureClass::Transport,
        kube::Error::Service(e) => classify_service_error(e.as_ref()),
        _ => FailureClass::Other,
    }
}

/// Classify a boxed error that came up through the tower service stack.
///
/// The transport layer's own timeout error is recognised by type. Anything
/// else at this level is a connection-level failure.
pub fn classify_service_error(err: &(dyn StdError + 'static)) -> FailureClass {
    if error_chain_contains::<super::client::RequestTimeout>(err) {
        FailureClass::Timeout
    } else {
        FailureClass::Transport
    }
}

/// Render an error with its whole `source()` chain, outermost first.
///
/// kube's `Display` stops at the top: a refused connection prints as
/// "ServiceError: client error (Connect)" and the "connection refused"
/// underneath is lost. Command output should carry the cause.
pub fn describe(err: &(dyn StdError + 'static)) -> String {
    let mut parts: Vec<String> = Vec::new();
    let mut current: Option<&(dyn StdError + 'static)> = Some(err);
    while let Some(e) = current {
        let text = e.to_string();
        // Wrappers often repeat their source's text; keep each once.
        if parts.last().is_none_or(|last| !last.ends_with(&text)) {
            parts.push(text);
        }
        current = e.source();
    }
    parts.join(": ")
}

/// Walk an error's `source()` chain looking for a concrete type.
pub fn error_chain_contains<T: StdError + 'static>(err: &(dyn StdError + 'static)) -> bool {
    let mut current: Option<&(dyn StdError + 'static)> = Some(err);
    while let Some(e) = current {
        if e.is::<T>() {
            return true;
        }
        current = e.source();
    }
    false
}

/// Walk an error's `source()` chain and return the first value of a type.
pub fn error_chain_find<'a, T: StdError + 'static>(
    err: &'a (dyn StdError + 'static),
) -> Option<&'a T> {
    let mut current: Option<&(dyn StdError + 'static)> = Some(err);
    while let Some(e) = current {
        if let Some(found) = e.downcast_ref::<T>() {
            return Some(found);
        }
        current = e.source();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_table() {
        let cases = [
            (429, FailureClass::RateLimited),
            (502, FailureClass::Unavailable),
            (503, FailureClass::Unavailable),
            (504, FailureClass::Unavailable),
            (500, FailureClass::ServerError),
            (599, FailureClass::ServerError),
            (401, FailureClass::Unauthorized),
            (403, FailureClass::Forbidden),
            (404, FailureClass::NotFound),
            (409, FailureClass::Conflict),
            (422, FailureClass::Invalid),
            (400, FailureClass::ClientError),
            (418, FailureClass::ClientError),
            (200, FailureClass::Other),
            (0, FailureClass::Other),
        ];
        for (code, want) in cases {
            assert_eq!(classify_status(code), want, "status {code}");
        }
    }

    #[test]
    fn transient_means_retryable() {
        for class in [
            FailureClass::RateLimited,
            FailureClass::Unavailable,
            FailureClass::ServerError,
            FailureClass::Transport,
            FailureClass::Timeout,
        ] {
            assert!(class.is_transient(), "{class:?}");
        }
        for class in [
            FailureClass::Unauthorized,
            FailureClass::Forbidden,
            FailureClass::NotFound,
            FailureClass::Conflict,
            FailureClass::Invalid,
            FailureClass::ClientError,
            FailureClass::Other,
        ] {
            assert!(!class.is_transient(), "{class:?}");
        }
    }

    #[test]
    fn classify_api_error_uses_status() {
        let err = kube::Error::Api(kube::error::ErrorResponse {
            status: "Failure".into(),
            message: "storage is (re)initializing".into(),
            reason: "TooManyRequests".into(),
            code: 429,
        });
        assert_eq!(classify(&err), FailureClass::RateLimited);
    }

    #[derive(Debug)]
    struct Outer(Box<dyn StdError + Send + Sync>);
    impl std::fmt::Display for Outer {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "outer")
        }
    }
    impl StdError for Outer {
        fn source(&self) -> Option<&(dyn StdError + 'static)> {
            Some(self.0.as_ref())
        }
    }

    #[test]
    fn describe_joins_the_chain_and_drops_repeats() {
        let inner =
            std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "connection refused");
        let outer = Outer(Box::new(inner));
        assert_eq!(describe(&outer), "outer: connection refused");
        // A wrapper whose text already ends with its source's text adds nothing.
        #[derive(Debug)]
        struct Echo(std::io::Error);
        impl std::fmt::Display for Echo {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "wrapped: {}", self.0)
            }
        }
        impl StdError for Echo {
            fn source(&self) -> Option<&(dyn StdError + 'static)> {
                Some(&self.0)
            }
        }
        let echo = Echo(std::io::Error::other("boom"));
        assert_eq!(describe(&echo), "wrapped: boom");
    }

    #[test]
    fn chain_walk_finds_nested_timeout() {
        let inner = super::super::client::RequestTimeout(std::time::Duration::from_secs(1));
        let outer = Outer(Box::new(inner));
        assert!(error_chain_contains::<super::super::client::RequestTimeout>(&outer));
        assert_eq!(classify_service_error(&outer), FailureClass::Timeout);
        let plain = Outer(Box::new(std::io::Error::other("reset")));
        assert_eq!(classify_service_error(&plain), FailureClass::Transport);
    }
}
