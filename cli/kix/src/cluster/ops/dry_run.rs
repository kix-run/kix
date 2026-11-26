//! A dry run of a real cluster's [`ResourceIo`] and [`SecretHydrator`].

use std::time::Duration;

use chrono::{DateTime, Utc};

use async_trait::async_trait;
use kube::Client;
use kube::discovery::{ApiResource, Scope};
use serde_json::Value;

use crate::manifest::types::ResourceId;

use super::super::apply::{ApplyAction, ApplyError, ApplyResult};
use super::super::cancel::CancelToken;
use super::super::errors::FetchError;
use super::super::preview::{
    DeleteWait, DryRunAnswer, DryRunOutcome, Journal, PruneAnswer, Refusal,
};
use super::super::prune_guard::Pruned;
use super::super::readiness::{Deletion, ImportTarget, ReadinessError, ReadinessResult};
use super::super::secrets::{HydrationResult, SecretError};
use super::{
    DeleteError, KubeResources, OnStatus, ReadError, RecreateError, ResourceIo, SecretHydrator,
    SopsHydrator,
};
use crate::build_source::SopsSources;

/// Dry-run wrapper over [`KubeResources`] and [`SopsHydrator`].
///
/// Every write is sent with `dryRun=All` so nothing persists to the cluster,
/// and no Activation record is created. The [`Journal`] records what the
/// apiserver returned for each object: the previewed apply result, a recreate,
/// a prune outcome, or the typed refusal.
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
        force: super::resources::Force,
        sops: SopsSources,
    ) -> Self {
        DryRun {
            resources: KubeResources::dry_run(client, discovery, cluster, identity_hash, force),
            secrets: SopsHydrator::new(sops),
            journal: Journal::default(),
        }
    }

    /// Drain and return the recorded dry-run answers from the journal.
    pub(crate) fn take_answers(&self) -> Vec<DryRunAnswer> {
        self.journal.take()
    }
}

#[async_trait]
impl ResourceIo for DryRun {
    /// An object being deleted is previewed as a recreate: the deploy waits
    /// for it to be gone, then creates it.
    async fn apply(
        &self,
        manifest: &Value,
        _timeout: Duration,
        _cancel: &CancelToken,
        _on_status: OnStatus<'_>,
    ) -> Result<ApplyResult, ApplyError> {
        let rid = ResourceId::from_value(manifest);
        // A dry run creates no CRD, so discovery cannot gain a kind during
        // one and a cache miss is final.
        let Some((ar, scope)) = self.resources.cached(&rid).await else {
            let e = ApplyError::UnknownKind {
                kind: rid.kind.clone(),
            };
            self.journal
                .record(rid, DryRunOutcome::Refused(Refusal::of_apply(&e)));
            return Err(e);
        };
        let applied = self.resources.apply_as(&ar, scope.clone(), manifest).await;
        if let Err(ApplyError::BeingDeleted { .. }) = &applied {
            // The whole object, metadata included, which says what the
            // delete waits for.
            let live = self
                .resources
                .api_for(&ar, &scope, &rid)
                .get_opt(&rid.name)
                .await
                .ok()
                .flatten()
                .and_then(|o| serde_json::to_value(o).ok());
            self.journal.record(
                rid,
                DryRunOutcome::Recreated {
                    live,
                    result: None,
                    not_kept: Vec::new(),
                },
            );
            return Ok(ApplyResult {
                action: ApplyAction::Created,
                preview: None,
                not_kept: Vec::new(),
                applied_hash: None,
            });
        }
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

    async fn recreate_in_place(
        &self,
        manifest: &Value,
        _timeout: Duration,
        _cancel: &CancelToken,
    ) -> Result<ApplyResult, RecreateError> {
        let rid = ResourceId::from_value(manifest);
        let (ar, scope, api, _) = self.resources.delete_for_recreate(&rid).await?;

        // Because the dry-run delete does not remove the live object, the
        // subsequent dry-run apply still sees the old immutable fields and may
        // fail with a 422 immutable-field conflict. We still run the apply to
        // validate schema, admission, RBAC, and field ownership, and treat an
        // immutable-field conflict as a successful recreate preview.
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
                not_kept: result.not_kept.clone(),
            },
            Err(ApplyError::ImmutableConflict { .. }) => DryRunOutcome::Recreated {
                live: existing,
                result: None,
                not_kept: Vec::new(),
            },
            Err(e) => DryRunOutcome::Refused(Refusal::of_apply(e)),
        };
        self.journal.record(rid.clone(), outcome);
        match applied {
            Ok(result) => Ok(result),
            Err(ApplyError::ImmutableConflict { .. }) => Ok(ApplyResult {
                action: ApplyAction::Created,
                preview: None,
                not_kept: Vec::new(),
                applied_hash: None,
            }),
            Err(e) => Err(RecreateError::DryRunReapply(e)),
        }
    }

    async fn wait_ready(
        &self,
        rid: &ResourceId,
        import_target: Option<&ImportTarget>,
        applied_at: Option<DateTime<Utc>>,
        timeout: Duration,
        cancel: &CancelToken,
        on_status: OnStatus<'_>,
    ) -> Result<ReadinessResult, ReadinessError> {
        self.resources
            .wait_ready(rid, import_target, applied_at, timeout, cancel, on_status)
            .await
    }

    /// Do nothing because a dry run persists no CRDs.
    async fn rediscover(&self) -> Result<(), FetchError> {
        Ok(())
    }

    async fn prune(
        &self,
        rid: &ResourceId,
        propagation: kube::api::PropagationPolicy,
    ) -> Result<Pruned, DeleteError> {
        let deleted = self.resources.prune(rid, propagation).await;
        let answer = match &deleted {
            Ok(Pruned::Deleted { finalizers, .. }) => PruneAnswer::Deleted(DeleteWait {
                finalizers: finalizers.clone(),
                ..DeleteWait::default()
            }),
            Ok(Pruned::AlreadyDeleting {
                finalizers, since, ..
            }) => PruneAnswer::Deleted(DeleteWait {
                finalizers: finalizers.clone(),
                deleting_since: since.clone(),
                ..DeleteWait::default()
            }),
            Ok(Pruned::Gone | Pruned::NotServed) => PruneAnswer::Deleted(DeleteWait::default()),
            Ok(Pruned::Kept(shared)) => PruneAnswer::KeptShared(shared.describe()),
            Ok(Pruned::Changed(_)) => PruneAnswer::KeptChanged,
            // Skip recording an answer when the delete never reached the
            // apiserver. The engine reports the failed node with this error.
            Err(DeleteError::Discovery(_)) => return deleted,
            Err(e) => PruneAnswer::Refused(e.to_string()),
        };
        self.journal
            .record(rid.clone(), DryRunOutcome::Pruned(answer));
        deleted
    }

    /// Return at once, because a dry-run delete removes nothing.
    async fn wait_gone(
        &self,
        _rid: &ResourceId,
        _uid: Option<&str>,
        _timeout: Duration,
        _cancel: &CancelToken,
        _on_status: OnStatus<'_>,
    ) -> Result<Deletion, ReadError> {
        Ok(Deletion::Gone)
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
            super::super::resources::Force::None,
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
        assert!(
            dry.apply(
                &manifest,
                Duration::from_secs(1),
                &CancelToken::new(),
                &|_| {}
            )
            .await
            .is_err()
        );
        let answers = dry.take_answers();
        assert_eq!(answers.len(), 1);
        assert!(matches!(
            &answers[0].outcome,
            DryRunOutcome::Refused(Refusal::UnknownKind { kind }) if kind == "Widget"
        ));
    }

    /// An apply onto an object being deleted is answered as a recreate that
    /// keeps the whole live object, so the plan can say what its delete
    /// waits for. The deploy goes on.
    #[tokio::test]
    async fn an_object_being_deleted_is_answered_as_a_recreate() {
        let api = FakeApi::new([json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": "cm",
                "namespace": "app",
                "deletionTimestamp": "2026-11-24T15:54:00Z",
                "finalizers": ["example.com/hold"],
            },
        })]);
        let dry = dry_run(&api).await;
        let manifest = json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": { "name": "cm", "namespace": "app" },
        });
        let applied = dry
            .apply(
                &manifest,
                Duration::from_secs(1),
                &CancelToken::new(),
                &|_| {},
            )
            .await
            .unwrap();
        assert_eq!(applied.action, ApplyAction::Created);
        let answers = dry.take_answers();
        let [answer] = answers.as_slice() else {
            panic!("{answers:?}");
        };
        let DryRunOutcome::Recreated {
            live: Some(live),
            result: None,
            ..
        } = &answer.outcome
        else {
            panic!("{answer:?}");
        };
        assert_eq!(live["metadata"]["finalizers"], json!(["example.com/hold"]));
        assert!(live["metadata"]["deletionTimestamp"].is_string());
    }

    /// A prune of a kind the cluster does not serve is answered as a
    /// delete with nothing to wait for, as is one the guard lets through.
    #[tokio::test]
    async fn a_prune_of_a_kind_the_cluster_does_not_serve_is_answered() {
        let api = FakeApi::new([json!({
            "apiVersion": "rbac.authorization.k8s.io/v1",
            "kind": "ClusterRole",
            "metadata": { "name": "old" },
        })]);
        let dry = dry_run(&api).await;
        let rid = |kind: &str| ResourceId {
            group: "rbac.authorization.k8s.io".into(),
            kind: kind.into(),
            namespace: CLUSTER_SCOPED.into(),
            name: "old".into(),
        };

        assert_eq!(
            dry.prune(&rid("Widget"), kube::api::PropagationPolicy::Background)
                .await
                .unwrap(),
            Pruned::NotServed
        );
        let answers = dry.take_answers();
        assert!(matches!(
            &answers[..],
            [a] if matches!(&a.outcome, DryRunOutcome::Pruned(PruneAnswer::Deleted(_)))
        ));

        dry.prune(
            &rid("ClusterRole"),
            kube::api::PropagationPolicy::Background,
        )
        .await
        .unwrap();
        let answers = dry.take_answers();
        assert_eq!(answers.len(), 1);
        assert!(matches!(
            &answers[0].outcome,
            DryRunOutcome::Pruned(PruneAnswer::Deleted(_))
        ));
    }
}
