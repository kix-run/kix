use std::path::Path;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::{SnapshotArgs, SnapshotCommand, SnapshotSaveArgs};

use super::CommandContext;

pub fn run(args: &SnapshotArgs, ctx: &mut CommandContext) -> Result<()> {
    match &args.command {
        SnapshotCommand::Save(save_args) => run_save(save_args, ctx),
    }
}

fn run_save(args: &SnapshotSaveArgs, ctx: &mut CommandContext) -> Result<()> {
    let out_dir = Path::new(&args.dir);

    // Reject path traversal
    for component in out_dir.components() {
        if matches!(component, std::path::Component::ParentDir) {
            return Err(miette!(
                "snapshot directory must not contain '..' components"
            ));
        }
    }

    let global = ctx.global.clone();

    ctx.runtime.block_on(async {
        let context = global.context.as_deref();
        let client = fetch::make_client(context)
            .await
            .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

        if !global.quiet {
            eprintln!("Discovering API resources...");
        }

        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("{e}"))?;

        if !global.quiet {
            eprintln!(
                "Fetching managed resources ({} resource types)...",
                discovery.len()
            );
        }

        let objects = fetch::fetch_managed_resources(&client, &discovery)
            .await
            .map_err(|e| miette!("failed to fetch resources: {e}"))?;

        if !global.quiet {
            eprintln!("Fetched {} resources", objects.len());
        }

        // The kix-owned view of each object (same recipe as `kix diff`), so
        // a snapshot compares to a build the way the live cluster does.
        let resources: Vec<(ResourceId, Value)> = fetch::kix_owned_manifests(objects)
            .into_iter()
            .map(|value| (ResourceId::from_value(&value), value))
            .collect();

        // Write to temp dir, then atomic swap
        let parent = out_dir.parent().unwrap_or(Path::new("."));
        std::fs::create_dir_all(parent).into_diagnostic()?;

        let tmp_dir = tempfile::tempdir_in(parent).into_diagnostic()?;
        let tmp_path = tmp_dir.path();

        let mut written = 0usize;
        for (id, value) in &resources {
            let ns_dir = if id.namespace == CLUSTER_SCOPED {
                CLUSTER_SCOPED.to_string()
            } else {
                id.namespace.clone()
            };
            let file_dir = tmp_path.join(&ns_dir);
            std::fs::create_dir_all(&file_dir).into_diagnostic()?;

            let filename = format!("{}-{}.yaml", id.name, id.kind.to_lowercase());
            let filepath = file_dir.join(&filename);

            let yaml = serde_yml::to_string(&value).into_diagnostic()?;
            std::fs::write(&filepath, &yaml).into_diagnostic()?;
            written += 1;
        }

        // Write README
        let timestamp = chrono_timestamp();
        let readme = format!(
            "# Cluster Snapshot\n\n\
             **Timestamp:** {timestamp}\n\
             **Context:** {context}\n\
             **Resources written:** {written}\n\n\
             ## Command\n\n\
             ```\nkix snapshot save {dir}\n```\n",
            context = global.context.as_deref().unwrap_or("(current)"),
            dir = args.dir,
        );
        std::fs::write(tmp_path.join("README.md"), &readme).into_diagnostic()?;

        // Atomic swap: remove old, rename temp into place
        if out_dir.exists() {
            std::fs::remove_dir_all(out_dir).into_diagnostic()?;
        }

        // Persist the tempdir (prevent auto-cleanup) then rename
        let persist_path = tmp_dir.keep();
        std::fs::rename(&persist_path, out_dir).into_diagnostic()?;

        if !global.quiet {
            eprintln!("Saved {written} resources to {}/", args.dir);
        }

        Ok(())
    })
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
