//! Constructing bundle headers and writing `.kixbundle` streams from store files.

use std::collections::{BTreeMap, HashMap};
use std::io::{self, Write};
use std::path::Path;

use kix::build_source::Provenance;
use kix::eval::error::KixEvalError;
use kix::eval::{store, store_path};

use crate::{FORMAT, FileEntry, Header, MAX_FRAME_BYTES, VERSION, stream_order};

/// What a bundle holds. [`Contents::write`] makes a bundle of it.
#[derive(Debug, Clone)]
pub struct Contents {
    pub kix_rev: String,
    pub receipt: Option<Provenance>,
    pub files: BTreeMap<String, BundleFile>,
}

/// One store file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleFile {
    pub bytes: Vec<u8>,
    /// The store paths it references, as Nix records them.
    pub references: Vec<String>,
}

impl Contents {
    /// Build the frame 0 [`Header`] for these contents. Fails when a path is
    /// not a store path, or a file references a path that is not among the
    /// files.
    pub fn header(&self) -> io::Result<Header> {
        let invalid = |message: String| io::Error::new(io::ErrorKind::InvalidInput, message);
        if let Some(path) = self.files.keys().find(|p| store_path::name_of(p).is_none()) {
            return Err(invalid(format!("'{path}' is not a store path")));
        }
        let mut paths: Vec<&str> = self.files.keys().map(String::as_str).collect();
        paths.sort_by(|a, b| stream_order(a, b));
        let position: HashMap<&str, u32> = (0..).zip(&paths).map(|(i, p)| (*p, i)).collect();
        let files = paths
            .iter()
            .map(|path| {
                let file = &self.files[*path];
                let references = file
                    .references
                    .iter()
                    .map(|r| {
                        position.get(r.as_str()).copied().ok_or_else(|| {
                            invalid(format!(
                                "{path} references {r}, which is not among the files"
                            ))
                        })
                    })
                    .collect::<io::Result<_>>()?;
                Ok(FileEntry {
                    path: path.to_string(),
                    size: file.bytes.len() as u64,
                    references,
                })
            })
            .collect::<io::Result<_>>()?;
        Ok(Header {
            format: FORMAT.to_string(),
            version: VERSION,
            kix_rev: self.kix_rev.clone(),
            files,
            receipt: self.receipt.clone(),
        })
    }

    /// Write the bundle to `out`. Produces deterministic output for the same
    /// Kix and libzstd versions: the file order is fixed, and zstd runs on one
    /// thread at its default level. Fails if any file exceeds
    /// [`MAX_FRAME_BYTES`].
    pub fn write(&self, out: impl Write) -> io::Result<()> {
        let header = self.header()?;
        if let Some(f) = header.files.iter().find(|f| f.size > MAX_FRAME_BYTES) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "{} is {} bytes; a bundle holds files of up to {MAX_FRAME_BYTES} bytes",
                    f.path, f.size
                ),
            ));
        }
        let files: Vec<&[u8]> = header
            .files
            .iter()
            .map(|f| self.files[&f.path].bytes.as_slice())
            .collect();
        kix_container::write(&serde_json::to_vec(&header)?, &files, out)
    }
}

/// Load bundle [`Contents`] from a Nix build result directory using
/// `nix path-info`.
pub fn from_result_dir(
    result_dir: &Path,
    kix_rev: &str,
    receipt: Option<Provenance>,
) -> Result<Contents, KixEvalError> {
    let err = |message: String| KixEvalError::StoreGraphError { message };
    let activation = store::canonicalize(&result_dir.join("activation")).map_err(|e| {
        err(format!(
            "failed to resolve activation in {}: {e}",
            result_dir.display()
        ))
    })?;
    let mut files = BTreeMap::new();
    for (path, references) in kix::eval::nix::path_info(&activation)? {
        let bytes = store::disk_path(Path::new(&path))
            .and_then(std::fs::read)
            .map_err(|e| err(format!("failed to read {path}: {e}")))?;
        files.insert(path, BundleFile { bytes, references });
    }
    Ok(Contents {
        kix_rev: kix_rev.to_string(),
        receipt,
        files,
    })
}
