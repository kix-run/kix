//! Field changes from the apiserver's answers to a dry-run deploy.
//!
//! `kix plan` builds the package diff the deploy prints (deployed build
//! against new build), then replaces each applied object's entry with what
//! the apiserver said: the live object compared with the object the dry-run
//! apply would produce, as `kubectl diff` does. An object the server would
//! create is an addition, one it would leave as it is drops out, and one it
//! refused keeps the build comparison and is reported in the plan's
//! `admission` or `conflicts` section instead.

use std::collections::HashMap;

use crate::cluster::field_manager::FieldManager;
use crate::cluster::preview::{DryRunAnswer, DryRunOutcome, Refusal};
use crate::eval::store_graph::StoreGraph;
use crate::manifest::diff::engine::structural_diff;
use crate::manifest::diff::{DiffConfig, Difference};
use crate::manifest::lifecycle;
use crate::manifest::types::{self, ResourceId};
use serde_json::Value;

use super::document::{BeingDeleted, DriftChange, EarlierDeployChange, FieldNotKept};
use super::origin::{ChangeLabel, FoldedBy, ThreeWay};
use super::{CLUSTER_LEVEL_KEY, PackageChangeDiff, PackageDiff, partition_propagation};

/// Metadata the apiserver maintains on every write. A dry-run apply returns
/// new values for these whatever the change, so they are not field changes.
const SERVER_METADATA: &[&str] = &[
    "managedFields",
    "resourceVersion",
    "generation",
    "uid",
    "creationTimestamp",
    "selfLink",
];

/// Annotations the apiserver writes itself when an apply changes the object:
/// a DaemonSet's template generation moves with every template change.
const SERVER_ANNOTATIONS: &[&str] = &["deprecated.daemonset.template.generation"];

/// Return `obj` without server-maintained metadata or `status`, which an apply
/// does not write.
pub fn comparable(obj: &Value) -> Value {
    let mut obj = obj.clone();
    if let Some(map) = obj.as_object_mut() {
        map.remove("status");
        if let Some(meta) = map.get_mut("metadata").and_then(Value::as_object_mut) {
            for key in SERVER_METADATA {
                meta.remove(*key);
            }
            if let Some(annotations) = meta.get_mut("annotations").and_then(Value::as_object_mut) {
                for key in SERVER_ANNOTATIONS {
                    annotations.remove(*key);
                }
            }
        }
    }
    obj
}

/// Diff `live` against the dry-run `result` with secret values redacted.
pub(crate) fn field_changes(live: &Value, result: &Value) -> Vec<Difference> {
    let config = DiffConfig::new("live", "planned");
    let mut diffs = structural_diff(&comparable(live), &comparable(result), "$", &config);
    let is_secret = types::is_secret(live) || types::is_secret(result);
    let max = super::MAX_SHOWN_VALUE_BYTES;
    for d in &mut diffs {
        let old = d.a_value.clone();
        for (side, before) in [(&mut d.a_value, None), (&mut d.b_value, old.as_ref())] {
            if let Some(v) = side.as_mut() {
                *v = super::shown_value(is_secret, &d.path, v, before, max);
            }
        }
    }
    diffs
}

/// Return the fields the server would not keep as the build sets them, for
/// every object the dry run writes: each create, update, and recreate the
/// server answered. Objects `skip` names are left out. The list is sorted by
/// resource, then path.
pub fn not_kept(answers: &[DryRunAnswer], skip: impl Fn(&ResourceId) -> bool) -> Vec<FieldNotKept> {
    let mut out: Vec<FieldNotKept> = answers
        .iter()
        .filter(|a| !lifecycle::is_record_kind(&a.rid.kind) && !skip(&a.rid))
        .flat_map(|a| {
            let fields = match &a.outcome {
                DryRunOutcome::Applied(p) => p.not_kept.as_slice(),
                DryRunOutcome::Recreated { not_kept, .. } => not_kept.as_slice(),
                DryRunOutcome::Refused(_) | DryRunOutcome::Pruned(_) => &[],
            };
            fields.iter().map(|f| FieldNotKept {
                resource: a.rid.display_id(),
                path: f.path.clone(),
                change: f.change,
                sent: f.sent.clone(),
                stored: f.stored.clone(),
            })
        })
        .collect();
    out.sort_by(|a, b| (&a.resource, &a.path).cmp(&(&b.resource, &b.path)));
    out
}

/// Return the objects of the build that the dry run found being deleted on
/// the cluster, sorted by resource. The deploy waits for each to be gone and
/// then creates it. `manifest` returns the build's manifest of an object,
/// which says whether it may hold data.
pub fn being_deleted<'a>(
    answers: &[DryRunAnswer],
    manifest: impl Fn(&ResourceId) -> Option<&'a Value>,
) -> Vec<BeingDeleted> {
    let mut out: Vec<BeingDeleted> = answers
        .iter()
        .filter_map(|a| {
            let DryRunOutcome::Recreated {
                live: Some(live), ..
            } = &a.outcome
            else {
                return None;
            };
            let since = live.pointer("/metadata/deletionTimestamp")?.as_str()?;
            let obj: kube::api::DynamicObject = serde_json::from_value(live.clone()).ok()?;
            Some(BeingDeleted {
                resource: a.rid.display_id(),
                since: since.to_string(),
                finalizers: crate::cluster::readiness::finalizers_of(&obj),
                holds_data: manifest(&a.rid).is_some_and(crate::cluster::migrate::may_hold_data),
            })
        })
        .collect();
    out.sort_by(|a, b| a.resource.cmp(&b.resource));
    out
}

/// What the server answers change about the package diff.
pub(crate) struct Overlay<'a> {
    pub new_graph: &'a StoreGraph,
    /// The deployed build's manifests, when the deployed build is known.
    /// Without them no field change is labelled and drift is not reported.
    pub deployed: Option<HashMap<ResourceId, &'a Value>>,
    /// Each resource's manifest in the builds of the folded deploy records.
    pub folded: HashMap<ResourceId, Vec<(FoldedBy, &'a Value)>>,
    /// The field manager of the Kix cluster planned.
    pub manager: FieldManager,
}

/// The fields where the live cluster differs from the deployed build, as
/// [`Overlay::apply`] sorts them.
#[derive(Debug, Default)]
pub(crate) struct Differences {
    /// Drift the deploy reverts.
    pub drift: Vec<DriftChange>,
    /// Values a folded deploy wrote.
    pub earlier: Vec<EarlierDeployChange>,
}

impl Overlay<'_> {
    /// Replace each answered object's entry in `diff` with the server's
    /// answer, label every field change when the deployed build is known,
    /// and return the drift the deploy reverts and the values folded
    /// deploys wrote.
    pub(crate) fn apply(&self, diff: &mut PackageDiff, answers: &[DryRunAnswer]) -> Differences {
        let membership = membership(self.new_graph);
        let new_by_rid: HashMap<ResourceId, &Value> = self
            .new_graph
            .resources
            .values()
            .map(|n| (ResourceId::from_value(&n.manifest), &n.manifest))
            .collect();
        let mut found = Differences::default();
        let mut labelled = Vec::new();
        diff.labelled = self.deployed.is_some();

        for answer in answers {
            let rid = &answer.rid;
            if lifecycle::is_record_kind(&rid.kind) {
                continue;
            }
            let recreated = matches!(answer.outcome, DryRunOutcome::Recreated { .. });
            let (live, result) = match &answer.outcome {
                DryRunOutcome::Applied(p) => (p.live.clone(), Some(p.result.clone())),
                DryRunOutcome::Recreated { live, result, .. } => (live.clone(), result.clone()),
                // A 409 means the object exists, so the build comparison's
                // "added" (the old side may not have known the object, made
                // by hand or by another tool) is wrong. List it as changed;
                // the conflict says what about it.
                DryRunOutcome::Refused(Refusal::Conflict { .. }) => {
                    if let Some((key, version)) = membership.get(rid)
                        && let Some(entry) = entry(diff, key, version.clone())
                        && entry.added_resources.contains(rid)
                    {
                        forget(entry, rid);
                        entry.resource_diffs.push((rid.clone(), Vec::new()));
                    }
                    continue;
                }
                DryRunOutcome::Refused(_) | DryRunOutcome::Pruned(_) => continue,
            };
            let Some((key, version)) = membership.get(rid) else {
                continue;
            };
            let Some(entry) = entry(diff, key, version.clone()) else {
                continue;
            };
            // Recreated, and the create could not be dry-run because the
            // object still exists: keep the build comparison.
            if let (true, Some(_), None) = (recreated, &live, &result) {
                if !entry.resource_diffs.iter().any(|(id, _)| id == rid) {
                    forget(entry, rid);
                    entry.resource_diffs.push((rid.clone(), Vec::new()));
                }
                continue;
            }
            forget(entry, rid);
            match (live, result) {
                (None, _) => entry.added_resources.push(rid.clone()),
                (Some(live), Some(result)) => {
                    let (real, propagation) = partition_propagation(field_changes(&live, &result));
                    if !real.is_empty() {
                        if let (Some(deployed), Some(new)) = (&self.deployed, new_by_rid.get(rid)) {
                            let three = ThreeWay {
                                deployed: deployed.get(rid).copied(),
                                live: &comparable(&live),
                                new,
                                managed: Some(&live),
                                applies: true,
                                secret: types::is_secret(&live) || types::is_secret(new),
                                folded: self.folded.get(rid).map_or(&[], Vec::as_slice),
                                manager: &self.manager,
                            };
                            let (labels, drifted) = three.label(&real);
                            labelled.push((rid.clone(), labels));
                            for d in drifted {
                                match d.by {
                                    Some(by) => found.earlier.push(EarlierDeployChange {
                                        resource: rid.display_id(),
                                        path: d.path,
                                        deployed: d.deployed,
                                        live: d.live,
                                        record: by.record,
                                        partly_deployed: by.partly_deployed,
                                    }),
                                    None => found.drift.push(DriftChange {
                                        resource: rid.display_id(),
                                        path: d.path,
                                        deployed: d.deployed,
                                        live: d.live,
                                        managers: d.managers,
                                        reverted: true,
                                    }),
                                }
                            }
                        }
                        entry.resource_diffs.push((rid.clone(), real));
                    } else if recreated {
                        // A rerun Job deleted and created again with the
                        // same spec is still a change.
                        entry.resource_diffs.push((rid.clone(), Vec::new()));
                    } else if !propagation.is_empty() {
                        entry.dep_affected_resources.push(rid.clone());
                    }
                }
                (Some(_), None) => {}
            }
        }

        diff.labels.extend(labelled);
        if diff.labelled {
            label_build_changes(diff);
        }
        prune_empty(diff);
        found
    }
}

/// Label remaining diffs from the build comparison as `Intended`.
fn label_build_changes(diff: &mut PackageDiff) {
    let PackageDiff {
        changed,
        cluster_level,
        labels,
        ..
    } = diff;
    for c in changed.iter().chain(cluster_level.iter()) {
        for (rid, diffs) in &c.resource_diffs {
            labels
                .entry(rid.clone())
                .or_insert_with(|| vec![vec![ChangeLabel::Intended]; diffs.len()]);
        }
    }
}

/// Map each resource in `graph` (including each package's PackageInstance) to
/// its package key and version, or [`CLUSTER_LEVEL_KEY`] when unowned.
fn membership(graph: &StoreGraph) -> HashMap<ResourceId, (String, Option<String>)> {
    let mut out = HashMap::new();
    for pkg in graph.packages.values() {
        let key = format!("{}/{}", pkg.namespace, pkg.instance_name);
        for path in pkg
            .resource_paths
            .iter()
            .chain(std::iter::once(&pkg.store_path))
        {
            if let Some(node) = graph.resources.get(path) {
                out.insert(
                    ResourceId::from_value(&node.manifest),
                    (key.clone(), pkg.version.clone()),
                );
            }
        }
    }
    for node in graph.resources.values() {
        out.entry(ResourceId::from_value(&node.manifest))
            .or_insert_with(|| (CLUSTER_LEVEL_KEY.to_string(), None));
    }
    out
}

/// Return or create the [`PackageChangeDiff`] entry for package `key`, or
/// return `None` when the package is newly added.
fn entry<'d>(
    diff: &'d mut PackageDiff,
    key: &str,
    version: Option<String>,
) -> Option<&'d mut PackageChangeDiff> {
    if key == CLUSTER_LEVEL_KEY {
        return Some(
            diff.cluster_level
                .get_or_insert_with(|| empty_change(CLUSTER_LEVEL_KEY, None)),
        );
    }
    if diff.added.iter().any(|p| p.key == key) {
        return None;
    }
    let at = match diff.changed.iter().position(|c| c.key == key) {
        Some(at) => at,
        None => {
            diff.unchanged = diff.unchanged.saturating_sub(1);
            diff.changed.push(empty_change(key, version));
            diff.changed.len() - 1
        }
    };
    Some(&mut diff.changed[at])
}

fn empty_change(key: &str, version: Option<String>) -> PackageChangeDiff {
    PackageChangeDiff {
        key: key.to_string(),
        old_version: version.clone(),
        new_version: version,
        resource_diffs: Vec::new(),
        dep_affected_resources: Vec::new(),
        added_resources: Vec::new(),
        removed_resources: Vec::new(),
        shared_kept: Vec::new(),
    }
}

fn forget(entry: &mut PackageChangeDiff, rid: &ResourceId) {
    entry.resource_diffs.retain(|(id, _)| id != rid);
    entry.dep_affected_resources.retain(|id| id != rid);
    entry.added_resources.retain(|id| id != rid);
}

fn is_empty(c: &PackageChangeDiff) -> bool {
    c.resource_diffs.is_empty()
        && c.dep_affected_resources.is_empty()
        && c.added_resources.is_empty()
        && c.removed_resources.is_empty()
        && c.shared_kept.is_empty()
}

/// Drop entries the server answers left empty. A package whose version
/// changed stays listed.
fn prune_empty(diff: &mut PackageDiff) {
    let before = diff.changed.len();
    diff.changed
        .retain(|c| !is_empty(c) || c.old_version != c.new_version);
    diff.unchanged += before - diff.changed.len();
    diff.changed.sort_by(|a, b| a.key.cmp(&b.key));
    if diff.cluster_level.as_ref().is_some_and(is_empty) {
        diff.cluster_level = None;
    }
    let listed: std::collections::HashSet<&ResourceId> = diff
        .changed_with_cluster_level()
        .flat_map(|c| c.resource_diffs.iter().map(|(id, _)| id))
        .collect();
    let stale: Vec<ResourceId> = diff
        .labels
        .keys()
        .filter(|id| !listed.contains(id))
        .cloned()
        .collect();
    for id in stale {
        diff.labels.remove(&id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::apply::ApplyPreview;
    use crate::manifest::keys;
    use serde_json::json;

    fn configmap(ns: &str, name: &str, hash: &str, data: Value) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": name, "namespace": ns, "annotations": {
                keys::PACKAGE: "web", keys::PACKAGE_NAMESPACE: "app",
                keys::IDENTITY_HASH: hash, keys::DEPENDS_ON: "",
            }},
            "data": data,
        })
    }

    fn rid(name: &str) -> ResourceId {
        ResourceId::new("", "ConfigMap", "app", name)
    }

    fn served(obj: &Value) -> Value {
        let mut o = obj.clone();
        o["metadata"]["resourceVersion"] = json!("42");
        o["metadata"]["uid"] = json!("u-1");
        o["metadata"]["managedFields"] = json!([{"manager": "kix", "operation": "Apply"}]);
        o
    }

    fn applied(name: &str, live: Option<Value>, result: Value) -> DryRunAnswer {
        DryRunAnswer {
            rid: rid(name),
            outcome: DryRunOutcome::Applied(Box::new(ApplyPreview {
                live,
                result,
                not_kept: Vec::new(),
            })),
        }
    }

    /// Every write the dry run answered reports the fields the server would
    /// not keep: a create and an update. The Activation record and the
    /// objects `skip` names are left out.
    #[test]
    fn not_kept_covers_creates_and_updates() {
        use super::super::document::NotKept;
        use crate::cluster::kept;
        let widget = |name: &str, spec: Value| {
            json!({"apiVersion": "example.com/v1", "kind": "Widget",
                "metadata": {"name": name, "namespace": "app"}, "spec": spec})
        };
        let answer = |live: Option<Value>, sent: Value, stored: Value| {
            let not_kept = kept::not_kept(&sent, &stored);
            DryRunAnswer {
                rid: ResourceId::from_value(&sent),
                outcome: DryRunOutcome::Applied(Box::new(ApplyPreview {
                    live,
                    result: served(&stored),
                    not_kept,
                })),
            }
        };
        let created = answer(
            None,
            widget("new", json!({"colour": "red"})),
            widget("new", json!({})),
        );
        let updated = answer(
            Some(served(&widget("old", json!({"size": 1})))),
            widget("old", json!({"size": 2})),
            widget("old", json!({"size": 5})),
        );
        let skipped = answer(
            None,
            widget("skip", json!({"colour": "red"})),
            widget("skip", json!({})),
        );
        let mut record = served(&json!({"apiVersion": "x/v1",
            "kind": crate::manifest::lifecycle::RECORD_KIND,
            "metadata": {"name": "r"}, "spec": {"a": 1}}));
        let record_sent = record.clone();
        record["spec"] = json!({});
        let record = DryRunAnswer {
            rid: ResourceId::from_value(&record_sent),
            outcome: DryRunOutcome::Applied(Box::new(ApplyPreview {
                live: None,
                not_kept: kept::not_kept(&record_sent, &record),
                result: record,
            })),
        };
        let answers = [created, updated, skipped, record];
        let found = not_kept(&answers, |rid| rid.name == "skip");
        let summary: Vec<(&str, &str, NotKept, Option<&Value>)> = found
            .iter()
            .map(|f| {
                (
                    f.resource.as_str(),
                    f.path.as_str(),
                    f.change,
                    f.stored.as_ref(),
                )
            })
            .collect();
        assert_eq!(
            summary,
            vec![
                (
                    "Widget.example.com/new@app",
                    "$.spec.colour",
                    NotKept::Dropped,
                    None
                ),
                (
                    "Widget.example.com/old@app",
                    "$.spec.size",
                    NotKept::Changed,
                    Some(&json!(5))
                ),
            ]
        );
        assert_eq!(found[1].sent, json!(2));
    }

    #[test]
    fn server_metadata_is_not_a_change_and_secrets_stay_hidden() {
        let live = served(
            &json!({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "s", "annotations": {
            "kubectl.kubernetes.io/last-applied-configuration": "{\"data\":{\"p\":\"cGxhaW4=\"}}"}},
            "data": {"p": "b2xk"}}),
        );
        let mut result = live.clone();
        result["metadata"]["resourceVersion"] = json!("43");
        result["data"]["p"] = json!("bmV3");
        result["metadata"]["annotations"]["kubectl.kubernetes.io/last-applied-configuration"] =
            json!("{}");
        let diffs = field_changes(&live, &result);
        let text = format!("{diffs:?}");
        for leaked in ["b2xk", "bmV3", "cGxhaW4="] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }
        assert_eq!(diffs.len(), 2, "{diffs:?}");
        assert!(diffs.iter().all(|d| !d.path.contains("resourceVersion")));
    }

    #[test]
    fn a_custom_resource_named_secret_shows_its_values() {
        let live = served(&json!({"apiVersion": "x.example/v1", "kind": "Secret",
            "metadata": {"name": "s"}, "data": {"p": "old-value"}}));
        let mut result = live.clone();
        result["data"]["p"] = json!("new-value");
        let diffs = field_changes(&live, &result);
        assert_eq!(diffs[0].a_value, Some(json!("old-value")), "{diffs:?}");
        assert_eq!(diffs[0].b_value, Some(json!("new-value")), "{diffs:?}");
    }

    /// The build comparison says a ConfigMap changed; the server says one
    /// change already holds live, one object is missing live and would be
    /// created, and an untouched package gains a change from drift.
    #[test]
    fn server_answers_replace_the_build_comparison() {
        let old = vec![
            configmap("app", "a", &"a".repeat(32), json!({"k": "1"})),
            configmap("app", "b", &"b".repeat(32), json!({"k": "1"})),
        ];
        let new = vec![
            configmap("app", "a", &"c".repeat(32), json!({"k": "2"})),
            configmap("app", "b", &"d".repeat(32), json!({"k": "2"})),
        ];
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&old, &new_graph);
        let mut diff = super::super::diff_graphs(&old_graph, &new_graph);
        assert_eq!(diff.changed[0].resource_diffs.len(), 2);

        // `a` already holds the new value live: only the hash moves.
        let live_a = served(&{
            let mut a = new[0].clone();
            a["metadata"]["annotations"][keys::IDENTITY_HASH] = json!("a".repeat(32));
            a
        });
        let answers = vec![
            applied("a", Some(live_a), served(&new[0])),
            applied("b", None, served(&new[1])),
        ];
        let deployed: HashMap<ResourceId, &Value> =
            old.iter().map(|m| (ResourceId::from_value(m), m)).collect();
        let overlay = Overlay {
            new_graph: &new_graph,
            deployed: Some(deployed),
            folded: HashMap::new(),
            manager: FieldManager::of("a"),
        };
        let drift = overlay.apply(&mut diff, &answers).drift;
        assert!(drift.is_empty());
        let web = &diff.changed[0];
        assert!(web.resource_diffs.is_empty(), "{:?}", web.resource_diffs);
        assert_eq!(web.dep_affected_resources, vec![rid("a")]);
        assert_eq!(web.added_resources, vec![rid("b")]);
    }

    /// A recreate stays in the plan: with no dry-run result the build
    /// comparison is kept, and a recreate with nothing to change is still
    /// listed, since the deploy deletes and creates the object.
    #[test]
    fn a_recreated_object_stays_a_change() {
        let old = vec![
            configmap("app", "a", &"a".repeat(32), json!({"k": "1"})),
            configmap("app", "b", &"b".repeat(32), json!({"k": "1"})),
        ];
        let new = vec![
            configmap("app", "a", &"c".repeat(32), json!({"k": "2"})),
            old[1].clone(),
        ];
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&old, &new_graph);
        let mut diff = super::super::diff_graphs(&old_graph, &new_graph);
        let recreated = |name: &str, live: &Value, result: Option<Value>| DryRunAnswer {
            rid: rid(name),
            outcome: DryRunOutcome::Recreated {
                live: Some(served(live)),
                result,
                not_kept: Vec::new(),
            },
        };
        let answers = vec![
            recreated("a", &old[0], None),
            recreated("b", &old[1], Some(served(&old[1]))),
        ];
        Overlay {
            new_graph: &new_graph,
            deployed: None,
            folded: HashMap::new(),
            manager: FieldManager::of("a"),
        }
        .apply(&mut diff, &answers);
        let web = &diff.changed[0];
        let listed: Vec<(&ResourceId, usize)> = web
            .resource_diffs
            .iter()
            .map(|(id, d)| (id, d.len()))
            .collect();
        assert_eq!(listed, vec![(&rid("a"), 1), (&rid("b"), 0)], "{listed:?}");
    }

    /// A recreate whose live object has a `deletionTimestamp` is an object
    /// the deploy waits for, and the plan lists it with its finalizers and
    /// whether it may hold data. A recreate of a live object that is not
    /// being deleted is not listed.
    #[test]
    fn an_object_being_deleted_is_listed_with_what_it_waits_for() {
        let held = |name: &str| {
            let mut live = configmap("app", name, &"a".repeat(32), json!({"k": "1"}));
            live["metadata"]["deletionTimestamp"] = json!("2026-11-24T15:54:00Z");
            live["metadata"]["finalizers"] = json!(["example.com/hold"]);
            live
        };
        let recreated = |name: &str, live: Value| DryRunAnswer {
            rid: rid(name),
            outcome: DryRunOutcome::Recreated {
                live: Some(live),
                result: None,
                not_kept: Vec::new(),
            },
        };
        let claim = json!({
            "apiVersion": "v1",
            "kind": "PersistentVolumeClaim",
            "metadata": { "name": "b", "namespace": "app" },
            "spec": { "resources": { "requests": { "storage": "1Gi" } } },
        });
        let answers = vec![
            recreated("b", held("b")),
            recreated("a", held("a")),
            recreated(
                "c",
                configmap("app", "c", &"a".repeat(32), json!({"k": "1"})),
            ),
        ];
        let found = being_deleted(&answers, |r| (r.name == "b").then_some(&claim));
        let listed: Vec<(&str, &str, bool)> = found
            .iter()
            .map(|d| (d.resource.as_str(), d.since.as_str(), d.holds_data))
            .collect();
        assert_eq!(
            listed,
            vec![
                (
                    rid("a").display_id().as_str(),
                    "2026-11-24T15:54:00Z",
                    false
                ),
                (rid("b").display_id().as_str(), "2026-11-24T15:54:00Z", true),
            ]
        );
        assert_eq!(found[0].finalizers, vec!["example.com/hold".to_string()]);
    }

    #[test]
    fn drift_the_deploy_reverts_is_labelled_and_reported() {
        let old = vec![configmap(
            "app",
            "a",
            &"a".repeat(32),
            json!({"k": "1", "x": "1"}),
        )];
        let new = vec![configmap(
            "app",
            "a",
            &"c".repeat(32),
            json!({"k": "2", "x": "1"}),
        )];
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&old, &new_graph);
        let mut diff = super::super::diff_graphs(&old_graph, &new_graph);
        let mut live = old[0].clone();
        live["data"]["x"] = json!("hand-edited");
        let answers = vec![applied("a", Some(served(&live)), served(&new[0]))];
        let deployed: HashMap<ResourceId, &Value> =
            old.iter().map(|m| (ResourceId::from_value(m), m)).collect();
        let drift = Overlay {
            new_graph: &new_graph,
            deployed: Some(deployed),
            folded: HashMap::new(),
            manager: FieldManager::of("a"),
        }
        .apply(&mut diff, &answers)
        .drift;
        assert_eq!(drift.len(), 1);
        assert_eq!(drift[0].path, "$.data.x");
        assert_eq!(drift[0].live, Some(json!("hand-edited")));
        let (id, diffs) = &diff.changed[0].resource_diffs[0];
        let labels = &diff.labels[id];
        for (d, l) in diffs.iter().zip(labels) {
            match d.path.as_str() {
                "$.data.k" => assert_eq!(l, &vec![ChangeLabel::Intended]),
                "$.data.x" => assert_eq!(l, &vec![ChangeLabel::RevertsDrift]),
                other => panic!("unexpected change at {other}"),
            }
        }
    }

    /// Return the object lists of a plan's `packages` section grouped by bucket.
    /// A live value a folded deploy's build has is listed as that deploy's
    /// write, labelled so, and kept out of the drift.
    #[test]
    fn a_value_a_folded_deploy_wrote_is_not_drift() {
        let old = vec![configmap(
            "app",
            "a",
            &"a".repeat(32),
            json!({"version": "1"}),
        )];
        let partial = configmap("app", "a", &"b".repeat(32), json!({"version": "2"}));
        let new = vec![configmap(
            "app",
            "a",
            &"c".repeat(32),
            json!({"version": "3"}),
        )];
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let old_graph = StoreGraph::synthesize(&old, &new_graph);
        let mut diff = super::super::diff_graphs(&old_graph, &new_graph);
        let answers = vec![applied("a", Some(served(&partial)), served(&new[0]))];
        let by = FoldedBy {
            record: "c-partial".into(),
            partly_deployed: true,
        };
        let found = Overlay {
            new_graph: &new_graph,
            deployed: Some(old.iter().map(|m| (ResourceId::from_value(m), m)).collect()),
            folded: [(rid("a"), vec![(by, &partial)])].into_iter().collect(),
            manager: FieldManager::of("a"),
        }
        .apply(&mut diff, &answers);
        assert!(found.drift.is_empty(), "{:?}", found.drift);
        assert_eq!(found.earlier.len(), 1, "{:?}", found.earlier);
        let e = &found.earlier[0];
        assert_eq!(e.path, "$.data.version");
        assert_eq!(
            (e.deployed.clone(), e.live.clone()),
            (Some(json!("1")), Some(json!("2")))
        );
        assert_eq!((e.record.as_str(), e.partly_deployed), ("c-partial", true));
        let (id, _) = &diff.changed[0].resource_diffs[0];
        assert!(
            diff.labels[id]
                .iter()
                .any(|l| l.contains(&ChangeLabel::AppliedByEarlierDeploy)
                    && !l.contains(&ChangeLabel::RevertsDrift)),
            "{:?}",
            diff.labels[id]
        );
    }

    fn objects(p: &super::super::document::Packages) -> Vec<(String, Vec<String>)> {
        let mut out = Vec::new();
        for c in p.changed.iter().chain(p.cluster_level.iter()) {
            let mut modified: Vec<String> = c
                .modified_resources
                .iter()
                .map(|m| m.resource.clone())
                .collect();
            modified.sort();
            out.push((format!("{} added", c.key), c.added_resources.clone()));
            out.push((format!("{} removed", c.key), c.removed_resources.clone()));
            out.push((format!("{} modified", c.key), modified));
        }
        out.sort();
        out
    }

    /// A `kix plan` and a `kix diff` against the same live state, which
    /// holds the deployed build exactly, list the same objects; both
    /// documents parse back into `Plan`.
    #[test]
    fn plan_and_diff_agree_on_the_objects_they_both_checked() {
        use super::super::document::{Build, Detail, MadeBy, NotCheckedReason, Plan};
        let deployed = vec![
            configmap("app", "a", &"a".repeat(32), json!({"k": "1"})),
            configmap("app", "b", &"b".repeat(32), json!({"k": "1"})),
            configmap("app", "gone", &"g".repeat(32), json!({"k": "1"})),
        ];
        let new = vec![
            configmap("app", "a", &"c".repeat(32), json!({"k": "2"})),
            deployed[1].clone(),
            configmap("app", "d", &"d".repeat(32), json!({"k": "1"})),
        ];
        let new_graph = StoreGraph::synthesize(&new, &StoreGraph::empty("c"));
        let deployed_graph = StoreGraph::synthesize(&deployed, &new_graph);

        // kix diff: the live view is the deployed build.
        let diff_side = super::super::diff_graphs(&deployed_graph, &new_graph);
        let diff_doc = Plan::new(
            super::super::document::KixBuild::current(&crate::version::running().to_string()),
            MadeBy::LiveRead,
            "c",
            Build::of(&new_graph),
            &diff_side,
            Detail::Fields,
            &[],
            NotCheckedReason::ReadOnly,
        );

        // kix plan: the server applies the new build onto that live state.
        let mut plan_side = super::super::diff_graphs(&deployed_graph, &new_graph);
        let answers = vec![
            applied("a", Some(served(&deployed[0])), served(&new[0])),
            applied("d", None, served(&new[2])),
        ];
        Overlay {
            new_graph: &new_graph,
            deployed: Some(
                deployed
                    .iter()
                    .map(|m| (ResourceId::from_value(m), m))
                    .collect(),
            ),
            folded: HashMap::new(),
            manager: FieldManager::of("a"),
        }
        .apply(&mut plan_side, &answers);
        let plan_doc = Plan::new(
            super::super::document::KixBuild::current(&crate::version::running().to_string()),
            MadeBy::DryRun,
            "c",
            Build::of(&new_graph),
            &plan_side,
            Detail::Fields,
            &[],
            NotCheckedReason::ReadOnly,
        );

        assert_eq!(objects(&plan_doc.packages), objects(&diff_doc.packages));
        for doc in [&plan_doc, &diff_doc] {
            let parsed: Plan = serde_json::from_str(&doc.to_json()).unwrap();
            assert_eq!(&parsed, doc);
        }
    }
}
