//! `kix bundle`, and reading bundles for `--bundle` and `--deployed-bundle`.
//!
//! A bundle (`kix::eval::bundle`) is a build as one file that loads without
//! Nix. `--bundle` makes it the new side of `kix plan`, `kix deploy` and
//! `kix graph`. `--deployed-bundle` supplies builds the cluster's records
//! name, which kix otherwise looks for in the local Nix store.

use std::collections::HashMap;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use miette::{IntoDiagnostic, Result, miette};

use kix::cluster::secrets::SopsSources;
use kix::eval::build::build_cluster_activation_with_status;
use kix::eval::bundle::{self, Bundle, BundleError, Header, OpenBundle};
use kix::eval::store_graph::{StoreGraph, store_hash};
use kix::text::printable;

use crate::cli::BundleArgs;

use super::CommandContext;

/// A bundle file, verified. Files are read from it as they are needed.
#[derive(Debug)]
pub struct LoadedBundle(Bundle<BufReader<File>>);

impl LoadedBundle {
    pub fn header(&self) -> &Header {
        self.0.header()
    }

    /// The store path of the Activation record.
    pub fn record(&self) -> &str {
        self.0.record()
    }

    /// The cluster the Activation record is labelled with.
    pub fn cluster(&self) -> &str {
        self.0.cluster()
    }

    /// The SHA-256 of the file's bytes.
    pub fn sha256(&self) -> &str {
        self.0.sha256()
    }

    /// The bundle's SOPS files. With `placeholders`, nothing is decrypted:
    /// what `kix plan` uses, so a plan made before approval reads no secret.
    pub fn sops(&mut self, placeholders: bool) -> Result<SopsSources> {
        let sources = self
            .0
            .other_files()
            .map_err(|e| miette!("cannot read the bundle's SOPS files: {e}"))?;
        SopsSources::carried(sources, placeholders)
            .map_err(|e| miette!("cannot write the bundle's SOPS files: {e}"))
    }
}

fn open_file(path: &Path) -> Result<BufReader<File>> {
    File::open(path)
        .map(BufReader::new)
        .map_err(|e| miette!("cannot read the bundle {}: {e}", path.display()))
}

/// Read and verify a bundle, and give it with its build, whose result
/// directory is `bundle:sha256:<sha256>`.
pub fn load(path: &Path) -> Result<(LoadedBundle, StoreGraph)> {
    let (bundle, graph) = Bundle::read(open_file(path)?)
        .map_err(|e| miette!("cannot use the bundle {}: {e}", path.display()))?;
    Ok((LoadedBundle(bundle), graph))
}

/// The `--deployed-bundle` files, by the identity hash of their Activation
/// record, which the header gives. Set once per process, before any record
/// is resolved.
static DEPLOYED: OnceLock<HashMap<String, PathBuf>> = OnceLock::new();

/// Open each `--deployed-bundle` file, reading its seek table and header
/// only. Later calls in the same process are ignored: `kix deploy --plan`
/// prepares twice with the same arguments.
pub fn register_deployed(paths: &[PathBuf]) -> Result<()> {
    if DEPLOYED.get().is_some() {
        return Ok(());
    }
    let mut by_hash = HashMap::new();
    for path in paths {
        if let Some(open) = open_deployed(path)? {
            by_hash.insert(store_hash(Path::new(open.record())), path.clone());
        }
    }
    let _ = DEPLOYED.set(by_hash);
    Ok(())
}

/// A `--deployed-bundle` file, opened, or `None` for a format 1 bundle. A
/// cluster deployed from one before format 2 still has those bytes as a
/// deployed build, so it is set aside with a warning rather than stopping
/// the command.
fn open_deployed(path: &Path) -> Result<Option<OpenBundle<BufReader<File>>>> {
    match OpenBundle::open(open_file(path)?) {
        Ok(open) => Ok(Some(open)),
        Err(BundleError::Format1) => {
            tracing::warn!(
                bundle = %path.display(),
                "set aside a deployed bundle of format 1, which this kix cannot read. For the Active build, the plan reads its objects from the cluster. For a failed or kept build, this plan cannot list or prune its orphans"
            );
            Ok(None)
        }
        Err(e) => Err(miette!("cannot use the bundle {}: {e}", path.display())),
    }
}

/// The build of the record with `identity_hash`, from `--deployed-bundle`,
/// or `Ok(None)` when no such file was given. Reads and verifies the file on
/// each call, so the process keeps no copy of the graph beside the one it
/// returns. A file that no longer verifies is an error, as a result
/// directory that does not load is.
pub fn deployed_graph(identity_hash: &str) -> Result<Option<StoreGraph>, String> {
    let Some(path) = DEPLOYED.get().and_then(|d| d.get(identity_hash)) else {
        return Ok(None);
    };
    graph_of(path, identity_hash).map(Some)
}

/// The graph of the bundle at `path`, which must still hold the build of
/// the record with `identity_hash`.
fn graph_of(path: &Path, identity_hash: &str) -> Result<StoreGraph, String> {
    let (loaded, graph) = load(path).map_err(|e| e.to_string())?;
    // The file may have changed since its header was read.
    let activation = loaded.record();
    if store_hash(Path::new(activation)) != identity_hash {
        return Err(format!(
            "the deployed bundle {} now holds activation {}, not {identity_hash}",
            path.display(),
            printable(activation)
        ));
    }
    Ok(graph)
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
    // Read back what was written, so a bundle that would be refused, or
    // that a deploy would read as another build, is never left at `file`.
    let (written, mut read_back) =
        load(temp.path()).map_err(|e| miette!("the build did not make a valid bundle: {e}"))?;
    read_back.result_dir = graph.result_dir.clone();
    if read_back != graph || !read_back.packages.keys().eq(graph.packages.keys()) {
        return Err(miette!(
            "the bundle reads back as another build than {}",
            result_dir.display()
        ));
    }
    temp.persist(&file).into_diagnostic()?;
    if !quiet {
        eprintln!(
            "Wrote {} ({} files, sha256:{})",
            file.display(),
            written.header().files.len(),
            written.sha256()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `--deployed-bundle` file that does not verify fails the command,
    /// as a result directory that does not load does.
    #[test]
    fn a_deployed_bundle_that_does_not_verify_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deployed.kixbundle");
        let mut bytes =
            include_bytes!("../../../kix/tests/fixtures/bundles/kix-enterprise-test.kixbundle")
                .to_vec();
        std::fs::write(&path, &bytes).unwrap();
        let hash = store_hash(Path::new(load(&path).unwrap().0.record()));
        assert!(graph_of(&path, &hash).is_ok());
        assert!(graph_of(&path, "0000").is_err());
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        std::fs::write(&path, &bytes).unwrap();
        assert!(graph_of(&path, &hash).is_err());
    }

    /// A cluster deployed from a format 1 bundle still has those bytes as
    /// its deployed build. The plan goes on without it.
    #[test]
    fn a_format_1_deployed_bundle_is_set_aside() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("old.kixbundle");
        let mut tar = vec![0u8; 1024];
        tar[..15].copy_from_slice(b"kix-bundle.json");
        std::fs::write(&path, tar).unwrap();
        assert!(open_deployed(&path).unwrap().is_none());
    }

    /// A seekable file with one frame, the header `header`, and its seek
    /// table: what a bundle's header and frames look like before any file.
    fn header_only(header: &serde_json::Value) -> Vec<u8> {
        let data = serde_json::to_vec(header).unwrap();
        let mut c = zstd::bulk::Compressor::new(3).unwrap();
        c.include_contentsize(true).unwrap();
        let frame = c.compress(&data).unwrap();
        let mut out = frame.clone();
        out.extend(0x184D_2A5Eu32.to_le_bytes());
        out.extend(17u32.to_le_bytes());
        out.extend((frame.len() as u32).to_le_bytes());
        out.extend((data.len() as u32).to_le_bytes());
        out.extend(1u32.to_le_bytes());
        out.push(0);
        out.extend(0x8F92_EAB1u32.to_le_bytes());
        out
    }

    /// Only a tar file is format 1. A header that says version 1, of this
    /// format or another, stops the command like any unreadable bundle.
    #[test]
    fn a_header_that_says_version_1_is_not_set_aside() {
        let dir = tempfile::tempdir().unwrap();
        for format in ["kix-bundle", "other"] {
            let path = dir.path().join(format!("{format}.kixbundle"));
            let header = serde_json::json!({"format": format, "version": 1});
            std::fs::write(&path, header_only(&header)).unwrap();
            assert!(open_deployed(&path).is_err(), "{format}");
        }
    }
}
