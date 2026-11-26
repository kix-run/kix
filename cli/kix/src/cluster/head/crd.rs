//! The definition of the head's CustomResourceDefinition.
//!
//! It carries no status subresource. Every write replaces the whole object
//! with its `resourceVersion`, so the lock and the commit point are each one
//! write that Kubernetes orders.

use serde_json::{Value, json};

use super::{KIND, PLURAL, crd_name};
use crate::manifest::keys;

/// Return the definition of the head's kind.
///
/// It has no `app.kubernetes.io/managed-by` label, so no sweep of Kix's own
/// objects lists it or its objects as something a build made.
pub(crate) fn definition() -> Value {
    let version = keys::API_VERSION
        .rsplit_once('/')
        .map_or(keys::API_VERSION, |(_, v)| v);
    let lock = json!({
        "type": "object",
        "x-kubernetes-preserve-unknown-fields": true,
        "properties": {
            "holder": { "type": "string" },
            "hint": { "type": "string" },
            "activation": { "type": "string" },
            "purpose": { "type": "string" },
            "renewed": { "type": "string", "format": "date-time" },
            "durationSeconds": { "type": "integer" },
            "waiting": { "type": "string" },
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
                "singular": "activationhead",
            },
            "versions": [{
                "name": version,
                "served": true,
                "storage": true,
                "schema": { "openAPIV3Schema": {
                    "type": "object",
                    "description": "Tracks a Kix cluster's active deployment record, the Kix version that last changed the cluster, and the current deploy lock holder. Managed by Kix; do not edit.",
                    "properties": {
                        "status": {
                            "type": "object",
                            "x-kubernetes-preserve-unknown-fields": true,
                            "properties": {
                                "current": { "type": "string" },
                                "generation": { "type": "integer" },
                                "lock": lock,
                                "writer": {
                                    "type": "object",
                                    "x-kubernetes-preserve-unknown-fields": true,
                                    "properties": {
                                        "version": { "type": "string" },
                                        "program": { "type": "string" },
                                    },
                                },
                            },
                        },
                    },
                }},
                "additionalPrinterColumns": [
                    { "name": "Current", "type": "string", "jsonPath": ".status.current" },
                    { "name": "Generation", "type": "integer", "jsonPath": ".status.generation" },
                    { "name": "Holder", "type": "string", "jsonPath": ".status.lock.hint" },
                    { "name": "Purpose", "type": "string", "jsonPath": ".status.lock.purpose" },
                    { "name": "Renewed", "type": "date", "jsonPath": ".status.lock.renewed" },
                ],
            }],
        },
    })
}
