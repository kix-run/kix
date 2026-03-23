//! Keyed list matching for Kubernetes array fields.
//!
//! Instead of comparing list items by index, we match them by natural keys
//! (e.g. containers by `name`, ports by `name` or `containerPort:protocol`).

use indexmap::IndexMap;
use serde_json::Value;

/// A pair of keyed list indices (A-side, B-side) for matched comparison.
pub type KeyedListPair<'a> = (IndexMap<String, &'a Value>, IndexMap<String, &'a Value>);

/// Extract a match key from a list item based on the parent field name.
///
/// Returns `None` if the parent field is not a known keyed list type,
/// or if the item is not an object.
pub fn extract_key(parent_field: &str, item: &Value) -> Option<String> {
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
        _ => None,
    }
}

/// Returns true if this parent field name supports keyed-list matching.
pub fn is_keyed_field(parent_field: &str) -> bool {
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
    )
}

/// Try to build keyed indices for two lists. Returns `None` if:
/// - The parent field is not a known keyed list type
/// - Any item is not an object
/// - Keys are not unique within either list
///
/// For ports: if any item in either list lacks a `name`, ALL items use
/// the `containerPort:protocol` fallback key. This prevents mismatches
/// when one side has a named port and the other doesn't.
pub fn try_key_lists<'a>(
    parent_field: &str,
    a: &'a [Value],
    b: &'a [Value],
) -> Option<KeyedListPair<'a>> {
    if !is_keyed_field(parent_field) {
        return None;
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
            "ports" // use name-based keying
        } else {
            "ports_by_number" // force containerPort:protocol
        }
    } else {
        parent_field
    };

    let mut a_map = IndexMap::new();
    for item in a {
        let key = extract_key_inner(effective_field, item)?;
        if a_map.insert(key, item).is_some() {
            return None; // Duplicate key in A
        }
    }

    let mut b_map = IndexMap::new();
    for item in b {
        let key = extract_key_inner(effective_field, item)?;
        if b_map.insert(key, item).is_some() {
            return None; // Duplicate key in B
        }
    }

    Some((a_map, b_map))
}

/// Internal key extraction that handles the ports_by_number pseudo-field.
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
pub fn path_leaf(path: &str) -> &str {
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
    fn extract_port_key_by_name() {
        let item = json!({"name": "http", "containerPort": 80});
        assert_eq!(extract_key("ports", &item), Some("http".into()));
    }

    #[test]
    fn extract_port_key_by_port_protocol() {
        let item = json!({"containerPort": 8080, "protocol": "UDP"});
        assert_eq!(extract_key("ports", &item), Some("8080:UDP".into()));
    }

    #[test]
    fn extract_port_key_default_protocol() {
        let item = json!({"containerPort": 443});
        assert_eq!(extract_key("ports", &item), Some("443:TCP".into()));
    }

    #[test]
    fn extract_volume_mount_key() {
        let item = json!({"mountPath": "/var/log", "name": "logs"});
        assert_eq!(extract_key("volumeMounts", &item), Some("/var/log".into()));
    }

    #[test]
    fn extract_subject_key() {
        let item = json!({"kind": "ServiceAccount", "name": "default"});
        assert_eq!(
            extract_key("subjects", &item),
            Some("ServiceAccount:default".into())
        );
    }

    #[test]
    fn extract_host_alias_key() {
        let item = json!({"ip": "10.0.0.1", "hostnames": ["foo"]});
        assert_eq!(extract_key("hostAliases", &item), Some("10.0.0.1".into()));
    }

    #[test]
    fn unknown_field_returns_none() {
        let item = json!({"name": "x"});
        assert_eq!(extract_key("unknown", &item), None);
    }

    #[test]
    fn non_object_returns_none() {
        assert_eq!(extract_key("containers", &json!("string")), None);
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
    fn try_key_lists_duplicate_fails() {
        let a = vec![json!({"name": "a"}), json!({"name": "a"})];
        let b = vec![json!({"name": "b"})];
        assert!(try_key_lists("containers", &a, &b).is_none());
    }

    #[test]
    fn try_key_lists_unknown_field() {
        let a = vec![json!({"name": "a"})];
        let b = vec![json!({"name": "b"})];
        assert!(try_key_lists("unknown", &a, &b).is_none());
    }

    #[test]
    fn path_leaf_simple() {
        assert_eq!(path_leaf("$.spec.containers"), "containers");
    }

    #[test]
    fn path_leaf_with_index() {
        assert_eq!(path_leaf("$.spec.containers[nginx].ports"), "ports");
    }

    #[test]
    fn path_leaf_root() {
        assert_eq!(path_leaf("$"), "$");
    }
}
