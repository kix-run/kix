//! Export a built cluster activation as Kubernetes YAML.
//!
//! Two modes, selected via `--for`:
//!
//! - `exit` (default): strip all `kix.run/*` annotations, skip kix-internal CRs
//!   (Activation, PackageInstance). Produces kix-neutral YAML the operator can
//!   pass to another tool such as kubectl, Flux, or Argo.
//!
//! - `audit`: preserve `kix.run/*` provenance annotations and all manifests.
//!   This mode preserves the same rendered
//!   state but with its kix provenance intact so auditors can trace who
//!   deployed what when.
//!
//! Output layout: `<out>/<namespace>/<Kind>-<name>.yaml` (nested), matching
//! what `manifest::serialize::load_manifests_from_dir` expects, so `kix diff
//! --from <dir>` can round-trip against the exported tree.

use std::fs;
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::cluster::normalize::strip_kix_annotations;
use kix::eval::build_cluster_activation_with_status;
use kix::eval::store_graph::StoreGraph;
use kix::manifest::serialize::strip_nulls;
use kix::manifest::stamp::stamp_annotations;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::{ExportArgs, ExportMode};
use crate::output;

use super::CommandContext;

pub fn run(args: &ExportArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    if !ctx.global.quiet {
        eprintln!("Building cluster '{}'...", args.cluster);
    }
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &|msg| {
            if !ctx.global.quiet {
                eprintln!("  {msg}");
            }
        })
        .map_err(|e| miette!("failed to build cluster activation: {e}"))?;

    let mut graph = StoreGraph::from_result_dir_with_status(&result_path, &|msg| {
        if !ctx.global.quiet {
            eprintln!("  {msg}");
        }
    })
    .map_err(|e| miette!("{e}"))?;

    // Stamp so the graph is in the same shape the deploy/diff pipelines see.
    // For `--for=audit` we want those annotations preserved; for `--for=exit`
    // we strip them again below.
    stamp_annotations(&mut graph);

    let out_dir = PathBuf::from(&args.out);
    if out_dir.exists() {
        if !args.force {
            return Err(miette!(
                "output directory '{}' already exists; pass --force to overwrite",
                args.out
            ));
        }
        // A forced export must remove stale YAML. Overwriting files in place
        // leaves resources from the previous export behind, and a later
        // `kubectl apply -R` would recreate them.
        //
        // Clear only a directory that has the shape of an earlier export.
        // `--out` is user input, so deleting an arbitrary directory is unsafe.
        if let Some(intruder) = first_non_export_entry(&out_dir)? {
            return Err(miette!(
                "cannot overwrite '{}': it contains '{}', which Kix does not recognize as an exported file. \
                 Remove the directory yourself, or export somewhere else.",
                args.out,
                intruder.display()
            ));
        }
        fs::remove_dir_all(&out_dir).into_diagnostic()?;
    }
    fs::create_dir_all(&out_dir).into_diagnostic()?;

    let mut written = 0usize;
    let mut skipped_internal = 0usize;

    for node in graph.resources.values() {
        let manifest = &node.manifest;
        let rid = ResourceId::from_value(manifest);

        // Exit mode: drop kix-internal CRs wholesale (they only make sense to
        // a live kix deployment and would be garbage in a neutral handoff).
        // Audit mode keeps them.
        if matches!(args.for_mode, ExportMode::Exit)
            && kix::manifest::lifecycle::is_kix_internal_kind(&rid.kind)
        {
            skipped_internal += 1;
            continue;
        }

        let transformed = transform_manifest(manifest, args.for_mode);
        let yaml = manifest_to_yaml(&transformed)?;
        let path = output_path_for(&out_dir, &rid);

        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).into_diagnostic()?;
        }
        fs::write(&path, yaml).into_diagnostic()?;
        written += 1;
    }

    if !ctx.global.quiet {
        let mode = match args.for_mode {
            ExportMode::Exit => "exit (kix-neutral)",
            ExportMode::Audit => "audit (kix provenance preserved)",
        };
        eprintln!();
        eprintln!(
            "  {} {} resources to {} ({mode})",
            output::green("Exported"),
            written,
            out_dir.display(),
        );
        if skipped_internal > 0 {
            eprintln!(
                "  {} {} kix-internal CRs (Activation, PackageInstance)",
                output::dim("Skipped"),
                skipped_internal,
            );
        }
    }

    Ok(())
}

/// Apply the per-mode manifest transform. `Exit` strips kix.run/* annotations
/// (using the shared helper in `cluster::normalize`) and null values. `Audit`
/// is a passthrough because compliance needs the full stamped manifest.
fn transform_manifest(manifest: &Value, mode: ExportMode) -> Value {
    let mut v = manifest.clone();
    match mode {
        ExportMode::Exit => {
            strip_kix_annotations(&mut v);
            strip_nulls(&mut v);
        }
        ExportMode::Audit => {
            strip_nulls(&mut v);
        }
    }
    v
}

/// Serialize a single manifest to sorted-key YAML. Shares the sorting
/// behavior of `manifests_to_yaml` so exported files match snapshot output.
fn manifest_to_yaml(manifest: &Value) -> Result<String> {
    // manifest::serialize only exposes a multi-doc writer and a dir writer
    // that uses the flat layout. For the nested layout we want here we
    // serialize one manifest at a time via the public multi-doc API with a
    // one-element slice.
    let yaml = kix::manifest::serialize::manifests_to_yaml(std::slice::from_ref(manifest))
        .map_err(|e| miette!("failed to serialize manifest: {e}"))?;
    Ok(yaml)
}

/// Nested output layout: `<out>/<namespace>/<Kind>-<name>.yaml`. Cluster-scoped
/// resources land in `<out>/_cluster/`.
fn output_path_for(out_dir: &Path, rid: &ResourceId) -> PathBuf {
    let ns = if rid.namespace.is_empty() {
        CLUSTER_SCOPED
    } else {
        rid.namespace.as_str()
    };
    let filename = format!("{}-{}.yaml", rid.kind, rid.name);
    out_dir.join(ns).join(filename)
}

fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
    if flake.contains(':') {
        Ok(PathBuf::from(flake))
    } else {
        let path = PathBuf::from(flake);
        if path.is_absolute() {
            Ok(path)
        } else {
            let cwd = std::env::current_dir().into_diagnostic()?;
            Ok(cwd.join(path))
        }
    }
}

/// Return the first entry under `dir` that Kix export would not have written.
///
/// An export writes `<namespace>/<Kind>-<name>.yaml` and nothing else, so a
/// tree containing only directories and `.yaml` files is safe to replace.
/// Any other entry prevents `--force` from deleting the directory.
fn first_non_export_entry(dir: &std::path::Path) -> Result<Option<PathBuf>> {
    for entry in fs::read_dir(dir).into_diagnostic()? {
        let entry = entry.into_diagnostic()?;
        let path = entry.path();
        let file_type = entry.file_type().into_diagnostic()?;

        // A symlink is never followed: whatever it points at is not ours.
        if file_type.is_symlink() {
            return Ok(Some(path));
        }
        if file_type.is_dir() {
            if let Some(found) = first_non_export_entry(&path)? {
                return Ok(Some(found));
            }
            continue;
        }
        if path.extension().and_then(|e| e.to_str()) != Some("yaml") {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod force_guard_tests {
    use super::*;
    use std::fs;

    fn tmpdir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("kix-export-guard-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    #[test]
    fn a_tree_of_yaml_is_recognised_as_a_previous_export() {
        let dir = tmpdir("yaml");
        fs::create_dir_all(dir.join("apps")).unwrap();
        fs::write(dir.join("apps/Deployment-web.yaml"), "kind: Deployment\n").unwrap();
        fs::create_dir_all(dir.join("_cluster")).unwrap();
        fs::write(
            dir.join("_cluster/Namespace-apps.yaml"),
            "kind: Namespace\n",
        )
        .unwrap();

        assert!(first_non_export_entry(&dir).unwrap().is_none());
        fs::remove_dir_all(&dir).unwrap();
    }

    /// Refuse to delete a user-selected output directory containing other data.
    #[test]
    fn anything_else_stops_the_overwrite() {
        let dir = tmpdir("mixed");
        fs::create_dir_all(dir.join("apps")).unwrap();
        fs::write(dir.join("apps/Deployment-web.yaml"), "kind: Deployment\n").unwrap();
        fs::write(dir.join("apps/notes.md"), "mine\n").unwrap();

        let found = first_non_export_entry(&dir).unwrap().expect("must refuse");
        assert!(found.ends_with("notes.md"));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_symlink_stops_the_overwrite_without_being_followed() {
        let dir = tmpdir("symlink");
        fs::write(dir.join("Namespace-apps.yaml"), "kind: Namespace\n").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink("/etc", dir.join("link")).unwrap();

        #[cfg(unix)]
        {
            let found = first_non_export_entry(&dir).unwrap().expect("must refuse");
            assert!(found.ends_with("link"));
        }
        fs::remove_dir_all(&dir).unwrap();
    }
}
