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

use kix::manifest::hash::strip_kix_annotations;
use kix::manifest::serialize::strip_nulls;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::{ExportArgs, ExportMode};
use crate::output;

use super::CommandContext;

pub fn run(args: &ExportArgs, ctx: &mut CommandContext) -> Result<()> {
    crate::esay!("Building cluster '{}'...", args.cluster);
    // Stamped, as the deploy and diff pipelines see it. `--for=audit` keeps
    // the annotations; `--for=exit` strips them again below.
    let status = |msg: &str| {
        crate::esay!("  {msg}");
    };
    let build = super::build_flake(
        &ctx.global,
        &args.cluster,
        &status,
        super::ACTIVATION_BUILD_FAILED,
    )?;
    let graph = build.graph();

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

    let mode = match args.for_mode {
        ExportMode::Exit => "exit (kix-neutral)",
        ExportMode::Audit => "audit (kix provenance preserved)",
    };
    crate::esay!();
    crate::esay!(
        "  {} {} resources to {} ({mode})",
        output::green("Exported"),
        written,
        out_dir.display(),
    );
    if skipped_internal > 0 {
        crate::esay!(
            "  {} {} kix-internal CRs (Activation, PackageInstance)",
            output::dim("Skipped"),
            skipped_internal,
        );
    }

    Ok(())
}

/// Apply the per-mode manifest transform. `Exit` strips kix.run/* annotations
/// (using the shared helper in `manifest::hash`) and null values. `Audit`
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
