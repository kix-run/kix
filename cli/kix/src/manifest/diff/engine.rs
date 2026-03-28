//! Core recursive structural differ on `serde_json::Value`.

use serde_json::Value;

use super::ignore::path_ignored;
use super::keyed_lists::{path_leaf, try_key_lists};
use super::{DiffConfig, Difference};

/// Compare two JSON values structurally, returning all differences.
///
/// Walks both trees in parallel, reporting differences by JSON path.
/// Dict key ordering does not matter. Lists use keyed matching for
/// known K8s fields, content-based matching otherwise.
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

            for key in all_keys {
                let child_path = format!("{path}.{key}");
                if path_ignored(&child_path, &config.ignore_paths) {
                    continue;
                }
                match (a_map.get(key), b_map.get(key)) {
                    (Some(av), Some(bv)) => {
                        diffs.extend(structural_diff(av, bv, &child_path, config));
                    }
                    (Some(av), None) => {
                        diffs.push(Difference::missing_in_b(child_path, av.clone()));
                    }
                    (None, Some(bv)) => {
                        diffs.push(Difference::extra_in_b(child_path, bv.clone()));
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

/// Diff two arrays, using keyed matching for known K8s fields,
/// content-based matching otherwise.
fn diff_arrays(a: &[Value], b: &[Value], path: &str, config: &DiffConfig) -> Vec<Difference> {
    let parent_field = path_leaf(path);

    // Try keyed-list matching first
    if let Some((a_map, b_map)) = try_key_lists(parent_field, a, b) {
        return diff_keyed_arrays(&a_map, &b_map, path, config);
    }

    // Fall back to content-based matching
    diff_content_arrays(a, b, path, config)
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

/// Diff two arrays by normalizing and matching on content.
fn diff_content_arrays(
    a: &[Value],
    b: &[Value],
    path: &str,
    config: &DiffConfig,
) -> Vec<Difference> {
    let mut diffs = Vec::new();

    let a_normed: Vec<Value> = a.iter().map(normalize_for_compare).collect();
    let b_normed: Vec<Value> = b.iter().map(normalize_for_compare).collect();

    let a_keyed: Vec<(String, &Value)> = a_normed.iter().map(|v| (sort_key_string(v), v)).collect();
    let b_keyed: Vec<(String, &Value)> = b_normed.iter().map(|v| (sort_key_string(v), v)).collect();

    // Group by canonical key
    let mut a_by_key: indexmap::IndexMap<String, Vec<&Value>> = indexmap::IndexMap::new();
    for (k, v) in &a_keyed {
        a_by_key.entry(k.clone()).or_default().push(v);
    }
    let mut b_by_key: indexmap::IndexMap<String, Vec<&Value>> = indexmap::IndexMap::new();
    for (k, v) in &b_keyed {
        b_by_key.entry(k.clone()).or_default().push(v);
    }

    // Merge all keys preserving sorted order
    let mut all_keys: Vec<String> = Vec::new();
    {
        let mut seen = std::collections::HashSet::new();
        let mut sorted_a: Vec<&str> = a_keyed.iter().map(|(k, _)| k.as_str()).collect();
        sorted_a.sort();
        let mut sorted_b: Vec<&str> = b_keyed.iter().map(|(k, _)| k.as_str()).collect();
        sorted_b.sort();
        for k in sorted_a.iter().chain(sorted_b.iter()) {
            if seen.insert(*k) {
                all_keys.push(k.to_string());
            }
        }
    }

    let mut idx = 0usize;
    for key in &all_keys {
        let a_items = a_by_key.get(key).map(|v| v.as_slice()).unwrap_or(&[]);
        let b_items = b_by_key.get(key).map(|v| v.as_slice()).unwrap_or(&[]);
        let paired = a_items.len().min(b_items.len());

        for j in 0..paired {
            let child_path = format!("{path}[{idx}]");
            if !path_ignored(&child_path, &config.ignore_paths) {
                diffs.extend(structural_diff(a_items[j], b_items[j], &child_path, config));
            }
            idx += 1;
            let _ = j;
        }
        for item in &a_items[paired..] {
            let child_path = format!("{path}[{idx}]");
            diffs.push(Difference::missing_in_b(child_path, (*item).clone()));
            idx += 1;
        }
        for item in &b_items[paired..] {
            let child_path = format!("{path}[{idx}]");
            diffs.push(Difference::extra_in_b(child_path, (*item).clone()));
            idx += 1;
        }
    }

    diffs
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
