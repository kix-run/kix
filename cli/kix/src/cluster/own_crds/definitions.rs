//! The definitions of the Activation and PackageInstance kinds.
//!
//! Their `spec` is what builds of earlier releases apply, field for field.
//! They have no `app.kubernetes.io/managed-by` label, so no sweep of Kix's
//! own objects lists them as something a build made.

use serde_json::{Value, json};

use crate::manifest::keys;
use crate::manifest::lifecycle::{PACKAGE_INSTANCE_KIND, RECORD_KIND};

/// Return the definition of the Activation kind.
pub(super) fn activation() -> Value {
    record(keys::ACTIVATIONS_CRD, RECORD_KIND, "activations", "Cluster")
}

/// Return the definition of the PackageInstance kind.
pub(super) fn package_instance() -> Value {
    record(
        keys::PACKAGE_INSTANCES_CRD,
        PACKAGE_INSTANCE_KIND,
        "packageinstances",
        "Namespaced",
    )
}

fn record(name: &str, kind: &str, plural: &str, scope: &str) -> Value {
    let version = keys::API_VERSION
        .rsplit_once('/')
        .map_or(keys::API_VERSION, |(_, v)| v);
    let open = json!({ "type": "object", "x-kubernetes-preserve-unknown-fields": true });
    json!({
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": { "name": name },
        "spec": {
            "group": keys::GROUP,
            "scope": scope,
            "names": {
                "kind": kind,
                "listKind": format!("{kind}List"),
                "plural": plural,
                "singular": kind.to_lowercase(),
            },
            "versions": [{
                "name": version,
                "served": true,
                "storage": true,
                "subresources": { "status": {} },
                "schema": { "openAPIV3Schema": {
                    "type": "object",
                    "properties": {
                        "apiVersion": { "type": "string" },
                        "kind": { "type": "string" },
                        "metadata": { "type": "object" },
                        "spec": open,
                        "status": open,
                    },
                }},
            }],
        },
    })
}
