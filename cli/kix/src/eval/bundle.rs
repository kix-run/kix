//! Bundles: a cluster build as one file, read without Nix.
//!
//! `kix bundle` writes every store file in a build's Activation closure,
//! with its references. `kix graph`, `kix plan`, and `kix deploy` read it
//! with `--bundle`, so a machine with no Nix store, such as an in-cluster
//! agent, can plan and deploy a build made elsewhere.
//!
//! # Format 3
//!
//! A bundle (`*.kixbundle`) is a file in zstd's seekable format. Integers
//! are little-endian.
//!
//! - Frame 0 is the [`Header`] as JSON: `format` (`kix-bundle`), `version`
//!   (3), `kix_rev`, an optional `receipt` that only the deploy receipt
//!   shows, and `files`, one `[path, size, references]` per store file,
//!   each reference an index into `files`. Files are sorted by store name,
//!   then by path, and no path appears twice.
//! - Frames 1 to n hold the files' bytes, concatenated in that order. A
//!   frame holds whole files and at least one byte.
//! - A skippable frame ends the file: the seek table, each frame's
//!   compressed and decompressed size, with no checksums.
//!
//! `zstd -d` gives the header followed by the files. The same contents give
//! the same bytes from the same kix and libzstd.
//!
//! # What the references say
//!
//! The header names no record, index or cluster. They are derived from the
//! references before any file is read:
//!
//! - The record is the one file no other file references. It is named
//!   `k8s-*` and is a manifest of kind Activation in the `kix.run` group.
//! - The index is the record's one direct reference named
//!   `kix-packages.json`.
//! - Every file is in the record's closure. kix/lib makes the record
//!   reference the index, and the index reference every file it lists, so
//!   the record's store path covers the whole build.
//! - The cluster is the record's `kix.run/cluster` label.
//!
//! Each file then has one [`Role`]: `Record`, `Index`, `Manifest` (any other
//! file named `k8s-*`), or `Other` (a SOPS source, or a marker such as
//! `kix-untracked-ref`, carried and not parsed).
//!
//! # Names equal content
//!
//! Every reader recomputes each file's store path from its bytes, its
//! references, and its name (`eval::store_path`), and refuses a file whose
//! path differs. Equal paths then mean equal content, as they do for a Nix
//! build, so the decisions kix makes by name (skip an unchanged object,
//! prune, gc, and the Activation name) hold for bundles.
//!
//! # One parser
//!
//! [`parse_manifest`] parses every manifest and every index, from bundles
//! and from result directories. It refuses a key given twice, a key that
//! starts `$serde_json::private::` (serde_json's `Value`, with the
//! `raw_value` feature this workspace turns on, reads an object with that
//! key as the raw JSON its value holds), and nesting past serde_json's own
//! limit of 128.
//!
//! # Two readers
//!
//! [`PathsChecked::read`] is for a server that stores bundles from any
//! tenant and never plans them. It checks the container, every store path,
//! the roles, and the closure, and parses only the record. It holds the
//! header as read and parsed, one frame compressed and decompressed, a few
//! words per file, and the parsed record: under 200 MiB.
//!
//! [`Bundle::read`] is for the agent and the CLI. It does the same, then
//! parses every manifest and the index and gives the build's [`StoreGraph`],
//! built by [`StoreGraph::assemble`] and checked by
//! [`StoreGraph::validate`], as a result directory's is. It keeps every
//! manifest parsed, so the process's memory limit bounds it.
//!
//! [`OpenBundle::open`] reads only the seek table and the header, for a
//! bundle verified before. Each file read through it is checked against its
//! store path again.
//!
//! # Invariants
//!
//! After [`PathsChecked::read`]:
//!
//! - every file's store path is made from its bytes, references, and name;
//! - one record, of kind Activation in `kix.run`, whose closure is every
//!   file and which references the index directly;
//! - `cluster()` is the record's cluster label, and `sha256()` covers every
//!   byte of the file.
//!
//! After [`Bundle::read`], also:
//!
//! - every manifest and the index parse with [`parse_manifest`], and every
//!   path the index lists is a manifest in the bundle;
//! - [`StoreGraph::validate`] holds: one Activation record, at the record's
//!   path, labelled with the index's cluster; each object (kind, namespace,
//!   name) once; one package per namespace and instance, each with its
//!   PackageInstance; only import markers listed by more than one package;
//!   every kind non-empty, and every name, namespace and `apiVersion` part
//!   one URL path segment: not empty, `.`, or `..`, and without `/`, `%`,
//!   `?`, or `#`, since kube-rs puts them in request paths unescaped.
//!
//! # Caps and refusals
//!
//! | Cap or refusal | Protects |
//! |---|---|
//! | [`MAX_STORED_BYTES`], 64 MiB | server: bytes read and hashed per upload |
//! | [`MAX_HEADER_BYTES`], 32 MiB | server: memory for the header |
//! | [`MAX_FILES`], 200,000 | server: memory per file and per seek-table entry |
//! | [`MAX_REFERENCES`], 1,600,000 | server: time to hash the references of every path |
//! | [`MAX_FRAME_BYTES`], 32 MiB | server: memory for one frame, so also the largest file |
//! | [`MAX_CONTENT_BYTES`], 1 GiB | server: time to decompress and hash the files |
//! | [`MAX_RECORD_BYTES`], 256 KiB | server: memory to parse the record |
//! | `cluster::secrets` 8 MiB of SOPS text, aliases expanded | agent: a plan parses SOPS files before anyone approves it |
//! | `WrongFormat`, `Format1` | another format is never read as this one; `--deployed-bundle` sets format 1 aside |
//! | `Malformed` | the reader finds each file where the header says, in one encoding |
//! | `PathMismatch` | names equal content |
//! | `Roots`, `NotARecord`, `NoIndex`, `Unreachable` | one record, whose name covers every file |
//! | `NotJson` | each check reads the value plan and deploy use |
//! | `Build` | plan shows each object once, under one package, at the URL kix requests |
//!
//! # Threat model
//!
//! - On the server, [`PathsChecked`] reads uploads from any tenant's
//!   uploader. Their effect must stay within bounded memory and CPU.
//! - On the agent, [`Bundle::read`] reads uploads from this cluster's
//!   uploader. Only name-equals-content and one record matter: plan-bound
//!   deploy refuses any write or delete the approved plan does not show,
//!   and the agent runs kix under memory, CPU, and time limits.

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};

use serde::de::{Error as _, MapAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};

use super::error::KixEvalError;
use super::store_graph::{KixPackageIndex, StoreGraph, store_name};
use super::store_path::{self, Method, STORE_DIR};
use crate::manifest::types::ResourceId;
use crate::manifest::{keys, lifecycle};

/// The `format` field of every bundle header.
pub const FORMAT: &str = "kix-bundle";
/// The version this kix writes and reads. A reader refuses any other.
pub const VERSION: u32 = 1;
/// The file extension `kix bundle` suggests.
pub const EXTENSION: &str = "kixbundle";
/// The name of the header entry, which must come first.
pub const HEADER_ENTRY: &str = "kix-bundle.json";
/// The directory the store files are under, inside the tar file.
pub const STORE_ENTRY_DIR: &str = "store";
/// The most bytes kix reads from a bundle, counted once as stored and once
/// uncompressed. The second count stops a small file that decompresses to
/// something huge.
pub const MAX_BYTES: u64 = 64 * 1024 * 1024;
/// The most store files a bundle may hold.
pub const MAX_FILES: usize = 50_000;
/// The largest header kix reads, in bytes. The header of the stage1 test build
/// takes 282 bytes per store path, so [`MAX_FILES`] paths at that rate take
/// 14 MB.
pub const MAX_HEADER_BYTES: u64 = 24 * 1024 * 1024;
/// The largest receipt a header may carry, as JSON. `kix bundle` writes
/// about 150 bytes per flake input.
pub const MAX_RECEIPT_BYTES: usize = 256 * 1024;
/// The largest manifest kix reads, in bytes. The API server refuses a
/// request body over 3 MiB.
pub const MAX_MANIFEST_BYTES: u64 = 3 * 1024 * 1024;

/// The first four bytes of a zstd frame.
const ZSTD_MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];

/// `kix-bundle.json`, the first entry of a bundle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Header {
    /// Always [`FORMAT`].
    pub format: String,
    /// Always [`VERSION`].
    pub version: u32,
    /// The kix revision that wrote the bundle, for the record. Not checked.
    pub kix_rev: String,
    /// The cluster name the build gives (`kix-packages.json`'s `cluster`).
    pub cluster: String,
    /// The store path of the Activation record.
    pub activation: String,
    /// The store path of `kix-packages.json`.
    pub index: String,
    /// Every store path in the bundle, with the store paths its file
    /// references, as Nix records them. The bundle holds exactly these files.
    #[serde(deserialize_with = "store_references")]
    pub references: BTreeMap<String, Vec<String>>,
    /// What `kix deploy` would otherwise read from the flake's checkout for
    /// the deploy receipt.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "capped_receipt"
    )]
    pub receipt: Option<Provenance>,
}

/// What the machine that wrote a bundle recorded about the build's source,
/// for the deploy receipt: the receipt's `source`, `inputs` and `builder`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provenance {
    #[serde(default)]
    pub source: serde_json::Map<String, serde_json::Value>,
    #[serde(default)]
    pub inputs: Vec<serde_json::Map<String, serde_json::Value>>,
    #[serde(default)]
    pub builder: serde_json::Map<String, serde_json::Value>,
}

/// The header's `references`, refused while it is parsed when it lists more
/// than [`MAX_FILES`] paths or holds a string that is not a store path. A
/// store path is at least 45 bytes, so the parsed map takes no more than a
/// few times the header's size in memory.
fn store_references<'de, D: Deserializer<'de>>(
    d: D,
) -> Result<BTreeMap<String, Vec<String>>, D::Error> {
    struct StorePath(String);
    impl<'de> Deserialize<'de> for StorePath {
        fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
            let path = String::deserialize(d)?;
            if store_path::name_of(&path).is_none() {
                return Err(D::Error::custom(format!("'{path}' is not a store path")));
            }
            Ok(StorePath(path))
        }
    }
    struct References;
    impl<'de> Visitor<'de> for References {
        type Value = BTreeMap<String, Vec<String>>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a map of store paths to the store paths they reference")
        }
        fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
            let mut out = BTreeMap::new();
            while let Some(StorePath(path)) = map.next_key()? {
                if out.len() == MAX_FILES {
                    return Err(A::Error::custom(format!(
                        "the bundle lists more than {MAX_FILES} store paths"
                    )));
                }
                let refs: Vec<StorePath> = map.next_value()?;
                out.insert(path, refs.into_iter().map(|StorePath(r)| r).collect());
            }
            Ok(out)
        }
    }
    d.deserialize_map(References)
}

/// The header's `receipt`, refused when it is over [`MAX_RECEIPT_BYTES`]
/// before it is parsed.
fn capped_receipt<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Provenance>, D::Error> {
    let Some(raw) = Option::<Box<serde_json::value::RawValue>>::deserialize(d)? else {
        return Ok(None);
    };
    if raw.get().len() > MAX_RECEIPT_BYTES {
        return Err(D::Error::custom(format!(
            "the receipt is larger than {MAX_RECEIPT_BYTES} bytes"
        )));
    }
    serde_json::from_str(raw.get())
        .map(Some)
        .map_err(|e| D::Error::custom(format!("receipt: {e}")))
}

/// What a bundle holds: the header's fields, and the files by store path.
/// [`Contents::write`] makes a bundle of it; [`Bundle::read`] gives it back
/// once the bundle is verified.
#[derive(Debug, Clone)]
pub struct Contents {
    pub kix_rev: String,
    pub cluster: String,
    pub activation: String,
    pub index: String,
    pub receipt: Option<Provenance>,
    pub files: BTreeMap<String, BundleFile>,
}

/// One store file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BundleFile {
    /// The file's bytes.
    pub bytes: Vec<u8>,
    /// The store paths it references, as Nix records them.
    pub references: Vec<String>,
}

/// A bundle that has been read and verified. Only [`Bundle::read`] makes
/// one.
#[derive(Debug, Clone)]
pub struct Bundle {
    contents: Contents,
    /// The store paths made by `builtins.path`: SOPS sources.
    sources: BTreeSet<String>,
    sha256: String,
}

/// Why a bundle was refused.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum BundleError {
    #[error("the bundle is larger than {MAX_BYTES} bytes, compressed or uncompressed")]
    TooLarge,
    #[error("the bundle is not a zstd-compressed tar file of the bundle format: {0}")]
    Unreadable(String),
    #[error("the bundle's first entry must be {HEADER_ENTRY}")]
    HeaderNotFirst,
    #[error(
        "the bundle's format is '{format}' version {version}; this kix reads '{FORMAT}' version {VERSION}"
    )]
    WrongFormat { format: String, version: u32 },
    #[error("'{0}' is not a store path")]
    NotAStorePath(String),
    #[error("the bundle's entry '{0}' is not a regular file under {STORE_ENTRY_DIR}/")]
    BadEntry(String),
    #[error("the bundle's entry '{0}' is not a store path its header lists")]
    UnlistedEntry(String),
    #[error("the bundle's entry '{0}' is out of order or repeated; entries must be sorted by name")]
    OutOfOrder(String),
    #[error("the bundle's header lists {0}, but the bundle has no entry for it")]
    MissingFile(String),
    #[error("{0} was not made from the bytes and references the bundle gives it")]
    PathMismatch(String),
    #[error("{path} references {missing}, which is not in the bundle")]
    MissingReference { path: String, missing: String },
    #[error("the bundle's {what} {path} is not among its files")]
    MissingEntry { what: &'static str, path: String },
    #[error(
        "{0} is in the bundle but not part of the build: nothing the Activation record depends on references it"
    )]
    Unreachable(String),
    #[error("{path} is not a JSON manifest: {message}")]
    NotJson { path: String, message: String },
    #[error(
        "the bundle must hold exactly one Activation record, and it must be its `activation`; found {0}"
    )]
    Records(usize),
    #[error("the bundle is for cluster '{bundle}', but its {what} says '{other}'")]
    WrongCluster {
        bundle: String,
        what: &'static str,
        other: String,
    },
    #[error("kix-packages.json lists {0}, which the Activation record's closure does not hold")]
    IndexOutsideClosure(String),
    #[error(
        "kix-packages.json and the Activation record's `spec.instances` list different package instances"
    )]
    IndexInstances,
    #[error("two manifests in the bundle name {0}")]
    DuplicateObject(String),
    #[error(
        "kix-packages.json lists {0}, which is not a manifest: its store name does not start with k8s-"
    )]
    IndexNotManifest(String),
    #[error("{0} has an apiVersion that is not spelled `v1` or `group/version`")]
    ApiVersion(String),
    #[error("{0} uses a retired kix domain key or group")]
    RetiredDomain(String),
    #[error("{0} is a source file that no Secret's SOPS source annotation names")]
    UnexpectedSource(String),
    #[error("the bundle's {HEADER_ENTRY} is larger than {MAX_HEADER_BYTES} bytes")]
    HeaderTooLarge,
    #[error(
        "{0} is larger than {MAX_MANIFEST_BYTES} bytes, the most the API server takes in one request"
    )]
    ManifestTooLarge(String),
    #[error(
        "the bundle has data after its archive: a second zstd frame, or bytes other than zero after the tar file's end"
    )]
    TrailingData,
}

impl Contents {
    /// The header [`Contents::write`] puts first.
    pub fn header(&self) -> Header {
        Header {
            format: FORMAT.to_string(),
            version: VERSION,
            kix_rev: self.kix_rev.clone(),
            cluster: self.cluster.clone(),
            activation: self.activation.clone(),
            index: self.index.clone(),
            references: self
                .files
                .iter()
                .map(|(path, file)| (path.clone(), file.references.clone()))
                .collect(),
            receipt: self.receipt.clone(),
        }
    }

    /// Write the bundle: a zstd-compressed tar file. The same contents give
    /// the same bytes from the same kix, since every tar header field is
    /// fixed and zstd runs on one thread at a fixed level.
    pub fn write(&self, out: impl Write) -> io::Result<()> {
        let mut encoder = zstd::Encoder::new(out, zstd::DEFAULT_COMPRESSION_LEVEL)?;
        write_tar(&self.header(), &self.files, &mut encoder)?;
        encoder.finish()?.flush()
    }

    /// Every store path the Activation record depends on, and the record.
    fn closure(&self) -> BTreeSet<&str> {
        closure_of(&self.activation, |p| {
            self.files.get(p).map(|f| f.references.as_slice())
        })
    }
}

/// Write `header` and `files` as a tar file to `out`.
fn write_tar(
    header: &Header,
    files: &BTreeMap<String, BundleFile>,
    out: impl Write,
) -> io::Result<()> {
    let mut tar = tar::Builder::new(out);
    let header_bytes = serde_json::to_vec(header).map_err(io::Error::other)?;
    append(&mut tar, HEADER_ENTRY, &header_bytes)?;
    for (path, file) in files {
        let base = store_path::name_of(path)
            .and(path.strip_prefix(STORE_DIR))
            .and_then(|p| p.strip_prefix('/'))
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("'{path}' is not a store path"),
                )
            })?;
        append(&mut tar, &format!("{STORE_ENTRY_DIR}/{base}"), &file.bytes)?;
    }
    tar.into_inner()?;
    Ok(())
}

/// Append a regular file with fixed metadata. A name longer than the 100
/// bytes a tar header holds gets a GNU long-name entry before it.
fn append(tar: &mut tar::Builder<impl Write>, name: &str, bytes: &[u8]) -> io::Result<()> {
    let mut header = tar::Header::new_gnu();
    header.set_entry_type(tar::EntryType::Regular);
    header.set_mode(0o444);
    header.set_mtime(0);
    header.set_uid(0);
    header.set_gid(0);
    header.set_size(bytes.len() as u64);
    tar.append_data(&mut header, name, bytes)
}

impl Bundle {
    /// Read a bundle and verify it: every path made from its file, the
    /// closure complete, one Activation record that everything hangs off,
    /// and a package index that agrees with it. See the module docs.
    ///
    /// Reads `input` to its end, so [`Bundle::sha256`] covers every byte.
    pub fn read(input: impl Read) -> Result<Self, BundleError> {
        read_limited(input, MAX_BYTES)
    }

    /// Read only the header, without verifying anything but its format and
    /// version. For choosing among bundles; [`Bundle::read`] the one chosen.
    pub fn read_header(input: impl Read) -> Result<Header, BundleError> {
        let exceeded = Cell::new(false);
        let mut stored = BufReader::new(Limited::new(input, MAX_BYTES, &exceeded));
        let result = (|| {
            let tar = open_tar(&mut stored)?;
            let mut archive = tar::Archive::new(Limited::new(tar, MAX_BYTES, &exceeded));
            let mut entries = archive.entries().map_err(unreadable)?;
            read_header_entry(&mut entries)
        })();
        result.map_err(|e| {
            if exceeded.get() {
                BundleError::TooLarge
            } else {
                e
            }
        })
    }

    pub fn contents(&self) -> &Contents {
        &self.contents
    }

    pub fn into_contents(self) -> Contents {
        self.contents
    }

    /// The SHA-256 of the bundle's bytes as read, lowercase hex: what
    /// `built-via`, the deploy receipt and a Kix Enterprise statement name
    /// it by.
    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    /// Every manifest in the bundle by store path: the files whose store
    /// name starts with `k8s-`. These are the objects a deploy of the
    /// bundle applies, the Activation record among them.
    pub fn manifests(&self) -> impl Iterator<Item = (&str, &[u8])> {
        self.contents
            .files
            .iter()
            .filter(|(path, _)| is_manifest(path))
            .map(|(path, file)| (path.as_str(), file.bytes.as_slice()))
    }

    /// The build as a [`StoreGraph`]. Its `result_dir` is
    /// `bundle:sha256:<sha256>`, which kix writes to the record's
    /// `kix.run/built-via`: a bundle has no directory on disk.
    pub fn graph(&self) -> Result<StoreGraph, KixEvalError> {
        let contents = &self.contents;
        let index = package_index(contents).map_err(|e| KixEvalError::StoreGraphError {
            message: e.to_string(),
        })?;
        let mut ref_cache: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        for path in contents.closure() {
            let mut refs: Vec<PathBuf> = contents.files[path]
                .references
                .iter()
                .filter(|r| r.as_str() != path)
                .map(PathBuf::from)
                .collect();
            // Same order `bulk_load_graph` gives a Nix build's references.
            refs.sort_by_key(|r| store_name(r).to_lowercase());
            if !refs.is_empty() {
                ref_cache.insert(PathBuf::from(path), refs);
            }
        }
        let read =
            |path: &Path| -> Result<serde_json::Value, KixEvalError> {
                let key = path.to_string_lossy();
                let file = contents.files.get(key.as_ref()).ok_or_else(|| {
                    KixEvalError::StoreGraphError {
                        message: format!("{key} is not in the bundle"),
                    }
                })?;
                serde_json::from_slice(&file.bytes).map_err(|e| KixEvalError::StoreGraphError {
                    message: format!("failed to parse JSON from {key}: {e}"),
                })
            };
        StoreGraph::assemble(
            index,
            PathBuf::from(&contents.activation),
            PathBuf::from(format!("bundle:sha256:{}", self.sha256)),
            ref_cache,
            &read,
            &|_| {},
        )
    }

    /// The bytes of each SOPS source in the bundle, by store path.
    pub fn sops_sources(&self) -> HashMap<String, Vec<u8>> {
        self.sources
            .iter()
            .map(|path| (path.clone(), self.contents.files[path].bytes.clone()))
            .collect()
    }
}

/// [`Bundle::read`] with `max_bytes` in place of [`MAX_BYTES`].
fn read_limited(input: impl Read, max_bytes: u64) -> Result<Bundle, BundleError> {
    let exceeded = Cell::new(false);
    let mut stored = BufReader::new(Hashing::new(Limited::new(input, max_bytes, &exceeded)));
    let result = (|| {
        let (contents, sources) = {
            let tar = open_tar(&mut stored)?;
            let mut tar = Limited::new(tar, max_bytes, &exceeded);
            let read = read_entries(&mut tar)?;
            // tar-rs stops at the first zero block. Every byte is hashed, so
            // anything after it must be zero, as `Contents::write` writes.
            all_zero(&mut tar)?;
            read
        };
        // `open_tar` decodes one zstd frame, and nothing may follow it.
        let mut rest = [0u8; 1];
        if stored.read(&mut rest).map_err(unreadable)? != 0 {
            return Err(BundleError::TrailingData);
        }
        Ok((contents, sources))
    })();
    let (contents, sources) = result.map_err(|e| {
        if exceeded.get() {
            BundleError::TooLarge
        } else {
            e
        }
    })?;
    Ok(Bundle {
        contents,
        sources,
        sha256: hex(&stored.into_inner().hasher.finalize()),
    })
}

/// The tar stream of a bundle: the first zstd frame decompressed, when it
/// starts with one, and as stored otherwise. The decoder takes no byte of
/// `input` past that frame.
fn open_tar<'a>(input: &'a mut impl BufRead) -> Result<Box<dyn Read + 'a>, BundleError> {
    let start = input.fill_buf().map_err(unreadable)?;
    if start.starts_with(&ZSTD_MAGIC) {
        let decoder = zstd::Decoder::with_buffer(input)
            .map_err(unreadable)?
            .single_frame();
        Ok(Box::new(decoder))
    } else {
        Ok(Box::new(input))
    }
}

/// Read `input` to its end, refusing any byte that is not zero.
fn all_zero(mut input: impl Read) -> Result<(), BundleError> {
    let mut buf = [0u8; 8192];
    loop {
        let n = input.read(&mut buf).map_err(unreadable)?;
        if n == 0 {
            return Ok(());
        }
        if buf[..n].iter().any(|b| *b != 0) {
            return Err(BundleError::TrailingData);
        }
    }
}

/// Read the header and every store file, checking each file's path as it
/// arrives, then check the build as a whole. Returns the contents and the
/// paths of the SOPS sources.
fn read_entries(tar: impl Read) -> Result<(Contents, BTreeSet<String>), BundleError> {
    let mut archive = tar::Archive::new(tar);
    let mut entries = archive.entries().map_err(unreadable)?;
    let header = read_header_entry(&mut entries)?;
    let closure = check_closure(&header)?;

    let mut files: BTreeMap<String, BundleFile> = BTreeMap::new();
    let mut methods: BTreeMap<String, Method> = BTreeMap::new();
    let mut last: Option<String> = None;
    for entry in entries {
        let mut entry = entry.map_err(unreadable)?;
        // The header names store paths as UTF-8; another spelling of the
        // same name would extract as a different file.
        let name = String::from_utf8(entry.path_bytes().into_owned()).map_err(|e| {
            BundleError::BadEntry(String::from_utf8_lossy(e.as_bytes()).into_owned())
        })?;
        if !entry.header().entry_type().is_file() {
            return Err(BundleError::BadEntry(name));
        }
        let Some(base) = name
            .strip_prefix(STORE_ENTRY_DIR)
            .and_then(|n| n.strip_prefix('/'))
        else {
            return Err(BundleError::BadEntry(name));
        };
        let path = format!("{STORE_DIR}/{base}");
        let Some(references) = header.references.get(&path) else {
            return Err(BundleError::UnlistedEntry(name));
        };
        if last.as_ref().is_some_and(|l| *l >= path) {
            return Err(BundleError::OutOfOrder(name));
        }
        if is_manifest(&path) && entry.size() > MAX_MANIFEST_BYTES {
            return Err(BundleError::ManifestTooLarge(path));
        }
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes).map_err(unreadable)?;
        let method = store_path::method_of(&path, &bytes, references)
            .ok_or_else(|| BundleError::PathMismatch(path.clone()))?;
        methods.insert(path.clone(), method);
        files.insert(
            path.clone(),
            BundleFile {
                bytes,
                references: references.clone(),
            },
        );
        last = Some(path);
    }
    if let Some(missing) = header.references.keys().find(|p| !files.contains_key(*p)) {
        return Err(BundleError::MissingFile(missing.clone()));
    }

    let sources: BTreeSet<String> = methods
        .iter()
        .filter(|(_, m)| **m == Method::Source)
        .map(|(p, _)| p.clone())
        .collect();
    let closure: BTreeSet<String> = closure.into_iter().map(str::to_string).collect();
    let contents = Contents {
        kix_rev: header.kix_rev,
        cluster: header.cluster,
        activation: header.activation,
        index: header.index,
        receipt: header.receipt,
        files,
    };
    check_build(&contents, &sources, &closure)?;
    Ok((contents, sources))
}

/// The first entry, parsed, with its format and version checked.
fn read_header_entry<R: Read>(entries: &mut tar::Entries<'_, R>) -> Result<Header, BundleError> {
    let mut entry = entries
        .next()
        .ok_or(BundleError::HeaderNotFirst)?
        .map_err(unreadable)?;
    if !entry.header().entry_type().is_file() || &*entry.path_bytes() != HEADER_ENTRY.as_bytes() {
        return Err(BundleError::HeaderNotFirst);
    }
    if entry.size() > MAX_HEADER_BYTES {
        return Err(BundleError::HeaderTooLarge);
    }
    let mut bytes = Vec::new();
    entry.read_to_end(&mut bytes).map_err(unreadable)?;
    // serde_json stops at 128 levels of nesting.
    let header: Header = serde_json::from_slice(&bytes)
        .map_err(|e| BundleError::Unreadable(format!("{HEADER_ENTRY}: {e}")))?;
    if header.format != FORMAT || header.version != VERSION {
        return Err(BundleError::WrongFormat {
            format: header.format,
            version: header.version,
        });
    }
    Ok(header)
}

/// Check the header's store paths and references before any file is read:
/// every path well formed, every reference present, the activation and the
/// index among the files, and every file part of the build. Returns the
/// Activation record's closure.
fn check_closure(header: &Header) -> Result<BTreeSet<&str>, BundleError> {
    for (path, references) in &header.references {
        if store_path::name_of(path).is_none() {
            return Err(BundleError::NotAStorePath(path.clone()));
        }
        for r in references {
            if !header.references.contains_key(r) {
                return Err(BundleError::MissingReference {
                    path: path.clone(),
                    missing: r.clone(),
                });
            }
        }
    }
    for (what, path) in [("activation", &header.activation), ("index", &header.index)] {
        if !header.references.contains_key(path) {
            return Err(BundleError::MissingEntry {
                what,
                path: path.clone(),
            });
        }
    }
    let closure = closure_of(&header.activation, |p| {
        header.references.get(p).map(Vec::as_slice)
    });
    if let Some(stray) = header
        .references
        .keys()
        .find(|p| !closure.contains(p.as_str()) && **p != header.index)
    {
        return Err(BundleError::Unreachable(stray.clone()));
    }
    Ok(closure)
}

/// Check what the files say once every path is known to be made from its
/// file: one Activation record, for this cluster; manifests kix applies as
/// written; SOPS sources that a Secret names; and a package index that
/// agrees with the record.
fn check_build(
    contents: &Contents,
    sources: &BTreeSet<String>,
    closure: &BTreeSet<String>,
) -> Result<(), BundleError> {
    let mut records = 0;
    let mut sops_sources: BTreeSet<String> = BTreeSet::new();
    let mut instances: BTreeSet<(String, String)> = BTreeSet::new();
    // Plan and deploy each keep one manifest per object, and which one
    // depends on hash map order, so two copies could plan one and apply
    // the other.
    let mut objects: BTreeSet<ResourceId> = BTreeSet::new();
    for (path, file) in &contents.files {
        if !is_manifest(path) {
            continue;
        }
        let manifest: serde_json::Value =
            serde_json::from_slice(&file.bytes).map_err(|e| BundleError::NotJson {
                path: path.clone(),
                message: e.to_string(),
            })?;
        if has_retired_domain(&manifest) {
            return Err(BundleError::RetiredDomain(path.clone()));
        }
        if !canonical_api_version(&text_at(&manifest, "/apiVersion")) {
            return Err(BundleError::ApiVersion(path.clone()));
        }
        let id = ResourceId::from_value(&manifest);
        if !objects.insert(id.clone()) {
            return Err(BundleError::DuplicateObject(id.display_id()));
        }
        match manifest.pointer("/kind").and_then(|k| k.as_str()) {
            Some(kind) if kind == lifecycle::RECORD_KIND => {
                records += 1;
                if *path != contents.activation {
                    return Err(BundleError::Records(records));
                }
            }
            Some(kind) if kind == lifecycle::PACKAGE_INSTANCE_KIND => {
                instances.insert((
                    text_at(&manifest, "/metadata/namespace"),
                    text_at(&manifest, "/spec/instanceName"),
                ));
            }
            _ => {}
        }
        if let Some(source) = keys::get(&manifest, keys::SOPS_SOURCE) {
            sops_sources.insert(source.to_string());
        }
    }
    if records != 1 {
        return Err(BundleError::Records(records));
    }
    if let Some(stray) = sources.iter().find(|p| !sops_sources.contains(*p)) {
        return Err(BundleError::UnexpectedSource(stray.clone()));
    }

    let record: serde_json::Value =
        serde_json::from_slice(&contents.files[&contents.activation].bytes).map_err(|e| {
            BundleError::NotJson {
                path: contents.activation.clone(),
                message: e.to_string(),
            }
        })?;
    let labelled = record
        .pointer("/metadata/labels")
        .and_then(|l| l.get(keys::CLUSTER_LABEL))
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    if labelled != contents.cluster {
        return Err(BundleError::WrongCluster {
            bundle: contents.cluster.clone(),
            what: "Activation record",
            other: labelled.to_string(),
        });
    }

    let index = package_index(contents)?;
    if index.cluster != contents.cluster {
        return Err(BundleError::WrongCluster {
            bundle: contents.cluster.clone(),
            what: "kix-packages.json",
            other: index.cluster.clone(),
        });
    }
    for (pi, resources) in &index.packages {
        for p in std::iter::once(pi).chain(resources) {
            // The checks above cover the files named k8s-*, and the
            // graph reads every file the index lists as a manifest.
            if !store_name(p).starts_with("k8s-") {
                return Err(BundleError::IndexNotManifest(
                    p.to_string_lossy().into_owned(),
                ));
            }
            let p = p.to_string_lossy();
            if !closure.contains(p.as_ref()) {
                return Err(BundleError::IndexOutsideClosure(p.into_owned()));
            }
        }
    }
    if instances != record_instances(&record) {
        return Err(BundleError::IndexInstances);
    }
    Ok(())
}

fn package_index(contents: &Contents) -> Result<KixPackageIndex, BundleError> {
    serde_json::from_slice(&contents.files[&contents.index].bytes).map_err(|e| {
        BundleError::NotJson {
            path: contents.index.clone(),
            message: e.to_string(),
        }
    })
}

/// `root` and every store path it reaches through `references_of`.
fn closure_of<'a>(
    root: &'a str,
    references_of: impl Fn(&str) -> Option<&'a [String]>,
) -> BTreeSet<&'a str> {
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let mut queue: VecDeque<&str> = VecDeque::from([root]);
    while let Some(path) = queue.pop_front() {
        if !seen.insert(path) {
            continue;
        }
        if let Some(refs) = references_of(path) {
            queue.extend(refs.iter().map(String::as_str));
        }
    }
    seen
}

fn is_manifest(path: &str) -> bool {
    store_name(Path::new(path)).starts_with("k8s-")
}

fn unreadable(e: impl std::fmt::Display) -> BundleError {
    BundleError::Unreadable(e.to_string())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A reader that fails once more than `limit` bytes have come through it,
/// and records that in `exceeded`, since a tar or zstd error wrapping the
/// failure would not say why.
struct Limited<'a, R> {
    inner: R,
    left: u64,
    exceeded: &'a Cell<bool>,
}

impl<'a, R> Limited<'a, R> {
    fn new(inner: R, limit: u64, exceeded: &'a Cell<bool>) -> Self {
        Self {
            inner,
            left: limit,
            exceeded,
        }
    }
}

impl<R: Read> Read for Limited<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        // Ask for one byte more than is left, to tell "at the limit" from
        // "over it".
        let want = buf
            .len()
            .min(usize::try_from(self.left + 1).unwrap_or(usize::MAX));
        let n = self.inner.read(&mut buf[..want])?;
        if n as u64 > self.left {
            self.exceeded.set(true);
            return Err(io::Error::other("bundle too large"));
        }
        self.left -= n as u64;
        Ok(n)
    }
}

/// A reader that hashes every byte read through it.
struct Hashing<R> {
    inner: R,
    hasher: Sha256,
}

impl<R> Hashing<R> {
    fn new(inner: R) -> Self {
        Self {
            inner,
            hasher: Sha256::new(),
        }
    }
}

impl<R: Read> Read for Hashing<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
}

/// The contents of the build in `result_dir`, reading references from the
/// Nix store (`nix path-info`). Needs Nix; reading a bundle does not.
pub fn from_result_dir(
    result_dir: &Path,
    kix_rev: &str,
    receipt: Option<Provenance>,
) -> Result<Contents, KixEvalError> {
    let err = |message: String| KixEvalError::StoreGraphError { message };
    let resolve = |name: &str| {
        std::fs::canonicalize(result_dir.join(name)).map_err(|e| {
            err(format!(
                "failed to resolve {name} in {}: {e}",
                result_dir.display()
            ))
        })
    };
    let activation = resolve("activation")?;
    let index = resolve("kix-packages.json")?;
    let output = std::process::Command::new("nix")
        .args([
            "path-info",
            "--json",
            "--recursive",
            "--extra-experimental-features",
            "nix-command",
        ])
        .arg(&activation)
        .arg(&index)
        .output()
        .map_err(|e| err(format!("failed to run nix path-info: {e}")))?;
    if !output.status.success() {
        return Err(err(format!(
            "nix path-info failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    let info: serde_json::Value = serde_json::from_slice(&output.stdout).map_err(|e| {
        err(format!(
            "nix path-info printed something other than JSON: {e}"
        ))
    })?;
    let mut files = BTreeMap::new();
    for (path, references) in path_info_references(&info) {
        let bytes = std::fs::read(&path).map_err(|e| err(format!("failed to read {path}: {e}")))?;
        files.insert(path, BundleFile { bytes, references });
    }
    let index_json: KixPackageIndex =
        serde_json::from_slice(&files[&index.to_string_lossy().into_owned()].bytes)
            .map_err(|e| err(format!("failed to parse kix-packages.json: {e}")))?;
    Ok(Contents {
        kix_rev: kix_rev.to_string(),
        cluster: index_json.cluster,
        activation: activation.to_string_lossy().into_owned(),
        index: index.to_string_lossy().into_owned(),
        receipt,
        files,
    })
}

/// `(path, references)` from `nix path-info --json`, which is an object keyed
/// by path in Nix 2.19 and later and an array of `{path, references}` before.
fn path_info_references(info: &serde_json::Value) -> Vec<(String, Vec<String>)> {
    let refs = |v: &serde_json::Value| -> Vec<String> {
        v.get("references")
            .and_then(|r| r.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default()
    };
    match info {
        serde_json::Value::Object(map) => map.iter().map(|(p, v)| (p.clone(), refs(v))).collect(),
        serde_json::Value::Array(items) => items
            .iter()
            .filter_map(|v| Some((v.get("path")?.as_str()?.to_string(), refs(v))))
            .collect(),
        _ => Vec::new(),
    }
}

fn text_at(v: &serde_json::Value, pointer: &str) -> String {
    v.pointer(pointer)
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string()
}

/// `spec.instances` as `(namespace, instance)` pairs.
fn record_instances(record: &serde_json::Value) -> BTreeSet<(String, String)> {
    record
        .pointer("/spec/instances")
        .and_then(|v| v.as_object())
        .into_iter()
        .flat_map(|by_ns| {
            by_ns.iter().flat_map(|(ns, names)| {
                names
                    .as_object()
                    .into_iter()
                    .flat_map(move |m| m.keys().map(move |k| (ns.clone(), k.clone())))
            })
        })
        .collect()
}

/// Whether `api_version` is `version` or `group/version`, with no empty
/// part and no whitespace. The API server reads `/v1` as the core group's
/// `v1`, but Kix Enterprise's agent compares the string with discovery's
/// `v1` to decide what the build owns, and would miss it.
fn canonical_api_version(api_version: &str) -> bool {
    let part = |s: &str| !s.is_empty() && !s.contains(char::is_whitespace);
    match api_version.split_once('/') {
        None => part(api_version),
        Some((group, version)) => part(group) && part(version) && !version.contains('/'),
    }
}

/// Whether a manifest carries a label or annotation key, or an API group,
/// of a retired kix domain. `stamp_annotations` would upgrade those, so the
/// bundle's bytes would differ from what is applied.
fn has_retired_domain(manifest: &serde_json::Value) -> bool {
    let retired_key = |field: &str| {
        manifest
            .pointer(&format!("/metadata/{field}"))
            .and_then(|v| v.as_object())
            .is_some_and(|m| m.keys().any(|k| crate::legacy_domain::is_legacy_key(k)))
    };
    let retired_group = manifest
        .pointer("/apiVersion")
        .and_then(|v| v.as_str())
        .and_then(|v| v.split_once('/'))
        .is_some_and(|(group, _)| crate::legacy_domain::is_legacy_key(&format!("{group}/x")));
    retired_key("labels") || retired_key("annotations") || retired_group
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &[u8] =
        include_bytes!("../../tests/fixtures/bundles/kix-enterprise-test.kixbundle");

    /// The contents of a real `kix-enterprise-test` build on stage1: 26
    /// manifests and `kix-packages.json`.
    fn real() -> Contents {
        Bundle::read(FIXTURE).unwrap().into_contents()
    }

    fn written(contents: &Contents) -> Vec<u8> {
        let mut bytes = Vec::new();
        contents.write(&mut bytes).unwrap();
        bytes
    }

    /// Write `contents` as a bundle and read it back.
    fn reread(contents: &Contents) -> Result<Bundle, BundleError> {
        Bundle::read(written(contents).as_slice())
    }

    /// A tar file of `header` and `files`, uncompressed.
    fn tar_of(header: &Header, files: &BTreeMap<String, BundleFile>) -> Vec<u8> {
        let mut bytes = Vec::new();
        write_tar(header, files, &mut bytes).unwrap();
        bytes
    }

    /// A tar file with exactly these entries, in this order.
    fn raw_tar(entries: &[(&str, tar::EntryType, &[u8])]) -> Vec<u8> {
        let mut tar = tar::Builder::new(Vec::new());
        for (name, kind, bytes) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(*kind);
            header.set_mode(0o444);
            header.set_size(bytes.len() as u64);
            tar.append_data(&mut header, name, *bytes).unwrap();
        }
        tar.into_inner().unwrap()
    }

    fn header_json(contents: &Contents) -> Vec<u8> {
        serde_json::to_vec(&contents.header()).unwrap()
    }

    fn entry_name(path: &str) -> String {
        format!("{STORE_ENTRY_DIR}/{}", &path[STORE_DIR.len() + 1..])
    }

    fn path_ending(contents: &Contents, suffix: &str) -> String {
        contents
            .files
            .keys()
            .find(|p| p.ends_with(suffix))
            .unwrap()
            .clone()
    }

    #[test]
    fn a_real_build_verifies_and_loads() {
        let bundle = Bundle::read(FIXTURE).unwrap();
        assert_eq!(bundle.sha256(), hex(&Sha256::digest(FIXTURE)));
        let graph = bundle.graph().unwrap();
        assert_eq!(graph.cluster_name, "kix-enterprise-test");
        assert_eq!(
            graph.result_dir,
            PathBuf::from(format!("bundle:sha256:{}", bundle.sha256()))
        );
        assert_eq!(graph.packages.len(), 6);
        assert_eq!(graph.resources.len(), 26);
        let cross: usize = graph.packages.values().map(|p| p.cross_deps.len()).sum();
        assert!(cross > 0, "the shop reads the valkey in another package");
        assert_eq!(bundle.manifests().count(), 26);
    }

    #[test]
    fn writing_is_reproducible_and_round_trips() {
        let contents = real();
        let bytes = written(&contents);
        assert_eq!(bytes, written(&contents));
        assert_eq!(bytes, FIXTURE, "the fixture is what this kix writes");
        let back = Bundle::read(bytes.as_slice()).unwrap().into_contents();
        assert_eq!(back.files, contents.files);
        assert_eq!(back.header(), contents.header());
    }

    #[test]
    fn an_uncompressed_tar_reads_the_same() {
        let contents = real();
        let tar = tar_of(&contents.header(), &contents.files);
        let bundle = Bundle::read(tar.as_slice()).unwrap();
        assert_eq!(bundle.contents().files, contents.files);
        assert_eq!(bundle.sha256(), hex(&Sha256::digest(&tar)));
    }

    #[test]
    fn the_header_reads_alone() {
        let header = Bundle::read_header(FIXTURE).unwrap();
        assert_eq!(header, real().header());
    }

    #[test]
    fn a_json_bundle_is_refused() {
        assert!(matches!(
            Bundle::read(&br#"{"format":"kix-bundle","version":1}"#[..]),
            Err(BundleError::Unreadable(_))
        ));
    }

    #[test]
    fn a_long_store_name_round_trips() {
        let mut contents = real();
        let name = format!("k8s-ConfigMap-kix-enterprise-test-web-{}", "x".repeat(150));
        let text = r#"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"long","namespace":"kix-enterprise-test-web"}}"#;
        let path = add_to_build(&mut contents, &name, text, None);
        assert!(entry_name(&path).len() > 100);
        let bundle = reread(&contents).unwrap();
        assert_eq!(bundle.contents().files[&path].bytes, text.as_bytes());
    }

    #[test]
    fn a_bundle_over_the_limit_is_refused() {
        let bytes = written(&real());
        assert_eq!(
            read_limited(bytes.as_slice(), bytes.len() as u64 - 1).err(),
            Some(BundleError::TooLarge)
        );
        // Small when stored, over the limit once decompressed.
        let limit = bytes.len() as u64 + 1;
        assert!(limit < tar_of(&real().header(), &real().files).len() as u64);
        assert_eq!(
            read_limited(bytes.as_slice(), limit).err(),
            Some(BundleError::TooLarge)
        );
    }

    #[test]
    fn a_store_file_before_the_header_is_refused() {
        let contents = real();
        let (path, file) = contents.files.iter().next().unwrap();
        let tar = raw_tar(&[
            (&entry_name(path), tar::EntryType::Regular, &file.bytes),
            (
                HEADER_ENTRY,
                tar::EntryType::Regular,
                &header_json(&contents),
            ),
        ]);
        assert_eq!(
            Bundle::read(tar.as_slice()).err(),
            Some(BundleError::HeaderNotFirst)
        );
    }

    #[test]
    fn a_symlink_entry_is_refused() {
        let contents = real();
        let path = contents.files.keys().next().unwrap();
        let tar = raw_tar(&[
            (
                HEADER_ENTRY,
                tar::EntryType::Regular,
                &header_json(&contents),
            ),
            (&entry_name(path), tar::EntryType::Symlink, b""),
        ]);
        assert_eq!(
            Bundle::read(tar.as_slice()).err(),
            Some(BundleError::BadEntry(entry_name(path)))
        );
    }

    #[test]
    fn an_entry_outside_the_store_directory_is_refused() {
        let contents = real();
        let tar = raw_tar(&[
            (
                HEADER_ENTRY,
                tar::EntryType::Regular,
                &header_json(&contents),
            ),
            ("etc/passwd", tar::EntryType::Regular, b"x"),
        ]);
        assert_eq!(
            Bundle::read(tar.as_slice()).err(),
            Some(BundleError::BadEntry("etc/passwd".to_string()))
        );
    }

    #[test]
    fn an_entry_the_header_does_not_list_is_refused() {
        let contents = real();
        let unlisted = store_path::path_for(Method::Text, b"x", &[], "k8s-ConfigMap-unlisted");
        let tar = raw_tar(&[
            (
                HEADER_ENTRY,
                tar::EntryType::Regular,
                &header_json(&contents),
            ),
            (&entry_name(&unlisted), tar::EntryType::Regular, b"x"),
        ]);
        assert_eq!(
            Bundle::read(tar.as_slice()).err(),
            Some(BundleError::UnlistedEntry(entry_name(&unlisted)))
        );
    }

    #[test]
    fn a_repeated_entry_is_refused() {
        let contents = real();
        let (path, file) = contents.files.iter().next().unwrap();
        let tar = raw_tar(&[
            (
                HEADER_ENTRY,
                tar::EntryType::Regular,
                &header_json(&contents),
            ),
            (&entry_name(path), tar::EntryType::Regular, &file.bytes),
            (&entry_name(path), tar::EntryType::Regular, &file.bytes),
        ]);
        assert_eq!(
            Bundle::read(tar.as_slice()).err(),
            Some(BundleError::OutOfOrder(entry_name(path)))
        );
    }

    #[test]
    fn a_file_the_header_lists_but_the_bundle_lacks_is_refused() {
        let contents = real();
        let mut files = contents.files.clone();
        let path = contents.files.keys().last().unwrap().clone();
        files.remove(&path);
        let tar = tar_of(&contents.header(), &files);
        assert_eq!(
            Bundle::read(tar.as_slice()).err(),
            Some(BundleError::MissingFile(path))
        );
    }

    #[test]
    fn a_changed_byte_is_refused() {
        let mut contents = real();
        let p = path_ending(
            &contents,
            "-k8s-ConfigMap-kix-enterprise-test-web-status-page",
        );
        let file = contents.files.get_mut(&p).unwrap();
        file.bytes = String::from_utf8(file.bytes.clone())
            .unwrap()
            .replace("status", "statux")
            .into_bytes();
        assert_eq!(reread(&contents).err(), Some(BundleError::PathMismatch(p)));
    }

    #[test]
    fn a_dropped_reference_is_refused() {
        let mut contents = real();
        let p = path_ending(
            &contents,
            "-k8s-Deployment-kix-enterprise-test-web-status-page",
        );
        // The Namespace stays reachable through other manifests, so the
        // closure check passes and the path check refuses the Deployment.
        contents
            .files
            .get_mut(&p)
            .unwrap()
            .references
            .retain(|r| !r.contains("-k8s-Namespace-"));
        assert_eq!(reread(&contents).err(), Some(BundleError::PathMismatch(p)));
    }

    #[test]
    fn a_missing_reference_is_refused() {
        let mut contents = real();
        let p = path_ending(
            &contents,
            "-k8s-Namespace-_cluster_-kix-enterprise-test-web",
        );
        contents.files.remove(&p);
        assert!(matches!(
            reread(&contents),
            Err(BundleError::MissingReference { missing, .. }) if missing == p
        ));
    }

    #[test]
    fn a_file_outside_the_build_is_refused() {
        let mut contents = real();
        let text = r#"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"extra","namespace":"kix-enterprise-test-web"}}"#;
        let path = store_path::path_for(Method::Text, text.as_bytes(), &[], "k8s-ConfigMap-extra");
        contents.files.insert(
            path.clone(),
            BundleFile {
                bytes: text.as_bytes().to_vec(),
                references: vec![],
            },
        );
        assert_eq!(
            reread(&contents).err(),
            Some(BundleError::Unreachable(path))
        );
    }

    /// Add a file named `name` holding `text` to the build: the Activation
    /// record references it, and when `package` is given (the end of a
    /// PackageInstance path) kix-packages.json lists it under that package.
    /// Recomputes the paths that change. Returns the new file's path.
    fn add_to_build(
        contents: &mut Contents,
        name: &str,
        text: &str,
        package: Option<&str>,
    ) -> String {
        let path = store_path::path_for(Method::Text, text.as_bytes(), &[], name);
        contents.files.insert(
            path.clone(),
            BundleFile {
                bytes: text.as_bytes().to_vec(),
                references: vec![],
            },
        );
        let mut record = contents.files.remove(&contents.activation).unwrap();
        record.references.push(path.clone());
        let record_name = store_path::name_of(&contents.activation)
            .unwrap()
            .to_string();
        contents.activation = store_path::path_for(
            Method::Text,
            &record.bytes,
            &record.references,
            &record_name,
        );
        contents.files.insert(contents.activation.clone(), record);
        if let Some(package) = package {
            let mut index = package_index(contents).unwrap();
            let (_, resources) = index
                .packages
                .iter_mut()
                .find(|(pi, _)| pi.to_string_lossy().ends_with(package))
                .unwrap();
            resources.push(PathBuf::from(&path));
            let bytes = serde_json::to_vec(&index).unwrap();
            contents.files.remove(&contents.index);
            contents.index = store_path::path_for(Method::Text, &bytes, &[], "kix-packages.json");
            contents.files.insert(
                contents.index.clone(),
                BundleFile {
                    bytes,
                    references: vec![],
                },
            );
        }
        path
    }

    #[test]
    fn two_manifests_of_one_object_are_refused() {
        let mut contents = real();
        let configmap = |value: &str| {
            format!(
                r#"{{"apiVersion":"v1","kind":"ConfigMap","metadata":{{"name":"x","namespace":"kix-enterprise-test-web"}},"data":{{"k":"{value}"}}}}"#
            )
        };
        let package = Some("-k8s-PackageInstance-kix-enterprise-test-web-status-page");
        add_to_build(
            &mut contents,
            "k8s-ConfigMap-kix-enterprise-test-web-x",
            &configmap("harmless"),
            package,
        );
        add_to_build(
            &mut contents,
            "k8s-ConfigMap-kix-enterprise-test-web-x-copy",
            &configmap("harmful"),
            package,
        );
        assert_eq!(
            reread(&contents).err(),
            Some(BundleError::DuplicateObject(
                "ConfigMap/x@kix-enterprise-test-web".to_string()
            ))
        );
    }

    #[test]
    fn an_index_entry_not_named_as_a_manifest_is_refused() {
        let mut contents = real();
        let record = serde_json::json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {"name": "other", "labels": {(keys::CLUSTER_LABEL): "kix-enterprise-test"}},
        })
        .to_string();
        let path = add_to_build(
            &mut contents,
            "extra",
            &record,
            Some("-k8s-PackageInstance-kix-enterprise-test-web-status-page"),
        );
        assert_eq!(
            reread(&contents).err(),
            Some(BundleError::IndexNotManifest(path))
        );
    }

    #[test]
    fn an_api_version_with_an_empty_group_is_refused() {
        let mut contents = real();
        let text = r#"{"apiVersion":"/v1","kind":"ConfigMap","metadata":{"name":"x","namespace":"kix-enterprise-test-web"}}"#;
        let path = add_to_build(
            &mut contents,
            "k8s-ConfigMap-kix-enterprise-test-web-x",
            text,
            Some("-k8s-PackageInstance-kix-enterprise-test-web-status-page"),
        );
        assert_eq!(reread(&contents).err(), Some(BundleError::ApiVersion(path)));
    }

    #[test]
    fn api_version_spellings() {
        for good in ["v1", "apps/v1", "example.com/v1alpha1"] {
            assert!(canonical_api_version(good), "{good}");
        }
        for bad in ["", "/v1", "apps/", "a/b/v1", " v1", "v1 ", "apps /v1"] {
            assert!(!canonical_api_version(bad), "{bad:?}");
        }
    }

    #[test]
    fn a_bundle_for_another_cluster_is_refused() {
        let mut contents = real();
        contents.cluster = "stage1".to_string();
        assert!(matches!(
            reread(&contents),
            Err(BundleError::WrongCluster { .. })
        ));
    }

    #[test]
    fn a_misnamed_path_is_refused() {
        let mut contents = real();
        let p = path_ending(
            &contents,
            "-k8s-Namespace-_cluster_-kix-enterprise-test-web",
        );
        let file = contents.files.remove(&p).unwrap();
        let renamed = p.replace("-k8s-Namespace", "-k8s-Namespacx");
        contents.files.insert(renamed, file);
        assert!(reread(&contents).is_err());
    }

    #[test]
    fn another_format_version_is_refused() {
        let contents = real();
        let mut header = contents.header();
        header.version = 2;
        let tar = tar_of(&header, &contents.files);
        assert!(matches!(
            Bundle::read(tar.as_slice()),
            Err(BundleError::WrongFormat { version: 2, .. })
        ));
    }

    #[test]
    fn an_unknown_header_field_is_refused() {
        let contents = real();
        let mut header: serde_json::Value = serde_json::to_value(contents.header()).unwrap();
        header["extra"] = serde_json::json!(1);
        let tar = raw_tar(&[(
            HEADER_ENTRY,
            tar::EntryType::Regular,
            &serde_json::to_vec(&header).unwrap(),
        )]);
        assert!(matches!(
            Bundle::read(tar.as_slice()),
            Err(BundleError::Unreadable(_))
        ));
    }

    /// A tar file of `header`, given as JSON, and `contents`' files.
    fn tar_with_header(header: &serde_json::Value, contents: &Contents) -> Vec<u8> {
        let header = serde_json::to_vec(header).unwrap();
        let names: Vec<String> = contents.files.keys().map(|p| entry_name(p)).collect();
        let mut entries: Vec<(&str, tar::EntryType, &[u8])> =
            vec![(HEADER_ENTRY, tar::EntryType::Regular, &header)];
        for (name, file) in names.iter().zip(contents.files.values()) {
            entries.push((name, tar::EntryType::Regular, &file.bytes));
        }
        raw_tar(&entries)
    }

    /// The header of `contents` with `receipt` in place of its own.
    fn with_receipt(contents: &Contents, receipt: serde_json::Value) -> serde_json::Value {
        let mut header = serde_json::to_value(contents.header()).unwrap();
        header["receipt"] = receipt;
        header
    }

    /// A small compressed file can hold a huge header. Parsing it into
    /// `serde_json::Value`s takes many times its size in memory.
    #[test]
    fn a_header_over_its_cap_is_refused_before_it_is_parsed() {
        let contents = real();
        let big = "a".repeat(30 << 20);
        let header = with_receipt(&contents, serde_json::json!({"source": {"x": big}}));
        let compressed = zstd::encode_all(&tar_with_header(&header, &contents)[..], 19).unwrap();
        assert!(compressed.len() < 100 << 10, "{}", compressed.len());
        assert_eq!(
            Bundle::read(compressed.as_slice()).err(),
            Some(BundleError::HeaderTooLarge)
        );
    }

    #[test]
    fn a_receipt_over_its_cap_is_refused() {
        let contents = real();
        let big = "a".repeat(300 << 10);
        let header = with_receipt(&contents, serde_json::json!({"source": {"x": big}}));
        assert!(matches!(
            Bundle::read(tar_with_header(&header, &contents).as_slice()),
            Err(BundleError::Unreadable(m)) if m.contains("receipt")
        ));
    }

    /// `kix deploy` adds to the receipt's `source`, which must be an object.
    #[test]
    fn a_receipt_of_another_shape_is_refused() {
        let contents = real();
        for receipt in [
            serde_json::json!({"source": 1}),
            serde_json::json!({"inputs": {}}),
            serde_json::json!({"builder": []}),
            serde_json::json!({"other": {}}),
        ] {
            let header = with_receipt(&contents, receipt.clone());
            assert!(
                matches!(
                    Bundle::read(tar_with_header(&header, &contents).as_slice()),
                    Err(BundleError::Unreadable(_))
                ),
                "{receipt}"
            );
        }
    }

    /// Each reference is checked as a store path while the header is
    /// parsed, so short strings cannot stand in for paths.
    #[test]
    fn a_reference_that_is_not_a_store_path_is_refused_while_parsing() {
        let contents = real();
        let mut header = serde_json::to_value(contents.header()).unwrap();
        header["references"][&contents.activation]
            .as_array_mut()
            .unwrap()
            .push(serde_json::json!(""));
        assert!(matches!(
            Bundle::read(tar_with_header(&header, &contents).as_slice()),
            Err(BundleError::Unreadable(m)) if m.contains("store path")
        ));
    }

    /// The API server takes no request body over 3 MiB, so no manifest kix
    /// applies is larger.
    #[test]
    fn a_manifest_over_its_cap_is_refused() {
        let mut contents = real();
        let big = "a".repeat(3 << 20);
        let text = format!(
            r#"{{"apiVersion":"v1","kind":"ConfigMap","metadata":{{"name":"big","namespace":"kix-enterprise-test-web"}},"data":{{"k":"{big}"}}}}"#
        );
        let path = add_to_build(
            &mut contents,
            "k8s-ConfigMap-kix-enterprise-test-web-big",
            &text,
            Some("-k8s-PackageInstance-kix-enterprise-test-web-status-page"),
        );
        assert_eq!(
            reread(&contents).err(),
            Some(BundleError::ManifestTooLarge(path))
        );
    }

    /// Bytes after the archive are in the hash, so each must be checked.
    /// tar-rs stops at the first zero block and the zstd decoder reads
    /// every frame, so other readers could see more files than kix did.
    #[test]
    fn data_after_the_archive_is_refused() {
        let contents = real();
        let path = contents.files.keys().next().unwrap();
        let second_tar = raw_tar(&[(&entry_name(path), tar::EntryType::Regular, b"evil")]);
        let mut second_frame = written(&contents);
        second_frame.extend(zstd::encode_all(&second_tar[..], 3).unwrap());
        let mut skippable = written(&contents);
        skippable.extend([0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, b'e', b'v', b'i', b'l']);
        let mut plain = tar_of(&contents.header(), &contents.files);
        plain.extend(&second_tar);
        for (what, bytes) in [
            ("a second zstd frame", second_frame),
            ("a skippable frame", skippable),
            ("a second tar file", plain),
        ] {
            assert_eq!(
                Bundle::read(bytes.as_slice()).err(),
                Some(BundleError::TrailingData),
                "{what}"
            );
        }
    }

    #[test]
    fn zero_padding_after_a_plain_tar_reads() {
        let contents = real();
        let mut plain = tar_of(&contents.header(), &contents.files);
        plain.extend([0; 10240]);
        assert!(Bundle::read(plain.as_slice()).is_ok());
    }

    /// The header names store paths as UTF-8, so an entry's name must be
    /// UTF-8 too, or other readers would extract a file of another name.
    #[test]
    fn an_entry_name_that_is_not_utf8_is_refused() {
        let mut contents = real();
        let path = add_to_build(&mut contents, "a\u{FFFD}", "x", None);
        let mut tar = tar_of(&contents.header(), &contents.files);
        // The entry's own tar header, which starts with its name.
        let name = entry_name(&path).into_bytes();
        let block = (0..tar.len())
            .step_by(512)
            .find(|b| tar[*b..].starts_with(&name))
            .unwrap();
        let end = block + name.len();
        tar[end - 3..end].copy_from_slice(b"\xff\0\0");
        let mut header = tar::Header::new_old();
        header
            .as_mut_bytes()
            .copy_from_slice(&tar[block..block + 512]);
        header.set_cksum();
        tar[block..block + 512].copy_from_slice(header.as_bytes());
        let err = Bundle::read(tar.as_slice()).err();
        assert!(matches!(err, Some(BundleError::BadEntry(_))), "{err:?}");
    }

    #[test]
    fn path_info_in_either_shape() {
        let object = serde_json::json!({"/nix/store/a-x": {"references": ["/nix/store/b-y"]}});
        let array =
            serde_json::json!([{"path": "/nix/store/a-x", "references": ["/nix/store/b-y"]}]);
        let want = vec![(
            "/nix/store/a-x".to_string(),
            vec!["/nix/store/b-y".to_string()],
        )];
        assert_eq!(path_info_references(&object), want);
        assert_eq!(path_info_references(&array), want);
    }
}
