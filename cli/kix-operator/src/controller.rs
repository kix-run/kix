//! Reconcile Activation resources for the Kix operator.
//!
//! # Phase-based lifecycle
//!
//! The operator manages Activation CRs through a phase-based lifecycle:
//!
//! New resources progress through Queued, Deploying, Active, and Superseded.
//!
//! - **Queued**: A new activation waiting to be deployed. The operator
//!   supersedes the current Active activation and begins deploying this one.
//! - **Deploying**: Deploy in progress (wave-by-wave apply).
//! - **Active**: Successfully deployed. Drift detection runs on requeue.
//! - **Superseded**: Replaced by a newer activation.
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
use kix::cluster::graph::ResourceGraph;
use kix::cluster::kubernetes_version;
use kix::cluster::prune_guard::{self, Pruned, Removal};
use kix::cluster::scheduler::{self, OnErrorPolicy, SchedulerConfig};
use kix::cluster::stops;
use kix::cluster::stream::DeployObserver;
use kix::cluster::watchdog::StallPolicy;
use kix::eval::store_graph::{KixPackageIndex, read_index};
use kix::manifest::lifecycle::{
    PHASE_ACTIVE, PHASE_DEGRADED, PHASE_DEPLOYING, PHASE_FAILED, PHASE_QUEUED, PHASE_SUPERSEDED,
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
}

/// Errors from the operator reconcile loop.
#[derive(Error, Debug)]
pub enum OperatorError {
    #[error("missing spec.source.path on Activation")]
    MissingSourcePath,

    #[error("failed to load store graph from {path}: {reason}")]
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
    let build = Build::local(path, &|_| {}).map_err(|e| OperatorError::StoreGraphError {
        path: path.display().to_string(),
        reason: e.to_string(),
    })?;
    Ok(build
        .graph()
        .resources
        .values()
        .map(|r| r.manifest.clone())
        .collect())
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
        // build whose deploy failed. Queue it and deploy it in this
        // reconcile, as a new record that supersedes the current one.
        s if s == PHASE_SUPERSEDED || s == PHASE_FAILED => match request {
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
            // Failed is terminal. The deploy that owned it has stopped, and
            // the next one folds its closure into the plan and supersedes it.
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
            // Yield to any queued Activation so it can perform the transition.
            let queued = ctx
                .records
                .queued(&cluster)
                .await
                .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;

            if !queued.is_empty() {
                tracing::info!(
                    name,
                    queued_count = queued.len(),
                    "Queued activations exist, yielding"
                );
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
            let action = run_reconcile(&activation, &ctx, name, Reconcile::Start).await?;
            finish_request(&ctx, name, Some(request)).await?;
            Ok(action)
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
            return run_reconcile(&activation, &ctx, name, Reconcile::Resume).await;
        }

        _ => {
            tracing::debug!(name, phase, "Unknown phase, skipping");
            Ok(Action::requeue(requeue_interval()))
        }
    }
}

/// Start the deploy of Queued record `name` of Kix cluster `cluster`: start
/// its pending request, run the checks a new record gets, supersede the
/// records it replaces, and deploy it.
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
    let events = || {
        K8sEventObserver::new(
            ctx.client.clone(),
            activation,
            keys::API_VERSION,
            Some(name.to_string()),
        )
    };
    let index = index_of(activation)?;
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
    if let Err(refusal) = stops::check(
        old_active.as_ref(),
        kix::version::running(),
        &ctx.required_stops,
    ) {
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

    if let Some(ref old) = old_active {
        tracing::info!(name, old = %old.name, "Superseding current Active activation");
        ctx.records
            .supersede(&old.name)
            .await
            .map_err(|e| OperatorError::LifecycleError(e.to_string()))?;
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
    /// Start the deploy of a Queued record, or of a request on the current
    /// record. This happens once for each deploy someone submits.
    Start,
    /// Resume a Deploying record, after the operator restarted or a run
    /// returned an error.
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
        self == Reconcile::Start
    }
}

/// Load desired state, fetch live state, diff, wave-plan, and apply.
async fn run_reconcile(
    activation: &DynamicObject,
    ctx: &Context,
    name: &str,
    reconcile: Reconcile,
) -> Result<Action, OperatorError> {
    let manage_lifecycle = reconcile.manages_lifecycle();
    let path = source_path(activation).ok_or(OperatorError::MissingSourcePath)?;
    let new_manifests = load_manifests(&path)?;

    if new_manifests.is_empty() {
        tracing::warn!(name, "No manifests found in store graph");
        return Ok(Action::requeue(requeue_interval()));
    }

    // Exclude CRDs (re-applying them triggers API watch restarts) and
    // Activation CRs (applying the Nix-generated manifest would overwrite
    // `spec.source` via server-side apply).
    let managed_manifests: Vec<Value> = new_manifests
        .iter()
        .filter(|m| {
            ResourceId::from_value(m).kind != "CustomResourceDefinition"
                && !kix::manifest::lifecycle::is_record(m)
        })
        .cloned()
        .collect();

    if managed_manifests.is_empty() {
        tracing::debug!(name, "No managed manifests to reconcile");
        return Ok(Action::requeue(requeue_interval()));
    }

    let mut plan = LivePlan::sweep(&ctx.client, activation, &managed_manifests)
        .await
        .map_err(operator_error)?;
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
    for (owner, count) in plan.foreign() {
        tracing::debug!(name, owner = %owner, count, "left out objects of another Kix cluster");
    }
    if plan.unattributed() > 0 {
        tracing::info!(
            name,
            count = plan.unattributed(),
            "left out Kix objects that name no Activation record; another Kix cluster deploys here",
        );
    }
    for s in plan.shared_orphans() {
        tracing::info!(name, resource = %s.rid, clusters = ?s.clusters, "prune: {}", s.describe());
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
        on_error: OnErrorPolicy::Stop,
        cancel: ctx.shutdown.clone(),
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
            ctx.client.clone(),
            activation,
            keys::API_VERSION,
            Some(name.to_string()),
        )) as Arc<dyn DeployObserver>,
    ]));
    let result = plan.run(manage_lifecycle, config, observer).await;

    match result {
        Ok(r) => {
            tracing::info!(
                name,
                created = r.created,
                configured = r.configured,
                unchanged = r.unchanged,
                pruned = r.pruned,
                failed = r.failed,
                lifecycle = manage_lifecycle,
                "Reconciliation complete"
            );
            Ok(Action::requeue(requeue_interval()))
        }
        Err(e) => {
            tracing::error!(name, error = %e, "Reconciliation failed");
            Err(OperatorError::ReconcileError(e.to_string()))
        }
    }
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

            let orphan_set: std::collections::HashSet<String> = all_rids
                .iter()
                .map(|rid| format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
                .collect();
            let orphan_manifests: Vec<Value> = manifests
                .iter()
                .filter(|m| {
                    let rid = ResourceId::from_value(m);
                    orphan_set.contains(&format!("{}/{}/{}", rid.kind, rid.namespace, rid.name))
                })
                .cloned()
                .collect();
            let ordered: Vec<ResourceId> = match ResourceGraph::from_manifests(&orphan_manifests) {
                Ok(g) => g.reverse_topo_ids(),
                Err(_) => all_rids.clone(),
            };

            delete_closure(&ctx.client, cluster, name, &ordered).await?;
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

/// Delete a deleted record's resources in `ordered` order through
/// [`prune_guard::delete_in_order`], preserving any object still referenced by
/// another Kix cluster's current build (such as a shared ClusterRole), and log
/// what happened to each. Namespaces and CRDs stay, which also keeps the CRD
/// this operator's own Activation records live in. `cluster` is the record's
/// Kix cluster; because the record remains listed while its finalizer is
/// present, its own hash still counts as belonging to `cluster`.
async fn delete_closure(
    client: &Client,
    cluster: &str,
    name: &str,
    ordered: &[ResourceId],
) -> Result<(), OperatorError> {
    let removals = prune_guard::delete_in_order(client, cluster, ordered)
        .await
        .map_err(|e| OperatorError::DiscoveryError(e.to_string()))?;
    for (rid, removal) in removals {
        match removal {
            Removal::NeverPruned => tracing::info!(
                name,
                resource = %rid,
                "Kept while deleting Activation: Kix never deletes this kind automatically. Delete it with kubectl if you want to remove it"
            ),
            Removal::UnknownKind => tracing::warn!(
                name,
                resource = %rid,
                "Not deleted while deleting Activation: Kubernetes does not recognize this kind. If its CustomResourceDefinition was removed, Kubernetes already deleted this object with it"
            ),
            Removal::Pruned(Pruned::Deleted) => tracing::info!(name, resource = %rid, "Deleted"),
            Removal::Pruned(Pruned::Gone) => {}
            Removal::Pruned(kept) => {
                let reason = kept.kept_reason().unwrap_or_default();
                tracing::info!(name, resource = %rid, "prune: {reason}");
            }
            Removal::Failed(e) => {
                tracing::warn!(name, resource = %rid, error = %e, "Failed to delete")
            }
        }
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
        assert!(Reconcile::Start.reads_last_runs());
        assert!(!Reconcile::Resume.reads_last_runs());
        assert!(!Reconcile::Repair.reads_last_runs());
        assert!(Reconcile::Start.manages_lifecycle() && Reconcile::Resume.manages_lifecycle());
        assert!(!Reconcile::Repair.manages_lifecycle());
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
            reason.contains(&format!("`cluster.kubernetes.uid` in 'a':  {ELSEWHERE}"))
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
    /// writes one, is queued again and deployed in the same reconcile: the
    /// current record is superseded at once, with no wait for another
    /// reconcile. One without a request, such as a record a direct deploy
    /// wrote or one from before requests, stays Superseded and is not
    /// written.
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
        // record was queued, its request started, and the current record
        // superseded.
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
        assert_eq!(old.data["status"]["phase"], PHASE_SUPERSEDED);

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
        delete_closure(&api.client(), "b", "b", &[rid("b-only"), rid("shared")])
            .await
            .unwrap();
        assert_eq!(api.names("ClusterRole"), vec!["shared"]);
    }
}
