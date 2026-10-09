//! Bundle files on disk: a bundle as the build `--bundle` plans and deploys,
//! the bundles `--deployed-bundle` supplies, and writing one for
//! `kix bundle`.

use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Cursor, Read};
use std::path::{Path, PathBuf};

use serde_json::json;

use kix::build_source::{Build, CarriedBuild, Provenance};
use kix::eval::stamp::stamp_annotations;
use kix::eval::store_graph::{StoreGraph, store_hash};
use kix::text::printable;

use crate::{Bundle, BundleError, MAX_STORED_BYTES, OpenBundle, from_result_dir};

/// The build in the bundle at `path`, with the `deployed` bundles, which
/// must be a build of `cluster`. Its result directory is
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

/// A bundle written by [`write_build`].
pub struct Written {
    /// How many store files it holds.
    pub files: usize,
    /// The SHA-256 of its bytes, in hex.
    pub sha256: String,
}

/// Write the build `graph`, read from its result directory in this
/// machine's Nix store, to `file` as a bundle. The bundle is read back
/// first, and `file` is left alone unless it reads as the same build.
pub fn write_build(
    graph: &StoreGraph,
    kix_rev: &str,
    receipt: Option<Provenance>,
    file: &Path,
) -> Result<Written, String> {
    let contents =
        from_result_dir(&graph.result_dir, kix_rev, receipt).map_err(|e| e.to_string())?;
    let dir = match file.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => Path::new("."),
    };
    let mut temp = tempfile::NamedTempFile::new_in(dir)
        .map_err(|e| format!("cannot write in {}: {e}", dir.display()))?;
    contents
        .write(std::io::BufWriter::new(temp.as_file_mut()))
        .map_err(|e| format!("cannot write {}: {e}", file.display()))?;
    // Read back what was written, so a bundle that would be refused, or
    // that a deploy would read as another build, is never left at `file`.
    // A deploy reads it stamped, so it is compared stamped, as `graph` is.
    // Stamped here, not through `Build`, because stamping records the result
    // directory, which must first be the build's.
    let (written, mut read_back) =
        load(temp.path()).map_err(|e| format!("the build did not make a valid bundle: {e}"))?;
    read_back.result_dir = graph.result_dir.clone();
    stamp_annotations(&mut read_back);
    if read_back != *graph || !read_back.packages.keys().eq(graph.packages.keys()) {
        return Err(format!(
            "the bundle reads back as another build than {}",
            graph.result_dir.display()
        ));
    }
    temp.persist(file)
        .map_err(|e| format!("cannot write {}: {e}", file.display()))?;
    Ok(Written {
        files: written.header().files.len(),
        sha256: written.sha256().to_string(),
    })
}

/// The bytes of the bundle file at `path`. Reads no more than a bundle may
/// hold, so a larger file is refused before it fills memory.
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

/// A bundle read whole into memory.
type InMemory = Bundle<Cursor<Vec<u8>>>;

/// A bundle as a build made elsewhere, with the `--deployed-bundle` files,
/// by the identity hash of their Activation record.
struct BundleSource {
    bundle: InMemory,
    deployed: HashMap<String, PathBuf>,
}

impl CarriedBuild for BundleSource {
    /// The bundle's files that are neither manifests nor its index. Each is
    /// checked against its store path again as it is read.
    fn sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String> {
        self.bundle
            .other_files()
            .map_err(|e| format!("cannot read the bundle's SOPS files: {e}"))
    }

    /// What the machine that made the bundle recorded, with the kix
    /// revision the bundle names under `source.bundle`.
    fn provenance(&self) -> Provenance {
        let header = self.bundle.header();
        let mut made = header.receipt.clone().unwrap_or_default();
        made.source
            .insert("bundle".to_string(), json!({ "kixRev": header.kix_rev }));
        made
    }

    /// Reads and verifies the `--deployed-bundle` file on each call, so the
    /// process keeps no copy of the graph beside the one it returns.
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

/// Read and verify the bundle at `path`, and give it with its build.
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

/// A `--deployed-bundle` file, opened, or `None` for a format 1 bundle. A
/// cluster deployed from one before format 2 still has those bytes as a
/// deployed build, so it is set aside with a warning rather than stopping
/// the command.
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

/// The graph of the bundle at `path`, which must still hold the build of
/// the record with `identity_hash`.
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
