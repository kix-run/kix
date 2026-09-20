//! Preflight for topology labels: do the nodes carry the labels the plan's
//! placement rules name?
//!
//! The compiler derives `topologySpreadConstraints` on the cluster's zone
//! and host labels (`kix/lib/plugins/availability/module.nix`) and never
//! sees a node. Under `DoNotSchedule` a node without the label is not a
//! domain and cannot host the pod, so on a cluster whose nodes are labelled
//! with custom labels, a wrong `cluster.topology.zoneKey` leaves every replica Pending.
//! Without this check the first sign is a readiness stall that names the
//! Deployment and nothing else. One LIST of nodes before apply turns that
//! into a line that names the label and the nodes lacking it.
//!
//! Three pure steps and one call: [`topology_keys`] reads the keys out of
//! the manifests, [`list_nodes`] fetches the labels, [`assess`] compares
//! them, and each [`Finding`] describes itself. Only the fetch touches the
//! cluster, so the rest is unit-tested without one.

use std::collections::{BTreeMap, BTreeSet};

use k8s_openapi::api::core::v1::Node;
use kube::{Api, Client, api::ListParams};
use serde_json::Value;

use super::errors::{FailureClass, classify};
use crate::manifest::workload::pod_spec;

/// Which workloads name a topology key, split by how hard the rule is.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyUse {
    /// `DoNotSchedule` spread or `requiredDuringScheduling` (anti-)affinity:
    /// a node without the label cannot take the pod.
    pub hard: BTreeSet<String>,
    /// `ScheduleAnyway` spread or preferred (anti-)affinity: a node without
    /// the label is merely not counted.
    pub soft: BTreeSet<String>,
}

/// The labels of one node and whether a pod could land on it at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeLabels {
    pub name: String,
    /// False when the node is cordoned or carries a `NoSchedule` or
    /// `NoExecute` taint. Such a node is excluded by `nodeTaintsPolicy:
    /// Honor` and by the scheduler alike, so its labels do not matter.
    pub placeable: bool,
    pub labels: BTreeMap<String, String>,
}

/// What listing the nodes returned.
#[derive(Debug)]
pub enum NodesOutcome {
    Listed(Vec<NodeLabels>),
    /// The account may not list nodes. A fact about the account, not a
    /// failure of the deploy; the check is skipped and says so.
    Forbidden,
}

/// One topology label that some placeable node lacks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub key: String,
    /// Placeable nodes without the label, by name.
    pub missing: Vec<String>,
    /// How many placeable nodes there are in total.
    pub placeable: usize,
    /// The workloads whose hard rules name the key. Empty when only soft
    /// rules do.
    pub hard: BTreeSet<String>,
    pub soft: BTreeSet<String>,
}

impl Finding {
    /// True when the finding means pods will not schedule.
    pub fn is_warning(&self) -> bool {
        !self.hard.is_empty()
    }

    fn workloads(&self) -> String {
        let set = if self.hard.is_empty() {
            &self.soft
        } else {
            &self.hard
        };
        let mut names: Vec<&str> = set.iter().map(String::as_str).collect();
        let extra = names.len().saturating_sub(3);
        names.truncate(3);
        let mut s = names.join(", ");
        if extra > 0 {
            s.push_str(&format!(" and {extra} more"));
        }
        s
    }

    /// One line, plain language, naming the label, the nodes and the effect.
    pub fn describe(&self) -> String {
        let all = self.missing.len() == self.placeable;
        let where_ = if all {
            format!(
                "none of the {} schedulable node{} carries the label {}",
                self.placeable,
                if self.placeable == 1 { "" } else { "s" },
                self.key
            )
        } else {
            format!(
                "{} of {} schedulable nodes lack the label {} ({})",
                self.missing.len(),
                self.placeable,
                self.key,
                self.missing.join(", ")
            )
        };
        if self.hard.is_empty() {
            format!(
                "{where_}, so the best-effort spread of {} on it has no effect",
                self.workloads()
            )
        } else if all {
            format!(
                "{where_}, and {} must spread on it: every replica would stay Pending. \
                 Check cluster.topology.zoneKey and hostKey against the node labels",
                self.workloads()
            )
        } else {
            format!(
                "{where_}, and {} must spread on it: those nodes cannot take its pods",
                self.workloads()
            )
        }
    }
}

/// Every topology key the manifests' placement rules name, with the
/// workloads that name it. Reads every kind with a pod template
/// (`manifest::workload::pod_spec`).
pub fn topology_keys(manifests: &[Value]) -> BTreeMap<String, KeyUse> {
    let mut keys: BTreeMap<String, KeyUse> = BTreeMap::new();
    for m in manifests {
        let Some(pod) = pod_spec(m) else { continue };
        let who = workload_name(m);
        let mut record = |key: Option<&Value>, hard: bool| {
            if let Some(k) = key.and_then(Value::as_str)
                && !k.is_empty()
            {
                let entry = keys.entry(k.to_string()).or_default();
                if hard {
                    entry.hard.insert(who.clone());
                } else {
                    entry.soft.insert(who.clone());
                }
            }
        };
        for c in pod
            .pointer("/topologySpreadConstraints")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let hard = c.get("whenUnsatisfiable").and_then(Value::as_str) == Some("DoNotSchedule");
            record(c.get("topologyKey"), hard);
        }
        for side in ["podAntiAffinity", "podAffinity"] {
            let base = format!("/affinity/{side}");
            for term in pod
                .pointer(&format!(
                    "{base}/requiredDuringSchedulingIgnoredDuringExecution"
                ))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                record(term.get("topologyKey"), true);
            }
            for weighted in pod
                .pointer(&format!(
                    "{base}/preferredDuringSchedulingIgnoredDuringExecution"
                ))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                record(weighted.pointer("/podAffinityTerm/topologyKey"), false);
            }
        }
    }
    keys
}

fn workload_name(m: &Value) -> String {
    let kind = m.get("kind").and_then(Value::as_str).unwrap_or("?");
    let name = m
        .pointer("/metadata/name")
        .and_then(Value::as_str)
        .unwrap_or("?");
    match m.pointer("/metadata/namespace").and_then(Value::as_str) {
        Some(ns) => format!("{kind}/{name}@{ns}"),
        None => format!("{kind}/{name}"),
    }
}

/// List the nodes and reduce each to its name, placeability and labels.
pub async fn list_nodes(client: &Client) -> Result<NodesOutcome, kube::Error> {
    let api: Api<Node> = Api::all(client.clone());
    match api.list(&ListParams::default()).await {
        Ok(list) => Ok(NodesOutcome::Listed(
            list.items.iter().map(node_labels).collect(),
        )),
        Err(e) if classify(&e) == FailureClass::Forbidden => Ok(NodesOutcome::Forbidden),
        Err(e) => Err(e),
    }
}

fn node_labels(node: &Node) -> NodeLabels {
    let spec = node.spec.as_ref();
    let cordoned = spec.and_then(|s| s.unschedulable).unwrap_or(false);
    let tainted = spec.and_then(|s| s.taints.as_ref()).is_some_and(|taints| {
        taints
            .iter()
            .any(|t| t.effect == "NoSchedule" || t.effect == "NoExecute")
    });
    NodeLabels {
        name: node.metadata.name.clone().unwrap_or_default(),
        placeable: !cordoned && !tainted,
        labels: node
            .metadata
            .labels
            .clone()
            .unwrap_or_default()
            .into_iter()
            .collect(),
    }
}

/// Compare the keys the plan names with the labels the placeable nodes
/// carry. A soft-only key is reported only when no node carries it, since
/// a partial soft spread still does what it can.
pub fn assess(keys: &BTreeMap<String, KeyUse>, nodes: &[NodeLabels]) -> Vec<Finding> {
    let placeable: Vec<&NodeLabels> = nodes.iter().filter(|n| n.placeable).collect();
    if placeable.is_empty() {
        return Vec::new();
    }
    keys.iter()
        .filter_map(|(key, use_)| {
            let missing: Vec<String> = placeable
                .iter()
                .filter(|n| !n.labels.contains_key(key))
                .map(|n| n.name.clone())
                .collect();
            if missing.is_empty() || (use_.hard.is_empty() && missing.len() < placeable.len()) {
                return None;
            }
            Some(Finding {
                key: key.clone(),
                missing,
                placeable: placeable.len(),
                hard: use_.hard.clone(),
                soft: use_.soft.clone(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn deployment(name: &str, constraints: Value) -> Value {
        json!({
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": { "name": name, "namespace": "app" },
            "spec": { "template": { "spec": { "topologySpreadConstraints": constraints } } }
        })
    }

    fn node(name: &str, labels: &[(&str, &str)], placeable: bool) -> NodeLabels {
        NodeLabels {
            name: name.to_string(),
            placeable,
            labels: labels
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    const RACK: &str = "topology.example.com/rack";
    const HOST: &str = "kubernetes.io/hostname";

    #[test]
    fn keys_are_split_by_strictness_and_read_every_pod_template() {
        let manifests = vec![
            deployment(
                "web",
                json!([
                    { "topologyKey": RACK, "whenUnsatisfiable": "DoNotSchedule" },
                    { "topologyKey": HOST, "whenUnsatisfiable": "ScheduleAnyway" },
                ]),
            ),
            json!({
                "kind": "CronJob", "metadata": { "name": "tick", "namespace": "app" },
                "spec": { "jobTemplate": { "spec": { "template": { "spec": { "affinity": {
                    "podAntiAffinity": {
                        "requiredDuringSchedulingIgnoredDuringExecution": [ { "topologyKey": HOST } ],
                        "preferredDuringSchedulingIgnoredDuringExecution": [
                            { "weight": 1, "podAffinityTerm": { "topologyKey": RACK } }
                        ]
                    }
                } } } } } }
            }),
            json!({ "kind": "Service", "metadata": { "name": "svc" }, "spec": {} }),
        ];
        let keys = topology_keys(&manifests);
        assert_eq!(keys.len(), 2);
        assert_eq!(
            keys[RACK].hard,
            BTreeSet::from(["Deployment/web@app".to_string()])
        );
        assert_eq!(
            keys[RACK].soft,
            BTreeSet::from(["CronJob/tick@app".to_string()])
        );
        assert_eq!(
            keys[HOST].hard,
            BTreeSet::from(["CronJob/tick@app".to_string()])
        );
        assert_eq!(
            keys[HOST].soft,
            BTreeSet::from(["Deployment/web@app".to_string()])
        );
    }

    #[test]
    fn a_hard_key_no_node_carries_is_a_warning_naming_pending() {
        let keys = topology_keys(&[deployment(
            "web",
            json!([{ "topologyKey": RACK, "whenUnsatisfiable": "DoNotSchedule" }]),
        )]);
        let nodes = vec![
            node("w1", &[(HOST, "w1")], true),
            node("w2", &[(HOST, "w2")], true),
            // The tainted control plane lacks the label too, and must not
            // count: nodeTaintsPolicy Honor excludes it anyway.
            node("cp", &[(HOST, "cp")], false),
        ];
        let findings = assess(&keys, &nodes);
        assert_eq!(findings.len(), 1);
        let f = &findings[0];
        assert!(f.is_warning());
        assert_eq!(f.missing, vec!["w1", "w2"]);
        assert_eq!(f.placeable, 2);
        let line = f.describe();
        assert!(
            line.starts_with(
                "none of the 2 schedulable nodes carries the label topology.example.com/rack"
            ),
            "{line}"
        );
        assert!(
            line.contains("Deployment/web@app must spread on it: every replica would stay Pending"),
            "{line}"
        );
        assert!(
            line.contains("cluster.topology.zoneKey and hostKey"),
            "{line}"
        );
    }

    #[test]
    fn a_hard_key_some_nodes_lack_names_those_nodes() {
        let keys = topology_keys(&[deployment(
            "web",
            json!([{ "topologyKey": RACK, "whenUnsatisfiable": "DoNotSchedule" }]),
        )]);
        let nodes = vec![
            node("w1", &[(RACK, "a")], true),
            node("w2", &[(RACK, "b")], true),
            node("w3", &[], true),
        ];
        let findings = assess(&keys, &nodes);
        assert_eq!(findings.len(), 1);
        let line = findings[0].describe();
        assert!(
            line.starts_with(
                "1 of 3 schedulable nodes lack the label topology.example.com/rack (w3)"
            ),
            "{line}"
        );
        assert!(line.ends_with("those nodes cannot take its pods"), "{line}");
    }

    #[test]
    fn a_soft_key_is_reported_only_when_no_node_carries_it() {
        let keys = topology_keys(&[deployment(
            "web",
            json!([{ "topologyKey": RACK, "whenUnsatisfiable": "ScheduleAnyway" }]),
        )]);
        let partial = vec![node("w1", &[(RACK, "a")], true), node("w2", &[], true)];
        assert!(assess(&keys, &partial).is_empty());

        let none = vec![node("w1", &[], true), node("w2", &[], true)];
        let findings = assess(&keys, &none);
        assert_eq!(findings.len(), 1);
        assert!(!findings[0].is_warning());
        assert!(
            findings[0]
                .describe()
                .ends_with("best-effort spread of Deployment/web@app on it has no effect")
        );
    }

    #[test]
    fn labelled_nodes_and_no_placeable_nodes_produce_nothing() {
        let keys = topology_keys(&[deployment(
            "web",
            json!([{ "topologyKey": RACK, "whenUnsatisfiable": "DoNotSchedule" }]),
        )]);
        let labelled = vec![
            node("w1", &[(RACK, "a")], true),
            node("w2", &[(RACK, "b")], true),
        ];
        assert!(assess(&keys, &labelled).is_empty());
        let only_tainted = vec![node("cp", &[], false)];
        assert!(assess(&keys, &only_tainted).is_empty());
    }

    #[test]
    fn many_workloads_are_truncated_in_the_line() {
        let keys = topology_keys(
            &["a", "b", "c", "d", "e"]
                .iter()
                .map(|n| {
                    deployment(
                        n,
                        json!([{ "topologyKey": RACK, "whenUnsatisfiable": "DoNotSchedule" }]),
                    )
                })
                .collect::<Vec<_>>(),
        );
        let findings = assess(&keys, &[node("w1", &[], true)]);
        let line = findings[0].describe();
        assert!(
            line.contains("Deployment/a@app, Deployment/b@app, Deployment/c@app and 2 more"),
            "{line}"
        );
    }

    #[test]
    fn node_reduction_marks_cordoned_and_tainted_nodes_unplaceable() {
        let n: Node = serde_json::from_value(json!({
            "metadata": { "name": "cp", "labels": { HOST: "cp" } },
            "spec": { "taints": [ { "key": "node-role.kubernetes.io/control-plane", "effect": "NoSchedule" } ] }
        }))
        .unwrap();
        let reduced = node_labels(&n);
        assert_eq!(reduced.name, "cp");
        assert!(!reduced.placeable);
        assert_eq!(reduced.labels.get(HOST).map(String::as_str), Some("cp"));

        let n: Node = serde_json::from_value(json!({
            "metadata": { "name": "w1" },
            "spec": { "unschedulable": true }
        }))
        .unwrap();
        assert!(!node_labels(&n).placeable);

        let n: Node = serde_json::from_value(json!({
            "metadata": { "name": "w2" },
            "spec": { "taints": [ { "key": "soft", "effect": "PreferNoSchedule" } ] }
        }))
        .unwrap();
        assert!(node_labels(&n).placeable);
    }
}
