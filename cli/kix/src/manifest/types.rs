//! `kix-core`'s manifest types, plus the conversion of fetched objects.

use kube::api::DynamicObject;

pub use kix_core::manifest::types::*;

/// Serialise a fetched object into a whole-manifest `Value`.
///
/// `DynamicObject` keeps `metadata` in a typed field and puts only the
/// *remaining* keys (`spec`, `data`, …) in `.data`. Serialising `.data`
/// alone therefore yields a manifest with no `metadata`, name, or namespace.
/// This silently degrades every `ResourceId` built from it to `Kind/unknown`.
/// Every live object of the same kind then
/// collapses onto one id, matches nothing on the kix side, and the diff
/// reports the whole cluster as "will be created".
///
/// `kind`/`apiVersion` come from `.data` (the cluster sweep injects them,
/// since LIST responses omit them per item) rather than from `.types`.
pub fn to_manifest_value(obj: &DynamicObject) -> serde_json::Value {
    serde_json::to_value(obj).unwrap_or_else(|e| {
        // ObjectMeta + a JSON Value cannot fail to serialise.
        unreachable!("DynamicObject failed to serialise: {e}")
    })
}
