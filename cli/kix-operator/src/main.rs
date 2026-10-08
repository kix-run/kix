//! Kubernetes operator that watches Activations and reconciles cluster state.
//!
//! The operator reuses the same deploy engine as `kix deploy` (from `kix-cluster`),
//! but runs as a long-lived controller instead of a one-shot CLI command.
//!
//! # How it works
//!
//! 1. Watches Activation CRs (kix.run/v1alpha1) via kube-rs informer
//! 2. Phase-based lifecycle: Queued → Deploying → Active → Superseded
//! 3. Unified reconcile: fetches live cluster state, compares identity-hashes,
//!    applies only what changed (works for both new deploys and drift correction)
//! 4. On delete (finalizer): cleans up resources for Active activations only
//!
//! # Reconcile loop prevention
//!
//! A stream-level `generation_filter`
//! watcher stream drops events where `metadata.generation` hasn't changed.
//! This prevents status-only changes from even reaching the reconciler.
//! (kube-rs's built-in `predicate_filter` can't be used with `DynamicObject`
//! because `ApiResource` doesn't implement `Default`.)
//!
//! # Requirements
//!
//! - `nix-store` binary on the host (for `nix-store -q --graph`)
//! - Read access to `/nix/store/` (the activation's store path must be present)
//! - Activation CRD must be registered on the cluster before starting

mod controller;
mod k8s_events;
mod observer;

use std::collections::HashMap;
use std::sync::Arc;

use futures::StreamExt;
use kube::{
    api::{Api, DynamicObject},
    discovery::ApiResource,
    runtime::{Controller, WatchStreamExt, reflector::store::Writer, watcher},
};
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

use controller::{Context, error_policy, reconcile_activation};
use kix::manifest::keys;

/// Build the ApiResource descriptor for kix Activation CRs.
fn activation_api_resource() -> ApiResource {
    ApiResource {
        group: keys::GROUP.into(),
        version: "v1alpha1".into(),
        api_version: keys::API_VERSION.into(),
        kind: kix::manifest::lifecycle::RECORD_KIND.into(),
        plural: "activations".into(),
    }
}

/// Stream-level generation filter for `DynamicObject`.
///
/// kube-rs's `predicate_filter(predicates::generation)` requires
/// `K::DynamicType: Default`, which `ApiResource` doesn't implement.
/// This is a manual equivalent: it tracks the last seen generation per
/// object name and drops events where the generation hasn't changed
/// (i.e., status-only updates).
fn generation_filter(
    stream: impl futures::Stream<Item = Result<DynamicObject, watcher::Error>>,
) -> impl futures::Stream<Item = Result<DynamicObject, watcher::Error>> {
    let mut cache: HashMap<String, i64> = HashMap::new();
    stream.filter_map(move |item| {
        let emit = match &item {
            Ok(obj) => {
                let name = obj.metadata.name.clone().unwrap_or_default();
                let generation = obj.metadata.generation.unwrap_or(0);
                let changed = cache.get(&name).is_none_or(|&old| old != generation);
                if changed {
                    cache.insert(name, generation);
                }
                changed
            }
            Err(_) => true,
        };
        async move { if emit { Some(item) } else { None } }
    })
}

/// Refuse to start on a cluster whose records sit under a retired API group.
///
/// Discovery that fails is a refusal too. It used to be logged and passed
/// over, which started the operator unchecked on exactly the kind of cluster
/// the gate is for. Kubernetes restarts the pod, and the next start checks
/// again. Only Kix's own groups, current and retired, are discovered: the
/// gate needs nothing else, and an unrelated API that is down must not keep
/// the operator from starting.
async fn check_domain(client: &kube::Client) -> anyhow::Result<()> {
    let groups: Vec<&str> = std::iter::once(keys::GROUP)
        .chain(kix::legacy_domain::DOMAINS.iter().copied())
        .collect();
    let discovery = match kix::cluster::fetch::discover_groups(client, &groups).await {
        Ok(discovery) => discovery,
        Err(e) => {
            tracing::error!("could not check the cluster's API groups: {e}");
            return Err(e.into());
        }
    };
    let groups: Vec<&str> = discovery
        .iter()
        .filter(|(ar, _)| kix::manifest::lifecycle::is_record_kind(&ar.kind))
        .map(|(ar, _)| ar.group.as_str())
        .collect();
    if let Err(e) = kix::legacy_domain::check_cluster(&groups) {
        tracing::error!("{e}");
        return Err(e.into());
    }
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize tracing with env filter (e.g. RUST_LOG=info,kix_operator=debug)
    tracing_subscriber::registry()
        .with(fmt::layer())
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,kix_operator=info,kix::cluster=info")),
        )
        .init();

    tracing::info!("Starting kix-operator");

    // Create Kubernetes client (works both in-cluster and via kubeconfig),
    // through the same transport policy the CLI uses: retries, deadlines,
    // and a cap on requests in flight.
    let client = kix::cluster::client::build_client(
        kube::Config::infer().await?,
        kix::cluster::client::ResiliencePolicy::from_env(),
    )
    .await?;
    tracing::info!("Connected to Kubernetes API server");

    // Set up the Activation API
    let ar = activation_api_resource();
    let activations: Api<DynamicObject> = Api::all_with(client.clone(), &ar);

    // The domain gate, before anything else touches a record.
    //
    // The operator watches one API group and hard-codes the current one, so
    // it cannot tell on its own that a cluster is simply on the retired one:
    // the list below would fail with "CRD not found", which reads as "your
    // CRDs are missing" and sends the reader to fix the wrong thing.
    //
    // Refusing while both groups are live matters more than the wording. In
    // that state a migration is either running or was interrupted, and Kix's
    // records exist twice. An operator that reconciled here would read the
    // copies the migration has created but not yet given a status to, and an
    // Activation with no phase reads as Queued: it would supersede the real
    // Active activation and deploy whatever build that record names.
    check_domain(&client).await?;

    // Verify CRD is registered by attempting a list
    match activations
        .list(&kube::api::ListParams::default().limit(1))
        .await
    {
        Ok(_) => tracing::info!("Activation CRD is registered"),
        Err(e) => {
            tracing::error!("Activation CRD not found on cluster: {e}");
            tracing::error!(
                "Ensure the Activation CRD ({}) is deployed before starting the operator",
                keys::ACTIVATIONS_CRD
            );
            return Err(e.into());
        }
    }

    let ctx = Arc::new(Context {
        client: client.clone(),
        activation_ar: ar.clone(),
    });

    // Build the watcher stream with generation-based dedup.
    // The reflect → applied_objects → generation_filter pipeline means:
    //   1. reflect: populates the in-memory store for the controller
    //   2. applied_objects: collapses watcher events into object snapshots
    //   3. generation_filter: drops events where generation hasn't changed
    //      (status-only updates), preventing them from reaching the reconciler
    let writer = Writer::<DynamicObject>::new(ar.clone());
    let reader = writer.as_reader();
    let stream = generation_filter(
        watcher(activations, watcher::Config::default())
            .default_backoff()
            .reflect(writer)
            .applied_objects(),
    );

    tracing::info!("Starting Activation controller with generation filter");
    Controller::for_stream_with(stream, reader, ar.clone())
        .run(reconcile_activation, error_policy, ctx)
        .for_each(|res| async move {
            match res {
                Ok(o) => tracing::debug!("reconciled: {:?}", o),
                Err(e) => tracing::error!("reconcile failed: {:?}", e),
            }
        })
        .await;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;

    /// Discovery that fails stops the start, since the domain gate could not
    /// run; discovery that answers lets it through.
    #[tokio::test]
    async fn the_operator_does_not_start_unchecked_when_discovery_fails() {
        let api = FakeApi::new([]);
        api.fail_next("/apis", 1, 500);
        assert!(check_domain(&api.client()).await.is_err());
        assert!(check_domain(&api.client()).await.is_ok());
    }

    /// The gate reads only Kix's own groups, so an unrelated API that is
    /// down does not stop the start; Kix's own group that is down does.
    #[tokio::test]
    async fn an_unrelated_api_that_is_down_does_not_stop_the_start() {
        let api = FakeApi::new([]);
        api.fail_next("/apis/rbac.authorization.k8s.io/v1", u32::MAX, 503);
        assert!(check_domain(&api.client()).await.is_ok());

        let api = FakeApi::new([]);
        api.fail_next(&format!("/apis/{}/v1alpha1", keys::GROUP), 1, 503);
        assert!(check_domain(&api.client()).await.is_err());
    }
}
