//! JSON attrset → YAML manifest serialization, directory loading.

use std::path::Path;

use super::types::ResourceId;

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
fn to_sorted_yaml(value: &serde_json::Value) -> Result<String, serde_yml::Error> {
    let sorted = sort_keys(value);
    serde_yml::to_string(&sorted)
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
pub fn manifests_to_yaml(manifests: &[serde_json::Value]) -> Result<String, serde_yml::Error> {
    let mut output = String::new();
    for (i, manifest) in manifests.iter().enumerate() {
        let mut cleaned = manifest.clone();
        strip_nulls(&mut cleaned);
        if i > 0 {
            output.push_str("---\n");
        }
        output.push_str(&to_sorted_yaml(&cleaned)?);
    }
    Ok(output)
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
        let mut value: serde_json::Value = serde_yml::from_str(&contents)?;
        // A snapshot is a dump of live objects, so one taken before the
        // domain move carries the retired keys. Without this, diffing it
        // against a build made now shows every Kix annotation as a paired
        // add and remove, and both of Kix's own CRDs as one addition plus
        // one deletion, on a cluster that is in sync.
        crate::legacy_domain::upgrade_manifest(&mut value);

        // Prefer the manifest's own identity over the filename's.
        //
        // The other side of every diff that uses this is keyed by
        // `ResourceId::from_value`, so the two must be derived the same way
        // or nothing matches. A filename carries the kind lowercased, which
        // alone means no id from a nested dump ever equals one from a build.
        // The upgrade above makes it worse: it can rename Kix's own CRDs,
        // and the filename would then still hold the name they had before.
        // The filename stays as the fallback, for a file whose content does
        // not say what it is.
        let rid = if value.pointer("/kind").and_then(|v| v.as_str()).is_some()
            && value
                .pointer("/metadata/name")
                .and_then(|v| v.as_str())
                .is_some()
        {
            ResourceId::from_value(&value)
        } else {
            rid
        };
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
        let yaml = to_sorted_yaml(&cleaned)
            .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { Box::new(e) })?;
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
    fn manifests_to_yaml_single_doc() {
        let manifests = vec![json!({
            "kind": "Service",
            "apiVersion": "v1",
            "metadata": { "name": "my-svc" }
        })];
        let yaml = manifests_to_yaml(&manifests).unwrap();
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
        let yaml = manifests_to_yaml(&manifests).unwrap();
        assert!(
            yaml.contains("---\n"),
            "documents should be separated by ---"
        );
        assert!(yaml.contains("kind: Service"));
        assert!(yaml.contains("kind: Deployment"));
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
        // From the manifest, not the filename. The filename spells the kind
        // lowercased, and everything these ids are compared against is keyed
        // by `ResourceId::from_value`, so taking the filename's spelling
        // meant a snapshot never matched a build.
        assert_eq!(results[0].0.kind, "Service");
        assert_eq!(results[0].1["kind"], "Service");
    }

    /// A file whose content does not say what it is still gets an id, from
    /// its name.
    #[test]
    fn load_falls_back_to_the_filename_when_the_manifest_is_headless() {
        let dir = TempDir::new().unwrap();
        let yaml = serde_yml::to_string(&json!({"data": {"a": "b"}})).unwrap();
        fs::write(dir.path().join("default--my-svc-service.yaml"), &yaml).unwrap();

        let results = load_manifests_from_dir(dir.path()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].0.kind, "service");
        assert_eq!(results[0].0.name, "my-svc");
    }
}
