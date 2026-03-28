//! kix-operator — Kubernetes operator that watches Activation CRs and reconciles cluster state.
//!
//! The operator reuses the same deploy engine as `kix deploy` (from `kix-cluster`),
//! but runs as a long-lived controller instead of a one-shot CLI command.
//!
//! # How it works
//!
//! 1. Watches Activation CRs (kix.dev/v1alpha1) via kube-rs informer
//! 2. On create/update: loads the store graph from `spec.source.path`, computes
//!    a local DAG diff against the previous activation, and applies wave-by-wave
//! 3. On delete (finalizer): cleans up resources unique to the deleted activation
//!
//! # Requirements
//!
//! - `nix-store` binary on the host (for `nix-store -q --graph`)
//! - Read access to `/nix/store/` (the activation's store path must be present)
//! - Activation CRD must be registered on the cluster before starting

mod controller;
mod observer;

use std::sync::Arc;

use futures::StreamExt;
use kube::{
    Client,
    api::{Api, DynamicObject},
    discovery::ApiResource,
    runtime::Controller,
    runtime::watcher,
};
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

use controller::{Context, error_policy, reconcile_activation};

/// Build the ApiResource descriptor for kix Activation CRs.
fn activation_api_resource() -> ApiResource {
    ApiResource {
        group: "kix.dev".into(),
        version: "v1alpha1".into(),
        api_version: "kix.dev/v1alpha1".into(),
        kind: "Activation".into(),
        plural: "activations".into(),
    }
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

    // Create Kubernetes client (works both in-cluster and via kubeconfig)
    let client = Client::try_default().await?;
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

    // Start the controller (use new_with for dynamic types)
    tracing::info!("Starting Activation controller");
    Controller::new_with(activations, watcher::Config::default(), ar.clone())
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
