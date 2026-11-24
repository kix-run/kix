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
//!   shows, optional `warnings`, the Kix library's warnings for the build,
//!   which the commands that read the bundle show, and `files`, one
//!   `[path, size, references]` per store file, each reference an index
//!   into `files`. Files are sorted by store name, then by path, and no
//!   path appears twice. A bundle with no warnings leaves the field out.
//! - Frames 1 to n hold the files' bytes, concatenated in that order. A
//!   frame holds whole files and at least one byte.
//! - A skippable frame ends the file: the seek table, each frame's
//!   compressed and decompressed size, with no checksums.
//!
//! `zstd -d` gives the header followed by the files. The same contents give
//! the same bytes from the same Kix and libzstd versions.
//!
//! The container (frames, seek table, caps, hashing) is `kix-container`'s,
//! which `kix plan --save` files share.
//!
//! # What the references say
//!
//! The header does not explicitly name the record, index, or cluster; they are
//! derived from the references before any file is read:
//!
//! - The record is the one file no other file references. It is named
//!   `k8s-*` and is a manifest of kind Activation in the `kix.run` group.
//! - The index is the record's one direct reference named
//!   `kix-packages.json`.
//! - Every file is in the record's closure. `kix/lib` makes the record
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
//! build, so the decisions Kix makes by name (skip an unchanged object,
//! prune, gc, and the Activation name) hold for bundles.
//!
//! # One parser
//!
//! Every manifest and the index are parsed with
//! `manifest_json::parse_manifest`, the same parser used when reading a Nix
//! result directory.
//!
//! # Two readers
//!
//! [`PathsChecked::read`] is for a server that stores bundles from any
//! tenant and never plans them. It checks the container, every store path,
//! the roles, and the closure, and parses only the record. It counts the
//! header's files, references, and receipt bytes before it keeps the
//! header, so the parsed header stays within a few times the caps. It holds
//! the header as read and parsed, one frame compressed and decompressed, a
//! few words per file, and the parsed record: under 200 MiB.
//!
//! [`Bundle::read`] is for the agent and the CLI. It does the same, then
//! parses every manifest and the index and gives the build's [`StoreGraph`](kix::eval::store_graph::StoreGraph),
//! built by `StoreGraph::assemble` and checked by
//! `StoreGraph::validate`, just like a Nix result directory. It keeps every
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
//! - every manifest and the index parse with `parse_manifest`, and every
//!   path the index lists is a manifest in the bundle;
//! - `StoreGraph::validate` holds: one Activation record, at the record's
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
//! | `MAX_HEADER_BYTES`, 32 MiB | server: memory for the header |
//! | `MAX_FILES`, 200,000 | server: memory per file and per seek-table entry, counted before the header is kept |
//! | `MAX_REFERENCES`, 1,600,000 | server: time to hash the references of every path, and memory for them |
//! | `MAX_RECEIPT_BYTES`, 256 KiB | server: memory to parse the receipt |
//! | `MAX_WARNINGS_BYTES`, 1 MiB | server: memory to parse the warnings |
//! | `MAX_FRAME_BYTES`, 32 MiB | server: memory for one frame, so also the largest file |
//! | `MAX_CONTENT_BYTES`, 1 GiB | server: time to decompress and hash the files |
//! | [`MAX_RECORD_BYTES`], 256 KiB | server: memory to parse the record |
//! | `cluster::secrets` 8 MiB of SOPS text, aliases expanded | agent: a plan parses SOPS files before anyone approves it |
//! | `WrongFormat`, `Format1` | another format is never read as this one; `--deployed-bundle` sets format 1 aside |
//! | `Malformed` | the reader finds each file where the header says, in one encoding |
//! | `PathMismatch` | names equal content |
//! | `Roots`, `NotARecord`, `NoIndex`, `Unreachable` | one record, whose name covers every file |
//! | `NotJson` | each check reads the value plan and deploy use |
//! | `Build` | plan shows each object once, under one package, at the URL Kix requests |
//!
//! # Threat model
//!
//! - On the server, [`PathsChecked`] reads uploads from any tenant's
//!   uploader. Their effect must stay within bounded memory and CPU.
//! - On the agent, [`Bundle::read`] reads uploads from this cluster's
//!   uploader. Only name-equals-content and one record matter: plan-bound
//!   deploy refuses any write or delete the approved plan does not show,
//!   and the agent runs Kix under memory, CPU, and time limits.

use std::cmp::Ordering;

use kix_container::{ContainerError, Limits};
use serde::{Deserialize, Serialize};

mod file;
mod read;
#[cfg(test)]
mod tests;
mod write;

pub use file::{Written, read_build, write_build};
pub use kix::build_source::Provenance;
use kix::eval::library_record::LibraryRecord;
use kix::eval::manifest_json::NotJson;
/// Re-exported for the Kix Enterprise server, which parses a bundle's
/// manifests one at a time as this crate does.
pub use kix::eval::manifest_json::parse_manifest;
use kix::eval::store_path;
use kix::manifest::keys;
use kix::text::printable;
pub use read::{Bundle, OpenBundle, PathsChecked};
pub use write::{BundleFile, Contents, from_local};

/// The `format` field of every bundle header.
pub(crate) const FORMAT: &str = "kix-bundle";
/// The version Kix writes and reads. A reader refuses any other.
pub(crate) const VERSION: u32 = 3;
/// The file extension `kix bundle` suggests.
pub const EXTENSION: &str = "kixbundle";
/// The store name of the package index.
pub const INDEX_NAME: &str = "kix-packages.json";

/// The largest bundle file Kix reads.
pub const MAX_STORED_BYTES: u64 = 64 * 1024 * 1024;
/// The largest header, decompressed. A header takes about 100 bytes a file.
pub(crate) const MAX_HEADER_BYTES: u64 = 32 * 1024 * 1024;
/// The most files a bundle may hold.
pub(crate) const MAX_FILES: usize = 200_000;
/// The most references the header may give over all its files. A build
/// gives about 3.5 a file.
pub(crate) const MAX_REFERENCES: usize = 8 * MAX_FILES;
/// The largest data frame, decompressed, and so the largest file. The
/// largest file is `kix-packages.json`, at about 130 bytes for each file it
/// lists: about 26 MB at [`MAX_FILES`].
pub(crate) const MAX_FRAME_BYTES: u64 = 32 * 1024 * 1024;
/// The most bytes the files may add up to, as the header lists them.
pub(crate) const MAX_CONTENT_BYTES: u64 = 1024 * 1024 * 1024;
/// The largest Activation record. A record lists the build's package
/// instances, about 2 KB for each Lithus cluster, and parses to about a
/// hundred times its size at worst.
pub const MAX_RECORD_BYTES: u64 = 256 * 1024;
/// The largest receipt in the header, as JSON. A receipt names the build's
/// source and inputs, a few KB, and parses to about sixteen times its size
/// at worst.
pub(crate) const MAX_RECEIPT_BYTES: usize = 256 * 1024;
/// The largest list of warnings in the header, as JSON. A build gives a few
/// hundred bytes for each warning, and a warning parses to about twenty
/// times its size at worst.
pub(crate) const MAX_WARNINGS_BYTES: usize = 1024 * 1024;

pub(crate) const LIMITS: Limits = Limits {
    stored: MAX_STORED_BYTES,
    header: MAX_HEADER_BYTES,
    frame: MAX_FRAME_BYTES,
    files: MAX_FILES,
    content: MAX_CONTENT_BYTES,
};
pub(crate) const ZSTD_MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];

/// Frame 0 of a bundle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Header {
    /// Always `FORMAT`.
    pub format: String,
    /// Always `VERSION`.
    pub version: u32,
    /// The kix revision that wrote the bundle, for the record.
    pub kix_rev: String,
    /// Every file, in stream order: by store name, then by path.
    pub files: Vec<FileEntry>,
    /// The bundle maker's account of the build's source, which only the
    /// deploy receipt shows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Provenance>,
    /// The Kix library's warnings for the build, which the commands that
    /// read the bundle show.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<LibraryRecord>,
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
    /// Return the index of `path` in [`Header::files`].
    pub fn position(&self, path: &str) -> Option<usize> {
        self.files
            .binary_search_by(|f| stream_order(&f.path, path))
            .ok()
    }

    pub(crate) fn references_of(&self, i: usize) -> Vec<&str> {
        let refs = &self.files[i].references;
        refs.iter()
            .map(|r| self.files[*r as usize].path.as_str())
            .collect()
    }
}

/// Compare store paths by store name first, then by full path, grouping files
/// of the same kind so they compress together.
pub(crate) fn stream_order(a: &str, b: &str) -> Ordering {
    let name_a = store_path::name_of(a).unwrap_or_default();
    let name_b = store_path::name_of(b).unwrap_or_default();
    name_a.cmp(name_b).then_with(|| a.cmp(b))
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
    #[error("the bundle is a format 1 bundle, a tar file; Kix reads '{FORMAT}' version {VERSION}")]
    Format1,
    #[error(
        "the bundle's format is '{}' version {version}; Kix reads '{FORMAT}' version {VERSION}",
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
        "the Activation record {} does not reference {INDEX_NAME}, because it was built with an older Kix library. Run `kix upgrade --to {}` to move the project to the Kix library of this version of Kix, then build the bundle again",
        printable(.0),
        kix::version::running().release()
    )]
    NoIndex(String),
    #[error(
        "{} is not in the Activation record's closure, so it is not part of the build",
        printable(.0)
    )]
    Unreachable(String),
    #[error("{} is not a JSON manifest: {}", printable(.path), printable(.message))]
    NotJson { path: String, message: String },
    /// `StoreGraph::assemble` or `StoreGraph::validate` refused the
    /// build. Their messages are escaped already.
    #[error("{0}")]
    Build(String),
}

impl From<ContainerError> for BundleError {
    fn from(e: ContainerError) -> Self {
        match e {
            ContainerError::Unreadable(m) => BundleError::Unreadable(m),
            ContainerError::NotSeekable => malformed(ContainerError::NotSeekable.to_string()),
            ContainerError::WrongFormat { format, version } => {
                BundleError::WrongFormat { format, version }
            }
            ContainerError::TooLarge(m) => BundleError::TooLarge(m),
            ContainerError::Malformed(m) => BundleError::Malformed(m),
        }
    }
}

impl From<NotJson> for BundleError {
    fn from(NotJson { path, message }: NotJson) -> Self {
        BundleError::NotJson { path, message }
    }
}

pub(crate) fn malformed(message: impl Into<String>) -> BundleError {
    BundleError::Malformed(message.into())
}

pub(crate) fn too_large(message: impl Into<String>) -> BundleError {
    BundleError::TooLarge(message.into())
}
