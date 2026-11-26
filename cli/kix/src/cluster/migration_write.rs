//! The one write that moves an object an older Kix applied onto this Kix's
//! bookkeeping.
//!
//! An older Kix applied every object under the field manager `kix`, then
//! wrote a second time to each object to record which deployment records
//! name it (`kix.run/activations`) and the hash of what it applied
//! (`kix.run/applied-hash`). That second write left an `Update` entry under
//! `kix` in `managedFields`. This Kix applies under one manager per Kix
//! cluster and keeps both facts in revisions instead.
//!
//! The migration write is one JSON patch per object ([`needed`]). It tests
//! the object's `resourceVersion`, renames the `Apply` entry under `kix` to
//! the cluster's manager, removes the `Update` entry under `kix`, and
//! removes the two notes and every annotation key of a retired Kix domain.
//! It runs before the object's first apply under the cluster's manager,
//! because that apply is refused while `kix` still owns a field it changes.
//!
//! A Kubernetes cluster can hold Kix clusters on two versions of Kix. An
//! older Kix prunes for its Kix cluster only what no record of another Kix
//! cluster names in `kix.run/activations`, and its objects carry their
//! fields under `kix`. So while an object's note names a record of a Kix
//! cluster that is not migrated ([`Rule::others`]), the write keeps the note
//! with the deploying record's hash beside that cluster's hashes, and leaves
//! the entries under `kix` in place. The deploy then adds this cluster's own
//! entry by its apply. Every deploy evaluates [`needed`] again, so the write
//! finishes the job on such an object once that other cluster migrates.

use std::collections::{BTreeSet, HashSet};
use std::sync::Arc;

use k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry;
use kube::api::{Api, DynamicObject, Patch, PatchParams};
use serde_json::{Value, json};
use thiserror::Error;

use super::field_manager::{self, FieldManager};
use crate::manifest::keys;

/// How many times [`write`] reads an object again because it changed
/// between the read and the write.
const ATTEMPTS: usize = 5;

/// What the migration write keeps for Kix clusters an older Kix still
/// deploys.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Rule {
    /// The identity hashes of the records of every other Kix cluster on the
    /// Kubernetes cluster that is not migrated.
    pub others: Arc<HashSet<String>>,
    /// The identity hash of the record the run deploys, which a kept note
    /// names for this Kix cluster. `None` for a run that deploys no record,
    /// which leaves a kept note as it is.
    pub record: Option<String>,
}

/// Why [`write`] did not rewrite an object.
#[derive(Debug, Error)]
pub enum WriteError {
    #[error(
        "could not move {resource} to this version of Kix's bookkeeping. Kubernetes refused the write that renames its field manager `{legacy}` and removes the annotations `{activations}` and `{applied}`: {source}. Run the deploy again",
        legacy = field_manager::LEGACY,
        activations = keys::ACTIVATIONS,
        applied = keys::APPLIED_HASH,
    )]
    Refused {
        resource: String,
        #[source]
        source: kube::Error,
    },
    #[error(
        "could not move {resource} to this version of Kix's bookkeeping, because something else changed it each of the {ATTEMPTS} times Kix read it. Find what keeps writing to {resource}, then run the deploy again"
    )]
    KeepsChanging { resource: String },
    #[error("could not read {resource}: {source}")]
    Read {
        resource: String,
        #[source]
        source: kube::Error,
    },
}

/// What [`write`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Written {
    Rewritten,
    /// The object needed no write, or it is gone.
    NothingToDo,
}

fn is_main(e: &ManagedFieldsEntry, operation: &str) -> bool {
    e.manager.as_deref() == Some(field_manager::LEGACY)
        && e.operation.as_deref() == Some(operation)
        && e.subresource.is_none()
}

fn annotations(obj: &DynamicObject) -> impl Iterator<Item = (&String, &String)> {
    obj.metadata.annotations.iter().flatten()
}

/// Return the record hashes `kix.run/activations` lists on `obj`.
pub(crate) fn note_of(obj: &DynamicObject) -> BTreeSet<&str> {
    obj.metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(keys::ACTIVATIONS))
        .map(String::as_str)
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|h| !h.is_empty())
        .collect()
}

/// Return whether `obj`'s note names a record of a Kix cluster that is not
/// migrated, so the write keeps the note and the entries under `kix`.
pub(crate) fn shared_with_unmigrated(obj: &DynamicObject, rule: &Rule) -> bool {
    note_of(obj).iter().any(|h| rule.others.contains(*h))
}

/// Return whether the migration write moves `obj`'s `Apply` entry under
/// `kix` to `manager`'s name: the object has one, has no `Apply` entry under
/// `manager` yet, and is not kept for a Kix cluster an older Kix deploys.
/// Until the write runs, the entry under `kix` holds the fields this Kix
/// cluster's manager will own.
pub fn renames(obj: &DynamicObject, manager: &FieldManager, rule: &Rule) -> bool {
    let entries = obj.metadata.managed_fields.as_deref().unwrap_or_default();
    !shared_with_unmigrated(obj, rule)
        && entries.iter().any(|e| is_main(e, "Apply"))
        && !entries.iter().any(|e| {
            e.manager.as_deref() == Some(manager.name())
                && e.operation.as_deref() == Some("Apply")
                && e.subresource.is_none()
        })
}

/// Escape `key` for one segment of a JSON pointer.
fn pointer_segment(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

/// Return the operations of the migration write of `obj` for the Kix
/// cluster of `manager`, without the `resourceVersion` test, or `None` when
/// the object needs none. Index positions in `managedFields` are those of
/// `obj`, so build the patch from the object as just read.
///
/// An object needs the write when it carries either note, a key of a
/// retired Kix domain, or an entry under `kix` that is not kept for a Kix
/// cluster an older Kix deploys ([`shared_with_unmigrated`]). A kept note
/// needs the write when it does not name exactly that cluster's hashes and
/// the deploying record's.
pub fn needed(obj: &DynamicObject, manager: &FieldManager, rule: &Rule) -> Option<Vec<Value>> {
    let mut ops = Vec::new();
    let shared = shared_with_unmigrated(obj, rule);
    if !shared {
        let entries = obj.metadata.managed_fields.as_deref().unwrap_or_default();
        let own_apply = entries.iter().any(|e| {
            e.manager.as_deref() == Some(manager.name())
                && e.operation.as_deref() == Some("Apply")
                && e.subresource.is_none()
        });
        let mut removed = Vec::new();
        for (i, e) in entries.iter().enumerate() {
            if is_main(e, "Apply") && !own_apply {
                ops.push(json!({ "op": "test", "path": format!("/metadata/managedFields/{i}/manager"), "value": field_manager::LEGACY }));
                ops.push(json!({ "op": "replace", "path": format!("/metadata/managedFields/{i}/manager"), "value": manager.name() }));
            } else if is_main(e, "Apply") || is_main(e, "Update") {
                removed.push(i);
            }
        }
        // Removing an entry moves the ones after it, so remove from the end.
        for i in removed.into_iter().rev() {
            ops.push(json!({ "op": "test", "path": format!("/metadata/managedFields/{i}/manager"), "value": field_manager::LEGACY }));
            ops.push(json!({ "op": "remove", "path": format!("/metadata/managedFields/{i}") }));
        }
    }
    let present: Vec<&String> = annotations(obj).map(|(k, _)| k).collect();
    let remove = |key: &str, ops: &mut Vec<Value>| {
        ops.push(json!({ "op": "remove", "path": format!("/metadata/annotations/{}", pointer_segment(key)) }));
    };
    let note = note_of(obj);
    if shared {
        if let Some(record) = &rule.record {
            let kept: BTreeSet<&str> = note
                .iter()
                .copied()
                .filter(|h| rule.others.contains(*h))
                .chain(std::iter::once(record.as_str()))
                .collect();
            if kept != note {
                let value = kept.into_iter().collect::<Vec<_>>().join(",");
                ops.push(json!({ "op": "replace", "path": format!("/metadata/annotations/{}", pointer_segment(keys::ACTIVATIONS)), "value": value }));
            }
        }
    } else if present.iter().any(|k| k.as_str() == keys::ACTIVATIONS) {
        remove(keys::ACTIVATIONS, &mut ops);
    }
    if present.iter().any(|k| k.as_str() == keys::APPLIED_HASH) {
        remove(keys::APPLIED_HASH, &mut ops);
    }
    for key in present
        .iter()
        .filter(|k| crate::legacy_domain::is_legacy_key(k))
    {
        remove(key, &mut ops);
    }
    (!ops.is_empty()).then_some(ops)
}

/// Rewrite the object `name` that `api` serves for the Kix cluster of
/// `manager`, if it needs the migration write ([`needed`]).
///
/// The write tests the `resourceVersion` it read. When Kubernetes refuses
/// it and the object has another `resourceVersion` now, something wrote in
/// between, so Kix reads the object again and builds the write again, up to
/// [`ATTEMPTS`] times. A refusal of an object that did not change is an
/// error.
pub async fn write(
    api: &Api<DynamicObject>,
    name: &str,
    resource: &str,
    manager: &FieldManager,
    rule: &Rule,
) -> Result<Written, WriteError> {
    let read = |source| WriteError::Read {
        resource: resource.to_string(),
        source,
    };
    let mut obj = api.get_opt(name).await.map_err(read)?;
    for _ in 0..ATTEMPTS {
        let Some(found) = &obj else {
            return Ok(Written::NothingToDo);
        };
        let Some(mut ops) = needed(found, manager, rule) else {
            return Ok(Written::NothingToDo);
        };
        let version = found.metadata.resource_version.clone().unwrap_or_default();
        ops.insert(
            0,
            json!({ "op": "test", "path": "/metadata/resourceVersion", "value": version }),
        );
        let patch =
            Patch::<Value>::Json(serde_json::from_value(Value::Array(ops)).expect(
                "the migration write is built from JSON patch operations, which always parse",
            ));
        let params = PatchParams {
            field_manager: Some(manager.name().to_string()),
            ..PatchParams::default()
        };
        let refused = match api.patch(name, &params, &patch).await {
            Ok(_) => return Ok(Written::Rewritten),
            Err(e) => e,
        };
        obj = api.get_opt(name).await.map_err(read)?;
        let now = obj
            .as_ref()
            .and_then(|o| o.metadata.resource_version.clone());
        if now.as_deref() == Some(version.as_str()) {
            return Err(WriteError::Refused {
                resource: resource.to_string(),
                source: refused,
            });
        }
    }
    Err(WriteError::KeepsChanging {
        resource: resource.to_string(),
    })
}

#[cfg(test)]
#[path = "migration_write_tests.rs"]
mod tests;
