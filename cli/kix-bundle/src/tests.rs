//! Unit tests for reading, writing, and verifying bundles.

use std::io::{self, Cursor, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use kix::eval::store_graph::StoreGraph;
use kix::eval::store_path::{self, Method};
use kix::manifest::{keys, lifecycle};
use kix_container::{hex, read_table, seek_table};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use zstd::zstd_safe;

use super::*;

/// Counts the bytes each test thread has allocated, so a test can bound
/// what a call keeps in memory.
mod allocated {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;

    thread_local! {
        static NOW: Cell<isize> = const { Cell::new(0) };
        static PEAK: Cell<isize> = const { Cell::new(0) };
    }

    struct Counting;

    fn add(bytes: isize) {
        let _ = NOW.try_with(|now| {
            now.set(now.get() + bytes);
            let _ = PEAK.try_with(|peak| peak.set(peak.get().max(now.get())));
        });
    }

    // SAFETY: each method passes its arguments to `System` unchanged.
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            let p = unsafe { System.alloc(layout) };
            if !p.is_null() {
                add(layout.size() as isize);
            }
            p
        }
        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            let p = unsafe { System.alloc_zeroed(layout) };
            if !p.is_null() {
                add(layout.size() as isize);
            }
            p
        }
        unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
            unsafe { System.dealloc(p, layout) };
            add(-(layout.size() as isize));
        }
        unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            let q = unsafe { System.realloc(p, layout, new_size) };
            if !q.is_null() {
                add(new_size as isize - layout.size() as isize);
            }
            q
        }
    }

    #[global_allocator]
    static COUNTING: Counting = Counting;

    /// Run `f` and return its result along with the peak additional bytes
    /// allocated on this thread.
    pub(super) fn peak_during<T>(f: impl FnOnce() -> T) -> (T, usize) {
        let start = NOW.with(Cell::get);
        PEAK.with(|peak| peak.set(start));
        let out = f();
        (out, (PEAK.with(Cell::get) - start).max(0) as usize)
    }
}

const FIXTURE: &[u8] = include_bytes!("../tests/fixtures/kix-enterprise-test.kixbundle");
const STATUS_PAGE: &str = "-k8s-PackageInstance-kix-enterprise-test-web-status-page";
const STATUS_CONFIG: &str = "-k8s-ConfigMap-kix-enterprise-test-web-status-page";

fn read(bytes: &[u8]) -> Result<StoreGraph, BundleError> {
    Bundle::read(Cursor::new(bytes)).map(|(_, graph)| graph)
}

fn checked(bytes: &[u8]) -> Result<PathsChecked<Cursor<&[u8]>>, BundleError> {
    PathsChecked::read(Cursor::new(bytes))
}

/// Load the `kix-enterprise-test` fixture contents (26 manifests and
/// `kix-packages.json`).
fn real() -> Contents {
    OpenBundle::open(Cursor::new(FIXTURE))
        .unwrap()
        .contents()
        .unwrap()
}

#[test]
fn the_libs_fixture_is_this_bundles_build() {
    let mut graph = read(FIXTURE).unwrap();
    let fixture = kix::plan::fixtures::kix_enterprise_test();
    graph.built_via = fixture.built_via.clone();
    assert!(graph == fixture && graph.packages.keys().eq(fixture.packages.keys()));
}

/// A bundle carries the build's warnings to the commands that read it,
/// cleaned as untrusted text. A bundle written without them, as the
/// fixture was, reads with none and writes no `warnings` field.
#[test]
fn a_bundle_carries_the_builds_warnings() {
    let dir = tempfile::tempdir().unwrap();
    let read_warnings = |bytes: &[u8]| {
        let path = dir.path().join("b.kixbundle");
        std::fs::write(&path, bytes).unwrap();
        crate::read_build(&path, &[], "kix-enterprise-test")
            .unwrap()
            .warnings()
            .to_vec()
    };
    assert!(read_warnings(FIXTURE).is_empty());
    let plain = written(&real());
    assert!(!String::from_utf8_lossy(&frames_of(&plain)[0]).contains("warnings"));

    let warning: LibraryRecord = serde_json::from_value(json!({
        "instance": "web/status-page",
        "message": "a warning\u{1b}[2J",
        "fix": "a fix",
    }))
    .unwrap();
    let mut contents = real();
    contents.warnings = vec![warning.clone()];
    // The maker's text arrives with its control characters as code points.
    let read = read_warnings(&written(&contents));
    assert_eq!(read, [warning.printable()]);
    assert_eq!(read[0].message, "a warning⟨U+001B⟩[2J");
}

fn written(contents: &Contents) -> Vec<u8> {
    let mut bytes = Vec::new();
    contents.write(&mut bytes).unwrap();
    bytes
}

/// Verify that [`PathsChecked::read`] and [`Bundle::read`] agree on
/// `contents`, returning the resulting [`StoreGraph`].
fn read_both(contents: &Contents) -> Result<StoreGraph, BundleError> {
    let bytes = written(contents);
    let full = read(&bytes);
    if let Err(e) = checked(&bytes) {
        assert_eq!(full.as_ref().err(), Some(&e), "the readers disagree");
    }
    full
}

/// Assert that [`PathsChecked::read`] accepts `contents` while
/// [`Bundle::read`] rejects it with [`BundleError::Build`], returning the
/// error message.
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

/// Build an import marker in the status page's namespace, matching
/// `scope.mkCRDRef`.
fn marker(name: &str) -> Value {
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": kix::plan::fixtures::PACKAGE_INSTANCE_KIND,
        "metadata": {
            "name": name,
            "namespace": "kix-enterprise-test-web",
            "annotations": {(keys::MODE): "import"},
        },
        "spec": {"instanceName": name},
    })
}

/// Decompress and return every frame of `bundle`, starting with frame 0.
fn frames_of(bundle: &[u8]) -> Vec<Vec<u8>> {
    let table = read_table(&mut Cursor::new(bundle), &LIMITS).unwrap();
    table
        .frames
        .iter()
        .map(|f| {
            let stored = &bundle[f.offset as usize..f.offset as usize + f.stored];
            zstd::bulk::decompress(stored, f.size).unwrap()
        })
        .collect()
}

/// Assemble a seekable bundle from pre-compressed `(frame_bytes,
/// decompressed_size)` pairs.
fn file_of(frames: &[(Vec<u8>, usize)]) -> Vec<u8> {
    let mut out: Vec<u8> = frames.iter().flat_map(|(f, _)| f.clone()).collect();
    let table: Vec<(u32, u32)> = frames
        .iter()
        .map(|(f, n)| (f.len() as u32, *n as u32))
        .collect();
    out.extend(seek_table(&table));
    out
}

/// Compress `frames` and assemble them into a seekable bundle.
fn join(frames: &[Vec<u8>]) -> Vec<u8> {
    let stored: Vec<(Vec<u8>, usize)> = frames
        .iter()
        .map(|f| (zstd::bulk::compress(f, 3).unwrap(), f.len()))
        .collect();
    file_of(&stored)
}

/// Return a copy of `FIXTURE` with `change` applied to its frame 0 JSON
/// header.
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
        graph.built_via,
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
        &include_bytes!("../tests/fixtures/immich.kixbundle")[..],
        &include_bytes!("../tests/fixtures/bundle-alias.kixbundle")[..],
    ] {
        checked(bytes).unwrap();
        read(bytes).unwrap();
    }
}

#[test]
fn writing_is_reproducible_and_round_trips() {
    let contents = real();
    let bytes = written(&contents);
    assert_eq!(bytes, FIXTURE, "the fixture is what Kix writes");
    let mut open = OpenBundle::open(Cursor::new(bytes.as_slice())).unwrap();
    assert_eq!(open.contents().unwrap().files, contents.files);
    assert_eq!(open.header(), &contents.header().unwrap());
}

/// Every fixture is what Kix writes from its contents, byte for
/// byte. A change to the writer that moves one byte changes every
/// bundle's SHA-256, which Kix Enterprise statements name bundles by.
/// `cnpg.kixbundle`, about 2 MB of files, was written by the kix before
/// the container moved to `kix-container`, and holds several data
/// frames, so the 1 MiB frame split is checked too.
#[test]
fn every_fixture_is_written_again_byte_for_byte() {
    let cnpg = &include_bytes!("../tests/fixtures/cnpg.kixbundle")[..];
    assert!(frames_of(cnpg).len() > 3, "cnpg has several data frames");
    for bytes in [
        FIXTURE,
        &include_bytes!("../tests/fixtures/immich.kixbundle")[..],
        &include_bytes!("../tests/fixtures/bundle-alias.kixbundle")[..],
        cnpg,
    ] {
        let contents = OpenBundle::open(Cursor::new(bytes))
            .unwrap()
            .contents()
            .unwrap();
        assert!(
            written(&contents) == bytes,
            "a fixture was written again differently"
        );
    }
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
    assert!(
        message.contains("only valid for an external resource reference"),
        "{message}"
    );
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
        h["files"][1][0] = json!("/nix/store/gqikj37r12iss0zrq8v90xr2qv65qsgj-a b");
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
    let hash = "gqikj37r12iss0zrq8v90xr2qv65qsgj";
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

/// The record must reference the index itself; a Kix library older
/// than this version of Kix builds records that do not, and the error names it.
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
    assert!(err.to_string().contains("Kix library"), "{err}");
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

// Plan and deploy key objects by API group, kind, namespace, and name.
#[test]
fn two_manifests_of_one_object_are_refused() {
    let mut contents = real();
    let config = path_ending(&contents, STATUS_CONFIG);
    let mut copy: Value = serde_json::from_slice(&contents.files[&config].bytes).unwrap();
    copy["data"] = json!({ "other": "content" });
    add_manifest(&mut contents, "k8s-ConfigMap-x", &copy);
    let message = build_error(&contents);
    assert!(message.contains("are both ConfigMap/"), "{message}");
}

/// A kind of the same name in another API group is another object.
#[test]
fn one_kind_name_in_two_groups_is_two_objects() {
    let mut contents = real();
    let config = path_ending(&contents, STATUS_CONFIG);
    let mut other_group: Value = serde_json::from_slice(&contents.files[&config].bytes).unwrap();
    other_group["apiVersion"] = json!("example.com/v1");
    add_manifest(&mut contents, "k8s-ConfigMap-x", &other_group);
    let bytes = written(&contents);
    checked(&bytes).unwrap();
    assert!(!matches!(read(&bytes), Err(BundleError::Build(_))));
}

#[test]
fn a_second_activation_is_refused() {
    let mut contents = real();
    let mut second = configmap("x");
    second["apiVersion"] = json!(keys::API_VERSION);
    second["kind"] = json!(lifecycle::RECORD_KIND);
    add_manifest(&mut contents, "k8s-Activation-x", &second);
    let message = build_error(&contents);
    assert!(
        message.contains("must hold 1 deployment record"),
        "{message}"
    );
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

/// Build a ConfigMap JSON string of roughly `bytes` bytes that expands to
/// roughly 100x its size when parsed.
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
    let (_, parsed) = allocated::peak_during(|| parse_manifest("o", one.as_bytes()));
    let mut contents = real();
    for i in 0..6 {
        let text = configmap_of_objects(&format!("o{i}"), 1 << 20);
        let path = add_file(&mut contents, &format!("k8s-ConfigMap-o{i}"), &text, vec![]);
        list_in_index(&mut contents, STATUS_PAGE, &path);
    }
    let bytes = written(&contents);
    let largest_frame = frames_of(&bytes).iter().map(Vec::len).max().unwrap();
    let (result, peak) = allocated::peak_during(|| checked(&bytes).map(drop));
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
    let (result, peak) = allocated::peak_during(|| checked(&bytes).map(drop));
    result.unwrap();
    assert!(peak < 200 << 20, "checking paths held {} MiB", peak >> 20);
}

/// A header of up to [`MAX_HEADER_BYTES`] that would parse to many
/// times its size, as a long receipt, many empty warnings, many empty
/// files, or one file's long list of references, is refused under the
/// stated bound.
#[test]
fn a_header_that_parses_large_is_refused_under_the_bound() {
    let header = |opening: &str, item: &str, closing: &str| {
        let room = MAX_HEADER_BYTES as usize - 200;
        let items = vec![item; room / (item.len() + 1)].join(",");
        format!(r#"{{"format":"kix-bundle","version":3,"kix_rev":"x",{opening}{items}{closing}}}"#)
    };
    let cases = [
        header(r#""files":[],"receipt":{"source":{"a":["#, "0", "]}}"),
        header(r#""files":[],"warnings":["#, r#"{"message":""}"#, "]"),
        header(r#""files":["#, r#"["",0,[]]"#, "]"),
        header(r#""files":[["",0,["#, "0", "]]]"),
    ];
    let mut frames = frames_of(FIXTURE);
    for text in cases {
        frames[0] = text.into_bytes();
        let bytes = join(&frames);
        let (result, peak) = allocated::peak_during(|| checked(&bytes).map(drop));
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
