//! Three-way labels: what made each field change.
//!
//! A comparison against the live cluster mixes the changes a commit makes
//! with the drift a deploy would undo. Each field change is compared with
//! two more objects: the deployed build's manifest (`deployed`, the closure
//! the Active record names) and the new build's manifest. A change is
//! `intended` where those two differ, and comes from drift where the live
//! object differs from the deployed manifest.

use std::collections::{BTreeSet, HashMap};

use kix::cluster::drift;
use kix::cluster::fieldsv1::KIX_FIELD_MANAGER;
use kix::manifest::diff::engine::structural_diff;
use kix::manifest::diff::{DiffConfig, DiffKind, Difference};
use kix::manifest::keys;
use kix::manifest::types::{self, ResourceId};
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
}

/// A field where the live object differs from the deployed build.
#[derive(Debug, Clone, PartialEq)]
pub struct Drifted {
    pub path: String,
    pub deployed: Option<Value>,
    pub live: Option<Value>,
    /// Field managers other than Kix that own the field on the live object.
    pub managers: Vec<String>,
}

/// The objects one resource's labels are computed from.
pub struct ThreeWay<'a> {
    /// The deployed build's manifest; `None` when the deployed build does
    /// not contain the resource, which makes every change intended.
    pub deployed: Option<&'a Value>,
    /// The live object as compared: a server object or the kix-owned view.
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
}

impl ThreeWay<'_> {
    /// One label list per change in `changes`, in order, and the drifted
    /// fields those changes touch.
    pub fn label(&self, changes: &[Difference]) -> (Vec<Vec<ChangeLabel>>, Vec<Drifted>) {
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
                let mut drifted = false;
                for (i, d) in drift.iter().enumerate() {
                    if overlaps(&d.path, &change.path) {
                        touched.insert(i);
                        drifted = true;
                    }
                }
                if drifted {
                    labels.push(if self.applies {
                        ChangeLabel::RevertsDrift
                    } else {
                        ChangeLabel::DriftKept
                    });
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
                }
            })
            .collect();
        (labels, drifted)
    }
}

/// The four objects a read-only comparison labels each modified resource
/// from, by resource id.
pub struct Sides<'a> {
    /// The deployed build's manifests.
    pub deployed: &'a HashMap<ResourceId, &'a Value>,
    /// The compared old side: the kix-owned view of the live object.
    pub live: HashMap<ResourceId, &'a Value>,
    pub new: HashMap<ResourceId, &'a Value>,
    /// The live objects with their `managedFields`.
    pub managed: &'a HashMap<ResourceId, Value>,
}

/// Label every field change of a comparison whose old side is the live
/// cluster, and return the drifted fields those changes touch. A resource
/// counts as applied when the deployed build lacks it or its identity hash
/// differs from the new build's, which is how `kix deploy` decides.
pub fn label_live(
    diff: &mut super::PackageDiff,
    sides: &Sides,
) -> Vec<super::document::DriftChange> {
    let mut labels = HashMap::new();
    let mut drift = Vec::new();
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
            };
            let (l, drifted) = three.label(changes);
            labels.insert(rid.clone(), l);
            drift.extend(drifted.into_iter().map(|d| super::document::DriftChange {
                resource: rid.display_id(),
                path: d.path,
                deployed: d.deployed,
                live: d.live,
                managers: d.managers,
                reverted: applies,
            }));
        }
    }
    diff.labelled = true;
    diff.labels = labels;
    drift
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

/// Whether one diff path is the other or lies under it.
pub fn overlaps(a: &str, b: &str) -> bool {
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

/// The value at diff-engine path `path` (`$.spec.containers[web].image`)
/// in `obj`. Map keys may contain dots (annotation keys), so each step takes
/// the longest key that matches; a list element is found by the key the
/// diff engine matched it on, or by position.
pub fn value_at<'v>(obj: &'v Value, path: &str) -> Option<&'v Value> {
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
                    kix::manifest::diff::keyed_lists::extract_key(field, item).as_deref()
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

/// `(manager, path)` for each field a manager other than Kix owns on the
/// live object, status writes left out.
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

/// Whether a managedFields path (`spec.template.spec.containers[name=web].image`)
/// and a diff path (`$.spec.template.spec.containers[web].image`) name
/// overlapping fields. The two spell list keys differently, so a keyed
/// element matches any key.
fn managed_path_overlaps(managed: &str, diff_path: &str) -> bool {
    let a = segments(managed);
    let b = segments(diff_path.strip_prefix("$.").unwrap_or(diff_path));
    a.iter()
        .zip(b.iter())
        .all(|(x, y)| x == y || x == "[]" || y == "[]")
}

/// Field names, with every bracketed element as `[]`.
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
        };
        let (labels, drifted) = three.label(&changes(&live, &new));
        assert_eq!(labels, vec![vec![ChangeLabel::Intended]]);
        assert!(drifted.is_empty());
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
