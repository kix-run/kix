//! kix-operator — Kubernetes operator that watches Activation CRs and reconciles cluster state.
//!
//! The operator reuses the same deploy engine as `kix deploy` (from `kix-cluster`),
//! but runs as a long-lived controller instead of a one-shot CLI command.
//!
//! # How it works
//!
//! 1. Watches Activation CRs (kix.dev/v1alpha1) via kube-rs informer
//! 2. Phase-based lifecycle: Queued → Deploying → Active → Superseded
//! 3. Unified reconcile: fetches live cluster state, compares identity-hashes,
//!    applies only what changed (works for both new deploys and drift correction)
//! 4. On delete (finalizer): cleans up resources for Active activations only
//!
//! # Reconcile loop prevention
//!
//! **Stream-level generation filter** — a custom `generation_filter` on the
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

/// Build the ApiResource descriptor for kix Activation CRs.
fn activation_api_resource() -> ApiResource {
    ApiResource {
        group: "kix.dev".into(),
        version: "v1alpha1".into(),
        api_version: "kix.dev/v1alpha1".into(),
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

    // Verify CRD is registered by attempting a list
    match activations
        .list(&kube::api::ListParams::default().limit(1))
        .await
    {
        Ok(_) => tracing::info!("Activation CRD is registered"),
        Err(e) => {
            tracing::error!("Activation CRD not found on cluster: {e}");
            tracing::error!(
                "Ensure the Activation CRD (activations.kix.dev) is deployed before starting the operator"
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
