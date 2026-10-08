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
//! Every manifest and the index are parsed with
//! [`manifest_json::parse_manifest`](super::manifest_json::parse_manifest),
//! the parser a result directory's are read with.
//!
//! # Two readers
//!
//! [`PathsChecked::read`] is for a server that stores bundles from any
//! tenant and never plans them. It checks the container, every store path,
//! the roles, and the closure, and parses only the record. It counts the
//! header's files, references and receipt bytes before it keeps the
//! header, so the parsed header stays within a few times the caps. It holds
//! the header as read and parsed, one frame compressed and decompressed, a
//! few words per file, and the parsed record: under 200 MiB.
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
//!   every kind, name, namespace, and `apiVersion` part one URL path
//!   segment: not empty, `.`, or `..`, and without `/`, `%`, `?`, or `#`,
//!   since kube-rs puts them in request paths unescaped.
//!
//! # Caps and refusals
//!
//! | Cap or refusal | Protects |
//! |---|---|
//! | [`MAX_STORED_BYTES`], 64 MiB | server: bytes read and hashed per upload |
//! | [`MAX_HEADER_BYTES`], 32 MiB | server: memory for the header |
//! | [`MAX_FILES`], 200,000 | server: memory per file and per seek-table entry, counted before the header is kept |
//! | [`MAX_REFERENCES`], 1,600,000 | server: time to hash the references of every path, and memory for them |
//! | [`MAX_RECEIPT_BYTES`], 256 KiB | server: memory to parse the receipt |
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

use serde::de::{IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};
use zstd::zstd_safe;

use super::error::KixEvalError;
use super::manifest_json::{NotJson, parse_index, parse_manifest};
use super::store_graph::{StoreGraph, store_name};
use super::store_path;
pub use crate::build_source::Provenance;
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
/// The largest receipt in the header, as JSON. A receipt names the build's
/// source and inputs, a few KB, and parses to about sixteen times its size
/// at worst.
pub const MAX_RECEIPT_BYTES: usize = 256 * 1024;

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

impl From<NotJson> for BundleError {
    fn from(NotJson { path, message }: NotJson) -> Self {
        BundleError::NotJson { path, message }
    }
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
        let bytes = if size == 0 {
            Vec::new()
        } else {
            self.cached.1[offset..offset + size].to_vec()
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
        let bytes = if size == 0 {
            &[][..]
        } else {
            &frame.1[offset..offset + size]
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
        return Err(if is_format_1(input) {
            BundleError::Format1
        } else {
            malformed("it does not end with a zstd seek table")
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
    // Counted before the header is kept: a header that is mostly empty
    // files, references, or receipt parses to many times its size.
    let counts: Counts = serde_json::from_slice(bytes).map_err(unreadable)?;
    if counts.files.0 > MAX_FILES {
        return Err(too_large(format!(
            "the header lists more than {MAX_FILES} files"
        )));
    }
    if counts.files.1 > MAX_REFERENCES {
        return Err(too_large(format!(
            "the header gives more than {MAX_REFERENCES} references"
        )));
    }
    if counts
        .receipt
        .is_some_and(|r| r.get().len() > MAX_RECEIPT_BYTES)
    {
        return Err(too_large(format!(
            "the receipt is over {MAX_RECEIPT_BYTES} bytes"
        )));
    }
    let header: Header = serde_json::from_slice(bytes).map_err(unreadable)?;
    let files = &header.files;
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

/// What [`parse_header`] counts in the header before it keeps it.
#[derive(Deserialize)]
struct Counts<'a> {
    #[serde(default)]
    files: FileCounts,
    #[serde(default, borrow)]
    receipt: Option<&'a serde_json::value::RawValue>,
}

/// The files a header lists and the references they give, counted
/// without keeping them.
#[derive(Default)]
struct FileCounts(usize, usize);

impl<'de> Deserialize<'de> for FileCounts {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Files;
        impl<'de> Visitor<'de> for Files {
            type Value = FileCounts;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a list of [path, size, references]")
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<FileCounts, A::Error> {
                let mut counts = FileCounts::default();
                while let Some((_, _, Count(references))) =
                    seq.next_element::<(IgnoredAny, IgnoredAny, Count)>()?
                {
                    counts.0 += 1;
                    counts.1 += references;
                }
                Ok(counts)
            }
        }
        d.deserialize_seq(Files)
    }
}

/// The items a JSON list holds, counted without keeping them.
struct Count(usize);

impl<'de> Deserialize<'de> for Count {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Items;
        impl<'de> Visitor<'de> for Items {
            type Value = Count;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a list")
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Count, A::Error> {
                let mut n = 0;
                while seq.next_element::<IgnoredAny>()?.is_some() {
                    n += 1;
                }
                Ok(Count(n))
            }
        }
        d.deserialize_seq(Items)
    }
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
        .map(|i| {
            if i == record {
                Role::Record
            } else if i == index {
                Role::Index
            } else if is_manifest(&files[i].path) {
                Role::Manifest
            } else {
                Role::Other
            }
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

fn unreadable(e: impl std::fmt::Display) -> BundleError {
    BundleError::Unreadable(e.to_string())
}

fn malformed(message: impl Into<String>) -> BundleError {
    BundleError::Malformed(message.into())
}

fn too_large(message: impl Into<String>) -> BundleError {
    BundleError::TooLarge(message.into())
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

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use serde_json::{Value, json};

    use super::*;
    use crate::eval::store_path::Method;

    const FIXTURE: &[u8] =
        include_bytes!("../../tests/fixtures/bundles/kix-enterprise-test.kixbundle");
    const STATUS_PAGE: &str = "-k8s-PackageInstance-kix-enterprise-test-web-status-page";
    const STATUS_CONFIG: &str = "-k8s-ConfigMap-kix-enterprise-test-web-status-page";

    fn read(bytes: &[u8]) -> Result<StoreGraph, BundleError> {
        Bundle::read(Cursor::new(bytes)).map(|(_, graph)| graph)
    }

    fn checked(bytes: &[u8]) -> Result<PathsChecked<Cursor<&[u8]>>, BundleError> {
        PathsChecked::read(Cursor::new(bytes))
    }

    /// The contents of a real `kix-enterprise-test` build on stage1: 26
    /// manifests and `kix-packages.json`.
    fn real() -> Contents {
        OpenBundle::open(Cursor::new(FIXTURE))
            .unwrap()
            .contents()
            .unwrap()
    }

    fn written(contents: &Contents) -> Vec<u8> {
        let mut bytes = Vec::new();
        contents.write(&mut bytes).unwrap();
        bytes
    }

    /// What both readers make of `contents`: each refuses it the same way,
    /// or `Bundle::read` gives its graph.
    fn read_both(contents: &Contents) -> Result<StoreGraph, BundleError> {
        let bytes = written(contents);
        let full = read(&bytes);
        if let Err(e) = checked(&bytes) {
            assert_eq!(full.as_ref().err(), Some(&e), "the readers disagree");
        }
        full
    }

    /// The `Build` refusal of `contents`, which `PathsChecked` accepts.
    fn build_error(contents: &Contents) -> String {
        let bytes = written(contents);
        checked(&bytes).unwrap();
        match read(&bytes) {
            Err(BundleError::Build(message)) => message,
            other => panic!("expected a Build refusal, got {other:?}"),
        }
    }

    fn path_ending(contents: &Contents, suffix: &str) -> String {
        let mut found = contents.files.keys().filter(|p| p.ends_with(suffix));
        let path = found.next().unwrap().clone();
        assert!(found.next().is_none(), "two files end with {suffix}");
        path
    }

    fn record(contents: &Contents) -> String {
        path_ending(contents, "-k8s-Activation-_cluster_-kix-enterprise-test")
    }

    fn index(contents: &Contents) -> String {
        path_ending(contents, &format!("-{INDEX_NAME}"))
    }

    /// Give the file at `path` these bytes and references, and its path
    /// again. Every file that references it or names it follows, as Nix
    /// would rebuild it. (The fixture's index names its entries without
    /// referencing them.) Returns the new path.
    fn set_file(contents: &mut Contents, path: &str, bytes: Vec<u8>, refs: Vec<String>) -> String {
        contents.files.remove(path).unwrap();
        let name = store_path::name_of(path).unwrap();
        let new = store_path::path_for(Method::Text, &bytes, &refs, name);
        contents.files.insert(
            new.clone(),
            BundleFile {
                bytes,
                references: refs,
            },
        );
        if new == path {
            return new;
        }
        let (old_hash, new_hash) = (&path[11..43], &new[11..43]);
        let names = |f: &BundleFile| f.bytes.windows(32).any(|w| w == old_hash.as_bytes());
        // One at a time: updating one referrer can rename another.
        while let Some(referrer) = contents
            .files
            .iter()
            .find(|(p, f)| **p != new && (f.references.iter().any(|r| r == path) || names(f)))
            .map(|(p, _)| p.clone())
        {
            let file = contents.files[&referrer].clone();
            let text = String::from_utf8(file.bytes).unwrap();
            let refs = file
                .references
                .iter()
                .map(|r| if r == path { new.clone() } else { r.clone() })
                .collect();
            set_file(
                contents,
                &referrer,
                text.replace(old_hash, new_hash).into_bytes(),
                refs,
            );
        }
        new
    }

    /// Change the JSON of the file at `path`. Returns its new path.
    fn edit(contents: &mut Contents, path: &str, change: impl FnOnce(&mut Value)) -> String {
        let file = contents.files[path].clone();
        let mut value: Value = serde_json::from_slice(&file.bytes).unwrap();
        change(&mut value);
        set_file(
            contents,
            path,
            serde_json::to_vec(&value).unwrap(),
            file.references,
        )
    }

    /// Add a file named `name` holding `text`, referencing `refs`, that no
    /// file references. Returns its path.
    fn add_file(contents: &mut Contents, name: &str, text: &str, refs: Vec<String>) -> String {
        let path = store_path::path_for(Method::Text, text.as_bytes(), &refs, name);
        let file = BundleFile {
            bytes: text.as_bytes().to_vec(),
            references: refs,
        };
        contents.files.insert(path.clone(), file);
        path
    }

    /// Make the file at `from` reference `to`.
    fn reference(contents: &mut Contents, from: &str, to: &str) {
        let file = contents.files[from].clone();
        let mut refs = file.references;
        refs.push(to.to_string());
        set_file(contents, from, file.bytes, refs);
    }

    /// List `path` in kix-packages.json under the package whose
    /// PackageInstance path ends with `package`, as kix/lib does: the
    /// index then references it.
    fn list_in_index(contents: &mut Contents, package: &str, path: &str) {
        let index = index(contents);
        reference(contents, &index, path);
        let index = self::index(contents);
        edit(contents, &index, |v| {
            let packages = v["packages"].as_object_mut().unwrap();
            let (_, list) = packages
                .iter_mut()
                .find(|(pi, _)| pi.ends_with(package))
                .unwrap();
            list.as_array_mut().unwrap().push(json!(path));
        });
    }

    /// Add a manifest to the status page's package.
    fn add_manifest(contents: &mut Contents, name: &str, manifest: &Value) -> String {
        let path = add_file(contents, name, &manifest.to_string(), vec![]);
        list_in_index(contents, STATUS_PAGE, &path);
        path
    }

    fn configmap(name: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": name, "namespace": "kix-enterprise-test-web"},
        })
    }

    /// An import marker in the status page's namespace, as
    /// `scope.mkCRDRef` makes one.
    fn marker(name: &str) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::PACKAGE_INSTANCE_KIND,
            "metadata": {
                "name": name,
                "namespace": "kix-enterprise-test-web",
                "annotations": {(keys::MODE): "import"},
            },
            "spec": {"instanceName": name},
        })
    }

    /// Each frame of `bundle`, decompressed, frame 0 first.
    fn frames_of(bundle: &[u8]) -> Vec<Vec<u8>> {
        let table = read_table(&mut Cursor::new(bundle)).unwrap();
        table
            .frames
            .iter()
            .map(|f| {
                let stored = &bundle[f.offset as usize..f.offset as usize + f.stored];
                zstd::bulk::decompress(stored, f.size).unwrap()
            })
            .collect()
    }

    /// A bundle file of these frames, as stored, each with its size
    /// decompressed, and a seek table that lists them.
    fn file_of(frames: &[(Vec<u8>, usize)]) -> Vec<u8> {
        let mut out: Vec<u8> = frames.iter().flat_map(|(f, _)| f.clone()).collect();
        let table: Vec<(u32, u32)> = frames
            .iter()
            .map(|(f, n)| (f.len() as u32, *n as u32))
            .collect();
        out.extend(seek_table(&table));
        out
    }

    /// A bundle file of these frames, decompressed, frame 0 first.
    fn join(frames: &[Vec<u8>]) -> Vec<u8> {
        let stored: Vec<(Vec<u8>, usize)> = frames
            .iter()
            .map(|f| (zstd::bulk::compress(f, 3).unwrap(), f.len()))
            .collect();
        file_of(&stored)
    }

    /// The fixture with `change` made to its header's JSON.
    fn with_header(change: impl FnOnce(&mut Value)) -> Vec<u8> {
        let mut frames = frames_of(FIXTURE);
        let mut header: Value = serde_json::from_slice(&frames[0]).unwrap();
        change(&mut header);
        frames[0] = serde_json::to_vec(&header).unwrap();
        join(&frames)
    }

    fn malformed(result: Result<StoreGraph, BundleError>) -> bool {
        matches!(result, Err(BundleError::Malformed(_)))
    }

    fn too_large(result: Result<StoreGraph, BundleError>) -> bool {
        matches!(result, Err(BundleError::TooLarge(_)))
    }

    // Honest builds.

    #[test]
    fn a_real_build_reads_and_gives_its_graph() {
        let (bundle, graph) = Bundle::read(Cursor::new(FIXTURE)).unwrap();
        assert_eq!(bundle.sha256(), hex(&Sha256::digest(FIXTURE)));
        assert_eq!(bundle.cluster(), "kix-enterprise-test");
        assert_eq!(graph.cluster_name, "kix-enterprise-test");
        assert_eq!(
            graph.result_dir,
            PathBuf::from(format!("bundle:sha256:{}", bundle.sha256()))
        );
        assert_eq!(graph.activation_path, PathBuf::from(bundle.record()));
        assert_eq!(graph.packages.len(), 6);
        assert_eq!(graph.resources.len(), 26);
        let cross: usize = graph.packages.values().map(|p| p.cross_deps.len()).sum();
        assert!(cross > 0, "the shop reads the valkey in another package");
        let checked = checked(FIXTURE).unwrap();
        assert_eq!(checked.cluster(), bundle.cluster());
        assert_eq!(checked.sha256(), bundle.sha256());
        assert_eq!(checked.record(), bundle.record());
        assert_eq!(checked.index(), bundle.index());
    }

    /// The other fixtures: `immich`, whose packages share import markers,
    /// and `test-bundle-alias`, an instance that names one resource twice.
    #[test]
    fn every_fixture_reads() {
        for bytes in [
            &include_bytes!("../../tests/fixtures/bundles/immich.kixbundle")[..],
            &include_bytes!("../../tests/fixtures/bundles/bundle-alias.kixbundle")[..],
        ] {
            checked(bytes).unwrap();
            read(bytes).unwrap();
        }
    }

    #[test]
    fn writing_is_reproducible_and_round_trips() {
        let contents = real();
        let bytes = written(&contents);
        assert_eq!(bytes, FIXTURE, "the fixture is what this kix writes");
        let mut open = OpenBundle::open(Cursor::new(bytes.as_slice())).unwrap();
        assert_eq!(open.contents().unwrap().files, contents.files);
        assert_eq!(open.header(), &contents.header().unwrap());
    }

    /// Any zstd tool decompresses a bundle to its header and its files, and
    /// zstd's own seekable reader reads its seek table.
    #[test]
    fn zstd_reads_a_bundle() {
        let contents = real();
        let header = contents.header().unwrap();
        let mut expected = serde_json::to_vec(&header).unwrap();
        for f in &header.files {
            expected.extend(&contents.files[&f.path].bytes);
        }
        assert_eq!(zstd::stream::decode_all(FIXTURE).unwrap(), expected);
        let frames = frames_of(FIXTURE);
        let mut seekable = zstd_safe::seekable::Seekable::create();
        seekable.init_buff(FIXTURE).unwrap();
        assert_eq!(seekable.num_frames() as usize, frames.len());
        for (i, frame) in frames.iter().enumerate() {
            let mut out: Vec<u8> = Vec::with_capacity(frame.len());
            seekable.decompress_frame(&mut out, i as u32).unwrap();
            assert_eq!(&out, frame, "frame {i}");
        }
    }

    /// An opened bundle reads any file, in any order, checked against its
    /// path; it reads none when it opens.
    #[test]
    fn an_opened_bundle_checks_each_file_it_reads() {
        let contents = real();
        let mut open = OpenBundle::open(Cursor::new(FIXTURE)).unwrap();
        for (path, file) in contents.files.iter().rev() {
            assert_eq!(open.file(path).unwrap(), file.bytes);
        }
        let missing = store_path::path_for(Method::Text, b"x", &[], "k8s-ConfigMap-missing");
        assert_eq!(open.file(&missing), Err(BundleError::NotInBundle(missing)));

        let p = path_ending(&contents, STATUS_CONFIG);
        let header = contents.header().unwrap();
        let i = header.position(&p).unwrap();
        let offset: usize = header.files[..i].iter().map(|f| f.size as usize).sum();
        let mut frames = frames_of(FIXTURE);
        assert_eq!(frames.len(), 2, "the fixture has one data frame");
        frames[1][offset + 1] ^= 1;
        let bytes = join(&frames);
        let mut open = OpenBundle::open(Cursor::new(bytes.as_slice())).unwrap();
        assert_eq!(open.file(&p), Err(BundleError::PathMismatch(p.clone())));
        assert_eq!(read(&bytes), Err(BundleError::PathMismatch(p)));
    }

    /// The reader needs only that frames hold whole files, not the
    /// writer's 1 MiB rule.
    #[test]
    fn one_frame_per_file_reads() {
        let contents = real();
        let header = contents.header().unwrap();
        let mut frames = vec![serde_json::to_vec(&header).unwrap()];
        for f in &header.files {
            frames.push(contents.files[&f.path].bytes.clone());
        }
        read(&join(&frames)).unwrap();
    }

    /// kix/lib lists an import marker no object references under its
    /// instance, so the record reaches it through the index, and a deploy
    /// applies it.
    #[test]
    fn an_import_marker_only_the_index_lists_is_in_the_build() {
        let mut contents = real();
        let path = add_manifest(
            &mut contents,
            "k8s-PackageInstance-kix-enterprise-test-web-crd-ref-x",
            &marker("crd-ref-x"),
        );
        let graph = read_both(&contents).unwrap();
        assert!(graph.resources.contains_key(Path::new(&path)));
    }

    /// Packages may list one import marker each; any other resource two
    /// packages list is refused.
    #[test]
    fn only_an_import_marker_may_be_listed_by_two_packages() {
        let shared = |manifest: &Value| {
            let mut contents = real();
            let path = add_manifest(&mut contents, "k8s-PackageInstance-x", manifest);
            list_in_index(
                &mut contents,
                "-k8s-PackageInstance-kix-enterprise-test-edge-landing",
                &path,
            );
            contents
        };
        read_both(&shared(&marker("secret-ref-x"))).unwrap();
        let message = build_error(&shared(&configmap("x")));
        assert!(message.contains("only an import marker"), "{message}");
    }

    /// A package that lists one path twice holds it once.
    #[test]
    fn a_path_listed_twice_by_one_package_counts_once() {
        let mut contents = real();
        let config = path_ending(&contents, STATUS_CONFIG);
        list_in_index(&mut contents, STATUS_PAGE, &config);
        let graph = read_both(&contents).unwrap();
        let package = graph
            .packages
            .values()
            .find(|p| p.instance_name == "status-page")
            .unwrap();
        let listed = package
            .resource_paths
            .iter()
            .filter(|p| **p == Path::new(&config))
            .count();
        assert_eq!(listed, 1);
    }

    /// A SOPS source made by `builtins.path` of a file with mode 0755 is
    /// carried, unparsed, among the files a Secret may name.
    #[test]
    fn an_executable_sops_source_is_carried() {
        let mut contents = real();
        let source = "/nix/store/mksphybbsiaag8ayhgj6bqq79f7p5cws-db.sops.yaml";
        let bytes = b"password: ENC[AES256_GCM,data:abc]\nsops:\n  age: []\n".to_vec();
        contents.files.insert(
            source.to_string(),
            BundleFile {
                bytes: bytes.clone(),
                references: vec![],
            },
        );
        let record = record(&contents);
        reference(&mut contents, &record, source);
        let bytes_written = written(&contents);
        let (mut bundle, _) = Bundle::read(Cursor::new(bytes_written.as_slice())).unwrap();
        assert_eq!(bundle.role(source), Some(Role::Other));
        assert_eq!(bundle.other_files().unwrap()[source], bytes);
    }

    /// Names with spaces, colons, and characters beyond ASCII are the
    /// API server's to judge.
    #[test]
    fn names_kix_can_request_are_carried() {
        for name in ["system:kube-proxy", "a b", "café", "x.y"] {
            let mut contents = real();
            add_manifest(&mut contents, "k8s-ConfigMap-x", &configmap(name));
            read_both(&contents).unwrap();
        }
    }

    // The container.

    /// A format 1 bundle is a tar file, zstd-compressed or not, whose first
    /// entry is `kix-bundle.json`. A seekable file whose header says
    /// version 1 is not one.
    #[test]
    fn a_format_1_bundle_is_refused_as_one() {
        let mut tar = vec![0u8; 1024];
        tar[..15].copy_from_slice(b"kix-bundle.json");
        let compressed = zstd::encode_all(tar.as_slice(), 3).unwrap();
        for bytes in [tar, compressed] {
            assert_eq!(read(&bytes), Err(BundleError::Format1));
        }
        let header = serde_json::to_vec(&json!({"format": FORMAT, "version": 1})).unwrap();
        assert_eq!(
            read(&join(&[header])),
            Err(BundleError::WrongFormat {
                format: FORMAT.to_string(),
                version: 1
            })
        );
    }

    /// The format and version are read alone, so a later version is named
    /// whatever else its header holds.
    #[test]
    fn another_version_is_refused_by_its_version() {
        let bytes = with_header(|h| {
            h["version"] = json!(4);
            h["files"] = json!("anything");
        });
        assert!(matches!(
            read(&bytes),
            Err(BundleError::WrongFormat { version: 4, .. })
        ));
    }

    #[test]
    fn a_header_of_another_shape_is_refused() {
        for change in [
            (|h: &mut Value| h["cluster"] = json!("x")) as fn(&mut Value),
            |h| h["files"][0] = json!(["/nix/store/x", 1]),
            |h| h["format"] = json!(3),
        ] {
            let bytes = with_header(change);
            assert!(
                matches!(
                    read(&bytes),
                    Err(BundleError::Unreadable(_)) | Err(BundleError::WrongFormat { .. })
                ),
                "{:?}",
                read(&bytes)
            );
        }
        assert!(malformed(read(b"{\"format\":\"kix-bundle\"}")));
    }

    #[test]
    fn a_header_that_breaks_its_rules_is_malformed() {
        let swap = |h: &mut Value| {
            let files = h["files"].as_array_mut().unwrap();
            files.swap(1, 2);
        };
        let repeat = |h: &mut Value| {
            let first = h["files"][1].clone();
            h["files"].as_array_mut().unwrap().insert(1, first);
        };
        let out_of_range = |h: &mut Value| h["files"][1][2] = json!([9999]);
        let not_a_store_path = |h: &mut Value| h["files"][1][0] = json!("/tmp/x");
        let bad_name = |h: &mut Value| {
            h["files"][1][0] = json!("/nix/store/0h5dy43cxa771fiz9dsx14c0vf32sn67-a b");
        };
        for change in [
            &swap as &dyn Fn(&mut Value),
            &repeat,
            &out_of_range,
            &not_a_store_path,
            &bad_name,
        ] {
            assert!(malformed(read(&with_header(change))));
        }
    }

    #[test]
    fn frames_that_disagree_with_the_header_are_malformed() {
        let frames = frames_of(FIXTURE);
        // The data frame cut in two inside a file.
        let mut split = frames.clone();
        let tail = split[1].split_off(100);
        split.push(tail);
        assert!(malformed(read(&join(&split))));
        // A byte short.
        let mut short = frames.clone();
        short[1].pop();
        assert!(malformed(read(&join(&short))));
        // A byte over.
        let mut long = frames;
        long[1].push(b' ');
        assert!(malformed(read(&join(&long))));
    }

    #[test]
    fn a_seek_table_that_disagrees_with_its_frames_is_malformed() {
        let stored: Vec<(Vec<u8>, usize)> = frames_of(FIXTURE)
            .iter()
            .map(|f| (zstd::bulk::compress(f, 3).unwrap(), f.len()))
            .collect();
        let mut wrong_size = stored.clone();
        wrong_size[1].1 += 1;
        assert!(malformed(read(&file_of(&wrong_size))));
        let mut with_extra = file_of(&stored);
        with_extra.insert(0, 0);
        assert!(malformed(read(&with_extra)));
        let mut after = file_of(&stored);
        after.push(0);
        assert!(malformed(read(&after)));
        let mut garbage = stored;
        garbage[1].0.extend([1, 2, 3]);
        assert!(malformed(read(&file_of(&garbage))));
    }

    /// Each frame's size is checked against its cap before it is read.
    #[test]
    fn frames_over_their_caps_are_refused_before_they_are_read() {
        let huge = |frame: usize, size: u64| {
            let mut stored: Vec<(Vec<u8>, usize)> = frames_of(FIXTURE)
                .iter()
                .map(|f| (zstd::bulk::compress(f, 3).unwrap(), f.len()))
                .collect();
            stored[frame].1 = size as usize + 1;
            file_of(&stored)
        };
        assert!(too_large(read(&huge(0, MAX_HEADER_BYTES))));
        assert!(too_large(read(&huge(1, MAX_FRAME_BYTES))));
    }

    /// The file's length is checked before any of it is read.
    #[test]
    fn a_file_over_the_stored_cap_is_refused() {
        struct Endless;
        impl Read for Endless {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                panic!("read past the length check");
            }
        }
        impl Seek for Endless {
            fn seek(&mut self, _: SeekFrom) -> io::Result<u64> {
                Ok(MAX_STORED_BYTES + 1)
            }
        }
        assert!(matches!(
            PathsChecked::read(Endless),
            Err(BundleError::TooLarge(_))
        ));
    }

    #[test]
    fn a_header_over_its_counts_is_refused() {
        let files = |n: usize| {
            with_header(|h| {
                let first = h["files"][0].clone();
                h["files"] = json!(vec![first; n]);
            })
        };
        assert!(too_large(read(&files(MAX_FILES + 1))));
        let references = with_header(|h| h["files"][0][2] = json!(vec![0; MAX_REFERENCES + 1]));
        assert!(too_large(read(&references)));
        let content = with_header(|h| h["files"][0][1] = json!(MAX_CONTENT_BYTES + 1));
        assert!(too_large(read(&content)));
    }

    #[test]
    fn writing_refuses_a_file_over_the_frame_cap_by_name() {
        let mut contents = real();
        let big = "x".repeat(MAX_FRAME_BYTES as usize + 1);
        let path = add_file(&mut contents, "big", &big, vec![]);
        let err = contents.write(io::sink()).unwrap_err();
        assert!(err.to_string().contains(&path), "{err}");
        let mut contents = real();
        let dangling = store_path::path_for(Method::Text, b"x", &[], "x");
        add_file(&mut contents, "y", "y", vec![dangling]);
        assert!(contents.write(io::sink()).is_err());
    }

    // Names equal content.

    #[test]
    fn a_changed_byte_or_reference_is_refused() {
        let mut contents = real();
        let config = path_ending(&contents, STATUS_CONFIG);
        contents.files.get_mut(&config).unwrap().bytes[1] ^= 1;
        assert_eq!(read_both(&contents), Err(BundleError::PathMismatch(config)));

        let mut contents = real();
        let deployment = path_ending(
            &contents,
            "-k8s-Deployment-kix-enterprise-test-web-status-page",
        );
        let namespace = "-k8s-Namespace-_cluster_-kix-enterprise-test-web";
        let refs = &mut contents.files.get_mut(&deployment).unwrap().references;
        refs.retain(|r| !r.ends_with(namespace));
        assert!(matches!(
            read_both(&contents),
            Err(BundleError::PathMismatch(p)) if p == deployment
        ));
    }

    // The record, the index, and the closure.

    #[test]
    fn a_file_outside_the_build_is_refused() {
        let mut contents = real();
        add_file(&mut contents, "k8s-ConfigMap-stray", "{}", vec![]);
        assert_eq!(read_both(&contents), Err(BundleError::Roots(2)));

        // Two files that reference each other are no root, and the record
        // does not reach them. Roles come from the header, before any path
        // is checked.
        let hash = "0h5dy43cxa771fiz9dsx14c0vf32sn67";
        let bytes = with_header(|h| {
            let files = h["files"].as_array_mut().unwrap();
            let n = files.len();
            files.push(json!([format!("/nix/store/{hash}-zz1"), 0, [n + 1]]));
            files.push(json!([format!("/nix/store/{hash}-zz2"), 0, [n]]));
        });
        assert_eq!(
            read(&bytes),
            Err(BundleError::Unreachable(format!("/nix/store/{hash}-zz1")))
        );
    }

    #[test]
    fn a_record_that_is_not_an_activation_is_refused() {
        let mut contents = real();
        let record = record(&contents);
        let file = contents.files.remove(&record).unwrap();
        let text = String::from_utf8(file.bytes).unwrap();
        let renamed = add_file(&mut contents, "activation.json", &text, file.references);
        assert_eq!(read_both(&contents), Err(BundleError::NotARecord(renamed)));

        for change in [
            (|v: &mut Value| v["kind"] = json!("ConfigMap")) as fn(&mut Value),
            |v| v["apiVersion"] = json!("other.io/v1"),
        ] {
            let mut contents = real();
            let record = self::record(&contents);
            let record = edit(&mut contents, &record, change);
            assert_eq!(read_both(&contents), Err(BundleError::NotARecord(record)));
        }
    }

    /// A record past its cap is refused from the header, before it is
    /// read.
    #[test]
    fn a_large_record_is_refused_before_it_is_read() {
        let mut contents = real();
        let record = record(&contents);
        let file = contents.files[&record].clone();
        let mut padded = file.bytes;
        padded.extend(vec![b' '; MAX_RECORD_BYTES as usize]);
        set_file(&mut contents, &record, padded, file.references);
        assert!(matches!(
            read_both(&contents),
            Err(BundleError::TooLarge(_))
        ));
    }

    /// The record must reference the index itself; a kixpkgs lib older
    /// than this kix builds records that do not, and the error names it.
    #[test]
    fn a_record_that_does_not_reference_the_index_is_refused() {
        let mut contents = real();
        let record = record(&contents);
        let index = index(&contents);
        let file = contents.files[&record].clone();
        let refs: Vec<String> = file
            .references
            .into_iter()
            .filter(|r| *r != index)
            .collect();
        let record = set_file(&mut contents, &record, file.bytes, refs);
        let holder = add_file(&mut contents, "holder", "holder", vec![index]);
        reference(&mut contents, &record, &holder);
        let record = self::record(&contents);
        let err = read_both(&contents).unwrap_err();
        assert_eq!(err, BundleError::NoIndex(record));
        assert!(err.to_string().contains("kixpkgs lib"), "{err}");
    }

    // The one parser.

    #[test]
    fn a_manifest_the_parser_refuses_is_refused() {
        for text in [
            r#"{"kind":"ConfigMap","kind":"Secret"}"#.to_string(),
            r#"{"data":{"$serde_json::private::RawValue":"{}"}}"#.to_string(),
            format!("{}{}", "[".repeat(200), "]".repeat(200)),
            r#"{"kind":"ConfigMap"} {}"#.to_string(),
        ] {
            let mut contents = real();
            let config = path_ending(&contents, STATUS_CONFIG);
            let refs = contents.files[&config].references.clone();
            let config = set_file(&mut contents, &config, text.into_bytes(), refs);
            assert!(checked(&written(&contents)).is_ok());
            assert!(matches!(
                read(&written(&contents)),
                Err(BundleError::NotJson { path, .. }) if path == config
            ));
        }
    }

    /// serde_json's `Value` reads its reserved key as raw JSON, and the
    /// parser refuses it, so the value a check reads is the value used.
    #[test]
    fn the_parser_refuses_what_value_would_read_differently() {
        let text = br#"{"a":{"$serde_json::private::RawValue":"{\"kind\":\"Secret\"}"}}"#;
        assert!(parse_manifest("x", text).is_err());
        assert!(parse_manifest("x", br#"{"a":1,"a":2}"#).is_err());
        let value = parse_manifest("x", br#"{"a":[1,-2,1.5,"s",null,true]}"#).unwrap();
        assert_eq!(value, json!({"a": [1, -2, 1.5, "s", null, true]}));
    }

    // The build.

    #[test]
    fn manifests_kix_cannot_request_are_refused() {
        let bad = [
            ("metadata.name", configmap("a/b")),
            ("metadata.name", configmap("a%2f")),
            ("metadata.name", configmap("a?b")),
            ("metadata.name", configmap("a#b")),
            ("metadata.name", configmap("..")),
            ("metadata.name", configmap("")),
            (
                "metadata.name",
                json!({"apiVersion": "v1", "kind": "ConfigMap"}),
            ),
            ("metadata.namespace", {
                let mut m = configmap("x");
                m["metadata"]["namespace"] = json!(".");
                m
            }),
            ("apiVersion", {
                let mut m = configmap("x");
                m["apiVersion"] = json!("/v1");
                m
            }),
            ("apiVersion", {
                let mut m = configmap("x");
                m["apiVersion"] = json!("a/b/c");
                m
            }),
            ("kind", {
                let mut m = configmap("x");
                m["kind"] = json!("");
                m
            }),
        ];
        for (field, manifest) in bad {
            let mut contents = real();
            add_manifest(&mut contents, "k8s-ConfigMap-x", &manifest);
            let message = build_error(&contents);
            assert!(message.contains(&format!("'s {field} must")), "{message}");
        }
    }

    /// Plan and deploy key objects by kind, namespace and name, without the
    /// API group.
    #[test]
    fn two_manifests_of_one_object_are_refused() {
        let mut contents = real();
        let config = path_ending(&contents, STATUS_CONFIG);
        let mut other_group: Value =
            serde_json::from_slice(&contents.files[&config].bytes).unwrap();
        other_group["apiVersion"] = json!("example.com/v1");
        add_manifest(&mut contents, "k8s-ConfigMap-x", &other_group);
        let message = build_error(&contents);
        assert!(message.contains("are both ConfigMap/"), "{message}");
    }

    #[test]
    fn a_second_activation_is_refused() {
        let mut contents = real();
        let mut second = configmap("x");
        second["apiVersion"] = json!(keys::API_VERSION);
        second["kind"] = json!(lifecycle::RECORD_KIND);
        add_manifest(&mut contents, "k8s-Activation-x", &second);
        let message = build_error(&contents);
        assert!(message.contains("one Activation record"), "{message}");
    }

    #[test]
    fn an_index_for_another_cluster_is_refused() {
        let mut contents = real();
        let index = index(&contents);
        edit(&mut contents, &index, |v| v["cluster"] = json!("other"));
        let message = build_error(&contents);
        assert!(
            message.contains("kix-packages.json says 'other'"),
            "{message}"
        );
    }

    /// Plan keys packages by namespace and instance.
    #[test]
    fn two_packages_of_one_instance_are_refused() {
        let mut contents = real();
        let mut twin: Value =
            serde_json::from_slice(&contents.files[&path_ending(&contents, STATUS_PAGE)].bytes)
                .unwrap();
        twin["metadata"]["name"] = json!("twin");
        let twin = add_file(
            &mut contents,
            "k8s-PackageInstance-twin",
            &twin.to_string(),
            vec![],
        );
        let index = index(&contents);
        reference(&mut contents, &index, &twin);
        let index = self::index(&contents);
        edit(&mut contents, &index, |v| {
            v["packages"][&twin] = json!([twin])
        });
        let message = build_error(&contents);
        assert!(message.contains("plan would show as one"), "{message}");
    }

    #[test]
    fn a_package_without_an_instance_name_is_refused() {
        let mut contents = real();
        let pi = path_ending(&contents, STATUS_PAGE);
        edit(&mut contents, &pi, |v| {
            v["spec"].as_object_mut().unwrap().remove("instanceName");
        });
        let message = build_error(&contents);
        assert!(message.contains("no spec.instanceName"), "{message}");
    }

    /// Every path the index lists is a manifest in the bundle.
    #[test]
    fn an_index_entry_that_is_not_a_manifest_is_refused() {
        let mut contents = real();
        let source = add_file(&mut contents, "db.sops.yaml", "x: 1", vec![]);
        list_in_index(&mut contents, STATUS_PAGE, &source);
        let message = build_error(&contents);
        assert!(
            message.contains("not a manifest in the bundle"),
            "{message}"
        );

        let mut contents = real();
        let index = index(&contents);
        let absent = store_path::path_for(Method::Text, b"{}", &[], "k8s-ConfigMap-absent");
        edit(&mut contents, &index, |v| {
            v["packages"]
                .as_object_mut()
                .unwrap()
                .values_mut()
                .next()
                .unwrap()
                .as_array_mut()
                .unwrap()
                .push(json!(absent));
        });
        let message = build_error(&contents);
        assert!(
            message.contains("not a manifest in the bundle"),
            "{message}"
        );
    }

    // Errors and memory.

    /// Every message shows the uploader's text with hidden characters
    /// flagged.
    #[test]
    fn errors_flag_the_uploaders_hidden_characters() {
        let bytes = with_header(|h| h["format"] = json!("x\u{1b}[2J\u{202e}"));
        let message = read(&bytes).unwrap_err().to_string();
        assert!(message.contains("x⟨U+001B⟩[2J⟨U+202E⟩"), "{message}");

        let mut contents = real();
        add_manifest(&mut contents, "k8s-ConfigMap-x", &configmap("a\u{200b}"));
        add_manifest(&mut contents, "k8s-ConfigMap-y", &configmap("a\u{200b}"));
        let message = build_error(&contents);
        assert!(message.contains("ConfigMap/a⟨U+200B⟩@"), "{message}");
    }

    /// A ConfigMap of about `bytes` bytes that parses to about a hundred
    /// times its size.
    fn configmap_of_objects(name: &str, bytes: usize) -> String {
        let chain = format!("{}0{}", r#"{"":"#.repeat(60), "}".repeat(60));
        let chains = (bytes - 1000) / (chain.len() + 1);
        format!(
            r#"{{"apiVersion":"v1","kind":"ConfigMap","metadata":{{"name":"{name}","namespace":"kix-enterprise-test-web"}},"data":[{}]}}"#,
            vec![chain; chains].join(",")
        )
    }

    /// `PathsChecked::read` parses no manifest but the record, so its peak
    /// is about one frame, compressed and decompressed, however large the
    /// manifests parse.
    #[test]
    fn checking_paths_holds_one_frame_and_parses_no_manifest() {
        let one = configmap_of_objects("o", 1 << 20);
        let (_, parsed) = crate::allocated::peak_during(|| parse_manifest("o", one.as_bytes()));
        let mut contents = real();
        for i in 0..6 {
            let text = configmap_of_objects(&format!("o{i}"), 1 << 20);
            let path = add_file(&mut contents, &format!("k8s-ConfigMap-o{i}"), &text, vec![]);
            list_in_index(&mut contents, STATUS_PAGE, &path);
        }
        let bytes = written(&contents);
        let largest_frame = frames_of(&bytes).iter().map(Vec::len).max().unwrap();
        let (result, peak) = crate::allocated::peak_during(|| checked(&bytes).map(drop));
        result.unwrap();
        assert!(
            peak < 3 * largest_frame,
            "checking paths held {peak} bytes; the largest frame is {largest_frame}"
        );
        assert!(peak < parsed / 10, "{peak} bytes against {parsed} parsed");
    }

    /// The module doc's bound for `PathsChecked::read`: a header of
    /// [`MAX_FILES`] files and a file of [`MAX_FRAME_BYTES`] take it under
    /// 200 MiB.
    #[test]
    fn checking_paths_stays_under_its_stated_bound() {
        let mut contents = real();
        let record = record(&contents);
        let mut file = contents.files[&record].clone();
        let big = add_file(
            &mut contents,
            "big",
            &" ".repeat(MAX_FRAME_BYTES as usize),
            vec![],
        );
        file.references.push(big);
        for i in 0..MAX_FILES - contents.files.len() {
            let path = store_path::path_for(Method::Text, &[], &[], &format!("e{i}"));
            file.references.push(path.clone());
            contents.files.insert(
                path,
                BundleFile {
                    bytes: vec![],
                    references: vec![],
                },
            );
        }
        set_file(&mut contents, &record, file.bytes, file.references);
        assert_eq!(contents.files.len(), MAX_FILES);
        let bytes = written(&contents);
        let (result, peak) = crate::allocated::peak_during(|| checked(&bytes).map(drop));
        result.unwrap();
        assert!(peak < 200 << 20, "checking paths held {} MiB", peak >> 20);
    }

    /// A header of up to [`MAX_HEADER_BYTES`] that would parse to many
    /// times its size, as a long receipt, many empty files, or one file's
    /// long list of references, is refused under the stated bound.
    #[test]
    fn a_header_that_parses_large_is_refused_under_the_bound() {
        let header = |opening: &str, item: &str, closing: &str| {
            let room = MAX_HEADER_BYTES as usize - 200;
            let items = vec![item; room / (item.len() + 1)].join(",");
            format!(
                r#"{{"format":"kix-bundle","version":3,"kix_rev":"x",{opening}{items}{closing}}}"#
            )
        };
        let cases = [
            header(r#""files":[],"receipt":{"source":{"a":["#, "0", "]}}"),
            header(r#""files":["#, r#"["",0,[]]"#, "]"),
            header(r#""files":[["",0,["#, "0", "]]]"),
        ];
        let mut frames = frames_of(FIXTURE);
        for text in cases {
            frames[0] = text.into_bytes();
            let bytes = join(&frames);
            let (result, peak) = crate::allocated::peak_during(|| checked(&bytes).map(drop));
            assert!(
                peak < 200 << 20,
                "reading the header held {} MiB",
                peak >> 20
            );
            assert!(
                matches!(result, Err(BundleError::TooLarge(_))),
                "{:?}",
                result.err()
            );
        }
    }

    #[test]
    fn path_info_in_either_shape() {
        let refs = vec!["/nix/store/b".to_string()];
        let new = json!({"/nix/store/a": {"references": ["/nix/store/b"]}});
        let old = json!([{"path": "/nix/store/a", "references": ["/nix/store/b"]}]);
        for info in [new, old] {
            assert_eq!(
                path_info_references(&info),
                vec![("/nix/store/a".to_string(), refs.clone())]
            );
        }
    }
}
