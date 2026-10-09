//! Live cluster resource fetching.
//!
//! Uses `kube` discovery to enumerate API resources, then parallel LIST
//! calls with label selectors to fetch kix-managed resources.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::Duration;

use super::activation;
use super::client::{ResiliencePolicy, build_client, mark_first_contact, preflight_enabled};
use super::errors::{FailureClass, classify};
use super::tenancy::{self, Tenancy};
use crate::manifest::keys;
use crate::manifest::lifecycle::never_pruned;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    Config,
    api::{Api, DynamicObject, ListParams},
    client::Client,
    config::{KubeConfigOptions, Kubeconfig},
    discovery::{ApiResource, Scope},
};
use thiserror::Error;
use tokio::task::JoinSet;

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
        super::errors::describe(source)
    )]
    ConnectFailed {
        endpoint: String,
        #[source]
        source: kube::Error,
    },

    #[error("could not discover the resource types supported by the Kubernetes API: {}", super::errors::describe(.0))]
    DiscoveryError(#[source] kube::Error),

    /// `/apis` kept listing group versions that answered 404 for
    /// [`DISCOVERY_SETTLE`]. `missing` holds their paths.
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

    #[error("failed to list {resource}: {}", super::errors::describe(source))]
    ListError {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error("failed to read {resource}: {}", super::errors::describe(source))]
    GetError {
        resource: String,
        #[source]
        source: kube::Error,
    },

    #[error("{0}")]
    RecordsError(#[source] activation::RecordsError),
}

/// The managed-by label value that kix sets on all resources.
pub const MANAGED_BY_LABEL: &str = "app.kubernetes.io/managed-by=kix";

/// Fully qualified resource name for logging (e.g. "pods" or "deployments.apps").
fn resource_fqn(ar: &ApiResource) -> String {
    if ar.group.is_empty() {
        ar.plural.clone()
    } else {
        format!("{}.{}", ar.plural, ar.group)
    }
}

/// Create a kube client, optionally targeting a specific context.
///
/// The client carries the transport policy from [`super::client`]: retries
/// with backoff and per-request deadlines. Every command and the operator
/// build their client here.
///
/// Before returning, the client has exchanged one request with the
/// apiserver, so every caller past this point is talking to an endpoint that
/// answers. See [`probe_apiserver`] for why that matters.
pub async fn make_client(context: Option<&str>) -> Result<Client, FetchError> {
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
        None => Config::infer()
            .await
            .map_err(|e| FetchError::ClientError(Box::new(e)))?,
    };

    let policy = ResiliencePolicy::from_env();
    let endpoint = config.cluster_url.to_string();
    let deadline = policy.connect_timeout + PROBE_GRACE;

    let client = build_client(config, policy)
        .await
        .map_err(|e| FetchError::ClientError(Box::new(e)))?;

    if preflight_enabled() {
        probe_apiserver(&client, &endpoint, deadline).await?;
    }
    Ok(client)
}

/// How much slack the probe's deadline gets over the transport's
/// `connect_timeout`.
///
/// The two bound different things and must not race. A connect that never
/// completes is the transport's to report, because it knows the cause
/// ("tcp connect error", "deadline has elapsed") where the probe knows only
/// that time passed; the probe adds the endpoint on the way out. What is
/// left over for the probe's own deadline is the case the transport cannot
/// see at all: a connect that succeeded, followed by silence.
const PROBE_GRACE: Duration = Duration::from_secs(5);

/// Confirm the apiserver answers at all, within `deadline`.
///
/// `Client::try_from` never touches the network, so without this the first
/// real request carries the cost of an unreachable endpoint and the "failed
/// to connect to cluster" message at every call site is dead code: no error
/// is ever produced for it to print, because nothing has tried to connect
/// (kixpkgs#36).
///
/// Two failure shapes, and only one of them is a connect problem:
///
/// - The connect never completes or is refused. The transport's own
///   `connect_timeout` bounds it, and the probe's job is to add the endpoint
///   to the error, where kube alone yields an opaque
///   `ServiceError: client error (Connect)`.
/// - The connect completes and the endpoint then says nothing. No connect
///   timeout can ever fire on this one, because the connect succeeded. With
///   HTTPS the TLS handshake usually turns this into the first shape, but a
///   load balancer that terminates TLS in front of a wedged apiserver does
///   not. Only the probe's own deadline bounds it.
///
/// Only transport failures count as unreachable. *Any* HTTP response, 401
/// and 403 and 404 included, proves the endpoint is alive, so the probe
/// passes and the real call gets to report the real error. That rule is what
/// keeps the probe from becoming a new failure mode of its own on a cluster
/// where the account cannot read `/version`.
async fn probe_apiserver(
    client: &Client,
    endpoint: &str,
    deadline: Duration,
) -> Result<(), FetchError> {
    // `Client::apiserver_version()` would do, but it gives us no way to mark
    // the request, so this is that call with the marker added. The response
    // is `/version`'s, and the connection it opens is pooled for the real
    // work that follows.
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
            // Alive, just not willing or able to serve /version to us.
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

/// Did an HTTP response come back? Separates "the endpoint is alive but said
/// no" from "we never reached it".
fn server_responded(e: &kube::Error) -> bool {
    matches!(
        e,
        kube::Error::Api(_) | kube::Error::SerdeError(_) | kube::Error::FromUtf8(_)
    )
}

/// How long [`discover_resources`] keeps asking about group versions that
/// `/apis` lists but that answer 404. On fresh kind clusters, a walk made
/// just after new CRDs were Established has got a plain-text
/// `404 page not found` for a listed group version, and a rerun of the
/// same deploy got past that point.
pub const DISCOVERY_SETTLE: Duration = Duration::from_secs(30);
const DISCOVERY_BACKOFF_START: Duration = Duration::from_millis(250);
const DISCOVERY_BACKOFF_MAX: Duration = Duration::from_secs(2);

/// Run API discovery and return all listable resources with their scope.
///
/// The core group comes first, then the groups in the order `/apis` lists
/// them, so a kind lookup that takes the first match is deterministic.
///
/// A listed group version that answers 404 makes the whole walk run again,
/// with backoff, until every listed group version answers or
/// [`DISCOVERY_SETTLE`] has passed ([`FetchError::DiscoveryUnsettled`]).
/// The walk is repeated from `/apis` because a group that is going away
/// stops being listed, and one that is arriving starts being served. Any
/// other failure is returned at once: the transport has already retried it.
pub async fn discover_resources(client: &Client) -> Result<Vec<(ApiResource, Scope)>, FetchError> {
    settled_discovery(client, None).await
}

/// [`discover_resources`] of the named API groups alone. A group the
/// cluster does not list is left out, and nothing else is asked for, so a
/// group version of some other API that is down cannot fail it.
pub async fn discover_groups(
    client: &Client,
    groups: &[&str],
) -> Result<Vec<(ApiResource, Scope)>, FetchError> {
    settled_discovery(client, Some(groups)).await
}

/// Walk `groups` (every group, the core one first, when `None`) until no
/// listed group version answers 404, as [`discover_resources`] describes.
async fn settled_discovery(
    client: &Client,
    groups: Option<&[&str]>,
) -> Result<Vec<(ApiResource, Scope)>, FetchError> {
    let start = tokio::time::Instant::now();
    let mut delay = DISCOVERY_BACKOFF_START;
    loop {
        let pass = discovery_pass(client, groups).await?;
        if pass.missing.is_empty() {
            tracing::debug!(count = pass.resources.len(), "API resources discovered");
            return Ok(pass.resources);
        }
        let waited = start.elapsed();
        if waited >= DISCOVERY_SETTLE {
            return Err(FetchError::DiscoveryUnsettled {
                missing: pass.missing,
                waited,
            });
        }
        tracing::debug!(
            missing = ?pass.missing,
            "listed group versions answered 404, discovering again"
        );
        tokio::time::sleep(delay.min(DISCOVERY_SETTLE - waited)).await;
        delay = (delay * 2).min(DISCOVERY_BACKOFF_MAX);
    }
}

/// One discovery walk, for a caller that retries on its own: a listed group
/// version that answers 404 is left out, named in `missing` and logged at
/// debug, with no wait. Any other failure is returned.
pub async fn discover_resources_once(client: &Client) -> Result<DiscoveryPass, FetchError> {
    let pass = discovery_pass(client, None).await?;
    if !pass.missing.is_empty() {
        tracing::debug!(missing = ?pass.missing, "group versions answered 404");
    }
    Ok(pass)
}

/// One discovery walk. `missing` holds the path of every listed group
/// version that answered 404; their resources are absent from `resources`,
/// and a kind served there may appear at another version of its group.
#[derive(Debug, Default)]
pub struct DiscoveryPass {
    pub resources: Vec<(ApiResource, Scope)>,
    pub missing: Vec<String>,
}

/// One walk of `only` (every group, the core one first, when `None`).
async fn discovery_pass(
    client: &Client,
    only: Option<&[&str]>,
) -> Result<DiscoveryPass, FetchError> {
    let mut pass = DiscoveryPass::default();
    if only.is_none() {
        walk_core(client, &mut pass).await?;
    }
    let groups = client
        .list_api_groups()
        .await
        .map_err(FetchError::DiscoveryError)?;
    for g in groups.groups {
        if only.is_none_or(|only| only.contains(&g.name.as_str())) {
            walk_api_group(client, g, &mut pass).await?;
        }
    }
    Ok(pass)
}

async fn walk_core(client: &Client, pass: &mut DiscoveryPass) -> Result<(), FetchError> {
    let core = client
        .list_core_api_versions()
        .await
        .map_err(FetchError::DiscoveryError)?;
    walk_group(client, "", Some("v1"), core.versions, pass).await
}

async fn walk_api_group(
    client: &Client,
    g: k8s_openapi::apimachinery::pkg::apis::meta::v1::APIGroup,
    pass: &mut DiscoveryPass,
) -> Result<(), FetchError> {
    let versions = g.versions.into_iter().map(|v| v.version).collect();
    let preferred = g.preferred_version.map(|v| v.version);
    walk_group(client, &g.name, preferred.as_deref(), versions, pass).await
}

/// Fetch each version of one group and add its listable resources to
/// `pass`, recording versions that answer 404 in `pass.missing`.
///
/// Versions are walked preferred first, then newest first by Kubernetes
/// version priority, and the first ApiResource seen per kind wins. Every
/// served version is walked, not only the preferred one, because a group
/// may serve some kinds only at an older version
/// (operator.victoriametrics.com serves kinds at both v1 and v1beta1).
async fn walk_group(
    client: &Client,
    group: &str,
    preferred: Option<&str>,
    mut versions: Vec<String>,
    pass: &mut DiscoveryPass,
) -> Result<(), FetchError> {
    versions.sort_by_cached_key(|v| {
        (
            Some(v.as_str()) != preferred,
            std::cmp::Reverse(kube::core::Version::parse(v).priority()),
        )
    });
    let mut seen_kinds = HashSet::new();
    for version in versions {
        let gv = kube::core::GroupVersion::gv(group, &version);
        let ag = match kube::discovery::pinned_group(client, &gv).await {
            Ok(ag) => ag,
            Err(kube::Error::Api(r)) if r.code == 404 => {
                pass.missing.push(if group.is_empty() {
                    format!("/api/{version}")
                } else {
                    format!("/apis/{group}/{version}")
                });
                continue;
            }
            Err(e) => return Err(FetchError::DiscoveryError(e)),
        };
        for (ar, caps) in ag.versioned_resources(&version) {
            if seen_kinds.insert(ar.kind.clone()) && caps.supports_operation("list") {
                pass.resources.push((ar, caps.scope));
            }
        }
    }
    Ok(())
}

/// Discovery of one group, the targeted fetch behind refresh-on-miss: a
/// bulk walk under deploy load can transiently omit a group, and this is a
/// smaller request. `group` is "" for the core group. A version that
/// answers 404 is left out rather than failing the group, and named in
/// `missing`, so the caller gets whatever the group serves now and can ask
/// again.
pub async fn discover_group(client: &Client, group: &str) -> Result<DiscoveryPass, FetchError> {
    let mut pass = DiscoveryPass::default();
    if group.is_empty() {
        walk_core(client, &mut pass).await?;
    } else {
        let groups = client
            .list_api_groups()
            .await
            .map_err(FetchError::DiscoveryError)?;
        let Some(g) = groups.groups.into_iter().find(|g| g.name == group) else {
            return Err(FetchError::DiscoveryError(kube::Error::Discovery(
                kube::error::DiscoveryError::MissingApiGroup(group.to_string()),
            )));
        };
        walk_api_group(client, g, &mut pass).await?;
    }
    if !pass.missing.is_empty() {
        tracing::debug!(missing = ?pass.missing, "group versions answered 404");
    }
    Ok(pass)
}

/// Merge a fresh discovery walk into an existing cache, unioned by
/// (group, kind). Kubernetes' aggregated discovery document is rebuilt
/// after CRD writes and can transiently omit unrelated groups, so a refresh
/// must never *forget* kinds the cluster already proved it serves. Stale
/// entries for genuinely deleted CRDs are harmless by comparison (their
/// applies would fail anyway).
///
/// When every listed group version answered, the fresh entry wins, so a
/// kind whose preferred version changed moves to it. When the walk skipped
/// a group version (`fresh.missing`), a kind it found may be one the
/// skipped version also serves at a higher priority: the walk picks the
/// next version that answered. The cached entry then wins, and the walk
/// only adds (group, kind) keys the cache lacks, so a momentary 404 does not
/// move a kind to an older version's URL.
pub fn merge_discovery(
    existing: &[(ApiResource, Scope)],
    fresh: DiscoveryPass,
) -> Vec<(ApiResource, Scope)> {
    let key = |ar: &ApiResource| (ar.group.clone(), ar.kind.clone());
    let (mut merged, rest) = if fresh.missing.is_empty() {
        (fresh.resources, existing.to_vec())
    } else {
        (existing.to_vec(), fresh.resources)
    };
    let known: HashSet<(String, String)> = merged.iter().map(|(ar, _)| key(ar)).collect();
    merged.extend(rest.into_iter().filter(|(ar, _)| !known.contains(&key(ar))));
    merged
}

/// What the managed sweep found.
pub struct ManagedSweep {
    /// Objects kix applied: each carries `kix.run/identity-hash`.
    pub managed: Vec<DynamicObject>,
    /// Objects that carry the kix label but no identity hash and no owner.
    /// kix never applied them (someone `kubectl apply`ed a kix render, or a
    /// pre-hash kix did). `kix gc --hard` reports them; nothing deletes them
    /// unless asked.
    pub unstamped: Vec<DynamicObject>,
    /// Resource types this account may not list (403). Nothing in them is
    /// visible to kix. Callers print this so a narrower-than-cluster view is
    /// never mistaken for a complete one.
    pub forbidden: Vec<String>,
    /// Under [`SweepScope::Cluster`]: objects left out because they belong
    /// only to other Kix clusters, counted per owner (several owners are
    /// joined with ", ").
    pub foreign: BTreeMap<String, usize>,
    /// Under [`SweepScope::Cluster`], when another Kix cluster has records
    /// here: objects that name no record of any cluster, so Kix cannot tell
    /// whose they are. Left out of `managed` and `unstamped`.
    pub unattributed: Vec<DynamicObject>,
    /// Under [`SweepScope::Records`]: objects of the named cluster that name
    /// none of the given records, such as leftovers of Superseded builds.
    pub other_builds: usize,
    /// The Activation records, read after the objects. Its `cluster` is the
    /// one the scope named, and empty under [`SweepScope::All`].
    pub tenancy: Tenancy,
}

impl ManagedSweep {
    /// One line per other Kix cluster whose objects the scope left out, and
    /// one for the unattributed objects, for a command to print.
    pub fn scope_notes(&self) -> Vec<String> {
        let mut notes: Vec<String> = self
            .foreign
            .iter()
            .map(|(owner, n)| {
                let (objects, belong) = if *n == 1 {
                    ("object", "belongs")
                } else {
                    ("objects", "belong")
                };
                let clusters = if owner.contains(", ") {
                    "Kix clusters"
                } else {
                    "Kix cluster"
                };
                format!("Skipped {n} {objects} that {belong} to {clusters} {owner}.")
            })
            .collect();
        if !self.unattributed.is_empty() {
            let n = self.unattributed.len();
            let (objects, name) = if n == 1 {
                ("object", "names")
            } else {
                ("objects", "name")
            };
            notes.push(format!(
                "Skipped {n} Kix {objects} that {name} no Activation record on this cluster; \
                 another Kix cluster deploys here, so Kix cannot tell whose they are."
            ));
        }
        notes
    }
}

/// Which Kix-labelled objects a sweep returns.
#[derive(Debug, Clone, Copy)]
pub enum SweepScope<'a> {
    /// The named Kix cluster's objects, by [`attribute`]: its own and the
    /// ones it shares with other clusters. Unattributed objects count as its
    /// own only while no other Kix cluster has records here.
    Cluster(&'a str),
    /// Objects naming one of `hashes` in `kix.run/activations`: the closures
    /// of exactly those records of `cluster`, whether or not the records
    /// still exist.
    Records {
        cluster: &'a str,
        hashes: &'a HashSet<String>,
    },
    /// Every Kix-labelled object, whichever cluster deployed it.
    All,
}

/// Whose an object is, by the record hashes it names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attribution {
    /// Names a record of this cluster and none of another's.
    Ours,
    /// Names a record of this cluster and records of these other clusters.
    Shared(Vec<String>),
    /// Names records of these other clusters only.
    Foreign(Vec<String>),
    /// Names no record on the cluster: its hashes are all retired, it has no
    /// `kix.run/activations`, or it was never stamped.
    Unattributed,
}

/// Attribute a swept object to Kix clusters through the record hashes it
/// names (see [`tenancy::named_hashes`]).
pub fn attribute(obj: &DynamicObject, tenancy: &Tenancy) -> Attribution {
    let mut ours = false;
    let mut others: Vec<String> = Vec::new();
    for hash in tenancy::named_hashes(obj) {
        if tenancy.own.contains(hash) {
            ours = true;
        } else if let Some(owner) = tenancy.others.get(hash) {
            others.push(owner.clone());
        }
    }
    others.sort();
    others.dedup();
    match (ours, others.is_empty()) {
        (true, true) => Attribution::Ours,
        (true, false) => Attribution::Shared(others),
        (false, false) => Attribution::Foreign(others),
        (false, true) => Attribution::Unattributed,
    }
}

/// Narrow a whole-cluster sweep to `scope`, attributing objects through
/// `tenancy`, which must be read for the cluster `scope` names.
pub fn scope_sweep(sweep: ManagedSweep, scope: SweepScope<'_>, tenancy: Tenancy) -> ManagedSweep {
    match scope {
        SweepScope::All => ManagedSweep { tenancy, ..sweep },
        SweepScope::Records { hashes, .. } => {
            let (managed, rest) = split_by_records(sweep.managed, hashes);
            let (unstamped, _) = split_by_records(sweep.unstamped, hashes);
            let other_builds = rest
                .iter()
                .filter(|o| {
                    matches!(
                        attribute(o, &tenancy),
                        Attribution::Ours | Attribution::Shared(_)
                    )
                })
                .count();
            ManagedSweep {
                managed,
                unstamped,
                other_builds,
                tenancy,
                ..sweep
            }
        }
        SweepScope::Cluster(_) => {
            let shared_cluster = !tenancy.others.is_empty();
            let mut foreign: BTreeMap<String, usize> = BTreeMap::new();
            let mut unattributed = Vec::new();
            let mut keep = |objects: Vec<DynamicObject>| -> Vec<DynamicObject> {
                let mut kept = Vec::new();
                for obj in objects {
                    match attribute(&obj, &tenancy) {
                        Attribution::Ours | Attribution::Shared(_) => kept.push(obj),
                        Attribution::Foreign(owners) => {
                            *foreign.entry(owners.join(", ")).or_default() += 1;
                        }
                        Attribution::Unattributed if shared_cluster => unattributed.push(obj),
                        Attribution::Unattributed => kept.push(obj),
                    }
                }
                kept
            };
            let managed = keep(sweep.managed);
            let unstamped = keep(sweep.unstamped);
            ManagedSweep {
                managed,
                unstamped,
                forbidden: sweep.forbidden,
                foreign,
                unattributed,
                other_builds: 0,
                tenancy,
            }
        }
    }
}

/// Split objects into the ones naming one of `hashes` in
/// `kix.run/activations` (the closures of exactly those records) and the
/// rest.
pub fn split_by_records(
    objects: Vec<DynamicObject>,
    hashes: &HashSet<String>,
) -> (Vec<DynamicObject>, Vec<DynamicObject>) {
    objects
        .into_iter()
        .partition(|o| tenancy::named_hashes(o).any(|h| hashes.contains(h)))
}

/// Fetch every resource kix applied, in parallel: one LIST per discovered
/// kind with the `managed-by=kix` label selector, then [`partition_sweep`].
///
/// A 403 on a resource type is recorded, not fatal: the account simply
/// cannot see that kind. Use [`sweep_managed`] to read the list. Any other
/// list failure that survives the transport's retries is an error: a plan
/// built on a partial view of the cluster is wrong in ways the user cannot
/// see, so no caller gets one.
pub async fn fetch_managed_resources(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    scope: SweepScope<'_>,
) -> Result<Vec<DynamicObject>, FetchError> {
    Ok(sweep_managed(client, discovery, scope).await?.managed)
}

/// The full sweep: kix-applied objects plus the unstamped label carriers,
/// narrowed to `scope`. The LIST selects by the managed-by label alone and
/// [`scope_sweep`] filters client-side, since the compiler stamps no
/// per-cluster label on ordinary objects.
///
/// The Activation records are listed after the objects, for the reason
/// [`tenancy::read`] gives.
pub async fn sweep_managed(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    scope: SweepScope<'_>,
) -> Result<ManagedSweep, FetchError> {
    let lp = ListParams::default().labels(MANAGED_BY_LABEL);
    let listed = fetch_parallel(client, discovery, &lp).await?;
    let mut sweep = partition_sweep(listed.objects);
    sweep.forbidden = listed.forbidden;
    let cluster = match scope {
        SweepScope::Cluster(cluster) | SweepScope::Records { cluster, .. } => cluster,
        SweepScope::All => "",
    };
    let tenancy = tenancy::read(client, discovery, cluster)
        .await
        .map_err(FetchError::RecordsError)?;
    Ok(scope_sweep(sweep, scope, tenancy))
}

/// Decide what the label sweep really found.
///
/// The label only finds candidates; it does not prove kix applied an object.
/// Controllers copy labels onto what they derive: the EndpointSlice
/// controller mirrors a Service's labels, ReplicaSets and Pods carry their
/// template's labels. Proof that kix applied something is its
/// `kix.run/identity-hash` annotation, which the apply step stamps and no
/// controller copies. So:
///
/// - stamped: kix's, whatever its owner references say (`managed`);
/// - unstamped and owned: a controller child, judged through its owner and
///   dropped here;
/// - unstamped and unowned: kept apart in `unstamped` for gc to report;
/// - unstamped `Endpoints` named after a managed Service in the same
///   namespace: that Service's mirror. Endpoints are the pre-EndpointSlice
///   mirror; the endpoints controller copies the Service's labels and sets
///   no owner reference, so ownership alone cannot tell them apart. Dropped.
///
/// These rules replace the fixed list of "ephemeral" kinds, which made every
/// listed kind undeployable because the apply path used the same discovery
/// cache (kixpkgs#41).
pub fn partition_sweep(objects: Vec<DynamicObject>) -> ManagedSweep {
    let (managed, rest): (Vec<DynamicObject>, Vec<DynamicObject>) =
        objects.into_iter().partition(is_stamped);
    let managed_services: HashSet<(String, String)> = managed
        .iter()
        .filter(|o| object_kind(o) == "Service")
        .map(|o| (namespace_of(o), o.metadata.name.clone().unwrap_or_default()))
        .collect();
    let unstamped = rest
        .into_iter()
        .filter(|o| !is_owned(o))
        .filter(|o| {
            !(object_kind(o) == "Endpoints"
                && managed_services
                    .contains(&(namespace_of(o), o.metadata.name.clone().unwrap_or_default())))
        })
        .collect();
    ManagedSweep {
        managed,
        unstamped,
        forbidden: Vec::new(),
        foreign: BTreeMap::new(),
        unattributed: Vec::new(),
        other_builds: 0,
        tenancy: Tenancy::default(),
    }
}

/// Did kix's apply step stamp this object?
pub fn is_stamped(obj: &DynamicObject) -> bool {
    obj.metadata
        .annotations
        .as_ref()
        .is_some_and(|a| keys::contains_meta(a, keys::IDENTITY_HASH))
}

/// Does a controller own this object?
pub fn is_owned(obj: &DynamicObject) -> bool {
    obj.metadata
        .owner_references
        .as_ref()
        .is_some_and(|owners| !owners.is_empty())
}

fn object_kind(obj: &DynamicObject) -> &str {
    obj.data
        .get("kind")
        .and_then(serde_json::Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("")
}

fn namespace_of(obj: &DynamicObject) -> String {
    obj.metadata.namespace.clone().unwrap_or_default()
}

/// Fetch specific resources by kind/name/namespace.
///
/// Runs a GET per resource rather than LIST+filter, since we know
/// exactly what we're looking for.
pub async fn fetch_matching_resources(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    manifests: &[ResourceId],
) -> Result<Vec<DynamicObject>, FetchError> {
    // Build a lookup: lowercase kind -> (ApiResource, Scope)
    let ar_by_kind: std::collections::HashMap<String, &(ApiResource, Scope)> = discovery
        .iter()
        .map(|pair| (pair.0.kind.to_lowercase(), pair))
        .collect();

    let mut set = JoinSet::new();

    for rid in manifests {
        let kind_lower = rid.kind.to_lowercase();
        let Some(&(ar, scope)) = ar_by_kind.get(&kind_lower) else {
            tracing::warn!(kind = %rid.kind, "Kubernetes does not recognize this resource kind; skipping it");
            continue;
        };

        let api = api_for(client, ar, scope, rid);

        let name = rid.name.clone();
        let resource_id = rid.display_id();
        set.spawn(async move {
            match api.get(&name).await {
                Ok(obj) => Some(obj),
                Err(e) => {
                    tracing::debug!(resource = %resource_id, error = %e, "resource not found on cluster");
                    None
                }
            }
        });
    }

    let mut results = Vec::new();
    while let Some(join_result) = set.join_next().await {
        match join_result {
            Ok(Some(obj)) => results.push(obj),
            Ok(None) => {} // not found, already logged
            Err(e) => {
                tracing::warn!(error = %e, "a resource-fetching task stopped unexpectedly; results may be incomplete")
            }
        }
    }
    Ok(results)
}

/// An orphan candidate that another Kix cluster's current build still
/// contains, so a prune keeps it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedOrphan {
    pub rid: ResourceId,
    /// The other Kix clusters, sorted.
    pub clusters: Vec<String>,
}

impl SharedOrphan {
    /// The line a plan prints for it.
    pub fn describe(&self) -> String {
        let clusters = if self.clusters.len() == 1 {
            "Kix cluster"
        } else {
            "Kix clusters"
        };
        format!(
            "kept {}, still deployed by {clusters} {}",
            self.rid,
            self.clusters.join(", ")
        )
    }
}

/// Split orphan candidates into the ones to prune and the ones another Kix
/// cluster still deploys, judged from live objects already in hand. Kinds
/// that [`never_pruned`] protects stay with the prunable ones: the prune
/// already keeps and reports them.
pub fn split_shared_orphans(
    orphans: Vec<ResourceId>,
    live: &[DynamicObject],
    tenancy: &Tenancy,
) -> (Vec<ResourceId>, Vec<SharedOrphan>) {
    let by_id: std::collections::HashMap<ResourceId, &DynamicObject> = live
        .iter()
        .map(|o| (ResourceId::from_value(&to_manifest_value(o)), o))
        .collect();
    split_by_lookup(orphans, |rid| by_id.get(rid).copied(), tenancy)
}

fn split_by_lookup<'a>(
    orphans: Vec<ResourceId>,
    live: impl Fn(&ResourceId) -> Option<&'a DynamicObject>,
    tenancy: &Tenancy,
) -> (Vec<ResourceId>, Vec<SharedOrphan>) {
    if tenancy.others_current.is_empty() {
        return (orphans, Vec::new());
    }
    let mut prune = Vec::new();
    let mut shared = Vec::new();
    for rid in orphans {
        if never_pruned(&rid.kind) {
            prune.push(rid);
            continue;
        }
        let clusters = live(&rid)
            .map(|o| tenancy.still_deployed_by_others(o))
            .unwrap_or_default();
        if clusters.is_empty() {
            prune.push(rid);
        } else {
            shared.push(SharedOrphan { rid, clusters });
        }
    }
    (prune, shared)
}

/// [`split_shared_orphans`] for a plan made from builds: GET each orphan
/// candidate to read its `kix.run/activations`, then read the Tenancy of
/// `cluster` (after the objects, for the reason [`tenancy::read`]
/// gives).
///
/// This decides what a plan shows. The delete itself goes through
/// [`super::prune_guard::PruneGuard`], which checks again.
///
/// A candidate that is gone or whose kind is not served is prunable (the
/// delete is then a no-op). Any other GET failure is an error: a prune that
/// cannot read an object cannot tell whether another cluster still uses it.
pub async fn split_shared_orphans_live(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    orphans: Vec<ResourceId>,
    cluster: &str,
) -> Result<(Vec<ResourceId>, Vec<SharedOrphan>), FetchError> {
    if orphans.is_empty() {
        return Ok((orphans, Vec::new()));
    }
    let ar_by_kind: std::collections::HashMap<&str, &(ApiResource, Scope)> = discovery
        .iter()
        .map(|pair| (pair.0.kind.as_str(), pair))
        .collect();
    let gets = orphans
        .iter()
        .filter(|rid| !never_pruned(&rid.kind))
        .filter_map(|rid| {
            let (ar, scope) = ar_by_kind.get(rid.kind.as_str())?;
            let api = api_for(client, ar, scope, rid);
            Some(async move {
                let obj = api
                    .get_opt(&rid.name)
                    .await
                    .map_err(|source| FetchError::GetError {
                        resource: rid.display_id(),
                        source,
                    })?;
                Ok::<_, FetchError>(obj.map(|o| (rid.clone(), o)))
            })
        });
    // Keyed by the candidate's own id: an object read from `default` for a
    // candidate without a namespace must still match that candidate.
    let live: std::collections::HashMap<ResourceId, DynamicObject> =
        futures::future::try_join_all(gets)
            .await?
            .into_iter()
            .flatten()
            .collect();
    let tenancy = tenancy::read(client, discovery, cluster)
        .await
        .map_err(FetchError::RecordsError)?;
    Ok(split_by_lookup(orphans, |rid| live.get(rid), &tenancy))
}

/// The API a request about `rid` goes to. For a namespaced kind keyed
/// [`CLUSTER_SCOPED`] (its manifest names no namespace) that is `default`:
/// [`crate::cluster::apply::apply_resource`] refuses to create such an
/// object, but Kix CLIs before that check applied it there, and a prune of
/// an old build reads and deletes it there.
pub fn api_for(
    client: &Client,
    ar: &ApiResource,
    scope: &Scope,
    rid: &ResourceId,
) -> Api<DynamicObject> {
    match scope {
        Scope::Namespaced => {
            let ns = if rid.namespace == CLUSTER_SCOPED {
                "default"
            } else {
                rid.namespace.as_str()
            };
            Api::namespaced_with(client.clone(), ns, ar)
        }
        Scope::Cluster => Api::all_with(client.clone(), ar),
    }
}

/// Strip server-side fields from a DynamicObject for diffing.
///
/// Removes: uid, resourceVersion, creationTimestamp, generation,
/// selfLink, managedFields, status, last-applied-configuration annotation.
pub fn normalize_for_diff(obj: &mut DynamicObject) {
    // Top-level metadata fields
    obj.metadata.uid = None;
    obj.metadata.resource_version = None;
    obj.metadata.creation_timestamp = None;
    obj.metadata.generation = None;
    obj.metadata.managed_fields = None;

    // Remove selfLink if present in the raw data
    if let Some(data) = obj.data.as_object_mut() {
        if let Some(meta) = data.get_mut("metadata").and_then(|m| m.as_object_mut()) {
            meta.remove("selfLink");
            meta.remove("uid");
            meta.remove("resourceVersion");
            meta.remove("creationTimestamp");
            meta.remove("generation");
            meta.remove("managedFields");

            // Strip last-applied-configuration annotation
            if let Some(annotations) = meta.get_mut("annotations").and_then(|a| a.as_object_mut()) {
                annotations.remove("kubectl.kubernetes.io/last-applied-configuration");
                // Remove annotations object entirely if empty
                if annotations.is_empty() {
                    meta.remove("annotations");
                }
            }
        }

        // Remove status entirely
        data.remove("status");
    }
}

/// The kix-owned view of a live object: the live value projected onto the
/// fieldset kix's server-side apply owns, with the type
/// meta and identity that fieldsV1 never lists (`apiVersion`, `kind`,
/// `metadata.name`, `metadata.namespace`) restored.
///
/// This is what `kix diff` and `kix snapshot save` compare against a build:
/// the server's defaults (deployment strategy, probe thresholds, scheduler
/// name, ...) are owned by nobody or by a controller, so they never enter the
/// view, and kix's own bookkeeping annotations (`kix.run/activations`,
/// `kix.run/applied-hash`) are written through a separate `Update` entry, so
/// they are excluded too. Comparing this to the rendered manifest asks the
/// question a change review actually needs answered: "does what kix would
/// apply differ from what kix last applied?"
///
/// Objects without a kix `Apply` entry (adopted externally, or predating SSA)
/// fall back to the whole object with server metadata stripped.
///
/// A Secret's view holds no live value: every `data` key reads
/// [`HIDDEN_SECRET_VALUE`] (see [`redact_secret`]). Values kix applied
/// through `stringData` are absent, since the server stores them only in
/// `data` and kix's fieldset lists `stringData`.
/// [`kix_owned_manifests_against`] compares both against a build.
pub fn kix_owned_view(obj: &DynamicObject) -> serde_json::Value {
    let mut view = unredacted_view(obj);
    redact_secret(&mut view, obj, None);
    view
}

/// [`kix_owned_view`] before [`redact_secret`]. A Secret's live values are
/// still in it, so it must not leave this module.
fn unredacted_view(obj: &DynamicObject) -> serde_json::Value {
    let Some(mut view) = super::fieldsv1::kix_owned_projection(obj) else {
        let mut fallback = obj.clone();
        normalize_for_diff(&mut fallback);
        return to_manifest_value(&fallback);
    };
    if let Some(map) = view.as_object_mut() {
        for key in ["apiVersion", "kind"] {
            if let Some(v) = obj.data.get(key) {
                map.insert(key.to_string(), v.clone());
            }
        }
        let meta = map
            .entry("metadata")
            .or_insert_with(|| serde_json::json!({}));
        if let Some(meta) = meta.as_object_mut() {
            if let Some(name) = &obj.metadata.name {
                meta.insert("name".into(), serde_json::Value::String(name.clone()));
            }
            if let Some(ns) = &obj.metadata.namespace {
                meta.insert("namespace".into(), serde_json::Value::String(ns.clone()));
            }
        }
    }
    view
}

/// Stands in for a live Secret value that differs from the build's, so a
/// diff shows the key as changed without printing what the cluster holds.
pub const HIDDEN_SECRET_VALUE: &str = "(live value differs from the build, not shown)";

/// Keep every live value out of a Secret's view.
///
/// Each key under the view's `data` becomes the value `built` gives it when
/// the decoded live value equals the build's: under `data` when the build
/// declares the key there, under `stringData` when the build declares it
/// there. Every other key reads [`HIDDEN_SECRET_VALUE`], as does every key
/// when `built` is `None`.
///
/// The API server merges `stringData` into `data` and never stores it, so the
/// projection of a Secret kix applied with `stringData` lists neither field.
/// For each `stringData` key `built` declares and kix's fieldset lists, the
/// decoded live `data` value is compared the same way and the key is added
/// under `stringData`; a key whose live value is missing or is not
/// base64-encoded UTF-8 is left out. A SOPS Secret's build manifest has no
/// `stringData` (kix decrypts its values at deploy time), so none of its keys
/// are restored and a value changed out of band does not show.
///
/// The view therefore never holds a value that is not already in the build.
fn redact_secret(
    view: &mut serde_json::Value,
    obj: &DynamicObject,
    built: Option<&serde_json::Value>,
) {
    use serde_json::{Map, Value};

    if !crate::manifest::types::is_secret(&obj.data) {
        return;
    }
    let hidden = || Value::String(HIDDEN_SECRET_VALUE.into());
    let built_data = built.and_then(|b| b.get("data")).and_then(Value::as_object);
    let built_string_data = built
        .and_then(|b| b.get("stringData"))
        .and_then(Value::as_object);
    let live_data = obj.data.get("data").and_then(Value::as_object);
    let live_text = |key: &str| -> Option<String> {
        let bytes = decode_base64(live_data?.get(key)?.as_str()?)?;
        String::from_utf8(bytes).ok()
    };

    let mut string_data: Map<String, Value> = Map::new();
    let Some(map) = view.as_object_mut() else {
        return;
    };
    // The server never returns `stringData`; hide anything found there.
    if let Some(Value::Object(found)) = map.remove("stringData") {
        string_data.extend(found.into_iter().map(|(k, _)| (k, hidden())));
    }
    if let Some(Value::Object(data)) = map.get_mut("data") {
        let keys: Vec<String> = data.keys().cloned().collect();
        for key in keys {
            let live_bytes = live_data
                .and_then(|d| d.get(&key))
                .and_then(Value::as_str)
                .and_then(decode_base64);
            let from_data = built_data.and_then(|d| d.get(&key)).filter(|b| {
                let built_bytes = b.as_str().and_then(decode_base64);
                built_bytes.is_some() && built_bytes == live_bytes
            });
            if let Some(value) = from_data {
                data.insert(key, value.clone());
                continue;
            }
            let from_string_data = built_string_data
                .and_then(|d| d.get(&key))
                .filter(|b| b.as_str().is_some() && b.as_str() == live_text(&key).as_deref());
            if let Some(value) = from_string_data {
                data.remove(&key);
                string_data.insert(key, value.clone());
            } else {
                data.insert(key, hidden());
            }
        }
        if data.is_empty() {
            map.remove("data");
        }
    }

    let owned = super::fieldsv1::kix_fieldset(obj);
    let owned = owned
        .as_ref()
        .and_then(|f| f.get("f:stringData"))
        .and_then(Value::as_object);
    if let (Some(declared), Some(owned)) = (built_string_data, owned) {
        for (key, built_value) in declared {
            if !owned.contains_key(&format!("f:{key}")) {
                continue;
            }
            let Some(text) = live_text(key) else { continue };
            let value = if built_value.as_str() == Some(text.as_str()) {
                built_value.clone()
            } else {
                hidden()
            };
            string_data.insert(key.clone(), value);
        }
    }
    if !string_data.is_empty() {
        map.insert("stringData".into(), Value::Object(string_data));
    }
}

fn decode_base64(text: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(text).ok()
}

/// The kix-owned view of every object in a sweep, brought to the current
/// domain: what a build is compared against, whether the comparison runs
/// now (`kix diff`), later from a directory (`kix snapshot save`), or as
/// the previous state a deploy plans from when its store path is gone.
///
/// The domain upgrade matters on a cluster a previous Kix stamped under a
/// retired domain: without it every Kix annotation reads as a paired add
/// and remove, and an in-sync cluster reads as entirely modified.
pub fn kix_owned_manifests(
    objects: impl IntoIterator<Item = DynamicObject>,
) -> Vec<serde_json::Value> {
    objects
        .into_iter()
        .map(|obj| {
            let mut manifest = kix_owned_view(&obj);
            crate::legacy_domain::upgrade_manifest(&mut manifest);
            manifest
        })
        .collect()
}

/// [`kix_owned_manifests`] for comparison against a build, with each object
/// that is unchanged since kix applied a manifest still in the build replaced
/// by that manifest. `built` maps identity hash to the build's stamped
/// manifest.
///
/// An object is unchanged when its `kix.run/identity-hash` names a manifest
/// in `built`, [`super::drift::check_object`] finds it in sync, and every
/// field that manifest sets holds the same value in the kix-owned view (see
/// [`build_holds_in`]). The view may carry fields the build does not set,
/// such as the `publisher` StackGres's mutating webhook adds to each
/// extension; those are what the replacement hides. In sync alone is not
/// enough: it means the live fields match the apply response, which already
/// lacks a field the CRD schema pruned and already holds a value a webhook
/// overwrote. The replacement keeps the live `kix.run/*` annotations, because
/// both hashes leave them out and a package move would otherwise not show.
///
/// Every other object is compared through its view, with [`redact_secret`]
/// run against the build manifest of the same name, so no live Secret value
/// leaves this function. A Secret kix applied with `stringData` always takes
/// that path (the server stores no `stringData`). A changed value shows there
/// only when the build holds the plaintext: a literal `data` or `stringData`
/// value, not a SOPS Secret's.
pub fn kix_owned_manifests_against(
    objects: impl IntoIterator<Item = DynamicObject>,
    built: &HashMap<String, &serde_json::Value>,
) -> Vec<serde_json::Value> {
    let by_id: HashMap<ResourceId, &serde_json::Value> = built
        .values()
        .map(|m| (ResourceId::from_value(m), *m))
        .collect();
    objects
        .into_iter()
        .map(|obj| {
            let mut view = unredacted_view(&obj);
            crate::legacy_domain::upgrade_manifest(&mut view);
            if let Some(manifest) = unchanged_since_apply(&obj, &view, built) {
                return manifest;
            }
            let build = by_id.get(&ResourceId::from_value(&view)).copied();
            redact_secret(&mut view, &obj, build);
            view
        })
        .collect()
}

/// The build manifest `obj` was applied from, with the live `kix.run/*`
/// annotations of `view`, when nothing has changed it since. See
/// [`kix_owned_manifests_against`].
fn unchanged_since_apply(
    obj: &DynamicObject,
    view: &serde_json::Value,
    built: &HashMap<String, &serde_json::Value>,
) -> Option<serde_json::Value> {
    let hash = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))?;
    let manifest = *built.get(hash)?;
    if super::drift::check_object(obj).verdict != super::drift::DriftVerdict::InSync
        || !build_holds_in(manifest, view, "$")
    {
        return None;
    }
    let mut out = manifest.clone();
    let live_stamps: Vec<(String, serde_json::Value)> = view
        .pointer("/metadata/annotations")
        .and_then(serde_json::Value::as_object)
        .into_iter()
        .flatten()
        .filter(|(k, _)| keys::is_kix_key(k))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    super::normalize::strip_kix_annotations(&mut out);
    if !live_stamps.is_empty()
        && let Some(meta) = out.get_mut("metadata").and_then(|m| m.as_object_mut())
        && let Some(annotations) = meta
            .entry("annotations")
            .or_insert_with(|| serde_json::json!({}))
            .as_object_mut()
    {
        annotations.extend(live_stamps);
    }
    Some(out)
}

/// Whether every field `build` sets is present in `live` with an equal
/// value, using the same equivalences as the diff engine (a server default
/// or empty list for an absent field, quantity spellings). `live` may hold
/// fields `build` does not. Lists match by the diff engine's keys, or by
/// position, and must have the same length. `path` is the diff path of
/// `build`, which the equivalence rules match on.
fn build_holds_in(build: &serde_json::Value, live: &serde_json::Value, path: &str) -> bool {
    use crate::manifest::diff::equivalence::{
        equivalent_to_unset, is_quantity_field, same_quantity,
    };
    use crate::manifest::diff::keyed_lists::{path_leaf, try_key_lists};
    use serde_json::Value;

    match (build, live) {
        (Value::Object(b), Value::Object(l)) => {
            let parent = path_leaf(path);
            b.iter().all(|(key, bv)| {
                let child = format!("{path}.{key}");
                match l.get(key) {
                    None => equivalent_to_unset(&child, bv),
                    Some(lv) => {
                        (bv.is_null() && equivalent_to_unset(&child, lv))
                            || (is_quantity_field(parent, key) && same_quantity(bv, lv))
                            || build_holds_in(bv, lv, &child)
                    }
                }
            })
        }
        (Value::Array(b), Value::Array(l)) => {
            if b.len() != l.len() {
                return false;
            }
            match try_key_lists(path_leaf(path), b, l) {
                Some((b_map, l_map)) => b_map.iter().all(|(key, bv)| {
                    l_map
                        .get(key)
                        .is_some_and(|lv| build_holds_in(bv, lv, &format!("{path}[{key}]")))
                }),
                None => b
                    .iter()
                    .zip(l)
                    .enumerate()
                    .all(|(i, (bv, lv))| build_holds_in(bv, lv, &format!("{path}[{i}]"))),
            }
        }
        _ => build == live,
    }
}

/// Serialise a fetched object into a whole-manifest `Value`.
///
/// `DynamicObject` keeps `metadata` in a typed field and puts only the
/// *remaining* keys (`spec`, `data`, …) in `.data`. Serialising `.data`
/// alone therefore yields a manifest with no `metadata`, name, or namespace.
/// This silently degrades every `ResourceId` built from it to `Kind/unknown`.
/// Every live object of the same kind then
/// collapses onto one id, matches nothing on the kix side, and the diff
/// reports the whole cluster as "will be created".
///
/// `kind`/`apiVersion` come from `.data` (injected by `fetch_parallel`,
/// since LIST responses omit them per item) rather than from `.types`.
pub fn to_manifest_value(obj: &DynamicObject) -> serde_json::Value {
    serde_json::to_value(obj).unwrap_or_else(|e| {
        // ObjectMeta + a JSON Value cannot fail to serialise.
        unreachable!("DynamicObject failed to serialise: {e}")
    })
}

/// What one parallel LIST pass produced.
pub struct Listed {
    pub objects: Vec<DynamicObject>,
    /// Resource types that answered 403.
    pub forbidden: Vec<String>,
}

/// One task's result inside [`fetch_parallel`].
enum ListOutcome {
    Items(Vec<DynamicObject>),
    Forbidden(String),
}

/// How many LISTs the sweep keeps in flight. One per kind is over a hundred
/// on a real cluster, and the apiserver's priority-and-fairness answers
/// that burst with 429s. Bounded here, on spawned tasks the runtime always
/// polls, rather than in the transport layer, where a permit held inside a
/// future its owner had parked deadlocked `kix deploy` (see
/// `cluster::client`). Override with `KIX_SWEEP_CONCURRENCY`.
pub const DEFAULT_SWEEP_CONCURRENCY: usize = 16;
/// Env var for [`DEFAULT_SWEEP_CONCURRENCY`].
pub const SWEEP_CONCURRENCY_ENV: &str = "KIX_SWEEP_CONCURRENCY";

fn sweep_concurrency() -> usize {
    super::client::env_number(SWEEP_CONCURRENCY_ENV)
        .map(|n| n.max(1) as usize)
        .unwrap_or(DEFAULT_SWEEP_CONCURRENCY)
}

/// Internal: run parallel LIST calls across all discovered resource types,
/// at most [`DEFAULT_SWEEP_CONCURRENCY`] at a time.
///
/// The transport layer already retried each LIST on 429, 5xx and
/// connection errors, so an error here is one that outlasted the budget.
/// It is returned, and dropping the `JoinSet` cancels the lists still in
/// flight. Treating a failed list as empty would make `kix diff` report live
/// resources as new during an apiserver restart.
async fn fetch_parallel(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    lp: &ListParams,
) -> Result<Listed, FetchError> {
    let mut set = JoinSet::new();
    let mut listed = Listed {
        objects: Vec::new(),
        forbidden: Vec::new(),
    };
    let limit = sweep_concurrency();

    for (ar, scope) in discovery {
        // Keep the number in flight bounded: drain one before adding one.
        while set.len() >= limit {
            match set.join_next().await {
                Some(outcome) => absorb(&mut listed, outcome)?,
                None => break,
            }
        }
        let api: Api<DynamicObject> = match scope {
            Scope::Namespaced => {
                // List across all namespaces
                Api::all_with(client.clone(), ar)
            }
            Scope::Cluster => Api::all_with(client.clone(), ar),
        };

        let lp = lp.clone();
        let fqn = resource_fqn(ar);
        let kind = ar.kind.clone();
        let api_version = ar.api_version.clone();
        set.spawn(async move {
            match api.list(&lp).await {
                Ok(list) => {
                    if !list.items.is_empty() {
                        tracing::debug!(resource = %fqn, count = list.items.len(), "fetched");
                    }
                    // Inject kind/apiVersion into data (LIST responses omit them)
                    let items: Vec<DynamicObject> = list
                        .items
                        .into_iter()
                        .map(|mut obj| {
                            if let Some(map) = obj.data.as_object_mut() {
                                map.entry("kind")
                                    .or_insert_with(|| serde_json::Value::String(kind.clone()));
                                map.entry("apiVersion").or_insert_with(|| {
                                    serde_json::Value::String(api_version.clone())
                                });
                            }
                            obj
                        })
                        .collect();
                    Ok(ListOutcome::Items(items))
                }
                Err(e) if classify(&e) == FailureClass::Forbidden => {
                    // RBAC: a stable fact about the account, not a fault.
                    tracing::debug!(resource = %fqn, "forbidden, recorded");
                    Ok(ListOutcome::Forbidden(fqn))
                }
                Err(e) => Err(FetchError::ListError {
                    resource: fqn,
                    source: e,
                }),
            }
        });
    }

    while let Some(join_result) = set.join_next().await {
        absorb(&mut listed, join_result)?;
    }
    listed.forbidden.sort();
    Ok(listed)
}

/// Fold one finished LIST task into the result, or stop on its error.
// FetchError carries a kube::Error; boxing it here would only move the
// size to every caller's match arms.
#[allow(clippy::result_large_err)]
fn absorb(
    listed: &mut Listed,
    join_result: Result<Result<ListOutcome, FetchError>, tokio::task::JoinError>,
) -> Result<(), FetchError> {
    match join_result {
        Ok(Ok(ListOutcome::Items(items))) => listed.objects.extend(items),
        Ok(Ok(ListOutcome::Forbidden(fqn))) => listed.forbidden.push(fqn),
        Ok(Err(e)) => return Err(e),
        Err(e) => return Err(FetchError::ClientError(Box::new(e))),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kube::api::ObjectMeta;
    use serde_json::{Value, json};

    fn managed(
        manager: &str,
        operation: &str,
        subresource: Option<&str>,
        fields: serde_json::Value,
    ) -> k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
        k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry {
            manager: Some(manager.into()),
            operation: Some(operation.into()),
            subresource: subresource.map(str::to_string),
            fields_v1: Some(k8s_openapi::apimachinery::pkg::apis::meta::v1::FieldsV1(
                fields,
            )),
            ..Default::default()
        }
    }

    /// A live Deployment as the apiserver hands it back: kix's Apply entry
    /// owns what kix sent, kix's bookkeeping patch is a separate Update
    /// entry, the controller owns its revision annotation and status, and
    /// the server defaulted strategy, probe thresholds and the like with no
    /// owner at all. Only the first survives.
    #[test]
    fn kix_owned_view_keeps_only_the_applied_fieldset() {
        let f_identity = format!("f:{}", keys::IDENTITY_HASH);
        let f_activations = format!("f:{}", keys::ACTIVATIONS);
        let f_applied = format!("f:{}", keys::APPLIED_HASH);
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("web".into()),
                namespace: Some("app".into()),
                uid: Some("abc".into()),
                resource_version: Some("9".into()),
                labels: Some(
                    [(
                        "app.kubernetes.io/managed-by".to_string(),
                        "kix".to_string(),
                    )]
                    .into(),
                ),
                annotations: Some(
                    [
                        (keys::IDENTITY_HASH.to_string(), "h1".to_string()),
                        (keys::ACTIVATIONS.to_string(), "a1".to_string()),
                        (keys::APPLIED_HASH.to_string(), "deadbeef".to_string()),
                        (
                            "deployment.kubernetes.io/revision".to_string(),
                            "1".to_string(),
                        ),
                    ]
                    .into(),
                ),
                managed_fields: Some(vec![
                    managed(
                        "kix",
                        "Apply",
                        None,
                        json!({
                            "f:metadata": {
                                "f:annotations": {f_identity: {}},
                                "f:labels": {"f:app.kubernetes.io/managed-by": {}}
                            },
                            "f:spec": {
                                "f:replicas": {},
                                "f:selector": {},
                                "f:template": {"f:spec": {"f:containers": {
                                    "k:{\"name\":\"nginx\"}": {
                                        ".": {}, "f:name": {}, "f:image": {},
                                        "f:readinessProbe": {"f:httpGet": {"f:path": {}, "f:port": {}}}
                                    }
                                }}}
                            }
                        }),
                    ),
                    managed(
                        "kix",
                        "Update",
                        None,
                        json!({
                            "f:metadata": {"f:annotations": {f_activations: {}, f_applied: {}}}
                        }),
                    ),
                    managed(
                        "kube-controller-manager",
                        "Update",
                        Some("status"),
                        json!({
                            "f:metadata": {"f:annotations": {"f:deployment.kubernetes.io/revision": {}}},
                            "f:status": {"f:replicas": {}}
                        }),
                    ),
                ]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "spec": {
                    "replicas": 2,
                    "selector": {"matchLabels": {"app": "web"}},
                    "progressDeadlineSeconds": 600,
                    "revisionHistoryLimit": 10,
                    "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": "25%"}},
                    "template": {
                        "metadata": {"creationTimestamp": null},
                        "spec": {
                            "dnsPolicy": "ClusterFirst",
                            "schedulerName": "default-scheduler",
                            "containers": [{
                                "name": "nginx",
                                "image": "nginx:1.27",
                                "terminationMessagePath": "/dev/termination-log",
                                "readinessProbe": {
                                    "httpGet": {"path": "/", "port": "http", "scheme": "HTTP"},
                                    "failureThreshold": 3,
                                    "periodSeconds": 10
                                }
                            }]
                        }
                    }
                },
                "status": {"replicas": 2}
            }),
        };

        assert_eq!(
            kix_owned_view(&obj),
            json!({
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": "web",
                    "namespace": "app",
                    "annotations": {keys::IDENTITY_HASH: "h1"},
                    "labels": {"app.kubernetes.io/managed-by": "kix"}
                },
                "spec": {
                    "replicas": 2,
                    "selector": {"matchLabels": {"app": "web"}},
                    "template": {"spec": {"containers": [{
                        "name": "nginx",
                        "image": "nginx:1.27",
                        "readinessProbe": {"httpGet": {"path": "/", "port": "http"}}
                    }]}}
                }
            })
        );
    }

    /// A live Secret kix applied with `stringData`: the server stored only
    /// `data`, under the given base64 password and `other`, which is not kix's.
    fn string_data_secret(password_b64: &str, annotations: Value) -> DynamicObject {
        let annotation_fields: serde_json::Map<String, Value> = annotations
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, _)| (format!("f:{k}"), json!({})))
            .collect();
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("creds".into()),
                namespace: Some("app".into()),
                annotations: Some(
                    annotations
                        .as_object()
                        .into_iter()
                        .flatten()
                        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
                        .collect(),
                ),
                managed_fields: Some(vec![managed(
                    "kix",
                    "Apply",
                    None,
                    json!({
                        "f:metadata": {"f:annotations": annotation_fields},
                        "f:stringData": {".": {}, "f:password": {}, "f:user": {}},
                        "f:type": {}
                    }),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "v1",
                "kind": "Secret",
                "type": "Opaque",
                // "admin", the given password, and "x".
                "data": {"user": "YWRtaW4=", "password": password_b64, "other": "eA=="}
            }),
        }
    }

    /// An object of another API group with kind Secret is not a Kubernetes
    /// Secret, and its view keeps its values.
    #[test]
    fn kix_owned_view_of_a_custom_resource_named_secret_keeps_its_values() {
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("creds".into()),
                namespace: Some("app".into()),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "x.example/v1",
                "kind": "Secret",
                "data": {"password": "plain"}
            }),
        };
        assert_eq!(kix_owned_view(&obj)["data"]["password"], json!("plain"));
    }

    #[test]
    fn kix_owned_view_of_a_string_data_secret_holds_no_values() {
        let view = kix_owned_view(&string_data_secret("ZGV2LXBhc3N3b3Jk", json!({})));
        assert!(view.get("stringData").is_none());
        assert!(view.get("data").is_none());
    }

    /// A live SGCluster after an apply: the operator's webhook added
    /// `publisher` to each extension, inside a list kix owns whole.
    fn webhook_defaulted_cluster(extensions: Value, applied_hash: Option<&str>) -> DynamicObject {
        applied_cluster(
            json!({"postgres": {"extensions": extensions}}),
            &[(keys::IDENTITY_HASH, "h-pg")],
            applied_hash,
        )
    }

    /// A live SGCluster whose kix Apply entry owns the given annotations and
    /// `spec.postgres.extensions`. The applied-content hash is computed from
    /// the object unless `applied_hash` overrides it.
    fn applied_cluster(
        spec: Value,
        owned_annotations: &[(&str, &str)],
        applied_hash: Option<&str>,
    ) -> DynamicObject {
        let mut annotations: BTreeMap<String, String> = owned_annotations
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let annotation_fields: serde_json::Map<String, Value> = owned_annotations
            .iter()
            .map(|(k, _)| (format!("f:{k}"), json!({})))
            .collect();
        let mut obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("postgres".into()),
                namespace: Some("data".into()),
                annotations: Some(annotations.clone()),
                managed_fields: Some(vec![managed(
                    "kix",
                    "Apply",
                    None,
                    json!({
                        "f:metadata": {"f:annotations": annotation_fields},
                        "f:spec": {"f:postgres": {"f:extensions": {}}}
                    }),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "stackgres.io/v1",
                "kind": "SGCluster",
                "spec": spec
            }),
        };
        let hash = match applied_hash {
            Some(h) => h.to_string(),
            None => crate::cluster::fieldsv1::applied_content_hash(&obj).unwrap(),
        };
        annotations.insert(keys::APPLIED_HASH.to_string(), hash);
        obj.metadata.annotations = Some(annotations);
        obj
    }

    fn built_cluster(spec: Value, annotations: Value) -> Value {
        json!({
            "apiVersion": "stackgres.io/v1",
            "kind": "SGCluster",
            "metadata": {"name": "postgres", "namespace": "data", "annotations": annotations},
            "spec": spec
        })
    }

    fn diff_paths(built: &Value, compared: &Value) -> Vec<String> {
        let config = crate::manifest::diff::DiffConfig::default();
        crate::manifest::diff::engine::structural_diff(built, compared, "$", &config)
            .into_iter()
            .map(|d| d.path)
            .collect()
    }

    /// A field the CRD schema pruned on apply is absent from the live object,
    /// although drift finds it in sync. It shows as missing.
    #[test]
    fn a_field_pruned_on_apply_shows_in_the_comparison() {
        let built = built_cluster(
            json!({"postgres": {"extensions": [{"name": "cube"}], "flavour": "babelfish"}}),
            json!({keys::IDENTITY_HASH: "h-pg"}),
        );
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();
        let live = applied_cluster(
            json!({"postgres": {"extensions": [{"name": "cube"}]}}),
            &[(keys::IDENTITY_HASH, "h-pg")],
            None,
        );
        let out = kix_owned_manifests_against([live], &by_hash).remove(0);
        assert_eq!(diff_paths(&built, &out), vec!["$.spec.postgres.flavour"]);
    }

    /// A value a mutating webhook overwrote on apply reads as changed, while
    /// the field it added beside it still does not show.
    #[test]
    fn a_value_a_webhook_overwrote_shows_in_the_comparison() {
        let built = built_cluster(
            json!({"postgres": {"extensions": [{"name": "cube", "version": "1.5"}]}}),
            json!({keys::IDENTITY_HASH: "h-pg"}),
        );
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();
        let live = webhook_defaulted_cluster(
            json!([{"name": "cube", "version": "1.6", "publisher": "com.ongres"}]),
            None,
        );
        let out = kix_owned_manifests_against([live], &by_hash).remove(0);
        assert_eq!(
            out["spec"]["postgres"]["extensions"][0]["version"],
            json!("1.6")
        );
        assert!(
            diff_paths(&built, &out)
                .contains(&"$.spec.postgres.extensions[cube].version".to_string())
        );
    }

    /// The identity and applied-content hashes leave out `kix.run/*`
    /// annotations, so a package move or a hand-edited stamp keeps both. The
    /// comparison carries the live stamps and shows the change.
    #[test]
    fn a_changed_stamp_annotation_shows_in_the_comparison() {
        let spec = json!({"postgres": {"extensions": [{"name": "cube"}]}});
        let built = built_cluster(
            spec.clone(),
            json!({keys::IDENTITY_HASH: "h-pg", keys::PACKAGE: "postgres-new"}),
        );
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();

        let moved = applied_cluster(
            spec.clone(),
            &[
                (keys::IDENTITY_HASH, "h-pg"),
                (keys::PACKAGE, "postgres-old"),
            ],
            None,
        );
        let out = kix_owned_manifests_against([moved], &by_hash).remove(0);
        assert_eq!(
            out["metadata"]["annotations"][keys::PACKAGE],
            json!("postgres-old")
        );

        let extra = applied_cluster(
            spec,
            &[
                (keys::IDENTITY_HASH, "h-pg"),
                (keys::PACKAGE, "postgres-new"),
                (keys::LIFECYCLE, "stateful"),
            ],
            None,
        );
        let out = kix_owned_manifests_against([extra], &by_hash).remove(0);
        assert_eq!(
            out["metadata"]["annotations"][keys::LIFECYCLE],
            json!("stateful")
        );
    }

    #[test]
    fn an_object_unchanged_since_apply_compares_as_its_build_manifest() {
        let built = json!({
            "apiVersion": "stackgres.io/v1",
            "kind": "SGCluster",
            "metadata": {"name": "postgres", "namespace": "data",
                         "annotations": {keys::IDENTITY_HASH: "h-pg"}},
            "spec": {"postgres": {"extensions": [{"name": "cube"}]}}
        });
        let by_hash: HashMap<String, &Value> = [("h-pg".to_string(), &built)].into();
        let live_extensions = json!([{"name": "cube", "publisher": "com.ongres"}]);

        let in_sync = webhook_defaulted_cluster(live_extensions.clone(), None);
        assert_eq!(
            kix_owned_manifests_against([in_sync], &by_hash),
            std::slice::from_ref(&built)
        );

        // Changed since the apply: the live view, webhook default and all.
        let drifted = webhook_defaulted_cluster(live_extensions.clone(), Some("other"));
        let out = kix_owned_manifests_against([drifted], &by_hash);
        assert_eq!(out[0]["spec"]["postgres"]["extensions"], live_extensions);

        // Applied from a manifest the build no longer has: the live view.
        let in_sync = webhook_defaulted_cluster(live_extensions.clone(), None);
        let out = kix_owned_manifests_against([in_sync], &HashMap::new());
        assert_eq!(out[0]["spec"]["postgres"]["extensions"], live_extensions);
    }

    fn compare_with_build(live: DynamicObject, built: &Value) -> Value {
        let by_hash: HashMap<String, &Value> = [("h-sec".to_string(), built)].into();
        kix_owned_manifests_against([live], &by_hash).remove(0)
    }

    /// Literal `stringData` in the build: a live value equal to the build's
    /// reads as the build's, a changed one is hidden, and one that does not
    /// decode is left out. `other` is not in the build and never appears.
    #[test]
    fn a_secret_applied_with_string_data_compares_against_the_build() {
        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app"},
            "stringData": {"user": "admin", "password": "dev-password"}
        });

        let same = compare_with_build(string_data_secret("ZGV2LXBhc3N3b3Jk", json!({})), &built);
        assert_eq!(same, built);

        // "rotated"
        let changed = compare_with_build(string_data_secret("cm90YXRlZA==", json!({})), &built);
        assert_eq!(
            changed["stringData"],
            json!({"user": "admin", "password": HIDDEN_SECRET_VALUE})
        );
        assert!(!changed.to_string().contains("rotated"));

        let broken = compare_with_build(string_data_secret("not base64", json!({})), &built);
        assert_eq!(broken["stringData"], json!({"user": "admin"}));
    }

    /// A SOPS Secret: the build has no `stringData`, and kix applied the
    /// decrypted values through it. The live object reads as the build, and
    /// no decrypted value appears in the comparison or the view.
    #[test]
    fn a_sops_secret_compares_unchanged_without_its_values() {
        let annotations = json!({
            keys::SOPS_SOURCE: "/nix/store/abc-secrets.yaml",
            keys::IDENTITY_HASH: "h-sec"
        });
        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app", "annotations": annotations}
        });
        // "s3cr3t-from-sops"
        let live = || string_data_secret("czNjcjN0LWZyb20tc29wcw==", annotations.clone());

        let compared = compare_with_build(live(), &built);
        let config = crate::manifest::diff::DiffConfig::default();
        assert_eq!(
            crate::manifest::diff::engine::structural_diff(&built, &compared, "$", &config),
            vec![]
        );
        for out in [compared, kix_owned_view(&live())] {
            let text = out.to_string();
            assert!(!text.contains("s3cr3t-from-sops"), "{text}");
            assert!(!text.contains("admin"), "{text}");
        }
    }

    /// A live Secret holding `data` user "admin", password "rotated" and
    /// `other` "x", whose managedFields are `managed_fields`.
    fn data_secret(
        managed_fields: Vec<k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry>,
    ) -> DynamicObject {
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("creds".into()),
                namespace: Some("app".into()),
                annotations: Some(
                    [
                        (keys::IDENTITY_HASH.to_string(), "h-sec".to_string()),
                        (keys::APPLIED_HASH.to_string(), "drifted".to_string()),
                    ]
                    .into(),
                ),
                managed_fields: Some(managed_fields),
                ..Default::default()
            },
            types: None,
            data: json!({
                "apiVersion": "v1",
                "kind": "Secret",
                "type": "Opaque",
                "data": {"user": "YWRtaW4=", "password": "cm90YXRlZA==", "other": "eA=="}
            }),
        }
    }

    fn assert_no_live_value(out: &Value) {
        let text = out.to_string();
        for live in ["cm90YXRlZA==", "rotated", "eA=="] {
            assert!(!text.contains(live), "{live} in {text}");
        }
    }

    /// A Secret kix applied through `data` that has drifted since: no live
    /// value is in its view, and against the build a key equal to the
    /// build's reads as the build's while a changed one is hidden.
    #[test]
    fn a_secret_applied_with_data_holds_no_live_value() {
        let live = || {
            data_secret(vec![managed(
                "kix",
                "Apply",
                None,
                json!({"f:data": {".": {}, "f:user": {}, "f:password": {}}, "f:type": {}}),
            )])
        };
        let view = kix_owned_view(&live());
        assert_eq!(
            view["data"],
            json!({"user": HIDDEN_SECRET_VALUE, "password": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&view);

        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app",
                         "annotations": {keys::IDENTITY_HASH: "h-sec"}},
            // "admin", "dev-password"
            "data": {"user": "YWRtaW4=", "password": "ZGV2LXBhc3N3b3Jk"}
        });
        let compared = compare_with_build(live(), &built);
        assert_eq!(
            compared["data"],
            json!({"user": "YWRtaW4=", "password": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&compared);
    }

    /// A Secret with no kix Apply entry falls back to the whole object, and
    /// still holds no live value: without a build every key is hidden, and a
    /// key the build declares under `stringData` with the same value reads
    /// as the build's.
    #[test]
    fn a_secret_without_an_apply_entry_holds_no_live_value() {
        let live = || {
            data_secret(vec![managed(
                "kubectl-create",
                "Update",
                None,
                json!({"f:data": {}}),
            )])
        };
        let view = kix_owned_view(&live());
        assert_eq!(
            view["data"],
            json!({"user": HIDDEN_SECRET_VALUE, "password": HIDDEN_SECRET_VALUE,
                   "other": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&view);
        assert_no_live_value(&kix_owned_manifests([live()]).remove(0));

        let built = json!({
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "creds", "namespace": "app"},
            "stringData": {"user": "admin", "password": "dev-password"}
        });
        let compared = compare_with_build(live(), &built);
        assert_eq!(compared["stringData"], json!({"user": "admin"}));
        assert_eq!(
            compared["data"],
            json!({"password": HIDDEN_SECRET_VALUE, "other": HIDDEN_SECRET_VALUE})
        );
        assert_no_live_value(&compared);
    }

    /// No kix Apply entry (adopted externally, or pre-SSA): the whole object,
    /// minus server metadata, so the diff still has something to show.
    #[test]
    fn kix_owned_view_falls_back_without_an_apply_entry() {
        let obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("cm".into()),
                namespace: Some("app".into()),
                uid: Some("abc".into()),
                managed_fields: Some(vec![managed(
                    "kubectl-create",
                    "Update",
                    None,
                    json!({"f:data": {}}),
                )]),
                ..Default::default()
            },
            types: None,
            data: json!({"apiVersion": "v1", "kind": "ConfigMap", "data": {"k": "v"}}),
        };
        let view = kix_owned_view(&obj);
        assert_eq!(view["data"], json!({"k": "v"}));
        assert_eq!(view["metadata"]["name"], json!("cm"));
        assert!(view["metadata"].get("uid").is_none());
        assert!(view["metadata"].get("managedFields").is_none());
    }

    #[test]
    fn normalize_strips_server_fields() {
        let mut obj = DynamicObject {
            metadata: ObjectMeta {
                name: Some("test".into()),
                namespace: Some("default".into()),
                uid: Some("abc-123".into()),
                resource_version: Some("12345".into()),
                generation: Some(3),
                managed_fields: Some(vec![]),
                ..Default::default()
            },
            types: None,
            data: json!({
                "metadata": {
                    "name": "test",
                    "namespace": "default",
                    "uid": "abc-123",
                    "resourceVersion": "12345",
                    "creationTimestamp": "2026-01-01T00:00:00Z",
                    "generation": 3,
                    "selfLink": "/api/v1/namespaces/default/pods/test",
                    "managedFields": [{"manager": "kubectl"}],
                    "annotations": {
                        "kubectl.kubernetes.io/last-applied-configuration": "{}",
                        "custom-annotation": "keep"
                    }
                },
                "spec": {"replicas": 1},
                "status": {"ready": true}
            }),
        };

        normalize_for_diff(&mut obj);

        // Typed metadata fields
        assert!(obj.metadata.uid.is_none());
        assert!(obj.metadata.resource_version.is_none());
        assert!(obj.metadata.generation.is_none());
        assert!(obj.metadata.managed_fields.is_none());

        // Raw JSON fields
        let data = obj.data.as_object().unwrap();
        let meta = data["metadata"].as_object().unwrap();
        assert!(!meta.contains_key("uid"));
        assert!(!meta.contains_key("resourceVersion"));
        assert!(!meta.contains_key("creationTimestamp"));
        assert!(!meta.contains_key("generation"));
        assert!(!meta.contains_key("selfLink"));
        assert!(!meta.contains_key("managedFields"));

        // last-applied-configuration stripped, custom annotation kept
        let annotations = meta["annotations"].as_object().unwrap();
        assert!(!annotations.contains_key("kubectl.kubernetes.io/last-applied-configuration"));
        assert_eq!(annotations["custom-annotation"], "keep");

        // status removed
        assert!(!data.contains_key("status"));

        // spec preserved
        assert!(data.contains_key("spec"));
    }

    /// A LIST item as the apiserver actually returns it: no per-item
    /// `apiVersion`/`kind`, and `metadata` alongside `spec`.
    fn list_item() -> DynamicObject {
        let mut obj: DynamicObject = serde_json::from_value(json!({
            "metadata": { "name": "lithus-secret-operator", "namespace": "lithus-system" },
            "spec": { "replicas": 1 },
        }))
        .unwrap();
        // What fetch_parallel does, because LIST omits these per item.
        let map = obj.data.as_object_mut().unwrap();
        map.insert("kind".into(), json!("Deployment"));
        map.insert("apiVersion".into(), json!("apps/v1"));
        obj
    }

    /// Pins the shape the whole bug turned on: kube-rs parses `metadata`
    /// into the typed field and leaves it OUT of `.data`. The synthetic
    /// fixtures above put `metadata` inside `.data`, which the apiserver
    /// never does, so anything reading `.data["metadata"]` reads nothing.
    #[test]
    fn deserialized_object_keeps_metadata_out_of_data() {
        let obj = list_item();
        assert_eq!(obj.metadata.name.as_deref(), Some("lithus-secret-operator"));
        assert!(
            obj.data.get("metadata").is_none(),
            "metadata must live on the typed field, not in .data"
        );
    }

    /// Regression: serialising `.data` alone drops metadata, so every live
    /// object of a kind degrades to the same `Kind/unknown` id, matches
    /// nothing, and `kix diff` reports an unchanged cluster as fully new.
    #[test]
    fn to_manifest_value_yields_a_matchable_resource_id() {
        let mut obj = list_item();
        normalize_for_diff(&mut obj);

        let broken = crate::manifest::types::ResourceId::from_value(&obj.data);
        assert_eq!(broken.name, "unknown", "the old .data-only path");

        let id = crate::manifest::types::ResourceId::from_value(&to_manifest_value(&obj));
        assert_eq!(id.kind, "Deployment");
        assert_eq!(id.name, "lithus-secret-operator");
        assert_eq!(id.namespace, "lithus-system");
    }

    /// normalize_for_diff clears the TYPED metadata fields; that only has
    /// any effect if the typed metadata is what gets serialised.
    #[test]
    fn to_manifest_value_drops_normalized_server_fields() {
        let mut obj = list_item();
        obj.metadata.uid = Some("abc-123".into());
        obj.metadata.resource_version = Some("12345".into());
        normalize_for_diff(&mut obj);

        let value = to_manifest_value(&obj);
        let meta = value.pointer("/metadata").unwrap().as_object().unwrap();
        assert!(!meta.contains_key("uid"));
        assert!(!meta.contains_key("resourceVersion"));
        assert_eq!(value.pointer("/spec/replicas").unwrap(), &json!(1));
    }

    fn swept(kind: &str, ns: &str, name: &str, stamped: bool, owned: bool) -> DynamicObject {
        use k8s_openapi::apimachinery::pkg::apis::meta::v1::OwnerReference;
        let mut obj = DynamicObject {
            types: None,
            metadata: ObjectMeta {
                name: Some(name.into()),
                namespace: Some(ns.into()),
                ..Default::default()
            },
            data: json!({ "kind": kind }),
        };
        if stamped {
            obj.metadata.annotations = Some(
                [(keys::IDENTITY_HASH.to_string(), "h".to_string())]
                    .into_iter()
                    .collect(),
            );
        }
        if owned {
            obj.metadata.owner_references = Some(vec![OwnerReference {
                api_version: "v1".into(),
                kind: "Service".into(),
                name: name.into(),
                uid: "abc".into(),
                controller: Some(true),
                block_owner_deletion: None,
            }]);
        }
        obj
    }

    fn names(objs: &[DynamicObject]) -> Vec<String> {
        let mut v: Vec<String> = objs
            .iter()
            .map(|o| {
                format!(
                    "{}/{}/{}",
                    o.metadata.namespace.as_deref().unwrap_or(""),
                    o.data["kind"].as_str().unwrap(),
                    o.metadata.name.as_deref().unwrap()
                )
            })
            .collect();
        v.sort();
        v
    }

    #[test]
    fn sweep_keeps_stamped_objects_whoever_owns_them() {
        let sweep = partition_sweep(vec![
            swept("Deployment", "ns", "web", true, false),
            swept("Job", "ns", "adopted", true, true),
        ]);
        assert_eq!(
            names(&sweep.managed),
            ["ns/Deployment/web", "ns/Job/adopted"]
        );
        assert!(sweep.unstamped.is_empty());
    }

    #[test]
    fn sweep_drops_owned_unstamped_children() {
        let sweep = partition_sweep(vec![
            swept("Service", "ns", "web", true, false),
            swept("EndpointSlice", "ns", "web-abc12", false, true),
            swept("ReplicaSet", "ns", "web-7d9f", false, true),
        ]);
        assert_eq!(names(&sweep.managed), ["ns/Service/web"]);
        assert!(sweep.unstamped.is_empty());
    }

    #[test]
    fn sweep_reports_unowned_unstamped_label_carriers() {
        let sweep = partition_sweep(vec![swept(
            "ConfigMap",
            "ns",
            "kubectl-applied",
            false,
            false,
        )]);
        assert!(sweep.managed.is_empty());
        assert_eq!(names(&sweep.unstamped), ["ns/ConfigMap/kubectl-applied"]);
    }

    #[test]
    fn sweep_treats_endpoints_named_after_a_managed_service_as_its_mirror() {
        let sweep = partition_sweep(vec![
            swept("Service", "ns", "web", true, false),
            swept("Endpoints", "ns", "web", false, false),
            swept("Endpoints", "ns", "stray", false, false),
            swept("Endpoints", "other", "web", false, false),
        ]);
        assert_eq!(names(&sweep.managed), ["ns/Service/web"]);
        assert_eq!(
            names(&sweep.unstamped),
            ["ns/Endpoints/stray", "other/Endpoints/web"],
            "only the same-namespace mirror is dropped"
        );
    }

    // These drive a real localhost socket rather than mocking kube, because
    // the mode that matters is a TCP-level one: accept the connection and
    // then say nothing. A mock at the kube layer cannot express it.

    /// A localhost stand-in for an apiserver.
    ///
    /// `reply: None` accepts the connection and then goes silent, which is
    /// the failure mode no connect timeout can catch: the handshake
    /// succeeds, so only a deadline above the connect ever fires.
    async fn fake_apiserver(reply: Option<&'static [u8]>) -> String {
        use tokio::io::AsyncWriteExt;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            // Sockets stay in `held` so the peer sees silence, not a close.
            let mut held = Vec::new();
            while let Ok((mut sock, _)) = listener.accept().await {
                if let Some(bytes) = reply {
                    let _ = sock.write_all(bytes).await;
                    let _ = sock.flush().await;
                }
                held.push(sock);
            }
        });
        format!("http://{addr}")
    }

    /// A client for `endpoint`, built the way `make_client` builds it.
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
        // The message has to name the endpoint: that is the whole point of
        // failing here rather than deep inside discovery.
        assert!(err.to_string().contains(&endpoint), "{err}");
    }

    #[tokio::test]
    async fn probe_passes_when_the_endpoint_answers_at_all() {
        // 403 on /version still proves the apiserver is alive and routable;
        // the real call gets to report the real error.
        let endpoint = fake_apiserver(Some(
            b"HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: 61\r\n\r\n\
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
        // Bind then drop: nothing is listening on the port any more.
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
        // The same refused port under the full policy is retried for ~18s.
        // The `FirstContact` marker is what stops that, and it is the whole
        // reason a probe on the real client is affordable.
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

    #[test]
    fn the_probe_deadline_does_not_tie_with_the_transports() {
        // Two deadlines of the same length would race for the error message.
        assert!(
            PROBE_GRACE > Duration::ZERO,
            "the transport must win the connect race, not tie it"
        );
    }

    // --- Scoping the sweep to one Kix cluster ---

    fn record(cluster: Option<&str>, hash: &str, phase: &str) -> DynamicObject {
        let mut labels = serde_json::Map::new();
        if let Some(c) = cluster {
            labels.insert(keys::CLUSTER_LABEL.into(), json!(c));
        }
        serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": labels,
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": phase },
        }))
        .unwrap()
    }

    /// Cluster `a` has records a1 (Superseded) and a2 (Active); cluster `b`
    /// has b0 (Superseded) and b1 (Active).
    fn two_clusters(cluster: &str) -> Tenancy {
        Tenancy::from_records(
            &[
                record(Some("a"), "a1", activation::PHASE_SUPERSEDED),
                record(Some("a"), "a2", activation::PHASE_ACTIVE),
                record(Some("b"), "b0", activation::PHASE_SUPERSEDED),
                record(Some("b"), "b1", activation::PHASE_ACTIVE),
            ],
            cluster,
        )
    }

    fn one_cluster() -> Tenancy {
        Tenancy::from_records(&[record(Some("a"), "a2", activation::PHASE_ACTIVE)], "a")
    }

    /// A stamped object naming `activations` (comma-separated) under `key`.
    fn named(kind: &str, ns: &str, name: &str, key: &str, activations: &str) -> DynamicObject {
        let mut obj = swept(kind, ns, name, true, false);
        if !activations.is_empty() {
            obj.metadata
                .annotations
                .get_or_insert_default()
                .insert(key.to_string(), activations.to_string());
        }
        obj
    }

    fn obj(kind: &str, name: &str, activations: &str) -> DynamicObject {
        named(kind, "ns", name, keys::ACTIVATIONS, activations)
    }

    #[test]
    fn attribution_follows_the_record_hashes_an_object_names() {
        let t = two_clusters("a");
        let cases = [
            ("a2", Attribution::Ours),
            ("a1", Attribution::Ours),
            ("a2,b1", Attribution::Shared(vec!["b".into()])),
            ("b1", Attribution::Foreign(vec!["b".into()])),
            ("b0,b1", Attribution::Foreign(vec!["b".into()])),
            ("dead1,dead2", Attribution::Unattributed),
            ("", Attribution::Unattributed),
        ];
        for (acts, want) in cases {
            assert_eq!(
                attribute(&obj("ConfigMap", "c", acts), &t),
                want,
                "{acts:?}"
            );
        }
        // An unstamped label carrier names nothing.
        assert_eq!(
            attribute(&swept("ConfigMap", "ns", "c", false, false), &t),
            Attribution::Unattributed
        );
    }

    #[test]
    fn attribution_reads_the_retired_activations_key() {
        let Some(domain) = crate::legacy_domain::DOMAINS.first() else {
            return;
        };
        let t = two_clusters("a");
        let legacy = named(
            "ConfigMap",
            "ns",
            "c",
            &format!("{domain}/activations"),
            "b1",
        );
        assert_eq!(
            attribute(&legacy, &t),
            Attribution::Foreign(vec!["b".into()])
        );
    }

    /// An Activation record names itself by its identity hash, before any
    /// deploy has stamped `kix.run/activations` on it.
    #[test]
    fn a_record_is_attributed_by_its_own_hash() {
        let t = two_clusters("a");
        assert_eq!(
            attribute(&record(Some("b"), "b1", activation::PHASE_ACTIVE), &t),
            Attribution::Foreign(vec!["b".into()])
        );
        assert_eq!(
            attribute(&record(Some("a"), "a2", activation::PHASE_ACTIVE), &t),
            Attribution::Ours
        );
    }

    fn mixed_sweep() -> ManagedSweep {
        partition_sweep(vec![
            obj("Deployment", "a-web", "a2"),
            obj("Deployment", "b-web", "b1"),
            obj("ClusterRole", "shared", "a2,b1"),
            obj("ConfigMap", "leftover", "dead"),
            swept("ConfigMap", "ns", "kubectl-applied", false, false),
        ])
    }

    fn sorted_names(objs: &[DynamicObject]) -> Vec<&str> {
        let mut v: Vec<&str> = objs
            .iter()
            .map(|o| o.metadata.name.as_deref().unwrap())
            .collect();
        v.sort();
        v
    }

    /// Two Kix clusters' objects in one apiserver: each cluster's scope sees
    /// its own objects and the shared one, never the other's.
    #[test]
    fn each_cluster_sees_only_its_own_objects() {
        let swept_a = scope_sweep(mixed_sweep(), SweepScope::Cluster("a"), two_clusters("a"));
        assert_eq!(sorted_names(&swept_a.managed), vec!["a-web", "shared"]);
        assert_eq!(swept_a.foreign, BTreeMap::from([("b".to_string(), 1)]));
        assert_eq!(
            sorted_names(&swept_a.unattributed),
            vec!["kubectl-applied", "leftover"]
        );
        assert!(swept_a.unstamped.is_empty());

        let swept_b = scope_sweep(mixed_sweep(), SweepScope::Cluster("b"), two_clusters("b"));
        assert_eq!(sorted_names(&swept_b.managed), vec!["b-web", "shared"]);
        assert_eq!(swept_b.foreign, BTreeMap::from([("a".to_string(), 1)]));
    }

    /// With one Kix cluster on the Kubernetes cluster, the scoped sweep is
    /// the whole sweep, as before scoping existed.
    #[test]
    fn a_single_cluster_keeps_every_object() {
        let t = one_cluster();
        let sweep = partition_sweep(vec![
            obj("Deployment", "web", "a2"),
            obj("ConfigMap", "leftover", "dead"),
            obj("ConfigMap", "never-annotated", ""),
            swept("ConfigMap", "ns", "kubectl-applied", false, false),
        ]);
        let scoped = scope_sweep(sweep, SweepScope::Cluster("a"), t);
        assert_eq!(
            sorted_names(&scoped.managed),
            vec!["leftover", "never-annotated", "web"]
        );
        assert_eq!(sorted_names(&scoped.unstamped), vec!["kubectl-applied"]);
        assert!(scoped.foreign.is_empty() && scoped.unattributed.is_empty());
        assert!(scoped.scope_notes().is_empty());

        // A Kubernetes cluster with no records at all: the same.
        let none = Tenancy::from_records(&[], "a");
        let scoped = scope_sweep(mixed_sweep(), SweepScope::Cluster("a"), none);
        assert_eq!(scoped.managed.len(), 4);
    }

    #[test]
    fn a_records_scope_keeps_exactly_those_closures() {
        let hashes: HashSet<String> = ["a2".to_string()].into();
        let mut objects = mixed_sweep();
        objects.managed.push(obj("ConfigMap", "a-older", "a1"));
        let scope = SweepScope::Records {
            cluster: "a",
            hashes: &hashes,
        };
        let scoped = scope_sweep(objects, scope, two_clusters("a"));
        assert_eq!(sorted_names(&scoped.managed), vec!["a-web", "shared"]);
        assert!(scoped.unstamped.is_empty());
        // `a-older` names only a Superseded record of `a`.
        assert_eq!(scoped.other_builds, 1);
    }

    #[test]
    fn scope_notes_name_the_other_cluster() {
        let notes =
            scope_sweep(mixed_sweep(), SweepScope::Cluster("a"), two_clusters("a")).scope_notes();
        assert_eq!(notes[0], "Skipped 1 object that belongs to Kix cluster b.");
        assert!(notes[1].starts_with("Skipped 2 Kix objects that name no Activation record"));
    }

    /// The sweep lists the Activation records after every object LIST, so
    /// every hash a listed object names belongs to a record it read.
    #[tokio::test]
    async fn the_sweep_reads_the_records_after_the_objects() {
        use crate::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        let client = api.client();
        let discovery = discover_resources(&client).await.unwrap();
        let before = api.requests().len();
        sweep_managed(&client, &discovery, SweepScope::Cluster("a"))
            .await
            .unwrap();
        let requests = api.requests().split_off(before);
        let records = format!("GET /apis/{}/activations", keys::API_VERSION);
        let last_object_list = requests
            .iter()
            .rposition(|r| r.contains("labelSelector="))
            .unwrap();
        let record_list = requests.iter().position(|r| *r == records).unwrap();
        assert!(last_object_list < record_list, "{requests:#?}");
    }

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            namespace: "ns".into(),
            name: name.into(),
        }
    }

    /// An object both clusters deploy is not pruned by either: dropping it
    /// from one build keeps it while the other's current record names it.
    #[test]
    fn an_orphan_another_cluster_still_deploys_is_kept() {
        let live = vec![
            obj("ClusterRole", "shared", "a2,b1"),
            obj("ClusterRole", "once-shared", "a2,b0"),
            obj("ConfigMap", "mine", "a2"),
        ];
        let orphans = vec![rid("ClusterRole", "shared"), rid("ConfigMap", "mine")];
        let (prune, kept) = split_shared_orphans(orphans, &live, &two_clusters("a"));
        assert_eq!(prune, vec![rid("ConfigMap", "mine")]);
        assert_eq!(
            kept,
            vec![SharedOrphan {
                rid: rid("ClusterRole", "shared"),
                clusters: vec!["b".into()],
            }]
        );
        assert_eq!(
            kept[0].describe(),
            "kept ClusterRole/shared@ns, still deployed by Kix cluster b"
        );

        // A Namespace is never pruned anyway; the prune lists it as kept.
        let ns = named(
            "Namespace",
            CLUSTER_SCOPED,
            "shared-ns",
            keys::ACTIVATIONS,
            "a2,b1",
        );
        let ns_rid = ResourceId::from_value(&to_manifest_value(&ns));
        let split = split_shared_orphans(vec![ns_rid.clone()], &[ns], &two_clusters("a"));
        assert_eq!(split, (vec![ns_rid], vec![]));

        let (prune, kept) = split_shared_orphans(
            vec![rid("ClusterRole", "shared")],
            &live,
            &two_clusters("b"),
        );
        assert!(prune.is_empty());
        assert_eq!(kept[0].clusters, vec!["a".to_string()]);

        // A Superseded record of `b` no longer deploys anything.
        let (prune, kept) = split_shared_orphans(
            vec![rid("ClusterRole", "once-shared")],
            &live,
            &two_clusters("a"),
        );
        assert_eq!(prune, vec![rid("ClusterRole", "once-shared")]);
        assert!(kept.is_empty());
    }

    const RBAC_V1: &str = "/apis/rbac.authorization.k8s.io/v1";

    fn gets(api: &crate::cluster::fake_api::FakeApi, path: &str) -> usize {
        let line = format!("GET {path}");
        api.requests().iter().filter(|r| **r == line).count()
    }

    /// A group version that `/apis` lists but that answers 404, as a CRD's
    /// group can for a moment after the CRD is Established, is fetched again
    /// until it answers.
    #[tokio::test(start_paused = true)]
    async fn discovery_waits_for_a_listed_group_version_that_404s() {
        use crate::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, 2, 404);
        let found = discover_resources(&api.client()).await.unwrap();
        assert!(found.iter().any(|(ar, _)| ar.kind == "ClusterRole"));
        assert_eq!(gets(&api, RBAC_V1), 3);
    }

    /// A group version that keeps answering 404 ends discovery after
    /// `DISCOVERY_SETTLE`, and the error names it.
    #[tokio::test(start_paused = true)]
    async fn discovery_that_never_settles_names_the_group_version() {
        use crate::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, u32::MAX, 404);
        let start = tokio::time::Instant::now();
        let err = discover_resources(&api.client()).await.unwrap_err();
        let waited = start.elapsed();
        assert!(
            waited >= DISCOVERY_SETTLE && waited <= DISCOVERY_SETTLE + DISCOVERY_BACKOFF_MAX,
            "{waited:?}"
        );
        let msg = err.to_string();
        assert!(msg.contains("rbac.authorization.k8s.io/v1"), "{msg}");
        assert!(msg.contains("404"), "{msg}");
    }

    /// Only a 404 is waited out. Other failures have already been through
    /// the transport's retries, so discovery reports them at once.
    #[tokio::test(start_paused = true)]
    async fn discovery_reports_other_failures_at_once() {
        use crate::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, u32::MAX, 403);
        let start = tokio::time::Instant::now();
        assert!(discover_resources(&api.client()).await.is_err());
        assert_eq!(start.elapsed(), Duration::ZERO);
        assert_eq!(gets(&api, RBAC_V1), 1);
    }

    /// The targeted fetch behind refresh-on-miss keeps the versions of a
    /// group that answer when another one 404s.
    #[tokio::test(start_paused = true)]
    async fn group_discovery_skips_a_version_that_404s() {
        use crate::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        api.fail_next(RBAC_V1, u32::MAX, 404);
        let found = discover_group(&api.client(), "rbac.authorization.k8s.io")
            .await
            .unwrap();
        assert!(found.resources.is_empty());
        assert_eq!(found.missing, vec![RBAC_V1.to_string()]);
        let core = discover_group(&api.client(), "").await.unwrap();
        assert!(core.resources.iter().any(|(ar, _)| ar.kind == "ConfigMap"));
    }

    const TWO_V1: &str = "/apis/example.kix.test/v1";
    const TWO_V1BETA1: &str = "/apis/example.kix.test/v1beta1";

    /// `(kind, version)` of each resource of the two-version group.
    fn versions_of(resources: &[(ApiResource, Scope)]) -> Vec<(String, String)> {
        let mut v: Vec<(String, String)> = resources
            .iter()
            .filter(|(ar, _)| ar.group == crate::cluster::fake_api::TWO_VERSION_GROUP)
            .map(|(ar, _)| (ar.kind.clone(), ar.version.clone()))
            .collect();
        v.sort();
        v
    }

    fn pair(kind: &str, version: &str) -> (String, String) {
        (kind.to_string(), version.to_string())
    }

    /// A group's preferred version is fetched first, and the first version
    /// that serves a kind wins: `Gizmo` at v1, `Gadget` from v1beta1.
    #[tokio::test]
    async fn group_discovery_walks_the_preferred_version_first() {
        use crate::cluster::fake_api::{FakeApi, TWO_VERSION_GROUP};
        let api = FakeApi::new([]);
        let walk = discover_group(&api.client(), TWO_VERSION_GROUP)
            .await
            .unwrap();
        assert_eq!(
            versions_of(&walk.resources),
            vec![pair("Gadget", "v1beta1"), pair("Gizmo", "v1")]
        );
        let order: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| r.ends_with(TWO_V1) || r.ends_with(TWO_V1BETA1))
            .collect();
        assert_eq!(
            order,
            vec![format!("GET {TWO_V1}"), format!("GET {TWO_V1BETA1}")]
        );
    }

    /// When the preferred version 404s, the walk keeps what the other
    /// version serves, `Gizmo` included at v1beta1, and says what it skipped.
    #[tokio::test]
    async fn group_discovery_keeps_the_versions_that_answer() {
        use crate::cluster::fake_api::{FakeApi, TWO_VERSION_GROUP};
        let api = FakeApi::new([]);
        api.fail_next(TWO_V1, u32::MAX, 404);
        let walk = discover_group(&api.client(), TWO_VERSION_GROUP)
            .await
            .unwrap();
        assert_eq!(
            versions_of(&walk.resources),
            vec![pair("Gadget", "v1beta1"), pair("Gizmo", "v1beta1")]
        );
        assert_eq!(walk.missing, vec![TWO_V1.to_string()]);
    }

    /// A walk that skipped the preferred version does not move a cached kind
    /// to the older version, but still adds a kind the cache lacks. A
    /// complete walk replaces the cached entry.
    #[tokio::test]
    async fn a_partial_walk_does_not_downgrade_a_cached_kind() {
        use crate::cluster::fake_api::{FakeApi, TWO_VERSION_GROUP};
        let api = FakeApi::new([]);
        let complete = discover_group(&api.client(), TWO_VERSION_GROUP)
            .await
            .unwrap();
        let cached: Vec<(ApiResource, Scope)> = complete
            .resources
            .iter()
            .filter(|(ar, _)| ar.kind == "Gizmo")
            .cloned()
            .collect();

        api.fail_next(TWO_V1, 1, 404);
        let partial = discover_group(&api.client(), TWO_VERSION_GROUP)
            .await
            .unwrap();
        let merged = merge_discovery(&cached, partial);
        assert_eq!(
            versions_of(&merged),
            vec![pair("Gadget", "v1beta1"), pair("Gizmo", "v1")]
        );

        let stale: Vec<(ApiResource, Scope)> = merged
            .into_iter()
            .map(|(mut ar, scope)| {
                ar.version = "v1alpha1".into();
                (ar, scope)
            })
            .collect();
        let merged = merge_discovery(&stale, complete);
        assert_eq!(
            versions_of(&merged),
            vec![pair("Gadget", "v1beta1"), pair("Gizmo", "v1")]
        );
    }
}
