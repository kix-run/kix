//! Three-way labels: what made each field change.
//!
//! A comparison against the live cluster mixes the changes a commit makes
//! with the drift a deploy would undo. Each field change is compared with
//! two more objects: the deployed build's manifest (`deployed`, the closure
//! the Active record names) and the new build's manifest. A change is
//! `intended` where those two differ, and comes from drift where the live
//! object differs from the deployed manifest.

use std::collections::{BTreeSet, HashMap};

use crate::cluster::drift;
use crate::cluster::fieldsv1::KIX_FIELD_MANAGER;
use crate::manifest::diff::engine::structural_diff;
use crate::manifest::diff::{DiffConfig, DiffKind, Difference};
use crate::manifest::keys;
use crate::manifest::types::{self, ResourceId};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Where a field change comes from. A change can carry both an intent label
/// and a drift label: the commit changes a field someone also edited by hand.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum ChangeLabel {
    /// The deployed build and the new build differ here.
    Intended,
    /// The live object differs from the deployed build here, and the deploy
    /// applies this object, so it puts the build's value back.
    RevertsDrift,
    /// The live object differs from the deployed build here, and the deploy
    /// leaves this object alone because its identity hash did not change, so
    /// the difference stays. `kix deploy --reconcile` applies it.
    DriftKept,
    /// The live object differs from the deployed build here because a deploy
    /// that did not finish wrote it: the live value is the one that deploy's
    /// build has. The plan's `earlier_deploys` names the deploy record.
    AppliedByEarlierDeploy,
}

/// A deploy record whose build a plan folded in: one that stopped, or one
/// that `kix deploy --only` left partly deployed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FoldedBy {
    pub record: String,
    pub partly_deployed: bool,
}

/// A field where the live object differs from the deployed build.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Drifted {
    pub path: String,
    pub deployed: Option<Value>,
    pub live: Option<Value>,
    /// Field managers other than Kix that own the field on the live object.
    pub managers: Vec<String>,
    /// The folded deploy whose build has the live value, when one does.
    pub by: Option<FoldedBy>,
}

/// The objects one resource's labels are computed from.
pub(crate) struct ThreeWay<'a> {
    /// The deployed build's manifest; `None` when the deployed build does
    /// not contain the resource, which makes every change intended.
    pub deployed: Option<&'a Value>,
    /// The live object as compared: a server object or the Kix-owned view.
    pub live: &'a Value,
    pub new: &'a Value,
    /// The live object with its `managedFields`, for naming who made a
    /// drift change. `None` names nobody.
    pub managed: Option<&'a Value>,
    /// The deploy applies this resource (its identity hash changed, or
    /// `--reconcile`).
    pub applies: bool,
    /// A Secret: its `data` and `stringData` are hidden on at least one
    /// side, so drift in them cannot be judged and is not reported.
    pub secret: bool,
    /// This resource's manifest in each folded build that has it. A live
    /// value that differs from `deployed` and equals a folded build's value
    /// is that deploy's write, not drift.
    pub folded: &'a [(FoldedBy, &'a Value)],
}

impl ThreeWay<'_> {
    /// Return one label list per change in `changes`, in order, along with the
    /// drifted fields those changes touch.
    pub(crate) fn label(&self, changes: &[Difference]) -> (Vec<Vec<ChangeLabel>>, Vec<Drifted>) {
        let config = DiffConfig::new("deployed", "other");
        // Both builds: a list in another order is a change the build makes.
        let intended: Option<Vec<Difference>> = self
            .deployed
            .map(|d| structural_diff(d, self.new, "$", &config.clone().in_order()));
        // A field only the live object has is a server default or another
        // manager's field; applying the build does not touch it.
        let drift: Vec<Difference> = self
            .deployed
            .map(|d| structural_diff(d, self.live, "$", &config))
            .unwrap_or_default()
            .into_iter()
            .filter(|d| d.kind != DiffKind::ExtraInB)
            .filter(|d| !(self.secret && is_secret_value_path(&d.path)))
            .collect();
        // The folded deploy whose build holds each drifted live value, by an
        // exact comparison of the value at the path.
        let by: Vec<Option<&FoldedBy>> = drift
            .iter()
            .map(|d| {
                self.folded
                    .iter()
                    .find(|(_, manifest)| value_at(manifest, &d.path) == d.b_value.as_ref())
                    .map(|(by, _)| by)
            })
            .collect();

        let mut touched: BTreeSet<usize> = BTreeSet::new();
        let labels = changes
            .iter()
            .map(|change| {
                let mut labels = Vec::new();
                let is_intended = match &intended {
                    None => true,
                    Some(diffs) => diffs.iter().any(|d| overlaps(&d.path, &change.path)),
                };
                if is_intended {
                    labels.push(ChangeLabel::Intended);
                }
                let (mut drifted, mut earlier) = (false, false);
                for (i, d) in drift.iter().enumerate() {
                    if overlaps(&d.path, &change.path) {
                        touched.insert(i);
                        match by[i] {
                            Some(_) => earlier = true,
                            None => drifted = true,
                        }
                    }
                }
                if drifted {
                    labels.push(if self.applies {
                        ChangeLabel::RevertsDrift
                    } else {
                        ChangeLabel::DriftKept
                    });
                }
                if earlier {
                    labels.push(ChangeLabel::AppliedByEarlierDeploy);
                }
                labels
            })
            .collect();

        let owners = self.managed.map(foreign_paths).unwrap_or_default();
        let drifted = touched
            .into_iter()
            .map(|i| {
                let d = &drift[i];
                let mut managers: Vec<String> = owners
                    .iter()
                    .filter(|(_, path)| managed_path_overlaps(path, &d.path))
                    .map(|(m, _)| m.clone())
                    .collect();
                managers.sort();
                managers.dedup();
                // The compared live side may be a projection that lacks a
                // field another manager took; the served object has it.
                let live = match self.managed {
                    Some(served) => value_at(served, &d.path).cloned(),
                    None => d.b_value.clone(),
                };
                let max = super::MAX_SHOWN_VALUE_BYTES;
                let shown = |v: Option<Value>, before: Option<&Value>| {
                    v.map(|v| super::shown_value(self.secret, &d.path, &v, before, max))
                };
                Drifted {
                    path: d.path.clone(),
                    deployed: shown(d.a_value.clone(), None),
                    live: shown(live, d.a_value.as_ref()),
                    managers,
                    by: by[i].cloned(),
                }
            })
            .collect();
        (labels, drifted)
    }
}

/// The objects a read-only comparison labels each modified resource from, by
/// resource id.
pub struct Sides<'a> {
    /// The deployed build's manifests.
    pub deployed: &'a HashMap<ResourceId, &'a Value>,
    /// The compared old side: the Kix-owned view of the live object.
    pub live: HashMap<ResourceId, &'a Value>,
    pub new: HashMap<ResourceId, &'a Value>,
    /// The live objects with their `managedFields`.
    pub managed: &'a HashMap<ResourceId, Value>,
    /// The live objects [`drift::check_object`] finds drifted. Only their
    /// changes can carry a drift label.
    pub drifted: &'a BTreeSet<ResourceId>,
}

/// Label every field change of a comparison whose old side is the live
/// cluster. A resource counts as applied when the deployed build lacks it or
/// its identity hash differs from the new build's, which is how `kix deploy`
/// decides.
///
/// A drift label goes only on an object that [`drift::check_object`] finds
/// drifted. Its verdict compares the server's own representations, so the
/// value diff against the deployed build, which also sees server
/// normalisation, cannot label an object in sync.
pub fn label_live(diff: &mut super::PackageDiff, sides: &Sides) {
    let mut labels = HashMap::new();
    for c in diff.changed_with_cluster_level() {
        for (rid, changes) in &c.resource_diffs {
            let (Some(live), Some(new)) = (sides.live.get(rid), sides.new.get(rid)) else {
                continue;
            };
            let deployed = sides.deployed.get(rid).copied();
            let applies = deployed.is_none_or(|d| {
                keys::get(d, keys::IDENTITY_HASH) != keys::get(new, keys::IDENTITY_HASH)
            });
            let three = ThreeWay {
                deployed,
                live,
                new,
                managed: sides.managed.get(rid),
                applies,
                secret: types::is_secret(live) || types::is_secret(new),
                folded: &[],
            };
            let (mut l, _) = three.label(changes);
            if !sides.drifted.contains(rid) {
                for change in &mut l {
                    change.retain(|label| *label == ChangeLabel::Intended);
                }
            }
            labels.insert(rid.clone(), l);
        }
    }
    diff.labelled = true;
    diff.labels = labels;
}

/// Return the drift entries for live objects of a comparison against the
/// cluster, from [`drift::check_object`] and the live object alone.
///
/// `drifted` holds each live object the check found drifted. An object the
/// new build does not contain is left out, because the deploy does not apply
/// it. Each field another manager changed or took over, and that the new
/// build sets, is one entry, named with every manager that owns it. A replicas
/// change Kubernetes recorded no owner for is an entry with no manager. An
/// object with neither gets one entry at path `$`.
///
/// The deployed value comes from the manifest whose identity hash the live
/// object carries: the new build's when the build does not change the object,
/// or `deployed`'s. It is `None` when neither has that manifest.
pub fn live_drift(
    drifted: &[(drift::DriftReport, kube::api::DynamicObject)],
    new: &HashMap<ResourceId, &Value>,
    deployed: Option<&HashMap<ResourceId, &Value>>,
) -> Vec<super::document::DriftChange> {
    let mut out = Vec::new();
    for (report, obj) in drifted {
        let drift::DriftVerdict::Drifted {
            unrecorded_scale, ..
        } = &report.verdict
        else {
            continue;
        };
        let Some(&new) = new.get(&report.rid) else {
            continue;
        };
        let live_hash = obj
            .metadata
            .annotations
            .as_ref()
            .and_then(|a| keys::get_meta(a, keys::IDENTITY_HASH));
        let applies = live_hash.is_none() || live_hash != keys::get(new, keys::IDENTITY_HASH);
        let applied = if applies {
            deployed
                .and_then(|d| d.get(&report.rid).copied())
                .filter(|d| live_hash.is_some() && keys::get(d, keys::IDENTITY_HASH) == live_hash)
        } else {
            Some(new)
        };
        let served = crate::cluster::fieldsv1::merge_typed_metadata(obj);
        let secret = types::is_secret(new);
        let max = super::MAX_SHOWN_VALUE_BYTES;
        let shown = |path: &str, v: Option<&Value>, before: Option<&Value>| {
            v.map(|v| super::shown_value(secret, path, v, before, max))
        };
        let resource = report.rid.display_id();
        let first = out.len();

        let mut fields: Vec<(String, Vec<String>, drift::ForeignField)> = Vec::new();
        for field in drift::foreign_fields(obj) {
            if field.value_in(new).is_none() {
                continue;
            }
            match fields.iter_mut().find(|(path, _, _)| *path == field.path) {
                Some((_, managers, _)) => managers.push(field.manager.clone()),
                None => fields.push((field.path.clone(), vec![field.manager.clone()], field)),
            }
        }
        for (path, mut managers, field) in fields {
            managers.sort();
            managers.dedup();
            let path = field
                .diff_path(&served)
                .or_else(|| field.diff_path(new))
                .unwrap_or_else(|| format!("$.{path}"));
            let before = applied.and_then(|a| field.value_in(a));
            out.push(super::document::DriftChange {
                deployed: shown(&path, before, None),
                live: shown(&path, field.value_in(&served), before),
                resource: resource.clone(),
                path,
                managers,
                reverted: applies,
            });
        }
        if let Some(scale) = unrecorded_scale {
            out.push(super::document::DriftChange {
                resource: resource.clone(),
                path: format!("$.{}", scale.path),
                deployed: Some(Value::from(scale.deployed)),
                live: Some(Value::from(scale.live)),
                managers: Vec::new(),
                reverted: applies,
            });
        }
        if out.len() == first {
            out.push(super::document::DriftChange {
                resource,
                path: "$".to_string(),
                deployed: None,
                live: None,
                managers: Vec::new(),
                reverted: applies,
            });
        }
    }
    out
}

/// Label every field change `intended`: the old side is a build, so every
/// difference is one the new build makes.
pub fn label_builds(diff: &mut super::PackageDiff) {
    let labels = diff
        .changed_with_cluster_level()
        .flat_map(|c| c.resource_diffs.iter())
        .map(|(rid, changes)| {
            (
                rid.clone(),
                vec![vec![ChangeLabel::Intended]; changes.len()],
            )
        })
        .collect();
    diff.labelled = true;
    diff.labels = labels;
}

/// Return true when one diff path equals or lies under the other.
pub(crate) fn overlaps(a: &str, b: &str) -> bool {
    let under = |child: &str, parent: &str| {
        child.len() > parent.len()
            && child.starts_with(parent)
            && matches!(child.as_bytes()[parent.len()], b'.' | b'[')
    };
    a == b || under(a, b) || under(b, a)
}

fn is_secret_value_path(path: &str) -> bool {
    ["$.data", "$.stringData"].iter().any(|f| overlaps(f, path))
}

/// Return the value at diff-engine `path` (such as
/// `$.spec.containers[web].image`) in `obj`. Map keys may contain dots
/// (annotation keys), so each step takes the longest matching key; list
/// elements are matched by their diff-engine key or by position.
pub(crate) fn value_at<'v>(obj: &'v Value, path: &str) -> Option<&'v Value> {
    let mut node = obj;
    let mut rest = path.strip_prefix('$')?;
    let mut field = "";
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix('.') {
            let map = node.as_object()?;
            let key = map
                .keys()
                .filter(|k| {
                    r.strip_prefix(k.as_str())
                        .is_some_and(|after| after.is_empty() || after.starts_with(['.', '[']))
                })
                .max_by_key(|k| k.len())?;
            node = &map[key];
            field = key;
            rest = &r[key.len()..];
        } else if let Some(r) = rest.strip_prefix('[') {
            let end = r.find(']')?;
            let wanted = &r[..end];
            let items = node.as_array()?;
            node = items
                .iter()
                .find(|item| {
                    crate::manifest::diff::keyed_lists::extract_key(field, item).as_deref()
                        == Some(wanted)
                        || item.get("name").and_then(Value::as_str) == Some(wanted)
                })
                .or_else(|| wanted.parse::<usize>().ok().and_then(|i| items.get(i)))?;
            rest = &r[end + 1..];
        } else {
            return None;
        }
    }
    Some(node)
}

/// Return `(manager, path)` pairs for each non-status field owned by a manager
/// other than Kix on `live`.
fn foreign_paths(live: &Value) -> Vec<(String, String)> {
    let Ok(obj) = serde_json::from_value::<kube::api::DynamicObject>(live.clone()) else {
        return Vec::new();
    };
    drift::foreign_owners(&obj)
        .into_iter()
        .filter(|o| o.manager != KIX_FIELD_MANAGER)
        .flat_map(|o| {
            let manager = o.manager.clone();
            o.paths.into_iter().map(move |p| (manager.clone(), p))
        })
        .collect()
}

/// Return true when a `managedFields` path (`spec.template.spec.containers[name=web].image`)
/// and a diff path (`$.spec.template.spec.containers[web].image`) refer to
/// overlapping fields. Because the two formats spell list keys differently, a
/// keyed element matches any key.
fn managed_path_overlaps(managed: &str, diff_path: &str) -> bool {
    let a = segments(managed);
    let b = segments(diff_path.strip_prefix("$.").unwrap_or(diff_path));
    a.iter()
        .zip(b.iter())
        .all(|(x, y)| x == y || x == "[]" || y == "[]")
}

/// Split `path` into field names with every bracketed element replaced by `[]`.
fn segments(path: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    for c in path.chars() {
        match c {
            '[' => {
                if depth == 0 {
                    if !current.is_empty() {
                        out.push(std::mem::take(&mut current));
                    }
                    out.push("[]".to_string());
                }
                depth += 1;
            }
            ']' => depth = depth.saturating_sub(1),
            '.' if depth == 0 && !current.is_empty() => out.push(std::mem::take(&mut current)),
            '.' if depth == 0 => {}
            _ if depth == 0 => current.push(c),
            _ => {}
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::revision::AppliedHashes;
    use serde_json::json;

    fn deployment(replicas: i64, image: &str) -> Value {
        json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "web", "namespace": "app"},
            "spec": {
                "replicas": replicas,
                "template": {"spec": {"containers": [{"name": "web", "image": image}]}},
            },
        })
    }

    fn changes(from: &Value, to: &Value) -> Vec<Difference> {
        structural_diff(from, to, "$", &DiffConfig::new("live", "new"))
    }

    #[test]
    fn a_commit_change_is_intended_and_a_hand_scale_is_drift() {
        let deployed = deployment(1, "web:1");
        let new = deployment(1, "web:2");
        let mut live = deployment(3, "web:1");
        live["metadata"]["managedFields"] = json!([
            {"manager": "kix", "operation": "Apply",
             "fieldsV1": {"f:spec": {"f:replicas": {}}}},
            {"manager": "kubectl", "operation": "Update", "subresource": "scale",
             "fieldsV1": {"f:spec": {"f:replicas": {}}}},
        ]);
        let diffs = changes(&live, &new);
        let three = ThreeWay {
            deployed: Some(&deployed),
            live: &live,
            new: &new,
            managed: Some(&live),
            applies: true,
            secret: false,
            folded: &[],
        };
        let (labels, drifted) = three.label(&diffs);
        let by_path: Vec<(&str, &Vec<ChangeLabel>)> =
            diffs.iter().map(|d| d.path.as_str()).zip(&labels).collect();
        assert!(by_path.contains(&("$.spec.replicas", &vec![ChangeLabel::RevertsDrift])));
        assert!(by_path.contains(&(
            "$.spec.template.spec.containers[web].image",
            &vec![ChangeLabel::Intended]
        )));
        assert_eq!(drifted.len(), 1);
        assert_eq!(drifted[0].path, "$.spec.replicas");
        assert_eq!(drifted[0].deployed, Some(json!(1)));
        assert_eq!(drifted[0].live, Some(json!(3)));
        assert_eq!(drifted[0].managers, vec!["kubectl".to_string()]);
    }

    /// A live value that a folded build has is that deploy's write. A value
    /// no folded build has stays drift.
    #[test]
    fn a_value_a_folded_build_has_is_that_deploys_write() {
        let deployed = deployment(1, "web:1");
        let new = deployment(1, "web:2");
        let live = deployment(3, "web:1");
        let by = |record: &str| FoldedBy {
            record: record.into(),
            partly_deployed: true,
        };
        let other = deployment(4, "web:1");
        let wrote = deployment(3, "web:1");
        let folded = [(by("c-other"), &other), (by("c-partial"), &wrote)];
        let three = ThreeWay {
            deployed: Some(&deployed),
            live: &live,
            new: &new,
            managed: None,
            applies: true,
            secret: false,
            folded: &folded,
        };
        let diffs = changes(&live, &new);
        let (labels, drifted) = three.label(&diffs);
        let replicas = diffs
            .iter()
            .position(|d| d.path == "$.spec.replicas")
            .unwrap();
        assert_eq!(labels[replicas], vec![ChangeLabel::AppliedByEarlierDeploy]);
        assert_eq!(drifted.len(), 1);
        assert_eq!(drifted[0].by, Some(by("c-partial")));

        let unmatched = [(by("c-other"), &other)];
        let three = ThreeWay {
            folded: &unmatched,
            ..three
        };
        let (labels, drifted) = three.label(&diffs);
        assert_eq!(labels[replicas], vec![ChangeLabel::RevertsDrift]);
        assert_eq!(drifted[0].by, None);
    }

    #[test]
    fn drift_on_an_object_the_deploy_skips_is_kept() {
        let deployed = deployment(1, "web:1");
        let live = deployment(3, "web:1");
        let three = ThreeWay {
            deployed: Some(&deployed),
            live: &live,
            new: &deployed,
            managed: None,
            applies: false,
            secret: false,
            folded: &[],
        };
        let (labels, _) = three.label(&changes(&live, &deployed));
        assert_eq!(labels, vec![vec![ChangeLabel::DriftKept]]);
    }

    #[test]
    fn a_field_the_commit_and_a_hand_edit_both_changed_carries_both_labels() {
        let deployed = deployment(1, "web:1");
        let new = deployment(2, "web:1");
        let live = deployment(3, "web:1");
        let three = ThreeWay {
            deployed: Some(&deployed),
            live: &live,
            new: &new,
            managed: None,
            applies: true,
            secret: false,
            folded: &[],
        };
        let (labels, _) = three.label(&changes(&live, &new));
        assert_eq!(
            labels,
            vec![vec![ChangeLabel::Intended, ChangeLabel::RevertsDrift]]
        );
    }

    #[test]
    fn a_resource_the_deployed_build_lacks_is_all_intended() {
        let new = deployment(1, "web:1");
        let live = deployment(3, "web:1");
        let three = ThreeWay {
            deployed: None,
            live: &live,
            new: &new,
            managed: None,
            applies: true,
            secret: false,
            folded: &[],
        };
        let (labels, drifted) = three.label(&changes(&live, &new));
        assert_eq!(labels, vec![vec![ChangeLabel::Intended]]);
        assert!(drifted.is_empty());
    }

    /// A value diff against the deployed build also sees what the API server
    /// rewrote, so a change on an object the drift check finds in sync gets
    /// no drift label.
    #[test]
    fn a_drift_label_needs_a_drifted_verdict() {
        use crate::plan::fixtures::{diff_of, package_instance, stamped};
        let side = |replicas: i64| {
            vec![
                package_instance("app", "web", "1", "h-pi"),
                stamped(
                    "Deployment",
                    "app",
                    "web",
                    ("app", "web"),
                    "h-dep",
                    json!({"replicas": replicas}),
                ),
            ]
        };
        let (deployed, live) = (side(1), side(3));
        let rid = ResourceId::from_value(&deployed[1]);
        let labels_with = |drifted: BTreeSet<ResourceId>| {
            let mut diff = diff_of(&live, &deployed);
            let sides = Sides {
                deployed: &[(rid.clone(), &deployed[1])].into(),
                live: [(rid.clone(), &live[1])].into(),
                new: [(rid.clone(), &deployed[1])].into(),
                managed: &HashMap::new(),
                drifted: &drifted,
            };
            label_live(&mut diff, &sides);
            diff.labels[&rid].clone()
        };
        assert_eq!(
            labels_with(BTreeSet::new()),
            vec![Vec::<ChangeLabel>::new()]
        );
        assert_eq!(
            labels_with([rid.clone()].into()),
            vec![vec![ChangeLabel::DriftKept]]
        );
    }

    /// Build a live Deployment Kix applied with image `web:1` and replicas 1,
    /// whose stamp no longer matches, with the given `managedFields`
    /// entries. Kix's `Apply` entry owns `kix_fields` under `spec`.
    fn drifted_deployment(
        image: &str,
        kix_fields: Value,
        others: Value,
    ) -> (drift::DriftReport, kube::api::DynamicObject) {
        let mut entries = vec![json!({
            "manager": "kix", "operation": "Apply",
            "fieldsV1": {"f:spec": kix_fields},
        })];
        entries.extend(others.as_array().cloned().unwrap_or_default());
        let mut obj = deployment(1, image);
        obj["metadata"]["annotations"] = json!({
            keys::IDENTITY_HASH: "h-dep",
            keys::APPLIED_HASH: "stamp-at-apply",
            "deployment.kubernetes.io/revision": "2",
        });
        obj["metadata"]["managedFields"] = Value::Array(entries);
        let obj: kube::api::DynamicObject = serde_json::from_value(obj).unwrap();
        (
            drift::check_object(&obj, AppliedHashes::from_annotations().applied(&obj)),
            obj,
        )
    }

    fn new_build(image: &str) -> Value {
        let mut new = deployment(1, image);
        new["metadata"]["annotations"] = json!({keys::IDENTITY_HASH: "h-dep"});
        new
    }

    /// An image someone set with `kubectl edit` shows as drift from the live
    /// object alone, with no deployed build. A controller's annotation the
    /// build does not set is not listed.
    #[test]
    fn an_out_of_band_edit_shows_as_drift_without_the_deployed_build() {
        let live = drifted_deployment(
            "web:2",
            json!({"f:replicas": {}, "f:template": {"f:spec": {"f:containers": {
                "k:{\"name\":\"web\"}": {".": {}, "f:name": {}}
            }}}}),
            json!([
                {"manager": "kubectl-edit", "operation": "Update",
                 "fieldsV1": {"f:spec": {"f:template": {"f:spec": {"f:containers": {
                     "k:{\"name\":\"web\"}": {"f:image": {}}
                 }}}}}},
                {"manager": "kube-controller-manager", "operation": "Update",
                 "fieldsV1": {"f:metadata": {"f:annotations": {
                     "f:deployment.kubernetes.io/revision": {}
                 }}}},
            ]),
        );
        assert!(matches!(
            live.0.verdict,
            drift::DriftVerdict::Drifted { .. }
        ));
        let new = new_build("web:1");
        let rid = ResourceId::from_value(&new);
        let found = live_drift(&[live], &[(rid, &new)].into(), None);
        assert_eq!(
            found,
            vec![super::super::document::DriftChange {
                resource: "Deployment.apps/web@app".into(),
                path: "$.spec.template.spec.containers[web].image".into(),
                deployed: Some(json!("web:1")),
                live: Some(json!("web:2")),
                managers: vec!["kubectl-edit".into()],
                reverted: false,
            }]
        );
    }

    /// A field another manager took over at the build's own value is drift in
    /// who owns it, so it is listed there and not as a change.
    #[test]
    fn a_field_another_manager_took_shows_as_drift_at_its_value() {
        let live = drifted_deployment(
            "web:1",
            json!({"f:template": {}}),
            json!([{"manager": "kubectl-patch", "operation": "Update",
                    "fieldsV1": {"f:spec": {"f:replicas": {}}}}]),
        );
        let new = new_build("web:1");
        let rid = ResourceId::from_value(&new);
        let found = live_drift(&[live], &[(rid, &new)].into(), None);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].path, "$.spec.replicas");
        assert_eq!(found[0].live, found[0].deployed);
        assert_eq!(found[0].managers, vec!["kubectl-patch".to_string()]);
    }

    /// A drifted object the new build changes is applied, so its drift is
    /// reverted. Without the deployed build its deployed value is not known.
    /// An object no other manager touched gets one entry for the whole object.
    #[test]
    fn drift_with_no_named_field_is_one_entry_for_the_object() {
        let live = drifted_deployment("web:1", json!({"f:replicas": {}}), json!([]));
        let mut new = new_build("web:3");
        new["metadata"]["annotations"][keys::IDENTITY_HASH] = json!("h-dep-2");
        let rid = ResourceId::from_value(&new);
        let found = live_drift(&[live], &[(rid, &new)].into(), None);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].path, "$");
        assert!(found[0].reverted);
        assert_eq!(found[0].deployed, None);
    }

    #[test]
    fn a_value_is_found_by_its_diff_path() {
        let obj = json!({
            "metadata": {"annotations": {"example.com/source": "/nix/store/x"}},
            "spec": {"template": {"spec": {"containers": [
                {"name": "sidecar", "image": "s:1"},
                {"name": "web", "image": "web:1"},
            ]}}},
        });
        assert_eq!(
            value_at(&obj, "$.metadata.annotations.example.com/source"),
            Some(&json!("/nix/store/x"))
        );
        assert_eq!(
            value_at(&obj, "$.spec.template.spec.containers[web].image"),
            Some(&json!("web:1"))
        );
        assert_eq!(value_at(&obj, "$.spec.replicas"), None);
    }

    #[test]
    fn paths_overlap_on_segment_boundaries_only() {
        assert!(overlaps("$.spec", "$.spec.replicas"));
        assert!(overlaps("$.spec.ports[http]", "$.spec.ports"));
        assert!(!overlaps("$.spec.replica", "$.spec.replicas"));
        assert!(managed_path_overlaps(
            "spec.template.spec.containers[name=web].image",
            "$.spec.template.spec.containers[web].image"
        ));
        assert!(!managed_path_overlaps("spec.replicas", "$.spec.selector"));
    }
}
