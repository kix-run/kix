//! Runtime content drift checks.
//!
//! For each Kix-managed live object, project it onto Kix's current server-side
//! apply fieldset, hash the projection, and compare it against the applied
//! hash computed from the SSA response at apply time. A revision's
//! `status.applied` holds that hash, and an object an earlier Kix applied
//! holds it in its `kix.run/applied-hash` annotation. When they match, every field Kix applied is identical to what the
//! server committed. When they differ, `managedFields` attributes which manager
//! modified each field and when.
//!
//! This check reads only the live object and does not require a Nix build.
//! `kix status` runs it on every object through [`super::observe`].

use kube::api::DynamicObject;
use serde_json::Value;

use super::apply;
use super::field_manager::{FieldManager, Whose};
use super::fieldsv1;
use crate::manifest::sent;
use crate::manifest::types::ResourceId;

/// Per-resource drift verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriftVerdict {
    /// Every field Kix applied is byte-identical to the state committed at
    /// apply time.
    InSync,
    /// The Kix-owned projection no longer hashes to the applied hash, because
    /// content changed under Kix's ownership or another manager took
    /// ownership.
    /// `foreign` lists the other managers' recorded fields, and
    /// `unrecorded_scale` is set when the change is a replicas write that
    /// Kubernetes recorded no owner for.
    Drifted {
        foreign: Vec<ForeignOwner>,
        unrecorded_scale: Option<UnrecordedScale>,
    },
    /// Kix does not know the object's applied hash: no revision records it,
    /// and the object has no `kix.run/applied-hash` annotation.
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
    /// The paths in `paths` that Kix's `Apply` entry does not also own.
    ///
    /// Only these can stop a deploy on a field ownership conflict. A field
    /// Kix also owns holds the value Kix applied, because the API server
    /// moves ownership to whoever changes a value, so applying it again
    /// changes nothing.
    pub unshared_paths: Vec<String>,
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
    /// The value Kix applied, recovered from the applied hash.
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
/// applied hash is a hash, recovering the deployed value requires hashing each
/// candidate up to this bound.
const SCALE_SEARCH_LIMIT: i64 = 1024;

/// Drift report for a single resource.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriftReport {
    pub rid: ResourceId,
    pub verdict: DriftVerdict,
}

/// Run the drift check on the live object `obj`, whose applied hash is
/// `applied`, against the fields `manager`'s Kix cluster applied. Another
/// Kix cluster's manager is another manager here. Take `applied` from [`AppliedHashes::applied`], which reads
/// the revisions of a record that names its revisions and the annotation
/// otherwise. `None` means the applied hash is not known.
///
/// [`AppliedHashes::applied`]: super::revision::AppliedHashes::applied
pub fn check_object(
    obj: &DynamicObject,
    applied: Option<&str>,
    manager: &FieldManager,
) -> DriftReport {
    let rid = resource_id(obj);

    let Some(stamped) = applied else {
        return DriftReport {
            rid,
            verdict: DriftVerdict::Unstamped,
        };
    };

    // Project onto Kix's current fieldset without the ceded fields, strip
    // `kix.run/*` annotations, and hash canonical JSON.
    let Some(current) = fieldsv1::applied_content_hash(obj, manager) else {
        return DriftReport {
            rid,
            verdict: DriftVerdict::NoFieldset,
        };
    };

    if current == stamped {
        DriftReport {
            rid,
            verdict: DriftVerdict::InSync,
        }
    } else {
        DriftReport {
            rid,
            verdict: DriftVerdict::Drifted {
                foreign: foreign_owners(obj, manager),
                unrecorded_scale: unrecorded_scale(obj, stamped, manager),
            },
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
fn unrecorded_scale(
    obj: &DynamicObject,
    stamped: &str,
    manager: &FieldManager,
) -> Option<UnrecordedScale> {
    // A ceded replicas count is out of the applied hash, so its change is
    // not drift.
    if !serves_scale(obj) || is_ceded(&ceded_of(obj), &["f:spec".into(), "f:replicas".into()]) {
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

    let mut projection = fieldsv1::hashed_projection(obj, manager)?;
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

/// Extract the field managers whose fields do not count as `manager`'s
/// ([`FieldManager::counts_as_own`]) from `managedFields`, with their
/// operation, subresource, timestamp, and flattened field paths. Another Kix
/// cluster's manager is among them.
///
/// Excludes entries with `subresource == "status"` because status writes are
/// controller updates rather than configuration drift. Other subresources stay
/// in the list, so a `/scale` write that Kubernetes records appears here under
/// subresource `scale` owning `spec.replicas` with no timestamp. Kubernetes
/// records a `/scale` entry only when the write sets a non-zero value and a
/// manager already owned `spec.replicas`. [`UnrecordedScale`] covers the other
/// cases.
///
/// A field the object cedes (`kix.run/cede-fields`) is left out: another
/// manager is meant to own it.
pub(crate) fn foreign_owners(obj: &DynamicObject, manager: &FieldManager) -> Vec<ForeignOwner> {
    let kix_owned = kix_owned_leaves(obj, manager);
    let ceded = ceded_of(obj);
    let Some(entries) = obj.metadata.managed_fields.as_deref() else {
        return Vec::new();
    };
    entries
        .iter()
        .filter(|e| !manager.counts_as_own(e.manager.as_deref()))
        .filter(|e| e.subresource.as_deref() != Some("status"))
        .map(|e| {
            let leaves: Vec<(String, Vec<String>)> = e
                .fields_v1
                .as_ref()
                .map(|f| leaves(&f.0))
                .unwrap_or_default()
                .into_iter()
                .filter(|(_, keys)| !is_ceded(&ceded, keys))
                .collect();
            let unshared_paths = leaves
                .iter()
                .filter(|(_, keys)| !kix_owned.contains(keys))
                .map(|(path, _)| path.clone())
                .collect();
            ForeignOwner {
                manager: e.manager.clone().unwrap_or_else(|| "unknown".to_string()),
                operation: e.operation.clone().unwrap_or_else(|| "?".to_string()),
                subresource: e.subresource.clone(),
                time: e
                    .time
                    .as_ref()
                    .and_then(crate::cluster::chrono_time)
                    .map(|t| t.to_rfc3339()),
                paths: leaves.into_iter().map(|(path, _)| path).collect(),
                unshared_paths,
            }
        })
        .collect()
}

/// Return the fieldsV1 key chain of each leaf that `manager`'s `Apply` entry
/// owns.
fn kix_owned_leaves(
    obj: &DynamicObject,
    manager: &FieldManager,
) -> std::collections::HashSet<Vec<String>> {
    fieldsv1::kix_fieldset(obj, manager)
        .map(|f| leaves(&f).into_iter().map(|(_, keys)| keys).collect())
        .unwrap_or_default()
}

/// Flatten a fieldsV1 tree into human-readable field paths.
///
/// `f:` segments join with `.`, keyed elements render as `[name=web]`, set
/// values as `[v=<json>]`, and positions as `[2]`. Only leaves are emitted, and
/// a node owning only `.` (element existence) is also treated as a leaf.
pub fn flatten_paths(fields: &Value) -> Vec<String> {
    leaves(fields).into_iter().map(|(path, _)| path).collect()
}

/// Return each leaf of a fieldsV1 tree as its [`flatten_paths`] path and its
/// chain of fieldsV1 keys from the root.
fn leaves(fields: &Value) -> Vec<(String, Vec<String>)> {
    let mut out = Vec::new();
    walk_paths(fields, String::new(), &mut Vec::new(), &mut out);
    out
}

fn walk_paths(
    fields: &Value,
    prefix: String,
    chain: &mut Vec<String>,
    out: &mut Vec<(String, Vec<String>)>,
) {
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
        chain.push(key.clone());
        walk_paths(subtree, format!("{prefix}{segment}"), chain, out);
        chain.pop();
    }

    if !has_children && !prefix.is_empty() {
        out.push((prefix, chain.clone()));
    }
}

/// A field that a manager other than Kix owns on a live object and Kix's
/// `Apply` entry no longer owns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForeignField {
    pub manager: String,
    /// The field path in [`flatten_paths`] form.
    pub path: String,
    keys: Vec<String>,
}

impl ForeignField {
    /// Return the value of this field in `manifest`, matching list elements
    /// the way the API server does.
    pub fn value_in<'v>(&self, manifest: &'v Value) -> Option<&'v Value> {
        self.walk(manifest).map(|(value, _)| value)
    }

    /// Return this field's path in `manifest` as the diff engine spells it
    /// (`$.spec.containers[web].image`), so it reads like the field changes
    /// beside it. A list element is named by its diff-engine key, then its
    /// `name`, then its position.
    pub fn diff_path(&self, manifest: &Value) -> Option<String> {
        self.walk(manifest).map(|(_, path)| path)
    }

    fn walk<'v>(&self, manifest: &'v Value) -> Option<(&'v Value, String)> {
        let mut node = manifest;
        let mut path = "$".to_string();
        let mut field = "";
        for key in &self.keys {
            match key.strip_prefix("f:") {
                Some(name) => {
                    node = node.get(name)?;
                    path.push('.');
                    path.push_str(name);
                    field = name;
                }
                None => {
                    let single = serde_json::Map::from_iter([(key.clone(), Value::Null)]);
                    let (i, elem) = node
                        .as_array()?
                        .iter()
                        .enumerate()
                        .find(|(i, e)| fieldsv1::match_element(e, *i, &single).is_some())?;
                    let name = crate::manifest::diff::keyed_lists::extract_key(field, elem)
                        .or_else(|| elem.get("name").and_then(Value::as_str).map(str::to_string))
                        .unwrap_or_else(|| i.to_string());
                    path.push_str(&format!("[{name}]"));
                    node = elem;
                }
            }
        }
        Some((node, path))
    }
}

/// Return the fields of `obj` that a manager other than Kix owns, leaving out
/// status writes, fields Kix's `Apply` entry still owns, and fields the
/// object cedes.
///
/// A field Kix still owns holds the value Kix applied, because the API server
/// moves ownership to whoever changes a value. So the fields returned are the
/// ones another manager changed or took over since Kix applied the object.
pub fn foreign_fields(obj: &DynamicObject, manager: &FieldManager) -> Vec<ForeignField> {
    let ceded = ceded_of(obj);
    taken_fields(obj, manager)
        .into_iter()
        .filter(|f| !is_ceded(&ceded, &f.keys))
        .collect()
}

/// One field a forced apply takes from another field manager, as the API
/// server named it in its answer to the same apply sent without force
/// ([`super::apply::takes_back`]): who holds it, and its value on the object
/// Kix read.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct TakenField {
    pub manager: String,
    /// The field path as the API server writes it, such as
    /// `.spec.ports[port=80,protocol="TCP"].targetPort`.
    pub path: String,
    /// The live value, as JSON text.
    pub live: String,
}

/// Return whether applying the built manifest `manifest` without force
/// would be refused with a conflict on `obj`: the manifest Kix sends
/// ([`sent::of`]) sets a field that another manager took from Kix, and the
/// object does not cede that field.
pub(crate) fn conflicts(obj: &DynamicObject, manifest: &Value, manager: &FieldManager) -> bool {
    let manifest = sent::of(manifest);
    foreign_fields(obj, manager)
        .iter()
        .any(|f| f.value_in(&manifest).is_some())
}

/// Return the field managers of other Kix clusters, sorted, that own a
/// field of `obj` that the manifest Kix sends for the built manifest
/// `manifest` ([`sent::of`]) sets and the object does not cede: the
/// fields another Kix cluster applied with other values than `manager`'s
/// Kix cluster did. Another Kix cluster's manager is named by the cluster's
/// name. The legacy manager `kix` counts too when `manager` does not count
/// it as its own, because an older Kix may apply under it for another Kix
/// cluster.
pub(crate) fn held_by_other_clusters(
    obj: &DynamicObject,
    manifest: &Value,
    manager: &FieldManager,
) -> Vec<String> {
    let manifest = sent::of(manifest);
    let mut clusters: Vec<String> = foreign_fields(obj, manager)
        .into_iter()
        .filter(|f| f.value_in(&manifest).is_some())
        .filter_map(|f| match manager.whose(&f.manager) {
            Whose::OtherCluster(cluster) => Some(cluster.to_string()),
            Whose::Legacy => Some(f.manager.clone()),
            Whose::This | Whose::NotKix => None,
        })
        .collect();
    clusters.sort();
    clusters.dedup();
    clusters
}

/// Return `manifest` without each field it cedes that another manager owns
/// on `obj` and Kix's `Apply` entry does not. A forced apply of the result
/// leaves those fields to their manager, as an apply that is refused on them
/// and sent again without them does. A Secret's ceded `data` key goes from
/// `stringData` too, which Kix sends as `data`.
pub(crate) fn without_ceded_taken(
    manifest: &Value,
    obj: &DynamicObject,
    manager: &FieldManager,
) -> Value {
    let ceded = apply::ceded_fields(manifest);
    let mut out = manifest.clone();
    if ceded.is_empty() {
        return out;
    }
    let secret = crate::manifest::types::is_secret(manifest);
    for field in taken_fields(obj, manager) {
        let Some(path) = segs(&field.keys) else {
            continue;
        };
        if !ceded.iter().any(|c| apply::covers(c, &path)) {
            continue;
        }
        apply::remove_path(&mut out, &path);
        if secret && path.first() == Some(&apply::Seg::Field("data".into())) {
            let mut in_strings = path.clone();
            in_strings[0] = apply::Seg::Field("stringData".into());
            apply::remove_path(&mut out, &in_strings);
        }
    }
    out
}

/// Return whether each field `manifest` cedes that `manager`'s own `Apply`
/// entry owns on `obj` holds the value Kix sends for it
/// ([`apply::forced_manifest`]).
///
/// The applied hash leaves ceded fields out, so that another manager can
/// change them without the object reading as drifted. While Kix's own
/// entry still owns a ceded field, nobody else changed it, and Kix sends
/// it. A value that differs from the build's was written by another
/// deploy of this Kix cluster, and an apply changes it.
pub(crate) fn owned_ceded_fields_match(
    manifest: &Value,
    obj: &DynamicObject,
    manager: &FieldManager,
) -> bool {
    let ceded = apply::ceded_fields(manifest);
    if ceded.is_empty() {
        return true;
    }
    let Some(fields) = fieldsv1::kix_fieldset(obj, manager) else {
        return true;
    };
    let live = fieldsv1::project(&fieldsv1::merge_typed_metadata(obj), &fields);
    let sent = fieldsv1::project(&apply::forced_manifest(manifest, obj, manager), &fields);
    ceded
        .iter()
        .all(|c| apply::covered_part(&live, c) == apply::covered_part(&sent, c))
}

/// Return the manifest Kix sends for `manifest` ([`sent::of`]) without each
/// field another manager took from Kix on `obj`, ceded or not. An apply of
/// the result without force is not refused on those fields, and leaves them
/// to the manager that holds them.
pub(crate) fn without_taken(
    manifest: &Value,
    obj: &DynamicObject,
    manager: &FieldManager,
) -> Value {
    let mut out = sent::of(manifest).into_owned();
    let secret = crate::manifest::types::is_secret(manifest);
    for field in taken_fields(obj, manager) {
        let Some(path) = segs(&field.keys) else {
            continue;
        };
        apply::remove_path(&mut out, &path);
        if secret && path.first() == Some(&apply::Seg::Field("data".into())) {
            let mut in_strings = path.clone();
            in_strings[0] = apply::Seg::Field("stringData".into());
            apply::remove_path(&mut out, &in_strings);
        }
    }
    out
}

/// Return the fields of `obj` that a manager other than Kix owns and Kix's
/// `Apply` entry does not, leaving out status writes.
fn taken_fields(obj: &DynamicObject, manager: &FieldManager) -> Vec<ForeignField> {
    let kix_owned = kix_owned_leaves(obj, manager);
    let Some(entries) = obj.metadata.managed_fields.as_deref() else {
        return Vec::new();
    };
    entries
        .iter()
        .filter(|e| !manager.counts_as_own(e.manager.as_deref()))
        .filter(|e| e.subresource.as_deref() != Some("status"))
        .flat_map(|e| {
            let manager = e.manager.clone().unwrap_or_else(|| "unknown".to_string());
            e.fields_v1
                .as_ref()
                .map(|f| leaves(&f.0))
                .unwrap_or_default()
                .into_iter()
                .filter(|(_, keys)| !kix_owned.contains(keys))
                .map(move |(path, keys)| ForeignField {
                    manager: manager.clone(),
                    path,
                    keys,
                })
        })
        .collect()
}

/// Return the field paths `obj` cedes in its `kix.run/cede-fields`
/// annotation.
fn ceded_of(obj: &DynamicObject) -> Vec<Vec<apply::Seg>> {
    let Some(declared) = obj
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(crate::manifest::keys::CEDE_FIELDS))
    else {
        return Vec::new();
    };
    apply::ceded_fields(&serde_json::json!({
        "metadata": { "annotations": { (crate::manifest::keys::CEDE_FIELDS): declared } }
    }))
}

/// Return whether one of `ceded` covers the field whose fieldsV1 key chain
/// is `keys`.
fn is_ceded(ceded: &[Vec<apply::Seg>], keys: &[String]) -> bool {
    !ceded.is_empty()
        && segs(keys).is_some_and(|path| ceded.iter().any(|c| apply::covers(c, &path)))
}

/// Convert a fieldsV1 key chain to the segments of a field path. A set
/// element (`v:`) has no such segment, so its chain gives `None`.
fn segs(keys: &[String]) -> Option<Vec<apply::Seg>> {
    keys.iter()
        .map(|key| {
            if let Some(name) = key.strip_prefix("f:") {
                Some(apply::Seg::Field(name.to_string()))
            } else if let Some(json) = key.strip_prefix("k:") {
                match serde_json::from_str::<Value>(json).ok()? {
                    Value::Object(keys) => Some(apply::Seg::Key(keys.into_iter().collect())),
                    _ => None,
                }
            } else if let Some(i) = key.strip_prefix("i:") {
                i.parse().ok().map(apply::Seg::Index)
            } else {
                None
            }
        })
        .collect()
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

/// Build a `ResourceId` from typed metadata + the kind and apiVersion that
/// `fetch_managed_resources` injects into raw data.
pub fn resource_id(obj: &DynamicObject) -> ResourceId {
    let api_version = obj
        .data
        .get("apiVersion")
        .and_then(Value::as_str)
        .or_else(|| obj.types.as_ref().map(|t| t.api_version.as_str()))
        .unwrap_or("");
    ResourceId {
        group: crate::manifest::types::api_group(api_version).to_string(),
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

    /// A manager's fields that Kix also owns are shared, so only the others
    /// can conflict with a deploy.
    #[test]
    fn foreign_owners_mark_the_fields_kix_does_not_share() {
        let entry = |manager: &str, operation: &str, fields: Value| {
            json!({
                "manager": manager,
                "operation": operation,
                "fieldsType": "FieldsV1",
                "fieldsV1": fields,
            })
        };
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "coredns",
                "namespace": "kube-system",
                "managedFields": [
                    entry("kix/a", "Apply", json!({"f:data": {"f:Corefile": {}}})),
                    entry("kubeadm", "Update", json!({"f:data": {"f:Corefile": {}}})),
                    entry("kubectl-patch", "Update", json!({"f:data": {"f:hosts": {}}})),
                ],
            },
            "data": {"Corefile": ".:53 {}", "hosts": "10.0.0.1 a"},
        }))
        .unwrap();
        let unshared: Vec<(String, Vec<String>)> = foreign_owners(&obj, &FieldManager::of("a"))
            .into_iter()
            .map(|o| (o.manager, o.unshared_paths))
            .collect();
        assert_eq!(
            unshared,
            [
                ("kubeadm".to_string(), vec![]),
                ("kubectl-patch".to_string(), vec!["data.hosts".to_string()]),
            ]
        );
    }

    /// Another Kix cluster's entry is another manager, and so is the legacy
    /// entry of a Kix cluster this Kix has deployed. A cluster's own entry
    /// holds the fields it applied, and the legacy one stands in only for a
    /// reader of a cluster that is not migrated.
    #[test]
    fn another_kix_cluster_is_another_manager() {
        let entry = |manager: &str, fields: Value| {
            json!({
                "manager": manager,
                "operation": "Apply",
                "fieldsType": "FieldsV1",
                "fieldsV1": fields,
            })
        };
        let obj: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "shared",
                "namespace": "app",
                "managedFields": [
                    entry("kix", json!({"f:data": {"f:a": {}, "f:old": {}}})),
                    entry("kix/a", json!({"f:data": {"f:a": {}}})),
                    entry("kix/b", json!({"f:data": {"f:a": {}, "f:b": {}}})),
                ],
            },
            "data": {"a": "1", "b": "2", "old": "3"},
        }))
        .unwrap();
        let owners = |cluster: &str| -> Vec<(String, Vec<String>)> {
            foreign_owners(&obj, &FieldManager::of(cluster))
                .into_iter()
                .map(|o| (o.manager, o.unshared_paths))
                .collect()
        };
        assert_eq!(
            owners("a"),
            [
                ("kix".to_string(), vec!["data.old".to_string()]),
                ("kix/b".to_string(), vec!["data.b".to_string()]),
            ]
        );
        assert_eq!(
            owners("b"),
            [
                ("kix".to_string(), vec!["data.old".to_string()]),
                ("kix/a".to_string(), Vec::<String>::new()),
            ]
        );
        let fields = |cluster: &str| fieldsv1::kix_fieldset(&obj, &FieldManager::of(cluster));
        assert_eq!(fields("a"), Some(json!({"f:data": {"f:a": {}}})));
        assert_eq!(fields("c"), None);
        assert_eq!(
            fieldsv1::kix_fieldset(&obj, &FieldManager::unmigrated("c")),
            Some(json!({"f:data": {"f:a": {}, "f:old": {}}}))
        );
    }

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
