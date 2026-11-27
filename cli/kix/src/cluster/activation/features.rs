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
use crate::manifest::lifecycle::{PHASE_DEPLOYING, PHASE_QUEUED};

/// The operator acts on `spec.request` and reports it in
/// `status.startedRequest` and `status.finishedRequest`.
pub const REQUESTS: &str = "requests";

/// The operator takes each Kix cluster's deploy lock
/// ([`crate::cluster::head`]) before it deploys, repairs, or tears down, and
/// commits its deploys on it. A CLI with the lock refuses to hand work to an
/// operator without it, which would deploy beside the lock.
pub const HEAD_LOCK: &str = "head-lock";

/// The operator keeps what a deploy did in revisions and writes no notes on
/// the objects it applies ([`crate::cluster::revision`]). An older operator
/// would write `kix.run/activations` and `kix.run/applied-hash` back after
/// the CLI removed them, so a CLI with revisions refuses to change a Kix
/// cluster whose records such an operator drives
/// ([`operator_without_revisions`]).
pub const REVISIONS: &str = "revisions";

/// Every feature this release's operator handles.
const HANDLED: &[&str] = &[REQUESTS, HEAD_LOCK, REVISIONS];

/// The features a running operator published.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OperatorFeatures(Vec<String>);

impl OperatorFeatures {
    /// Return whether the operator handles `feature`.
    pub fn handles(&self, feature: &str) -> bool {
        self.0.iter().any(|f| f == feature)
    }

    /// Return whether an operator published any feature, which shows that
    /// one is installed. An operator from before the annotation publishes
    /// nothing.
    pub fn published(&self) -> bool {
        !self.0.is_empty()
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

/// A record of a Kix cluster that a Kix operator older than this Kix
/// deploys or repairs ([`operator_without_revisions`]).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error(
    "[K9557] Kix cluster {cluster} was handed to a Kix operator older than Kix {version}\n  \
     Nothing was changed on the cluster.\n\n  \
     Why:\n    \
     Deployment record `{record}` of Kix cluster {cluster} was submitted to the Kix operator, which deploys it and repairs its objects again and again. \
     CustomResourceDefinition `{crd}` does not list `{feature}` in its `{key}` annotation. \
     So either the operator running here is older than Kix {version}, or the operator was uninstalled. Kix cannot tell which. \
     An older operator writes the annotations `{activations}` and `{applied}` back onto every object it applies, after this version of Kix removed them.\n\n  \
     Next:\n    \
     If the operator still runs, upgrade it to Kix {version} or newer, wait for it to start, then run the command again.\n    \
     If the operator was uninstalled, run `kix deploy {cluster} --{flag}`. \
     That deploy takes the Kix cluster back from the operator, and later commands need no flag. \
     Do not use it while an older operator still runs, because the operator would keep writing the annotations back.",
    version = crate::version::running(),
    crd = keys::ACTIVATIONS_CRD,
    feature = REVISIONS,
    key = keys::OPERATOR_FEATURES,
    activations = keys::ACTIVATIONS,
    applied = keys::APPLIED_HASH,
    flag = OPERATOR_REMOVED_FLAG,
)]
pub struct OperatorWithoutRevisions {
    pub cluster: String,
    /// The operator-driven record.
    pub record: String,
}

/// The `kix deploy` flag that states no Kix operator runs for a Kix
/// cluster ([`take_back`]).
pub const OPERATOR_REMOVED_FLAG: &str = "operator-removed";

/// Why [`operator_without_revisions`] could not tell.
#[derive(Debug, thiserror::Error)]
pub enum FeaturesCheckError {
    #[error(
        "could not read CustomResourceDefinition `{crd}` to check the Kix operator's features: {0}. Check that this account has permission to read it, then run the command again",
        crd = keys::ACTIVATIONS_CRD
    )]
    Crd(kube::Error),
    #[error(transparent)]
    Records(super::RecordsError),
}

/// Return the first record of Kix cluster `cluster` that an operator
/// without [`REVISIONS`] would deploy or repair ([`driven_by_older_operator`]).
pub async fn operator_without_revisions(
    client: &Client,
    records: &super::Records,
    cluster: &str,
) -> Result<Option<OperatorWithoutRevisions>, FeaturesCheckError> {
    Ok(driven_by_older_operator(client, records, cluster)
        .await?
        .first()
        .map(|r| OperatorWithoutRevisions {
            cluster: cluster.to_string(),
            record: r.name.clone(),
        }))
}

/// Return the records of Kix cluster `cluster` that an operator without
/// [`REVISIONS`] would deploy or repair: each record the operator drives
/// (`spec.source` set) that is the current record (the one the deploy lock
/// names, else the newest by phase), queued, or deploying,
/// when the Activation CRD does not list [`REVISIONS`]. The operator acts
/// only on such records, so a Kix cluster with none of them is safe beside
/// any operator. A cluster without the CRD has no operator.
pub async fn driven_by_older_operator(
    client: &Client,
    records: &super::Records,
    cluster: &str,
) -> Result<Vec<super::Record>, FeaturesCheckError> {
    match read(client).await {
        Ok(found) if found.handles(REVISIONS) => return Ok(Vec::new()),
        Ok(_) => {}
        Err(kube::Error::Api(e)) if e.code == 404 => return Ok(Vec::new()),
        Err(e) => return Err(FeaturesCheckError::Crd(e)),
    }
    let own = records
        .of_cluster(cluster)
        .await
        .map_err(FeaturesCheckError::Records)?;
    // The current record is the one the deploy lock names, when the head
    // can be read, as for every run that takes the lock.
    let head_current = crate::cluster::head::read(client, cluster)
        .await
        .ok()
        .flatten()
        .and_then(|h| h.status.and_then(|s| s.current));
    let current = crate::cluster::revision::convert::current_of(head_current.as_deref(), &own)
        .map(|r| r.name.clone());
    Ok(own
        .into_iter()
        .filter(|r| r.operator_driven)
        .filter(|r| Some(&r.name) == current.as_ref() || queued_or_deploying(r))
        .collect())
}

fn queued_or_deploying(record: &super::Record) -> bool {
    matches!(record.phase.as_str(), "" | PHASE_QUEUED | PHASE_DEPLOYING)
}

/// What [`take_back`] changed on the records of a Kix cluster.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TakenBack {
    /// The current record, which no longer names a build for the operator.
    pub current: Option<String>,
    /// Queued records the operator never started, now `Superseded`.
    pub superseded: Vec<String>,
    /// Records the operator was deploying, now `Failed`.
    pub failed: Vec<String>,
}

impl TakenBack {
    /// Return whether nothing was changed.
    pub fn is_empty(&self) -> bool {
        self.current.is_none() && self.superseded.is_empty() && self.failed.is_empty()
    }
}

/// Why [`take_back`] could not finish.
#[derive(Debug, thiserror::Error)]
pub enum TakeBackError {
    #[error(transparent)]
    Check(#[from] FeaturesCheckError),
    #[error(transparent)]
    Records(#[from] super::RecordsError),
}

/// Take Kix cluster `cluster` back from a Kix operator that a person says
/// was uninstalled (`--operator-removed`), through `client`, which holds the
/// cluster's deploy lock. Change only the records
/// [`driven_by_older_operator`] returns. A queued record becomes
/// `Superseded`, because no operator will start it. A deploying record
/// becomes `Failed`, so the next plan takes in what it applied. Each record
/// then loses `spec.source`, which names the build for the operator, so it
/// reads as one the CLI deployed. Once this returns, no record of the
/// cluster makes [`operator_without_revisions`] refuse.
///
/// Each record changes its phase before it loses `spec.source`, so a run
/// that stops in between leaves a record that is still refused or one that
/// no longer counts. Running it again finishes the job.
pub async fn take_back(
    client: &Client,
    records: &super::Records,
    cluster: &str,
) -> Result<TakenBack, TakeBackError> {
    let driven = driven_by_older_operator(client, records, cluster).await?;
    let mut taken = TakenBack::default();
    let reason = format!(
        "the Kix operator was uninstalled (`kix deploy {cluster} --{OPERATOR_REMOVED_FLAG}`), so this deploy will not finish"
    );
    for record in driven {
        match record.phase.as_str() {
            "" | PHASE_QUEUED => {
                records.supersede(&record.name).await?;
                taken.superseded.push(record.name.clone());
            }
            PHASE_DEPLOYING => {
                records.fail_deploy(&record.name, &reason).await?;
                taken.failed.push(record.name.clone());
            }
            _ => taken.current = Some(record.name.clone()),
        }
        records.clear_source(&record.name).await?;
    }
    Ok(taken)
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
        assert!(read(&client).await.unwrap().handles(REVISIONS));
    }

    /// An operator that lists `revisions` is not refused, so taking the
    /// cluster back changes nothing, even with a queued record it drives.
    #[tokio::test]
    async fn take_back_leaves_records_an_operator_with_revisions_drives() {
        let mut crd = activation_crd();
        crd["metadata"]["annotations"] = json!({ (keys::OPERATOR_FEATURES): HANDLED.join(",") });
        let record = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-1",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
            },
            "spec": { "cluster": "a", "source": { "path": "/nix/store/x" } },
            "status": { "phase": "Queued" },
        });
        let api = FakeApi::new([crd, record.clone()]);
        let client = api.client();
        let found = crate::cluster::discovery::discover_resources(&client)
            .await
            .unwrap();
        let records = super::super::Records::open_installed(&client, &found).unwrap();
        let taken = take_back(&client, &records, "a").await.unwrap();
        assert!(taken.is_empty());
        let after = api.object("Activation", "a-1").unwrap();
        assert_eq!(after["spec"], record["spec"]);
        assert_eq!(after["status"]["phase"], "Queued");
    }
}
