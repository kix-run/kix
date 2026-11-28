use std::collections::BTreeMap;

use kube::api::DynamicObject;
use serde_json::json;

use super::*;
use crate::cluster::field_manager::{FieldManager, LEGACY};
use crate::cluster::head::HeadStatus;
use crate::cluster::revision::{Revision, RevisionMap, RevisionObject, RevisionSpec, Slot};
use crate::manifest::hash::object_hash;
use crate::manifest::lifecycle::{PHASE_ACTIVE, PHASE_DEGRADED, PHASE_FAILED, RECORD_KIND};

const CLUSTER: &str = "a";

/// The new build's ConfigMap `name` holding `v`. Its build hash moves with
/// `deps`, as a changed dependency moves it, and its object hash does not.
fn manifest_with(name: &str, v: &str, deps: &str) -> Value {
    json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "d",
            "annotations": {
                (keys::IDENTITY_HASH): format!("h-{name}-{v}-{deps}"),
                (keys::DEPENDS_ON): deps,
                (keys::PACKAGE): "web",
            },
        },
        "data": { "k": v },
    })
}

fn manifest(name: &str, v: &str) -> Value {
    manifest_with(name, v, "")
}

/// The object hash of [`manifest`].
fn oh(name: &str, v: &str) -> String {
    object_hash(&manifest(name, v))
}

/// The live ConfigMap `name` holding `v`, whose one field `manager` applied.
fn live_as(name: &str, v: &str, manager: &str) -> DynamicObject {
    serde_json::from_value(json!({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": name,
            "namespace": "d",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "managedFields": [{
                "manager": manager,
                "operation": "Apply",
                "apiVersion": "v1",
                "fieldsV1": { "f:data": { "f:k": {} } },
            }],
        },
        "data": { "k": v },
    }))
    .unwrap()
}

fn live(name: &str, v: &str) -> DynamicObject {
    live_as(name, v, "kix/a")
}

/// The applied hash of [`live`].
fn applied(name: &str, v: &str) -> String {
    fieldsv1::applied_content_hash(&live(name, v), &FieldManager::of(CLUSTER)).unwrap()
}

fn id(name: &str) -> ResourceId {
    ResourceId::new("", "ConfigMap", "d", name)
}

/// One record of Kix cluster `a` and what its revisions name.
struct Rec {
    name: &'static str,
    phase: &'static str,
    current: bool,
    /// Each object its instance revision names, with its hash.
    objects: Vec<(ResourceId, String)>,
    /// The applied hash recorded for each hash.
    applied: Vec<(String, String)>,
    /// Each object its kept-orphans revision names, with its hash.
    kept: Vec<(ResourceId, String)>,
}

impl Rec {
    fn new(name: &'static str, phase: &'static str, current: bool) -> Rec {
        Rec {
            name,
            phase,
            current,
            objects: Vec::new(),
            applied: Vec::new(),
            kept: Vec::new(),
        }
    }

    /// Name `name` at `v`, with no applied hash.
    fn names(mut self, name: &str, v: &str) -> Rec {
        self.objects.push((id(name), oh(name, v)));
        self
    }

    /// Name `name` at `v`, with the applied hash of [`live`] at `v`.
    fn applied(mut self, name: &str, v: &str) -> Rec {
        self.objects.push((id(name), oh(name, v)));
        self.applied.push((oh(name, v), applied(name, v)));
        self
    }

    /// Name `name` with hash `hash` and applied hash `recorded`.
    fn recorded(self, name: &str, hash: &str, recorded: &str) -> Rec {
        self.recorded_as(id(name), hash, recorded)
    }

    /// Name the object `rid` with hash `hash` and applied hash `recorded`.
    fn recorded_as(mut self, rid: ResourceId, hash: &str, recorded: &str) -> Rec {
        self.objects.push((rid, hash.into()));
        self.applied.push((hash.into(), recorded.into()));
        self
    }

    /// Name the object `rid` with hash `hash`, with no applied hash.
    fn names_as(mut self, rid: ResourceId, hash: &str) -> Rec {
        self.objects.push((rid, hash.into()));
        self
    }

    fn kept(mut self, name: &str, hash: &str) -> Rec {
        self.kept.push((id(name), hash.into()));
        self
    }
}

fn revision(slot: Slot, objects: &[(ResourceId, String)]) -> Revision {
    Revision::new(RevisionSpec::new(
        CLUSTER,
        slot,
        objects
            .iter()
            .map(|(rid, hash)| RevisionObject::of_id(hash, rid))
            .collect(),
    ))
}

/// Return the tenancy of Kix cluster `a` that `recs` give.
fn tenancy(recs: &[Rec]) -> Tenancy {
    let mut heads = BTreeMap::new();
    let mut records = Vec::new();
    let mut revisions = Vec::new();
    for rec in recs {
        let slot = Slot::Instance {
            namespace: "d".into(),
            name: rec.name.into(),
            lifecycle: None,
        };
        let mut instance = revision(slot, &rec.objects);
        instance.applied = rec.applied.iter().cloned().collect();
        let cluster_level = revision(Slot::ClusterLevel, &[]);
        let kept = (!rec.kept.is_empty()).then(|| revision(Slot::KeptOrphans, &rec.kept));
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

fn ledger(recs: &[Rec]) -> Ledger {
    Ledger::of(&tenancy(recs), true).unwrap()
}

/// Decide `new` against `live` as the CLI does, which forces.
fn decide_cli(new: &[Value], live: Vec<DynamicObject>, ledger: &Ledger) -> Decided {
    let made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    decide(new, &made, &LiveObjects::of(live, []), ledger, false, true).unwrap()
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
                Label::Unfinished {
                    record,
                    drift: Some(report),
                } => format!("unfinished {record} reverts drift on {}", report.rid.name),
                Label::Unfinished {
                    record,
                    drift: None,
                } => format!("unfinished {record}"),
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

/// Return whether the CLI applies the decision of `name` with force.
fn forced(decided: &Decided, name: &str) -> bool {
    decided
        .decisions
        .iter()
        .find(|d| d.id.name == name)
        .is_some_and(|d| d.label.reverts_drift())
}

// The eight cases of the one rule. The current record `cur` applied `web`
// at `1` and holds its applied hash.

#[test]
fn a_missing_object_is_applied() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1")]);
    let decided = decide_cli(&[manifest("web", "1")], vec![], &ledger);
    assert_eq!(shown(&decided), ["web: apply intended"]);
}

#[test]
fn a_change_of_content_in_the_build_is_applied() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1")]);
    let decided = decide_cli(&[manifest("web", "2")], vec![live("web", "1")], &ledger);
    assert_eq!(shown(&decided), ["web: apply intended"]);
    assert!(!forced(&decided, "web"));
}

/// A changed dependency moves the object's build hash and its dependency
/// note, which Kix does not send, so the object hash stays and nothing is
/// written.
#[test]
fn a_change_of_dependencies_alone_is_skipped() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1")]);
    let moved = manifest_with("web", "1", "requires:h-dep-2");
    assert_ne!(
        keys::get(&moved, keys::IDENTITY_HASH),
        keys::get(&manifest("web", "1"), keys::IDENTITY_HASH)
    );
    assert_eq!(object_hash(&moved), oh("web", "1"));
    let decided = decide_cli(&[moved], vec![live("web", "1")], &ledger);
    assert_eq!(shown(&decided), ["web: skip unchanged"]);
}

/// A run that applied `web` at `2` and died before it wrote its applied
/// hashes left a `Failed` record that names it without one. The deploy of
/// that build applies it again, which changes nothing, and records it.
#[test]
fn a_run_that_died_before_its_status_write_is_applied_again() {
    let ledger = ledger(&[
        Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1"),
        Rec::new("killed", PHASE_FAILED, false).names("web", "2"),
    ]);
    let decided = decide_cli(&[manifest("web", "2")], vec![live("web", "2")], &ledger);
    assert_eq!(shown(&decided), ["web: apply applied hash missing"]);
    assert!(!forced(&decided, "web"));
}

#[test]
fn an_edit_by_hand_reverts_drift() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1")]);
    let decided = decide_cli(
        &[manifest("web", "1")],
        vec![live("web", "edited")],
        &ledger,
    );
    assert_eq!(shown(&decided), ["web: apply reverts drift on web"]);
    assert!(forced(&decided, "web"));
}

/// A `Failed` deploy wrote `web` at `2` and recorded it. Going back to `1`
/// applies it without force, and the label names that deploy.
#[test]
fn an_object_a_failed_deploy_wrote_is_applied() {
    let ledger = ledger(&[
        Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1"),
        Rec::new("failed", PHASE_FAILED, false).applied("web", "2"),
    ]);
    let decided = decide_cli(&[manifest("web", "1")], vec![live("web", "2")], &ledger);
    assert_eq!(shown(&decided), ["web: apply applied by failed"]);
    assert!(!forced(&decided, "web"));
}

/// Only a dependency changed, and someone edited the object. Kubernetes
/// refused the unforced write this used to be. It reverts drift now.
#[test]
fn a_change_of_dependencies_and_an_edit_by_hand_revert_drift() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1")]);
    let moved = manifest_with("web", "1", "requires:h-dep-2");
    let decided = decide_cli(&[moved], vec![live("web", "edited")], &ledger);
    assert_eq!(shown(&decided), ["web: apply reverts drift on web"]);
    assert!(forced(&decided, "web"));
}

/// A killed run wrote `web` at `2`, and another tool then took the field.
/// No applied hash matches the live object, and the killed run's record
/// names it without one, so the label says a deploy that did not finish
/// may have written it. It reverts drift.
#[test]
fn a_killed_run_and_another_manager_revert_drift() {
    let ledger = ledger(&[
        Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1"),
        Rec::new("killed", PHASE_FAILED, false).names("web", "2"),
    ]);
    let mut obj = live("web", "2");
    obj.metadata.managed_fields = Some(vec![
        serde_json::from_value(json!({
            "manager": "kix/a", "operation": "Apply", "apiVersion": "v1",
            "fieldsV1": { "f:metadata": { "f:labels": {} } },
        }))
        .unwrap(),
        serde_json::from_value(json!({
            "manager": "kubectl-edit", "operation": "Update", "apiVersion": "v1",
            "fieldsV1": { "f:data": { "f:k": {} } },
        }))
        .unwrap(),
    ]);
    let decided = decide_cli(&[manifest("web", "1")], vec![obj], &ledger);
    assert_eq!(
        shown(&decided),
        ["web: apply unfinished killed reverts drift on web"]
    );
    assert!(forced(&decided, "web"));
}

/// The other labels. The current record `cur` is `Degraded`. An object it
/// names with no applied hash was not reached. A killed run's record names
/// an object the new build changes, which nothing recorded: the write is
/// labelled with that record and sent without force. An `Active` record
/// that names the object with the new build's hash and no applied hash
/// gets one.
#[test]
fn the_labels_come_from_the_records() {
    let ledger = ledger(&[
        Rec::new("cur", PHASE_DEGRADED, true)
            .names("unreached", "2")
            .applied("changed", "1"),
        Rec::new("killed", PHASE_FAILED, false).names("changed", "2"),
    ]);
    let decided = decide_cli(
        &[manifest("unreached", "2"), manifest("changed", "3")],
        vec![live("unreached", "1"), live("changed", "2")],
        &ledger,
    );
    assert_eq!(
        shown(&decided),
        [
            "unreached: apply left by cur",
            "changed: apply unfinished killed"
        ]
    );
    assert!(!forced(&decided, "changed"));

    let ledger = self::ledger(&[Rec::new("cur", PHASE_ACTIVE, true).names("web", "1")]);
    let decided = decide_cli(&[manifest("web", "1")], vec![live("web", "1")], &ledger);
    assert_eq!(shown(&decided), ["web: apply applied hash missing"]);
}

/// Orphans, lost objects, and `--reconcile`. An object the current record
/// names that the build leaves unchanged and that is gone or being deleted
/// is lost. An object the build makes that the runner does not apply, as
/// the operator leaves out CRDs, is no orphan.
#[test]
fn orphans_lost_objects_and_reconcile() {
    let recs = [
        Rec::new("cur", PHASE_ACTIVE, true)
            .applied("in-sync", "1")
            .applied("deleting", "1")
            .applied("gone", "1")
            .applied("cur-orphan", "1")
            .applied("crd-like", "1")
            .kept("kept", "h-k"),
        Rec::new("failed", PHASE_FAILED, false).applied("failed-left", "1"),
    ];
    let ledger = ledger(&recs);
    assert_eq!(ledger.taken_in(), ["failed"]);
    let mut deleting = live("deleting", "1");
    deleting.metadata.deletion_timestamp =
        serde_json::from_value(json!("2026-11-26T10:00:00Z")).unwrap();
    let objects = vec![
        live("in-sync", "1"),
        deleting,
        live("cur-orphan", "1"),
        live("kept", "1"),
        live("failed-left", "1"),
        live("crd-like", "1"),
    ];
    let new = [
        manifest("in-sync", "1"),
        manifest("deleting", "1"),
        manifest("gone", "1"),
    ];
    let mut made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    made.insert(id("crd-like"));
    let live = LiveObjects::of(objects, []);
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(
        shown(&decided),
        [
            "in-sync: skip unchanged",
            "deleting: apply intended",
            "gone: apply intended",
        ]
    );
    assert_eq!(
        decided.orphans,
        [id("cur-orphan"), id("failed-left"), id("kept")]
    );
    assert_eq!(decided.lost, [id("deleting"), id("gone")]);
    let reconciled = decide(&new, &made, &live, &ledger, true, true).unwrap();
    assert!(shown(&reconciled).contains(&"in-sync: apply reconciled".to_string()));
}

/// While another deploy may be applying objects, a `Failed` record's
/// objects are not taken in and its writes are not labelled as its own.
#[test]
fn a_failed_record_is_left_out_while_another_deploy_may_run() {
    let recs = [
        Rec::new("cur", PHASE_ACTIVE, true),
        Rec::new("failed", PHASE_FAILED, false)
            .applied("by-failed", "2")
            .applied("failed-left", "1"),
    ];
    let ledger = Ledger::of(&tenancy(&recs), false).unwrap();
    assert!(ledger.taken_in().is_empty());
    let decided = decide_cli(
        &[manifest("by-failed", "1")],
        vec![live("by-failed", "2"), live("failed-left", "1")],
        &ledger,
    );
    assert_eq!(shown(&decided), ["by-failed: apply intended"]);
    assert!(decided.orphans.is_empty());
}

/// The Activation record has no applied hash, because no revision names
/// it. Its name and its build hash say which build it records, so an
/// unchanged record is left alone.
#[test]
fn an_unchanged_record_is_left_alone() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true)]);
    let record = json!({
        "apiVersion": keys::API_VERSION,
        "kind": RECORD_KIND,
        "metadata": { "name": "cur", "annotations": { (keys::IDENTITY_HASH): "rec-cur" } },
    });
    let obj: DynamicObject = serde_json::from_value(record.clone()).unwrap();
    let decided = decide_cli(&[record], vec![obj], &ledger);
    assert!(matches!(decided.decisions[0].label, Label::Unchanged));
}

/// The choice of planner fails closed: a tenancy that could not list the
/// revisions, or read the current record's map, refuses rather than plans
/// by comparing builds.
#[test]
fn a_tenancy_that_could_not_read_the_revisions_has_no_ledger_and_no_fallback() {
    let recs = [Rec::new("cur", PHASE_ACTIVE, true).names("web", "1")];
    assert!(Ledger::of(&tenancy(&recs), true).is_ok());
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

/// An object of the build whose kind the cluster does not serve yet is
/// absent: the deploy applies it once its kind is served. A candidate whose
/// kind is not served is not known to be gone, so it keeps its place in the
/// kept-orphans revision with the hash the records give it.
#[test]
fn an_unserved_kind_is_absent_for_the_build_and_not_known_for_a_candidate() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true)
        .names("web", "1")
        .names("old", "1")]);
    let live = LiveObjects::of([], []).unserved([(String::new(), "ConfigMap".to_string())]);
    let new = [manifest("web", "1")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&decided), ["web: apply intended"]);
    assert!(decided.orphans.is_empty());
    assert_eq!(
        decided.unknown,
        [RevisionObject::of_id(&oh("old", "1"), &id("old"))]
    );
}

/// The plan refuses when the account may neither list nor get the objects
/// of a kind it must read, whether an object of the build or a candidate is
/// of that kind. It never skips a write the build makes.
#[test]
fn an_object_this_account_cannot_read_stops_the_plan() {
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).names("old", "1")]);
    let unread = || LiveObjects::of([], [(String::new(), "ConfigMap".to_string())]);
    let new = [manifest("web", "1")];
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
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1")]);
    let mut obj = live("web", "1");
    obj.metadata.managed_fields = Some(Vec::new());
    let decided = decide_cli(&[manifest("web", "1")], vec![obj], &ledger);
    assert_eq!(shown(&decided), ["web: apply reverts drift on web"]);
}

/// The applied hash covers every `kix.run/*` annotation Kix sends. A
/// `Failed` or killed deploy of a build that changed only the readiness
/// rule of `web` wrote it, and the deploy of the earlier build applies it
/// again, so the live object does not keep the other build's rule.
#[test]
fn a_kix_annotation_changed_by_a_stopped_deploy_is_applied() {
    let with_rule = |rule: &str| {
        let mut m = manifest("web", "1");
        m["metadata"]["annotations"][keys::READINESS] = json!(rule);
        m
    };
    let live_with_rule = |rule: &str| {
        let mut obj = live("web", "1");
        obj.metadata
            .annotations
            .get_or_insert_default()
            .insert(keys::READINESS.into(), rule.into());
        let entry = &mut obj.metadata.managed_fields.as_mut().unwrap()[0];
        entry.fields_v1.as_mut().unwrap().0["f:metadata"] =
            json!({ "f:annotations": { (format!("f:{}", keys::READINESS)): {} } });
        obj
    };
    let applied_of = |rule: &str| {
        fieldsv1::applied_content_hash(&live_with_rule(rule), &FieldManager::of(CLUSTER)).unwrap()
    };
    let (one, two) = (object_hash(&with_rule("r1")), object_hash(&with_rule("r2")));
    assert_ne!(one, two);
    assert_ne!(applied_of("r1"), applied_of("r2"));
    let cur = || Rec::new("cur", PHASE_ACTIVE, true).recorded("web", &one, &applied_of("r1"));

    let failed = ledger(&[
        cur(),
        Rec::new("failed", PHASE_FAILED, false).recorded("web", &two, &applied_of("r2")),
    ]);
    let decided = decide_cli(&[with_rule("r1")], vec![live_with_rule("r2")], &failed);
    assert_eq!(shown(&decided), ["web: apply applied by failed"]);

    let mut killed = Rec::new("killed", PHASE_FAILED, false);
    killed.objects.push((id("web"), two.clone()));
    let killed = ledger(&[cur(), killed]);
    let decided = decide_cli(&[with_rule("r1")], vec![live_with_rule("r2")], &killed);
    assert_eq!(
        shown(&decided),
        ["web: apply unfinished killed reverts drift on web"]
    );
}

/// An object that moved to another instance and back across a `Failed`
/// deploy sends the same manifest in both builds, because Kix sends no
/// instance note, so the deploy skips it. A live object that still carries
/// the instance note an older Kix wrote gets the migration write, which
/// removes it.
#[test]
fn an_object_that_moved_between_instances_keeps_no_instance_note() {
    let mut other_instance = manifest("web", "1");
    other_instance["metadata"]["annotations"][keys::PACKAGE] = json!("db");
    assert_eq!(object_hash(&other_instance), oh("web", "1"));
    let ledger = ledger(&[
        Rec::new("cur", PHASE_ACTIVE, true).applied("web", "1"),
        Rec::new("failed", PHASE_FAILED, false).applied("web", "1"),
    ]);
    let mut stale = live("web", "1");
    stale
        .metadata
        .annotations
        .get_or_insert_default()
        .insert(keys::PACKAGE.into(), "db".into());
    let decided = decide_cli(&[manifest("web", "1")], vec![stale], &ledger);
    assert_eq!(shown(&decided), ["web: skip unchanged"]);
    assert_eq!(decided.migrations, [id("web")]);
}

/// Return the live Deployment `web`, which cedes `spec.replicas`, after
/// `scaler` (when given) set `spec.replicas` to `replicas` and took it from
/// Kix, and `editor` (when given) changed the image.
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
        json!({ "manager": "kix/a", "operation": "Apply", "fieldsV1": kix_fields }),
    );
    serde_json::from_value(json!({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "name": "web",
            "namespace": "d",
            "labels": { "app.kubernetes.io/managed-by": "kix" },
            "annotations": { (keys::CEDE_FIELDS): ".spec.replicas" },
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

/// Return the ledger of a current record whose revision names the
/// Deployment of [`deployment_manifest`] with the applied hash of
/// [`deployment`] as Kix applied it.
fn deployment_ledger() -> Ledger {
    let applied =
        fieldsv1::applied_content_hash(&deployment(1, None, None), &FieldManager::of("a")).unwrap();
    let mut ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true)]);
    let hash = object_hash(&deployment_manifest());
    let mut revision = Revision::new(RevisionSpec::new(
        CLUSTER,
        Slot::Instance {
            namespace: "d".into(),
            name: "cur".into(),
            lifecycle: None,
        },
        vec![RevisionObject::of_id(
            &hash,
            &ResourceId::new("apps", "Deployment", "d", "web"),
        )],
    ));
    revision.applied = [(hash, applied)].into();
    let record = crate::cluster::activation::Record {
        name: "cur".into(),
        phase: PHASE_ACTIVE.into(),
        revisions: Some(Ok(RevisionMap {
            instances: [("d/cur".to_string(), revision.name.clone())].into(),
            cluster_level: String::new(),
            kept_orphans: None,
        })),
        ..Default::default()
    };
    ledger.applied = AppliedHashes::of([&record], [&revision]);
    ledger
}

/// A field the object cedes is out of the applied hash, so an autoscaler
/// that changes it leaves the object in sync, for the CLI and the operator.
#[test]
fn an_autoscaled_ceded_field_is_not_drift() {
    let ledger = deployment_ledger();
    let live = LiveObjects::of([deployment(5, Some("hpa"), None)], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();
    for forces in [true, false] {
        let decided = decide(&new, &made, &live, &ledger, false, forces).unwrap();
        assert_eq!(shown(&decided), ["web: skip unchanged"], "forces {forces}");
    }
}

/// A `Failed` or killed deploy of a build with `replicas: 0` wrote that
/// value while Kix's own entry still owned the ceded field. The applied hash
/// leaves the field out, so it is the one the current record holds, and
/// only the third clause of the rule sees the other build's value. The
/// deploy of the earlier build applies it, without force. Once an
/// autoscaler holds the field, its value is the autoscaler's: the object is
/// skipped and nothing reports drift.
#[test]
fn a_ceded_field_another_build_wrote_while_kix_owned_it_is_applied() {
    let rid = ResourceId::new("apps", "Deployment", "d", "web");
    let with_replicas = |n: i64| {
        let mut m = deployment_manifest();
        m["spec"]["replicas"] = json!(n);
        m
    };
    let (one, zero) = (
        object_hash(&with_replicas(1)),
        object_hash(&with_replicas(0)),
    );
    assert_ne!(one, zero);
    let applied_of =
        |obj: &DynamicObject| fieldsv1::applied_content_hash(obj, &FieldManager::of(CLUSTER));
    let applied = applied_of(&deployment(0, None, None)).unwrap();
    assert_eq!(
        applied_of(&deployment(1, None, None)),
        Some(applied.clone())
    );
    let cur = || Rec::new("cur", PHASE_ACTIVE, true).recorded_as(rid.clone(), &one, &applied);
    let failed = ledger(&[
        cur(),
        Rec::new("failed", PHASE_FAILED, false).recorded_as(rid.clone(), &zero, &applied),
    ]);
    let killed = ledger(&[
        cur(),
        Rec::new("killed", PHASE_FAILED, false).names_as(rid.clone(), &zero),
    ]);
    let wrote_zero = || vec![deployment(0, None, None)];

    let decided = decide_cli(&[with_replicas(1)], wrote_zero(), &failed);
    assert_eq!(shown(&decided), ["web: apply applied by failed"]);
    assert!(!forced(&decided, "web"));
    let decided = decide_cli(&[with_replicas(1)], wrote_zero(), &killed);
    assert_eq!(shown(&decided), ["web: apply intended"]);
    assert!(!forced(&decided, "web"));
    // The build that wrote the value leaves it alone.
    let decided = decide_cli(&[with_replicas(0)], wrote_zero(), &failed);
    assert_eq!(shown(&decided), ["web: skip unchanged"]);

    let scaled = LiveObjects::of([deployment(5, Some("hpa"), None)], []);
    let new = [with_replicas(1)];
    let made = new.iter().map(ResourceId::from_value).collect();
    for ledger in [&failed, &killed] {
        for forces in [true, false] {
            let decided = decide(&new, &made, &scaled, ledger, false, forces).unwrap();
            assert_eq!(shown(&decided), ["web: skip unchanged"], "forces {forces}");
        }
    }
}

/// A forced revert of drift hands the run the whole manifest: the forced
/// apply leaves out each ceded field another manager holds on the object it
/// reads right before it writes, so the autoscaler keeps the replicas count
/// even when it took it after the plan. The operator, which never forces,
/// applies the build without the fields another manager holds, so the
/// apply is not refused. It reports the drift and records no applied hash,
/// so the report stays until the drift is gone.
#[test]
fn a_forced_revert_leaves_ceded_fields_to_their_manager_and_the_operator_reports_it() {
    let ledger = deployment_ledger();
    let live = LiveObjects::of([deployment(5, Some("hpa"), Some("kubectl-edit"))], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();

    let cli = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&cli), ["web: apply reverts drift on web"]);
    let ChangeAction::Apply(sent) = &cli.decisions[0].action else {
        panic!("an apply");
    };
    assert_eq!(sent, &new[0]);
    let Live::Present(obj) = live.get(&ResourceId::from_value(&new[0])) else {
        panic!("the live object");
    };
    let forced = crate::cluster::apply::forced_manifest(sent, obj, &FieldManager::of("a"));
    assert_eq!(forced.pointer("/spec/replicas"), None, "{forced}");
    assert_eq!(
        forced.pointer("/spec/template/spec/image"),
        Some(&json!("web:1"))
    );
    let Label::RevertsDrift(report) = &cli.decisions[0].label else {
        panic!("reverts drift");
    };
    // The ceded field's manager is not named as having changed it.
    let owners = crate::plan::document::DriftOwner::of_report(report);
    assert_eq!(owners.len(), 1, "{owners:?}");
    assert_eq!(owners[0].manager, "kubectl-edit");
    assert!(cli.unrecorded.is_empty());

    let operator = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&operator), ["web: apply reports drift on web"]);
    let ChangeAction::Apply(sent) = &operator.decisions[0].action else {
        panic!("an apply");
    };
    assert_eq!(sent.pointer("/spec/template/spec/image"), None, "{sent}");
    assert_eq!(sent.pointer("/spec/replicas"), None, "{sent}");
    assert_eq!(operator.unrecorded, [ResourceId::from_value(&new[0])]);
}

/// A killed CLI run wrote a newer image over `web`, and `kubectl scale`
/// then took the replicas count, which `web` does not cede. The operator
/// repairs the current record: it puts its own image back without the field
/// `kubectl` holds, reports that field, and records no applied hash.
#[test]
fn the_operator_corrects_its_own_fields_and_reports_the_held_one() {
    let ledger = deployment_ledger();
    let mut obj = deployment(5, Some("kubectl-scale"), None);
    obj.data["spec"]["template"]["spec"]["image"] = json!("web:2");
    obj.metadata.annotations = None;
    let live = LiveObjects::of([obj], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();
    let operator = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&operator), ["web: apply reports drift on web"]);
    let ChangeAction::Apply(sent) = &operator.decisions[0].action else {
        panic!("an apply");
    };
    assert_eq!(
        sent.pointer("/spec/template/spec/image"),
        Some(&json!("web:1"))
    );
    assert_eq!(sent.pointer("/spec/replicas"), None, "{sent}");
    assert_eq!(operator.unrecorded, [ResourceId::from_value(&new[0])]);
}

/// Drift that no other manager owns, such as a removed field, is applied
/// by the operator too, without force: the apply cannot conflict.
#[test]
fn the_operator_applies_drift_no_other_manager_owns() {
    let ledger =
        ledger(&[Rec::new("cur", PHASE_ACTIVE, true).recorded("web", &oh("web", "1"), "stale")]);
    let new = [manifest("web", "1")];
    let made = new.iter().map(ResourceId::from_value).collect();
    let live = LiveObjects::of([live("web", "1")], []);
    let decided = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&decided), ["web: apply reverts drift on web"]);
    assert!(decided.unrecorded.is_empty());
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
/// taken in only when this Kix cluster wrote it: the record's revision holds
/// an applied hash for it, or it has an `Apply` entry under this Kix
/// cluster's own manager. An entry under the shared manager `kix` alone
/// does not count, and one that only another Kix cluster wrote came from
/// elsewhere and stays. An `Active` current record's objects and kept
/// orphans need neither.
#[test]
fn leftovers_are_taken_in_only_when_this_cluster_wrote_them() {
    let recs = |phase| {
        [
            Rec::new("cur", phase, true)
                .names("own", "1")
                .names("legacy", "1")
                .applied("legacy-applied", "1")
                .names("other", "1")
                .kept("kept-other", "h-ko"),
            Rec::new("failed", PHASE_FAILED, false)
                .names("failed-own", "1")
                .names("failed-legacy", "1")
                .applied("failed-applied", "1")
                .names("failed-other", "1"),
        ]
    };
    let live = LiveObjects::of(
        [
            written_by(live("own", "1"), &["kix/a"]),
            written_by(live("legacy", "1"), &[LEGACY]),
            written_by(live("legacy-applied", "1"), &[LEGACY]),
            written_by(live("other", "1"), &["kix/b"]),
            written_by(live("kept-other", "1"), &["kix/b"]),
            written_by(live("failed-own", "1"), &["kix/a", "kix/b"]),
            written_by(live("failed-legacy", "1"), &[LEGACY]),
            written_by(live("failed-applied", "1"), &[LEGACY]),
            written_by(live("failed-other", "1"), &["kix/b"]),
        ],
        [],
    );
    let made = HashSet::new();

    let degraded = ledger(&recs(PHASE_DEGRADED));
    let decided = decide(&[], &made, &live, &degraded, false, true).unwrap();
    assert_eq!(
        decided.orphans,
        [
            id("failed-applied"),
            id("failed-own"),
            id("kept-other"),
            id("legacy-applied"),
            id("own")
        ]
    );

    let active = ledger(&recs(PHASE_ACTIVE));
    let decided = decide(&[], &made, &live, &active, false, true).unwrap();
    assert_eq!(
        decided.orphans,
        [
            id("failed-applied"),
            id("failed-own"),
            id("kept-other"),
            id("legacy"),
            id("legacy-applied"),
            id("other"),
            id("own")
        ]
    );
}

/// Another Kix cluster made `shared` under the manager `kix` with an older
/// Kix, and retired the records its note named. This Kix cluster's deploy
/// that would have added an object of that name stopped before it reached
/// it. The `Failed` record names the object, and the entry under `kix`
/// would count as this cluster's own, but this cluster never wrote the
/// object, so the prune leaves it.
#[test]
fn a_stopped_record_does_not_take_in_what_only_the_shared_manager_wrote() {
    let ledger = ledger(&[
        Rec::new("cur", PHASE_ACTIVE, true),
        Rec::new("failed", PHASE_FAILED, false).names("shared", "1"),
    ]);
    let mut leftover = written_by(live("shared", "1"), &[LEGACY]);
    leftover
        .metadata
        .annotations
        .get_or_insert_default()
        .insert(keys::ACTIVATIONS.into(), "rec-retired".into());
    let decided = decide(
        &[],
        &HashSet::new(),
        &LiveObjects::of([leftover], []),
        &ledger,
        false,
        true,
    )
    .unwrap();
    assert!(decided.orphans.is_empty(), "{:?}", decided.orphans);
}

/// Another Kix cluster applied the image with another value. The CLI sends
/// the apply without force, so Kubernetes refuses it and names that Kix
/// cluster, rather than taking the field and moving the refusal to the
/// other cluster's next deploy. The operator applies the rest and reports
/// the field.
#[test]
fn a_field_another_kix_cluster_holds_is_not_taken_by_force() {
    let ledger = deployment_ledger();
    let live = LiveObjects::of([deployment(1, None, Some("kix/b"))], []);
    let new = [deployment_manifest()];
    let made = new.iter().map(ResourceId::from_value).collect();

    let cli = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(shown(&cli), ["web: apply held by another cluster on web"]);
    let operator = decide(&new, &made, &live, &ledger, false, false).unwrap();
    assert_eq!(shown(&operator), ["web: apply reports drift on web"]);
}

/// Return the live ConfigMap `name` holding `v` as an older Kix left it:
/// applied under `kix`, stamped with the build hash of [`manifest`], with
/// `notes` listing the record hashes that name it and the applied hash it
/// recorded, which left out every `kix.run/*` annotation.
fn noted(name: &str, v: &str, notes: &str) -> DynamicObject {
    let mut obj = live_as(name, v, LEGACY);
    let identity = keys::get(&manifest(name, v), keys::IDENTITY_HASH)
        .unwrap()
        .to_string();
    let annotations = obj.metadata.annotations.get_or_insert_default();
    annotations.insert(keys::IDENTITY_HASH.into(), identity);
    annotations.insert(keys::ACTIVATIONS.into(), notes.into());
    let applied =
        fieldsv1::older_kix_applied_hash(&obj, &FieldManager::unmigrated(CLUSTER)).unwrap();
    obj.metadata
        .annotations
        .get_or_insert_default()
        .insert(keys::APPLIED_HASH.into(), applied);
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

/// A Kix cluster an older Kix deployed last is read after the conversion a
/// run writes first ([`crate::cluster::revision::convert`]): the current
/// record names what its note lists, the builds under
/// `status.orphansKeptFrom` name kept orphans, and a `Failed` record left
/// what its note lists and wrote what still matches its applied hash. A
/// `Superseded` record and another Kix cluster's record name nothing of it.
/// The object the new build makes from the same
/// file, and that still matches its applied hash, is unchanged. One a hand
/// edit changed before the upgrade still reverts drift. Every object it
/// holds needs the migration write, and drift is judged as the write leaves
/// it. An object another Kix cluster an older Kix deploys also names keeps
/// its entry under `kix`, so it is not renamed, and the plan applies it
/// without force to add the cluster's own entry.
#[test]
fn a_cluster_an_older_kix_deployed_is_read_after_its_conversion() {
    use crate::cluster::revision::convert;
    let records = [
        legacy_record("cur", CLUSTER, PHASE_ACTIVE, &["old-build"]),
        legacy_record("fail", CLUSTER, PHASE_FAILED, &[]),
        legacy_record("sup", CLUSTER, lifecycle::PHASE_SUPERSEDED, &[]),
        legacy_record("b-cur", "b", PHASE_ACTIVE, &[]),
    ];
    let tenancy = Tenancy::fixture(&records, CLUSTER);
    let mut edited = noted("edited", "1", "rec-cur");
    edited.data["data"]["k"] = json!("by hand");
    let swept = [
        noted("same", "1", "rec-cur"),
        edited,
        noted("gone", "1", "rec-cur"),
        noted("kept", "1", "old-build"),
        noted("left", "1", "rec-fail"),
        noted("superseded", "1", "rec-sup"),
        noted("b-only", "1", "rec-b-cur"),
        noted("shared", "1", "rec-b-cur,rec-cur"),
    ];
    let new = [
        manifest("same", "1"),
        manifest("edited", "1"),
        manifest("shared", "1"),
        manifest("left", "2"),
    ];
    let own = tenancy.own_records();
    let conversion = convert::plan(
        CLUSTER,
        convert::current_of(tenancy.own_current(), own),
        own,
        &[],
        &swept,
        &[],
        &convert::BuildHashes::of(&new),
    )
    .unwrap();
    let converted = tenancy.with_conversion(&conversion);
    let mut ledger = Ledger::of(&converted, true).unwrap();
    ledger.deploying(Some("rec-new"));
    assert_eq!(ledger.taken_in(), ["fail"]);
    let made: HashSet<ResourceId> = new.iter().map(ResourceId::from_value).collect();
    let live = LiveObjects::of(swept.iter().cloned(), []);
    let decided = decide(&new, &made, &live, &ledger, false, true).unwrap();
    assert_eq!(
        shown(&decided),
        [
            "same: skip unchanged",
            "edited: apply reverts drift on edited",
            "shared: apply held by another cluster on shared",
            "left: apply applied by fail",
        ]
    );
    let names = |ids: &[ResourceId]| ids.iter().map(|r| r.name.clone()).collect::<Vec<_>>();
    assert_eq!(names(&decided.orphans), ["gone", "kept"]);
    assert_eq!(
        names(&decided.migrations),
        ["edited", "left", "same", "shared"]
    );
    assert_eq!(names(&decided.renamed), ["edited", "left", "same"]);
    assert_eq!(names(&decided.orphan_migrations), ["gone", "kept"]);
}

/// Another group's `Activation` and `PackageInstance`, such as Crossplane's
/// `Activation`, are objects like any other. The rule decides them by their
/// applied hash, even with `kix.run/mode: import`, and one the build stops
/// making is an orphan.
#[test]
fn another_groups_record_and_instance_kinds_follow_the_rule() {
    let as_foreign = |mut m: Value, kind: &str| {
        m["apiVersion"] = json!("ssm.aws.upbound.io/v1beta1");
        m["kind"] = json!(kind);
        m["metadata"]["annotations"][keys::MODE] = json!("import");
        m
    };
    let live_foreign = |name: &str, v: &str, kind: &str| {
        let mut obj = live(name, v);
        let types = obj.types.as_mut().unwrap();
        types.api_version = "ssm.aws.upbound.io/v1beta1".into();
        types.kind = kind.into();
        obj
    };
    let rid = |kind: &str, name: &str| ResourceId::new("ssm.aws.upbound.io", kind, "d", name);
    let act = as_foreign(manifest("act", "1"), "Activation");
    let pi = as_foreign(manifest("pi", "1"), "PackageInstance");
    let applied_of = |obj: &DynamicObject| {
        fieldsv1::applied_content_hash(obj, &FieldManager::of(CLUSTER)).unwrap()
    };
    let ledger = ledger(&[Rec::new("cur", PHASE_ACTIVE, true)
        .recorded_as(
            rid("Activation", "act"),
            &object_hash(&act),
            &applied_of(&live_foreign("act", "1", "Activation")),
        )
        .recorded_as(
            rid("PackageInstance", "pi"),
            &object_hash(&pi),
            &applied_of(&live_foreign("pi", "1", "PackageInstance")),
        )
        .recorded_as(rid("Activation", "gone"), "h-gone", "a-gone")]);
    let live = vec![
        live_foreign("act", "1", "Activation"),
        live_foreign("pi", "by hand", "PackageInstance"),
        live_foreign("gone", "1", "Activation"),
    ];
    let decided = decide_cli(&[act, pi], live, &ledger);
    assert_eq!(
        shown(&decided),
        ["act: skip unchanged", "pi: apply reverts drift on pi"]
    );
    assert_eq!(decided.orphans, [rid("Activation", "gone")]);
}
