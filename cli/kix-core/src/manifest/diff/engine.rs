//! Core recursive structural differ on `serde_json::Value`.

use serde_json::Value;

use super::equivalence::{equivalent_to_unset, is_quantity_field, same_quantity};
use super::ignore::path_ignored;
use super::keyed_lists::{path_leaf, try_key_lists};
use super::{DiffConfig, Difference};

/// Compare two JSON values structurally, returning all differences.
///
/// Walks both trees in parallel, reporting differences by JSON path.
/// Dict key ordering does not matter. Lists use keyed matching for
/// known K8s fields and lists of named objects, content-based matching
/// otherwise (see [`diff_content_arrays`]). With
/// [`DiffConfig::ordered`], a list whose shared items sit in another order
/// is also a difference, at the list's path. Spellings the API server
/// treats as equal are not differences: see [`super::equivalence`].
pub fn structural_diff(a: &Value, b: &Value, path: &str, config: &DiffConfig) -> Vec<Difference> {
    if path_ignored(path, &config.ignore_paths) {
        return Vec::new();
    }

    match (a, b) {
        (Value::Null, Value::Null) => Vec::new(),

        // Both objects
        (Value::Object(a_map), Value::Object(b_map)) => {
            let mut diffs = Vec::new();
            let mut all_keys: Vec<&String> = a_map.keys().chain(b_map.keys()).collect();
            all_keys.sort();
            all_keys.dedup();

            let parent = path_leaf(path);
            for key in all_keys {
                let child_path = format!("{path}.{key}");
                if path_ignored(&child_path, &config.ignore_paths) {
                    continue;
                }
                match (a_map.get(key), b_map.get(key)) {
                    (Some(av), Some(bv)) => {
                        if (av.is_null() && equivalent_to_unset(&child_path, bv))
                            || (bv.is_null() && equivalent_to_unset(&child_path, av))
                            || (is_quantity_field(parent, key) && same_quantity(av, bv))
                        {
                            continue;
                        }
                        diffs.extend(structural_diff(av, bv, &child_path, config));
                    }
                    (Some(av), None) => {
                        if !equivalent_to_unset(&child_path, av) {
                            diffs.push(Difference::missing_in_b(child_path, av.clone()));
                        }
                    }
                    (None, Some(bv)) => {
                        if !equivalent_to_unset(&child_path, bv) {
                            diffs.push(Difference::extra_in_b(child_path, bv.clone()));
                        }
                    }
                    (None, None) => unreachable!(),
                }
            }
            diffs
        }

        // Both arrays
        (Value::Array(a_arr), Value::Array(b_arr)) => diff_arrays(a_arr, b_arr, path, config),

        // Number comparison: treat int/float as compatible
        (Value::Number(_), Value::Number(_)) => {
            if a != b {
                vec![Difference::value_mismatch(
                    path.to_string(),
                    a.clone(),
                    b.clone(),
                )]
            } else {
                Vec::new()
            }
        }

        // Same type, compare
        _ if std::mem::discriminant(a) == std::mem::discriminant(b) => {
            if a != b {
                vec![Difference::value_mismatch(
                    path.to_string(),
                    a.clone(),
                    b.clone(),
                )]
            } else {
                Vec::new()
            }
        }

        // Type mismatch
        _ => {
            vec![Difference::type_mismatch(
                path.to_string(),
                a.clone(),
                b.clone(),
            )]
        }
    }
}

/// Diff two arrays, using keyed matching for known K8s fields and lists of
/// named objects, content-based matching otherwise.
fn diff_arrays(a: &[Value], b: &[Value], path: &str, config: &DiffConfig) -> Vec<Difference> {
    let parent_field = path_leaf(path);

    // Try keyed-list matching first
    if let Some((a_map, b_map)) = try_key_lists(parent_field, a, b) {
        let mut diffs = diff_keyed_arrays(&a_map, &b_map, path, config);
        let a_keys: Vec<&String> = a_map.keys().collect();
        let b_keys: Vec<&String> = b_map.keys().collect();
        if config.ordered && reordered(&a_keys, &b_keys) {
            diffs.push(Difference::value_mismatch(
                path.to_string(),
                serde_json::json!(a_keys),
                serde_json::json!(b_keys),
            ));
        }
        return diffs;
    }

    // Fall back to content-based matching
    diff_content_arrays(a, b, path, config)
}

/// Check whether the items both lists hold, by key, sit in another order. A
/// repeated item counts as often as the side with fewer copies holds it.
fn reordered(a: &[&String], b: &[&String]) -> bool {
    let shared = |side: &[&String], other: &[&String]| -> Vec<String> {
        let mut left: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
        for k in other {
            *left.entry(k.as_str()).or_default() += 1;
        }
        side.iter()
            .filter(|k| match left.get_mut(k.as_str()) {
                Some(n) if *n > 0 => {
                    *n -= 1;
                    true
                }
                _ => false,
            })
            .map(|k| k.to_string())
            .collect()
    };
    shared(a, b) != shared(b, a)
}

/// Diff two keyed arrays by matching on natural keys.
fn diff_keyed_arrays(
    a_map: &indexmap::IndexMap<String, &Value>,
    b_map: &indexmap::IndexMap<String, &Value>,
    path: &str,
    config: &DiffConfig,
) -> Vec<Difference> {
    let mut diffs = Vec::new();

    // Preserve insertion order: a's keys first, then b-only keys
    let mut all_keys: Vec<&String> = Vec::new();
    for k in a_map.keys() {
        all_keys.push(k);
    }
    for k in b_map.keys() {
        if !a_map.contains_key(k) {
            all_keys.push(k);
        }
    }

    for key in all_keys {
        let child_path = format!("{path}[{key}]");
        if path_ignored(&child_path, &config.ignore_paths) {
            continue;
        }
        match (a_map.get(key), b_map.get(key)) {
            (Some(av), Some(bv)) => {
                diffs.extend(structural_diff(av, bv, &child_path, config));
            }
            (Some(av), None) => {
                diffs.push(Difference::missing_in_b(child_path, (*av).clone()));
            }
            (None, Some(bv)) => {
                diffs.push(Difference::extra_in_b(child_path, (*bv).clone()));
            }
            (None, None) => unreachable!(),
        }
    }

    diffs
}

/// Diff two lists that have no key, matching items by content. Unordered,
/// the lists inside each item are sorted first. Ordered, an item whose inner
/// list moved is a different item.
///
/// Items with equal content pair up wherever they sit. If the items left over
/// sit at the same positions in both lists, each one that [`same_item`]
/// accepts was changed in place. It is diffed against the item at its
/// position, so one changed field reads as one change. Every other leftover
/// is reported as removed at its index in `a` and added at its index in `b`. Pairing by position only when the
/// positions agree keeps an insertion or a removal from shifting every later
/// item into a false change.
fn diff_content_arrays(
    a: &[Value],
    b: &[Value],
    path: &str,
    config: &DiffConfig,
) -> Vec<Difference> {
    let item_path = format!("{path}[]");
    let content = |item: &Value| -> String {
        let item = drop_unset(&item_path, item);
        if config.ordered {
            sort_key_string(&item)
        } else {
            sort_key_string(&normalize_for_compare(&item))
        }
    };
    let a_keys: Vec<String> = a.iter().map(content).collect();
    let b_keys: Vec<String> = b.iter().map(content).collect();

    let mut unpaired_a: std::collections::HashMap<&str, std::collections::VecDeque<usize>> =
        std::collections::HashMap::new();
    for (i, k) in a_keys.iter().enumerate() {
        unpaired_a.entry(k.as_str()).or_default().push_back(i);
    }
    let mut left_b = Vec::new();
    for (j, k) in b_keys.iter().enumerate() {
        if unpaired_a
            .get_mut(k.as_str())
            .and_then(|q| q.pop_front())
            .is_none()
        {
            left_b.push(j);
        }
    }
    let mut left_a: Vec<usize> = unpaired_a.into_values().flatten().collect();
    left_a.sort_unstable();

    let (in_place, left_a, left_b): (Vec<usize>, Vec<usize>, Vec<usize>) = if left_a == left_b {
        let (same, other): (Vec<usize>, Vec<usize>) =
            left_a.into_iter().partition(|&i| same_item(&a[i], &b[i]));
        (same, other.clone(), other)
    } else {
        (Vec::new(), left_a, left_b)
    };

    let mut diffs = Vec::new();
    for &i in &in_place {
        let child_path = format!("{path}[{i}]");
        if !path_ignored(&child_path, &config.ignore_paths) {
            diffs.extend(structural_diff(&a[i], &b[i], &child_path, config));
        }
    }
    for &i in &left_a {
        let child_path = format!("{path}[{i}]");
        if !path_ignored(&child_path, &config.ignore_paths) {
            diffs.push(Difference::missing_in_b(child_path, a[i].clone()));
        }
    }
    for &j in &left_b {
        let child_path = format!("{path}[{j}]");
        if !path_ignored(&child_path, &config.ignore_paths) {
            diffs.push(Difference::extra_in_b(child_path, b[j].clone()));
        }
    }

    let a_refs: Vec<&String> = a_keys.iter().collect();
    let b_refs: Vec<&String> = b_keys.iter().collect();
    if config.ordered && reordered(&a_refs, &b_refs) {
        diffs.push(Difference::value_mismatch(
            path.to_string(),
            Value::Array(a.to_vec()),
            Value::Array(b.to_vec()),
        ));
    }

    diffs
}

/// Check whether two unkeyed items at the same position can be one item
/// changed in place. Two objects qualify when they share a top-level member
/// with the same scalar value, so `[A, B]` turning into `[B', A']` does not
/// read as A turning into B. Two values that are not objects always qualify.
fn same_item(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Object(a), Value::Object(b)) => a.iter().any(|(k, av)| {
            !av.is_object() && !av.is_array() && !av.is_null() && b.get(k) == Some(av)
        }),
        (Value::Object(_), _) | (_, Value::Object(_)) => false,
        _ => true,
    }
}

/// Return `value` without the members that mean the same as an absent field,
/// such as `creationTimestamp: null`, so they do not make two items' content
/// differ. `path` is the value's diff path, used to find server defaults.
fn drop_unset(path: &str, value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter_map(|(k, v)| {
                    let child = format!("{path}.{k}");
                    (!equivalent_to_unset(&child, v)).then(|| (k.clone(), drop_unset(&child, v)))
                })
                .collect(),
        ),
        Value::Array(items) => {
            let child = format!("{path}[]");
            Value::Array(items.iter().map(|v| drop_unset(&child, v)).collect())
        }
        other => other.clone(),
    }
}

/// Deep-sort all arrays within a value so order doesn't affect comparison.
fn normalize_for_compare(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let new_map: serde_json::Map<String, Value> = map
                .iter()
                .map(|(k, v)| (k.clone(), normalize_for_compare(v)))
                .collect();
            Value::Object(new_map)
        }
        Value::Array(arr) => {
            let mut items: Vec<Value> = arr.iter().map(normalize_for_compare).collect();
            items.sort_by_key(sort_key_string);
            Value::Array(items)
        }
        other => other.clone(),
    }
}

/// Return a canonical string key for any JSON value, for sorting/dedup.
fn sort_key_string(value: &Value) -> String {
    match value {
        Value::Null => "0:".to_string(),
        Value::Bool(b) => format!("1:{b}"),
        Value::Number(n) => format!("2:{n}"),
        Value::String(s) => format!("3:{s}"),
        Value::Array(arr) => {
            let inner: Vec<String> = arr.iter().map(sort_key_string).collect();
            format!("4:[{}]", inner.join(","))
        }
        Value::Object(map) => {
            let mut pairs: Vec<(String, String)> = map
                .iter()
                .map(|(k, v)| (k.clone(), sort_key_string(v)))
                .collect();
            pairs.sort();
            let inner: Vec<String> = pairs.iter().map(|(k, v)| format!("{k}={v}")).collect();
            format!("5:{{{}}}", inner.join(","))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::diff::DiffKind;
    use serde_json::json;

    fn cfg() -> DiffConfig {
        DiffConfig::new("kix", "cluster")
    }

    #[test]
    fn identical_values_no_diff() {
        let a = json!({"kind": "Deployment", "spec": {"replicas": 3}});
        let diffs = structural_diff(&a, &a, "$", &cfg());
        assert!(diffs.is_empty());
    }

    #[test]
    fn scalar_value_mismatch() {
        let a = json!({"replicas": 3});
        let b = json!({"replicas": 5});
        let diffs = structural_diff(&a, &b, "$", &cfg());
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].kind, DiffKind::ValueMismatch);
        assert_eq!(diffs[0].path, "$.replicas");
    }

    #[test]
    fn missing_key() {
        let a = json!({"a": 1, "b": 2});
        let b = json!({"a": 1});
        let diffs = structural_diff(&a, &b, "$", &cfg());
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].kind, DiffKind::MissingInB);
        assert_eq!(diffs[0].path, "$.b");
    }

    #[test]
    fn extra_key() {
        let a = json!({"a": 1});
        let b = json!({"a": 1, "c": 3});
        let diffs = structural_diff(&a, &b, "$", &cfg());
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].kind, DiffKind::ExtraInB);
        assert_eq!(diffs[0].path, "$.c");
    }

    #[test]
    fn nested_diff() {
        let a = json!({"spec": {"template": {"metadata": {"labels": {"app": "foo"}}}}});
        let b = json!({"spec": {"template": {"metadata": {"labels": {"app": "bar"}}}}});
        let diffs = structural_diff(&a, &b, "$", &cfg());
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "$.spec.template.metadata.labels.app");
    }

    #[test]
    fn keyed_list_containers_by_name() {
        let a = json!({
            "containers": [
                {"name": "app", "image": "v1"},
                {"name": "sidecar", "image": "s1"}
            ]
        });
        let b = json!({
            "containers": [
                {"name": "sidecar", "image": "s1"},
                {"name": "app", "image": "v2"}
            ]
        });
        let diffs = structural_diff(&a, &b, "$", &cfg());
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "$.containers[app].image");
        assert_eq!(diffs[0].kind, DiffKind::ValueMismatch);
    }

    // The noise classes below were recorded by `kix diff` on a kind cluster
    // right after a deploy that changed nothing. In each, `live` is the
    // kix-owned view of the object and `built` is the manifest kix applied.

    fn paths(diffs: &[Difference]) -> Vec<&str> {
        diffs.iter().map(|d| d.path.as_str()).collect()
    }

    #[test]
    fn a_defaulted_field_ref_api_version_is_not_a_difference() {
        let env = |field_ref: Value| {
            json!({"containers": [{"name": "app", "env": [
                {"name": "POD", "valueFrom": {"fieldRef": field_ref}}
            ]}]})
        };
        let live = env(json!({"apiVersion": "v1", "fieldPath": "metadata.name"}));
        let built = env(json!({"fieldPath": "metadata.name"}));
        assert!(structural_diff(&live, &built, "$", &cfg()).is_empty());

        let other = env(json!({"apiVersion": "v2", "fieldPath": "metadata.name"}));
        assert_eq!(
            paths(&structural_diff(&other, &built, "$", &cfg())),
            ["$.containers[app].env[POD].valueFrom.fieldRef.apiVersion"]
        );
    }

    #[test]
    fn empty_lists_and_nulls_the_server_drops_are_not_differences() {
        let live = json!({"template": {"metadata": {"labels": {"a": "b"}},
            "spec": {"containers": [{"name": "app", "image": "i"}]}}});
        let built = json!({"template": {"metadata": {"labels": {"a": "b"}, "annotations": null},
        "spec": {"initContainers": [], "containers": [
            {"name": "app", "image": "i", "env": [], "envFrom": []}
        ]}}});
        assert!(structural_diff(&live, &built, "$", &cfg()).is_empty());
        assert!(structural_diff(&built, &live, "$", &cfg()).is_empty());
    }

    #[test]
    fn zero_values_the_server_omits_are_not_differences() {
        let live = json!({"containers": [{"name": "app",
            "volumeMounts": [{"name": "s", "mountPath": "/s"}],
            "readinessProbe": {"httpGet": {"path": "/"}}}]});
        let built = json!({"containers": [{"name": "app",
            "volumeMounts": [{"name": "s", "mountPath": "/s", "readOnly": false}],
            "readinessProbe": {"httpGet": {"path": "/"}, "initialDelaySeconds": 0}}]});
        assert!(structural_diff(&live, &built, "$", &cfg()).is_empty());

        let read_only = json!({"containers": [{"name": "app",
            "volumeMounts": [{"name": "s", "mountPath": "/s", "readOnly": true}],
            "readinessProbe": {"httpGet": {"path": "/"}}}]});
        assert_eq!(
            paths(&structural_diff(&live, &read_only, "$", &cfg())),
            ["$.containers[app].volumeMounts[/s].readOnly"]
        );
    }

    #[test]
    fn a_null_probe_field_matches_its_default_and_nothing_else() {
        let probe = |threshold: Value| json!({"containers": [{"name": "op", "readinessProbe": {"failureThreshold": threshold}}]});
        let built = probe(json!(null));
        assert!(structural_diff(&probe(json!(3)), &built, "$", &cfg()).is_empty());

        let diffs = structural_diff(&probe(json!(5)), &built, "$", &cfg());
        assert_eq!(
            paths(&diffs),
            ["$.containers[op].readinessProbe.failureThreshold"]
        );
        assert_eq!(diffs[0].kind, DiffKind::TypeMismatch);
    }

    #[test]
    fn quantities_compare_by_amount_not_spelling() {
        let limits = |cpu: Value| json!({"initContainers": [{"name": "cni", "resources": {"limits": {"cpu": cpu}}}]});
        assert!(structural_diff(&limits(json!("1")), &limits(json!(1)), "$", &cfg()).is_empty());
        assert!(
            structural_diff(&limits(json!("500m")), &limits(json!(0.5)), "$", &cfg()).is_empty()
        );
        assert_eq!(
            paths(&structural_diff(
                &limits(json!("1")),
                &limits(json!(2)),
                "$",
                &cfg()
            )),
            ["$.initContainers[cni].resources.limits.cpu"]
        );
        // Outside a quantity map a string and a number stay different.
        let port = |p: Value| json!({"spec": {"targetPort": p}});
        assert_eq!(
            structural_diff(&port(json!("80")), &port(json!(80)), "$", &cfg())[0].kind,
            DiffKind::TypeMismatch
        );
    }

    #[test]
    fn claim_templates_match_by_name_and_ignore_server_filled_fields() {
        let live = json!({"volumeClaimTemplates": [{
            "apiVersion": "v1",
            "kind": "PersistentVolumeClaim",
            "metadata": {"name": "data"},
            "spec": {"accessModes": ["ReadWriteOnce"], "volumeMode": "Filesystem",
                     "resources": {"requests": {"storage": "8Gi"}}},
            "status": {"phase": "Pending"},
        }]});
        let built = |storage: &str| {
            json!({"volumeClaimTemplates": [{
                "metadata": {"name": "data"},
                "spec": {"accessModes": ["ReadWriteOnce"],
                         "resources": {"requests": {"storage": storage}}},
            }]})
        };
        assert!(structural_diff(&live, &built("8Gi"), "$", &cfg()).is_empty());
        assert_eq!(
            paths(&structural_diff(&live, &built("16Gi"), "$", &cfg())),
            ["$.volumeClaimTemplates[data].spec.resources.requests.storage"]
        );
    }

    #[test]
    fn a_field_an_operator_adds_to_named_list_items_reads_per_item() {
        let live = json!({"extensions": [
            {"name": "cube", "publisher": "com.ongres"},
            {"name": "vector", "publisher": "com.ongres"},
        ]});
        let built = json!({"extensions": [{"name": "cube"}, {"name": "vector"}]});
        assert_eq!(
            paths(&structural_diff(&live, &built, "$", &cfg())),
            [
                "$.extensions[cube].publisher",
                "$.extensions[vector].publisher"
            ]
        );
    }

    fn kinds(diffs: &[Difference]) -> Vec<(&str, DiffKind)> {
        diffs
            .iter()
            .map(|d| (d.path.as_str(), d.kind.clone()))
            .collect()
    }

    fn disk(id: &str, size: &str) -> Value {
        json!({"source": {"blank": {}}, "id": id, "storage": size})
    }

    #[test]
    fn one_changed_item_in_an_unkeyed_list_is_one_change_at_its_index() {
        let a = json!({"disks": [disk("root", "100Gi"), disk("scratch", "10Gi")]});
        let b = json!({"disks": [disk("root", "200Gi"), disk("scratch", "10Gi")]});
        assert_eq!(
            kinds(&structural_diff(&a, &b, "$", &cfg())),
            [("$.disks[0].storage", DiffKind::ValueMismatch)]
        );

        let b = json!({"disks": [disk("root", "100Gi"), disk("scratch", "20Gi")]});
        assert_eq!(
            kinds(&structural_diff(&a, &b, "$", &cfg())),
            [("$.disks[1].storage", DiffKind::ValueMismatch)]
        );
    }

    #[test]
    fn every_item_changed_in_an_unkeyed_list_reads_per_item() {
        let a = json!({"disks": [disk("root", "100Gi"), disk("scratch", "10Gi")]});
        let b = json!({"disks": [disk("root", "200Gi"), disk("scratch", "20Gi")]});
        assert_eq!(
            paths(&structural_diff(&a, &b, "$", &cfg())),
            ["$.disks[0].storage", "$.disks[1].storage"]
        );
    }

    #[test]
    fn a_null_only_difference_inside_list_items_is_not_a_difference() {
        let item = |id: &str, stamp: bool| {
            let mut v = json!({"metadata": {"labels": {"id": id}}, "spec": {"size": 1}});
            if stamp {
                v["metadata"]["creationTimestamp"] = Value::Null;
            }
            v
        };
        let live = json!({"templates": [item("a", true), item("b", true)]});
        let built = json!({"templates": [item("b", false), item("a", false)]});
        assert!(structural_diff(&live, &built, "$", &cfg()).is_empty());
        assert!(structural_diff(&built, &live, "$", &cfg()).is_empty());
    }

    #[test]
    fn data_volume_templates_match_by_metadata_name() {
        let template = |name: &str, size: &str, stamp: bool| {
            let mut v = json!({"metadata": {"name": name},
                "spec": {"storage": {"resources": {"requests": {"storage": size}}}}});
            if stamp {
                v["metadata"]["creationTimestamp"] = Value::Null;
            }
            v
        };
        let live = json!({"dataVolumeTemplates": [
            template("root", "100Gi", true), template("scratch", "10Gi", true)
        ]});
        let reordered = json!({"dataVolumeTemplates": [
            template("scratch", "10Gi", false), template("root", "200Gi", false)
        ]});
        assert_eq!(
            kinds(&structural_diff(&live, &reordered, "$", &cfg())),
            [(
                "$.dataVolumeTemplates[root].spec.storage.resources.requests.storage",
                DiffKind::ValueMismatch
            )]
        );
    }

    #[test]
    fn an_insertion_or_removal_reports_the_real_indexes() {
        let a = json!({"disks": [disk("a", "1Gi"), disk("b", "1Gi")]});
        let b = json!({"disks": [disk("a", "1Gi"), disk("x", "1Gi"), disk("b", "1Gi")]});
        assert_eq!(
            kinds(&structural_diff(&a, &b, "$", &cfg())),
            [("$.disks[1]", DiffKind::ExtraInB)]
        );
        assert_eq!(
            kinds(&structural_diff(&b, &a, "$", &cfg())),
            [("$.disks[1]", DiffKind::MissingInB)]
        );

        // A removal and an append in a list of the same length are not
        // mistaken for two items changed in place.
        let a = json!({"disks": [disk("a", "1Gi"), disk("b", "1Gi"), disk("c", "1Gi")]});
        let b = json!({"disks": [disk("a", "1Gi"), disk("c", "1Gi"), disk("d", "1Gi")]});
        assert_eq!(
            kinds(&structural_diff(&a, &b, "$", &cfg())),
            [
                ("$.disks[1]", DiffKind::MissingInB),
                ("$.disks[2]", DiffKind::ExtraInB)
            ]
        );
    }

    #[test]
    fn a_changed_scalar_in_an_unkeyed_list_is_one_value_change() {
        let a = json!({"args": ["--port", "80", "--verbose"]});
        let b = json!({"args": ["--port", "8080", "--verbose"]});
        assert_eq!(
            kinds(&structural_diff(&a, &b, "$", &cfg())),
            [("$.args[1]", DiffKind::ValueMismatch)]
        );
    }

    #[test]
    fn unrelated_items_at_the_same_position_are_not_paired() {
        let item = |id: &str, size: &str| json!({"id": id, "storage": size});
        let a = json!({"disks": [item("a", "1Gi"), item("b", "2Gi")]});
        let b = json!({"disks": [item("b", "3Gi"), item("a", "4Gi")]});
        assert_eq!(
            kinds(&structural_diff(&a, &b, "$", &cfg())),
            [
                ("$.disks[0]", DiffKind::MissingInB),
                ("$.disks[1]", DiffKind::MissingInB),
                ("$.disks[0]", DiffKind::ExtraInB),
                ("$.disks[1]", DiffKind::ExtraInB)
            ]
        );
    }

    #[test]
    fn ignore_exact_path() {
        let a = json!({"metadata": {"annotations": {"x": "1"}}, "spec": {"replicas": 3}});
        let b = json!({"metadata": {"annotations": {"x": "2"}}, "spec": {"replicas": 5}});
        let mut config = cfg();
        config
            .ignore_paths
            .insert("$.metadata.annotations".to_string());
        let diffs = structural_diff(&a, &b, "$", &config);
        assert_eq!(diffs.len(), 1);
        assert_eq!(diffs[0].path, "$.spec.replicas");
    }
}
