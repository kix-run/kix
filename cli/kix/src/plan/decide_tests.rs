use std::collections::BTreeMap;

use kube::api::DynamicObject;
use serde_json::json;

use super::*;
use crate::cluster::activation::Record;
use crate::cluster::field_manager::{FieldManager, LEGACY};
use crate::cluster::fieldsv1;
use crate::cluster::head::HeadStatus;
use crate::cluster::revision::{Revision, RevisionMap, RevisionObject, RevisionSpec, Slot};
use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_DEGRADED, PHASE_FAILED, RECORD_KIND};

const CLUSTER: &str = "a";

/// One record of Kix cluster `a` and what its revisions name.
struct Rec<'a> {
    name: &'a str,
    phase: &'a str,
    current: bool,
    /// Each object its instance revision names, with its build hash.
    objects: &'a [(&'a str, &'a str)],
    /// The applied hash recorded for each build hash.
    applied: &'a [(&'a str, &'a str)],
    /// Each object its kept-orphans revision names, with its build hash.
    kept: &'a [(&'a str, &'a str)],
}

fn revision_object(name: &str, hash: &str) -> RevisionObject {
    RevisionObject {
        hash: hash.into(),
        group: String::new(),
        kind: "ConfigMap".into(),
        namespace: Some("d".into()),
        name: name.into(),
    }
}

fn revision(slot: Slot, objects: &[(&str, &str)]) -> Revision {
    Revision::new(RevisionSpec::new(
        CLUSTER,
        slot,
        objects
            .iter()
            .map(|(name, hash)| revision_object(name, hash))
            .collect(),
    ))
}

/// Return the tenancy of Kix cluster `a` that `recs` give.
fn tenancy(recs: &[Rec<'_>]) -> Tenancy {
    let mut heads = BTreeMap::new();
    let mut records = Vec::new();
    let mut revisions = Vec::new();
    for rec in recs {
        let slot = Slot::Instance {
            namespace: "d".into(),
            name: rec.name.into(),
        };
        let mut instance = revision(slot, rec.objects);
        instance.applied = rec
            .applied
            .iter()
            .map(|(h, a)| (h.to_string(), a.to_string()))
            .collect();
        let cluster_level = revision(Slot::ClusterLevel, &[]);
        let kept = (!rec.kept.is_empty()).then(|| revision(Slot::KeptOrphans, rec.kept));
        let map = RevisionMap {
            instances: [(format!("d/{}", rec.name), instance.name.clone())].into(),
            cluster_level: cluster_level.name.clone(),
            kept_orphans: kept.as_ref().map(|k| k.name.clone()),
        };
        records.push(
            serde_json::from_value::<DynamicObject>(json!({
                "apiVersion": keys::API_VERSION,
                "kind": RECORD_KIND,
                "metadata": {
                    "name": rec.name,
                    "labels": { (keys::CLUSTER_LABEL): CLUSTER },
                    "annotations": { (keys::IDENTITY_HASH): format!("rec-{}", rec.name) },
                },
                "status": { "phase": rec.phase, "revisions": map.to_value() },
            }))
            .unwrap(),
        );
        if rec.current {
            let status: HeadStatus =
                serde_json::from_value(json!({ "current": rec.name, "generation": 1 })).unwrap();
            heads.insert(CLUSTER.to_string(), status);
        }
        revisions.extend([instance, cluster_level]);
        revisions.extend(kept);
    }
    Tenancy::fixture_of_state(CLUSTER, &heads, &records, &revisions)
}

/// Return the live ConfigMap `name` with build hash `hash`, whose one field
/// Kix applied.
fn live(name: &str, hash: &str) -> DynamicObject {
    serde_json::from_value(json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "d",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": { (keys::IDENTITY_HASH): hash },
            "managedFields": [{
                "manager": LEGACY,
                "operation": "Apply",
                "apiVersion": "v1",
                "fieldsV1": { "f:data": { "f:k": {} } },
            }],
        },
        "data": { "k": name },
    }))
    .unwrap()
}

/// Return the new build's ConfigMap `name` with build hash `hash`.
fn manifest(kind: &str, name: &str, hash: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": "d",
            "annotations": { (keys::IDENTITY_HASH): hash },
        },
        "data": { "k": name },
    })
}

fn id(name: &str) -> ResourceId {
    ResourceId::new("", "ConfigMap", "d", name)
}

fn in_sync(name: &str, hash: &str) -> String {
    fieldsv1::applied_content_hash(&live(name, hash), &FieldManager::unmigrated("a")).unwrap()
}

/// Return each decision as `name: action label`.
fn shown(decided: &Decided) -> Vec<String> {
    decided
        .decisions
        .iter()
        .map(|d| {
            let action = match &d.action {
                ChangeAction::Apply(_) => "apply",
                ChangeAction::Recreate(..) => "recreate",
                ChangeAction::Skip(_) => "skip",
                ChangeAction::Orphan(_) => "orphan",
            };
            let label = match &d.label {
                Label::Intended => "intended".to_string(),
                Label::AppliedByRecord(r) => format!("applied by {r}"),
                Label::LeftByDegraded(r) => format!("left by {r}"),
                Label::AppliedHashMissing => "applied hash missing".to_string(),
                Label::RevertsDrift(report) => format!("reverts drift on {}", report.rid.name),
                Label::DriftReported(report) => format!("reports drift on {}", report.rid.name),
                Label::HeldByOtherCluster(report) => {
                    format!("held by another cluster on {}", report.rid.name)
                }
                Label::Reconciled => "reconciled".to_string(),
                Label::Unchanged => "unchanged".to_string(),
            };
            format!("{}: {action} {label}", d.id.name)
        })
        .collect()
}

/// Every rule and every label, each from one object. The current record
/// `cur` is `Degraded`, and `failed` stopped after it wrote `by-failed` and
/// `failed-left`, before it wrote any applied hash.
#[test]
fn the_three_rules_decide_in_order_and_label_each_write() {
    let sync = in_sync("in-sync", "h-sync");
    let recs = [
        Rec {
            name: "cur",
            phase: PHASE_DEGRADED,
            current: true,
            objects: &[
                ("changed", "h-old"),
                ("unreached", "h-new"),
                ("missing-hash", "h-m"),
                ("drifted", "h-d"),
                ("in-sync", "h-sync"),
                ("both", "h-b-old"),
                ("cur-orphan", "h-o"),
                ("crd-like", "h-c"),
                ("gone", "h-g"),
                ("deleting", "h-del"),
                ("never-made", "h-nm"),
            ],
            applied: &[
                ("h-old", "x"),
                ("h-new", "x"),
                ("h-d", "stale"),
                ("h-sync", &sync),
                ("h-o", "x"),
                ("h-del", "x"),
            ],
            kept: &[("kept", "h-k")],
        },
        Rec {
            name: "failed",
            phase: PHASE_FAILED,
            current: false,
            objects: &[
                ("by-failed", "h-f"),
                ("failed-left", "h-fl"),
                ("failed-not-applied", "h-fna"),
            ],
            applied: &[],
            kept: &[],
        },
    ];
    let tenancy = tenancy(&recs);
    let ledger = Ledger::of(&tenancy, true)
        .unwrap()
        .expect("read from revisions");
    assert_eq!(ledger.taken_in(), ["failed"]);

    let mut deleting = live("deleting", "h-del");
    deleting.metadata.deletion_timestamp =
        serde_json::from_value(json!("2026-11-26T10:00:00Z")).unwrap();
    let live = LiveObjects::of(
        [
            live("changed", "h-old"),
            live("unreached", "h-older"),
            live("missing-hash", "h-m"),
            live("drifted", "h-d"),
            live("in-sync", "h-sync"),
            live("both", "h-b-old"),
            live("by-failed", "h-f"),
            deleting,
            live("cur-orphan", "h-o"),
            live("kept", "h-k"),
            live("failed-left", "h-fl"),
            live("failed-not-applied", "h-someone-else"),
            live("crd-like", "h-c"),
        ],
        [],
    );
    let new = [
        manifest("ConfigMap", "absent", "h-a"),
        manifest("ConfigMap", "changed", "h-changed"),
        manifest("ConfigMap", "unreached", "h-new"),
        manifest("ConfigMap", "by-failed", "h-by"),
        manifest("ConfigMap", "missing-hash", "h-m"),
        manifest("ConfigMap", "drifted", "h-d"),
        manifest("ConfigMap", "in-sync", "h-sync"),
        manifest("ConfigMap", "both", "h-b-new"),
        manifest("ConfigMap", "deleting", "h-del"),
        manifest("ConfigMap", "never-made", "h-nm"),
    ];
    let mut made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    // An object the build makes that the runner does not apply, as the
    // operator leaves out CRDs: no decision, and not an orphan.
    made.insert(id("crd-like"));

    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(
        shown(&decided),
        [
            "absent: apply intended",
            "changed: apply intended",
            "unreached: apply left by cur",
            "by-failed: apply applied by failed",
            "missing-hash: apply applied hash missing",
            "drifted: apply reverts drift on drifted",
            "in-sync: skip unchanged",
            // Rule 1 comes first: a changed build hash is an intended
            // change, whatever the applied hash says.
            "both: apply intended",
            "deleting: apply intended",
            // Gone, and the Degraded record has no applied hash for it.
            "never-made: apply left by cur",
        ]
    );
    assert_eq!(
        decided.orphans,
        [id("cur-orphan"), id("failed-left"), id("kept")]
    );
    // Only an object the build leaves unchanged counts as lost.
    assert_eq!(decided.lost, [id("deleting"), id("never-made")]);
    assert!(decided.unknown.is_empty());

    // With `--reconcile`, the unchanged object is written again.
    let reconciled = decide(&new, &made, &live, &ledger, true, true).unwrap();
    assert!(shown(&reconciled).contains(&"in-sync: apply reconciled".to_string()));
}

/// While another deploy may be applying objects, a `Failed` record's
/// objects are not taken in and its writes are not labelled as its own.
#[test]
fn a_failed_record_is_left_out_while_another_deploy_may_run() {
    let recs = [
        Rec {
            name: "cur",
            phase: PHASE_ACTIVE,
            current: true,
            objects: &[],
            applied: &[],
            kept: &[],
        },
        Rec {
            name: "failed",
            phase: PHASE_FAILED,
            current: false,
            objects: &[("by-failed", "h-f"), ("failed-left", "h-fl")],
            applied: &[],
            kept: &[],
        },
    ];
    let ledger = Ledger::of(&tenancy(&recs), false).unwrap().unwrap();
    assert!(ledger.taken_in().is_empty());
    let live = LiveObjects::of([live("by-failed", "h-f"), live("failed-left", "h-fl")], []);
    let new = [manifest("ConfigMap", "by-failed", "h-by")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&decided), ["by-failed: apply intended"]);
    assert!(decided.orphans.is_empty());
}

/// The Activation record has no applied hash, because no revision names
/// it, so an unchanged record is left alone.
#[test]
fn an_unchanged_record_is_left_alone() {
    let recs = [Rec {
        name: "cur",
        phase: PHASE_ACTIVE,
        current: true,
        objects: &[],
        applied: &[],
        kept: &[],
    }];
    let ledger = Ledger::of(&tenancy(&recs), true).unwrap().unwrap();
    let record = json!({
        "apiVersion": keys::API_VERSION,
        "kind": RECORD_KIND,
        "metadata": { "name": "cur", "annotations": { (keys::IDENTITY_HASH): "rec-cur" } },
    });
    let obj: DynamicObject = serde_json::from_value(record.clone()).unwrap();
    let live = LiveObjects::of([obj], []);
    let new = [record];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert!(matches!(decided.decisions[0].label, Label::Unchanged));
}

/// A Kix cluster that is not read from revisions has no ledger from
/// revisions, so a plan reads it from its notes ([`Ledger::of_notes`]).
#[test]
fn a_cluster_not_read_from_revisions_has_no_ledger() {
    let tenancy = Tenancy::fixture_of_state(CLUSTER, &BTreeMap::new(), &[], &[]);
    assert!(Ledger::of(&tenancy, true).unwrap().is_none());
}

/// The choice of planner fails closed: a tenancy that could not list the
/// revisions, or read the current record's map, refuses rather than plans
/// by comparing builds.
#[test]
fn a_tenancy_that_could_not_read_the_revisions_has_no_ledger_and_no_fallback() {
    let recs = [Rec {
        name: "cur",
        phase: PHASE_ACTIVE,
        current: true,
        objects: &[("web", "h-w")],
        applied: &[],
        kept: &[],
    }];
    assert!(Ledger::of(&tenancy(&recs), true).unwrap().is_some());
    let heads: BTreeMap<String, HeadStatus> = [(
        CLUSTER.to_string(),
        serde_json::from_value(json!({ "current": "cur", "generation": 1 })).unwrap(),
    )]
    .into();
    let failed = Tenancy::from_state(CLUSTER, &heads, &[], Err("forbidden".into()));
    assert!(matches!(
        Ledger::of(&failed, true),
        Err(Problem::Revisions { .. })
    ));
}

/// Return the tenancy of one `Active` record `cur` whose instance revision
/// names `objects` with the applied hashes `applied`, and whose
/// kept-orphans revision names `kept`.
fn current(objects: &[(&str, &str)], applied: &[(&str, &str)], kept: &[(&str, &str)]) -> Ledger {
    let recs = [Rec {
        name: "cur",
        phase: PHASE_ACTIVE,
        current: true,
        objects,
        applied,
        kept,
    }];
    Ledger::of(&tenancy(&recs), true).unwrap().unwrap()
}

/// An object of the build whose kind the cluster does not serve yet is
/// absent: the deploy applies it once its kind is served. A candidate whose
/// kind is not served is not known to be gone, so it keeps its place in the
/// kept-orphans revision with the hash the records give it.
#[test]
fn an_unserved_kind_is_absent_for_the_build_and_not_known_for_a_candidate() {
    let ledger = current(&[("web", "h-w"), ("old", "h-o")], &[], &[]);
    let live = LiveObjects::of([], []).unserved([(String::new(), "ConfigMap".to_string())]);
    let new = [manifest("ConfigMap", "web", "h-w")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&decided), ["web: apply intended"]);
    assert!(decided.orphans.is_empty());
    assert_eq!(decided.unknown, [revision_object("old", "h-o")]);
}

/// The plan refuses when the account may neither list nor get the objects
/// of a kind it must read, whether an object of the build or a candidate is
/// of that kind. It never skips a write the build makes.
#[test]
fn an_object_this_account_cannot_read_stops_the_plan() {
    let ledger = current(&[("old", "h-o")], &[], &[]);
    let unread = || LiveObjects::of([], [(String::new(), "ConfigMap".to_string())]);
    let new = [manifest("ConfigMap", "web", "h-w")];
    let made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    let refused = decide(&new, &made, &unread(), &ledger, false, true).unwrap_err();
    assert_eq!(refused.resources, ["configmaps"]);
    assert!(
        refused.to_string().contains("`list` on `configmaps`"),
        "{refused}"
    );
    // A candidate alone is enough.
    let refused = decide(&[], &HashSet::new(), &unread(), &ledger, false, true).unwrap_err();
    assert_eq!(refused.resources, ["configmaps"]);
}

/// Kix recorded an applied hash for the object, so an object that now has
/// no Kix field records lost the fields Kix applied: it reverts drift.
#[test]
fn an_object_that_lost_every_kix_field_reverts_drift() {
    let ledger = current(&[("web", "h-w")], &[("h-w", "x")], &[]);
    let mut obj = live("web", "h-w");
    obj.metadata.managed_fields = Some(Vec::new());
    let live = LiveObjects::of([obj], []);
    let new = [manifest("ConfigMap", "web", "h-w")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&decided), ["web: apply reverts drift on web"]);
}

/// Return the live Deployment `web` with build hash `h-w`, which cedes
/// `spec.replicas`, after `scaler` (when given) set `spec.replicas` to
/// `replicas` and took it from Kix, and `editor` (when given) changed the
/// image.
fn deployment(replicas: i64, scaler: Option<&str>, editor: Option<&str>) -> DynamicObject {
    let mut kix_fields = json!({
        "f:metadata": { "f:annotations": { (format!("f:{}", keys::CEDE_FIELDS)): {} } },
        "f:spec": { "f:replicas": {}, "f:template": { "f:spec": { "f:image": {} } } },
    });
    let mut entries = Vec::new();
    if let Some(scaler) = scaler {
        kix_fields["f:spec"]
            .as_object_mut()
            .unwrap()
            .remove("f:replicas");
        entries.push(json!({
            "manager": scaler, "operation": "Update", "subresource": "scale",
            "fieldsV1": { "f:spec": { "f:replicas": {} } },
        }));
    }
    let mut image = "web:1";
    if let Some(editor) = editor {
        kix_fields["f:spec"]["f:template"]["f:spec"]
            .as_object_mut()
            .unwrap()
            .remove("f:image");
        entries.push(json!({
            "manager": editor, "operation": "Update",
            "fieldsV1": { "f:spec": { "f:template": { "f:spec": { "f:image": {} } } } },
        }));
        image = "web:edited";
    }
    entries.insert(
        0,
        json!({ "manager": LEGACY, "operation": "Apply", "fieldsV1": kix_fields }),
    );
    serde_json::from_value(json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": "web",
            "namespace": "d",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": {
                (keys::IDENTITY_HASH): "h-w",
                (keys::CEDE_FIELDS): ".spec.replicas",
            },
            "resourceVersion": "7",
            "managedFields": entries,
        },
        "spec": { "replicas": replicas, "template": { "spec": { "image": image } } },
    }))
    .unwrap()
}

fn deployment_manifest() -> Value {
    json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": "web",
            "namespace": "d",
            "annotations": {
                (keys::IDENTITY_HASH): "h-w",
                (keys::CEDE_FIELDS): ".spec.replicas",
            },
        },
        "spec": { "replicas": 1, "template": { "spec": { "image": "web:1" } } },
    })
}

fn deployment_ledger(applied: &str) -> Ledger {
    let recs = [Rec {
        name: "cur",
        phase: PHASE_ACTIVE,
        current: true,
        objects: &[],
        applied: &[],
        kept: &[],
    }];
    let mut ledger = Ledger::of(&tenancy(&recs), true).unwrap().unwrap();
    let mut revision = Revision::new(RevisionSpec::new(
        CLUSTER,
        Slot::Instance {
            namespace: "d".into(),
            name: "cur".into(),
        },
        vec![RevisionObject {
            hash: "h-w".into(),
            group: "apps".into(),
            kind: "Deployment".into(),
            namespace: Some("d".into()),
            name: "web".into(),
        }],
    ));
    revision.applied = [("h-w".to_string(), applied.to_string())].into();
    let record = Record {
        name: "cur".into(),
        phase: PHASE_ACTIVE.into(),
        revisions: Some(Ok(RevisionMap {
            instances: [("d/cur".to_string(), revision.name.clone())].into(),
            cluster_level: String::new(),
            kept_orphans: None,
        })),
        ..Record::default()
    };
    ledger.applied = AppliedHashes::of([&record], [&revision]);
    ledger
}

/// A field the object cedes is out of the applied hash, so an autoscaler
/// that changes it leaves the object in sync, for the CLI and the operator.
#[test]
fn an_autoscaled_ceded_field_is_not_drift() {
    let applied =
        fieldsv1::applied_content_hash(&deployment(1, None, None), &FieldManager::unmigrated("a"))
            .unwrap();
    let ledger = deployment_ledger(&applied);
    let live = LiveObjects::of([deployment(5, Some("hpa"), None)], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();
    for forces in [true, false] {
        let decided = decide(&new, &made, &live, &ledger, false, forces).unwrap();
        assert_eq!(shown(&decided), ["web: skip unchanged"], "forces {forces}");
    }
}

/// A forced revert of drift leaves out each ceded field another manager
/// owns, so it takes back the edited image and leaves the replicas to the
/// autoscaler. It records the `resourceVersion` it read. The operator,
/// which never forces, writes nothing and reports the drift, because
/// another manager owns a field the build sets.
#[test]
fn a_forced_revert_leaves_ceded_fields_to_their_manager_and_the_operator_reports_it() {
    let applied =
        fieldsv1::applied_content_hash(&deployment(1, None, None), &FieldManager::unmigrated("a"))
            .unwrap();
    let ledger = deployment_ledger(&applied);
    let live = LiveObjects::of([deployment(5, Some("hpa"), Some("kubectl-edit"))], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();

    let cli = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&cli), ["web: apply reverts drift on web"]);
    let ChangeAction::Apply(sent) = &cli.decisions[0].action else {
        panic!("an apply");
    };
    assert_eq!(sent.pointer("/spec/replicas"), None, "{sent}");
    assert_eq!(
        sent.pointer("/spec/template/spec/image"),
        Some(&json!("web:1"))
    );
    assert_eq!(cli.decisions[0].resource_version.as_deref(), Some("7"));
    let Label::RevertsDrift(report) = &cli.decisions[0].label else {
        panic!("reverts drift");
    };
    // The ceded field's manager is not named as having changed it.
    let owners = crate::plan::document::DriftOwner::of_report(report);
    assert_eq!(owners.len(), 1, "{owners:?}");
    assert_eq!(owners[0].manager, "kubectl-edit");

    let operator = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&operator), ["web: skip reports drift on web"]);
}

/// Drift that no other manager owns, such as a removed field, is applied
/// by the operator too, without force: the apply cannot conflict.
#[test]
fn the_operator_applies_drift_no_other_manager_owns() {
    let ledger = current(&[("web", "h-w")], &[("h-w", "stale")], &[]);
    let live = LiveObjects::of([live("web", "h-w")], []);
    let new = [manifest("ConfigMap", "web", "h-w")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&decided), ["web: apply reverts drift on web"]);
}

/// Return `obj` with its `managedFields` entries under `managers` only.
fn written_by(mut obj: DynamicObject, managers: &[&str]) -> DynamicObject {
    let entries = managers
        .iter()
        .map(|m| json!({ "manager": m, "operation": "Apply", "apiVersion": "v1" }))
        .collect::<Vec<_>>();
    obj.metadata.managed_fields = serde_json::from_value(json!(entries)).unwrap();
    obj
}

/// An object that a `Degraded` current record or a `Failed` record names is
/// taken in only when it has an entry under this Kix cluster's field
/// manager, or the legacy one. One that only another Kix cluster wrote came
/// from elsewhere and stays. An `Active` current record's objects and kept
/// orphans need no entry.
#[test]
fn leftovers_are_taken_in_only_with_the_clusters_own_entry() {
    let recs = |phase| {
        [
            Rec {
                name: "cur",
                phase,
                current: true,
                objects: &[("own", "h-own"), ("legacy", "h-l"), ("other", "h-x")],
                applied: &[],
                kept: &[("kept-other", "h-ko")],
            },
            Rec {
                name: "failed",
                phase: PHASE_FAILED,
                current: false,
                objects: &[("failed-own", "h-fo"), ("failed-other", "h-fx")],
                applied: &[],
                kept: &[],
            },
        ]
    };
    let live = LiveObjects::of(
        [
            written_by(live("own", "h-own"), &["kix/a"]),
            written_by(live("legacy", "h-l"), &[LEGACY]),
            written_by(live("other", "h-x"), &["kix/b"]),
            written_by(live("kept-other", "h-ko"), &["kix/b"]),
            written_by(live("failed-own", "h-fo"), &["kix/a", "kix/b"]),
            written_by(live("failed-other", "h-fx"), &["kix/b"]),
        ],
        [],
    );
    let made = HashSet::new();

    let degraded = Ledger::of(&tenancy(&recs(PHASE_DEGRADED)), true)
        .unwrap()
        .unwrap();
    let decided = decide(&[], &made, &live, &degraded, false, true).unwrap();
    assert_eq!(
        decided.orphans,
        [id("failed-own"), id("kept-other"), id("legacy"), id("own")]
    );

    let active = Ledger::of(&tenancy(&recs(PHASE_ACTIVE)), true)
        .unwrap()
        .unwrap();
    let decided = decide(&[], &made, &live, &active, false, true).unwrap();
    assert_eq!(
        decided.orphans,
        [
            id("failed-own"),
            id("kept-other"),
            id("legacy"),
            id("other"),
            id("own")
        ]
    );
}

/// Another Kix cluster applied the image with another value. The CLI sends
/// the apply without force, so Kubernetes refuses it and names that Kix
/// cluster, rather than taking the field and moving the refusal to the
/// other cluster's next deploy. The operator reports the drift.
#[test]
fn a_field_another_kix_cluster_holds_is_not_taken_by_force() {
    let applied =
        fieldsv1::applied_content_hash(&deployment(1, None, None), &FieldManager::unmigrated("a"))
            .unwrap();
    let ledger = deployment_ledger(&applied);
    let live = LiveObjects::of([deployment(1, None, Some("kix/b"))], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();

    let cli = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&cli), ["web: apply held by another cluster on web"]);
    let operator = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&operator), ["web: skip reports drift on web"]);
}

/// Return the live ConfigMap `name` as an older Kix left it: applied under
/// `kix`, with `notes` listing the record hashes that name it and the
/// applied hash it recorded.
fn noted(name: &str, hash: &str, notes: &str) -> DynamicObject {
    let mut obj = live(name, hash);
    let applied = in_sync(name, hash);
    let annotations = obj.metadata.annotations.get_or_insert_default();
    annotations.insert(keys::ACTIVATIONS.into(), notes.into());
    annotations.insert(keys::APPLIED_HASH.into(), applied);
    obj
}

fn legacy_record(name: &str, cluster: &str, phase: &str, kept_from: &[&str]) -> DynamicObject {
    let kept: Vec<Value> = kept_from
        .iter()
        .map(|h| json!({ "activation": format!("{h}-record"), "identityHash": h }))
        .collect();
    serde_json::from_value(json!({
        "apiVersion": keys::API_VERSION,
        "kind": RECORD_KIND,
        "metadata": {
            "name": name,
            "labels": { (keys::CLUSTER_LABEL): cluster },
            "annotations": { (keys::IDENTITY_HASH): format!("rec-{name}") },
        },
        "status": { "phase": phase, (keys::ORPHANS_KEPT_FROM_FIELD): kept },
    }))
    .unwrap()
}

/// A Kix cluster an older Kix deployed last is read from the notes: the
/// current record names what its note lists, the builds under
/// `status.orphansKeptFrom` name kept orphans, and a `Failed` record left
/// what its note lists, with the build hash the object carries. A
/// `Superseded` record and another Kix cluster's record name nothing of
/// it. Every object it holds needs the migration write, and drift is
/// judged as the write leaves it. An object another Kix cluster an older
/// Kix deploys also names keeps its entry under `kix`, so it is not
/// renamed, and the plan applies it without force to add the cluster's
/// own entry.
#[test]
fn a_cluster_not_read_from_revisions_is_read_from_its_notes() {
    let records = [
        legacy_record("cur", CLUSTER, PHASE_ACTIVE, &["old-build"]),
        legacy_record("fail", CLUSTER, PHASE_FAILED, &[]),
        legacy_record("sup", CLUSTER, lifecycle::PHASE_SUPERSEDED, &[]),
        legacy_record("b-cur", "b", PHASE_ACTIVE, &[]),
    ];
    let tenancy = Tenancy::fixture(&records, CLUSTER);
    let swept = [
        noted("same", "h-same", "rec-cur"),
        noted("gone", "h-gone", "rec-cur"),
        noted("kept", "h-kept", "old-build"),
        noted("left", "h-left", "rec-fail"),
        noted("superseded", "h-sup", "rec-sup"),
        noted("b-only", "h-b", "rec-b-cur"),
        noted("shared", "h-shared", "rec-b-cur,rec-cur"),
    ];
    let mut ledger = Ledger::of_notes(&tenancy, &swept, true).unwrap();
    ledger.deploying(Some("rec-new"));
    assert!(ledger.is_from_notes());
    assert_eq!(ledger.taken_in(), ["fail"]);
    let new = [
        manifest("ConfigMap", "same", "h-same"),
        manifest("ConfigMap", "shared", "h-shared"),
        manifest("ConfigMap", "left", "h-left-new"),
    ];
    let made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    let live = LiveObjects::of(swept.iter().cloned(), []);
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(
        shown(&decided),
        [
            "same: skip unchanged",
            "shared: apply held by another cluster on shared",
            "left: apply applied by fail",
        ]
    );
    let names = |ids: &[ResourceId]| ids.iter().map(|r| r.name.clone()).collect::<Vec<_>>();
    assert_eq!(names(&decided.orphans), ["gone", "kept"]);
    assert_eq!(names(&decided.migrations), ["left", "same", "shared"]);
    assert_eq!(names(&decided.renamed), ["left", "same"]);
    assert_eq!(names(&decided.orphan_migrations), ["gone", "kept"]);
    let carried: Vec<&str> = decided
        .carried
        .iter()
        .map(|(o, _)| o.name.as_str())
        .collect();
    assert_eq!(carried, ["same"]);
}
