//! [`DeployRecord`] on a real cluster's Activation records.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;

use std::collections::HashSet;

use crate::manifest::types::ResourceId;

use super::super::activation::{KeptOrphans, Record, Records, WaveRecord, WaveStatus};
use super::super::revision::{
    Revision, RevisionMap, RevisionObject, RevisionSet, RevisionSpec, Revisions, Slot, applied,
    keep,
};
use super::{DeployRecord, Finalized, KubeResources, Left, RecordWriteError};

/// Timeout for best-effort writes (checkpoint and finalize). These writes run
/// on their own tasks so a slow write does not block the scheduler, and this
/// bound caps how long the end of the run waits for the final checkpoint and
/// finalize.
const BEST_EFFORT_TIMEOUT: Duration = Duration::from_secs(30);

/// What a run writes to its Activation record, beyond the cluster and the
/// identity hash its [`KubeResources`] carry.
pub(crate) struct RecordConfig {
    /// The record's name, or `None` when the run writes no lifecycle (such as
    /// the operator correcting drift).
    pub(crate) name: Option<String>,
    /// The record's own stamped manifest, so [`DeployRecord::begin`] can
    /// create it before the first node instead of waiting for it to run as the
    /// last node of the plan.
    ///
    /// Both places apply the same manifest with the same field manager and
    /// identity hash, so the final node's apply is a no-op that re-asserts
    /// `spec` once its dependencies are Ready. `None` for the operator, which
    /// created the record itself and owns `spec.source`.
    pub(crate) manifest: Option<Value>,
    /// Provenance to record on the Activation when the deploy finishes. The
    /// CLI computes this from the source tree, whereas the operator leaves it
    /// `None`.
    pub(crate) receipt: Option<Value>,
    /// Failed records whose leftovers this run's plan folded in. Superseded
    /// on finalize, because by then they describe nothing outstanding.
    pub(crate) consumed_failed: Vec<String>,
    /// What the run's kept-orphans revision names besides the orphans the
    /// run leaves on the cluster.
    pub(crate) kept_orphans: KeptOrphans,
    /// The orphans the plan found on a Kix cluster an older Kix deployed
    /// last, which [`DeployRecord::begin`] names in a kept-orphans revision
    /// before the run removes the notes that name them. A run that stops
    /// then leaves a record that names them. `None` for any other run.
    pub(crate) kept_at_begin: Option<Vec<RevisionObject>>,
    /// The revisions of the build the run deploys. [`DeployRecord::begin`]
    /// creates them and then names them in the record's `status.revisions`,
    /// and
    /// [`DeployRecord::finalize`] adds the kept orphans. `None` for a run
    /// that writes no record, such as the operator correcting drift.
    pub(crate) revisions: Option<RevisionSet>,
    /// The instances (`namespace/instance`) a deploy with `--only` selected,
    /// which [`DeployRecord::end_partial`] writes to `status.partial`. Empty
    /// for a run of the whole build.
    pub(crate) only: Vec<String>,
    /// Whether [`DeployRecord::abort`] should mark the record Failed.
    ///
    /// True for the CLI, which owns the run end to end. False for the
    /// operator, which retries a run that stopped and marks the record
    /// Failed itself once it stops retrying.
    pub(crate) mark_failed_on_abort: bool,
    /// The run's deploy lock. [`DeployRecord::finalize`] commits the deploy
    /// on it between writing the record's result and setting the phases,
    /// and [`DeployRecord::before_prune`] renews it. `None` only in tests.
    pub(crate) lock: Option<Arc<crate::cluster::head::Lock>>,
}

/// A run's Activation record, written through
/// [`super::super::activation::Records`].
pub(crate) struct ActivationRecord {
    /// The objects of the same run. The record is applied through them.
    resources: Arc<KubeResources>,
    config: RecordConfig,
    /// The instances that earlier deploys with `--only` of the same build
    /// applied, read from the record's `status.partial` when the run began.
    /// [`DeployRecord::end_partial`] adds them to this run's.
    earlier_only: std::sync::Mutex<Vec<String>>,
    /// Whether [`DeployRecord::write_applied`] has carried the old
    /// revisions' hashes into the run's revisions.
    carried: std::sync::atomic::AtomicBool,
}

impl ActivationRecord {
    pub(super) fn new(resources: Arc<KubeResources>, config: RecordConfig) -> Self {
        ActivationRecord {
            resources,
            config,
            earlier_only: std::sync::Mutex::new(Vec::new()),
            carried: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Open the `Activation` records API for optional writes, logging a
    /// domain-gate error and returning `None` when the gate refuses.
    async fn logged_records(&self) -> Option<Records> {
        self.resources
            .records()
            .await
            .inspect_err(|e| tracing::error!("{e}"))
            .ok()
    }

    /// Return the configured record name and `Records` handle, or `None` when
    /// lifecycle recording is disabled. Propagates domain-gate errors so a
    /// cluster with retired records does not finalize as if it had none.
    async fn named_records(&self) -> Result<Option<(&str, Records)>, RecordWriteError> {
        let Some(name) = self.config.name.as_deref() else {
            return Ok(None);
        };
        let records = self
            .resources
            .records()
            .await
            .map_err(RecordWriteError::Domain)?;
        Ok(Some((name, records)))
    }

    /// Create the Activation record `name` from the run's manifest. The
    /// apply uses the same path as the plan's own node, so field manager,
    /// identity hash, and annotation stamping all match and the later apply
    /// is an unchanged no-op. Only the CLI provides a manifest. The operator
    /// deploys a record that exists.
    async fn create_record(&self, name: &str, records: &Records) -> Result<(), RecordWriteError> {
        let Some(manifest) = self.config.manifest.as_ref() else {
            return Ok(());
        };
        self.resources
            .apply_as(
                records.watch_resource(),
                kube::discovery::Scope::Cluster,
                manifest,
            )
            .await
            .map(|_| ())
            .map_err(|source| RecordWriteError::Create {
                name: name.to_string(),
                source,
            })
    }

    /// Create every revision the record names. A revision that exists
    /// already counts as created, because its name is a hash of its
    /// contents. A run that writes no record creates none.
    ///
    /// Every run sends the creates, so a run that takes over or continues a
    /// record creates what an earlier run of it did not.
    ///
    /// A revision that exists and that no record of `records` names was left
    /// by a run that stopped, or by a cleanup that failed. Its
    /// `status.applied` describes that run's objects, so it is cleared.
    async fn create_revisions(&self, records: &Records) -> Result<(), RecordWriteError> {
        let (Some(_), Some(set)) = (&self.config.name, &self.config.revisions) else {
            return Ok(());
        };
        let store = Revisions::new(self.resources.client());
        let store = &store;
        let created = futures::future::try_join_all(set.all().map(|revision| async move {
            Ok::<_, super::super::revision::RevisionError>((
                revision,
                store.create(revision).await?,
            ))
        }))
        .await
        .map_err(RecordWriteError::Revisions)?;
        let existing: Vec<&Revision> = created
            .into_iter()
            .filter(|(_, c)| *c == super::super::revision::Created::Exists)
            .map(|(r, _)| r)
            .collect();
        if existing.is_empty() {
            return Ok(());
        }
        let named = keep::named_by(
            &records
                .of_cluster(self.resources.cluster())
                .await
                .map_err(RecordWriteError::Records)?,
        );
        for revision in existing.into_iter().filter(|r| !named.contains(&r.name)) {
            store
                .clear_applied(&revision.name)
                .await
                .map_err(RecordWriteError::Revisions)?;
        }
        Ok(())
    }

    /// Create the kept-orphans revision of [`RecordConfig::kept_at_begin`]
    /// and return its name, or `None` when there is none.
    async fn create_kept_at_begin(&self) -> Result<Option<String>, RecordWriteError> {
        let (Some(set), Some(objects)) = (&self.config.revisions, &self.config.kept_at_begin)
        else {
            return Ok(None);
        };
        if objects.is_empty() {
            return Ok(None);
        }
        let revision = Revision::new(RevisionSpec::new(
            set.cluster(),
            Slot::KeptOrphans,
            objects.clone(),
        ));
        Revisions::new(self.resources.client())
            .create(&revision)
            .await
            .map_err(|e| RecordWriteError::KeptOrphans(e.to_string()))?;
        Ok(Some(revision.name))
    }

    /// Create the kept-orphans revision of a finished deploy and return its
    /// name, or `None` when the deploy left nothing or the run names no
    /// revisions.
    ///
    /// It lists the orphans the run left, as the manifests they came from
    /// describe them. When the plan did not read the cluster (`--offline`),
    /// it also carries forward the objects of `current`'s kept-orphans
    /// revision unexamined. Refuse when that revision cannot be read, or the
    /// new one cannot be created, because the finalize that follows deletes
    /// the old one and the list would be lost.
    async fn write_kept_orphans(
        &self,
        current: Option<&Record>,
        left: Left<'_>,
    ) -> Result<Option<String>, RecordWriteError> {
        let Some(set) = self.config.revisions.as_ref() else {
            return Ok(None);
        };
        let store = Revisions::new(self.resources.client());
        let wanted: HashSet<&ResourceId> = left.orphans.iter().chain(left.never_pruned).collect();
        let mut objects: Vec<RevisionObject> = left
            .manifests
            .iter()
            .filter(|m| wanted.contains(&ResourceId::from_value(m)))
            .filter_map(RevisionObject::of_manifest)
            .collect();
        let kept = &self.config.kept_orphans;
        objects.extend(kept.unknown.iter().cloned());
        if kept.carry_current {
            let earlier = match current.and_then(|c| c.revisions.as_ref()) {
                None => None,
                Some(Ok(map)) => map.kept_orphans.as_deref(),
                Some(Err(e)) => {
                    let record = current.map_or("", |c| c.name.as_str());
                    return Err(RecordWriteError::KeptOrphans(format!(
                        "the current deployment record `{record}` cannot be read: {e}"
                    )));
                }
            };
            if let Some(earlier) = earlier {
                let revision = store
                    .get(earlier)
                    .await
                    .map_err(|e| RecordWriteError::KeptOrphans(e.to_string()))?
                    .ok_or_else(|| {
                        RecordWriteError::KeptOrphans(format!(
                            "the current deployment record names kept-orphans revision `{earlier}`, which is missing"
                        ))
                    })?;
                objects.extend(revision.spec.objects);
            }
        }
        if objects.is_empty() {
            return Ok(None);
        }
        let revision = Revision::new(RevisionSpec::new(set.cluster(), Slot::KeptOrphans, objects));
        store
            .create(&revision)
            .await
            .map_err(|e| RecordWriteError::KeptOrphans(e.to_string()))?;
        Ok(Some(revision.name))
    }

    /// Return each revision the record names that replaces the revision of
    /// the same instance, or of the cluster level, that `current` names,
    /// paired as `(old, new)`. Read both from `listed` when they are there,
    /// so the pairs carry the hashes already written.
    fn replaced<'a>(
        &'a self,
        current: Option<&Record>,
        listed: &'a [Revision],
    ) -> Vec<(&'a Revision, &'a Revision)> {
        let (Some(set), Some(Ok(old_map))) = (
            self.config.revisions.as_ref(),
            current.and_then(|c| c.revisions.as_ref()),
        ) else {
            return Vec::new();
        };
        let find = |name: &str| listed.iter().find(|r| r.name == name);
        let instances = set
            .instances
            .iter()
            .map(|(key, new)| (old_map.instances.get(key), new));
        let cluster_level = std::iter::once((Some(&old_map.cluster_level), &set.cluster_level));
        instances
            .chain(cluster_level)
            .filter_map(|(old, new)| {
                let old = find(old.filter(|o| **o != new.name)?)?;
                Some((old, find(&new.name).unwrap_or(new)))
            })
            .collect()
    }

    /// Delete the revisions no record needs any more, under the run's lock.
    /// The deploy is already current, so a failure only warns, and the next
    /// cleanup deletes them.
    async fn clean_revisions(&self, records: &Records) {
        if self.config.lock.is_none() {
            return;
        }
        let cluster = self.resources.cluster();
        let clean = keep::clean(self.resources.client(), records, cluster);
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, clean).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                tracing::warn!(error = %e, "could not delete the revisions no record needs; the next deploy or `kix gc` deletes them")
            }
            Err(_) => tracing::warn!(
                "deleting the revisions no record needs did not finish in time; the next deploy or `kix gc` deletes them"
            ),
        }
    }
}

#[async_trait]
impl DeployRecord for ActivationRecord {
    async fn begin(&self) -> Result<(), RecordWriteError> {
        // A run with a record to write cannot write it on a cluster whose
        // records sit under a retired group, so it stops before applying.
        let records = match self.config.name {
            Some(_) => self
                .resources
                .records()
                .await
                .map_err(RecordWriteError::Domain)?,
            None => match self.logged_records().await {
                Some(records) => records,
                None => return Ok(()),
            },
        };

        let Some(name) = self.config.name.as_deref() else {
            return Ok(());
        };
        // Create the revisions before the write that names them, so a record
        // names only revisions that exist. A failure stops the run before
        // anything is applied, and leaves the record as it was.
        self.create_record(name, &records).await?;
        self.create_revisions(&records).await?;
        let kept = self.create_kept_at_begin().await?;
        let map = self.config.revisions.as_ref().map(|set| RevisionMap {
            kept_orphans: kept,
            ..RevisionMap::of(set)
        });
        let earlier = records
            .begin_deploy(name, self.resources.cluster(), 1, map.as_ref())
            .await
            .map_err(RecordWriteError::Records)?;
        if let Ok(mut guard) = self.earlier_only.lock() {
            *guard = earlier;
        }
        Ok(())
    }

    async fn checkpoint(
        &self,
        applied: usize,
        failed: usize,
        finalizing: bool,
    ) -> Result<(), RecordWriteError> {
        let Some((name, records)) = self.named_records().await? else {
            return Ok(());
        };
        // Record progress as a single synthetic wave to provide a liveness
        // pulse on the Activation status. The final checkpoint marks the
        // wave Failed when any object in it failed.
        let status = match (finalizing, failed) {
            (false, _) => WaveStatus::Pending,
            (true, 0) => WaveStatus::Complete,
            (true, _) => WaveStatus::Failed,
        };
        let record = WaveRecord {
            wave_index: 0,
            status,
            resource_count: applied + failed,
            applied,
            failed,
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, records.record_waves(name, &[record])).await
        {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(RecordWriteError::Records(e)),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }

    async fn write_applied(&self) -> Result<(), RecordWriteError> {
        let applied = self.resources.take_applied();
        // A run that names revisions carries the old revisions' hashes into
        // them once, even when it applied nothing.
        let carry = self.config.name.is_some()
            && self.config.revisions.is_some()
            && !self.carried.swap(true, std::sync::atomic::Ordering::SeqCst);
        if applied.is_empty() && !carry {
            return Ok(());
        }
        let records = self
            .resources
            .records()
            .await
            .map_err(RecordWriteError::Domain)?;
        let client = self.resources.client();
        let work = async {
            let state = keep::State::read(client, &records, self.resources.cluster()).await?;
            // A record whose map this Kix cannot read names revisions it
            // cannot see, which then get no hashes. The others still do.
            let needed = state.needed_readable();
            let listed = &state.revisions.readable;
            let kept: Vec<&Revision> = listed.iter().filter(|r| needed.contains(&r.name)).collect();
            let replaced = self.replaced(state.current(), listed);
            let writes = applied::pending(&applied, &kept, &replaced);
            let store = Revisions::new(client);
            futures::future::try_join_all(
                writes
                    .iter()
                    .map(|(name, entries)| store.write_applied(name, entries)),
            )
            .await?;
            Ok::<_, keep::CleanError>(())
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, work).await {
            Ok(result) => result.map_err(RecordWriteError::Applied),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }

    async fn abort(&self, reason: &str) -> Result<(), RecordWriteError> {
        if !self.config.mark_failed_on_abort {
            return Ok(());
        }
        let Some((name, records)) = self.named_records().await? else {
            return Ok(());
        };
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, records.fail_deploy(name, reason)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(RecordWriteError::Records(e)),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }

    async fn before_prune(&self) -> Result<(), RecordWriteError> {
        match &self.config.lock {
            Some(lock) => lock.renew().await.map_err(RecordWriteError::Lock),
            None => Ok(()),
        }
    }

    async fn end_partial(&self) -> Result<(), RecordWriteError> {
        let Some((name, records)) = self.named_records().await? else {
            return Ok(());
        };
        let mut only = self
            .earlier_only
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        only.extend(self.config.only.iter().cloned());
        match tokio::time::timeout(BEST_EFFORT_TIMEOUT, records.end_partial(name, &only)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(RecordWriteError::Records(e)),
            Err(_) => Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        }
    }

    async fn finalize(
        &self,
        had_failures: bool,
        left: Left<'_>,
    ) -> Result<Option<Finalized>, RecordWriteError> {
        let Some((name, records)) = self.named_records().await? else {
            return Ok(None);
        };
        let cluster = self.resources.cluster();
        let work = async {
            let current = records
                .active(cluster)
                .await
                .map_err(RecordWriteError::Records)?;
            let map = match &self.config.revisions {
                Some(set) => Some(RevisionMap {
                    kept_orphans: self.write_kept_orphans(current.as_ref(), left).await?,
                    ..RevisionMap::of(set)
                }),
                None => None,
            };
            let old = current.filter(|old| old.name != name);
            records
                .record_finish(
                    cluster,
                    name,
                    old.as_ref(),
                    self.config.receipt.as_ref(),
                    map.as_ref(),
                )
                .await
                .map_err(RecordWriteError::Records)?;
            // The one point at which the deploy becomes current. A run that
            // stops after it leaves phases the next run repairs from the head.
            if let Some(lock) = &self.config.lock {
                lock.commit(name).await.map_err(RecordWriteError::Commit)?;
            }
            records
                .settle_phases(
                    name,
                    old.as_ref(),
                    had_failures,
                    &self.config.consumed_failed,
                )
                .await
                .map_err(RecordWriteError::Records)?;
            Ok::<_, RecordWriteError>(Finalized {
                activation: name.to_string(),
                previous: old.map(|a| a.name),
            })
        };
        let finalized = match tokio::time::timeout(BEST_EFFORT_TIMEOUT, work).await {
            Ok(result) => result?,
            Err(_) => return Err(RecordWriteError::NoAnswer(BEST_EFFORT_TIMEOUT)),
        };
        self.clean_revisions(&records).await;
        Ok(Some(finalized))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::discovery;
    use crate::cluster::fake_api::FakeApi;

    const NONE_LEFT: Left<'static> = Left {
        orphans: &[],
        never_pruned: &[],
        manifests: &[],
    };

    async fn record(api: &FakeApi, name: Option<&str>) -> ActivationRecord {
        record_with_only(api, name, Vec::new()).await
    }

    async fn record_with_only(
        api: &FakeApi,
        name: Option<&str>,
        only: Vec<String>,
    ) -> ActivationRecord {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        ActivationRecord::new(
            Arc::new(KubeResources::new(
                client,
                discovery,
                "a".into(),
                None,
                crate::cluster::ops::Force::None,
            )),
            RecordConfig {
                name: name.map(str::to_string),
                manifest: None,
                receipt: None,
                consumed_failed: Vec::new(),
                kept_orphans: KeptOrphans::default(),
                kept_at_begin: None,
                revisions: None,
                only,
                mark_failed_on_abort: true,
                lock: None,
            },
        )
    }

    /// On a cluster whose records sit under a retired group, a run with a
    /// record to write fails its begin, checkpoint, abort, and finalize with
    /// the gate's refusal instead of finalizing as if there were no record. A
    /// run that writes no lifecycle is not affected.
    #[tokio::test]
    async fn the_domain_gate_fails_the_record_writes() {
        let api = FakeApi::new([]);
        api.serve_retired_records();
        let named = record(&api, Some("act")).await;
        for err in [
            named.begin().await.unwrap_err(),
            named.checkpoint(1, 0, false).await.unwrap_err(),
            named.abort("stopped").await.unwrap_err(),
            named.finalize(false, NONE_LEFT).await.unwrap_err(),
        ] {
            assert!(matches!(err, RecordWriteError::Domain(_)), "{err}");
            assert!(err.to_string().contains("kix migrate domain"), "{err}");
        }

        let unnamed = record(&api, None).await;
        assert!(unnamed.begin().await.is_ok());
        assert!(unnamed.checkpoint(1, 0, false).await.is_ok());
        assert!(unnamed.finalize(false, NONE_LEFT).await.unwrap().is_none());
    }

    /// Finalizing a deploy supersedes the cluster's current record and links
    /// the new record to it. `kix deploy` and the operator both finalize
    /// here, so the current record stays current until then. With no
    /// current record, the new one has no predecessor.
    #[tokio::test]
    async fn finalizing_supersedes_the_current_record_and_links_it() {
        use crate::manifest::keys;
        let rec = |name: &str, phase: &str| {
            serde_json::json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": name,
                    "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
                    "annotations": { (keys::IDENTITY_HASH): format!("h-{name}") },
                },
                "status": { "phase": phase },
            })
        };
        let api = FakeApi::new([rec("old", "Active"), rec("new", "Deploying")]);
        let finalized = record(&api, Some("new"))
            .await
            .finalize(false, NONE_LEFT)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(finalized.previous.as_deref(), Some("old"));
        assert_eq!(
            api.object("Activation", "old").unwrap()["status"]["phase"],
            "Superseded"
        );
        let new = api.object("Activation", "new").unwrap();
        assert_eq!(new["status"]["phase"], "Active");
        assert_eq!(new["status"]["previousActivation"], "old");
        assert_eq!(new["metadata"]["annotations"][keys::PREVIOUS], "h-old");

        let api = FakeApi::new([rec("old", "Superseded"), rec("new", "Deploying")]);
        let finalized = record(&api, Some("new"))
            .await
            .finalize(false, NONE_LEFT)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(finalized.previous, None);
        let new = api.object("Activation", "new").unwrap();
        assert_eq!(new["status"]["phase"], "Active");
        assert!(new["status"].get("previousActivation").is_none(), "{new}");
    }

    /// Under the deploy lock, finalize writes the record's result, then
    /// commits the deploy on the lock (current, generation, writer), then
    /// sets the phases. The lock stays held for the caller to release.
    #[tokio::test]
    async fn finalizing_commits_on_the_lock_between_result_and_phases() {
        use crate::cluster::head::{self, Holder, Purpose};
        use crate::manifest::keys;
        let rec = |name: &str, phase: &str| {
            serde_json::json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": name,
                    "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
                },
                "status": { "phase": phase },
            })
        };
        let api = FakeApi::new([rec("old", "Active"), rec("new", "Deploying")]);
        let client = api.client();
        let lock = Arc::new(
            head::take(
                &client,
                head::Request {
                    cluster: "a".into(),
                    holder: Holder::cli("kix deploy"),
                    purpose: Purpose::Deploy,
                    activation: Some("new".into()),
                    expect: Some(0),
                },
                head::system_clock(),
                &|_| {},
            )
            .await
            .unwrap(),
        );
        let mut run = record(&api, Some("new")).await;
        run.config.lock = Some(lock.clone());
        let finalized = run.finalize(false, NONE_LEFT).await.unwrap().unwrap();
        assert_eq!(finalized.previous.as_deref(), Some("old"));
        let head_status = |api: &FakeApi| api.object(head::KIND, "a").unwrap()["status"].clone();
        let status = head_status(&api);
        assert_eq!(status["current"], "new");
        assert_eq!(status["generation"], 1);
        assert_eq!(status["writer"]["program"], "cli");
        assert!(
            status["lock"].is_object(),
            "held until the caller releases it"
        );
        assert_eq!(
            api.object("Activation", "new").unwrap()["status"]["phase"],
            "Active"
        );
        assert_eq!(
            api.object("Activation", "old").unwrap()["status"]["phase"],
            "Superseded"
        );
        lock.release().await.unwrap();
        assert!(head_status(&api).get("lock").is_none());
        assert_eq!(head_status(&api)["generation"], 1);
    }

    /// The final checkpoint of a run in which an object failed marks the
    /// wave Failed, so `kix deploy --operator` does not print it as
    /// Complete. A run with no failure still ends Complete, and a
    /// checkpoint before the end stays Pending.
    #[tokio::test]
    async fn the_final_checkpoint_marks_a_wave_with_failures_failed() {
        let api = FakeApi::new([serde_json::json!({
            "apiVersion": crate::manifest::keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "act" },
            "status": { "phase": "Deploying" },
        })]);
        let named = record(&api, Some("act")).await;
        let wave =
            |api: &FakeApi| api.object("Activation", "act").unwrap()["status"]["waves"][0].clone();
        named.checkpoint(0, 1, false).await.unwrap();
        assert_eq!(wave(&api)["status"], "Pending");
        named.checkpoint(0, 1, true).await.unwrap();
        assert_eq!(
            wave(&api),
            serde_json::json!({ "wave": 0, "status": "Failed", "resources": 1, "applied": 0, "failed": 1 })
        );
        named.checkpoint(2, 0, true).await.unwrap();
        assert_eq!(wave(&api)["status"], "Complete");
    }

    /// A second deploy with `--only` of a Partial record's build clears
    /// `status.partial` while it runs, and ends `Partial` again with the
    /// instances of both deploys.
    #[tokio::test]
    async fn a_second_partial_run_adds_its_instances_to_the_first() {
        let api = FakeApi::new([serde_json::json!({
            "apiVersion": crate::manifest::keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "act" },
            "status": {
                "phase": "Partial",
                "partial": { "only": ["app/a"], "at": "2026-11-25T10:00:00Z" },
            },
        })]);
        let status = |api: &FakeApi| api.object("Activation", "act").unwrap()["status"].clone();
        let run = record_with_only(&api, Some("act"), vec!["web/b".into()]).await;
        run.begin().await.unwrap();
        let during = status(&api);
        assert_eq!(during["phase"], "Deploying");
        assert!(during.get("partial").is_none(), "{during}");
        run.end_partial().await.unwrap();
        let after = status(&api);
        assert_eq!(after["phase"], "Partial");
        assert_eq!(
            after["partial"]["only"],
            serde_json::json!(["app/a", "web/b"])
        );
    }

    mod revisions {
        use super::*;
        use crate::cluster::head::{self, Holder, Purpose};
        use crate::cluster::revision::{self, Created};
        use crate::manifest::keys;
        use serde_json::{Value, json};
        use std::collections::BTreeMap;

        fn object(hash: &str, ns: &str, name: &str) -> RevisionObject {
            RevisionObject {
                hash: format!("{hash:a>32}"),
                group: String::new(),
                kind: "ConfigMap".into(),
                namespace: Some(ns.into()),
                name: name.into(),
            }
        }

        fn instance(ns: &str, name: &str, hash: &str) -> Revision {
            Revision::new(RevisionSpec::new(
                "a",
                Slot::Instance {
                    namespace: ns.into(),
                    name: name.into(),
                },
                vec![object(hash, ns, name)],
            ))
        }

        /// The revisions of a build whose `app/web` instance has the object
        /// hash `web`. `data/db` and the cluster level never change.
        fn build(web: &str) -> RevisionSet {
            RevisionSet {
                instances: BTreeMap::from([
                    ("app/web".to_string(), instance("app", "web", web)),
                    ("data/db".to_string(), instance("data", "db", "d")),
                ]),
                cluster_level: Revision::new(RevisionSpec::new(
                    "a",
                    Slot::ClusterLevel,
                    vec![object("e", "app", "shared")],
                )),
            }
        }

        fn activation(name: &str, phase: &str, map: Option<&RevisionMap>) -> Value {
            let mut status = json!({ "phase": phase });
            if let Some(map) = map {
                status["revisions"] = map.to_value();
            }
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": name,
                    "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
                    "annotations": { (keys::IDENTITY_HASH): format!("h-{name}") },
                },
                "status": status,
            })
        }

        async fn lock(api: &FakeApi, activation: &str) -> Arc<head::Lock> {
            Arc::new(
                head::take(
                    &api.client(),
                    head::Request {
                        cluster: "a".into(),
                        holder: Holder::cli("kix deploy"),
                        purpose: Purpose::Deploy,
                        activation: Some(activation.into()),
                        expect: None,
                    },
                    head::system_clock(),
                    &|_| {},
                )
                .await
                .unwrap(),
            )
        }

        /// A run of record `name` that names the revisions of `set`, under
        /// a lock when `lock` is given.
        async fn run(
            api: &FakeApi,
            name: &str,
            set: Option<RevisionSet>,
            lock: Option<Arc<head::Lock>>,
        ) -> ActivationRecord {
            let mut run = record(api, Some(name)).await;
            run.config.revisions = set;
            run.config.lock = lock;
            run
        }

        fn stored_map(api: &FakeApi, name: &str) -> Option<RevisionMap> {
            let obj = api.object("Activation", name).unwrap();
            let map = &obj["status"]["revisions"];
            (!map.is_null()).then(|| RevisionMap::read(map).unwrap())
        }

        fn revision_creates(api: &FakeApi) -> usize {
            api.requests()
                .iter()
                .filter(|r| r.starts_with("POST ") && r.contains(revision::PLURAL))
                .count()
        }

        /// The record names a revision for every instance and the cluster
        /// level, and begin creates each of them. A second deploy that
        /// leaves `data/db` unchanged names the same revision for it, so
        /// only the changed instance adds a revision.
        #[tokio::test]
        async fn a_record_names_every_instance_and_an_unchanged_one_keeps_its_revision() {
            let api = FakeApi::new([
                activation("one", "Deploying", None),
                activation("two", "Deploying", None),
            ]);
            let first = build("1");
            run(&api, "one", Some(first.clone()), None)
                .await
                .begin()
                .await
                .unwrap();
            let map = stored_map(&api, "one").unwrap();
            assert_eq!(map, RevisionMap::of(&first));
            assert_eq!(
                map.instances.keys().collect::<Vec<_>>(),
                ["app/web", "data/db"]
            );
            assert_eq!(map.cluster_level, first.cluster_level.name);
            let mut expected: Vec<String> = first.all().map(|r| r.name.clone()).collect();
            expected.sort();
            assert_eq!(api.names(revision::KIND), expected);

            let second = build("2");
            run(&api, "two", Some(second.clone()), None)
                .await
                .begin()
                .await
                .unwrap();
            let two = stored_map(&api, "two").unwrap();
            assert_eq!(two.instances["data/db"], map.instances["data/db"]);
            assert_eq!(two.cluster_level, map.cluster_level);
            assert_ne!(two.instances["app/web"], map.instances["app/web"]);
            assert_eq!(api.names(revision::KIND).len(), 4);
            let store = Revisions::new(&api.client());
            assert_eq!(
                store.create(&second.instances["data/db"]).await.unwrap(),
                Created::Exists
            );
        }

        /// A run that takes over a record sends every create again. The
        /// revisions the first run created count as created, and the one it
        /// did not reach is created.
        #[tokio::test]
        async fn a_run_that_takes_over_creates_the_revisions_again() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let set = build("1");
            run(&api, "one", Some(set.clone()), None)
                .await
                .begin()
                .await
                .unwrap();
            let lost = &set.instances["app/web"].name;
            Revisions::new(&api.client()).delete(lost).await.unwrap();
            let before = revision_creates(&api);

            run(&api, "one", Some(set.clone()), None)
                .await
                .begin()
                .await
                .unwrap();
            assert_eq!(revision_creates(&api) - before, set.all().count());
            assert!(api.names(revision::KIND).contains(lost));
            assert_eq!(stored_map(&api, "one"), Some(RevisionMap::of(&set)));
        }

        /// A deploy's run creates its record at the start, then the
        /// revisions, then names them on the record in the write that marks
        /// it Deploying, so a record names only revisions that exist. This
        /// holds on a cluster's first deploy too, because taking the lock
        /// installed the record's kind.
        #[tokio::test]
        async fn the_first_deploy_creates_the_record_then_the_revisions_then_names_them() {
            let api = FakeApi::new([]);
            let set = build("1");
            let mut run = run(&api, "one", Some(set.clone()), None).await;
            let mut manifest = activation("one", "", None);
            manifest.as_object_mut().unwrap().remove("status");
            run.config.manifest = Some(manifest);
            run.begin().await.unwrap();
            assert_eq!(api.names(revision::KIND).len(), set.all().count());
            assert_eq!(
                api.object("Activation", "one").unwrap()["status"]["phase"],
                "Deploying"
            );
            let requests = api.requests();
            let position = |want: &dyn Fn(&String) -> bool| requests.iter().position(want).unwrap();
            let record = position(&|r| r.starts_with("PATCH ") && r.contains("/activations/one?"));
            let revision = position(&|r| r.starts_with("POST ") && r.contains(revision::PLURAL));
            let named =
                position(&|r| r.starts_with("PATCH ") && r.contains("/activations/one/status"));
            assert!(record < revision && revision < named, "{requests:?}");
        }

        /// A revision that cannot be created stops begin before the record
        /// is marked Deploying or names anything, so no record is left
        /// Deploying with a map of revisions that do not exist.
        #[tokio::test]
        async fn a_failed_create_stops_begin_before_the_record_names_anything() {
            let mut queued = activation("one", "", None);
            queued["status"] = json!({});
            let api = FakeApi::new([queued]);
            api.fail_next(
                &format!("/apis/{}/{}", keys::API_VERSION, revision::PLURAL),
                u32::MAX,
                403,
            );
            let err = run(&api, "one", Some(build("1")), None)
                .await
                .begin()
                .await
                .unwrap_err();
            assert!(matches!(err, RecordWriteError::Revisions(_)), "{err}");
            let status = &api.object("Activation", "one").unwrap()["status"];
            assert!(status.get("phase").is_none(), "{status}");
            assert!(status.get("revisions").is_none(), "{status}");
        }

        /// Begin fails when the record cannot be marked Deploying, whatever
        /// the reason: a record that is missing, or a write the API server
        /// refuses. The run then applies nothing.
        #[tokio::test]
        async fn begin_fails_when_the_record_cannot_be_marked_deploying() {
            let api = FakeApi::new([]);
            let err = run(&api, "one", Some(build("1")), None)
                .await
                .begin()
                .await
                .unwrap_err();
            assert!(matches!(err, RecordWriteError::Records(_)), "{err}");

            let api = FakeApi::new([activation("one", "", None)]);
            api.fail_next(
                &format!("/apis/{}/activations/one/status", keys::API_VERSION),
                1,
                500,
            );
            let err = run(&api, "one", Some(build("1")), None)
                .await
                .begin()
                .await
                .unwrap_err();
            assert!(matches!(err, RecordWriteError::Records(_)), "{err}");
        }

        /// The operator's run on a record that `kix deploy --operator`
        /// submitted, which has no package index and no map, writes the
        /// map and creates the revisions. A run that writes no record, as
        /// the operator's drift repair, creates none.
        #[tokio::test]
        async fn an_operator_deploy_gives_a_record_without_an_index_a_map() {
            let mut queued = activation("one", "", None);
            queued["status"] = json!({});
            let api = FakeApi::new([queued]);
            let set = build("1");
            let mut operator = run(&api, "one", Some(set.clone()), None).await;
            operator.config.mark_failed_on_abort = false;
            operator.begin().await.unwrap();
            assert_eq!(stored_map(&api, "one"), Some(RevisionMap::of(&set)));
            assert_eq!(api.names(revision::KIND).len(), set.all().count());

            let api = FakeApi::new([activation("one", "Active", None)]);
            let mut repair = record(&api, None).await;
            repair.config.revisions = None;
            repair.begin().await.unwrap();
            assert!(api.names(revision::KIND).is_empty());
            assert_eq!(stored_map(&api, "one"), None);
        }

        /// A finished deploy deletes the old revision of the instance it
        /// changed. It keeps what the new record, a `Failed`, a `Partial`
        /// and a queued record name, and drops what only a `Superseded`
        /// record named.
        #[tokio::test]
        async fn a_finished_deploy_deletes_the_revisions_no_record_needs() {
            let old = build("1");
            let failed = build("f");
            let partial = build("p");
            let queued = build("q");
            let superseded = build("s");
            let api = FakeApi::new([
                activation("old", "Active", Some(&RevisionMap::of(&old))),
                activation("failed", "Failed", Some(&RevisionMap::of(&failed))),
                activation("partial", "Partial", Some(&RevisionMap::of(&partial))),
                activation("queued", "Queued", Some(&RevisionMap::of(&queued))),
                activation("gone", "Superseded", Some(&RevisionMap::of(&superseded))),
                activation("new", "Deploying", None),
            ]);
            let store = Revisions::new(&api.client());
            for set in [&old, &failed, &partial, &queued, &superseded] {
                for revision in set.all() {
                    store.create(revision).await.unwrap();
                }
            }
            let new = build("2");
            let lock = lock(&api, "new").await;
            let run = run(&api, "new", Some(new.clone()), Some(lock.clone())).await;
            run.begin().await.unwrap();
            run.finalize(false, NONE_LEFT).await.unwrap().unwrap();
            lock.release().await.unwrap();

            let left = api.names(revision::KIND);
            let has = |r: &Revision| left.contains(&r.name);
            assert!(
                !has(&old.instances["app/web"]),
                "the changed instance's old revision"
            );
            assert!(!has(&superseded.instances["app/web"]));
            for set in [&new, &failed, &partial, &queued] {
                assert!(set.all().all(has));
            }
            assert_eq!(
                api.object("Activation", "old").unwrap()["status"]["phase"],
                "Superseded"
            );
        }

        /// A deploy with `--only` names a revision for every instance of its
        /// build, and ending `Partial` deletes no revision.
        #[tokio::test]
        async fn a_partial_deploy_names_every_instance_and_deletes_nothing() {
            let old = build("1");
            let api = FakeApi::new([
                activation("old", "Superseded", Some(&RevisionMap::of(&old))),
                activation("new", "Active", None),
            ]);
            let store = Revisions::new(&api.client());
            for revision in old.all() {
                store.create(revision).await.unwrap();
            }
            api.patch_object("Activation", "new", |o| o["status"]["phase"] = json!(""));
            let set = build("2");
            let lock = lock(&api, "new").await;
            let mut run = run(&api, "new", Some(set.clone()), Some(lock.clone())).await;
            run.config.only = vec!["app/web".into()];
            run.begin().await.unwrap();
            run.end_partial().await.unwrap();
            lock.release().await.unwrap();

            assert_eq!(
                api.object("Activation", "new").unwrap()["status"]["phase"],
                "Partial"
            );
            assert_eq!(stored_map(&api, "new"), Some(RevisionMap::of(&set)));
            assert!(
                old.all()
                    .all(|r| api.names(revision::KIND).contains(&r.name))
            );
            assert!(
                !api.requests()
                    .iter()
                    .any(|r| r.starts_with("DELETE ") && r.contains(revision::PLURAL)),
                "{:?}",
                api.requests()
            );
        }

        fn left_manifest(name: &str, hash: &str) -> Value {
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": name,
                    "namespace": "app",
                    "annotations": { (keys::IDENTITY_HASH): format!("{hash:a>32}") },
                },
            })
        }

        fn kept_objects(api: &FakeApi, name: &str) -> Vec<String> {
            let kept = stored_map(api, name).unwrap().kept_orphans.unwrap();
            let obj = api.object(revision::KIND, &kept).unwrap();
            assert_eq!(obj["spec"]["slot"]["kind"], "keptOrphans");
            obj["spec"]["objects"]
                .as_array()
                .unwrap()
                .iter()
                .map(|o| o["name"].as_str().unwrap().to_string())
                .collect()
        }

        /// A deploy that leaves orphans lists them in a kept-orphans
        /// revision that its record names, beside `status.orphansKeptFrom`.
        /// An earlier kept orphan that the next deploy finds again and
        /// leaves is carried forward, and one it deleted, or that was gone,
        /// is dropped. The previous record's kept-orphans revision is then
        /// no longer needed.
        #[tokio::test]
        async fn the_kept_orphans_revision_carries_forward_what_is_still_live() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let manifests = [
                left_manifest("stale-a", "1"),
                left_manifest("stale-b", "2"),
                left_manifest("unrelated", "3"),
            ];
            let orphans: Vec<ResourceId> =
                manifests[..2].iter().map(ResourceId::from_value).collect();
            let lock1 = lock(&api, "one").await;
            let one = run(&api, "one", Some(build("1")), Some(lock1.clone())).await;
            one.begin().await.unwrap();
            one.finalize(
                false,
                Left {
                    orphans: &orphans,
                    never_pruned: &[],
                    manifests: &manifests,
                },
            )
            .await
            .unwrap();
            lock1.release().await.unwrap();
            assert_eq!(kept_objects(&api, "one"), ["stale-a", "stale-b"]);
            let first_kept = stored_map(&api, "one").unwrap().kept_orphans.unwrap();

            // The next deploy deletes `stale-b` and leaves `stale-a`.
            api.insert(activation("two", "Deploying", None));
            let lock2 = lock(&api, "two").await;
            let two = run(&api, "two", Some(build("2")), Some(lock2.clone())).await;
            two.begin().await.unwrap();
            two.finalize(
                false,
                Left {
                    orphans: &orphans[..1],
                    never_pruned: &[],
                    manifests: &manifests,
                },
            )
            .await
            .unwrap();
            lock2.release().await.unwrap();
            assert_eq!(kept_objects(&api, "two"), ["stale-a"]);
            assert!(!api.names(revision::KIND).contains(&first_kept));
            assert_eq!(
                api.object("Activation", "two").unwrap()["status"][keys::ORPHANS_KEPT_FROM_FIELD],
                Value::Null,
                "no kept builds were found by this test's plan"
            );

            // A deploy that leaves nothing names no kept orphans.
            api.insert(activation("three", "Deploying", None));
            let lock3 = lock(&api, "three").await;
            let three = run(&api, "three", Some(build("3")), Some(lock3.clone())).await;
            three.begin().await.unwrap();
            three.finalize(false, NONE_LEFT).await.unwrap();
            lock3.release().await.unwrap();
            assert_eq!(stored_map(&api, "three").unwrap().kept_orphans, None);
        }

        /// A plan that did not read the cluster carries the previous
        /// record's kept orphans forward unexamined, as it carries
        /// `status.orphansKeptFrom`.
        #[tokio::test]
        async fn a_plan_that_did_not_read_the_cluster_carries_the_kept_orphans_forward() {
            let manifests = [left_manifest("stale-a", "1"), left_manifest("stale-c", "4")];
            let earlier = Revision::new(RevisionSpec::new(
                "a",
                Slot::KeptOrphans,
                vec![object("1", "app", "stale-a")],
            ));
            let mut old_map = RevisionMap::of(&build("1"));
            old_map.kept_orphans = Some(earlier.name.clone());
            let api = FakeApi::new([
                activation("old", "Active", Some(&old_map)),
                activation("new", "Deploying", None),
            ]);
            Revisions::new(&api.client())
                .create(&earlier)
                .await
                .unwrap();
            let orphans = vec![ResourceId::from_value(&manifests[1])];
            let lock = lock(&api, "new").await;
            let mut new = run(&api, "new", Some(build("2")), Some(lock.clone())).await;
            new.config.kept_orphans.carry_current = true;
            new.begin().await.unwrap();
            new.finalize(
                false,
                Left {
                    orphans: &orphans,
                    never_pruned: &[],
                    manifests: &manifests,
                },
            )
            .await
            .unwrap();
            lock.release().await.unwrap();
            assert_eq!(kept_objects(&api, "new"), ["stale-a", "stale-c"]);
        }

        /// A finalize that must carry the previous kept orphans forward and
        /// cannot read their revision fails before the commit. The record
        /// stays Deploying and the previous record stays current, so the
        /// list is not lost.
        #[tokio::test]
        async fn a_kept_orphans_revision_that_cannot_be_read_fails_finalize() {
            let mut old_map = RevisionMap::of(&build("1"));
            old_map.kept_orphans = Some("a-missing".into());
            let api = FakeApi::new([
                activation("old", "Active", Some(&old_map)),
                activation("new", "Deploying", None),
            ]);
            let lock = lock(&api, "new").await;
            let mut new = run(&api, "new", Some(build("2")), Some(lock.clone())).await;
            new.config.kept_orphans.carry_current = true;
            new.begin().await.unwrap();
            let err = new.finalize(false, NONE_LEFT).await.unwrap_err();
            assert!(matches!(err, RecordWriteError::KeptOrphans(_)), "{err}");
            assert!(err.to_string().contains("a-missing"), "{err}");
            assert_eq!(
                api.object("Activation", "new").unwrap()["status"]["phase"],
                "Deploying"
            );
            assert_eq!(
                api.object("Activation", "old").unwrap()["status"]["phase"],
                "Active"
            );
            lock.release().await.unwrap();
        }

        /// A kept-orphans revision that cannot be created fails finalize
        /// too, rather than writing a record that names no kept orphans.
        #[tokio::test]
        async fn a_kept_orphans_revision_that_cannot_be_created_fails_finalize() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let manifests = [left_manifest("stale-a", "1")];
            let orphans = vec![ResourceId::from_value(&manifests[0])];
            let lock = lock(&api, "one").await;
            let one = run(&api, "one", Some(build("1")), Some(lock.clone())).await;
            one.begin().await.unwrap();
            api.fail_next(
                &format!("/apis/{}/{}", keys::API_VERSION, revision::PLURAL),
                1,
                403,
            );
            let err = one
                .finalize(
                    false,
                    Left {
                        orphans: &orphans,
                        never_pruned: &[],
                        manifests: &manifests,
                    },
                )
                .await
                .unwrap_err();
            assert!(matches!(err, RecordWriteError::KeptOrphans(_)), "{err}");
            assert_eq!(
                api.object("Activation", "one").unwrap()["status"]["phase"],
                "Deploying"
            );
            lock.release().await.unwrap();
        }

        /// A record that was superseded and is deployed again names no kept
        /// orphans from its earlier deploy, whose revision is gone.
        #[tokio::test]
        async fn a_record_deployed_again_after_it_was_superseded_names_no_old_kept_orphans() {
            let mut map = RevisionMap::of(&build("1"));
            map.kept_orphans = Some("a-gone".into());
            let api = FakeApi::new([activation("one", "Active", Some(&map))]);
            let records = Records::undiscovered(&api.client());
            records.supersede("one").await.unwrap();
            run(&api, "one", Some(build("1")), None)
                .await
                .begin()
                .await
                .unwrap();
            assert_eq!(stored_map(&api, "one"), Some(RevisionMap::of(&build("1"))));
        }

        /// The manifest of `object` as a run applies it, carrying its build
        /// hash.
        fn manifest(object: &RevisionObject) -> Value {
            json!({
                "apiVersion": "v1",
                "kind": object.kind,
                "metadata": {
                    "name": object.name,
                    "namespace": object.namespace,
                    "annotations": { (keys::IDENTITY_HASH): object.hash },
                },
            })
        }

        fn status_writes(api: &FakeApi) -> usize {
            api.requests()
                .iter()
                .filter(|r| {
                    r.starts_with("PATCH ") && r.contains(revision::PLURAL) && r.contains("/status")
                })
                .count()
        }

        fn applied_of(api: &FakeApi, revision: &Revision) -> BTreeMap<String, String> {
            let obj = api.object(revision::KIND, &revision.name).unwrap();
            serde_json::from_value(obj["status"]["applied"].clone()).unwrap_or_default()
        }

        fn web_revision(objects: Vec<RevisionObject>) -> Revision {
            Revision::new(RevisionSpec::new(
                "a",
                Slot::Instance {
                    namespace: "app".into(),
                    name: "web".into(),
                },
                objects,
            ))
        }

        /// Step 5 writes one status patch for each revision that names an
        /// object the run applied, and none for a revision with no applies.
        /// A second call with nothing new writes nothing.
        #[tokio::test]
        async fn the_applied_hashes_go_once_to_each_revision_with_applies() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let set = build("1");
            let run = run(&api, "one", Some(set.clone()), None).await;
            run.begin().await.unwrap();
            let web = object("1", "app", "web");
            let shared = object("e", "app", "shared");
            run.resources.note_applied(&manifest(&web), "w1".into());
            run.resources.note_applied(&manifest(&shared), "s1".into());
            run.write_applied().await.unwrap();
            assert_eq!(status_writes(&api), 2);
            assert_eq!(
                applied_of(&api, &set.instances["app/web"]),
                BTreeMap::from([(web.hash.clone(), "w1".to_string())])
            );
            assert_eq!(
                applied_of(&api, &set.cluster_level),
                BTreeMap::from([(shared.hash.clone(), "s1".to_string())])
            );
            assert!(applied_of(&api, &set.instances["data/db"]).is_empty());
            run.write_applied().await.unwrap();
            assert_eq!(status_writes(&api), 2);
        }

        #[tokio::test]
        async fn a_run_that_applied_nothing_writes_no_hashes() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let run = run(&api, "one", Some(build("1")), None).await;
            run.begin().await.unwrap();
            run.write_applied().await.unwrap();
            assert_eq!(status_writes(&api), 0);
        }

        /// A changed instance's new revision takes the old revision's hash
        /// of each object the run did not apply, in the same write as the
        /// hashes the run applied. The old revision is the one the current
        /// record names.
        #[tokio::test]
        async fn a_changed_instance_carries_the_hashes_of_unchanged_objects() {
            let (x, y1, y2) = (
                object("x", "app", "x"),
                object("y1", "app", "y"),
                object("y2", "app", "y"),
            );
            let mut old = build("1");
            old.instances
                .insert("app/web".into(), web_revision(vec![x.clone(), y1.clone()]));
            let mut new = old.clone();
            new.instances
                .insert("app/web".into(), web_revision(vec![x.clone(), y2.clone()]));
            let api = FakeApi::new([
                activation("old", "Active", Some(&RevisionMap::of(&old))),
                activation("new", "Deploying", None),
            ]);
            let store = Revisions::new(&api.client());
            for revision in old.all() {
                store.create(revision).await.unwrap();
            }
            let old_web = &old.instances["app/web"];
            store
                .write_applied(
                    &old_web.name,
                    &BTreeMap::from([
                        (x.hash.clone(), "hx".to_string()),
                        (y1.hash.clone(), "hy1".to_string()),
                    ]),
                )
                .await
                .unwrap();
            let committed = lock(&api, "old").await;
            committed.commit("old").await.unwrap();
            committed.release().await.unwrap();

            let run = run(&api, "new", Some(new.clone()), None).await;
            run.begin().await.unwrap();
            let before = status_writes(&api);
            run.resources.note_applied(&manifest(&y2), "hy2".into());
            run.write_applied().await.unwrap();
            assert_eq!(status_writes(&api) - before, 1);
            assert_eq!(
                applied_of(&api, &new.instances["app/web"]),
                BTreeMap::from([
                    (x.hash.clone(), "hx".to_string()),
                    (y2.hash.clone(), "hy2".to_string()),
                ])
            );
            assert_eq!(applied_of(&api, old_web).len(), 2);
        }

        /// An object that the current record's revision and a Failed
        /// record's revision both name with one build hash gets its applied
        /// hash in both. A Superseded record's revision is not kept, so it
        /// gets nothing. A run that writes no record, as the operator's
        /// repair, writes the same way.
        #[tokio::test]
        async fn an_object_two_kept_revisions_name_gets_its_hash_in_both() {
            let z = object("z", "app", "z");
            let revision_of = |other: &str| {
                let mut set = build("1");
                set.instances.insert(
                    "app/web".into(),
                    web_revision(vec![z.clone(), object(other, "app", other)]),
                );
                set
            };
            let (current, failed, gone) = (revision_of("c"), revision_of("f"), revision_of("g"));
            let api = FakeApi::new([
                activation("current", "Active", Some(&RevisionMap::of(&current))),
                activation("failed", "Failed", Some(&RevisionMap::of(&failed))),
                activation("gone", "Superseded", Some(&RevisionMap::of(&gone))),
            ]);
            let store = Revisions::new(&api.client());
            for set in [&current, &failed, &gone] {
                for revision in set.all() {
                    store.create(revision).await.unwrap();
                }
            }
            let repair = record(&api, None).await;
            repair.resources.note_applied(&manifest(&z), "hz".into());
            repair.write_applied().await.unwrap();
            let expected = BTreeMap::from([(z.hash.clone(), "hz".to_string())]);
            assert_eq!(applied_of(&api, &current.instances["app/web"]), expected);
            assert_eq!(applied_of(&api, &failed.instances["app/web"]), expected);
            assert!(applied_of(&api, &gone.instances["app/web"]).is_empty());
            assert_eq!(status_writes(&api), 2);
        }

        /// A run that applied nothing, such as an operator deploy whose
        /// build only removed an object, still carries the old revision's
        /// hashes into the revision that replaces it.
        #[tokio::test]
        async fn a_run_that_applied_nothing_carries_the_hashes_of_unchanged_objects() {
            let (x, y) = (object("x", "app", "x"), object("y", "app", "y"));
            let mut old = build("1");
            old.instances
                .insert("app/web".into(), web_revision(vec![x.clone(), y.clone()]));
            let mut new = old.clone();
            new.instances
                .insert("app/web".into(), web_revision(vec![x.clone()]));
            let api = FakeApi::new([
                activation("old", "Active", Some(&RevisionMap::of(&old))),
                activation("new", "Deploying", None),
            ]);
            let store = Revisions::new(&api.client());
            for revision in old.all() {
                store.create(revision).await.unwrap();
            }
            store
                .write_applied(
                    &old.instances["app/web"].name,
                    &BTreeMap::from([(x.hash.clone(), "hx".to_string())]),
                )
                .await
                .unwrap();
            let committed = lock(&api, "old").await;
            committed.commit("old").await.unwrap();
            committed.release().await.unwrap();

            let run = run(&api, "new", Some(new.clone()), None).await;
            run.begin().await.unwrap();
            run.write_applied().await.unwrap();
            assert_eq!(
                applied_of(&api, &new.instances["app/web"]),
                BTreeMap::from([(x.hash.clone(), "hx".to_string())])
            );
        }

        /// A revision that exists when a run creates it, and that no record
        /// names, was left by a run that stopped or a cleanup that failed.
        /// The run clears its applied hashes, which describe that run's
        /// objects. A revision a record names keeps its hashes.
        #[tokio::test]
        async fn a_revision_no_record_names_is_adopted_without_its_hashes() {
            let set = build("1");
            let mut current = build("1");
            current.instances.insert(
                "app/web".into(),
                web_revision(vec![object("c", "app", "c")]),
            );
            let api = FakeApi::new([
                activation("cur", "Active", Some(&RevisionMap::of(&current))),
                activation("new", "Deploying", None),
            ]);
            let store = Revisions::new(&api.client());
            let left = &set.instances["app/web"];
            let named = &set.instances["data/db"];
            for revision in [left, named] {
                store.create(revision).await.unwrap();
                store
                    .write_applied(
                        &revision.name,
                        &BTreeMap::from([("h".to_string(), "stale".to_string())]),
                    )
                    .await
                    .unwrap();
            }
            // `cur` names the db revision too: the instance did not change.
            assert_eq!(current.instances["data/db"].name, named.name);

            run(&api, "new", Some(set.clone()), None)
                .await
                .begin()
                .await
                .unwrap();
            assert!(applied_of(&api, left).is_empty());
            assert_eq!(applied_of(&api, named).len(), 1);
        }

        /// A record whose map this Kix cannot read names revisions it cannot
        /// see. The run still writes its applied hashes to the revisions the
        /// other records name.
        #[tokio::test]
        async fn an_unreadable_record_does_not_stop_the_applied_hashes() {
            let api = FakeApi::new([
                activation("newer", "Failed", None),
                activation("one", "Deploying", None),
            ]);
            api.patch_object("Activation", "newer", |o| {
                o["status"]["revisions"] = json!({ "format": 99 });
            });
            let set = build("1");
            let run = run(&api, "one", Some(set.clone()), None).await;
            run.begin().await.unwrap();
            let web = object("1", "app", "web");
            run.resources.note_applied(&manifest(&web), "w1".into());
            run.write_applied().await.unwrap();
            assert_eq!(
                applied_of(&api, &set.instances["app/web"]),
                BTreeMap::from([(web.hash.clone(), "w1".to_string())])
            );
        }

        /// An orphan of a kind Kix never prunes, such as a Namespace, is
        /// named by the kept-orphans revision, so later reports list it.
        #[tokio::test]
        async fn the_kept_orphans_revision_names_what_kix_never_prunes() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let namespace = json!({
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {
                    "name": "old-ns",
                    "annotations": { (keys::IDENTITY_HASH): format!("{:a>32}", "n") },
                },
            });
            let manifests = [left_manifest("stale", "1"), namespace.clone()];
            let lock = lock(&api, "one").await;
            let one = run(&api, "one", Some(build("1")), Some(lock.clone())).await;
            one.begin().await.unwrap();
            one.finalize(
                false,
                Left {
                    orphans: &[],
                    never_pruned: &[ResourceId::from_value(&namespace)],
                    manifests: &manifests,
                },
            )
            .await
            .unwrap();
            lock.release().await.unwrap();
            assert_eq!(kept_objects(&api, "one"), ["old-ns"]);
        }

        /// The objects a plan could not find out about, because the cluster
        /// does not serve their kind, keep their place in the kept-orphans
        /// revision.
        #[tokio::test]
        async fn the_kept_orphans_revision_names_what_the_plan_could_not_read() {
            let api = FakeApi::new([activation("one", "Deploying", None)]);
            let lock = lock(&api, "one").await;
            let mut one = run(&api, "one", Some(build("1")), Some(lock.clone())).await;
            one.config.kept_orphans.unknown = vec![RevisionObject {
                hash: format!("{:a>32}", "w"),
                group: "example.com".into(),
                kind: "Widget".into(),
                namespace: Some("app".into()),
                name: "unserved".into(),
            }];
            one.begin().await.unwrap();
            one.finalize(false, NONE_LEFT).await.unwrap();
            lock.release().await.unwrap();
            assert_eq!(kept_objects(&api, "one"), ["unserved"]);
        }
    }
}
