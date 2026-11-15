//! A property of every bundle made by changing an honest one: kix refuses
//! it (the reader, the graph, the planning steps or the objects check), or
//! a deploy of it writes and deletes exactly the objects the plan file
//! lists, each one shown under the package the plan names.
//!
//! Each case changes one of the seed bundles in one to four ways and
//! recomputes every store path the change touches, as Nix would, so the
//! case reaches the checks past path verification. It then plans a deploy
//! over one of three old sides (none, the honest build deployed, or the
//! honest build's objects with no build to compare) with one set of flags.
//!
//! What is checked when kix accepts the bundle, computed apart from
//! `kix::plan::objects::of`:
//! - The writes of the engine plan, each matched to the one build file
//!   whose manifest it applies, equal the plan document's `objects.writes`,
//!   and the deletes equal its `objects.deletes`.
//! - Each write the plan does not call a re-apply appears in the package
//!   section the plan names, the plan file (`kix plan --save`) shows it
//!   under that package, and its manifest is the new manifest the file
//!   holds for it. A dep-affected write differs from the deployed
//!   object only in the four propagated annotations.
//! - Each delete is listed as removed: in a changed package's
//!   `removed_resources`, or shown with no new side under a removed
//!   package's key.
//!
//! `PROPTEST_CASES` sets the number of cases (256 by default, about ten
//! seconds in a debug build). A long run:
//! `PROPTEST_CASES=20000 cargo test -p kix-bundle --release --test plan_bound`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use proptest::prelude::*;
use proptest::test_runner::{Config, TestCaseError, TestRunner};
use serde_json::{Value, json};

use kix::cluster::apply::ChangeAction;
use kix::cluster::graph::GraphListing;
use kix::eval::store_graph::{KixPackageIndex, StoreGraph, store_hash};
use kix::eval::store_path::{self, Method};
use kix::manifest::types::ResourceId;
use kix::manifest::{keys, lifecycle};
use kix::plan::baseline::Baseline;
use kix::plan::document::{Build, Detail, KixBuild, MadeBy, NotCheckedReason, Plan, WriteChange};
use kix::plan::file::{self, PlanFile};
use kix::plan::fixtures::{
    self, deletes_of, deployed, deployed_objects, equivalent_to_unset, flags, old_side, plan,
    shown_manifest, stamp,
};
use kix::plan::{CLUSTER_LEVEL_KEY, ManifestIndex, PlanError};
use kix_bundle::{Bundle, BundleError, BundleFile, Contents, INDEX_NAME, Provenance};

/// Honest bundles: the kix-enterprise-test build, and this repository's
/// `bundle-alias` and `immich` test clusters, the second with import
/// markers several packages list.
const SEEDS: &[(&str, &[u8])] = &[
    (
        "kix-enterprise-test",
        include_bytes!("fixtures/kix-enterprise-test.kixbundle"),
    ),
    (
        "bundle-alias",
        include_bytes!("fixtures/bundle-alias.kixbundle"),
    ),
    ("immich", include_bytes!("fixtures/immich.kixbundle")),
];

/// A build as a list of files, which a change edits in place and
/// [`Draft::contents`] turns back into store paths.
#[derive(Clone)]
struct Draft {
    kix_rev: String,
    receipt: Option<Provenance>,
    files: Vec<DraftFile>,
}

#[derive(Clone)]
struct DraftFile {
    /// The hash part of the file's path as the other files' bytes mention
    /// it. [`Draft::contents`] replaces it with the recomputed one.
    hash: String,
    name: String,
    method: Method,
    bytes: Vec<u8>,
    /// Positions in [`Draft::files`].
    refs: Vec<usize>,
}

const BASE32: &[u8] = b"0123456789abcdfghijklmnpqrsvwxyz";

/// A hash part for the `n`th added file, unlike any Nix would make.
fn token(n: usize) -> String {
    let mut digits = Vec::new();
    let mut rest = n;
    loop {
        digits.push(BASE32[rest % 32]);
        rest /= 32;
        if rest == 0 {
            break;
        }
    }
    let digits: String = digits.iter().rev().map(|b| *b as char).collect();
    format!("{digits:z>32}")
}

fn replace_all(bytes: &[u8], from: &[u8], to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i..].starts_with(from) {
            out.extend_from_slice(to);
            i += from.len();
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    out
}

impl Draft {
    fn of(contents: &Contents) -> Self {
        let at: HashMap<&str, usize> = contents
            .files
            .keys()
            .enumerate()
            .map(|(i, p)| (p.as_str(), i))
            .collect();
        let files = contents
            .files
            .iter()
            .map(|(path, file)| DraftFile {
                hash: store_hash(Path::new(path)),
                name: store_path::name_of(path).unwrap().to_string(),
                method: store_path::method_of(path, &file.bytes, &file.references).unwrap(),
                bytes: file.bytes.clone(),
                refs: file.references.iter().map(|r| at[r.as_str()]).collect(),
            })
            .collect();
        Draft {
            kix_rev: contents.kix_rev.clone(),
            receipt: contents.receipt.clone(),
            files,
        }
    }

    fn path(&self, i: usize) -> String {
        format!(
            "{}/{}-{}",
            fixtures::STORE_DIR,
            self.files[i].hash,
            self.files[i].name
        )
    }

    /// The build with every path recomputed from its file, in dependency
    /// order, each file's mention of another's hash part rewritten to the
    /// new one. A file in a cycle keeps the stale hash parts it mentions,
    /// which the reader refuses.
    fn contents(&self) -> Contents {
        let n = self.files.len();
        let by_hash: HashMap<&[u8], usize> = self
            .files
            .iter()
            .enumerate()
            .map(|(i, f)| (f.hash.as_bytes(), i))
            .collect();
        let deps: Vec<BTreeSet<usize>> = self
            .files
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let mentioned = f.bytes.windows(32).filter_map(|w| by_hash.get(w).copied());
                f.refs
                    .iter()
                    .copied()
                    .chain(mentioned)
                    .filter(|j| *j != i)
                    .collect()
            })
            .collect();
        let mut waiting: Vec<usize> = deps.iter().map(BTreeSet::len).collect();
        let mut dependents: Vec<Vec<usize>> = vec![Vec::new(); n];
        for (i, d) in deps.iter().enumerate() {
            for j in d {
                dependents[*j].push(i);
            }
        }
        let mut order: Vec<usize> = (0..n).filter(|i| waiting[*i] == 0).collect();
        let mut next = 0;
        while next < order.len() {
            for &k in &dependents[order[next]] {
                waiting[k] -= 1;
                if waiting[k] == 0 {
                    order.push(k);
                }
            }
            next += 1;
        }
        let placed: BTreeSet<usize> = order.iter().copied().collect();
        order.extend((0..n).filter(|i| !placed.contains(i)));

        let mut paths: Vec<Option<String>> = vec![None; n];
        let mut files = BTreeMap::new();
        for i in order {
            let f = &self.files[i];
            let mut bytes = f.bytes.clone();
            for j in &deps[i] {
                if let Some(new) = &paths[*j] {
                    let new_hash = store_hash(Path::new(new));
                    if new_hash != self.files[*j].hash {
                        bytes = replace_all(
                            &bytes,
                            self.files[*j].hash.as_bytes(),
                            new_hash.as_bytes(),
                        );
                    }
                }
            }
            let references: Vec<String> = f
                .refs
                .iter()
                .map(|j| match &paths[*j] {
                    Some(p) => p.clone(),
                    None if *j == i => self.path(i),
                    None => self.path(*j),
                })
                .collect();
            let path = store_path::path_for(f.method, &bytes, &references, &f.name);
            paths[i] = Some(path.clone());
            files.insert(path, BundleFile { bytes, references });
        }
        Contents {
            kix_rev: self.kix_rev.clone(),
            receipt: self.receipt.clone(),
            files,
        }
    }

    fn add(&mut self, name: &str, bytes: Vec<u8>, refs: Vec<usize>) -> usize {
        let hash = token(self.files.len());
        self.files.push(DraftFile {
            hash,
            name: name.to_string(),
            method: Method::Text,
            bytes,
            refs,
        });
        self.files.len() - 1
    }

    fn manifest(&self, i: usize) -> Option<Value> {
        serde_json::from_slice(&self.files[i].bytes).ok()
    }

    fn set_manifest(&mut self, i: usize, manifest: &Value) {
        self.files[i].bytes = serde_json::to_vec(manifest).unwrap();
    }

    fn index(&self) -> Option<usize> {
        self.files.iter().position(|f| f.name == INDEX_NAME)
    }

    /// The file nothing else references, which the reader takes as the
    /// Activation record.
    fn record(&self) -> Option<usize> {
        let referenced: BTreeSet<usize> = self
            .files
            .iter()
            .enumerate()
            .flat_map(|(i, f)| f.refs.iter().copied().filter(move |j| *j != i))
            .collect();
        (0..self.files.len()).find(|i| !referenced.contains(i))
    }

    /// The manifests, by position: files named `k8s-*`.
    fn manifests(&self) -> Vec<usize> {
        (0..self.files.len())
            .filter(|i| self.files[*i].name.starts_with("k8s-"))
            .collect()
    }

    fn package_index(&self) -> Option<KixPackageIndex> {
        serde_json::from_slice(&self.files[self.index()?].bytes).ok()
    }

    /// Change the index with `change`. The index references each file it
    /// lists when it referenced any before, as kix/lib builds it.
    fn change_index(&mut self, change: impl FnOnce(&mut KixPackageIndex)) {
        let (Some(at), Some(mut index)) = (self.index(), self.package_index()) else {
            return;
        };
        change(&mut index);
        self.files[at].bytes = serde_json::to_vec(&index).unwrap();
        if !self.files[at].refs.is_empty() {
            let by_path: HashMap<String, usize> =
                (0..self.files.len()).map(|i| (self.path(i), i)).collect();
            let listed: BTreeSet<usize> = index
                .packages
                .iter()
                .flat_map(|(pi, resources)| std::iter::once(pi).chain(resources))
                .filter_map(|p| by_path.get(&*p.to_string_lossy()).copied())
                .collect();
            self.files[at].refs = listed.into_iter().collect();
        }
    }

    fn reference_from_record(&mut self, j: usize) {
        if let Some(record) = self.record()
            && record != j
        {
            self.files[record].refs.push(j);
        }
    }
}

fn pick<T: Clone>(items: &[T], i: usize) -> Option<T> {
    (!items.is_empty()).then(|| items[i % items.len()].clone())
}

/// Store names a change gives a file.
const STORE_NAMES: &[&str] = &[
    INDEX_NAME,
    "k8s-Activation-_cluster_-other",
    "activation.json",
    "k8s-ConfigMap-a-b",
    "k8s-",
    "k8s-PackageInstance-a-b",
    "x",
];

/// JSON pointers a change sets or removes in a manifest.
fn fields() -> Vec<String> {
    let mut f: Vec<String> = [
        "/metadata/name",
        "/metadata/namespace",
        "/kind",
        "/apiVersion",
        "/spec/instanceName",
        "/spec/mode",
        "/spec/namespaceName",
        "/spec/instances",
    ]
    .map(String::from)
    .to_vec();
    f.push(format!(
        "/metadata/labels/{}",
        keys::CLUSTER_LABEL.replace('/', "~1")
    ));
    f.push(format!(
        "/metadata/annotations/{}",
        keys::MODE.replace('/', "~1")
    ));
    f
}

/// Values a change sets a field to; `None` removes it.
fn values() -> Vec<Option<Value>> {
    let mut v: Vec<Option<Value>> = [
        "",
        " ",
        ".",
        "..",
        "unknown",
        "_cluster",
        "default",
        "a/b",
        "a%2Fb",
        "x?y",
        "\u{202e}cba",
        "zero\u{200b}width",
        "line\nbreak",
        lifecycle::RECORD_KIND,
        fixtures::PACKAGE_INSTANCE_KIND,
        "ConfigMap",
        "Namespace",
        "Secret",
        keys::API_VERSION,
        "v1",
        "import",
        "shop",
        "cache",
        "landing",
        "kix-enterprise-test",
        "kix-enterprise-test-data",
    ]
    .iter()
    .map(|s| Some(json!(s)))
    .collect();
    v.extend(
        fixtures::legacy_spellings(keys::API_VERSION)
            .into_iter()
            .map(|s| Some(json!(s))),
    );
    v.extend([
        None,
        Some(json!("x".repeat(254))),
        Some(json!(1)),
        Some(Value::Null),
        Some(json!({})),
        Some(json!([])),
        Some(json!({"kix-enterprise-test-data": {"evil": "evil"}})),
    ]);
    v
}

/// Annotation keys a change sets or removes, among them keys that begin
/// with a propagated annotation's.
fn annotations() -> Vec<String> {
    let mut a: Vec<String> = [
        keys::IDENTITY_HASH,
        keys::DEPENDS_ON,
        keys::ACTIVATIONS,
        keys::BUILT_VIA,
        keys::PACKAGE,
        keys::PACKAGE_NAMESPACE,
        keys::MODE,
        fixtures::SOPS_SOURCE,
        fixtures::RERUN,
        "checksum/config",
        "other",
    ]
    .map(String::from)
    .to_vec();
    a.push(format!("{}.x", keys::IDENTITY_HASH));
    a.push(format!("{}.extra", keys::DEPENDS_ON));
    a.extend(fixtures::legacy_spellings(keys::IDENTITY_HASH));
    a
}

/// Objects a change adds: kind, API version, and whether it is namespaced.
const OBJECTS: &[(&str, &str, bool)] = &[
    ("ConfigMap", "v1", true),
    ("Secret", "v1", true),
    ("ClusterRoleBinding", "rbac.authorization.k8s.io/v1", false),
    ("Namespace", "v1", false),
    (fixtures::PACKAGE_INSTANCE_KIND, keys::API_VERSION, true),
    (lifecycle::RECORD_KIND, keys::API_VERSION, false),
    ("CustomResourceDefinition", "apiextensions.k8s.io/v1", false),
    (fixtures::PACKAGE_INSTANCE_KIND, "example.com/v1", true),
    (lifecycle::RECORD_KIND, "example.com/v1", false),
];

#[derive(Debug, Clone)]
enum Change {
    /// A second PackageInstance for an existing one's instance, listed in
    /// the index as a package, holding one of the first's resources, moved
    /// or copied.
    SecondPackageInstance {
        package: usize,
        name: usize,
        moved: bool,
    },
    /// A second `kix-packages.json`, the record referencing it.
    SecondIndex {
        drop_package: usize,
    },
    /// The record listed in the index, as a package or as a resource.
    RecordInIndex {
        as_key: bool,
        package: usize,
    },
    RenameFile {
        file: usize,
        name: usize,
    },
    SetField {
        file: usize,
        field: usize,
        value: usize,
    },
    /// serde_json's reserved RawValue key, at the top or under metadata.
    RawValueKey {
        file: usize,
        top: bool,
    },
    /// A manifest's key given twice, the second time with another value.
    DuplicateKey {
        file: usize,
        field: usize,
        value: usize,
    },
    ShareListing {
        from: usize,
        entry: usize,
        to: usize,
    },
    MoveListing {
        from: usize,
        entry: usize,
        to: usize,
    },
    DropListing {
        package: usize,
        entry: usize,
    },
    AddListing {
        file: usize,
        package: usize,
    },
    DropPackage {
        package: usize,
        from_record: bool,
    },
    /// A new object, referenced by the record or by another file, and
    /// listed under a package or not.
    AddObject {
        object: usize,
        name: usize,
        namespace: usize,
        listed: Option<usize>,
        referenced_by: Option<usize>,
    },
    /// A copy of the record under another name, referenced by the record
    /// or by nothing.
    SecondRecord {
        referenced: bool,
        name: usize,
    },
    AddReference {
        file: usize,
        to: usize,
    },
    DropReference {
        file: usize,
        entry: usize,
    },
    SetAnnotation {
        file: usize,
        key: usize,
        value: usize,
    },
    /// A manifest made the same object as another: kind, namespace, name.
    /// With `default`, a namespace of `default` is dropped and a missing
    /// one becomes `default`: another id for the same live object.
    CopyIdentity {
        file: usize,
        from: usize,
        default: bool,
    },
    /// The record's `spec.instances` gains or loses an instance.
    RecordInstance {
        add: bool,
        package: usize,
        name: usize,
    },
    /// A manifest's list of two or more items, such as `args` or `env`,
    /// reversed.
    ReverseList {
        file: usize,
        list: usize,
    },
}

fn change() -> impl Strategy<Value = Change> {
    let n = any::<usize>;
    prop_oneof![
        (n(), n(), any::<bool>()).prop_map(|(package, name, moved)| {
            Change::SecondPackageInstance {
                package,
                name,
                moved,
            }
        }),
        n().prop_map(|drop_package| Change::SecondIndex { drop_package }),
        (any::<bool>(), n())
            .prop_map(|(as_key, package)| Change::RecordInIndex { as_key, package }),
        (n(), n()).prop_map(|(file, name)| Change::RenameFile { file, name }),
        (n(), n(), n()).prop_map(|(file, field, value)| Change::SetField { file, field, value }),
        (n(), any::<bool>()).prop_map(|(file, top)| Change::RawValueKey { file, top }),
        (n(), n(), n()).prop_map(|(file, field, value)| Change::DuplicateKey {
            file,
            field,
            value
        }),
        (n(), n(), n()).prop_map(|(from, entry, to)| Change::ShareListing { from, entry, to }),
        (n(), n(), n()).prop_map(|(from, entry, to)| Change::MoveListing { from, entry, to }),
        (n(), n()).prop_map(|(package, entry)| Change::DropListing { package, entry }),
        (n(), n()).prop_map(|(file, package)| Change::AddListing { file, package }),
        (n(), any::<bool>()).prop_map(|(package, from_record)| Change::DropPackage {
            package,
            from_record
        }),
        (
            n(),
            n(),
            n(),
            proptest::option::of(n()),
            proptest::option::of(n())
        )
            .prop_map(|(object, name, namespace, listed, referenced_by)| {
                Change::AddObject {
                    object,
                    name,
                    namespace,
                    listed,
                    referenced_by,
                }
            }),
        (any::<bool>(), n())
            .prop_map(|(referenced, name)| Change::SecondRecord { referenced, name }),
        (n(), n()).prop_map(|(file, to)| Change::AddReference { file, to }),
        (n(), n()).prop_map(|(file, entry)| Change::DropReference { file, entry }),
        (n(), n(), n()).prop_map(|(file, key, value)| Change::SetAnnotation { file, key, value }),
        (n(), n(), any::<bool>()).prop_map(|(file, from, default)| Change::CopyIdentity {
            file,
            from,
            default
        }),
        (any::<bool>(), n(), n()).prop_map(|(add, package, name)| Change::RecordInstance {
            add,
            package,
            name
        }),
        (n(), n()).prop_map(|(file, list)| Change::ReverseList { file, list }),
    ]
}

/// Set `pointer` in `v` to `value`, making the objects on the way, or
/// remove it when `value` is `None`.
fn set_pointer(v: &mut Value, pointer: &str, value: Option<Value>) {
    let parts: Vec<String> = pointer
        .split('/')
        .skip(1)
        .map(|p| p.replace("~1", "/").replace("~0", "~"))
        .collect();
    let (last, path) = parts.split_last().unwrap();
    let mut at = v;
    for p in path {
        if !at.get(p).is_some_and(Value::is_object) {
            if value.is_none() {
                return;
            }
            if let Some(o) = at.as_object_mut() {
                o.insert(p.clone(), json!({}));
            } else {
                return;
            }
        }
        at = at.get_mut(p).unwrap();
    }
    if let Some(o) = at.as_object_mut() {
        match value {
            Some(value) => {
                o.insert(last.clone(), value);
            }
            None => {
                o.remove(last);
            }
        }
    }
}

fn apply(draft: &mut Draft, change: &Change) {
    let manifests = draft.manifests();
    let values = values();
    let packages: Vec<(PathBuf, Vec<PathBuf>)> = draft
        .package_index()
        .map(|i| i.packages.into_iter().collect())
        .unwrap_or_default();
    let by_path: HashMap<String, usize> =
        (0..draft.files.len()).map(|i| (draft.path(i), i)).collect();
    let position = |p: &Path| by_path.get(&*p.to_string_lossy()).copied();
    match change {
        Change::SecondPackageInstance {
            package,
            name,
            moved,
        } => {
            let Some((pi, resources)) = pick(&packages, *package) else {
                return;
            };
            let Some(at) = position(&pi) else { return };
            let Some(mut manifest) = draft.manifest(at) else {
                return;
            };
            let names = ["second", "", "unknown"];
            let new_name = names[name % names.len()];
            set_pointer(&mut manifest, "/metadata/name", Some(json!(new_name)));
            let refs = draft.files[at].refs.clone();
            let file_name = format!("{}-{new_name}", draft.files[at].name);
            let copy = draft.add(&file_name, serde_json::to_vec(&manifest).unwrap(), refs);
            draft.reference_from_record(copy);
            let copy_path = PathBuf::from(draft.path(copy));
            let taken = resources.into_iter().find(|r| *r != pi);
            draft.change_index(|index| {
                if let (Some(taken), true) = (&taken, *moved) {
                    index.packages[&pi].retain(|r| r != taken);
                }
                let mut listed: Vec<PathBuf> = taken.into_iter().collect();
                listed.push(copy_path.clone());
                index.packages.insert(copy_path, listed);
            });
        }
        Change::SecondIndex { drop_package } => {
            let Some(at) = draft.index() else { return };
            let Some(mut index) = draft.package_index() else {
                return;
            };
            if !index.packages.is_empty() {
                let k = drop_package % index.packages.len();
                index.packages.shift_remove_index(k);
            }
            let refs = draft.files[at].refs.clone();
            let second = draft.add(INDEX_NAME, serde_json::to_vec(&index).unwrap(), refs);
            draft.reference_from_record(second);
        }
        Change::RecordInIndex { as_key, package } => {
            let Some(record) = draft.record() else { return };
            let record = PathBuf::from(draft.path(record));
            draft.change_index(|index| {
                if *as_key {
                    index.packages.insert(record.clone(), vec![record]);
                } else if !index.packages.is_empty() {
                    let k = package % index.packages.len();
                    index.packages[k].push(record);
                }
            });
        }
        Change::RenameFile { file, name } => {
            if let Some(i) = pick(&(0..draft.files.len()).collect::<Vec<_>>(), *file) {
                draft.files[i].name = STORE_NAMES[name % STORE_NAMES.len()].to_string();
            }
        }
        Change::SetField { file, field, value } => {
            let Some(i) = pick(&manifests, *file) else {
                return;
            };
            let Some(mut manifest) = draft.manifest(i) else {
                return;
            };
            set_pointer(
                &mut manifest,
                &fields()[field % fields().len()],
                values[value % values.len()].clone(),
            );
            draft.set_manifest(i, &manifest);
        }
        Change::RawValueKey { file, top } => {
            let Some(i) = pick(&manifests, *file) else {
                return;
            };
            let Some(mut manifest) = draft.manifest(i) else {
                return;
            };
            let raw =
                json!({"$serde_json::private::RawValue": "{\"kind\":\"ClusterRoleBinding\"}"});
            if *top {
                manifest = raw;
            } else {
                set_pointer(&mut manifest, "/metadata/labels", Some(raw));
            }
            draft.set_manifest(i, &manifest);
        }
        Change::DuplicateKey { file, field, value } => {
            let Some(i) = pick(&manifests, *file) else {
                return;
            };
            let keys = [
                ("{", "kind"),
                ("\"metadata\":{", "name"),
                ("\"metadata\":{", "namespace"),
                ("\"spec\":{", "instanceName"),
            ];
            let (after, key) = keys[field % keys.len()];
            let Some(Some(value)) = values.get(value % values.len()).cloned() else {
                return;
            };
            let text = String::from_utf8_lossy(&draft.files[i].bytes).into_owned();
            let Some(at) = text.find(after) else { return };
            let at = at + after.len();
            let inserted = format!("\"{key}\":{value},");
            let mut changed = text.clone();
            changed.insert_str(at, &inserted);
            draft.files[i].bytes = changed.into_bytes();
        }
        Change::ShareListing { from, entry, to } | Change::MoveListing { from, entry, to } => {
            let Some((from_pi, resources)) = pick(&packages, *from) else {
                return;
            };
            let Some(resource) = pick(&resources, *entry) else {
                return;
            };
            let Some((to_pi, _)) = pick(&packages, *to) else {
                return;
            };
            let moving = matches!(change, Change::MoveListing { .. });
            draft.change_index(|index| {
                if moving {
                    index.packages[&from_pi].retain(|r| *r != resource);
                }
                index.packages[&to_pi].push(resource);
            });
        }
        Change::DropListing { package, entry } => {
            let Some((pi, resources)) = pick(&packages, *package) else {
                return;
            };
            let Some(resource) = pick(&resources, *entry) else {
                return;
            };
            draft.change_index(|index| index.packages[&pi].retain(|r| *r != resource));
        }
        Change::AddListing { file, package } => {
            let Some((pi, _)) = pick(&packages, *package) else {
                return;
            };
            let Some(i) = pick(&(0..draft.files.len()).collect::<Vec<_>>(), *file) else {
                return;
            };
            let path = PathBuf::from(draft.path(i));
            draft.change_index(|index| index.packages[&pi].push(path));
        }
        Change::DropPackage {
            package,
            from_record,
        } => {
            let Some((pi, _)) = pick(&packages, *package) else {
                return;
            };
            if *from_record
                && let Some(at) = position(&pi)
                && let Some(manifest) = draft.manifest(at)
                && let Some(record) = draft.record()
                && let Some(mut record_manifest) = draft.manifest(record)
            {
                let namespace = manifest
                    .pointer("/metadata/namespace")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let instance = manifest
                    .pointer("/spec/instanceName")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if let Some(instances) = record_manifest
                    .pointer_mut(&format!("/spec/instances/{namespace}"))
                    .and_then(Value::as_object_mut)
                {
                    instances.remove(instance);
                }
                draft.set_manifest(record, &record_manifest);
            }
            draft.change_index(|index| {
                index.packages.shift_remove(&pi);
            });
        }
        Change::AddObject {
            object,
            name,
            namespace,
            listed,
            referenced_by,
        } => {
            let (kind, api_version, namespaced) = OBJECTS[object % OBJECTS.len()];
            let names = ["added", "shop", "cache", "unknown", "kix-enterprise-test"];
            let name = names[name % names.len()];
            let namespaces = [
                "kix-enterprise-test-data",
                "kix-enterprise-test-web",
                "default",
                "other",
            ];
            let namespace = namespaces[namespace % namespaces.len()];
            let mut manifest = json!({
                "apiVersion": api_version,
                "kind": kind,
                "metadata": {"name": name},
            });
            if namespaced {
                manifest["metadata"]["namespace"] = json!(namespace);
            }
            if kind == fixtures::PACKAGE_INSTANCE_KIND {
                manifest["spec"] = json!({"instanceName": name, "namespaceName": namespace});
            }
            if kind == lifecycle::RECORD_KIND {
                manifest["metadata"]["labels"] =
                    json!({(keys::CLUSTER_LABEL): "kix-enterprise-test"});
            }
            let file_name = format!(
                "k8s-{kind}-{}-{name}",
                if namespaced { namespace } else { "_cluster_" }
            );
            let added = draft.add(
                &file_name,
                serde_json::to_vec(&manifest).unwrap(),
                Vec::new(),
            );
            match referenced_by.and_then(|r| pick(&(0..added).collect::<Vec<_>>(), r)) {
                Some(by) => draft.files[by].refs.push(added),
                None => draft.reference_from_record(added),
            }
            if let Some((pi, _)) = listed.and_then(|p| pick(&packages, p)) {
                let path = PathBuf::from(draft.path(added));
                draft.change_index(|index| index.packages[&pi].push(path));
            }
        }
        Change::SecondRecord { referenced, name } => {
            let Some(record) = draft.record() else { return };
            let Some(mut manifest) = draft.manifest(record) else {
                return;
            };
            let names = ["second", "kix-enterprise-test", ""];
            set_pointer(
                &mut manifest,
                "/metadata/name",
                Some(json!(names[name % names.len()])),
            );
            let refs = draft.files[record].refs.clone();
            let file_name = format!("{}-second", draft.files[record].name);
            let second = draft.add(&file_name, serde_json::to_vec(&manifest).unwrap(), refs);
            if *referenced {
                draft.files[record].refs.push(second);
            }
        }
        Change::AddReference { file, to } => {
            let all: Vec<usize> = (0..draft.files.len()).collect();
            if let (Some(i), Some(j)) = (pick(&all, *file), pick(&all, *to)) {
                draft.files[i].refs.push(j);
                draft.files[i].refs.sort_unstable();
                draft.files[i].refs.dedup();
            }
        }
        Change::DropReference { file, entry } => {
            let all: Vec<usize> = (0..draft.files.len()).collect();
            if let Some(i) = pick(&all, *file)
                && !draft.files[i].refs.is_empty()
            {
                let k = entry % draft.files[i].refs.len();
                draft.files[i].refs.remove(k);
            }
        }
        Change::SetAnnotation { file, key, value } => {
            let Some(i) = pick(&manifests, *file) else {
                return;
            };
            let Some(mut manifest) = draft.manifest(i) else {
                return;
            };
            let annotations = annotations();
            let key = annotations[key % annotations.len()].replace('/', "~1");
            let value = match value % 3 {
                0 => Some(json!("changed")),
                1 => Some(json!(draft.path(value % draft.files.len()))),
                _ => None,
            };
            set_pointer(
                &mut manifest,
                &format!("/metadata/annotations/{key}"),
                value,
            );
            draft.set_manifest(i, &manifest);
        }
        Change::CopyIdentity {
            file,
            from,
            default,
        } => {
            let (Some(i), Some(j)) = (pick(&manifests, *file), pick(&manifests, *from)) else {
                return;
            };
            let (Some(mut manifest), Some(other)) = (draft.manifest(i), draft.manifest(j)) else {
                return;
            };
            for pointer in [
                "/kind",
                "/apiVersion",
                "/metadata/name",
                "/metadata/namespace",
            ] {
                set_pointer(&mut manifest, pointer, other.pointer(pointer).cloned());
            }
            if *default {
                let namespace = match other.pointer("/metadata/namespace") {
                    None => Some(json!("default")),
                    Some(ns) if ns == "default" => None,
                    Some(ns) => Some(ns.clone()),
                };
                set_pointer(&mut manifest, "/metadata/namespace", namespace);
            }
            draft.set_manifest(i, &manifest);
        }
        Change::RecordInstance { add, package, name } => {
            let Some(record) = draft.record() else { return };
            let Some(mut manifest) = draft.manifest(record) else {
                return;
            };
            let Some(instances) = manifest
                .pointer_mut("/spec/instances")
                .and_then(Value::as_object_mut)
            else {
                return;
            };
            let namespaces: Vec<String> = instances.keys().cloned().collect();
            let Some(namespace) = pick(&namespaces, *package) else {
                return;
            };
            let Some(names) = instances.get_mut(&namespace).and_then(Value::as_object_mut) else {
                return;
            };
            if *add {
                let added = ["added", "unknown", ""][name % 3];
                names.insert(added.to_string(), json!(added));
            } else {
                let present: Vec<String> = names.keys().cloned().collect();
                if let Some(gone) = pick(&present, *name) {
                    names.remove(&gone);
                }
            }
            draft.set_manifest(record, &manifest);
        }
        Change::ReverseList { file, list } => {
            let Some(i) = pick(&manifests, *file) else {
                return;
            };
            let Some(mut manifest) = draft.manifest(i) else {
                return;
            };
            let mut found = Vec::new();
            lists(&manifest, "", &mut found);
            let Some(pointer) = pick(&found, *list) else {
                return;
            };
            if let Some(Value::Array(items)) = manifest.pointer_mut(&pointer) {
                items.reverse();
            }
            draft.set_manifest(i, &manifest);
        }
    }
}

/// JSON pointers to the lists in `v`, at `at`, that hold two or more items.
fn lists(v: &Value, at: &str, found: &mut Vec<String>) {
    match v {
        Value::Object(o) => {
            for (k, child) in o {
                let k = k.replace('~', "~0").replace('/', "~1");
                lists(child, &format!("{at}/{k}"), found);
            }
        }
        Value::Array(a) => {
            if a.len() >= 2 {
                found.push(at.to_string());
            }
            for (j, child) in a.iter().enumerate() {
                lists(child, &format!("{at}/{j}"), found);
            }
        }
        _ => {}
    }
}

/// `bundle` with its header's fields written in another order: the order
/// of `fields` after rotating it by `turn`.
fn reorder_header(bundle: &[u8], turn: usize) -> Vec<u8> {
    let u32_at = |at: usize| u32::from_le_bytes(bundle[at..at + 4].try_into().unwrap());
    let footer = bundle.len() - 9;
    let frames = u32_at(footer) as usize;
    let table = footer - 8 * frames;
    let sizes: Vec<(usize, usize)> = (0..frames)
        .map(|k| {
            (
                u32_at(table + 8 * k) as usize,
                u32_at(table + 8 * k + 4) as usize,
            )
        })
        .collect();
    let (stored, size) = sizes[0];
    let header = zstd::bulk::decompress(&bundle[..stored], size).unwrap();
    let header: serde_json::Map<String, Value> = serde_json::from_slice(&header).unwrap();
    let mut fields: Vec<(&String, &Value)> = header.iter().collect();
    let len = fields.len();
    fields.rotate_left(turn % len);
    let text = format!(
        "{{{}}}",
        fields
            .iter()
            .map(|(k, v)| format!("{}:{}", json!(k), v))
            .collect::<Vec<_>>()
            .join(",")
    );
    let mut c = zstd::bulk::Compressor::new(3).unwrap();
    c.include_contentsize(true).unwrap();
    let frame = c.compress(text.as_bytes()).unwrap();
    let skippable_start = table - 8;
    let mut out = frame.clone();
    out.extend_from_slice(&bundle[stored..skippable_start]);
    let mut entries = vec![(frame.len() as u32, text.len() as u32)];
    entries.extend(sizes[1..].iter().map(|(s, d)| (*s as u32, *d as u32)));
    out.extend(0x184D_2A5Eu32.to_le_bytes());
    out.extend((8 * entries.len() as u32 + 9).to_le_bytes());
    for (s, d) in &entries {
        out.extend(s.to_le_bytes());
        out.extend(d.to_le_bytes());
    }
    out.extend((entries.len() as u32).to_le_bytes());
    out.push(0);
    out.extend(0x8F92_EAB1u32.to_le_bytes());
    out
}

/// What the cluster runs before the deploy.
#[derive(Debug, Clone, Copy)]
enum OldSide {
    /// Nothing: a first deploy.
    Nothing,
    /// The honest build, its graph at hand.
    Deployed,
    /// The honest build's objects, with no graph to compare: the plan
    /// synthesizes one.
    ObjectsOnly,
}

const FLAG_SETS: &[&[&str]] = &[
    &[],
    &["--prune"],
    &["--reconcile"],
    &["--prune", "--reconcile"],
];

#[derive(Debug, Clone)]
struct Case {
    seed: usize,
    changes: Vec<Change>,
    reorder: Option<usize>,
    old: OldSide,
    flags: usize,
}

fn case() -> impl Strategy<Value = Case> {
    (
        0..SEEDS.len(),
        proptest::collection::vec(change(), 1..=4),
        proptest::option::weighted(0.1, any::<usize>()),
        prop_oneof![
            Just(OldSide::Nothing),
            Just(OldSide::Deployed),
            Just(OldSide::ObjectsOnly)
        ],
        0..FLAG_SETS.len(),
    )
        .prop_map(|(seed, changes, reorder, old, flags)| Case {
            seed,
            changes,
            reorder,
            old,
            flags,
        })
}

/// Where a case stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
enum Outcome {
    ReaderRefused,
    GraphRefused,
    PlanningRefused,
    ObjectsRefused,
    Checked,
}

/// A manifest without the annotations a dependency's change propagates,
/// and without the fields the plan's diff reads as absent
/// (`equivalent_to_unset`: null, an empty list, a server default).
fn without_propagation(manifest: &Value) -> Value {
    fn drop_unset(v: &mut Value, path: &str) {
        match v {
            Value::Object(o) => {
                o.retain(|k, v| !equivalent_to_unset(&format!("{path}.{k}"), v));
                for (k, v) in o.iter_mut() {
                    drop_unset(v, &format!("{path}.{k}"));
                }
            }
            Value::Array(a) => a
                .iter_mut()
                .for_each(|v| drop_unset(v, &format!("{path}[]"))),
            _ => {}
        }
    }
    let mut m = manifest.clone();
    drop_unset(&mut m, "$");
    if let Some(annotations) = m
        .pointer_mut("/metadata/annotations")
        .and_then(Value::as_object_mut)
    {
        for key in [
            keys::IDENTITY_HASH,
            keys::DEPENDS_ON,
            keys::ACTIVATIONS,
            keys::BUILT_VIA,
        ] {
            annotations.remove(key);
            for legacy in fixtures::legacy_spellings(key) {
                annotations.remove(&legacy);
            }
        }
    }
    m
}

/// Plan a deploy of `new` over `old` with `flags`, as `kix::plan::Planner`
/// does before it reads the cluster, and check what it would write and
/// delete against the plan. `Err` is a violation of the property.
fn plan_and_check(
    new: &StoreGraph,
    honest: &StoreGraph,
    old: OldSide,
    extra: &[&str],
) -> Result<Outcome, String> {
    let flags = flags(extra);
    let (new_graph, _) = stamp(new);
    let (_, honest_manifests) = stamp(honest);
    let baseline: Baseline = match old {
        OldSide::Nothing => deployed(None),
        OldSide::Deployed => deployed(Some(honest)),
        OldSide::ObjectsOnly => deployed_objects(honest_manifests),
    };
    let checked = match plan(&baseline, new, flags) {
        Ok(checked) => checked,
        Err(PlanError::Graph(_) | PlanError::Marker(_) | PlanError::AliasedMove(_)) => {
            return Ok(Outcome::PlanningRefused);
        }
        Err(PlanError::Unshown(_)) => return Ok(Outcome::ObjectsRefused),
        Err(e) => return Err(format!("the plan failed: {e}")),
    };
    let (plan, pkg_diff, objects) = (checked.plan(), checked.pkg_diff(), checked.objects());
    let deletes = deletes_of(flags.prune, checked.orphans());
    let (old_graph, active_manifests) = old_side(&baseline, &new_graph);

    // What the deploy writes, each matched to the build file whose
    // manifest it applies.
    let mut written: BTreeMap<(String, String, String, String), &Value> = BTreeMap::new();
    for node in plan.nodes() {
        let (id, files): (ResourceId, Vec<(&PathBuf, &Value)>) = match (&node.action, &node.rerun) {
            (ChangeAction::Apply(m) | ChangeAction::Recreate(m, _), _) => (
                ResourceId::from_value(m),
                new_graph
                    .resources
                    .iter()
                    .filter(|(_, r)| r.manifest == *m)
                    .map(|(p, r)| (p, &r.manifest))
                    .collect(),
            ),
            (ChangeAction::Skip(id), Some(_)) => (
                id.clone(),
                new_graph
                    .resources
                    .iter()
                    .filter(|(_, r)| ResourceId::from_value(&r.manifest) == *id)
                    .map(|(p, r)| (p, &r.manifest))
                    .collect(),
            ),
            _ => continue,
        };
        let [(path, manifest)] = files[..] else {
            return Err(format!(
                "the deploy writes {} from {} build files",
                id.display_id(),
                files.len()
            ));
        };
        let key = (id.kind, id.namespace, id.name, store_hash(path));
        if written.insert(key.clone(), manifest).is_some() {
            return Err(format!("the deploy writes {key:?} twice"));
        }
    }
    let listed: BTreeMap<(String, String, String, String), (&str, WriteChange)> = objects
        .writes
        .iter()
        .map(|w| {
            (
                (
                    w.kind.clone(),
                    w.namespace.clone(),
                    w.name.clone(),
                    w.store_hash.clone(),
                ),
                (w.package.as_str(), w.change),
            )
        })
        .collect();
    if listed.len() != objects.writes.len() || !written.keys().eq(listed.keys()) {
        return Err(format!(
            "the deploy writes {:?}; the plan lists {:?}",
            written.keys().collect::<Vec<_>>(),
            listed.keys().collect::<Vec<_>>()
        ));
    }
    let deleted: BTreeSet<ResourceId> = deletes.iter().cloned().collect();
    let listed_deletes: BTreeSet<ResourceId> = objects
        .deletes
        .iter()
        .map(|d| ResourceId {
            group: d.group.clone(),
            kind: d.kind.clone(),
            namespace: d.namespace.clone(),
            name: d.name.clone(),
        })
        .collect();
    if deleted != listed_deletes || deleted.len() != deletes.len() {
        return Err(format!(
            "the deploy deletes {deleted:?}; the plan lists {listed_deletes:?}"
        ));
    }

    // Each listed write and delete, as the plan file shows it.
    let index = ManifestIndex::new(&old_graph, &new_graph);
    let document = Plan::new(
        KixBuild {
            version: "test".into(),
            store_path: None,
        },
        MadeBy::Builds,
        &new_graph.cluster_name,
        Build::of(&new_graph),
        pkg_diff,
        Detail::Manifests(&index),
        &[],
        NotCheckedReason::BuildsOnly,
    );
    let empty = GraphListing {
        nodes: vec![],
        edges: vec![],
    };
    let mut bytes = Vec::new();
    file::write(document, empty, &mut bytes).map_err(|e| format!("writing the plan: {e}"))?;
    let (mut plan_file, _) =
        PlanFile::verify(Cursor::new(bytes)).map_err(|e| format!("reading the plan: {e}"))?;
    let doc = plan_file.header().plan.packages.clone();
    let old_of = |id: &ResourceId| {
        old_graph
            .resources
            .values()
            .map(|r| &r.manifest)
            .find(|m| ResourceId::from_value(m) == *id)
    };
    for ((kind, namespace, name, hash), manifest) in &written {
        let id = ResourceId::from_value(manifest);
        let shown_id = id.display_id();
        let (package, change) =
            listed[&(kind.clone(), namespace.clone(), name.clone(), hash.clone())];
        let old = old_of(&id);
        let expected = shown_manifest(manifest, old);
        let shown_new = plan_file
            .new_manifest(&shown_id)
            .map_err(|e| format!("reading {shown_id}: {e}"))?;
        let shown_under = plan_file
            .header()
            .shown
            .get(&shown_id)
            .map(|s| s.package.as_str());
        let shows = || shown_new.as_ref() == Some(&expected) && shown_under == Some(package);
        let ok = match change {
            WriteChange::Reapplied | WriteChange::IfLastRunFailed => {
                active_manifests.iter().any(|m| {
                    ResourceId::from_value(m) == id
                        && keys::get(m, keys::IDENTITY_HASH) == Some(hash.as_str())
                })
            }
            _ if lifecycle::is_record_kind(kind) => {
                package == CLUSTER_LEVEL_KEY
                    && doc.activation.as_ref().and_then(|a| a.new.as_deref()) == Some(name.as_str())
            }
            WriteChange::Added if doc.added.iter().any(|p| p.key == package) => {
                doc.added.iter().any(|p| p.key == package && shows())
            }
            WriteChange::Added | WriteChange::Modified | WriteChange::DepAffected => {
                let changed = doc
                    .changed
                    .iter()
                    .chain(doc.cluster_level.iter())
                    .find(|c| c.key == package);
                match (changed, change) {
                    (Some(c), WriteChange::Added) => {
                        c.added_resources.contains(&shown_id) && shows()
                    }
                    (Some(c), WriteChange::Modified) => {
                        c.modified_resources.iter().any(|r| r.resource == shown_id) && shows()
                    }
                    (Some(c), WriteChange::DepAffected) => {
                        c.dep_affected_resources.contains(&shown_id)
                            && old.is_some_and(|o| {
                                without_propagation(o) == without_propagation(manifest)
                            })
                    }
                    _ => false,
                }
            }
        };
        if !ok {
            return Err(format!(
                "the deploy writes {shown_id} (store hash {hash}), listed as {change:?} under {package}, \
                 and the plan file does not show it so. Deployed: {}. Written: {}",
                old.map_or("none".to_string(), |o| without_propagation(o).to_string()),
                without_propagation(manifest),
            ));
        }
    }
    for id in &deleted {
        let shown_id = id.display_id();
        let removed_package = plan_file.header().shown.get(&shown_id).is_some_and(|s| {
            s.old.is_some() && s.new.is_none() && doc.removed.iter().any(|p| p.key == s.package)
        });
        let removed_resource = doc
            .changed
            .iter()
            .chain(doc.cluster_level.iter())
            .any(|c| c.removed_resources.contains(&shown_id));
        if !removed_package && !removed_resource {
            return Err(format!(
                "the deploy deletes {shown_id}, which the plan file does not list as removed"
            ));
        }
    }
    Ok(Outcome::Checked)
}

fn run(case: &Case, honest: &[(Contents, StoreGraph)]) -> Result<Outcome, String> {
    let (contents, honest_graph) = &honest[case.seed];
    let mut draft = Draft::of(contents);
    for change in &case.changes {
        apply(&mut draft, change);
    }
    let mut bytes = Vec::new();
    if draft.contents().write(&mut bytes).is_err() {
        return Ok(Outcome::ReaderRefused);
    }
    if let Some(turn) = case.reorder {
        bytes = reorder_header(&bytes, turn);
    }
    let graph = match Bundle::read(Cursor::new(bytes.as_slice())) {
        Ok((_, graph)) => graph,
        Err(BundleError::Build(_)) => return Ok(Outcome::GraphRefused),
        Err(_) => return Ok(Outcome::ReaderRefused),
    };
    plan_and_check(&graph, honest_graph, case.old, FLAG_SETS[case.flags])
}

/// Each seed reads and plans unchanged, and its draft rebuilds it to the
/// same bytes, so a refused case is refused for its changes.
#[test]
fn every_seed_reads_and_rebuilds_unchanged() {
    for (name, bytes) in SEEDS {
        let (mut bundle, graph) =
            Bundle::read(Cursor::new(*bytes)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let contents = bundle.contents().unwrap();
        assert_eq!(
            Draft::of(&contents).contents().files,
            contents.files,
            "{name}"
        );
        for old in [OldSide::Nothing, OldSide::Deployed, OldSide::ObjectsOnly] {
            for flags in FLAG_SETS {
                assert_eq!(
                    plan_and_check(&graph, &graph, old, flags),
                    Ok(Outcome::Checked),
                    "{name} over {old:?} with {flags:?}"
                );
            }
        }
        let reordered = reorder_header(bytes, 1);
        assert!(
            Bundle::read(Cursor::new(reordered.as_slice())).is_ok(),
            "{name}"
        );
    }
}

#[test]
// The case counts show how far the cases reached, under `--nocapture`.
#[allow(clippy::print_stderr)]
fn a_changed_bundle_is_refused_or_deploys_what_its_plan_shows() {
    let honest: Vec<(Contents, StoreGraph)> = SEEDS
        .iter()
        .map(|(_, bytes)| {
            let (mut bundle, graph) = Bundle::read(Cursor::new(*bytes)).unwrap();
            (bundle.contents().unwrap(), graph)
        })
        .collect();
    let counts: Vec<AtomicUsize> = (0..5).map(|_| AtomicUsize::new(0)).collect();
    let mut runner = TestRunner::new(Config {
        failure_persistence: None,
        ..Config::default()
    });
    let result = runner.run(&case(), |case| {
        let outcome = run(&case, &honest).map_err(TestCaseError::fail)?;
        counts[outcome as usize].fetch_add(1, Ordering::Relaxed);
        Ok(())
    });
    let counts: Vec<usize> = counts.iter().map(|c| c.load(Ordering::Relaxed)).collect();
    eprintln!(
        "cases: {} refused by the reader, {} by the graph, {} by planning, {} by the objects check, {} checked",
        counts[0], counts[1], counts[2], counts[3], counts[4]
    );
    if let Err(e) = result {
        panic!("{e}");
    }
    assert!(
        counts[4] * 10 >= counts.iter().sum::<usize>(),
        "under a tenth of the cases reached the check: {counts:?}"
    );
}

/// A field change that moves the `landing` Deployment out of the `apps`
/// group, keeping its kind, namespace, and name. The plan shows the delete
/// and the write as two objects, and the deploy does what it shows.
#[test]
fn a_deployment_moved_to_the_core_group_deploys_what_its_plan_shows() {
    let honest: Vec<(Contents, StoreGraph)> = SEEDS
        .iter()
        .map(|(_, bytes)| {
            let (mut bundle, graph) = Bundle::read(Cursor::new(*bytes)).unwrap();
            (bundle.contents().unwrap(), graph)
        })
        .collect();
    let case = Case {
        seed: 0,
        changes: vec![Change::SetField {
            file: 826970914687456496,
            field: 15257103688815975303,
            value: 1170401294027661380,
        }],
        reorder: None,
        old: OldSide::Deployed,
        flags: 0,
    };
    assert_eq!(run(&case, &honest), Ok(Outcome::Checked));
}
