use super::*;
use crate::manifest::lifecycle::{PHASE_DEPLOYING, PHASE_FAILED, PHASE_PARTIAL};
use serde_json::json;

fn record(cluster: Option<&str>, hash: Option<&str>, phase: &str) -> DynamicObject {
    let mut labels = serde_json::Map::new();
    if let Some(c) = cluster {
        labels.insert(keys::CLUSTER_LABEL.into(), json!(c));
    }
    let mut annotations = serde_json::Map::new();
    if let Some(h) = hash {
        annotations.insert(keys::IDENTITY_HASH.into(), json!(h));
    }
    serde_json::from_value(json!({
        "apiVersion": keys::API_VERSION,
        "kind": "Activation",
        "metadata": { "name": "r", "labels": labels, "annotations": annotations },
        "status": { "phase": phase },
    }))
    .unwrap()
}

#[test]
fn records_are_partitioned_by_their_cluster_label() {
    let records = [
        record(Some("a"), Some("a1"), PHASE_SUPERSEDED),
        record(Some("a"), Some("a2"), PHASE_ACTIVE),
        record(Some("b"), Some("b0"), PHASE_SUPERSEDED),
        record(Some("b"), Some("b1"), PHASE_DEGRADED),
        record(None, Some("x1"), PHASE_ACTIVE),
        record(Some("a"), None, PHASE_DEPLOYING),
    ];
    let t = Tenancy::from_records(&records, "a");
    assert_eq!(t.legacy.own, HashSet::from(["a1".into(), "a2".into()]));
    assert_eq!(
        t.legacy.others,
        HashMap::from([
            ("b0".into(), "b".into()),
            ("b1".into(), "b".into()),
            // A record without the label is another cluster's, so it can
            // only narrow what this cluster sees and deletes.
            ("x1".into(), "?".into()),
        ])
    );
    assert_eq!(
        t.legacy.others_current,
        HashSet::from(["b1".into(), "x1".into()])
    );
}

#[test]
fn a_cluster_with_no_records_among_others_is_refused() {
    let records = [record(Some("b"), Some("b1"), PHASE_ACTIVE)];
    let err = Tenancy::from_records(&records, "typo")
        .require_records()
        .unwrap_err();
    assert!(
        err.contains("'typo'")
            && err.contains("Kix clusters with deployment records on this cluster: b\n"),
        "{err}"
    );
    assert!(
        Tenancy::from_records(&records, "b")
            .require_records()
            .is_ok()
    );
    assert!(Tenancy::from_records(&[], "new").require_records().is_ok());
}

/// A build that a record lists under `status.orphansKeptFrom` belongs
/// to that record's cluster after its own record is retired, so a full
/// scan and soft gc agree on whose its leftovers are. It is never
/// another cluster's current build.
#[test]
fn builds_a_record_kept_orphans_from_belong_to_its_cluster() {
    let kept = |mut r: DynamicObject, hash: &str| {
        r.data["status"]["orphansKeptFrom"] =
            json!([{ "activation": "old", "identityHash": hash }]);
        r
    };
    let records = [
        kept(record(Some("a"), Some("a2"), PHASE_ACTIVE), "a1"),
        kept(record(Some("b"), Some("b2"), PHASE_ACTIVE), "b1"),
    ];
    let t = Tenancy::from_records(&records, "a");
    assert_eq!(t.legacy.own, HashSet::from(["a1".into(), "a2".into()]));
    assert_eq!(t.legacy.others.get("b1").map(String::as_str), Some("b"));
    assert!(!t.legacy.others_current.contains("b1"));

    // Without the list, the retired build's objects name no record.
    let t = Tenancy::from_records(&[record(Some("a"), Some("a2"), PHASE_ACTIVE)], "a");
    assert!(!t.knows("a1"));
}

/// An object a failed, partly deployed, or deploying record of this
/// cluster names belongs to that pending record. The current record,
/// a Superseded one, and another cluster's failed record make no object
/// pending.
#[test]
fn objects_of_pending_records_name_those_records() {
    let named = |name: &str, phase: &str, cluster: &str, hash: &str| {
        let mut r = record(Some(cluster), Some(hash), phase);
        r.metadata.name = Some(name.into());
        r
    };
    let t = Tenancy::from_records(
        &[
            named("a-cur", PHASE_ACTIVE, "a", "cur"),
            named("a-old", PHASE_SUPERSEDED, "a", "old"),
            named("a-failed", PHASE_FAILED, "a", "fail"),
            named("a-only", PHASE_PARTIAL, "a", "part"),
            named("a-run", PHASE_DEPLOYING, "a", "run"),
            named("b-failed", PHASE_FAILED, "b", "bfail"),
        ],
        "a",
    );
    let obj = |activations: &str| -> DynamicObject {
        serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "c",
                "namespace": "d",
                "annotations": { (keys::ACTIVATIONS): activations },
            },
        }))
        .unwrap()
    };
    assert_eq!(t.pending_records_of(&obj("cur,fail")), ["a-failed"]);
    assert_eq!(
        t.pending_records_of(&obj("part,run,old")),
        ["a-only", "a-run"]
    );
    assert!(t.pending_records_of(&obj("cur,old,bfail")).is_empty());
}

/// An empty cluster name, as the operator uses for a record that names
/// no cluster, owns no record, even one whose label is empty.
#[test]
fn an_empty_cluster_name_owns_nothing() {
    let records = [record(Some(""), Some("e1"), PHASE_ACTIVE)];
    let t = Tenancy::from_records(&records, "");
    assert!(t.legacy.own.is_empty());
    assert!(t.legacy.others_current.contains("e1"));
}

mod both_sources {
    use super::*;
    use crate::cluster::inventory::{Attribution, attribute};
    use crate::cluster::tenancy_fixture::{Rec, State, Written, state};

    /// Kix cluster `a`: its current record, a Superseded one, a failed, a
    /// partly deployed, and a deploying one, and a current record that kept
    /// orphans. Kix cluster `b`: a current record and a failed one.
    fn recs() -> Vec<Rec<'static>> {
        vec![
            Rec {
                name: "a-cur",
                cluster: "a",
                hash: "cur",
                phase: PHASE_ACTIVE,
                current: true,
                objects: &["web", "shared"],
                kept: &["left"],
                ..Rec::default()
            },
            Rec {
                name: "a-old",
                cluster: "a",
                hash: "old",
                phase: PHASE_SUPERSEDED,
                objects: &["web", "gone"],
                ..Rec::default()
            },
            Rec {
                name: "a-failed",
                cluster: "a",
                hash: "fail",
                phase: PHASE_FAILED,
                objects: &["web", "tried"],
                ..Rec::default()
            },
            Rec {
                name: "a-only",
                cluster: "a",
                hash: "part",
                phase: PHASE_PARTIAL,
                objects: &["web", "added"],
                ..Rec::default()
            },
            Rec {
                name: "a-run",
                cluster: "a",
                hash: "run",
                phase: PHASE_DEPLOYING,
                objects: &["web", "coming"],
                ..Rec::default()
            },
            Rec {
                name: "b-cur",
                cluster: "b",
                hash: "bcur",
                phase: PHASE_ACTIVE,
                current: true,
                objects: &["theirs", "shared"],
                kept: &["their-left"],
                ..Rec::default()
            },
            Rec {
                name: "b-failed",
                cluster: "b",
                hash: "bfail",
                phase: PHASE_FAILED,
                objects: &["their-try"],
                ..Rec::default()
            },
        ]
    }

    const OBJECTS: &[&str] = &[
        "web",
        "shared",
        "left",
        "tried",
        "added",
        "coming",
        "theirs",
        "their-left",
        "their-try",
    ];

    /// Return the answers `tenancy` gives for each object of `state`.
    fn answers(state: &State, tenancy: &Tenancy) -> Vec<String> {
        OBJECTS
            .iter()
            .map(|name| {
                let obj = state.object(name);
                format!(
                    "{name}: owners {:?}, others {:?}, pending {:?}, {:?}",
                    tenancy.owners_of(&obj),
                    tenancy.still_deployed_by_others(&obj),
                    tenancy.pending_records_of(&obj),
                    attribute(&obj, tenancy),
                )
            })
            .collect()
    }

    /// Every combination of sources gives the same answers for both Kix
    /// clusters: each object belongs to the clusters whose current, pending,
    /// or kept records name it, and another cluster's kept orphans do not
    /// stop a prune.
    #[test]
    fn each_source_gives_the_same_answers() {
        let mut seen = Vec::new();
        for a in [Written::Records, Written::Revisions] {
            for b in [Written::Records, Written::Revisions] {
                let state = state(&recs(), |c| if c == "a" { a } else { b });
                for cluster in ["a", "b"] {
                    let tenancy = state.tenancy(cluster);
                    assert_eq!(
                        tenancy.source_of("a") == Source::Revisions,
                        a == Written::Revisions
                    );
                    assert!(tenancy.problems().is_empty(), "{:?}", tenancy.problems());
                    seen.push((cluster, (a, b), answers(&state, &tenancy)));
                }
            }
        }
        for cluster in ["a", "b"] {
            let mut of: Vec<&Vec<String>> = seen
                .iter()
                .filter(|(c, _, _)| *c == cluster)
                .map(|(_, _, answers)| answers)
                .collect();
            let first = of.remove(0);
            for other in of {
                assert_eq!(first, other, "cluster {cluster}");
            }
        }
        let state = state(&recs(), |_| Written::Revisions);
        let a = state.tenancy("a");
        let shared = state.object("shared");
        assert_eq!(
            attribute(&shared, &a),
            Attribution::Shared(vec!["b".into()])
        );
        assert_eq!(a.still_deployed_by_others(&shared), ["b"]);
        assert!(
            a.still_deployed_by_others(&state.object("their-left"))
                .is_empty()
        );
        assert_eq!(a.pending_records_of(&state.object("tried")), ["a-failed"]);
        assert_eq!(a.pending_records_of(&state.object("added")), ["a-only"]);
        assert_eq!(a.pending_records_of(&state.object("coming")), ["a-run"]);
        assert!(a.pending_records_of(&state.object("web")).len() == 3);
        assert_eq!(attribute(&state.object("left"), &a), Attribution::Ours);
    }

    /// A sweep narrowed to one Kix cluster keeps the same objects from
    /// either source, and a sweep narrowed to the records a plan compares
    /// with keeps the same objects whether it names their hashes or their
    /// revisions.
    #[test]
    fn a_sweep_keeps_the_same_objects_from_either_source() {
        use crate::cluster::inventory::{SweepScope, partition_sweep, scope_sweep};
        let names = |objs: &[DynamicObject]| {
            let mut v: Vec<String> = objs
                .iter()
                .filter_map(|o| o.metadata.name.clone())
                .collect();
            v.sort();
            v
        };
        let mut seen = Vec::new();
        for written in [Written::Records, Written::Revisions] {
            let mut state = state(&recs(), |_| written);
            // Only a Superseded record names it, which a cluster read from
            // revisions keeps no revisions for.
            state.objects.retain(|o| o["metadata"]["name"] != "gone");
            let objects: Vec<DynamicObject> = state
                .objects
                .iter()
                .map(|o| serde_json::from_value(o.clone()).unwrap())
                .collect();
            let tenancy = state.tenancy("a");
            let cluster = scope_sweep(
                partition_sweep(objects.clone()),
                SweepScope::Cluster("a"),
                tenancy.clone(),
            );
            let hashes: HashSet<String> = ["cur", "fail", "part", "k-cur"].map(String::from).into();
            let revisions: BTreeSet<String> = ["a-cur", "a-failed", "a-only"]
                .iter()
                .flat_map(|r| {
                    ["instance", "clusterLevel", "keptOrphans"].map(|f| state.revision_named(r, f))
                })
                .filter(|n| !n.is_empty())
                .collect();
            let scope = match written {
                Written::Records => SweepScope::Records {
                    cluster: "a",
                    hashes: &hashes,
                },
                Written::Revisions => SweepScope::Revisions {
                    cluster: "a",
                    names: &revisions,
                },
            };
            let previous = scope_sweep(partition_sweep(objects), scope, tenancy);
            seen.push((
                names(&cluster.managed),
                cluster.foreign,
                names(&previous.managed),
                previous.other_builds,
            ));
        }
        assert_eq!(seen[0], seen[1]);
        assert_eq!(
            seen[0].2,
            ["added", "left", "shared", "tried", "web"].map(String::from)
        );
        assert_eq!(seen[0].3, 1, "the deploying record's object");
    }

    /// Each Activation record belongs to its own Kix cluster whichever
    /// source that cluster is read from, so a sweep narrowed to one Kix
    /// cluster keeps its records and leaves out the other cluster's.
    #[test]
    fn a_record_belongs_to_its_cluster_from_either_source() {
        for written in [Written::Records, Written::Revisions] {
            let state = state(&recs(), |_| written);
            let a = state.tenancy("a");
            for value in &state.records {
                let record: DynamicObject = serde_json::from_value(value.clone()).unwrap();
                let cluster = value["metadata"]["labels"][keys::CLUSTER_LABEL]
                    .as_str()
                    .unwrap()
                    .to_string();
                let expected = if cluster == "a" {
                    Attribution::Ours
                } else {
                    Attribution::Foreign(vec![cluster])
                };
                assert_eq!(attribute(&record, &a), expected, "{written:?} {value}");
            }
        }
    }

    /// A Kix cluster read from revisions takes nothing from
    /// `kix.run/activations`: an object that names its record's hash and
    /// that no revision names is not its object. Beside it, a Kix cluster
    /// read from records keeps reading the annotation.
    #[test]
    fn each_cluster_reads_from_its_own_source() {
        let state = state(&recs(), |c| {
            if c == "a" {
                Written::Revisions
            } else {
                Written::Records
            }
        });
        let a = state.tenancy("a");
        assert_eq!(a.source_of("a"), Source::Revisions);
        assert_eq!(a.source_of("b"), Source::Records);
        let stamped = |stamps: &[&str], name: &str| -> DynamicObject {
            serde_json::from_value(crate::cluster::tenancy_fixture::object_of(
                name,
                &stamps.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            ))
            .unwrap()
        };
        assert!(a.owners_of(&stamped(&["cur"], "stray")).is_empty());
        assert_eq!(a.owners_of(&stamped(&["bcur"], "stray")), ["b"]);
        assert_eq!(
            a.still_deployed_by_others(&stamped(&["bcur"], "stray")),
            ["b"]
        );
        assert_eq!(a.owners_of(&state.object("web")), ["a"]);
    }

    /// gc may delete only what the kept-orphans revision names and no other
    /// revision of a needed record names. A cluster read from records gives
    /// no answer, and gc decides as before.
    #[test]
    fn gc_deletes_only_what_the_kept_orphans_revision_alone_names() {
        let mut recs = recs();
        recs[0].kept = &["left", "added"];
        let revisions = state(&recs, |_| Written::Revisions);
        let a = revisions.tenancy("a");
        assert_eq!(a.gc_may_delete(&revisions.object("left")), Some(true));
        // A deploy with `--only` added it back, so gc holds it.
        assert_eq!(a.gc_may_delete(&revisions.object("added")), Some(false));
        assert_eq!(a.pending_records_of(&revisions.object("added")), ["a-only"]);
        assert_eq!(a.gc_may_delete(&revisions.object("web")), Some(false));
        assert_eq!(a.gc_may_delete(&revisions.object("theirs")), None);
        let records = state(&recs, |_| Written::Records);
        assert_eq!(
            records.tenancy("a").gc_may_delete(&records.object("left")),
            None
        );
    }

    /// A revision a record names that is missing is a problem that names
    /// the revision and the record, and a command that deletes refuses on
    /// it. The rest is read from what is there.
    #[test]
    fn a_missing_revision_is_a_problem_that_names_it() {
        let mut state = state(&recs(), |_| Written::Revisions);
        let missing = state.revision_named("a-failed", "instance");
        state.remove_revision(&missing);
        let a = state.tenancy("a");
        let err = a.complete().unwrap_err();
        let text = err.to_string();
        assert!(
            text.contains(&missing)
                && text.contains("a-failed")
                && text.contains("A deploy of that record's build writes it again"),
            "{text}"
        );
        assert!(a.complete_for_others().is_ok());
        assert!(a.complete_for_kept().is_ok());
        assert!(a.complete_for_records(&["a-only"]).is_ok());
        assert!(a.complete_for_records(&["a-failed"]).is_err());
        assert!(state.tenancy("b").complete_for_others().is_err());
        assert_eq!(a.owners_of(&state.object("web")), ["a"]);
        assert!(a.owners_of(&state.object("tried")).is_empty());

        let kept = state.revision_named("a-cur", "keptOrphans");
        state.remove_revision(&kept);
        let a = state.tenancy("a");
        let err = a.complete_for_kept().unwrap_err();
        assert!(err.to_string().contains(&kept), "{err}");
    }

    /// A current record whose map this release cannot read leaves its Kix
    /// cluster read from records, and says so.
    #[test]
    fn an_unreadable_current_map_falls_back_to_records() {
        let mut state = state(&recs(), |_| Written::Revisions);
        let current = state
            .records
            .iter_mut()
            .find(|r| r["metadata"]["name"] == "a-cur")
            .unwrap();
        current["status"]["revisions"]["format"] = json!(99);
        let a = state.tenancy("a");
        assert_eq!(a.source_of("a"), Source::Records);
        assert_eq!(a.source_of("b"), Source::Revisions);
        assert!(matches!(
            a.complete().unwrap_err(),
            Problem::UnreadableMap { record, .. } if record == "a-cur"
        ));
    }

    /// The applied hashes say which records' deploys applied an object, as
    /// `kix.run/activations` does for a cluster read from records.
    #[test]
    fn applied_by_follows_the_applied_hashes() {
        let mut recs = recs();
        recs[2].unapplied = &["tried"];
        for written in [Written::Records, Written::Revisions] {
            let state = state(&recs, |_| written);
            let a = state.tenancy("a");
            assert!(
                a.applied_by(&state.object("tried")).is_empty(),
                "{written:?}"
            );
            assert!(
                a.applied_by(&state.object("web")).contains("fail"),
                "{written:?}"
            );
        }
    }

    /// A record of a cluster read from revisions that may still gain a map,
    /// such as a queued one, is not settled, so a prune guard that meets an
    /// object naming it reads again.
    #[test]
    fn a_record_without_its_map_yet_is_not_settled() {
        let mut recs = recs();
        recs.push(Rec {
            name: "a-queued",
            cluster: "a",
            hash: "queued",
            phase: "",
            ..Rec::default()
        });
        let mut state = state(&recs, |_| Written::Revisions);
        let queued = state
            .records
            .iter_mut()
            .find(|r| r["metadata"]["name"] == "a-queued")
            .unwrap();
        queued["status"]
            .as_object_mut()
            .unwrap()
            .remove("revisions");
        let a = state.tenancy("a");
        assert!(!a.knows("queued"));
        assert!(a.knows("cur") && a.knows("fail") && a.knows("old") && a.knows("bcur"));
    }
}
