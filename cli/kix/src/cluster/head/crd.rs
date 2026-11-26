//! The head's CustomResourceDefinition, which Kix creates itself.
//!
//! The definition carries no status subresource. Every write replaces the
//! whole object with its `resourceVersion`, so the lock and the commit point
//! are each one write that Kubernetes orders.

use std::time::Duration;

use kube::Client;
use kube::api::{Api, DynamicObject, PostParams};
use kube::discovery::ApiResource;
use serde_json::{Value, json};

use super::{KIND, PLURAL, crd_name};
use crate::manifest::keys;

/// How long [`ensure_crd`] waits for a definition it created to be served.
const ESTABLISH_WAIT: Duration = Duration::from_secs(30);

fn crds(client: &Client) -> Api<DynamicObject> {
    let resource = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("apiextensions.k8s.io", "v1", "CustomResourceDefinition"),
        "customresourcedefinitions",
    );
    Api::all_with(client.clone(), &resource)
}

/// Return the definition of the head's kind.
///
/// It has no `app.kubernetes.io/managed-by` label, so no sweep of Kix's own
/// objects lists it or its objects as something a build made.
pub(super) fn definition() -> Value {
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

fn established(crd: &DynamicObject) -> bool {
    crd.data
        .pointer("/status/conditions")
        .and_then(Value::as_array)
        .is_some_and(|conditions| {
            conditions
                .iter()
                .any(|c| c["type"] == "Established" && c["status"] == "True")
        })
}

/// Why [`ensure_crd`] could not make the head's kind available.
#[derive(Debug, thiserror::Error)]
pub enum CrdError {
    #[error(
        "[K9557] cannot read or create CustomResourceDefinition `{name}` for the deploy lock: {}. Nothing was changed on the cluster. Grant this account `get` and `create` on `customresourcedefinitions` (or have an account with those permissions create `{name}` once, and grant this account `get`, `list`, `create`, and `update` on `{name}`)",
        crate::cluster::errors::describe(.source)
    )]
    Api {
        name: String,
        #[source]
        source: kube::Error,
    },
    #[error(
        "created CustomResourceDefinition `{name}`, but the Kubernetes API server did not start serving it within {} seconds. Nothing else was changed on the cluster. Wait a moment and run the command again",
        ESTABLISH_WAIT.as_secs()
    )]
    NotEstablished { name: String },
}

/// Create the head's CustomResourceDefinition when the cluster does not have
/// it, and wait until Kubernetes serves the kind. A definition that exists is
/// left as it is.
pub async fn ensure_crd(client: &Client) -> Result<(), CrdError> {
    let api = crds(client);
    let name = crd_name();
    let fail = |source| CrdError::Api {
        name: crd_name(),
        source,
    };
    match api.get_opt(&name).await {
        Ok(Some(found)) if established(&found) => return Ok(()),
        Ok(_) => {}
        // An account that may not read definitions needs none when the kind
        // is already served: only the first run on a cluster creates it.
        Err(e)
            if crate::cluster::errors::classify(&e)
                == crate::cluster::errors::FailureClass::Forbidden =>
        {
            if super::api(client)
                .list(&kube::api::ListParams::default().limit(1))
                .await
                .is_ok()
            {
                return Ok(());
            }
            return Err(fail(e));
        }
        Err(e) => return Err(fail(e)),
    }
    let definition: DynamicObject =
        serde_json::from_value(definition()).expect("the head's definition is an object");
    match api.create(&PostParams::default(), &definition).await {
        Ok(_) => {}
        Err(kube::Error::Api(e)) if e.code == 409 => {}
        Err(e) => return Err(fail(e)),
    }
    let start = tokio::time::Instant::now();
    loop {
        if let Some(found) = api.get_opt(&name).await.map_err(fail)?
            && established(&found)
        {
            return Ok(());
        }
        if start.elapsed() >= ESTABLISH_WAIT {
            return Err(CrdError::NotEstablished { name });
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}
