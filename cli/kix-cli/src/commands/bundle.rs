//! `kix bundle`, and reading bundles for `--bundle` and `--deployed-bundle`.
//!
//! A bundle (`kix::eval::bundle`) is a build as one file that loads without
//! Nix. `--bundle` makes it the new side of `kix plan`, `kix deploy` and
//! `kix graph`. `--deployed-bundle` supplies builds the cluster's records
//! name, which kix otherwise looks for in the local Nix store.

use std::collections::HashMap;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use miette::{IntoDiagnostic, Result, miette};

use kix::cluster::secrets::SopsSources;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::bundle::{self, Bundle, Contents};
use kix::eval::store_graph::{StoreGraph, store_hash};

use crate::cli::BundleArgs;

use super::CommandContext;

/// A bundle read from a file and verified.
#[derive(Debug, Clone)]
pub struct LoadedBundle(Bundle);

impl From<Bundle> for LoadedBundle {
    fn from(bundle: Bundle) -> Self {
        Self(bundle)
    }
}

impl LoadedBundle {
    pub fn contents(&self) -> &Contents {
        self.0.contents()
    }

    /// The SHA-256 of the file's bytes.
    pub fn sha256(&self) -> &str {
        self.0.sha256()
    }

    /// The build, with `bundle:sha256:<sha256>` as its result directory.
    pub fn graph(&self) -> Result<StoreGraph> {
        self.0.graph().map_err(|e| miette!("{e}"))
    }

    /// The bundle's SOPS files. With `placeholders`, nothing is decrypted:
    /// what `kix plan` uses, so a plan made before approval reads no secret.
    pub fn sops(&self, placeholders: bool) -> Result<SopsSources> {
        SopsSources::from_bundle(self.0.sops_sources(), placeholders)
            .map_err(|e| miette!("cannot write the bundle's SOPS files: {e}"))
    }
}

/// Read and verify a bundle.
pub fn load(path: &Path) -> Result<LoadedBundle> {
    let file = std::fs::File::open(path)
        .map_err(|e| miette!("cannot read the bundle {}: {e}", path.display()))?;
    Bundle::read(BufReader::new(file))
        .map(LoadedBundle)
        .map_err(|e| miette!("cannot use the bundle {}: {e}", path.display()))
}

/// A `--deployed-bundle` file, read in full the first time a record asks
/// for its build.
struct Deployed {
    path: PathBuf,
    loaded: OnceLock<Option<LoadedBundle>>,
}

/// The `--deployed-bundle` files, by the identity hash of the Activation
/// record their header names. Set once per process, before any record is
/// resolved.
static DEPLOYED: OnceLock<HashMap<String, Deployed>> = OnceLock::new();

/// Read the header of each `--deployed-bundle` file. Later calls in the same
/// process are ignored: `kix deploy --plan` prepares twice with the same
/// arguments.
pub fn register_deployed(paths: &[PathBuf]) -> Result<()> {
    if DEPLOYED.get().is_some() {
        return Ok(());
    }
    let mut by_hash = HashMap::new();
    for path in paths {
        let file = std::fs::File::open(path)
            .map_err(|e| miette!("cannot read the bundle {}: {e}", path.display()))?;
        let header = Bundle::read_header(BufReader::new(file))
            .map_err(|e| miette!("cannot use the bundle {}: {e}", path.display()))?;
        by_hash.insert(
            store_hash(Path::new(&header.activation)),
            Deployed {
                path: path.clone(),
                loaded: OnceLock::new(),
            },
        );
    }
    let _ = DEPLOYED.set(by_hash);
    Ok(())
}

/// The build of the record with `identity_hash`, from `--deployed-bundle`.
pub fn deployed_graph(identity_hash: &str) -> Option<StoreGraph> {
    let deployed = DEPLOYED.get()?.get(identity_hash)?;
    let loaded = deployed.loaded.get_or_init(|| {
        let loaded = load(&deployed.path)
            .inspect_err(
                |e| tracing::warn!(identity_hash, error = %e, "a deployed bundle would not load"),
            )
            .ok()?;
        // The header was read without verifying; the file may also have
        // changed since.
        let activation = &loaded.contents().activation;
        if store_hash(Path::new(activation)) != identity_hash {
            tracing::warn!(identity_hash, %activation, "a deployed bundle now holds another build");
            return None;
        }
        Some(loaded)
    });
    match loaded.as_ref()?.graph() {
        Ok(graph) => Some(graph),
        Err(e) => {
            tracing::warn!(identity_hash, error = %e, "a deployed bundle would not load");
            None
        }
    }
}

/// `kix bundle <cluster> [FILE]`.
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
    let object = |v: &serde_json::Value| v.as_object().cloned().unwrap_or_default();
    let provenance = bundle::Provenance {
        source: object(&receipt["source"]),
        inputs: receipt["inputs"]
            .as_array()
            .into_iter()
            .flatten()
            .map(object)
            .collect(),
        builder: object(&receipt["builder"]),
    };
    let kix = crate::plan::document::KixBuild::current();
    let kix_rev = match &kix.store_path {
        Some(path) => format!("{} ({path})", kix.version),
        None => kix.version,
    };
    let contents = bundle::from_result_dir(&result_dir, &kix_rev, Some(provenance))
        .map_err(|e| miette!("{e}"))?;
    let file = args
        .file
        .clone()
        .unwrap_or_else(|| PathBuf::from(format!("{}.{}", args.cluster, bundle::EXTENSION)));
    let dir = match file.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => Path::new("."),
    };
    let mut temp = tempfile::NamedTempFile::new_in(dir)
        .map_err(|e| miette!("cannot write in {}: {e}", dir.display()))?;
    contents
        .write(std::io::BufWriter::new(temp.as_file_mut()))
        .map_err(|e| miette!("cannot write {}: {e}", file.display()))?;
    // Read back what was written, so a bundle that would be refused is never
    // left at `file`.
    let written =
        load(temp.path()).map_err(|e| miette!("the build did not make a valid bundle: {e}"))?;
    temp.persist(&file).into_diagnostic()?;
    if !quiet {
        eprintln!(
            "Wrote {} ({} files, sha256:{})",
            file.display(),
            written.contents().files.len(),
            written.sha256()
        );
    }
    Ok(())
}
