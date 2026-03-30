//! Operator-mode helpers for CLI commands.
//!
//! When `--operator` is passed to deploy/rollback/gc, the CLI delegates
//! the actual cluster mutation to the kix-operator. The CLI creates or patches
//! Activation CRs and watches their status for progress, rather than calling
//! the reconcile engine directly.

use std::time::Duration;

use kube::api::{Api, DynamicObject, ListParams, Patch, PatchParams};
use kube::client::Client;
use kube::discovery::ApiResource;
use miette::{Result, miette};
use serde_json::{Value, json};

use kix::cluster::activation::{BUILT_VIA_ANNOTATION, CLUSTER_LABEL};
use kix::cluster::apply::IDENTITY_HASH_ANNOTATION;
use kix::cluster::fetch;

use crate::output;

/// Build the ApiResource descriptor for kix Activation CRs.
pub fn activation_api_resource() -> ApiResource {
    ApiResource {
        group: "kix.dev".into(),
        version: "v1alpha1".into(),
        api_version: "kix.dev/v1alpha1".into(),
        kind: "Activation".into(),
        plural: "activations".into(),
    }
}

/// Connect to the cluster and verify the operator is running (Activation CRD exists).
pub async fn connect_and_verify(
    context: Option<&str>,
    quiet: bool,
) -> Result<(Client, ApiResource)> {
    if !quiet {
        println!("Connecting to cluster...");
    }

    let client = fetch::make_client(context)
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    let ar = activation_api_resource();
    let api: Api<DynamicObject> = Api::all_with(client.clone(), &ar);

    // Verify CRD exists
    api.list(&ListParams::default().limit(1))
        .await
        .map_err(|e| {
            miette!(
                "Activation CRD not registered on cluster: {e}\n\
                 Ensure the kix-operator is deployed and CRDs are applied."
            )
        })?;

    if !quiet {
        println!("  {} Activation CRD found", output::green("✓"));
    }

    Ok((client, ar))
}

/// Create or update an Activation CR to trigger operator reconciliation.
///
/// The CR is created without a phase — the operator treats it as Queued
/// and handles the lifecycle transition (Queued → Deploying → Active).
pub async fn apply_activation(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    cluster_name: &str,
    source_path: &str,
    identity_hash: Option<&str>,
) -> Result<()> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);

    let mut annotations = serde_json::Map::new();
    if let Some(hash) = identity_hash {
        annotations.insert(
            IDENTITY_HASH_ANNOTATION.to_string(),
            Value::String(hash.to_string()),
        );
    }
    annotations.insert(
        BUILT_VIA_ANNOTATION.to_string(),
        Value::String(source_path.to_string()),
    );

    let patch = json!({
        "apiVersion": "kix.dev/v1alpha1",
        "kind": "Activation",
        "metadata": {
            "name": activation_name,
            "labels": {
                "app.kubernetes.io/managed-by": "kix",
                CLUSTER_LABEL: cluster_name,
            },
            "annotations": annotations,
        },
        "spec": {
            "cluster": cluster_name,
            "source": {
                "type": "storePath",
                "path": source_path,
            },
        },
    });

    api.patch(
        activation_name,
        &PatchParams::apply("kix-cli").force(),
        &Patch::Apply(&patch),
    )
    .await
    .map_err(|e| miette!("failed to apply Activation CR: {e}"))?;

    Ok(())
}

/// Watch an Activation CR's status until it reaches Active phase or fails.
///
/// Polls the Activation status periodically, printing wave progress as it happens.
/// Completion is signaled by `status.phase == "Active"`.
pub async fn watch_activation_progress(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    _expected_source: &str,
    quiet: bool,
) -> Result<()> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let poll_interval = Duration::from_secs(2);
    let timeout = Duration::from_secs(600);
    let start = std::time::Instant::now();

    let mut last_wave_count = 0usize;
    let mut seen_deploying = false;

    loop {
        if start.elapsed() > timeout {
            return Err(miette!(
                "timed out waiting for operator to reconcile Activation '{}'",
                activation_name
            ));
        }

        let act = api
            .get(activation_name)
            .await
            .map_err(|e| miette!("failed to get Activation '{}': {e}", activation_name))?;

        let phase = act
            .data
            .pointer("/status/phase")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let waves = act.data.pointer("/status/waves").and_then(|v| v.as_array());

        let total_waves = act
            .data
            .pointer("/status/totalWaves")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as usize;

        // Print new wave completions
        if let Some(waves) = waves {
            if !seen_deploying && phase == "Deploying" {
                seen_deploying = true;
                if !quiet {
                    println!(
                        "  {} Operator is reconciling ({} waves)...",
                        output::dim("•"),
                        total_waves,
                    );
                }
            }

            #[allow(clippy::mut_range_bound)]
            for i in last_wave_count..waves.len() {
                if let Some(wave) = waves.get(i) {
                    let status = wave
                        .get("status")
                        .and_then(|v| v.as_str())
                        .unwrap_or("Pending");
                    let applied = wave.get("applied").and_then(|v| v.as_u64()).unwrap_or(0);
                    let failed = wave.get("failed").and_then(|v| v.as_u64()).unwrap_or(0);
                    let resources = wave.get("resources").and_then(|v| v.as_u64()).unwrap_or(0);

                    if status == "Complete" || status == "Failed" {
                        if !quiet {
                            let status_str = if status == "Complete" {
                                output::green(status)
                            } else {
                                output::red(status)
                            };
                            println!(
                                "  {} Wave {}: {} ({}/{} applied, {} failed)",
                                if status == "Complete" {
                                    output::green("✓")
                                } else {
                                    output::red("✗")
                                },
                                i + 1,
                                status_str,
                                applied,
                                resources,
                                failed,
                            );
                        }
                        last_wave_count = i + 1;
                    }
                }
            }
        }

        // Completion: phase is Active
        if phase == "Active" {
            if !quiet {
                println!(
                    "  {} Activation '{}' is {}",
                    output::green("✓"),
                    activation_name,
                    output::green("Active"),
                );
            }
            return Ok(());
        }

        // Check for Superseded (another activation took over)
        if phase == "Superseded" {
            return Err(miette!(
                "Activation '{}' was superseded by a newer activation",
                activation_name
            ));
        }

        if phase == "Failed" {
            let message = act
                .data
                .pointer("/status/message")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error");
            return Err(miette!(
                "Operator reconciliation failed for '{}': {}",
                activation_name,
                message
            ));
        }

        tokio::time::sleep(poll_interval).await;
    }
}

/// Wait for an Activation CR to be fully deleted (finalizer cleanup complete).
pub async fn wait_for_deletion(
    client: &Client,
    ar: &ApiResource,
    activation_name: &str,
    quiet: bool,
) -> Result<()> {
    let api: Api<DynamicObject> = Api::all_with(client.clone(), ar);
    let poll_interval = Duration::from_secs(2);
    let timeout = Duration::from_secs(300);
    let start = std::time::Instant::now();

    loop {
        if start.elapsed() > timeout {
            return Err(miette!(
                "timed out waiting for Activation '{}' to be deleted",
                activation_name
            ));
        }

        match api.get(activation_name).await {
            Ok(act) => {
                // Check if deletion is in progress
                if act.metadata.deletion_timestamp.is_some() && !quiet {
                    eprint!("\r  {} Finalizer cleanup in progress...", output::dim("•"),);
                }
            }
            Err(kube::Error::Api(ref e)) if e.code == 404 => {
                if !quiet {
                    eprintln!();
                    println!(
                        "  {} Activation '{}' deleted",
                        output::green("✓"),
                        activation_name,
                    );
                }
                return Ok(());
            }
            Err(e) => {
                return Err(miette!(
                    "failed to check Activation '{}': {e}",
                    activation_name
                ));
            }
        }

        tokio::time::sleep(poll_interval).await;
    }
}
