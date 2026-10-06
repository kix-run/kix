//! `kix bundle`, and reading bundles for `--bundle` and `--deployed-bundle`.
//!
//! A bundle (`kix::eval::bundle`) is a build as one file that loads without
//! Nix. `--bundle` makes it the new side of `kix plan`, `kix deploy` and
//! `kix graph`. `--deployed-bundle` supplies builds the cluster's records
//! name, which kix otherwise looks for in the local Nix store.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use miette::{Result, miette};

use kix::cluster::secrets::SopsSources;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::bundle::{self, Bundle};
use kix::eval::store_graph::{StoreGraph, store_hash};

use crate::cli::BundleArgs;

use super::CommandContext;

/// A bundle read from a file and verified.
#[derive(Debug, Clone)]
pub struct LoadedBundle {
    pub bundle: Bundle,
    /// The SHA-256 of the file's bytes.
    pub sha256: String,
}

impl LoadedBundle {
    /// The build, with `bundle:sha256:<sha256>` as its result directory.
    pub fn graph(&self) -> Result<StoreGraph> {
        self.bundle
            .into_graph(&self.sha256)
            .map_err(|e| miette!("{e}"))
    }

    /// The bundle's SOPS files. With `placeholders`, nothing is decrypted:
    /// what `kix plan` uses, so a plan made before approval reads no secret.
    pub fn sops(&self, placeholders: bool) -> Result<SopsSources> {
        SopsSources::from_bundle(self.bundle.sops_sources(), placeholders)
            .map_err(|e| miette!("cannot write the bundle's SOPS files: {e}"))
    }
}

/// Read and verify a bundle.
pub fn load(path: &Path) -> Result<LoadedBundle> {
    let bytes = std::fs::read(path)
        .map_err(|e| miette!("cannot read the bundle {}: {e}", path.display()))?;
    let bundle = Bundle::parse(&bytes)
        .map_err(|e| miette!("cannot use the bundle {}: {e}", path.display()))?;
    bundle
        .verify()
        .map_err(|e| miette!("cannot use the bundle {}: {e}", path.display()))?;
    Ok(LoadedBundle {
        bundle,
        sha256: bundle::sha256_hex(&bytes),
    })
}

/// The `--deployed-bundle` builds, by the identity hash of their Activation
/// record. Set once per process, before any record is resolved.
static DEPLOYED: OnceLock<HashMap<String, LoadedBundle>> = OnceLock::new();

/// Load the `--deployed-bundle` files. Later calls in the same process are
/// ignored: `kix deploy --plan` prepares twice with the same arguments.
pub fn register_deployed(paths: &[PathBuf]) -> Result<()> {
    if DEPLOYED.get().is_some() {
        return Ok(());
    }
    let mut by_hash = HashMap::new();
    for path in paths {
        let loaded = load(path)?;
        by_hash.insert(store_hash(Path::new(&loaded.bundle.activation)), loaded);
    }
    let _ = DEPLOYED.set(by_hash);
    Ok(())
}

/// The build of the record with `identity_hash`, from `--deployed-bundle`.
pub fn deployed_graph(identity_hash: &str) -> Option<StoreGraph> {
    let loaded = DEPLOYED.get()?.get(identity_hash)?;
    match loaded.graph() {
        Ok(graph) => Some(graph),
        Err(e) => {
            tracing::warn!(identity_hash, error = %e, "a deployed bundle would not load");
            None
        }
    }
}

/// `kix bundle <cluster> FILE`.
pub fn run(args: &BundleArgs, ctx: &mut CommandContext) -> Result<()> {
    let flake_path = super::deploy::resolve_flake_path(&ctx.global.flake)?;
    let quiet = ctx.global.quiet;
    let status = |msg: &str| {
        if !quiet {
            eprint!("\r\x1b[2K  {msg}");
        }
    };
    let overrides = ctx.global.input_overrides();
    let result_dir =
        build_cluster_activation_with_status(&flake_path, &args.cluster, &overrides, &status)
            .map_err(|e| miette!("failed to build cluster: {e}"))?;
    if !quiet {
        eprint!("\r\x1b[2K");
    }
    let graph = StoreGraph::from_result_dir(&result_dir).map_err(|e| miette!("{e}"))?;
    let receipt = super::compliance::receipt::build_receipt(&graph, &ctx.global.flake);
    let provenance = serde_json::json!({
        "source": receipt["source"],
        "inputs": receipt["inputs"],
        "builder": receipt["builder"],
    });
    let kix = crate::plan::document::KixBuild::current();
    let kix_rev = match &kix.store_path {
        Some(path) => format!("{} ({path})", kix.version),
        None => kix.version,
    };
    let bundle = bundle::from_result_dir(&result_dir, &kix_rev, Some(provenance))
        .map_err(|e| miette!("{e}"))?;
    bundle
        .verify()
        .map_err(|e| miette!("the build did not make a valid bundle: {e}"))?;
    let bytes = serde_json::to_vec(&bundle).map_err(|e| miette!("{e}"))?;
    std::fs::write(&args.file, &bytes)
        .map_err(|e| miette!("cannot write {}: {e}", args.file.display()))?;
    if !quiet {
        eprintln!(
            "Wrote {} ({} files, sha256:{})",
            args.file.display(),
            bundle.files.len(),
            bundle::sha256_hex(&bytes)
        );
    }
    Ok(())
}
