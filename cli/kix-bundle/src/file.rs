//! Reading and writing `.kixbundle` files on disk for `--bundle`,
//! `--deployed-bundle`, and `kix bundle`.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Cursor, Read};
use std::path::{Path, PathBuf};

use serde_json::json;

use kix::build_source::{Build, CarriedBuild, Provenance};
use kix::eval::stamp::stamp_annotations;
use kix::eval::store_graph::{StoreGraph, store_hash};
use kix::text::printable;

use crate::{Bundle, BundleError, MAX_STORED_BYTES, OpenBundle, from_local};

/// Load the bundle at `path` (along with any `--deployed-bundle` paths in
/// `deployed`) as a [`Build`] for `cluster`, setting its `built_via` to
/// `bundle:sha256:<sha256>`.
pub fn read_build(path: &Path, deployed: &[PathBuf], cluster: &str) -> Result<Build, String> {
    let bytes = read_file(path)?;
    let deployed = deployed_by_hash(deployed)?;
    Build::carried(bytes, cluster, |bytes| {
        let (bundle, graph) = Bundle::read(Cursor::new(bytes)).map_err(|e| e.to_string())?;
        Ok((BundleSource { bundle, deployed }, graph))
    })
    .map_err(|e| format!("cannot use the bundle {}: {e}", path.display()))
}

/// Summary of a bundle written by [`write_build`].
pub struct Written {
    /// Number of store files in the bundle.
    pub files: usize,
    /// Lowercase hex SHA-256 digest of the bundle file.
    pub sha256: String,
}

/// Write `graph` from its build in the local Nix store to `file` as
/// a bundle, verifying that the written bundle reads back as an identical
/// build before persisting it.
pub fn write_build(
    graph: &StoreGraph,
    kix_rev: &str,
    receipt: Option<Provenance>,
    file: &Path,
) -> Result<Written, String> {
    let contents = from_local(&graph.built_via, kix_rev, receipt).map_err(|e| e.to_string())?;
    let dir = match file.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => Path::new("."),
    };
    let mut temp = tempfile::NamedTempFile::new_in(dir)
        .map_err(|e| format!("cannot write in {}: {e}", dir.display()))?;
    contents
        .write(std::io::BufWriter::new(temp.as_file_mut()))
        .map_err(|e| format!("cannot write {}: {e}", file.display()))?;
    // Verify that the written bundle loads and stamps to the exact same
    // StoreGraph before atomically renaming it into place.
    let (written, mut read_back) =
        load(temp.path()).map_err(|e| format!("the build did not make a valid bundle: {e}"))?;
    read_back.built_via = graph.built_via.clone();
    stamp_annotations(&mut read_back);
    if read_back != *graph || !read_back.packages.keys().eq(graph.packages.keys()) {
        return Err(format!(
            "the bundle reads back as another build than {}",
            graph.built_via.display()
        ));
    }
    temp.persist(file)
        .map_err(|e| format!("cannot write {}: {e}", file.display()))?;
    Ok(Written {
        files: written.header().files.len(),
        sha256: written.sha256().to_string(),
    })
}

/// Read the bundle file at `path`, rejecting files larger than
/// [`MAX_STORED_BYTES`] before reading the rest into memory.
fn read_file(path: &Path) -> Result<Vec<u8>, String> {
    let mut bytes = Vec::new();
    open_file(path)?
        .take(MAX_STORED_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read the bundle {}: {e}", path.display()))?;
    if bytes.len() as u64 > MAX_STORED_BYTES {
        return Err(format!(
            "the bundle {} is larger than the {MAX_STORED_BYTES} bytes a bundle may hold",
            path.display(),
        ));
    }
    Ok(bytes)
}

type InMemory = Bundle<Cursor<Vec<u8>>>;

/// Bundle-backed [`CarriedBuild`] implementation paired with any
/// `--deployed-bundle` paths keyed by Activation identity hash.
struct BundleSource {
    bundle: InMemory,
    deployed: HashMap<String, PathBuf>,
}

impl CarriedBuild for BundleSource {
    /// Return all [`Role::Other`](crate::Role::Other) files in the bundle,
    /// re-verifying each file's store path as it is read.
    fn sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String> {
        self.bundle
            .other_files()
            .map_err(|e| format!("cannot read the bundle's SOPS files: {e}"))
    }

    /// Return the provenance recorded in the bundle header, adding the
    /// bundle's `kix_rev` under `source.bundle`.
    fn provenance(&self) -> Provenance {
        let header = self.bundle.header();
        let mut made = header.receipt.clone().unwrap_or_default();
        made.source
            .insert("bundle".to_string(), json!({ "kixRev": header.kix_rev }));
        made
    }

    /// Read and verify the `--deployed-bundle` file on each call so only one
    /// deployed graph is held in memory at a time.
    fn deployed_build(&self, identity_hash: &str) -> Result<Option<StoreGraph>, String> {
        let Some(path) = self.deployed.get(identity_hash) else {
            return Ok(None);
        };
        graph_of(path, identity_hash).map(Some)
    }
}

fn open_file(path: &Path) -> Result<BufReader<File>, String> {
    File::open(path)
        .map(BufReader::new)
        .map_err(|e| format!("cannot read the bundle {}: {e}", path.display()))
}

/// Read and verify the bundle at `path`, returning the in-memory bundle and
/// its [`StoreGraph`].
fn load(path: &Path) -> Result<(InMemory, StoreGraph), String> {
    let bytes = read_file(path)?;
    Bundle::read(Cursor::new(bytes))
        .map_err(|e| format!("cannot use the bundle {}: {e}", path.display()))
}

/// Open each `--deployed-bundle` file, reading its seek table and header
/// only, and key it by the identity hash of its Activation record.
fn deployed_by_hash(paths: &[PathBuf]) -> Result<HashMap<String, PathBuf>, String> {
    let mut by_hash = HashMap::new();
    for path in paths {
        if let Some(open) = open_deployed(path)? {
            by_hash.insert(store_hash(Path::new(open.record())), path.clone());
        }
    }
    Ok(by_hash)
}

/// Open a `--deployed-bundle` file, or log a warning and return `None` if it
/// is a legacy format 1 bundle.
fn open_deployed(path: &Path) -> Result<Option<OpenBundle<BufReader<File>>>, String> {
    match OpenBundle::open(open_file(path)?) {
        Ok(open) => Ok(Some(open)),
        Err(BundleError::Format1) => {
            tracing::warn!(
                bundle = %path.display(),
                "set aside a deployed bundle of format 1, which this kix cannot read. For the Active build, the plan reads its objects from the cluster. For a failed or kept build, this plan cannot list or prune its orphans"
            );
            Ok(None)
        }
        Err(e) => Err(format!("cannot use the bundle {}: {e}", path.display())),
    }
}

/// Load the [`StoreGraph`] from the bundle at `path` and verify that its
/// Activation record still matches `identity_hash`.
fn graph_of(path: &Path, identity_hash: &str) -> Result<StoreGraph, String> {
    let (loaded, graph) = load(path)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &[u8] = include_bytes!("../tests/fixtures/kix-enterprise-test.kixbundle");

    /// A `--deployed-bundle` file that does not verify fails the command,
    /// as a result directory that does not load does.
    #[test]
    fn a_deployed_bundle_that_does_not_verify_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deployed.kixbundle");
        let mut bytes = FIXTURE.to_vec();
        std::fs::write(&path, &bytes).unwrap();
        let hash = store_hash(Path::new(load(&path).unwrap().0.record()));
        assert!(graph_of(&path, &hash).is_ok());
        assert!(graph_of(&path, "0000").is_err());
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        std::fs::write(&path, &bytes).unwrap();
        assert!(graph_of(&path, &hash).is_err());
    }

    /// A `--deployed-bundle` that no longer verifies is an error for the
    /// build it holds, not a build this machine lacks: the plan says so.
    #[test]
    fn a_deployed_bundle_that_does_not_verify_is_not_taken_as_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deployed.kixbundle");
        let mut bytes = FIXTURE.to_vec();
        std::fs::write(&path, &bytes).unwrap();
        let build = read_build(&path, std::slice::from_ref(&path), "kix-enterprise-test").unwrap();
        let hash = store_hash(&build.graph().activation_path);
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        std::fs::write(&path, &bytes).unwrap();
        let found =
            kix::plan::baseline::record_graph(Some(&build), "kix-enterprise-test", &hash, None);
        assert!(found.is_err());
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

    /// Build a single-frame seekable zstd file containing `header`.
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
