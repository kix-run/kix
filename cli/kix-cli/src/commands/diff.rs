use std::collections::BTreeMap;
use std::path::Path;

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix_cluster::fetch;
use kix_manifest::diff::display::format_diffs;
use kix_manifest::diff::engine::structural_diff;
use kix_manifest::diff::rename::find_renames;
use kix_manifest::diff::{DiffConfig, Difference};
use kix_manifest::normalize;
use kix_manifest::serialize::load_manifests_from_dir;
use kix_manifest::types::ResourceId;

use crate::cli::{DiffArgs, OutputFormat};
use crate::output;

use super::CommandContext;

/// Result of diffing a cluster: classified into categories.
struct DiffResult {
    identical: Vec<ResourceId>,
    modified: Vec<(ResourceId, Vec<Difference>)>,
    kix_only: Vec<(ResourceId, Value)>,
    cluster_only: Vec<(ResourceId, Value)>,
    renames: Vec<kix_manifest::diff::rename::RenamePair>,
}

pub fn run(args: &DiffArgs, ctx: &mut CommandContext) -> Result<()> {
    // Evaluate cluster manifests via mock/real backend
    let kix_manifests = eval_cluster_manifests(&args.cluster)?;

    // Load cluster-side manifests: from snapshot or live cluster
    let cluster_manifests = if let Some(snapshot_dir) = &args.snapshot {
        let snapshot_path = Path::new(snapshot_dir);
        if !snapshot_path.is_dir() {
            return Err(miette!("snapshot directory does not exist: {snapshot_dir}"));
        }
        load_manifests_from_dir(snapshot_path)
            .map_err(|e| miette!("failed to load snapshot directory: {e}"))?
    } else {
        // Live cluster fetch
        let global = ctx.global.clone();
        ctx.runtime.block_on(fetch_live_manifests(&global))?
    };

    let config = DiffConfig::new("kix", "cluster");

    // Run the diff
    let result = compute_diff(kix_manifests, cluster_manifests, &config);

    // Output
    let has_diff = !result.modified.is_empty()
        || !result.kix_only.is_empty()
        || !result.cluster_only.is_empty()
        || !result.renames.is_empty();

    match ctx.output_format(OutputFormat::Text) {
        OutputFormat::Json => {
            print_json_output(&result, false)?;
        }
        OutputFormat::Yaml => {
            print_json_output(&result, true)?;
        }
        OutputFormat::Text => {
            print_text_output(&result, &config, &ctx.global);
        }
    }

    if has_diff {
        // Exit code 2 when diff exists
        std::process::exit(2);
    }

    Ok(())
}

/// Fetch managed resources from the live cluster and convert to (ResourceId, Value) pairs.
async fn fetch_live_manifests(global: &crate::cli::GlobalArgs) -> Result<Vec<(ResourceId, Value)>> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

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

    let mut resources = Vec::new();
    for mut obj in objects {
        fetch::normalize_for_diff(&mut obj);
        let value = serde_json::to_value(&obj.data).into_diagnostic()?;
        let id = ResourceId::from_value(&value);
        resources.push((id, value));
    }

    Ok(resources)
}

/// Evaluate cluster manifests. For now, uses the kix build output directory
/// at `./result` as the source (the standard nix build output location).
fn eval_cluster_manifests(cluster: &str) -> Result<Vec<(ResourceId, Value)>> {
    // Try ./result first (standard kix build output)
    let result_path = Path::new("result");
    if result_path.is_dir() {
        let manifests = load_manifests_from_dir(result_path)
            .map_err(|e| miette!("failed to load kix build output from ./result: {e}"))?;
        if !manifests.is_empty() {
            return Ok(manifests);
        }
    }

    Err(miette!(
        "no build output found. Run `kix build {cluster}` first to generate ./result"
    ))
}

/// Core diff computation: classify resources into categories.
fn compute_diff(
    kix_manifests: Vec<(ResourceId, Value)>,
    cluster_manifests: Vec<(ResourceId, Value)>,
    config: &DiffConfig,
) -> DiffResult {
    // Normalize both sides
    let kix_map: BTreeMap<ResourceId, Value> = kix_manifests
        .into_iter()
        .map(|(id, v)| (id, normalize::normalize_kix(v)))
        .collect();

    let cluster_map: BTreeMap<ResourceId, Value> = cluster_manifests
        .into_iter()
        .map(|(id, v)| (id, normalize::normalize_cluster(v)))
        .collect();

    let mut identical = Vec::new();
    let mut modified = Vec::new();
    let mut kix_only_map: BTreeMap<ResourceId, Value> = BTreeMap::new();
    let mut cluster_only_map: BTreeMap<ResourceId, Value> = BTreeMap::new();

    // Find resources present on both sides
    for (id, kix_val) in &kix_map {
        if let Some(cluster_val) = cluster_map.get(id) {
            let diffs = structural_diff(kix_val, cluster_val, "$", config);
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

    // Run rename detection on unmatched resources
    let kix_only_refs: Vec<(ResourceId, &Value)> =
        kix_only_map.iter().map(|(id, v)| (id.clone(), v)).collect();
    let cluster_only_refs: Vec<(ResourceId, &Value)> = cluster_only_map
        .iter()
        .map(|(id, v)| (id.clone(), v))
        .collect();
    let renames = find_renames(&kix_only_refs, &cluster_only_refs, config);

    // Remove renamed resources from kix-only and cluster-only
    for rename in &renames {
        kix_only_map.remove(&rename.kix_id);
        cluster_only_map.remove(&rename.cluster_id);
    }

    let kix_only: Vec<(ResourceId, Value)> = kix_only_map.into_iter().collect();
    let cluster_only: Vec<(ResourceId, Value)> = cluster_only_map.into_iter().collect();

    DiffResult {
        identical,
        modified,
        kix_only,
        cluster_only,
        renames,
    }
}

fn print_text_output(result: &DiffResult, config: &DiffConfig, global: &crate::cli::GlobalArgs) {
    let color = output::color_enabled();
    let total = result.identical.len()
        + result.modified.len()
        + result.kix_only.len()
        + result.cluster_only.len()
        + result.renames.len();

    if !global.quiet {
        println!(
            "{} resources compared: {} identical, {} modified, {} kix-only, {} cluster-only, {} renamed",
            total,
            result.identical.len(),
            result.modified.len(),
            result.kix_only.len(),
            result.cluster_only.len(),
            result.renames.len(),
        );
        println!();
    }

    // Renames
    if !result.renames.is_empty() {
        println!("{}", output::bold("Renames/Moves:"));
        for rename in &result.renames {
            println!(
                "  {} -> {} ({:.0}% similar)",
                output::yellow(&rename.cluster_id.to_string()),
                output::green(&rename.kix_id.to_string()),
                rename.similarity * 100.0,
            );
            if !rename.diffs.is_empty() {
                let formatted = format_diffs(&rename.diffs, config, color, true);
                println!("{formatted}");
            }
        }
        println!();
    }

    // Modified resources
    if !result.modified.is_empty() {
        println!("{}", output::bold("Modified:"));
        for (id, diffs) in &result.modified {
            println!("  {}", output::yellow(&id.to_string()));
            let formatted = format_diffs(diffs, config, color, true);
            println!("{formatted}");
        }
        println!();
    }

    // Kix-only
    if !result.kix_only.is_empty() {
        println!("{}", output::bold("Only in kix (will be created):"));
        for (id, _) in &result.kix_only {
            println!("  {}", output::green(&id.to_string()));
        }
        println!();
    }

    // Cluster-only
    if !result.cluster_only.is_empty() {
        println!("{}", output::bold("Only in cluster (not managed by kix):"));
        for (id, _) in &result.cluster_only {
            println!("  {}", output::red(&id.to_string()));
        }
        println!();
    }

    if result.modified.is_empty()
        && result.kix_only.is_empty()
        && result.cluster_only.is_empty()
        && result.renames.is_empty()
    {
        println!("{}", output::green("No differences found."));
    }
}

fn print_json_output(result: &DiffResult, as_yaml: bool) -> Result<()> {
    let output = serde_json::json!({
        "summary": {
            "identical": result.identical.len(),
            "modified": result.modified.len(),
            "kix_only": result.kix_only.len(),
            "cluster_only": result.cluster_only.len(),
            "renames": result.renames.len(),
        },
        "modified": result.modified.iter().map(|(id, diffs)| {
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
        "kix_only": result.kix_only.iter().map(|(id, _)| id.display_id()).collect::<Vec<_>>(),
        "cluster_only": result.cluster_only.iter().map(|(id, _)| id.display_id()).collect::<Vec<_>>(),
        "renames": result.renames.iter().map(|r| {
            serde_json::json!({
                "from": r.cluster_id.display_id(),
                "to": r.kix_id.display_id(),
                "similarity": r.similarity,
                "diff_count": r.diffs.len(),
            })
        }).collect::<Vec<_>>(),
    });

    if as_yaml {
        print!("{}", serde_yml::to_string(&output).into_diagnostic()?);
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&output).into_diagnostic()?
        );
    }
    Ok(())
}
