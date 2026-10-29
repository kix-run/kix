//! Reading and verifying `.kixbundle` containers, store paths, roles, and build graphs.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap};
use std::io::{self, Read, Seek, SeekFrom};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};

use kix::eval::error::KixEvalError;
use kix::eval::manifest_json::parse_index;
use kix::eval::store_graph::{StoreGraph, store_name};
use kix::eval::store_path;
use kix::manifest::{keys, lifecycle};
use kix::text::printable;
use kix_container::{Container, ContainerError};
use serde::de::{IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};

use crate::{
    BundleError, BundleFile, Contents, FORMAT, FileEntry, Header, INDEX_NAME, LIMITS,
    MAX_CONTENT_BYTES, MAX_FILES, MAX_RECEIPT_BYTES, MAX_RECORD_BYTES, MAX_REFERENCES, Role,
    VERSION, ZSTD_MAGIC, malformed, parse_manifest, stream_order, too_large,
};

/// A bundle whose seek table and header have been read and checked, and
/// whose roles are known. Each file read through it is checked against its
/// store path.
#[derive(Debug)]
pub struct OpenBundle<R> {
    container: Container<R>,
    header: Header,
    roles: Roles,
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
    /// Read the seek table and the header, and derive each file's role
    /// without reading file contents.
    pub fn open(input: R) -> Result<Self, BundleError> {
        let (container, header, roles) = open_container(input)?;
        Ok(OpenBundle {
            container,
            header,
            roles,
        })
    }

    /// Read and return the bytes of the file at `path`, verifying that they
    /// match its store path.
    pub fn file(&mut self, path: &str) -> Result<Vec<u8>, BundleError> {
        let i = self
            .header
            .position(path)
            .ok_or_else(|| BundleError::NotInBundle(path.to_string()))?;
        self.file_at(i)
    }

    /// Read and verify every file in the bundle, returning the complete
    /// [`Contents`].
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

    /// Read and return all [`Role::Other`] files (such as SOPS source files),
    /// keyed by store path.
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
        let bytes = self.container.file(i)?;
        check_path(&self.header, i, &bytes)?;
        Ok(bytes)
    }
}

impl<R> OpenBundle<R> {
    pub fn header(&self) -> &Header {
        &self.header
    }

    /// Return the store path of the Activation record.
    pub fn record(&self) -> &str {
        &self.header.files[self.roles.record].path
    }

    /// Return the store path of `kix-packages.json`.
    pub fn index(&self) -> &str {
        &self.header.files[self.roles.index].path
    }

    /// Return the [`Role`] of the file at `path`, or `None` if `path` is not
    /// in the bundle.
    pub fn role(&self, path: &str) -> Option<Role> {
        Some(self.roles.of[self.header.position(path)?])
    }
}

/// A bundle whose store paths, roles, and closure have been verified, with
/// only the Activation record parsed.
#[derive(Debug)]
pub struct PathsChecked<R> {
    open: OpenBundle<R>,
    cluster: String,
    sha256: String,
}

impl<R: Read + Seek> PathsChecked<R> {
    /// Read and verify the bundle's container, store paths, roles, and
    /// closure, parsing only the Activation record.
    pub fn read(input: R) -> Result<Self, BundleError> {
        read_checked(input, |_, _, _| Ok(()))
    }
}

impl<R> PathsChecked<R> {
    /// Return the Activation record's `kix.run/cluster` label.
    pub fn cluster(&self) -> &str {
        &self.cluster
    }

    /// Return the lowercase hex SHA-256 digest of the bundle's bytes.
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
    /// Read and verify the entire bundle, returning the bundle and its
    /// validated [`StoreGraph`] (with `result_dir` set to
    /// `bundle:sha256:<sha256>`).
    pub fn read(input: R) -> Result<(Self, StoreGraph), BundleError> {
        let mut manifests = HashMap::new();
        let mut index = None;
        let checked = read_checked(input, |path, role, bytes| {
            match role {
                Role::Record | Role::Manifest => {
                    manifests.insert(PathBuf::from(path), bytes.to_vec());
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
        .map_err(|e| match e {
            KixEvalError::NotJson(e) => BundleError::from(e),
            e => BundleError::Build(e.to_string()),
        })?;
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

/// Read and hash every byte of `input` in order, verifying each file's store
/// path, parsing the Activation record, and passing each file to `each`.
fn read_checked<R: Read + Seek>(
    input: R,
    mut each: impl FnMut(&str, Role, &[u8]) -> Result<(), BundleError>,
) -> Result<PathsChecked<R>, BundleError> {
    let (container, header, roles) = open_container(input)?;
    let mut cluster = String::new();
    let (container, sha256) = container.read_all(|i, bytes| {
        let path = &header.files[i].path;
        check_path(&header, i, bytes)?;
        if roles.of[i] == Role::Record {
            cluster = record_cluster(path, bytes)?;
        }
        each(path, roles.of[i], bytes)
    })?;
    Ok(PathsChecked {
        open: OpenBundle {
            container,
            header,
            roles,
        },
        cluster,
        sha256,
    })
}

/// Read the seek table and the header, map each file to its data frame, and
/// derive file roles without reading file contents.
fn open_container<R: Read + Seek>(
    mut input: R,
) -> Result<(Container<R>, Header, Roles), BundleError> {
    if !kix_container::has_seek_table(&mut input, &LIMITS)? {
        return Err(if is_format_1(&mut input) {
            BundleError::Format1
        } else {
            ContainerError::NotSeekable.into()
        });
    }
    let (mut container, bytes) = Container::open(input, FORMAT, VERSION, &LIMITS)?;
    let header = parse_header(&bytes)?;
    drop(bytes);
    let sizes: Vec<u64> = header.files.iter().map(|f| f.size).collect();
    container.place(&sizes)?;
    let roles = roles_of(&header.files)?;
    Ok((container, header, roles))
}

/// Return whether `input` is a format 1 bundle (a tar archive, optionally
/// zstd-compressed, starting with `kix-bundle.json`).
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

/// Parse frame 0, whose format and version `Container::open` checked.
fn parse_header(bytes: &[u8]) -> Result<Header, BundleError> {
    let unreadable = |e: serde_json::Error| BundleError::Unreadable(format!("the header: {e}"));
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

/// Verify that file `i`'s store path matches `bytes` and its declared
/// references.
fn check_path(header: &Header, i: usize, bytes: &[u8]) -> Result<(), BundleError> {
    let path = &header.files[i].path;
    match store_path::method_of(path, bytes, &header.references_of(i)) {
        Some(_) => Ok(()),
        None => Err(BundleError::PathMismatch(path.clone())),
    }
}

/// Parse the Activation record at `path` and return its `kix.run/cluster`
/// label (or an empty string if unset), rejecting non-Activation manifests.
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

/// Build the per-file reference map expected by [`StoreGraph`], excluding
/// self-references and sorting references by lowercase store name.
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
