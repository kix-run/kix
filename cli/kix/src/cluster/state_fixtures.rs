//! Read cluster state written by earlier Kix releases with today's readers.
//!
//! Each folder under `tests/fixtures/cluster-state/<version>/` holds objects
//! as Kix `<version>` left them on a cluster: Activation records, a
//! PackageInstance, and a managed object with Kix's annotations and
//! managedFields. `written.toml` names the release and its date.
//! `expected.json` holds what today's readers make of those objects. A
//! change to a reader that reads old state differently fails here.
//!
//! A Kix release must read the state written by the previous minor release,
//! and by any release from the last six months. The release skill adds a
//! folder only for a release that changes cluster state, so a folder stands
//! for every release up to the next folder.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use kube::api::DynamicObject;
use serde_json::{Value, json};

use crate::cluster::activation::{self, Record};
use crate::cluster::drift::{self, DriftVerdict};
use crate::cluster::revision::{self, AppliedHashes, Revision};
use crate::cluster::tenancy::Tenancy;
use crate::manifest::keys;
use crate::manifest::lifecycle;

/// How long a release's state must stay readable, in days (six months).
const READABLE_FOR_DAYS: i64 = 183;

#[derive(serde::Deserialize)]
struct Written {
    version: String,
    date: toml::value::Datetime,
}

struct Folder {
    path: PathBuf,
    version: (u64, u64, u64),
    date: chrono::NaiveDate,
}

fn fixtures_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/cluster-state")
}

fn parse_version(s: &str) -> (u64, u64, u64) {
    let parts: Vec<u64> = s
        .split('.')
        .map(|p| p.parse().unwrap_or_else(|_| panic!("bad version {s}")))
        .collect();
    assert_eq!(parts.len(), 3, "version {s} must be MAJOR.MINOR.PATCH");
    (parts[0], parts[1], parts[2])
}

fn folders() -> Vec<Folder> {
    let mut out: Vec<Folder> = std::fs::read_dir(fixtures_root())
        .expect("tests/fixtures/cluster-state exists")
        .map(|e| e.unwrap().path())
        .filter(|p| p.is_dir())
        .map(|path| {
            let text = std::fs::read_to_string(path.join("written.toml"))
                .unwrap_or_else(|e| panic!("{}/written.toml: {e}", path.display()));
            let written: Written = toml::from_str(&text)
                .unwrap_or_else(|e| panic!("{}/written.toml: {e}", path.display()));
            let folder_name = path.file_name().unwrap().to_string_lossy().to_string();
            assert_eq!(
                written.version,
                folder_name,
                "{}/written.toml names another version",
                path.display()
            );
            let date = chrono::NaiveDate::parse_from_str(&written.date.to_string(), "%Y-%m-%d")
                .unwrap_or_else(|e| panic!("{}/written.toml date: {e}", path.display()));
            Folder {
                version: parse_version(&written.version),
                path,
                date,
            }
        })
        .collect();
    out.sort_by_key(|f| f.version);
    out
}

/// Return every object in the folder's JSON files, except `expected.json`.
/// A file holds one object or an array of them.
fn objects(folder: &Path) -> Vec<(String, DynamicObject)> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(folder)
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .filter(|p| p.file_name().is_some_and(|n| n != "expected.json"))
        .collect();
    files.sort();
    let mut out = Vec::new();
    for file in files {
        let name = file.file_name().unwrap().to_string_lossy().to_string();
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap())
            .unwrap_or_else(|e| panic!("{}: {e}", file.display()));
        let items = match value {
            Value::Array(items) => items,
            other => vec![other],
        };
        for item in items {
            let obj: DynamicObject = serde_json::from_value(item)
                .unwrap_or_else(|e| panic!("{}: not a Kubernetes object: {e}", file.display()));
            out.push((name.clone(), obj));
        }
    }
    out
}

fn kind(obj: &DynamicObject) -> &str {
    obj.types.as_ref().map_or("", |t| t.kind.as_str())
}

fn record_view(r: &Record) -> Value {
    json!({
        "name": r.name,
        "phase": r.phase,
        "identityHash": r.identity_hash,
        "builtVia": r.built_via,
        "deployedAt": r.deployed_at,
        "previousActivation": r.previous_activation,
        "failureReason": r.failure_reason,
        "failedAt": r.failed_at,
        "createdAt": r.created_at.map(|t| t.to_rfc3339()),
        "operatorDriven": r.operator_driven,
        "request": r.request,
        "startedRequest": r.started_request,
        "finishedRequest": r.finished_request,
        "failedAttempts": r.failed_attempts,
        "pendingRequest": r.pending_request(),
        "orphansKeptFrom": r.orphans_kept_from,
        "packageIndex": r.package_index.as_ref().map(|i| i.to_value()),
        "waves": r.waves.iter().map(|w| json!({
            "wave": w.wave_index,
            "status": w.status.as_str(),
            "resources": w.resource_count,
            "applied": w.applied,
            "failed": w.failed,
        })).collect::<Vec<_>>(),
        "totalWaves": r.total_waves,
        "deleting": r.deleting,
        "uid": r.uid,
        "interfaces": r.interfaces.iter().map(|(k, v)| (k.clone(), json!({
            "consumer": v.consumer, "path": v.path, "sha256": v.sha256,
        }))).collect::<BTreeMap<_, _>>(),
        "publishedInterfaces": r.published_interfaces,
    })
}

fn verdict_name(v: &DriftVerdict) -> &'static str {
    match v {
        DriftVerdict::InSync => "InSync",
        DriftVerdict::Drifted { .. } => "Drifted",
        DriftVerdict::Unstamped => "Unstamped",
        DriftVerdict::NoFieldset => "NoFieldset",
    }
}

/// Return what today's readers make of the objects in `folder`.
fn read_back(folder: &Path) -> Value {
    let all = objects(folder);
    let records: Vec<DynamicObject> = all
        .iter()
        .filter(|(_, o)| kind(o) == lifecycle::RECORD_KIND)
        .map(|(_, o)| o.clone())
        .collect();
    let cluster = records
        .iter()
        .find_map(|r| {
            r.metadata
                .labels
                .as_ref()
                .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
        })
        .unwrap_or_default()
        .to_string();
    let tenancy = Tenancy::from_records(&records, &cluster);
    let parsed: Vec<Record> = records.iter().map(Record::of).collect();
    let revisions: Vec<Revision> = all
        .iter()
        .filter(|(_, o)| kind(o) == revision::KIND)
        .filter_map(|(_, o)| Revision::from_object(o).ok())
        .collect();
    let applied = AppliedHashes::of(&parsed, &revisions);
    let current = activation::current_record(&records);

    let others: Vec<Value> = all
        .iter()
        .filter(|(_, o)| kind(o) != lifecycle::RECORD_KIND)
        .map(|(file, o)| {
            let manifest = serde_json::to_value(o).unwrap();
            json!({
                "file": file,
                "kind": kind(o),
                "name": o.metadata.name,
                "lifecycle": format!("{:?}", lifecycle::lifecycle_of(&manifest)),
                "owners": tenancy.owners_of(o),
                "drift": verdict_name(&drift::check_object(o, applied.applied(o), &tenancy.manager_of(&cluster)).verdict),
            })
        })
        .collect();

    json!({
        "cluster": cluster,
        "records": records.iter().map(|r| record_view(&Record::of(r))).collect::<Vec<_>>(),
        "current": current.and_then(|c| c.metadata.name.clone()),
        "currentReceiptSchema": current
            .and_then(|c| c.data.pointer(&format!("/status/{}/schema", keys::RECEIPT_FIELD)))
            .cloned(),
        "receiptSchema": keys::RECEIPT_SCHEMA,
        "objects": others,
    })
}

/// Today's readers give the recorded values for state every fixture release
/// wrote. A folder without `expected.json` gets one written from today's
/// readers, and the test fails so that someone reviews it before committing.
#[test]
fn cluster_state_from_earlier_releases_reads_back() {
    let folders = folders();
    assert!(
        !folders.is_empty(),
        "no folders under {}",
        fixtures_root().display()
    );
    let mut failures = Vec::new();
    for folder in &folders {
        let got = read_back(&folder.path);
        let expected_path = folder.path.join("expected.json");
        let rendered = serde_json::to_string_pretty(&got).unwrap() + "\n";
        let Ok(expected) = std::fs::read_to_string(&expected_path) else {
            std::fs::write(&expected_path, &rendered).unwrap();
            failures.push(format!(
                "{} was missing, so the test wrote it from today's readers. Check that \
                 every value is what Kix should read from those objects, then commit it.",
                expected_path.display()
            ));
            continue;
        };
        let expected: Value = serde_json::from_str(&expected).unwrap();
        if expected != got {
            failures.push(format!(
                "Kix no longer reads the cluster state that Kix {} wrote the same way.\n\
                 Restore the old reading, or keep a fallback that reads the old form \
                 for at least one minor release (CLAUDE.md, Versioning and breaking changes).\n\
                 expected ({}):\n{}\ngot:\n{}",
                folder.path.file_name().unwrap().to_string_lossy(),
                expected_path.display(),
                serde_json::to_string_pretty(&expected).unwrap(),
                rendered,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}

/// Print each folder that no release Kix must still read stands for.
///
/// A folder stands for its release and every later one up to the next
/// folder. It is safe to delete when the next folder is no newer than the
/// previous minor release and is more than six months old. No folder is
/// required for any particular release.
#[test]
// The note about folders that are safe to delete goes to the test output.
#[allow(clippy::print_stdout)]
fn cluster_state_folders_safe_to_delete() {
    // A prerelease such as 0.10.0-rc.1 counts as its release.
    let release = env!("CARGO_PKG_VERSION")
        .split('-')
        .next()
        .unwrap_or_default();
    let (major, minor, _) = parse_version(release);
    let folders = folders();
    let previous = if minor > 0 {
        (major, minor - 1)
    } else {
        let older = folders.iter().filter(|f| f.version.0 < major);
        older
            .map(|f| (f.version.0, f.version.1))
            .max()
            .unwrap_or((0, 0))
    };
    let cutoff = chrono::Utc::now().date_naive() - chrono::Duration::days(READABLE_FOR_DAYS);
    for pair in folders.windows(2) {
        let (old, next) = (&pair[0], &pair[1]);
        if (next.version.0, next.version.1) <= previous && next.date < cutoff {
            println!(
                "{} is safe to delete. {} and the folders after it cover Kix {}.{} and \
                 every release from the last six months.",
                old.path.display(),
                next.path.display(),
                previous.0,
                previous.1,
            );
        }
    }
}

/// Return the manifest a build would give the live object `obj`: the object
/// without what the API server and earlier deploys wrote, and without
/// `kix.run/depends-on`, whose targets the test build does not hold.
fn manifest_of(obj: &DynamicObject) -> Value {
    let mut manifest = serde_json::to_value(obj).unwrap();
    let meta = manifest["metadata"].as_object_mut().unwrap();
    for key in [
        "managedFields",
        "resourceVersion",
        "uid",
        "creationTimestamp",
        "generation",
    ] {
        meta.remove(key);
    }
    if let Some(annotations) = meta.get_mut("annotations").and_then(Value::as_object_mut) {
        annotations.retain(|k, _| {
            k != keys::DEPENDS_ON
                && k != keys::ACTIVATIONS
                && k != keys::APPLIED_HASH
                && !k.starts_with("deployment.kubernetes.io/")
        });
    }
    manifest.as_object_mut().unwrap().remove("status");
    manifest
}

/// Each fixture cluster, as the release that wrote it left it, moves to
/// revisions on its first deploy by this Kix. The deploy builds the same
/// managed objects again. Afterwards every object has one `Apply` entry
/// under the cluster's own field manager and neither note, the revisions
/// name every object and carry the applied hash from its note, and a
/// second plan has nothing to do. The PackageInstance is left out, because
/// the fake API server does not serve its kind.
#[tokio::test]
async fn each_fixture_cluster_moves_to_revisions_on_its_first_deploy() {
    use crate::cluster::fake_api::FakeApi;
    use crate::plan::migration_tests::{deploy, managers, notes, plan, written};
    for folder in folders() {
        let all = objects(&folder.path);
        let managed: Vec<&DynamicObject> = all
            .iter()
            .map(|(_, o)| o)
            .filter(|o| kind(o) == "Deployment")
            .collect();
        let cluster = all
            .iter()
            .find_map(|(_, o)| {
                o.metadata
                    .labels
                    .as_ref()
                    .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
            })
            .unwrap()
            .to_string();
        let api = FakeApi::new(
            all.iter()
                .filter(|(_, o)| kind(o) == lifecycle::RECORD_KIND || kind(o) == "Deployment")
                .map(|(_, o)| serde_json::to_value(o).unwrap()),
        );
        api.track_owners();
        let mut manifests: Vec<Value> = managed.iter().map(|o| manifest_of(o)).collect();
        manifests.push(json!({
            "apiVersion": keys::API_VERSION,
            "kind": lifecycle::RECORD_KIND,
            "metadata": {
                "name": format!("{cluster}-first000000"),
                "labels": { (keys::CLUSTER_LABEL): cluster },
                "annotations": { (keys::IDENTITY_HASH): "a".repeat(29) + "fst" },
            },
            "spec": { "cluster": cluster },
        }));
        // A real build names each file by the object's identity hash, so a
        // reference graph with those paths gives the synthesized build the
        // same names.
        let mut reference = crate::eval::store_graph::StoreGraph::empty(&cluster);
        for manifest in &manifests {
            let hash = keys::get(manifest, keys::IDENTITY_HASH).unwrap();
            let path = PathBuf::from(format!("/nix/store/{hash}-k8s"));
            reference.resources.insert(
                path.clone(),
                crate::eval::store_graph::ResourceNode {
                    store_path: path,
                    manifest: manifest.clone(),
                },
            );
        }
        let graph = crate::eval::store_graph::StoreGraph::synthesize(&manifests, &reference);
        let version = folder.path.display().to_string();
        let checked = plan(&api, &cluster, &graph).await;
        assert!(
            written(&checked).is_empty(),
            "{version}: {:?}",
            written(&checked)
        );
        assert_eq!(checked.metadata_rewrites(), managed.len(), "{version}");
        deploy(&api, &cluster, &graph)
            .await
            .unwrap_or_else(|e| panic!("{version}: {e}"));
        let own = format!("kix/{cluster}:Apply");
        for obj in &managed {
            let name = obj.metadata.name.as_deref().unwrap();
            let entries = managers(&api, kind(obj), name);
            assert!(
                entries.iter().filter(|e| e.ends_with(":Apply")).eq([&own]),
                "{version}: {entries:?}"
            );
            assert!(
                !entries.iter().any(|e| e.starts_with("kix:")),
                "{version}: {entries:?}"
            );
            assert_eq!(notes(&api, kind(obj), name), (None, None), "{version}");
        }
        let listed = crate::cluster::revision::Revisions::new(&api.client())
            .list(&cluster)
            .await
            .unwrap()
            .readable;
        for obj in &managed {
            let hash = obj
                .metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH))
                .unwrap();
            let applied = obj
                .metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, keys::APPLIED_HASH))
                .unwrap();
            let named: Vec<&Revision> = listed
                .iter()
                .filter(|r| r.spec.objects.iter().any(|o| o.hash == hash))
                .collect();
            assert!(!named.is_empty(), "{version}: no revision names {hash}");
            assert!(
                named
                    .iter()
                    .all(|r| r.applied.get(hash).map(String::as_str) == Some(applied)),
                "{version}: {named:?}"
            );
        }
        let again = plan(&api, &cluster, &graph).await;
        assert!(
            written(&again).is_empty(),
            "{version}: {:?}",
            written(&again)
        );
        assert_eq!(again.metadata_rewrites(), 0, "{version}");
    }
}

/// An older Kix that deploys a Kix cluster after this Kix wrote its head
/// leaves a record that is current by phase and has no revision map, while
/// the head names the record this Kix deployed. Kix then reads the Kix
/// cluster as not migrated, from the notes, until it deploys it again.
#[test]
fn an_older_kix_that_deployed_after_this_one_leaves_the_cluster_not_migrated() {
    use crate::cluster::head::HeadStatus;
    use crate::cluster::revision::{RevisionMap, Slot};
    for folder in folders() {
        let all = objects(&folder.path);
        let mut records: Vec<DynamicObject> = all
            .iter()
            .filter(|(_, o)| kind(o) == lifecycle::RECORD_KIND)
            .map(|(_, o)| o.clone())
            .collect();
        let older = records
            .iter()
            .find(|r| r.data["status"]["phase"] == lifecycle::PHASE_ACTIVE)
            .unwrap()
            .clone();
        let cluster = older
            .metadata
            .labels
            .as_ref()
            .and_then(|l| keys::get_meta(l, keys::CLUSTER_LABEL))
            .unwrap()
            .to_string();
        let revision = Revision::new(crate::cluster::revision::RevisionSpec::new(
            &cluster,
            Slot::ClusterLevel,
            Vec::new(),
        ));
        let map = RevisionMap {
            instances: Default::default(),
            cluster_level: revision.name.clone(),
            kept_orphans: None,
        };
        // This Kix deployed `newer` before the older Kix deployed `older`.
        let mut newer = older.clone();
        newer.metadata.name = Some(format!("{cluster}-newer0000000"));
        newer.data["status"] = json!({
            "phase": lifecycle::PHASE_ACTIVE,
            "deployedAt": "2026-01-01T00:00:00Z",
            "revisions": map.to_value(),
        });
        records.push(newer.clone());
        let heads = BTreeMap::from([(
            cluster.clone(),
            HeadStatus {
                current: newer.metadata.name.clone(),
                ..HeadStatus::default()
            },
        )]);
        let tenancy = Tenancy::fixture_of_state(&cluster, &heads, &records, &[revision]);
        assert_eq!(
            tenancy.own_source(),
            crate::cluster::tenancy::Source::Records,
            "{}",
            folder.path.display()
        );
        // With the older Kix's record gone from the phases, the head's
        // record is read from revisions again.
        records.retain(|r| r.metadata.name != older.metadata.name);
        let tenancy = Tenancy::fixture_of_state(&cluster, &heads, &records, &[]);
        assert_eq!(
            tenancy.own_source(),
            crate::cluster::tenancy::Source::Revisions,
            "{}",
            folder.path.display()
        );
    }
}
