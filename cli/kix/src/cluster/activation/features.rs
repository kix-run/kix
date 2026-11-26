//! What a running Kix operator handles, published on the Activation CRD.
//!
//! The CLI and the operator ship in the same release, but a cluster can run
//! an operator older than the CLI that talks to it. The operator therefore
//! writes the features it handles to the `kix.run/operator-features`
//! annotation on the Activation CRD when it starts, and the CLI reads them
//! before it hands the operator work. An operator that writes nothing is one
//! from before the annotation, which handles none of these features.

use kube::Client;
use kube::api::{Api, DynamicObject, Patch, PatchParams};
use kube::discovery::ApiResource;
use serde_json::json;

use crate::manifest::keys;

/// The operator acts on `spec.request` and reports it in
/// `status.startedRequest` and `status.finishedRequest`.
pub const REQUESTS: &str = "requests";

/// The operator takes each Kix cluster's deploy lock
/// ([`crate::cluster::head`]) before it deploys, repairs, or tears down, and
/// commits its deploys on it. A CLI with the lock refuses to hand work to an
/// operator without it, which would deploy beside the lock.
pub const HEAD_LOCK: &str = "head-lock";

/// Every feature this release's operator handles.
const HANDLED: &[&str] = &[REQUESTS, HEAD_LOCK];

/// The features a running operator published.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OperatorFeatures(Vec<String>);

impl OperatorFeatures {
    /// Return whether the operator handles `feature`.
    pub fn handles(&self, feature: &str) -> bool {
        self.0.iter().any(|f| f == feature)
    }

    fn parse(annotation: Option<&str>) -> Self {
        OperatorFeatures(
            annotation
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|f| !f.is_empty())
                .map(str::to_string)
                .collect(),
        )
    }
}

fn crds(client: &Client) -> Api<DynamicObject> {
    let resource = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("apiextensions.k8s.io", "v1", "CustomResourceDefinition"),
        "customresourcedefinitions",
    );
    Api::all_with(client.clone(), &resource)
}

/// Write the features this release's operator handles to the Activation CRD.
pub async fn publish(client: &Client) -> Result<(), kube::Error> {
    let patch = json!({
        "metadata": { "annotations": { (keys::OPERATOR_FEATURES): HANDLED.join(",") } },
    });
    crds(client)
        .patch(
            keys::ACTIVATIONS_CRD,
            &PatchParams::default(),
            &Patch::Merge(&patch),
        )
        .await
        .map(|_| ())
}

/// Read the features the cluster's operator published on the Activation CRD.
/// A CRD without the annotation gives no features.
pub async fn read(client: &Client) -> Result<OperatorFeatures, kube::Error> {
    let crd = crds(client).get(keys::ACTIVATIONS_CRD).await?;
    let annotation = crd
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| a.get(keys::OPERATOR_FEATURES))
        .map(String::as_str);
    Ok(OperatorFeatures::parse(annotation))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;

    fn activation_crd() -> serde_json::Value {
        json!({
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": { "name": keys::ACTIVATIONS_CRD },
        })
    }

    /// A CRD an older operator left alone reads as no features, and one the
    /// operator published on reads as what it handles.
    #[tokio::test]
    async fn an_unpublished_operator_handles_no_requests() {
        let api = FakeApi::new([activation_crd()]);
        let client = api.client();
        assert!(!read(&client).await.unwrap().handles(REQUESTS));
        publish(&client).await.unwrap();
        assert!(read(&client).await.unwrap().handles(REQUESTS));
        assert!(read(&client).await.unwrap().handles(HEAD_LOCK));
    }
}
