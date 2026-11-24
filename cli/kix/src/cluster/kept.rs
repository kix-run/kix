//! Fields Kix sent that the API server did not store as sent.
//!
//! A CRD's schema prunes a field it does not declare, and a mutating
//! admission webhook can overwrite a value. The write still succeeds, so the
//! user's setting never takes effect and nothing else says so. [`not_kept`]
//! compares the manifest Kix sent with the object the server answered with.
//!
//! Only the fields Kix sent count. A field the server adds (a default,
//! `status`, metadata) is not a finding, and neither is a value the server
//! stores in another spelling that means the same thing. A field the object
//! cedes (`ownership.cede`, the `kix.run/cede-fields` annotation) is left
//! to another controller, so a value it stores there is not a finding either.
//!
//! This is the check at apply time. It catches what a build cannot know:
//! mutating admission webhooks, and CRDs the environment installs rather than
//! the build. A field a vendored CRD's schema prunes could be caught before
//! the deploy, by checking the manifest against that schema at build time.

use base64::Engine as _;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::cluster::apply::{Seg, ceded_fields};
use crate::manifest::diff::engine::structural_diff;
use crate::manifest::diff::equivalence::same_quantity;
use crate::manifest::diff::{DiffConfig, DiffKind, Difference};
use crate::manifest::{hash, types};
use crate::plan::server::comparable;

/// One field Kix sent that the server did not store as sent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct NotKeptField {
    /// The field, as a diff path (`$.spec.foo`).
    pub path: String,
    pub change: NotKept,
    /// The value Kix sent. A Secret value reads `(secret, not shown)`.
    pub sent: Value,
    /// The value the server stored. Absent when it dropped the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stored: Option<Value>,
}

/// What the server did with a field Kix sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum NotKept {
    /// The stored object does not have the field, for example because the
    /// CRD's schema does not declare it.
    Dropped,
    /// The stored object has another value, for example because a mutating
    /// admission webhook set it.
    Changed,
}

/// Return the fields of `sent` that `stored` does not keep, or keeps with
/// another value.
///
/// `sent` is the manifest of a server-side apply and `stored` the object the
/// server answered with, from a real apply or a dry run. A field counts as
/// kept when the diff engine finds no difference ([`structural_diff`] and its
/// equivalence rules), and also when:
///
/// - the object is of a built-in kind and Kix sent a zero value (`""`, `0`,
///   `false`, or an empty map or list). Go types cannot tell a zero value
///   from an absent field, so the server drops it or fills in a default. A
///   CRD stores a zero value as sent, so this rule does not apply to custom
///   resources.
/// - both values are the same resource quantity or the same number.
/// - a list item Kix sent sits elsewhere in the stored list, perhaps with
///   fields the server added.
/// - the field is at or under a path `sent` cedes in `kix.run/cede-fields`.
///
/// `sent` is the manifest as the apply sent it, so a Secret's values are
/// under `data`. Secret values are never returned.
pub fn not_kept(sent: &Value, stored: &Value) -> Vec<NotKeptField> {
    // The server answers in the version the request names. Another version
    // would make every renamed field look dropped.
    if sent.get("apiVersion") != stored.get("apiVersion") || sent.get("kind") != stored.get("kind")
    {
        return Vec::new();
    }
    let builtin = types::is_known_api(sent);
    let secret = types::is_secret(sent);
    let sent_view = sent_view(sent, stored, secret);
    let stored_view = stored_view(stored, secret);
    let rule = Rule { builtin };
    let ceded = ceded_fields(sent);
    let mut found = rule.judge(structural_diff(
        &sent_view,
        &stored_view,
        "$",
        &DiffConfig::default(),
    ));
    found.retain(|f| !ceded.iter().any(|c| cedes(c, &f.path)));
    for f in &mut found {
        let max = crate::plan::MAX_SHOWN_VALUE_BYTES;
        f.sent = crate::plan::shown_value(secret, &f.path, &f.sent, None, max);
        let sent = f.sent.clone();
        if let Some(v) = &mut f.stored {
            *v = crate::plan::shown_value(secret, &f.path, v, Some(&sent), max);
        }
    }
    found
}

/// Describe `fields` of `resource` on one line, for a deploy warning:
/// `Kubernetes did not keep fields Kix applied to Widget/w@app:
/// spec.colour dropped (sent "red")`.
pub fn describe(resource: &str, fields: &[NotKeptField]) -> String {
    let each: Vec<String> = fields.iter().map(describe_field).collect();
    format!(
        "Kubernetes did not keep fields Kix applied to {resource}: {}",
        each.join("; ")
    )
}

/// Describe one field: `spec.colour dropped (sent "red")` or
/// `spec.size changed (sent 2, stored 5)`.
pub fn describe_field(f: &NotKeptField) -> String {
    let path = f.path.trim_start_matches("$.");
    match (&f.change, &f.stored) {
        (NotKept::Changed, Some(stored)) => format!(
            "{path} changed (sent {}, stored {})",
            compact(&f.sent),
            compact(stored)
        ),
        _ => format!("{path} dropped (sent {})", compact(&f.sent)),
    }
}

/// Format `v` on one line, cut to 60 characters.
pub fn compact(v: &Value) -> String {
    const WIDTH: usize = 60;
    let full = v.to_string();
    if full.len() <= WIDTH {
        return full;
    }
    let cut = &full[..full.floor_char_boundary(WIDTH)];
    format!("{cut}… ({} bytes)", full.len())
}

struct Rule {
    builtin: bool,
}

impl Rule {
    /// Turn the differences from the sent manifest to the stored object into
    /// findings.
    fn judge(&self, diffs: Vec<Difference>) -> Vec<NotKeptField> {
        // Stored list items no sent item paired with. A sent item that is not
        // paired may still be kept by one of them.
        let mut spare: Vec<Difference> = diffs
            .iter()
            .filter(|d| d.kind == DiffKind::ExtraInB && list_of(&d.path).is_some())
            .cloned()
            .collect();
        let mut found = Vec::new();
        for d in diffs {
            let Some(sent) = d.a_value else {
                continue;
            };
            if self.builtin && is_zero(&sent) {
                continue;
            }
            match (d.kind, d.b_value) {
                (DiffKind::MissingInB, _) => {
                    if self.kept_by_spare(&d.path, &sent, &mut spare) {
                        continue;
                    }
                    found.push(NotKeptField {
                        path: d.path,
                        change: NotKept::Dropped,
                        sent,
                        stored: None,
                    });
                }
                (_, Some(stored)) => {
                    if same_quantity(&sent, &stored) || same_number(&sent, &stored) {
                        continue;
                    }
                    found.push(NotKeptField {
                        path: d.path,
                        change: NotKept::Changed,
                        sent,
                        stored: Some(stored),
                    });
                }
                (_, None) => {}
            }
        }
        found
    }

    /// Check whether a stored item of the same list keeps the list item `sent`
    /// at `path`, and if one does, take it out of `spare`.
    fn kept_by_spare(&self, path: &str, sent: &Value, spare: &mut Vec<Difference>) -> bool {
        let Some(list) = list_of(path) else {
            return false;
        };
        let keeper = spare.iter().position(|e| {
            list_of(&e.path) == Some(list)
                && e.b_value.as_ref().is_some_and(|stored| {
                    let diffs = structural_diff(sent, stored, path, &DiffConfig::default());
                    self.judge(diffs).is_empty()
                })
        });
        keeper.map(|i| spare.remove(i)).is_some()
    }
}

/// Check whether the ceded path `ceded` is `path`, a diff path such as
/// `$.webhooks[a.example.io].rules`, or a prefix of it. A ceded `[*]`
/// matches any list item, `[name="x"]` the item whose diff key is `x`, and
/// `[2]` the item at that index.
fn cedes(ceded: &[Seg], path: &str) -> bool {
    let Some(segs) = diff_segments(path) else {
        return false;
    };
    ceded.len() <= segs.len()
        && ceded.iter().zip(&segs).all(|(c, p)| match (c, p) {
            (Seg::Field(f), DiffSeg::Field(g)) => f == g,
            (Seg::Any, DiffSeg::Item(_)) => true,
            (Seg::Index(i), DiffSeg::Item(k)) => i.to_string() == *k,
            (Seg::Key(keys), DiffSeg::Item(k)) => match keys.as_slice() {
                [(_, Value::String(v))] => v == k,
                [(_, v)] => serde_json::from_str::<Value>(k).is_ok_and(|k| k == *v),
                _ => false,
            },
            _ => false,
        })
}

enum DiffSeg<'a> {
    Field(&'a str),
    Item(&'a str),
}

/// Split a diff path (`$.a.b[key].c`) into its segments, or return `None`
/// when it is malformed.
fn diff_segments(path: &str) -> Option<Vec<DiffSeg<'_>>> {
    let mut rest = path.strip_prefix('$')?;
    let mut out = Vec::new();
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix('[') {
            let end = after.find(']')?;
            out.push(DiffSeg::Item(&after[..end]));
            rest = &after[end + 1..];
        } else {
            let after = rest.strip_prefix('.')?;
            let end = after.find(['.', '[']).unwrap_or(after.len());
            out.push(DiffSeg::Field(&after[..end]));
            rest = &after[end..];
        }
    }
    Some(out)
}

/// Return the path of the list that the item at `path` belongs to, or `None`
/// when `path` is not a list item.
fn list_of(path: &str) -> Option<&str> {
    if !path.ends_with(']') {
        return None;
    }
    path.rfind('[').map(|i| &path[..i])
}

/// Check whether `v` is the zero value of its type, as Go's `omitempty`
/// treats it. An object whose members are all zero counts too.
fn is_zero(v: &Value) -> bool {
    match v {
        Value::Null => true,
        Value::Bool(b) => !b,
        Value::Number(n) => n.as_f64() == Some(0.0),
        Value::String(s) => s.is_empty(),
        Value::Array(items) => items.is_empty(),
        Value::Object(map) => map.values().all(is_zero),
    }
}

/// Check whether two numbers are equal as numbers, such as `1` and `1.0`.
fn same_number(a: &Value, b: &Value) -> bool {
    match (a.as_f64(), b.as_f64()) {
        (Some(x), Some(y)) => a.is_number() && b.is_number() && x == y,
        _ => false,
    }
}

/// Return the parts of `sent` the server stores.
///
/// `status` is left out because an apply does not write it. A namespace on an
/// object the server stores without one (a cluster-scoped kind) is left out
/// too.
fn sent_view(sent: &Value, stored: &Value, secret: bool) -> Value {
    let mut view = comparable(sent);
    hash::strip_kix_annotations(&mut view);
    if stored.pointer("/metadata/namespace").is_none()
        && let Some(meta) = view.get_mut("metadata").and_then(Value::as_object_mut)
    {
        meta.remove("namespace");
    }
    if secret && let Some(obj) = view.as_object_mut() {
        canonical_data(obj);
    }
    view
}

/// Return the parts of `stored` an apply writes.
fn stored_view(stored: &Value, secret: bool) -> Value {
    let mut view = comparable(stored);
    hash::strip_kix_annotations(&mut view);
    if secret && let Some(obj) = view.as_object_mut() {
        canonical_data(obj);
    }
    view
}

/// Re-encode each base64 value of a Secret's `data` in canonical form, so two
/// spellings of the same bytes compare equal. A value that does not decode is
/// left as it is.
fn canonical_data(secret: &mut Map<String, Value>) {
    let Some(Value::Object(data)) = secret.get_mut("data") else {
        return;
    };
    let engine = base64::engine::general_purpose::STANDARD;
    for v in data.values_mut() {
        if let Some(text) = v.as_str() {
            let compact: String = text.chars().filter(|c| !c.is_whitespace()).collect();
            if let Ok(bytes) = engine.decode(compact) {
                *v = Value::String(engine.encode(bytes));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn deployment(spec: Value) -> Value {
        json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "web", "namespace": "app"},
            "spec": spec,
        })
    }

    /// Return `obj` as the server answers: with server metadata and status.
    fn served(obj: &Value) -> Value {
        let mut o = obj.clone();
        o["metadata"]["resourceVersion"] = json!("42");
        o["metadata"]["uid"] = json!("u-1");
        o["metadata"]["creationTimestamp"] = json!("2026-11-05T00:00:00Z");
        o["metadata"]["managedFields"] = json!([{"manager": "kix", "operation": "Apply"}]);
        o["status"] = json!({"observedGeneration": 1});
        o
    }

    fn widget(spec: Value) -> Value {
        json!({
            "apiVersion": "example.com/v1",
            "kind": "Widget",
            "metadata": {"name": "w", "namespace": "app"},
            "spec": spec,
        })
    }

    #[test]
    fn a_field_the_crd_pruned_is_dropped() {
        let sent = widget(json!({"size": 3, "colour": "red"}));
        let stored = served(&widget(json!({"size": 3})));
        assert_eq!(
            not_kept(&sent, &stored),
            vec![NotKeptField {
                path: "$.spec.colour".into(),
                change: NotKept::Dropped,
                sent: json!("red"),
                stored: None,
            }]
        );
    }

    #[test]
    fn a_value_a_webhook_changed_is_changed_with_both_values() {
        let container = |image: &str| json!({"name": "web", "image": image});
        let pod = |image: &str| json!({"template": {"spec": {"containers": [container(image)]}}});
        let sent = deployment(pod("nginx:1.27"));
        let stored = served(&deployment(pod("mirror.example/nginx:1.27")));
        assert_eq!(
            not_kept(&sent, &stored),
            vec![NotKeptField {
                path: "$.spec.template.spec.containers[web].image".into(),
                change: NotKept::Changed,
                sent: json!("nginx:1.27"),
                stored: Some(json!("mirror.example/nginx:1.27")),
            }]
        );
    }

    #[test]
    fn a_zero_value_a_built_in_kind_drops_or_defaults_is_kept() {
        let sent = deployment(json!({
            "paused": false,
            "minReadySeconds": 0,
            "template": {"metadata": {"labels": {}}, "spec": {
                "serviceAccountName": "",
                "containers": [{"name": "web", "image": "nginx",
                    "imagePullPolicy": "",
                    "env": [{"name": "A", "value": ""}],
                    "readinessProbe": {"httpGet": {"path": "/", "port": 80}, "periodSeconds": 0},
                }],
            }},
        }));
        let stored = served(&deployment(json!({
            "template": {"spec": {
                "containers": [{"name": "web", "image": "nginx",
                    "imagePullPolicy": "IfNotPresent",
                    "env": [{"name": "A"}],
                    "readinessProbe": {"httpGet": {"path": "/", "port": 80, "scheme": "HTTP"},
                        "periodSeconds": 10, "timeoutSeconds": 1},
                }],
            }},
        })));
        assert_eq!(not_kept(&sent, &stored), vec![]);
    }

    #[test]
    fn a_custom_resource_keeps_a_zero_value_so_its_loss_is_reported() {
        let sent = widget(json!({"size": 3, "note": ""}));
        let stored = served(&widget(json!({"size": 3})));
        let found = not_kept(&sent, &stored);
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].path, "$.spec.note");
    }

    #[test]
    fn quantity_spellings_and_numbers_are_kept() {
        let resources = |cpu: Value, memory: &str| json!({"limits": {"cpu": cpu, "memory": memory}, "requests": {"cpu": "100m"}});
        let pod = |r: Value| {
            json!({"template": {"spec": {"containers": [
            {"name": "web", "image": "nginx", "resources": r}]}}})
        };
        let sent = deployment(pod(resources(json!(0.5), "1024Mi")));
        let stored = served(&deployment(pod(resources(json!("500m"), "1Gi"))));
        assert_eq!(not_kept(&sent, &stored), vec![]);

        // A quantity outside `limits`/`requests`, and an integral float.
        let pv = |capacity: &str, weight: Value| {
            json!({"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": "pv"},
                "spec": {"capacity": {"storage": capacity}, "weight": weight}})
        };
        assert_eq!(
            not_kept(&pv("1024Mi", json!(1.0)), &served(&pv("1Gi", json!(1)))),
            vec![]
        );
    }

    #[test]
    fn fields_the_server_adds_are_not_findings() {
        let sent = deployment(json!({"replicas": 2}));
        let mut stored = served(&deployment(
            json!({"replicas": 2, "revisionHistoryLimit": 10, "strategy": {"type": "RollingUpdate"}}),
        ));
        stored["metadata"]["annotations"] = json!({"deployment.kubernetes.io/revision": "1"});
        stored["metadata"]["generation"] = json!(1);
        assert_eq!(not_kept(&sent, &stored), vec![]);
    }

    #[test]
    fn status_and_a_cluster_scoped_namespace_are_not_findings() {
        let mut sent = json!({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRole",
            "metadata": {"name": "r", "namespace": "app"}, "rules": []});
        sent["status"] = json!({"phase": "Ready"});
        let mut stored = sent.clone();
        stored["metadata"]
            .as_object_mut()
            .unwrap()
            .remove("namespace");
        stored.as_object_mut().unwrap().remove("status");
        assert_eq!(not_kept(&sent, &served(&stored)), vec![]);
    }

    #[test]
    fn secret_data_is_kept_and_values_never_show() {
        let secret = |body: Value| {
            let mut s = json!({"apiVersion": "v1", "kind": "Secret",
                "metadata": {"name": "s", "namespace": "app"}, "type": "Opaque"});
            s.as_object_mut()
                .unwrap()
                .extend(body.as_object().unwrap().clone());
            s
        };
        let sent = secret(json!({"data": {"password": "aHVudGVyMg==", "k": "YWJj\n"}}));
        let stored = served(&secret(
            json!({"data": {"password": "aHVudGVyMg==", "k": "YWJj"}}),
        ));
        assert_eq!(not_kept(&sent, &stored), vec![]);

        let changed = served(&secret(
            json!({"data": {"password": "b3RoZXI=", "k": "YWJj"}}),
        ));
        let found = not_kept(&sent, &changed);
        let text = format!("{found:?}");
        for leaked in ["hunter2", "aHVudGVyMg==", "b3RoZXI=", "other"] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].path, "$.data.password");
        assert_eq!(found[0].change, NotKept::Changed);
    }

    #[test]
    fn a_reordered_list_is_kept() {
        let pod = |containers: Value, tolerations: Value| json!({"template": {"spec": {"containers": containers, "tolerations": tolerations}}});
        let a = json!({"name": "a", "image": "x"});
        let b = json!({"name": "b", "image": "y"});
        let t1 = json!({"key": "k1", "operator": "Exists"});
        let t2 = json!({"key": "k2", "operator": "Exists"});
        let sent = deployment(pod(json!([a, b]), json!([t1, t2])));
        let stored = served(&deployment(pod(json!([b, a]), json!([t2, t1]))));
        assert_eq!(not_kept(&sent, &stored), vec![]);
    }

    /// An unkeyed list item that moved and gained a server default still
    /// counts as kept.
    #[test]
    fn a_list_item_that_moved_and_gained_defaults_is_kept() {
        let sent = deployment(json!({"template": {"spec": {"tolerations": [
            {"key": "k1", "operator": "Exists"}]}}}));
        let stored = served(&deployment(json!({"template": {"spec": {"tolerations": [
            {"key": "injected", "operator": "Exists"},
            {"key": "k1", "operator": "Exists", "effect": "NoSchedule"}]}}})));
        assert_eq!(not_kept(&sent, &stored), vec![]);

        let lost = served(&deployment(json!({"template": {"spec": {"tolerations": [
            {"key": "injected", "operator": "Exists"}]}}})));
        let found = not_kept(&sent, &lost);
        assert_eq!(found.len(), 1, "{found:?}");
    }

    #[test]
    fn documented_server_defaults_are_kept() {
        let pod = |mount: Value| {
            json!({"template": {"spec": {"containers": [
            {"name": "web", "image": "nginx", "volumeMounts": [mount]}]}}})
        };
        let sent = deployment(pod(
            json!({"name": "v", "mountPath": "/v", "readOnly": false}),
        ));
        let stored = served(&deployment(pod(json!({"name": "v", "mountPath": "/v"}))));
        assert_eq!(not_kept(&sent, &stored), vec![]);
    }

    /// A field the object cedes is another controller's to set, so a value
    /// the server stores there is kept. A field the cede does not cover is
    /// still reported.
    #[test]
    fn a_ceded_field_the_server_changed_is_kept() {
        let cluster = |version: &str, cede: &str| {
            json!({"apiVersion": "stackgres.io/v1", "kind": "SGCluster",
                "metadata": {"name": "db", "namespace": "app",
                    "annotations": {crate::manifest::keys::CEDE_FIELDS: cede}},
                "spec": {"instances": 1, "postgres": {"version": version}}})
        };
        let sent = cluster("17", "spec.postgres.version");
        let stored = served(&cluster("17.4", "spec.postgres.version"));
        assert_eq!(not_kept(&sent, &stored), vec![]);

        let other = cluster("17", "spec.instances");
        let found = not_kept(&other, &served(&cluster("17.4", "spec.instances")));
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].path, "$.spec.postgres.version");

        // `[*]` covers every item of a list, and a ceded parent covers
        // the fields under it.
        let hook = |rules: &str, cede: &str| {
            json!({"apiVersion": "admissionregistration.k8s.io/v1",
                "kind": "ValidatingWebhookConfiguration",
                "metadata": {"name": "op",
                    "annotations": {crate::manifest::keys::CEDE_FIELDS: cede}},
                "webhooks": [{"name": "a.example.io", "sideEffects": "None",
                    "rules": [{"apiGroups": [rules]}]}]})
        };
        for cede in [
            "webhooks[*].rules",
            "webhooks[name=\"a.example.io\"]",
            "webhooks",
        ] {
            let found = not_kept(&hook("x", cede), &served(&hook("y", cede)));
            assert_eq!(found, vec![], "cede {cede}");
        }
        let found = not_kept(
            &hook("x", "webhooks[*].sideEffects"),
            &served(&hook("y", "webhooks[*].sideEffects")),
        );
        assert_eq!(found.len(), 1, "{found:?}");
    }

    #[test]
    fn another_api_version_is_not_compared() {
        let sent = widget(json!({"colour": "red"}));
        let mut stored = served(&widget(json!({})));
        stored["apiVersion"] = json!("example.com/v2");
        assert_eq!(not_kept(&sent, &stored), vec![]);
    }
}
