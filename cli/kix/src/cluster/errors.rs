//! Classify Kubernetes API failures for retry and reporting decisions.
//!
//! [`super::client`] uses the classification for retries, [`super::inventory`]
//! distinguishes forbidden requests from other failures, and apply and
//! readiness handle conflicts and missing resources from the same table.
//! [`FetchError`] is what a failed read of the cluster returns.

use std::error::Error as StdError;
use std::time::Duration;

use thiserror::Error;

use super::activation;

/// What kind of failure an apiserver call produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureClass {
    /// HTTP 429. The server refused the request before doing any work. Safe to
    /// retry for every method, after the interval it asked for.
    RateLimited,
    /// HTTP 502, 503 or 504. The request may or may not have reached the server.
    /// Safe to retry for idempotent methods.
    Unavailable,
    /// Any other 5xx. Safe to retry for idempotent methods.
    ServerError,
    /// The connection failed or dropped: refused, reset, TLS, EOF.
    Transport,
    /// A deadline set by kix expired before the server answered.
    Timeout,
    /// HTTP 401.
    Unauthorized,
    /// HTTP 403. Retrying with the same credentials will not grant access.
    Forbidden,
    /// HTTP 404.
    NotFound,
    /// HTTP 409.
    Conflict,
    /// HTTP 422.
    Invalid,
    /// Any other 4xx.
    ClientError,
    /// Errors outside the classes above, such as serialization or kubeconfig errors.
    Other,
}

impl FailureClass {
    /// Whether retry policy may repeat the same request.
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
    if error_chain_contains::<RequestTimeout>(err) {
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

/// The error the per-attempt deadline produces. Classified as
/// [`FailureClass::Timeout`] by [`classify`].
#[derive(Debug)]
pub struct RequestTimeout(pub Duration);

impl std::fmt::Display for RequestTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no response from the apiserver within {:?}", self.0)
    }
}

impl std::error::Error for RequestTimeout {}

/// Errors from cluster fetching operations.
#[derive(Error, Debug)]
pub enum FetchError {
    #[error("failed to create Kubernetes client: {0}")]
    ClientError(#[source] Box<dyn std::error::Error + Send + Sync>),

    /// The endpoint swallowed the first-contact probe: no answer at all
    /// within the deadline. A stale `server:` address, a routing blackhole, a
    /// VPN or tailnet that is not up, or a load balancer that terminates TLS
    /// in front of an apiserver that has stopped answering all land here.
    #[error(
        "no response from the Kubernetes API server at {endpoint} within {}s. \
         Check the server address in your kubeconfig, or try --context <name>. \
         If the connection is working but needs more time, increase KIX_CONNECT_TIMEOUT (seconds).",
        timeout.as_secs()
    )]
    Unreachable { endpoint: String, timeout: Duration },

    /// First contact failed outright: DNS, connection refused, TLS, or a
    /// credential plugin that could not produce a token.
    #[error(
        "cannot reach the Kubernetes API server at {endpoint}: {}. \
         Check your kubeconfig, or try --context <name>.",
        describe(source)
    )]
    ConnectFailed {
        endpoint: String,
        #[source]
        source: kube::Error,
    },

    #[error("could not discover the resource types supported by the Kubernetes API: {}", describe(.0))]
    DiscoveryError(#[source] kube::Error),

    /// `/apis` kept listing group versions that answered 404 for
    /// [`DISCOVERY_SETTLE`](super::discovery::DISCOVERY_SETTLE). `missing` holds their paths.
    #[error(
        "could not discover the resource types supported by the Kubernetes API: \
         the API server lists {} but answered 404 for {} for {}s. \
         `kubectl get --raw {}` shows what it answers now.",
        missing.join(", "),
        if missing.len() == 1 { "it" } else { "them" },
        waited.as_secs(),
        missing.first().map_or("/apis", String::as_str)
    )]
    DiscoveryUnsettled {
        missing: Vec<String>,
        waited: Duration,
    },

    #[error("failed to list {resource}: {}", describe(source))]
    ListError {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error("failed to read {resource}: {}", describe(source))]
    GetError {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error("{0}")]
    RecordsError(#[source] activation::RecordsError),
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
        let inner = RequestTimeout(std::time::Duration::from_secs(1));
        let outer = Outer(Box::new(inner));
        assert!(error_chain_contains::<RequestTimeout>(&outer));
        assert_eq!(classify_service_error(&outer), FailureClass::Timeout);
        let plain = Outer(Box::new(std::io::Error::other("reset")));
        assert_eq!(classify_service_error(&plain), FailureClass::Transport);
    }
}
