//! `kix export` — dump a built cluster activation as plain Kubernetes YAML.
//!
//! Two modes, selected via `--for`:
//!
//! - `exit` (default): strip all `kix.run/*` annotations, skip kix-internal CRs
//!   (Activation, PackageInstance). Produces kix-neutral YAML the operator can
//!   hand off to any other tool (`kubectl apply -f`, Flux, Argo, ...). Answers
//!   Sam's "what if I want to leave kix" question in doc 84 §1.
//!
//! - `audit`: preserve `kix.run/*` provenance annotations and all manifests.
//!   This mode is the M3 compliance-evidence precursor — the same rendered
//!   state but with its kix provenance intact so auditors can trace who
//!   deployed what when.
//!
//! Output layout: `<out>/<namespace>/<Kind>-<name>.yaml` (nested), matching
//! what `manifest::serialize::load_manifests_from_dir` expects, so `kix diff
//! --snapshot <dir>` can round-trip against the exported tree.

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
    .map_err(|e| miette!("failed to load store graph: {e}"))?;

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
    } else {
        fs::create_dir_all(&out_dir).into_diagnostic()?;
    }

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
/// is a passthrough — we want the full stamped manifest for compliance.
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
