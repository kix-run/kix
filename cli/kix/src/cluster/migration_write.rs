//! The one write that tidies an object an older Kix applied onto this Kix's
//! bookkeeping.
//!
//! An older Kix applied every object under the field manager `kix`, then
//! wrote a second time to each object to record which deployment records
//! name it (`kix.run/activations`) and the hash of what it applied
//! (`kix.run/applied-hash`). That second write left an `Update` entry under
//! `kix` in `managedFields`. This Kix applies under one manager per Kix
//! cluster and keeps both facts in revisions. Before a run writes any
//! object, it gives the records the older Kix wrote revisions
//! ([`super::revision::convert`]), so by the time this write runs the notes
//! are no longer read.
//!
//! The migration write is one JSON patch per object ([`needed`]). It tests
//! the object's `resourceVersion`, moves the `Apply` entry under `kix` to the
//! Kix cluster's manager when the entry holds that cluster's fields
//! ([`takes_legacy`]), removes the `Update` entry under `kix`, and removes
//! the two notes and every annotation key of a retired Kix domain. It runs
//! before the object's first apply under the cluster's manager, because that
//! apply is refused while `kix` still owns a field it changes.
//!
//! The entry under `kix` is shared by every Kix cluster that applied the
//! object under it. A Kix cluster takes it only for an object one of its
//! records names, and only when every other Kix cluster whose records name
//! the object has an `Apply` entry of its own. Otherwise the entry may hold
//! another cluster's fields, and it stays.
//!
//! A Kubernetes cluster can hold Kix clusters on two versions of Kix. An
//! older Kix prunes for its Kix cluster only what no record of another Kix
//! cluster names in `kix.run/activations`, and reads drift from
//! `kix.run/applied-hash`. So while an object's note names a record of
//! another Kix cluster that has no revision map
//! ([`Tenancy::older_kix_hashes`]), the write keeps both notes, writes the
//! deploying record's hash into the first beside that cluster's hashes, and
//! leaves the entries under `kix` in place. Every deploy evaluates [`needed`]
//! again, so the write finishes the job on such an object once that other
//! cluster has revisions.

use std::collections::BTreeSet;

use k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry;
use kube::api::{Api, DynamicObject, Patch, PatchParams};
use serde_json::{Value, json};
use thiserror::Error;

use super::apply;
use super::drift;
use super::field_manager::{self, FieldManager};
use super::prune_guard::PruneGuard;
use super::tenancy::Tenancy;
use crate::manifest::keys;

/// How many times [`write`] reads an object again because it changed
/// between the read and the write.
const ATTEMPTS: usize = 5;

/// Why [`write`] did not rewrite an object.
#[derive(Debug, Error)]
pub enum WriteError {
    #[error(
        "could not update Kix metadata on {resource} because Kubernetes refused the patch that renames field manager `{legacy}` and removes retired annotations `{activations}` and `{applied}`: {source}. Check permissions on {resource}, then run the deploy again",
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
        "could not update Kix metadata on {resource} because the dry-run conflict check failed: {source}. Check your cluster connection and permissions on {resource}, then run the deploy again"
    )]
    CheckRefused {
        resource: String,
        #[source]
        source: kube::Error,
    },
    #[error(
        "could not update Kix metadata on {resource} because another writer modified it on each of the {ATTEMPTS} attempts. Stop whatever keeps updating {resource}, then run the deploy again"
    )]
    KeepsChanging { resource: String },
    /// What the run's forced apply of the object would take back no longer
    /// matches what Kix found when making the plan.
    #[error(
        "{resource} was not updated because the fields Kix would take back changed on the cluster after the plan was made. Run the command again to review a fresh plan"
    )]
    ChangedSincePlan { resource: String },
    #[error(
        "could not read {resource} before updating its Kix metadata: {source}. Check your cluster connection and `get` permission on {resource}, then run the deploy again"
    )]
    Read {
        resource: String,
        #[source]
        source: kube::Error,
    },
    #[error(
        "could not determine which Kix clusters deploy {resource}, so its Kix metadata was not updated: {reason}"
    )]
    Tenancy { resource: String, reason: String },
}

/// What [`write`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Written {
    /// The object was rewritten and has this `resourceVersion` now.
    Rewritten { resource_version: String },
    /// The object needed no write, or it is gone.
    NothingToDo,
}

fn is_legacy(e: &ManagedFieldsEntry, operation: &str) -> bool {
    e.manager.as_deref() == Some(field_manager::LEGACY)
        && e.operation.as_deref() == Some(operation)
        && e.subresource.is_none()
}

fn has_apply_entry(obj: &DynamicObject, manager: &str) -> bool {
    obj.metadata.managed_fields.iter().flatten().any(|e| {
        e.manager.as_deref() == Some(manager)
            && e.operation.as_deref() == Some("Apply")
            && e.subresource.is_none()
    })
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

/// Return whether the fields under `obj`'s `Apply` entry for `kix` are the
/// fields of `manager`'s Kix cluster: a record of that cluster names the
/// object, every other Kix cluster whose records name it has an `Apply`
/// entry of its own, and no record of another Kix cluster without a map is
/// in its note. Only then may the write move or remove the entry, and a
/// planner count it as the cluster's own. The record that names the object
/// is the cluster's whose tenancy `tenancy` is read for.
pub fn takes_legacy(obj: &DynamicObject, tenancy: &Tenancy) -> bool {
    tenancy.named_by_own(obj)
        && tenancy.older_kix_hashes(obj).is_empty()
        && tenancy
            .named_by_others(obj)
            .iter()
            .all(|c| has_apply_entry(obj, FieldManager::of(c).name()))
}

/// Return whether the migration write moves `obj`'s `Apply` entry under
/// `kix` to `manager`'s name: the object has one, has no `Apply` entry under
/// `manager` yet, and the entry holds the cluster's fields
/// ([`takes_legacy`]). Until the write runs, the entry under `kix` holds the
/// fields the cluster's manager will own.
pub fn renames(obj: &DynamicObject, manager: &FieldManager, tenancy: &Tenancy) -> bool {
    obj.metadata
        .managed_fields
        .iter()
        .flatten()
        .any(|e| is_legacy(e, "Apply"))
        && !has_apply_entry(obj, manager.name())
        && takes_legacy(obj, tenancy)
}

/// Escape `key` for one segment of a JSON pointer.
fn pointer_segment(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

/// Return the operations of the migration write of `obj` for the Kix
/// cluster of `manager`, without the `resourceVersion` test, or `None` when
/// the object needs none. `tenancy` says which Kix clusters name the object,
/// and `record` is the identity hash of the record the run deploys, which a
/// kept note names. Index positions in `managedFields` are those of `obj`,
/// so build the patch from the object as just read.
///
/// An object needs the write when it carries either note that is not kept
/// for an older Kix, a key of a retired Kix domain, an `Update` entry under
/// `kix` that is not kept, or an `Apply` entry under `kix` that the cluster
/// takes ([`takes_legacy`]). A kept note needs the write when it does not
/// name exactly that older cluster's hashes and the deploying record's.
pub fn needed(
    obj: &DynamicObject,
    manager: &FieldManager,
    tenancy: &Tenancy,
    record: Option<&str>,
) -> Option<Vec<Value>> {
    let mut ops = Vec::new();
    let older: BTreeSet<&str> = tenancy.older_kix_hashes(obj).into_iter().collect();
    let kept_for_older = !older.is_empty();
    let take = takes_legacy(obj, tenancy);
    let own_apply = has_apply_entry(obj, manager.name());
    let entries = obj.metadata.managed_fields.as_deref().unwrap_or_default();
    let mut removed = Vec::new();
    for (i, e) in entries.iter().enumerate() {
        if is_legacy(e, "Apply") && take && !own_apply {
            ops.push(json!({ "op": "test", "path": format!("/metadata/managedFields/{i}/manager"), "value": field_manager::LEGACY }));
            ops.push(json!({ "op": "replace", "path": format!("/metadata/managedFields/{i}/manager"), "value": manager.name() }));
        } else if (is_legacy(e, "Apply") && take) || (is_legacy(e, "Update") && !kept_for_older) {
            removed.push(i);
        }
    }
    // Removing an entry moves the ones after it, so remove from the end.
    for i in removed.into_iter().rev() {
        ops.push(json!({ "op": "test", "path": format!("/metadata/managedFields/{i}/manager"), "value": field_manager::LEGACY }));
        ops.push(json!({ "op": "remove", "path": format!("/metadata/managedFields/{i}") }));
    }
    let present: Vec<&String> = obj
        .metadata
        .annotations
        .iter()
        .flatten()
        .map(|(k, _)| k)
        .collect();
    let has = |key: &str| present.iter().any(|k| k.as_str() == key);
    let remove = |key: &str, ops: &mut Vec<Value>| {
        ops.push(json!({ "op": "remove", "path": format!("/metadata/annotations/{}", pointer_segment(key)) }));
    };
    if kept_for_older {
        let note = note_of(obj);
        if let Some(record) = record {
            let kept: BTreeSet<&str> = older.iter().copied().chain([record]).collect();
            if kept != note {
                let value = kept.into_iter().collect::<Vec<_>>().join(",");
                ops.push(json!({ "op": "replace", "path": format!("/metadata/annotations/{}", pointer_segment(keys::ACTIVATIONS)), "value": value }));
            }
        }
    } else {
        for key in [keys::ACTIVATIONS, keys::APPLIED_HASH] {
            if has(key) {
                remove(key, &mut ops);
            }
        }
    }
    for key in present
        .iter()
        .filter(|k| crate::legacy_domain::is_legacy_key(k))
    {
        remove(key, &mut ops);
    }
    (!ops.is_empty()).then_some(ops)
}

/// Return the field manager to judge `obj` with as the migration write
/// leaves it: one that counts the entry under `kix` as `manager`'s own when
/// the write moves that entry to `manager` ([`renames`]).
pub fn view_of(obj: &DynamicObject, manager: &FieldManager, tenancy: &Tenancy) -> FieldManager {
    if renames(obj, manager, tenancy) {
        manager.as_unmigrated()
    } else {
        manager.clone()
    }
}

/// Return the field manager whose name the API server must see as its own
/// for an apply to `obj` to judge ownership as `manager`'s apply after the
/// migration write: the legacy manager `kix` when the write moves that entry
/// to `manager` ([`renames`]), since until then the entry under `kix` holds
/// the fields `manager` will own.
pub fn applies_as(obj: &DynamicObject, manager: &FieldManager, tenancy: &Tenancy) -> FieldManager {
    if renames(obj, manager, tenancy) {
        FieldManager::legacy_for(manager.cluster())
    } else {
        manager.clone()
    }
}

/// What [`write`] needs besides the object.
pub struct Write<'a> {
    pub api: &'a Api<DynamicObject>,
    pub name: &'a str,
    /// The object as messages name it.
    pub resource: &'a str,
    pub manager: &'a FieldManager,
    /// The identity hash of the record the run deploys.
    pub record: Option<&'a str>,
    /// Reads which Kix clusters name the object, again when the object names
    /// a record the last read did not see ([`PruneGuard::tenancy_naming`]).
    pub judge: &'a PruneGuard,
    /// For an object the run applies with force: the manifest it applies
    /// and what the plan's answer said the forced apply takes
    /// ([`apply::takes_back`]). The write goes on only while the API server
    /// gives the same answer for the object the write read.
    pub takes_back: Option<(&'a Value, &'a [drift::TakenField])>,
}

/// Rewrite the object `w.name` if it needs the migration write
/// ([`needed`]).
///
/// The write tests the `resourceVersion` it read. When the test fails,
/// something wrote in between, so Kix reads the object again and builds the
/// write again, up to [`ATTEMPTS`] times. Any other refusal is reported as
/// it is. With `w.takes_back`, each round first asks the API server what the
/// forced apply would take from the object it read, under the name the apply
/// will own that object's fields by ([`applies_as`]). An answer other than
/// the plan's fails with [`WriteError::ChangedSincePlan`], and an object that
/// moved since the read is read again.
pub async fn write(w: &Write<'_>) -> Result<Written, WriteError> {
    let read = |source| WriteError::Read {
        resource: w.resource.to_string(),
        source,
    };
    let changed = || WriteError::ChangedSincePlan {
        resource: w.resource.to_string(),
    };
    let mut obj = w.api.get_opt(w.name).await.map_err(read)?;
    for _ in 0..ATTEMPTS {
        let Some(found) = &obj else {
            return Ok(Written::NothingToDo);
        };
        let version = found.metadata.resource_version.clone().unwrap_or_default();
        let tenancy = w
            .judge
            .tenancy_naming(found)
            .await
            .map_err(|e| WriteError::Tenancy {
                resource: w.resource.to_string(),
                reason: match e {
                    super::prune_guard::PruneError::Tenancy(problem) => problem.to_string(),
                    other => other.to_string(),
                },
            })?;
        if let Some((manifest, shown)) = w.takes_back {
            let owner = applies_as(found, w.manager, &tenancy);
            let sent = apply::bound_to(apply::forced_manifest(manifest, found, &owner), found);
            let answer = apply::takes_back(w.api, w.name, &owner, &sent, found)
                .await
                .map_err(|source| WriteError::CheckRefused {
                    resource: w.resource.to_string(),
                    source,
                })?;
            match answer {
                apply::Takes::Fields(taken) if taken == shown => {}
                apply::Takes::Moved => {
                    obj = w.api.get_opt(w.name).await.map_err(read)?;
                    continue;
                }
                apply::Takes::Fields(_) | apply::Takes::Unknown => return Err(changed()),
            }
        }
        let Some(mut ops) = needed(found, w.manager, &tenancy, w.record) else {
            return Ok(Written::NothingToDo);
        };
        ops.insert(
            0,
            json!({ "op": "test", "path": "/metadata/resourceVersion", "value": version }),
        );
        let patch =
            Patch::<Value>::Json(serde_json::from_value(Value::Array(ops)).expect(
                "the migration write is built from JSON patch operations, which always parse",
            ));
        let params = PatchParams {
            field_manager: Some(w.manager.name().to_string()),
            ..PatchParams::default()
        };
        let refused = match w.api.patch(w.name, &params, &patch).await {
            Ok(written) => {
                return Ok(Written::Rewritten {
                    resource_version: written.metadata.resource_version.unwrap_or_default(),
                });
            }
            Err(e) => e,
        };
        // Kubernetes refuses a patch whose `test` fails with 422. The patch
        // was built from the object at `version`, so the test failed only if
        // the object is at another version now.
        let invalid = matches!(&refused, kube::Error::Api(e) if e.code == 422);
        obj = w.api.get_opt(w.name).await.map_err(read)?;
        let now = obj
            .as_ref()
            .and_then(|o| o.metadata.resource_version.clone());
        if !invalid || now.as_deref() == Some(version.as_str()) {
            return Err(WriteError::Refused {
                resource: w.resource.to_string(),
                source: refused,
            });
        }
    }
    Err(WriteError::KeepsChanging {
        resource: w.resource.to_string(),
    })
}

#[cfg(test)]
#[path = "migration_write_tests.rs"]
mod tests;
