//! Apiserver retry and deadline policy shared by every client call.
//!
//! 429 responses may be retried for every method. Server errors and connection
//! failures are retried only for idempotent methods, except a POST whose
//! connection never opened. Backoff is bounded by an attempt count and a time
//! budget, and `Retry-After` takes precedence.
//!
//! The layer does not limit requests in flight. A permit held inside an
//! unpolled request future can block work needed to resume that future. Callers
//! that create bursts, such as [`super::inventory`], bound their own concurrency.
//! Exhausted requests return their last response or error unchanged.

use std::{
    future::Future,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use bytes::Bytes;
use http::{HeaderMap, Method, Request, Response, StatusCode, Uri, Version, header::RETRY_AFTER};
use http_body_util::BodyExt;
use kube::{
    Client, Config,
    client::{Body, ClientBuilder},
    config::{KubeConfigOptions, Kubeconfig},
};
use tower::{BoxError, Layer, Service, ServiceExt, buffer::Buffer};

use super::errors::{FailureClass, FetchError, RequestTimeout, classify_status, error_chain_find};

/// Retry and timeout settings for apiserver requests.
#[derive(Debug, Clone)]
pub struct ResiliencePolicy {
    /// Total attempts per request, including the first. `1` disables retries.
    ///
    /// The default spans roughly twenty seconds of backoff before jitter.
    pub max_attempts: usize,
    /// First backoff. Doubles each attempt up to `max_backoff`.
    pub initial_backoff: Duration,
    /// Cap on the computed backoff.
    pub max_backoff: Duration,
    /// Maximum delay accepted from a `Retry-After` header.
    pub retry_after_cap: Duration,
    /// Total wall-clock budget across all attempts of one request. Once
    /// spent, the last outcome is returned.
    pub budget: Duration,
    /// Per-attempt deadline for requests that are not watches, measured until
    /// the response headers arrive. `None` means no deadline.
    pub request_timeout: Option<Duration>,
    /// TCP connect timeout, applied on kube's connector.
    pub connect_timeout: Duration,
    /// Whether [`make_client`] proves the endpoint answers before handing
    /// the client over.
    pub preflight: bool,
}

impl Default for ResiliencePolicy {
    fn default() -> Self {
        Self {
            max_attempts: 7,
            initial_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(8),
            retry_after_cap: Duration::from_secs(30),
            budget: Duration::from_secs(60),
            request_timeout: Some(Duration::from_secs(120)),
            connect_timeout: Duration::from_secs(15),
            preflight: true,
        }
    }
}

/// Env var: total attempts per request (`1` disables retries).
pub(crate) const RETRY_ATTEMPTS_ENV: &str = "KIX_RETRY_ATTEMPTS";
/// Env var: per-attempt deadline in whole seconds (`0` = none).
pub(crate) const REQUEST_TIMEOUT_ENV: &str = "KIX_REQUEST_TIMEOUT";
/// Env var: TCP connect timeout in whole seconds.
pub(crate) const CONNECT_TIMEOUT_ENV: &str = "KIX_CONNECT_TIMEOUT";
/// Env var: set to `0` to skip the first-contact probe in [`make_client`].
pub(crate) const PREFLIGHT_ENV: &str = "KIX_PREFLIGHT";

impl ResiliencePolicy {
    /// Return the default policy with environment overrides applied.
    /// Unparseable values are ignored with a warning rather than failing the
    /// command. The binaries call this once, and nothing in this crate reads
    /// the transport policy from the environment.
    pub fn from_env() -> Self {
        let mut policy = Self::default();
        if let Some(n) = env_number(RETRY_ATTEMPTS_ENV) {
            policy.max_attempts = n.max(1) as usize;
        }
        if let Some(n) = env_number(REQUEST_TIMEOUT_ENV) {
            policy.request_timeout = (n > 0).then(|| Duration::from_secs(n));
        }
        if let Some(n) = env_number(CONNECT_TIMEOUT_ENV)
            && n > 0
        {
            policy.connect_timeout = Duration::from_secs(n);
        }
        if let Some(n) = env_number(PREFLIGHT_ENV) {
            policy.preflight = n > 0;
        }
        policy
    }
}

/// Marks the request that verifies the cluster answers.
///
/// This request gets one attempt and relies on the caller's deadline. The
/// transport connect timeout still applies so connection failures retain
/// their specific cause. It uses the shared client to preserve its connection.
#[derive(Clone, Copy, Debug)]
pub(crate) struct FirstContact;

/// Mark a request as first contact. See [`FirstContact`].
pub(crate) fn mark_first_contact<T>(req: &mut Request<T>) {
    req.extensions_mut().insert(FirstContact);
}

/// Read a whole-number environment variable, warning on garbage.
pub(crate) fn env_number(name: &str) -> Option<u64> {
    let raw = std::env::var(name).ok()?;
    match raw.trim().parse::<u64>() {
        Ok(n) => Some(n),
        Err(_) => {
            tracing::warn!(var = name, value = %raw, "ignoring: not a whole number");
            None
        }
    }
}

/// Build a kube `Client` from a `Config` with the resilience layer applied.
///
/// This is the one place a client is constructed for the CLI and the
/// operator. Prefer it over `Client::try_from(config)`. The client asks for
/// gzip answers. `ClientBuilder::try_from` adds the layer that decodes them,
/// beneath the resilience layer added here. A kubeconfig cluster that sets
/// `disable-compression: true` turns compression off.
pub async fn build_client(
    mut config: Config,
    policy: ResiliencePolicy,
) -> Result<Client, kube::Error> {
    config.connect_timeout = Some(policy.connect_timeout);
    // A read that stalls this long means a dead connection. The server ends
    // a watch after 290 s, so a live watch always reads something before
    // this. The operator's watch reconnects instead of waiting forever.
    config.read_timeout = Some(std::time::Duration::from_secs(295));
    // kube's own retry layer would sit beneath this one and repeat each
    // attempt up to 15 times, so the attempt cap and budget here would no
    // longer bound a request.
    config.default_retry = false;
    let builder = ClientBuilder::try_from(config)?;
    Ok(builder.with_layer(&ResilienceLayer::new(policy)).build())
}

/// Request counters maintained by the layer, read by its tests.
#[derive(Debug, Default)]
pub(crate) struct Stats {
    /// Requests that entered the layer.
    pub requests: AtomicU64,
    /// Attempts sent to the inner service (>= requests).
    pub attempts: AtomicU64,
    /// Requests that were retried at least once.
    pub retried: AtomicU64,
    /// Requests returned after the budget or attempt cap was spent.
    pub exhausted: AtomicU64,
}

/// Tower layer that wraps the inner service in a `Buffer` (so the retry
/// future can own a handle to it) and then in [`Resilience`].
#[derive(Clone)]
pub(crate) struct ResilienceLayer {
    policy: Arc<ResiliencePolicy>,
    stats: Arc<Stats>,
}

impl ResilienceLayer {
    pub fn new(policy: ResiliencePolicy) -> Self {
        Self {
            policy: Arc::new(policy),
            stats: Arc::new(Stats::default()),
        }
    }
}

impl<S> Layer<S> for ResilienceLayer
where
    S: Service<Request<Body>> + Send + 'static,
    S::Future: Send,
    S::Error: Into<BoxError> + Send + Sync,
{
    type Service = Resilience<Buffer<Request<Body>, S::Future>>;

    fn layer(&self, inner: S) -> Self::Service {
        // The bound only limits how many requests can queue for the worker
        // before callers see backpressure. It is not a concurrency cap and
        // this layer has none (see the module docs).
        let buffered = Buffer::new(inner, 1024);
        Resilience::with_shared(buffered, self.policy.clone(), self.stats.clone())
    }
}

/// Retry and timeout service, generic so tests can wrap a fake service without
/// `Buffer`.
#[derive(Clone)]
pub(crate) struct Resilience<S> {
    inner: S,
    policy: Arc<ResiliencePolicy>,
    stats: Arc<Stats>,
}

impl<S> Resilience<S> {
    /// Wrap `inner` with fresh counters.
    #[cfg(test)]
    pub fn new(inner: S, policy: ResiliencePolicy) -> Self {
        Self::with_shared(inner, Arc::new(policy), Arc::new(Stats::default()))
    }

    fn with_shared(inner: S, policy: Arc<ResiliencePolicy>, stats: Arc<Stats>) -> Self {
        Self {
            inner,
            policy,
            stats,
        }
    }

    #[cfg(test)]
    pub(crate) fn stats(&self) -> Arc<Stats> {
        self.stats.clone()
    }
}

impl<S, B> Service<Request<Body>> for Resilience<S>
where
    S: Service<Request<Body>, Response = Response<B>> + Clone + Send + 'static,
    S::Future: Send + 'static,
    S::Error: Into<BoxError>,
    B: Send + 'static,
{
    type Response = Response<B>;
    type Error = BoxError;
    type Future = Pin<Box<dyn Future<Output = Result<Response<B>, BoxError>> + Send>>;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.inner.poll_ready(cx).map_err(Into::into)
    }

    fn call(&mut self, req: Request<Body>) -> Self::Future {
        // Move `self.inner`, which holds the polled readiness, into the future
        // and keep a clone.
        let clone = self.inner.clone();
        let inner = std::mem::replace(&mut self.inner, clone);
        let policy = self.policy.clone();
        let stats = self.stats.clone();
        Box::pin(run(inner, req, policy, stats))
    }
}

/// Request parts needed to rebuild a request for another attempt. Because
/// `http::request::Parts` is not `Clone`, the relevant fields are copied once.
struct RequestShape {
    method: Method,
    uri: Uri,
    version: Version,
    headers: HeaderMap,
    is_watch: bool,
    idempotent: bool,
    dry_run: bool,
    first_contact: bool,
}

impl RequestShape {
    fn from_parts(parts: &http::request::Parts) -> Self {
        Self {
            method: parts.method.clone(),
            uri: parts.uri.clone(),
            version: parts.version,
            headers: parts.headers.clone(),
            is_watch: is_watch_uri(&parts.uri),
            idempotent: is_idempotent(&parts.method),
            dry_run: is_dry_run_uri(&parts.uri),
            first_contact: parts.extensions.get::<FirstContact>().is_some(),
        }
    }

    fn build(&self, body: Bytes) -> Request<Body> {
        let mut req = Request::builder()
            .method(self.method.clone())
            .uri(self.uri.clone())
            .version(self.version)
            .body(Body::from(body))
            .expect("rebuilding a request from valid parts cannot fail");
        *req.headers_mut() = self.headers.clone();
        req
    }
}

/// Return whether `uri` is a watch request (`watch=true` or `watch=1` in the
/// query).
pub(crate) fn is_watch_uri(uri: &Uri) -> bool {
    uri.query().is_some_and(|q| {
        q.split('&')
            .any(|pair| pair == "watch=true" || pair == "watch=1")
    })
}

/// Return whether `uri` asks for a dry run (`dryRun=All` in the query).
pub(crate) fn is_dry_run_uri(uri: &Uri) -> bool {
    uri.query()
        .is_some_and(|q| q.split('&').any(|pair| pair == "dryRun=All"))
}

/// Return whether `method` can be repeated without changing the outcome.
///
/// Everything Kix sends is idempotent except POST. Server-side apply is a
/// PATCH, and a repeated apply of the same manifest is a no-op.
pub(crate) fn is_idempotent(method: &Method) -> bool {
    matches!(
        *method,
        Method::GET | Method::HEAD | Method::OPTIONS | Method::DELETE | Method::PUT | Method::PATCH
    )
}

/// Outcome of a single request attempt for retry decisions.
pub enum Observed<'a> {
    /// The server answered.
    Status(StatusCode, &'a HeaderMap),
    /// The connection failed, or the deadline expired.
    Error(&'a BoxError),
}

/// Action to take after a request attempt.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Return this outcome to the caller.
    Done,
    /// Sleep this long, then send the request again.
    Retry(Duration),
}

/// Decide whether to retry or finish after `attempt` (starting at 1), given
/// `elapsed` since the first attempt started.
///
/// A dry run is not retried after HTTP 500. The apiserver answers a dry run
/// with 500 when an admission webhook cannot be reached, and that does not
/// change within the retry budget. A real write keeps the retry, which helps
/// while a webhook's pod starts.
pub fn decide(
    policy: &ResiliencePolicy,
    shape_idempotent: bool,
    dry_run: bool,
    observed: Observed<'_>,
    attempt: usize,
    elapsed: Duration,
) -> Verdict {
    let retryable = match &observed {
        Observed::Status(status, _) => match classify_status(status.as_u16()) {
            FailureClass::RateLimited => true,
            FailureClass::Unavailable => shape_idempotent,
            FailureClass::ServerError => shape_idempotent && !dry_run,
            _ => false,
        },
        // Do not extend a connect timeout across the full retry budget.
        // Refused and reset connections remain retryable because the server
        // may be restarting.
        Observed::Error(err) if is_connect_timeout(err.as_ref()) => false,
        Observed::Error(err) => shape_idempotent || is_connect_error(err.as_ref()),
    };
    if !retryable || attempt >= policy.max_attempts || elapsed >= policy.budget {
        return Verdict::Done;
    }
    let delay = match &observed {
        Observed::Status(_, headers) => retry_after(headers)
            .map(|ra| ra.min(policy.retry_after_cap))
            .unwrap_or_else(|| backoff(policy, attempt)),
        Observed::Error(_) => backoff(policy, attempt),
    };
    if elapsed + delay > policy.budget {
        return Verdict::Done;
    }
    Verdict::Retry(delay)
}

/// Compute exponential backoff with equal jitter. Half of each step is fixed
/// and half is random, spreading consecutive attempts without collapsing to
/// zero.
pub fn backoff(policy: &ResiliencePolicy, attempt: usize) -> Duration {
    let exp = attempt.saturating_sub(1).min(16) as u32;
    let base = policy
        .initial_backoff
        .saturating_mul(1u32 << exp)
        .min(policy.max_backoff);
    let half = base / 2;
    let jitter_ms = if half.is_zero() {
        0
    } else {
        fastrand::u64(0..=half.as_millis() as u64)
    };
    half + Duration::from_millis(jitter_ms)
}

/// Parse a `Retry-After` header given in whole seconds. HTTP-date forms are
/// ignored because the API server never sends them.
pub(crate) fn retry_after(headers: &HeaderMap) -> Option<Duration> {
    headers
        .get(RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
}

/// Return whether the request failed before the connection opened. Such a
/// request never reached the server, so even a POST is safe to send again.
pub(crate) fn is_connect_error(err: &(dyn std::error::Error + 'static)) -> bool {
    error_chain_find::<hyper_util::client::legacy::Error>(err).is_some_and(|e| e.is_connect())
}

/// Return whether the connect phase timed out rather than being refused or
/// reset. Kube's connector reports this as an `io::Error` of kind `TimedOut`
/// beneath the hyper connect error.
pub(crate) fn is_connect_timeout(err: &(dyn std::error::Error + 'static)) -> bool {
    is_connect_error(err)
        && error_chain_find::<std::io::Error>(err)
            .is_some_and(|e| e.kind() == std::io::ErrorKind::TimedOut)
}

async fn run<S, B>(
    mut inner: S,
    req: Request<Body>,
    policy: Arc<ResiliencePolicy>,
    stats: Arc<Stats>,
) -> Result<Response<B>, BoxError>
where
    S: Service<Request<Body>, Response = Response<B>> + Send + 'static,
    S::Future: Send + 'static,
    S::Error: Into<BoxError>,
{
    stats.requests.fetch_add(1, Ordering::Relaxed);
    let (parts, body) = req.into_parts();
    let shape = RequestShape::from_parts(&parts);
    // Buffer the body once so it can be replayed. Kix request bodies are
    // manifests, a few kilobytes at most.
    let bytes = body.collect().await.map_err(BoxError::from)?.to_bytes();
    let started = Instant::now();
    let mut attempt = 0usize;
    let mut retried = false;

    loop {
        attempt += 1;
        stats.attempts.fetch_add(1, Ordering::Relaxed);
        let outcome = send_once(&mut inner, &shape, bytes.clone(), &policy).await;

        let observed = match &outcome {
            Ok(resp) => Observed::Status(resp.status(), resp.headers()),
            Err(err) => Observed::Error(err),
        };
        let verdict = if shape.first_contact {
            Verdict::Done
        } else {
            decide(
                &policy,
                shape.idempotent,
                shape.dry_run,
                observed,
                attempt,
                started.elapsed(),
            )
        };
        match verdict {
            Verdict::Done => {
                if retried {
                    let gave_up = match &outcome {
                        Ok(resp) => !resp.status().is_success(),
                        Err(_) => true,
                    };
                    if gave_up {
                        stats.exhausted.fetch_add(1, Ordering::Relaxed);
                        tracing::warn!(
                            method = %shape.method,
                            path = shape.uri.path(),
                            attempts = attempt,
                            elapsed_ms = started.elapsed().as_millis() as u64,
                            "giving up on apiserver request"
                        );
                    }
                }
                return outcome;
            }
            Verdict::Retry(delay) => {
                if !retried {
                    retried = true;
                    stats.retried.fetch_add(1, Ordering::Relaxed);
                }
                let reason = match &outcome {
                    Ok(resp) => resp.status().to_string(),
                    Err(err) => err.to_string(),
                };
                // Log retries at debug. The `Done` arm warns if all retries are
                // exhausted.
                tracing::debug!(
                    method = %shape.method,
                    path = shape.uri.path(),
                    attempt,
                    max_attempts = policy.max_attempts,
                    delay_ms = delay.as_millis() as u64,
                    reason,
                    "apiserver request failed, retrying"
                );
                tokio::time::sleep(delay).await;
            }
        }
    }
}

async fn send_once<S, B>(
    inner: &mut S,
    shape: &RequestShape,
    body: Bytes,
    policy: &ResiliencePolicy,
) -> Result<Response<B>, BoxError>
where
    S: Service<Request<Body>, Response = Response<B>>,
    S::Error: Into<BoxError>,
{
    let req = shape.build(body);
    let ready = inner.ready().await.map_err(Into::into)?;
    let call = ready.call(req);
    // Watch requests are long-lived, and first-contact requests use the
    // caller's deadline.
    let exempt = shape.is_watch || shape.first_contact;
    match policy.request_timeout.filter(|_| !exempt) {
        Some(deadline) => match tokio::time::timeout(deadline, call).await {
            Ok(result) => result.map_err(Into::into),
            Err(_) => Err(Box::new(RequestTimeout(deadline)) as BoxError),
        },
        None => call.await.map_err(Into::into),
    }
}

/// Create a kube client with `policy` applied, optionally targeting a specific
/// context.
///
/// Every command builds its client here using [`ResiliencePolicy::from_env`].
/// When `policy.preflight` is enabled, this probes the API server before
/// returning so callers only receive a client whose endpoint responds.
pub async fn make_client(
    context: Option<&str>,
    policy: ResiliencePolicy,
) -> Result<Client, FetchError> {
    let config = match context {
        Some(ctx) => {
            let kubeconfig =
                Kubeconfig::read().map_err(|e| FetchError::ClientError(Box::new(e)))?;
            let options = KubeConfigOptions {
                context: Some(ctx.to_string()),
                ..Default::default()
            };
            Config::from_custom_kubeconfig(kubeconfig, &options)
                .await
                .map_err(|e| FetchError::ClientError(Box::new(e)))?
        }
        None => Config::infer().await.map_err(|e| FetchError::NoCluster {
            detail: e.to_string(),
        })?,
    };

    let endpoint = config.cluster_url.to_string();
    let deadline = policy.connect_timeout + PROBE_GRACE;
    let preflight = policy.preflight;

    let client = build_client(config, policy)
        .await
        .map_err(|e| FetchError::ClientError(Box::new(e)))?;

    if preflight {
        probe_apiserver(&client, &endpoint, deadline).await?;
    }
    Ok(client)
}

/// Extra time given to the preflight probe beyond `connect_timeout`.
///
/// The transport's `connect_timeout` bounds TCP and TLS connection setup and
/// reports the specific connection error. The probe's own deadline is slightly
/// longer so it only fires when a connection succeeds and the endpoint then
/// stops responding.
const PROBE_GRACE: Duration = Duration::from_secs(5);

/// Verify that the API server responds within `deadline`.
///
/// `Client::try_from` does not touch the network, so probing up front catches
/// unreachable endpoints before the first API call:
///
/// - If the connection fails or times out, the transport's `connect_timeout`
///   bounds the attempt and the probe attaches the endpoint URL to the error.
/// - If the connection succeeds (for example, through a TLS-terminating load
///   balancer) and the upstream server never replies, the probe's `deadline`
///   bounds the wait.
///
/// Only transport failures count as unreachable. Any HTTP response, including
/// 401, 403, or 404, proves the endpoint is reachable and lets the subsequent
/// API call report the status error.
async fn probe_apiserver(
    client: &Client,
    endpoint: &str,
    deadline: Duration,
) -> Result<(), FetchError> {
    // Send GET /version with the `FirstContact` marker so it does not retry,
    // while pooling the connection for subsequent requests.
    let mut request = match http::Request::get("/version").body(Vec::new()) {
        Ok(request) => request,
        Err(e) => return Err(FetchError::ClientError(Box::new(e))),
    };
    mark_first_contact(&mut request);

    let probe = client.request::<k8s_openapi::apimachinery::pkg::version::Info>(request);
    match tokio::time::timeout(deadline, probe).await {
        Ok(Ok(info)) => {
            tracing::debug!(endpoint, version = %info.git_version, "apiserver reachable");
            Ok(())
        }
        Ok(Err(e)) if server_responded(&e) => {
            tracing::debug!(endpoint, error = %e, "apiserver reachable, /version unreadable");
            Ok(())
        }
        Ok(Err(source)) => Err(FetchError::ConnectFailed {
            endpoint: endpoint.to_string(),
            source,
        }),
        Err(_elapsed) => Err(FetchError::Unreachable {
            endpoint: endpoint.to_string(),
            timeout: deadline,
        }),
    }
}

/// Return whether `e` came from an HTTP response rather than a transport
/// failure.
fn server_responded(e: &kube::Error) -> bool {
    matches!(
        e,
        kube::Error::Api(_) | kube::Error::SerdeError(_) | kube::Error::FromUtf8(_)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::Full;
    use kube::client::DynBody;
    use std::{collections::VecDeque, convert::Infallible, sync::Mutex};

    fn policy() -> ResiliencePolicy {
        ResiliencePolicy {
            max_attempts: 4,
            initial_backoff: Duration::from_millis(2),
            max_backoff: Duration::from_millis(4),
            retry_after_cap: Duration::from_millis(10),
            budget: Duration::from_secs(5),
            request_timeout: Some(Duration::from_millis(500)),
            connect_timeout: Duration::from_secs(1),
            preflight: true,
        }
    }

    fn empty_body() -> Box<DynBody> {
        Box::new(Full::new(Bytes::new()).map_err(|never: Infallible| match never {}))
    }

    fn response(status: u16) -> Response<Box<DynBody>> {
        Response::builder()
            .status(status)
            .body(empty_body())
            .unwrap()
    }

    /// What the fake inner service should do on each successive attempt.
    enum Step {
        Reply(u16),
        ReplyWith(u16, &'static str, &'static str),
        Fail(&'static str),
        Hang(Duration),
    }

    struct Seen {
        methods: Vec<Method>,
        bodies: Vec<Bytes>,
    }

    type Script = Arc<Mutex<VecDeque<Step>>>;
    type Log = Arc<Mutex<Seen>>;
    type BoxFut = Pin<Box<dyn Future<Output = Result<Response<Box<DynBody>>, BoxError>> + Send>>;

    /// A fake apiserver that follows a script and records what it saw.
    #[derive(Clone)]
    struct Fake {
        script: Script,
        log: Log,
    }

    impl Service<Request<Body>> for Fake {
        type Response = Response<Box<DynBody>>;
        type Error = BoxError;
        type Future = BoxFut;

        fn poll_ready(&mut self, _cx: &mut Context<'_>) -> Poll<Result<(), BoxError>> {
            Poll::Ready(Ok(()))
        }

        fn call(&mut self, req: Request<Body>) -> BoxFut {
            let script = self.script.clone();
            let log = self.log.clone();
            Box::pin(async move {
                let (parts, body) = req.into_parts();
                let bytes = body.collect().await.map_err(BoxError::from)?.to_bytes();
                {
                    let mut seen = log.lock().unwrap();
                    seen.methods.push(parts.method.clone());
                    seen.bodies.push(bytes);
                }
                let step = script
                    .lock()
                    .unwrap()
                    .pop_front()
                    .expect("script exhausted");
                match step {
                    Step::Reply(code) => Ok(response(code)),
                    Step::ReplyWith(code, name, value) => {
                        let mut resp = response(code);
                        resp.headers_mut().insert(name, value.parse().unwrap());
                        Ok(resp)
                    }
                    Step::Fail(msg) => Err(BoxError::from(std::io::Error::other(msg))),
                    Step::Hang(d) => {
                        tokio::time::sleep(d).await;
                        Ok(response(200))
                    }
                }
            })
        }
    }

    fn harness(steps: Vec<Step>, policy: ResiliencePolicy) -> (Resilience<Fake>, Log) {
        let script: Script = Arc::new(Mutex::new(steps.into()));
        let log: Log = Arc::new(Mutex::new(Seen {
            methods: vec![],
            bodies: vec![],
        }));
        (
            Resilience::new(
                Fake {
                    script,
                    log: log.clone(),
                },
                policy,
            ),
            log,
        )
    }

    /// Extract the error from `r` without requiring `Response<Box<DynBody>>: Debug`.
    fn expect_err(r: Result<Response<Box<DynBody>>, BoxError>) -> BoxError {
        match r {
            Ok(resp) => panic!("expected an error, got status {}", resp.status()),
            Err(e) => e,
        }
    }

    fn request(method: Method, uri: &str, body: &'static str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .body(Body::from(Bytes::from_static(body.as_bytes())))
            .unwrap()
    }

    #[tokio::test]
    async fn rate_limited_get_is_retried_until_it_succeeds() {
        let (mut svc, log) = harness(
            vec![Step::Reply(429), Step::Reply(429), Step::Reply(200)],
            policy(),
        );
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::GET, "/api/v1/pods", ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(log.lock().unwrap().methods.len(), 3);
        let stats = svc.stats();
        assert_eq!(stats.requests.load(Ordering::Relaxed), 1);
        assert_eq!(stats.attempts.load(Ordering::Relaxed), 3);
        assert_eq!(stats.retried.load(Ordering::Relaxed), 1);
        assert_eq!(stats.exhausted.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn rate_limited_post_is_retried_too() {
        // 429 means the server did no work, so even a create is safe to resend.
        let (mut svc, log) = harness(vec![Step::Reply(429), Step::Reply(201)], policy());
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::POST, "/api/v1/namespaces", "{}"))
            .await
            .unwrap();
        assert_eq!(resp.status(), 201);
        assert_eq!(log.lock().unwrap().methods.len(), 2);
    }

    #[tokio::test]
    async fn unavailable_post_is_not_retried() {
        let (mut svc, log) = harness(vec![Step::Reply(503)], policy());
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::POST, "/api/v1/namespaces", "{}"))
            .await
            .unwrap();
        assert_eq!(resp.status(), 503);
        assert_eq!(log.lock().unwrap().methods.len(), 1);
    }

    #[tokio::test]
    async fn unavailable_patch_is_retried_with_the_same_body() {
        let (mut svc, log) = harness(
            vec![Step::Reply(503), Step::Reply(500), Step::Reply(200)],
            policy(),
        );
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(
                Method::PATCH,
                "/apis/apps/v1/namespaces/x/deployments/y?fieldManager=kix",
                "{\"kind\":\"Deployment\"}",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        let seen = log.lock().unwrap();
        assert_eq!(seen.methods.len(), 3);
        for body in &seen.bodies {
            assert_eq!(body.as_ref(), b"{\"kind\":\"Deployment\"}");
        }
    }

    #[tokio::test]
    async fn a_dry_run_500_is_returned_at_once() {
        let (mut svc, log) = harness(vec![Step::Reply(500), Step::Reply(200)], policy());
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(
                Method::PATCH,
                "/apis/postgresql.cnpg.io/v1/namespaces/x/clusters/y?dryRun=All&fieldManager=kix",
                "{}",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), 500);
        assert_eq!(log.lock().unwrap().methods.len(), 1);
    }

    #[tokio::test]
    async fn gives_up_after_max_attempts_and_returns_the_last_response() {
        let mut p = policy();
        p.max_attempts = 3;
        let (mut svc, log) = harness(
            vec![Step::Reply(429), Step::Reply(429), Step::Reply(429)],
            p,
        );
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::GET, "/api/v1/pods", ""))
            .await
            .unwrap();
        // The caller sees the real 429, so kube turns it into the same
        // ApiError it would have produced with no retries.
        assert_eq!(resp.status(), 429);
        assert_eq!(log.lock().unwrap().methods.len(), 3);
        assert_eq!(svc.stats().exhausted.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn retry_after_header_sets_the_delay() {
        let mut p = policy();
        p.retry_after_cap = Duration::from_millis(60);
        let (mut svc, _log) = harness(
            vec![Step::ReplyWith(429, "retry-after", "1"), Step::Reply(200)],
            p,
        );
        let started = Instant::now();
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::GET, "/api/v1/pods", ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        // The 1s Retry-After is capped to 60ms.
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(60), "waited {waited:?}");
        assert!(waited < Duration::from_millis(900), "waited {waited:?}");
    }

    #[tokio::test]
    async fn transport_error_on_get_is_retried() {
        let (mut svc, log) = harness(
            vec![Step::Fail("connection reset"), Step::Reply(200)],
            policy(),
        );
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::GET, "/api/v1/pods", ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(log.lock().unwrap().methods.len(), 2);
    }

    #[tokio::test]
    async fn transport_error_on_post_is_returned() {
        let (mut svc, log) = harness(vec![Step::Fail("connection reset")], policy());
        let err = expect_err(
            svc.ready()
                .await
                .unwrap()
                .call(request(Method::POST, "/api/v1/pods", "{}"))
                .await,
        );
        assert!(err.to_string().contains("connection reset"));
        assert_eq!(log.lock().unwrap().methods.len(), 1);
    }

    #[tokio::test]
    async fn per_attempt_deadline_fires_and_is_retried() {
        let mut p = policy();
        p.request_timeout = Some(Duration::from_millis(20));
        p.max_attempts = 2;
        let (mut svc, log) = harness(
            vec![Step::Hang(Duration::from_millis(200)), Step::Reply(200)],
            p,
        );
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(Method::GET, "/api/v1/pods", ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
        assert_eq!(log.lock().unwrap().methods.len(), 2);
    }

    #[tokio::test]
    async fn deadline_exhausted_returns_a_timeout_error() {
        let mut p = policy();
        p.request_timeout = Some(Duration::from_millis(10));
        p.max_attempts = 2;
        let (mut svc, _log) = harness(
            vec![
                Step::Hang(Duration::from_millis(200)),
                Step::Hang(Duration::from_millis(200)),
            ],
            p,
        );
        let err = expect_err(
            svc.ready()
                .await
                .unwrap()
                .call(request(Method::GET, "/api/v1/pods", ""))
                .await,
        );
        assert!(err.is::<RequestTimeout>(), "{err}");
        assert_eq!(
            super::super::errors::classify_service_error(err.as_ref()),
            FailureClass::Timeout
        );
    }

    #[tokio::test]
    async fn watches_get_no_deadline() {
        let mut p = policy();
        p.request_timeout = Some(Duration::from_millis(10));
        let (mut svc, _log) = harness(vec![Step::Hang(Duration::from_millis(50))], p);
        let resp = svc
            .ready()
            .await
            .unwrap()
            .call(request(
                Method::GET,
                "/api/v1/pods?watch=true&resourceVersion=1",
                "",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);
    }

    /// Ensure a request whose future is no longer polled does not block other
    /// requests. The scheduler parks apply futures in `FuturesUnordered` while
    /// awaiting rediscovery inline, so parked requests must not hold shared
    /// permits.
    #[tokio::test]
    async fn unpolled_requests_never_block_another() {
        // As many parked requests as the scheduler can have in flight.
        let parked_count = 64;
        let mut steps: Vec<Step> = (0..parked_count)
            .map(|_| Step::Hang(Duration::from_secs(3600)))
            .collect();
        steps.push(Step::Reply(200));
        let (svc, _log) = harness(steps, policy());
        let waker = futures::task::noop_waker();
        let mut cx = Context::from_waker(&waker);
        let mut parked = Vec::new();
        for i in 0..parked_count {
            let mut s = svc.clone();
            let path = format!("/apis/apiextensions.k8s.io/v1/customresourcedefinitions/crd-{i}");
            let mut fut = Box::pin(async move {
                s.ready()
                    .await
                    .unwrap()
                    .call(
                        Request::builder()
                            .method(Method::PATCH)
                            .uri(path)
                            .body(Body::from(Bytes::from_static(b"{}")))
                            .unwrap(),
                    )
                    .await
            });
            // Poll exactly once so it is dispatched, then never again.
            assert!(fut.as_mut().poll(&mut cx).is_pending());
            parked.push(fut);
        }

        let mut live = svc.clone();
        let resp = tokio::time::timeout(Duration::from_secs(2), async {
            live.ready()
                .await
                .unwrap()
                .call(request(Method::GET, "/apis", ""))
                .await
                .unwrap()
        })
        .await
        .expect("a parked request must not block a live one");
        assert_eq!(resp.status(), 200);
        drop(parked);
    }

    #[test]
    fn decide_table() {
        let p = policy();
        let headers = HeaderMap::new();
        let ok = |code| Observed::Status(StatusCode::from_u16(code).unwrap(), &headers);
        assert_eq!(
            decide(&p, true, false, ok(200), 1, Duration::ZERO),
            Verdict::Done
        );
        assert_eq!(
            decide(&p, true, false, ok(404), 1, Duration::ZERO),
            Verdict::Done
        );
        assert_eq!(
            decide(&p, true, false, ok(409), 1, Duration::ZERO),
            Verdict::Done
        );
        assert!(matches!(
            decide(&p, true, false, ok(429), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert!(matches!(
            decide(&p, false, false, ok(429), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert!(matches!(
            decide(&p, true, false, ok(503), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert_eq!(
            decide(&p, false, false, ok(503), 1, Duration::ZERO),
            Verdict::Done
        );
        assert!(matches!(
            decide(&p, true, false, ok(500), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        // A dry run keeps its retries for 429 and 503, and not for 500.
        assert_eq!(
            decide(&p, true, true, ok(500), 1, Duration::ZERO),
            Verdict::Done
        );
        assert!(matches!(
            decide(&p, true, true, ok(503), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert!(matches!(
            decide(&p, true, true, ok(429), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        // Attempt cap and budget both end the loop.
        assert_eq!(
            decide(&p, true, false, ok(429), p.max_attempts, Duration::ZERO),
            Verdict::Done
        );
        assert_eq!(decide(&p, true, false, ok(429), 1, p.budget), Verdict::Done);
        let io: BoxError = Box::new(std::io::Error::other("reset"));
        assert!(matches!(
            decide(&p, true, false, Observed::Error(&io), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert_eq!(
            decide(&p, false, false, Observed::Error(&io), 1, Duration::ZERO),
            Verdict::Done
        );
    }

    #[test]
    fn connect_timeout_needs_both_the_hyper_connect_error_and_a_timed_out_io_error() {
        // `hyper_util::client::legacy::Error` has no public constructor, so the
        // positive case is covered by live tests. Here we verify that a bare
        // `TimedOut` or `ConnectionReset` `io::Error` is not treated as a
        // connect timeout.
        let timed_out: BoxError =
            Box::new(std::io::Error::new(std::io::ErrorKind::TimedOut, "connect"));
        assert!(!is_connect_timeout(timed_out.as_ref()));
        assert!(!is_connect_error(timed_out.as_ref()));
        let reset: BoxError = Box::new(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "reset",
        ));
        assert!(!is_connect_timeout(reset.as_ref()));
        // And a plain io error on an idempotent request is still retried.
        let p = policy();
        assert!(matches!(
            decide(
                &p,
                true,
                false,
                Observed::Error(&timed_out),
                1,
                Duration::ZERO
            ),
            Verdict::Retry(_)
        ));
    }

    #[test]
    fn backoff_grows_and_caps_with_jitter_inside_the_step() {
        let p = ResiliencePolicy {
            initial_backoff: Duration::from_millis(100),
            max_backoff: Duration::from_millis(350),
            ..ResiliencePolicy::default()
        };
        for _ in 0..50 {
            let a1 = backoff(&p, 1);
            assert!(
                a1 >= Duration::from_millis(50) && a1 <= Duration::from_millis(100),
                "{a1:?}"
            );
            let a2 = backoff(&p, 2);
            assert!(
                a2 >= Duration::from_millis(100) && a2 <= Duration::from_millis(200),
                "{a2:?}"
            );
            let a9 = backoff(&p, 9);
            assert!(
                a9 >= Duration::from_millis(175) && a9 <= Duration::from_millis(350),
                "{a9:?}"
            );
        }
    }

    #[test]
    fn retry_after_parses_whole_seconds_only() {
        let mut h = HeaderMap::new();
        assert_eq!(retry_after(&h), None);
        h.insert(RETRY_AFTER, "3".parse().unwrap());
        assert_eq!(retry_after(&h), Some(Duration::from_secs(3)));
        h.insert(
            RETRY_AFTER,
            "Wed, 21 Oct 2015 07:28:00 GMT".parse().unwrap(),
        );
        assert_eq!(retry_after(&h), None);
    }

    #[test]
    fn watch_and_idempotence_detection() {
        assert!(is_watch_uri(&"/api/v1/pods?watch=true".parse().unwrap()));
        assert!(is_watch_uri(
            &"/api/v1/pods?resourceVersion=3&watch=1".parse().unwrap()
        ));
        assert!(!is_watch_uri(
            &"/api/v1/pods?labelSelector=watch%3Dtrue".parse().unwrap()
        ));
        assert!(!is_watch_uri(&"/api/v1/pods".parse().unwrap()));
        assert!(is_dry_run_uri(
            &"/api/v1/namespaces/x/services/y?dryRun=All&fieldManager=kix"
                .parse()
                .unwrap()
        ));
        assert!(!is_dry_run_uri(
            &"/api/v1/namespaces/x/services/y?fieldManager=kix"
                .parse()
                .unwrap()
        ));
        assert!(is_idempotent(&Method::GET));
        assert!(is_idempotent(&Method::PATCH));
        assert!(is_idempotent(&Method::DELETE));
        assert!(!is_idempotent(&Method::POST));
    }

    #[test]
    fn env_overrides() {
        // Run all environment-variable cases in one test to avoid races.
        unsafe {
            std::env::set_var(RETRY_ATTEMPTS_ENV, "1");
            std::env::set_var(REQUEST_TIMEOUT_ENV, "0");
            std::env::set_var(CONNECT_TIMEOUT_ENV, "7");
            std::env::set_var(PREFLIGHT_ENV, "0");
        }
        let p = ResiliencePolicy::from_env();
        assert_eq!(p.max_attempts, 1);
        assert_eq!(p.request_timeout, None);
        assert_eq!(p.connect_timeout, Duration::from_secs(7));
        assert!(!p.preflight);
        unsafe {
            std::env::set_var(RETRY_ATTEMPTS_ENV, "many");
            std::env::remove_var(REQUEST_TIMEOUT_ENV);
            std::env::remove_var(CONNECT_TIMEOUT_ENV);
            std::env::remove_var(PREFLIGHT_ENV);
        }
        let p = ResiliencePolicy::from_env();
        assert_eq!(p.max_attempts, ResiliencePolicy::default().max_attempts);
        assert!(p.preflight);
        unsafe {
            std::env::remove_var(RETRY_ATTEMPTS_ENV);
        }
    }

    /// Start a localhost TCP listener that stands in for an API server.
    ///
    /// When `reply` is `None`, the listener accepts connections and never
    /// writes back, testing the case where the TCP handshake succeeds and the
    /// server then hangs.
    async fn fake_apiserver(reply: Option<&'static [u8]>) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            // Keep accepted sockets open so the peer sees silence rather than EOF.
            let mut held = Vec::new();
            while let Ok((mut sock, _)) = listener.accept().await {
                if let Some(bytes) = reply {
                    // Reply only once the request head has arrived. hyper
                    // refuses a response that comes before its request.
                    let mut head = Vec::new();
                    let mut buf = [0u8; 1024];
                    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                        match sock.read(&mut buf).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => head.extend_from_slice(&buf[..n]),
                        }
                    }
                    let _ = sock.write_all(bytes).await;
                    let _ = sock.flush().await;
                }
                held.push(sock);
            }
        });
        format!("http://{addr}")
    }

    /// Build a client for `endpoint` using the default resilience policy.
    async fn client_for(endpoint: &str) -> Client {
        let config = Config::new(endpoint.parse().unwrap());
        build_client(config, ResiliencePolicy::default())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn probe_gives_up_on_a_silent_endpoint() {
        let endpoint = fake_apiserver(None).await;
        let client = client_for(&endpoint).await;

        let started = tokio::time::Instant::now();
        let err = probe_apiserver(&client, &endpoint, Duration::from_millis(300))
            .await
            .expect_err("a silent endpoint must not pass the probe");

        assert!(
            matches!(err, FetchError::Unreachable { .. }),
            "expected Unreachable, got {err:?}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "probe must fail on its own deadline, not the transport's"
        );
        assert!(err.to_string().contains(&endpoint), "{err}");
    }

    #[tokio::test]
    async fn probe_passes_when_the_endpoint_answers_at_all() {
        // A 403 on /version still proves the API server is reachable.
        let endpoint = fake_apiserver(Some(
            b"HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 62\r\n\r\n\
              {\"kind\":\"Status\",\"status\":\"Failure\",\"code\":403,\"message\":\"no\"}",
        ))
        .await;
        let client = client_for(&endpoint).await;

        probe_apiserver(&client, &endpoint, Duration::from_secs(5))
            .await
            .expect("an endpoint that responds must pass the probe");
    }

    #[tokio::test]
    async fn probe_reports_a_refused_connection() {
        // Bind and immediately drop the listener to get a closed port.
        let endpoint = {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            format!("http://{}", listener.local_addr().unwrap())
        };
        let client = client_for(&endpoint).await;

        let err = probe_apiserver(&client, &endpoint, Duration::from_secs(5))
            .await
            .expect_err("a closed port must not pass the probe");

        assert!(
            matches!(err, FetchError::ConnectFailed { .. }),
            "expected ConnectFailed, got {err:?}"
        );
        assert!(err.to_string().contains(&endpoint), "{err}");
    }

    #[tokio::test]
    async fn probe_reports_a_refused_connection_without_retrying() {
        // The `FirstContact` marker skips the retry policy on a refused port.
        let endpoint = {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            format!("http://{}", listener.local_addr().unwrap())
        };
        let client = client_for(&endpoint).await;

        let started = tokio::time::Instant::now();
        probe_apiserver(&client, &endpoint, Duration::from_secs(30))
            .await
            .expect_err("a closed port must not pass the probe");

        assert!(
            started.elapsed() < Duration::from_secs(5),
            "first contact must not spend the retry budget: took {:?}",
            started.elapsed()
        );
    }

    #[tokio::test]
    async fn the_client_asks_for_gzip_and_decodes_it() {
        use std::io::Write as _;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let body = br#"{"kind":"ConfigMapList","items":[]}"#;
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(body).unwrap();
        let gzipped = encoder.finish().unwrap();

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let mut head = Vec::new();
            let mut buf = [0u8; 1024];
            while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = sock.read(&mut buf).await.unwrap();
                assert!(n > 0, "the client closed before sending a request");
                head.extend_from_slice(&buf[..n]);
            }
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                 Content-Encoding: gzip\r\nContent-Length: {}\r\n\r\n",
                gzipped.len()
            );
            sock.write_all(reply.as_bytes()).await.unwrap();
            sock.write_all(&gzipped).await.unwrap();
            sock.flush().await.unwrap();
            String::from_utf8(head).unwrap().to_ascii_lowercase()
        });

        let client = client_for(&endpoint).await;
        let request = http::Request::get("/api/v1/configmaps")
            .body(Vec::new())
            .unwrap();
        let text = client.request_text(request).await.unwrap();
        let head = server.await.unwrap();

        assert!(
            head.lines()
                .any(|l| l.starts_with("accept-encoding:") && l.contains("gzip")),
            "the request must ask for gzip:\n{head}"
        );
        assert_eq!(text.as_bytes(), body);
    }

    #[test]
    fn the_probe_deadline_does_not_tie_with_the_transports() {
        // Two deadlines of the same length would race for the error message.
        assert!(
            PROBE_GRACE > Duration::ZERO,
            "the transport must win the connect race, not tie it"
        );
    }
}
