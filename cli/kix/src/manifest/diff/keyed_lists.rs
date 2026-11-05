//! Keyed list matching for Kubernetes array fields.
//!
//! Instead of comparing list items by index, we match them by natural keys
//! (e.g. containers by `name`, ports by `name` or `containerPort:protocol`).
//!
//! These rules approximate the list keys Kubernetes declares in its schemas
//! with `x-kubernetes-list-type: map` and `x-kubernetes-list-map-keys`. A
//! lookup of those schema keys would go in [`try_key_lists`], ahead of the
//! name rules.

use indexmap::IndexMap;
use serde_json::Value;

/// A pair of keyed list indices (A-side, B-side) for matched comparison.
pub(crate) type KeyedListPair<'a> = (IndexMap<String, &'a Value>, IndexMap<String, &'a Value>);

/// Extract a match key from a list item based on the parent field name.
///
/// Returns `None` if the parent field is not a known keyed list type,
/// or if the item is not an object.
pub(crate) fn extract_key(parent_field: &str, item: &Value) -> Option<String> {
    let obj = item.as_object()?;
    match parent_field {
        "containers" | "initContainers" => obj
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        "ports" => {
            // Try name first, fall back to containerPort:protocol
            if let Some(name) = obj.get("name").and_then(|v| v.as_str())
                && !name.is_empty()
            {
                return Some(name.to_string());
            }
            let port = obj
                .get("containerPort")
                .or_else(|| obj.get("port"))
                .map(|v| match v {
                    Value::Number(n) => n.to_string(),
                    Value::String(s) => s.clone(),
                    _ => String::new(),
                })
                .unwrap_or_default();
            let protocol = obj
                .get("protocol")
                .and_then(|v| v.as_str())
                .unwrap_or("TCP");
            Some(format!("{port}:{protocol}"))
        }
        "volumes" => obj
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        "volumeMounts" => obj
            .get("mountPath")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        "env" => obj
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        "hostAliases" => obj
            .get("ip")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        "subjects" => {
            let kind = obj.get("kind").and_then(|v| v.as_str()).unwrap_or("");
            let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("");
            Some(format!("{kind}:{name}"))
        }
        "volumeClaimTemplates" => obj
            .get("metadata")
            .and_then(|m| m.get("name"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        _ => None,
    }
}

/// Return whether `parent_field` uses a dedicated natural key for list matching.
pub(crate) fn is_keyed_field(parent_field: &str) -> bool {
    matches!(
        parent_field,
        "containers"
            | "initContainers"
            | "ports"
            | "volumes"
            | "volumeMounts"
            | "env"
            | "hostAliases"
            | "subjects"
            | "volumeClaimTemplates"
    )
}

/// Try to build keyed indices for two lists. A known keyed field uses its
/// own key. Any other list is keyed by `metadata.name`, or else by `name`,
/// when every item on both sides has that field as a non-empty string.
/// Returns `None` if:
/// - The list is neither a known keyed field nor keyable by a name
/// - Any item is not an object
/// - Keys are not unique within either list
///
/// For ports: if any item in either list lacks a `name`, ALL items use
/// the `containerPort:protocol` fallback key. This prevents mismatches
/// when one side has a named port and the other doesn't.
pub(crate) fn try_key_lists<'a>(
    parent_field: &str,
    a: &'a [Value],
    b: &'a [Value],
) -> Option<KeyedListPair<'a>> {
    if !is_keyed_field(parent_field) {
        return key_by_name(a, b, |item| item.get("metadata")?.get("name"))
            .or_else(|| key_by_name(a, b, |item| item.get("name")));
    }

    // For ports, check if all items have names. If not, force containerPort:protocol keying.
    let effective_field = if parent_field == "ports" {
        let all_have_names = a.iter().chain(b.iter()).all(|item| {
            item.as_object()
                .and_then(|o| o.get("name"))
                .and_then(|v| v.as_str())
                .is_some_and(|s| !s.is_empty())
        });
        if all_have_names {
            "ports"
        } else {
            "ports_by_number"
        }
    } else {
        parent_field
    };

    let mut a_map = IndexMap::new();
    for item in a {
        let key = extract_key_inner(effective_field, item)?;
        if a_map.insert(key, item).is_some() {
            return None;
        }
    }

    let mut b_map = IndexMap::new();
    for item in b {
        let key = extract_key_inner(effective_field, item)?;
        if b_map.insert(key, item).is_some() {
            return None;
        }
    }

    Some((a_map, b_map))
}

/// Key two lists of named objects, such as a custom resource's list of
/// extensions or a VirtualMachine's `dataVolumeTemplates`, by the name `get`
/// finds in each item. An item changed in place then reads as a change to
/// that item rather than as one item removed and another added.
fn key_by_name<'a>(
    a: &'a [Value],
    b: &'a [Value],
    get: impl Fn(&'a Value) -> Option<&'a Value>,
) -> Option<KeyedListPair<'a>> {
    let index = |items: &'a [Value]| -> Option<IndexMap<String, &'a Value>> {
        let mut map = IndexMap::new();
        for item in items {
            let name = get(item)
                .and_then(Value::as_str)
                .filter(|n| !n.is_empty())?;
            if map.insert(name.to_string(), item).is_some() {
                return None;
            }
        }
        Some(map)
    };
    if a.is_empty() && b.is_empty() {
        return None;
    }
    Some((index(a)?, index(b)?))
}

/// Extract a match key for `field`, supporting the internal `ports_by_number` mode.
fn extract_key_inner(field: &str, item: &Value) -> Option<String> {
    if field == "ports_by_number" {
        let obj = item.as_object()?;
        let port = obj
            .get("containerPort")
            .or_else(|| obj.get("port"))
            .map(|v| match v {
                Value::Number(n) => n.to_string(),
                Value::String(s) => s.clone(),
                _ => String::new(),
            })
            .unwrap_or_default();
        let protocol = obj
            .get("protocol")
            .and_then(|v| v.as_str())
            .unwrap_or("TCP");
        Some(format!("{port}:{protocol}"))
    } else {
        extract_key(field, item)
    }
}

/// Extract the leaf field name from a JSON path, stripping array indices.
///
/// e.g. `$.spec.containers[nginx].ports` -> `ports`
/// e.g. `$.spec.volumes` -> `volumes`
pub(crate) fn path_leaf(path: &str) -> &str {
    let part = match path.rsplit_once('.') {
        Some((_, leaf)) => leaf,
        None => path,
    };
    match part.find('[') {
        Some(idx) => &part[..idx],
        None => part,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn extract_container_key() {
        let item = json!({"name": "nginx", "image": "nginx:latest"});
        assert_eq!(extract_key("containers", &item), Some("nginx".into()));
    }

    #[test]
    fn try_key_lists_success() {
        let a = vec![json!({"name": "a"}), json!({"name": "b"})];
        let b = vec![json!({"name": "b"}), json!({"name": "c"})];
        let result = try_key_lists("containers", &a, &b);
        assert!(result.is_some());
        let (a_map, b_map) = result.unwrap();
        assert_eq!(a_map.len(), 2);
        assert_eq!(b_map.len(), 2);
    }

    #[test]
    fn volume_claim_templates_key_by_metadata_name() {
        let a = vec![json!({"metadata": {"name": "data"}})];
        let b = vec![json!({"metadata": {"name": "data"}, "kind": "PersistentVolumeClaim"})];
        let (a_map, b_map) = try_key_lists("volumeClaimTemplates", &a, &b).unwrap();
        assert!(a_map.contains_key("data") && b_map.contains_key("data"));
    }

    #[test]
    fn other_lists_of_named_objects_key_by_name() {
        let a = vec![json!({"name": "cube"}), json!({"name": "vector"})];
        let b = vec![
            json!({"name": "vector", "publisher": "x"}),
            json!({"name": "cube"}),
        ];
        let (a_map, b_map) = try_key_lists("extensions", &a, &b).unwrap();
        assert_eq!(a_map.keys().collect::<Vec<_>>(), ["cube", "vector"]);
        assert_eq!(b_map.len(), 2);

        // One unnamed item, or a repeated name, leaves the list to
        // content matching.
        let unnamed = vec![json!({"name": "cube"}), json!({"version": "1"})];
        assert!(try_key_lists("extensions", &a, &unnamed).is_none());
        let repeated = vec![json!({"name": "cube"}), json!({"name": "cube"})];
        assert!(try_key_lists("extensions", &a, &repeated).is_none());
        assert!(try_key_lists("args", &[json!("a")], &[json!("b")]).is_none());
    }

    #[test]
    fn lists_of_embedded_objects_key_by_metadata_name() {
        let a = vec![
            json!({"metadata": {"name": "root"}}),
            json!({"metadata": {"name": "scratch"}}),
        ];
        let b = vec![
            json!({"metadata": {"name": "scratch"}}),
            json!({"metadata": {"name": "root", "creationTimestamp": null}}),
        ];
        let (a_map, b_map) = try_key_lists("dataVolumeTemplates", &a, &b).unwrap();
        assert_eq!(a_map.keys().collect::<Vec<_>>(), ["root", "scratch"]);
        assert_eq!(b_map.keys().collect::<Vec<_>>(), ["scratch", "root"]);

        // Without `metadata.name` on every item, `name` is tried next.
        let named = vec![
            json!({"name": "x", "metadata": {"name": "y"}}),
            json!({"name": "z"}),
        ];
        let (a_map, _) = try_key_lists("items", &named, &named).unwrap();
        assert_eq!(a_map.keys().collect::<Vec<_>>(), ["x", "z"]);
    }

    #[test]
    fn try_key_lists_duplicate_fails() {
        let a = vec![json!({"name": "a"}), json!({"name": "a"})];
        let b = vec![json!({"name": "b"})];
        assert!(try_key_lists("containers", &a, &b).is_none());
    }
}
