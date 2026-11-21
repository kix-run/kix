use std::path::Path;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use crate::client;
use kix::cluster::activation::Records;
use kix::cluster::{discovery, inventory, owned_view};
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};
use kube::Client;
use kube::api::DynamicObject;

use crate::cli::SnapshotArgs;

use super::CommandContext;

/// Discover API resources and sweep all objects managed by `cluster`.
///
/// Runs the domain gate via [`Records::open`] so an unmigrated cluster is
/// rejected rather than attributing all objects to `cluster`.
async fn sweep_cluster(client: &Client, cluster: &str) -> Result<inventory::ManagedSweep> {
    crate::esay!("Discovering API resources...");

    let discovery = discovery::discover_resources(client)
        .await
        .map_err(|e| miette!("{e}"))?;
    let records = Records::open(client, &discovery).map_err(|e| miette!("{e}"))?;

    crate::esay!(
        "Fetching managed resources ({} resource types)...",
        discovery.len()
    );

    let sweep = inventory::sweep_managed(
        client,
        &discovery,
        &records,
        inventory::SweepScope::Cluster(cluster),
    )
    .await
    .map_err(|e| miette!("failed to fetch resources: {e}"))?;
    sweep
        .tenancy
        .require_records()
        .map_err(|e| miette!("{e}"))?;
    Ok(sweep)
}

pub fn run(args: &SnapshotArgs, ctx: &mut CommandContext) -> Result<()> {
    let out_dir = Path::new(&args.out);

    for component in out_dir.components() {
        if matches!(component, std::path::Component::ParentDir) {
            return Err(miette!(
                "snapshot directory must not contain '..' components"
            ));
        }
    }

    let global = ctx.global.clone();
    // A person types the cluster's key in flake.nix. Its deploy records
    // carry its name, which differs when the definition sets one.
    let cluster = ctx.cluster_identity(&args.cluster, super::Lookup::ReadOnly)?;

    ctx.runtime()?.block_on(async {
        let context = global.context.as_deref();
        let client = client::make_client(context)
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

        let sweep = sweep_cluster(&client, &cluster).await?;

        crate::esay!("Fetched {} resources", sweep.managed.len());
        for note in sweep.scope_notes() {
            crate::esay!("{note}");
        }
        let resources = snapshot_resources(sweep.managed);

        // Stage files in a sibling temporary directory and swap into place so
        // an interrupted snapshot does not leave a partial output directory.
        let parent = out_dir.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(parent).into_diagnostic()?;

        let tmp_dir = tempfile::tempdir_in(parent).into_diagnostic()?;
        let tmp_path = tmp_dir.path();

        let written = write_resources(tmp_path, &resources)?;

        let timestamp = chrono_timestamp();
        let readme = format!(
            "# Cluster Snapshot\n\n\
             **Timestamp:** {timestamp}\n\
             **Cluster:** {cluster}\n\
             **Context:** {context}\n\
             **Resources written:** {written}\n\n\
             ## Command\n\n\
             ```\nkix snapshot {key} --out {dir}\n```\n",
            key = args.cluster,
            context = global.context.as_deref().unwrap_or("(current)"),
            dir = args.out,
        );
        std::fs::write(tmp_path.join("README.md"), &readme).into_diagnostic()?;

        if out_dir.exists() {
            std::fs::remove_dir_all(out_dir).into_diagnostic()?;
        }

        let persist_path = tmp_dir.keep();
        std::fs::rename(&persist_path, out_dir).into_diagnostic()?;

        crate::esay!("Saved {written} resources to {}/", args.out);

        Ok(())
    })
}

/// Extract the Kix-owned manifest view for each live object, redacting Secret
/// values so snapshots can be compared against builds without exposing live
/// secrets.
fn snapshot_resources(objects: Vec<DynamicObject>) -> Vec<(ResourceId, Value)> {
    owned_view::kix_owned_manifests(objects)
        .into_iter()
        .map(|value| (ResourceId::from_value(&value), value))
        .collect()
}

/// Write each resource to `<dir>/<namespace>/<name>-<kind>.yaml` and return
/// how many were written.
fn write_resources(dir: &Path, resources: &[(ResourceId, Value)]) -> Result<usize> {
    for (id, value) in resources {
        let ns_dir = if id.namespace == CLUSTER_SCOPED {
            CLUSTER_SCOPED.to_string()
        } else {
            id.namespace.clone()
        };
        let file_dir = dir.join(&ns_dir);
        std::fs::create_dir_all(&file_dir).into_diagnostic()?;

        let filename = format!("{}-{}.yaml", id.name, id.kind.to_lowercase());
        let yaml = kix::yaml::to_string(&value).into_diagnostic()?;
        std::fs::write(file_dir.join(&filename), &yaml).into_diagnostic()?;
    }
    Ok(resources.len())
}

fn chrono_timestamp() -> String {
    use std::time::SystemTime;
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    let mut y = 1970i64;
    let mut remaining_days = days as i64;
    loop {
        let year_days = if is_leap(y) { 366 } else { 365 };
        if remaining_days < year_days {
            break;
        }
        remaining_days -= year_days;
        y += 1;
    }
    let month_days: &[i64] = if is_leap(y) {
        &[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        &[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m = 1;
    for &md in month_days {
        if remaining_days < md {
            break;
        }
        remaining_days -= md;
        m += 1;
    }
    let d = remaining_days + 1;

    format!("{y:04}-{m:02}-{d:02}T{hours:02}:{minutes:02}:{seconds:02}Z")
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::fake_api::FakeApi;
    use kix::manifest::keys;
    use kix::manifest::lifecycle::RECORD_KIND;
    use serde_json::json;

    /// Verify that live Secret values are redacted before writing snapshot files.
    #[tokio::test]
    async fn a_snapshot_writes_no_live_secret_value() {
        let api = FakeApi::new([
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": RECORD_KIND,
                "metadata": {
                    "name": "rec-a1",
                    "labels": {
                        "app.kubernetes.io/managed-by": "kix",
                        (keys::CLUSTER_LABEL): "a",
                    },
                    "annotations": { (keys::IDENTITY_HASH): "a1" },
                },
                "status": { "phase": "Active" },
            }),
            json!({
                "apiVersion": "v1",
                "kind": "Secret",
                "metadata": {
                    "name": "creds",
                    "namespace": "app",
                    "labels": { "app.kubernetes.io/managed-by": "kix" },
                    "annotations": {
                        (keys::IDENTITY_HASH): "h-creds",
                        (keys::ACTIVATIONS): "a1",
                    },
                    "managedFields": [{ "manager": "kix", "operation": "Update" }],
                },
                // "hunter2"
                "data": { "password": "aHVudGVyMg==" },
            }),
        ]);
        let sweep = sweep_cluster(&api.client(), "a").await.unwrap();
        let resources = snapshot_resources(sweep.managed);
        let dir = tempfile::tempdir().unwrap();
        write_resources(dir.path(), &resources).unwrap();

        let text = std::fs::read_to_string(dir.path().join("app/creds-secret.yaml")).unwrap();
        assert!(text.contains(owned_view::HIDDEN_SECRET_VALUE), "{text}");
        assert!(!text.contains("aHVudGVyMg=="), "{text}");
    }

    /// Verify that [`sweep_cluster`] rejects clusters whose records sit under a retired API group.
    #[tokio::test]
    async fn a_snapshot_of_an_unmigrated_cluster_is_refused() {
        let api = FakeApi::new([]);
        api.serve_retired_records();
        let Err(err) = sweep_cluster(&api.client(), "a").await else {
            panic!("an unmigrated cluster was swept");
        };
        let err = err.to_string();
        assert!(err.contains("kix migrate domain"), "{err}");
    }
}
