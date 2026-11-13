//! Plan files (`*.kixplan`): a plan, its build's graph, and the manifests
//! of each object it changes, in one file.
//!
//! `kix plan --out` and `kix diff --out` write one; `kix deploy --plan`
//! reads one; Kix Enterprise stores the file as uploaded and reads the
//! header for each page, and one or two files for an object's page.
//!
//! # Version 1
//!
//! The container is `kix-container`'s, as a bundle's is: seekable zstd,
//! frame 0 the [`Header`] as JSON, frames 1 to n the files in the order the
//! header lists them, then the seek table. `zstd -d` gives the header and
//! the files.
//!
//! - `plan` is the [`Plan`] at `--detail fields`: field changes listed,
//!   no manifests.
//! - `graph` is the new build's dependency graph, as `kix graph -o json`
//!   prints it.
//! - `shown` has an entry for each object `--detail manifests` shows
//!   (modified, added, and removed; kept left out), keyed by its id. It
//!   names the package that lists the object, the object's old and new
//!   manifest files, and says what a deploy does to its Pods
//!   ([`Rollout`]).
//! - `files` lists each file as `[sha256, size]`, sorted by SHA-256, each
//!   once. Each file is one manifest as compact JSON, with secret values
//!   hidden and over [`super::MAX_SHOWN_MANIFEST_BYTES`] replaced by a size
//!   note, as `--detail manifests` shows it. For an object the apiserver
//!   answered for, the old side is the live object and the new side the
//!   dry-run result. Objects with equal manifests share a file.
//!
//! # Names equal content
//!
//! A file is named by the SHA-256 of its bytes. Every read recomputes it
//! and refuses a file whose bytes miss their name.
//!
//! # Readers
//!
//! [`PlanFile::open`] reads the seek table and the header, and reads files
//! one at a time as asked. [`PlanFile::verify`] also reads every file once
//! and gives the SHA-256 of the whole file: for a server that stores
//! uploads, or a deploy that names the file it used.
//!
//! The same plan produces identical bytes from the same Kix and libzstd builds
//! because the header's field order is fixed by its types and the files are
//! sorted.
//!
//! # Caps
//!
//! Each is checked before what it guards is read. `kix plan --out` fails,
//! naming the cap, when a plan would pass one.
//!
//! | Cap | Protects |
//! |---|---|
//! | [`MAX_STORED_BYTES`], 64 MiB | bytes read and hashed |
//! | [`MAX_HEADER_BYTES`], 8 MiB | memory for the header as read |
//! | [`MAX_HEADER_VALUES`], 1,000,000 | memory for the header as parsed, counted before it is kept |
//! | [`MAX_FILES`], 100,000 | memory per file and per seek-table entry |
//! | [`MAX_FILE_BYTES`], 3 MiB | memory to parse one manifest |
//! | [`MAX_FRAME_BYTES`], 4 MiB | memory for one frame |
//! | [`MAX_CONTENT_BYTES`], 512 MiB | time to decompress and hash the files |

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::io::{self, Read, Seek, Write};

use kix_container::{Container, ContainerError, Limits, hex};
use schemars::JsonSchema;
use serde::de::{self, DeserializeSeed, Deserializer, IgnoredAny, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::document::{FieldChange, Packages, Plan};
use crate::cluster::graph::{GraphError, GraphListing, ResourceGraph};
use crate::eval::store_graph::StoreGraph;
use crate::text::printable;

/// The `format` field of every plan file's header.
pub const FORMAT: &str = "kixplan";
/// The format version that Kix writes and reads. Readers reject any other
/// version.
pub const VERSION: u32 = 1;
/// The file extension of a plan file.
pub const EXTENSION: &str = "kixplan";

/// The largest plan file Kix reads.
pub const MAX_STORED_BYTES: u64 = 64 * 1024 * 1024;
/// The largest header, decompressed. A plan at `--detail fields` of a
/// cluster of 26 objects is about 30 KB.
pub const MAX_HEADER_BYTES: u64 = 8 * 1024 * 1024;
/// The most JSON values the header may hold: every object, list, string,
/// number, boolean, and null, at any depth.
pub const MAX_HEADER_VALUES: usize = 1_000_000;
/// The most files a plan file may hold.
pub const MAX_FILES: usize = 100_000;
/// The largest file. A shown manifest is at most
/// [`super::MAX_SHOWN_MANIFEST_BYTES`], 3 MiB, as compact JSON.
pub const MAX_FILE_BYTES: u64 = super::MAX_SHOWN_MANIFEST_BYTES as u64;
/// The largest data frame, decompressed. The writer fills a frame to 1 MiB
/// and puts a larger file in a frame of its own, so a frame is at most
/// [`MAX_FILE_BYTES`].
pub const MAX_FRAME_BYTES: u64 = 4 * 1024 * 1024;
/// The most bytes the files may add up to.
pub const MAX_CONTENT_BYTES: u64 = 512 * 1024 * 1024;

const LIMITS: Limits = Limits {
    stored: MAX_STORED_BYTES,
    header: MAX_HEADER_BYTES,
    frame: MAX_FRAME_BYTES,
    files: MAX_FILES,
    content: MAX_CONTENT_BYTES,
};

/// Frame 0 of a plan file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Header {
    /// Always [`FORMAT`].
    pub format: String,
    /// Always [`VERSION`].
    pub version: u32,
    /// The plan at `--detail fields`: no package lists `manifests`.
    pub plan: Plan,
    /// The new build's dependency graph.
    pub graph: GraphListing,
    /// Each object whose manifests the file holds, by id.
    pub shown: BTreeMap<String, ShownObject>,
    /// Every file, sorted by SHA-256.
    pub files: Vec<FileEntry>,
}

/// The manifests of one object, and what a deploy does to its Pods.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ShownObject {
    /// The key of the package `plan.packages` lists the object under, as
    /// that list names it: `namespace/instance` for an added, removed, or
    /// changed package, `_cluster` for `cluster_level`. An object that moved
    /// between packages carries the package it moves to.
    pub package: String,
    /// The SHA-256 of the file of its old manifest: the deployed or live
    /// object. `null` when the object does not exist on the old side.
    pub old: Option<String>,
    /// The SHA-256 of the file of its new manifest: the dry-run result, or
    /// the build's manifest. `null` when the deploy deletes the object.
    pub new: Option<String>,
    /// `null` when the deploy does not replace its Pods.
    pub rollout: Option<Rollout>,
}

/// What deploying the plan does to a workload's Pods.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Rollout {
    /// A field of its pod template changes, so its controller replaces its
    /// Pods.
    Restart,
    /// A field of its pod template changes, but the new manifest sets
    /// `spec.updateStrategy.type: OnDelete`: running Pods keep the old
    /// template until each is deleted.
    OnDelete,
}

/// Kinds whose controller replaces their Pods when the pod template changes.
/// A bare ReplicaSet does not: only Pods it starts later get the new
/// template.
const ROLLING_KINDS: [&str; 3] = ["Deployment", "StatefulSet", "DaemonSet"];

/// One file of the [`Header`], written `[sha256, size]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(from = "(String, u64)", into = "(String, u64)")]
pub struct FileEntry {
    /// The SHA-256 of its bytes, lowercase hex.
    pub sha256: String,
    pub size: u64,
}

impl From<(String, u64)> for FileEntry {
    fn from((sha256, size): (String, u64)) -> Self {
        FileEntry { sha256, size }
    }
}

impl From<FileEntry> for (String, u64) {
    fn from(f: FileEntry) -> Self {
        (f.sha256, f.size)
    }
}

/// Why a plan file was refused. Its strings may hold the writer's text,
/// and each message shows them through [`printable`].
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PlanFileError {
    #[error("the plan file cannot be read: {}", printable(.0))]
    Unreadable(String),
    #[error("the file is not a valid `.{EXTENSION}` archive (missing archive footer)")]
    NotAPlanFile,
    #[error(
        "the plan file's format is '{}' version {version}, and Kix {} reads '{FORMAT}' version {VERSION}",
        printable(.format),
        crate::version::running().release()
    )]
    WrongFormat { format: String, version: u32 },
    #[error(
        "the plan file uses plan schema version {}, and Kix {} reads version {}",
        printable(.0),
        crate::version::running().release(),
        super::document::SCHEMA_VERSION
    )]
    WrongSchema(String),
    #[error("the plan file is too large ({})", printable(.0))]
    TooLarge(String),
    #[error("the plan file is corrupted or malformed ({})", printable(.0))]
    Malformed(String),
    #[error(
        "manifest {} inside the plan file is corrupted (its bytes do not match its SHA-256 digest)",
        printable(.0)
    )]
    FileMismatch(String),
}

impl From<ContainerError> for PlanFileError {
    fn from(e: ContainerError) -> Self {
        match e {
            ContainerError::Unreadable(m) => PlanFileError::Unreadable(m),
            ContainerError::NotSeekable => PlanFileError::NotAPlanFile,
            ContainerError::WrongFormat { format, version } => {
                PlanFileError::WrongFormat { format, version }
            }
            ContainerError::TooLarge(m) => PlanFileError::TooLarge(m),
            ContainerError::Malformed(m) => PlanFileError::Malformed(m),
        }
    }
}

/// Write the plan file of `plan` and `graph`, the new build's graph.
/// `plan` must be made at `Detail::Manifests`: the manifests its packages
/// list become the files, and the header's plan lists none.
///
/// Fails before writing, naming the cap, when the header would pass
/// [`MAX_HEADER_BYTES`] or [`MAX_HEADER_VALUES`], or the files
/// [`MAX_FILES`] or [`MAX_CONTENT_BYTES`]. The stored size is known only
/// once written: read the file back with [`PlanFile::verify`].
pub fn write(mut plan: Plan, graph: GraphListing, out: impl Write) -> io::Result<()> {
    let sides = plan.packages.take_manifests();
    let changes = field_changes(&plan.packages);
    let mut files: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let mut file_of = |manifest: Option<Value>| -> io::Result<Option<String>> {
        let Some(manifest) = manifest else {
            return Ok(None);
        };
        let bytes = serde_json::to_vec(&manifest)?;
        let sha256 = hex(&Sha256::digest(&bytes));
        files.insert(sha256.clone(), bytes);
        Ok(Some(sha256))
    };
    let mut shown = BTreeMap::new();
    for (id, (package, sides)) in sides {
        let rollout = rollout(&id, changes.get(id.as_str()).copied(), sides.new.as_ref());
        let object = ShownObject {
            package,
            old: file_of(sides.old)?,
            new: file_of(sides.new)?,
            rollout,
        };
        shown.insert(id, object);
    }
    let header = Header {
        format: FORMAT.to_string(),
        version: VERSION,
        plan,
        graph,
        shown,
        files: files
            .iter()
            .map(|(sha256, bytes)| FileEntry {
                sha256: sha256.clone(),
                size: bytes.len() as u64,
            })
            .collect(),
    };
    let header = serde_json::to_vec(&header)?;
    let over = |message: String| io::Error::new(io::ErrorKind::InvalidInput, message);
    if header.len() as u64 > MAX_HEADER_BYTES {
        return Err(over(format!(
            "the plan's summary header is {} bytes, over the 8 MiB limit ({MAX_HEADER_BYTES} bytes)",
            header.len()
        )));
    }
    count_values(&header).map_err(|e| over(e.to_string()))?;
    if files.len() > MAX_FILES {
        return Err(over(format!(
            "the plan has {} manifests, over the 100,000-manifest limit ({MAX_FILES})",
            files.len()
        )));
    }
    let content: u64 = files.values().map(|f| f.len() as u64).sum();
    if content > MAX_CONTENT_BYTES {
        return Err(over(format!(
            "the plan's manifests total {content} bytes, over the 512 MiB limit ({MAX_CONTENT_BYTES} bytes)"
        )));
    }
    let files: Vec<&[u8]> = files.values().map(Vec::as_slice).collect();
    kix_container::write(&header, &files, out)
}

/// Return the field changes of each modified object, keyed by resource ID.
fn field_changes(packages: &Packages) -> BTreeMap<&str, &[FieldChange]> {
    packages
        .changed
        .iter()
        .chain(packages.cluster_level.as_ref())
        .flat_map(|c| &c.modified_resources)
        .filter_map(|m| Some((m.resource.as_str(), m.changes.as_deref()?)))
        .collect()
}

/// Return the [`Rollout`] effect on Pods of `id` when `id` is a modified
/// rolling workload whose pod template changes. `new` is the shown new
/// manifest; a manifest replaced by a size note is treated as not `OnDelete`.
fn rollout(id: &str, changes: Option<&[FieldChange]>, new: Option<&Value>) -> Option<Rollout> {
    let kind = id.split('/').next().unwrap_or_default();
    let template_changes = ROLLING_KINDS.contains(&kind)
        && changes?
            .iter()
            .any(|c| c.path.starts_with("$.spec.template."));
    if !template_changes {
        return None;
    }
    let strategy = new
        .and_then(|n| n.pointer("/spec/updateStrategy/type"))
        .and_then(Value::as_str);
    Some(if strategy == Some("OnDelete") {
        Rollout::OnDelete
    } else {
        Rollout::Restart
    })
}

/// Build the dependency graph of `build` as `kix graph -o json --bundle`
/// prints it, with manifests sorted by `apiVersion`, `kind`, `namespace`, and
/// `name`.
pub fn graph_of(build: &StoreGraph) -> Result<GraphListing, GraphError> {
    let mut manifests: Vec<Value> = build
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect();
    manifests.sort_by_cached_key(crate::eval::cli_backend::manifest_sort_key);
    Ok(ResourceGraph::from_manifests(&manifests)?.listing())
}

/// A plan file whose seek table and header have been read and checked.
/// Each file read through it is checked against its name.
#[derive(Debug)]
pub struct PlanFile<R> {
    container: Container<R>,
    header: Header,
}

impl<R: Read + Seek> PlanFile<R> {
    /// Read the seek table and the header, and check the header: the
    /// counts first, then its files sorted and each named by some object.
    /// Reads no file.
    pub fn open(input: R) -> Result<Self, PlanFileError> {
        let (mut container, bytes) = Container::open(input, FORMAT, VERSION, &LIMITS)?;
        let header = parse_header(&bytes)?;
        drop(bytes);
        let sizes: Vec<u64> = header.files.iter().map(|f| f.size).collect();
        container.place(&sizes)?;
        Ok(PlanFile { container, header })
    }

    /// Read the file once, in order, checking every file against its name
    /// and that it is JSON, and give it with the SHA-256 of all its bytes,
    /// lowercase hex. Holds the header and one frame.
    pub fn verify(input: R) -> Result<(Self, String), PlanFileError> {
        let PlanFile { container, header } = Self::open(input)?;
        let (container, sha256) = container.read_all(|i, bytes| {
            check_file(&header.files[i].sha256, bytes)?;
            serde_json::from_slice::<IgnoredAny>(bytes).map_err(|e| {
                PlanFileError::Malformed(format!(
                    "file {} is not JSON: {e}",
                    header.files[i].sha256
                ))
            })?;
            Ok::<_, PlanFileError>(())
        })?;
        Ok((PlanFile { container, header }, sha256))
    }

    /// Read and verify the manifest stored under `sha256`, or return `Ok(None)`
    /// when the plan file holds no such file.
    pub fn file(&mut self, sha256: &str) -> Result<Option<Value>, PlanFileError> {
        let Ok(i) = self
            .header
            .files
            .binary_search_by(|f| f.sha256.as_str().cmp(sha256))
        else {
            return Ok(None);
        };
        let bytes = self.container.file(i)?;
        check_file(sha256, &bytes)?;
        let manifest = serde_json::from_slice(&bytes)
            .map_err(|e| PlanFileError::Malformed(format!("file {sha256} is not JSON: {e}")))?;
        Ok(Some(manifest))
    }

    /// Read the shown old manifest of object `id`, or return `Ok(None)` when
    /// the plan shows no old side for it.
    pub fn old_manifest(&mut self, id: &str) -> Result<Option<Value>, PlanFileError> {
        match self.header.shown.get(id).and_then(|s| s.old.clone()) {
            Some(sha256) => self.file(&sha256),
            None => Ok(None),
        }
    }

    /// Read the shown new manifest of object `id`, or return `Ok(None)` when
    /// the plan shows no new side for it.
    pub fn new_manifest(&mut self, id: &str) -> Result<Option<Value>, PlanFileError> {
        match self.header.shown.get(id).and_then(|s| s.new.clone()) {
            Some(sha256) => self.file(&sha256),
            None => Ok(None),
        }
    }
}

impl<R> PlanFile<R> {
    pub fn header(&self) -> &Header {
        &self.header
    }

    pub fn into_header(self) -> Header {
        self.header
    }
}

fn check_file(sha256: &str, bytes: &[u8]) -> Result<(), PlanFileError> {
    if hex(&Sha256::digest(bytes)) != sha256 {
        return Err(PlanFileError::FileMismatch(sha256.to_string()));
    }
    Ok(())
}

/// Parse frame 0, whose format and version `Container::open` checked.
fn parse_header(bytes: &[u8]) -> Result<Header, PlanFileError> {
    count_values(bytes)?;
    // A plan of another schema version may not parse as this one, so its
    // version is read first and refused by name.
    #[derive(Deserialize)]
    struct Versioned {
        plan: SchemaVersion,
    }
    #[derive(Deserialize)]
    struct SchemaVersion {
        schema_version: String,
    }
    if let Ok(Versioned { plan }) = serde_json::from_slice::<Versioned>(bytes)
        && plan.schema_version != super::document::SCHEMA_VERSION
    {
        return Err(PlanFileError::WrongSchema(plan.schema_version));
    }
    let header: Header = serde_json::from_slice(bytes)
        .map_err(|e| PlanFileError::Unreadable(format!("the header: {e}")))?;
    if header.files.len() > MAX_FILES {
        return Err(PlanFileError::TooLarge(format!(
            "the header lists more than MAX_FILES ({MAX_FILES}) files"
        )));
    }
    let malformed = |m: String| Err(PlanFileError::Malformed(m));
    let mut named = BTreeSet::new();
    for object in header.shown.values() {
        named.extend(object.old.iter().chain(&object.new).map(String::as_str));
    }
    for (i, file) in header.files.iter().enumerate() {
        let sha = &file.sha256;
        if sha.len() != 64
            || !sha
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return malformed(format!("'{sha}' is not a SHA-256 in lowercase hex"));
        }
        if i > 0 && header.files[i - 1].sha256 >= *sha {
            return malformed(format!("the header lists {sha} out of order or twice"));
        }
        if file.size > MAX_FILE_BYTES {
            return Err(PlanFileError::TooLarge(format!(
                "file {sha} is over MAX_FILE_BYTES ({MAX_FILE_BYTES})"
            )));
        }
        if !named.remove(sha.as_str()) {
            return malformed(format!("no object names file {sha}"));
        }
    }
    if let Some(sha) = named.first() {
        return malformed(format!("the header does not list file {sha}"));
    }
    Ok(header)
}

/// Count the JSON values in `bytes` without keeping them, and refuse more
/// than [`MAX_HEADER_VALUES`]: a header that is mostly short values parses
/// to many times its size.
fn count_values(bytes: &[u8]) -> Result<(), PlanFileError> {
    let count = Cell::new(0);
    let mut de = serde_json::Deserializer::from_slice(bytes);
    let read = Values { count: &count }
        .deserialize(&mut de)
        .and_then(|()| de.end());
    if count.get() > MAX_HEADER_VALUES {
        return Err(PlanFileError::TooLarge(format!(
            "the header holds more than MAX_HEADER_VALUES ({MAX_HEADER_VALUES}) JSON values"
        )));
    }
    read.map_err(|e| PlanFileError::Unreadable(format!("the header: {e}")))
}

/// Counts every value of one JSON document into `count`, stopping past
/// [`MAX_HEADER_VALUES`].
struct Values<'a> {
    count: &'a Cell<usize>,
}

impl Values<'_> {
    fn one<E: de::Error>(&self) -> Result<(), E> {
        self.count.set(self.count.get() + 1);
        if self.count.get() > MAX_HEADER_VALUES {
            return Err(E::custom("too many values"));
        }
        Ok(())
    }
}

impl<'de> DeserializeSeed<'de> for Values<'_> {
    type Value = ();
    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<(), D::Error> {
        d.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Values<'_> {
    type Value = ();
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("a JSON value")
    }
    fn visit_bool<E: de::Error>(self, _: bool) -> Result<(), E> {
        self.one()
    }
    fn visit_i64<E: de::Error>(self, _: i64) -> Result<(), E> {
        self.one()
    }
    fn visit_u64<E: de::Error>(self, _: u64) -> Result<(), E> {
        self.one()
    }
    fn visit_f64<E: de::Error>(self, _: f64) -> Result<(), E> {
        self.one()
    }
    fn visit_str<E: de::Error>(self, _: &str) -> Result<(), E> {
        self.one()
    }
    fn visit_unit<E: de::Error>(self) -> Result<(), E> {
        self.one()
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<(), A::Error> {
        self.one()?;
        while seq
            .next_element_seed(Values { count: self.count })?
            .is_some()
        {}
        Ok(())
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        self.one()?;
        while map.next_key::<IgnoredAny>()?.is_some() {
            map.next_value_seed(Values { count: self.count })?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, SeekFrom};

    use serde_json::json;

    use super::*;
    use crate::plan::document::{Build, Detail, KixBuild, MadeBy, NotCheckedReason};
    use crate::plan::fixtures::*;
    use crate::plan::{ManifestIndex, SECRET_CHANGED_NOT_SHOWN, SECRET_NOT_SHOWN, diff_graphs};

    const DEPLOYMENT: &str = "Deployment/web@app";
    const SECRET: &str = "Secret/web@app";

    /// Return test old and new manifest lists where the Secret's password and
    /// the Deployment's pod template change.
    fn sides() -> (Vec<Value>, Vec<Value>) {
        let secret = |hash: &str, password: &str| {
            web_resource(
                "Secret",
                hash,
                json!({"data": {"password": password, "user": "YWRtaW4="}}),
            )
        };
        let mut old = baseline();
        old.push(secret(&h("s1"), "b2xkLXBhc3M="));
        let mut new = baseline();
        new.push(secret(&h("s2"), "bmV3LXBhc3M="));
        let deployment = |hash: &str, image: &str| {
            stamped(
                "Deployment",
                "app",
                "web",
                ("app", "web"),
                hash,
                json!({"template": {"spec": {"containers": [{"name": "web", "image": image}]}}}),
            )
        };
        old[4] = deployment(&h("dep1"), "web:1");
        new[4] = deployment(&h("dep2"), "web:2");
        (old, new)
    }

    /// Build a plan from `old` to `new` at `--detail manifests` or `--detail
    /// fields`, along with the new build's graph.
    fn plan_at(old: &[Value], new: &[Value], manifests: bool) -> (Plan, GraphListing) {
        let (old_graph, new_graph) = graphs_of(old, new);
        let index = ManifestIndex::new(&old_graph, &new_graph);
        let detail = if manifests {
            Detail::Manifests(&index)
        } else {
            Detail::Fields
        };
        let plan = Plan::new(
            KixBuild {
                version: "test".into(),
                store_path: None,
            },
            MadeBy::Builds,
            "c",
            Build::of(&new_graph),
            &diff_graphs(&old_graph, &new_graph),
            detail,
            &[],
            NotCheckedReason::BuildsOnly,
        );
        (plan, graph_of(&new_graph).unwrap())
    }

    fn written(old: &[Value], new: &[Value]) -> Vec<u8> {
        let (plan, graph) = plan_at(old, new, true);
        let mut bytes = Vec::new();
        write(plan, graph, &mut bytes).unwrap();
        bytes
    }

    fn verify(bytes: &[u8]) -> Result<Header, PlanFileError> {
        PlanFile::verify(Cursor::new(bytes)).map(|(f, _)| f.into_header())
    }

    /// Write a plan file from raw `header` JSON and `files`.
    fn file_of(header: &Value, files: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        kix_container::write(&serde_json::to_vec(header).unwrap(), files, &mut out).unwrap();
        out
    }

    /// Return the header JSON and ordered file payloads of the test plan file.
    fn parts() -> (Value, Vec<Vec<u8>>) {
        let (old, new) = sides();
        let bytes = written(&old, &new);
        let mut file = PlanFile::open(Cursor::new(&bytes)).unwrap();
        let header = serde_json::to_value(file.header()).unwrap();
        let files = (0..file.header().files.len())
            .map(|i| file.container.file(i).unwrap())
            .collect();
        (header, files)
    }

    #[test]
    fn a_plan_round_trips_at_fields_with_its_manifests_in_files() {
        let (old, new) = sides();
        let bytes = written(&old, &new);
        let (mut file, sha256) = PlanFile::verify(Cursor::new(bytes.as_slice())).unwrap();
        assert_eq!(sha256, hex(&Sha256::digest(&bytes)));
        let (fields, graph) = plan_at(&old, &new, false);
        assert_eq!(file.header().plan, fields);
        assert_eq!(file.header().graph, graph);
        let (with_manifests, _) = plan_at(&old, &new, true);
        let shown = with_manifests.packages.changed[0]
            .manifests
            .clone()
            .unwrap();
        assert_eq!(
            file.header().shown.keys().collect::<Vec<_>>(),
            shown.keys().collect::<Vec<_>>()
        );
        for (id, sides) in shown {
            assert_eq!(file.old_manifest(&id).unwrap(), sides.old, "{id}");
            assert_eq!(file.new_manifest(&id).unwrap(), sides.new, "{id}");
        }
    }

    /// `kix/tests/fixtures/plan.kixplan` is the plan file of [`sides`] as this
    /// Kix writes it, ensuring deterministic output across builds. Regenerate
    /// it with `KIX_WRITE_FIXTURES=1 cargo test -p kix-lib plan::file`.
    #[test]
    fn the_fixture_is_what_this_kix_writes() {
        let path =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/plan.kixplan");
        let (old, new) = sides();
        let bytes = written(&old, &new);
        if std::env::var_os("KIX_WRITE_FIXTURES").is_some() {
            std::fs::write(&path, &bytes).unwrap();
        }
        assert!(
            std::fs::read(&path).unwrap_or_default() == bytes,
            "kix/tests/fixtures/plan.kixplan is not what Kix writes. Regenerate it with \
             KIX_WRITE_FIXTURES=1 cargo test -p kix-lib plan::file"
        );
    }

    /// Both sides of a changed Secret are hidden; the new side marks the
    /// changed value.
    #[test]
    fn a_changed_secrets_files_hold_no_secret_value() {
        let (old, new) = sides();
        let bytes = written(&old, &new);
        let text = String::from_utf8_lossy(&zstd::stream::decode_all(bytes.as_slice()).unwrap())
            .into_owned();
        for leaked in ["b2xkLXBhc3M=", "bmV3LXBhc3M=", "YWRtaW4="] {
            assert!(!text.contains(leaked), "{leaked} in the plan file");
        }
        let mut file = PlanFile::open(Cursor::new(bytes.as_slice())).unwrap();
        let old = file.old_manifest(SECRET).unwrap().unwrap();
        let new = file.new_manifest(SECRET).unwrap().unwrap();
        assert_eq!(old["data"]["password"], json!(SECRET_NOT_SHOWN));
        assert_eq!(new["data"]["password"], json!(SECRET_CHANGED_NOT_SHOWN));
        assert_eq!(new["data"]["user"], json!(SECRET_NOT_SHOWN));
    }

    #[test]
    fn the_same_plan_gives_the_same_bytes_and_zstd_reads_them() {
        let (old, new) = sides();
        let bytes = written(&old, &new);
        assert_eq!(bytes, written(&old, &new));
        let (_, files) = parts();
        let file = PlanFile::open(Cursor::new(bytes.as_slice())).unwrap();
        let mut expected = serde_json::to_vec(file.header()).unwrap();
        expected.extend(files.concat());
        assert_eq!(
            zstd::stream::decode_all(bytes.as_slice()).unwrap(),
            expected
        );
    }

    /// Two objects with the same manifest on one side share its file.
    #[test]
    fn equal_manifests_share_a_file() {
        let (old, new) = sides();
        let (header, files) = parts();
        let named: usize = header["shown"]
            .as_object()
            .unwrap()
            .values()
            .map(|s| ["old", "new"].iter().filter(|k| !s[**k].is_null()).count())
            .sum();
        assert_eq!(files.len(), named, "no two sides here are equal");
        let mut twice = new.clone();
        let mut copy = new[3].clone();
        copy["metadata"]["name"] = json!("other");
        twice.push(copy);
        let file = PlanFile::open(Cursor::new(written(&old, &twice))).unwrap();
        assert_eq!(file.header().files.len(), files.len() + 1);
    }

    /// A manifest larger than the 1 MiB frame fill, as a large CRD is, is
    /// kept whole in a frame of its own. One over the apiserver's 3 MiB
    /// request limit, which no cluster can store, is replaced by a size
    /// note, so the plan of such a build can still be saved and read.
    #[test]
    fn a_large_manifest_is_kept_whole_up_to_the_apiservers_limit() {
        let (old, mut new) = sides();
        let config = |text: String| {
            stamped(
                "ConfigMap",
                "app",
                "web",
                ("app", "web"),
                &h("cm2"),
                json!({"k": text}),
            )
        };
        new[3] = config("x".repeat(2 << 20));
        let bytes = written(&old, &new);
        let (mut file, _) = PlanFile::verify(Cursor::new(bytes.as_slice())).unwrap();
        let shown = file.new_manifest("ConfigMap/web@app").unwrap().unwrap();
        assert_eq!(shown, new[3]);
        let table = kix_container::read_table(&mut Cursor::new(&bytes), &LIMITS).unwrap();
        assert!(
            table.frames.len() >= 3,
            "the large file has a frame of its own"
        );
        assert!(
            table
                .frames
                .iter()
                .all(|f| f.size as u64 <= MAX_FRAME_BYTES)
        );

        new[3] = config("x".repeat(MAX_FILE_BYTES as usize));
        let mut file = PlanFile::open(Cursor::new(written(&old, &new))).unwrap();
        let note = file.new_manifest("ConfigMap/web@app").unwrap().unwrap();
        assert!(
            note.as_str()
                .is_some_and(|n| n.ends_with(" bytes, not shown)")),
            "{note}"
        );
    }

    /// Every shown object names the package `plan.packages` lists it
    /// under: a removed package's objects its key, as an added or changed
    /// package's do, and a cluster-level object `_cluster`.
    #[test]
    fn each_shown_object_names_its_package() {
        let packages = |old: &[Value], new: &[Value]| -> BTreeMap<String, String> {
            let file = PlanFile::open(Cursor::new(written(old, new))).unwrap();
            let header = file.into_header();
            header
                .shown
                .into_iter()
                .map(|(id, s)| (id, s.package))
                .collect()
        };
        let (old, new) = sides();
        let changed = packages(&old, &new);
        assert_eq!(changed[DEPLOYMENT], "app/web");
        assert_eq!(changed[SECRET], "app/web");

        // Without the web package, every object of it is removed under its key.
        let mut other = baseline()[..2].to_vec();
        other.push(cluster_level("Namespace", "other", &h("ns2"), json!({})));
        let removed = packages(&old, &other);
        let (plan, _) = plan_at(&old, &other, false);
        assert_eq!(plan.packages.removed[0].key, "app/web");
        for id in ["ConfigMap/web@app", DEPLOYMENT, SECRET] {
            assert_eq!(removed[id], "app/web", "{id}");
        }
        assert_eq!(removed["Namespace/other"], "_cluster");
        let added = packages(&other, &old);
        assert_eq!(added[DEPLOYMENT], "app/web");
    }

    #[test]
    fn a_deployments_pod_template_change_restarts_its_pods() {
        let (old, mut new) = sides();
        let rollout = |old: &[Value], new: &[Value]| {
            let file = PlanFile::open(Cursor::new(written(old, new))).unwrap();
            file.header().shown[DEPLOYMENT].rollout
        };
        assert_eq!(rollout(&old, &new), Some(Rollout::Restart));
        new[4]["spec"]["updateStrategy"] = json!({"type": "OnDelete"});
        assert_eq!(rollout(&old, &new), Some(Rollout::OnDelete));
        new[4]["spec"] = old[4]["spec"].clone();
        new[4]["spec"]["replicas"] = json!(3);
        assert_eq!(rollout(&old, &new), None);
        let file = PlanFile::open(Cursor::new(written(&old, &sides().1))).unwrap();
        assert_eq!(file.header().shown[SECRET].rollout, None);
    }

    /// The graph is what `kix graph -o json` prints.
    #[test]
    fn the_graph_is_kix_graphs_json() {
        let (graph, _) = stamp(&kix_enterprise_test());
        let mut manifests: Vec<Value> = graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect();
        manifests.sort_by_cached_key(crate::eval::cli_backend::manifest_sort_key);
        let resources = ResourceGraph::from_manifests(&manifests).unwrap();
        assert_eq!(
            serde_json::to_value(graph_of(&graph).unwrap()).unwrap(),
            resources.to_json()
        );
        assert!(!resources.listing().edges.is_empty());
    }

    #[test]
    fn a_file_whose_bytes_miss_its_name_is_refused() {
        let (header, mut files) = parts();
        files[0][1] ^= 1;
        let refs: Vec<&[u8]> = files.iter().map(Vec::as_slice).collect();
        let bytes = file_of(&header, &refs);
        let sha = header["files"][0][0].as_str().unwrap().to_string();
        assert_eq!(
            verify(&bytes),
            Err(PlanFileError::FileMismatch(sha.clone()))
        );
        let mut file = PlanFile::open(Cursor::new(bytes.as_slice())).unwrap();
        assert_eq!(file.file(&sha), Err(PlanFileError::FileMismatch(sha)));
    }

    /// A flipped byte past the header's frame is refused, or reads as the
    /// same files: each file is checked against its name. Frames carry no
    /// checksum, so a flip in frame 0 is refused only when it breaks the
    /// header's JSON or rules; the SHA-256 of the whole file, which a deploy
    /// reports and Kix Enterprise binds approvals to, covers every byte.
    #[test]
    fn a_flipped_byte_past_the_header_is_refused_or_reads_the_same() {
        let (old, new) = sides();
        let bytes = written(&old, &new);
        let (_, files) = parts();
        let table = kix_container::read_table(&mut Cursor::new(&bytes), &LIMITS).unwrap();
        let mut refused = 0;
        for at in table.frames[0].stored..bytes.len() {
            let mut changed = bytes.clone();
            changed[at] ^= 0x01;
            let Ok((mut file, sha256)) = PlanFile::verify(Cursor::new(changed.as_slice())) else {
                refused += 1;
                continue;
            };
            assert_ne!(sha256, hex(&Sha256::digest(&bytes)));
            for (i, f) in files.iter().enumerate() {
                assert_eq!(&file.container.file(i).unwrap(), f, "byte {at} flipped");
            }
        }
        assert!(refused > (bytes.len() - table.frames[0].stored) * 9 / 10);
    }

    #[test]
    fn another_format_or_version_or_a_json_plan_is_refused() {
        let (mut header, files) = parts();
        let refs: Vec<&[u8]> = files.iter().map(Vec::as_slice).collect();
        header["version"] = json!(2);
        assert!(matches!(
            verify(&file_of(&header, &refs)),
            Err(PlanFileError::WrongFormat { version: 2, .. })
        ));
        header["version"] = json!(VERSION);
        header["format"] = json!("kix-bundle");
        assert!(matches!(
            verify(&file_of(&header, &refs)),
            Err(PlanFileError::WrongFormat { .. })
        ));
        let (plan, _) = plan_at(&sides().0, &sides().1, false);
        assert_eq!(
            verify(plan.to_json().as_bytes()),
            Err(PlanFileError::NotAPlanFile)
        );
    }

    /// A plan of another schema version is refused by its version, even
    /// when its fields do not parse as this version's.
    #[test]
    fn another_schema_version_is_refused_by_name() {
        let (mut header, files) = parts();
        let refs: Vec<&[u8]> = files.iter().map(Vec::as_slice).collect();
        header["plan"]["schema_version"] = json!("2026-10-07");
        header["plan"]["flags"] = json!({
            "prune": false,
            "prune_mode": null,
            "reconcile": false,
            "force_conflicts": false,
            "accept_migrations": false,
        });
        let err = verify(&file_of(&header, &refs)).unwrap_err();
        assert_eq!(err, PlanFileError::WrongSchema("2026-10-07".into()));
        assert!(
            err.to_string().contains("schema version 2026-10-07"),
            "{err}"
        );
    }

    #[test]
    fn a_header_that_breaks_its_rules_is_malformed() {
        let (header, files) = parts();
        let refs: Vec<&[u8]> = files.iter().map(Vec::as_slice).collect();
        let changed = |change: &dyn Fn(&mut Value)| {
            let mut h = header.clone();
            change(&mut h);
            verify(&file_of(&h, &refs))
        };
        let swap = |h: &mut Value| h["files"].as_array_mut().unwrap().swap(0, 1);
        let unnamed = |h: &mut Value| h["shown"][DEPLOYMENT]["old"] = json!(null);
        let unlisted = |h: &mut Value| h["shown"][DEPLOYMENT]["old"] = json!("0".repeat(64));
        let upper = |h: &mut Value| {
            let sha = h["files"][0][0].as_str().unwrap().to_uppercase();
            h["files"][0][0] = json!(sha);
        };
        for change in [&swap as &dyn Fn(&mut Value), &unnamed, &unlisted, &upper] {
            assert!(matches!(changed(change), Err(PlanFileError::Malformed(_))));
        }
        let extra = |h: &mut Value| h["extra"] = json!(1);
        assert!(matches!(changed(&extra), Err(PlanFileError::Unreadable(_))));
    }

    /// The seek table's sizes are checked before a frame is read, and the
    /// header's counts before it is kept.
    #[test]
    fn a_plan_file_over_a_cap_is_refused_before_it_is_read() {
        let (header, files) = parts();
        let refs: Vec<&[u8]> = files.iter().map(Vec::as_slice).collect();
        let too_large =
            |r: Result<Header, PlanFileError>| matches!(r, Err(PlanFileError::TooLarge(_)));

        // A frame larger than its cap, by the seek table.
        let bytes = file_of(&header, &refs);
        let table = kix_container::read_table(&mut Cursor::new(&bytes), &LIMITS).unwrap();
        let mut sizes: Vec<(u32, u32)> = table
            .frames
            .iter()
            .map(|f| (f.stored as u32, f.size as u32))
            .collect();
        let body = &bytes[..bytes.len() - table.bytes.len()];
        for (frame, cap) in [(0, MAX_HEADER_BYTES), (1, MAX_FRAME_BYTES)] {
            let saved = sizes[frame];
            sizes[frame].1 = cap as u32 + 1;
            let mut over = body.to_vec();
            over.extend(kix_container::seek_table(&sizes));
            assert!(too_large(verify(&over)), "frame {frame}");
            sizes[frame] = saved;
        }

        // A header of many short values.
        let mut many = header.clone();
        many["plan"]["extra"] = json!(vec![0; MAX_HEADER_VALUES]);
        assert!(too_large(verify(&file_of(&many, &refs))));

        // More files than the cap, a file over its size, content over its cap.
        let mut count = header.clone();
        count["files"] = json!(vec![json!(["0".repeat(64), 0]); MAX_FILES + 1]);
        assert!(too_large(verify(&file_of(&count, &refs))));
        let mut big = header.clone();
        big["files"][0][1] = json!(MAX_FILE_BYTES + 1);
        assert!(too_large(verify(&file_of(&big, &refs))));
        let mut content = header;
        content["files"][0][1] = json!(MAX_CONTENT_BYTES + 1);
        assert!(too_large(verify(&file_of(&content, &refs))));
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
            PlanFile::verify(Endless),
            Err(PlanFileError::TooLarge(_))
        ));
    }

    #[test]
    fn writing_names_the_cap_a_plan_passes() {
        let (old, new) = sides();
        let (mut plan, graph) = plan_at(&old, &new, true);
        let huge = "x".repeat(MAX_HEADER_BYTES as usize);
        plan.not_checked
            .push(crate::plan::document::UncheckedObject {
                resource: SECRET.into(),
                reason: crate::plan::document::UncheckedReason::WebhookNoDryRun,
                because: None,
                detail: huge,
            });
        let err = write(plan, graph, io::sink()).unwrap_err();
        assert!(err.to_string().contains("over the 8 MiB limit"), "{err}");
    }
}
