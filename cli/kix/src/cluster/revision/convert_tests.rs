use kube::api::DynamicObject;
use serde_json::{Value, json};

use super::*;
use crate::cluster::fake_api::FakeApi;
use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_FAILED};

const CLUSTER: &str = "a";

fn h(name: &str) -> String {
    format!("{name:a>32}")
}

/// A live ConfigMap as an older Kix left it: build hash `hash`, a note
/// naming `noted`, and an applied hash.
fn live(name: &str, hash: &str, noted: &[&str]) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "app",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": {
                (keys::IDENTITY_HASH): hash,
                (keys::ACTIVATIONS): noted.join(","),
                (keys::APPLIED_HASH): format!("applied-{name}"),
            },
            "managedFields": [{ "manager": "kix", "operation": "Apply", "fieldsType": "FieldsV1", "fieldsV1": {} }],
        },
        "data": { "k": name },
    })
}

/// A record of Kix cluster `a` with `index` as its package index.
fn record(name: &str, phase: &str, index: Option<Value>, kept_from: &[&str]) -> Value {
    let mut status = json!({ "phase": phase });
    if let Some(index) = index {
        status["packageIndex"] = index;
    }
    if !kept_from.is_empty() {
        status[keys::ORPHANS_KEPT_FROM_FIELD] = kept_from
            .iter()
            .map(|h| json!({ "activation": format!("{h}-rec"), "identityHash": h }))
            .collect();
    }
    json!({
        "apiVersion": keys::API_VERSION,
        "kind": "Activation",
        "metadata": {
            "name": name,
            "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): CLUSTER },
            "annotations": { (keys::IDENTITY_HASH): h(name) },
        },
        "status": status,
    })
}

/// A package index with one instance `app/web` listing `hashes`, naming
/// each object when `names` is set.
fn index(objects: &[(&str, &str)], names: bool) -> Value {
    let mut value = json!({
        "format": 1,
        "packages": { "app/web": { "instance": h("pi"), "resources": objects.iter().map(|(_, hash)| hash).collect::<Vec<_>>() } },
        "clusterLevel": [],
    });
    if names {
        let mut named: serde_json::Map<String, Value> = objects
            .iter()
            .map(|(name, hash)| (hash.to_string(), json!(["ConfigMap", "app", name])))
            .collect();
        named.insert(h("pi"), json!(["PackageInstance", "app", "web-instance"]));
        value["names"] = named.into();
        value["groups"] = json!({ (h("pi")): keys::DOMAIN });
    }
    value
}

fn parsed(values: &[Value]) -> Vec<Record> {
    values
        .iter()
        .map(|v| Record::of(&serde_json::from_value::<DynamicObject>(v.clone()).unwrap()))
        .collect()
}

fn objects(values: &[Value]) -> Vec<DynamicObject> {
    values
        .iter()
        .map(|v| serde_json::from_value(v.clone()).unwrap())
        .collect()
}

fn names(revision: &Revision) -> Vec<&str> {
    let mut out: Vec<&str> = revision
        .spec
        .objects
        .iter()
        .map(|o| o.name.as_str())
        .collect();
    out.sort();
    out
}

/// The current record and each `Failed` or `Partial` record without a map
/// are converted, the current one last. A record with a map is not.
#[test]
fn the_targets_are_the_records_a_run_needs_without_a_map() {
    let own = parsed(&[
        record("cur", PHASE_ACTIVE, None, &[]),
        record("fail", PHASE_FAILED, None, &[]),
        record("old", "Superseded", None, &[]),
    ]);
    let current = current_of(None, &own);
    let found: Vec<&str> = targets(current, &own)
        .iter()
        .map(|r| r.name.as_str())
        .collect();
    assert_eq!(found, ["fail", "cur"]);
    let mut mapped = own.clone();
    mapped[0].revisions = Some(Ok(RevisionMap {
        instances: Default::default(),
        cluster_level: "x".into(),
        kept_orphans: None,
    }));
    let found: Vec<&str> = targets(current_of(None, &mapped), &mapped)
        .iter()
        .map(|r| r.name.as_str())
        .collect();
    assert_eq!(found, ["fail"]);
}

/// A record whose index names its objects is converted from the index, by
/// instance, with each applied hash from the live object's note when the
/// object carries the hash the record gives it. An object only the note
/// names joins the cluster level. The kept builds name the kept orphans
/// through the notes.
#[test]
fn a_record_is_converted_from_its_index_and_the_notes() {
    let own_values = [record(
        "cur",
        PHASE_ACTIVE,
        Some(index(&[("web", &h("web")), ("gone", &h("gone"))], true)),
        &[&h("old")],
    )];
    let own = parsed(&own_values);
    let live_values = [
        live("web", &h("web"), &[&h("cur")]),
        // Changed since by a later deploy: the index's hash, not the live
        // one, and no applied hash carried.
        live("extra", &h("extra"), &[&h("cur")]),
        live("kept", &h("kept"), &[&h("old")]),
    ];
    let conversion = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        &[],
        &objects(&live_values),
        &[],
    )
    .unwrap();
    let converted = &conversion.records()[0];
    assert_eq!(converted.record, "cur");
    let instance = converted
        .revisions
        .iter()
        .find(|r| r.name == converted.map.instances["app/web"])
        .unwrap();
    assert_eq!(names(instance), ["gone", "web", "web-instance"]);
    assert_eq!(
        instance.applied.get(&h("web")).map(String::as_str),
        Some("applied-web")
    );
    assert!(!instance.applied.contains_key(&h("gone")));
    let cluster_level = converted
        .revisions
        .iter()
        .find(|r| r.name == converted.map.cluster_level)
        .unwrap();
    assert_eq!(names(cluster_level), ["extra"]);
    let kept = converted
        .revisions
        .iter()
        .find(|r| Some(&r.name) == converted.map.kept_orphans.as_ref())
        .unwrap();
    assert_eq!(names(kept), ["kept"]);
}

/// An index without names, as releases before 0.10 wrote, is read through
/// the live objects that carry its hashes.
#[test]
fn an_index_without_names_is_read_through_the_live_hashes() {
    let own = parsed(&[record(
        "cur",
        PHASE_ACTIVE,
        Some(index(&[("web", &h("web")), ("gone", &h("gone"))], false)),
        &[],
    )]);
    let live_values = [live("web", &h("web"), &[])];
    let conversion = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        &[],
        &objects(&live_values),
        &[],
    )
    .unwrap();
    let converted = &conversion.records()[0];
    let instance = converted
        .revisions
        .iter()
        .find(|r| r.name == converted.map.instances["app/web"])
        .unwrap();
    assert_eq!(names(instance), ["web"]);
}

/// A kept build that is a record with a map, as this Kix wrote before an
/// older Kix deployed over it, is read from its revisions.
#[test]
fn a_kept_build_with_revisions_is_read_from_them() {
    let earlier = Revision::new(RevisionSpec::new(
        CLUSTER,
        Slot::ClusterLevel,
        vec![RevisionObject::of_id(
            &h("left"),
            &ResourceId::new("", "ConfigMap", "app", "left"),
        )],
    ));
    let mut newer = record("newer", "Superseded", None, &[]);
    newer["status"]["revisions"] = RevisionMap {
        instances: Default::default(),
        cluster_level: earlier.name.clone(),
        kept_orphans: None,
    }
    .to_value();
    let own = parsed(&[record("cur", PHASE_ACTIVE, None, &[&h("newer")]), newer]);
    let conversion = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        std::slice::from_ref(&earlier),
        &[],
        &[],
    )
    .unwrap();
    let converted = &conversion.records()[0];
    let kept = converted
        .revisions
        .iter()
        .find(|r| Some(&r.name) == converted.map.kept_orphans.as_ref())
        .unwrap();
    assert_eq!(names(kept), ["left"]);
}

async fn run_on(api: &FakeApi) -> bool {
    let client = api.client();
    let found = crate::cluster::discovery::discover_resources(&client)
        .await
        .unwrap();
    let records = crate::cluster::activation::Records::open_installed(&client, &found).unwrap();
    run(&client, &records, &found, CLUSTER).await.unwrap()
}

/// The conversion names the revisions on each record and writes the
/// applied hashes. Run again, it finds every record converted and writes
/// nothing. A conversion that stopped after it created the revisions and
/// before it named them is finished by the next one, which reads the notes
/// it left in place.
#[tokio::test]
async fn the_conversion_is_safe_to_run_twice_and_to_stop() {
    let values = [
        record(
            "cur",
            PHASE_ACTIVE,
            Some(index(&[("web", &h("web"))], true)),
            &[],
        ),
        record(
            "fail",
            PHASE_FAILED,
            Some(index(&[("new", &h("new"))], true)),
            &[],
        ),
        live("web", &h("web"), &[&h("cur")]),
        live("new", &h("new"), &[&h("fail")]),
    ];
    let api = FakeApi::new(values.clone());
    // A conversion that stopped before its first map write.
    let own = parsed(&values[..2]);
    let stopped = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        &[],
        &objects(&values[2..]),
        &[],
    )
    .unwrap();
    let store = Revisions::new(&api.client());
    for revision in stopped.revisions() {
        store.create(revision).await.unwrap();
    }
    assert!(run_on(&api).await);
    for name in ["cur", "fail"] {
        let obj = api.object("Activation", name).unwrap();
        assert!(obj["status"]["revisions"].is_object(), "{obj}");
    }
    let listed = store.list(CLUSTER).await.unwrap().readable;
    let web = listed
        .iter()
        .find(|r| r.spec.objects.iter().any(|o| o.name == "web"))
        .unwrap();
    assert_eq!(
        web.applied.get(&h("web")).map(String::as_str),
        Some("applied-web")
    );
    let writes = api.requests().len();
    assert!(!run_on(&api).await);
    let more = api.requests()[writes..]
        .iter()
        .filter(|r| !r.starts_with("GET"))
        .count();
    assert_eq!(more, 0, "{:?}", &api.requests()[writes..]);
    // The objects keep their notes until a deploy tidies them.
    assert!(
        api.object("ConfigMap", "web").unwrap()["metadata"]["annotations"][keys::ACTIVATIONS]
            .is_string()
    );
}

/// A record whose index does not name its objects, or that has no index,
/// is read through the listing, so a listing that missed a kind refuses
/// the conversion and names the kind. An index that names every object
/// needs no listing. The plan and the run both call [`plan`] with the
/// kinds their listing missed.
#[test]
fn a_listing_that_missed_a_kind_refuses_a_record_without_names() {
    let forbidden = ["secrets".to_string()];
    for own_values in [
        record(
            "cur",
            PHASE_ACTIVE,
            Some(index(&[("web", &h("web"))], false)),
            &[],
        ),
        record("cur", PHASE_ACTIVE, None, &[]),
        // A kept build without a map is read through the notes.
        record(
            "cur",
            PHASE_ACTIVE,
            Some(index(&[("web", &h("web"))], true)),
            &[&h("old")],
        ),
    ] {
        let own = parsed(&[own_values]);
        let err = plan(CLUSTER, current_of(None, &own), &own, &[], &[], &forbidden).unwrap_err();
        assert_eq!(
            err,
            Refusal::NotListed {
                record: "cur".into(),
                kinds: forbidden.to_vec(),
            }
        );
        let text = err.to_string();
        assert!(
            text.starts_with("[K9558]")
                && text.contains("`list` secrets")
                && text.contains("Nothing was changed"),
            "{text}"
        );
    }
    let own = parsed(&[record(
        "cur",
        PHASE_ACTIVE,
        Some(index(&[("web", &h("web"))], true)),
        &[],
    )]);
    let conversion = plan(CLUSTER, current_of(None, &own), &own, &[], &[], &forbidden).unwrap();
    assert_eq!(conversion.records().len(), 1);
}

/// The kept-orphans revision names only live objects whose note names the
/// kept build, as an older Kix found them. An object the kept build's index
/// names that carries no such note is not a kept orphan.
#[test]
fn a_kept_orphan_is_found_by_its_note() {
    let older = record(
        "old",
        "Superseded",
        Some(index(&[("stale", &h("stale")), ("kept", &h("kept"))], true)),
        &[],
    );
    let mut older = older;
    older["metadata"]["annotations"][keys::IDENTITY_HASH] = json!(h("old"));
    let own = parsed(&[record("cur", PHASE_ACTIVE, None, &[&h("old")]), older]);
    let live_values = [
        live("kept", &h("kept"), &[&h("old")]),
        // Made since by something else under the same name.
        live("stale", &h("other"), &[]),
    ];
    let conversion = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        &[],
        &objects(&live_values),
        &[],
    )
    .unwrap();
    let converted = &conversion.records()[0];
    let kept = converted
        .revisions
        .iter()
        .find(|r| Some(&r.name) == converted.map.kept_orphans.as_ref())
        .unwrap();
    assert_eq!(names(kept), ["kept"]);
}

/// A record without a package index puts every object it names into one
/// revision. Past the size Kubernetes stores, the conversion refuses with
/// advice for such a record, not for a build.
#[test]
fn a_record_without_an_index_too_large_for_one_revision_is_refused() {
    let own = parsed(&[record("cur", PHASE_ACTIVE, None, &[])]);
    let cur = h("cur");
    let live_values: Vec<Value> = (0..7000)
        .map(|i| live(&format!("object-{i:05}"), &h(&format!("o{i}")), &[&cur]))
        .collect();
    let err = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        &[],
        &objects(&live_values),
        &[],
    )
    .unwrap_err();
    let text = err.to_string();
    assert!(
        matches!(err, Refusal::TooLarge(_))
            && text.contains("without a package index")
            && text.contains("Kix 0.9"),
        "{text}"
    );
}

/// An older Kix recorded an object's dependencies only in its
/// `kix.run/depends-on` note, and an instance's lifecycle only in its
/// objects' `kix.run/lifecycle` note. The conversion writes both into the
/// revisions, each hash named by the live object that carries it.
#[test]
fn the_conversion_records_the_noted_edges_and_lifecycle() {
    let own_values = [record(
        "cur",
        PHASE_ACTIVE,
        Some(index(&[("web", &h("web")), ("db", &h("db"))], true)),
        &[],
    )];
    let own = parsed(&own_values);
    let mut web = live("web", &h("web"), &[&h("cur")]);
    web["metadata"]["annotations"][keys::DEPENDS_ON] =
        json!(format!("requires:{},{}", h("db"), h("nothing")));
    web["metadata"]["annotations"][keys::LIFECYCLE] = json!("stateful");
    let live_values = [web, live("db", &h("db"), &[&h("cur")])];
    let conversion = plan(
        CLUSTER,
        current_of(None, &own),
        &own,
        &[],
        &objects(&live_values),
        &[],
    )
    .unwrap();
    let converted = &conversion.records()[0];
    let instance = converted
        .revisions
        .iter()
        .find(|r| r.name == converted.map.instances["app/web"])
        .unwrap();
    assert!(instance.spec.records_edges());
    assert!(matches!(
        &instance.spec.slot,
        Slot::Instance { lifecycle: Some(l), .. } if l == "stateful"
    ));
    let web = instance
        .spec
        .objects
        .iter()
        .find(|o| o.name == "web")
        .unwrap();
    let needs: Vec<(&str, Option<&str>)> = web
        .needs
        .iter()
        .map(|n| (n.name.as_str(), n.role.as_deref()))
        .collect();
    assert_eq!(needs, [("db", Some("requires"))]);
}
