//! Runtime content drift checks.
//!
//! For every kix-managed live object: project it onto kix's current SSA
//! fieldset, hash, and compare against the `kix.run/applied-hash` stamp
//! written from the SSA response echo at apply time. Match ⇒ every field kix
//! applied is byte-identical to what the server committed. Mismatch ⇒
//! attribute via `managedFields`: the apiserver records field-precisely who
//! took what, when.
//!
//! Cluster-only: no nix build, no store, any kubeconfig context.

use kube::{
    api::DynamicObject,
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;

use super::activation::Tenancy;
use super::fetch::{self, FetchError};
use super::fieldsv1::{self, KIX_FIELD_MANAGER};
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

/// Per-resource drift verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftVerdict {
    /// Every field kix applied is byte-identical to the state committed at
    /// apply time.
    InSync,
    /// The kix-owned projection no longer hashes to the stamp. Content
    /// changed under kix's ownership or ownership was taken by another
    /// manager. `foreign` attributes the co-owners.
    Drifted { foreign: Vec<ForeignOwner> },
    /// No `kix.run/applied-hash` annotation: the resource predates stamping
    /// or the stamp patch was lost. This is restamped on the next deploy.
    Unstamped,
    /// `managedFields` missing or stripped (backup/restore tools, etcd
    /// surgery); the check cannot run for this object.
    NoFieldset,
}

/// A non-kix field manager owning parts of the object, flattened from its
/// `managedFields` entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignOwner {
    pub manager: String,
    pub operation: String,
    /// Subresource the write went through (e.g. "scale"). Status writes are
    /// excluded before this is ever constructed.
    pub subresource: Option<String>,
    /// RFC 3339 timestamp of the entry's last write, as reported by the server.
    pub time: Option<String>,
    /// Field paths the manager owns, e.g.
    /// `spec.template.spec.containers[name=web].image`.
    pub paths: Vec<String>,
}

/// Drift report for a single resource.
#[derive(Debug, Clone)]
pub struct DriftReport {
    pub rid: ResourceId,
    pub verdict: DriftVerdict,
    /// The Kix clusters whose Activation records name the object, sorted.
    /// Empty when it names no record on the cluster.
    pub clusters: Vec<String>,
}

/// Check kix-managed resources on the cluster: every one when `cluster` is
/// `None`, otherwise the ones [`fetch::SweepScope::Cluster`] gives for it.
/// Also returns the sweep's [`Tenancy`], which names each report's clusters.
///
/// Fetches through [`fetch::sweep_managed`] and hashes raw objects.
/// `fetch::normalize_for_diff` cannot be used because it removes managedFields.
pub async fn check_cluster(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    cluster: Option<&str>,
) -> Result<(Vec<DriftReport>, Tenancy), FetchError> {
    let scope = match cluster {
        Some(cluster) => fetch::SweepScope::Cluster(cluster),
        None => fetch::SweepScope::All,
    };
    let sweep = fetch::sweep_managed(client, discovery, scope).await?;
    let mut reports: Vec<DriftReport> = sweep
        .managed
        .iter()
        .map(|obj| DriftReport {
            clusters: sweep.tenancy.owners_of(obj),
            ..check_object(obj)
        })
        .collect();
    reports.sort_by(|a, b| a.rid.cmp(&b.rid));
    Ok((reports, sweep.tenancy))
}

/// Run the drift check on one live object. `clusters` is left empty;
/// [`check_cluster`] fills it.
pub fn check_object(obj: &DynamicObject) -> DriftReport {
    let rid = resource_id(obj);

    let stamped = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::APPLIED_HASH))
        .map(str::to_string);

    let Some(stamped) = stamped else {
        return DriftReport {
            rid,
            verdict: DriftVerdict::Unstamped,
            clusters: Vec::new(),
        };
    };

    // Same recipe as the stamp side: project onto kix's current fieldset,
    // strip kix.run self-references, hash canonical JSON.
    // TODO: exclude PI spec.driftIgnore pointers here, resolved through
    // kix.run/package annotations and a PackageInstance GET, so compiled
    // delegation (HPA on replicas, cert-manager on Secret data) is an
    // expected co-owner, not drift.
    let Some(current) = fieldsv1::applied_content_hash(obj) else {
        return DriftReport {
            rid,
            verdict: DriftVerdict::NoFieldset,
            clusters: Vec::new(),
        };
    };

    if current == stamped {
        DriftReport {
            rid,
            verdict: DriftVerdict::InSync,
            clusters: Vec::new(),
        }
    } else {
        DriftReport {
            rid,
            verdict: DriftVerdict::Drifted {
                foreign: foreign_owners(obj),
            },
            clusters: Vec::new(),
        }
    }
}

/// Attribute co-ownership: flatten every OTHER manager's fieldsV1 into field
/// paths with manager name, operation, subresource, and timestamp.
///
/// Excludes entries with subresource == "status" because status writes are
/// controller noise, never drift. Other subresources stay visible on purpose:
/// autoscalers and `kubectl scale` write through the "/scale" subresource,
/// which the check must attribute as scaling drift.
pub fn foreign_owners(obj: &DynamicObject) -> Vec<ForeignOwner> {
    let Some(entries) = obj.metadata.managed_fields.as_deref() else {
        return Vec::new();
    };
    entries
        .iter()
        .filter(|e| e.manager.as_deref() != Some(KIX_FIELD_MANAGER))
        .filter(|e| e.subresource.as_deref() != Some("status"))
        .map(|e| ForeignOwner {
            manager: e.manager.clone().unwrap_or_else(|| "unknown".to_string()),
            operation: e.operation.clone().unwrap_or_else(|| "?".to_string()),
            subresource: e.subresource.clone(),
            time: e.time.as_ref().map(|t| t.0.to_rfc3339()),
            paths: e
                .fields_v1
                .as_ref()
                .map(|f| flatten_paths(&f.0))
                .unwrap_or_default(),
        })
        .collect()
}

/// Flatten a fieldsV1 tree into human-readable field paths:
/// `f:` segments join with `.`, keyed elements render as `[name=web]`,
/// set values as `[v=<json>]`, positions as `[2]`. Only leaves are emitted;
/// a node owning just `.` (element existence) is a leaf too.
pub fn flatten_paths(fields: &Value) -> Vec<String> {
    let mut out = Vec::new();
    walk_paths(fields, String::new(), &mut out);
    out
}

fn walk_paths(fields: &Value, prefix: String, out: &mut Vec<String>) {
    let Some(map) = fields.as_object() else {
        return;
    };

    let mut has_children = false;
    for (key, subtree) in map {
        let segment = if let Some(name) = key.strip_prefix("f:") {
            if prefix.is_empty() {
                name.to_string()
            } else {
                format!(".{name}")
            }
        } else if let Some(key_json) = key.strip_prefix("k:") {
            format!("[{}]", format_list_key(key_json))
        } else if let Some(val_json) = key.strip_prefix("v:") {
            format!("[v={val_json}]")
        } else if let Some(idx) = key.strip_prefix("i:") {
            format!("[{idx}]")
        } else {
            // "." marks the node itself rather than a child.
            continue;
        };
        has_children = true;
        walk_paths(subtree, format!("{prefix}{segment}"), out);
    }

    if !has_children && !prefix.is_empty() {
        out.push(prefix);
    }
}

/// Render a `k:{...}` associative-list key as `name=web` (comma-joined for
/// multi-key lists). Falls back to the raw JSON on parse failure.
fn format_list_key(key_json: &str) -> String {
    match serde_json::from_str::<Value>(key_json) {
        Ok(Value::Object(keys)) => keys
            .iter()
            .map(|(k, v)| match v {
                Value::String(s) => format!("{k}={s}"),
                other => format!("{k}={other}"),
            })
            .collect::<Vec<_>>()
            .join(","),
        _ => key_json.to_string(),
    }
}

/// Build a `ResourceId` from typed metadata + the kind that
/// `fetch_managed_resources` injects into raw data.
fn resource_id(obj: &DynamicObject) -> ResourceId {
    let kind = obj
        .data
        .get("kind")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("Unknown")
        .to_string();
    ResourceId {
        kind,
        namespace: obj
            .metadata
            .namespace
            .clone()
            .unwrap_or_else(|| crate::manifest::types::CLUSTER_SCOPED.to_string()),
        name: obj.metadata.name.clone().unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn flatten_nested_paths() {
        let fields = json!({
            "f:spec": {
                "f:template": {
                    "f:spec": {
                        "f:containers": {
                            "k:{\"name\":\"web\"}": {
                                ".": {},
                                "f:image": {},
                                "f:env": {
                                    "k:{\"name\":\"FOO\"}": {".": {}, "f:name": {}, "f:value": {}}
                                }
                            }
                        }
                    }
                }
            }
        });
        let paths = flatten_paths(&fields);
        assert!(paths.contains(&"spec.template.spec.containers[name=web].image".to_string()));
        assert!(
            paths.contains(
                &"spec.template.spec.containers[name=web].env[name=FOO].name".to_string()
            )
        );
        // "." under [name=web] is not a leaf because f:image etc. exist.
        assert!(!paths.contains(&"spec.template.spec.containers[name=web]".to_string()));
    }

    #[test]
    fn flatten_dot_only_element_is_leaf() {
        let fields = json!({
            "f:spec": {"f:containers": {"k:{\"name\":\"web\"}": {".": {}}}}
        });
        assert_eq!(
            flatten_paths(&fields),
            vec!["spec.containers[name=web]".to_string()]
        );
    }

    #[test]
    fn flatten_scale_style_replicas() {
        // What a `kubectl scale` / HPA write through /scale looks like.
        let fields = json!({"f:spec": {"f:replicas": {}}});
        assert_eq!(flatten_paths(&fields), vec!["spec.replicas".to_string()]);
    }
}
