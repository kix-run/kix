//! API discovery: the resource types the apiserver serves, and the API a
//! request about one object goes to.

use std::collections::HashSet;
use std::time::Duration;

use super::errors::FetchError;
use crate::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::{
    api::{Api, DynamicObject},
    client::Client,
    discovery::{ApiResource, Scope},
};

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

/// The API a request about `rid` goes to. For a namespaced kind keyed
/// [`CLUSTER_SCOPED`] (its manifest names no namespace) that is `default`:
/// `apply::apply_resource` refuses to create such an
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

#[cfg(test)]
mod tests {
    use super::*;

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
