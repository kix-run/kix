//! The definition of the revisions' CustomResourceDefinition.
//!
//! `status` is a subresource, so a cluster can let an account edit
//! workloads and still deny it the applied hashes.

use serde_json::{Value, json};

use super::{KIND, PLURAL, crd_name, version};
use crate::manifest::keys;

/// Return the definition of the revision kind.
///
/// It has no `app.kubernetes.io/managed-by` label, so no sweep of Kix's own
/// objects lists it or its objects as something a build made.
pub(crate) fn definition() -> Value {
    let object = json!({
        "type": "object",
        "required": ["hash", "kind", "name"],
        "properties": {
            "hash": { "type": "string" },
            "group": { "type": "string" },
            "kind": { "type": "string" },
            "namespace": { "type": "string" },
            "name": { "type": "string" },
        },
    });
    let slot = json!({
        "type": "object",
        "required": ["kind"],
        "properties": {
            "kind": { "type": "string" },
            "namespace": { "type": "string" },
            "name": { "type": "string" },
        },
    });
    json!({
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": { "name": crd_name() },
        "spec": {
            "group": keys::GROUP,
            "scope": "Cluster",
            "names": {
                "kind": KIND,
                "listKind": format!("{KIND}List"),
                "plural": PLURAL,
                "singular": "packageinstancerevision",
            },
            "versions": [{
                "name": version(),
                "served": true,
                "storage": true,
                "subresources": { "status": {} },
                "schema": { "openAPIV3Schema": {
                    "type": "object",
                    "description": "Lists the objects one Kix build makes for one package instance, and the hash of each object as Kix last applied it. Managed by Kix; do not edit.",
                    "properties": {
                        "spec": {
                            "type": "object",
                            "required": ["cluster", "slot", "objects"],
                            "x-kubernetes-validations": [{
                                "rule": "self == oldSelf",
                                "message": "spec cannot change, because the revision's name is a hash of it",
                            }],
                            "properties": {
                                "cluster": { "type": "string" },
                                "slot": slot,
                                "objects": { "type": "array", "items": object },
                            },
                        },
                        "status": {
                            "type": "object",
                            "x-kubernetes-preserve-unknown-fields": true,
                            "properties": {
                                "applied": {
                                    "type": "object",
                                    "additionalProperties": { "type": "string" },
                                },
                            },
                        },
                    },
                }},
                "additionalPrinterColumns": [
                    { "name": "Cluster", "type": "string", "jsonPath": ".spec.cluster" },
                    { "name": "Slot", "type": "string", "jsonPath": ".spec.slot.kind" },
                    { "name": "Namespace", "type": "string", "jsonPath": ".spec.slot.namespace" },
                    { "name": "Instance", "type": "string", "jsonPath": ".spec.slot.name" },
                ],
            }],
        },
    })
}
