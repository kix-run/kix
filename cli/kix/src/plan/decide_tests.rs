use std::collections::BTreeMap;

use kube::api::DynamicObject;
use serde_json::json;

use super::*;
use crate::cluster::fieldsv1::{self, KIX_FIELD_MANAGER};
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
                "manager": KIX_FIELD_MANAGER,
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
    fieldsv1::applied_content_hash(&live(name, hash)).unwrap()
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
                Label::Reconciled => "reconciled".to_string(),
                Label::Unchanged => "unchanged".to_string(),
                Label::NotListed => "not listed".to_string(),
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
    let ledger = Ledger::of(&tenancy, true).expect("read from revisions");
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
        [(String::new(), "Secret".to_string())],
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
        manifest("Secret", "hidden", "h-s"),
    ];
    let mut made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    // An object the build makes that the runner does not apply, as the
    // operator leaves out CRDs: no decision, and not an orphan.
    made.insert(id("crd-like"));

    let decided = decide(&new, &made, &live, &ledger, false);
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
            "hidden: skip not listed",
        ]
    );
    assert_eq!(
        decided.orphans,
        [id("cur-orphan"), id("failed-left"), id("kept")]
    );
    // Only an object the build leaves unchanged counts as lost.
    assert_eq!(decided.lost, [id("deleting"), id("never-made")]);
    assert_eq!(decided.unread, ["Secret".to_string()].into());

    // With `--reconcile`, the unchanged object is written again.
    let reconciled = decide(&new, &made, &live, &ledger, true);
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
    let ledger = Ledger::of(&tenancy(&recs), false).unwrap();
    assert!(ledger.taken_in().is_empty());
    let live = LiveObjects::of([live("by-failed", "h-f"), live("failed-left", "h-fl")], []);
    let new = [manifest("ConfigMap", "by-failed", "h-by")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false);
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
    let ledger = Ledger::of(&tenancy(&recs), true).unwrap();
    let record = json!({
        "apiVersion": keys::API_VERSION,
        "kind": RECORD_KIND,
        "metadata": { "name": "cur", "annotations": { (keys::IDENTITY_HASH): "rec-cur" } },
    });
    let obj: DynamicObject = serde_json::from_value(record.clone()).unwrap();
    let live = LiveObjects::of([obj], []);
    let new = [record];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false);
    assert!(matches!(decided.decisions[0].label, Label::Unchanged));
}

/// A Kix cluster that is not read from revisions has no ledger, so its
/// plans compare builds.
#[test]
fn a_cluster_not_read_from_revisions_has_no_ledger() {
    let tenancy = Tenancy::fixture_of_state(CLUSTER, &BTreeMap::new(), &[], &[]);
    assert!(Ledger::of(&tenancy, true).is_none());
}
