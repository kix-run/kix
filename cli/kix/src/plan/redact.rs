//! Manifest indexing, secret redaction, and value size bounds for plan output.

use std::collections::{BTreeMap, HashMap};

use serde_json::Value;

use super::diff::resource_map_for_package;
use super::document;
use crate::eval::store_graph::StoreGraph;
use crate::manifest::diff::Difference;
use crate::manifest::keys;
use crate::manifest::types::{self, ResourceId};

/// The side of a diff a manifest comes from.
#[derive(Clone, Copy)]
pub(crate) enum Side {
    Old,
    New,
}

/// The old and new manifest of every resource a diff compared, by resource
/// id, for `--detail manifests`. Built from the two graphs; `kix plan`
/// replaces each object the apiserver answered with the live object and the
/// dry-run result ([`ManifestIndex::answered`]).
pub struct ManifestIndex<'a> {
    old_graph: &'a StoreGraph,
    new_graph: &'a StoreGraph,
    old: HashMap<ResourceId, Value>,
    new: HashMap<ResourceId, Value>,
}

impl<'a> ManifestIndex<'a> {
    pub fn new(old_graph: &'a StoreGraph, new_graph: &'a StoreGraph) -> Self {
        let index = |g: &StoreGraph| {
            g.resources
                .values()
                .map(|node| {
                    (
                        ResourceId::from_value(&node.manifest),
                        node.manifest.clone(),
                    )
                })
                .collect()
        };
        Self {
            old_graph,
            new_graph,
            old: index(old_graph),
            new: index(new_graph),
        }
    }

    /// Show `live` as the old side of `rid` and `result` as the new side,
    /// each side absent when `None`.
    pub fn answered(&mut self, rid: &ResourceId, live: Option<Value>, result: Option<Value>) {
        for (side, value) in [(&mut self.old, live), (&mut self.new, result)] {
            match value {
                Some(v) => side.insert(rid.clone(), v),
                None => side.remove(rid),
            };
        }
    }

    /// Return the resources of package `key` (`namespace/name`) on `side`,
    /// including its PackageInstance.
    pub(crate) fn package_resources(&self, key: &str, side: Side) -> Vec<ResourceId> {
        let graph = match side {
            Side::Old => self.old_graph,
            Side::New => self.new_graph,
        };
        graph
            .packages
            .values()
            .find(|p| format!("{}/{}", p.namespace, p.instance_name) == key)
            .map(|p| resource_map_for_package(p, graph).into_keys().collect())
            .unwrap_or_default()
    }

    /// Render the old and new manifests for each resource in `ids` when
    /// present on that side.
    pub(crate) fn render<'i>(
        &self,
        ids: impl IntoIterator<Item = &'i ResourceId>,
    ) -> BTreeMap<String, document::ManifestSides> {
        ids.into_iter()
            .map(|id| {
                let old = self.old.get(id);
                let new = self.new.get(id);
                let is_secret =
                    old.is_some_and(types::is_secret) || new.is_some_and(types::is_secret);
                let sides = document::ManifestSides {
                    old: old.map(|o| shown_manifest(is_secret, o, None)),
                    new: new.map(|n| shown_manifest(is_secret, n, old)),
                };
                (id.display_id(), sides)
            })
            .collect()
    }
}

/// Placeholder for a secret value omitted from the JSON diff. Covers a
/// Secret's `data` and `stringData` values, a Secret's
/// `kix.run/content-hash` and `kix.run/applied-hash`, and every
/// `checksum/*` annotation (where Helm charts store Secret hashes).
pub const SECRET_NOT_SHOWN: &str = "(secret, not shown)";

/// Placeholder for a secret value on the new side when the old side has a
/// different value at the same path, so a line diff of the two manifests
/// still shows the line as changed.
pub const SECRET_CHANGED_NOT_SHOWN: &str = "(secret, changed, not shown)";

/// Maximum serialized manifest size (3 MiB) shown at `--detail manifests` and
/// in a plan file. Matches the apiserver's request body limit so any object a
/// cluster can store is shown in full.
pub const MAX_SHOWN_MANIFEST_BYTES: usize = 3 * 1024 * 1024;

/// Maximum serialized field value size (16 KiB) included in a JSON diff so
/// large CRD schemas or ConfigMap entries do not bloat uploaded plans.
pub const MAX_SHOWN_VALUE_BYTES: usize = 16 * 1024;

/// Return `manifest` with secrets redacted and values capped at
/// [`MAX_SHOWN_MANIFEST_BYTES`].
fn shown_manifest(is_secret: bool, manifest: &Value, old: Option<&Value>) -> Value {
    shown_value(is_secret, "$", manifest, old, MAX_SHOWN_MANIFEST_BYTES)
}

/// Redact secret values in `value` at `path` (see [`hide_secrets`]), or
/// replace the value with a size note when it exceeds `max_bytes`.
pub(crate) fn shown_value(
    is_secret: bool,
    path: &str,
    value: &Value,
    old: Option<&Value>,
    max_bytes: usize,
) -> Value {
    let mut value = value.clone();
    hide_secrets(is_secret, path, &mut value, old);
    let bytes = value.to_string().len();
    if bytes > max_bytes {
        return Value::String(format!("({bytes} bytes, not shown)"));
    }
    value
}

/// Return `d` with secret values redacted for the text plan. Unlike the JSON
/// diff, this preserves large values so the text diff can print them line by
/// line.
pub fn without_secrets(is_secret: bool, d: &Difference) -> Difference {
    let mut d = d.clone();
    let old = d.a_value.clone();
    if let Some(value) = &mut d.a_value {
        hide_secrets(is_secret, &d.path, value, None);
    }
    if let Some(value) = &mut d.b_value {
        hide_secrets(is_secret, &d.path, value, old.as_ref());
    }
    d
}

/// Replace every secret value in `value` with [`SECRET_NOT_SHOWN`], or with
/// [`SECRET_CHANGED_NOT_SHOWN`] when `old` holds a different value at the
/// same path. Array elements are matched to `old` by position.
fn hide_secrets(is_secret: bool, path: &str, value: &mut Value, old: Option<&Value>) {
    if is_secret_path(is_secret, path) {
        let changed = old.is_some_and(|o| o != value);
        let marker = if changed {
            SECRET_CHANGED_NOT_SHOWN
        } else {
            SECRET_NOT_SHOWN
        };
        *value = Value::String(marker.into());
        return;
    }
    match value {
        Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                let old_child = old.and_then(|o| o.get(key));
                hide_secrets(is_secret, &format!("{path}.{key}"), child, old_child);
            }
        }
        Value::Array(items) => {
            for (i, child) in items.iter_mut().enumerate() {
                let old_child = old.and_then(|o| o.get(i));
                hide_secrets(is_secret, &format!("{path}[{i}]"), child, old_child);
            }
        }
        _ => {}
    }
}

/// Return true when the value at `path` is secret. Because annotation keys
/// contain dots and slashes that diff paths do not escape, keys are matched
/// by their suffix after `annotations.`.
///
/// On a Secret, this also covers `kubectl.kubernetes.io/last-applied-configuration`
/// and the content and applied hashes under every domain Kix has stamped.
fn is_secret_path(is_secret: bool, path: &str) -> bool {
    if path.contains(".annotations.checksum/") {
        return true;
    }
    if !is_secret {
        return false;
    }
    let under = |field: &str| {
        path.starts_with(&format!("{field}.")) || path.starts_with(&format!("{field}["))
    };
    let Some(annotation) = path.strip_prefix("$.metadata.annotations.") else {
        return under("$.data") || under("$.stringData");
    };
    annotation == LAST_APPLIED
        || [keys::CONTENT_HASH, keys::APPLIED_HASH].iter().any(|k| {
            annotation == *k
                || crate::legacy_domain::legacy_spellings(k)
                    .iter()
                    .any(|l| annotation == l)
        })
}

/// The annotation `kubectl apply` keeps the whole applied object in.
pub(super) const LAST_APPLIED: &str = "kubectl.kubernetes.io/last-applied-configuration";
