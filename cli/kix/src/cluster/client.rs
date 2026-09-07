//! The apiserver transport policy: retries, deadlines and a concurrency
//! cap, applied once at the client so every call site inherits them.
//!
//! kube's `Client` is a tower service. [`build_client`] wraps the stack kube
//! builds from a `Config` in one more layer, [`ResilienceLayer`], and that
//! layer owns three things nothing else in the tree should own:
//!
//! - **Retries.** 429 is retried for every method: the server refused the
//!   request before doing any work, and it tells us how long to wait. 5xx
//!   and connection failures are retried for idempotent methods only (GET,
//!   HEAD, DELETE, PUT, PATCH; server-side apply is a PATCH). A POST is
//!   retried only when the connection never opened. Backoff is exponential
//!   with jitter, capped, under a total time budget, and a `Retry-After`
//!   header wins over the computed delay.
//! - **Deadlines.** A connect timeout on the transport, and a per-attempt
//!   deadline for every request that is not a watch. Watches are long-lived
//!   by design and keep kube's own idle read timeout.
//!
//! Two things this layer deliberately does not do.
//!
//! - **Cap requests in flight.** The first version held a semaphore permit
//!   for the duration of each request. That deadlocked `kix deploy`: the
//!   scheduler of the day drove its apply futures from a `FuturesUnordered`
//!   in one task, and after a CRD apply it awaited API rediscovery inline,
//!   without polling those futures. Sixteen CRD applies held every permit
//!   while parked, rediscovery waited for a permit, and nothing moved. Not
//!   even the per-attempt deadline fired, because a future nobody polls
//!   cannot time out. The scheduler now spawns its work (doc 134), but the
//!   rule stands: a permit that lives inside a future is only safe when
//!   every owner keeps polling, and a transport layer cannot know its
//!   callers.
//!   Burst control belongs where the burst is made: the managed sweep in
//!   [`super::fetch`] bounds its own parallel LISTs, on spawned tasks the
//!   runtime always polls.
//! - **Turn a failure into an empty result.** When the budget is spent the
//!   last response or error is returned as is, and kube maps it to the same
//!   `kube::Error` the caller would have seen with no retries at all.
//!   Callers decide what a failure means; see [`super::errors`].
//!
//! Every knob has an environment override for debugging (`KIX_RETRY_ATTEMPTS`,
//! `KIX_REQUEST_TIMEOUT`, `KIX_CONNECT_TIMEOUT`); see
//! [`ResiliencePolicy::from_env`].

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
};
use tower::{BoxError, Layer, Service, ServiceExt, buffer::Buffer};

use super::errors::{FailureClass, classify_status, error_chain_find};

/// The knobs. Defaults are sized for a real cluster mid-incident: an
/// apiserver restart, a webhook pod rolling, a control-plane node reboot.
#[derive(Debug, Clone)]
pub struct ResiliencePolicy {
    /// Total attempts per request, including the first. `1` disables retries.
    ///
    /// Sized to outlast a webhook controller restart: seven attempts with
    /// the default backoff span roughly twenty seconds before jitter, which
    /// covers JVM-cold-start webhooks like the stackgres operator. That
    /// number used to live in `apply.rs` as a per-patch retry loop.
    pub max_attempts: usize,
    /// First backoff. Doubles each attempt up to `max_backoff`.
    pub initial_backoff: Duration,
    /// Cap on the computed backoff.
    pub max_backoff: Duration,
    /// Cap on a `Retry-After` the server asks for. Longer waits are cut to
    /// this; a server asking for minutes is a server we should stop
    /// waiting on and tell the user about.
    pub retry_after_cap: Duration,
    /// Total wall-clock budget across all attempts of one request. Once
    /// spent, the last outcome is returned.
    pub budget: Duration,
    /// Per-attempt deadline for requests that are not watches. `None`
    /// leaves only kube's own idle read timeout.
    pub request_timeout: Option<Duration>,
    /// TCP connect timeout, applied on kube's connector.
    pub connect_timeout: Duration,
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
        }
    }
}

/// Env var: total attempts per request (`1` disables retries).
pub const RETRY_ATTEMPTS_ENV: &str = "KIX_RETRY_ATTEMPTS";
/// Env var: per-attempt deadline in whole seconds (`0` = none).
pub const REQUEST_TIMEOUT_ENV: &str = "KIX_REQUEST_TIMEOUT";
/// Env var: TCP connect timeout in whole seconds.
pub const CONNECT_TIMEOUT_ENV: &str = "KIX_CONNECT_TIMEOUT";

impl ResiliencePolicy {
    /// The defaults with environment overrides applied. Unparseable values
    /// are ignored with a warning rather than failing the command.
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
        policy
    }
}

/// Read a whole-number environment variable, warning on garbage.
pub fn env_number(name: &str) -> Option<u64> {
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
/// operator. Prefer it over `Client::try_from(config)`.
pub async fn build_client(
    mut config: Config,
    policy: ResiliencePolicy,
) -> Result<Client, kube::Error> {
    config.connect_timeout = Some(policy.connect_timeout);
    let builder = ClientBuilder::try_from(config)?;
    Ok(builder.with_layer(&ResilienceLayer::new(policy)).build())
}

/// Counters the layer keeps. Read by tests; a future `-v` summary can print them.
#[derive(Debug, Default)]
pub struct Stats {
    /// Requests that entered the layer.
    pub requests: AtomicU64,
    /// Attempts sent to the inner service (>= requests).
    pub attempts: AtomicU64,
    /// Requests that were retried at least once.
    pub retried: AtomicU64,
    /// Requests returned after the budget or attempt cap was spent.
    pub exhausted: AtomicU64,
}

impl Stats {
    /// Attempts beyond the first, summed over all requests.
    pub fn retries(&self) -> u64 {
        self.attempts.load(Ordering::Relaxed) - self.requests.load(Ordering::Relaxed)
    }
}

/// The tower layer. Wraps the inner service in a `Buffer` (so the retry
/// future can own a handle to it) and then in [`Resilience`].
#[derive(Clone)]
pub struct ResilienceLayer {
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

    pub fn stats(&self) -> Arc<Stats> {
        self.stats.clone()
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

/// The service. Generic so tests can wrap a fake without the `Buffer`.
#[derive(Clone)]
pub struct Resilience<S> {
    inner: S,
    policy: Arc<ResiliencePolicy>,
    stats: Arc<Stats>,
}

impl<S> Resilience<S> {
    /// Wrap `inner` with fresh counters.
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

    pub fn stats(&self) -> Arc<Stats> {
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
        // Standard tower idiom: the readiness we just polled belongs to
        // `self.inner`, so move that one into the future and keep a clone.
        let clone = self.inner.clone();
        let inner = std::mem::replace(&mut self.inner, clone);
        let policy = self.policy.clone();
        let stats = self.stats.clone();
        Box::pin(run(inner, req, policy, stats))
    }
}

/// The error the per-attempt deadline produces. Classified as
/// [`FailureClass::Timeout`] by [`super::errors`].
#[derive(Debug)]
pub struct RequestTimeout(pub Duration);

impl std::fmt::Display for RequestTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no response from the apiserver within {:?}", self.0)
    }
}

impl std::error::Error for RequestTimeout {}

/// The parts of a request we need to rebuild it for another attempt.
/// `http::request::Parts` is not `Clone` (extensions), so the fields that
/// matter are copied out once.
struct RequestShape {
    method: Method,
    uri: Uri,
    version: Version,
    headers: HeaderMap,
    is_watch: bool,
    idempotent: bool,
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

/// Is this a watch request? Kube encodes it as `watch=true` in the query.
pub fn is_watch_uri(uri: &Uri) -> bool {
    uri.query().is_some_and(|q| {
        q.split('&')
            .any(|pair| pair == "watch=true" || pair == "watch=1")
    })
}

/// Can this method be repeated without changing the outcome?
///
/// Everything kix sends is idempotent except POST. Server-side apply is a
/// PATCH, and a repeated apply of the same manifest is a no-op.
pub fn is_idempotent(method: &Method) -> bool {
    matches!(
        *method,
        Method::GET | Method::HEAD | Method::OPTIONS | Method::DELETE | Method::PUT | Method::PATCH
    )
}

/// What one attempt produced, seen through the retry policy's eyes.
pub enum Observed<'a> {
    /// The server answered.
    Status(StatusCode, &'a HeaderMap),
    /// The connection failed, or the deadline expired.
    Error(&'a BoxError),
}

/// What to do after an attempt.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Return this outcome to the caller.
    Done,
    /// Sleep this long, then send the request again.
    Retry(Duration),
}

/// The pure decision. `attempt` counts from 1; `elapsed` is since the first
/// attempt started.
pub fn decide(
    policy: &ResiliencePolicy,
    shape_idempotent: bool,
    observed: Observed<'_>,
    attempt: usize,
    elapsed: Duration,
) -> Verdict {
    let retryable = match &observed {
        Observed::Status(status, _) => match classify_status(status.as_u16()) {
            FailureClass::RateLimited => true,
            FailureClass::Unavailable | FailureClass::ServerError => shape_idempotent,
            _ => false,
        },
        // A connect that timed out is a black hole (stale server address,
        // tailnet down, routing). Waiting the whole budget on it would turn
        // a 15-second connect timeout into a minute of silence; the user
        // needs the error, not persistence. A refused or reset connection
        // is different: that is a process restarting, and retrying is what
        // gets a deploy through a control-plane node reboot.
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

/// Exponential backoff with equal jitter: half the step is fixed, the other
/// half random, so consecutive attempts spread out without collapsing to
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
        rand::Rng::gen_range(&mut rand::thread_rng(), 0..=half.as_millis() as u64)
    };
    half + Duration::from_millis(jitter_ms)
}

/// Parse a `Retry-After` header given in whole seconds. HTTP-date forms are
/// ignored; the apiserver never sends them.
pub fn retry_after(headers: &HeaderMap) -> Option<Duration> {
    headers
        .get(RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
}

/// Did the request fail before the connection opened? Such a request never
/// reached the server, so even a POST is safe to send again.
pub fn is_connect_error(err: &(dyn std::error::Error + 'static)) -> bool {
    error_chain_find::<hyper_util::client::legacy::Error>(err).is_some_and(|e| e.is_connect())
}

/// Did the connect phase time out (as opposed to being refused or reset)?
/// kube's connector reports this as an `io::Error` of kind `TimedOut`
/// beneath the hyper connect error.
pub fn is_connect_timeout(err: &(dyn std::error::Error + 'static)) -> bool {
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
        match decide(
            &policy,
            shape.idempotent,
            observed,
            attempt,
            started.elapsed(),
        ) {
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
                tracing::warn!(
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
    match (shape.is_watch, policy.request_timeout) {
        (false, Some(deadline)) => match tokio::time::timeout(deadline, call).await {
            Ok(result) => result.map_err(Into::into),
            Err(_) => Err(Box::new(RequestTimeout(deadline)) as BoxError),
        },
        _ => call.await.map_err(Into::into),
    }
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

    /// `Result::unwrap_err` needs `T: Debug`, and a boxed body is not.
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
        // Asked for 1s, capped to 60ms: longer than the 2ms backoff, shorter
        // than the header.
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

    /// Regression for the deploy deadlock: a request whose future its owner
    /// stops polling must not hold anything another request needs. The
    /// scheduler parks its apply futures in a `FuturesUnordered` while it
    /// awaits rediscovery inline; with a shared limiter, sixteen parked
    /// applies starved the rediscovery of permits and the deploy hung with
    /// every thread idle.
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
        assert_eq!(decide(&p, true, ok(200), 1, Duration::ZERO), Verdict::Done);
        assert_eq!(decide(&p, true, ok(404), 1, Duration::ZERO), Verdict::Done);
        assert_eq!(decide(&p, true, ok(409), 1, Duration::ZERO), Verdict::Done);
        assert!(matches!(
            decide(&p, true, ok(429), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert!(matches!(
            decide(&p, false, ok(429), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert!(matches!(
            decide(&p, true, ok(503), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert_eq!(decide(&p, false, ok(503), 1, Duration::ZERO), Verdict::Done);
        assert!(matches!(
            decide(&p, true, ok(500), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        // Attempt cap and budget both end the loop.
        assert_eq!(
            decide(&p, true, ok(429), p.max_attempts, Duration::ZERO),
            Verdict::Done
        );
        assert_eq!(decide(&p, true, ok(429), 1, p.budget), Verdict::Done);
        let io: BoxError = Box::new(std::io::Error::other("reset"));
        assert!(matches!(
            decide(&p, true, Observed::Error(&io), 1, Duration::ZERO),
            Verdict::Retry(_)
        ));
        assert_eq!(
            decide(&p, false, Observed::Error(&io), 1, Duration::ZERO),
            Verdict::Done
        );
    }

    #[test]
    fn connect_timeout_needs_both_the_hyper_connect_error_and_a_timed_out_io_error() {
        // hyper_util's legacy `Error` has no public constructor, so the
        // positive case is covered live (a black-holed server address fails
        // in one connect timeout). The negative cases are what a unit test
        // can pin: a bare timed-out io error is not a connect timeout, and
        // neither is a reset.
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
            decide(&p, true, Observed::Error(&timed_out), 1, Duration::ZERO),
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
        assert!(is_idempotent(&Method::GET));
        assert!(is_idempotent(&Method::PATCH));
        assert!(is_idempotent(&Method::DELETE));
        assert!(!is_idempotent(&Method::POST));
    }

    #[test]
    fn env_overrides() {
        // Serialised through the env: run the cases in one test.
        unsafe {
            std::env::set_var(RETRY_ATTEMPTS_ENV, "1");
            std::env::set_var(REQUEST_TIMEOUT_ENV, "0");
            std::env::set_var(CONNECT_TIMEOUT_ENV, "7");
        }
        let p = ResiliencePolicy::from_env();
        assert_eq!(p.max_attempts, 1);
        assert_eq!(p.request_timeout, None);
        assert_eq!(p.connect_timeout, Duration::from_secs(7));
        unsafe {
            std::env::set_var(RETRY_ATTEMPTS_ENV, "many");
            std::env::remove_var(REQUEST_TIMEOUT_ENV);
            std::env::remove_var(CONNECT_TIMEOUT_ENV);
        }
        let p = ResiliencePolicy::from_env();
        assert_eq!(p.max_attempts, ResiliencePolicy::default().max_attempts);
        unsafe {
            std::env::remove_var(RETRY_ATTEMPTS_ENV);
        }
    }
}
