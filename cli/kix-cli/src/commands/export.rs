//! Export a built cluster activation as Kubernetes YAML.
//!
//! By default the export strips all `kix.run/*` annotations and omits
//! Kix-internal custom resources (`Activation`, `PackageInstance`), producing
//! standard Kubernetes YAML for tools such as `kubectl`, Flux, or Argo CD.
//! `--with-kix-metadata` keeps the annotations and all manifests so auditors
//! can trace which build produced each resource.
//!
//! Files are written to `<out>/<namespace>/<Kind>-<name>.yaml`, matching the
//! layout expected by `manifest::serialize::load_manifests_from_dir` so
//! `kix diff --from <dir>` can compare against an exported tree.

use std::fs;
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::manifest::hash::strip_kix_annotations;
use kix::manifest::serialize::strip_nulls;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId};

use crate::cli::ExportArgs;
use crate::output;

use super::CommandContext;

pub fn run(args: &ExportArgs, ctx: &mut CommandContext) -> Result<()> {
    crate::esay!("Building cluster '{}'...", args.cluster);
    // Build the full stamped graph. Without `--with-kix-metadata`, Kix
    // annotations are stripped below.
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
        // Remove the previous export directory before writing so stale YAML
        // files do not survive into a later `kubectl apply -R`. Because `--out`
        // is user input, refuse to delete a directory that contains anything
        // other than exported `.yaml` files.
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

        // Omit Kix-internal custom resources that only apply to Kix
        // deployments, unless the export keeps Kix's metadata.
        if !args.with_kix_metadata
            && kix::manifest::lifecycle::is_kix_internal_kind(rid.group_kind())
        {
            skipped_internal += 1;
            continue;
        }

        let transformed = transform_manifest(manifest, args.with_kix_metadata);
        let yaml = manifest_to_yaml(&transformed)?;
        let path = output_path_for(&out_dir, &rid);

        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).into_diagnostic()?;
        }
        fs::write(&path, yaml).into_diagnostic()?;
        written += 1;
    }

    let mode = if args.with_kix_metadata {
        "with Kix metadata"
    } else {
        "plain Kubernetes YAML"
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

/// Strip nulls from `manifest`, and unless `with_kix_metadata` also strip
/// `kix.run/*` annotations.
fn transform_manifest(manifest: &Value, with_kix_metadata: bool) -> Value {
    let mut v = manifest.clone();
    if !with_kix_metadata {
        strip_kix_annotations(&mut v);
    }
    strip_nulls(&mut v);
    v
}

/// Serialize a single manifest to sorted-key YAML matching snapshot output.
fn manifest_to_yaml(manifest: &Value) -> Result<String> {
    // Use the single-slice multi-document serializer because `manifest::serialize`
    // only exposes a flat directory writer.
    let yaml = kix::manifest::serialize::manifests_to_yaml(std::slice::from_ref(manifest))
        .map_err(|e| miette!("failed to serialize manifest: {e}"))?;
    Ok(yaml)
}

/// Return the output path `<out>/<namespace>/<Kind>-<name>.yaml` (using
/// `_cluster` for cluster-scoped resources).
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

        // Refuse symlinks rather than following them outside the export directory.
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

    /// Verify that `--force` refuses to delete an output directory containing non-YAML files.
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
