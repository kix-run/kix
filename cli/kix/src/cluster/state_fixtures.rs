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
                "drift": verdict_name(&drift::check_object(o).verdict),
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
    let (major, minor, _) = parse_version(env!("CARGO_PKG_VERSION"));
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
