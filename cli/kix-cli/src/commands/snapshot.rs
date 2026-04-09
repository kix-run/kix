use std::collections::BTreeMap;
use std::path::Path;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::fetch;
use kix::manifest::diff::display::format_diffs;
use kix::manifest::diff::engine::structural_diff;
use kix::manifest::diff::rename::find_renames;
use kix::manifest::diff::{DiffConfig, Difference};
use kix::manifest::serialize::load_manifests_from_dir;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::{OutputFormat, SnapshotArgs, SnapshotCommand, SnapshotDiffArgs, SnapshotSaveArgs};
use crate::output;

use super::CommandContext;

pub fn run(args: &SnapshotArgs, ctx: &mut CommandContext) -> Result<()> {
    match &args.command {
        SnapshotCommand::Save(save_args) => run_save(save_args, ctx),
        SnapshotCommand::Diff(diff_args) => run_diff(diff_args, ctx),
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
        let client = fetch::make_client(context).await.map_err(|e| {
            miette!(
                "failed to connect to cluster: {e}. Check your kubeconfig or try --context <name>"
            )
        })?;

        if !global.quiet {
            eprintln!("Discovering API resources...");
        }

        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("API discovery failed: {e}"))?;

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

        // Collect resources (server-side fields already stripped by normalize_for_diff)
        let mut resources: Vec<(ResourceId, Value)> = Vec::new();
        for mut obj in objects {
            fetch::normalize_for_diff(&mut obj);
            let value = serde_json::to_value(&obj.data).into_diagnostic()?;
            let id = ResourceId::from_value(&value);
            resources.push((id, value));
        }

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

fn run_diff(args: &SnapshotDiffArgs, ctx: &mut CommandContext) -> Result<()> {
    let snapshot_path = Path::new(&args.dir);
    if !snapshot_path.is_dir() {
        return Err(miette!("snapshot directory does not exist: {}", args.dir));
    }

    // Load snapshot (cluster side)
    let cluster_manifests = load_manifests_from_dir(snapshot_path)
        .map_err(|e| miette!("failed to load snapshot directory: {e}"))?;

    // Load kix side from ./result
    let result_path = Path::new("result");
    let kix_manifests = if result_path.is_dir() {
        load_manifests_from_dir(result_path)
            .map_err(|e| miette!("failed to load kix build output from ./result: {e}"))?
    } else {
        return Err(miette!(
            "no build output found. Run `kix build {}` first to generate ./result",
            args.cluster,
        ));
    };

    let config = DiffConfig::new("kix", "cluster");

    let kix_map: BTreeMap<ResourceId, Value> = kix_manifests.into_iter().collect();
    let cluster_map: BTreeMap<ResourceId, Value> = cluster_manifests.into_iter().collect();

    // Diff
    let mut identical = Vec::new();
    let mut modified: Vec<(ResourceId, Vec<Difference>)> = Vec::new();
    let mut kix_only_map: BTreeMap<ResourceId, Value> = BTreeMap::new();
    let mut cluster_only_map: BTreeMap<ResourceId, Value> = BTreeMap::new();

    for (id, kix_val) in &kix_map {
        if let Some(cluster_val) = cluster_map.get(id) {
            let diffs = structural_diff(kix_val, cluster_val, "$", &config);
            if diffs.is_empty() {
                identical.push(id.clone());
            } else {
                modified.push((id.clone(), diffs));
            }
        } else {
            kix_only_map.insert(id.clone(), kix_val.clone());
        }
    }

    for (id, cluster_val) in &cluster_map {
        if !kix_map.contains_key(id) {
            cluster_only_map.insert(id.clone(), cluster_val.clone());
        }
    }

    // Rename detection
    let kix_only_refs: Vec<(ResourceId, &Value)> =
        kix_only_map.iter().map(|(id, v)| (id.clone(), v)).collect();
    let cluster_only_refs: Vec<(ResourceId, &Value)> = cluster_only_map
        .iter()
        .map(|(id, v)| (id.clone(), v))
        .collect();
    let renames = find_renames(&kix_only_refs, &cluster_only_refs, &config);

    for rename in &renames {
        kix_only_map.remove(&rename.kix_id);
        cluster_only_map.remove(&rename.cluster_id);
    }

    let kix_only: Vec<(ResourceId, Value)> = kix_only_map.into_iter().collect();
    let cluster_only: Vec<(ResourceId, Value)> = cluster_only_map.into_iter().collect();

    let has_diff = !modified.is_empty()
        || !kix_only.is_empty()
        || !cluster_only.is_empty()
        || !renames.is_empty();

    // Output
    match ctx.output_format(OutputFormat::Text) {
        OutputFormat::Json | OutputFormat::Yaml => {
            let as_yaml = matches!(ctx.global.output, Some(OutputFormat::Yaml));
            let output_val = serde_json::json!({
                "summary": {
                    "identical": identical.len(),
                    "modified": modified.len(),
                    "kix_only": kix_only.len(),
                    "cluster_only": cluster_only.len(),
                    "renames": renames.len(),
                },
                "modified": modified.iter().map(|(id, diffs)| {
                    serde_json::json!({
                        "resource": id.display_id(),
                        "diff_count": diffs.len(),
                        "diffs": diffs.iter().map(|d| {
                            serde_json::json!({
                                "path": d.path,
                                "kind": format!("{:?}", d.kind),
                                "a_value": d.a_value,
                                "b_value": d.b_value,
                            })
                        }).collect::<Vec<_>>(),
                    })
                }).collect::<Vec<_>>(),
                "kix_only": kix_only.iter().map(|(id, _)| id.display_id()).collect::<Vec<_>>(),
                "cluster_only": cluster_only.iter().map(|(id, _)| id.display_id()).collect::<Vec<_>>(),
                "renames": renames.iter().map(|r| {
                    serde_json::json!({
                        "from": r.cluster_id.display_id(),
                        "to": r.kix_id.display_id(),
                        "similarity": r.similarity,
                        "diff_count": r.diffs.len(),
                    })
                }).collect::<Vec<_>>(),
            });
            if as_yaml {
                print!("{}", serde_yml::to_string(&output_val).into_diagnostic()?);
            } else {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&output_val).into_diagnostic()?
                );
            }
        }
        OutputFormat::Text | OutputFormat::Markdown => {
            let color = output::color_enabled();
            let total = identical.len()
                + modified.len()
                + kix_only.len()
                + cluster_only.len()
                + renames.len();

            if !ctx.global.quiet {
                println!(
                    "{total} resources compared: {} identical, {} modified, {} kix-only, {} cluster-only, {} renamed",
                    identical.len(),
                    modified.len(),
                    kix_only.len(),
                    cluster_only.len(),
                    renames.len(),
                );
                println!();
            }

            if !renames.is_empty() {
                println!("{}", output::bold("Renames/Moves:"));
                for rename in &renames {
                    println!(
                        "  {} -> {} ({:.0}% similar)",
                        output::yellow(&rename.cluster_id.to_string()),
                        output::green(&rename.kix_id.to_string()),
                        rename.similarity * 100.0,
                    );
                    if !rename.diffs.is_empty() {
                        println!("{}", format_diffs(&rename.diffs, &config, color, true));
                    }
                }
                println!();
            }

            if !modified.is_empty() {
                println!("{}", output::bold("Modified:"));
                for (id, diffs) in &modified {
                    println!("  {}", output::yellow(&id.to_string()));
                    println!("{}", format_diffs(diffs, &config, color, true));
                }
                println!();
            }

            if !kix_only.is_empty() {
                println!("{}", output::bold("Only in kix (will be created):"));
                for (id, _) in &kix_only {
                    println!("  {}", output::green(&id.to_string()));
                }
                println!();
            }

            if !cluster_only.is_empty() {
                println!("{}", output::bold("Only in cluster (not managed by kix):"));
                for (id, _) in &cluster_only {
                    println!("  {}", output::red(&id.to_string()));
                }
                println!();
            }

            if !has_diff {
                println!("{}", output::green("No differences found."));
            }
        }
    }

    if has_diff {
        std::process::exit(2);
    }

    Ok(())
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
