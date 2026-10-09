//! A dry run of a real cluster's [`ResourceIo`] and [`SecretHydrator`].

use std::time::Duration;

use async_trait::async_trait;
use kube::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;

use crate::manifest::types::ResourceId;

use super::super::apply::{ApplyAction, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::errors::FetchError;
use super::super::preview::{DryRunAnswer, DryRunOutcome, Journal, PruneAnswer, Refusal};
use super::super::prune_guard::Pruned;
use super::super::readiness::{ImportTarget, ReadinessError, ReadinessResult};
use super::super::secrets::{HydrationResult, SecretError};
use super::{
    DeleteError, KubeResources, OnStatus, ReadError, RecreateError, ResourceIo, SecretHydrator,
    SopsHydrator,
};
use crate::build_source::SopsSources;

/// [`KubeResources`] and [`SopsHydrator`] with every write sent as
/// `dryRun=All`: the resources are made here, as dry-run ones, so no path
/// through them persists a write. Nothing persists, so nothing is written to
/// the Activation record either: a run made with [`super::Cluster::dry_run`]
/// has none.
///
/// Keeps what the apiserver answered for each object in a [`Journal`]: the
/// object an apply would produce, a recreate, a prune answer, or the typed
/// reason it was refused.
pub(crate) struct DryRun {
    resources: KubeResources,
    secrets: SopsHydrator,
    journal: Journal,
}

impl DryRun {
    pub(crate) fn new(
        client: Client,
        discovery: Vec<(ApiResource, Scope)>,
        cluster: String,
        identity_hash: Option<String>,
        force_conflicts: bool,
        sops: SopsSources,
    ) -> Self {
        DryRun {
            resources: KubeResources::dry_run(
                client,
                discovery,
                cluster,
                identity_hash,
                force_conflicts,
            ),
            secrets: SopsHydrator::new(sops),
            journal: Journal::default(),
        }
    }

    /// What the apiserver answered for each object so far. Drains the
    /// journal.
    pub(crate) fn take_answers(&self) -> Vec<DryRunAnswer> {
        self.journal.take()
    }
}

#[async_trait]
impl ResourceIo for DryRun {
    async fn apply(&self, manifest: &Value) -> Result<ApplyResult, ApplyError> {
        let rid = ResourceId::from_value(manifest);
        // A dry run creates no CRD, so discovery cannot gain a kind during
        // one and a cache miss is final.
        let Some((ar, scope)) = self.resources.cached_kind(&rid.kind).await else {
            let e = ApplyError::UnknownKind {
                kind: rid.kind.clone(),
            };
            self.journal
                .record(rid, DryRunOutcome::Refused(Refusal::of_apply(&e)));
            return Err(e);
        };
        let applied = self.resources.apply_as(&ar, scope, manifest).await;
        match &applied {
            Ok(ApplyResult {
                preview: Some(preview),
                ..
            }) => self
                .journal
                .record(rid, DryRunOutcome::Applied(preview.clone())),
            Ok(_) => {}
            Err(e) => self
                .journal
                .record(rid, DryRunOutcome::Refused(Refusal::of_apply(e))),
        }
        applied
    }

    async fn get_live(&self, rid: &ResourceId) -> Result<Option<Value>, ReadError> {
        self.resources.get_live(rid).await
    }

    async fn recreate_in_place(&self, manifest: &Value) -> Result<ApplyResult, RecreateError> {
        let rid = ResourceId::from_value(manifest);
        let (ar, scope, api, _) = self.resources.delete_for_recreate(&rid).await?;

        // The delete was checked but nothing went away, so the dry-run apply
        // of the changed manifest hits the immutable-field 422 the real path
        // avoids by deleting first. Every other answer (schema, admission,
        // RBAC, field conflicts) is the validation a dry run promises, so
        // the apply still runs; only that one error is the expected "would
        // be created after the delete".
        let existing = api
            .get_opt(&rid.name)
            .await
            .ok()
            .flatten()
            .and_then(|o| serde_json::to_value(o).ok());
        let applied = self.resources.apply_as(&ar, scope, manifest).await;
        let outcome = match &applied {
            Ok(result) => DryRunOutcome::Recreated {
                live: existing,
                result: result.preview.as_ref().map(|p| p.result.clone()),
            },
            Err(ApplyError::ImmutableConflict { .. }) => DryRunOutcome::Recreated {
                live: existing,
                result: None,
            },
            Err(e) => DryRunOutcome::Refused(Refusal::of_apply(e)),
        };
        self.journal.record(rid.clone(), outcome);
        match applied {
            Ok(result) => Ok(result),
            Err(ApplyError::ImmutableConflict { .. }) => Ok(ApplyResult {
                action: ApplyAction::Created,
                preview: None,
            }),
            Err(e) => Err(RecreateError::DryRunReapply(e)),
        }
    }

    async fn wait_ready(
        &self,
        rid: &ResourceId,
        import_target: Option<&ImportTarget>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ReadinessResult, ReadinessError> {
        self.resources
            .wait_ready(rid, import_target, timeout, cancel, on_status)
            .await
    }

    /// A dry run persists no CRD, so there is nothing new to discover.
    async fn rediscover(&self) -> Result<(), FetchError> {
        Ok(())
    }

    async fn prune(&self, rid: &ResourceId) -> Result<Pruned, DeleteError> {
        let deleted = self.resources.prune(rid).await;
        let answer = match &deleted {
            Ok(Pruned::Deleted | Pruned::Gone) => PruneAnswer::Deleted,
            Ok(Pruned::Kept(shared)) => PruneAnswer::KeptShared(shared.describe()),
            Ok(Pruned::Changed(_)) => PruneAnswer::KeptChanged,
            // No answer to keep: the delete never reached the apiserver. The
            // engine reports the failed node with this error.
            Err(DeleteError::NotDiscovered(_)) => return deleted,
            Err(e) => PruneAnswer::Refused(e.to_string()),
        };
        self.journal
            .record(rid.clone(), DryRunOutcome::Pruned(answer));
        deleted
    }
}

#[async_trait]
impl SecretHydrator for DryRun {
    async fn hydrate(&self, manifest: Value) -> Result<(Value, Vec<HydrationResult>), SecretError> {
        let rid = ResourceId::from_value(&manifest);
        let hydrated = self.secrets.hydrate(manifest).await;
        if let Err(e) = &hydrated {
            self.journal
                .record(rid, DryRunOutcome::Refused(Refusal::of_hydration(e)));
        }
        hydrated
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::discovery;
    use crate::cluster::fake_api::FakeApi;
    use crate::manifest::types::CLUSTER_SCOPED;
    use serde_json::json;

    async fn dry_run(api: &FakeApi) -> DryRun {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        DryRun::new(
            client,
            discovery,
            "a".into(),
            None,
            false,
            Default::default(),
        )
    }

    /// An apply of a kind the cluster does not serve is refused, and the
    /// refusal is kept as the object's answer.
    #[tokio::test]
    async fn an_apply_of_an_unknown_kind_is_kept_as_a_refusal() {
        let dry = dry_run(&FakeApi::new([])).await;
        let manifest = json!({
            "apiVersion": "example.com/v1",
            "kind": "Widget",
            "metadata": { "name": "w" },
        });
        assert!(dry.apply(&manifest).await.is_err());
        let answers = dry.take_answers();
        assert_eq!(answers.len(), 1);
        assert!(matches!(
            &answers[0].outcome,
            DryRunOutcome::Refused(Refusal::UnknownKind { kind }) if kind == "Widget"
        ));
    }

    /// A prune of a kind discovery lacks fails without an answer: the engine
    /// reports the failed node itself. One the guard lets through is
    /// answered.
    #[tokio::test]
    async fn a_prune_is_answered_only_when_it_reaches_the_apiserver() {
        let api = FakeApi::new([json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": { "name": "old" },
        })]);
        let dry = dry_run(&api).await;
        let rid = |kind: &str| ResourceId {
            kind: kind.into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "old".into(),
        };

        let err = dry.prune(&rid("Widget")).await.unwrap_err();
        assert!(matches!(err, DeleteError::NotDiscovered(_)), "{err}");
        assert!(dry.take_answers().is_empty());

        dry.prune(&rid("ClusterRole")).await.unwrap();
        let answers = dry.take_answers();
        assert_eq!(answers.len(), 1);
        assert!(matches!(
            &answers[0].outcome,
            DryRunOutcome::Pruned(PruneAnswer::Deleted)
        ));
    }
}
