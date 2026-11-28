use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::cluster::drift::DriftVerdict;
use crate::cluster::head::HeadStatus;
use crate::cluster::revision::{
    Revision, RevisionImport, RevisionMap, RevisionObject, RevisionSpec,
};
use crate::cluster::tenancy::Source;
use crate::manifest::keys;
use crate::manifest::lifecycle::{
    PACKAGE_INSTANCE_KIND, PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED,
    PHASE_PARTIAL, PHASE_SUPERSEDED,
};

const CLUSTER: &str = "a";

fn h(name: &str) -> String {
    format!("{name:a>32}")
}

fn rid(name: &str) -> ResourceId {
    ResourceId::new("", "ConfigMap", "app", name)
}

fn marker_rid(name: &str) -> ResourceId {
    ResourceId::new(keys::GROUP, PACKAGE_INSTANCE_KIND, "app", name)
}

/// A live object `name` of kind `kind` in namespace `app` with
/// `annotations`, applied under the field manager an older Kix used.
fn live_of(api_version: &str, kind: &str, name: &str, annotations: Value) -> DynamicObject {
    serde_json::from_value(json!({
        "apiVersion": api_version,
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": "app",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": annotations,
            "managedFields": [{ "manager": "kix", "operation": "Apply", "apiVersion": api_version }],
        },
    }))
    .unwrap()
}

fn cm(name: &str, annotations: Value) -> DynamicObject {
    live_of("v1", "ConfigMap", name, annotations)
}

fn observed(obj: DynamicObject, applied: Option<&str>) -> Observed {
    Observed {
        obj,
        applied: applied.map(str::to_string),
    }
}

fn web(lifecycle: Option<&str>) -> Slot {
    Slot::Instance {
        namespace: "app".into(),
        name: "web".into(),
        lifecycle: lifecycle.map(str::to_string),
    }
}

fn object(name: &str, hash: &str) -> RevisionObject {
    RevisionObject::of_id(hash, &rid(name))
}

fn revision(slot: Slot, objects: Vec<RevisionObject>, applied: &[(&str, &str)]) -> Revision {
    let mut revision = Revision::new(RevisionSpec::new(CLUSTER, slot, objects));
    revision.applied = applied
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    revision
}

fn cluster_level() -> Revision {
    revision(Slot::ClusterLevel, Vec::new(), &[])
}

/// A record of Kix cluster `a` whose map names `instance`, the empty
/// cluster level, and `kept`.
fn record(name: &str, phase: &str, instance: &Revision, kept: Option<&Revision>) -> DynamicObject {
    let map = RevisionMap {
        instances: BTreeMap::from([("app/web".to_string(), instance.name.clone())]),
        cluster_level: cluster_level().name,
        kept_orphans: kept.map(|k| k.name.clone()),
    };
    record_with(name, json!({ "phase": phase, "revisions": map.to_value() }))
}

fn record_with(name: &str, status: Value) -> DynamicObject {
    serde_json::from_value(json!({
        "apiVersion": keys::API_VERSION,
        "kind": "Activation",
        "metadata": {
            "name": name,
            "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): CLUSTER },
            "annotations": { (keys::IDENTITY_HASH): h(name) },
        },
        "status": status,
    }))
    .unwrap()
}

fn heads(current: &str) -> BTreeMap<String, HeadStatus> {
    BTreeMap::from([(
        CLUSTER.to_string(),
        HeadStatus {
            current: Some(current.to_string()),
            generation: 1,
            lock: None,
            writer: None,
        },
    )])
}

/// A Kix cluster on format 2 is read from its revisions: the slot and its
/// lifecycle, the hash, the records, the edges, and the applied hash. An
/// object only the kept-orphans revision names is in that slot and no
/// record deploys it.
#[test]
fn a_cluster_on_format_two_reads_from_its_revisions() {
    let instance = revision(
        web(Some("stateful")),
        vec![
            object("a", "oa").with_needs([Need::of(&rid("b"), Some("requires"))]),
            object("b", "ob"),
        ],
        &[("oa", "ap-a"), ("ob", "ap-b")],
    );
    let kept = revision(Slot::KeptOrphans, vec![object("c", "oc")], &[]);
    let records = [record("r1", PHASE_ACTIVE, &instance, Some(&kept))];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[instance, kept, cluster_level()],
    );
    assert_eq!(tenancy.own_source(), Source::Revisions);
    let live = [
        observed(cm("a", json!({})), Some("ap-a")),
        observed(cm("b", json!({})), Some("drifted")),
        observed(cm("c", json!({})), None),
    ];
    let recorded = RecordedObjects::of(&tenancy, &live);

    assert_eq!(
        recorded.get(&live[0].obj),
        Some(&Recorded {
            slot: web(Some("stateful")),
            hash: Some("oa".into()),
            records: vec![h("r1")],
            needs: vec![Need::of(&rid("b"), Some("requires"))],
            applied: Some("ap-a".into()),
        })
    );
    assert_eq!(recorded.drift(&live[0]).verdict, DriftVerdict::InSync);
    assert!(matches!(
        recorded.drift(&live[1]).verdict,
        DriftVerdict::Drifted { .. }
    ));

    let orphan = recorded.get(&live[2].obj).unwrap();
    assert_eq!(orphan.slot, Slot::KeptOrphans);
    assert_eq!(orphan.hash.as_deref(), Some("oc"));
    assert!(orphan.records.is_empty());
}

/// A record whose map names format 1 revisions is read as the next deploy
/// converts it: the lifecycle and the edges come from the notes on the
/// live objects, and the hash stays the one the format 1 revision gives.
#[test]
fn a_cluster_on_format_one_reads_as_converted() {
    let format_one = |slot: Slot, objects: Vec<RevisionObject>, applied: &[(&str, &str)]| {
        let mut spec = RevisionSpec::new(CLUSTER, slot, objects);
        spec.format = 1;
        let mut revision = Revision::new(spec);
        revision.applied = applied
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        revision
    };
    let instance = format_one(
        web(None),
        vec![object("a", "oa"), object("b", "ob")],
        &[("oa", "old-a")],
    );
    let level = format_one(Slot::ClusterLevel, Vec::new(), &[]);
    let map = RevisionMap {
        instances: BTreeMap::from([("app/web".to_string(), instance.name.clone())]),
        cluster_level: level.name.clone(),
        kept_orphans: None,
    };
    let records = [record_with(
        "r1",
        json!({ "phase": PHASE_ACTIVE, "revisions": map.to_value() }),
    )];
    let tenancy = Tenancy::fixture_of_state(CLUSTER, &heads("r1"), &records, &[instance, level]);
    let live = [
        observed(
            cm(
                "a",
                json!({
                    (keys::IDENTITY_HASH): "oa",
                    (keys::LIFECYCLE): "stateful",
                    (keys::DEPENDS_ON): "requires:ob",
                }),
            ),
            None,
        ),
        observed(cm("b", json!({ (keys::IDENTITY_HASH): "ob" })), None),
    ];
    let recorded = RecordedObjects::of(&tenancy, &live);

    let a = recorded.get(&live[0].obj).unwrap();
    assert_eq!(a.slot, web(Some("stateful")));
    assert_eq!(a.hash.as_deref(), Some("oa"));
    assert_eq!(a.records, [h("r1")]);
    assert_eq!(a.needs, [Need::of(&rid("b"), Some("requires"))]);
    assert_eq!(a.applied.as_deref(), Some("old-a"));
}

/// A Kix cluster an older Kix deployed last is read from its records and
/// the notes on its objects by the conversion's rules. The package index
/// puts an instance's own PackageInstance and a marker it applied in its
/// slot, an object only a note names is at the cluster level, and the hash
/// is the build's store hash.
#[test]
fn a_cluster_read_from_records_reads_as_converted() {
    let index = json!({
        "format": 1,
        "packages": { "app/web": { "instance": h("pi"), "resources": [h("a"), h("m")] } },
        "clusterLevel": [],
        "names": {
            (h("pi")): [PACKAGE_INSTANCE_KIND, "app", "web"],
            (h("a")): ["ConfigMap", "app", "a"],
            (h("m")): [PACKAGE_INSTANCE_KIND, "app", "other"],
        },
        "groups": { (h("pi")): keys::GROUP, (h("m")): keys::GROUP },
    });
    let records = [record_with(
        "r1",
        json!({ "phase": PHASE_ACTIVE, "packageIndex": index }),
    )];
    let tenancy = Tenancy::fixture(&records, CLUSTER);
    assert_eq!(tenancy.own_source(), Source::Records);
    let noted = |hash: &str, more: Value| {
        let mut annotations = json!({
            (keys::IDENTITY_HASH): hash,
            (keys::ACTIVATIONS): h("r1"),
        });
        annotations
            .as_object_mut()
            .unwrap()
            .extend(more.as_object().unwrap().clone());
        annotations
    };
    let live = [
        observed(
            cm(
                "a",
                noted(
                    &h("a"),
                    json!({ (keys::LIFECYCLE): "stateful", (keys::APPLIED_HASH): "ap-a" }),
                ),
            ),
            Some("ap-a"),
        ),
        observed(
            live_of(
                keys::API_VERSION,
                PACKAGE_INSTANCE_KIND,
                "web",
                noted(&h("pi"), json!({})),
            ),
            None,
        ),
        observed(
            live_of(
                keys::API_VERSION,
                PACKAGE_INSTANCE_KIND,
                "other",
                noted(&h("m"), json!({})),
            ),
            None,
        ),
        observed(cm("z", noted(&h("z"), json!({}))), None),
    ];
    let recorded = RecordedObjects::of(&tenancy, &live);

    let a = recorded.get(&live[0].obj).unwrap();
    assert_eq!(a.slot, web(Some("stateful")));
    assert_eq!(a.hash, Some(h("a")));
    assert_eq!(a.records, [h("r1")]);
    assert_eq!(a.applied.as_deref(), Some("ap-a"));
    assert_eq!(recorded.drift(&live[0]).verdict, DriftVerdict::InSync);
    assert_eq!(
        recorded.get(&live[1].obj).map(|r| &r.slot),
        Some(&web(Some("stateful")))
    );
    assert_eq!(
        recorded.get(&live[2].obj).map(|r| &r.slot),
        Some(&web(Some("stateful")))
    );
    assert_eq!(
        recorded.get(&live[3].obj).map(|r| &r.slot),
        Some(&Slot::ClusterLevel)
    );
}

/// A deploy under way names the object with a new hash. The hash of the
/// revision that applied what the object holds wins. When none did, the
/// records disagree, the hash is not known, and every record that names
/// the object is listed.
#[test]
fn a_deploy_under_way_files_the_object_under_the_hash_it_applied() {
    let old = revision(web(None), vec![object("a", "old")], &[("old", "ap-old")]);
    let new = revision(web(None), vec![object("a", "new")], &[("new", "ap-new")]);
    let records = [
        record("r1", PHASE_ACTIVE, &old, None),
        record("r2", PHASE_DEPLOYING, &new, None),
    ];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[old, new, cluster_level()],
    );
    let read = |applied: Option<&str>| {
        let live = [observed(cm("a", json!({})), applied)];
        let recorded = RecordedObjects::of(&tenancy, &live);
        let found = recorded.get(&live[0].obj).unwrap();
        (found.hash.clone(), found.records.clone())
    };
    assert_eq!(read(Some("ap-new")), (Some("new".into()), vec![h("r2")]));
    assert_eq!(read(Some("ap-old")), (Some("old".into()), vec![h("r1")]));
    assert_eq!(read(Some("other")), (None, vec![h("r1"), h("r2")]));
    assert_eq!(read(None), (None, vec![h("r1"), h("r2")]));
}

/// When no revision applied what the object holds, the one hash every
/// record agrees on is the hash.
#[test]
fn records_that_agree_give_their_hash() {
    let same = revision(web(None), vec![object("a", "same")], &[("same", "ap")]);
    let records = [
        record("r1", PHASE_ACTIVE, &same, None),
        record("r2", PHASE_DEPLOYING, &same, None),
    ];
    let tenancy =
        Tenancy::fixture_of_state(CLUSTER, &heads("r1"), &records, &[same, cluster_level()]);
    let live = [observed(cm("a", json!({})), Some("drifted"))];
    let recorded = RecordedObjects::of(&tenancy, &live);
    let found = recorded.get(&live[0].obj).unwrap();
    assert_eq!(found.hash.as_deref(), Some("same"));
    assert_eq!(found.records, [h("r1"), h("r2")]);
}

/// A revision's import marker gets no entry, and an edge through it ends
/// at what the marker needs.
#[test]
fn imports_get_no_entry() {
    let mut instance = revision(
        web(None),
        vec![
            object("x", "ox").with_needs([Need::of(&marker_rid("crd"), Some("requires"))]),
            object("y", "oy"),
        ],
        &[],
    );
    instance.spec.imports = vec![RevisionImport {
        namespace: Some("app".into()),
        name: "crd".into(),
        hash: "om".into(),
        target: None,
        needs: vec![Need::of(&rid("y"), None)],
    }];
    let instance = Revision::new(instance.spec);
    let records = [record("r1", PHASE_ACTIVE, &instance, None)];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[instance, cluster_level()],
    );
    let x = observed(cm("x", json!({})), None);
    let y = observed(cm("y", json!({})), None);
    let recorded = RecordedObjects::of(&tenancy, &[x.clone(), y]);
    assert_eq!(
        recorded.get(&x.obj).unwrap().needs,
        [Need::of(&rid("y"), None)]
    );

    let marker = observed(
        live_of(keys::API_VERSION, PACKAGE_INSTANCE_KIND, "crd", json!({})),
        None,
    );
    let recorded = RecordedObjects::of(&tenancy, std::slice::from_ref(&marker));
    assert_eq!(recorded.get(&marker.obj), None);
}

/// A kept orphan of a list `kix gc` rebuilt has no known hash.
#[test]
fn a_rebuilt_orphan_has_no_hash() {
    let instance = revision(web(None), vec![object("a", "oa")], &[]);
    let kept = revision(Slot::KeptOrphans, vec![object("c", REBUILT)], &[]);
    let records = [record("r1", PHASE_ACTIVE, &instance, Some(&kept))];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[instance, kept, cluster_level()],
    );
    let live = [observed(cm("c", json!({})), None)];
    let recorded = RecordedObjects::of(&tenancy, &live);
    let orphan = recorded.get(&live[0].obj).unwrap();
    assert_eq!(orphan.slot, Slot::KeptOrphans);
    assert_eq!(orphan.hash, None);
}

/// An object no record of the Kix cluster names gets no entry, and its
/// drift check reads its applied hash as not known.
#[test]
fn an_object_no_record_names_has_no_entry() {
    let instance = revision(web(None), vec![object("a", "oa")], &[]);
    let records = [record("r1", PHASE_ACTIVE, &instance, None)];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[instance, cluster_level()],
    );
    let stray = observed(cm("stray", json!({})), Some("ap"));
    let recorded = RecordedObjects::of(&tenancy, std::slice::from_ref(&stray));
    assert_eq!(recorded.get(&stray.obj), None);
    assert_eq!(recorded.drift(&stray).verdict, DriftVerdict::Unstamped);
}

fn instance_slot(name: &str) -> Slot {
    Slot::Instance {
        namespace: "app".into(),
        name: name.into(),
        lifecycle: None,
    }
}

/// A record of Kix cluster `cluster` whose map names `instances` by
/// instance name, the empty cluster level, and `kept`.
fn record_in(
    cluster: &str,
    name: &str,
    phase: &str,
    instances: &[(&str, &Revision)],
    kept: Option<&Revision>,
) -> DynamicObject {
    let map = RevisionMap {
        instances: instances
            .iter()
            .map(|(key, r)| (format!("app/{key}"), r.name.clone()))
            .collect(),
        cluster_level: Revision::new(RevisionSpec::new(cluster, Slot::ClusterLevel, Vec::new()))
            .name,
        kept_orphans: kept.map(|k| k.name.clone()),
    };
    let mut record = record_with(name, json!({ "phase": phase, "revisions": map.to_value() }));
    record
        .metadata
        .labels
        .get_or_insert_default()
        .insert(keys::CLUSTER_LABEL.to_string(), cluster.to_string());
    record
}

/// A record an older Kix wrote, with a package index that lists each of
/// `objects` (name, build hash) under instance `app/web`.
fn older_record(name: &str, phase: &str, objects: &[(&str, &str)]) -> DynamicObject {
    let names: serde_json::Map<String, Value> = objects
        .iter()
        .map(|(n, hash)| (hash.to_string(), json!(["ConfigMap", "app", n])))
        .collect();
    let index = json!({
        "format": 1,
        "packages": { "app/web": {
            "instance": h(&format!("pi{name}")),
            "resources": objects.iter().map(|(_, hash)| hash).collect::<Vec<_>>(),
        } },
        "clusterLevel": [],
        "names": names,
        "groups": {},
    });
    record_with(name, json!({ "phase": phase, "packageIndex": index }))
}

/// A live object an older Kix wrote: build hash `hash`, notes naming the
/// records `noted`, and the applied hash `applied`.
fn older_object(name: &str, hash: &str, noted: &[&str], applied: &str) -> DynamicObject {
    let noted: Vec<String> = noted.iter().map(|r| h(r)).collect();
    cm(
        name,
        json!({
            (keys::IDENTITY_HASH): hash,
            (keys::ACTIVATIONS): noted.join(","),
            (keys::APPLIED_HASH): applied,
        }),
    )
}

/// A lost revision of an own record is reported, also when the record's
/// map is format 1 and the conversion in memory would otherwise hide it.
#[test]
fn a_lost_revision_is_reported() {
    let mut spec = RevisionSpec::new(CLUSTER, web(None), vec![object("a", "oa")]);
    spec.format = 1;
    let instance = Revision::new(spec);
    let records = [record("r1", PHASE_ACTIVE, &instance, None)];
    // The cluster level revision the map names is missing.
    let tenancy = Tenancy::fixture_of_state(CLUSTER, &heads("r1"), &records, &[instance]);
    let live = [observed(
        cm("a", json!({ (keys::IDENTITY_HASH): "oa" })),
        None,
    )];
    let recorded = RecordedObjects::of(&tenancy, &live);
    assert!(matches!(
        recorded.incomplete(),
        [Incomplete::Tenancy(Problem::MissingRevision { .. })]
    ));
    assert!(recorded.get(&live[0].obj).is_some());
}

/// A tenancy read for no Kix cluster gives no entry, and says so.
#[test]
fn a_tenancy_for_no_cluster_is_reported() {
    let instance = revision(web(None), vec![object("a", "oa")], &[]);
    let records = [record("r1", PHASE_ACTIVE, &instance, None)];
    let tenancy = Tenancy::fixture_of_state("", &heads("r1"), &records, &[instance]);
    let live = [observed(cm("a", json!({})), None)];
    let recorded = RecordedObjects::of(&tenancy, &live);
    assert_eq!(recorded.incomplete(), [Incomplete::NoCluster]);
    assert_eq!(recorded.get(&live[0].obj), None);
}

/// A deploy by an older Kix that is still under way names no revisions,
/// so the object it rewrote stays under the current record. The answer
/// says it may be stale.
#[test]
fn a_deploy_by_an_older_kix_under_way_is_reported() {
    let records = [
        older_record("r1", PHASE_ACTIVE, &[("a", &h("a"))]),
        older_record("r2", PHASE_DEPLOYING, &[("a", &h("a2"))]),
    ];
    let tenancy = Tenancy::fixture(&records, CLUSTER);
    let live = [observed(
        older_object("a", &h("a2"), &["r1", "r2"], "ap-a2"),
        Some("ap-a2"),
    )];
    let recorded = RecordedObjects::of(&tenancy, &live);
    assert_eq!(
        recorded.incomplete(),
        [Incomplete::OlderKixPending {
            records: vec!["r2".into()]
        }]
    );
    assert_eq!(recorded.get(&live[0].obj).unwrap().records, [h("r1")]);
}

/// A Failed or Partial record an older Kix wrote is converted with the
/// current one, so an object its deploy rewrote is filed under its build.
#[test]
fn failed_and_partial_records_of_an_older_kix_are_read() {
    for phase in [PHASE_FAILED, PHASE_PARTIAL] {
        let records = [
            older_record("r1", PHASE_ACTIVE, &[("a", &h("a"))]),
            older_record("r2", phase, &[("a", &h("a2"))]),
        ];
        let tenancy = Tenancy::fixture(&records, CLUSTER);
        let live = [observed(
            older_object("a", &h("a2"), &["r1", "r2"], "ap-a2"),
            Some("ap-a2"),
        )];
        let recorded = RecordedObjects::of(&tenancy, &live);
        assert!(recorded.incomplete().is_empty(), "{phase}");
        let a = recorded.get(&live[0].obj).unwrap();
        assert_eq!(a.hash, Some(h("a2")), "{phase}");
        assert_eq!(a.records, [h("r2")], "{phase}");
        assert_eq!(a.slot, web(None), "{phase}");
    }
}

/// A Degraded current record names its objects as an Active one does.
#[test]
fn a_degraded_current_record_names_its_objects() {
    let instance = revision(web(None), vec![object("a", "oa")], &[("oa", "ap")]);
    let records = [record("r1", PHASE_DEGRADED, &instance, None)];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[instance, cluster_level()],
    );
    let live = [observed(cm("a", json!({})), Some("ap"))];
    let recorded = RecordedObjects::of(&tenancy, &live);
    let a = recorded.get(&live[0].obj).unwrap();
    assert_eq!(a.hash.as_deref(), Some("oa"));
    assert_eq!(a.records, [h("r1")]);
    assert_eq!(recorded.drift(&live[0]).verdict, DriftVerdict::InSync);
}

/// Another Kix cluster's revision of a shared object takes no part.
#[test]
fn another_clusters_revision_takes_no_part() {
    let own = revision(web(None), vec![object("a", "oa")], &[]);
    let theirs = Revision::new(RevisionSpec::new("b", web(None), vec![object("a", "ob")]));
    let theirs_level = Revision::new(RevisionSpec::new("b", Slot::ClusterLevel, Vec::new()));
    let records = [
        record("r1", PHASE_ACTIVE, &own, None),
        record_in("b", "rb", PHASE_ACTIVE, &[("web", &theirs)], None),
    ];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[own, theirs, theirs_level, cluster_level()],
    );
    let live = [observed(cm("a", json!({})), None)];
    let recorded = RecordedObjects::of(&tenancy, &live);
    let a = recorded.get(&live[0].obj).unwrap();
    assert_eq!(a.hash.as_deref(), Some("oa"));
    assert_eq!(a.records, [h("r1")]);
}

/// When the kept orphans and an instance both name an object, the
/// instance decides, unless the kept-orphans entry applied what the object
/// holds. No record deploys an object by keeping it.
#[test]
fn kept_and_deployed_revisions_naming_one_object() {
    let instance = revision(web(None), vec![object("a", "oa")], &[]);
    let kept = revision(
        Slot::KeptOrphans,
        vec![object("a", "ok")],
        &[("ok", "ap-k")],
    );
    let records = [record("r1", PHASE_ACTIVE, &instance, Some(&kept))];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[instance, kept, cluster_level()],
    );
    let read = |applied: Option<&str>| {
        let live = [observed(cm("a", json!({})), applied)];
        let recorded = RecordedObjects::of(&tenancy, &live);
        let a = recorded.get(&live[0].obj).unwrap().clone();
        (a.slot, a.hash, a.records)
    };
    assert_eq!(read(None), (web(None), Some("oa".into()), vec![h("r1")]));
    assert_eq!(
        read(Some("ap-k")),
        (Slot::KeptOrphans, Some("ok".into()), vec![])
    );
}

/// An object that moved to another instance between two records takes its
/// slot from the revision that gave it its hash.
#[test]
fn the_slot_follows_the_hash() {
    let old = revision(
        instance_slot("web"),
        vec![object("a", "old")],
        &[("old", "ap-old")],
    );
    let new = revision(
        instance_slot("api"),
        vec![object("a", "new")],
        &[("new", "ap-new")],
    );
    let records = [
        record_in(CLUSTER, "r1", PHASE_ACTIVE, &[("web", &old)], None),
        record_in(CLUSTER, "r2", PHASE_DEPLOYING, &[("api", &new)], None),
    ];
    let tenancy = Tenancy::fixture_of_state(
        CLUSTER,
        &heads("r1"),
        &records,
        &[old, new, cluster_level()],
    );
    let slot = |applied: Option<&str>| {
        let live = [observed(cm("a", json!({})), applied)];
        let recorded = RecordedObjects::of(&tenancy, &live);
        recorded.get(&live[0].obj).unwrap().slot.clone()
    };
    assert_eq!(slot(Some("ap-new")), instance_slot("api"));
    assert_eq!(slot(Some("ap-old")), instance_slot("web"));
    assert_eq!(slot(None), instance_slot("web"));
}

/// A Superseded record the head still names, after an older Kix deployed
/// another, takes no part in the hash, as it takes none in the applied
/// hashes.
#[test]
fn a_superseded_record_takes_no_part() {
    let stale = revision(web(None), vec![object("a", "stale")], &[]);
    let records = [
        record("r1", PHASE_SUPERSEDED, &stale, None),
        older_record("r2", PHASE_ACTIVE, &[("a", &h("a"))]),
    ];
    let tenancy =
        Tenancy::fixture_of_state(CLUSTER, &heads("r1"), &records, &[stale, cluster_level()]);
    let live = [observed(
        older_object("a", &h("a"), &["r2"], "ap-a"),
        Some("other"),
    )];
    let recorded = RecordedObjects::of(&tenancy, &live);
    let a = recorded.get(&live[0].obj).unwrap();
    assert_eq!(a.hash, Some(h("a")));
    assert_eq!(a.records, [h("r2")]);
}
