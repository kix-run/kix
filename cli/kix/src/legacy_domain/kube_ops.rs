//! The migration against a real apiserver.
//!
//! The only file in the compatibility layer that knows `kube::Api`, the way
//! `cluster::ops::kube` is for the deploy engine. Its counterpart is the
//! scripted fake in [`super::migrate`]'s tests.

use std::time::Duration;

use async_trait::async_trait;
use kube::{
    api::{Api, DeleteParams, DynamicObject, ListParams, Patch, PatchParams, PostParams},
    client::Client,
    core::GroupVersionKind,
    discovery::ApiResource,
};
use serde_json::{Value, json};

use super::migrate::{MigrationOps, RecordKind};

/// How long to wait for a CRD to appear in, or disappear from, discovery.
const CRD_SETTLE_TIMEOUT: Duration = Duration::from_secs(60);

/// How often to poll while waiting.
const CRD_POLL_INTERVAL: Duration = Duration::from_millis(500);

/// How long to wait between clearing the operator's finalizers and reading
/// them back. Clearing one is a change to the record, so an operator that is
/// watching reconciles on the event rather than on a timer and puts its
/// finalizer back in about a second. This is long enough to be sure, and
/// short enough that a migration on a cluster with no operator, where it is
/// pure cost, stays quick.
const OPERATOR_PROBE_WAIT: Duration = Duration::from_secs(15);

/// Field manager for the records the migration creates, so `managedFields`
/// attributes them to the migration rather than to a deploy.
const FIELD_MANAGER: &str = "kix-migrate-domain";

/// Field manager for the two CRDs. Deliberately the one `kix deploy` uses:
/// the deploy that follows applies the same two CRDs, and a different
/// manager here would make that apply a conflict the moment the schema
/// changes under a newer pin.
const CRD_FIELD_MANAGER: &str = "kix";

/// The version of Kix's own records. Not part of the domain: the move keeps
/// the schema and the version, and changes only the group.
const RECORD_VERSION: &str = "v1alpha1";

/// `MigrationOps` against a cluster.
pub struct KubeMigrationOps {
    client: Client,
}

impl KubeMigrationOps {
    pub fn new(client: Client) -> Self {
        Self { client }
    }

    /// The CustomResourceDefinition API.
    fn crds(&self) -> Api<k8s_openapi::apiextensions_apiserver::pkg::apis::apiextensions::v1::CustomResourceDefinition>
    {
        Api::all(self.client.clone())
    }

    /// A dynamic API for one record kind in one group.
    ///
    /// Built by hand rather than from discovery: during the migration both
    /// groups can be registered, and discovery lookup is first-kind-wins, so
    /// it cannot say which `Activation` a caller meant.
    ///
    /// The handle spans all namespaces, which is what listing wants and is
    /// valid for a namespaced kind. Writing through it is only correct for a
    /// cluster-scoped kind, so every write below calls [`Self::writable`]
    /// first rather than trusting the caller.
    fn records(&self, group: &str, record: RecordKind) -> Api<DynamicObject> {
        let gvk = GroupVersionKind::gvk(group, RECORD_VERSION, record.kind);
        let ar = ApiResource::from_gvk_with_plural(&gvk, record.plural);
        Api::all_with(self.client.clone(), &ar)
    }

    /// The same handle, for a write.
    ///
    /// `Api::all_with` addresses the cluster-scoped endpoint. For a
    /// namespaced kind that is right for a LIST and wrong for a POST, which
    /// would 404 against a URL with no namespace. Today only the
    /// cluster-scoped Activation is written, and this turns a future caller's
    /// mistake into a clear error instead of a confusing 404.
    fn writable(&self, group: &str, record: RecordKind) -> Result<Api<DynamicObject>, String> {
        if !record.cluster_scoped {
            return Err(format!(
                "{} is namespaced; the migration only writes cluster-scoped records",
                record.kind
            ));
        }
        Ok(self.records(group, record))
    }

    /// Poll until `check` holds, or give up.
    async fn settle<F, Fut>(&self, what: &str, check: F) -> Result<(), String>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<bool, String>>,
    {
        let deadline = std::time::Instant::now() + CRD_SETTLE_TIMEOUT;
        loop {
            if check().await? {
                return Ok(());
            }
            if std::time::Instant::now() >= deadline {
                return Err(format!(
                    "{what} did not settle within {}s. Run the migration again once the \
                     apiserver is healthy: it skips what is already done. Note that a \
                     delete already sent is still in flight, so this does not mean the \
                     object is still there.",
                    CRD_SETTLE_TIMEOUT.as_secs()
                ));
            }
            tokio::time::sleep(CRD_POLL_INTERVAL).await;
        }
    }
}

#[async_trait]
impl MigrationOps for KubeMigrationOps {
    async fn pause_for_operator(&self) {
        tokio::time::sleep(OPERATOR_PROBE_WAIT).await;
    }

    async fn crd_exists(&self, name: &str) -> Result<bool, String> {
        match self.crds().get_opt(name).await {
            Ok(found) => Ok(found.is_some()),
            Err(e) => Err(format!(
                "could not read CustomResourceDefinition {name}: {e}"
            )),
        }
    }

    async fn list_records(&self, group: &str, record: RecordKind) -> Result<Vec<Value>, String> {
        let list = self
            .records(group, record)
            .list(&ListParams::default())
            .await
            .map_err(|e| format!("could not list {} in {group}: {e}", record.plural))?;
        list.items
            .into_iter()
            .map(|o| {
                serde_json::to_value(&o)
                    .map_err(|e| format!("could not read a {} record: {e}", record.kind))
            })
            .collect()
    }

    async fn apply_crd(&self, manifest: &Value) -> Result<(), String> {
        let name = manifest
            .pointer("/metadata/name")
            .and_then(Value::as_str)
            .ok_or_else(|| "a CustomResourceDefinition manifest has no name".to_string())?;
        let pp = PatchParams::apply(CRD_FIELD_MANAGER);
        self.crds()
            .patch(name, &pp, &Patch::Apply(manifest))
            .await
            .map_err(|e| format!("could not apply CustomResourceDefinition {name}: {e}"))?;
        Ok(())
    }

    async fn await_crd(&self, name: &str) -> Result<(), String> {
        self.settle(&format!("CustomResourceDefinition {name}"), || async {
            let Some(crd) = self
                .crds()
                .get_opt(name)
                .await
                .map_err(|e| format!("could not read CustomResourceDefinition {name}: {e}"))?
            else {
                return Ok(false);
            };
            // Established means the apiserver is serving the kind.
            Ok(crd
                .status
                .as_ref()
                .and_then(|s| s.conditions.as_ref())
                .is_some_and(|cs| {
                    cs.iter()
                        .any(|c| c.type_ == "Established" && c.status == "True")
                }))
        })
        .await
    }

    async fn create_record(
        &self,
        group: &str,
        record: RecordKind,
        manifest: &Value,
    ) -> Result<(), String> {
        let object: DynamicObject = serde_json::from_value(manifest.clone())
            .map_err(|e| format!("could not build a {} record: {e}", record.kind))?;
        let name = object.metadata.name.clone().unwrap_or_default();
        self.writable(group, record)?
            .create(&PostParams::default(), &object)
            .await
            .map_err(|e| format!("could not create {} {name} in {group}: {e}", record.kind))?;
        Ok(())
    }

    async fn set_record_status(
        &self,
        group: &str,
        record: RecordKind,
        name: &str,
        status: &Value,
    ) -> Result<(), String> {
        let pp = PatchParams {
            field_manager: Some(FIELD_MANAGER.to_string()),
            ..PatchParams::default()
        };
        self.writable(group, record)?
            .patch_status(name, &pp, &Patch::Merge(&json!({ "status": status })))
            .await
            .map_err(|e| format!("could not write the status of {} {name}: {e}", record.kind))?;
        Ok(())
    }

    async fn strip_finalizer(
        &self,
        group: &str,
        record: RecordKind,
        name: &str,
        finalizer: &str,
    ) -> Result<(), String> {
        let api = self.writable(group, record)?;
        let Some(object) = api
            .get_opt(name)
            .await
            .map_err(|e| format!("could not read {} {name}: {e}", record.kind))?
        else {
            return Ok(());
        };
        let remaining: Vec<String> = object
            .metadata
            .finalizers
            .unwrap_or_default()
            .into_iter()
            .filter(|f| f != finalizer)
            .collect();
        // A merge patch sends the whole list, so this both removes the one
        // finalizer and leaves any other controller's finalizer in place.
        let pp = PatchParams {
            field_manager: Some(FIELD_MANAGER.to_string()),
            ..PatchParams::default()
        };
        api.patch(
            name,
            &pp,
            &Patch::Merge(&json!({ "metadata": { "finalizers": remaining } })),
        )
        .await
        .map_err(|e| {
            format!(
                "could not clear the finalizer on {} {name}: {e}",
                record.kind
            )
        })?;
        Ok(())
    }

    async fn delete_crd(&self, name: &str) -> Result<(), String> {
        match self.crds().delete(name, &DeleteParams::default()).await {
            Ok(_) => Ok(()),
            // Already gone is the outcome we wanted.
            Err(kube::Error::Api(e)) if e.code == 404 => Ok(()),
            Err(e) => Err(format!(
                "could not delete CustomResourceDefinition {name}: {e}"
            )),
        }
    }

    async fn await_crd_gone(&self, name: &str) -> Result<(), String> {
        self.settle(
            &format!("the deletion of CustomResourceDefinition {name}"),
            || async { Ok(!self.crd_exists(name).await?) },
        )
        .await
    }
}
