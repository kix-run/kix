//! Orphans another Kix cluster still deploys.
//!
//! Two Kix clusters on one Kubernetes cluster can both contain an object, such
//! as an identical ClusterRole. When one of them drops it from its build, the
//! comparison of builds plans it as an orphan, but the other cluster's current
//! build still contains it. Every command that prunes from a plan passes its
//! orphans through [`keep_shared`] so the plan lists such an object as kept,
//! and deletes through `kix::cluster::prune_guard::PruneGuard`, which checks
//! again at the delete.

use kix::cluster::{fetch, fetch::SharedOrphan};
use kix::manifest::types::ResourceId;
use kube::client::Client;
use miette::{Result, miette};

use crate::output;

/// Split `orphans` into the ones to prune and the ones another Kix cluster's
/// current Activation record still names. Reads each candidate, then the
/// records.
pub async fn keep_shared(
    client: &Client,
    cluster: &str,
    orphans: Vec<ResourceId>,
) -> Result<(Vec<ResourceId>, Vec<SharedOrphan>)> {
    if orphans.is_empty() {
        return Ok((orphans, Vec::new()));
    }
    let discovery = fetch::discover_resources(client)
        .await
        .map_err(|e| miette!("{e}"))?;
    fetch::split_shared_orphans_live(client, &discovery, orphans, cluster)
        .await
        .map_err(|e| miette!("cannot check whether another Kix cluster deploys an orphan: {e}"))
}

/// One line per kept object.
pub fn print(shared: &[SharedOrphan]) {
    for s in shared {
        crate::say!("  {} prune: {}", output::yellow("="), s.describe());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::activation::PHASE_ACTIVE;
    use kix::cluster::fake_api::FakeApi;
    use kix::manifest::keys;
    use kix::manifest::types::CLUSTER_SCOPED;
    use serde_json::{Value, json};

    fn record(cluster: &str, hash: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": format!("rec-{hash}"),
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): hash },
            },
            "status": { "phase": PHASE_ACTIVE },
        })
    }

    fn rid(kind: &str, ns: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            namespace: ns.into(),
            name: name.into(),
        }
    }

    /// Kix cluster `a` drops a ClusterRole and a ConfigMap that `b` still
    /// deploys, and a ConfigMap only `a` had: the plan keeps the first two.
    /// The unnamespaced ConfigMap is read in `default`, where it was applied.
    #[tokio::test]
    async fn orphans_another_cluster_still_deploys_are_kept() {
        let api = FakeApi::new([
            record("a", "a1"),
            record("b", "b1"),
            json!({
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "ClusterRole",
                "metadata": { "name": "shared", "annotations": { (keys::ACTIVATIONS): "a1,b1" } },
            }),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "shared-cm",
                    "namespace": "default",
                    "annotations": { (keys::ACTIVATIONS): "a1,b1" },
                },
            }),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "mine",
                    "namespace": "app",
                    "annotations": { (keys::ACTIVATIONS): "a1" },
                },
            }),
        ]);
        let orphans = vec![
            rid("ClusterRole", CLUSTER_SCOPED, "shared"),
            rid("ConfigMap", CLUSTER_SCOPED, "shared-cm"),
            rid("ConfigMap", "app", "mine"),
        ];
        let (prune, kept) = keep_shared(&api.client(), "a", orphans).await.unwrap();
        assert_eq!(prune, vec![rid("ConfigMap", "app", "mine")]);
        let kept: Vec<&str> = kept.iter().map(|s| s.rid.name.as_str()).collect();
        assert_eq!(kept, vec!["shared", "shared-cm"]);
    }
}
