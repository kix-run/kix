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
    api::DynamicObject,
    runtime::{Controller, WatchStreamExt, reflector::store::Writer, watcher},
};
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

use anyhow::Context as _;
use controller::{Context, error_policy, reconcile_activation};
use kix::cluster::activation::Records;
use kix::manifest::keys;

/// Filter a `DynamicObject` watch stream to emit only when
/// `metadata.generation` changes.
///
/// kube-rs's `predicate_filter(predicates::generation)` requires
/// `K::DynamicType: Default`, which `ApiResource` does not implement. This
/// tracks the last seen generation per object name and drops status-only
/// updates where the generation has not changed.
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

/// Open the cluster's Activation records after verifying the domain gate.
///
/// Fails if API group discovery fails or if retired Kix API groups are still
/// present on the cluster, so Kubernetes restarts the pod rather than running
/// the operator against an unmigrated cluster. Discovers only Kix's own API
/// groups (current and retired) so an unavailable third-party API service does
/// not block startup.
async fn open_records(client: &kube::Client) -> anyhow::Result<Records> {
    let groups: Vec<&str> = std::iter::once(keys::GROUP)
        .chain(kix::legacy_domain::DOMAINS.iter().copied())
        .collect();
    let discovery = kix::cluster::discovery::discover_groups(client, &groups)
        .await
        .context("could not check the cluster's API groups")?;
    let records = Records::open(client, &discovery)?
        .into_records()
        .with_context(|| {
        format!(
            "the Activation CRD ({}) is not served on this cluster; deploy it before starting the operator",
            keys::ACTIVATIONS_CRD
        )
    })?;
    records
        .reachable()
        .await
        .context("the operator cannot list Activation records")?;
    Ok(records)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(fmt::layer())
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,kix_operator=info,kix::cluster=info")),
        )
        .init();

    tracing::info!("Starting kix-operator");

    let client = kix::cluster::client::build_client(
        kube::Config::infer().await?,
        kix::cluster::client::ResiliencePolicy::from_env(),
    )
    .await?;
    tracing::info!("Connected to Kubernetes API server");

    // Verify the domain gate before watching records. If both the retired and
    // current API groups are present (for example, during an in-flight or
    // interrupted `kix migrate domain`), newly copied Activation records may
    // not yet have their `.status.phase` populated; reconciling in that state
    // would treat them as Queued and supersede the active deployment.
    let records = open_records(&client).await?;
    tracing::info!("Activation CRD is registered");
    let ar = records.watch_resource().clone();
    let activations = records.watcher(watcher::Config::default());

    let ctx = Arc::new(Context {
        client: client.clone(),
        records,
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
        activations
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
    /// run, and so does a cluster that has not migrated; a migrated one
    /// lets it through.
    #[tokio::test]
    async fn the_operator_does_not_start_unchecked_when_discovery_fails() {
        let api = FakeApi::new([]);
        api.fail_next("/apis", 1, 500);
        assert!(open_records(&api.client()).await.is_err());
        assert!(open_records(&api.client()).await.is_ok());

        let unmigrated = FakeApi::new([]);
        unmigrated.serve_retired_records();
        let Err(err) = open_records(&unmigrated.client()).await else {
            panic!("an unmigrated cluster's records were opened");
        };
        assert!(err.to_string().contains("kix migrate domain"), "{err}");
    }

    /// The gate reads only Kix's own groups, so an unrelated API that is
    /// down does not stop the start; Kix's own group that is down does.
    #[tokio::test]
    async fn an_unrelated_api_that_is_down_does_not_stop_the_start() {
        let api = FakeApi::new([]);
        api.fail_next("/apis/rbac.authorization.k8s.io/v1", u32::MAX, 503);
        assert!(open_records(&api.client()).await.is_ok());

        let api = FakeApi::new([]);
        api.fail_next(&format!("/apis/{}/v1alpha1", keys::GROUP), 1, 503);
        assert!(open_records(&api.client()).await.is_err());
    }
}
