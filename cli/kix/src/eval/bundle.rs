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

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};

use serde::de::{DeserializeSeed, Error as _, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};
use zstd::zstd_safe;

use super::error::KixEvalError;
use super::store_graph::{KixPackageIndex, StoreGraph, store_name};
use super::store_path;
use crate::manifest::{keys, lifecycle};
use crate::text::printable;

/// The `format` field of every bundle header.
pub const FORMAT: &str = "kix-bundle";
/// The version this kix writes and reads. A reader refuses any other.
pub const VERSION: u32 = 3;
/// The file extension `kix bundle` suggests.
pub const EXTENSION: &str = "kixbundle";
/// The store name of the package index.
pub const INDEX_NAME: &str = "kix-packages.json";

/// The largest bundle file kix reads.
pub const MAX_STORED_BYTES: u64 = 64 * 1024 * 1024;
/// The largest header, decompressed. A header takes about 100 bytes a file.
pub const MAX_HEADER_BYTES: u64 = 32 * 1024 * 1024;
/// The most files a bundle may hold.
pub const MAX_FILES: usize = 200_000;
/// The most references the header may give over all its files. A build
/// gives about 3.5 a file.
pub const MAX_REFERENCES: usize = 8 * MAX_FILES;
/// The largest data frame, decompressed, and so the largest file. The
/// largest file is `kix-packages.json`, at about 130 bytes for each file it
/// lists: about 26 MB at [`MAX_FILES`].
pub const MAX_FRAME_BYTES: u64 = 32 * 1024 * 1024;
/// The most bytes the files may add up to, as the header lists them.
pub const MAX_CONTENT_BYTES: u64 = 1024 * 1024 * 1024;
/// The largest Activation record. A record lists the build's package
/// instances, about 2 KB for each Lithus cluster, and parses to about a
/// hundred times its size at worst.
pub const MAX_RECORD_BYTES: u64 = 256 * 1024;

/// The writer starts a new frame before a file that would take a frame past
/// this size. Larger frames compress better, since files of one kind repeat
/// each other.
const FRAME_FILL_BYTES: usize = 1024 * 1024;
const ZSTD_MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];
const SEEK_TABLE_MAGIC: u32 = 0x184D_2A5E;
const SEEKABLE_MAGIC: u32 = 0x8F92_EAB1;
/// The seek table's footer: the frame count (u32), the descriptor (u8),
/// and [`SEEKABLE_MAGIC`].
const FOOTER_BYTES: usize = 9;

/// Frame 0 of a bundle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Header {
    /// Always [`FORMAT`].
    pub format: String,
    /// Always [`VERSION`].
    pub version: u32,
    /// The kix revision that wrote the bundle, for the record.
    pub kix_rev: String,
    /// Every file, in stream order: by store name, then by path.
    pub files: Vec<FileEntry>,
    /// The bundle maker's account of the build's source, which only the
    /// deploy receipt shows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Provenance>,
}

/// One file of the [`Header`], written `[path, size, references]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "(String, u64, Vec<u32>)", into = "(String, u64, Vec<u32>)")]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    /// The files it references, as Nix records them, each by its index in
    /// [`Header::files`]. A file may reference itself.
    pub references: Vec<u32>,
}

impl From<(String, u64, Vec<u32>)> for FileEntry {
    fn from((path, size, references): (String, u64, Vec<u32>)) -> Self {
        Self {
            path,
            size,
            references,
        }
    }
}

impl From<FileEntry> for (String, u64, Vec<u32>) {
    fn from(f: FileEntry) -> Self {
        (f.path, f.size, f.references)
    }
}

impl Header {
    /// The index of `path` in [`Header::files`].
    pub fn position(&self, path: &str) -> Option<usize> {
        self.files
            .binary_search_by(|f| stream_order(&f.path, path))
            .ok()
    }

    fn references_of(&self, i: usize) -> Vec<&str> {
        let refs = &self.files[i].references;
        refs.iter()
            .map(|r| self.files[*r as usize].path.as_str())
            .collect()
    }
}

/// By store name, then by path, so files of one kind sit together and
/// compress against each other.
fn stream_order(a: &str, b: &str) -> Ordering {
    let name_a = store_path::name_of(a).unwrap_or_default();
    let name_b = store_path::name_of(b).unwrap_or_default();
    name_a.cmp(name_b).then_with(|| a.cmp(b))
}

/// What the machine that wrote a bundle recorded about the build's source:
/// the deploy receipt's `source`, `inputs` and `builder`.
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

/// What a file is to its bundle, decided from the header's references.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The Activation record: the one file no other file references.
    Record,
    /// `kix-packages.json`: the record's one direct reference of that name.
    Index,
    /// Any other file named `k8s-*`.
    Manifest,
    /// Any other file: a SOPS source, or a marker such as
    /// `kix-untracked-ref`. Carried and not parsed.
    Other,
}

/// Why a bundle was refused. Its strings may hold the uploader's text, and
/// each message shows them through [`printable`].
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum BundleError {
    #[error("the bundle cannot be read: {}", printable(.0))]
    Unreadable(String),
    #[error(
        "the bundle is a format 1 bundle, a tar file; this kix reads '{FORMAT}' version {VERSION}"
    )]
    Format1,
    #[error(
        "the bundle's format is '{}' version {version}; this kix reads '{FORMAT}' version {VERSION}",
        printable(.format)
    )]
    WrongFormat { format: String, version: u32 },
    #[error("the bundle is too large: {}", printable(.0))]
    TooLarge(String),
    #[error("the bundle is malformed: {}", printable(.0))]
    Malformed(String),
    #[error(
        "{} was not made from the bytes and references the bundle gives it",
        printable(.0)
    )]
    PathMismatch(String),
    #[error("{} is not in the bundle", printable(.0))]
    NotInBundle(String),
    #[error(
        "the bundle must hold one file that no other file references, its Activation record; it holds {0}"
    )]
    Roots(usize),
    #[error(
        "{} is the file no other file references, so it must be the Activation record: a manifest named k8s-* of kind Activation in the {} group",
        printable(.0),
        keys::GROUP
    )]
    NotARecord(String),
    #[error(
        "the Activation record {} does not reference one {INDEX_NAME}, so its name does not cover the whole build. A kixpkgs lib older than this kix builds records like that: update the flake's kixpkgs input and build again",
        printable(.0)
    )]
    NoIndex(String),
    #[error(
        "{} is not in the Activation record's closure, so it is not part of the build",
        printable(.0)
    )]
    Unreachable(String),
    #[error("{} is not a JSON manifest: {}", printable(.path), printable(.message))]
    NotJson { path: String, message: String },
    /// [`StoreGraph::assemble`] or [`StoreGraph::validate`] refused the
    /// build. Their messages are escaped already.
    #[error("{0}")]
    Build(String),
}

impl Contents {
    /// The header [`Contents::write`] puts in frame 0. Fails when a path is
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

    /// Write the bundle. The same contents give the same bytes from the
    /// same kix and libzstd: the order is fixed, and zstd runs on one
    /// thread at its default level. Fails on a file over
    /// [`MAX_FRAME_BYTES`], naming it.
    pub fn write(&self, mut out: impl Write) -> io::Result<()> {
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
        let mut compressor = zstd::bulk::Compressor::new(zstd::DEFAULT_COMPRESSION_LEVEL)?;
        compressor.include_checksum(false)?;
        compressor.include_contentsize(true)?;
        compressor.include_dictid(false)?;
        let mut table: Vec<(u32, u32)> = Vec::new();
        let mut put = |data: &[u8], out: &mut dyn Write| -> io::Result<()> {
            let stored = compressor.compress(data)?;
            let size =
                |n: usize| u32::try_from(n).map_err(|_| io::Error::other("a frame is over 4 GiB"));
            table.push((size(stored.len())?, size(data.len())?));
            out.write_all(&stored)
        };
        put(&serde_json::to_vec(&header)?, &mut out)?;
        let mut frame: Vec<u8> = Vec::new();
        for entry in &header.files {
            let bytes = &self.files[&entry.path].bytes;
            if !frame.is_empty() && frame.len() + bytes.len() > FRAME_FILL_BYTES {
                put(&frame, &mut out)?;
                frame.clear();
            }
            frame.extend_from_slice(bytes);
        }
        if !frame.is_empty() {
            put(&frame, &mut out)?;
        }
        out.write_all(&seek_table(&table))?;
        out.flush()
    }
}

/// The seek table of frames of these `(compressed, decompressed)` sizes, as
/// a skippable frame, with no checksums.
fn seek_table(frames: &[(u32, u32)]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + 8 * frames.len() + FOOTER_BYTES);
    out.extend(SEEK_TABLE_MAGIC.to_le_bytes());
    out.extend(((8 * frames.len() + FOOTER_BYTES) as u32).to_le_bytes());
    for (stored, size) in frames {
        out.extend(stored.to_le_bytes());
        out.extend(size.to_le_bytes());
    }
    out.extend((frames.len() as u32).to_le_bytes());
    out.push(0);
    out.extend(SEEKABLE_MAGIC.to_le_bytes());
    out
}

/// A bundle whose seek table and header have been read and checked, and
/// whose roles are known. Each file read through it is checked against its
/// store path.
#[derive(Debug)]
pub struct OpenBundle<R> {
    input: R,
    header: Header,
    roles: Roles,
    /// The data frames: frame 1 of the file first.
    frames: Vec<Frame>,
    /// Where each file of [`Header::files`] lies.
    places: Vec<Place>,
    /// The data frame decompressed last, by its index in `frames`.
    cached: (usize, Vec<u8>),
}

#[derive(Debug, Clone, Copy)]
struct Frame {
    /// Its first byte's offset in the file.
    offset: u64,
    /// Its length in the file.
    stored: usize,
    /// Its length decompressed.
    size: usize,
}

/// Data frame `frame` holds a file's bytes from byte `offset`.
#[derive(Debug, Clone, Copy)]
struct Place {
    frame: usize,
    offset: usize,
}

/// Each file's [`Role`], by index in [`Header::files`], and the indices of
/// the record and the index.
#[derive(Debug)]
struct Roles {
    of: Vec<Role>,
    record: usize,
    index: usize,
}

impl<R: Read + Seek> OpenBundle<R> {
    /// Read the seek table and the header, and derive each file's role.
    /// Reads no file.
    pub fn open(mut input: R) -> Result<Self, BundleError> {
        let table = read_table(&mut input)?;
        input.seek(SeekFrom::Start(0)).map_err(unreadable)?;
        let (header, places, roles) = read_start(&mut input, &table.frames)?;
        Ok(Self::new(input, header, roles, table.frames, places))
    }

    /// The bytes of the file at `path`, checked against its store path.
    pub fn file(&mut self, path: &str) -> Result<Vec<u8>, BundleError> {
        let i = self
            .header
            .position(path)
            .ok_or_else(|| BundleError::NotInBundle(path.to_string()))?;
        self.file_at(i)
    }

    /// Every file, with the header's fields: the whole build in memory.
    pub fn contents(&mut self) -> Result<Contents, BundleError> {
        let mut files = BTreeMap::new();
        for i in 0..self.header.files.len() {
            let bytes = self.file_at(i)?;
            let references = self.header.references_of(i);
            files.insert(
                self.header.files[i].path.clone(),
                BundleFile {
                    bytes,
                    references: references.into_iter().map(str::to_string).collect(),
                },
            );
        }
        Ok(Contents {
            kix_rev: self.header.kix_rev.clone(),
            receipt: self.header.receipt.clone(),
            files,
        })
    }

    /// The files of [`Role::Other`], by store path: the SOPS sources a
    /// Secret may name are among them.
    pub fn other_files(&mut self) -> Result<HashMap<String, Vec<u8>>, BundleError> {
        let others: Vec<usize> = (0..self.header.files.len())
            .filter(|i| self.roles.of[*i] == Role::Other)
            .collect();
        others
            .into_iter()
            .map(|i| Ok((self.header.files[i].path.clone(), self.file_at(i)?)))
            .collect()
    }

    fn file_at(&mut self, i: usize) -> Result<Vec<u8>, BundleError> {
        let size = self.header.files[i].size as usize;
        let Place { frame, offset } = self.places[i];
        if size > 0 && self.cached.0 != frame {
            let f = self.frames[frame];
            self.input
                .seek(SeekFrom::Start(f.offset))
                .map_err(unreadable)?;
            self.cached = (frame, read_frame(&mut self.input, frame + 1, &f)?);
        }
        let bytes = match size {
            0 => Vec::new(),
            _ => self.cached.1[offset..offset + size].to_vec(),
        };
        check_path(&self.header, i, &bytes)?;
        Ok(bytes)
    }
}

impl<R> OpenBundle<R> {
    fn new(input: R, header: Header, roles: Roles, frames: Vec<Frame>, places: Vec<Place>) -> Self {
        Self {
            input,
            header,
            roles,
            frames: frames[1..].to_vec(),
            places,
            cached: (usize::MAX, Vec::new()),
        }
    }

    pub fn header(&self) -> &Header {
        &self.header
    }

    /// The store path of the Activation record.
    pub fn record(&self) -> &str {
        &self.header.files[self.roles.record].path
    }

    /// The store path of `kix-packages.json`.
    pub fn index(&self) -> &str {
        &self.header.files[self.roles.index].path
    }

    /// The role of the file at `path`, or `None` when the bundle does not
    /// hold `path`.
    pub fn role(&self, path: &str) -> Option<Role> {
        Some(self.roles.of[self.header.position(path)?])
    }
}

/// A bundle whose every store path, role, and closure has been checked,
/// and of whose files only the record has been parsed: what a server that
/// stores bundles and never plans them needs.
#[derive(Debug)]
pub struct PathsChecked<R> {
    open: OpenBundle<R>,
    cluster: String,
    sha256: String,
}

impl<R: Read + Seek> PathsChecked<R> {
    /// Read a bundle once, in order: see the module doc for what it checks
    /// and holds.
    pub fn read(input: R) -> Result<Self, BundleError> {
        read_checked(input, |_, _, _| Ok(()))
    }
}

impl<R> PathsChecked<R> {
    /// The record's `kix.run/cluster` label.
    pub fn cluster(&self) -> &str {
        &self.cluster
    }

    /// The SHA-256 of the bundle's bytes, lowercase hex: what `built-via`,
    /// the deploy receipt, and a Kix Enterprise statement name it by.
    pub fn sha256(&self) -> &str {
        &self.sha256
    }
}

impl<R> Deref for PathsChecked<R> {
    type Target = OpenBundle<R>;
    fn deref(&self) -> &OpenBundle<R> {
        &self.open
    }
}

impl<R> DerefMut for PathsChecked<R> {
    fn deref_mut(&mut self) -> &mut OpenBundle<R> {
        &mut self.open
    }
}

/// A bundle read in full: its paths checked, and its build valid.
#[derive(Debug)]
pub struct Bundle<R>(PathsChecked<R>);

impl<R: Read + Seek> Bundle<R> {
    /// Read a bundle once, in order, and give it with its build, whose
    /// `result_dir` is `bundle:sha256:<sha256>`. See the module doc for
    /// what it checks.
    pub fn read(input: R) -> Result<(Self, StoreGraph), BundleError> {
        let mut manifests = HashMap::new();
        let mut index = None;
        let checked = read_checked(input, |path, role, bytes| {
            match role {
                Role::Record | Role::Manifest => {
                    manifests.insert(PathBuf::from(path), parse_manifest(path, bytes)?);
                }
                Role::Index => index = Some(parse_index(path, bytes)?),
                Role::Other => {}
            }
            Ok(())
        })?;
        let Some(index) = index else {
            unreachable!("read_checked passes every file, and every bundle has an index");
        };
        let mut read = |path: &Path| {
            manifests
                .remove(path)
                .ok_or_else(|| KixEvalError::StoreGraphError {
                    message: format!(
                        "{} is not a manifest in the bundle",
                        printable(&path.to_string_lossy())
                    ),
                })
        };
        let graph = StoreGraph::assemble(
            index,
            PathBuf::from(checked.record()),
            PathBuf::from(format!("bundle:sha256:{}", checked.sha256)),
            ref_cache_of(&checked.header),
            &mut read,
            &|_| {},
        )
        .and_then(|graph| graph.validate().map(|()| graph))
        .map_err(|e| BundleError::Build(e.to_string()))?;
        Ok((Bundle(checked), graph))
    }
}

impl<R> Deref for Bundle<R> {
    type Target = PathsChecked<R>;
    fn deref(&self) -> &PathsChecked<R> {
        &self.0
    }
}

impl<R> DerefMut for Bundle<R> {
    fn deref_mut(&mut self) -> &mut PathsChecked<R> {
        &mut self.0
    }
}

/// Read every byte of `input` once, in order, and hash them. Check each
/// file's store path as its frame arrives, parse the record, and pass each
/// file to `each` with its role.
fn read_checked<R: Read + Seek>(
    mut input: R,
    mut each: impl FnMut(&str, Role, &[u8]) -> Result<(), BundleError>,
) -> Result<PathsChecked<R>, BundleError> {
    let table = read_table(&mut input)?;
    input.seek(SeekFrom::Start(0)).map_err(unreadable)?;
    let mut stream = Hashing {
        inner: &mut input,
        hasher: Sha256::new(),
    };
    let (header, places, roles) = read_start(&mut stream, &table.frames)?;
    let mut cluster = String::new();
    let mut frame: (usize, Vec<u8>) = (usize::MAX, Vec::new());
    for (i, file) in header.files.iter().enumerate() {
        let Place { frame: k, offset } = places[i];
        let size = file.size as usize;
        // `place_files` puts every frame's bytes in some file, so each
        // frame is read once and in order.
        if size > 0 && frame.0 != k {
            frame = (k, read_frame(&mut stream, k + 1, &table.frames[k + 1])?);
        }
        let bytes = match size {
            0 => &[][..],
            _ => &frame.1[offset..offset + size],
        };
        check_path(&header, i, bytes)?;
        if roles.of[i] == Role::Record {
            cluster = record_cluster(&file.path, bytes)?;
        }
        each(&file.path, roles.of[i], bytes)?;
    }
    let mut rest = Vec::new();
    (&mut stream)
        .take(table.bytes.len() as u64 + 1)
        .read_to_end(&mut rest)
        .map_err(unreadable)?;
    if rest != table.bytes {
        return Err(BundleError::Unreadable(
            "the file changed while it was read".to_string(),
        ));
    }
    let sha256 = hex(&stream.hasher.finalize());
    Ok(PathsChecked {
        open: OpenBundle::new(input, header, roles, table.frames, places),
        cluster,
        sha256,
    })
}

/// The seek table: every frame, frame 0 first, and the table's own bytes.
struct SeekTable {
    frames: Vec<Frame>,
    bytes: Vec<u8>,
}

/// Read the seek table at the end of `input`, and check that its frames
/// cover every byte before it and are within the caps.
fn read_table(input: &mut (impl Read + Seek)) -> Result<SeekTable, BundleError> {
    let len = input.seek(SeekFrom::End(0)).map_err(unreadable)?;
    if len > MAX_STORED_BYTES {
        return Err(too_large(format!(
            "the file is over {MAX_STORED_BYTES} bytes"
        )));
    }
    let mut footer = [0u8; FOOTER_BYTES];
    if len >= FOOTER_BYTES as u64 {
        input
            .seek(SeekFrom::End(-(FOOTER_BYTES as i64)))
            .map_err(unreadable)?;
        input.read_exact(&mut footer).map_err(unreadable)?;
    }
    if u32_at(&footer, 5) != SEEKABLE_MAGIC {
        return Err(match is_format_1(input) {
            true => BundleError::Format1,
            false => malformed("it does not end with a zstd seek table"),
        });
    }
    let count = u32_at(&footer, 0) as usize;
    if footer[4] != 0 || count == 0 || count > MAX_FILES + 1 {
        return Err(malformed(format!(
            "its seek table lists {count} frames with descriptor {:#04x}",
            footer[4]
        )));
    }
    let table_len = 8 + 8 * count + FOOTER_BYTES;
    let Some(start) = len.checked_sub(table_len as u64) else {
        return Err(malformed("its seek table is longer than the file"));
    };
    input.seek(SeekFrom::Start(start)).map_err(unreadable)?;
    let mut bytes = vec![0u8; table_len];
    input.read_exact(&mut bytes).map_err(unreadable)?;
    if u32_at(&bytes, 0) != SEEK_TABLE_MAGIC || u32_at(&bytes, 4) as usize != table_len - 8 {
        return Err(malformed("its seek table's frame header is wrong"));
    }
    let mut frames = Vec::with_capacity(count);
    let mut offset = 0u64;
    for i in 0..count {
        let stored = u32_at(&bytes, 8 + 8 * i) as usize;
        let size = u32_at(&bytes, 12 + 8 * i) as usize;
        let cap = if i == 0 {
            MAX_HEADER_BYTES
        } else {
            MAX_FRAME_BYTES
        };
        if size as u64 > cap {
            return Err(too_large(format!("frame {i} is over {cap} bytes")));
        }
        if size == 0 || stored > zstd_safe::compress_bound(size) {
            return Err(malformed(format!(
                "its seek table gives frame {i} {stored} bytes for {size}"
            )));
        }
        frames.push(Frame {
            offset,
            stored,
            size,
        });
        offset += stored as u64;
    }
    if offset != start {
        return Err(malformed(format!(
            "its frames take {offset} bytes, but its seek table starts at byte {start}"
        )));
    }
    Ok(SeekTable { frames, bytes })
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

/// Whether `input` is a format 1 bundle: a tar file, compressed with zstd
/// or not, whose first entry is `kix-bundle.json`.
fn is_format_1(input: &mut (impl Read + Seek)) -> bool {
    const FIRST_NAME: &[u8; 16] = b"kix-bundle.json\0";
    let start = (|| -> io::Result<[u8; 16]> {
        input.seek(SeekFrom::Start(0))?;
        let mut start = [0u8; 16];
        input.read_exact(&mut start[..4])?;
        if start[..4] == ZSTD_MAGIC {
            let stored = io::Cursor::new(ZSTD_MAGIC).chain(&mut *input);
            let mut decoder = zstd::stream::read::Decoder::new(stored)?;
            // Format 1 was written at level 3, whose window is at most 2^21
            // bytes; a larger window would only cost memory.
            decoder.window_log_max(23)?;
            decoder.read_exact(&mut start)?;
        } else {
            input.read_exact(&mut start[4..])?;
        }
        Ok(start)
    })();
    start.is_ok_and(|s| &s == FIRST_NAME)
}

/// Read frame 0 from `input`'s position, parse the header, place each file
/// in a data frame, and derive the roles.
fn read_start(
    input: &mut impl Read,
    frames: &[Frame],
) -> Result<(Header, Vec<Place>, Roles), BundleError> {
    let header = parse_header(&read_frame(input, 0, &frames[0])?)?;
    let places = place_files(&header, &frames[1..])?;
    let roles = roles_of(&header.files)?;
    Ok((header, places, roles))
}

/// Read frame `number` of the file from `input`'s position and decompress
/// it to the size the seek table gives.
fn read_frame(input: &mut impl Read, number: usize, frame: &Frame) -> Result<Vec<u8>, BundleError> {
    let mut stored = vec![0u8; frame.stored];
    input.read_exact(&mut stored).map_err(unreadable)?;
    let bytes = zstd::bulk::Decompressor::new()
        .and_then(|mut d| d.decompress(&stored, frame.size))
        .map_err(|e| malformed(format!("frame {number} does not decompress: {e}")))?;
    if bytes.len() != frame.size {
        return Err(malformed(format!(
            "frame {number} decompresses to {} bytes, not {}",
            bytes.len(),
            frame.size
        )));
    }
    Ok(bytes)
}

/// Parse frame 0. The format and version are read first, so a bundle of
/// another version is refused as such whatever else its header holds.
fn parse_header(bytes: &[u8]) -> Result<Header, BundleError> {
    #[derive(Deserialize)]
    struct Version {
        format: String,
        version: u32,
    }
    let unreadable = |e: serde_json::Error| BundleError::Unreadable(format!("the header: {e}"));
    let Version { format, version } = serde_json::from_slice(bytes).map_err(unreadable)?;
    if format != FORMAT || version != VERSION {
        return Err(BundleError::WrongFormat { format, version });
    }
    let header: Header = serde_json::from_slice(bytes).map_err(unreadable)?;
    let files = &header.files;
    if files.len() > MAX_FILES {
        return Err(too_large(format!(
            "the header lists more than {MAX_FILES} files"
        )));
    }
    if files.iter().map(|f| f.references.len()).sum::<usize>() > MAX_REFERENCES {
        return Err(too_large(format!(
            "the header gives more than {MAX_REFERENCES} references"
        )));
    }
    if files.iter().map(|f| f.size).fold(0, u64::saturating_add) > MAX_CONTENT_BYTES {
        return Err(too_large(format!(
            "the files add up to more than {MAX_CONTENT_BYTES} bytes"
        )));
    }
    for (i, file) in files.iter().enumerate() {
        if store_path::name_of(&file.path).is_none() {
            return Err(malformed(format!("'{}' is not a store path", file.path)));
        }
        if i > 0 && stream_order(&files[i - 1].path, &file.path) != Ordering::Less {
            return Err(malformed(format!(
                "the header lists {} out of order or twice",
                file.path
            )));
        }
        if let Some(r) = file.references.iter().find(|r| **r as usize >= files.len()) {
            return Err(malformed(format!(
                "{} references file {r}, which the header does not list",
                file.path
            )));
        }
    }
    Ok(header)
}

/// Place each file in the data frame that holds it. The frames must hold
/// exactly the bytes the header lists, each file in one frame. An empty
/// file goes in the frame the file before it ends in.
fn place_files(header: &Header, frames: &[Frame]) -> Result<Vec<Place>, BundleError> {
    let in_frames: u64 = frames.iter().map(|f| f.size as u64).sum();
    let listed: u64 = header.files.iter().map(|f| f.size).sum();
    if in_frames != listed {
        return Err(malformed(format!(
            "its frames hold {in_frames} bytes, but its header lists {listed}"
        )));
    }
    let mut places = Vec::with_capacity(header.files.len());
    let (mut frame, mut filled) = (0, 0);
    for file in &header.files {
        let size = file.size as usize;
        if size > 0 && filled == frames[frame].size {
            frame += 1;
            filled = 0;
        }
        if size > 0 && filled + size > frames[frame].size {
            return Err(malformed(format!(
                "{} runs past the end of its frame",
                file.path
            )));
        }
        places.push(Place {
            frame,
            offset: filled,
        });
        filled += size;
    }
    Ok(places)
}

/// Derive each file's role from the references: see the module doc.
fn roles_of(files: &[FileEntry]) -> Result<Roles, BundleError> {
    let mut referenced = vec![false; files.len()];
    for (i, file) in files.iter().enumerate() {
        for r in file.references.iter().map(|r| *r as usize) {
            referenced[r] |= r != i;
        }
    }
    let roots: Vec<usize> = (0..files.len()).filter(|i| !referenced[*i]).collect();
    let [record] = roots[..] else {
        return Err(BundleError::Roots(roots.len()));
    };
    let path = &files[record].path;
    if !is_manifest(path) {
        return Err(BundleError::NotARecord(path.clone()));
    }
    if files[record].size > MAX_RECORD_BYTES {
        return Err(too_large(format!(
            "the Activation record {path} is over {MAX_RECORD_BYTES} bytes"
        )));
    }
    let indexes: Vec<usize> = files[record]
        .references
        .iter()
        .map(|r| *r as usize)
        .filter(|r| store_path::name_of(&files[*r].path) == Some(INDEX_NAME))
        .collect();
    let [index] = indexes[..] else {
        return Err(BundleError::NoIndex(path.clone()));
    };
    let mut reached = vec![false; files.len()];
    let mut queue = vec![record];
    while let Some(i) = queue.pop() {
        if !std::mem::replace(&mut reached[i], true) {
            queue.extend(files[i].references.iter().map(|r| *r as usize));
        }
    }
    if let Some(stray) = reached.iter().position(|r| !r) {
        return Err(BundleError::Unreachable(files[stray].path.clone()));
    }
    let of = (0..files.len())
        .map(|i| match i {
            _ if i == record => Role::Record,
            _ if i == index => Role::Index,
            _ if is_manifest(&files[i].path) => Role::Manifest,
            _ => Role::Other,
        })
        .collect();
    Ok(Roles { of, record, index })
}

fn is_manifest(path: &str) -> bool {
    store_path::name_of(path).is_some_and(|name| name.starts_with("k8s-"))
}

/// Refuse file `i` unless its store path is made from `bytes` and its
/// references.
fn check_path(header: &Header, i: usize, bytes: &[u8]) -> Result<(), BundleError> {
    let path = &header.files[i].path;
    match store_path::method_of(path, bytes, &header.references_of(i)) {
        Some(_) => Ok(()),
        None => Err(BundleError::PathMismatch(path.clone())),
    }
}

/// The cluster the record at `path` names in its `kix.run/cluster` label,
/// or empty when it names none. Refuses a record that is not an Activation
/// in the `kix.run` group.
fn record_cluster(path: &str, bytes: &[u8]) -> Result<String, BundleError> {
    let record = parse_manifest(path, bytes)?;
    let group = record["apiVersion"]
        .as_str()
        .and_then(|v| v.split_once('/'))
        .map(|(group, _)| group);
    if record["kind"] != lifecycle::RECORD_KIND || group != Some(keys::GROUP) {
        return Err(BundleError::NotARecord(path.to_string()));
    }
    Ok(keys::label(&record, keys::CLUSTER_LABEL)
        .unwrap_or_default()
        .to_string())
}

/// The references of each file, by path, as [`StoreGraph`] holds a
/// result directory's: no file's own path among them, sorted by store name
/// in lower case, and no entry for a file with none.
fn ref_cache_of(header: &Header) -> HashMap<PathBuf, Vec<PathBuf>> {
    let mut ref_cache = HashMap::new();
    for (i, file) in header.files.iter().enumerate() {
        let mut refs: Vec<PathBuf> = header
            .references_of(i)
            .into_iter()
            .filter(|r| *r != file.path)
            .map(PathBuf::from)
            .collect();
        if !refs.is_empty() {
            refs.sort_by_cached_key(|r| store_name(r).to_lowercase());
            ref_cache.insert(PathBuf::from(&file.path), refs);
        }
    }
    ref_cache
}

/// `bytes`, the manifest at `path`, parsed as JSON: the one parser for
/// manifests and indexes. Refuses a key given twice and a key with
/// serde_json's reserved prefix; serde_json refuses nesting past 128. An
/// integer outside `i64` and `u64` reads as the nearest `f64`.
pub fn parse_manifest(path: &str, bytes: &[u8]) -> Result<serde_json::Value, BundleError> {
    let mut de = serde_json::Deserializer::from_slice(bytes);
    Strict
        .deserialize(&mut de)
        .and_then(|v| de.end().map(|()| v))
        .map_err(|e| BundleError::NotJson {
            path: path.to_string(),
            message: e.to_string(),
        })
}

/// `kix-packages.json` at `path`, parsed with [`parse_manifest`].
pub fn parse_index(path: &str, bytes: &[u8]) -> Result<KixPackageIndex, BundleError> {
    serde_json::from_value(parse_manifest(path, bytes)?).map_err(|e| BundleError::NotJson {
        path: path.to_string(),
        message: e.to_string(),
    })
}

/// The prefix of the keys serde_json reserves for its own types. With the
/// `raw_value` feature, `serde_json::Value` reads an object whose one key is
/// `$serde_json::private::RawValue` as the JSON text its value holds.
const SERDE_JSON_PRIVATE: &str = "$serde_json::private::";

/// A JSON value parsed by [`parse_manifest`]'s rules.
struct Strict;

impl<'de> DeserializeSeed<'de> for Strict {
    type Value = serde_json::Value;
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error> {
        d.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Strict {
    type Value = serde_json::Value;
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a JSON value")
    }
    fn visit_bool<E>(self, v: bool) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_f64<E>(self, v: f64) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_str<E>(self, v: &str) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_string<E>(self, v: String) -> Result<Self::Value, E> {
        Ok(v.into())
    }
    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(serde_json::Value::Null)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        let mut out = Vec::new();
        while let Some(v) = seq.next_element_seed(Strict)? {
            out.push(v);
        }
        Ok(out.into())
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut out = serde_json::Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if key.starts_with(SERDE_JSON_PRIVATE) {
                return Err(A::Error::custom(format!(
                    "the key '{key}' is reserved by serde_json"
                )));
            }
            if out.contains_key(&key) {
                return Err(A::Error::custom(format!("the key '{key}' is given twice")));
            }
            let value = map.next_value_seed(Strict)?;
            out.insert(key, value);
        }
        Ok(out.into())
    }
}

fn unreadable(e: impl std::fmt::Display) -> BundleError {
    BundleError::Unreadable(e.to_string())
}

fn malformed(message: impl Into<String>) -> BundleError {
    BundleError::Malformed(message.into())
}

fn too_large(message: String) -> BundleError {
    BundleError::TooLarge(message)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A reader that hashes every byte read through it.
struct Hashing<R> {
    inner: R,
    hasher: Sha256,
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
    let activation = std::fs::canonicalize(result_dir.join("activation")).map_err(|e| {
        err(format!(
            "failed to resolve activation in {}: {e}",
            result_dir.display()
        ))
    })?;
    let output = std::process::Command::new("nix")
        .args([
            "path-info",
            "--json",
            "--recursive",
            "--extra-experimental-features",
            "nix-command",
        ])
        .arg(&activation)
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
    Ok(Contents {
        kix_rev: kix_rev.to_string(),
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
