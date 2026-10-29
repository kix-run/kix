//! Runtime content drift checks.
//!
//! For each Kix-managed live object, project it onto Kix's current server-side
//! apply fieldset, hash the projection, and compare it against the
//! `kix.run/applied-hash` annotation written from the SSA response at apply
//! time. When they match, every field Kix applied is identical to what the
//! server committed. When they differ, `managedFields` attributes which manager
//! modified each field and when.
//!
//! This check queries only the cluster and does not require a Nix build or
//! store.

use kube::{
    api::DynamicObject,
    client::Client,
    discovery::{ApiResource, Scope},
};
use serde_json::Value;

use super::activation::OpenedRecords;
use super::errors::FetchError;
use super::fieldsv1::{self, KIX_FIELD_MANAGER};
use super::inventory;
use super::tenancy::Tenancy;
use crate::manifest::keys;
use crate::manifest::types::ResourceId;

/// Per-resource drift verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftVerdict {
    /// Every field Kix applied is byte-identical to the state committed at
    /// apply time.
    InSync,
    /// The Kix-owned projection no longer hashes to the stamp because content
    /// changed under Kix's ownership or another manager took ownership.
    /// `foreign` lists the other managers' recorded fields, and
    /// `unrecorded_scale` is set when the change is a replicas write that
    /// Kubernetes recorded no owner for.
    Drifted {
        foreign: Vec<ForeignOwner>,
        unrecorded_scale: Option<UnrecordedScale>,
    },
    /// The resource has no `kix.run/applied-hash` annotation and will be
    /// stamped on the next deploy.
    Unstamped,
    /// `managedFields` is missing or has no Kix entry, so the drift check
    /// cannot run for this object.
    NoFieldset,
}

/// A non-Kix field manager owning parts of the object, flattened from its
/// `managedFields` entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignOwner {
    pub manager: String,
    pub operation: String,
    /// Subresource the write went through (e.g. "scale"). Status writes are
    /// excluded before this is ever constructed.
    pub subresource: Option<String>,
    /// RFC 3339 timestamp of the entry's last write, as reported by the
    /// server. `None` for a `/scale` entry because the API server copies the
    /// scale writer's fields onto the parent object without a timestamp.
    pub time: Option<String>,
    /// Field paths the manager owns, e.g.
    /// `spec.template.spec.containers[name=web].image`.
    pub paths: Vec<String>,
}

/// A replicas change Kix can prove although no managedFields entry records
/// it.
///
/// A write through the `/scale` subresource leaves `spec.replicas` with no
/// owner in two cases: it sets 0, which the Scale object omits so the write
/// counts as a removal, or no manager owned `spec.replicas` before it, which
/// makes the apiserver skip tracking for the write. Either way Kix's `Apply`
/// entry loses the field and no other entry gains it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnrecordedScale {
    /// Field path, always `spec.replicas`.
    pub path: String,
    /// The value Kix applied, recovered from the `kix.run/applied-hash`
    /// stamp.
    pub deployed: i64,
    /// The value on the live object.
    pub live: i64,
}

/// Kinds whose `/scale` subresource writes `spec.replicas`, by API group and
/// kind. A custom resource's scale subresource names its replicas path in its
/// CRD, which this check does not read.
const SCALE_KINDS: &[(&str, &str)] = &[
    ("apps", "Deployment"),
    ("apps", "ReplicaSet"),
    ("apps", "StatefulSet"),
    ("", "ReplicationController"),
];

/// Highest deployed replicas value [`unrecorded_scale`] tries. Because the
/// stamp is a hash, recovering the deployed value requires hashing each
/// candidate up to this bound.
const SCALE_SEARCH_LIMIT: i64 = 1024;

/// Drift report for a single resource.
#[derive(Debug, Clone)]
pub struct DriftReport {
    pub rid: ResourceId,
    pub verdict: DriftVerdict,
    /// The Kix clusters whose Activation records name the object, sorted.
    /// Empty when it names no record on the cluster.
    pub clusters: Vec<String>,
}

/// Check Kix-managed resources on the cluster. Checks all managed resources
/// when `cluster` is `None`, or only those in [`inventory::SweepScope::Cluster`]
/// when `Some`. Also returns the sweep's [`Tenancy`].
///
/// Fetches raw objects through [`inventory::sweep_managed`] so `managedFields`
/// remains intact.
pub async fn check_cluster(
    client: &Client,
    discovery: &[(ApiResource, Scope)],
    records: &OpenedRecords,
    cluster: Option<&str>,
) -> Result<(Vec<DriftReport>, Tenancy), FetchError> {
    let scope = match cluster {
        Some(cluster) => inventory::SweepScope::Cluster(cluster),
        None => inventory::SweepScope::All,
    };
    let sweep = inventory::sweep_managed(client, discovery, records, scope).await?;
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

/// Run the drift check on one live object. `clusters` is left empty and
/// populated by [`check_cluster`].
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

    // Project onto Kix's current fieldset, strip `kix.run/*` annotations, and
    // hash canonical JSON.
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
                unrecorded_scale: unrecorded_scale(obj, &stamped),
            },
            clusters: Vec::new(),
        }
    }
}

/// Detect a replicas change that no managedFields entry records (see
/// [`UnrecordedScale`]).
///
/// Applies to the kinds in [`SCALE_KINDS`] whose live `spec.replicas` no
/// entry owns. Puts `spec.replicas` back into Kix's projection with each value
/// from 0 to [`SCALE_SEARCH_LIMIT`] and returns the value whose hash equals
/// `stamped`. A match proves Kix applied that value and that `spec.replicas`
/// is the only field Kix owned that changed. Returns `None` when nothing
/// matches, which includes a replicas change combined with any other change
/// to Kix's fields.
fn unrecorded_scale(obj: &DynamicObject, stamped: &str) -> Option<UnrecordedScale> {
    if !serves_scale(obj) {
        return None;
    }
    let live = obj.data.pointer("/spec/replicas")?.as_i64()?;
    let entries = obj.metadata.managed_fields.as_deref()?;
    let owned = entries.iter().any(|e| {
        e.fields_v1
            .as_ref()
            .is_some_and(|f| f.0.pointer("/f:spec/f:replicas").is_some())
    });
    if owned {
        return None;
    }

    let mut projection = fieldsv1::kix_owned_projection(obj)?;
    // Indexing `projection["spec"]` below panics unless it is an object.
    projection.get("spec")?.as_object()?;
    let deployed = (0..=SCALE_SEARCH_LIMIT).find(|&candidate| {
        projection["spec"]["replicas"] = Value::from(candidate);
        fieldsv1::projection_hash(projection.clone()) == stamped
    })?;
    Some(UnrecordedScale {
        path: "spec.replicas".to_string(),
        deployed,
        live,
    })
}

fn serves_scale(obj: &DynamicObject) -> bool {
    let api_version = obj
        .data
        .get("apiVersion")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.api_version.as_str()))
        .unwrap_or_default();
    let group = api_version.rsplit_once('/').map_or("", |(group, _)| group);
    let kind = resource_id_kind(obj);
    SCALE_KINDS.contains(&(group, kind))
}

/// Extract non-Kix field managers from `managedFields` with their operation,
/// subresource, timestamp, and flattened field paths.
///
/// Excludes entries with `subresource == "status"` because status writes are
/// controller updates rather than configuration drift. Other subresources stay
/// in the list, so a `/scale` write that Kubernetes records appears here under
/// subresource `scale` owning `spec.replicas` with no timestamp. Kubernetes
/// records a `/scale` entry only when the write sets a non-zero value and a
/// manager already owned `spec.replicas`. [`UnrecordedScale`] covers the other
/// cases.
pub(crate) fn foreign_owners(obj: &DynamicObject) -> Vec<ForeignOwner> {
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

/// Flatten a fieldsV1 tree into human-readable field paths.
///
/// `f:` segments join with `.`, keyed elements render as `[name=web]`, set
/// values as `[v=<json>]`, and positions as `[2]`. Only leaves are emitted, and
/// a node owning only `.` (element existence) is also treated as a leaf.
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
    ResourceId {
        kind: resource_id_kind(obj).to_string(),
        namespace: obj
            .metadata
            .namespace
            .clone()
            .unwrap_or_else(|| crate::manifest::types::CLUSTER_SCOPED.to_string()),
        name: obj.metadata.name.clone().unwrap_or_default(),
    }
}

fn resource_id_kind(obj: &DynamicObject) -> &str {
    obj.data
        .get("kind")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("Unknown")
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
