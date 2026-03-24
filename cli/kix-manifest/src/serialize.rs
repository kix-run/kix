//! JSON attrset → YAML manifest serialization, directory loading.

use std::path::Path;

use crate::types::ResourceId;

#[derive(thiserror::Error, Debug)]
pub enum ManifestLoadError {
    #[error("failed to walk directory: {0}")]
    WalkDir(#[from] walkdir::Error),
    #[error("failed to read file: {0}")]
    Io(#[from] std::io::Error),
    #[error("failed to parse YAML: {0}")]
    Yaml(#[from] serde_yml::Error),
}

/// Recursively remove null values and empty objects from a JSON value (in-place).
pub fn strip_nulls(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Array(arr) => {
            arr.retain(|v| !v.is_null());
            for item in arr.iter_mut() {
                strip_nulls(item);
            }
        }
        serde_json::Value::Object(map) => {
            map.retain(|_, v| !v.is_null());
            for v in map.values_mut() {
                strip_nulls(v);
            }
            // Remove objects that became empty after stripping
            map.retain(|_, v| !matches!(v, serde_json::Value::Object(m) if m.is_empty()));
        }
        _ => {}
    }
}

/// Convert a JSON value to a sorted-key YAML string.
///
/// serde_yml preserves insertion order, so we sort keys by converting to
/// a BTreeMap-based structure first.
fn to_sorted_yaml(value: &serde_json::Value) -> String {
    let sorted = sort_keys(value);
    serde_yml::to_string(&sorted).unwrap_or_default()
}

/// Recursively sort object keys by converting to BTreeMap-based serde_json::Value.
fn sort_keys(value: &serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => {
            let sorted: serde_json::Map<String, serde_json::Value> = map
                .iter()
                .map(|(k, v)| (k.clone(), sort_keys(v)))
                .collect::<std::collections::BTreeMap<_, _>>()
                .into_iter()
                .collect();
            serde_json::Value::Object(sorted)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(sort_keys).collect())
        }
        other => other.clone(),
    }
}

/// Serialize a list of manifest JSON values to multi-document YAML.
///
/// Documents are separated by `---\n`. Null values are stripped and keys are sorted.
pub fn manifests_to_yaml(manifests: &[serde_json::Value]) -> String {
    let mut output = String::new();
    for (i, manifest) in manifests.iter().enumerate() {
        let mut cleaned = manifest.clone();
        strip_nulls(&mut cleaned);
        if i > 0 {
            output.push_str("---\n");
        }
        output.push_str(&to_sorted_yaml(&cleaned));
    }
    output
}

/// Pretty-print manifests as a JSON array.
pub fn manifests_to_json(manifests: &[serde_json::Value]) -> String {
    serde_json::to_string_pretty(manifests).unwrap_or_else(|_| "[]".to_string())
}

/// Load YAML files from a directory, returning parsed manifests with their ResourceIds.
///
/// Handles both flat (`{ns}--{name}-{kind}.yaml`) and nested (`{ns}/{name}-{kind}.yaml`) layouts.
/// Skips packageinstance files and README.md.
pub fn load_manifests_from_dir(
    dir: &Path,
) -> Result<Vec<(ResourceId, serde_json::Value)>, ManifestLoadError> {
    let mut results = Vec::new();

    for entry in walkdir::WalkDir::new(dir)
        .min_depth(1)
        .max_depth(2)
        .sort_by_file_name()
    {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }

        let filename = entry.file_name().to_string_lossy();

        // Skip non-YAML files
        if !filename.ends_with(".yaml") {
            continue;
        }

        // Skip packageinstance files
        if filename.ends_with("-packageinstance.yaml") || filename.contains("-packageinstance.yaml")
        {
            continue;
        }

        let rid = if entry.depth() == 1 {
            // Flat layout: file directly in dir
            ResourceId::from_filename(&filename)
        } else {
            // Nested layout: dir/ns_dir/file.yaml
            let parent = entry
                .path()
                .parent()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().to_string());
            match parent {
                Some(ns_dir) => ResourceId::from_nested_path(&ns_dir, &filename),
                None => None,
            }
        };

        let rid = match rid {
            Some(r) => r,
            None => continue, // Skip unparseable filenames
        };

        // Skip oversized files to prevent memory exhaustion
        let file_meta = entry.metadata()?;
        if file_meta.len() > 10 * 1024 * 1024 {
            tracing::warn!(
                "skipping oversized file ({} bytes): {:?}",
                file_meta.len(),
                entry.path()
            );
            continue;
        }

        let contents = std::fs::read_to_string(entry.path())?;
        let value: serde_json::Value = serde_yml::from_str(&contents)?;
        results.push((rid, value));
    }

    Ok(results)
}

/// Write manifests as individual YAML files into a directory.
///
/// Each manifest is written as `{ns}--{name}-{kind}.yaml` using the ResourceId.
/// Returns the number of files written.
pub fn write_manifests_to_dir(
    manifests: &[serde_json::Value],
    dir: &Path,
) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
    let mut count = 0;
    for manifest in manifests {
        let rid = ResourceId::from_value(manifest);
        let filename = rid.to_flat_filename();
        let mut cleaned = manifest.clone();
        strip_nulls(&mut cleaned);
        let yaml = to_sorted_yaml(&cleaned);
        std::fs::write(dir.join(&filename), yaml)?;
        count += 1;
    }
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn strip_nulls_removes_null_values() {
        let mut val = json!({
            "a": 1,
            "b": null,
            "c": {
                "d": null,
                "e": "hello"
            }
        });
        strip_nulls(&mut val);
        assert_eq!(
            val,
            json!({
                "a": 1,
                "c": { "e": "hello" }
            })
        );
    }

    #[test]
    fn strip_nulls_removes_empty_objects() {
        let mut val = json!({
            "a": 1,
            "b": { "c": null }
        });
        strip_nulls(&mut val);
        assert_eq!(val, json!({ "a": 1 }));
    }

    #[test]
    fn strip_nulls_array() {
        let mut val = json!([1, null, "hello", null]);
        strip_nulls(&mut val);
        assert_eq!(val, json!([1, "hello"]));
    }

    #[test]
    fn strip_nulls_nested_array() {
        let mut val = json!({
            "items": [{"a": null, "b": 1}, null]
        });
        strip_nulls(&mut val);
        assert_eq!(val, json!({ "items": [{"b": 1}] }));
    }

    #[test]
    fn manifests_to_yaml_single_doc() {
        let manifests = vec![json!({
            "kind": "Service",
            "apiVersion": "v1",
            "metadata": { "name": "my-svc" }
        })];
        let yaml = manifests_to_yaml(&manifests);
        assert!(yaml.contains("apiVersion: v1"));
        assert!(yaml.contains("kind: Service"));
        // apiVersion should come before kind (sorted keys)
        let api_pos = yaml.find("apiVersion").unwrap();
        let kind_pos = yaml.find("kind").unwrap();
        assert!(api_pos < kind_pos, "keys should be sorted alphabetically");
    }

    #[test]
    fn manifests_to_yaml_multi_doc() {
        let manifests = vec![json!({"kind": "Service"}), json!({"kind": "Deployment"})];
        let yaml = manifests_to_yaml(&manifests);
        assert!(
            yaml.contains("---\n"),
            "documents should be separated by ---"
        );
        assert!(yaml.contains("kind: Service"));
        assert!(yaml.contains("kind: Deployment"));
    }

    #[test]
    fn manifests_to_yaml_strips_nulls() {
        let manifests = vec![json!({
            "kind": "Service",
            "spec": null
        })];
        let yaml = manifests_to_yaml(&manifests);
        assert!(!yaml.contains("spec"), "null values should be stripped");
        assert!(!yaml.contains("null"));
    }

    #[test]
    fn manifests_to_yaml_empty() {
        let yaml = manifests_to_yaml(&[]);
        assert!(yaml.is_empty());
    }

    #[test]
    fn manifests_to_json_output() {
        let manifests = vec![json!({"kind": "Service"}), json!({"kind": "Deployment"})];
        let output = manifests_to_json(&manifests);
        let parsed: Vec<serde_json::Value> = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0]["kind"], "Service");
    }

    #[test]
    fn manifests_to_json_empty() {
        let output = manifests_to_json(&[]);
        assert_eq!(output, "[]");
    }

    #[test]
    fn load_flat_layout() {
        let dir = TempDir::new().unwrap();
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": { "name": "my-svc", "namespace": "default" }
        });
        let yaml = serde_yml::to_string(&manifest).unwrap();
        fs::write(dir.path().join("default--my-svc-service.yaml"), &yaml).unwrap();

        let results = load_manifests_from_dir(dir.path()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0.namespace, "default");
        assert_eq!(results[0].0.name, "my-svc");
        assert_eq!(results[0].0.kind, "service");
        assert_eq!(results[0].1["kind"], "Service");
    }

    #[test]
    fn load_nested_layout() {
        let dir = TempDir::new().unwrap();
        let ns_dir = dir.path().join("kube-system");
        fs::create_dir(&ns_dir).unwrap();
        let manifest = json!({
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": { "name": "coredns", "namespace": "kube-system" }
        });
        fs::write(
            ns_dir.join("coredns-deployment.yaml"),
            serde_yml::to_string(&manifest).unwrap(),
        )
        .unwrap();

        let results = load_manifests_from_dir(dir.path()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0.namespace, "kube-system");
        assert_eq!(results[0].0.name, "coredns");
        assert_eq!(results[0].0.kind, "deployment");
    }

    #[test]
    fn load_skips_packageinstance() {
        let dir = TempDir::new().unwrap();
        let manifest = json!({"kind": "PackageInstance"});
        fs::write(
            dir.path().join("default--my-app-packageinstance.yaml"),
            serde_yml::to_string(&manifest).unwrap(),
        )
        .unwrap();
        fs::write(
            dir.path().join("default--my-svc-service.yaml"),
            serde_yml::to_string(&json!({"kind": "Service"})).unwrap(),
        )
        .unwrap();

        let results = load_manifests_from_dir(dir.path()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0.kind, "service");
    }

    #[test]
    fn load_skips_non_yaml() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("README.md"), "# Hello").unwrap();
        fs::write(dir.path().join("notes.txt"), "stuff").unwrap();

        let results = load_manifests_from_dir(dir.path()).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn sort_keys_nested() {
        let val = json!({
            "z": 1,
            "a": { "c": 3, "b": 2 }
        });
        let sorted = sort_keys(&val);
        let yaml = serde_yml::to_string(&sorted).unwrap();
        let a_pos = yaml.find('a').unwrap();
        let z_pos = yaml.find('z').unwrap();
        assert!(a_pos < z_pos);
    }
}
