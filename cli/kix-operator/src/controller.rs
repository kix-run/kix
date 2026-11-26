//! Reconcile Activation resources for the Kix operator.
//!
//! # Phase-based lifecycle
//!
//! The operator manages Activation CRs through a phase-based lifecycle:
//!
//! New resources progress through Queued, Deploying, Active, and Superseded.
//!
//! - **Queued**: A new activation waiting to be deployed. The operator
//!   begins deploying it.
//! - **Deploying**: Deploy in progress (wave-by-wave apply).
//! - **Active**: Successfully deployed. Drift detection runs on requeue.
//! - **Superseded**: Replaced by a newer activation.
//!
//! The current Active or Degraded record stays current until a newer record
//! finishes its deploy. The shared finalize step supersedes it then, as it
//! does for `kix deploy`. Its drift repair waits while a newer record of the
//! same Kix cluster is Queued or Deploying. When that deploy ends Failed,
//! the repair resumes and returns the cluster to the current record's build.
//!
//! # Unified reconcile loop
//!
//! Both new deployments and drift correction use the same path:
//! 1. Load desired manifests from `spec.source.path`
//! 2. Fetch the live Kix-managed resources of the record's Kix cluster
//! 3. Compare identity-hashes (desired vs live) to determine Apply/Skip/Orphan
//! 4. Wave-plan and apply
//!
//! # Reconcile loop prevention
//!
//! 1. The generation predicate filters events where
//!    only `.status` changed (no generation bump).
//! 2. Status writes use the status subresource through `patch_status`,
//!    which never bumps generation.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use kube::{api::DynamicObject, client::Client, runtime::controller::Action};
use serde_json::Value;
use thiserror::Error;

use kix::build_source::Build;
use kix::cluster::activation::{Record, Records};
use kix::cluster::binding::{self, BindingError, Connection};
use kix::cluster::cancel::CancelToken;
use kix::cluster::graph::DeleteOrder;
use kix::cluster::head::{self, Holder, Lock, Purpose, TakeError, WritesStopped};
use kix::cluster::kubernetes_version;
use kix::cluster::prune_guard::{self, Pruned, Removal, Step};
use kix::cluster::readiness::{self, DeletePath};
use kix::cluster::revision::RevisionSet;
use kix::cluster::scheduler::{self, DeployError, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stops;
use kix::cluster::stream::{DeployObserver, DeployResult};
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::{KixPackageIndex, read_index};
use kix::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_PARTIAL, PHASE_QUEUED,
    PHASE_SUPERSEDED,
};
use kix::manifest::types::ResourceId;
use kix::plan::LastRuns;
use kix::plan::live::{LivePlan, LivePlanError, cluster_of};
use kix::version::Version;

use crate::k8s_events::{CompositeObserver, K8sEventObserver};
use crate::observer::OperatorObserver;
use kix::manifest::keys;

/// Finalizer name for operator-managed cleanup.
const FINALIZER: &str = keys::OPERATOR_GC_FINALIZER;

/// Short requeue when yielding to a Queued activation.
const QUEUED_REQUEUE_INTERVAL: Duration = Duration::from_secs(5);

/// How long a resource may go without readiness progress before an operator
/// deploy fails it. Every operator deploy uses this value. `kix deploy
/// --operator` refuses `--timeout` with `[K7218]`, and that message quotes
/// this value.
const READINESS_TIMEOUT: Duration = Duration::from_secs(300);

/// Default requeue interval after successful reconciliation.
/// Override with KIX_REQUEUE_INTERVAL_SECS env var.
fn requeue_interval() -> Duration {
    std::env::var("KIX_REQUEUE_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(300))
}

/// Default requeue interval after errors.
const ERROR_REQUEUE_INTERVAL: Duration = Duration::from_secs(30);

/// Environment variable for how many times the operator retries a deploy
/// that stopped at a failure before it marks the record Failed. `0` marks it
/// Failed at the first stop, as `kix deploy` does.
pub const DEPLOY_RETRIES_ENV: &str = "KIX_DEPLOY_RETRIES";

/// The number of retries when [`DEPLOY_RETRIES_ENV`] is unset. A deploy that
/// stops within seconds, such as one whose SOPS file the operator cannot
/// decrypt, is retried every [`ERROR_REQUEUE_INTERVAL`], so ten retries end
/// it in about five minutes. That is inside the 600 seconds `kix deploy
/// --operator` waits, so the command reports the failure instead of timing
/// out.
pub const DEFAULT_DEPLOY_RETRIES: u32 = 10;

/// Return the number of retries [`DEPLOY_RETRIES_ENV`] sets, or
/// [`DEFAULT_DEPLOY_RETRIES`].
pub fn deploy_retries() -> u32 {
    kix::cluster::client::env_number(DEPLOY_RETRIES_ENV).map_or(DEFAULT_DEPLOY_RETRIES, |n| {
        u32::try_from(n).unwrap_or(u32::MAX)
    })
}

/// Shared context for the controller.
pub struct Context {
    pub client: Client,
    pub records: Records,
    /// The required stops a Queued record must not skip, normally
    /// [`stops::required_stops`].
    pub required_stops: Vec<Version>,
    /// Cancelled when the operator is asked to stop. A running deploy then
    /// stops at its next step and leaves its record `Deploying`, and the
    /// next operator start resumes it.
    pub shutdown: CancelToken,
    /// The one Event recorder every reconcile reports through
    /// ([`crate::k8s_events::recorder`]).
    pub events: Arc<kube::runtime::events::Recorder>,
    /// How many times a deploy that stopped at a failure is retried before
    /// its record is marked Failed, normally [`deploy_retries`].
    pub deploy_retries: u32,
    /// Who the operator is on each Kix cluster's deploy lock. The id stays
    /// the same after a restart.
    pub holder: Holder,
    /// One mutex per Kix cluster, so the operator runs one deploy, repair,
    /// or teardown of a Kix cluster at a time. A lock held by its own id is
    /// then always one a previous pod left.
    pub runs: std::sync::Mutex<std::collections::HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl Context {
    /// Return the mutex that orders this operator's runs on Kix cluster
    /// `cluster`.
    fn runs_of(&self, cluster: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.runs
            .lock()
            .expect("runs lock")
            .entry(cluster.to_string())
            .or_default()
            .clone()
    }

    /// Take the deploy lock of Kix cluster `cluster` for `purpose`, deploying
    /// record `activation`. Return `None`, after logging who holds it, when
    /// another run holds the lock, so the caller tries again later.
    async fn take(
        &self,
        cluster: &str,
        purpose: Purpose,
        activation: &str,
    ) -> Result<Option<Lock>, OperatorError> {
        let request = head::Request {
            cluster: cluster.to_string(),
            holder: self.holder.clone(),
            purpose,
            activation: Some(activation.to_string()),
            expect: None,
        };
        let on_watch = |other: &head::LockState| {
            tracing::info!(cluster, holder = %other.holder, hint = %other.hint, purpose = other.purpose.as_str(), "another run holds the deploy lock; watching it");
        };
        match head::take(&self.client, request, head::system_clock(), &on_watch).await {
            Ok(lock) => Ok(Some(lock)),
            Err(TakeError::Held(held)) => {
                tracing::info!(cluster, activation, "{held}");
                Ok(None)
            }
            Err(e) => Err(OperatorError::LifecycleError(e.to_string())),
        }
    }
}

/// Release `lock`, logging a failure. The lock then expires after its lease.
async fn release(lock: &Lock) {
    if let Err(e) = lock.release().await {
        tracing::warn!(error = %e, "could not release the deploy lock; its lease will expire automatically");
    }
}

/// Errors from the operator reconcile loop.
#[derive(Error, Debug)]
pub enum OperatorError {
    #[error("missing spec.source.path on Activation")]
    MissingSourcePath,

    #[error(
        "the operator pod cannot read the build at {path} (`spec.source.path`): {reason}\n\
         Check that the build exists at that path in the store the operator reads."
    )]
    StoreGraphError { path: String, reason: String },

    #[error("failed to run API discovery: {0}")]
    DiscoveryError(String),

    #[error("reconcile failed: {0}")]
    ReconcileError(String),

    #[error("kube error: {0}")]
    KubeError(#[from] kube::Error),

    #[error("graph error: {0}")]
    GraphError(String),

    #[error("activation lifecycle error: {0}")]
    LifecycleError(String),

    #[error(
        "{count} object(s) of the deleted Activation (deployment record) are still on the cluster, and the Kix operator keeps the deleted Activation and tries again every 30 seconds; wait for slow cleanups to finish, or check the controller that added any stuck finalizer: {leftovers}"
    )]
    DeletionUnfinished { count: usize, leftovers: String },
}

/// Extract the source store path from an Activation CR.
fn source_path(activation: &DynamicObject) -> Option<std::path::PathBuf> {
    activation
        .data
        .pointer("/spec/source/path")
        .and_then(|v| v.as_str())
        .map(std::path::PathBuf::from)
}

/// Load the stamped manifests of the build in `path`.
///
/// Does not reject retired domains ([`Build::installable`]): the record may
/// reference a build created before a domain migration (such as during
/// `kix rollback --operator`), and `kix deploy` validates new builds before
/// writing the record.
fn load_manifests(path: &Path) -> Result<Vec<Value>, OperatorError> {
    Ok(load_build(path)?
        .graph()
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect())
}

/// Load the build in `path`, as [`load_manifests`] does.
fn load_build(path: &Path) -> Result<Build, OperatorError> {
    Build::local(path, &|_| {}).map_err(|e| OperatorError::StoreGraphError {
        path: path.display().to_string(),
        reason: e.to_string(),
    })
}

/// Return whether the operator applies `manifest`. It leaves out
/// CustomResourceDefinitions, because applying them again restarts API
/// watches, and the Activation record, because applying the manifest the
/// build holds would overwrite `spec.source` through server-side apply.
fn operator_applies(manifest: &Value) -> bool {
    ResourceId::from_value(manifest).kind != "CustomResourceDefinition"
        && !kix::manifest::lifecycle::is_record(manifest)
}

/// What the binding check decided for a Queued record.
enum Binding {
    /// The build may be applied here.
    Accepted,
    /// The build belongs to another Kubernetes cluster, or names none where
    /// a bound one deployed: the record fails with this message.
    Refused(String),
    /// The operator may not read the `kube-system` Namespace: a grant of
    /// permission resolves it, so the record waits with this message.
    Forbidden(String),
}

/// Read `kix-packages.json` of the build the Queued `activation` names, for
/// the checks that run before the whole graph is loaded.
fn index_of(activation: &DynamicObject) -> Result<KixPackageIndex, OperatorError> {
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;
    read_index(&path).map_err(|e| OperatorError::StoreGraphError {
        path: path.display().to_string(),
        reason: e.to_string(),
    })
}

/// Check that the build `index` describes belongs to the Kubernetes cluster
/// the operator runs on ([`binding::check`]). An error means the check could
/// not run, so the reconcile is retried.
async fn check_binding(client: &Client, index: &KixPackageIndex) -> Result<Binding, OperatorError> {
    match binding::check(
        client,
        &Connection::InCluster,
        binding::Action::Deploy,
        &index.cluster,
        index.kubernetes.uid.as_deref(),
    )
    .await
    {
        Ok(()) => Ok(Binding::Accepted),
        Err(e) if e.is_forbidden() => Ok(Binding::Forbidden(e.to_string())),
        Err(
            e @ (BindingError::Mismatch { .. }
            | BindingError::Unbound { .. }
            | BindingError::UnboundRestored { .. }),
        ) => Ok(Binding::Refused(e.to_string())),
        Err(e) => Err(OperatorError::DiscoveryError(e.to_string())),
    }
}

/// What the version check decided for a Queued record.
enum VersionCheck {
    /// The build was checked against the version this cluster runs, or
    /// against none.
    Accepted,
    /// The cluster runs another version: the record fails with this message.
    Refused(String),
    /// The version could not be read: the record waits with this message.
    Unread(String),
}

/// Check that the build `index` describes was checked against the
/// Kubernetes version this cluster runs ([`kubernetes_version::check`]).
async fn check_version(client: &Client, index: &KixPackageIndex) -> VersionCheck {
    match kubernetes_version::check(
        client,
        &Connection::InCluster,
        &index.cluster,
        index.kubernetes.version.as_deref(),
        index.kubernetes.version_from.as_deref(),
    )
    .await
    {
        Ok(()) => VersionCheck::Accepted,
        Err(e) if e.is_mismatch() => VersionCheck::Refused(e.to_string()),
        Err(e) => VersionCheck::Unread(e.to_string()),
    }
}

/// Map a [`LivePlanError`] to the corresponding [`OperatorError`] variant.
fn operator_error(e: LivePlanError) -> OperatorError {
    match e {
        LivePlanError::Fetch(_) | LivePlanError::Domain(_) => {
            OperatorError::DiscoveryError(e.to_string())
        }
        LivePlanError::Graph(_) | LivePlanError::Marker(_) => {
            OperatorError::GraphError(e.to_string())
        }
        LivePlanError::Tenancy(_) | LivePlanError::ReadForbidden(_) => {
            OperatorError::ReconcileError(e.to_string())
        }
    }
}

/// Reconcile an Activation resource according to its current phase.
pub async fn reconcile_activation(
    activation: Arc<DynamicObject>,
    ctx: Arc<Context>,
) -> Result<Action, OperatorError> {
    let name = activation.metadata.name.as_deref().unwrap_or("<unnamed>");
    // Records are looked up by the cluster label, so a record that names no
    // cluster finds only itself. The sweep and the prune get an empty name
    // instead, under which no record counts as this cluster's own.
    let own_cluster = cluster_of(&activation).unwrap_or_default();
    let cluster = if own_cluster.is_empty() {
        name.to_string()
    } else {
        own_cluster.clone()
    };

    if activation.metadata.deletion_timestamp.is_some() {
        return handle_delete(&activation, &ctx, name, &own_cluster).await;
    }

    let record = Record::of(&activation);
    let phase = record.phase.as_str();
    let request = record.pending_request();

    match phase {
        // A person asked to deploy this record again: `kix rollback
        // --operator` to an earlier record, or `kix deploy --operator` of a
        // build whose deploy failed or that `kix deploy --only` partly
        // deployed. Queue it and deploy it in this reconcile, as a new record
        // that supersedes the current one.
        s if s == PHASE_SUPERSEDED || s == PHASE_FAILED || s == PHASE_PARTIAL => match request {
            Some(request) => {
                tracing::info!(name, phase, "Re-queueing activation for new spec.request");
                ctx.records
                    .requeue(name, request)
                    .await
                    .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                let mut queued = record.clone();
                queued.phase = PHASE_QUEUED.to_string();
                queued.started_request = Some(request.to_string());
                start_queued(&activation, &ctx, name, &cluster, &queued).await
            }
            // Failed and Partial are terminal. The deploy that owned the
            // record has stopped, and the next one folds its closure into the
            // plan and supersedes it.
            None => {
                tracing::debug!(
                    name,
                    phase,
                    "Skipping activation with no pending spec.request"
                );
                Ok(Action::await_change())
            }
        },

        // Ignore records without `spec.source`. The CLI creates an Activation
        // record before marking it `Deploying`, so a newly created CLI record
        // briefly has an empty phase. Adopting it here would supersede the
        // Active record before the CLI applies anything, attach the operator
        // finalizer to a CLI-owned record, and run two writers concurrently.
        s if s.is_empty() || s == PHASE_QUEUED => {
            if source_path(&activation).is_none() {
                tracing::debug!(name, "record has no spec.source; not ours to drive");
                return Ok(Action::await_change());
            }
            tracing::info!(name, cluster = %cluster, "Processing Queued activation");
            start_queued(&activation, &ctx, name, &cluster, &record).await
        }

        // Active and Degraded records run drift detection on requeue. Degraded
        // means the last deploy completed with some failures, but the CR is
        // still the current intended state.
        s if s == PHASE_ACTIVE || s == PHASE_DEGRADED => {
            // A record that `kix deploy` wrote without `--operator` names no
            // build the operator can read, so the operator neither repairs it
            // nor adds its finalizer.
            if source_path(&activation).is_none() {
                tracing::debug!(
                    name,
                    "Skipping Active or Degraded Activation with no spec.source.path (deployed without --operator)"
                );
                return Ok(Action::await_change());
            }
            // The record stays current while a newer one deploys, and its
            // repair would undo that deploy, so it waits.
            if let Some(newer) = newer_deploy(&ctx.records, &cluster, name).await? {
                tracing::info!(name, newer = %newer, "Waiting while another Activation for this cluster is queued or deploying");
                return Ok(Action::requeue(QUEUED_REQUEUE_INTERVAL));
            }

            ensure_finalizer(&ctx.records, name, &activation).await?;

            // A request on the current record deploys its build again, as a
            // `kix deploy` of the build already deployed does. The record
            // stays current throughout, and the checks for a Queued record
            // do not run, because this build already runs here.
            let Some(request) = request else {
                return run_reconcile(&activation, &ctx, name, Reconcile::Repair).await;
            };
            tracing::info!(name, "Redeploying current activation for new spec.request");
            ctx.records
                .start_request(name, request)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
            match run_reconcile(&activation, &ctx, name, Reconcile::Redeploy).await {
                Ok(action) => {
                    finish_request(&ctx, name, Some(request)).await?;
                    Ok(action)
                }
                // The record stays current, and a later reconcile repairs it
                // but never runs this request again. The request is answered
                // with the failure now, so the command waiting on it stops.
                Err(e) => {
                    let reason = redeploy_failed_reason(&record.phase, &e);
                    ctx.records
                        .fail_request(name, request, &reason)
                        .await
                        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
                    Err(e)
                }
            }
        }

        // Resume an interrupted operator deployment. Records without
        // `spec.source` belong to an in-flight CLI `kix deploy` and must not
        // be adopted by the operator.
        s if s == PHASE_DEPLOYING => {
            if source_path(&activation).is_none() {
                tracing::debug!(
                    name,
                    "Deploying record has no spec.source; not ours to drive"
                );
                return Ok(Action::await_change());
            }
            tracing::info!(name, "Resuming Deploying activation");
            ensure_finalizer(&ctx.records, name, &activation).await?;
            let action = run_reconcile(&activation, &ctx, name, Reconcile::Resume).await?;
            finish_request(&ctx, name, record.started_request.as_deref()).await?;
            Ok(action)
        }

        _ => {
            tracing::debug!(name, phase, "Unknown phase, skipping");
            Ok(Action::requeue(requeue_interval()))
        }
    }
}

/// Return the name of a record of Kix cluster `cluster`, other than `name`,
/// that the operator has queued or is deploying, or `None` when there is
/// none.
///
/// Records without `spec.source` are left out. A direct `kix deploy` writes
/// them, and one whose process died stays Deploying with nothing to resume
/// it.
async fn newer_deploy(
    records: &Records,
    cluster: &str,
    name: &str,
) -> Result<Option<String>, OperatorError> {
    let lifecycle =
        |e: kix::cluster::activation::RecordsError| OperatorError::LifecycleError(e.to_string());
    let queued = records.queued(cluster).await.map_err(lifecycle)?;
    let deploying = records.deploying(cluster).await.map_err(lifecycle)?;
    Ok(queued
        .into_iter()
        .chain(deploying.into_iter().filter(|r| r.operator_driven))
        .map(|r| r.name)
        .find(|n| n != name))
}

/// Start the deploy of Queued record `name` of Kix cluster `cluster`: start
/// its pending request, run the checks a new record gets, supersede older
/// Queued records, and deploy it. The current record stays current until
/// the deploy finishes, when the shared finalize step supersedes it.
async fn start_queued(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    cluster: &str,
    record: &Record,
) -> Result<Action, OperatorError> {
    // The request is started here, before the checks, so a refusal
    // answers it too and the command that waits on it stops.
    if let Some(request) = record.pending_request() {
        ctx.records
            .start_request(name, request)
            .await
            .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
    }

    // A build bound to another Kubernetes cluster, or an unbound one
    // where a bound build has deployed, fails here, before any other
    // record is superseded and before anything is applied. A 403 on
    // the Namespace leaves the record Queued and retries, since a
    // grant of permission resolves it. A build checked against a
    // Kubernetes version this cluster does not run fails the same
    // way. Only a Queued record gets these checks: an Active record
    // keeps being repaired after a Kubernetes upgrade.
    let events = || K8sEventObserver::new(ctx.events.clone(), activation, keys::API_VERSION);
    let index = match index_of(activation) {
        Ok(index) => index,
        Err(e) => {
            let action =
                after_failed_attempt(activation, ctx, &ctx.records, name, &e.to_string()).await?;
            finish_request(ctx, name, record.request.as_deref()).await?;
            return Ok(action);
        }
    };
    match check_binding(&ctx.client, &index).await? {
        Binding::Accepted => {}
        Binding::Refused(reason) => {
            tracing::warn!(name, %reason, "Refusing the Queued activation");
            ctx.records
                .fail_queued(name, &reason)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
            events().warn_now("BindingRefused", &reason).await;
            return Ok(Action::await_change());
        }
        Binding::Forbidden(reason) => {
            tracing::warn!(name, %reason, "Cannot check the Queued activation's binding yet");
            events().warn_now("BindingUnchecked", &reason).await;
            return Err(OperatorError::DiscoveryError(reason));
        }
    }
    match check_version(&ctx.client, &index).await {
        VersionCheck::Accepted => {}
        VersionCheck::Refused(reason) => {
            tracing::warn!(name, %reason, "Refusing the Queued activation");
            ctx.records
                .fail_queued(name, &reason)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
            events().warn_now("KubernetesVersionRefused", &reason).await;
            return Ok(Action::await_change());
        }
        VersionCheck::Unread(reason) => {
            tracing::warn!(name, %reason, "Cannot check the Queued activation's Kubernetes version yet");
            events()
                .warn_now("KubernetesVersionUnchecked", &reason)
                .await;
            return Err(OperatorError::DiscoveryError(reason));
        }
    }

    // The operator writes this deploy with its own Kix, so the build fails
    // here when the operator's Kix would skip a required stop, or when a
    // newer minor of Kix made the cluster's last deploy.
    let old_active = ctx
        .records
        .active(cluster)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
    let head = head::read(&ctx.client, cluster).await?;
    let last = stops::LastWrite::of(head.as_ref().and_then(|h| h.writer()), old_active.as_ref());
    if let Err(refusal) = stops::check(&last, kix::version::running(), &ctx.required_stops) {
        let reason = refusal.to_string();
        tracing::warn!(name, %reason, "Refusing the Queued activation");
        ctx.records
            .fail_queued(name, &reason)
            .await
            .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
        events().warn_now(refusal.event_reason(), &reason).await;
        return Ok(Action::await_change());
    }

    let queued = ctx
        .records
        .queued(cluster)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

    // If a newer Queued activation exists, supersede this one.
    if let Some(newest) = queued.first()
        && newest.name != name
    {
        tracing::info!(
            name,
            newest = %newest.name,
            "Newer Queued activation exists, superseding self"
        );
        ctx.records
            .supersede(name)
            .await
            .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
        return Ok(Action::await_change());
    }

    // The operator deploys one record of a Kix cluster at a time. A record
    // it is still deploying, or will resume after a restart, finishes first,
    // and this one supersedes it afterwards.
    let deploying = ctx
        .records
        .deploying(cluster)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
    if let Some(running) = deploying
        .iter()
        .find(|r| r.operator_driven && r.name != name)
    {
        tracing::info!(
            name,
            deploying = %running.name,
            "Waiting for in-progress deploy of this cluster to finish"
        );
        return Ok(Action::requeue(QUEUED_REQUEUE_INTERVAL));
    }

    // Supersede any older Queued activations.
    for q in &queued {
        if q.name != name {
            tracing::info!(name, superseding = %q.name, "Superseding older Queued activation");
            ctx.records
                .supersede(&q.name)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
        }
    }

    ensure_finalizer(&ctx.records, name, activation).await?;

    let action = run_reconcile(activation, ctx, name, Reconcile::Start).await?;
    finish_request(ctx, name, record.request.as_deref()).await?;
    Ok(action)
}

/// Record that the run of `request` on record `name` finished, so the
/// command that submitted it stops waiting. A record with no request has
/// nothing to record.
async fn finish_request(
    ctx: &Context,
    name: &str,
    request: Option<&str>,
) -> Result<(), OperatorError> {
    let Some(request) = request else {
        return Ok(());
    };
    ctx.records
        .finish_request(name, request)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))
}

/// Which reconcile of an Activation record the operator runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reconcile {
    /// Start the deploy of a Queued record, which marks it Deploying. This
    /// happens once for each deploy someone submits.
    Start,
    /// Deploy the current record's build again for a request on it. The
    /// record stays Active or Degraded throughout.
    Redeploy,
    /// Resume a Deploying record, after the operator restarted or a run
    /// stopped at a failure.
    Resume,
    /// Correct drift from an Active or Degraded record's build, on every
    /// requeue.
    Repair,
}

impl Reconcile {
    /// Return whether the run writes the record's lifecycle (`begin_deploy`,
    /// `record_waves`, and `finalize_deploy`). A repair leaves the record's
    /// phase alone.
    fn manages_lifecycle(self) -> bool {
        self != Reconcile::Repair
    }

    /// Return whether the plan reads the last runs of its Jobs, so that a
    /// Job under `kix.run/rerun` whose last run failed runs again. Only the
    /// start of a deploy does, as each `kix deploy` does. The operator
    /// retries a resume and a repair, and would recreate a failing Job on
    /// every retry.
    fn reads_last_runs(self) -> bool {
        matches!(self, Reconcile::Start | Reconcile::Redeploy)
    }

    /// Return whether an attempt that fails counts toward
    /// [`Context::deploy_retries`]. Only the attempts to deploy a Queued or
    /// Deploying record do, whatever stopped them: the build could not be
    /// read, the cluster's objects could not be listed, or the run stopped.
    /// After a redeploy fails, the record is still current, and the next
    /// reconcile repairs it.
    fn counts_failed_runs(self) -> bool {
        matches!(self, Reconcile::Start | Reconcile::Resume)
    }

    /// Return what the run does when an object fails. A repair goes on with
    /// the other objects and skips only the dependents of the failed one.
    /// The operator never forces, so an object another field manager
    /// changed fails on every repair, and stopping there would leave every
    /// other object unrepaired. A deploy stops at the first failure, and the
    /// operator retries it.
    fn on_error(self) -> OnErrorPolicy {
        match self {
            Reconcile::Repair => OnErrorPolicy::Continue,
            Reconcile::Start | Reconcile::Redeploy | Reconcile::Resume => OnErrorPolicy::Stop,
        }
    }
}

/// Load the desired manifests from the record's build and plan them
/// against the live objects of its Kix cluster. Return `None` when the build
/// holds nothing the operator applies.
async fn sweep(
    activation: &DynamicObject,
    client: &Client,
    name: &str,
) -> Result<Option<LivePlan>, OperatorError> {
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;
    let graph = load_build(&path)?.into_graph();

    if graph.resources.is_empty() {
        tracing::warn!(name, "No manifests found in store graph");
        return Ok(None);
    }

    let managed_manifests: Vec<Value> = graph
        .resources
        .values()
        .map(|r| &r.manifest)
        .filter(|m| operator_applies(m))
        .cloned()
        .collect();

    if managed_manifests.is_empty() {
        tracing::debug!(name, "No managed manifests to reconcile");
        return Ok(None);
    }

    // The revisions name the whole build, as the CLI's do, so both name the
    // same revisions for one build. What the operator leaves out shows as an
    // object with no applied hash. The revisions are labelled with the
    // record's Kix cluster, which the cleanup lists them by. A record that
    // names none gets no revisions.
    let revisions = cluster_of(activation).map(|cluster| RevisionSet::of(&cluster, &graph));
    LivePlan::sweep(client, activation, &managed_manifests, revisions)
        .await
        .map(Some)
        .map_err(operator_error)
}

/// Take the Kix cluster's deploy lock, then load desired state, fetch live
/// state, diff, wave-plan, and apply. A repair holds the lock as a repair,
/// which gives way to a run that waits for it. When another run holds the
/// lock, try again after [`QUEUED_REQUEUE_INTERVAL`].
async fn run_reconcile(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    reconcile: Reconcile,
) -> Result<Action, OperatorError> {
    // A record with no cluster label uses the head named after itself.
    let cluster = cluster_of(activation)
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| name.to_string());
    let runs = ctx.runs_of(&cluster);
    let _one_at_a_time = runs.lock().await;
    let purpose = if reconcile == Reconcile::Repair {
        Purpose::Repair
    } else {
        Purpose::Deploy
    };
    let Some(lock) = ctx.take(&cluster, purpose, name).await? else {
        return Ok(Action::requeue(QUEUED_REQUEUE_INTERVAL));
    };
    let lock = Arc::new(lock);
    let result = run_locked(activation, ctx, name, reconcile, &lock).await;
    let yielded = lock.stopped() == Some(WritesStopped::Yielded);
    release(&lock).await;
    if yielded {
        tracing::info!(
            name,
            "Yielded the deploy lock to a waiting run; drift repair will retry later"
        );
        return Ok(Action::requeue(QUEUED_REQUEUE_INTERVAL));
    }
    result
}

/// Carry out [`run_reconcile`] once the operator holds `lock`. Every write
/// goes through the lock's guarded client.
async fn run_locked(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    reconcile: Reconcile,
    lock: &Arc<Lock>,
) -> Result<Action, OperatorError> {
    let client = lock.guarded(&ctx.client);
    let records = ctx.records.through(&client);
    let manage_lifecycle = reconcile.manages_lifecycle();
    let mut plan = match sweep(activation, &client, name).await {
        Ok(Some(plan)) => plan,
        Ok(None) => return Ok(Action::requeue(requeue_interval())),
        Err(e) if reconcile.counts_failed_runs() => {
            return after_failed_attempt(activation, ctx, &records, name, &e.to_string()).await;
        }
        Err(e) => return Err(e),
    };
    if reconcile.reads_last_runs() {
        match plan.read_last_runs().await {
            LastRuns::Read { failed } => {
                for rid in failed {
                    tracing::info!(name, resource = %rid, "unchanged Job failed on its last run and has no {} annotation; the deploy will report it as failed", keys::RERUN);
                }
            }
            LastRuns::Unreadable => {
                tracing::info!(
                    name,
                    "could not read every Job before starting; Kix will check live Jobs during the deploy"
                );
            }
        }
    }
    let foreign = plan.foreign();
    if foreign.objects > 0 {
        tracing::debug!(name, count = foreign.objects, clusters = ?foreign.clusters, "skipped live objects belonging to other Kix clusters");
    }
    if plan.unattributed() > 0 {
        tracing::info!(
            name,
            count = plan.unattributed(),
            "skipped live Kix-labeled objects with no matching Activation record, because Kix cannot tell which Kix cluster they belong to",
        );
    }
    for s in plan.shared_orphans() {
        tracing::info!(name, resource = %s.rid, clusters = ?s.clusters, "prune: {}", s.describe());
    }
    // The recorder counts a repeated Event on one Event, so a drift left in
    // place adds one Event, not one for every requeue.
    let events = K8sEventObserver::new(ctx.events.clone(), activation, keys::API_VERSION);
    for drift in plan.drift_not_reverted() {
        let message = drift_not_reverted_message(drift);
        tracing::warn!(name, resource = %drift.rid, "{message}");
        events.warn_now("DriftNotReverted", &message).await;
    }

    tracing::info!(
        name,
        apply = plan.applies(),
        orphans = plan.orphans().len(),
        unchanged = plan.unchanged(),
        lifecycle = manage_lifecycle,
        "Live change detection complete"
    );

    let config = SchedulerConfig {
        timeout: READINESS_TIMEOUT,
        on_error: reconcile.on_error(),
        // The stall watchdog cancels this token. A child token keeps that
        // cancel inside this run, and an operator shutdown still reaches it.
        cancel: ctx.shutdown.child(),
        concurrency: scheduler::CONCURRENCY,
        stall: StallPolicy::from_env(),
        // A new build is checked against the objects it leaves unchanged.
        // Drift repair of a running build runs every requeue, and an
        // unchanged object that never reports ready would fail the record
        // every cycle.
        check_unchanged: manage_lifecycle,
        names_flags: false,
    };

    // Compose two observers: tracing (structured logs) + K8s Events
    // (cluster-observable audit trail on the Activation CR).
    let observer: Arc<dyn DeployObserver> = Arc::new(CompositeObserver::new(vec![
        Arc::new(OperatorObserver::new(name)) as Arc<dyn DeployObserver>,
        Arc::new(K8sEventObserver::new(
            ctx.events.clone(),
            activation,
            keys::API_VERSION,
        )) as Arc<dyn DeployObserver>,
    ]));
    let result = plan
        .run(lock.clone(), manage_lifecycle, config, observer)
        .await;
    after_run(activation, ctx, &records, name, reconcile, result).await
}

/// Decide what follows a `reconcile` run of record `name` that ended with
/// `result`.
async fn after_run(
    activation: &DynamicObject,
    ctx: &Context,
    records: &Records,
    name: &str,
    reconcile: Reconcile,
    result: Result<DeployResult, DeployError>,
) -> Result<Action, OperatorError> {
    match result {
        // A repair goes on past a failed object, so its run ends without an
        // error. It returns one here, which logs the first failure and
        // brings the next repair after the error requeue.
        Ok(r) if reconcile == Reconcile::Repair && r.failed > 0 => {
            tracing::error!(
                name,
                configured = r.configured,
                pruned = r.pruned,
                failed = r.failed,
                "Repair finished, but some objects could not be repaired"
            );
            Err(OperatorError::ReconcileError(
                first_failure(&r)
                    .unwrap_or_else(|| format!("{} object(s) could not be repaired", r.failed)),
            ))
        }
        Ok(r) => {
            tracing::info!(
                name,
                created = r.created,
                configured = r.configured,
                unchanged = r.unchanged,
                pruned = r.pruned,
                failed = r.failed,
                lifecycle = reconcile.manages_lifecycle(),
                "Reconciliation complete"
            );
            Ok(Action::requeue(requeue_interval()))
        }
        // A run the operator's shutdown interrupted is resumed when the
        // operator starts again, and does not count as a failed attempt.
        Err(e) if !reconcile.counts_failed_runs() || ctx.shutdown.is_cancelled() => {
            tracing::error!(name, error = %e, "Reconciliation failed");
            Err(OperatorError::ReconcileError(stop_cause(&e)))
        }
        Err(e) => after_failed_attempt(activation, ctx, records, name, &stop_cause(&e)).await,
    }
}

/// Count the attempt to deploy record `name` that failed with `cause`, and
/// mark the record Failed once the deploy has been retried
/// [`Context::deploy_retries`] times. Return the error that requeues the next
/// retry, or an action that waits for a new request once the record is
/// Failed.
///
/// The count lives in the record's `status.failedAttempts`, so an operator
/// restart does not reset it. Starting a new request on the record clears it
/// ([`Records::start_request`] and [`Records::requeue`]).
async fn after_failed_attempt(
    activation: &DynamicObject,
    ctx: &Context,
    records: &Records,
    name: &str,
    cause: &str,
) -> Result<Action, OperatorError> {
    let lifecycle =
        |e: kix::cluster::activation::RecordsError| OperatorError::LifecycleError(e.to_string());
    let failed_before = records
        .get(name)
        .await
        .map_err(lifecycle)?
        .map_or(0, |r| r.failed_attempts);
    let attempts = failed_before.saturating_add(1);
    let retries = ctx.deploy_retries;
    let events = K8sEventObserver::new(ctx.events.clone(), activation, keys::API_VERSION);
    if attempts > retries {
        let current = match cluster_of(activation) {
            Some(cluster) => ctx
                .records
                .active(&cluster)
                .await
                .map_err(lifecycle)?
                .map(|r| r.name)
                .filter(|n| n != name),
            None => None,
        };
        let reason = gave_up_reason(attempts, retries, current.as_deref(), cause);
        if ctx
            .records
            .fail_attempt(name, attempts, &reason, true)
            .await
            .map_err(lifecycle)?
        {
            tracing::error!(name, attempts, error = %cause, "Stopped retrying deploy; marked Activation Failed");
            events
                .warn_now(
                    "DeployFailed",
                    &format!(
                        "The Kix operator stopped retrying after {attempts} failed {} and marked this Activation Failed. See status.failure.reason or earlier Warning Events for the cause, fix the problem, and run `kix deploy --operator` or `kix rollback --operator` again.",
                        plural(attempts, "attempt", "attempts"),
                    ),
                )
                .await;
            return Ok(Action::await_change());
        }
    } else {
        records
            .fail_attempt(name, attempts, cause, false)
            .await
            .map_err(lifecycle)?;
        tracing::warn!(name, attempts, retries, error = %cause, "Deploy attempt failed; retrying in 30s");
        events
            .warn_now(
                "DeployRetrying",
                &format!(
                    "Attempt {attempts} of {} failed. The Kix operator will retry in {} seconds. See status.failure.reason or earlier Warning Events for the cause.",
                    u64::from(retries) + 1,
                    ERROR_REQUEUE_INTERVAL.as_secs(),
                ),
            )
            .await;
    }
    Err(OperatorError::ReconcileError(cause.to_string()))
}

/// Return the message for a drifted object the operator leaves as it is.
fn drift_not_reverted_message(drift: &kix::plan::live::DriftNotReverted) -> String {
    let resource = drift.rid.display_id();
    let owners = if drift.owners.is_empty() {
        "another field manager now owns fields".to_string()
    } else {
        let named: Vec<String> = drift
            .owners
            .iter()
            .map(|o| format!("{} now owns {}", o.manager, o.fields.join(", ")))
            .collect();
        named.join("; ")
    };
    format!(
        "{resource} changed on the cluster since Kix applied it: {owners}. The Kix operator never takes fields from another field manager, so it left {resource} as it is. Run `kix deploy` to take the fields back, or declare them with `ownership.cede` if that manager is meant to own them."
    )
}

/// Return what stopped a run: the first object that failed and why, or the
/// run's own error when no object failed.
fn stop_cause(error: &DeployError) -> String {
    first_failure(error.partial()).unwrap_or_else(|| error.to_string())
}

/// Return the first object of `result` that failed and why, or `None` when
/// none failed.
fn first_failure(result: &DeployResult) -> Option<String> {
    result
        .failures
        .first()
        .map(|f| format!("{}: {}", f.node, f.message))
}

/// Return the `status.failure.reason` of a record whose deploy the operator
/// stopped retrying after `attempts` failed runs, while record `current`
/// is the cluster's current record. `kix deploy --operator` and `kix
/// rollback --operator` print it.
fn gave_up_reason(attempts: u32, retries: u32, current: Option<&str>, cause: &str) -> String {
    let restore = match current {
        Some(current) => format!(
            "Activation '{current}' remains the current deployment, and the operator will restore the cluster to match it. "
        ),
        None => String::new(),
    };
    format!(
        "the Kix operator stopped after {attempts} failed {} ({DEPLOY_RETRIES_ENV} is {retries} on the operator) and marked this Activation Failed. \
         {restore}Fix the cause below, then run `kix deploy --operator` or `kix rollback --operator` again.\n\n  \
         Last failure:\n    {}",
        plural(attempts, "attempt", "attempts"),
        cause.replace('\n', "\n    "),
    )
}

/// Return the reason `kix deploy --operator` prints when the redeploy of a
/// record in `phase`, which stays current, failed with `error`.
fn redeploy_failed_reason(phase: &str, error: &OperatorError) -> String {
    let cause = match error {
        OperatorError::ReconcileError(cause) => cause.clone(),
        other => other.to_string(),
    };
    format!(
        "the Kix operator could not redeploy the current build. \
         This Activation stays {phase}, and the operator continues repairing drift for this build. \
         It does not retry a failed redeploy. \
         Fix the cause below, then run `kix deploy --operator` again.\n\n  \
         Cause:\n    {}",
        cause.replace('\n', "\n    "),
    )
}

fn plural<'a>(n: u32, one: &'a str, many: &'a str) -> &'a str {
    if n == 1 { one } else { many }
}

/// Handle deletion of an Activation CR (finalizer cleanup).
///
/// Only Active, Deploying, or Degraded activations trigger resource cleanup,
/// keeping kinds protected by `never_pruned` and objects still referenced by
/// another Kix cluster's active build (see [`delete_closure`]). Superseded
/// activations simply have their finalizer removed because the Active
/// activation now owns their resources.
async fn handle_delete(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    cluster: &str,
) -> Result<Action, OperatorError> {
    let finalizers = activation.metadata.finalizers.as_deref().unwrap_or(&[]);

    if !finalizers.contains(&FINALIZER.to_string()) {
        return Ok(Action::await_change());
    }

    let record = Record::of(activation);
    let phase = record.phase.as_str();

    if phase == PHASE_ACTIVE || phase == PHASE_DEPLOYING || phase == PHASE_DEGRADED {
        tracing::info!(
            name,
            phase,
            "Handling Activation deletion — cleaning up resources"
        );

        if let Some(path) = source_path(activation)
            && let Ok(manifests) = load_manifests(&path)
        {
            let all_rids: Vec<ResourceId> = manifests
                .iter()
                .map(ResourceId::from_value)
                .filter(|rid| !kix::manifest::lifecycle::is_record_kind(&rid.kind))
                .collect();

            let mut order = DeleteOrder::of_manifests(&manifests);
            order.retain(|rid| all_rids.contains(rid));

            // A record with no cluster label uses the head named after
            // itself.
            let head_of = if cluster.is_empty() { name } else { cluster };
            let runs = ctx.runs_of(head_of);
            let _one_at_a_time = runs.lock().await;
            let Some(lock) = ctx.take(head_of, Purpose::Teardown, name).await? else {
                return Ok(Action::requeue(QUEUED_REQUEUE_INTERVAL));
            };
            let deleted = delete_closure(
                &lock.guarded(&ctx.client),
                cluster,
                name,
                order,
                &ctx.shutdown,
            )
            .await;
            release(&lock).await;
            if let Err(e @ OperatorError::DeletionUnfinished { .. }) = &deleted
                && !ctx.shutdown.is_cancelled()
            {
                K8sEventObserver::new(ctx.events.clone(), activation, keys::API_VERSION)
                    .warn_now("DeletionUnfinished", &e.to_string())
                    .await;
            }
            deleted?;
        }
    } else {
        tracing::info!(
            name,
            phase,
            "Activation is Superseded/Queued — removing finalizer without resource cleanup"
        );
    }

    let rest: Vec<String> = finalizers
        .iter()
        .filter(|f| f.as_str() != FINALIZER)
        .cloned()
        .collect();
    ctx.records
        .set_finalizers(name, &rest)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

    tracing::info!(name, "Finalizer removed, Activation can be deleted");
    Ok(Action::await_change())
}

/// Delete a deleted record's resources in `order` through
/// [`prune_guard::delete_in_order`], which waits for each to be gone,
/// preserving any object still referenced by another Kix cluster's current
/// build (such as a shared ClusterRole), and log what happened to each.
/// Namespaces and CRDs stay, which also keeps the CRD this operator's own
/// Activation records live in. `cluster` is the record's Kix cluster;
/// because the record remains listed while its finalizer is present, its own
/// hash still counts as belonging to `cluster`.
///
/// Each delete waits up to [`READINESS_TIMEOUT`] without progress for its
/// object to be gone, and `shutdown` stops the teardown. Return
/// [`OperatorError::DeletionUnfinished`], naming what is left, when a delete
/// failed, did not finish, or did not start, so the record keeps its
/// finalizer and the controller tries again after its error requeue.
async fn delete_closure(
    client: &Client,
    cluster: &str,
    name: &str,
    order: DeleteOrder,
    shutdown: &CancelToken,
) -> Result<(), OperatorError> {
    /// How many objects the error names before it counts the rest.
    const NAMED: usize = 5;
    let mut unfinished = 0usize;
    let mut leftovers: Vec<String> = Vec::new();
    let mut stuck_any = false;
    let mut report = |rid: &ResourceId, step: Step<'_>| {
        let removal = match step {
            Step::Waiting(status) => {
                tracing::debug!(name, resource = %rid, status, "Waiting for the object to be deleted");
                return;
            }
            Step::Done(removal) => removal,
        };
        if removal.unfinished() {
            unfinished += 1;
            let why = match removal {
                Removal::Stuck(stuck) if stuck.finalizers.is_empty() => {
                    "still being deleted".to_string()
                }
                Removal::Stuck(stuck) => {
                    format!("waiting for {}", stuck.finalizers.join(", "))
                }
                Removal::HeldBack { by, .. } => format!("{by} still needs it"),
                Removal::Pruned(Pruned::Changed(_)) => {
                    "changed while being deleted; tried again on the next attempt".to_string()
                }
                Removal::Cycle => "in a dependency cycle".to_string(),
                Removal::Cancelled => "not deleted before the operator stopped".to_string(),
                Removal::Failed(e) => e.to_string(),
                _ => String::new(),
            };
            leftovers.push(format!("{rid} ({why})"));
        }
        match removal {
            Removal::NeverPruned => tracing::info!(
                name,
                resource = %rid,
                "Kept while deleting Activation: Kix never deletes this kind automatically. Delete it with kubectl if you want to remove it"
            ),
            Removal::Pruned(Pruned::Deleted { .. } | Pruned::AlreadyDeleting { .. }) => {
                tracing::info!(name, resource = %rid, "Deleted")
            }
            Removal::Pruned(Pruned::Gone | Pruned::NotServed) => {}
            Removal::Pruned(kept) => {
                let reason = kept.kept_reason().unwrap_or_default();
                tracing::info!(name, resource = %rid, "prune: {reason}");
            }
            Removal::Stuck(stuck) => {
                stuck_any = true;
                tracing::warn!(name, resource = %rid, "{}", readiness::stuck_message(rid, stuck))
            }
            Removal::HeldBack { by, shared } => tracing::info!(
                name,
                resource = %rid,
                "{}",
                readiness::held_back_reason(rid, by, DeletePath::Teardown, *shared)
            ),
            Removal::Cycle => tracing::warn!(
                name,
                resource = %rid,
                "{}",
                readiness::cycle_reason(rid)
            ),
            Removal::Cancelled => {}
            Removal::Failed(e) => {
                tracing::warn!(name, resource = %rid, error = %e, "Failed to delete")
            }
        }
    };
    prune_guard::delete_in_order(
        client,
        cluster,
        order,
        READINESS_TIMEOUT,
        shutdown,
        &mut report,
    )
    .await
    .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;
    if stuck_any {
        tracing::warn!(
            name,
            "{}",
            readiness::stuck_explanation(DeletePath::Teardown)
        );
    }
    if unfinished > 0 {
        let more = leftovers.len().saturating_sub(NAMED);
        leftovers.truncate(NAMED);
        let mut named = leftovers.join("; ");
        if more > 0 {
            named.push_str(&format!("; and {more} more"));
        }
        return Err(OperatorError::DeletionUnfinished {
            count: unfinished,
            leftovers: named,
        });
    }
    Ok(())
}

/// Ensure the finalizer is set on the Activation CR.
async fn ensure_finalizer(
    records: &Records,
    name: &str,
    activation: &DynamicObject,
) -> Result<(), OperatorError> {
    let finalizers = activation.metadata.finalizers.as_deref().unwrap_or(&[]);

    if finalizers.contains(&FINALIZER.to_string()) {
        return Ok(());
    }

    let mut new_finalizers: Vec<String> = finalizers.to_vec();
    new_finalizers.push(FINALIZER.to_string());
    records
        .set_finalizers(name, &new_finalizers)
        .await
        .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

    tracing::info!(name, "Added finalizer {FINALIZER}");
    Ok(())
}

/// Requeue failed reconciliations after [`ERROR_REQUEUE_INTERVAL`].
pub fn error_policy(
    _activation: Arc<DynamicObject>,
    error: &OperatorError,
    _ctx: Arc<Context>,
) -> Action {
    tracing::warn!(error = %error, "Error during reconciliation, requeueing");
    Action::requeue(ERROR_REQUEUE_INTERVAL)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::cluster::discovery;

    /// Only the start of a submitted deploy reruns a failed Job, once. The
    /// operator retries a resume and a repair, so they must not.
    #[test]
    fn only_the_start_of_a_deploy_reads_last_runs() {
        assert!(Reconcile::Start.reads_last_runs() && Reconcile::Redeploy.reads_last_runs());
        assert!(!Reconcile::Resume.reads_last_runs());
        assert!(!Reconcile::Repair.reads_last_runs());
        assert!(Reconcile::Start.manages_lifecycle() && Reconcile::Resume.manages_lifecycle());
        assert!(Reconcile::Redeploy.manages_lifecycle());
        assert!(!Reconcile::Repair.manages_lifecycle());
        assert!(Reconcile::Start.counts_failed_runs() && Reconcile::Resume.counts_failed_runs());
        assert!(
            !Reconcile::Redeploy.counts_failed_runs() && !Reconcile::Repair.counts_failed_runs()
        );
    }
    use kix::cluster::fake_api::{FakeApi, kube_system};
    use serde_json::json;

    const HERE: &str = "9f8e7d6c-5b4a-4321-8765-0fedcba98765";
    const ELSEWHERE: &str = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";

    /// A Queued record of cluster `a` whose build, in a temporary result
    /// directory, names the Kubernetes cluster `kubernetes_uid` and was
    /// checked against Kubernetes `k8s_version`.
    fn queued(dir: &Path, kubernetes_uid: Option<&str>, k8s_version: Option<&str>) -> Value {
        queued_from(dir, kubernetes_uid, k8s_version, None)
    }

    /// As [`queued`], with `k8s_version` supplied by the interface file of
    /// the platform `version_from`.
    fn queued_from(
        dir: &Path,
        kubernetes_uid: Option<&str>,
        k8s_version: Option<&str>,
        version_from: Option<&str>,
    ) -> Value {
        let index = json!({
            "cluster": "a",
            "kubernetes": {
                "uid": kubernetes_uid,
                "version": k8s_version,
                "versionFrom": version_from,
            },
            "packages": {},
        });
        std::fs::write(dir.join("kix-packages.json"), index.to_string()).unwrap();
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-new",
                "labels": { (keys::CLUSTER_LABEL): "a" },
            },
            "spec": {
                "cluster": "a",
                "source": { "type": "storePath", "path": dir.display().to_string() },
            },
        })
    }

    /// Reconcile `queued` on a fake holding `objects`, and return the record
    /// afterwards.
    async fn reconcile_queued(objects: Vec<Value>, queued: Value) -> (FakeApi, DynamicObject) {
        let api = FakeApi::new(objects);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let resource = records.watch_resource().clone();
        let ctx = Arc::new(Context {
            client,
            records,
            required_stops: stops::required_stops(),
            shutdown: CancelToken::new(),
            events: crate::k8s_events::recorder(api.client(), None),
            deploy_retries: DEFAULT_DEPLOY_RETRIES,
            holder: Holder::operator("kix", None),
            runs: Default::default(),
        });
        let activation: DynamicObject = serde_json::from_value(queued).unwrap();
        reconcile_activation(Arc::new(activation), ctx.clone())
            .await
            .unwrap();
        let after = kube::Api::<DynamicObject>::all_with(ctx.client.clone(), &resource)
            .get("a-new")
            .await
            .unwrap();
        (api, after)
    }

    /// A Queued build bound to another Kubernetes cluster is marked Failed
    /// with the reason, and the Active record is left alone.
    #[tokio::test]
    async fn a_queued_build_bound_elsewhere_fails_before_anything_is_superseded() {
        let dir = tempfile::tempdir().unwrap();
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
            },
            "status": { "phase": PHASE_ACTIVE },
        });
        let record = queued(dir.path(), Some(ELSEWHERE), None);
        let (api, after) =
            reconcile_queued(vec![kube_system(HERE), active, record.clone()], record).await;
        assert_eq!(after.data["status"]["phase"], PHASE_FAILED);
        let reason = after.data["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains(&format!("`cluster.kubernetes.uid` in 'a':    {ELSEWHERE}"))
                && reason.contains("Nothing was applied"),
            "{reason}"
        );
        let supersedes: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| r.contains("a-old"))
            .collect();
        assert!(supersedes.is_empty(), "{supersedes:?}");
    }

    /// An unbound Queued build on a Kubernetes cluster where a bound build
    /// deployed fails the same way, naming that build's cluster.
    #[tokio::test]
    async fn an_unbound_queued_build_fails_where_a_bound_build_deployed() {
        let dir = tempfile::tempdir().unwrap();
        let bound = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "lab1-1",
                "labels": { (keys::CLUSTER_LABEL): "lab1", (keys::KUBERNETES_UID): HERE },
            },
            "status": { "phase": PHASE_ACTIVE },
        });
        let record = queued(dir.path(), None, None);
        let (_, after) =
            reconcile_queued(vec![kube_system(HERE), bound, record.clone()], record).await;
        assert_eq!(after.data["status"]["phase"], PHASE_FAILED);
        let reason = after.data["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains(&format!("is locked to UID '{HERE}' by cluster 'lab1'")),
            "{reason}"
        );
    }

    /// A 403 on the Namespace leaves the Queued record as it is and retries,
    /// since a grant to the operator's service account resolves it.
    #[tokio::test]
    async fn a_forbidden_namespace_read_leaves_the_record_queued() {
        let dir = tempfile::tempdir().unwrap();
        let record = queued(dir.path(), Some(HERE), None);
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 403);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let resource = records.watch_resource().clone();
        let ctx = Arc::new(Context {
            client,
            records,
            required_stops: stops::required_stops(),
            shutdown: CancelToken::new(),
            events: crate::k8s_events::recorder(api.client(), None),
            deploy_retries: DEFAULT_DEPLOY_RETRIES,
            holder: Holder::operator("kix", None),
            runs: Default::default(),
        });
        let activation: DynamicObject = serde_json::from_value(record).unwrap();
        let err = reconcile_activation(Arc::new(activation), ctx.clone())
            .await
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("to the operator's service account; the operator will retry"),
            "{err}"
        );
        let after = kube::Api::<DynamicObject>::all_with(ctx.client.clone(), &resource)
            .get("a-new")
            .await
            .unwrap();
        assert!(after.data.get("status").is_none(), "{:?}", after.data);
    }

    /// Reconcile `record` on `api`, which may fail, and return the record
    /// afterwards.
    async fn reconcile_on(api: &FakeApi, record: Value) -> (Result<Action, OperatorError>, Value) {
        reconcile_with_stops(api, record, stops::required_stops()).await
    }

    /// As [`reconcile_on`], with `required_stops` in place of the built-in
    /// list.
    async fn reconcile_with_stops(
        api: &FakeApi,
        record: Value,
        required_stops: Vec<Version>,
    ) -> (Result<Action, OperatorError>, Value) {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        let resource = records.watch_resource().clone();
        let ctx = Arc::new(Context {
            client,
            records,
            required_stops,
            shutdown: CancelToken::new(),
            events: crate::k8s_events::recorder(api.client(), None),
            deploy_retries: DEFAULT_DEPLOY_RETRIES,
            holder: Holder::operator("kix", None),
            runs: Default::default(),
        });
        let name = record["metadata"]["name"].as_str().unwrap().to_string();
        let activation: DynamicObject = serde_json::from_value(record).unwrap();
        let result = reconcile_activation(Arc::new(activation), ctx.clone()).await;
        let after = kube::Api::<DynamicObject>::all_with(ctx.client.clone(), &resource)
            .get(&name)
            .await
            .unwrap();
        (result, after.data)
    }

    /// A Queued record waits while the operator still deploys another
    /// record of the same Kix cluster, and changes nothing meanwhile.
    #[tokio::test]
    async fn a_queued_record_waits_for_a_deploying_one() {
        let dir = tempfile::tempdir().unwrap();
        let deploying = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
            },
            "spec": { "cluster": "a", "source": { "type": "storePath", "path": "/nonexistent" } },
            "status": { "phase": PHASE_DEPLOYING },
        });
        let record = queued(dir.path(), Some(HERE), None);
        let api = FakeApi::new(vec![kube_system(HERE), deploying, record.clone()]);
        let (result, after) = reconcile_on(&api, record).await;
        assert!(
            matches!(result, Ok(ref action) if *action == Action::requeue(QUEUED_REQUEUE_INTERVAL)),
            "{result:?}"
        );
        assert!(after.get("status").is_none(), "{after}");
        let writes: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| !r.starts_with("GET"))
            .collect();
        assert!(writes.is_empty(), "{writes:?}");
    }

    /// A Queued build checked against another Kubernetes version is marked
    /// Failed with the value to set, and the Active record is left alone.
    #[tokio::test]
    async fn a_queued_build_for_another_kubernetes_version_fails_before_anything_is_superseded() {
        let dir = tempfile::tempdir().unwrap();
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
            },
            "status": { "phase": PHASE_ACTIVE },
        });
        let record = queued(dir.path(), Some(HERE), Some("1.30"));
        let api = FakeApi::new(vec![kube_system(HERE), active, record.clone()]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        let (result, after) = reconcile_on(&api, record).await;
        result.unwrap();
        assert_eq!(after["status"]["phase"], PHASE_FAILED);
        let reason = after["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains("`k8sVersion` in 'a':  1.30")
                && reason.contains("Live cluster version:         v1.31.4+k3s1")
                && reason.contains("Set `k8sVersion = \"1.31\";` in 'a's definition")
                && reason.contains("Nothing was applied"),
            "{reason}"
        );
        let supersedes: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| r.contains("a-old"))
            .collect();
        assert!(supersedes.is_empty(), "{supersedes:?}");
    }

    /// A Queued build whose version came from a platform's interface file
    /// fails with the message that names the platform.
    #[tokio::test]
    async fn a_queued_build_with_an_inherited_version_names_the_platform() {
        let dir = tempfile::tempdir().unwrap();
        let record = queued_from(dir.path(), Some(HERE), Some("1.30"), Some("prod"));
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        let (result, after) = reconcile_on(&api, record).await;
        result.unwrap();
        assert_eq!(after["status"]["phase"], PHASE_FAILED);
        let reason = after["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains("it loads 'prod's interface file with `kix.interface`")
                && reason.contains("Export a new interface file from 'prod'"),
            "{reason}"
        );
    }

    /// When `/version` cannot be read, the Queued record stays as it is, a
    /// Warning event says why, and the reconcile is retried.
    #[tokio::test]
    async fn an_unreadable_version_leaves_the_record_queued_with_an_event() {
        let dir = tempfile::tempdir().unwrap();
        let record = queued(dir.path(), Some(HERE), Some("1.31"));
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        api.fail_next("/version", 1, 503);
        let (result, after) = reconcile_on(&api, record).await;
        let err = result.unwrap_err().to_string();
        assert!(
            err.contains("could not read the Kubernetes version from") && err.contains("HTTP 503 "),
            "{err}"
        );
        assert!(after.get("status").is_none(), "{after:?}");
        let events: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| r.starts_with("POST ") && r.contains("/events"))
            .collect();
        assert_eq!(events.len(), 1, "{:?}", api.requests());
    }

    /// A Queued build on a cluster that an older Kix last deployed fails
    /// when the operator's Kix would skip a required stop, and the Active
    /// record is left alone.
    #[tokio::test]
    async fn a_queued_build_that_skips_a_required_stop_fails_before_anything_is_superseded() {
        let dir = tempfile::tempdir().unwrap();
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): "a",
                },
            },
            "status": {
                "phase": PHASE_ACTIVE,
                (keys::RECEIPT_FIELD): { "builder": { "kixVersion": "0.8.0" } },
            },
        });
        let record = queued(dir.path(), Some(HERE), None);
        let api = FakeApi::new(vec![kube_system(HERE), active, record.clone()]);
        // The running Kix is 0.10 or newer, past the stop's minor.
        let stop: Version = "0.9.0".parse().unwrap();
        let (result, after) = reconcile_with_stops(&api, record, vec![stop]).await;
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(after["status"]["phase"], PHASE_FAILED);
        let reason = after["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains("last deployed with Kix 0.8.0")
                && reason.contains("required stop Kix 0.9.0")
                && reason.contains("Nothing was applied"),
            "{reason}"
        );
        let supersedes: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| r.contains("a-old"))
            .collect();
        assert!(supersedes.is_empty(), "{supersedes:?}");
    }

    /// A Queued build on a cluster that a newer minor of Kix last deployed
    /// fails with its own event reason, and the Active record is left alone.
    #[tokio::test]
    async fn a_queued_build_on_a_cluster_a_newer_kix_deployed_fails() {
        let dir = tempfile::tempdir().unwrap();
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): "a",
                },
            },
            "status": {
                "phase": PHASE_ACTIVE,
                (keys::RECEIPT_FIELD): {
                    "builder": { "kixVersion": "99.0.0" },
                    "source": { "gitCommit": "abc1234def5678" },
                },
            },
        });
        let record = queued(dir.path(), Some(HERE), None);
        let api = FakeApi::new(vec![kube_system(HERE), active, record.clone()]);
        let (result, after) = reconcile_on(&api, record).await;
        assert!(result.is_ok(), "{result:?}");
        assert_eq!(after["status"]["phase"], PHASE_FAILED);
        let reason = after["status"]["failure"]["reason"]
            .as_str()
            .unwrap_or_default();
        assert!(
            reason.contains("last deployed with Kix 99.0.0 (from commit abc1234)")
                && reason.contains("Nothing was applied"),
            "{reason}"
        );
        let requests = api.requests();
        assert!(
            requests
                .iter()
                .any(|r| r.starts_with("POST ") && r.contains("/events")),
            "{requests:?}"
        );
        assert!(
            !requests.iter().any(|r| r.contains("a-old")),
            "{requests:?}"
        );
    }

    /// A Queued build whose definition leaves `k8sVersion` unset is not asked
    /// about the version at all.
    #[tokio::test]
    async fn a_queued_build_without_a_version_is_not_compared() {
        let dir = tempfile::tempdir().unwrap();
        let record = queued(dir.path(), Some(HERE), None);
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        // Past the checks, loading the build fails in the temporary
        // directory, which is after the point under test.
        let (result, after) = reconcile_on(&api, record).await;
        assert!(result.is_err());
        assert_ne!(after["status"]["phase"], PHASE_FAILED);
        assert!(
            !api.requests().iter().any(|r| r.ends_with("/version")),
            "{:?}",
            api.requests()
        );
    }

    /// An Active record is repaired, not refused, after a Kubernetes
    /// upgrade: the version is not even read for it.
    #[tokio::test]
    async fn an_active_record_is_repaired_whatever_the_kubernetes_version() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), Some("1.30"));
        record["status"] = json!({ "phase": PHASE_ACTIVE });
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        // Loading the build fails in the temporary directory, which is after
        // the point where a Queued record would have been refused.
        let (result, after) = reconcile_on(&api, record).await;
        let err = result.unwrap_err().to_string();
        assert!(!err.contains("k8sVersion"), "{err}");
        assert_eq!(after["status"]["phase"], PHASE_ACTIVE);
        assert!(
            !api.requests().iter().any(|r| r.ends_with("/version")),
            "{:?}",
            api.requests()
        );
    }

    /// An earlier record with a request, as `kix rollback --operator`
    /// writes one, is queued again and deployed in the same reconcile, with
    /// no wait for another reconcile. The current record stays current
    /// until that deploy finishes. One without a request, such as a record
    /// a direct deploy wrote or one from before requests, stays Superseded
    /// and is not written.
    #[tokio::test]
    async fn a_request_deploys_an_earlier_record_in_the_same_reconcile() {
        let dir = tempfile::tempdir().unwrap();
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": {
                    "app.kubernetes.io/managed-by": "kix",
                    (keys::CLUSTER_LABEL): "a",
                },
            },
            "status": { "phase": PHASE_ACTIVE },
        });
        let mut record = queued(dir.path(), Some(HERE), None);
        record["status"] = json!({ "phase": PHASE_SUPERSEDED });
        record["spec"]["request"] = json!("r1");
        let api = FakeApi::new(vec![kube_system(HERE), active, record.clone()]);
        // Loading the build fails in the temporary directory, after the
        // record was queued and its request started.
        let (result, after) = reconcile_on(&api, record.clone()).await;
        assert!(result.is_err());
        assert_eq!(after["status"]["phase"], PHASE_QUEUED);
        assert_eq!(after["status"]["startedRequest"], "r1");
        let old = kube::Api::<DynamicObject>::all_with(
            api.client(),
            &kube::discovery::ApiResource::from_gvk_with_plural(
                &kube::api::GroupVersionKind::gvk(keys::GROUP, "v1alpha1", "Activation"),
                "activations",
            ),
        )
        .get("a-old")
        .await
        .unwrap();
        assert_eq!(old.data["status"]["phase"], PHASE_ACTIVE);

        let mut direct = record;
        direct["spec"].as_object_mut().unwrap().remove("request");
        let api = FakeApi::new(vec![kube_system(HERE), direct.clone()]);
        let (_, after) = reconcile_on(&api, direct).await;
        assert_eq!(after["status"]["phase"], PHASE_SUPERSEDED);
        assert!(
            !api.requests().iter().any(|r| r.contains("PATCH")),
            "{:?}",
            api.requests()
        );
    }

    /// A request on the current record, as `kix deploy --operator` of the
    /// build already deployed writes one, is started while the record stays
    /// Active. The checks for a Queued record do not run, so a Kubernetes
    /// upgrade cannot fail the current record.
    #[tokio::test]
    async fn a_request_on_the_current_record_keeps_it_active() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), Some("1.30"));
        record["status"] = json!({ "phase": PHASE_ACTIVE });
        record["spec"]["request"] = json!("r1");
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        // Loading the build fails in the temporary directory, after the
        // request was started.
        let (result, after) = reconcile_on(&api, record).await;
        assert!(result.is_err());
        assert_eq!(after["status"]["phase"], PHASE_ACTIVE);
        assert_eq!(after["status"]["startedRequest"], "r1");
        assert!(after["status"].get("finishedRequest").is_none());
    }

    /// A current record that `kix deploy` wrote without `--operator` has no
    /// `spec.source`. The operator leaves it alone: no finalizer, no repair,
    /// and no error to requeue. The same record with `spec.source` is still
    /// repaired.
    #[tokio::test]
    async fn a_current_record_from_a_direct_deploy_is_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), None);
        record["status"] = json!({ "phase": PHASE_ACTIVE });
        record["spec"].as_object_mut().unwrap().remove("source");
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let (result, after) = reconcile_on(&api, record).await;
        assert_eq!(result.unwrap(), Action::await_change());
        assert_eq!(after["status"]["phase"], PHASE_ACTIVE);
        let stored = api.object("Activation", "a-new").unwrap();
        assert!(stored["metadata"].get("finalizers").is_none(), "{stored}");
        assert!(
            !api.requests().iter().any(|r| !r.starts_with("GET")),
            "{:?}",
            api.requests()
        );

        // With `spec.source`, the operator adds its finalizer and repairs
        // the record. Loading the build then fails in the temporary
        // directory.
        let mut record = queued(dir.path(), Some(HERE), None);
        record["status"] = json!({ "phase": PHASE_ACTIVE });
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let (result, _) = reconcile_on(&api, record).await;
        assert!(result.is_err());
        let stored = api.object("Activation", "a-new").unwrap();
        assert_eq!(stored["metadata"]["finalizers"], json!([FINALIZER]));
    }

    /// A redeploy of the current record that fails answers its request
    /// with the failure in `status.failedRequest`, and leaves
    /// `status.finishedRequest` alone so an older CLI does not take it for
    /// success. The record stays current. A repair that fails, with no
    /// request, answers nothing.
    #[tokio::test]
    async fn a_failed_redeploy_answers_its_request() {
        let mut record = deploying(0);
        record["status"] = json!({ "phase": PHASE_DEGRADED, "finishedRequest": "r0" });
        let api = FakeApi::new([record.clone()]);
        let (result, after) = reconcile_on(&api, record.clone()).await;
        assert!(result.is_err());
        let status = &after["status"];
        assert_eq!(status["phase"], PHASE_DEGRADED);
        assert_eq!(status["startedRequest"], "r1");
        assert_eq!(status["finishedRequest"], "r0");
        assert_eq!(status["failedRequest"]["request"], "r1");
        let reason = status["failedRequest"]["reason"].as_str().unwrap();
        assert!(
            reason.starts_with("the Kix operator could not redeploy the current build. This Activation stays Degraded,")
                && reason.contains("Cause:\n    ")
                && reason.contains("/nonexistent"),
            "{reason}"
        );

        // The next reconcile finds the request started and only repairs.
        let (result, after) = reconcile_on(&api, api.object("Activation", "a-new").unwrap()).await;
        assert!(result.is_err());
        assert_eq!(after["status"]["failedRequest"]["request"], "r1");

        record["spec"].as_object_mut().unwrap().remove("request");
        let api = FakeApi::new([record.clone()]);
        let (result, after) = reconcile_on(&api, record).await;
        assert!(result.is_err());
        assert!(after["status"].get("failedRequest").is_none(), "{after}");
    }

    /// A request the operator already started is not started again: a
    /// direct deploy that reuses the record leaves its request as it was,
    /// and the operator only repairs the record.
    #[tokio::test]
    async fn a_started_request_is_not_started_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), None);
        record["status"] = json!({ "phase": PHASE_ACTIVE, "startedRequest": "r1" });
        record["spec"]["request"] = json!("r1");
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let _ = reconcile_on(&api, record).await;
        assert!(
            !api.requests()
                .iter()
                .any(|r| r.contains("PATCH") && r.contains("/status")),
            "{:?}",
            api.requests()
        );
    }

    /// Deleting `b`'s Active record tears down `b`'s closure but leaves the
    /// ClusterRole `a`'s current build also contains.
    #[tokio::test]
    async fn finalizer_keeps_what_another_cluster_still_deploys() {
        use kix::cluster::fake_api::FakeApi;
        let rec = |cluster: &str, hash: &str| {
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": cluster,
                    "labels": { (keys::CLUSTER_LABEL): cluster },
                    "annotations": { (keys::IDENTITY_HASH): hash },
                },
                "status": { "phase": PHASE_ACTIVE },
            })
        };
        let role = |name: &str, activations: &str| {
            json!({
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "ClusterRole",
                "metadata": { "name": name, "annotations": { (keys::ACTIVATIONS): activations } },
            })
        };
        let api = FakeApi::new([
            rec("a", "a1"),
            rec("b", "b1"),
            role("b-only", "b1"),
            role("shared", "a1,b1"),
        ]);
        let rid = |name: &str| ResourceId {
            group: "rbac.authorization.k8s.io".into(),
            kind: "ClusterRole".into(),
            namespace: kix::manifest::types::CLUSTER_SCOPED.into(),
            name: name.into(),
        };
        delete_closure(
            &api.client(),
            "b",
            "b",
            DeleteOrder::unordered(vec![rid("b-only"), rid("shared")]),
            &CancelToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }

    /// An object that keeps its finalizer past the wait fails the teardown,
    /// so the Activation keeps the operator's finalizer and the next
    /// reconcile tries again.
    #[tokio::test(start_paused = true)]
    async fn a_stuck_delete_keeps_the_activation_finalizer() {
        use kix::cluster::fake_api::FakeApi;
        let api = FakeApi::new([
            json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": {
                    "name": "b",
                    "labels": { (keys::CLUSTER_LABEL): "b" },
                    "annotations": { (keys::IDENTITY_HASH): "b1" },
                },
                "status": { "phase": PHASE_ACTIVE },
            }),
            json!({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "held",
                    "namespace": "app",
                    "finalizers": ["example.com/hold"],
                    "annotations": { (keys::ACTIVATIONS): "b1" },
                },
            }),
        ]);
        let rid = ResourceId::new("", "ConfigMap", "app", "held");
        let err = delete_closure(
            &api.client(),
            "b",
            "b",
            DeleteOrder::unordered(vec![rid.clone()]),
            &CancelToken::new(),
        )
        .await
        .unwrap_err();
        assert!(
            matches!(&err, OperatorError::DeletionUnfinished { count: 1, leftovers }
                if leftovers.contains("waiting for example.com/hold")),
            "{err}"
        );

        // A shutdown stops the wait at once, and the record keeps its
        // finalizer.
        let shutdown = CancelToken::new();
        shutdown.cancel();
        let start = tokio::time::Instant::now();
        let err = delete_closure(
            &api.client(),
            "b",
            "b",
            DeleteOrder::unordered(vec![rid]),
            &shutdown,
        )
        .await
        .unwrap_err();
        assert!(
            matches!(err, OperatorError::DeletionUnfinished { .. }),
            "{err}"
        );
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    /// The operator's one recorder turns a repeated warning on the same
    /// Activation into a count on one Event, so a teardown that keeps
    /// failing does not add an Event at every retry.
    #[tokio::test]
    async fn a_repeated_teardown_warning_is_one_event() {
        use kix::cluster::fake_api::FakeApi;
        let api = FakeApi::new([]);
        let recorder = crate::k8s_events::recorder(api.client(), None);
        let activation: DynamicObject = serde_json::from_value(json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": { "name": "b", "uid": "uid-b" },
        }))
        .unwrap();
        for _ in 0..3 {
            K8sEventObserver::new(recorder.clone(), &activation, keys::API_VERSION)
                .warn_now("DeletionUnfinished", "1 object(s) are still on the cluster")
                .await;
        }
        assert_eq!(api.names("Event").len(), 1, "{:?}", api.requests());
    }

    /// A teardown that did not finish is retried after the error requeue.
    #[test]
    fn an_unfinished_teardown_is_requeued() {
        let activation: Arc<DynamicObject> = Arc::new(
            serde_json::from_value(json!({
                "apiVersion": keys::API_VERSION,
                "kind": "Activation",
                "metadata": { "name": "b" },
            }))
            .unwrap(),
        );
        let err = OperatorError::DeletionUnfinished {
            count: 1,
            leftovers: "ConfigMap/held@app (waiting for example.com/hold)".into(),
        };
        let api = kix::cluster::fake_api::FakeApi::new([]);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let ctx = runtime.block_on(async {
            let client = api.client();
            let discovery = kix::cluster::discovery::discover_resources(&client)
                .await
                .unwrap();
            Arc::new(Context {
                records: Records::open_installed(&client, &discovery).unwrap(),
                client,
                required_stops: Vec::new(),
                shutdown: CancelToken::new(),
                events: crate::k8s_events::recorder(api.client(), None),
                deploy_retries: DEFAULT_DEPLOY_RETRIES,
                holder: Holder::operator("kix", None),
                runs: Default::default(),
            })
        });
        assert_eq!(
            error_policy(activation, &err, ctx),
            Action::requeue(ERROR_REQUEUE_INTERVAL)
        );
    }

    /// A Deploying record of cluster `a` whose deploy the operator started
    /// for request `r1`, after `failed` runs that stopped.
    fn deploying(failed: u32) -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-new",
                "labels": { (keys::CLUSTER_LABEL): "a" },
            },
            "spec": {
                "cluster": "a",
                "source": { "type": "storePath", "path": "/nonexistent" },
                "request": "r1",
            },
            "status": {
                "phase": PHASE_DEPLOYING,
                "startedRequest": "r1",
                "failedAttempts": failed,
            },
        })
    }

    /// A run that stopped at a Secret whose SOPS file could not be
    /// decrypted.
    fn stopped() -> DeployError {
        use kix::cluster::stream::{NodeFailure, NodeId};
        DeployError::NodesFailed {
            count: 1,
            partial: DeployResult {
                failed: 1,
                failures: vec![NodeFailure {
                    node: NodeId::Resource(ResourceId::new("", "Secret", "app", "db")),
                    message: "cannot decrypt SOPS file db.yaml\n  no key".into(),
                }],
                ..Default::default()
            },
        }
    }

    /// Return a Context on `api` that retries a stopped deploy `retries`
    /// times, as an operator that has just started would have.
    async fn operator(api: &FakeApi, retries: u32) -> Context {
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        Context {
            records: Records::open_installed(&client, &discovery).unwrap(),
            client,
            required_stops: Vec::new(),
            shutdown: CancelToken::new(),
            events: crate::k8s_events::recorder(api.client(), None),
            deploy_retries: retries,
            holder: Holder::operator("kix", None),
            runs: Default::default(),
        }
    }

    /// The operator takes a Kix cluster's deploy lock as itself. When a live
    /// run from a machine holds it, the operator waits for its next
    /// renewal, then leaves the lock alone and tries again later. A lock its
    /// own previous pod left is taken over at once.
    #[tokio::test(start_paused = true)]
    async fn the_operator_waits_for_a_live_lock_and_takes_back_its_own() {
        let api = FakeApi::new([]);
        let ctx = operator(&api, DEFAULT_DEPLOY_RETRIES).await;
        let cli = head::take(
            &ctx.client,
            head::Request {
                cluster: "a".into(),
                holder: Holder::cli("kix deploy"),
                purpose: Purpose::Deploy,
                activation: Some("a-new".into()),
                expect: None,
            },
            head::system_clock(),
            &|_| {},
        )
        .await
        .unwrap();
        assert!(
            ctx.take("a", Purpose::Repair, "a-old")
                .await
                .unwrap()
                .is_none()
        );
        cli.release().await.unwrap();

        let mine = ctx
            .take("a", Purpose::Deploy, "a-new")
            .await
            .unwrap()
            .unwrap();
        // The pod stops without releasing; the next pod has the same id.
        drop(mine);
        let started = tokio::time::Instant::now();
        let again = ctx.take("a", Purpose::Deploy, "a-new").await.unwrap();
        assert!(again.is_some());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    /// Hand `result` of a `reconcile` run of record `a-new` to the operator,
    /// and return its answer and the record's status afterwards.
    async fn after_a_run(
        api: &FakeApi,
        ctx: &Context,
        reconcile: Reconcile,
        result: Result<DeployResult, DeployError>,
    ) -> (Result<Action, OperatorError>, Value) {
        let record: DynamicObject =
            serde_json::from_value(api.object("Activation", "a-new").unwrap()).unwrap();
        let answer = after_run(&record, ctx, &ctx.records, "a-new", reconcile, result).await;
        let status = api.object("Activation", "a-new").unwrap()["status"].clone();
        (answer, status)
    }

    /// Return the reasons of the Events posted on `api`.
    fn event_reasons(api: &FakeApi) -> Vec<String> {
        api.names("Event")
            .iter()
            .filter_map(|n| api.object("Event", n))
            .map(|e| e["reason"].as_str().unwrap_or_default().to_string())
            .collect()
    }

    /// Each stopped run under the limit is counted on the record, which
    /// stays Deploying, and the error requeues the next try. A run that
    /// then succeeds is not marked Failed.
    #[tokio::test]
    async fn a_stopped_deploy_is_retried_and_may_then_succeed() {
        let api = FakeApi::new([deploying(0)]);
        let ctx = operator(&api, 2).await;
        for attempt in 1..=2 {
            let (answer, status) = after_a_run(&api, &ctx, Reconcile::Resume, Err(stopped())).await;
            assert!(answer.is_err(), "{answer:?}");
            assert_eq!(status["phase"], PHASE_DEPLOYING);
            assert_eq!(status["failedAttempts"], attempt);
            assert_eq!(
                status["failure"]["reason"],
                "Secret/db@app: cannot decrypt SOPS file db.yaml\n  no key"
            );
        }
        assert_eq!(event_reasons(&api), ["DeployRetrying", "DeployRetrying"]);
        let (answer, status) =
            after_a_run(&api, &ctx, Reconcile::Resume, Ok(DeployResult::default())).await;
        assert_eq!(answer.unwrap(), Action::requeue(requeue_interval()));
        assert_eq!(status["phase"], PHASE_DEPLOYING);
    }

    /// The run after the last retry marks the record Failed with the number
    /// of attempts and the last failure, posts a DeployFailed Event, and
    /// waits for a new request instead of requeueing.
    #[tokio::test]
    async fn a_deploy_that_keeps_stopping_is_marked_failed_after_the_retries() {
        let api = FakeApi::new([deploying(2)]);
        let ctx = operator(&api, 2).await;
        let (answer, status) = after_a_run(&api, &ctx, Reconcile::Resume, Err(stopped())).await;
        assert_eq!(answer.unwrap(), Action::await_change());
        assert_eq!(status["phase"], PHASE_FAILED);
        assert_eq!(status["failedAttempts"], 3);
        let reason = status["failure"]["reason"].as_str().unwrap();
        assert!(
            reason.contains("after 3 failed attempts (KIX_DEPLOY_RETRIES is 2")
                && reason.contains("kix deploy --operator")
                && reason.contains("Secret/db@app: cannot decrypt SOPS file db.yaml\n      no key"),
            "{reason}"
        );
        assert_eq!(event_reasons(&api), ["DeployFailed"]);
    }

    /// With no retries, the first stop marks the record Failed, as `kix
    /// deploy` does.
    #[tokio::test]
    async fn zero_retries_fail_the_deploy_at_the_first_stop() {
        let api = FakeApi::new([deploying(0)]);
        let ctx = operator(&api, 0).await;
        let (answer, status) = after_a_run(&api, &ctx, Reconcile::Start, Err(stopped())).await;
        assert_eq!(answer.unwrap(), Action::await_change());
        assert_eq!(status["phase"], PHASE_FAILED);
        assert_eq!(status["failedAttempts"], 1);
        let reason = status["failure"]["reason"].as_str().unwrap();
        assert!(reason.contains("after 1 failed attempt ("), "{reason}");
    }

    /// A run that the operator's shutdown interrupted writes nothing, so
    /// the operator that starts next resumes it with the count it had. That
    /// count is read from the record, so the restart does not reset it.
    #[tokio::test]
    async fn a_run_interrupted_by_a_restart_is_not_counted() {
        let api = FakeApi::new([deploying(2)]);
        let ctx = operator(&api, 2).await;
        ctx.shutdown.cancel();
        let cancelled = Err(DeployError::Cancelled {
            reason: "cancelled".into(),
            partial: DeployResult::default(),
        });
        let (answer, status) = after_a_run(&api, &ctx, Reconcile::Resume, cancelled).await;
        assert!(answer.is_err(), "{answer:?}");
        assert_eq!(status["phase"], PHASE_DEPLOYING);
        assert_eq!(status["failedAttempts"], 2);
        assert!(status.get("failure").is_none(), "{status}");
        assert!(event_reasons(&api).is_empty());

        // The next operator's resume stops once more, which is the third
        // failed attempt.
        let restarted = operator(&api, 2).await;
        let (answer, status) =
            after_a_run(&api, &restarted, Reconcile::Resume, Err(stopped())).await;
        assert_eq!(answer.unwrap(), Action::await_change());
        assert_eq!(status["phase"], PHASE_FAILED);
        assert_eq!(status["failedAttempts"], 3);
    }

    /// A stall cancels only the run it stalls in. The operator keeps
    /// running, and the stall counts as a failed attempt.
    #[tokio::test]
    async fn a_stalled_run_counts_and_leaves_the_operator_running() {
        let api = FakeApi::new([deploying(0)]);
        let ctx = operator(&api, 2).await;
        ctx.shutdown
            .child()
            .cancel_with_reason("no progress for 600s");
        assert!(!ctx.shutdown.is_cancelled());
        let stalled = Err(DeployError::Cancelled {
            reason: "no progress for 600s".into(),
            partial: DeployResult::default(),
        });
        let (answer, status) = after_a_run(&api, &ctx, Reconcile::Resume, stalled).await;
        assert!(answer.is_err(), "{answer:?}");
        assert_eq!(status["failedAttempts"], 1);
        assert_eq!(
            status["failure"]["reason"],
            "deploy cancelled: no progress for 600s"
        );
    }

    /// A redeploy of the current record that stops is not counted: the
    /// record stays current and is repaired on the next reconcile.
    #[tokio::test]
    async fn a_stopped_redeploy_of_the_current_record_is_not_counted() {
        let mut record = deploying(0);
        record["status"]["phase"] = json!(PHASE_ACTIVE);
        let api = FakeApi::new([record]);
        let ctx = operator(&api, 0).await;
        let (answer, status) = after_a_run(&api, &ctx, Reconcile::Redeploy, Err(stopped())).await;
        assert!(answer.is_err(), "{answer:?}");
        assert_eq!(status["phase"], PHASE_ACTIVE);
        assert_eq!(status["failedAttempts"], 0);
        assert!(event_reasons(&api).is_empty());
    }

    /// A repair goes on past an object it could not repair, and only a
    /// repair does. A repair that ends with such an object is an error, so
    /// the next repair comes after the error requeue, and the record is not
    /// written.
    #[tokio::test]
    async fn a_repair_with_an_object_it_could_not_repair_requeues_as_an_error() {
        assert_eq!(Reconcile::Repair.on_error(), OnErrorPolicy::Continue);
        for deploy in [Reconcile::Start, Reconcile::Redeploy, Reconcile::Resume] {
            assert_eq!(deploy.on_error(), OnErrorPolicy::Stop);
        }

        let mut record = deploying(0);
        record["status"]["phase"] = json!(PHASE_ACTIVE);
        let api = FakeApi::new([record]);
        let ctx = operator(&api, 0).await;
        let DeployError::NodesFailed { partial, .. } = stopped() else {
            unreachable!()
        };
        let repaired = DeployResult {
            configured: 1,
            ..partial
        };
        let (answer, status) = after_a_run(&api, &ctx, Reconcile::Repair, Ok(repaired)).await;
        let err = answer.unwrap_err();
        assert_eq!(
            err.to_string(),
            "reconcile failed: Secret/db@app: cannot decrypt SOPS file db.yaml\n  no key"
        );
        assert_eq!(
            error_policy(
                Arc::new(
                    serde_json::from_value(api.object("Activation", "a-new").unwrap()).unwrap()
                ),
                &err,
                Arc::new(operator(&api, 0).await),
            ),
            Action::requeue(ERROR_REQUEUE_INTERVAL)
        );
        assert_eq!(status["phase"], PHASE_ACTIVE);
        assert_eq!(status["failedAttempts"], 0);
    }

    /// A new request starts the count again: a Queued record submitted
    /// for a new request, and a Failed record that someone deploys again.
    /// The attempt in each case then fails, because the build in the
    /// temporary directory cannot be loaded, and counts as the first.
    #[tokio::test]
    async fn a_new_request_starts_the_count_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), None);
        record["spec"]["request"] = json!("r1");
        record["status"] = json!({ "failedAttempts": 5 });
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let (result, after) = reconcile_on(&api, record.clone()).await;
        assert!(result.is_err());
        assert_eq!(after["status"]["failedAttempts"], 1, "{after}");

        record["status"] = json!({
            "phase": PHASE_FAILED,
            "failedAttempts": 11,
            "startedRequest": "r1",
            "finishedRequest": "r1",
        });
        record["spec"]["request"] = json!("r2");
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let (result, after) = reconcile_on(&api, record).await;
        assert!(result.is_err());
        assert_eq!(after["status"]["startedRequest"], "r2");
        assert_eq!(after["status"]["failedAttempts"], 1, "{after}");
    }

    /// A request on a Partial record queues it again, as on a Failed
    /// record, and drops its `status.partial`.
    #[tokio::test]
    async fn a_request_on_a_partial_record_queues_it_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), None);
        record["spec"]["request"] = json!("r1");
        record["status"] = json!({
            "phase": PHASE_PARTIAL,
            "partial": { "only": ["app/a"], "at": "2026-11-25T10:00:00Z" },
        });
        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let (result, after) = reconcile_on(&api, record).await;
        assert!(result.is_err());
        assert_eq!(after["status"]["startedRequest"], "r1");
        assert_ne!(after["status"]["phase"], PHASE_PARTIAL, "{after}");
        assert!(after["status"].get("partial").is_none(), "{after}");
    }

    /// Reconcile `record` on `api` with an operator that retries `retries`
    /// times, and return the answer and the record's status afterwards.
    async fn reconcile_retrying(
        api: &FakeApi,
        record: Value,
        retries: u32,
    ) -> (Result<Action, OperatorError>, Value) {
        let ctx = Arc::new(operator(api, retries).await);
        let name = record["metadata"]["name"].as_str().unwrap().to_string();
        let activation: DynamicObject = serde_json::from_value(record).unwrap();
        let answer = reconcile_activation(Arc::new(activation), ctx).await;
        let status = api.object("Activation", &name).unwrap()["status"].clone();
        (answer, status)
    }

    /// A Deploying record whose build the operator cannot read counts each
    /// attempt, and is marked Failed once the retries run out, as a run
    /// that stopped is. The reason names the build.
    #[tokio::test]
    async fn a_missing_build_counts_as_a_failed_attempt() {
        let api = FakeApi::new([deploying(0)]);
        let (answer, status) = reconcile_retrying(&api, deploying(0), 1).await;
        assert!(answer.is_err(), "{answer:?}");
        assert_eq!(status["phase"], PHASE_DEPLOYING);
        assert_eq!(status["failedAttempts"], 1);
        let reason = status["failure"]["reason"].as_str().unwrap();
        assert!(
            reason.starts_with(
                "the operator pod cannot read the build at /nonexistent (`spec.source.path`): "
            ),
            "{reason}"
        );

        let (answer, status) = reconcile_retrying(&api, deploying(1), 1).await;
        assert_eq!(answer.unwrap(), Action::await_change());
        assert_eq!(status["phase"], PHASE_FAILED);
        assert_eq!(status["failedAttempts"], 2);
        let reason = status["failure"]["reason"].as_str().unwrap();
        assert!(
            reason.contains("after 2 failed attempts")
                && reason.contains("cannot read the build at /nonexistent"),
            "{reason}"
        );
        assert_eq!(event_reasons(&api), ["DeployRetrying", "DeployFailed"]);
    }

    /// A Queued record whose build index the operator cannot read counts
    /// the attempt while the record stays Queued, and is marked Failed once
    /// the retries run out. The current record is not superseded.
    #[tokio::test]
    async fn a_queued_record_with_a_missing_build_fails_after_the_retries() {
        let active = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
            },
            "spec": { "cluster": "a", "source": { "type": "storePath", "path": "/old" } },
            "status": { "phase": PHASE_ACTIVE },
        });
        let mut record = deploying(0);
        record["status"] = json!({ "phase": PHASE_QUEUED, "startedRequest": "r1" });
        let api = FakeApi::new(vec![kube_system(HERE), active, record.clone()]);
        let (answer, status) = reconcile_retrying(&api, record.clone(), 1).await;
        assert!(answer.is_err(), "{answer:?}");
        assert_eq!(status["phase"], PHASE_QUEUED);
        assert_eq!(status["failedAttempts"], 1);

        record["status"]["failedAttempts"] = json!(1);
        let (answer, status) = reconcile_retrying(&api, record, 1).await;
        assert_eq!(answer.unwrap(), Action::await_change());
        assert_eq!(status["phase"], PHASE_FAILED);
        assert_eq!(status["finishedRequest"], "r1");
        assert_eq!(
            api.object("Activation", "a-old").unwrap()["status"]["phase"],
            PHASE_ACTIVE
        );
    }

    /// A redeploy or a repair of the current record whose build cannot be
    /// read is not counted: the record stays current, and the reconcile is
    /// retried.
    #[tokio::test]
    async fn a_missing_build_on_the_current_record_is_not_counted() {
        let mut record = deploying(0);
        record["status"] = json!({ "phase": PHASE_ACTIVE, "startedRequest": "r1" });
        let api = FakeApi::new([record.clone()]);
        let (answer, status) = reconcile_retrying(&api, record, 0).await;
        assert!(answer.is_err(), "{answer:?}");
        assert_eq!(status["phase"], PHASE_ACTIVE);
        assert!(status.get("failedAttempts").is_none(), "{status}");
        assert!(event_reasons(&api).is_empty());
    }

    /// The current record of cluster `a`, built from `/old`, which the
    /// operator repairs.
    fn current() -> Value {
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {
                "name": "a-old",
                "labels": { "app.kubernetes.io/managed-by": "kix", (keys::CLUSTER_LABEL): "a" },
            },
            "spec": { "cluster": "a", "source": { "type": "storePath", "path": "/old" } },
            "status": { "phase": PHASE_ACTIVE },
        })
    }

    /// A Queued record whose deploy starts and then fails leaves the current
    /// record Active, so the cluster keeps a current record. The reason
    /// names it. Without a current record, the reason names none.
    #[tokio::test]
    async fn a_failed_deploy_leaves_the_current_record_active() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = queued(dir.path(), Some(HERE), None);
        record["spec"]["request"] = json!("r1");
        let api = FakeApi::new(vec![kube_system(HERE), current(), record.clone()]);
        // The checks pass, and loading the build then fails in the
        // temporary directory, which is the point where the current record
        // used to be superseded.
        let (answer, status) = reconcile_retrying(&api, record.clone(), 0).await;
        assert_eq!(answer.unwrap(), Action::await_change());
        assert_eq!(status["phase"], PHASE_FAILED);
        assert_eq!(status["finishedRequest"], "r1");
        let reason = status["failure"]["reason"].as_str().unwrap();
        assert!(
            reason.contains(
                "Activation 'a-old' remains the current deployment, and the operator will restore the cluster to match it."
            ),
            "{reason}"
        );
        assert_eq!(
            api.object("Activation", "a-old").unwrap()["status"]["phase"],
            PHASE_ACTIVE
        );
        assert!(
            !api.requests()
                .iter()
                .any(|r| r.contains("PATCH") && r.contains("a-old/status")),
            "{:?}",
            api.requests()
        );

        let api = FakeApi::new(vec![kube_system(HERE), record.clone()]);
        let (_, status) = reconcile_retrying(&api, record, 0).await;
        assert_eq!(status["phase"], PHASE_FAILED);
        let reason = status["failure"]["reason"].as_str().unwrap();
        assert!(!reason.contains("current deployment"), "{reason}");
    }

    /// Return `record` with the `managed-by` label that
    /// [`Records::submit`] writes, so a listing of its cluster finds it.
    fn listed(mut record: Value) -> Value {
        record["metadata"]["labels"]["app.kubernetes.io/managed-by"] = json!("kix");
        record
    }

    /// The current record does not repair while the operator deploys a
    /// newer record of its cluster, so the repair cannot undo that deploy.
    /// It writes nothing and checks again soon.
    #[tokio::test]
    async fn the_current_record_waits_while_a_newer_one_deploys() {
        let api = FakeApi::new(vec![current(), listed(deploying(1))]);
        let (result, after) = reconcile_on(&api, current()).await;
        assert_eq!(result.unwrap(), Action::requeue(QUEUED_REQUEUE_INTERVAL));
        assert_eq!(after["status"]["phase"], PHASE_ACTIVE);
        let writes: Vec<String> = api
            .requests()
            .into_iter()
            .filter(|r| !r.starts_with("GET"))
            .collect();
        assert!(writes.is_empty(), "{writes:?}");
    }

    /// Once the newer record is Failed, or when the record deploying names
    /// no build because a direct `kix deploy` wrote it, the current record
    /// repairs again. The repair then fails here only because `/old` does
    /// not exist.
    #[tokio::test]
    async fn the_current_record_repairs_after_a_newer_deploy_fails() {
        let mut failed = deploying(11);
        failed["status"]["phase"] = json!(PHASE_FAILED);
        let mut direct = deploying(0);
        direct["metadata"]["name"] = json!("a-direct");
        direct["spec"].as_object_mut().unwrap().remove("source");
        for other in [failed, direct] {
            let api = FakeApi::new(vec![current(), listed(other)]);
            let (result, after) = reconcile_on(&api, current()).await;
            let err = result.unwrap_err().to_string();
            assert!(err.contains("cannot read the build at /old"), "{err}");
            assert_eq!(after["status"]["phase"], PHASE_ACTIVE);
        }
    }
}
