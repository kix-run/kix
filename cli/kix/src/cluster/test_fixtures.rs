//! Manifests for the deploy engine's unit tests.

use serde_json::{Value, json};

use crate::manifest::keys;
use crate::manifest::lifecycle::{PACKAGE_INSTANCE_KIND, RECORD_KIND};

/// Return the `apiVersion` of `kind` in these tests.
pub(crate) fn api_version_of(kind: &str) -> &'static str {
    match kind {
        "Deployment" | "StatefulSet" => "apps/v1",
        "Job" => "batch/v1",
        k if k == PACKAGE_INSTANCE_KIND || k == RECORD_KIND => keys::API_VERSION,
        _ => "v1",
    }
}

/// Return a manifest with identity hash `id_hash` that depends on the
/// comma-separated identity hashes in `deps`.
pub(crate) fn manifest(kind: &str, name: &str, ns: &str, id_hash: &str, deps: &str) -> Value {
    let mut annotations = serde_json::Map::new();
    annotations.insert(keys::IDENTITY_HASH.into(), json!(id_hash));
    if !deps.is_empty() {
        annotations.insert(keys::DEPENDS_ON.into(), json!(deps));
    }
    json!({
        "apiVersion": api_version_of(kind),
        "kind": kind,
        "metadata": {
            "name": name,
            "namespace": ns,
            "annotations": annotations,
        }
    })
}
